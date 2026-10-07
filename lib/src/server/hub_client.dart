import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'paths.dart';

class HubException implements Exception {
  const HubException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Talks to the hub from this computer: the MCP server, `fixkit run`,
/// `fixkit doctor`. Starts the hub when it is not running.
class HubClient {
  HubClient({this.port = fixkitPort, this.entryScript});

  final int port;

  /// The Dart file that starts the hub (`<project>/.fixkit/mcp.dart`).
  /// Defaults to the running program, which works for the launcher itself.
  final String? entryScript;

  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..findProxy = (_) => 'DIRECT';

  Uri get _base => Uri.parse('http://127.0.0.1:$port');

  /// The hub's `/hello`, or null when nothing fixkit answers.
  Future<Map<String, Object?>?> hello() async {
    try {
      final answer = await call('GET', '/hello', timeout: const Duration(seconds: 2));
      return answer != null && answer['fixkit'] == true ? answer : null;
    } catch (_) {
      return null;
    }
  }

  /// Makes sure a hub of this version (or newer) is running, starting one in
  /// the background when needed.
  Future<Map<String, Object?>> ensure({bool restartIfLanDiffers = false}) async {
    var hello = await this.hello();
    if (hello != null) {
      final older = _compareVersions('${hello['version']}', fixkitVersion) < 0;
      final lanWanted = FixkitSettings.load().lan;
      final lanDiffers = restartIfLanDiffers && (hello['lan'] == true) != lanWanted;
      if (!older && !lanDiffers) return hello;
      // An older hub (or one without the LAN setting) gives way to this one.
      try {
        await call('POST', '/admin/shutdown', timeout: const Duration(seconds: 2));
      } catch (_) {}
      for (var i = 0; i < 30 && await this.hello() != null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } else if (await _portTakenByOther()) {
      throw HubException(
        'Port $port is taken by another program, so the fixkit hub cannot start. '
        'Free the port and try again.',
      );
    }

    await spawnHub();
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      hello = await this.hello();
      if (hello != null) return hello;
    }
    throw HubException('The fixkit hub did not start. See ${hubLogFile().path}.');
  }

  Future<bool> _portTakenByOther() async {
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Starts `<this program> hub` detached, so it outlives the process that
  /// started it and serves every editor on the computer.
  Future<void> spawnHub() async {
    final script = entryScript == null ? Platform.script : Uri.file(entryScript!);
    final arguments = [
      ...Platform.executableArguments.where((argument) =>
          !argument.startsWith('--enable-vm-service') &&
          !argument.startsWith('--observe') &&
          !argument.startsWith('--pause') &&
          !argument.startsWith('--write-service-info')),
      if (script.scheme == 'file') script.toFilePath() else script.toString(),
      'hub',
      '--port=$port',
    ];
    await Process.start(
      Platform.resolvedExecutable,
      arguments,
      mode: ProcessStartMode.detached,
      workingDirectory: homeDirectory(),
    );
  }

  /// One request. Returns the decoded body, or null for 204 No Content.
  Future<Map<String, Object?>?> call(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final uri = _base.replace(path: path, queryParameters: query);
    final future = () async {
      final request = await _http.openUrl(method, uri);
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode == HttpStatus.noContent) return null;
      final decoded = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
      if (decoded is! Map) throw HubException('The hub answered $text');
      final map = decoded.cast<String, Object?>();
      if (response.statusCode != HttpStatus.ok) {
        throw HubException('${map['error'] ?? 'The hub answered ${response.statusCode}'}');
      }
      return map;
    }();
    return future.timeout(timeout);
  }

  void close() => _http.close(force: true);
}

/// Compares `1.2.3` style versions; pre-release suffixes are ignored.
int _compareVersions(String a, String b) {
  List<int> parts(String version) =>
      version.split('-').first.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final left = parts(a);
  final right = parts(b);
  for (var i = 0; i < 3; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}
