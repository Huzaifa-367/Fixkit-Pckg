import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../protocol.dart';
import 'hub_client.dart';
import 'paths.dart';

/// The MCP protocol versions this server speaks. It answers with the client's
/// version when it is one of these, else with the first.
const _protocolVersions = ['2025-06-18', '2025-11-25', '2025-03-26', '2024-11-05'];

/// What every agent is told about fixkit when it connects.
const String mcpInstructions = '''
fixkit connects this chat to a Flutter app running in debug mode. When the person long-presses a widget in the app and types what is wrong, that becomes a fix report.

When the person says "watch for fixes", "fixkit" or "/fixkit", or asks you to handle reports from the app:
1. Call wait_for_fix_report. It returns the request, where the pressed widget is constructed in the source, the widgets around it, and a screenshot. If it answers that there is no report yet, call it again; keep watching until the person asks you to stop.
2. Treat the person's words as the task: a bug ("button is shifted") or a change ("make this green").
3. Start at the first file:line of the widget path: the selected widget is constructed there, and the lines after it are its parents. Usually that is the widget under the finger; when the report says the person widened the selection (to a Row, a Column, a card), the request is about that whole widget. Text built from data (amounts, dates) is easier to find through the fixed text near it.
4. Make the smallest change that does what was asked. Do not refactor or reformat. The app shows the person your progress live (it notices your edits by itself); for a longer fix you may also call fix_progress with a few words, like "Fixing the colour test".
5. Open the screenshot only when the words and the code leave the request unclear.
6. Put the change on screen: call hot_reload. If it says fixkit cannot reload this app, use a hot_reload tool from the Dart/Flutter MCP server if you have one; otherwise hot reload on save does it.
7. Call complete_fix with the report id, the outcome and a one-sentence summary; the person sees the summary in the app. To ask a question instead, use the outcome needs_input and ask in the chat.
8. Call wait_for_fix_report again.''';

const String _watchPrompt = '''
Watch for fix reports from my running Flutter app (fixkit) and handle each one:
call wait_for_fix_report, make the smallest fix the report asks for starting at the file and line it gives, hot reload (hot_reload), call complete_fix with a one-sentence summary, then call wait_for_fix_report again. Keep going until I say stop.''';

/// The MCP server an editor starts over stdio. It registers with the hub as
/// an agent and turns the hub's reports into tool results.
class FixkitMcpServer {
  FixkitMcpServer({
    required Stream<List<int>> input,
    required IOSink output,
    this.project,
    this.wildcard = false,
    HubClient? hub,
    this.log,
  })  : _input = input,
        _output = output,
        hub = hub ?? HubClient();

  final Stream<List<int>> _input;
  final IOSink _output;

  /// The project the launcher belongs to; used until the editor lists its
  /// workspace roots.
  final String? project;

  /// Take reports from any project (a global config, as Antigravity uses).
  final bool wildcard;
  final HubClient hub;
  final void Function(String message)? log;

  final String agentId = List.generate(12, (_) => Random.secure().nextInt(16).toRadixString(16)).join();
  String _clientName = 'agent';
  bool _clientHasRoots = false;
  List<String> _roots = const [];
  bool _registered = false;
  Timer? _heartbeat;
  int _nextId = 0;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final Set<Object> _cancelled = {};

  Set<String> get projects => {
        ..._roots,
        if (_roots.isEmpty && project != null) normalizePath(project!),
      };

  /// Serves until the editor closes stdin.
  Future<void> serve() async {
    final lines = _input.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      Object? message;
      try {
        message = jsonDecode(line);
      } catch (_) {
        _send({'jsonrpc': '2.0', 'id': null, 'error': {'code': -32700, 'message': 'Parse error'}});
        continue;
      }
      if (message is List) {
        for (final item in message) {
          if (item is Map) unawaited(_handle(item.cast<String, Object?>()));
        }
      } else if (message is Map) {
        unawaited(_handle(message.cast<String, Object?>()));
      }
    }
    await shutdown();
  }

  Future<void> shutdown() async {
    _closed = true;
    _heartbeat?.cancel();
    if (_registered) {
      try {
        await hub.call('POST', '/agent/unregister', body: {'agent': agentId}, timeout: const Duration(seconds: 2));
      } catch (_) {}
    }
    hub.close();
  }

  void _send(Map<String, Object?> message) {
    _output.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  void _result(Object? id, Object? result) => _send({'jsonrpc': '2.0', 'id': id, 'result': result});

  void _error(Object? id, int code, String message) =>
      _send({'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message}});

  void _notify(String method, Map<String, Object?> params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  /// Sends a request to the client and waits for its answer.
  Future<Map<String, Object?>> _request(String method) {
    final id = 'fixkit-${_nextId++}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method});
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(id);
      return const {};
    });
  }

  Future<void> _handle(Map<String, Object?> message) async {
    final method = message['method'];
    final id = message['id'];

    // An answer to one of our requests.
    if (method == null) {
      final completer = _pending.remove('$id');
      if (completer != null && !completer.isCompleted) {
        final result = message['result'];
        completer.complete(result is Map ? result.cast<String, Object?>() : const {});
      }
      return;
    }

    final params = message['params'] is Map ? (message['params'] as Map).cast<String, Object?>() : <String, Object?>{};
    try {
      switch (method) {
        case 'initialize':
          _result(id, _initialize(params));
          unawaited(_connect());
          return;
        case 'notifications/initialized':
          await _initialized();
          return;
        case 'notifications/roots/list_changed':
          await _loadRoots();
          return;
        case 'notifications/cancelled':
          final requestId = params['requestId'];
          if (requestId != null) _cancelled.add(requestId);
          return;
        case 'ping':
          return _result(id, const <String, Object?>{});
        case 'tools/list':
          return _result(id, {'tools': _tools});
        case 'tools/call':
          return _result(id, await _callTool(id, params));
        case 'prompts/list':
          return _result(id, {'prompts': _prompts});
        case 'prompts/get':
          return _result(id, _getPrompt(params));
        case 'resources/list':
          return _result(id, {'resources': const []});
        case 'resources/templates/list':
          return _result(id, {'resourceTemplates': const []});
      }
      if (id != null) _error(id, -32601, 'Method not found: $method');
    } catch (error) {
      if (id != null) _error(id, -32603, '$error');
    }
  }

  Map<String, Object?> _initialize(Map<String, Object?> params) {
    final requested = params['protocolVersion'];
    final capabilities = params['capabilities'];
    _clientHasRoots = capabilities is Map && capabilities['roots'] != null;
    final info = params['clientInfo'];
    if (info is Map && info['name'] is String) _clientName = agentDisplayName(info['name'] as String);

    return {
      'protocolVersion': _protocolVersions.contains(requested) ? requested : _protocolVersions.first,
      'capabilities': {
        'tools': {'listChanged': false},
        'prompts': {'listChanged': false},
      },
      'serverInfo': {'name': 'fixkit', 'title': 'fixkit', 'version': fixkitVersion},
      'instructions': mcpInstructions,
    };
  }

  /// Registers at once, so the app sees the agent as soon as the editor has
  /// started fixkit, then again with the editor's folders once it lists them.
  Future<void> _connect() => _connecting ??= () async {
        await _register();
        if (!_closed) _heartbeat ??= Timer.periodic(const Duration(seconds: 15), (_) => _register());
      }();

  Future<void>? _connecting;
  bool _closed = false;

  Future<void> _initialized() async {
    await _connect();
    if (_clientHasRoots) await _loadRoots();
  }

  /// The folders the editor has open. Reports from apps in them come here.
  Future<void> _loadRoots() async {
    if (!_clientHasRoots) return;
    try {
      final result = await _request('roots/list');
      final roots = result['roots'];
      if (roots is List) {
        _roots = [
          for (final root in roots)
            if (root is Map && root['uri'] is String)
              if (pathFromLocation(root['uri'] as String) case final String path) normalizePath(path),
        ];
      }
    } catch (error) {
      log?.call('roots/list failed: $error');
    }
    await _register();
  }

  Future<void> _register() async {
    if (_closed) return;
    try {
      await hub.ensure();
      await hub.call('POST', '/agent/register', body: {
        'agent': agentId,
        'name': _clientName,
        'projects': projects.toList(),
        'wildcard': wildcard && projects.isEmpty,
      });
      _registered = true;
    } catch (error) {
      log?.call('could not register with the hub: $error');
    }
  }

  // ---- Tools -----------------------------------------------------------------

  static const List<Map<String, Object?>> _tools = [
    {
      'name': 'wait_for_fix_report',
      'title': 'Wait for a fix report',
      'description':
          'Watch for fix reports from the running Flutter app (fixkit). Use it when the person says "watch for fixes", '
              '"fixkit" or asks you to handle reports from the app. Waits until someone long-presses a widget in the app '
              'and describes a problem, then returns their words, where the widget is constructed in the source (file:line), '
              'the widgets around it, and a screenshot. After fixing, call complete_fix, then call this again. '
              'If it answers that there is no report yet, call it again to keep watching.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'timeout_seconds': {
            'type': 'integer',
            'minimum': 5,
            'maximum': 600,
            'description': 'How long to wait before answering "no report yet". Default 45.',
          },
          'include_screenshot': {
            'type': 'boolean',
            'description': 'Attach the screenshot as an image. Default true.',
          },
        },
      },
    },
    {
      'name': 'complete_fix',
      'title': 'Finish a fix report',
      'description':
          'Say how a fix report ended. The summary appears in the app, under the steps of its agent card. For outcome "fixed", fixkit waits '
              'briefly for the app to hot reload and answers whether the fix is on screen.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'The report id, like "r3".'},
          'outcome': {
            'type': 'string',
            'enum': ['fixed', 'failed', 'needs_input'],
            'description': '"fixed", "failed", or "needs_input" when you ask the person something in the chat.',
          },
          'summary': {'type': 'string', 'description': 'One sentence: what was wrong and what changed.'},
        },
        'required': ['id', 'outcome', 'summary'],
      },
    },
    {
      'name': 'fix_progress',
      'title': 'Show progress in the app',
      'description':
          'Optional: tell the person what you are doing on a fix report, in a few words ("Fixing the colour test"). '
              'It appears live in the app under the report. fixkit already shows when you take the report, edit its '
              'files, reload and finish, so use this only for longer fixes.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'The report id, like "r3".'},
          'message': {'type': 'string', 'description': 'A few words, under 60 characters.'},
        },
        'required': ['id', 'message'],
      },
    },
    {
      'name': 'hot_reload',
      'title': 'Hot reload the app',
      'description':
          'Hot reload the running Flutter app so a fix shows up. Works when the app was started with `dart run fixkit run`; '
              'otherwise it explains what to use instead (a Dart MCP hot_reload tool, or hot reload on save).',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
    {
      'name': 'get_fix_report',
      'title': 'Get a fix report',
      'description': 'Fetch a fix report again by id, with its screenshot.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'The report id, like "r3".'},
        },
        'required': ['id'],
      },
    },
    {
      'name': 'list_fix_reports',
      'title': 'List fix reports',
      'description': 'List recent fix reports for this project and their status.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
    },
  ];

  Future<Map<String, Object?>> _callTool(Object? requestId, Map<String, Object?> params) async {
    final name = params['name'];
    final args = params['arguments'] is Map ? (params['arguments'] as Map).cast<String, Object?>() : <String, Object?>{};
    final meta = params['_meta'];
    final progressToken = meta is Map ? meta['progressToken'] : null;

    try {
      switch (name) {
        case 'wait_for_fix_report':
          return await _waitForReport(requestId, args, progressToken);
        case 'complete_fix':
          return await _completeFix(args);
        case 'fix_progress':
          return await _fixProgress(args);
        case 'hot_reload':
          return await _hotReload();
        case 'get_fix_report':
          return await _getReport(args);
        case 'list_fix_reports':
          return await _listReports();
      }
      return _toolError('Unknown tool: $name');
    } on HubException catch (error) {
      return _toolError(error.message);
    } on TimeoutException {
      return _toolError('The fixkit hub did not answer in time. Try again; `dart run fixkit doctor` shows what is wrong.');
    } on SocketException catch (error) {
      return _toolError('Could not reach the fixkit hub: ${error.message}');
    }
  }

  Map<String, Object?> _text(String text) => {
        'content': [
          {'type': 'text', 'text': text},
        ],
      };

  Map<String, Object?> _toolError(String text) => {
        'content': [
          {'type': 'text', 'text': text},
        ],
        'isError': true,
      };

  Future<Map<String, Object?>> _waitForReport(
    Object? requestId,
    Map<String, Object?> args,
    Object? progressToken,
  ) async {
    final seconds = (args['timeout_seconds'] is int ? args['timeout_seconds'] as int : 45).clamp(5, 600);
    final screenshot = args['include_screenshot'] != false;
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    if (!_registered) await _register();
    if (!_registered) {
      return _toolError('fixkit could not start its hub. Run `dart run fixkit doctor` in the project for details.');
    }

    var tick = 0;
    while (true) {
      if (_cancelled.remove(requestId)) return _text('Cancelled.');
      final left = deadline.difference(DateTime.now()).inSeconds;
      if (left <= 0) break;
      if (progressToken != null) {
        _notify('notifications/progress', {
          'progressToken': progressToken,
          'progress': ++tick,
          'message': 'Waiting for a fix report from the app',
        });
      }

      Map<String, Object?>? answer;
      try {
        answer = await hub.call(
          'GET',
          '/agent/next',
          query: {'agent': agentId, 'timeout': '${min(left, 20)}'},
          timeout: Duration(seconds: min(left, 20) + 10),
        );
      } on HubException catch (error) {
        if (error.message.contains('register first')) {
          await _register();
          continue;
        }
        rethrow;
      } on SocketException {
        // The hub went away (an update, a restart): start it again.
        await _register();
        continue;
      }
      if (answer == null) continue;

      final report = answer['report'];
      if (report is! Map) continue;
      final id = '${report['id']}';
      if (_cancelled.remove(requestId)) {
        await hub.call('POST', '/agent/release', body: {'id': id});
        return _text('Cancelled.');
      }
      await hub.call('POST', '/agent/ack', body: {'id': id});
      return _reportResult(answer, includeScreenshot: screenshot);
    }

    return _text(
      'No fix report yet. To keep watching, call wait_for_fix_report again. '
      '(The person long-presses a widget in the running app and types what is wrong.)',
    );
  }

  Map<String, Object?> _reportResult(Map<String, Object?> answer, {bool includeScreenshot = true}) {
    final report = (answer['report'] as Map).cast<String, Object?>();
    final id = report['id'];
    final prompt = '${answer['prompt']}';
    final content = <Map<String, Object?>>[
      {
        'type': 'text',
        'text': '$prompt\n\n'
            'When done: call complete_fix with id "$id", then call wait_for_fix_report to keep watching.',
      },
    ];
    final path = report['screenshot'];
    if (includeScreenshot && path is String) {
      try {
        final bytes = File(path).readAsBytesSync();
        content.add({'type': 'image', 'data': base64Encode(bytes), 'mimeType': 'image/png'});
      } catch (_) {}
    }
    return {'content': content};
  }

  Future<Map<String, Object?>> _completeFix(Map<String, Object?> args) async {
    final id = args['id'];
    if (id is! String || id.isEmpty) return _toolError('Give the report id, like "r3".');
    final outcome = args['outcome'] is String ? args['outcome'] as String : 'fixed';
    final answer = await hub.call(
      'POST',
      '/agent/complete',
      body: {'id': id, 'outcome': outcome, 'summary': args['summary']},
      timeout: const Duration(seconds: 30),
    );
    final status = '${answer?['status']}';
    final next = 'Call wait_for_fix_report to keep watching.';
    switch (status) {
      case FixStatus.live:
        return _text('$id is live: the app reloaded with the fix and shows your summary. $next');
      case FixStatus.applied:
        return _text(
          '$id is fixed in code, but the app has not reloaded yet. Hot reload it (hot_reload, a Dart MCP hot_reload '
          'tool, or save the file); fixkit marks it live when the app reloads. $next',
        );
      case FixStatus.needsInput:
        return _text('$id is waiting for the person: the app tells them to answer in the chat. Ask your question here.');
      case FixStatus.failed:
        return _text('$id is marked as not fixed; the app shows your summary. $next');
    }
    return _text('$id is now $status. $next');
  }

  Future<Map<String, Object?>> _fixProgress(Map<String, Object?> args) async {
    final id = args['id'];
    final message = args['message'];
    if (id is! String || message is! String || message.trim().isEmpty) {
      return _toolError('Give the report id and a short message.');
    }
    final answer = await hub.call('POST', '/agent/progress', body: {'id': id, 'message': message});
    return answer?['ok'] == true
        ? _text('Shown in the app.')
        : _toolError('No report $id, or it is already finished.');
  }

  Future<Map<String, Object?>> _hotReload() async {
    final project = projects.isEmpty ? null : projects.first;
    final answer = await hub.call(
      'POST',
      '/agent/reload',
      body: {'project': project},
      timeout: const Duration(seconds: 20),
    );
    if (answer?['runner'] != true) {
      return _text(
        'This app was not started with `dart run fixkit run`, so fixkit cannot reload it itself. '
        'Use a hot_reload tool from the Dart/Flutter MCP server if you have one; otherwise saving the edited files '
        'hot reloads an app run from VS Code, Cursor or Antigravity. fixkit notices the reload by itself.',
      );
    }
    if (answer?['reloaded'] == true) return _text('Hot reloaded: the app confirmed the reload.');
    return _text(
      'Asked `fixkit run` to hot reload, but the app did not confirm within 10 seconds. '
      'The terminal running it may show a compile error.',
    );
  }

  Future<Map<String, Object?>> _getReport(Map<String, Object?> args) async {
    final id = args['id'];
    if (id is! String || id.isEmpty) return _toolError('Give the report id, like "r3".');
    final answer = await hub.call('GET', '/agent/report', query: {'id': id});
    if (answer == null) return _toolError('No report $id.');
    return _reportResult(answer);
  }

  Future<Map<String, Object?>> _listReports() async {
    final answer = await hub.call('GET', '/agent/list', query: {'agent': agentId});
    final reports = answer?['reports'];
    if (reports is! List || reports.isEmpty) return _text('No fix reports yet.');
    final lines = [
      for (final report in reports.reversed.take(30))
        if (report is Map) '${report['id']}  ${report['status']}  "${report['comment']}"  ${report['headline']}',
    ];
    return _text(lines.join('\n'));
  }

  // ---- Prompts ---------------------------------------------------------------

  static const List<Map<String, Object?>> _prompts = [
    {
      'name': 'fixkit',
      'title': 'Watch for fixes',
      'description': 'Handle fix reports from the running Flutter app until told to stop.',
      'arguments': <Object?>[],
    },
  ];

  Map<String, Object?> _getPrompt(Map<String, Object?> params) {
    if (params['name'] != 'fixkit') throw ArgumentError('Unknown prompt: ${params['name']}');
    return {
      'description': 'Watch for fixes from the running Flutter app',
      'messages': [
        {
          'role': 'user',
          'content': {'type': 'text', 'text': _watchPrompt},
        },
      ],
    };
  }
}

/// How the app names an agent: `Cursor` rather than `cursor-vscode`.
String agentDisplayName(String client) {
  final name = client.toLowerCase();
  if (name.contains('cursor')) return 'Cursor';
  if (name.contains('antigravity')) return 'Antigravity';
  if (name.contains('windsurf') || name.contains('codeium') || name.contains('cascade')) return 'Windsurf';
  if (name.contains('claude-ai') || name.contains('claude desktop')) return 'Claude';
  if (name.contains('claude')) return 'Claude Code';
  if (name.contains('gemini')) return 'Gemini CLI';
  if (name.contains('copilot') || name.contains('visual studio code') || name.contains('vscode')) return 'VS Code';
  if (RegExp(r'(^|[^a-z])zed([^a-z]|$)').hasMatch(name)) return 'Zed';
  if (name.contains('jetbrains') || name.contains('intellij') || name.contains('android studio')) return 'Android Studio';
  return client;
}

/// Runs the MCP server on stdin/stdout. Anything else goes to stderr, since
/// stdout carries the protocol.
Future<void> runMcpServer({String? project, bool wildcard = false}) async {
  final server = FixkitMcpServer(
    input: stdin,
    output: stdout,
    project: project,
    wildcard: wildcard,
    log: (message) => stderr.writeln('fixkit: $message'),
  );
  await server.serve();
  await stdout.flush();
}
