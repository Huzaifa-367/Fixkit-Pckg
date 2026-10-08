import 'dart:io';

import '../protocol.dart';
import '../server/host_tools.dart';
import '../server/hub_client.dart';
import '../server/paths.dart';
import 'console.dart';
import 'editors.dart';
import 'main_patch.dart';
import 'project.dart';
import 'templates.dart';
import 'versions.dart';

/// `dart run fixkit doctor`: checks every piece and says how to fix what is
/// missing. Exits 1 when something is broken.
Future<int> runDoctor(List<String> arguments, Console console) async {
  var problems = 0;
  void broken(String label, String detail, [String? hint]) {
    problems++;
    console.fail(label, detail);
    if (hint != null) console.hint(hint);
  }

  final project = Project.find();
  console.title('fixkit doctor  ${console.dim(project?.root ?? Directory.current.path)}');

  // The SDK.
  console.ok('Dart', '${dartVersion()}  ${console.dim(dartExecutable())}');
  final flutter = flutterExecutable();
  if (flutter == 'flutter') {
    console.warn('Flutter', 'not found next to this Dart or on PATH');
  } else {
    console.ok('Flutter', console.dim(flutter));
  }

  if (project == null) {
    broken('Project', 'no pubspec.yaml here or above', 'Run doctor in your Flutter project.');
    return 1;
  }

  // The package.
  if (!project.dependsOnFixkit) {
    broken('pubspec.yaml', 'fixkit is not a dependency', 'flutter pub add fixkit');
  } else if (!project.fixkitResolved) {
    broken('pubspec.yaml', 'fixkit is listed but not resolved', 'flutter pub get');
  } else {
    final installed = readInstalled(project);
    console.ok('pubspec.yaml', 'fixkit $fixkitVersion  ${console.dim(installed.describe())}');
    if (installed.source == FixkitSource.git && Semver.tryParse(installed.gitRef) == null) {
      console.warn('Version', 'the git dependency follows a branch; pin a release with `ref: v$fixkitVersion`');
    }
  }

  // main.dart.
  final entries = project.entryPoints.where((file) => hasRunApp(file.readAsStringSync())).toList();
  final wrapped = entries.where((file) => file.readAsStringSync().contains('FixKit(')).toList();
  if (entries.isEmpty) {
    console.warn('main.dart', 'no runApp(...) in lib/main*.dart: make sure FixKit wraps your app');
  } else if (wrapped.isEmpty) {
    broken('main.dart', 'runApp is not wrapped in FixKit', 'dart run fixkit init');
  } else {
    console.ok('main.dart', wrapped.map((file) => project.relative(file.path)).join(', '));
  }

  // The launcher.
  final launcher = project.launcher;
  if (!launcher.existsSync()) {
    broken('Launcher', '.fixkit/mcp.dart is missing', 'dart run fixkit init');
  } else if (launcher.readAsStringSync() != launcherSource) {
    console.warn('Launcher', '.fixkit/mcp.dart differs from this version: run `dart run fixkit init`');
  } else {
    console.ok('Launcher', '.fixkit/mcp.dart');
  }

  // Editors.
  final editors = detectEditors(project, only: allEditorIds.toSet())
      .where((editor) => editor.file.existsSync() || detectEditors(project).any((found) => found.configPath == editor.configPath))
      .toList();
  var configured = 0;
  for (final editor in editors) {
    final check = checkEditorConfig(editor, project);
    final where = editor.global ? editor.configPath : project.relative(editor.configPath);
    if (check.valid) {
      configured++;
      console.ok(editor.name, where);
    } else if (check.present) {
      broken(editor.name, '$where: ${check.problem}', 'dart run fixkit init');
    } else {
      console.info(editor.name, '${console.dim('not set up')} ${console.dim('($where)')}');
    }
  }
  if (configured == 0) broken('Editors', 'no editor has fixkit', 'dart run fixkit init');

  // Agent rules.
  final agents = project.file('AGENTS.md');
  if (agents.existsSync() && agents.readAsStringSync().contains(agentsStart)) {
    console.ok('Agent rules', 'AGENTS.md');
  } else {
    console.warn('Agent rules', 'AGENTS.md has no fixkit section (the MCP server still explains itself)');
  }

  // The hub.
  final hub = HubClient(entryScript: launcher.existsSync() ? launcher.path : null);
  final hello = await hub.hello();
  if (hello == null) {
    final taken = await _portTaken();
    if (taken) {
      broken('Hub', 'port $fixkitPort is used by another program', 'Free the port; fixkit needs it.');
    } else {
      console.warn('Hub', 'not running: your editor starts it when it loads fixkit');
      if (arguments.contains('--start')) {
        try {
          await hub.ensure();
          console.ok('Hub', 'started');
        } catch (error) {
          broken('Hub', 'could not start: $error', 'See ${hubLogFile().path}');
        }
      } else {
        console.hint('Start it now with `dart run fixkit doctor --start`.');
      }
    }
  } else {
    final state = await hub.call('GET', '/admin/state');
    final agentsList = (state?['agents'] as List?) ?? const [];
    final mine = agentsList.whereType<Map>().where((agent) {
      final projects = (agent['projects'] as List?)?.whereType<String>() ?? const <String>[];
      return projects.isEmpty || projects.any((p) => isWithin(p, project.root) || isWithin(project.root, p));
    }).toList();
    console.ok('Hub', 'fixkit ${hello['version']} on port $fixkitPort${hello['lan'] == true ? ' (Wi-Fi on)' : ''}');
    final hubVersion = Semver.tryParse('${hello['version']}');
    if (hubVersion != null && hubVersion < currentVersion) {
      broken('Hub', 'runs fixkit $hubVersion, older than this project\'s $fixkitVersion', 'dart run fixkit restart');
    }
    if (hello['protocol'] is int && (hello['protocol'] as int) < fixkitProtocol) {
      broken('Hub', 'speaks protocol ${hello['protocol']}, the app needs $fixkitProtocol', 'Reload your editor window.');
    }
    if (mine.isEmpty) {
      console.warn('Agent', 'no editor connected for this project yet: reload the editor window');
    } else {
      for (final agent in mine) {
        final watching = agent['watching'] == true || agent['waiting'] == true;
        final label = '${agent['name']}';
        if (watching) {
          console.ok('Agent', '$label is watching for fixes');
        } else {
          console.warn('Agent', '$label is connected but not watching: say "watch for fixes" in its chat');
        }
        final agentVersion = Semver.tryParse('${agent['version']}');
        if (agentVersion == null || agentVersion < currentVersion) {
          broken('Agent', '$label runs ${agentVersion == null ? 'an older fixkit' : 'fixkit $agentVersion'}, not $fixkitVersion',
              'Reload the editor window (Cursor/VS Code: "Developer: Reload Window") so it starts the new fixkit.');
        }
      }
    }
    final apps = state?['apps'] is Map ? (state!['apps'] as Map).keys.whereType<String>() : const <String>[];
    final runners = ((state?['runners'] as List?) ?? const []).whereType<Map>().map((runner) => '${runner['project']}');
    bool ours(String root) => isWithin(root, project.root) || isWithin(project.root, root);
    final app = state?['app'] is Map ? state!['app'] as Map : null;
    if (app == null) {
      console.warn('App', 'has not reached the hub since it started: run the app (badge says "fixkit offline"? see Android/iPhone below)');
    } else {
      final appVersion = Semver.tryParse('${app['version']}');
      final seen = DateTime.tryParse('${app['at']}');
      final ago = seen == null ? '' : ', last heard ${DateTime.now().difference(seen).inSeconds}s ago';
      console.ok('App', '${app['platform'] ?? 'unknown platform'}, fixkit ${app['version'] ?? '?'}$ago');
      if (appVersion != null && appVersion < currentVersion) {
        broken('App', 'runs fixkit $appVersion, older than $fixkitVersion', 'Stop the app and run it again (a hot reload keeps the old fixkit).');
      }
    }
    if (runners.any(ours)) {
      console.ok('Hot reload', 'the agent reloads the app through `fixkit run`');
    } else if (apps.any(ours)) {
      console.ok('Hot reload', 'through the app\'s Flutter session; agent edits reload by themselves${state?['autoReload'] == false ? ' (autoReload is off in ~/.fixkit/config.json)' : ''}');
    } else if (app != null && app['session'] != true) {
      broken('Hot reload', 'the app did not find its Flutter session', 'Run the app from the IDE or `flutter run` (debug mode). The debug console says why at launch.');
    } else {
      console.warn('Hot reload', 'no running app known yet: start the app (a full start, not a hot reload)');
    }
    final last = state?['lastReload'] is Map ? state!['lastReload'] as Map : null;
    if (last != null) {
      if (last['reloaded'] == true) {
        console.ok('Last reload', 'worked (${last['via']})');
      } else {
        console.warn('Last reload', 'failed: ${last['error']}');
      }
    }
  }
  hub.close();

  // Versions: the setup's stamp and the newest release.
  final stamp = readStamp(project);
  if (stamp == null) {
    console.warn('Setup', 'made before version stamps: run `dart run fixkit init --refresh`');
  } else if (stamp != currentVersion) {
    console.warn('Setup', 'made with fixkit $stamp; your editor refreshes it on its next start, or run `dart run fixkit init --refresh`');
  } else {
    console.ok('Setup', 'made with fixkit $stamp');
  }
  if (!arguments.contains('--offline')) {
    final installed = readInstalled(project);
    if (installed.source == FixkitSource.hosted || installed.source == FixkitSource.git) {
      final latest = await latestRelease(installed, timeout: const Duration(seconds: 3));
      if (latest == null) {
        console.info('Latest', 'could not check (offline?)');
      } else if (latest > currentVersion) {
        console.warn('Latest', 'fixkit $latest is out: run `dart run fixkit upgrade`');
      } else {
        console.ok('Latest', 'fixkit $fixkitVersion is the newest release');
      }
    }
  }

  // Devices.
  final tools = HostTools();
  final adb = tools.findAdb();
  if (adb == null) {
    console.warn('Android', 'adb not found, so phones on USB cannot reach the hub (emulators still can, at 10.0.2.2)');
    console.hint('Install the Android SDK platform-tools, or point fixkit at your SDK: `flutter config --android-sdk <path>`.');
  } else {
    final devices = await tools.adbDeviceStates();
    if (devices.isEmpty) console.ok('Android', 'adb ready, no device connected  ${console.dim(adb)}');
    for (final MapEntry(key: serial, value: state) in devices.entries) {
      switch (state) {
        case 'device':
          // Doctor sets the reverse itself when the hub has not (yet).
          if (await tools.ensureReverse(serial)) {
            console.ok('Android $serial', 'USB ready: 127.0.0.1:$fixkitPort on the phone reaches this computer (adb reverse)');
          } else {
            broken('Android $serial', 'adb reverse tcp:$fixkitPort failed', 'Unplug and replug the phone, then run doctor again.');
          }
        case 'unauthorized':
          broken('Android $serial', 'USB debugging not allowed yet', 'Unlock the phone and accept the "Allow USB debugging?" prompt.');
        default:
          broken('Android $serial', 'adb says "$state"', 'Unplug and replug the phone (or run `adb kill-server`), then run doctor again.');
      }
    }
  }
  final settings = FixkitSettings.load();
  if (settings.lan) {
    final address = await tools.lanAddress();
    console.ok('Wi-Fi', 'on: phones reach ${address ?? 'this computer'}:$fixkitPort with the token');
  } else {
    console.info('Wi-Fi', 'off: iPhones on Wi-Fi need `dart run fixkit init --lan`');
  }

  console.line();
  if (problems == 0) {
    console.line('  ${console.green('Ready.')} Run the app, then say "watch for fixes" in your agent chat.');
  } else {
    console.line('  ${console.red('$problems problem${problems == 1 ? '' : 's'}')} found; the hints above fix them.');
  }
  console.line();
  return problems == 0 ? 0 : 1;
}

Future<bool> _portTaken() async {
  try {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, fixkitPort, timeout: const Duration(seconds: 1));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
