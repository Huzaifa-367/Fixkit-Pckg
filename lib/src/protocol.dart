// Shared between the in-app library, the hub and the MCP server. Pure Dart:
// no dart:io and no Flutter, so every side can import it.

/// The protocol the app and the hub speak. Bumped on incompatible changes; the
/// hub accepts reports from any app whose version is not newer than its own.
const int fixkitProtocol = 1;

/// The package version. Kept equal to `version:` in pubspec.yaml by
/// `dart run tool/release.dart`, and checked by test/version_test.dart.
const String fixkitVersion = '0.1.0';

/// Where fixkit's source and releases live; `fixkit upgrade` reads its tags
/// for projects that depend on fixkit through git.
const String fixkitRepository = 'https://github.com/Huzaifa-367/Fixkit-Pckg';

/// The port the hub listens on. The app looks for it on 127.0.0.1 (simulators,
/// desktop, Android through `adb reverse`) and 10.0.2.2 (Android emulator).
const int fixkitPort = 4747;

/// Header carrying the LAN token. Requests from loopback need no token.
const String fixkitTokenHeader = 'x-fixkit-token';

/// The stages a report moves through. The app's agent card shows each one.
abstract final class FixStatus {
  /// Waiting for an agent to pick it up.
  static const queued = 'queued';

  /// An agent took it and is working on it.
  static const fixing = 'fixing';

  /// The agent finished and asked for a hot reload.
  static const reloading = 'reloading';

  /// The app reloaded with the fix.
  static const live = 'live';

  /// Fixed in code, but no reload has reached the app yet.
  static const applied = 'applied';

  /// The agent could not fix it.
  static const failed = 'failed';

  /// The agent needs an answer from the person in the chat.
  static const needsInput = 'needs_input';

  static const all = [queued, fixing, reloading, live, applied, failed, needsInput];

  /// Statuses after which the app stops following a report.
  static const finished = [live, applied, failed, needsInput];

  static bool isFinished(String status) => finished.contains(status);
}
