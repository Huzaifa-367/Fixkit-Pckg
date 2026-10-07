import 'dart:io';

import 'package:fixkit/src/cli/project.dart';
import 'package:fixkit/src/cli/templates.dart';
import 'package:fixkit/src/cli/versions.dart';
import 'package:fixkit/src/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('one version everywhere', () {
    test('pubspec.yaml and fixkitVersion agree', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final version = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec)![1];
      expect(version, fixkitVersion);
      expect(Semver.tryParse(fixkitVersion), isNotNull);
    });

    test('the README installs this version from pub.dev and from git', () {
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('fixkit: ^$fixkitVersion'));
      expect(readme, contains('ref: v$fixkitVersion'));
      expect(readme, contains('url: $fixkitRepository.git'));
    });

    test('the changelog has this version and an Unreleased section on top', () {
      final changelog = File('CHANGELOG.md').readAsStringSync();
      final headings = RegExp(r'^## (.+)$', multiLine: true).allMatches(changelog).map((m) => m[1]!.trim()).toList();
      expect(headings.first, 'Unreleased');
      expect(headings, contains(fixkitVersion));
    });

    test('the repository URL matches pubspec.yaml', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('repository: $fixkitRepository'));
    });
  });

  group('Semver', () {
    test('parses with or without v, with pre-releases', () {
      expect(Semver.tryParse('v1.2.3').toString(), '1.2.3');
      expect(Semver.tryParse('1.2.3-beta.2')!.pre, 'beta.2');
      expect(Semver.tryParse('1.2'), isNull);
      expect(Semver.tryParse('main'), isNull);
    });

    test('orders releases after their pre-releases', () {
      final versions = ['1.0.0', '0.9.9', '1.0.0-beta.10', '1.0.0-beta.2', '0.10.0'].map((v) => Semver.tryParse(v)!).toList()
        ..sort();
      expect(versions.map((v) => '$v'), ['0.9.9', '0.10.0', '1.0.0-beta.2', '1.0.0-beta.10', '1.0.0']);
      expect(Semver.tryParse('0.1.4') == Semver.tryParse('v0.1.4'), isTrue);
    });

    test('bumps', () {
      final v = Semver.tryParse('0.1.4')!;
      expect('${v.bump('patch')}', '0.1.5');
      expect('${v.bump('minor')}', '0.2.0');
      expect('${v.bump('major')}', '1.0.0');
      expect('${Semver.tryParse('0.2.0-rc.1')!.bump('patch')}', '0.2.0');
    });
  });

  group('reading the dependency', () {
    const lock = '''
packages:
  collection:
    dependency: transitive
    version: "1.18.0"
  fixkit:
    dependency: "direct main"
    description:
      path: "."
      ref: "v0.1.4"
      resolved-ref: "0123456789abcdef"
      url: "https://github.com/Huzaifa-367/Fixkit-Pckg.git"
    source: git
    version: "0.1.4"
  flutter:
    dependency: "direct main"
''';

    test('pub.dev', () {
      final installed = parseInstalled('name: app\ndependencies:\n  flutter:\n    sdk: flutter\n  fixkit: ^0.1.4 # agent fixes\n');
      expect(installed.source, FixkitSource.hosted);
      expect(installed.constraint, '^0.1.4');
    });

    test('git, with the lock', () {
      const pubspec = '''
name: app
dependencies:
  fixkit:
    git:
      url: https://github.com/Huzaifa-367/Fixkit-Pckg.git
      ref: v0.1.4
  http: ^1.0.0
''';
      final installed = parseInstalled(pubspec, lock: lock);
      expect(installed.source, FixkitSource.git);
      expect(installed.gitUrl, 'https://github.com/Huzaifa-367/Fixkit-Pckg.git');
      expect(installed.gitRef, 'v0.1.4');
      expect(installed.lockedVersion.toString(), '0.1.4');
      expect(installed.resolvedRef, '0123456789abcdef');
      expect(installed.describe(), 'git v0.1.4 @ 0123456 → 0.1.4');
    });

    test('path, and not found', () {
      expect(parseInstalled('dependencies:\n  fixkit:\n    path: ../fixkit\n').source, FixkitSource.path);
      expect(parseInstalled('dependencies:\n  flutter:\n    sdk: flutter\n').source, FixkitSource.unknown);
      // A key named fixkit elsewhere is not the dependency.
      expect(parseInstalled('flutter:\n  fixkit: true\n').source, FixkitSource.unknown);
    });

    test('github repo from URLs', () {
      expect(githubRepo('https://github.com/Huzaifa-367/Fixkit-Pckg.git'), 'Huzaifa-367/Fixkit-Pckg');
      expect(githubRepo('git@github.com:Huzaifa-367/Fixkit-Pckg.git'), 'Huzaifa-367/Fixkit-Pckg');
      expect(githubRepo('https://gitlab.com/a/b'), isNull);
    });
  });

  group('moving to another version', () {
    final next = Semver.tryParse('0.1.5')!;

    test('pub.dev constraint', () {
      const pubspec = 'dependencies:\n  fixkit: ^0.1.4\n  http: ^1.0.0\n';
      expect(setHostedConstraint(pubspec, next), 'dependencies:\n  fixkit: ^0.1.5\n  http: ^1.0.0\n');
    });

    test('git ref', () {
      const pubspec = 'dependencies:\n  fixkit:\n    git:\n      url: https://github.com/Huzaifa-367/Fixkit-Pckg.git\n      ref: v0.1.4\n';
      expect(setGitRef(pubspec, next), contains('      ref: v0.1.5\n'));
      expect(setGitRef(pubspec, next), isNot(contains('v0.1.4')));
    });

    test('git without a ref gets one', () {
      const pubspec = 'dependencies:\n  fixkit:\n    git:\n      url: https://github.com/Huzaifa-367/Fixkit-Pckg.git\n  http: any\n';
      final updated = setGitRef(pubspec, next);
      expect(updated, contains('      url: https://github.com/Huzaifa-367/Fixkit-Pckg.git\n      ref: v0.1.5\n  http: any\n'));
    });

    test('one-line git becomes a block with the ref', () {
      const pubspec = 'dependencies:\n  fixkit:\n    git: https://github.com/Huzaifa-367/Fixkit-Pckg.git\n';
      final updated = setGitRef(pubspec, next);
      expect(parseInstalled(updated).gitRef, 'v0.1.5');
      expect(parseInstalled(updated).gitUrl, 'https://github.com/Huzaifa-367/Fixkit-Pckg.git');
    });
  });

  group('the project setup follows the version', () {
    late Directory dir;
    late Project project;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('fixkit_version');
      File('${dir.path}/pubspec.yaml').writeAsStringSync('name: app\ndependencies:\n  fixkit: ^0.1.4\n');
      Directory('${dir.path}/lib').createSync();
      File('${dir.path}/lib/main.dart').writeAsStringSync('void main() => runApp(FixKit(child: App()));\n');
      project = Project(dir.path);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('nothing to do for a project fixkit never set up', () {
      expect(refreshIfUpgraded(dir.path), isEmpty);
    });

    test('an older setup is refreshed once, and the code is left alone', () {
      project.launcher
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('// written by an older fixkit\n');
      File('${dir.path}/.fixkit/state.json').writeAsStringSync('{"version": "0.1.0"}');
      File('${dir.path}/AGENTS.md').writeAsStringSync('# Agents\n\n$agentsStart\nold rules\n$agentsEnd\n');
      final main = File('${dir.path}/lib/main.dart').readAsStringSync();

      final changed = refreshIfUpgraded(dir.path);
      expect(changed, containsAll(['.fixkit/mcp.dart', 'AGENTS.md', '.fixkit/state.json']));
      expect(project.launcher.readAsStringSync(), launcherSource);
      expect(File('${dir.path}/AGENTS.md').readAsStringSync(), contains('wait_for_fix_report'));
      expect(File('${dir.path}/AGENTS.md').readAsStringSync(), startsWith('# Agents\n'));
      expect(readStamp(project), currentVersion);
      expect(File('${dir.path}/lib/main.dart').readAsStringSync(), main);

      // Once is enough.
      expect(refreshIfUpgraded(dir.path), isEmpty);
    });
  });
}
