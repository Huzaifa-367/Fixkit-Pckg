# fixkit

Long press any widget in your running Flutter app and ask your agent to change it. The AI agent in your editor gets the request with the widget's **file and line**, the widgets around it and a screenshot. It fixes the code and hot reloads. Inside the app, a live agent card shows every step (*sent*, *reading the file*, *edited*, *hot reloaded*, *fixed*) and types out the agent's summary.

It works with any editor or agent that speaks MCP: **Cursor, VS Code (Copilot agent mode), Antigravity, Windsurf, Claude Code, Gemini CLI**. It runs on Android and iOS (simulators, emulators and devices) and on desktop. Release builds contain none of it.

A Flutter take on [ostiums/fixkit](https://github.com/ostiums/fixkit) (iOS + Claude Code), rebuilt to work in any editor with no configuration.

## Installation

Add fixkit to your app's `pubspec.yaml`:

```yaml
dependencies:
  fixkit: ^0.1.1
```

Or from GitHub:

```yaml
dependencies:
  fixkit:
    git:
      url: https://github.com/Huzaifa-367/Fixkit-Pckg.git
      ref: v0.1.1
```

Then:

```bash
flutter pub get
dart run fixkit init
```

That is the whole setup. `init` does the rest and tells you what it did:

- wraps your app: `runApp(FixKit(child: MyApp()))`, a no-op in release builds;
- finds the editors on your computer and adds fixkit to each one's MCP config. It also adds the Dart SDK's MCP server where it is missing, so agents can hot reload;
- pre-approves fixkit's tools where the editor allows it from a file (Claude Code, Gemini CLI);
- turns on hot reload on save for the Dart extension (VS Code, Cursor, Antigravity, Windsurf);
- adds a short fixkit section to `AGENTS.md` (and `CLAUDE.md` for Claude Code);
- starts the fixkit hub;
- records the fixkit version it set up, so later upgrades refresh the setup by themselves (see [Versions and upgrades](#versions-and-upgrades)).

Then:

1. **Reload your editor window once** so it loads fixkit. Cursor and VS Code may ask you to enable or start the server; Claude Code asks to approve the project's `.mcp.json`.
2. **Run the app as usual**: F5 in the editor, or `flutter run`.
3. **In your agent's chat, say: `watch for fixes`.** Where the editor supports MCP prompts, `/fixkit` does the same.
4. **Long press anything in the app**, type what is wrong, press Send.

`dart run fixkit doctor` checks every piece and says how to fix anything missing.

## Where you type "watch for fixes"

In the editor's AI chat, the panel where you normally ask the agent to write code:

| Editor | Chat |
| --- | --- |
| Cursor | Agent chat (Cmd/Ctrl+L) |
| VS Code | Copilot Chat in **Agent** mode (Ask mode cannot call tools) |
| Antigravity | The agent panel / Agent Manager |
| Windsurf | Cascade |
| Claude Code | The `claude` prompt |
| Gemini CLI | The `gemini` prompt |

The agent then loops: it waits for a report, fixes it, hot reloads, reports back, and waits again.

## What the agent receives

```
Income should be green

[fix r3] Text "+€4,650.00" · lib/features/activity/transaction_row.dart:35 · Activity screen
Widget path, innermost first (each line is where that widget is constructed):
  - Text "+€4,650.00" → lib/features/activity/transaction_row.dart:35
  - Row → lib/features/activity/transaction_row.dart:18
  - Padding → lib/features/activity/transaction_row.dart:16
  - TransactionRow → lib/features/activity/activity_page.dart:29
  - ActivityPage → lib/main.dart:43
Nearby text: "Northwind GmbH", "Salary, September"
Screen: Activity
Platform: iOS
Screenshot: .fixkit/reports/r3-1759821234.png (pressed area outlined in red)
```

The screenshot is also attached as an image.

**No marks needed.** Debug builds of Flutter record where every widget is constructed (the data the Flutter Inspector uses), so fixkit reads the pressed widget's file and line inside the app. The iOS original needed an accessibility tool for this; Flutter does not.

## What it looks like in the app

- **Any widget, even interactive ones.** Long press works on text fields, buttons, `InkWell`s and `GestureDetector`s with their own long press, list items and sliders. fixkit watches the finger itself instead of competing for the gesture. It fires just before Flutter's own long press, then cancels the press for the widget underneath, so the widget doesn't react:
  - text is not selected;
  - the button does not tap;
  - the app's own long-press menu does not open.

  A ring under the finger fills while you hold, so you can see the press coming. Moving the finger (a scroll) or using a second finger (a pinch) cancels the press.
- **Select a Row, Column or card.** The composer's selection bar lists the pressed widget and the widgets of your own code around it, for example `Text › Row › Padding › TransactionRow › Column`. Tap one, or use **−** and **+**, to move the selection. The light glides to it and the label shows its file and line. The report is then about that widget (its spacing, alignment or children), and it still says which widget was under the finger. Suggestions change to fit, such as *Align the items* for a Row.
- **The composer.** The selected widget is lit and labelled with its file and line. Above the keyboard there are three compact rows:
  - the selection bar;
  - a badge saying who is watching ("Cursor is watching"), followed by suggestion chips that fit the widget, such as *Change the colour* or *Fix the overflow* for text, *Match the other buttons* for buttons, and *Align the items* for a Row;
  - the prompt.
- **The agent card.** After you send, a glass card at the top of the screen follows the fix live, with an animated orb for the agent:
  - *Sent to Cursor*
  - *Reading transaction_row.dart:35*
  - *Edited transaction_row.dart*
  - *Hot reloaded*
  - *Fixed*, followed by the agent's summary typed out

  Each step appears the moment the hub hears of it: the app keeps one request open that the hub answers as soon as the report changes, rather than polling. The hub notices the agent's edits by watching your project's `lib` folder, so the card stays live with any agent. Agents can add their own notes with the optional `fix_progress` tool. A timer beside the title shows how long the agent has been at it.

  Tap the card to fold it into a pill, or ✕ to close it (the agent keeps working).
- **Light on the app.** The overlay uses Flutter's own `ValueNotifier`s and painters, with no blur and no extra packages. Your app never rebuilds because of fixkit: a status change repaints the card, a presence check repaints the badge, and the hold ring and spotlight repaint in layers of their own.

The animated walkthrough in [`docs/demo.html`](docs/demo.html) shows the whole flow; open it in a browser.

## Optional: names

`FixName` gives an area a name of your choosing. It appears in the selection bar as a stop of its own (`"home.walletCard"`), and reports from inside it lead with the name:

```dart
FixName('home.walletCard', child: WalletCard(card: card))
```

`FixScreen` names a screen. Without it, fixkit reports the route name and the nearest widget called `…Screen`, `…Page` or `…View`:

```dart
FixScreen('Checkout', child: Scaffold(...))
```

Both return their child unchanged in release builds.

## How it works

```
 app (debug build)                 your computer
┌──────────────────┐   POST /report   ┌───────────────┐   long poll    ┌──────────────────┐
│ FixKit           │ ───────────────▶ │  fixkit hub   │ ◀───────────── │ fixkit MCP server │◀── agent in Cursor,
│ long press,      │                  │  :4747        │                │ (one per editor)  │    VS Code, Antigravity,
│ composer, banner │ ◀─── /status ─── │  routes by    │ ── report ───▶ │ wait_for_fix_report│   Claude Code ...
│ reassemble() ────┼─── /signal ────▶ │  project      │ ◀── complete ─ │ complete_fix      │
└──────────────────┘                  └───────────────┘                └──────────────────┘
```

- **In the app:** `FixKit` listens to raw pointer events above your app, outside the gesture arena. A press held for 450 ms belongs to fixkit: it cancels that pointer for every other recognizer, so text fields, buttons and widgets with their own long press do not react. fixkit then:
  - hit-tests the render tree and walks the widget chain with each widget's creation location;
  - keeps the widgets of your own code around the press as selectable scopes;
  - captures the screen; the outline is drawn around the final selection when the report is sent;
  - opens the composer, sliding the app up if the keyboard would cover the widget.

  When it opens the composer, it asks the hub which agent is watching. On every launch and every hot reload (`State.reassemble`), it tells the hub. That is how a fix is confirmed on screen, whatever did the reload.
- **The hub** is one small background process per computer, started by whichever editor needs it first. It:
  - routes each report to the agent that has the widget's project open, so several projects and several editors work at once;
  - keeps each report's activity (taken, reading, edited, reloaded, fixed), noticing edits by watching the widget's files;
  - keeps the queue and the statuses;
  - runs `adb reverse` for Android devices;
  - stops itself after 30 minutes with nothing connected.
- **The MCP server** is what editors start (`dart .fixkit/mcp.dart`). It registers with the hub and exposes these tools:
  - `wait_for_fix_report`
  - `complete_fix`
  - `fix_progress` (optional notes shown live in the app)
  - `hot_reload`
  - `get_fix_report`
  - `list_fix_reports`
  
  It also offers a `fixkit` prompt.
- **If no agent picks a report up**, because the editor is closed or nobody said "watch for fixes", the hub copies the request to your clipboard and shows a desktop notification. You can paste it into any chat, in any editor, even one without MCP.

## Devices

| Device | How it connects | Setup |
| --- | --- | --- |
| iOS simulator, macOS/Windows/Linux app | Shares the computer's loopback | none |
| Android emulator | `adb reverse`, or 10.0.2.2 | none |
| Android phone (USB or wireless debugging) | `adb reverse`, which the hub runs whenever a device connects | none |
| iPhone | Wi-Fi to the computer, with a token | `dart run fixkit init --lan` once |

With `--lan`:

- The hub listens on the network. Requests from other machines must carry a random per-computer token, so nobody on the network can send your agent requests.
- Launches from the editor pass the computer's address and the token to the app through `.fixkit/defines.json`. `init --lan` adds `--dart-define-from-file` to `.vscode/launch.json` for you.
- From a terminal, use `dart run fixkit run --lan`.
- iOS asks once for local network access.

## Hot reload

fixkit puts the agent's change on screen by itself. You don't need to press hot reload, and the app can run however you like: the Run button in VS Code, Cursor, Antigravity or Windsurf, Android Studio, or `flutter run` in a terminal.

- **How.** Every `flutter run` starts a Dart Development Service on your computer, and the Flutter tool registers its hot reload there. At launch the app looks up where that service is (from its own VM service) and tells the hub. The hub then asks the Flutter tool to hot reload, exactly as the editor's reload button does, so the editor's session, debug console and compiler stay in step.
- **When.**
  - When the agent calls fixkit's `hot_reload` tool.
  - When the agent's edits pause for a moment, so each change shows as it is made. Set `"autoReload": false` in `~/.fixkit/config.json` to turn this off.
  - When the agent calls `complete_fix` and the app hasn't reloaded since its last edit.
- **Confirmation.** The app's own reload signal (`State.reassemble`) confirms each reload, whatever triggered it. A compile error comes back to the agent, which fixes it and reloads again.

`dart run fixkit run` (a drop-in for `flutter run`) still works as another way in. Hot reload on save and the Dart MCP server's `hot_reload` tool also still count.

## Commands

```
dart run fixkit init        set up the project and editors (--lan, --editors=..., --dry-run, --no-main, --no-dart-mcp)
dart run fixkit doctor      check everything (--start starts the hub)
dart run fixkit run         flutter run that agents can hot reload (--lan; other options go to flutter run)
dart run fixkit status      connected agents and recent reports (--json)
dart run fixkit upgrade     move to the newest (or a given) release and refresh the setup
dart run fixkit restart     replace the running hub with this project's fixkit
dart run fixkit version     installed, running and latest versions
dart run fixkit uninstall   undo init
```

## Versions and upgrades

fixkit follows [semantic versioning](https://semver.org). Each release is published to pub.dev and tagged `vX.Y.Z` on [GitHub](https://github.com/Huzaifa-367/Fixkit-Pckg/tags), with the same version in both places.

**Upgrading takes one command:**

```bash
dart run fixkit upgrade            # to the newest release
dart run fixkit upgrade 0.1.5      # to a specific one
```

It works whether you depend on fixkit from pub.dev or from git:

- **From pub.dev**, it moves your `fixkit: ^x.y.z` constraint.
- **From git**, it moves the `ref: vx.y.z` tag.

Then it runs `flutter pub get`, refreshes the project setup with the new version, and restarts the hub.

**If you upgrade by hand instead** (editing `pubspec.yaml`, then `flutter pub get`), nothing else is needed:

- **Project files.** fixkit notices the new version the next time your editor starts its MCP server. It then refreshes the launcher, the editor configs that already list fixkit, and the `AGENTS.md` section. It never touches your code.
- **The hub.** An older hub gives way to the newer one automatically.

**Checking versions:**

- **`dart run fixkit doctor`** shows:
  - the installed version and where it comes from (pub.dev, or git and which ref);
  - the running hub's version;
  - whether a newer release exists.
- **`dart run fixkit version`** prints the same in one line.

**Mismatches:**

- The app, the hub and the MCP server agree on a protocol number. A protocol only changes in a release that says so in the changelog.
- When the app runs a newer fixkit than the hub, the app says so in its agent card and asks you to restart the editor, instead of failing silently.

## Settings

- **In code:**
  - `FixKit(enabled: false)` turns fixkit off.
  - `pressDuration` changes how long the press is held (450 ms by default, just under Flutter's own 500 ms long press, so fixkit always gets the press first).
  - `screenshots: false` sends reports without a screenshot, for screens that show data that must not leave the device.
- **Per computer**, in `~/.fixkit/config.json`:
  - `lan` (Wi-Fi devices; set by `init --lan`);
  - `clipboard` (copy unclaimed reports);
  - `notifications`.

## Files

| Path | What | Commit it? |
| --- | --- | --- |
| `.fixkit/mcp.dart` | The launcher editors run | Yes |
| `.fixkit/reports/` | Screenshots and report JSON | No (`.fixkit/.gitignore` excludes it) |
| `.fixkit/defines.json` | Wi-Fi host and token | No |
| `.fixkit/state.json` | The fixkit version the setup was made with | Yes |
| `.cursor/mcp.json`, `.vscode/mcp.json`, `.mcp.json`, `.gemini/settings.json` | Editor configs | Your choice. They hold the path to your Dart SDK, so teammates run `dart run fixkit init` once. |
| `~/.fixkit/` | Hub log, token, settings | Stays on your computer |

## Troubleshooting

The badge at the start of the suggestions row says what the app sees:

| Badge | Meaning | What to do |
| --- | --- | --- |
| **Cursor is watching** | The agent gets your request at once | Send it |
| **Cursor is busy** | It is finishing another fix; yours is next | Send it; it queues |
| **Cursor is idle** | The editor has fixkit, but the agent is not looping | Say "watch for fixes" in its chat |
| **No agent** | No editor has fixkit loaded | Open the project in your editor and reload the window once; `dart run fixkit status` lists connected agents |
| **fixkit offline** | The app cannot reach the hub | `dart run fixkit doctor`. Physical Android phones need adb (the hub runs `adb reverse` by itself); iPhones need `init --lan` |
| **Updating fixkit** | A hub from an older fixkit was running | The app asks it to stop, and your editor starts the current one within seconds. If it persists, run `dart run fixkit restart` |

If the agent's changes don't reload by themselves, restart the app once (not just hot reload it): the app tells the hub how to reach its Flutter session at launch. `dart run fixkit status` lists the apps the hub can reload under **Agent hot reload**.

Hot reload or restart the app after upgrading fixkit, and reload the editor window, so all three parts run the same version. `dart run fixkit doctor` checks for that too.

## Limits

- Debug builds only, by design: `kDebugMode` compiles fixkit out of profile and release builds.
- Widgets inside platform views (maps, web views) are reported by the Flutter widget that hosts them, and are not in the screenshot.
- A press inside a dialog or bottom sheet works, because they are part of the widget tree. The composer is drawn above them.
- On Windows, `fixkit run` reloads by typing `r` into `flutter run`; hot reload on save and the Dart MCP server work as everywhere else.
- Agents decide how long they keep looping. If one stops, say "watch for fixes" again; reports wait in the queue meanwhile.

## Example

`example/` is Tally, a small wallet app with four seeded UI bugs. See [example/README.md](example/README.md).

## Development

```bash
flutter pub get
flutter analyze
flutter test
```

### Releasing

The version lives in four places, and `tool/release.dart` keeps them equal:

- `pubspec.yaml`
- `lib/src/protocol.dart` (`fixkitVersion`)
- the snippets in this README
- the newest section of `CHANGELOG.md`

`test/version_test.dart` fails if they drift apart.

1. Write the changes under `## Unreleased` at the top of `CHANGELOG.md`.
2. Run `dart run tool/release.dart patch`. It also takes `minor`, `major` or an exact version like `0.2.0`. The script:
   - bumps the version in all three places;
   - turns `## Unreleased` into the new version's section;
   - with `--commit`, commits and tags `vX.Y.Z`.
3. Push the commit and the tag: `git push && git push --tags`.

The **Release** workflow runs on the tag. It:

1. checks that the tag matches `pubspec.yaml`;
2. runs the tests;
3. publishes to pub.dev through automated publishing (enable it once for the repository on the package's admin page on pub.dev);
4. creates the GitHub release with that version's changelog section.

The package has no dependencies beyond Flutter. The in-app library is `lib/src/app`; the hub, MCP server and CLI are plain Dart (`lib/src/server`, `lib/src/cli`) that never import Flutter.

## License

MIT
