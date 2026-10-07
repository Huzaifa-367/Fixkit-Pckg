import 'dart:io';

import 'package:fixkit/src/cli/cli.dart';

Future<void> main(List<String> arguments) async {
  final code = await runCli(arguments);
  // The hub and the MCP server end on their own; other commands exit now, so
  // an open HTTP client never keeps the process alive.
  final command = arguments.isEmpty ? '' : arguments.first;
  if (command != 'hub' && command != 'mcp') exit(code);
  exitCode = code;
}
