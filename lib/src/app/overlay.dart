import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show DefaultCupertinoLocalizations;
import 'package:flutter/material.dart';

import '../protocol.dart';
import 'controller.dart';
import 'inspector.dart';

/// fixkit's accent, kept for the pressed-widget label.
const Color fixTint = Color(0xFFD97757);

/// The agent's colours: the orb, the edge glow, the send button.
const List<Color> fixAgentColors = [
  Color(0xFFFF8A65),
  Color(0xFFB388FF),
  Color(0xFF4FC3F7),
  Color(0xFF5EEAD4),
  Color(0xFFFF8A65),
];

const Color _glassDark = Color(0xD91A1C28);
const Color _glassEdge = Color(0x2EFFFFFF);
const Color _textStrong = Color(0xFFFFFFFF);
const Color _textSoft = Color(0xD9FFFFFF);
const Color _textDim = Color(0x99FFFFFF);
const Color _green = Color(0xFF4ADE80);
const Color _amber = Color(0xFFFBBF24);
const Color _red = Color(0xFFF87171);
const Color _blue = Color(0xFF4FC3F7);

const Duration _liftDuration = Duration(milliseconds: 260);
const Curve _liftCurve = Curves.easeOutCubic;

/// The height the composer takes above the keyboard (selection bar, the
/// suggestions row with who is watching, and the input bar), for the lift.
const double fixComposerBarHeight = 138;

List<Color> _toneColors(FixTone? tone) => switch (tone) {
      FixTone.success => const [Color(0xFF86EFAC), Color(0xFF22C55E), Color(0xFF14B8A6), Color(0xFF86EFAC)],
      FixTone.error => const [Color(0xFFFCA5A5), Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFFCA5A5)],
      FixTone.warning => const [Color(0xFFFDE68A), Color(0xFFF59E0B), Color(0xFFFB923C), Color(0xFFFDE68A)],
      _ => fixAgentColors,
    };

// ---------------------------------------------------------------------------
// The agent orb
// ---------------------------------------------------------------------------

/// A small living sphere that stands for the agent. It turns faster and
/// breathes while the agent works, and takes the colour of the outcome.
class FixOrb extends StatefulWidget {
  const FixOrb({super.key, this.size = 24, this.busy = false, this.tone});

  final double size;
  final bool busy;

  /// The outcome colour; null for the agent's own colours.
  final FixTone? tone;

  @override
  State<FixOrb> createState() => _FixOrbState();
}

class _FixOrbState extends State<FixOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: _period)..repeat();

  Duration get _period => Duration(milliseconds: widget.busy ? 1500 : 3600);

  @override
  void didUpdateWidget(FixOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.busy != widget.busy) {
      _turn.duration = _period;
      _turn.repeat();
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _turn,
        builder: (context, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _OrbPainter(turn: _turn.value, busy: widget.busy, colors: _toneColors(widget.tone)),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.turn, required this.busy, required this.colors});

  final double turn;
  final bool busy;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final breathe = busy ? 1 + 0.07 * math.sin(turn * math.pi * 4) : 1.0;
    final radius = size.shortestSide / 2 * 0.86 * breathe;
    final bounds = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius * 1.05,
      Paint()
        ..color = colors[1].withAlpha(busy ? 150 : 90)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, radius * 0.55),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..shader = SweepGradient(colors: colors, transform: GradientRotation(turn * math.pi * 2)).createShader(bounds),
    );
    // A second, counter-rotating layer makes the colours swirl like liquid.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(math.cos(-turn * math.pi * 2) * 0.5, math.sin(-turn * math.pi * 2) * 0.5),
          radius: 0.9,
          colors: [colors[2].withAlpha(170), colors[2].withAlpha(0)],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.38, -0.45),
          radius: 0.55,
          colors: [Color(0xB3FFFFFF), Color(0x00FFFFFF)],
        ).createShader(bounds),
    );
    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x59FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) =>
      oldDelegate.turn != turn || oldDelegate.busy != busy || oldDelegate.colors != colors;
}

// ---------------------------------------------------------------------------
// The edge glow
// ---------------------------------------------------------------------------

/// A glow that runs around the edge of the screen while fixkit has the
/// agent's attention: bright while composing, softer while the agent works.
class FixAura extends StatefulWidget {
  const FixAura({super.key, required this.strength});

  /// 0 hides it; 1 is full brightness.
  final double strength;

  @override
  State<FixAura> createState() => _FixAuraState();
}

class _FixAuraState extends State<FixAura> with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(vsync: this, duration: const Duration(seconds: 5));

  @override
  void initState() {
    super.initState();
    if (widget.strength > 0) _turn.repeat();
  }

  @override
  void didUpdateWidget(FixAura oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.strength > 0 && !_turn.isAnimating) _turn.repeat();
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = MediaQuery.sizeOf(context).shortestSide < 600 ? 44.0 : 14.0;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: widget.strength),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (widget.strength == 0) _turn.stop();
      },
      builder: (context, strength, _) {
        if (strength <= 0.01) return const SizedBox.expand();
        return RepaintBoundary(
          child: AnimatedBuilder(
            animation: _turn,
            builder: (context, _) => CustomPaint(
              size: Size.infinite,
              painter: _AuraPainter(turn: _turn.value, strength: strength, radius: radius),
            ),
          ),
        );
      },
    );
  }
}

class _AuraPainter extends CustomPainter {
  _AuraPainter({required this.turn, required this.strength, required this.radius});

  final double turn;
  final double strength;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    final shader = SweepGradient(
      colors: fixAgentColors,
      transform: GradientRotation(turn * math.pi * 2),
    ).createShader(bounds);
    final edge = RRect.fromRectAndRadius(bounds.deflate(1.5), Radius.circular(radius));

    canvas.saveLayer(bounds, Paint()..color = Color.fromRGBO(0, 0, 0, strength.clamp(0.0, 1.0).toDouble()));
    canvas.drawRRect(
      edge,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    canvas.drawRRect(
      edge,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AuraPainter oldDelegate) =>
      oldDelegate.turn != turn || oldDelegate.strength != strength || oldDelegate.radius != radius;
}

// ---------------------------------------------------------------------------
// Glass
// ---------------------------------------------------------------------------

class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.radius = 24, this.padding = EdgeInsets.zero, this.glow});

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: [
          const BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10)),
          if (glow != null) BoxShadow(color: glow!, blurRadius: 22, spreadRadius: -4),
        ],
      ),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              border: Border.all(color: _glassEdge),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color.alphaBlend(const Color(0x14FFFFFF), _glassDark), _glassDark],
              ),
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The composer
// ---------------------------------------------------------------------------

/// The dimmed app with the pressed widget lit and labelled, and the agent
/// prompt above the keyboard: who is watching, suggestions for this kind of
/// widget, and the field.
///
/// It sits above the app's own `MaterialApp`, so it brings what a text field
/// needs: localizations, a theme, a `Material` and an `Overlay`.
class FixComposer extends StatefulWidget {
  const FixComposer({super.key, required this.controller, required this.target, required this.lift});

  final FixKitController controller;
  final FixTarget target;

  /// How far the app is slid up so the keyboard does not cover the widget.
  final double lift;

  @override
  State<FixComposer> createState() => _FixComposerState();
}

class _FixComposerState extends State<FixComposer> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  final FocusNode _focus = FocusNode(debugLabel: 'fixkit.composer');
  late final OverlayEntry _entry = OverlayEntry(builder: _buildBody);

  @override
  void initState() {
    super.initState();
    // The app's own focus scope holds focus, so autofocus would be ignored.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(FixComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lift != widget.lift || oldWidget.target != widget.target) {
      _entry.markNeedsBuild();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.controller.draft.text.trim().isEmpty) return;
    _focus.unfocus();
    widget.controller.send();
  }

  void _cancel() {
    _focus.unfocus();
    widget.controller.cancel();
  }

  void _suggest(String text) {
    widget.controller.suggest(text);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return FixKitChrome(
      child: Localizations(
        locale: const Locale('en', 'US'),
        delegates: const [
          DefaultWidgetsLocalizations.delegate,
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
        ],
        child: Theme(
          data: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFB388FF), brightness: Brightness.dark),
          ),
          child: Overlay(initialEntries: [_entry]),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final media = MediaQuery.of(context);
    final inspection = widget.target.inspection;
    final spot = inspection.spotRect;
    final label = inspection.label;
    final suggestions = suggestionsFor(inspection);
    final bottom = media.viewInsets.bottom + 10 + (media.viewInsets.bottom == 0 ? media.padding.bottom : 0);

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _cancel,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: widget.lift),
            duration: _liftDuration,
            curve: _liftCurve,
            builder: (context, lift, _) => TweenAnimationBuilder<Rect?>(
              // The light glides to the new widget when the selection moves.
              tween: RectTween(begin: spot, end: spot),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              builder: (context, animated, _) {
                final shift = Offset(0, -lift);
                final rect = animated?.shift(shift);
                final touch = inspection.touch + shift;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    AnimatedBuilder(
                      animation: _pulse,
                      builder: (context, _) => CustomPaint(
                        painter: _SpotlightPainter(rect: rect, touch: touch, phase: _pulse.value),
                      ),
                    ),
                    if (label != null)
                      CustomSingleChildLayout(
                        delegate: _LabelLayout(
                          anchor: rect ?? Rect.fromCircle(center: touch, radius: 28),
                          topInset: media.padding.top,
                        ),
                        child: _Chip(label),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        Positioned(
          left: 10,
          right: 10,
          bottom: bottom,
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (inspection.scopes.length > 1) ...[
                  _ScopeBar(inspection: inspection, controller: widget.controller),
                  const SizedBox(height: 8),
                ],
                _Suggestions(
                  key: ValueKey(suggestions.first),
                  leading: _Presence(controller: widget.controller),
                  items: suggestions,
                  onTap: _suggest,
                ),
                const SizedBox(height: 8),
                _InputBar(
                  controller: widget.controller,
                  focusNode: _focus,
                  onSubmit: _submit,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The selection bar: the pressed widget and the app's widgets around it,
/// innermost first. Tap one, or use − and +, to select a whole Row, Column
/// or card instead of the widget under the finger.
class _ScopeBar extends StatefulWidget {
  const _ScopeBar({required this.inspection, required this.controller});

  final FixInspection inspection;
  final FixKitController controller;

  @override
  State<_ScopeBar> createState() => _ScopeBarState();
}

class _ScopeBarState extends State<_ScopeBar> {
  final List<GlobalKey> _keys = [];

  @override
  void didUpdateWidget(_ScopeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inspection.selected != widget.inspection.selected) _reveal();
  }

  /// Scrolls the selected chip into view.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final index = widget.inspection.selected;
      final context = index < _keys.length ? _keys[index].currentContext : null;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final inspection = widget.inspection;
    final scopes = inspection.scopes;
    while (_keys.length < scopes.length) {
      _keys.add(GlobalKey(debugLabel: 'fixkit.scope.${_keys.length}'));
    }
    return Row(
      children: [
        _StepButton(
          glyph: '−',
          label: 'Select the smaller widget',
          enabled: inspection.canNarrow,
          onTap: widget.controller.narrow,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: scopes.length,
              separatorBuilder: (context, index) => const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 3),
                  child: Text('›', style: TextStyle(color: _textDim, fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
              itemBuilder: (context, index) => _ScopeChip(
                key: _keys[index],
                label: scopes[index].label,
                selected: index == inspection.selected,
                onTap: () => widget.controller.select(index),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        _StepButton(
          glyph: '+',
          label: 'Select the parent widget',
          enabled: inspection.canWiden,
          onTap: widget.controller.widen,
        ),
      ],
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        color: _textStrong,
        fontSize: 12,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        fontFamily: 'monospace',
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: 'Select $label',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: ShapeDecoration(
            shape: StadiumBorder(side: BorderSide(color: selected ? const Color(0x99FFFFFF) : _glassEdge)),
            gradient: selected
                ? const LinearGradient(colors: [Color(0xEBFF8A65), Color(0xEBB388FF)])
                : const LinearGradient(colors: [Color(0xCC2A2D40), Color(0xCC1A1C28)]),
            shadows: selected ? const [BoxShadow(color: Color(0x66B388FF), blurRadius: 12)] : const [],
          ),
          child: text,
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.glyph, required this.label, required this.enabled, required this.onTap});

  final String glyph;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled ? 1 : 0.35,
          child: _Glass(
            radius: 17,
            child: SizedBox.square(
              dimension: 34,
              child: Center(
                child: Text(glyph, style: const TextStyle(color: _textStrong, fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Who will take the request: the agent watching, or what happens if none is.
class _Presence extends StatelessWidget {
  const _Presence({required this.controller});

  final FixKitController controller;

  @override
  Widget build(BuildContext context) {
    final agent = controller.agent;
    final name = agent ?? 'Your agent';
    final (Color dot, String text, String detail) = switch (controller.presence) {
      FixPresence.watching => (_green, '$name is watching', '$name gets this as soon as you send it'),
      FixPresence.busy => (_blue, '$name is busy', '$name is finishing another fix; this one is next'),
      FixPresence.idle => (_amber, '$name is idle', 'Say "watch for fixes" in the $name chat, then send'),
      FixPresence.none => (_textDim, 'No agent', 'No editor has fixkit loaded: open the project and reload the window'),
      FixPresence.offline => (_red, 'fixkit offline', 'The app cannot reach fixkit: run `dart run fixkit doctor`'),
      FixPresence.outdated => (_amber, 'Updating fixkit', 'An older fixkit hub is running. It is being replaced; if this stays, run `dart run fixkit restart`'),
      FixPresence.checking => (_textDim, 'Checking...', 'Looking for your agent'),
    };
    return Tooltip(
      message: detail,
      child: _Glass(
        radius: 17,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: dot.withAlpha(150), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _textSoft, fontSize: 11.5, fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({super.key, required this.leading, required this.items, required this.onTap});

  /// Who is watching, first in the row.
  final Widget leading;
  final List<String> items;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length + 1,
        separatorBuilder: (context, index) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          if (index == 0) return leading;
          final item = items[index - 1];
          return Semantics(
            button: true,
            child: GestureDetector(
              onTap: () => onTap(item),
              child: _Glass(
                radius: 17,
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                child: Text(
                  item,
                  style: const TextStyle(color: _textStrong, fontSize: 12.5, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.focusNode, required this.onSubmit});

  final FixKitController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: _Glass(
        radius: 26,
        glow: const Color(0x66B388FF),
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Row(
          children: [
            const FixOrb(size: 26),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: controller.draft,
                focusNode: focusNode,
                minLines: 1,
                maxLines: 4,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.send,
                textCapitalization: TextCapitalization.sentences,
                autocorrect: false,
                cursorColor: const Color(0xFFB388FF),
                style: const TextStyle(color: _textStrong, fontSize: 15.5),
                decoration: InputDecoration.collapsed(
                  hintText: 'What should change here?',
                  hintStyle: const TextStyle(color: _textDim, fontSize: 15.5),
                ),
                onSubmitted: (_) => onSubmit(),
              ),
            ),
            const SizedBox(width: 8),
            ListenableBuilder(
              listenable: controller.draft,
              builder: (context, _) {
                final ready = controller.draft.text.trim().isNotEmpty;
                return Semantics(
                  button: true,
                  label: 'Send to your agent',
                  child: GestureDetector(
                    onTap: ready ? onSubmit : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ready ? null : const Color(0x24FFFFFF),
                        gradient: ready
                            ? const SweepGradient(colors: fixAgentColors, transform: GradientRotation(-0.6))
                            : null,
                        boxShadow: ready ? const [BoxShadow(color: Color(0x88B388FF), blurRadius: 14)] : const [],
                      ),
                      child: const Text(
                        '↑',
                        style: TextStyle(color: _textStrong, fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: Color(0x66FFFFFF))),
        gradient: LinearGradient(colors: [Color(0xEBFF8A65), Color(0xEBB388FF)]),
        shadows: [BoxShadow(color: Color(0x66B388FF), blurRadius: 14, offset: Offset(0, 4))],
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _textStrong,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
          decoration: TextDecoration.none,
        ),
      ),
    );
  }
}

/// Places the label above the lit area, or below it near the top of the screen.
class _LabelLayout extends SingleChildLayoutDelegate {
  _LabelLayout({required this.anchor, required this.topInset});

  final Rect anchor;
  final double topInset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(maxWidth: math.max(0, constraints.maxWidth - 24));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (anchor.center.dx - childSize.width / 2)
        .clamp(12.0, math.max(12.0, size.width - childSize.width - 12))
        .toDouble();
    final above = anchor.top - childSize.height - 10;
    final y = above > topInset + 8 ? above : anchor.bottom + 10;
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_LabelLayout oldDelegate) => oldDelegate.anchor != anchor || oldDelegate.topInset != topInset;
}

class _SpotlightPainter extends CustomPainter {
  _SpotlightPainter({required this.rect, required this.touch, required this.phase});

  final Rect? rect;
  final Offset touch;

  /// 0..1, repeating: turns the glow's colours.
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    // Kept inside the screen, so the ring is never cut by its edge.
    final bounds = (Offset.zero & size).deflate(4);
    final raw = rect == null ? Rect.fromCircle(center: touch, radius: 28) : rect!.inflate(6);
    final area = raw.intersect(bounds).isEmpty ? raw : raw.intersect(bounds);
    final hole = RRect.fromRectAndRadius(area, Radius.circular(rect == null ? 28 : 12));

    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(hole);
    canvas.drawPath(dim, Paint()..color = const Color(0x9E080A14));

    // The halo is drawn outside the hole only, so the widget stays crisp.
    canvas.save();
    canvas.clipPath(dim);

    final shader = SweepGradient(
      colors: fixAgentColors,
      transform: GradientRotation(phase * math.pi * 2),
    ).createShader(hole.outerRect.inflate(8));
    final breathe = 0.5 + 0.5 * math.sin(phase * math.pi * 2);
    canvas.drawRRect(
      hole,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 + 6 * breathe),
    );
    canvas.restore();
    canvas.drawRRect(
      hole,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SpotlightPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.touch != touch || oldDelegate.phase != phase;
}

// ---------------------------------------------------------------------------
// The agent card
// ---------------------------------------------------------------------------

/// The agent's live activity at the top of the screen: who has the request,
/// each step as it happens, and the agent's summary when it is done. Tap it to
/// fold it into a pill; tap again to open it.
class FixAgentCard extends StatelessWidget {
  const FixAgentCard({super.key, required this.controller});

  final FixKitController controller;

  @override
  Widget build(BuildContext context) {
    final run = controller.run;
    final notice = controller.notice;
    final width = math.min(MediaQuery.sizeOf(context).width - 24, 420.0);

    Widget child;
    if (run != null) {
      child = _RunCard(
        key: const ValueKey('fixkit.run'),
        run: run,
        expanded: controller.expanded,
        onToggle: controller.toggleExpanded,
        onClose: controller.dismiss,
      );
    } else if (notice != null) {
      child = _NoticeCard(key: ValueKey('fixkit.notice.${notice.title}'), notice: notice);
    } else {
      child = const SizedBox.shrink(key: ValueKey('fixkit.none'));
    }

    return DefaultTextStyle(
      style: const TextStyle(color: _textStrong, fontSize: 13, decoration: TextDecoration.none),
      child: SizedBox(
        width: width,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(alignment: Alignment.topCenter, scale: animation, child: child),
          ),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topCenter,
            children: [...previous, if (current != null) current],
          ),
          child: child,
        ),
      ),
    );
  }
}

Color _toneGlow(FixTone tone) => switch (tone) {
      FixTone.success => const Color(0x8022C55E),
      FixTone.error => const Color(0x80EF4444),
      FixTone.warning => const Color(0x80F59E0B),
      FixTone.info => const Color(0x804FC3F7),
      FixTone.working => const Color(0x80B388FF),
    };

class _RunCard extends StatelessWidget {
  const _RunCard({super.key, required this.run, required this.expanded, required this.onToggle, required this.onClose});

  final FixRun run;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onClose;

  /// The hub's steps; a hub that sends none (an older one) still gets steps
  /// that follow the status.
  List<FixStep> get _steps {
    if (run.steps.isNotEmpty) return run.steps;
    final who = run.agent ?? 'your agent';
    return switch (run.status) {
      FixRun.sending => const [FixStep('Sending the report')],
      FixStatus.queued => [FixStep('Waiting for $who')],
      FixStatus.fixing => [FixStep('Sent to $who', kind: FixStepKind.done), const FixStep('Working on the code')],
      FixStatus.reloading => [
          FixStep('Sent to $who', kind: FixStepKind.done),
          const FixStep('Edited the code', kind: FixStepKind.done),
          const FixStep('Hot reloading'),
        ],
      _ => const [],
    };
  }

  @override
  Widget build(BuildContext context) {
    final finished = run.finished;
    final steps = _steps;
    final footnote = run.footnote;

    return Semantics(
      container: true,
      liveRegion: true,
      label: run.title,
      child: GestureDetector(
        onTap: onToggle,
        child: _Glass(
          radius: expanded ? 24 : 22,
          glow: _toneGlow(run.tone),
          padding: EdgeInsets.fromLTRB(12, 10, 10, expanded ? 14 : 10),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    FixOrb(size: 28, busy: !finished, tone: finished ? run.tone : null),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 220),
                            child: Text(
                              run.title,
                              key: ValueKey(run.title),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: _textStrong),
                            ),
                          ),
                          if (run.comment.isNotEmpty)
                            Text(
                              '“${run.comment}”',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: _textDim),
                            ),
                        ],
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Close',
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onClose,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('✕', style: TextStyle(color: _textDim, fontSize: 13, fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                  ],
                ),
                if (expanded) ...[
                  const SizedBox(height: 10),
                  for (var i = 0; i < steps.length; i++)
                    _StepRow(
                      key: ValueKey('$i:${steps[i].text}'),
                      step: steps[i],
                      active: i == steps.length - 1 && !finished && steps[i].kind == FixStepKind.step,
                    ),
                  if (footnote != null && footnote.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _Summary(text: footnote, tone: run.tone),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({super.key, required this.step, required this.active});

  final FixStep step;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final Widget mark = switch (step.kind) {
      _ when active => const SizedBox.square(dimension: 14, child: _Spinner()),
      FixStepKind.error => const _Mark('✕', _red),
      FixStepKind.question => const _Mark('?', _amber),
      _ => const _Mark('✓', _green),
    };
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 6), child: child),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 6, top: 3, bottom: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: SizedBox(width: 16, child: Center(child: mark))),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                step.text,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.35,
                  color: active || step.kind == FixStepKind.done ? _textStrong : _textSoft,
                  fontWeight: step.kind == FixStepKind.done ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark(this.glyph, this.color);

  final String glyph;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 15,
      height: 15,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color.withAlpha(46), shape: BoxShape.circle),
      child: Text(glyph, style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w800, height: 1)),
    );
  }
}

/// The agent's own words, typed out.
class _Summary extends StatelessWidget {
  const _Summary({required this.text, required this.tone});

  final String text;
  final FixTone tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _toneGlow(tone)),
      ),
      child: TweenAnimationBuilder<int>(
        key: ValueKey(text),
        tween: IntTween(begin: 0, end: text.length),
        duration: Duration(milliseconds: math.min(1400, 16 * text.length)),
        builder: (context, shown, _) => Text(
          text.substring(0, shown),
          style: const TextStyle(fontSize: 13, height: 1.4, color: _textStrong),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({super.key, required this.notice});

  final FixNotice notice;

  @override
  Widget build(BuildContext context) {
    final color = switch (notice.tone) {
      FixTone.error => _red,
      FixTone.warning => _amber,
      FixTone.success => _green,
      _ => const Color(0xFF4FC3F7),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: _Glass(
        radius: 22,
        glow: _toneGlow(notice.tone),
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: color.withAlpha(160), blurRadius: 8)],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(notice.title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  if (notice.detail != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(notice.detail!, style: const TextStyle(fontSize: 12, color: _textSoft, height: 1.35)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small spinner that needs no Material ancestor.
class _Spinner extends StatefulWidget {
  const _Spinner();

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _turns =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(turns: _turns, child: const CustomPaint(painter: _ArcPainter()));
  }
}

class _ArcPainter extends CustomPainter {
  const _ArcPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = (Offset.zero & size).deflate(1);
    final paint = Paint()
      ..shader = const SweepGradient(colors: [Color(0x00B388FF), Color(0xFFB388FF), Color(0xFF4FC3F7)])
          .createShader(bounds)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(bounds, 0, math.pi * 1.5, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter oldDelegate) => false;
}
