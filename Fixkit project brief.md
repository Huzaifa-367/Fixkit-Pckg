# fixkit for Flutter: project brief

**Owner:** Muhammad Huzaifa · **Repository:** https://github.com/Huzaifa-367/Fixkit-Pckg · **Version:** 0.1.8 · **Updated:** 8 October 2026

**Status:** v0.1.8 is committed and tagged locally (`v0.1.4` to `v0.1.8`) and ready to push. It has not been compiled yet, because the build environment had no Flutter SDK. Independent code reviews traced the changes and tests against the code, and their findings are fixed. The first real run of `flutter analyze` and `flutter test` (CI does both on push) is the next step, followed by a real-device check of agent hot reload (`dart run fixkit reload`).

## What it is

fixkit is a Flutter take on [ostiums/fixkit](https://github.com/ostiums/fixkit), which only works for iOS apps in Claude Code. The flow:

1. In a debug build, long press any widget.
2. Ask the agent in your editor to change it.
3. The agent receives the widget's `file:line`, the widgets around it, nearby text and a screenshot.
4. It fixes the code, and fixkit hot reloads the app by itself.

It works in any MCP editor: Cursor, VS Code (Copilot agent mode), Antigravity, Windsurf, Claude Code and Gemini CLI. It runs on Android, iOS and desktop, and is compiled out of release builds.

## Installation (as documented in the README)

```yaml
dependencies:
  fixkit: ^0.1.8
```

or from GitHub:

```yaml
dependencies:
  fixkit:
    git:
      url: https://github.com/Huzaifa-367/Fixkit-Pckg.git
      ref: v0.1.8
```

then `flutter pub get` and `dart run fixkit init`.

`init` does all of the setup automatically:

- wraps `runApp` in `FixKit`;
- writes the MCP config for every editor it finds;
- pre-approves fixkit's tools where the editor allows it;
- turns on hot reload on save;
- adds a section to `AGENTS.md` (and `CLAUDE.md`);
- stamps the version in `.fixkit/state.json`;
- starts the hub.

After that, the user reloads the editor once, runs the app, and says **"watch for fixes"** in the agent chat.

## Decisions made

| Question | Decision |
| --- | --- |
| Which editors | Any MCP editor. The agent long-polls `wait_for_fix_report`, because no editor allows prompt injection. |
| Setup effort | Plug and play: two commands, no servers, ports or IPs to configure |
| Finding the widget | In-process, using Flutter's widget creation locations (file:line), with no marks needed |
| Agent hot reload (0.1.7–0.1.8) | Hot reload on save does not fire when an agent writes files itself, so fixkit reloads the app on its own. At launch the app asks its own VM service, which redirects to the Dart Development Service (DDS) that `flutter run` started on the computer. The app sends that address to the hub, along with its `FixKit` location so the hub knows the project. In a terminal `flutter run` the app looks again a few seconds after launch. The hub calls the `reloadSources` service the Flutter tool registered there, which is the same as pressing the editor's reload button. It works from any editor, Android Studio or a terminal, on any device. From 0.1.8 the hub watches the project's `lib` and reloads 2.5 s after any Dart edit stops, with or without a fix report, unless the editor's reload on save already covered it (`autoReload`, on by default). It also reloads on `hot_reload`, and in `complete_fix` when nothing has reloaded since the last edit. `dart run fixkit reload` checks it by hand; `dart run fixkit run` still works as another route. |
| Confirming a fix is live | The app's `reassemble()` signal on every hot reload, whatever triggered it. A reload in the middle of a fix keeps the report open; only `complete_fix` finishes it. |
| In-app UI | AI-agent style: a composer with a presence badge ("Cursor is watching") and suggestion chips, and a live agent card with an orb, steps, elapsed time and a typed summary. The full-screen edge glow was removed in 0.1.6. |
| Pressing interactive widgets | A raw pointer listener outside the gesture arena fires at 450 ms, before Flutter's own 500 ms long press, then cancels the pointer. A ring under the finger fills while holding (from 0.1.6). Text fields, buttons and widgets with their own long press never react; a scroll or a pinch cancels the press. |
| Selecting layouts | A selection bar (− / + / tap a chip) widens the selection from the pressed widget to the Row, Column, card or screen around it. The report names the selected widget and the one under the finger. |
| Live steps | The hub records them (sent, reading, edited, hot reloaded, fix on screen). From 0.1.6 the app holds one status request open (`since` revision) and the hub answers it the moment the report changes. The hub watches the project's `lib` folder for edits to any file. The `fix_progress` tool is optional. |
| State management | Flutter built-ins only: `ValueNotifier`, `ValueListenableBuilder`, `Listenable.merge`, and `CustomPainter`s that repaint from their animations. No third-party packages. |
| Versioning | Semver. The same version appears in pubspec, code, README and changelog; tags are `vX.Y.Z`. |

## Stages the package handles

| Stage | What happens |
| --- | --- |
| No hub or editor | The badge says "fixkit offline"; the card says "fixkit is not listening", with how to fix it. On launch, the console prints a hint to run `init`. |
| Hub left over from an older fixkit | The badge says "Updating fixkit"; the app asks the old hub to stop and the editor starts the current one. `dart run fixkit restart` does the same by hand. |
| Hub up, no agent watching | Shown as queued. After 3 s the request goes to the clipboard and a desktop notification appears. |
| Agent busy | The badge says busy; the report is queued and the agent picks it up on its next wait. |
| Agent takes it | The card shows live steps as they happen: sent, reading file:line, edited (noticed by the hub), hot reloading, fix on screen. The agent's summary is typed out. |
| Agent (or any tool) edits Dart files | The hub hot reloads the app once the edits pause, fix report or not. A compile error on `hot_reload` goes back to the agent and shows on the card. |
| Agent fails, or asks a question | A red or amber card. Questions stay on screen until dismissed. |
| Agent disconnects mid-fix | The report goes back to the queue. |
| Agent goes quiet for 15 min | The report is marked not fixed, with a hint. |
| App restarted or hot restarted mid-fix | The launch signal resumes following the report and refreshes the app's Flutter session. |
| Rotation or resize while composing | The composer closes, because its measurements are stale. |
| Keyboard opens or closes while composing | The app slides with it frame by frame. |
| App in the background | Following pauses (not when the desktop window merely loses focus) and catches up on return. |
| App's fixkit newer than the hub | The card says to reload the editor. |
| Scroll, pinch, or right-click | Not a long press. |

## Performance (0.1.6)

- The controller is a set of `ValueNotifier`s, so each change rebuilds only the widget that shows it. The app under fixkit never rebuilds.
- No backdrop blur, blur masks or `saveLayer`. Glass is a translucent fill with gradients.
- The spotlight dim, pulse ring, hold ring and orb are painters that repaint in their own layers from their animations.
- The press listener only starts timers; the hold ring stays idle for the first 120 ms, so taps cost nothing.
- Inspection runs once per press. The screenshot is captured once, after the composer has opened, and the outline is drawn at send time.
- Status uses a long poll; hubs from 0.1.5 and earlier fall back to 800 ms polling. Nothing runs while no report is active or the app is in the background.
- Reduced motion stops the pulse and the burst.

## Version handling

- **One source of truth.**
  - `tool/release.dart patch|minor|major|x.y.z` bumps the version in `pubspec.yaml`, `fixkitVersion` in code and the README snippets, and turns `## Unreleased` into the new changelog section. `--commit` also commits and tags.
  - `test/version_test.dart` and `release.dart --check` fail if those places drift apart.
- **Release workflow.** It runs on a `v*` tag:
  1. checks that the tag matches the version;
  2. runs analyze and the tests;
  3. publishes to pub.dev through automated publishing (enable it once on pub.dev for the repository);
  4. creates the GitHub release from the changelog.
- **Upgrades.** `dart run fixkit upgrade [x.y.z]` works for both pub.dev and git dependencies:
  1. moves the `^constraint` or the `ref: vX.Y.Z` tag;
  2. runs `pub get`;
  3. runs `init --refresh` with the new code.

  If `pubspec.yaml` is upgraded by hand, the MCP server refreshes the launcher, the editor configs and the AGENTS section on its next start, using the stamp. It never touches app code.
- **Runtime.**
  - An older hub gives way to a newer one automatically, including when the app detects it.
  - The app shows "Reload your editor to update fixkit" when the hub speaks an older protocol.
  - `doctor` and `version` show the installed source and version, the hub's version, and the newest release from pub.dev or GitHub tags. `doctor` and `status` also show whether the agent can hot reload the app.

## Commands

`init`, `doctor`, `run`, `status`, `reload`, `upgrade`, `version`, `restart`, `uninstall` (plus `mcp` and `hub`, which editors start themselves).

## Demo

An animated liquid-glass walkthrough of the full flow, including the hold ring: https://claude.ai/artifact/CA2qDznRCoNZyE1VeVa8Yg (also `docs/demo.html` in the repo).

## Next steps

1. Push the package and its tags to https://github.com/Huzaifa-367/Fixkit-Pckg. Then run `flutter pub get`, `flutter analyze` and `flutter test`, and fix whatever the compiler reports.
2. Check agent hot reload on a real setup:
   1. Upgrade to 0.1.8 and fully restart the app.
   2. The debug console should say "fixkit: agent hot reload is on".
   3. Run `dart run fixkit reload`; it reloads the app or prints why it couldn't.
   4. Then let the agent edit a file and watch the app reload by itself.
3. Try the demo:
   1. `cd example`
   2. `flutter create . --platforms=android,ios`
   3. `dart run fixkit init`
   4. Run the app and say "watch for fixes".
4. Release:
   1. Check that the name `fixkit` is free on pub.dev.
   2. Publish the first version by hand with `dart pub publish`, because automated publishing needs the package to exist first.
   3. Enable automated publishing for the repository.
   4. Push the tag `v0.1.8`.
5. Optional later: a VS Code/Open VSX extension with a queue sidebar.

## Known limits

- Debug builds only.
- Platform views are not in the screenshot.
- The agent decides how long it keeps watching. If it stops, say "watch for fixes" again; reports wait in the queue meanwhile.
- Editor configs hold the path to the Dart SDK. `init`, or the automatic refresh, rewrites it after a Flutter upgrade.
- Agent hot reload needs the app's DDS, which every normal `flutter run` starts. A run with `--no-dds` falls back to `fixkit run`, hot reload on save or the Dart MCP server.
- Edits an agent leaves unsaved in an editor tab are not on disk, so nothing can reload them until they are saved.
- `FixConnection.status` gained an optional `since` parameter in 0.1.6, and `FixConnection.signal` an optional `appFile` in 0.1.8; only custom connections (test fakes) need updating.