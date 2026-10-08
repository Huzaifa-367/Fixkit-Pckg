import 'dart:convert';
import 'dart:io';

import 'package:fixkit/src/protocol.dart';
import 'package:fixkit/src/server/hub.dart';
import 'package:fixkit/src/server/hub_client.dart';
import 'package:fixkit/src/server/paths.dart';
import 'package:fixkit/src/server/vm_reload.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Stands in for the Flutter tool: records each reload and, like a real app,
/// sends the reload signal when it succeeds.
class FakeReloader extends FlutterReloader {
  FakeReloader({this.error});

  final String? error;
  final List<Uri> calls = [];
  final List<String?> isolates = [];
  HubClient? app;

  @override
  Future<ReloadOutcome> reload(Uri service, {String? isolateId}) async {
    calls.add(service);
    isolates.add(isolateId);
    if (error != null) return ReloadOutcome.failed(error!);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await app?.call('POST', '/signal', body: {'kind': 'reload'});
    return const ReloadOutcome.reloaded();
  }
}

const Map<String, Object?> session = {'dds': 'ws://127.0.0.1:50123/AbCd=/ws', 'isolate': 'isolates/42'};

void main() {
  late Directory project;
  late FixHub hub;
  late HubClient client;
  late FakeReloader reloader;

  Future<void> startHub({String? error, bool autoReload = true}) async {
    project = makeProject('reload');
    reloader = FakeReloader(error: error);
    hub = FixHub(
      port: 0,
      settings: FixkitSettings(clipboard: false, notifications: false, autoReload: autoReload),
      tools: FakeHostTools(),
      reloadWait: const Duration(seconds: 2),
      adbInterval: const Duration(hours: 1),
      autoReloadDelay: const Duration(milliseconds: 300),
      reloader: reloader,
    );
    await hub.start();
    client = HubClient(port: hub.boundPort);
    reloader.app = HubClient(port: hub.boundPort);
  }

  tearDown(() async {
    client.close();
    reloader.app?.close();
    await hub.close();
    project.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>?> post(String path, Map<String, Object?> body) => client.call('POST', path, body: body);
  Future<Map<String, Object?>?> get(String path, Map<String, String> query) => client.call('GET', path, query: query);

  /// An agent takes a report sent with the app's Flutter session.
  Future<void> takeReport() async {
    await post('/agent/register', {'agent': 'Cursor', 'name': 'Cursor', 'projects': [project.path]});
    final next = get('/agent/next', {'agent': 'Cursor', 'timeout': '5'});
    await post('/report', {...appReport(project), 'flutterSession': session});
    await next;
    await post('/agent/ack', {'id': 'r1'});
  }

  List<String> activity(Map<String, Object?>? status) =>
      [for (final line in status?['activity'] as List) '${(line as Map)['text']}'];

  test('hot_reload goes through the app\'s Flutter session', () async {
    await startHub(autoReload: false);
    await takeReport();
    final answer = await post('/agent/reload', {'project': project.path});
    expect(answer?['via'], 'flutter');
    expect(answer?['reloaded'], isTrue);
    expect(reloader.calls.single, Uri.parse('ws://127.0.0.1:50123/AbCd=/ws'));
    expect(reloader.isolates.single, 'isolates/42');

    // A reload in the middle of the fix leaves the agent at work.
    final status = await get('/status', {'id': 'r1'});
    expect(status?['status'], FixStatus.fixing);
    expect(activity(status), containsAllInOrder(['Hot reloading', 'Hot reloaded']));
  });

  test('complete_fix reloads the app when the agent did not', () async {
    await startHub(autoReload: false);
    await takeReport();
    final done = await post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Income is green'});
    expect(reloader.calls, hasLength(1));
    expect(done?['status'], FixStatus.live);
    expect(activity(done).last, 'Fix is on screen');
  });

  test('a failed reload is reported to the agent and on the card', () async {
    await startHub(error: 'Unable to reload sources: compile error', autoReload: false);
    await takeReport();
    final answer = await post('/agent/reload', {'project': project.path});
    expect(answer?['reloaded'], isFalse);
    expect('${answer?['error']}', contains('compile error'));
    final status = await get('/status', {'id': 'r1'});
    expect(status?['status'], FixStatus.fixing);
    expect(activity(status).last, startsWith('Hot reload failed'));
  });

  test('the app reloads by itself once the agent\'s edits pause', () async {
    await startHub();
    await takeReport();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    File('${project.path}/lib/home.dart').writeAsStringSync('// fixed\n');
    for (var i = 0; i < 40 && reloader.calls.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(reloader.calls, hasLength(1));
    // The agent then completes: the reload already carried its edit.
    final done = await post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Done'});
    expect(done?['status'], FixStatus.live);
    expect(reloader.calls, hasLength(1));
  });

  test('sessions not on this computer are ignored', () async {
    await startHub(autoReload: false);
    await post('/signal', {
      'kind': 'launch',
      'flutterSession': {'dds': 'ws://192.168.1.9:50123/x=/ws'},
    });
    final answer = await post('/agent/reload', {'project': project.path});
    expect(answer?['via'], isNull);
    expect(reloader.calls, isEmpty);
  });

  test('the launch signal is enough to know the session', () async {
    await startHub(autoReload: false);
    await post('/signal', {'kind': 'launch', 'flutterSession': session});
    final answer = await post('/agent/reload', {'project': project.path});
    expect(answer?['reloaded'], isTrue);
  });

  group('DdsReloader', () {
    late HttpServer dds;
    late List<Map<String, Object?>> received;
    var fail = false;

    setUp(() async {
      // A stand-in for DDS: lists the Flutter tool's reloadSources service
      // when asked for the Service stream, and answers the calls.
      received = [];
      fail = false;
      dds = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      dds.listen((request) async {
        if (request.uri.path != '/token=/ws') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((data) {
          final message = (jsonDecode(data as String) as Map).cast<String, Object?>();
          received.add(message);
          final id = message['id'];
          switch (message['method']) {
            case 'streamListen':
              socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': {'type': 'Success'}}));
              socket.add(jsonEncode({
                'jsonrpc': '2.0',
                'method': 'streamNotify',
                'params': {
                  'streamId': 'Service',
                  'event': {'type': 'Event', 'kind': 'ServiceRegistered', 'service': 'reloadSources', 'method': 's0.reloadSources', 'alias': 'Flutter Tools'},
                },
              }));
            case 'getVM':
              socket.add(jsonEncode({
                'jsonrpc': '2.0',
                'id': id,
                'result': {
                  'type': 'VM',
                  'isolates': [
                    {'type': '@Isolate', 'id': 'isolates/7', 'name': 'main'},
                  ],
                },
              }));
            case 's0.reloadSources':
              socket.add(jsonEncode(fail
                  ? {
                      'jsonrpc': '2.0',
                      'id': id,
                      'error': {'code': -32000, 'message': 'Unable to reload sources', 'data': {'details': 'lib/home.dart:3: Error'}},
                    }
                  : {'jsonrpc': '2.0', 'id': id, 'result': {'type': 'Success'}}));
          }
        });
      });
    });

    tearDown(() async {
      await dds.close(force: true);
    });

    // The file's tearDown closes a hub and its project.
    setUp(() async => startHub(autoReload: false));

    test('calls the Flutter tool\'s reloadSources for the app\'s isolate', () async {
      final outcome = await const DdsReloader().reload(Uri.parse('ws://127.0.0.1:${dds.port}/token=/ws'), isolateId: 'isolates/old');
      expect(outcome.ok, isTrue);
      final call = received.firstWhere((message) => message['method'] == 's0.reloadSources');
      // The named isolate is gone (a hot restart): the main one is used.
      expect((call['params'] as Map)['isolateId'], 'isolates/7');
    });

    test('accepts the http form of the address', () async {
      final outcome = await const DdsReloader().reload(Uri.parse('http://127.0.0.1:${dds.port}/token=/'));
      expect(outcome.ok, isTrue);
    });

    test('passes on a compile error', () async {
      fail = true;
      final outcome = await const DdsReloader().reload(Uri.parse('ws://127.0.0.1:${dds.port}/token=/ws'));
      expect(outcome.ok, isFalse);
      expect(outcome.error, contains('lib/home.dart:3'));
    });

    test('says when the session cannot be reached', () async {
      final outcome = await const DdsReloader(connectTimeout: Duration(seconds: 1)).reload(Uri.parse('ws://127.0.0.1:1/x=/ws'));
      expect(outcome.ok, isFalse);
    });
  });
}
