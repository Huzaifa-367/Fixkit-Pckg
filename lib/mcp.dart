/// Entry point for the editor-facing side of fixkit: the MCP server, and the
/// hub it starts in the background.
///
/// Editors start it through the launcher `dart run fixkit init` writes to
/// `.fixkit/mcp.dart`, which calls [main]. It never imports Flutter, so plain
/// `dart` runs it.
library;

import 'dart:io';

import 'src/cli/versions.dart' show refreshIfUpgraded;
import 'src/protocol.dart';
import 'src/server/hub.dart';
import 'src/server/mcp.dart';
import 'src/server/paths.dart';

export 'src/server/mcp.dart' show FixkitMcpServer, mcpInstructions;

/// `mcp [--project=<root>] [--global]` (the default) or `hub [--port=<n>]`.
Future<void> main(List<String> arguments) async {
  final command = arguments.isNotEmpty && !arguments.first.startsWith('-') ? arguments.first : 'mcp';
  final options = arguments.where((argument) => argument.startsWith('--')).toList();

  String? option(String name) {
    for (final option in options) {
      if (option.startsWith('--$name=')) return option.substring(name.length + 3);
    }
    return null;
  }

  switch (command) {
    case 'hub':
      final port = int.tryParse(option('port') ?? '') ?? fixkitPort;
      await runHub(port: port, foreground: options.contains('--foreground'));
    case 'mcp':
      // A global config (Antigravity, Windsurf) serves whatever project the
      // editor has open, so it ignores the launcher's own project.
      final global = options.contains('--global');
      final home = option('project') ?? _launcherProject();
      final project = global ? option('project') : home;
      // After an upgrade, the first start brings the project's setup up to date.
      if (home != null) {
        final changed = refreshIfUpgraded(home);
        if (changed.isNotEmpty) stderr.writeln('fixkit: refreshed ${changed.join(', ')} for $fixkitVersion');
      }
      await runMcpServer(project: project, wildcard: global);
    default:
      stderr.writeln('fixkit: unknown command "$command". Expected "mcp" or "hub".');
      exitCode = 64;
  }
}

/// The project a launcher in `<project>/.fixkit/mcp.dart` belongs to.
String? _launcherProject() {
  final script = Platform.script;
  if (script.scheme != 'file') return null;
  final dir = File(script.toFilePath()).parent;
  if (dir.uri.pathSegments.where((segment) => segment.isNotEmpty).lastOrNull != '.fixkit') return null;
  final root = dir.parent.path;
  return File(joinPath(root, 'pubspec.yaml')).existsSync() ? normalizePath(root) : null;
}
