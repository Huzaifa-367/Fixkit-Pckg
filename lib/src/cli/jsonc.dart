import 'dart:convert';

/// Reads and edits JSON with comments and trailing commas (the format of VS
/// Code's settings and most editors' MCP configs) without reformatting the
/// file: an edit replaces or inserts text where it belongs and leaves every
/// other byte, comments included, as it was.

sealed class JNode {
  JNode(this.start, this.end);

  /// Offsets in the source: [start, end).
  final int start;
  final int end;
}

class JObject extends JNode {
  JObject(super.start, super.end, this.members);

  final List<JMember> members;

  JMember? member(String key) {
    for (final member in members) {
      if (member.key == key) return member;
    }
    return null;
  }
}

class JMember {
  JMember(this.key, this.keyStart, this.value);

  final String key;
  final int keyStart;
  final JNode value;
}

class JArray extends JNode {
  JArray(super.start, super.end, this.items);

  final List<JNode> items;
}

class JScalar extends JNode {
  JScalar(super.start, super.end, this.value);

  final Object? value;
}

class JsoncException implements FormatException {
  JsoncException(this.message, this.offset, this.source);

  @override
  final String message;
  @override
  final int offset;
  @override
  final String source;

  @override
  String toString() => 'Invalid JSON at offset $offset: $message';
}

/// Parses [source]; the root must be a value (usually an object).
JNode parseJsonc(String source) {
  final parser = _Parser(source);
  parser.skip();
  final node = parser.value();
  parser.skip();
  if (parser.i != source.length) throw JsoncException('unexpected text', parser.i, source);
  return node;
}

/// The plain Dart value of [node].
Object? jsoncValue(JNode node) => switch (node) {
      JObject(:final members) => {for (final member in members) member.key: jsoncValue(member.value)},
      JArray(:final items) => [for (final item in items) jsoncValue(item)],
      JScalar(:final value) => value,
    };

/// Decodes JSONC to a plain value. Empty text decodes to an empty object.
Object? decodeJsonc(String source) {
  if (source.trim().isEmpty) return <String, Object?>{};
  return jsoncValue(parseJsonc(source));
}

class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  Never fail(String message) => throw JsoncException(message, i, s);

  /// Whitespace and comments.
  void skip() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xFEFF) {
        i++;
      } else if (s.startsWith('//', i)) {
        final end = s.indexOf('\n', i);
        i = end == -1 ? s.length : end + 1;
      } else if (s.startsWith('/*', i)) {
        final end = s.indexOf('*/', i + 2);
        if (end == -1) fail('unclosed comment');
        i = end + 2;
      } else {
        return;
      }
    }
  }

  JNode value() {
    if (i >= s.length) fail('expected a value');
    final c = s[i];
    if (c == '{') return object();
    if (c == '[') return array();
    if (c == '"') {
      final start = i;
      final text = string();
      return JScalar(start, i, text);
    }
    return scalar();
  }

  JObject object() {
    final start = i;
    i++; // {
    final members = <JMember>[];
    while (true) {
      skip();
      if (i >= s.length) fail('unclosed object');
      if (s[i] == '}') {
        i++;
        return JObject(start, i, members);
      }
      if (s[i] != '"') fail('expected a key');
      final keyStart = i;
      final key = string();
      skip();
      if (i >= s.length || s[i] != ':') fail('expected ":"');
      i++;
      skip();
      members.add(JMember(key, keyStart, value()));
      skip();
      if (i < s.length && s[i] == ',') {
        i++;
        continue;
      }
      skip();
      if (i < s.length && s[i] == '}') continue;
      fail('expected "," or "}"');
    }
  }

  JArray array() {
    final start = i;
    i++; // [
    final items = <JNode>[];
    while (true) {
      skip();
      if (i >= s.length) fail('unclosed array');
      if (s[i] == ']') {
        i++;
        return JArray(start, i, items);
      }
      items.add(value());
      skip();
      if (i < s.length && s[i] == ',') {
        i++;
        continue;
      }
      skip();
      if (i < s.length && s[i] == ']') continue;
      fail('expected "," or "]"');
    }
  }

  String string() {
    final start = i;
    i++; // opening quote
    while (i < s.length) {
      final c = s[i];
      if (c == '\\') {
        i += 2;
      } else if (c == '"') {
        i++;
        return jsonDecode(s.substring(start, i)) as String;
      } else {
        i++;
      }
    }
    fail('unclosed string');
  }

  JScalar scalar() {
    final start = i;
    while (i < s.length && !' \t\r\n,}]/'.contains(s[i])) {
      i++;
    }
    final text = s.substring(start, i);
    if (text.isEmpty) fail('expected a value');
    try {
      return JScalar(start, i, jsonDecode(text));
    } catch (_) {
      fail('invalid value "$text"');
    }
  }
}

/// The indentation of the line [offset] is on.
String _indentAt(String s, int offset) {
  final lineStart = s.lastIndexOf('\n', offset > 0 ? offset - 1 : 0) + 1;
  var end = lineStart;
  while (end < s.length && (s[end] == ' ' || s[end] == '\t')) {
    end++;
  }
  return s.substring(lineStart, end);
}

/// The unit of indentation the file uses: two spaces unless it shows another.
String _indentUnit(String s) {
  final match = RegExp(r'\n([ \t]+)\S').firstMatch(s);
  return match?.group(1) ?? '  ';
}

/// [value] as JSON, indented to sit at [indent] in a file indented by [unit].
String _encode(Object? value, String indent, String unit) {
  final text = JsonEncoder.withIndent(unit).convert(value);
  return text.split('\n').join('\n$indent');
}

/// Sets `path[0].path[1]...[key] = value` in [source], creating the objects on
/// the way, and returns the new text. Leaves the rest of the text as it was.
/// [source] may be empty.
String setJsoncValue(String source, List<String> path, Object? value) {
  if (source.trim().isEmpty) {
    Object? nested = value;
    for (final key in path.reversed) {
      nested = {key: nested};
    }
    return '${const JsonEncoder.withIndent('  ').convert(nested)}\n';
  }
  final root = parseJsonc(source);
  if (root is! JObject) throw JsoncException('the file is not a JSON object', 0, source);
  final unit = _indentUnit(source);

  var object = root;
  for (var depth = 0; depth < path.length; depth++) {
    final key = path[depth];
    final member = object.member(key);
    final last = depth == path.length - 1;
    if (member == null) {
      // Insert the rest of the path as one nested value.
      Object? nested = value;
      for (final rest in path.sublist(depth + 1).reversed) {
        nested = {rest: nested};
      }
      return _insertMember(source, object, key, nested, unit);
    }
    if (last) return _replace(source, member.value, value, unit);
    final next = member.value;
    if (next is! JObject) {
      // Something other than an object is in the way: replace it.
      Object? nested = value;
      for (final rest in path.sublist(depth + 1).reversed) {
        nested = {rest: nested};
      }
      return _replace(source, next, nested, unit);
    }
    object = next;
  }
  return source;
}

/// Removes `path[0]...[key]` from [source] if present.
String removeJsoncValue(String source, List<String> path) {
  if (source.trim().isEmpty) return source;
  final root = parseJsonc(source);
  if (root is! JObject) return source;
  var object = root;
  for (var depth = 0; depth < path.length; depth++) {
    final member = object.member(path[depth]);
    if (member == null) return source;
    if (depth == path.length - 1) return _removeMember(source, object, member);
    final next = member.value;
    if (next is! JObject) return source;
    object = next;
  }
  return source;
}

String _replace(String s, JNode node, Object? value, String unit) {
  final indent = _indentAt(s, node.start);
  return s.replaceRange(node.start, node.end, _encode(value, indent, unit));
}

String _insertMember(String s, JObject object, String key, Object? value, String unit) {
  final closing = object.end - 1; // the "}"
  final objectIndent = _indentAt(s, object.start);
  final memberIndent = object.members.isEmpty ? '$objectIndent$unit' : _indentAt(s, object.members.last.keyStart);
  final entry = '${jsonEncode(key)}: ${_encode(value, memberIndent, unit)}';

  if (object.members.isEmpty) {
    return s.replaceRange(object.start, object.end, '{\n$memberIndent$entry\n$objectIndent}');
  }

  // After the last member's value (and a trailing comma, if the file has one).
  final last = object.members.last.value;
  var at = last.end;
  var probe = at;
  while (probe < closing && ' \t\r\n'.contains(s[probe])) {
    probe++;
  }
  final hasTrailingComma = probe < closing && s[probe] == ',';
  if (hasTrailingComma) {
    at = probe + 1;
    return s.replaceRange(at, at, '\n$memberIndent$entry,');
  }
  return s.replaceRange(at, at, ',\n$memberIndent$entry');
}

String _removeMember(String s, JObject object, JMember member) {
  final index = object.members.indexOf(member);
  var start = member.keyStart;
  var end = member.value.end;

  // Take the comma after it, or the one before it when it is last.
  var probe = end;
  while (probe < s.length && ' \t\r\n'.contains(s[probe])) {
    probe++;
  }
  if (probe < s.length && s[probe] == ',') {
    end = probe + 1;
  } else if (index > 0) {
    var back = start - 1;
    while (back > 0 && ' \t\r\n'.contains(s[back])) {
      back--;
    }
    if (s[back] == ',') start = back;
  }
  // Take the line the member was on when it is left empty.
  final lineStart = s.lastIndexOf('\n', start - 1) + 1;
  if (s.substring(lineStart, start).trim().isEmpty) start = lineStart > 0 ? lineStart - 1 : lineStart;
  return s.replaceRange(start, end, '');
}
