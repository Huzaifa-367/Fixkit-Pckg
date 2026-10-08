import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

/// How fixkit's hub can hot reload this app: `{dds, isolate}`.
///
/// `flutter run` (from a terminal or any editor) starts a Dart Development
/// Service (DDS) on the computer and hands it the app's VM service. From
/// then on the VM service answers a WebSocket request with a redirect to the
/// DDS's address (`http://127.0.0.1:port/code=/`), so asking our own VM
/// service tells us where the DDS listens on the computer, whatever the
/// device. Before DDS takes over (early in a terminal `flutter run`) there
/// is no redirect yet, and the caller asks again later. The hub calls the `reloadSources` service
/// the Flutter tool registered there: the same hot reload as the editor's
/// button. Null when there is no VM service (profile, release) or no DDS.
Future<Map<String, Object?>?> findFlutterSession() async {
  try {
    final info = await developer.Service.getInfo().timeout(const Duration(seconds: 2));
    final ws = info.serverWebSocketUri;
    if (ws == null) return null;
    final dds = await _ddsBehind(ws);
    if (dds == null) return null;
    return {
      'dds': dds.toString(),
      'isolate': developer.Service.getIsolateId(Isolate.current),
    };
  } catch (_) {
    return null;
  }
}

Future<Uri?> _ddsBehind(Uri ws) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (_) => 'DIRECT';
  try {
    final request = await client.getUrl(ws.replace(scheme: ws.scheme == 'wss' ? 'https' : 'http'));
    request.followRedirects = false;
    final random = math.Random();
    request.headers
      ..set(HttpHeaders.connectionHeader, 'Upgrade')
      ..set(HttpHeaders.upgradeHeader, 'websocket')
      ..set('Sec-WebSocket-Version', '13')
      ..set('Sec-WebSocket-Key', base64Encode(List<int>.generate(16, (_) => random.nextInt(256))));
    final response = await request.close().timeout(const Duration(seconds: 3));
    if (response.statusCode == HttpStatus.switchingProtocols) {
      // No DDS: the VM service took the connection itself.
      (await response.detachSocket()).destroy();
      return null;
    }
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>().catchError((Object _) {});
    if (location == null || !response.isRedirect) return null;
    final dds = ws.resolve(location);
    return dds.scheme == 'ws' || dds.scheme == 'wss' || dds.scheme == 'http' ? dds : null;
  } finally {
    client.close(force: true);
  }
}
