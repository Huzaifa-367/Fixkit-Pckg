import 'connection_stub.dart' if (dart.library.io) 'connection_io.dart' as impl;

/// The hub could not be reached: no editor with fixkit is open, or the device
/// cannot see this computer.
class FixHubUnreachable implements Exception {
  const FixHubUnreachable([this.reason]);

  final String? reason;

  @override
  String toString() => 'fixkit hub not reachable${reason == null ? '' : ': $reason'}';
}

/// The hub runs an older fixkit than the app: the editor needs a restart (or
/// the project an upgrade) before reports can go through.
class FixVersionMismatch extends FixHubUnreachable {
  const FixVersionMismatch(String super.reason);

  String get message => reason ?? 'fixkit versions differ';
}

/// Talks to the fixkit hub on the developer's computer.
abstract class FixConnection {
  /// Sends a report; answers with its id.
  Future<Map<String, Object?>> report(Map<String, Object?> body);

  /// The status of one report. With [since] (the `revision` of the last
  /// answer) the hub holds the request until the report changes, or for
  /// about 20 seconds, so changes arrive as they happen.
  Future<Map<String, Object?>> status(String id, {int? since});

  /// Says the app launched (`launch`) or hot reloaded (`reload`); answers with
  /// the report the app should follow, if any. Never throws.
  Future<Map<String, Object?>?> signal(String kind);

  /// Which agent would take a report: `{agent, watching, busy}`. [file] is
  /// the pressed widget's file, so the hub names that project's agent.
  /// `{outdated: true, version}` when the hub predates this app's fixkit; null
  /// when the hub cannot be reached. Never throws.
  Future<Map<String, Object?>?> presence({String? file});

  /// Asks an outdated hub to stop, so the editor starts the current one.
  /// Only works from this computer (simulators, emulators, USB). Never throws.
  Future<bool> restartHub();

  /// Where the hub was found, for messages.
  String get description;
}

/// The connection for this platform: HTTP on mobile and desktop, none on web.
FixConnection createConnection() => impl.createConnection();
