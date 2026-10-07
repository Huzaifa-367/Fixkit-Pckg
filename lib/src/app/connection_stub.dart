import 'connection.dart';

/// Web builds have no dart:io: fixkit stays idle there.
FixConnection createConnection() => _NoConnection();

class _NoConnection implements FixConnection {
  @override
  String get description => 'not supported on this platform';

  @override
  Future<Map<String, Object?>> report(Map<String, Object?> body) =>
      Future.error(const FixHubUnreachable('fixkit runs on Android, iOS and desktop, not on the web'));

  @override
  Future<Map<String, Object?>> status(String id, {int? since}) =>
      Future.error(const FixHubUnreachable('not supported on this platform'));

  @override
  Future<Map<String, Object?>?> signal(String kind) async => null;

  @override
  Future<Map<String, Object?>?> presence({String? file}) async => null;

  @override
  Future<bool> restartHub() async => false;
}
