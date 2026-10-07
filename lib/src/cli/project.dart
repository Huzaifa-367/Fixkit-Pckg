import 'dart:io';

import '../server/paths.dart';

/// The Flutter project the CLI runs in.
class Project {
  Project(this.root);

  /// The nearest folder at or above [start] with a pubspec.yaml.
  static Project? find([String? start]) {
    var dir = Directory(start ?? Directory.current.path).absolute;
    for (var i = 0; i < 40; i++) {
      if (File(joinPath(dir.path, 'pubspec.yaml')).existsSync()) return Project(normalizeNative(dir.path));
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  /// The project's absolute path, in the platform's own form.
  final String root;

  String path(String relative) => joinPath(root, relative);

  File file(String relative) => File(path(relative));

  String get pubspec => file('pubspec.yaml').readAsStringSync();

  /// The `name:` in pubspec.yaml.
  String get name => RegExp(r'^name:\s*([\w]+)', multiLine: true).firstMatch(pubspec)?.group(1) ?? 'app';

  bool get isFlutter => RegExp(r'^\s+flutter:\s*\n\s+sdk:\s*flutter', multiLine: true).hasMatch(pubspec) ||
      pubspec.contains('sdk: flutter');

  /// Whether pubspec.yaml lists fixkit, and pub has resolved it.
  bool get dependsOnFixkit => RegExp(r'^\s+fixkit\s*:', multiLine: true).hasMatch(pubspec);

  bool get fixkitResolved {
    final config = file(joinPath('.dart_tool', 'package_config.json'));
    return config.existsSync() && config.readAsStringSync().contains('"name": "fixkit"');
  }

  /// `lib/main.dart` and the other `lib/main*.dart` entry points.
  List<File> get entryPoints {
    final lib = Directory(path('lib'));
    if (!lib.existsSync()) return const [];
    final files = lib
        .listSync()
        .whereType<File>()
        .where((file) {
          final name = file.uri.pathSegments.last;
          return name.startsWith('main') && name.endsWith('.dart');
        })
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// `.fixkit/mcp.dart`: what editors run to start fixkit's MCP server.
  File get launcher => file(joinPath('.fixkit', 'mcp.dart'));

  String relative(String absolute) => relativeTo(root, absolute);
}

/// An absolute path without a trailing separator, in the platform's form.
String normalizeNative(String path) {
  var result = path;
  while (result.length > 1 && (result.endsWith('/') || result.endsWith(r'\')) && !result.endsWith(':\\')) {
    result = result.substring(0, result.length - 1);
  }
  return result;
}

/// Finds [command] on PATH.
String? which(String command) {
  final env = Platform.environment;
  final separator = Platform.isWindows ? ';' : ':';
  final names = Platform.isWindows ? ['$command.exe', '$command.bat', '$command.cmd', command] : [command];
  for (final dir in (env['PATH'] ?? '').split(separator)) {
    if (dir.isEmpty) continue;
    for (final name in names) {
      final candidate = joinPath(dir, name);
      if (File(candidate).existsSync()) return candidate;
    }
  }
  return null;
}

/// The dart executable running this program: the one the project's Flutter
/// SDK ships, which editors can start without PATH.
String dartExecutable() => Platform.resolvedExecutable;

/// The flutter command of the same SDK, else the one on PATH.
String flutterExecutable() {
  // <flutter>/bin/cache/dart-sdk/bin/dart → <flutter>/bin/flutter
  final dart = File(Platform.resolvedExecutable);
  final binCache = dart.parent.parent.parent.parent; // <flutter>/bin
  final candidate = joinPath(binCache.path, Platform.isWindows ? 'flutter.bat' : 'flutter');
  if (File(candidate).existsSync()) return candidate;
  return which('flutter') ?? 'flutter';
}

/// The Dart SDK version, like 3.9.2.
String dartVersion() => Platform.version.split(' ').first;

bool dartAtLeast(int major, int minor) {
  final parts = dartVersion().split('.').map((part) => int.tryParse(part.split('-').first) ?? 0).toList();
  if (parts.length < 2) return false;
  return parts[0] > major || (parts[0] == major && parts[1] >= minor);
}
