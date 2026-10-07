import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../protocol.dart';
import 'capture.dart';
import 'connection.dart';
import 'inspector.dart';

/// What a long press captured, before the comment is typed.
class FixTarget {
  FixTarget({required this.inspection, required this.capture});

  /// The pressed widget, and which widget around it is selected.
  final FixInspection inspection;

  /// The app as it looked, taken once the frame under the press has painted;
  /// null when screenshots are off. The outline goes on when it is sent.
  final Future<FixCapture?> capture;

  FixTarget withInspection(FixInspection next) => FixTarget(inspection: next, capture: capture);

  void discard() {
    capture.then((image) => image?.dispose(), onError: (Object _) {});
  }
}

enum FixStepKind { step, done, error, question }

/// One line of the agent's live activity.
@immutable
class FixStep {
  const FixStep(this.text, {this.kind = FixStepKind.step});

  static FixStep? fromJson(Object? json) {
    if (json is! Map || json['text'] is! String) return null;
    final kind = switch (json['kind']) {
      'done' => FixStepKind.done,
      'error' => FixStepKind.error,
      'question' => FixStepKind.question,
      _ => FixStepKind.step,
    };
    return FixStep(json['text'] as String, kind: kind);
  }

  final String text;
  final FixStepKind kind;

  @override
  bool operator ==(Object other) => other is FixStep && other.text == text && other.kind == kind;

  @override
  int get hashCode => Object.hash(text, kind);
}

enum FixTone { working, success, info, warning, error }

/// Who would take a report, as the composer's badge shows it.
enum FixPresence {
  /// Not known yet.
  checking,

  /// An agent is waiting for reports.
  watching,

  /// The agent is working on another report; this one is next.
  busy,

  /// An agent is connected but nobody said "watch for fixes".
  idle,

  /// The hub runs, but no editor has fixkit loaded.
  none,

  /// The app cannot reach the hub.
  offline,

  /// The hub is left over from an older fixkit.
  outdated,
}

/// The report being followed, as the agent card shows it.
@immutable
class FixRun {
  const FixRun({
    required this.status,
    required this.comment,
    this.id,
    this.agent,
    this.message,
    this.steps = const [],
  });

  /// The status before the hub has answered.
  static const sending = 'sending';

  final String? id;
  final String status;
  final String comment;

  /// The agent working on it, by the name its editor gives.
  final String? agent;

  /// The agent's summary, or the hub's hint.
  final String? message;
  final List<FixStep> steps;

  bool get finished => FixStatus.isFinished(status);

  /// Whether the card would look the same.
  bool sameAs(FixRun other) =>
      other.id == id &&
      other.status == status &&
      other.agent == agent &&
      other.message == message &&
      other.comment == comment &&
      listEquals(other.steps, steps);

  String get _who => agent ?? 'your agent';

  String get title => switch (status) {
        sending => 'Sending to $_who',
        FixStatus.queued => 'Waiting for $_who',
        FixStatus.fixing => '${_capital(_who)} is fixing it',
        FixStatus.reloading => 'Hot reloading the fix',
        FixStatus.live => 'Fixed',
        FixStatus.applied => 'Fixed in code',
        FixStatus.failed => 'Not fixed',
        FixStatus.needsInput => '${_capital(_who)} has a question',
        _ => 'Working on it',
      };

  FixTone get tone => switch (status) {
        FixStatus.live => FixTone.success,
        FixStatus.applied => FixTone.info,
        FixStatus.failed => FixTone.error,
        FixStatus.needsInput => FixTone.warning,
        _ => FixTone.working,
      };

  /// The line under the steps once it is finished, or the hub's hint.
  String? get footnote {
    if (status == FixStatus.queued) return message;
    if (finished) return message;
    return null;
  }
}

String _capital(String text) => text.isEmpty ? text : text[0].toUpperCase() + text.substring(1);

/// A short message with no report behind it: the hub cannot be reached, say.
@immutable
class FixNotice {
  const FixNotice(this.title, {this.detail, this.tone = FixTone.info});

  final String title;
  final String? detail;
  final FixTone tone;
}

/// The state behind the composer and the agent card: the press being
/// described, the report being followed, and who is watching.
class FixKitController extends ChangeNotifier {
  FixKitController(this.connection);

  final FixConnection connection;

  /// The comment being typed.
  final TextEditingController draft = TextEditingController();

  FixTarget? _target;
  FixTarget? get target => _target;

  FixRun? _run;
  FixRun? get run => _run;

  FixNotice? _notice;
  FixNotice? get notice => _notice;

  String? _agent;
  FixPresence _presence = FixPresence.checking;
  String? _hubVersion;
  Timer? _presenceTimer;
  bool _restartAsked = false;

  /// The agent that would take a report now, when the hub knows one.
  String? get agent => _agent;

  /// Who would take a report now.
  FixPresence get presence => _presence;

  /// Whether an agent is waiting for reports right now.
  bool get watching => _presence == FixPresence.watching;

  /// The outdated hub's version, when [presence] is [FixPresence.outdated].
  String? get hubVersion => _hubVersion;

  bool _expanded = true;

  /// Whether the agent card shows its steps.
  bool get expanded => _expanded;

  bool _sending = false;
  bool get sending => _sending;

  /// A press is being described or sent: a new long press is ignored.
  bool get busy => _target != null || _sending;

  /// An agent is working on a report: the screen edge glows.
  bool get working {
    final run = _run;
    return run != null && !run.finished;
  }

  Timer? _hideTimer;
  int _following = 0;
  bool _hinted = false;
  bool _disposed = false;

  void begin(FixTarget target) {
    draft.clear();
    _target = target;
    _notify();
    // Kept current while the composer is open: an agent may start watching,
    // or finish another fix, while the comment is typed.
    unawaited(refreshPresence());
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) => refreshPresence());
  }

  void cancel() {
    _presenceTimer?.cancel();
    _target?.discard();
    _target = null;
    _notify();
  }

  /// Selects another widget around the press: 0 is the pressed widget, each
  /// step up is a parent written in the app's code (a Row, a Column...).
  void select(int index) {
    final target = _target;
    if (target == null || index == target.inspection.selected) return;
    _target = target.withInspection(target.inspection.select(index));
    _notify();
  }

  /// Widens the selection to the parent.
  void widen() {
    final target = _target;
    if (target != null && target.inspection.canWiden) select(target.inspection.selected + 1);
  }

  /// Narrows the selection back toward the pressed widget.
  void narrow() {
    final target = _target;
    if (target != null && target.inspection.canNarrow) select(target.inspection.selected - 1);
  }

  /// Puts a suggestion in the field, ready to send or edit.
  void suggest(String text) {
    draft.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  }

  void toggleExpanded() {
    _expanded = !_expanded;
    // A card the person opens again stays until they close it.
    if (_expanded) _hideTimer?.cancel();
    _notify();
  }

  /// Dismisses the card and stops following its report. The agent keeps
  /// working; the next launch or reload shows the outcome.
  void dismiss() {
    _hideTimer?.cancel();
    _noticeTimer?.cancel();
    _following++;
    _run = null;
    _notice = null;
    _notify();
  }

  bool _foreground = true;

  /// The app went to the background (false) or came back (true). Polling
  /// stops in the background and catches up on return.
  void setForeground(bool foreground) {
    if (foreground == _foreground) return;
    _foreground = foreground;
    final run = _run;
    if (foreground && run != null && run.id != null && !run.finished) unawaited(_follow(run.id!));
  }

  /// Asks the hub who would take a report, for the composer's badge.
  Future<void> refreshPresence() async {
    final answer = await connection.presence(file: _target?.inspection.target?.file);
    if (_disposed) return;
    var agent = _agent;
    FixPresence next;
    if (answer == null) {
      next = FixPresence.offline;
    } else if ((answer['outdated'] == true && (answer['version'] == null || _isOlder(answer['version'], fixkitVersion))) ||
        (answer['outdated'] != true && _isOlder(answer['version'], fixkitVersion))) {
      next = FixPresence.outdated;
      _hubVersion = answer['version'] is String ? answer['version'] as String : null;
      unawaited(_replaceOutdatedHub());
    } else if (answer['outdated'] == true) {
      // A hub without presence but not older than this app: name nobody.
      next = FixPresence.none;
    } else {
      agent = answer['agent'] is String ? answer['agent'] as String : null;
      next = agent == null
          ? FixPresence.none
          : answer['watching'] == true
              ? FixPresence.watching
              : answer['busy'] == true
                  ? FixPresence.busy
                  : FixPresence.idle;
    }
    if (next == _presence && agent == _agent) return;
    _presence = next;
    _agent = agent;
    _notify();
  }

  /// A hub left over from an older fixkit is asked, once, to stop. The
  /// editor's fixkit starts the current one within seconds.
  Future<void> _replaceOutdatedHub() async {
    if (_restartAsked) return;
    _restartAsked = true;
    final stopped = await connection.restartHub();
    debugPrint(stopped
        ? 'fixkit: stopped an outdated fixkit hub (${_hubVersion ?? 'older'}); your editor starts the current one.'
        : 'fixkit: the fixkit hub is outdated (${_hubVersion ?? 'older'}). Run `dart run fixkit restart` in the project.');
  }

  /// Sends the typed comment with the press it describes.
  Future<void> send() async {
    final target = _target;
    final comment = draft.text.trim();
    if (target == null || comment.isEmpty) return;

    _presenceTimer?.cancel();
    _target = null;
    _sending = true;
    _notice = null;
    _expanded = true;
    _hideTimer?.cancel();
    _run = FixRun(status: FixRun.sending, comment: comment, agent: _agent);
    _notify();

    final inspection = target.inspection;
    final capture = await target.capture.catchError((Object _) => null);
    Uint8List? screenshot;
    try {
      screenshot = await capture?.toPng(highlight: inspection.spotRect, touch: inspection.touch);
    } catch (error) {
      debugPrint('fixkit: no screenshot: $error');
    } finally {
      capture?.dispose();
    }
    final body = <String, Object?>{
      'protocol': fixkitProtocol,
      'version': fixkitVersion,
      'comment': comment,
      'platform': defaultTargetPlatform.name,
      ...inspection.toJson(),
      if (screenshot != null) 'screenshotPNG': base64Encode(screenshot),
    };

    try {
      final answer = await connection.report(body);
      _sending = false;
      final id = answer['id'];
      if (id is! String) throw const FixHubUnreachable('the hub gave no id');
      _apply(answer, comment: comment);
      if (!FixStatus.isFinished('${answer['status']}')) unawaited(_follow(id));
    } on FixVersionMismatch catch (error) {
      _sending = false;
      _run = null;
      debugPrint('fixkit: ${error.message}');
      _showNotice(FixNotice('Reload your editor to update fixkit', detail: error.message, tone: FixTone.warning));
    } catch (error) {
      _sending = false;
      _run = null;
      debugPrint('fixkit: $error');
      _showNotice(
        const FixNotice(
          'fixkit is not listening',
          detail: 'Open the project in your editor. `dart run fixkit doctor` shows what is missing.',
          tone: FixTone.error,
        ),
      );
    }
  }

  /// The app launched or hot reloaded: the hub decides whether that put a fix
  /// on screen, and tells which report to keep following.
  Future<void> signal(String kind) async {
    final answer = await connection.signal(kind);
    if (_disposed) return;
    // Knowing who is watching before the first press makes the badge right
    // at once; it also finds a hub left over from an older fixkit.
    if (kind == 'launch') unawaited(refreshPresence());
    if (answer == null) {
      if (kind == 'launch' && !_hinted) {
        _hinted = true;
        debugPrint(
          'fixkit: no fixkit hub found (${connection.description}). '
          'Run `dart run fixkit init` in the project, then reload your editor window.',
        );
      }
      return;
    }
    // The hub speaks an older protocol: say so once, instead of failing later.
    final hubProtocol = answer['hubProtocol'];
    if (hubProtocol is int && hubProtocol < fixkitProtocol) {
      _showNotice(FixNotice(
        'Reload your editor to update fixkit',
        detail: 'This app uses fixkit $fixkitVersion; the hub runs ${answer['hubVersion'] ?? 'an older one'}.',
        tone: FixTone.warning,
      ));
      return;
    }
    final id = answer['id'];
    if (id is! String) return;
    final status = '${answer['status']}';
    if (status == FixStatus.live && answer['announce'] != true) return;
    _apply(answer);
    if (!FixStatus.isFinished(status)) unawaited(_follow(id));
  }

  Future<void> _follow(String id) async {
    final token = ++_following;
    var misses = 0;
    while (!_disposed && token == _following) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (_disposed || token != _following) return;
      // setForeground starts a new loop when the app comes back.
      if (!_foreground) return;
      try {
        final answer = await connection.status(id);
        misses = 0;
        _apply(answer);
        if (FixStatus.isFinished('${answer['status']}')) return;
      } catch (_) {
        if (++misses == 8) {
          _showNotice(const FixNotice('Lost the fixkit hub', detail: 'Still trying...', tone: FixTone.warning));
        }
        if (misses > 150) return;
      }
    }
  }

  /// Updates the card from a status answer.
  void _apply(Map<String, Object?> answer, {String? comment}) {
    final status = '${answer['status']}';
    final activity = answer['activity'];
    final steps = activity is List ? activity.map(FixStep.fromJson).whereType<FixStep>().toList() : const <FixStep>[];
    final previous = _run;
    final next = FixRun(
      id: answer['id'] is String ? answer['id'] as String : previous?.id,
      status: status,
      comment: answer['comment'] is String ? answer['comment'] as String : (comment ?? previous?.comment ?? ''),
      agent: answer['agent'] is String ? answer['agent'] as String : (previous?.agent ?? _agent),
      message: answer['message'] is String ? answer['message'] as String : null,
      steps: steps.isEmpty ? (previous?.steps ?? const []) : steps,
    );
    // Most polls change nothing: skip the rebuild then.
    if (previous != null && next.sameAs(previous) && _notice == null) return;
    _run = next;
    if (_notice?.tone == FixTone.warning) _notice = null;
    _hideTimer?.cancel();
    if (_run!.finished) {
      // Questions stay until dismissed; everything else folds away.
      if (status != FixStatus.needsInput) {
        _hideTimer = Timer(const Duration(seconds: 7), () {
          _run = null;
          _notify();
        });
      }
    }
    _notify();
  }

  Timer? _noticeTimer;

  void _showNotice(FixNotice notice) {
    _noticeTimer?.cancel();
    _notice = notice;
    // A finished run gives way to the notice now rather than in 7 seconds.
    final run = _run;
    if (run != null && run.finished) {
      _hideTimer?.cancel();
      _run = null;
    }
    _notify();
    _noticeTimer = Timer(const Duration(seconds: 6), () {
      _notice = null;
      _notify();
    });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _target?.discard();
    _target = null;
    _presenceTimer?.cancel();
    _hideTimer?.cancel();
    _noticeTimer?.cancel();
    draft.dispose();
    super.dispose();
  }
}

/// Whether [version] (`1.2.3`) is older than [than]. Unknown is not older.
bool _isOlder(Object? version, String than) {
  if (version is! String) return false;
  List<int> parts(String v) => v.split('-').first.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final a = parts(version);
  final b = parts(than);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x < y;
  }
  return false;
}

/// Requests that fit the pressed widget, offered as chips in the composer.
List<String> suggestionsFor(FixInspection inspection) {
  final widget = inspection.target?.widget ?? '';
  bool has(List<String> names) => names.any(widget.contains);

  if (has(['Button', 'InkWell', 'GestureDetector', 'Chip'])) {
    return const ['Fix the alignment', 'Match the other buttons', 'Make it bigger', 'Change the label'];
  }
  if (has(['TextField', 'TextFormField', 'Input'])) {
    return const ['Fix the validation', 'Change the hint', 'Use the right keyboard'];
  }
  if (has(['Icon', 'Image', 'Avatar'])) {
    return const ['Make it bigger', 'Change the icon', 'Fix the alignment'];
  }
  if (has(['Row', 'Column', 'Flex', 'Wrap', 'Stack', 'ListView', 'GridView', 'Padding', 'Container', 'SizedBox', 'Card'])) {
    return const ['Fix the spacing', 'Align the items', 'Add padding', 'Make it scroll'];
  }
  if (widget == 'Text' || widget == 'RichText' || widget == 'SelectableText' || inspection.targetText != null) {
    return const ['Change the colour', 'Fix the overflow', 'Make it bold', 'Fix the alignment'];
  }
  return const ['Fix the spacing', 'Fix the alignment', 'Change the colour'];
}
