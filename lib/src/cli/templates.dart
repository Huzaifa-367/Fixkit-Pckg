/// Files `fixkit init` writes into the project.
library;

const String launcherSource = '''
// Written by `dart run fixkit init`. Editors start fixkit's MCP server with
// `dart .fixkit/mcp.dart`; it starts the fixkit hub in the background.
// Safe to commit: it holds no paths or secrets.
import 'package:fixkit/mcp.dart' as fixkit;

Future<void> main(List<String> arguments) => fixkit.main(arguments);
''';

const String agentsStart = '<!-- fixkit:start -->';
const String agentsEnd = '<!-- fixkit:end -->';

const String agentsSection = '''
$agentsStart
## Fix requests from the running app (fixkit)

This app uses [fixkit](https://pub.dev/packages/fixkit): in a debug build,
someone long-presses a widget and types what is wrong, and it becomes a fix
report for you.

When asked to "watch for fixes" (or `/fixkit`), call the fixkit MCP tool
`wait_for_fix_report` in a loop, and for each report:

- Start at the first `file:line` of its widget path: the selected widget is
  constructed there; the lines after it are its parents. If the person
  widened the selection (to a Row, Column or card), change that widget.
- Make the smallest change that does what was asked. Do not refactor. The
  app shows your progress live; `fix_progress` adds a note for longer fixes.
- Hot reload with fixkit's `hot_reload` tool: it reloads the app through
  the Flutter session it runs in, from any editor. Then call `complete_fix`
  with a one-sentence summary (it reloads too if needed), then wait again.
$agentsEnd
''';

/// Puts the fixkit section in [existing] (replacing an older copy), or
/// returns it as the start of a new file.
String withAgentsSection(String? existing) {
  if (existing == null || existing.trim().isEmpty) return agentsSection;
  final start = existing.indexOf(agentsStart);
  final end = existing.indexOf(agentsEnd);
  if (start != -1 && end > start) {
    return existing.replaceRange(start, end + agentsEnd.length + (existing.length > end + agentsEnd.length && existing[end + agentsEnd.length] == '\n' ? 1 : 0), agentsSection);
  }
  final separator = existing.endsWith('\n\n') ? '' : (existing.endsWith('\n') ? '\n' : '\n\n');
  return '$existing$separator$agentsSection';
}

/// Removes the fixkit section, if present.
String withoutAgentsSection(String existing) {
  final start = existing.indexOf(agentsStart);
  final end = existing.indexOf(agentsEnd);
  if (start == -1 || end < start) return existing;
  var to = end + agentsEnd.length;
  if (to < existing.length && existing[to] == '\n') to++;
  var from = start;
  while (from > 0 && existing[from - 1] == '\n' && (from < 2 || existing[from - 2] == '\n')) {
    from--;
  }
  return existing.replaceRange(from, to, '');
}

/// `.fixkit/.gitignore`: screenshots and the LAN token stay local; the
/// launcher is committed.
const String fixkitGitignore = '''
# Written by fixkit: reports, screenshots and the Wi-Fi token stay local.
reports/
defines.json
''';
