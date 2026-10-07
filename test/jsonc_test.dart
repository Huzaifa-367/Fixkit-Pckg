import 'dart:convert';

import 'package:fixkit/src/cli/jsonc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeJsonc', () {
    test('reads comments and trailing commas', () {
      const source = '''
{
  // Line comment
  "a": 1, /* block */
  "b": ["x", "y",],
  "c": {"d": "e // not a comment"},
}
''';
      expect(decodeJsonc(source), {
        'a': 1,
        'b': ['x', 'y'],
        'c': {'d': 'e // not a comment'},
      });
    });

    test('empty text is an empty object', () {
      expect(decodeJsonc('  \n'), <String, Object?>{});
    });

    test('rejects broken JSON', () {
      expect(() => decodeJsonc('{"a": }'), throwsFormatException);
    });
  });

  group('setJsoncValue', () {
    test('creates a file from nothing', () {
      final text = setJsoncValue('', ['mcpServers', 'fixkit'], {'command': 'dart'});
      expect(jsonDecode(text), {
        'mcpServers': {
          'fixkit': {'command': 'dart'},
        },
      });
    });

    test('adds a server next to existing ones and keeps comments', () {
      const source = '''
{
  // My servers
  "mcpServers": {
    "github": {"command": "gh"}
  }
}
''';
      final text = setJsoncValue(source, ['mcpServers', 'fixkit'], {'command': 'dart'});
      expect(text, contains('// My servers'));
      expect(text, contains('"github": {"command": "gh"}'));
      expect(decodeJsonc(text), {
        'mcpServers': {
          'github': {'command': 'gh'},
          'fixkit': {'command': 'dart'},
        },
      });
    });

    test('replaces an existing value in place', () {
      const source = '{\n  "mcpServers": {\n    "fixkit": {"command": "old"},\n    "other": 1\n  }\n}\n';
      final text = setJsoncValue(source, ['mcpServers', 'fixkit'], {'command': 'new'});
      expect(decodeJsonc(text), {
        'mcpServers': {
          'fixkit': {'command': 'new'},
          'other': 1,
        },
      });
      expect(text.indexOf('"fixkit"'), lessThan(text.indexOf('"other"')));
    });

    test('adds the parent object when missing', () {
      const source = '{\n  "editor.fontSize": 14\n}\n';
      final text = setJsoncValue(source, ['servers', 'fixkit'], {'type': 'stdio'});
      expect(decodeJsonc(text), {
        'editor.fontSize': 14,
        'servers': {
          'fixkit': {'type': 'stdio'},
        },
      });
    });

    test('keeps a trailing comma style', () {
      const source = '{\n  "a": 1,\n}\n';
      final text = setJsoncValue(source, ['b'], 2);
      expect(decodeJsonc(text), {'a': 1, 'b': 2});
      expect(text, contains('"b": 2,'));
    });

    test('fills an empty object', () {
      final text = setJsoncValue('{}', ['a'], true);
      expect(jsonDecode(text), {'a': true});
    });

    test('matches the file indentation', () {
      const source = '{\n    "a": {\n        "b": 1\n    }\n}\n';
      final text = setJsoncValue(source, ['a', 'c'], 2);
      expect(text, contains('\n        "c": 2'));
    });
  });

  group('removeJsoncValue', () {
    test('removes a middle member', () {
      const source = '{\n  "a": 1,\n  "b": 2,\n  "c": 3\n}\n';
      expect(decodeJsonc(removeJsoncValue(source, ['b'])), {'a': 1, 'c': 3});
    });

    test('removes the last member and its comma', () {
      const source = '{\n  "servers": {\n    "x": 1,\n    "fixkit": {"command": "dart"}\n  }\n}\n';
      final text = removeJsoncValue(source, ['servers', 'fixkit']);
      expect(jsonDecode(text), {
        'servers': {'x': 1},
      });
    });

    test('removes the only member', () {
      const source = '{\n  "servers": {\n    "fixkit": {"command": "dart"}\n  }\n}\n';
      expect(jsonDecode(removeJsoncValue(source, ['servers', 'fixkit'])), {'servers': <String, Object?>{}});
    });

    test('leaves the text alone when the key is absent', () {
      const source = '{"a": 1}';
      expect(removeJsoncValue(source, ['b']), source);
    });
  });
}
