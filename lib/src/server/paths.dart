import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Small path helpers, so the package needs no `path` dependency.
String joinPath(String first, [String? a, String? b, String? c, String? d]) {
  final parts = [first, a, b, c, d].whereType<String>().where((part) => part.isNotEmpty);
  final separator = Platform.pathSeparator;
  final buffer = StringBuffer();
  for (final part in parts) {
    if (buffer.isEmpty) {
      buffer.write(part);
      continue;
    }
    final current = buffer.toString();
    final endsWithSeparator = current.endsWith('/') || current.endsWith(separator);
    final trimmed = part.startsWith('/') || part.startsWith(separator) ? part.substring(1) : part;
    buffer.write(endsWithSeparator ? trimmed : '$separator$trimmed');
  }
  return buffer.toString();
}

/// Forward slashes, no trailing slash: the form paths are compared in.
String normalizePath(String path) {
  var normal = path.replaceAll('\\', '/');
  while (normal.length > 1 && normal.endsWith('/')) {
    normal = normal.substring(0, normal.length - 1);
  }
  // Windows drive letters compare case-insensitively.
  if (RegExp(r'^[A-Za-z]:/').hasMatch(normal)) normal = normal[0].toLowerCase() + normal.substring(1);
  return normal;
}

/// Whether [path] is [root] or inside it.
bool isWithin(String root, String path) {
  final r = normalizePath(root);
  final p = normalizePath(path);
  return p == r || p.startsWith('$r/');
}

/// [path] relative to [root], with forward slashes; [path] itself when it is
/// outside.
String relativeTo(String root, String path) {
  final r = normalizePath(root);
  final p = normalizePath(path);
  if (p == r) return '.';
  if (p.startsWith('$r/')) return p.substring(r.length + 1);
  return p;
}

/// The local path of a creation location (`file:///...`), or null.
String? pathFromLocation(String location) {
  try {
    final uri = Uri.parse(location);
    if (uri.scheme == 'file') return uri.toFilePath();
    if (uri.scheme.isEmpty && location.startsWith('/')) return location;
    return null;
  } catch (_) {
    return null;
  }
}

String homeDirectory() =>
    Platform.environment['HOME'] ??
    Platform.environment['USERPROFILE'] ??
    Directory.systemTemp.path;

/// `~/.fixkit`: the hub's state, log, token and settings.
Directory fixkitHome() {
  final dir = Directory(joinPath(homeDirectory(), '.fixkit'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

File hubLogFile() => File(joinPath(fixkitHome().path, 'hub.log'));

/// The token phones on Wi-Fi send. Created once per computer.
String lanToken() {
  final file = File(joinPath(fixkitHome().path, 'token'));
  if (file.existsSync()) {
    final token = file.readAsStringSync().trim();
    if (token.length >= 16) return token;
  }
  final random = Random.secure();
  final token = List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();
  file.writeAsStringSync(token);
  return token;
}

/// Computer-wide settings in `~/.fixkit/config.json`.
class FixkitSettings {
  const FixkitSettings({this.lan = false, this.clipboard = true, this.notifications = true, this.autoReload = true});

  /// Listen on the network for phones on Wi-Fi (they need the token).
  final bool lan;

  /// Copy a report's prompt to the clipboard when no agent picks it up.
  final bool clipboard;

  /// Show a desktop notification when no agent picks a report up.
  final bool notifications;

  /// Hot reload the app whenever the agent's edits pause, so changes show as
  /// they are made. complete_fix reloads regardless.
  final bool autoReload;

  static File get file => File(joinPath(fixkitHome().path, 'config.json'));

  static FixkitSettings load() {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return const FixkitSettings();
      return FixkitSettings(
        lan: json['lan'] == true,
        clipboard: json['clipboard'] != false,
        notifications: json['notifications'] != false,
        autoReload: json['autoReload'] != false,
      );
    } catch (_) {
      return const FixkitSettings();
    }
  }

  void save() {
    file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'lan': lan,
      'clipboard': clipboard,
      'notifications': notifications,
      'autoReload': autoReload,
    }));
  }

  FixkitSettings copyWith({bool? lan, bool? clipboard, bool? notifications, bool? autoReload}) => FixkitSettings(
        lan: lan ?? this.lan,
        clipboard: clipboard ?? this.clipboard,
        notifications: notifications ?? this.notifications,
        autoReload: autoReload ?? this.autoReload,
      );
}

/// Finds the Flutter or Dart project a file belongs to: the nearest folder
/// above it with a `pubspec.yaml`. Cached, since every report asks.
class ProjectFinder {
  final Map<String, String?> _cache = {};

  String? rootOf(String filePath) {
    var dir = File(filePath).parent;
    final visited = <String>[];
    for (var i = 0; i < 40; i++) {
      final key = normalizePath(dir.path);
      if (_cache.containsKey(key)) {
        final found = _cache[key];
        for (final path in visited) {
          _cache[path] = found;
        }
        return found;
      }
      visited.add(key);
      if (File(joinPath(dir.path, 'pubspec.yaml')).existsSync()) {
        for (final path in visited) {
          _cache[path] = key;
        }
        return key;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    for (final path in visited) {
      _cache[path] = null;
    }
    return null;
  }
}

/// Code that is not the app's own: the Flutter SDK, pub packages, generated
/// and build output, fixkit itself.
bool isOutsideAppCode(String path) {
  final p = normalizePath(path);
  const markers = [
    '/packages/flutter/',
    '/flutter/packages/',
    '/flutter/bin/cache/',
    '/sky_engine/',
    '/.pub-cache/',
    '/Pub/Cache/',
    '/.dart_tool/',
    '/build/',
    '/fixkit/lib/src/',
  ];
  return markers.any(p.contains);
}
