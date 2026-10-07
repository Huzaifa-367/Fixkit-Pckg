import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fixkit/src/server/hub.dart';
import 'package:fixkit/src/server/hub_client.dart';
import 'package:fixkit/src/server/mcp.dart';
import 'package:fixkit/src/server/paths.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Drives a [FixkitMcpServer] over in-memory stdio, as an editor would.
class FakeEditor {
  FakeEditor(this.server, this._input, Stream<Map<String, Object?>> output) {
    output.listen((message) {
      final id = message['id'];
      if (message['method'] == null && _waiting.containsKey(id)) {
        _waiting.remove(id)!.complete(message);
      } else {
        received.add(message);
      }
    });
  }

  final FixkitMcpServer server;
  final StreamController<List<int>> _input;
  final Map<Object?, Completer<Map<String, Object?>>> _waiting = {};
  final List<Map<String, Object?>> received = [];
  int _id = 0;

  void send(Map<String, Object?> message) => _input.add(utf8.encode('${jsonEncode(message)}\n'));

  Future<Map<String, Object?>> request(String method, [Map<String, Object?>? params]) {
    final id = ++_id;
    final completer = Completer<Map<String, Object?>>();
    _waiting[id] = completer;
    send({'jsonrpc': '2.0', 'id': id, 'method': method, if (params != null) 'params': params});
    return completer.future.timeout(const Duration(seconds: 20));
  }

  void notify(String method, [Map<String, Object?>? params]) =>
      send({'jsonrpc': '2.0', 'method': method, if (params != null) 'params': params});
}

void main() {
  late Directory project;
  late FixHub hub;
  late StreamController<List<int>> input;
  late FakeEditor editor;

  setUp(() async {
    project = makeProject('mcp');
    hub = FixHub(
      port: 0,
      settings: const FixkitSettings(clipboard: false, notifications: false),
      tools: FakeHostTools(),
      reloadWait: const Duration(milliseconds: 500),
      adbInterval: const Duration(hours: 1),
    );
    await hub.start();

    input = StreamController<List<int>>();
    final output = StreamController<List<int>>();
    final lines = output.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) => (jsonDecode(line) as Map).cast<String, Object?>());
    final server = FixkitMcpServer(
      input: input.stream,
      output: IOSink(output),
      project: project.path,
      hub: HubClient(port: hub.boundPort),
    );
    editor = FakeEditor(server, input, lines);
    unawaited(server.serve());
  });

  tearDown(() async {
    await input.close();
    await hub.close();
    project.deleteSync(recursive: true);
  });

  Future<void> initialize({Map<String, Object?> capabilities = const {}}) async {
    final answer = await editor.request('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': capabilities,
      'clientInfo': {'name': 'test-editor', 'version': '1.0'},
    });
    expect((answer['result'] as Map)['protocolVersion'], '2025-06-18');
    editor.notify('notifications/initialized');
    for (var i = 0; i < 50 && hub.agents.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(hub.agents.values.single.name, 'test-editor');
  }

  test('initialize describes the server and how to use it', () async {
    final answer = await editor.request('initialize', {
      'protocolVersion': '2024-11-05',
      'capabilities': <String, Object?>{},
      'clientInfo': {'name': 'old-editor'},
    });
    final result = answer['result'] as Map;
    expect(result['protocolVersion'], '2024-11-05');
    expect((result['serverInfo'] as Map)['name'], 'fixkit');
    expect('${result['instructions']}', contains('wait_for_fix_report'));
    expect((result['capabilities'] as Map).keys, containsAll(['tools', 'prompts']));
  });

  test('an unknown protocol version gets the newest one this server speaks', () async {
    final answer = await editor.request('initialize', {'protocolVersion': '1999-01-01', 'capabilities': {}});
    expect((answer['result'] as Map)['protocolVersion'], '2025-06-18');
  });

  test('lists its tools and its prompt', () async {
    await initialize();
    final tools = ((await editor.request('tools/list'))['result'] as Map)['tools'] as List;
    expect(tools.map((tool) => (tool as Map)['name']),
        ['wait_for_fix_report', 'complete_fix', 'fix_progress', 'hot_reload', 'get_fix_report', 'list_fix_reports']);
    final prompts = ((await editor.request('prompts/list'))['result'] as Map)['prompts'] as List;
    expect((prompts.single as Map)['name'], 'fixkit');
    final prompt = (await editor.request('prompts/get', {'name': 'fixkit'}))['result'] as Map;
    expect('${((prompt['messages'] as List).single as Map)['content']}', contains('wait_for_fix_report'));
  });

  test('wait_for_fix_report returns the report with its screenshot, complete_fix finishes it', () async {
    await initialize();
    final waiting = editor.request('tools/call', {
      'name': 'wait_for_fix_report',
      'arguments': {'timeout_seconds': 15},
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final app = HubClient(port: hub.boundPort);
    addTearDown(app.close);
    await app.call('POST', '/report', body: appReport(project));

    final result = (await waiting)['result'] as Map;
    final content = result['content'] as List;
    final text = '${(content.first as Map)['text']}';
    expect(text, startsWith('Make it green'));
    expect(text, contains('[fix r1]'));
    expect(text, contains('lib/home.dart:42'));
    expect(text, contains('call complete_fix with id "r1"'));
    expect((content.last as Map)['type'], 'image');
    expect((content.last as Map)['mimeType'], 'image/png');
    expect(hub.reports['r1']!.acknowledged, isTrue);

    final completing = editor.request('tools/call', {
      'name': 'complete_fix',
      'arguments': {'id': 'r1', 'outcome': 'fixed', 'summary': 'Income is green'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await app.call('POST', '/signal', body: {'kind': 'reload'});
    final done = (await completing)['result'] as Map;
    expect('${((done['content'] as List).single as Map)['text']}', contains('r1 is live'));
  });

  test('wait_for_fix_report says when nothing came', () async {
    await initialize();
    final result = (await editor.request('tools/call', {
      'name': 'wait_for_fix_report',
      'arguments': {'timeout_seconds': 5},
    }))['result'] as Map;
    expect('${((result['content'] as List).single as Map)['text']}', contains('No fix report yet'));
  });

  test('hot_reload explains the alternatives without a runner', () async {
    await initialize();
    final result = (await editor.request('tools/call', {'name': 'hot_reload', 'arguments': {}}))['result'] as Map;
    expect('${((result['content'] as List).single as Map)['text']}', contains('fixkit run'));
  });

  test('uses the workspace roots the editor lists', () async {
    final workspace = makeProject('mcp_roots');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final answering = editor.received.length;
    unawaited(initialize(capabilities: {'roots': {'listChanged': true}}).catchError((_) {}));
    // The server asks for the roots; answer like an editor would.
    Map<String, Object?>? ask;
    for (var i = 0; i < 100 && ask == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ask = editor.received.skip(answering).where((message) => message['method'] == 'roots/list').firstOrNull;
    }
    expect(ask, isNotNull);
    editor.send({
      'jsonrpc': '2.0',
      'id': ask!['id'],
      'result': {
        'roots': [
          {'uri': Uri.directory(workspace.path).toString(), 'name': 'mcp_roots'},
        ],
      },
    });
    final expected = {normalizePath(workspace.path)};
    for (var i = 0; i < 100 && !setEquals(hub.agents.values.singleOrNull?.projects, expected); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(hub.agents.values.single.projects, expected);
  });

  test('unknown methods get a JSON-RPC error', () async {
    final answer = await editor.request('does/not/exist');
    expect((answer['error'] as Map)['code'], -32601);
  });

  test('unknown tools are tool errors', () async {
    await initialize();
    final result = (await editor.request('tools/call', {'name': 'nope', 'arguments': {}}))['result'] as Map;
    expect(result['isError'], isTrue);
  });

  test('agents get names people know', () {
    expect(agentDisplayName('cursor-vscode'), 'Cursor');
    expect(agentDisplayName('Visual Studio Code'), 'VS Code');
    expect(agentDisplayName('antigravity-client'), 'Antigravity');
    expect(agentDisplayName('claude-code'), 'Claude Code');
    expect(agentDisplayName('gemini-cli-mcp-client'), 'Gemini CLI');
    expect(agentDisplayName('test-editor'), 'test-editor');
  });

  test('the agent is registered as soon as the editor initializes', () async {
    await editor.request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'cursor-vscode'}});
    for (var i = 0; i < 50 && hub.agents.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(hub.agents.values.single.name, 'Cursor');
  });

  test('mcpInstructions mention the full loop', () {
    for (final tool in ['wait_for_fix_report', 'hot_reload', 'complete_fix']) {
      expect(mcpInstructions, contains(tool));
    }
  });
}
