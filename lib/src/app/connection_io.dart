import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'connection.dart';

/// Set by `dart run fixkit run --lan` (or `.fixkit/defines.json`) for phones
/// that reach the computer over Wi-Fi: `192.168.1.20:4747`.
const String _definedHost = String.fromEnvironment('FIXKIT_HOST');

/// The LAN token the hub requires from devices that are not on loopback.
const String _definedToken = String.fromEnvironment('FIXKIT_TOKEN');

FixConnection createConnection() => IoFixConnection();

/// Finds the hub without configuration:
/// - iOS simulators and desktop apps share the computer's loopback;
/// - Android devices and emulators reach it on loopback through the
///   `adb reverse` the hub sets up, and emulators also on 10.0.2.2;
/// - phones on Wi-Fi use the host baked in with `FIXKIT_HOST`.
class IoFixConnection implements FixConnection {
  IoFixConnection({List<Uri>? candidates}) : _explicit = candidates;

  final List<Uri>? _explicit;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..idleTimeout = const Duration(seconds: 10)
    // A proxy on the device must not see these requests.
    ..findProxy = (_) => 'DIRECT';

  Uri? _base;
  Future<Uri?>? _resolving;

  List<Uri> get candidates {
    final explicit = _explicit;
    if (explicit != null) return explicit;
    final found = <Uri>[];
    if (_definedHost.isNotEmpty) {
      final host = _definedHost.contains(':') ? _definedHost : '$_definedHost:$fixkitPort';
      found.add(Uri.parse('http://$host'));
    }
    found.add(Uri.parse('http://127.0.0.1:$fixkitPort'));
    if (Platform.isAndroid) found.add(Uri.parse('http://10.0.2.2:$fixkitPort'));
    return found;
  }

  @override
  String get description => _base?.authority ?? candidates.map((uri) => uri.authority).join(' or ');

  /// The first candidate whose `/hello` answers as a fixkit hub.
  Future<Uri?> _resolve() {
    final base = _base;
    if (base != null) return Future.value(base);
    return _resolving ??= () async {
      try {
        for (final candidate in candidates) {
          try {
            final hello = await _request(candidate, 'GET', '/hello').timeout(const Duration(milliseconds: 1500));
            if (hello['fixkit'] == true) return _base = candidate;
          } catch (_) {
            // Try the next address.
          }
        }
        return null;
      } finally {
        _resolving = null;
      }
    }();
  }

  Future<Map<String, Object?>> _call(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final base = await _resolve();
    if (base == null) throw FixHubUnreachable('tried $description');
    try {
      return await _request(base, method, path, body: body, query: query).timeout(timeout);
    } on SocketException catch (error) {
      _base = null;
      throw FixHubUnreachable(error.message);
    } on TimeoutException {
      _base = null;
      throw const FixHubUnreachable('timed out');
    } on HttpException catch (error) {
      throw FixHubUnreachable(error.message);
    }
  }

  Future<Map<String, Object?>> _request(
    Uri base,
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
  }) async {
    final uri = base.replace(path: path, queryParameters: query);
    final request = await _client.openUrl(method, uri);
    if (_definedToken.isNotEmpty) request.headers.set(fixkitTokenHeader, _definedToken);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == HttpStatus.conflict) {
      String? error;
      try {
        final body = jsonDecode(text);
        if (body is Map && body['error'] is String) error = body['error'] as String;
      } catch (_) {}
      throw FixVersionMismatch(error ?? 'The fixkit hub is older than this app. Reload your editor window.');
    }
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('hub answered ${response.statusCode}: $text', uri: uri);
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) throw HttpException('hub answered with no object', uri: uri);
    return decoded.cast<String, Object?>();
  }

  @override
  Future<Map<String, Object?>> report(Map<String, Object?> body) =>
      _call('POST', '/report', body: body, timeout: const Duration(seconds: 15));

  @override
  Future<Map<String, Object?>> status(String id, {int? since}) => since == null
      ? _call('GET', '/status', query: {'id': id})
      : _call(
          'GET',
          '/status',
          query: {'id': id, 'since': '$since', 'wait': '$statusWaitSeconds'},
          timeout: const Duration(seconds: statusWaitSeconds + 6),
        );

  /// How long the hub may hold a status request.
  static const int statusWaitSeconds = 20;

  @override
  Future<Map<String, Object?>?> presence({String? file}) async {
    try {
      return await _call(
        'GET',
        '/presence',
        query: file == null ? null : {'file': file},
        timeout: const Duration(seconds: 3),
      );
    } on FixHubUnreachable catch (error) {
      // A hub from before presence existed answers 404: it is outdated.
      if ((error.reason ?? '').contains('answered 404')) return await _outdated();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, Object?>?> _outdated() async {
    final base = _base;
    if (base == null) return {'outdated': true};
    try {
      final hello = await _request(base, 'GET', '/hello').timeout(const Duration(seconds: 2));
      return {'outdated': true, 'version': hello['version']};
    } catch (_) {
      return {'outdated': true};
    }
  }

  @override
  Future<bool> restartHub() async {
    try {
      await _call('POST', '/admin/shutdown', body: const {}, timeout: const Duration(seconds: 3));
      _base = null;
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Map<String, Object?>?> signal(String kind) async {
    try {
      return await _call('POST', '/signal', body: {'kind': kind, 'protocol': fixkitProtocol, 'version': fixkitVersion});
    } catch (_) {
      return null;
    }
  }
}
