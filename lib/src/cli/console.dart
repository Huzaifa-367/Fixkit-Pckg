import 'dart:io';

/// Terminal output with ✔ / ! / ✖ marks, colored when the terminal allows.
class Console {
  Console({IOSink? out, bool? color})
      : out = out ?? stdout,
        color = color ?? (stdout.hasTerminal && stdout.supportsAnsiEscapes && !Platform.environment.containsKey('NO_COLOR'));

  final IOSink out;
  final bool color;

  String _paint(String code, String text) => color ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String text) => _paint('1', text);
  String dim(String text) => _paint('2', text);
  String green(String text) => _paint('32', text);
  String yellow(String text) => _paint('33', text);
  String red(String text) => _paint('31', text);
  String cyan(String text) => _paint('36', text);

  void line([String text = '']) => out.writeln(text);

  void title(String text) {
    line();
    line(bold(text));
    line();
  }

  void ok(String label, [String? detail]) => _row(green('✔'), label, detail);
  void warn(String label, [String? detail]) => _row(yellow('!'), label, detail);
  void fail(String label, [String? detail]) => _row(red('✖'), label, detail);
  void info(String label, [String? detail]) => _row(dim('·'), label, detail);

  void _row(String mark, String label, String? detail) {
    final padded = label.padRight(16);
    line('  $mark ${bold(padded)}${detail == null ? '' : ' $detail'}');
  }

  /// An indented hint under a row.
  void hint(String text) => line('      ${dim(text)}');
}
