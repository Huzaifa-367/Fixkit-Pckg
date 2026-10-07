import 'dart:io';

import '../protocol.dart';
import '../server/hub_client.dart';
import 'console.dart';
import 'project.dart';
import 'versions.dart';

/// `dart run fixkit upgrade [version]`: moves the project to the newest (or
/// the given) release, whether fixkit comes from pub.dev or from git, then
/// refreshes the setup with the new version.
Future<int> runUpgrade(List<String> arguments, Console console) async {
  final project = Project.find();
  if (project == null) {
    console.line('${console.red('✖')} No pubspec.yaml here or above. Run this in your Flutter project.');
    return 1;
  }
  final installed = readInstalled(project);
  final current = installed.lockedVersion ?? currentVersion;
  console.title('fixkit upgrade  ${console.dim(installed.describe())}');

  switch (installed.source) {
    case FixkitSource.unknown:
      console.fail('pubspec.yaml', 'fixkit is not a dependency');
      console.hint('Add it as shown in the README, then run `flutter pub get` and `dart run fixkit init`.');
      return 1;
    case FixkitSource.path:
      console.fail('pubspec.yaml', 'fixkit comes from a local path (${installed.path})');
      console.hint('Update that checkout instead, then run `dart run fixkit init --refresh`.');
      return 1;
    case FixkitSource.hosted:
    case FixkitSource.git:
      break;
  }

  // The release to move to: the one asked for, else the newest.
  final asked = arguments.where((argument) => !argument.startsWith('-')).firstOrNull;
  Semver? target;
  if (asked != null) {
    target = Semver.tryParse(asked);
    if (target == null) {
      console.fail('Version', '"$asked" is not a version like 0.1.5');
      return 64;
    }
  } else {
    console.info('Latest', installed.source == FixkitSource.git ? 'reading the tags on GitHub...' : 'asking pub.dev...');
    target = await latestRelease(installed);
    if (target == null) {
      console.fail('Latest', 'could not reach ${installed.source == FixkitSource.git ? 'GitHub' : 'pub.dev'}');
      console.hint('Pass the version yourself: dart run fixkit upgrade 0.1.5');
      return 1;
    }
  }

  final force = arguments.contains('--force');
  if (target == current && !force) {
    console.ok('fixkit', 'already on $current');
    _refreshHere(project, console);
    return 0;
  }
  if (target < current && !force) {
    console.warn('fixkit', '$target is older than $current; pass --force to go back');
    return 1;
  }

  // Edit pubspec.yaml, keeping the original to put back if pub fails.
  final pubspecFile = project.file('pubspec.yaml');
  final original = pubspecFile.readAsStringSync();
  final updated = installed.source == FixkitSource.git ? setGitRef(original, target) : setHostedConstraint(original, target);
  pubspecFile.writeAsStringSync(updated);
  console.ok(
    'pubspec.yaml',
    installed.source == FixkitSource.git ? 'ref: v$target' : 'fixkit: ^$target',
  );

  console.line(console.dim('  flutter pub get'));
  final pub = await Process.start(
    flutterExecutable(),
    ['pub', 'get'],
    workingDirectory: project.root,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  if (await pub.exitCode != 0) {
    pubspecFile.writeAsStringSync(original);
    console.fail('pub get', 'failed; pubspec.yaml is back as it was');
    return 1;
  }

  // The rest runs with the new fixkit's own code. On Windows this process
  // holds the old snapshot open, so the refresh is left to the next command.
  if (Platform.isWindows) {
    console.line('  ${console.green('Upgraded')} fixkit $current → $target.');
    console.line('  Now run ${console.cyan('dart run fixkit init --refresh')} (or just reload your editor window).');
    console.line();
    return 0;
  }
  console.line(console.dim('  dart run fixkit init --refresh'));
  final init = await Process.start(
    dartExecutable(),
    ['run', 'fixkit', 'init', '--refresh'],
    workingDirectory: project.root,
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await init.exitCode;
  if (code != 0) {
    console.warn('init', 'the refresh reported a problem; run `dart run fixkit doctor`');
    return code;
  }
  console.line('  ${console.green('Upgraded')} fixkit $current → $target.');
  console.line();
  return 0;
}

void _refreshHere(Project project, Console console) {
  final changed = refreshProject(project);
  if (changed.isEmpty) {
    console.ok('Setup', 'up to date');
  } else {
    console.ok('Setup', 'refreshed ${changed.join(', ')}');
  }
}

/// `dart run fixkit version`: what is installed, what is running, what is new.
Future<int> runVersion(List<String> arguments, Console console) async {
  final project = Project.find();
  final installed = project == null ? null : readInstalled(project);
  final hub = HubClient();
  final hello = await hub.hello();
  hub.close();
  final latest = installed == null || installed.source == FixkitSource.unknown || arguments.contains('--offline')
      ? null
      : await latestRelease(installed, timeout: const Duration(seconds: 3));

  final parts = <String>[
    'fixkit $fixkitVersion',
    if (installed != null) '(${installed.describe()})',
    'protocol $fixkitProtocol',
    hello == null ? 'hub not running' : 'hub ${hello['version']}',
    if (latest != null) latest > currentVersion ? 'latest $latest: run `dart run fixkit upgrade`' : 'up to date',
  ];
  console.line(parts.join('  ·  '));
  return 0;
}
