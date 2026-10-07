// Releases fixkit: one version, kept equal in pubspec.yaml,
// lib/src/protocol.dart, the README's install snippets and the changelog.
//
//   dart run tool/release.dart patch|minor|major|<x.y.z> [--commit] [--dry-run]
//       Bumps the version everywhere and turns `## Unreleased` in
//       CHANGELOG.md into the new version's section. With --commit, commits
//       and tags vX.Y.Z (push them yourself: git push && git push --tags).
//
//   dart run tool/release.dart --check [--tag vX.Y.Z]
//       Fails unless every place holds the same version (and the tag
//       matches it). The Release workflow runs this on every tag.
//
//   dart run tool/release.dart --notes [x.y.z]
//       Prints a version's changelog section, for the GitHub release.
//
// No dependencies: it runs with plain `dart`.
import 'dart:io';

const _pubspec = 'pubspec.yaml';
const _protocol = 'lib/src/protocol.dart';
const _readme = 'README.md';
const _changelog = 'CHANGELOG.md';

final _semver = RegExp(r'^(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$');

void main(List<String> arguments) {
  try {
    if (!File(_pubspec).existsSync()) _fail('Run this from the fixkit package root.');
    if (arguments.contains('--check')) return _check(arguments);
    if (arguments.contains('--notes')) return _notes(arguments);
    _release(arguments);
  } on _Exit catch (exit) {
    exitCode = exit.code;
  }
}

class _Exit implements Exception {
  const _Exit(this.code);
  final int code;
}

Never _fail(String message, [int code = 1]) {
  stderr.writeln('release: $message');
  throw _Exit(code);
}

String _read(String path) => File(path).readAsStringSync();

String pubspecVersion() {
  final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(_read(_pubspec));
  if (match == null) _fail('no version in $_pubspec');
  return match[1]!;
}

String? protocolVersion() =>
    RegExp(r"const String fixkitVersion = '([^']+)';").firstMatch(_read(_protocol))?[1];

List<String> readmeVersions() {
  final text = _read(_readme);
  return [
    for (final match in RegExp(r'fixkit: \^(\d+\.\d+\.\d+[0-9A-Za-z.-]*)').allMatches(text)) match[1]!,
    for (final match in RegExp(r'ref: v(\d+\.\d+\.\d+[0-9A-Za-z.-]*)').allMatches(text)) match[1]!,
  ];
}

bool changelogHas(String version) => RegExp('^## ${RegExp.escape(version)}\\s*\$', multiLine: true).hasMatch(_read(_changelog));

String _next(String current, String how) {
  final match = _semver.firstMatch(current);
  if (match == null) _fail('pubspec version "$current" is not x.y.z');
  final major = int.parse(match[1]!);
  final minor = int.parse(match[2]!);
  final patch = int.parse(match[3]!);
  final pre = match[4] != null;
  switch (how) {
    case 'major':
      return '${major + 1}.0.0';
    case 'minor':
      return '$major.${minor + 1}.0';
    case 'patch':
      return pre ? '$major.$minor.$patch' : '$major.$minor.${patch + 1}';
  }
  if (_semver.hasMatch(how)) return how;
  _fail('expected patch, minor, major or a version like 1.2.3, not "$how"', 64);
}

int _compare(String a, String b) {
  List<int> parts(String v) => _semver.firstMatch(v)!.groups([1, 2, 3]).map((p) => int.parse(p!)).toList();
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i].compareTo(right[i]);
  }
  final leftPre = a.contains('-');
  final rightPre = b.contains('-');
  if (leftPre == rightPre) return a.compareTo(b);
  return leftPre ? -1 : 1;
}

void _release(List<String> arguments) {
  final how = arguments.where((argument) => !argument.startsWith('-')).firstOrNull;
  if (how == null) _fail('say how to bump: patch, minor, major or a version like 1.2.3', 64);
  final dryRun = arguments.contains('--dry-run');
  final current = pubspecVersion();
  final next = _next(current, how);
  if (_compare(next, current) <= 0) _fail('$next is not newer than $current');

  // The changes for this release are what is under ## Unreleased.
  final changelog = _read(_changelog);
  final unreleased = RegExp(r'^## Unreleased[ \t]*\r?\n', multiLine: true).firstMatch(changelog);
  if (unreleased == null) _fail('CHANGELOG.md has no "## Unreleased" section');
  final rest = changelog.substring(unreleased.end);
  final nextHeading = RegExp(r'^## ', multiLine: true).firstMatch(rest);
  final notes = (nextHeading == null ? rest : rest.substring(0, nextHeading.start)).trim();
  if (notes.isEmpty && !arguments.contains('--allow-empty')) {
    _fail('write the changes under "## Unreleased" in CHANGELOG.md first (or pass --allow-empty)');
  }

  final edits = <String, String>{
    _pubspec: _read(_pubspec).replaceFirst(RegExp(r'^version:\s*\S+', multiLine: true), 'version: $next'),
    _protocol: _read(_protocol).replaceFirst(
      RegExp(r"const String fixkitVersion = '[^']+';"),
      "const String fixkitVersion = '$next';",
    ),
    _readme: _read(_readme)
        .replaceAll(RegExp(r'fixkit: \^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?'), 'fixkit: ^$next')
        .replaceAll(RegExp(r'ref: v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?'), 'ref: v$next'),
    _changelog: changelog.replaceRange(
      unreleased.start,
      unreleased.end + (nextHeading == null ? rest.length : nextHeading.start),
      '## Unreleased\n\n## $next\n\n${notes.isEmpty ? '- Maintenance release.' : notes}\n\n',
    ),
  };

  stdout.writeln('fixkit $current → $next${dryRun ? ' (dry run)' : ''}');
  for (final entry in edits.entries) {
    final changed = entry.value != _read(entry.key);
    stdout.writeln('  ${changed ? '✔' : '·'} ${entry.key}');
    if (changed && !dryRun) File(entry.key).writeAsStringSync(entry.value);
  }
  if (dryRun) return;

  if (arguments.contains('--commit')) {
    _git(['add', ...edits.keys]);
    _git(['commit', '-m', 'Release v$next']);
    _git(['tag', '-a', 'v$next', '-m', 'fixkit $next']);
    stdout.writeln('\nCommitted and tagged v$next. Publish it with:\n  git push && git push --tags');
  } else {
    stdout.writeln('\nNext:\n'
        '  git commit -am "Release v$next" && git tag -a v$next -m "fixkit $next"\n'
        '  git push && git push --tags');
  }
}

void _git(List<String> arguments) {
  final result = Process.runSync('git', arguments);
  if (result.exitCode != 0) _fail('git ${arguments.join(' ')} failed:\n${result.stderr}');
}

void _check(List<String> arguments) {
  final version = pubspecVersion();
  final problems = <String>[];
  if (!_semver.hasMatch(version)) problems.add('pubspec version "$version" is not x.y.z');
  final code = protocolVersion();
  if (code != version) problems.add('$_protocol says $code, pubspec.yaml says $version');
  final snippets = readmeVersions();
  if (snippets.isEmpty) problems.add('$_readme has no install snippet with the version');
  for (final snippet in snippets.toSet()) {
    if (snippet != version) problems.add('$_readme shows $snippet, pubspec.yaml says $version');
  }
  if (!changelogHas(version)) problems.add('$_changelog has no "## $version" section');

  final tagIndex = arguments.indexOf('--tag');
  if (tagIndex != -1) {
    final tag = tagIndex + 1 < arguments.length ? arguments[tagIndex + 1] : '';
    if (tag != 'v$version') problems.add('tag "$tag" does not match the package version v$version');
  }

  if (problems.isEmpty) {
    stdout.writeln('fixkit $version: every place agrees.');
    return;
  }
  for (final problem in problems) {
    stderr.writeln('✖ $problem');
  }
  _fail('versions disagree; run `dart run tool/release.dart <version>` to set them all');
}

void _notes(List<String> arguments) {
  final asked = arguments.where((argument) => !argument.startsWith('-')).firstOrNull;
  final version = (asked ?? pubspecVersion()).replaceFirst(RegExp('^v'), '');
  final changelog = _read(_changelog);
  final heading = RegExp('^## ${RegExp.escape(version)}\\s*\$', multiLine: true).firstMatch(changelog);
  if (heading == null) _fail('CHANGELOG.md has no "## $version" section');
  final rest = changelog.substring(heading.end);
  final next = RegExp(r'^## ', multiLine: true).firstMatch(rest);
  stdout.writeln((next == null ? rest : rest.substring(0, next.start)).trim());
}
