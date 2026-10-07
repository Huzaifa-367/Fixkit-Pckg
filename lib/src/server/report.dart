import 'dart:async';

import '../protocol.dart';
import 'paths.dart';

/// One widget of the pressed widget's chain, resolved against the project.
class ChainFrame {
  const ChainFrame({
    required this.widget,
    required this.path,
    required this.relative,
    this.line,
    this.column,
    this.text,
  });

  final String widget;

  /// Absolute path of the file the widget is constructed in.
  final String path;

  /// The same path relative to the project root.
  final String relative;
  final int? line;
  final int? column;
  final String? text;

  String get location => line == null ? relative : '$relative:$line';

  String describe() {
    final label = text == null ? widget : '$widget ${_quote(text!)}';
    return '$label → $location';
  }

  Map<String, Object?> toJson() => {
        'widget': widget,
        'file': relative,
        if (line != null) 'line': line,
        if (column != null) 'column': column,
        if (text != null) 'text': text,
      };
}

/// A fix request from the app, as the hub keeps it.
class FixReport {
  FixReport({
    required this.id,
    required this.comment,
    required this.body,
    required this.projectRoot,
    required this.chain,
    required this.receivedAt,
  }) : updatedAt = receivedAt;

  /// Builds a report from what the app sent. [knownRoots] are the projects
  /// the hub's agents and runners have open; [finder] finds the project of a
  /// file otherwise.
  factory FixReport.fromApp({
    required String id,
    required Map<String, Object?> body,
    required Iterable<String> knownRoots,
    required ProjectFinder finder,
    DateTime? now,
  }) {
    final rawChain = body['chain'] is List ? body['chain'] as List : const [];
    final frames = <({Map<String, Object?> raw, String path, String root})>[];
    final votes = <String, int>{};
    final known = knownRoots.map(normalizePath).toList()..sort((a, b) => b.length.compareTo(a.length));

    for (final item in rawChain) {
      if (item is! Map) continue;
      final raw = item.cast<String, Object?>();
      final file = raw['file'];
      if (file is! String) continue;
      final path = pathFromLocation(file);
      if (path == null || isOutsideAppCode(path)) continue;
      final root = known.where((r) => isWithin(r, path)).firstOrNull ?? finder.rootOf(path);
      if (root == null) continue;
      frames.add((raw: raw, path: path, root: root));
      votes[root] = (votes[root] ?? 0) + 1;
    }

    // The project most of the chain lives in; on a tie, the innermost frame's.
    String? projectRoot;
    var best = 0;
    for (final frame in frames) {
      final count = votes[frame.root]!;
      if (count > best) {
        best = count;
        projectRoot = frame.root;
      }
    }

    final chain = <ChainFrame>[];
    for (final frame in frames) {
      if (frame.root != projectRoot) continue;
      final widget = '${frame.raw['widget'] ?? 'Widget'}';
      if (widget == 'FixKit') continue;
      final line = frame.raw['line'] is int ? frame.raw['line'] as int : null;
      final previous = chain.lastOrNull;
      if (previous != null && previous.path == frame.path && previous.line == line && previous.widget == widget) {
        continue;
      }
      chain.add(ChainFrame(
        widget: widget,
        path: frame.path,
        relative: relativeTo(projectRoot!, frame.path),
        line: line,
        column: frame.raw['column'] is int ? frame.raw['column'] as int : null,
        text: frame.raw['text'] is String ? frame.raw['text'] as String : null,
      ));
    }

    final comment = '${body['comment'] ?? ''}'.trim();
    final stored = Map<String, Object?>.of(body)..remove('screenshotPNG');
    return FixReport(
      id: id,
      comment: comment,
      body: stored,
      projectRoot: projectRoot,
      chain: chain,
      receivedAt: now ?? DateTime.now(),
    );
  }

  final String id;
  final String comment;

  /// What the app sent, without the screenshot.
  final Map<String, Object?> body;

  /// The project the pressed widget's code lives in, when it could be told.
  String? projectRoot;

  /// The app's own widgets around the press, innermost first.
  final List<ChainFrame> chain;
  final DateTime receivedAt;

  /// Absolute path of the screenshot, once saved.
  String? screenshotPath;

  String status = FixStatus.queued;

  /// What the agent card says under the steps: the agent's summary, a hint.
  String? message;
  DateTime updatedAt;

  /// The agent that took it, and when.
  String? agentId;
  String? agentName;
  DateTime? deliveredAt;

  /// Delivered but not yet acknowledged by the agent's MCP server.
  bool acknowledged = false;

  /// The app reloaded while the agent was working on it.
  bool sawReload = false;
  DateTime? lastReloadAt;

  /// The prompt was copied to the clipboard because no agent took it.
  bool copiedToClipboard = false;

  /// The app was told it went live.
  bool announced = false;

  /// Completes on the next reload signal; used while finishing a fix.
  Completer<void>? reloadWaiter;

  /// What has happened so far, oldest first: the app shows it as the agent's
  /// live activity.
  final List<Map<String, Object?>> activity = [];

  /// The files of the widget path and when they last changed, to notice the
  /// agent's edits without its help.
  final Map<String, DateTime?> watched = {};
  final Set<String> edited = {};

  /// Adds a line to [activity]. `kind` is `step`, `done`, `error` or
  /// `question`.
  void note(String text, {String kind = 'step'}) {
    final line = text.trim();
    if (line.isEmpty) return;
    if (activity.isNotEmpty && activity.last['text'] == line) return;
    activity.add({'text': line.length > 90 ? '${line.substring(0, 87)}...' : line, 'kind': kind, 'at': DateTime.now().toIso8601String()});
    if (activity.length > 30) activity.removeAt(0);
  }

  /// What the app's status calls receive.
  Map<String, Object?> statusJson({bool announce = false}) => {
        'id': id,
        'status': status,
        'message': message,
        'comment': comment,
        if (agentName != null) 'agent': agentName,
        'activity': activity,
        if (announce) 'announce': true,
      };

  bool get isFinished => FixStatus.isFinished(status);

  void setStatus(String next, {String? message, bool keepMessage = false}) {
    status = next;
    if (!keepMessage) this.message = message;
    updatedAt = DateTime.now();
  }

  String? get _route => body['route'] is String ? body['route'] as String : null;
  String? get _screen => body['screen'] is String ? body['screen'] as String : null;
  String? get _targetText => body['targetText'] is String ? body['targetText'] as String : null;

  List<String> get _nearby => body['nearby'] is List ? [for (final item in body['nearby'] as List) '$item'] : const [];

  /// The widget under the finger, when the selection was widened past it.
  ({String describe})? get _pressed {
    final pressed = body['pressed'];
    if (pressed is! Map) return null;
    final widget = '${pressed['widget'] ?? 'a widget'}';
    final text = pressed['text'] is String ? ' ${_quote(pressed['text'] as String)}' : '';
    final file = pressed['file'] is String ? pathFromLocation(pressed['file'] as String) : null;
    final line = pressed['line'];
    var where = '';
    if (file != null) {
      final rel = projectRoot == null ? normalizePath(file) : relativeTo(projectRoot!, file);
      where = ' (${line is int ? '$rel:$line' : rel})';
    }
    return (describe: '$widget$text$where');
  }

  ({String name, String? location})? get _named {
    final named = body['named'];
    if (named is! Map) return null;
    final name = named['name'];
    if (name is! String) return null;
    final file = named['file'] is String ? pathFromLocation(named['file'] as String) : null;
    final line = named['line'];
    String? location;
    if (file != null) {
      final rel = projectRoot == null ? file : relativeTo(projectRoot!, file);
      location = line is int ? '$rel:$line' : rel;
    }
    return (name: name, location: location);
  }

  /// The screenshot path relative to the project, for the prompt.
  String? get screenshotForPrompt {
    final path = screenshotPath;
    if (path == null) return null;
    final root = projectRoot;
    return root != null && isWithin(root, path) ? relativeTo(root, path) : normalizePath(path);
  }

  /// One line naming what was pressed, as the `[fix …]` line and lists show it.
  String get headline {
    final parts = <String>[];
    final named = _named;
    if (named != null) parts.add(named.name);
    final target = chain.firstOrNull;
    final text = _targetText;
    if (target != null) {
      parts.add(text == null ? target.widget : '${target.widget} ${_quote(text)}');
      parts.add(target.location);
    } else if (text != null) {
      parts.add(_quote(text));
    }
    final screen = _screen ?? _route;
    if (screen != null) parts.add('$screen screen');
    return parts.isEmpty ? 'unknown widget' : parts.join(' · ');
  }

  /// The prompt the agent receives: the person's words, then what is known
  /// about the widget.
  String prompt({bool includeProject = true}) {
    final lines = <String>[comment.isEmpty ? '(no comment)' : comment, '', '[fix $id] $headline'];

    final pressed = _pressed;
    final selected = chain.firstOrNull;
    final named = _named;
    if (pressed != null && selected != null) {
      final what = selected.widget == 'FixName' && named != null ? 'the named area "${named.name}"' : 'this ${selected.widget}';
      lines.add(
        'Selection: the person pressed ${pressed.describe} and widened the selection to $what, '
        'so the request is about all of it (its spacing, alignment, size or children).',
      );
    }

    if (named != null) {
      lines.add('Named: ${named.name}${named.location == null ? '' : ' (FixName at ${named.location})'}');
    }

    if (chain.isNotEmpty) {
      lines.add('Widget path, innermost first (each line is where that widget is constructed):');
      for (final frame in chain.take(8)) {
        lines.add('  - ${frame.describe()}');
      }
      if (chain.length > 8) lines.add('  - … ${chain.length - 8} more');
    } else {
      final raw = body['chain'] is List ? body['chain'] as List : const [];
      final types = [for (final item in raw.take(12)) if (item is Map) '${item['widget']}'];
      if (body['tracking'] == false) {
        lines.add('Source locations are off in this build (run it with `flutter run`, which tracks widget creation by default).');
      }
      if (types.isNotEmpty) lines.add('Widgets under the finger: ${types.join(' < ')}');
    }

    final text = _targetText;
    if (text != null && chain.isEmpty) lines.add('Pressed text: ${_quote(text)}');
    final nearby = _nearby;
    if (nearby.isNotEmpty) lines.add('Nearby text: ${nearby.map(_quote).join(', ')}');

    final screen = _screen;
    final route = _route;
    if (screen != null || route != null) {
      lines.add('Screen: ${[if (screen != null) screen, if (route != null) 'route $route'].join(', ')}');
    }
    final platform = body['platform'];
    if (platform is String) lines.add('Platform: $platform');

    final shot = screenshotForPrompt;
    if (shot != null) lines.add('Screenshot: $shot (pressed area outlined in red)');
    if (includeProject && projectRoot != null) lines.add('Project: $projectRoot');
    return lines.join('\n');
  }

  /// A short form for lists and the status command.
  Map<String, Object?> summary() => {
        'id': id,
        'status': status,
        'comment': comment,
        'headline': headline,
        if (message != null) 'message': message,
        if (projectRoot != null) 'project': projectRoot,
        if (agentName != null) 'agent': agentName,
        'receivedAt': receivedAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// Everything the agent gets, minus the image.
  Map<String, Object?> toJson() => {
        ...summary(),
        'prompt': prompt(),
        'chain': [for (final frame in chain) frame.toJson()],
        if (screenshotPath != null) 'screenshot': screenshotPath,
        'app': body,
      };
}

String _quote(String text) => '"${text.replaceAll('"', r'\"')}"';
