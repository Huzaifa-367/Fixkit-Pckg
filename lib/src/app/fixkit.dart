import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'capture.dart';
import 'connection.dart';
import 'controller.dart';
import 'inspector.dart';
import 'overlay.dart';

/// Lets you long press any widget in a debug build, describe what is wrong,
/// and send it to the AI agent in your editor.
///
/// Wrap the app once, around everything `runApp` receives
/// (`dart run fixkit init` does this for you):
///
/// ```dart
/// void main() => runApp(FixKit(child: MyApp()));
/// ```
///
/// In profile and release builds it returns [child] and does nothing else.
class FixKit extends StatefulWidget {
  const FixKit({
    super.key,
    required this.child,
    this.enabled = true,
    this.pressDuration = const Duration(milliseconds: 450),
    this.screenshots = true,
    this.connection,
  });

  /// The app.
  final Widget child;

  /// Turns fixkit off without removing it. Changing it rebuilds the app.
  final bool enabled;

  /// How long a press lasts before it opens the composer.
  ///
  /// fixkit watches the pointer itself instead of joining the gesture arena,
  /// so it works on every widget: text fields, buttons, `InkWell`s and
  /// `GestureDetector`s with their own long press, list items, sliders. The
  /// default fires just before Flutter's own long press (500 ms); when it
  /// does, the press belongs to fixkit and every other recognizer on that
  /// finger is cancelled, so the widget under it does not react. Moving the
  /// finger (a scroll, a drag) or a second finger (a pinch) cancels it.
  final Duration pressDuration;

  /// Sends a screenshot with each report, the pressed widget outlined. Turn
  /// it off when the screen shows data that must not leave the device.
  final bool screenshots;

  /// Where reports go. Tests use it; apps leave it out.
  final FixConnection? connection;

  @override
  State<FixKit> createState() => _FixKitState();
}

class _FixKitState extends State<FixKit> with WidgetsBindingObserver, TickerProviderStateMixin {
  FixKitController? _controller;
  final GlobalKey _boundary = GlobalKey(debugLabel: 'fixkit.app');

  /// What the app saw before the keyboard opened; kept while composing so the
  /// app does not resize under the composer.
  MediaQueryData? _appMedia;

  bool get _active => kDebugMode && widget.enabled;

  @override
  void initState() {
    super.initState();
    _hold = AnimationController(vsync: this, duration: _ringDuration);
    _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
    if (_active) _start();
  }

  /// The agent card, built once: it listens to its own state, so the root's
  /// rebuilds (metrics, a press) pass it by.
  Widget? _card;

  void _start() {
    final controller = FixKitController(widget.connection ?? createConnection());
    _controller = controller;
    _card = FixKitChrome(child: FixAgentCard(controller: controller));
    WidgetsBinding.instance.addObserver(this);
    // Tells the hub the app is up: during a fix that means the fix is on
    // screen, whatever started the app.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.signal('launch'));
  }

  void _stop() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    _card = null;
  }

  @override
  void didUpdateWidget(FixKit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_active && _controller == null) _start();
    if (!_active && _controller != null) _stop();
  }

  /// Runs on every hot reload: how the hub learns a fix reached the screen.
  @override
  void reassemble() {
    super.reassemble();
    _controller?.signal('reload');
  }

  /// The screen size at the press: a rotation or resize while composing makes
  /// the measured widgets stale, so the composer closes.
  Size? _pressSize;

  @override
  void didChangeMetrics() {
    final controller = _controller;
    if (controller == null || controller.target == null || !mounted) return;
    final size = View.of(context).physicalSize;
    // The keyboard changes the insets, not the size.
    if (_pressSize != null && size != _pressSize) controller.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No polling while the app is in the background; catch up on return.
    // Desktop and web report `inactive` when the window merely loses focus
    // (to the editor beside it): keep following then.
    _controller?.setForeground(switch (state) {
      AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached => false,
      _ => true,
    });
  }

  @override
  Future<bool> didPopRoute() async {
    final controller = _controller;
    if (controller != null && controller.target != null) {
      controller.cancel();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _reset();
    if (_controller != null) _stop();
    _hold.dispose();
    _pop.dispose();
    _holdAt.dispose();
    super.dispose();
  }

  // ---- The hold ring -----------------------------------------------------------
  //
  // A ring under the finger fills while the press is held, and bursts when it
  // opens the composer. It paints from its animations alone: no rebuilds.

  late final AnimationController _hold;
  late final AnimationController _pop;
  final ValueNotifier<Offset?> _holdAt = ValueNotifier(null);
  Offset? _popAt;
  Timer? _ringTimer;

  /// The ring stays away for the first moment of a press, so taps (most
  /// presses) never start it, then fills over the rest of the press.
  static const Duration _ringDelay = Duration(milliseconds: 120);
  Duration get _ringDuration {
    final rest = widget.pressDuration - _ringDelay;
    return rest > const Duration(milliseconds: 50) ? rest : const Duration(milliseconds: 50);
  }

  bool get _reduceMotion => WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;

  // ---- The press -------------------------------------------------------------
  //
  // A Listener sees every pointer event under it without taking part in the
  // gesture arena, so no widget can win the press away from fixkit: a text
  // field's selection, a button's tap and an InkWell's own long press all
  // compete in the arena, and fixkit simply fires first and cancels them.

  final Set<int> _down = {};
  int? _pointer;
  Offset? _downAt;
  double _slop = kTouchSlop;
  Timer? _timer;

  void _onDown(PointerDownEvent event) {
    _down.add(event.pointer);
    final controller = _controller;
    if (controller == null || controller.busy) return;
    // A second finger is a pinch or a two-finger gesture, not a long press.
    if (_down.length > 1) {
      _reset();
      return;
    }
    // Mice press with the primary button only; the others open menus.
    if (event.kind == PointerDeviceKind.mouse && event.buttons != kPrimaryMouseButton) return;
    _pointer = event.pointer;
    _downAt = event.position;
    _ringTimer?.cancel();
    final at = event.position;
    _ringTimer = Timer(_ringDelay, () {
      if (!mounted) return;
      _holdAt.value = at;
      _hold
        ..duration = _ringDuration
        ..forward(from: 0);
    });
    // The same slop the app's scrollables use, so a slow scroll never turns
    // into a long press. Worked out once per press, not per move.
    _slop = event.kind == PointerDeviceKind.mouse
        ? 4.0
        : computeHitSlop(event.kind, DeviceGestureSettings.fromView(View.of(context)));
    _timer?.cancel();
    _timer = Timer(widget.pressDuration, () => _fire(event.pointer, event.position));
  }

  void _onMove(PointerMoveEvent event) {
    final start = _downAt;
    if (event.pointer != _pointer || start == null) return;
    if ((event.position - start).distance > _slop) _reset();
  }

  void _onEnd(PointerEvent event) {
    _down.remove(event.pointer);
    if (event.pointer == _pointer) _reset();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _ringTimer?.cancel();
    _ringTimer = null;
    _pointer = null;
    _downAt = null;
    if (_hold.isAnimating || _hold.value > 0) {
      _hold
        ..stop()
        ..value = 0;
    }
    _holdAt.value = null;
  }

  void _fire(int pointer, Offset position) {
    _reset();
    if (!mounted || _controller == null || _controller!.busy) return;
    if (!_reduceMotion) {
      _popAt = position;
      _pop.forward(from: 0);
    }
    // The press is fixkit's now: every recognizer on this finger gets a
    // cancel, so the widget under it neither taps nor long presses.
    GestureBinding.instance.cancelPointer(pointer);
    _pressed(position);
  }

  void _pressed(Offset position) {
    final controller = _controller;
    if (controller == null || controller.busy || !mounted) return;

    FixInspection inspection;
    try {
      inspection = inspectAt(position, View.of(context).viewId);
    } catch (error, stack) {
      debugPrint('fixkit: could not inspect the widget under the press: $error\n$stack');
      inspection = FixInspection.empty(position);
    }

    _pressSize = View.of(context).physicalSize;
    // Where the app sits before the lift moves it: the outline is drawn
    // against this, however far the app has slid by the time it is captured.
    final box = _boundary.currentContext?.findRenderObject();
    final origin = box is RenderBox && box.hasSize ? box.localToGlobal(Offset.zero) : null;
    HapticFeedback.mediumImpact();
    // The capture waits until the composer has opened, so reading the screen
    // back never competes with its entrance animation, and stays at a modest
    // resolution. The composer is drawn outside the captured boundary, and the
    // outline goes on at send time, around the final selection.
    final Future<FixCapture?> capture = !widget.screenshots
        ? Future<FixCapture?>.value()
        : Future<void>.delayed(const Duration(milliseconds: 320))
            .then((_) => SchedulerBinding.instance.endOfFrame)
            .then((_) => mounted ? captureApp(_boundary, maxPixelRatio: 1.5, origin: origin) : null)
            .catchError((Object error) {
            debugPrint('fixkit: no screenshot: $error');
            return null;
          });
    controller.begin(FixTarget(inspection: inspection, capture: capture));
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_active || controller == null) return widget.child;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery.fromView(
        view: View.of(context),
        // Rebuilds only when a press opens or closes the composer (and on
        // metrics changes, as any app root does). The agent card and the hold
        // ring listen to their own state below.
        child: ValueListenableBuilder<FixTarget?>(
          valueListenable: controller.targetListenable,
          builder: (context, target, _) => _layout(context, controller, target),
        ),
      ),
    );
  }

  /// The keyboard's height while composing.
  double _keyboard = 0;
  double _lastInset = 0;

  Widget _layout(BuildContext context, FixKitController controller, FixTarget? target) {
    final media = MediaQuery.of(context);
    if (target == null || _appMedia == null) _appMedia = media;
    final appMedia = target == null ? media : _appMedia!;
    // While the keyboard slides, the lift follows it frame by frame (its
    // insets are already smooth); a tween would restart every frame. Other
    // changes, a new selection say, glide.
    final inset = media.viewInsets.bottom;
    final keyboardMoving = target != null && inset != _lastInset;
    _lastInset = inset;
    // The lift tracks the keyboard both ways: up as it opens, down when the
    // system's back button hides it.
    _keyboard = target == null ? 0 : inset;
    final liftDuration = keyboardMoving ? Duration.zero : const Duration(milliseconds: 260);
    final lift = _lift(target, media);

    return Stack(
      fit: StackFit.expand,
      children: [
        TweenAnimationBuilder<double>(
          key: const ValueKey('fixkit.app'),
          tween: Tween<double>(begin: 0, end: lift),
          duration: liftDuration,
          curve: Curves.easeOutCubic,
          builder: (context, lift, child) => Transform.translate(offset: Offset(0, -lift), child: child),
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onDown,
            onPointerMove: _onMove,
            onPointerUp: _onEnd,
            onPointerCancel: _onEnd,
            child: RepaintBoundary(
              key: _boundary,
              // The app reads this instead of making its own from the view;
              // while composing it keeps what it saw before the keyboard.
              child: MediaQuery(data: appMedia, child: widget.child),
            ),
          ),
        ),
        // The hold ring under the finger.
        Positioned.fill(
          key: const ValueKey('fixkit.hold'),
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _HoldPainter(
                  hold: _hold,
                  at: _holdAt,
                  pop: _pop,
                  popAt: () => _popAt,
                  delay: _ringDelay,
                  press: widget.pressDuration,
                ),
              ),
            ),
          ),
        ),
        if (target != null)
          Positioned.fill(
            key: const ValueKey('fixkit.composer'),
            child: FixComposer(controller: controller, target: target, lift: lift, liftDuration: liftDuration),
          ),
        Positioned(
          key: const ValueKey('fixkit.card'),
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: media.padding.top + 6),
            child: Align(alignment: Alignment.topCenter, child: _card),
          ),
        ),
      ],
    );
  }

  /// How far to slide the app up so the keyboard and the input bar leave the
  /// pressed widget in view, without pushing its top off screen.
  double _lift(FixTarget? target, MediaQueryData media) {
    if (target == null) return 0;
    final inspection = target.inspection;
    final rect = inspection.spotRect ?? Rect.fromCircle(center: inspection.touch, radius: 28);
    final keyboardTop = media.size.height - _keyboard - fixComposerBarHeight - 24;
    final overlap = rect.bottom + 16 - keyboardTop;
    if (overlap <= 0) return 0;
    final room = math.max(0.0, rect.top - media.padding.top - 48);
    return math.min(overlap, room);
  }
}

/// The ring under a held finger: a faint track, an arc that fills over the
/// press, and a burst when the composer opens. It appears only after a short
/// moment, so ordinary taps never flash it.
class _HoldPainter extends CustomPainter {
  _HoldPainter({
    required this.hold,
    required this.at,
    required this.pop,
    required this.popAt,
    required this.delay,
    required this.press,
  }) : super(repaint: Listenable.merge([hold, at, pop]));

  /// 0 to 1 over the part of the press after [delay].
  final Animation<double> hold;
  final ValueListenable<Offset?> at;
  final AnimationController pop;
  final Offset? Function() popAt;
  final Duration delay;
  final Duration press;

  static const double _radius = 30;
  static const _colors = [Color(0xFFFF8A65), Color(0xFFB388FF), Color(0xFF4FC3F7), Color(0xFF5EEAD4), Color(0xFFFF8A65)];

  @override
  void paint(Canvas canvas, Size size) {
    final center = at.value;
    if (center != null && hold.value > 0) {
      // Fades in over 80 ms; the arc shows the whole press, so it starts
      // part filled (the moment before the ring appeared).
      final total = math.max(1, press.inMilliseconds);
      final ringMs = math.max(1, total - delay.inMilliseconds);
      final opacity = (hold.value * ringMs / 80).clamp(0.0, 1.0);
      final progress = ((delay.inMilliseconds + hold.value * ringMs) / total).clamp(0.0, 1.0);
      if (opacity > 0) {
        final alpha = (opacity * 255).round();
        final rect = Rect.fromCircle(center: center, radius: _radius);
        canvas.drawCircle(center, _radius + 6, Paint()..color = Color.fromARGB((opacity * 40).round(), 255, 255, 255));
        canvas.drawCircle(
          center,
          _radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..color = Color.fromARGB((opacity * 90).round(), 255, 255, 255),
        );
        canvas.drawArc(
          rect,
          -math.pi / 2,
          math.pi * 2 * progress,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..strokeCap = StrokeCap.round
            ..shader = SweepGradient(
              colors: [for (final color in _colors) color.withAlpha(alpha)],
              transform: const GradientRotation(-math.pi / 2),
            ).createShader(rect),
        );
      }
    }
    final burstAt = popAt();
    final t = pop.value;
    if (burstAt != null && pop.isAnimating) {
      final eased = Curves.easeOutCubic.transform(t);
      canvas.drawCircle(
        burstAt,
        _radius + 24 * eased,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * (1 - eased) + 0.5
          ..color = Color.fromARGB(((1 - t) * 220).round(), 179, 136, 255),
      );
    }
  }

  @override
  bool shouldRepaint(_HoldPainter oldDelegate) =>
      oldDelegate.hold != hold ||
      oldDelegate.at != at ||
      oldDelegate.pop != pop ||
      oldDelegate.delay != delay ||
      oldDelegate.press != press;
}
