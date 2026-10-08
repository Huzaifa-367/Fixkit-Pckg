import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../server/hub_client.dart';
import '../server/paths.dart';
import 'console.dart';
import 'project.dart';

/// `dart run fixkit run [--lan] [flutter run options]`: `flutter run` that the
/// agent can hot reload through fixkit's `hot_reload` tool, from any editor.
///
/// Everything else works as with `flutter run`: the keys (r, R, q), the
/// output, the device picker.
Future<int> runFlutter(List<String> arguments, Console console) async {
  final project = Project.find();
  if (project == null) {
    console.line('${console.red('✖')} No pubspec.yaml here or above. Run this in your Flutter project.');
    return 1;
  }

  final lan = arguments.contains('--lan');
  final flutterArguments = arguments.where((argument) => argument != '--lan').toList();
  if (lan) FixkitSettings.load().copyWith(lan: true).save();

  final hub = HubClient(entryScript: project.launcher.existsSync() ? project.launcher.path : null);
  Map<String, Object?>? registration;
  try {
    await hub.ensure(restartIfLanDiffers: lan);
    registration = await hub.call('POST', '/runner/register', body: {'project': project.root});
  } catch (error) {
    console.warn('fixkit', 'hub unavailable ($error); running without agent hot reload');
  }

  final defines = <String>[];
  if (lan) {
    final host = registration?['host'];
    final token = registration?['token'];
    if (host is String && token is String) {
      defines
        ..add('--dart-define=FIXKIT_HOST=$host')
        ..add('--dart-define=FIXKIT_TOKEN=$token');
    } else {
      console.warn('fixkit', 'no network address found for Wi-Fi devices');
    }
  }

  final pidFile = File(joinPath(Directory.systemTemp.path, 'fixkit-flutter-$pid.pid'));
  if (pidFile.existsSync()) pidFile.deleteSync();
  final flutter = flutterExecutable();
  final commandLine = ['run', '--pid-file', pidFile.path, ...defines, ...flutterArguments];
  stderr.writeln(console.dim('fixkit: flutter ${commandLine.join(' ')}'));

  // POSIX: the terminal stays flutter's own; hot reload goes through SIGUSR1.
  // Windows has no signals: flutter reads the keys from this process, which
  // types `r` to reload.
  final windows = Platform.isWindows;
  final process = await Process.start(
    flutter,
    commandLine,
    workingDirectory: project.root,
    mode: windows ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
    runInShell: windows,
  );
  StreamSubscription<List<int>>? input;
  if (windows) {
    unawaited(stdout.addStream(process.stdout));
    unawaited(stderr.addStream(process.stderr));
    input = stdin.listen(process.stdin.add, onDone: () => process.stdin.close());
  }

  var running = true;
  Future<void> reload() async {
    if (windows) {
      process.stdin.write('r');
      return;
    }
    if (!pidFile.existsSync()) return;
    final flutterPid = int.tryParse(pidFile.readAsStringSync().trim());
    if (flutterPid != null) Process.killPid(flutterPid, ProcessSignal.sigusr1);
  }

  // Waits for the hub to ask for reloads, until flutter exits.
  unawaited(() async {
    var failures = 0;
    while (running) {
      try {
        final answer = await hub.call(
          'GET',
          '/runner/next',
          query: {'project': project.root, 'timeout': '25'},
          timeout: const Duration(seconds: 35),
        );
        failures = 0;
        if (answer?['command'] == 'reload') await reload();
      } catch (_) {
        if (!running) break;
        failures++;
        await Future<void>.delayed(Duration(seconds: failures > 5 ? 10 : 2));
        try {
          await hub.ensure();
          await hub.call('POST', '/runner/register', body: {'project': project.root});
        } catch (_) {}
      }
    }
  }());

  final code = await process.exitCode;
  running = false;
  await input?.cancel();
  hub.close();
  if (pidFile.existsSync()) pidFile.deleteSync();
  return code;
}

/// `dart run fixkit status`: what the hub sees.
Future<int> runStatus(List<String> arguments, Console console) async {
  final hub = HubClient();
  final hello = await hub.hello();
  if (hello == null) {
    console.line('The fixkit hub is not running. Your editor starts it when it loads fixkit.');
    hub.close();
    return 1;
  }
  final state = await hub.call('GET', '/admin/state');
  hub.close();
  if (arguments.contains('--json')) {
    console.line(const JsonEncoder.withIndent('  ').convert(state));
    return 0;
  }
  console.title('fixkit hub ${state?['version']}  ${console.dim('pid ${state?['pid']}, port ${state?['port']}${state?['lan'] == true ? ', Wi-Fi on' : ''}')}');

  final agents = state?['agents'] as List? ?? const [];
  console.line(console.bold('Agents'));
  if (agents.isEmpty) console.line(console.dim('  none connected: open the project in your editor'));
  for (final agent in agents.cast<Map>()) {
    final projects = (agent['projects'] as List?)?.join(', ');
    final watching = agent['watching'] == true || agent['waiting'] == true ? console.green('watching') : console.yellow('not watching');
    console.line('  ${agent['name']}  $watching  ${console.dim(projects == null || projects.isEmpty ? 'any project' : projects)}');
  }

  final runners = state?['runners'] as List? ?? const [];
  if (runners.isNotEmpty) {
    console.line();
    console.line(console.bold('fixkit run'));
    for (final runner in runners.cast<Map>()) {
      console.line('  ${runner['project']}');
    }
  }

  final apps = state?['apps'] is Map ? state!['apps'] as Map : const {};
  if (apps.isNotEmpty) {
    console.line();
    console.line(console.bold('Agent hot reload'));
    for (final entry in apps.entries) {
      console.line('  ${entry.key}  ${console.green('through the app\'s Flutter session')}');
    }
  }

  final android = state?['android'] as List? ?? const [];
  if (android.isNotEmpty) {
    console.line();
    console.line('${console.bold('Android')}  adb reverse on ${android.join(', ')}');
  }

  final reports = state?['reports'] as List? ?? const [];
  console.line();
  console.line(console.bold('Reports'));
  if (reports.isEmpty) console.line(console.dim('  none yet'));
  for (final report in reports.cast<Map>().toList().reversed.take(20)) {
    console.line('  ${report['id']}  ${_status(console, '${report['status']}')}  "${report['comment']}"');
    console.line('      ${console.dim('${report['headline']}')}');
    if (report['message'] != null) console.line('      ${console.dim('${report['message']}')}');
  }
  console.line();
  return 0;
}

String _status(Console console, String status) => switch (status) {
      'live' => console.green(status),
      'failed' => console.red(status),
      'needs_input' || 'applied' => console.yellow(status),
      _ => console.cyan(status),
    };

/// `dart run fixkit restart`: stops the running hub (an outdated one, say)
/// and starts this project's fixkit in its place. Agents reconnect by
/// themselves; reports in progress are lost.
Future<int> runRestart(List<String> arguments, Console console) async {
  final project = Project.find();
  final hub = HubClient(entryScript: project != null && project.launcher.existsSync() ? project.launcher.path : null);
  final before = await hub.hello();
  if (before != null) {
    try {
      await hub.call('POST', '/admin/shutdown', timeout: const Duration(seconds: 3));
    } catch (_) {}
    for (var i = 0; i < 40 && await hub.hello() != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    console.ok('Hub', 'stopped fixkit ${before['version']}');
  }
  try {
    final hello = await hub.ensure();
    console.ok('Hub', 'fixkit ${hello['version']} running on port ${hub.port}');
    console.hint('Agents reconnect within 15 seconds; say "watch for fixes" again if one was watching.');
    return 0;
  } catch (error) {
    console.fail('Hub', '$error');
    return 1;
  } finally {
    hub.close();
  }
}
