# Changelog

All notable changes to fixkit. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and fixkit uses [semantic versioning](https://semver.org). Write new changes under **Unreleased**; `dart run tool/release.dart` turns that section into the next version.

## Unreleased

## 0.1.0

First public release.

### In the app
- `FixKit`: long press any widget in a debug build, describe what is wrong, and send it to your editor's agent. Reports carry the comment, the widget's construction file and line, the widget chain around it, nearby text, the screen and a screenshot. Compiled out of release builds.
- The agent UI:
  - an edge glow while the agent has your attention;
  - a composer that names the watching agent and offers suggestions that fit the pressed widget;
  - a live agent card with an animated orb that shows each step (sent, reading, edited, hot reloaded, fix on screen) and types out the agent's summary.
- Long press works on every widget, including text fields, buttons and widgets with their own long press. fixkit watches the pointer outside the gesture arena and cancels the press for the widget underneath. A scroll or a pinch cancels it.
- A selection bar in the composer widens the selection from the pressed widget to the Row, Column, card or screen around it (−, +, or tap a widget). The spotlight glides to the selection, the screenshot outlines it, and the report names both the selected widget and the one under the finger.
- Composer presence tells watching, busy, idle, offline and outdated-hub states apart, names the project's agent, and re-checks while the composer is open.
- `FixName` and `FixScreen` for optional names.
- The app tells you when it runs a newer fixkit than the hub, instead of failing silently.

### On the computer
- The hub is one background process per computer. It:
  - routes reports to the agent with the right project open;
  - keeps each report's activity, noticing the agent's edits by watching the widget's files;
  - runs `adb reverse` for Android devices (including the SDK from `flutter config --android-sdk`);
  - falls back to the clipboard and a notification when no agent is watching.
- The MCP server works with Cursor, VS Code, Antigravity, Windsurf, Claude Code and Gemini CLI. It offers the tools `wait_for_fix_report`, `complete_fix`, `fix_progress`, `hot_reload`, `get_fix_report` and `list_fix_reports`, and the `fixkit` prompt.
- CLI commands:
  - `dart run fixkit init`
  - `dart run fixkit doctor`
  - `dart run fixkit run`
  - `dart run fixkit restart`
  - `dart run fixkit status`
  - `dart run fixkit upgrade`
  - `dart run fixkit version`
  - `dart run fixkit uninstall`
- Version handling:
  - the project setup is stamped with its fixkit version and refreshes itself after an upgrade;
  - older hubs give way to newer ones;
  - `upgrade` works for pub.dev and git dependencies.
- Wi-Fi devices (iPhone) are supported with `--lan` and a per-computer token.
