/// Wraps the widget passed to `runApp(...)` in `FixKit(child: ...)`, and
/// undoes it. Works on the source text: comments, strings and formatting
/// elsewhere stay as they are.

const String fixkitImport = "import 'package:fixkit/fixkit.dart';";

class PatchResult {
  const PatchResult(this.source, {this.changes = 0, this.alreadyDone = false});

  final String source;

  /// How many `runApp` calls were changed.
  final int changes;

  /// Every `runApp` call was already in the wanted state.
  final bool alreadyDone;

  bool get changed => changes > 0;
}

/// Offsets of code outside comments and strings, so a search never matches
/// `runApp(` inside a comment or a string.
class _Scanner {
  _Scanner(this.s) {
    _scan();
  }

  final String s;

  /// For each offset, whether it is code.
  late final List<bool> code = List<bool>.filled(s.length, true);

  void _scan() {
    var i = 0;
    while (i < s.length) {
      if (s.startsWith('//', i)) {
        final end = s.indexOf('\n', i);
        i = _mark(i, end == -1 ? s.length : end);
      } else if (s.startsWith('/*', i)) {
        var depth = 1;
        var j = i + 2;
        while (j < s.length && depth > 0) {
          if (s.startsWith('/*', j)) {
            depth++;
            j += 2;
          } else if (s.startsWith('*/', j)) {
            depth--;
            j += 2;
          } else {
            j++;
          }
        }
        i = _mark(i, j);
      } else if (_isStringStart(i)) {
        i = _mark(i, _stringEnd(i));
      } else {
        i++;
      }
    }
  }

  int _mark(int from, int to) {
    for (var k = from; k < to && k < s.length; k++) {
      code[k] = false;
    }
    return to;
  }

  bool _isStringStart(int i) {
    final c = s[i];
    if (c == '"' || c == "'") return true;
    if ((c == 'r' || c == 'R') && i + 1 < s.length && (s[i + 1] == '"' || s[i + 1] == "'")) {
      return i == 0 || !_isIdentifierChar(s[i - 1]);
    }
    return false;
  }

  /// The offset after the string literal starting at [i].
  int _stringEnd(int i) {
    var raw = false;
    if (s[i] == 'r' || s[i] == 'R') {
      raw = true;
      i++;
    }
    final quote = s[i];
    final triple = s.startsWith(quote * 3, i);
    final close = triple ? quote * 3 : quote;
    var j = i + close.length;
    while (j < s.length) {
      if (!raw && s[j] == r'\') {
        j += 2;
        continue;
      }
      if (!raw && s.startsWith(r'${', j)) {
        j = _interpolationEnd(j + 2);
        continue;
      }
      if (s.startsWith(close, j)) return j + close.length;
      if (!triple && s[j] == '\n') return j;
      j++;
    }
    return s.length;
  }

  /// The offset after the `}` closing an interpolation that starts at [i].
  int _interpolationEnd(int i) {
    var depth = 1;
    var j = i;
    while (j < s.length && depth > 0) {
      if (_isStringStart(j)) {
        j = _stringEnd(j);
        continue;
      }
      if (s[j] == '{') depth++;
      if (s[j] == '}') depth--;
      j++;
    }
    return j;
  }

  /// The offset of the `)` matching the `(` at [open], or -1.
  int matchingParen(int open) {
    var depth = 0;
    for (var j = open; j < s.length; j++) {
      if (!code[j]) continue;
      final c = s[j];
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') {
        depth--;
        if (depth == 0) return c == ')' ? j : -1;
      }
    }
    return -1;
  }

  /// Offsets in code where [word] starts as a whole identifier followed by `(`;
  /// returns the offsets of the `(`.
  List<int> calls(String word) {
    final found = <int>[];
    var from = 0;
    while (true) {
      final at = s.indexOf(word, from);
      if (at == -1) break;
      from = at + word.length;
      if (!code[at]) continue;
      if (at > 0 && (_isIdentifierChar(s[at - 1]) || s[at - 1] == r'$')) continue;
      var j = at + word.length;
      if (j < s.length && _isIdentifierChar(s[j])) continue;
      while (j < s.length && ' \t\r\n'.contains(s[j])) {
        j++;
      }
      // Generic calls such as runApp<T>( are not expected; plain calls only.
      if (j < s.length && s[j] == '(' && code[j]) found.add(j);
    }
    return found;
  }
}

bool _isIdentifierChar(String c) {
  final unit = c.codeUnitAt(0);
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      c == '_';
}

/// Whether [source] calls `runApp(`.
bool hasRunApp(String source) => _Scanner(source).calls('runApp').isNotEmpty;

/// Wraps the argument of every `runApp(...)` in `FixKit(child: ...)` and adds
/// the import.
PatchResult wrapRunApp(String source) {
  final scanner = _Scanner(source);
  final opens = scanner.calls('runApp');
  if (opens.isEmpty) return PatchResult(source);

  var result = source;
  var changes = 0;
  // From the end, so earlier offsets stay valid.
  for (final open in opens.reversed) {
    final close = scanner.matchingParen(open);
    if (close == -1) continue;
    final inner = source.substring(open + 1, close);
    var argument = inner.trim();
    if (argument.endsWith(',')) argument = argument.substring(0, argument.length - 1).trimRight();
    if (argument.isEmpty) continue;
    if (RegExp(r'^(const\s+)?FixKit\s*\(').hasMatch(argument)) continue;
    result = result.replaceRange(open + 1, close, 'FixKit(child: $argument)');
    changes++;
  }
  if (changes == 0) return PatchResult(source, alreadyDone: true);
  return PatchResult(addImport(result), changes: changes);
}

/// Replaces every `FixKit(... child: X ...)` with `X`, and removes the import
/// when nothing from fixkit is used any more.
PatchResult unwrapFixKit(String source) {
  var result = source;
  var changes = 0;
  while (true) {
    final scanner = _Scanner(result);
    final opens = scanner.calls('FixKit');
    if (opens.isEmpty) break;
    final open = opens.first;
    final close = scanner.matchingParen(open);
    if (close == -1) break;
    final child = _namedArgument(result, scanner, open, close, 'child');
    if (child == null) break;
    // Take a `const ` in front of the call with it.
    var start = result.lastIndexOf('FixKit', open);
    final before = result.substring(0, start);
    final constMatch = RegExp(r'const\s+$').firstMatch(before);
    if (constMatch != null) start = constMatch.start;
    result = result.replaceRange(start, close + 1, child);
    changes++;
  }
  if (changes == 0) return PatchResult(source, alreadyDone: true);
  return PatchResult(_removeImportIfUnused(result), changes: changes);
}

/// The text of the named argument [name] of the call whose parentheses are at
/// [open] and [close].
String? _namedArgument(String s, _Scanner scanner, int open, int close, String name) {
  var depth = 0;
  var start = open + 1;
  final parts = <(int, int)>[];
  for (var j = open + 1; j < close; j++) {
    if (!scanner.code[j]) continue;
    final c = s[j];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ',' && depth == 0) {
      parts.add((start, j));
      start = j + 1;
    }
  }
  parts.add((start, close));
  for (final (from, to) in parts) {
    final text = s.substring(from, to).trim();
    final match = RegExp('^$name\\s*:\\s*').firstMatch(text);
    if (match != null) return text.substring(match.end).trim();
  }
  return null;
}

/// Adds the fixkit import after the last import, if it is not there.
String addImport(String source) {
  if (source.contains(fixkitImport) || source.contains('import "package:fixkit/fixkit.dart";')) return source;
  final imports = RegExp(r'''^import\s+['"][^'"]+['"][^;]*;[ \t]*$''', multiLine: true).allMatches(source).toList();
  if (imports.isNotEmpty) {
    final end = imports.last.end;
    return source.replaceRange(end, end, '\n$fixkitImport');
  }
  final library = RegExp(r'^library[^;]*;[ \t]*$', multiLine: true).firstMatch(source);
  if (library != null) return source.replaceRange(library.end, library.end, '\n\n$fixkitImport');
  return '$fixkitImport\n\n$source';
}

String _removeImportIfUnused(String source) {
  final withoutImport = source
      .replaceAll(RegExp(r'''^import\s+['"]package:fixkit/fixkit\.dart['"];[ \t]*\r?\n''', multiLine: true), '');
  final scanner = _Scanner(withoutImport);
  final used = ['FixKit', 'FixName', 'FixScreen'].any((name) => scanner.calls(name).isNotEmpty);
  return used ? source : withoutImport;
}
