import 'package:fixkit/src/cli/main_patch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('wrapRunApp', () {
    test('wraps the argument and adds the import after the last import', () {
      const source = '''
import 'package:flutter/material.dart';
import 'app.dart';

void main() => runApp(const MyApp());
''';
      final result = wrapRunApp(source);
      expect(result.changes, 1);
      expect(result.source, contains('runApp(FixKit(child: const MyApp()))'));
      expect(result.source, contains("import 'app.dart';\nimport 'package:fixkit/fixkit.dart';"));
    });

    test('keeps multi-line arguments and drops a trailing comma', () {
      const source = '''
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ProviderScope(
      child: MyApp(title: 'a (tricky) title'),
    ),
  );
}
''';
      final result = wrapRunApp(source);
      expect(result.changes, 1);
      expect(result.source, contains("runApp(FixKit(child: ProviderScope(\n      child: MyApp(title: 'a (tricky) title'),\n    )));"));
    });

    test('ignores runApp in comments and strings', () {
      const source = '''
// runApp(Old());
const hint = "call runApp(App())";
/* runApp(Nested(/* runApp(x) */)) */
void main() => runApp(App());
''';
      final result = wrapRunApp(source);
      expect(result.changes, 1);
      expect(result.source, contains('// runApp(Old());'));
      expect(result.source, contains('"call runApp(App())"'));
      expect(result.source, contains('runApp(FixKit(child: App()))'));
    });

    test('handles interpolation and raw strings inside the argument', () {
      const source = r'''
void main() => runApp(App(title: 'Hi ${name.split(')').first}', raw: r'\('));
''';
      final result = wrapRunApp(source);
      expect(result.changes, 1);
      expect(result.source, contains(r"FixKit(child: App(title: 'Hi ${name.split(')').first}', raw: r'\('))"));
    });

    test('is idempotent', () {
      const source = "import 'package:fixkit/fixkit.dart';\nvoid main() => runApp(FixKit(child: App()));\n";
      final result = wrapRunApp(source);
      expect(result.changed, isFalse);
      expect(result.alreadyDone, isTrue);
      expect(result.source, source);
    });

    test('does not touch identifiers that only contain runApp', () {
      const source = 'void main() { myrunApp(App()); runAppLater(App()); }';
      expect(wrapRunApp(source).changed, isFalse);
    });

    test('adds the import at the top when there are none', () {
      final result = wrapRunApp('void main() => runApp(App());\n');
      expect(result.source, startsWith("import 'package:fixkit/fixkit.dart';\n\n"));
    });
  });

  group('unwrapFixKit', () {
    test('restores the child and removes the unused import', () {
      const original = "import 'package:flutter/material.dart';\n\nvoid main() => runApp(const MyApp());\n";
      final wrapped = wrapRunApp(original).source;
      final result = unwrapFixKit(wrapped);
      expect(result.changes, 1);
      expect(result.source, original);
    });

    test('keeps the import while FixName is still used', () {
      const source = "import 'package:fixkit/fixkit.dart';\n"
          'void main() => runApp(FixKit(child: App()));\n'
          "Widget a() => FixName('a', child: B());\n";
      final result = unwrapFixKit(source);
      expect(result.source, contains("import 'package:fixkit/fixkit.dart';"));
      expect(result.source, contains('runApp(App())'));
    });

    test('takes extra arguments and const with it', () {
      const source = 'void main() => runApp(const FixKit(enabled: true, child: App()));';
      expect(unwrapFixKit(source).source, 'void main() => runApp(App());');
    });
  });
}
