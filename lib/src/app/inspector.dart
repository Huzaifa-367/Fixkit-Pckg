import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'markers.dart';

/// Wraps fixkit's own views (the composer, the agent card). A press never reports
/// them.
class FixKitChrome extends StatelessWidget {
  const FixKitChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// One widget in the chain from the pressed widget up to the root, with the
/// place in the source where it was constructed.
class FixFrame {
  const FixFrame({required this.widget, this.file, this.line, this.column, this.text});

  /// The widget's class name.
  final String widget;

  /// The file the widget was constructed in, as a `file:` URI. Debug builds
  /// track this for every widget (`--track-widget-creation`, on by default).
  final String? file;
  final int? line;
  final int? column;

  /// The text the widget shows, when it is a [Text] or [RichText].
  final String? text;

  Map<String, Object?> toJson() => {
        'widget': widget,
        if (file != null) 'file': file,
        if (line != null) 'line': line,
        if (column != null) 'column': column,
        if (text != null) 'text': text,
      };

  /// `wallet_card.dart:42`, for the composer's label.
  String get shortLocation {
    final path = file;
    if (path == null) return widget;
    final name = path.split('/').last;
    return line == null ? name : '$name:$line';
  }
}

/// A widget the selection can rest on: the pressed widget, or one of its
/// ancestors written in the app's own code (a Row, a Column, a card...).
@immutable
class FixScope {
  const FixScope({required this.frame, required this.rect, required this.chainIndex, this.name, this.text});

  final FixFrame frame;

  /// Its bounds in the view's logical pixels.
  final Rect rect;

  /// Where [frame] sits in [FixInspection.chain].
  final int chainIndex;

  /// The [FixName]'s name, when this scope is one.
  final String? name;

  /// Its own text, or the first text inside it.
  final String? text;

  /// How the selection bar names it: `Row`, `"home.walletCard"`.
  String get label => name == null ? frame.widget : '"$name"';

  Map<String, Object?> toJson() => {
        ...frame.toJson(),
        if (name != null) 'name': name,
        if (text != null) 'text': text,
        'rect': _rectJson(rect),
      };
}

/// What a long press landed on, and how far the selection reaches: the
/// pressed widget or, after widening it, a Row, Column or card around it.
@immutable
class FixInspection {
  const FixInspection({
    required this.touch,
    required this.chain,
    required this.tracking,
    this.scopes = const [],
    this.selected = 0,
    this.named,
    this.route,
    this.screen,
    this.nearby = const [],
  });

  /// Nothing could be inspected: only the touch point is known.
  factory FixInspection.empty(Offset touch) => FixInspection(touch: touch, chain: const [], tracking: false);

  /// Where the finger was, in logical pixels of the view.
  final Offset touch;

  /// From the pressed widget up to the root, deepest first: the app's own
  /// widgets (or every widget, up to a limit, when creation tracking is off).
  final List<FixFrame> chain;

  /// Whether the build tracks widget creation locations.
  final bool tracking;

  /// What the selection can rest on, from the pressed widget outwards.
  final List<FixScope> scopes;

  /// The selected scope's index in [scopes]; 0 is the pressed widget.
  final int selected;

  /// The innermost [FixName] around the pressed widget, with the place it
  /// was declared and its index in [chain].
  final ({String name, FixFrame frame, int chainIndex})? named;

  /// The route's name, when it has one.
  final String? route;

  /// The [FixScreen] name, else a widget whose class ends in Screen/Page/View.
  final String? screen;

  /// Texts shown near the pressed widget, nearest first.
  final List<String> nearby;

  /// The selected scope.
  FixScope? get scope => scopes.isEmpty ? null : scopes[selected.clamp(0, scopes.length - 1)];

  /// The widget the finger was on.
  FixScope? get pressed => scopes.isEmpty ? null : scopes.first;

  /// The selected widget: what the report is about.
  FixFrame? get target => scope?.frame ?? (chain.isEmpty ? null : chain.first);
  Rect? get targetRect => scope?.rect;
  String? get targetText => scope?.text;

  /// The area the composer lights and the screenshot outlines.
  Rect? get spotRect => targetRect;

  bool get canWiden => selected < scopes.length - 1;
  bool get canNarrow => selected > 0;

  /// The same press with another scope selected.
  FixInspection select(int index) => FixInspection(
        touch: touch,
        chain: chain,
        tracking: tracking,
        scopes: scopes,
        selected: scopes.isEmpty ? 0 : index.clamp(0, scopes.length - 1),
        named: named,
        route: route,
        screen: screen,
        nearby: nearby,
      );

  /// Whether the selection sits inside the [FixName] (or is it).
  bool get _insideNamed {
    final named = this.named;
    if (named == null) return false;
    final scope = this.scope;
    return scope == null || named.chainIndex >= scope.chainIndex;
  }

  /// The composer's label: the selected widget and its file and line.
  String? get label {
    final scope = this.scope;
    if (scope != null) return '${scope.label}  ·  ${scope.frame.shortLocation}';
    if (screen != null) return '$screen screen';
    return null;
  }

  Map<String, Object?> toJson() {
    final scope = this.scope;
    final pressed = this.pressed;
    final from = scope?.chainIndex ?? 0;
    return {
      'touch': {'x': touch.dx.roundToDouble(), 'y': touch.dy.roundToDouble()},
      'tracking': tracking,
      // From the selected widget up: the agent starts at the first line.
      'chain': [for (final frame in chain.skip(from)) frame.toJson()],
      if (target != null) 'target': target!.toJson(),
      if (targetRect != null) 'targetRect': _rectJson(targetRect!),
      if (targetText != null) 'targetText': targetText,
      if (pressed != null && selected > 0) 'pressed': pressed.toJson(),
      if (scopes.length > 1)
        'selection': {
          'index': selected,
          'widgets': [for (final scope in scopes) scope.label],
        },
      if (named != null && _insideNamed) 'named': {'name': named!.name, ...named!.frame.toJson()},
      if (route != null) 'route': route,
      if (screen != null) 'screen': screen,
      if (nearby.isNotEmpty) 'nearby': nearby,
    };
  }
}

Map<String, Object?> _rectJson(Rect rect) => {
      'x': rect.left.roundToDouble(),
      'y': rect.top.roundToDouble(),
      'width': rect.width.roundToDouble(),
      'height': rect.height.roundToDouble(),
    };

/// How many ancestors are walked, and how many are kept.
const int _maxWalk = 400;
const int _maxChain = 60;
const int _maxScopes = 12;

/// Where fixkit's own `lib/src/` is, as creation locations spell it. Set at
/// launch, so fixkit's widgets never count as the app's, however fixkit is
/// installed (a path dependency to a clone, say).
String? fixkitSourceRoot;

/// Whether a creation location is in the app's own code rather than in the
/// Flutter SDK, a pub package or fixkit itself. The hub repeats this check
/// with the project's real root.
bool looksLikeAppCode(String file) {
  final path = file.replaceAll('\\', '/');
  final own = fixkitSourceRoot;
  if (own != null && path.startsWith(own)) return false;
  const outside = [
    '/packages/flutter/',
    '/flutter/packages/',
    '/flutter/bin/cache/',
    '/sky_engine/',
    '/.pub-cache/',
    '/Pub/Cache/',
    '/fixkit/lib/src/',
    'org-dartlang-sdk',
    'dart:',
  ];
  return !outside.any(path.contains);
}

/// Inspects the widget under [position] in the view [viewId].
FixInspection inspectAt(Offset position, int viewId) {
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, viewId);

  Element? hit;
  for (final entry in result.path) {
    final target = entry.target;
    if (target is! RenderObject) continue;
    final creator = target.debugCreator;
    if (creator is! DebugCreator) continue;
    if (_isChrome(creator.element)) continue;
    hit = creator.element;
    break;
  }
  if (hit == null) return FixInspection.empty(position);
  final first = _inspect(hit, position);

  // A press on a gap (between the avatar and the name in a Row, around a
  // heading) or on a widget that takes no touches (a Text under
  // IgnorePointer, a decoration) falls through to whatever is behind it:
  // often the whole screen. Then look for the app's own widget drawn under
  // the finger, by its bounds.
  final pressedRect = first.inspection.pressed?.rect;
  final area = _screenArea(hit);
  if (pressedRect == null || pressedRect.width * pressedRect.height >= area * 0.4) {
    final drawn = _appElementAt(first.pressed ?? hit, position);
    if (drawn != null && drawn != first.pressed) {
      final second = _inspect(drawn, position);
      final rect = second.inspection.pressed?.rect;
      if (rect != null && (pressedRect == null || rect.width * rect.height < pressedRect.width * pressedRect.height)) {
        return second.inspection;
      }
    }
  }
  return first.inspection;
}

/// The deepest widget of the app's own code drawn at [touch] inside [root],
/// whether or not it takes touches: the topmost child at each level, as hit
/// testing would pick, but by bounds alone.
Element? _appElementAt(Element root, Offset touch) {
  final delegate = InspectorSerializationDelegate(
    service: WidgetInspectorService.instance,
    subtreeDepth: 0,
    includeProperties: false,
  );
  final tracking = _isTracking();
  Element? best;
  var bestDepth = -1;
  var visits = 0;

  bool hidden(Widget widget) =>
      widget is FixKitChrome ||
      (widget is Offstage && widget.offstage) ||
      (widget is Visibility && !widget.visible) ||
      (widget is TickerMode && !widget.enabled);

  // Whether [element]'s render object lets children draw outside it (a Stack
  // with Clip.none, for an avatar overlapping a banner).
  bool overflows(Element element) {
    final box = element.findRenderObject();
    return box is RenderStack && box.clipBehavior == Clip.none;
  }

  /// Walks [element]; true when it (or something inside) is a candidate.
  bool walk(Element element, int depth) {
    if (++visits > 3000 || hidden(element.widget)) return false;
    final rect = _rectOf(element);
    final contains = rect == null || rect.contains(touch);
    if (!contains && !overflows(element)) return false;
    var found = false;
    if (rect != null && contains && depth > bestDepth && element != root) {
      final location = tracking ? _creationLocation(element, delegate) : null;
      if (location != null && looksLikeAppCode(location.file) && !_isSpacer(element.widget)) {
        best = element;
        bestDepth = depth;
        found = true;
      }
    }
    final children = <Element>[];
    element.visitChildElements(children.add);
    final widget = element.widget;
    if (widget is IndexedStack && widget.index != null && children.length == widget.children.length) {
      final index = widget.index!;
      if (index >= 0 && index < children.length) found = walk(children[index], depth + 1) || found;
      return found;
    }
    // Later children paint on top, except in a scroll view, where the first
    // sliver (a pinned header) is on top: the first child that holds the
    // point and has something of the app's wins.
    final viewport = element is RenderObjectElement && element.renderObject is RenderViewportBase;
    final order = viewport ? children : children.reversed;
    final loose = overflows(element);
    for (final child in order) {
      final childRect = _rectOf(child);
      final inside = childRect == null || childRect.contains(touch) || loose || overflows(child);
      if (!inside) continue;
      if (walk(child, depth + 1)) {
        found = true;
        if (childRect != null || viewport) break;
      }
    }
    return found;
  }

  walk(root, 0);
  return best;
}

/// Empty space between widgets: a press there is about the widget around it.
bool _isSpacer(Widget widget) => (widget is SizedBox && widget.child == null) || widget is Spacer;

double _screenArea(Element element) {
  final view = View.maybeOf(element);
  if (view == null) return double.infinity;
  return (view.physicalSize.width / view.devicePixelRatio) * (view.physicalSize.height / view.devicePixelRatio);
}

/// Inspects [hit], the deepest element under [touch], and its ancestors.
FixInspection inspectElement(Element hit, Offset touch) => _inspect(hit, touch).inspection;

({FixInspection inspection, Element? pressed}) _inspect(Element hit, Offset touch) {
  final tracking = _isTracking();
  // One delegate for the whole walk.
  final delegate = InspectorSerializationDelegate(
    service: WidgetInspectorService.instance,
    subtreeDepth: 0,
    includeProperties: false,
  );
  final chain = <FixFrame>[];
  final elements = <Element>[];
  ({String name, FixFrame frame, int chainIndex})? named;
  String? screen;
  String? screenGuess;

  var walked = 0;
  void visit(Element element) {
    walked++;
    final widget = element.widget;
    if (widget is FixKitChrome) return;
    final location = tracking ? _creationLocation(element, delegate) : null;
    final frame = FixFrame(
      widget: _typeName(widget),
      file: location?.file,
      line: location?.line,
      column: location?.column,
      text: _ownText(widget),
    );

    if (widget is FixScreen && screen == null) screen = widget.name;
    if (screenGuess == null && location != null && looksLikeAppCode(location.file)) {
      final type = frame.widget;
      if (type.endsWith('Screen') || type.endsWith('Page') || type.endsWith('View')) screenGuess = type;
    }

    // With creation tracking every widget has a location, Flutter's own
    // included: keep the deepest one and the app's own widgets. Without it,
    // keep the nearest widgets by type alone.
    final isApp = location != null && looksLikeAppCode(location.file);
    final keep = tracking ? (isApp || widget is FixName || (location != null && chain.isEmpty)) : chain.length < 25;
    if (keep && chain.length < _maxChain) {
      if (widget is FixName && named == null) named = (name: widget.name, frame: frame, chainIndex: chain.length);
      chain.add(frame);
      elements.add(element);
    }
  }

  visit(hit);
  hit.visitAncestorElements((ancestor) {
    visit(ancestor);
    return walked < _maxWalk;
  });

  // The scopes: the app's own widgets that have a size, from the pressed one
  // outwards, up to the first that fills the screen.
  final screenArea = _screenArea(hit);
  final scopes = <FixScope>[];
  Element? pressedElement;
  String? pressedText;
  for (var i = 0; i < chain.length && scopes.length < _maxScopes; i++) {
    final frame = chain[i];
    final file = frame.file;
    if (tracking && (file == null || !looksLikeAppCode(file))) continue;
    if (frame.widget == 'FixKit') continue;
    final rect = _rectOf(elements[i]);
    if (rect == null) continue;
    // A widget and the one it builds at the same place add nothing, except a
    // FixName, which is a stop of its own.
    final widget = elements[i].widget;
    final last = scopes.isEmpty ? null : scopes.last;
    if (last != null &&
        widget is! FixName &&
        last.rect == rect &&
        last.frame.file == frame.file &&
        last.frame.line == frame.line) {
      continue;
    }

    String? text;
    if (pressedElement == null) {
      pressedElement = elements[i];
      pressedText = _textAlong(hit, elements[i]) ?? _firstTextInside(elements[i]);
      text = pressedText;
    } else {
      text = _ownText(widget) ?? _firstTextInside(elements[i]);
    }
    scopes.add(FixScope(
      frame: frame,
      rect: rect,
      chainIndex: i,
      name: widget is FixName ? widget.name : null,
      text: text,
    ));
    if (rect.width * rect.height >= screenArea * 0.9) break;
  }

  // Nothing of the app's own under the finger: the deepest widget will do.
  if (scopes.isEmpty && chain.isNotEmpty) {
    final rect = _rectOf(elements.first) ?? _rectOf(hit);
    if (rect != null) {
      pressedElement = elements.first;
      pressedText = _textAlong(hit, elements.first) ?? _firstTextInside(elements.first);
      scopes.add(FixScope(frame: chain.first, rect: rect, chainIndex: 0, text: pressedText));
    }
  }

  final inspection = FixInspection(
    touch: touch,
    chain: chain,
    tracking: tracking,
    scopes: scopes,
    named: named,
    route: _routeName(hit),
    screen: screen ?? screenGuess,
    nearby: _nearbyTexts(pressedElement ?? hit, touch, exclude: pressedText),
  );
  return (inspection: inspection, pressed: pressedElement);
}

/// The file [element]'s widget was constructed in, as a `file://` URI, when
/// widget creation is tracked. For `FixKit` that is the app's `main.dart`, which
/// tells the hub which project the app is.
String? creationFileOf(Element element) {
  if (!_isTracking()) return null;
  final delegate = InspectorSerializationDelegate(
    service: WidgetInspectorService.instance,
    subtreeDepth: 0,
    includeProperties: false,
  );
  return _creationLocation(element, delegate)?.file;
}

bool _isTracking() {
  try {
    return WidgetInspectorService.instance.isWidgetCreationTracked();
  } catch (_) {
    return false;
  }
}

/// The place [element]'s widget was constructed, from the same data the
/// Flutter inspector shows. Only available in debug builds with widget creation
/// tracking, which `flutter run` turns on by default.
({String file, int line, int column})? _creationLocation(Element element, InspectorSerializationDelegate delegate) {
  try {
    final json = element.toDiagnosticsNode().toJsonMap(delegate);
    final location = json['creationLocation'];
    if (location is! Map) return null;
    final file = location['file'];
    final line = location['line'];
    final column = location['column'];
    if (file is! String || line is! int) return null;
    return (file: file, line: line, column: column is int ? column : 0);
  } catch (_) {
    return null;
  }
}

String _typeName(Widget widget) {
  final name = widget.runtimeType.toString();
  // Generic widgets read as `Consumer<Cart>`; keep them as they are.
  return name;
}

String? _ownText(Widget widget) {
  String? text;
  if (widget is Text) {
    text = widget.data ?? widget.textSpan?.toPlainText();
  } else if (widget is RichText) {
    text = widget.text.toPlainText();
  } else if (widget is Icon) {
    text = widget.semanticLabel;
  } else if (widget is Image) {
    text = widget.semanticLabel;
  } else if (widget is Semantics) {
    text = widget.properties.label;
  }
  return _clean(text);
}

String? _clean(String? text) {
  if (text == null) return null;
  final trimmed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (trimmed.isEmpty) return null;
  return trimmed.length > 120 ? '${trimmed.substring(0, 117)}...' : trimmed;
}

/// The first text on the way from [from] up to [to].
String? _textAlong(Element from, Element to) {
  String? found = _ownText(from.widget);
  if (found != null || identical(from, to)) return found;
  from.visitAncestorElements((ancestor) {
    found = _ownText(ancestor.widget);
    return found == null && !identical(ancestor, to);
  });
  return found;
}

/// The first text inside [element]: the label of a button, say.
String? _firstTextInside(Element element) {
  String? found;
  var budget = 300;
  void visit(Element child) {
    if (found != null || budget-- <= 0) return;
    final text = child.widget is RichText ? _ownText(child.widget) : null;
    if (text != null) {
      found = text;
      return;
    }
    child.visitChildElements(visit);
  }

  element.visitChildElements(visit);
  return found;
}

/// Texts near the pressed widget: those inside the smallest ancestor that
/// holds a few, nearest first.
List<String> _nearbyTexts(Element element, Offset touch, {String? exclude}) {
  var scope = element;
  var texts = _textsInside(scope);
  var climbs = 0;
  while (texts.length < 4 && climbs < 8) {
    Element? parent;
    scope.visitAncestorElements((ancestor) {
      parent = ancestor;
      return false;
    });
    if (parent == null) break;
    scope = parent!;
    texts = _textsInside(scope);
    climbs++;
  }

  double distance(({String text, Rect rect}) item) =>
      (item.rect.center - touch).distance;
  texts.sort((a, b) => distance(a).compareTo(distance(b)));

  final seen = <String>{if (exclude != null) exclude};
  final nearby = <String>[];
  for (final item in texts) {
    if (seen.add(item.text)) nearby.add(item.text);
    if (nearby.length == 6) break;
  }
  return nearby;
}

List<({String text, Rect rect})> _textsInside(Element element) {
  final found = <({String text, Rect rect})>[];
  var budget = 600;
  void visit(Element child) {
    if (budget-- <= 0 || child.widget is FixKitChrome) return;
    if (child.widget is RichText) {
      final text = _ownText(child.widget);
      final rect = _rectOf(child);
      if (text != null && rect != null) found.add((text: text, rect: rect));
      return;
    }
    child.visitChildElements(visit);
  }

  visit(element);
  return found;
}

/// [element]'s bounds in the view's logical pixels.
Rect? _rectOf(Element element) {
  try {
    final renderObject = element.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached || !renderObject.hasSize) return null;
    final rect = MatrixUtils.transformRect(
      renderObject.getTransformTo(null),
      Offset.zero & renderObject.size,
    );
    if (!rect.isFinite || rect.isEmpty) return null;
    return Rect.fromLTRB(
      rect.left,
      rect.top,
      math.max(rect.right, rect.left + 1),
      math.max(rect.bottom, rect.top + 1),
    );
  } catch (_) {
    return null;
  }
}

String? _routeName(Element element) {
  try {
    final name = ModalRoute.of(element)?.settings.name;
    return name == null || name.isEmpty ? null : name;
  } catch (_) {
    return null;
  }
}

bool _isChrome(Element element) {
  if (element.widget is FixKitChrome) return true;
  var chrome = false;
  element.visitAncestorElements((ancestor) {
    chrome = ancestor.widget is FixKitChrome;
    return !chrome;
  });
  return chrome;
}
