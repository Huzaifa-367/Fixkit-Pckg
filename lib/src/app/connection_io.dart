import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'connection.dart';
import 'flutter_session_io.dart';

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

  /// Where the hub can hot reload this app (see [findFlutterSession]). Kept
  /// once found; until then looked up again at most every 15 seconds, since
  /// the Flutter tool's DDS may take over after the app's first frame.
  Map<String, Object?>? _session;
  Future<Map<String, Object?>?>? _lookingUp;
  DateTime? _lookedUpAt;

  bool _said = false;
  String? _appFile;
  bool _lookingAgain = false;

  /// A terminal `flutter run` starts the app before its DDS takes over, so
  /// the launch lookup can come up empty. Look again a few times, and tell
  /// the hub as soon as the session is there, so agent edits reload the app
  /// without waiting for a reload or a report.
  void _lookAgainLater() {
    if (_lookingAgain) return;
    _lookingAgain = true;
    unawaited(() async {
      for (final wait in const [Duration(seconds: 3), Duration(seconds: 10), Duration(seconds: 30)]) {
        await Future<void>.delayed(wait);
        if (_session != null) return;
        final session = await findFlutterSession();
        if (session == null) continue;
        _session = session;
        // ignore: avoid_print
        print('fixkit: agent hot reload is on (through this run\'s Flutter session).');
        try {
          await _call('POST', '/signal', body: {
            'kind': 'session',
            'protocol': fixkitProtocol,
            'version': fixkitVersion,
            if (_appFile != null) 'appFile': _appFile,
            'flutterSession': session,
          });
        } catch (_) {}
        return;
      }
    }());
  }

  /// Says once, in the debug console, whether fixkit can hot reload the app
  /// for the agent.
  void _sayHowItReloads(Map<String, Object?>? session) {
    if (_said) return;
    _said = true;
    // ignore: avoid_print
    print(session != null
        ? 'fixkit: agent hot reload is on (through this run\'s Flutter session).'
        : 'fixkit: no Flutter session found yet for agent hot reload; fixkit tries again on the next reload or report.');
  }

  Future<Map<String, Object?>?> _flutterSession() async {
    final found = _session;
    if (found != null) return found;
    final last = _lookedUpAt;
    if (_lookingUp == null && (last == null || DateTime.now().difference(last) > const Duration(seconds: 15))) {
      _lookedUpAt = DateTime.now();
      _lookingUp = findFlutterSession().then((session) {
        _session = session;
        _lookingUp = null;
        return session;
      });
    }
    final looking = _lookingUp;
    if (looking == null) return null;
    return looking.timeout(const Duration(seconds: 4), onTimeout: () => null);
  }

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
  Future<Map<String, Object?>> report(Map<String, Object?> body) async {
    final session = await _flutterSession();
    return _call(
      'POST',
      '/report',
      body: {...body, if (session != null) 'flutterSession': session},
      timeout: const Duration(seconds: 15),
    );
  }

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
  Future<Map<String, Object?>?> signal(String kind, {String? appFile}) async {
    try {
      if (appFile != null) _appFile = appFile;
      final session = await _flutterSession();
      if (kind == 'launch') {
        _sayHowItReloads(session);
        if (session == null) _lookAgainLater();
      }
      return await _call('POST', '/signal', body: {
        'kind': kind,
        'protocol': fixkitProtocol,
        'version': fixkitVersion,
        if (appFile != null) 'appFile': appFile,
        if (session != null) 'flutterSession': session,
      });
    } catch (_) {
      return null;
    }
  }
}
