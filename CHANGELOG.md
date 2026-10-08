# Changelog

All notable changes to fixkit. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and fixkit uses [semantic versioning](https://semver.org). Write new changes under **Unreleased**; `dart run tool/release.dart` turns that section into the next version.

## Unreleased

## 0.1.3

### Fixed
- **Presses that missed.** A press on a gap (between an avatar and a name, beside a heading, the empty part of a header row) or on a widget that takes no touches fell through to whatever was behind it. Often that was the whole app, so the composer opened with nothing selected. fixkit now looks for the app's own widget drawn under the finger: the Row, the header or the Text. Empty spacers (`SizedBox`, `Spacer`) count as the widget around them. Widgets that stick out of a `Stack` (an avatar over a banner) and pinned headers in scroll views are found too.
- **fixkit's own widgets never count as the app's,** even when fixkit is a path dependency to a clone.
- **Agent hot reload without DDS.** A run with `--no-dds` is reloaded through the app's VM service: on this computer for simulators and desktop, and through flutter's `adb forward` for Android.
- **Hot reload after any agent edit, not only during a fix.** The hub now watches the `lib` folder of every app it can reload. When an agent (or any tool) writes Dart files and stops for a moment, the app hot reloads, whether or not there is a fix report. If the editor's reload on save already caught the edit, nothing happens twice.
- **The app tells the hub which project it is.** It sends where its `FixKit` is constructed, so the hub knows the project from the first launch, before any report.
- **Terminal `flutter run` and runs without debugging work too.** There the app can start before the Flutter session is ready, so it looks again a few seconds after launch and tells the hub once it finds it.
- **Edits made during a reload are not lost.** A reload only counts for the edits made before it began, so a later edit gets its own reload. Automatic reloads wait 2.5 s after the last change.

### Added
- `dart run fixkit reload` hot reloads the app the way the agent does and says what happened. Use it to check agent hot reload.
- `doctor` checks agent hot reload.
- At launch, the debug console says whether agent hot reload is on.

## 0.1.2

### Fixed
- **The agent's changes now hot reload by themselves.** Before, the app only reloaded when the editor saw a save, so when an agent wrote the files itself you had to press hot reload. Now the app finds its Flutter session at launch and tells the hub, and the hub asks the Flutter tool to hot reload, as the editor's reload button does. This works whether the app was started from VS Code, Cursor, Antigravity, Windsurf, Android Studio or `flutter run`, on any device.
  - fixkit's `hot_reload` tool reloads through it.
  - The hub also reloads when the agent's edits pause (`autoReload` in `~/.fixkit/config.json`, on by default).
  - `complete_fix` reloads if nothing has since the last edit.
  - A compile error goes back to the agent and shows on the card.
- **A reload during a fix no longer ends it.** A reload in the middle of a fix used to mark it as done before the agent had finished, and the card stopped following. Only `complete_fix` finishes it now.

## 0.1.1

### Added
- **Hold ring.** A ring under the finger fills while a press is held and bursts when the composer opens. It stays hidden for the first moment, so taps never flash it, and the burst is skipped when the system asks for reduced motion.
- **Live agent card.** The app keeps one status request open, and the hub answers it the moment the report changes (a step, a note, an edit, a new status). Steps show as they happen instead of up to a second late. Hubs from 0.1.5 and earlier are still polled.
- **Edits anywhere in `lib`.** The hub watches the project's `lib` folder (and new folders in it) while an agent works, so *Edited theme.dart* shows for any file, not just the pressed widget's own. Atomic saves are seen too.
- **Elapsed time.** The card shows how long the agent has been working.

### Changed
- **Performance.**
  - The controller is a set of `ValueNotifier`s, so each change rebuilds only the widget that shows it. The app under fixkit never rebuilds.
  - The glass has no backdrop blur and the spotlight has no blur mask. Painters repaint from their animations, in their own layers.
  - The lift follows the keyboard frame by frame instead of restarting a tween each frame.
  - The ring's pulse stops when the system asks for reduced motion.
- **No edge glow.** The glow around the screen while the agent works is gone. The orb and the card show the same state.
- **`FixConnection.status`** takes an optional `since` revision. Only a custom `FixConnection` (a test fake, say) needs the new parameter.

### Fixed
- The screenshot outline was offset when the app had slid up for the keyboard before the capture.
- The app stayed slid up when the keyboard closed while the composer was open.

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
