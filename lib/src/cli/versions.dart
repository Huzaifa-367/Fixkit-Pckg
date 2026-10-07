import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import '../server/paths.dart';
import 'editors.dart';
import 'jsonc.dart';
import 'project.dart';
import 'templates.dart';

/// A semantic version: `1.2.3`, `1.2.3-beta.1`, with or without a leading `v`.
class Semver implements Comparable<Semver> {
  const Semver(this.major, this.minor, this.patch, [this.pre = '']);

  static Semver? tryParse(String? text) {
    if (text == null) return null;
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$').firstMatch(text.trim());
    if (match == null) return null;
    return Semver(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!), match[4] ?? '');
  }

  final int major;
  final int minor;
  final int patch;

  /// The pre-release part, like `beta.1`; empty for a release.
  final String pre;

  bool get isPrerelease => pre.isNotEmpty;

  /// The next version for `patch`, `minor` or `major`.
  Semver bump(String part) => switch (part) {
        'major' => Semver(major + 1, 0, 0),
        'minor' => Semver(major, minor + 1, 0),
        _ => isPrerelease ? Semver(major, minor, patch) : Semver(major, minor, patch + 1),
      };

  @override
  int compareTo(Semver other) {
    for (final (a, b) in [(major, other.major), (minor, other.minor), (patch, other.patch)]) {
      if (a != b) return a.compareTo(b);
    }
    if (pre == other.pre) return 0;
    if (pre.isEmpty) return 1;
    if (other.pre.isEmpty) return -1;
    return _comparePre(pre, other.pre);
  }

  static int _comparePre(String a, String b) {
    final left = a.split('.');
    final right = b.split('.');
    for (var i = 0; i < left.length && i < right.length; i++) {
      final l = int.tryParse(left[i]);
      final r = int.tryParse(right[i]);
      final order = l != null && r != null ? l.compareTo(r) : left[i].compareTo(right[i]);
      if (order != 0) return order;
    }
    return left.length.compareTo(right.length);
  }

  bool operator <(Semver other) => compareTo(other) < 0;
  bool operator >(Semver other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) => other is Semver && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre);

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-$pre'}';
}

/// The version of this fixkit.
final Semver currentVersion = Semver.tryParse(fixkitVersion)!;

enum FixkitSource { hosted, git, path, unknown }

/// How a project depends on fixkit.
class InstalledFixkit {
  const InstalledFixkit({
    required this.source,
    this.constraint,
    this.gitUrl,
    this.gitRef,
    this.path,
    this.lockedVersion,
    this.resolvedRef,
  });

  final FixkitSource source;

  /// `^0.1.4` for a pub.dev dependency.
  final String? constraint;
  final String? gitUrl;

  /// The tag or branch in pubspec.yaml, like `v0.1.4`.
  final String? gitRef;
  final String? path;

  /// The version pubspec.lock resolved to.
  final Semver? lockedVersion;

  /// The commit pubspec.lock resolved a git dependency to.
  final String? resolvedRef;

  String describe() {
    final locked = lockedVersion == null ? '' : ' → $lockedVersion';
    return switch (source) {
      FixkitSource.hosted => 'pub.dev ${constraint ?? 'any'}$locked',
      FixkitSource.git => 'git ${gitRef ?? 'default branch'}'
          '${resolvedRef == null ? '' : ' @ ${resolvedRef!.substring(0, resolvedRef!.length.clamp(0, 7))}'}$locked',
      FixkitSource.path => 'path ${path ?? '?'}$locked',
      FixkitSource.unknown => 'not in pubspec.yaml',
    };
  }
}

/// The lines of the `fixkit:` entry in pubspec.yaml: the key line and the
/// indented lines under it.
({int start, int end, String indent, String inline})? _fixkitBlock(List<String> lines) {
  ({int start, int end, String indent, String inline})? found;
  for (var i = 0; i < lines.length; i++) {
    final match = RegExp(r'^(\s+)fixkit\s*:(.*)$').firstMatch(lines[i]);
    if (match == null) continue;
    // Only inside dependencies, dev_dependencies or dependency_overrides.
    var section = '';
    for (var j = i - 1; j >= 0; j--) {
      final top = RegExp(r'^([A-Za-z_]+)\s*:').firstMatch(lines[j]);
      if (top != null) {
        section = top[1]!;
        break;
      }
    }
    if (!{'dependencies', 'dev_dependencies', 'dependency_overrides'}.contains(section)) continue;
    final indent = match[1]!;
    var end = i + 1;
    while (end < lines.length) {
      final line = lines[end];
      if (line.trim().isEmpty) {
        end++;
        continue;
      }
      final lead = line.length - line.trimLeft().length;
      if (lead <= indent.length) break;
      end++;
    }
    // Trailing blank lines are not part of the entry.
    while (end > i + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    final block = (start: i, end: end, indent: indent, inline: _stripComment(match[2]!));
    // An override is what pub uses, so it wins.
    if (section == 'dependency_overrides') return block;
    found ??= block;
  }
  return found;
}

String _stripComment(String text) {
  final hash = text.indexOf(' #');
  return (hash == -1 ? text : text.substring(0, hash)).trim();
}

String _unquote(String text) {
  final t = text.trim();
  if (t.length >= 2 && (t.startsWith('"') && t.endsWith('"') || t.startsWith("'") && t.endsWith("'"))) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

/// Reads how [pubspec] depends on fixkit, and what [lock] resolved.
InstalledFixkit parseInstalled(String pubspec, {String? lock}) {
  final lines = const LineSplitter().convert(pubspec);
  final block = _fixkitBlock(lines);
  final locked = lock == null ? null : parseLock(lock);
  if (block == null) return InstalledFixkit(source: FixkitSource.unknown, lockedVersion: locked?.version);

  if (block.inline.isNotEmpty) {
    return InstalledFixkit(
      source: FixkitSource.hosted,
      constraint: _unquote(block.inline),
      lockedVersion: locked?.version,
    );
  }

  final body = lines.sublist(block.start + 1, block.end).map((line) => _stripComment(line)).toList();
  String? value(String key) {
    for (final line in body) {
      final match = RegExp('^${RegExp.escape(key)}\\s*:(.*)\$').firstMatch(line);
      if (match != null) return _unquote(match[1]!);
    }
    return null;
  }

  final git = value('git');
  if (git != null) {
    return InstalledFixkit(
      source: FixkitSource.git,
      gitUrl: git.isNotEmpty ? git : value('url'),
      gitRef: value('ref'),
      lockedVersion: locked?.version,
      resolvedRef: locked?.resolvedRef,
    );
  }
  final path = value('path');
  if (path != null) return InstalledFixkit(source: FixkitSource.path, path: path, lockedVersion: locked?.version);
  final version = value('version');
  if (value('hosted') != null || version != null) {
    return InstalledFixkit(source: FixkitSource.hosted, constraint: version, lockedVersion: locked?.version);
  }
  return InstalledFixkit(source: FixkitSource.unknown, lockedVersion: locked?.version);
}

/// fixkit's entry in pubspec.lock.
({Semver? version, String? source, String? resolvedRef})? parseLock(String lock) {
  final lines = const LineSplitter().convert(lock);
  final start = lines.indexWhere((line) => RegExp(r'^  fixkit:\s*$').hasMatch(line));
  if (start == -1) return null;
  String? version;
  String? source;
  String? resolved;
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (RegExp(r'^  \S').hasMatch(line) || RegExp(r'^\S').hasMatch(line)) break;
    final match = RegExp(r'^\s+([\w-]+):\s*(.*)$').firstMatch(line);
    if (match == null) continue;
    final key = match[1]!;
    final value = _unquote(match[2]!);
    if (key == 'version') version = value;
    if (key == 'source') source = value;
    if (key == 'resolved-ref') resolved = value;
  }
  return (version: Semver.tryParse(version), source: source, resolvedRef: resolved);
}

InstalledFixkit readInstalled(Project project) {
  final lock = project.file('pubspec.lock');
  return parseInstalled(project.pubspec, lock: lock.existsSync() ? lock.readAsStringSync() : null);
}

/// [pubspec] with fixkit's pub.dev constraint set to `^version`.
String setHostedConstraint(String pubspec, Semver version) {
  final lines = const LineSplitter().convert(pubspec);
  final block = _fixkitBlock(lines);
  if (block == null) throw const FormatException('pubspec.yaml has no fixkit dependency');
  if (block.inline.isNotEmpty) {
    lines[block.start] = '${block.indent}fixkit: ^$version';
  } else {
    var replaced = false;
    for (var i = block.start + 1; i < block.end; i++) {
      final match = RegExp(r'^(\s+)version\s*:').firstMatch(lines[i]);
      if (match != null) {
        lines[i] = '${match[1]}version: ^$version';
        replaced = true;
      }
    }
    if (!replaced) {
      lines.replaceRange(block.start, block.end, ['${block.indent}fixkit: ^$version']);
    }
  }
  return _join(lines, pubspec);
}

/// [pubspec] with fixkit's git dependency pinned to the tag `v<version>`.
String setGitRef(String pubspec, Semver version) {
  final lines = const LineSplitter().convert(pubspec);
  final block = _fixkitBlock(lines);
  if (block == null) throw const FormatException('pubspec.yaml has no fixkit dependency');
  final tag = 'v$version';

  for (var i = block.start + 1; i < block.end; i++) {
    final ref = RegExp(r'^(\s+)ref\s*:').firstMatch(lines[i]);
    if (ref != null) {
      lines[i] = '${ref[1]}ref: $tag';
      return _join(lines, pubspec);
    }
  }
  for (var i = block.start + 1; i < block.end; i++) {
    // `git: <url>` on one line becomes a block with the ref.
    final inline = RegExp(r'^(\s+)git\s*:\s*(\S.*)$').firstMatch(lines[i]);
    if (inline != null && !_stripComment(inline[2]!).startsWith('#')) {
      final indent = inline[1]!;
      final unit = indent.length > block.indent.length ? indent.substring(block.indent.length) : '  ';
      lines.replaceRange(i, i + 1, [
        '${indent}git:',
        '$indent${unit}url: ${_stripComment(inline[2]!)}',
        '$indent${unit}ref: $tag',
      ]);
      return _join(lines, pubspec);
    }
    final url = RegExp(r'^(\s+)url\s*:').firstMatch(lines[i]);
    if (url != null) {
      lines.insert(i + 1, '${url[1]}ref: $tag');
      return _join(lines, pubspec);
    }
  }
  throw const FormatException('fixkit is not a git dependency');
}

String _join(List<String> lines, String original) {
  final newline = original.contains('\r\n') ? '\r\n' : '\n';
  return '${lines.join(newline)}${original.endsWith('\n') ? newline : ''}';
}

/// The newest release: pub.dev's latest for a pub.dev dependency, the highest
/// `vX.Y.Z` tag for a git one. Null when it cannot be reached.
Future<Semver?> latestRelease(InstalledFixkit installed, {Duration timeout = const Duration(seconds: 5)}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    if (installed.source == FixkitSource.git) {
      final repo = githubRepo(installed.gitUrl ?? fixkitRepository);
      if (repo == null) return null;
      final tags = await _getJson(client, Uri.parse('https://api.github.com/repos/$repo/tags?per_page=100'), timeout);
      if (tags is! List) return null;
      final versions = [
        for (final tag in tags)
          if (Semver.tryParse(tag is Map ? '${tag['name']}' : null) case final Semver version)
            if (!version.isPrerelease) version,
      ]..sort();
      return versions.isEmpty ? null : versions.last;
    }
    final package = await _getJson(client, Uri.parse('https://pub.dev/api/packages/fixkit'), timeout);
    if (package is! Map) return null;
    final latest = package['latest'];
    return latest is Map ? Semver.tryParse('${latest['version']}') : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<Object?> _getJson(HttpClient client, Uri uri, Duration timeout) async {
  final request = await client.getUrl(uri).timeout(timeout);
  request.headers.set(HttpHeaders.userAgentHeader, 'fixkit/$fixkitVersion');
  request.headers.set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close().timeout(timeout);
  final text = await response.transform(utf8.decoder).join().timeout(timeout);
  if (response.statusCode != HttpStatus.ok) return null;
  return jsonDecode(text);
}

/// `owner/repo` from a GitHub URL (https, ssh or `git@github.com:`).
String? githubRepo(String url) {
  final match = RegExp(r'github\.com[/:]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$').firstMatch(url.trim());
  return match == null ? null : '${match[1]}/${match[2]}';
}

// ---------------------------------------------------------------------------
// The project's setup, stamped with the version that made it
// ---------------------------------------------------------------------------

File stampFile(Project project) => project.file(joinPath('.fixkit', 'state.json'));

/// The fixkit version the project's setup was last written by.
Semver? readStamp(Project project) {
  try {
    final json = jsonDecode(stampFile(project).readAsStringSync());
    return json is Map ? Semver.tryParse('${json['version']}') : null;
  } catch (_) {
    return null;
  }
}

void writeStamp(Project project) {
  final file = stampFile(project);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
        'version': fixkitVersion,
        'protocol': fixkitProtocol,
      })}\n');
}

/// Brings the files fixkit wrote into line with this version: the launcher,
/// fixkit's entries in the editor configs that already have one, and the
/// agent rules sections. Never touches the app's code. Returns what changed.
List<String> refreshProject(Project project) {
  final changed = <String>[];

  final launcher = project.launcher;
  if (!launcher.existsSync() || launcher.readAsStringSync() != launcherSource) {
    launcher.parent.createSync(recursive: true);
    launcher.writeAsStringSync(launcherSource);
    changed.add('.fixkit/mcp.dart');
  }
  final ignore = project.file(joinPath('.fixkit', '.gitignore'));
  if (!ignore.existsSync()) {
    ignore.writeAsStringSync(fixkitGitignore);
    changed.add('.fixkit/.gitignore');
  }

  for (final editor in detectEditors(project, only: allEditorIds.toSet())) {
    if (!editor.file.existsSync()) continue;
    final entry = _fixkitEntry(editor);
    if (entry == null) continue;
    // A computer-wide config follows the project that last set it up.
    if (editor.global && !_pointsAt(entry, project)) continue;
    final change = writeEditorConfig(editor, project, addDart: false);
    if (change.wrote) changed.add(editor.global ? editor.configPath : project.relative(editor.configPath));
  }

  for (final name in ['AGENTS.md', 'CLAUDE.md', 'GEMINI.md', '.github/copilot-instructions.md']) {
    final file = project.file(name);
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync();
    if (!text.contains(agentsStart)) continue;
    final updated = withAgentsSection(text);
    if (updated != text) {
      file.writeAsStringSync(updated);
      changed.add(name);
    }
  }

  final stamp = readStamp(project);
  if (stamp == null || stamp < currentVersion) {
    writeStamp(project);
    changed.add('.fixkit/state.json');
  }
  return changed;
}

Map<Object?, Object?>? _fixkitEntry(EditorTarget editor) {
  try {
    final decoded = decodeJsonc(editor.file.readAsStringSync());
    final servers = decoded is Map ? decoded[editor.serversKey] : null;
    final entry = servers is Map ? servers['fixkit'] : null;
    return entry is Map ? entry : null;
  } catch (_) {
    return null;
  }
}

bool _pointsAt(Map<Object?, Object?> entry, Project project) {
  final args = entry['args'];
  if (args is! List || args.isEmpty) return false;
  return normalizePath('${args.first}') == normalizePath(project.launcher.path);
}

/// Run by the MCP server when an editor starts it: refreshes the project's
/// setup once after fixkit was upgraded. Quiet and never fatal.
List<String> refreshIfUpgraded(String projectRoot) {
  try {
    final project = Project(projectRoot);
    if (!project.launcher.existsSync()) return const [];
    // Only an upgrade refreshes: a teammate's newer stamp is left alone.
    final stamp = readStamp(project);
    if (stamp != null && !(stamp < currentVersion)) return const [];
    return refreshProject(project);
  } catch (_) {
    return const [];
  }
}
