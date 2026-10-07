import 'dart:io';

import 'package:fixkit/src/server/paths.dart';
import 'package:fixkit/src/server/report.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late Directory project;

  setUp(() => project = makeProject('report'));
  tearDown(() => project.deleteSync(recursive: true));

  test('resolves the project and keeps only its own widgets', () {
    final report = FixReport.fromApp(
      id: 'r1',
      body: appReport(project),
      knownRoots: const [],
      finder: ProjectFinder(),
    );
    expect(report.projectRoot, normalizePath(project.path));
    expect(report.chain.map((frame) => frame.widget), ['Text', 'Row', 'HomePage']);
    expect(report.chain.first.location, 'lib/home.dart:42');
    expect(report.body.containsKey('screenshotPNG'), isFalse);
  });

  test('builds a prompt that leads with the person\'s words', () {
    final report = FixReport.fromApp(id: 'r7', body: appReport(project), knownRoots: const [], finder: ProjectFinder());
    final prompt = report.prompt();
    expect(prompt, startsWith('Make it green\n\n[fix r7] Text "+€4,650.00" · lib/home.dart:42 · Activity screen'));
    expect(prompt, contains('  - Row → lib/home.dart:38'));
    expect(prompt, contains('Nearby text: "Northwind GmbH", "Salary, September"'));
    expect(prompt, isNot(contains('FixKit')));
  });

  test('prefers a known root over the nearest pubspec', () {
    final nested = Directory('${project.path}/packages/ui')..createSync(recursive: true);
    File('${nested.path}/pubspec.yaml').writeAsStringSync('name: ui\n');
    final body = appReport(project)
      ..['chain'] = [
        {'widget': 'Button', 'file': location(project, 'packages/ui/lib/button.dart'), 'line': 3},
        {'widget': 'HomePage', 'file': location(project, 'lib/main.dart'), 'line': 20},
        {'widget': 'App', 'file': location(project, 'lib/main.dart'), 'line': 9},
      ];
    final report = FixReport.fromApp(id: 'r2', body: body, knownRoots: [project.path], finder: ProjectFinder());
    expect(report.projectRoot, normalizePath(project.path));
    expect(report.chain.first.relative, 'packages/ui/lib/button.dart');
  });

  test('works without source locations', () {
    final body = {
      'comment': 'Too small',
      'tracking': false,
      'chain': [
        {'widget': 'RichText'},
        {'widget': 'Text'},
      ],
      'targetText': 'Sign in',
    };
    final report = FixReport.fromApp(id: 'r3', body: body, knownRoots: const [], finder: ProjectFinder());
    expect(report.projectRoot, isNull);
    final prompt = report.prompt();
    expect(prompt, contains('Source locations are off'));
    expect(prompt, contains('Widgets under the finger: RichText < Text'));
    expect(prompt, contains('Pressed text: "Sign in"'));
  });

  test('says when the selection was widened past the pressed widget', () {
    final body = appReport(project)
      ..['chain'] = [
        {'widget': 'Row', 'file': location(project, 'lib/home.dart'), 'line': 38},
        {'widget': 'HomePage', 'file': location(project, 'lib/main.dart'), 'line': 20},
      ]
      ..['pressed'] = {'widget': 'Text', 'file': location(project, 'lib/home.dart'), 'line': 42, 'text': '+€4,650.00'};
    final report = FixReport.fromApp(id: 'r5', body: body, knownRoots: const [], finder: ProjectFinder());
    expect(report.headline, contains('Row'));
    expect(
      report.prompt(),
      contains('Selection: the person pressed Text "+€4,650.00" (lib/home.dart:42) and widened the selection to this Row'),
    );
  });

  test('names a FixName with its declaration', () {
    final body = appReport(project)
      ..['named'] = {'name': 'activity.income', 'file': location(project, 'lib/home.dart'), 'line': 40};
    final report = FixReport.fromApp(id: 'r4', body: body, knownRoots: const [], finder: ProjectFinder());
    expect(report.headline, startsWith('activity.income · Text'));
    expect(report.prompt(), contains('Named: activity.income (FixName at lib/home.dart:40)'));
  });

  test('paths helpers', () {
    expect(isWithin('/a/b', '/a/b/c.dart'), isTrue);
    expect(isWithin('/a/b', '/a/bc/d.dart'), isFalse);
    expect(relativeTo('/a/b', '/a/b/lib/x.dart'), 'lib/x.dart');
    expect(normalizePath(r'C:\Users\me\app\'), 'c:/Users/me/app');
    expect(isOutsideAppCode('/Users/me/.pub-cache/hosted/pub.dev/provider-6.0.0/lib/x.dart'), isTrue);
    expect(isOutsideAppCode('/Users/me/app/lib/x.dart'), isFalse);
  });
}
