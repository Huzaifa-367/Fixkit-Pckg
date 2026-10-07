import 'dart:async';
import 'dart:io';

import 'package:fixkit/src/protocol.dart';
import 'package:fixkit/src/server/hub.dart';
import 'package:fixkit/src/server/hub_client.dart';
import 'package:fixkit/src/server/paths.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late Directory project;
  late FakeHostTools tools;
  late FixHub hub;
  late HubClient client;

  setUp(() async {
    project = makeProject('hub');
    tools = FakeHostTools();
    hub = FixHub(
      port: 0,
      settings: const FixkitSettings(notifications: true),
      tools: tools,
      fallbackDelay: const Duration(milliseconds: 100),
      reloadWait: const Duration(milliseconds: 600),
      adbInterval: const Duration(hours: 1),
    );
    await hub.start();
    client = HubClient(port: hub.boundPort);
  });

  tearDown(() async {
    client.close();
    await hub.close();
    project.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>?> post(String path, Map<String, Object?> body) => client.call('POST', path, body: body);
  Future<Map<String, Object?>?> get(String path, Map<String, String> query) => client.call('GET', path, query: query);

  Future<void> register(String agent, {List<String>? projects}) =>
      post('/agent/register', {'agent': agent, 'name': agent, 'projects': projects ?? [project.path]});

  test('answers hello as a fixkit hub', () async {
    final hello = await client.hello();
    expect(hello?['fixkit'], isTrue);
    expect(hello?['version'], fixkitVersion);
  });

  test('a report with no agent is queued, copied to the clipboard and announced', () async {
    final sent = await post('/report', appReport(project));
    expect(sent?['id'], 'r1');
    expect(sent?['status'], FixStatus.queued);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    final status = await get('/status', {'id': 'r1'});
    expect(status?['status'], FixStatus.queued);
    expect('${status?['message']}', contains('No agent is connected'));
    expect(tools.clipboard.single, startsWith('Make it green\n\n[fix r1]'));
    expect(tools.notifications, hasLength(1));

    // The screenshot and the report are saved in the project.
    final files = Directory('${project.path}/.fixkit/reports').listSync().map((file) => file.path).toList();
    expect(files.where((path) => path.endsWith('.png')), hasLength(1));
    expect(files.where((path) => path.endsWith('.json')), hasLength(1));
    expect(File('${project.path}/.fixkit/.gitignore').existsSync(), isTrue);
  });

  test('a waiting agent gets the report, and a reload after completing makes it live', () async {
    await register('cursor');
    final next = get('/agent/next', {'agent': 'cursor', 'timeout': '5'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await post('/report', appReport(project));

    final delivered = await next;
    final report = delivered?['report'] as Map;
    expect(report['id'], 'r1');
    expect('${delivered?['prompt']}', contains('lib/home.dart:42'));
    expect(report['screenshot'], isNotNull);
    await post('/agent/ack', {'id': 'r1'});
    expect((await get('/status', {'id': 'r1'}))?['status'], FixStatus.fixing);

    final completing = post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Income is green now'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await get('/status', {'id': 'r1'}))?['status'], FixStatus.reloading);
    final signal = await post('/signal', {'kind': 'reload'});
    expect(signal?['id'], 'r1');
    expect(signal?['announce'], isTrue);

    final done = await completing;
    expect(done?['status'], FixStatus.live);
    final status = await get('/status', {'id': 'r1'});
    expect(status?['message'], 'Income is green now');
    // The app was told once already.
    expect(status?['announce'], isNull);
  });

  test('a fix with no reload ends as applied, and goes live on the next reload', () async {
    await register('vscode');
    final next = get('/agent/next', {'agent': 'vscode', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    await post('/agent/ack', {'id': 'r1'});

    final done = await post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Done'});
    expect(done?['status'], FixStatus.applied);
    await post('/signal', {'kind': 'reload'});
    expect((await get('/status', {'id': 'r1'}))?['status'], FixStatus.live);
  });

  test('a reload during the fix counts when the agent completes', () async {
    await register('claude');
    final next = get('/agent/next', {'agent': 'claude', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    await post('/agent/ack', {'id': 'r1'});
    await post('/signal', {'kind': 'reload'}); // hot reload on save
    final done = await post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Done'});
    expect(done?['status'], FixStatus.live);
  });

  test('reports go to the agent that has their project open', () async {
    final other = makeProject('other');
    addTearDown(() => other.deleteSync(recursive: true));
    await register('a', projects: [other.path]);
    await register('b');
    final nextA = get('/agent/next', {'agent': 'a', 'timeout': '2'});
    final nextB = get('/agent/next', {'agent': 'b', 'timeout': '5'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await post('/report', appReport(project));
    expect(((await nextB)?['report'] as Map)['id'], 'r1');
    expect(await nextA, isNull);
  });

  test('a queued report waits for its agent and is not copied while it is busy', () async {
    await register('agent');
    // First report: taken.
    final first = get('/agent/next', {'agent': 'agent', 'timeout': '5'});
    await post('/report', appReport(project, comment: 'first'));
    await first;
    await post('/agent/ack', {'id': 'r1'});
    // Second report while the agent is busy: queued, no clipboard.
    await post('/report', appReport(project, comment: 'second'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(tools.clipboard, isEmpty);
    expect((await get('/status', {'id': 'r2'}))?['status'], FixStatus.queued);
    // The next wait picks it up at once.
    final second = await get('/agent/next', {'agent': 'agent', 'timeout': '5'});
    expect(((second?['report']) as Map)['comment'], 'second');
  });

  test('a released report goes back to the queue', () async {
    await register('agent');
    final next = get('/agent/next', {'agent': 'agent', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    await post('/agent/release', {'id': 'r1'});
    expect((await get('/status', {'id': 'r1'}))?['status'], FixStatus.queued);
  });

  test('needs_input and failed are passed to the app', () async {
    await register('agent');
    final next = get('/agent/next', {'agent': 'agent', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    final done = await post('/agent/complete', {'id': 'r1', 'outcome': 'needs_input', 'summary': 'Which green?'});
    expect(done?['status'], FixStatus.needsInput);
    expect((await get('/status', {'id': 'r1'}))?['message'], 'Which green?');
  });

  test('an unregistered agent is asked to register', () async {
    expect(() => get('/agent/next', {'agent': 'nobody'}), throwsA(isA<HubException>()));
  });

  test('hot reload goes through a registered runner', () async {
    await post('/runner/register', {'project': project.path});
    final command = get('/runner/next', {'project': project.path, 'timeout': '5'});
    final reload = post('/agent/reload', {'project': project.path});
    expect((await command)?['command'], 'reload');
    await post('/signal', {'kind': 'reload'});
    final answer = await reload;
    expect(answer?['runner'], isTrue);
    expect(answer?['reloaded'], isTrue);
  });

  test('without a runner, hot reload says so', () async {
    final answer = await post('/agent/reload', {'project': project.path});
    expect(answer?['runner'], isFalse);
  });

  test('state lists agents and reports', () async {
    await register('agent');
    await post('/report', appReport(project));
    final state = await get('/admin/state', const {});
    expect((state?['agents'] as List).single['name'], 'agent');
    expect((state?['reports'] as List).single['id'], 'r1');
  });

  test('a protocol newer than the hub is refused', () async {
    expect(
      () => post('/report', {...appReport(project), 'protocol': fixkitProtocol + 1}),
      throwsA(isA<HubException>()),
    );
  });

  test('the app is told about a fresh fix when it relaunches', () async {
    await register('agent');
    final next = get('/agent/next', {'agent': 'agent', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    unawaited(post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Done'}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final launch = await post('/signal', {'kind': 'launch'});
    expect(launch?['status'], FixStatus.live);
    expect(launch?['announce'], isTrue);
    final again = await post('/signal', {'kind': 'launch'});
    expect(again?['id'], isNull);
  });

  test('the activity feed follows the report and notices the agent\'s edits', () async {
    final source = File('${project.path}/lib/home.dart')..writeAsStringSync('// home\n');
    source.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 1)));
    await register('Cursor');
    final next = get('/agent/next', {'agent': 'Cursor', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    await post('/agent/ack', {'id': 'r1'});

    // The agent edits the pressed widget's file; the hub notices by itself.
    source.writeAsStringSync('// home, fixed\n');
    source.setLastModifiedSync(DateTime.now());
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    await post('/agent/progress', {'id': 'r1', 'message': 'Fixing the colour test'});

    final completing = post('/agent/complete', {'id': 'r1', 'outcome': 'fixed', 'summary': 'Income is green'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await post('/signal', {'kind': 'reload'});
    final done = await completing;

    final texts = [for (final line in done?['activity'] as List) (line as Map)['text']];
    expect(texts, [
      'Sent to Cursor',
      'Reading lib/home.dart:42',
      'Edited home.dart',
      'Fixing the colour test',
      'Hot reloading',
      'Fix is on screen',
    ]);
    expect(((done?['activity'] as List).last as Map)['kind'], 'done');
    expect(done?['agent'], 'Cursor');
    expect(done?['comment'], 'Make it green');
  });

  test('presence names the agent and whether it is watching', () async {
    expect((await get('/presence', const {}))?['agent'], isNull);
    await register('Antigravity');
    final idle = await get('/presence', const {});
    expect(idle?['agent'], 'Antigravity');
    expect(idle?['watching'], isFalse);
    final next = get('/agent/next', {'agent': 'Antigravity', 'timeout': '2'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect((await get('/presence', const {}))?['watching'], isTrue);
    await next;
  });

  test('presence names the project\'s agent, keeps it watching between polls, and knows when it is busy', () async {
    final other = makeProject('presence_other');
    addTearDown(() => other.deleteSync(recursive: true));
    await register('Antigravity', projects: [other.path]);
    await register('Cursor');
    final file = location(project, 'lib/home.dart');

    // Cursor has this project open: it is named, even though Antigravity registered first.
    final first = get('/agent/next', {'agent': 'Cursor', 'timeout': '1'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    var presence = await get('/presence', {'file': file});
    expect(presence?['agent'], 'Cursor');
    expect(presence?['watching'], isTrue);

    // Between two polls it still counts as watching.
    await first;
    presence = await get('/presence', {'file': file});
    expect(presence?['watching'], isTrue);

    // Taking a report makes it busy with it.
    final next = get('/agent/next', {'agent': 'Cursor', 'timeout': '5'});
    await post('/report', appReport(project));
    await next;
    presence = await get('/presence', {'file': file});
    expect(presence?['busy'], isTrue);
    expect(presence?['watching'], isFalse);
    expect(presence?['version'], fixkitVersion);
  });

  test('hello lists what the hub can do', () async {
    final hello = await client.hello();
    expect(hello?['features'], containsAll(['activity', 'presence']));
  });

  test('a queued report says why in its activity', () async {
    final sent = await post('/report', appReport(project));
    final texts = [for (final line in sent?['activity'] as List) (line as Map)['text']];
    expect(texts, ['Waiting for an agent to watch']);
  });
}
