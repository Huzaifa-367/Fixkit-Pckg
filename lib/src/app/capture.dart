import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// The app as it looked when it was pressed. The outline is drawn when the
/// report is sent, around whatever is selected by then.
class FixCapture {
  FixCapture._(this._image, this._pixelRatio, this._origin);

  final ui.Image _image;
  final double _pixelRatio;

  /// Where the captured boundary sits in the view.
  final Offset _origin;
  bool _disposed = false;

  /// A PNG with [highlight] outlined in red, or a red ring around [touch] when
  /// there is no area to outline. Coordinates are logical pixels of the view.
  Future<Uint8List?> toPng({Rect? highlight, Offset? touch}) async {
    if (_disposed) return null;
    final ratio = _pixelRatio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImage(_image, Offset.zero, Paint());

    final stroke = Paint()
      ..color = const Color(0xFFFF3B30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5 * ratio;
    if (highlight != null) {
      final local = highlight.shift(-_origin);
      final scaled = Rect.fromLTRB(local.left * ratio, local.top * ratio, local.right * ratio, local.bottom * ratio)
          .inflate(4 * ratio);
      canvas.drawRRect(RRect.fromRectAndRadius(scaled, Radius.circular(8 * ratio)), stroke);
    } else if (touch != null) {
      canvas.drawCircle((touch - _origin) * ratio, 22 * ratio, stroke);
    }

    final picture = recorder.endRecording();
    final marked = await picture.toImage(_image.width, _image.height);
    picture.dispose();
    try {
      final bytes = await marked.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } finally {
      marked.dispose();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _image.dispose();
  }
}

/// Captures the app under [boundaryKey]. Call it after a frame has painted
/// (`SchedulerBinding.endOfFrame`): a repaint boundary can only be captured
/// once it is painted.
Future<FixCapture?> captureApp(GlobalKey boundaryKey, {double maxPixelRatio = 2}) async {
  final context = boundaryKey.currentContext;
  if (context == null) return null;
  final boundary = context.findRenderObject();
  if (boundary is! RenderRepaintBoundary || !boundary.attached || boundary.debugNeedsPaint) {
    return null;
  }
  final ratio = math.min(View.of(context).devicePixelRatio, maxPixelRatio);
  final origin = boundary.localToGlobal(Offset.zero);
  final image = await boundary.toImage(pixelRatio: ratio);
  return FixCapture._(image, ratio, origin);
}
