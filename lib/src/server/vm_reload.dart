import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// What a hot reload request came to.
class ReloadOutcome {
  const ReloadOutcome.reloaded()
      : error = null,
        unreachable = false;
  const ReloadOutcome.failed(String this.error) : unreachable = false;

  /// The session did not answer at all: it is gone (the app restarted).
  const ReloadOutcome.unreachable(String this.error) : unreachable = true;

  /// Why it did not reload; null when it did.
  final String? error;
  final bool unreachable;

  bool get ok => error == null;
}

/// Hot reloads a running Flutter app through the session that started it.
abstract class FlutterReloader {
  const FlutterReloader();

  /// Asks the Flutter tool behind [service] (the app's Dart Development
  /// Service, on this computer) to hot reload, as the editor's reload button
  /// does. [isolateId] is the app's main isolate, when the app said which.
  Future<ReloadOutcome> reload(Uri service, {String? isolateId});
}

/// Talks to the app's Dart Development Service (DDS) over the VM service
/// protocol. Every `flutter run` (from a terminal, VS Code, Cursor,
/// Antigravity, Android Studio...) registers a `reloadSources` service there;
/// calling it is exactly what the editor's hot reload button does, so the
/// editor's session, its console and its compiler stay in step.
class DdsReloader extends FlutterReloader {
  const DdsReloader({
    this.connectTimeout = const Duration(seconds: 3),
    this.serviceTimeout = const Duration(seconds: 3),
    this.reloadTimeout = const Duration(seconds: 45),
  });

  final Duration connectTimeout;

  /// How long to wait for the Flutter tool's services to be listed.
  final Duration serviceTimeout;

  /// A reload compiles the changes first; a big change takes a while.
  final Duration reloadTimeout;

  @override
  Future<ReloadOutcome> reload(Uri service, {String? isolateId}) async {
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(_webSocketUri(service).toString()).timeout(connectTimeout);
    } catch (error) {
      return ReloadOutcome.unreachable('could not reach the app\'s Flutter session ($error)');
    }
    final rpc = _Rpc(socket);
    try {
      await rpc.call('streamListen', {'streamId': 'Service'}).timeout(serviceTimeout);
      final method = await rpc.reloadMethod.timeout(serviceTimeout, onTimeout: () => null);
      if (method == null) {
        return const ReloadOutcome.failed('the app\'s Flutter session offers no hot reload (not started by flutter run?)');
      }
      final isolate = await _isolate(rpc, isolateId);
      if (isolate == null) return const ReloadOutcome.failed('the app has no isolate to reload');
      final answer = await rpc.call(method, {'isolateId': isolate}).timeout(reloadTimeout);
      if (answer is Map && answer['type'] == 'Success') return const ReloadOutcome.reloaded();
      return ReloadOutcome.failed('the Flutter tool answered ${jsonEncode(answer)}');
    } on _RpcError catch (error) {
      return ReloadOutcome.failed(error.message);
    } on TimeoutException {
      return const ReloadOutcome.failed('the Flutter tool did not answer in time');
    } catch (error) {
      return ReloadOutcome.failed('$error');
    } finally {
      await rpc.close();
    }
  }

  /// The app's main isolate: the one it named if it is still running (a hot
  /// restart starts a new one), else the first isolate called main.
  Future<String?> _isolate(_Rpc rpc, String? wanted) async {
    final vm = await rpc.call('getVM', const {}).timeout(serviceTimeout);
    final isolates = vm is Map && vm['isolates'] is List ? (vm['isolates'] as List).whereType<Map>().toList() : const <Map>[];
    if (isolates.isEmpty) return wanted;
    final ids = [for (final isolate in isolates) '${isolate['id']}'];
    if (wanted != null && ids.contains(wanted)) return wanted;
    final main = isolates.where((isolate) => '${isolate['name']}'.contains('main')).firstOrNull;
    return '${(main ?? isolates.first)['id']}';
  }

  static Uri _webSocketUri(Uri service) {
    var uri = service;
    if (uri.scheme == 'http') uri = uri.replace(scheme: 'ws');
    if (uri.scheme == 'https') uri = uri.replace(scheme: 'wss');
    final path = uri.path.endsWith('/ws') ? uri.path : '${uri.path.endsWith('/') ? uri.path : '${uri.path}/'}ws';
    return uri.replace(path: path);
  }
}

class _RpcError implements Exception {
  const _RpcError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The smallest JSON-RPC 2.0 client the VM service protocol needs.
class _Rpc {
  _Rpc(this._socket) {
    _subscription = _socket.listen(
      _receive,
      onDone: _closed,
      onError: (Object _) => _closed(),
      cancelOnError: true,
    );
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final Map<String, Completer<Object?>> _pending = {};
  final Completer<String?> _reload = Completer<String?>();
  int _id = 0;

  /// The method name the Flutter tool registered for `reloadSources`.
  Future<String?> get reloadMethod => _reload.future;

  Future<Object?> call(String method, Map<String, Object?> params) {
    final id = 'fixkit-${++_id}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params}));
    return completer.future;
  }

  void _receive(dynamic data) {
    if (data is! String) return;
    final Object? message;
    try {
      message = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (message is! Map) return;
    final id = message['id'];
    if (id != null) {
      final completer = _pending.remove('$id');
      if (completer == null) return;
      final error = message['error'];
      if (error is Map) {
        final details = error['data'] is Map ? (error['data'] as Map)['details'] : null;
        completer.completeError(_RpcError('${error['message'] ?? 'error'}${details is String && details.isNotEmpty ? ': $details' : ''}'));
      } else {
        completer.complete(message['result']);
      }
      return;
    }
    if (message['method'] == 'streamNotify') {
      final params = message['params'];
      final event = params is Map ? params['event'] : null;
      if (event is Map &&
          event['kind'] == 'ServiceRegistered' &&
          event['service'] == 'reloadSources' &&
          event['method'] is String &&
          !_reload.isCompleted) {
        _reload.complete(event['method'] as String);
      }
    }
  }

  void _closed() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(const _RpcError('the Flutter session closed the connection'));
    }
    _pending.clear();
    if (!_reload.isCompleted) _reload.complete(null);
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close().timeout(const Duration(seconds: 1), onTimeout: () {});
    _closed();
  }
}
