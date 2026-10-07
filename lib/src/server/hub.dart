import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'host_tools.dart';
import 'paths.dart';
import 'report.dart';

/// An agent's MCP server, registered with the hub.
class AgentSession {
  AgentSession({required this.id, required this.name, required this.projects, required this.wildcard});

  final String id;
  String name;

  /// Project roots the agent has open. Reports from these go to it first.
  Set<String> projects;

  /// Takes reports from any project no other agent claims.
  bool wildcard;
  DateTime lastSeen = DateTime.now();

  /// A long poll waiting for the next report.
  Completer<FixReport?>? waiter;

  /// When its last long poll ended: an agent loops wait → wait, so a short
  /// gap between two polls still counts as watching.
  DateTime? lastWaitEnd;

  bool get isWaiting => waiter != null && !waiter!.isCompleted;

  bool isWatching(DateTime now) =>
      isWaiting || (lastWaitEnd != null && now.difference(lastWaitEnd!) < const Duration(seconds: 30));

  bool claims(String? root) {
    if (root == null) return false;
    return projects.any((project) => isWithin(project, root) || isWithin(root, project));
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'projects': projects.toList(),
        'wildcard': wildcard,
        'waiting': isWaiting,
        'watching': isWatching(DateTime.now()),
        'lastSeen': lastSeen.toIso8601String(),
      };
}

/// A `fixkit run` process: it can hot reload one project's app.
class RunnerSession {
  RunnerSession(this.project);

  final String project;
  DateTime lastSeen = DateTime.now();
  final List<String> pending = [];
  Completer<String?>? waiter;

  Map<String, Object?> toJson() => {'project': project, 'lastSeen': lastSeen.toIso8601String()};
}

/// The machine-wide hub. Apps send reports to it on port 4747; agents' MCP
/// servers long-poll it for reports; `fixkit run` long-polls it for reloads.
///
/// One hub serves every project and every editor on the computer: reports are
/// routed to the agent that has the pressed widget's project open.
class FixHub {
  FixHub({
    this.port = fixkitPort,
    FixkitSettings? settings,
    HostTools? tools,
    this.idleTimeout = const Duration(minutes: 30),
    this.ackTimeout = const Duration(seconds: 12),
    this.fallbackDelay = const Duration(seconds: 3),
    this.reloadWait = const Duration(seconds: 10),
    this.adbInterval = const Duration(seconds: 3),
    this.staleAfter = const Duration(minutes: 15),
    Log? log,
  })  : settings = settings ?? FixkitSettings.load(),
        _log = log ?? ((_) {}),
        tools = tools ?? HostTools(log: log);

  final int port;
  final FixkitSettings settings;
  final HostTools tools;
  final Duration idleTimeout;
  final Duration ackTimeout;
  final Duration fallbackDelay;
  final Duration reloadWait;
  final Duration adbInterval;

  /// How long a report may sit with an agent that does nothing.
  final Duration staleAfter;
  final Log _log;

  final List<HttpServer> _servers = [];
  final Map<String, FixReport> reports = {};
  final Map<String, AgentSession> agents = {};
  final Map<String, RunnerSession> runners = {};
  final ProjectFinder _finder = ProjectFinder();
  final List<Completer<void>> _reloadWaiters = [];
  final Completer<void> _closed = Completer<void>();
  late final String _token = lanToken();
  int _seq = 0;
  DateTime _lastActivity = DateTime.now();
  Timer? _housekeeping;
  Timer? _adbTimer;
  Timer? _editTimer;
  bool _closing = false;

  /// Watches the project's `lib` while an agent works on a report, so an
  /// edit to any file shows on the app's card at once.
  final Map<String, _ProjectWatch> _projectWatches = {};
  bool _adbBusy = false;
  String? _lanAddress;

  /// Completes when the hub has shut down.
  Future<void> get done => _closed.future;

  int get boundPort => _servers.isEmpty ? port : _servers.first.port;

  /// Binds the port. Throws a [SocketException] when it is taken.
  Future<void> start() async {
    if (settings.lan) {
      _servers.add(await HttpServer.bind(InternetAddress.anyIPv4, port));
      _lanAddress = await tools.lanAddress();
    } else {
      _servers.add(await HttpServer.bind(InternetAddress.loopbackIPv4, port));
    }
    final actual = _servers.first.port;
    try {
      // `adb reverse` and some tools reach "localhost" over IPv6.
      _servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, actual, v6Only: true));
    } catch (_) {}
    for (final server in _servers) {
      server.listen(_serve, onError: (Object error) => _log('server: $error'));
    }
    _housekeeping = Timer.periodic(const Duration(seconds: 5), (_) => _tidy());
    _adbTimer = Timer.periodic(adbInterval, (_) => _reverseAndroid());
    _editTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      for (final report in reports.values) {
        if (report.status == FixStatus.fixing || report.status == FixStatus.reloading) {
          _checkEdits(report);
        } else if (_projectWatches.containsKey(report.id)) {
          unawaited(_projectWatches.remove(report.id)!.cancel());
        }
      }
      // Reports trimmed away stop being watched too.
      for (final id in [..._projectWatches.keys]) {
        if (!reports.containsKey(id)) unawaited(_projectWatches.remove(id)!.cancel());
      }
    });
    unawaited(_reverseAndroid());
    _log('hub ${settings.lan ? 'on all interfaces' : 'on loopback'} port $actual (fixkit $fixkitVersion)');
  }

  Future<void> close() async {
    _closing = true;
    _housekeeping?.cancel();
    _adbTimer?.cancel();
    _editTimer?.cancel();
    for (final agent in agents.values) {
      if (agent.isWaiting) agent.waiter!.complete(null);
    }
    for (final runner in runners.values) {
      if (runner.waiter != null && !runner.waiter!.isCompleted) runner.waiter!.complete(null);
    }
    final watches = [..._projectWatches.values];
    _projectWatches.clear();
    await Future.wait([for (final watch in watches) watch.cancel()]);
    // Held status requests are answered before the sockets go.
    for (final report in reports.values) {
      report.releaseWaiters();
    }
    await Future<void>.delayed(Duration.zero);
    for (final server in _servers) {
      await server.close(force: true);
    }
    _servers.clear();
    if (!_closed.isCompleted) _closed.complete();
  }

  // ---- HTTP ----------------------------------------------------------------

  Future<void> _serve(HttpRequest request) async {
    try {
      await _route(request);
    } catch (error, stack) {
      _log('${request.method} ${request.uri.path}: $error\n$stack');
      try {
        _reply(request, HttpStatus.internalServerError, {'error': '$error'});
      } catch (_) {}
    }
  }

  Future<void> _route(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    final loopback = request.connectionInfo?.remoteAddress.isLoopback ?? false;

    if (method == 'GET' && path == '/hello') {
      return _reply(request, HttpStatus.ok, {
        'fixkit': true,
        'version': fixkitVersion,
        'protocol': fixkitProtocol,
        'pid': pid,
        'lan': settings.lan,
        // What this hub can do; an app finding less knows the hub is old.
        'features': const ['activity', 'presence', 'progress', 'selection', 'live-status'],
      });
    }

    // Devices on the network must carry the token; agents and runners must
    // be on this computer.
    if (!loopback && request.headers.value(fixkitTokenHeader) != _token) {
      return _reply(request, HttpStatus.forbidden, {'error': 'missing or wrong fixkit token'});
    }
    final appRoute = path == '/report' || path == '/status' || path == '/signal' || path == '/presence';
    if (!loopback && !appRoute) {
      return _reply(request, HttpStatus.forbidden, {'error': 'only from this computer'});
    }
    if (appRoute) _lastActivity = DateTime.now();

    switch ((method, path)) {
      case ('POST', '/report'):
        return _report(request);
      case ('GET', '/status'):
        return _status(request);
      case ('POST', '/signal'):
        return _signal(request);
      case ('GET', '/presence'):
        return _presence(request);
      case ('POST', '/agent/progress'):
        return _progress(request);
      case ('POST', '/agent/register'):
        return _registerAgent(request);
      case ('POST', '/agent/unregister'):
        return _unregisterAgent(request);
      case ('GET', '/agent/next'):
        return _next(request);
      case ('POST', '/agent/ack'):
        return _ack(request);
      case ('POST', '/agent/release'):
        return _release(request);
      case ('GET', '/agent/report'):
        return _getReport(request);
      case ('GET', '/agent/list'):
        return _list(request);
      case ('POST', '/agent/complete'):
        return _complete(request);
      case ('POST', '/agent/reload'):
        return _reload(request);
      case ('POST', '/runner/register'):
        return _registerRunner(request);
      case ('GET', '/runner/next'):
        return _runnerNext(request);
      case ('GET', '/admin/state'):
        return _reply(request, HttpStatus.ok, state());
      case ('POST', '/admin/shutdown'):
        _reply(request, HttpStatus.ok, {'ok': true});
        _log('shutdown requested');
        Timer(const Duration(milliseconds: 100), close);
        return;
    }
    _reply(request, HttpStatus.notFound, {'error': 'not found: $method $path'});
  }

  void _reply(HttpRequest request, int status, Object? body) {
    final response = request.response;
    response.statusCode = status;
    // A client that hung up mid long poll must not take the hub down.
    if (body == null) {
      response.close().ignore();
      return;
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    response.close().ignore();
  }

  Future<Map<String, Object?>> _json(HttpRequest request) async {
    final bytes = await request.fold<BytesBuilder>(BytesBuilder(copy: false), (builder, chunk) {
      if (builder.length + chunk.length > 40 * 1024 * 1024) throw const FormatException('body too large');
      return builder..add(chunk);
    });
    if (bytes.isEmpty) return {};
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map) throw const FormatException('expected a JSON object');
    return decoded.cast<String, Object?>();
  }

  // ---- App endpoints ---------------------------------------------------------

  Future<void> _report(HttpRequest request) async {
    final body = await _json(request);
    final protocol = body['protocol'];
    if (protocol is int && protocol > fixkitProtocol) {
      return _reply(request, HttpStatus.conflict, {
        'error': 'This app uses fixkit ${body['version'] ?? 'a newer version'}; the hub runs $fixkitVersion. '
            'Reload your editor window so it starts the newer hub.',
      });
    }

    final id = 'r${++_seq}';
    final report = FixReport.fromApp(
      id: id,
      body: body,
      knownRoots: _knownRoots(),
      finder: _finder,
    );
    report.projectRoot ??= _soleProject();
    _saveFiles(report, body['screenshotPNG']);
    reports[id] = report;
    _trimReports();
    _log('report $id from ${report.projectRoot ?? 'an unknown project'}: ${report.comment}');

    _dispatch(report);
    _reply(request, HttpStatus.ok, report.statusJson());
  }

  /// A report's status. With `since` (the revision the app last saw) and
  /// `wait` (seconds), the answer waits until the report changes, so the app
  /// shows each step as it happens without polling.
  Future<void> _status(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final report = reports[query['id']];
    if (report == null) return _reply(request, HttpStatus.notFound, {'error': 'no such report'});
    final since = int.tryParse(query['since'] ?? '');
    final wait = (int.tryParse(query['wait'] ?? '') ?? 0).clamp(0, 25);
    if (since != null && wait > 0 && !report.isFinished && !_closing) {
      await report.changeAfter(since, Duration(seconds: wait));
    }
    final announce = report.status == FixStatus.live && !report.announced;
    if (announce) report.announced = true;
    _reply(request, HttpStatus.ok, report.statusJson(announce: announce));
  }

  /// The app launched or hot reloaded. A fix that was waiting for a reload is
  /// now on screen. Answers with the report the app should follow.
  Future<void> _signal(HttpRequest request) async {
    final body = await _json(request);
    final kind = '${body['kind'] ?? 'reload'}';
    final now = DateTime.now();

    for (final report in reports.values) {
      switch (report.status) {
        case FixStatus.fixing:
          report.sawReload = true;
          report.lastReloadAt = now;
          _checkEdits(report);
          report.note('Hot reloaded');
        case FixStatus.reloading:
          report.lastReloadAt = now;
          report.setStatus(FixStatus.live, keepMessage: true);
        case FixStatus.applied:
          report.lastReloadAt = now;
          report.setStatus(FixStatus.live, keepMessage: true);
          report.note('Hot reloaded: the fix is on screen', kind: 'done');
      }
      final waiter = report.reloadWaiter;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
    for (final waiter in _reloadWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _log('app $kind');

    // Follow the oldest report still in progress, else announce a fresh fix.
    FixReport? follow;
    for (final report in reports.values) {
      if (!report.isFinished) {
        follow = report;
        break;
      }
    }
    if (follow == null) {
      for (final report in reports.values.toList().reversed) {
        if (report.status == FixStatus.live &&
            !report.announced &&
            now.difference(report.updatedAt) < const Duration(seconds: 30)) {
          follow = report;
          break;
        }
      }
    }
    final hub = {'hubVersion': fixkitVersion, 'hubProtocol': fixkitProtocol};
    if (follow == null) return _reply(request, HttpStatus.ok, {'id': null, ...hub});
    final announce = follow.status == FixStatus.live;
    if (announce) follow.announced = true;
    _reply(request, HttpStatus.ok, {...follow.statusJson(announce: announce), ...hub});
  }

  /// Which agent would take a report now, for the composer to name it. The
  /// app passes the pressed widget's file, so the agent with that project
  /// open is the one named.
  void _presence(HttpRequest request) {
    final now = DateTime.now();
    final live = agents.values
        .where((agent) => agent.isWaiting || now.difference(agent.lastSeen) < const Duration(seconds: 50))
        .toList();
    final file = request.uri.queryParameters['file'];
    final path = file == null ? null : pathFromLocation(file);
    final root = path == null ? null : (_knownRoots().where((r) => isWithin(r, path)).firstOrNull ?? _finder.rootOf(path));
    final mine = root == null ? const <AgentSession>[] : live.where((agent) => agent.claims(root)).toList();
    // Only agents that would actually get the report: the project's own, else
    // one that takes any project.
    final pool = root == null
        ? live
        : (mine.isNotEmpty ? mine : live.where((agent) => agent.wildcard || agent.projects.isEmpty).toList());

    bool busy(AgentSession agent) => reports.values.any((report) =>
        report.agentId == agent.id && (report.status == FixStatus.fixing || report.status == FixStatus.reloading));
    // Busy beats the grace period after a poll: it is working, not waiting.
    bool watching(AgentSession agent) => agent.isWaiting || (!busy(agent) && agent.isWatching(now));
    AgentSession? pick(bool Function(AgentSession) test) => pool.where(test).firstOrNull;
    final agent = pick(watching) ?? pick(busy) ?? pool.firstOrNull;
    _reply(request, HttpStatus.ok, {
      'agent': agent?.name,
      'watching': agent != null && watching(agent),
      'busy': agent != null && busy(agent),
      'agents': live.length,
      'version': fixkitVersion,
      'protocol': fixkitProtocol,
    });
  }

  /// Optional: the agent says what it is doing; the app shows it live.
  Future<void> _progress(HttpRequest request) async {
    final body = await _json(request);
    final report = reports['${body['id']}'];
    final message = body['message'];
    if (report != null && message is String && !report.isFinished) report.note(message);
    _reply(request, HttpStatus.ok, {'ok': report != null});
  }

  // ---- Agent endpoints -----------------------------------------------------

  Future<void> _registerAgent(HttpRequest request) async {
    final body = await _json(request);
    final id = '${body['agent']}';
    final projects = <String>{
      for (final item in (body['projects'] is List ? body['projects'] as List : const []))
        if (item is String && item.isNotEmpty) normalizePath(item),
    };
    final name = '${body['name'] ?? 'agent'}';
    final wildcard = body['wildcard'] == true;
    final agent = agents[id];
    if (agent == null) {
      agents[id] = AgentSession(id: id, name: name, projects: projects, wildcard: wildcard);
      _log('agent $name connected for ${projects.isEmpty ? 'any project' : projects.join(', ')}');
    } else {
      agent
        ..name = name
        ..projects = projects
        ..wildcard = wildcard
        ..lastSeen = DateTime.now();
    }
    if (settings.lan) projects.forEach(_writeDefines);
    _reply(request, HttpStatus.ok, {'ok': true, 'version': fixkitVersion});
  }

  Future<void> _unregisterAgent(HttpRequest request) async {
    final body = await _json(request);
    final agent = agents.remove('${body['agent']}');
    if (agent != null && agent.isWaiting) agent.waiter!.complete(null);
    _reply(request, HttpStatus.ok, {'ok': true});
  }

  /// Long poll: answers with the next report for this agent, or 204.
  Future<void> _next(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final agent = agents[query['agent']];
    if (agent == null) return _reply(request, HttpStatus.notFound, {'error': 'register first'});
    agent.lastSeen = DateTime.now();
    final seconds = int.tryParse(query['timeout'] ?? '') ?? 25;
    final timeout = Duration(seconds: seconds.clamp(0, 55));

    final queued = _queuedFor(agent);
    if (queued != null) {
      agent.lastWaitEnd = DateTime.now();
      _deliver(queued, agent);
      return _reply(request, HttpStatus.ok, _delivery(queued));
    }

    if (agent.isWaiting) agent.waiter!.complete(null);
    final waiter = Completer<FixReport?>();
    agent.waiter = waiter;
    final report = await waiter.future.timeout(timeout, onTimeout: () => null);
    if (identical(agent.waiter, waiter)) agent.waiter = null;
    agent.lastSeen = DateTime.now();
    agent.lastWaitEnd = agent.lastSeen;
    if (report == null) return _reply(request, HttpStatus.noContent, null);
    _reply(request, HttpStatus.ok, _delivery(report));
  }

  Map<String, Object?> _delivery(FixReport report) => {
        'report': report.toJson(),
        'prompt': report.prompt(),
      };

  Future<void> _ack(HttpRequest request) async {
    final body = await _json(request);
    final report = reports['${body['id']}'];
    if (report != null) {
      report.acknowledged = true;
      final first = report.chain.firstOrNull;
      report.note(first == null ? 'Reading the report' : 'Reading ${first.location}');
      _watchFiles(report);
    }
    _reply(request, HttpStatus.ok, {'ok': report != null});
  }

  /// The agent's tool call was cancelled before it saw the report: queue it
  /// again for the next one.
  Future<void> _release(HttpRequest request) async {
    final body = await _json(request);
    final report = reports['${body['id']}'];
    if (report != null && report.status == FixStatus.fixing) {
      _requeue(report, 'released by ${report.agentName ?? 'the agent'}');
    }
    _reply(request, HttpStatus.ok, {'ok': report != null});
  }

  void _getReport(HttpRequest request) {
    final report = reports[request.uri.queryParameters['id']];
    if (report == null) return _reply(request, HttpStatus.notFound, {'error': 'no such report'});
    _reply(request, HttpStatus.ok, _delivery(report));
  }

  void _list(HttpRequest request) {
    final agent = agents[request.uri.queryParameters['agent']];
    final list = [
      for (final report in reports.values)
        if (agent == null || agent.wildcard || agent.claims(report.projectRoot) || report.projectRoot == null)
          report.summary(),
    ];
    _reply(request, HttpStatus.ok, {'reports': list});
  }

  /// The agent is done with a report. A fix waits briefly for the app to
  /// reload, so the answer says whether it is on screen.
  Future<void> _complete(HttpRequest request) async {
    final body = await _json(request);
    final report = reports['${body['id']}'];
    if (report == null) return _reply(request, HttpStatus.notFound, {'error': 'no such report'});
    final outcome = '${body['outcome'] ?? 'fixed'}';
    final summary = body['summary'] is String ? (body['summary'] as String).trim() : null;
    final message = summary == null || summary.isEmpty ? null : summary;

    switch (outcome) {
      case 'failed':
        report.setStatus(FixStatus.failed, message: message);
        report.note('Not fixed', kind: 'error');
      case 'needs_input':
        report.setStatus(FixStatus.needsInput, message: message);
        report.note('Waiting for your answer in ${report.agentName ?? 'the agent chat'}', kind: 'question');
      default:
        final completedAt = DateTime.now();
        final hadReload = report.sawReload;
        _checkEdits(report);
        report.setStatus(FixStatus.reloading, message: message);
        if (!hadReload) report.note('Hot reloading');
        final waiter = Completer<void>();
        report.reloadWaiter = waiter;
        // A reload that already happened during the fix usually carried the
        // last edit (hot reload on save); give a newer one a moment anyway.
        final wait = hadReload ? const Duration(milliseconds: 2500) : reloadWait;
        await waiter.future.timeout(wait, onTimeout: () {});
        report.reloadWaiter = null;
        final reloaded = report.lastReloadAt != null && !report.lastReloadAt!.isBefore(completedAt);
        if (report.status == FixStatus.reloading) {
          report.setStatus(reloaded || hadReload ? FixStatus.live : FixStatus.applied, message: message);
        }
        report.note(
          report.status == FixStatus.live ? 'Fix is on screen' : 'Fixed in code: hot reload to see it',
          kind: 'done',
        );
    }
    _log('report ${report.id} ${report.status}${message == null ? '' : ': $message'}');
    _reply(request, HttpStatus.ok, report.statusJson());
  }

  /// Hot reloads the project's app through its `fixkit run`, when there is
  /// one, and waits for the app to confirm.
  Future<void> _reload(HttpRequest request) async {
    final body = await _json(request);
    final project = body['project'] is String ? normalizePath(body['project'] as String) : null;
    final runner = _runnerFor(project);
    if (runner == null) {
      return _reply(request, HttpStatus.ok, {'runner': false, 'reloaded': false});
    }
    final waiter = Completer<void>();
    _reloadWaiters.add(waiter);
    for (final active in reports.values) {
      if (active.status == FixStatus.fixing) {
        _checkEdits(active);
        active.setStatus(FixStatus.reloading, keepMessage: true);
        active.note('Hot reloading');
      }
    }
    _sendToRunner(runner, 'reload');
    await waiter.future.timeout(reloadWait, onTimeout: () {});
    _reloadWaiters.remove(waiter);
    final reloaded = waiter.isCompleted;
    // Reports marked reloading go back to fixing if no reload came, unless an
    // agent is finishing them.
    if (!reloaded) {
      for (final active in reports.values) {
        if (active.status == FixStatus.reloading && active.reloadWaiter == null) {
          active.setStatus(FixStatus.fixing, keepMessage: true);
        }
      }
    }
    _reply(request, HttpStatus.ok, {'runner': true, 'reloaded': reloaded});
  }

  // ---- Runner endpoints ------------------------------------------------------

  Future<void> _registerRunner(HttpRequest request) async {
    final body = await _json(request);
    final project = normalizePath('${body['project']}');
    runners.putIfAbsent(project, () => RunnerSession(project)).lastSeen = DateTime.now();
    _log('runner for $project');
    if (settings.lan) _writeDefines(project);
    _reply(request, HttpStatus.ok, {'ok': true, 'lan': settings.lan, if (settings.lan) ..._lanDefines()});
  }

  Future<void> _runnerNext(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final project = normalizePath('${query['project']}');
    final runner = runners.putIfAbsent(project, () => RunnerSession(project));
    runner.lastSeen = DateTime.now();
    if (runner.pending.isNotEmpty) {
      return _reply(request, HttpStatus.ok, {'command': runner.pending.removeAt(0)});
    }
    final waiter = Completer<String?>();
    final previous = runner.waiter;
    if (previous != null && !previous.isCompleted) previous.complete(null);
    runner.waiter = waiter;
    final seconds = int.tryParse(query['timeout'] ?? '') ?? 25;
    final command = await waiter.future.timeout(Duration(seconds: seconds.clamp(0, 55)), onTimeout: () => null);
    if (identical(runner.waiter, waiter)) runner.waiter = null;
    runner.lastSeen = DateTime.now();
    if (command == null) return _reply(request, HttpStatus.noContent, null);
    _reply(request, HttpStatus.ok, {'command': command});
  }

  void _sendToRunner(RunnerSession runner, String command) {
    final waiter = runner.waiter;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(command);
    } else {
      runner.pending.add(command);
    }
  }

  RunnerSession? _runnerFor(String? project) {
    final live = runners.values.where((runner) => DateTime.now().difference(runner.lastSeen) < const Duration(seconds: 60));
    if (project != null) {
      for (final runner in live) {
        if (isWithin(runner.project, project) || isWithin(project, runner.project)) return runner;
      }
    }
    return live.length == 1 ? live.first : null;
  }

  /// `<project>/.fixkit/defines.json`, which Flutter launches pass to the
  /// app (`--dart-define-from-file`) so a phone on Wi-Fi finds this hub.
  void _writeDefines(String project) {
    try {
      final dir = Directory(joinPath(project, '.fixkit'));
      if (!dir.existsSync()) return;
      final file = File(joinPath(dir.path, 'defines.json'));
      final text = const JsonEncoder.withIndent('  ').convert({
        'FIXKIT_HOST': _lanAddress == null ? '' : '$_lanAddress:$boundPort',
        'FIXKIT_TOKEN': _token,
      });
      if (!file.existsSync() || file.readAsStringSync() != text) file.writeAsStringSync(text);
    } catch (error) {
      _log('could not write defines for $project: $error');
    }
  }

  Map<String, Object?> _lanDefines() => {
        'host': _lanAddress == null ? null : '$_lanAddress:$boundPort',
        'token': _token,
      };

  // ---- Routing ---------------------------------------------------------------

  Iterable<String> _knownRoots() => {
        for (final agent in agents.values) ...agent.projects,
        ...runners.keys,
      };

  /// The only project anything is connected for, if there is exactly one.
  String? _soleProject() {
    final roots = _knownRoots().toSet();
    return roots.length == 1 ? roots.first : null;
  }

  /// The agent that should take [report] now: one waiting with its project
  /// open, else a waiting wildcard agent.
  AgentSession? _agentFor(FixReport report) {
    final candidates = agents.values.where((agent) => agent.isWaiting).toList();
    for (final agent in candidates) {
      if (agent.claims(report.projectRoot)) return agent;
    }
    // Nobody claims the project: an agent that claims no project at all, or
    // any agent when the project is unknown.
    final claimed = agents.values.any((agent) => agent.claims(report.projectRoot));
    if (claimed) return null;
    for (final agent in candidates) {
      if (agent.wildcard || agent.projects.isEmpty || report.projectRoot == null) return agent;
    }
    return null;
  }

  FixReport? _queuedFor(AgentSession agent) {
    for (final report in reports.values) {
      if (report.status != FixStatus.queued) continue;
      if (agent.claims(report.projectRoot)) return report;
    }
    for (final report in reports.values) {
      if (report.status != FixStatus.queued) continue;
      final claimed = agents.values.any((other) => other.claims(report.projectRoot));
      if (!claimed && (agent.wildcard || agent.projects.isEmpty || report.projectRoot == null)) return report;
    }
    return null;
  }

  void _dispatch(FixReport report) {
    final agent = _agentFor(report);
    if (agent != null) {
      _deliver(report, agent);
      agent.waiter!.complete(report);
      return;
    }
    _queue(report);
  }

  void _deliver(FixReport report, AgentSession agent) {
    report
      ..agentId = agent.id
      ..agentName = agent.name
      ..deliveredAt = DateTime.now()
      ..acknowledged = false
      ..setStatus(FixStatus.fixing, message: 'Picked up by ${agent.name}')
      ..note('Sent to ${agent.name}');
    _log('report ${report.id} → ${agent.name}');
  }

  void _requeue(FixReport report, String why) {
    _log('report ${report.id} queued again: $why');
    report
      ..agentId = null
      ..agentName = null
      ..deliveredAt = null;
    _dispatch(report);
  }

  /// No agent is waiting for the report. If none picks it up shortly, say how
  /// to get it handled, and put the prompt on the clipboard.
  void _queue(FixReport report) {
    final watching = agents.values.any((agent) => agent.claims(report.projectRoot) || agent.wildcard);
    report.setStatus(
      FixStatus.queued,
      message: watching ? 'Waiting for your agent to finish its current task' : 'Waiting for an agent',
    );
    report.note(watching ? 'Queued: your agent is finishing another fix' : 'Waiting for an agent to watch');
    Timer(fallbackDelay, () => _fallback(report));
  }

  Future<void> _fallback(FixReport report) async {
    if (report.status != FixStatus.queued || report.copiedToClipboard) return;
    final connected = agents.values.any((agent) => agent.claims(report.projectRoot) || agent.wildcard);
    final busy = agents.values.any((agent) =>
        (agent.claims(report.projectRoot) || agent.wildcard) &&
        reports.values.any((other) => other.agentId == agent.id && other.status == FixStatus.fixing));

    // An agent busy with an earlier report will come back for this one.
    if (busy) return;

    var copied = false;
    if (settings.clipboard) copied = await tools.copyToClipboard(report.prompt());
    report.copiedToClipboard = copied;
    if (report.status != FixStatus.queued) return;

    final hint = connected
        ? 'Say "watch for fixes" in your agent chat.'
        : 'No agent is connected: open the project in your editor and say "watch for fixes".';
    report.setStatus(
      FixStatus.queued,
      message: copied ? '$hint The request is also on your clipboard to paste.' : hint,
    );
    if (copied) report.note('Copied to your clipboard to paste into any chat');
    if (settings.notifications) {
      unawaited(tools.notify(
        'fixkit: ${report.comment.isEmpty ? 'new fix request' : report.comment}',
        copied ? '$hint Or paste the request (copied to the clipboard).' : hint,
      ));
    }
  }

  DateTime _reportActivity(FixReport report) {
    var last = report.updatedAt;
    final at = report.activity.isEmpty ? null : DateTime.tryParse('${report.activity.last['at']}');
    if (at != null && at.isAfter(last)) last = at;
    return last;
  }

  /// Remembers when the files of the widget path last changed, and watches
  /// the project's `lib` for edits to any other file.
  void _watchFiles(FixReport report) {
    for (final frame in report.chain.take(8)) {
      report.watched.putIfAbsent(frame.path, () => _modified(frame.path));
    }
    final root = report.projectRoot;
    if (root == null || _projectWatches.containsKey(report.id)) return;
    final lib = Directory(joinPath(root, 'lib'));
    try {
      if (!lib.existsSync()) return;
      _projectWatches[report.id] = _ProjectWatch(lib, (file) {
        if (report.status == FixStatus.fixing || report.status == FixStatus.reloading) _noteEdit(report, file);
      });
    } catch (_) {
      // No file watching here (some network drives): the poll still sees
      // the widget's own files.
    }
  }

  void _noteEdit(FixReport report, String file) {
    final path = _canonical(file);
    if (!report.edited.add(path)) return;
    report.note('Edited ${path.split('/').last}');
  }

  /// One spelling per file, whichever way it was reached (macOS reports
  /// `/private/var/...` for `/var/...`).
  String _canonical(String file) {
    try {
      return normalizePath(File(file).resolveSymbolicLinksSync());
    } catch (_) {
      return normalizePath(file);
    }
  }

  /// Notes each watched file the agent has changed since it took the report.
  void _checkEdits(FixReport report) {
    for (final entry in report.watched.entries) {
      if (report.edited.contains(_canonical(entry.key))) continue;
      final now = _modified(entry.key);
      if (now != null && now != entry.value) _noteEdit(report, entry.key);
    }
  }

  DateTime? _modified(String path) {
    try {
      return File(path).lastModifiedSync();
    } catch (_) {
      return null;
    }
  }

  // ---- Files and housekeeping ------------------------------------------------

  void _saveFiles(FixReport report, Object? screenshot) {
    final root = report.projectRoot;
    final dir = root == null
        ? Directory(joinPath(fixkitHome().path, 'reports'))
        : Directory(joinPath(root, '.fixkit', 'reports'));
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      if (root != null) _ensureIgnored(root);
      if (screenshot is String && screenshot.isNotEmpty) {
        final file = File(joinPath(dir.path, '${report.id}-${report.receivedAt.millisecondsSinceEpoch}.png'));
        file.writeAsBytesSync(base64Decode(screenshot));
        report.screenshotPath = file.path;
      }
      File(joinPath(dir.path, '${report.id}-${report.receivedAt.millisecondsSinceEpoch}.json'))
          .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } catch (error) {
      _log('could not save files for ${report.id}: $error');
    }
  }

  /// `.fixkit/` holds screenshots: keep it out of git even if init never ran.
  void _ensureIgnored(String root) {
    final ignore = File(joinPath(root, '.fixkit', '.gitignore'));
    if (!ignore.existsSync()) {
      ignore.writeAsStringSync('# Created by fixkit: reports and screenshots stay local.\nreports/\ndefines.json\n');
    }
  }

  void _trimReports() {
    if (reports.length <= 200) return;
    final finished = reports.values.where((report) => report.isFinished).take(reports.length - 200).toList();
    for (final report in finished) {
      reports.remove(report.id);
    }
  }

  void _tidy() {
    final now = DateTime.now();

    // Agents whose MCP server stopped heartbeating.
    final gone = agents.values.where((agent) => !agent.isWaiting && now.difference(agent.lastSeen) > const Duration(seconds: 50)).toList();
    for (final agent in gone) {
      agents.remove(agent.id);
      _log('agent ${agent.name} gone');
    }
    runners.removeWhere((_, runner) => runner.waiter == null && now.difference(runner.lastSeen) > const Duration(seconds: 90));

    // Reports delivered to an MCP server that never acknowledged them.
    for (final report in reports.values.toList()) {
      if (report.status == FixStatus.fixing &&
          !report.acknowledged &&
          report.deliveredAt != null &&
          now.difference(report.deliveredAt!) > ackTimeout) {
        _requeue(report, 'not acknowledged');
      }
      // A report whose agent disappeared mid-fix goes back to the queue.
      if (report.status == FixStatus.fixing && report.agentId != null && !agents.containsKey(report.agentId)) {
        _requeue(report, 'its agent disconnected');
      }
      // An agent that took a report and went quiet (its chat stopped, say):
      // tell the app instead of spinning forever.
      if (report.status == FixStatus.fixing && report.acknowledged && now.difference(_reportActivity(report)) > staleAfter) {
        report.setStatus(
          FixStatus.failed,
          message: 'No answer from ${report.agentName ?? 'the agent'} for ${staleAfter.inMinutes} minutes. '
              'Say "watch for fixes" in its chat and send the request again.',
        );
        report.note('No answer from the agent', kind: 'error');
        _log('report ${report.id} timed out');
      }
    }

    if (agents.isEmpty && runners.isEmpty && now.difference(_lastActivity) > idleTimeout) {
      _log('idle: shutting down');
      unawaited(close());
    }
    if (agents.isNotEmpty || runners.isNotEmpty) _lastActivity = now;
  }

  Future<void> _reverseAndroid() async {
    if (_adbBusy) return;
    _adbBusy = true;
    try {
      await tools.reverseAndroidPorts(port: boundPort);
    } finally {
      _adbBusy = false;
    }
  }

  /// Everything `fixkit doctor` and `fixkit status` show.
  Map<String, Object?> state() => {
        'version': fixkitVersion,
        'pid': pid,
        'port': boundPort,
        'lan': settings.lan,
        if (settings.lan) 'lanAddress': _lanAddress,
        'agents': [for (final agent in agents.values) agent.toJson()],
        'runners': [for (final runner in runners.values) runner.toJson()],
        'reports': [for (final report in reports.values) report.summary()],
        'android': tools.reversedDevices.toList(),
        'adb': tools.findAdb(),
      };
}

/// Runs the hub until it shuts down; logs to `~/.fixkit/hub.log`.
Future<void> runHub({int port = fixkitPort, bool foreground = false}) async {
  final logFile = hubLogFile();
  if (logFile.existsSync() && logFile.lengthSync() > 1024 * 1024) {
    logFile.renameSync('${logFile.path}.1');
  }
  final sink = logFile.openWrite(mode: FileMode.append);
  void log(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    sink.writeln(line);
    if (foreground) stderr.writeln(line);
  }

  final hub = FixHub(port: port, log: log);
  try {
    await hub.start();
  } on SocketException catch (error) {
    log('could not listen on port $port: ${error.message}');
    await sink.flush();
    await sink.close();
    exitCode = 1;
    return;
  }
  await hub.done;
  await sink.flush();
  await sink.close();
}

/// Watches a project's `lib` folder for changed Dart files. macOS and Windows
/// watch the tree in one go; Linux (inotify) watches each folder, and adds
/// folders as they appear.
class _ProjectWatch {
  _ProjectWatch(Directory lib, this._onEdit) {
    if (Platform.isLinux) {
      _watch(lib, recursive: false);
      try {
        for (final entity in lib.listSync(recursive: true, followLinks: false)) {
          if (entity is Directory) _watch(entity, recursive: false);
        }
      } catch (_) {
        // A folder that cannot be listed: the ones found so far are watched.
      }
    } else {
      _watch(lib, recursive: true);
    }
  }

  /// Plenty for an app's `lib`; keeps inotify use bounded on huge trees.
  static const int _maxFolders = 400;

  final void Function(String file) _onEdit;
  final Map<String, StreamSubscription<FileSystemEvent>> _subscriptions = {};
  bool _cancelled = false;

  void _watch(Directory dir, {required bool recursive}) {
    if (_cancelled || _subscriptions.length >= _maxFolders || _subscriptions.containsKey(dir.path)) return;
    try {
      _subscriptions[dir.path] = dir.watch(recursive: recursive).listen(
        _event,
        onError: (Object _) => _subscriptions.remove(dir.path)?.cancel(),
        cancelOnError: true,
      );
    } catch (_) {
      // This folder cannot be watched; the others still are.
    }
  }

  void _event(FileSystemEvent event) {
    if (event.isDirectory) {
      final created = event is FileSystemCreateEvent
          ? event.path
          : event is FileSystemMoveEvent
              ? event.destination
              : null;
      if (Platform.isLinux && created != null) {
        final dir = Directory(created);
        _watch(dir, recursive: false);
        // Files written before the new folder's watch began.
        try {
          for (final entity in dir.listSync(recursive: true, followLinks: false)) {
            if (entity is Directory) {
              _watch(entity, recursive: false);
            } else if (entity.path.endsWith('.dart')) {
              _onEdit(entity.path);
            }
          }
        } catch (_) {}
      }
      return;
    }
    if (event is FileSystemDeleteEvent) return;
    if (event is FileSystemModifyEvent && !event.contentChanged) return;
    // Editors that save atomically write a temporary file and move it over
    // the real one: the destination is the file that changed.
    final file = event is FileSystemMoveEvent ? (event.destination ?? event.path) : event.path;
    if (file.endsWith('.dart')) _onEdit(file);
  }

  Future<void> cancel() async {
    _cancelled = true;
    final subscriptions = [..._subscriptions.values];
    _subscriptions.clear();
    await Future.wait([for (final subscription in subscriptions) subscription.cancel()]);
  }
}
