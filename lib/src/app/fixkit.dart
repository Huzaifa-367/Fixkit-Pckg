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

class _FixKitState extends State<FixKit> with WidgetsBindingObserver {
  FixKitController? _controller;
  final GlobalKey _boundary = GlobalKey(debugLabel: 'fixkit.app');

  /// What the app saw before the keyboard opened; kept while composing so the
  /// app does not resize under the composer.
  MediaQueryData? _appMedia;

  bool get _active => kDebugMode && widget.enabled;

  @override
  void initState() {
    super.initState();
    if (_active) _start();
  }

  void _start() {
    final controller = FixKitController(widget.connection ?? createConnection());
    _controller = controller;
    WidgetsBinding.instance.addObserver(this);
    // Tells the hub the app is up: during a fix that means the fix is on
    // screen, whatever started the app.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.signal('launch'));
  }

  void _stop() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
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
    super.dispose();
  }

  // ---- The press -------------------------------------------------------------
  //
  // A Listener sees every pointer event under it without taking part in the
  // gesture arena, so no widget can win the press away from fixkit: a text
  // field's selection, a button's tap and an InkWell's own long press all
  // compete in the arena, and fixkit simply fires first and cancels them.

  final Set<int> _down = {};
  int? _pointer;
  Offset? _downAt;
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
    _timer?.cancel();
    _timer = Timer(widget.pressDuration, () => _fire(event.pointer, event.position));
  }

  void _onMove(PointerMoveEvent event) {
    final start = _downAt;
    if (event.pointer != _pointer || start == null) return;
    // The same slop the app's scrollables use, so a slow scroll never turns
    // into a long press.
    final slop = event.kind == PointerDeviceKind.mouse
        ? 4.0
        : computeHitSlop(event.kind, DeviceGestureSettings.fromView(View.of(context)));
    if ((event.position - start).distance > slop) _reset();
  }

  void _onEnd(PointerEvent event) {
    _down.remove(event.pointer);
    if (event.pointer == _pointer) _reset();
  }

  void _reset() {
    _timer?.cancel();
    _timer = null;
    _pointer = null;
    _downAt = null;
  }

  void _fire(int pointer, Offset position) {
    _reset();
    if (!mounted || _controller == null || _controller!.busy) return;
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
    HapticFeedback.mediumImpact();
    // The capture waits for the frame that settles the press (a cancelled ink
    // splash, say). The composer is drawn outside the captured boundary, and
    // the outline goes on at send time, around the final selection.
    final Future<FixCapture?> capture = !widget.screenshots
        ? Future<FixCapture?>.value()
        : SchedulerBinding.instance.endOfFrame.then((_) => captureApp(_boundary)).catchError((Object error) {
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
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => _layout(context, controller),
        ),
      ),
    );
  }

  Widget _layout(BuildContext context, FixKitController controller) {
    final media = MediaQuery.of(context);
    final target = controller.target;
    if (target == null || _appMedia == null) _appMedia = media;
    final appMedia = target == null ? media : _appMedia!;

    return Stack(
      fit: StackFit.expand,
      children: [
        TweenAnimationBuilder<double>(
          key: const ValueKey('fixkit.app'),
          tween: Tween<double>(begin: 0, end: _lift(target, media)),
          duration: const Duration(milliseconds: 260),
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
        if (target != null)
          Positioned.fill(
            key: const ValueKey('fixkit.composer'),
            child: FixComposer(controller: controller, target: target, lift: _lift(target, media)),
          ),
        // The screen edge glows while fixkit has the agent's attention.
        Positioned.fill(
          key: const ValueKey('fixkit.aura'),
          child: IgnorePointer(
            child: FixAura(strength: target != null ? 1 : (controller.working ? 0.55 : 0)),
          ),
        ),
        Positioned(
          key: const ValueKey('fixkit.card'),
          top: 0,
          left: 0,
          right: 0,
          child: FixKitChrome(
            child: Padding(
              padding: EdgeInsets.only(top: media.padding.top + 6),
              child: Align(alignment: Alignment.topCenter, child: FixAgentCard(controller: controller)),
            ),
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
    final keyboardTop = media.size.height - media.viewInsets.bottom - fixComposerBarHeight - 24;
    final overlap = rect.bottom + 16 - keyboardTop;
    if (overlap <= 0) return 0;
    final room = math.max(0.0, rect.top - media.padding.top - 48);
    return math.min(overlap, room);
  }
}
