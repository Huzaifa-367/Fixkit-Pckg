import 'dart:io';

import 'package:fixkit/src/server/host_tools.dart';

/// HostTools that touch nothing on the computer and record what they were
/// asked to do.
class FakeHostTools extends HostTools {
  final List<String> clipboard = [];
  final List<String> notifications = [];

  @override
  Future<bool> copyToClipboard(String text) async {
    clipboard.add(text);
    return true;
  }

  @override
  Future<void> notify(String title, String body) async => notifications.add('$title: $body');

  @override
  Future<void> reverseAndroidPorts({int port = 4747}) async {}

  @override
  String? findAdb() => null;

  @override
  Future<String?> lanAddress() async => '192.168.1.20';
}

/// A throwaway Flutter project: a pubspec and a lib folder.
Directory makeProject(String name) {
  final dir = Directory.systemTemp.createTempSync('fixkit_$name');
  File('${dir.path}/pubspec.yaml').writeAsStringSync('name: $name\n');
  Directory('${dir.path}/lib').createSync();
  File('${dir.path}/lib/main.dart').writeAsStringSync('void main() {}\n');
  return dir;
}

/// A creation location for a file in [project], as the app sends it.
String location(Directory project, String relative) => Uri.file('${project.path}/$relative').toString();

/// The smallest valid PNG, for screenshot plumbing.
const String tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==';

/// A report body as the app sends it, pressed on a Text in lib/home.dart.
Map<String, Object?> appReport(Directory project, {String comment = 'Make it green', bool screenshot = true}) => {
      'protocol': 1,
      'comment': comment,
      'platform': 'android',
      'touch': {'x': 120.0, 'y': 300.0},
      'tracking': true,
      'chain': [
        {'widget': 'RichText', 'file': 'file:///sdk/flutter/packages/flutter/lib/src/widgets/text.dart', 'line': 600},
        {'widget': 'Text', 'file': location(project, 'lib/home.dart'), 'line': 42, 'column': 13, 'text': '+€4,650.00'},
        {'widget': 'Row', 'file': location(project, 'lib/home.dart'), 'line': 38, 'column': 12},
        {'widget': 'HomePage', 'file': location(project, 'lib/main.dart'), 'line': 20, 'column': 15},
        {'widget': 'FixKit', 'file': location(project, 'lib/main.dart'), 'line': 8, 'column': 23},
      ],
      'targetText': '+€4,650.00',
      'nearby': ['Northwind GmbH', 'Salary, September'],
      'screen': 'Activity',
      if (screenshot) 'screenshotPNG': tinyPngBase64,
    };
