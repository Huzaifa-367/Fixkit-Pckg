import 'dart:io';

import '../../mcp.dart' as entry;
import '../protocol.dart';
import 'console.dart';
import 'doctor.dart';
import 'init.dart';
import 'run.dart';
import 'upgrade.dart';

const String _usage = '''
fixkit $fixkitVersion: long press a widget in your running Flutter app, say what
is wrong, and the agent in your editor fixes it.

Usage: dart run fixkit <command> [options]

Commands:
  init        Set up this project and your editors (run once).
                --lan            also reach phones on Wi-Fi (iPhones need it; on by
                                 itself on a Mac with Xcode)
                --no-lan         keep Wi-Fi devices off
                --editors=a,b    only these: cursor, vscode, antigravity,
                                 windsurf, claude, gemini
                --no-main        leave lib/main.dart alone
                --no-dart-mcp    do not add the Dart SDK's MCP server
                --dry-run        show what would change, write nothing
                --refresh        rerun after an upgrade (shorter output)
  doctor      Check every piece and say how to fix what is missing.
                --start          start the hub if it is not running
                --offline        skip the check for a newer release
  run         `flutter run` that your agent can hot reload from any editor.
                --lan            pass the Wi-Fi host and token to the app
                Other options go to `flutter run`.
  status      Show connected agents and recent reports.  (--json)
  reload      Hot reload the running app the way the agent does, and say
              what happened (to check agent hot reload).
  restart     Replace the running hub with this project's fixkit (after an
              upgrade, or when the app says the hub is outdated).
  upgrade     Move to the newest release (or the one given, like 0.1.5),
              from pub.dev or git, and refresh the setup.  (--force)
  version     Installed, running and latest versions.  (--offline)
  uninstall   Undo init.
  mcp         The MCP server editors start (they run .fixkit/mcp.dart).
  hub         Run the hub in the foreground (it normally starts by itself).
  help        Show this.
''';

/// Runs a CLI command; returns the exit code.
Future<int> runCli(List<String> arguments) async {
  final console = Console();
  final command = arguments.isEmpty ? 'help' : arguments.first;
  final rest = arguments.skip(1).toList();

  switch (command) {
    case 'init':
      return runInit(rest, console);
    case 'doctor':
      return runDoctor(rest, console);
    case 'run':
      return runFlutter(rest, console);
    case 'status':
      return runStatus(rest, console);
    case 'reload':
      return runReload(rest, console);
    case 'uninstall':
      return runUninstall(rest, console);
    case 'mcp':
      await entry.main(['mcp', ...rest]);
      return exitCode;
    case 'hub':
      await entry.main(['hub', '--foreground', ...rest]);
      return exitCode;
    case 'upgrade':
      return runUpgrade(rest, console);
    case 'restart':
      return runRestart(rest, console);
    case 'version':
      return runVersion(rest, console);
    case '--version':
      console.line(fixkitVersion);
      return 0;
    case 'help':
    case '--help':
    case '-h':
      console.line(_usage);
      return 0;
  }
  stderr.writeln('Unknown command "$command".\n');
  stderr.writeln(_usage);
  return 64;
}
