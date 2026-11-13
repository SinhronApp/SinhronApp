import 'dart:math' as math;

import 'package:flutter/widgets.dart';

enum DsIconShape {
  search,
  edit,
  voice,
  photo,
  call,
  check,
  doubleCheck,
  muteBell,
  groupSilhouette,
  // ADR-055 — Saved messages.
  bookmark,
  tabChats,
  tabCalls,
  tabContacts,
  tabSettings,
}

class DsIcon extends StatelessWidget {
  final DsIconShape shape;
  final double size;
  final Color color;
  final double strokeWidth;

  const DsIcon({super.key, required this.shape, required this.size, required this.color, this.strokeWidth = 1.8});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DsIconPainter(shape: shape, color: color, strokeWidth: strokeWidth),
      ),
    );
  }
}

class _DsIconPainter extends CustomPainter {
  final DsIconShape shape;
  final Color color;
  final double strokeWidth;

  _DsIconPainter({required this.shape, required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (shape) {
      case DsIconShape.search:
        canvas.drawCircle(const Offset(11, 11), 7, stroke);
        canvas.drawLine(const Offset(16.5, 16.5), const Offset(21, 21), stroke);

      case DsIconShape.edit:
        final p = Path()
          ..moveTo(16.5, 3.5)
          ..lineTo(20.5, 7.5)
          ..lineTo(8.5, 19.5)
          ..lineTo(4.5, 19.5)
          ..lineTo(4.5, 15.5)
          ..close();
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(13.5, 6.5), const Offset(17.5, 10.5), stroke);

      case DsIconShape.voice:
        final wave = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;
        final bars = <List<double>>[
          [2, 12, 4, 12],
          [6, 8, 6, 16],
          [10, 5, 10, 19],
          [14, 8, 14, 16],
          [18, 10, 18, 14],
          [22, 12, 20, 12],
        ];
        for (final b in bars) {
          canvas.drawLine(Offset(b[0], b[1]), Offset(b[2], b[3]), wave);
        }

      case DsIconShape.photo:
        final rect = RRect.fromRectAndRadius(const Rect.fromLTWH(3, 5, 18, 14), const Radius.circular(2));
        canvas.drawRRect(rect, stroke);
        canvas.drawCircle(const Offset(9, 11), 2, stroke);
        final p = Path()
          ..moveTo(3, 17)
          ..lineTo(8, 13)
          ..lineTo(12, 16)
          ..lineTo(15, 14)
          ..lineTo(21, 19);
        canvas.drawPath(p, stroke);

      case DsIconShape.call:
      case DsIconShape.tabCalls:
        // Lucide / Feather "phone" path — canonical handset, fits 24×24 viewBox.
        // Source: lucide.dev/icons/phone (MIT). Ported arc-by-arc to dart:ui.
        final p = Path()
          ..moveTo(22, 16.92)
          ..lineTo(22, 19.92)
          ..arcToPoint(const Offset(19.82, 21.92), radius: const Radius.circular(2))
          ..arcToPoint(const Offset(11.19, 18.85), radius: const Radius.circular(19.79))
          ..arcToPoint(const Offset(5.19, 12.85), radius: const Radius.circular(19.5))
          ..arcToPoint(const Offset(2.12, 4.18), radius: const Radius.circular(19.79))
          ..arcToPoint(const Offset(4.11, 2), radius: const Radius.circular(2))
          ..lineTo(7.11, 2)
          ..arcToPoint(const Offset(9.11, 3.72), radius: const Radius.circular(2))
          ..cubicTo(9.24, 4.68, 9.47, 5.62, 9.81, 6.53)
          ..arcToPoint(const Offset(9.36, 8.64), radius: const Radius.circular(2))
          ..lineTo(8.09, 9.91)
          ..arcToPoint(const Offset(14.09, 15.91), radius: const Radius.circular(16), clockwise: false)
          ..lineTo(15.36, 14.64)
          ..arcToPoint(const Offset(17.47, 14.19), radius: const Radius.circular(2))
          ..cubicTo(18.38, 14.53, 19.32, 14.76, 20.28, 14.89)
          ..arcToPoint(const Offset(22, 16.92), radius: const Radius.circular(2))
          ..close();
        canvas.drawPath(p, stroke);

      case DsIconShape.check:
        canvas.save();
        canvas.translate(2, 5);
        final p = Path()
          ..moveTo(1, 7)
          ..lineTo(5.5, 11.5)
          ..lineTo(13, 4);
        canvas.drawPath(p, stroke);
        canvas.restore();

      case DsIconShape.doubleCheck:
        canvas.save();
        canvas.translate(1, 5);
        final p1 = Path()
          ..moveTo(1, 7)
          ..lineTo(5.5, 11.5)
          ..lineTo(13, 4);
        final p2 = Path()
          ..moveTo(9, 7)
          ..lineTo(13.5, 11.5)
          ..lineTo(21, 4);
        canvas.drawPath(p1, stroke);
        canvas.drawPath(p2, stroke);
        canvas.restore();

      case DsIconShape.muteBell:
        final p = Path()
          ..moveTo(12, 4)
          ..cubicTo(14.76, 4, 17, 6.24, 17, 9)
          ..lineTo(17, 13)
          ..lineTo(19, 16)
          ..lineTo(5, 16)
          ..lineTo(7, 13)
          ..lineTo(7, 9)
          ..cubicTo(7, 6.24, 9.24, 4, 12, 4)
          ..close();
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(3, 3), const Offset(21, 21), stroke);

      case DsIconShape.bookmark:
        // A ribbon bookmark, filled (Saved messages avatar).
        final p = Path()
          ..moveTo(6, 3.5)
          ..lineTo(18, 3.5)
          ..quadraticBezierTo(19, 3.5, 19, 4.5)
          ..lineTo(19, 20.5)
          ..lineTo(12, 15.8)
          ..lineTo(5, 20.5)
          ..lineTo(5, 4.5)
          ..quadraticBezierTo(5, 3.5, 6, 3.5)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);

      case DsIconShape.groupSilhouette:
        final whiteFull = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        final whiteFaded = Paint()
          ..color = color.withValues(alpha: color.a * 0.72)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(const Offset(9, 9), 3.5, whiteFull);
        canvas.drawCircle(const Offset(16.5, 9.5), 2.7, whiteFaded);
        final body1 = Path()
          ..moveTo(3, 18.5)
          ..cubicTo(3, 15.5, 5.7, 13.3, 9, 13.3)
          ..cubicTo(12.3, 13.3, 15, 15.5, 15, 18.5)
          ..lineTo(15, 19)
          ..lineTo(3, 19)
          ..close();
        canvas.drawPath(body1, whiteFull);
        final body2 = Path()
          ..moveTo(14.5, 18)
          ..cubicTo(14.9, 16.4, 16.2, 15.1, 18.0, 14.6)
          ..cubicTo(20.4, 14.0, 21.5, 15.7, 21.5, 18.0)
          ..lineTo(21.5, 19)
          ..lineTo(14.5, 19)
          ..close();
        canvas.drawPath(body2, whiteFaded);

      case DsIconShape.tabChats:
        final p = Path()
          ..moveTo(4, 6.5)
          ..cubicTo(4, 5.12, 5.12, 4, 6.5, 4)
          ..lineTo(17.5, 4)
          ..cubicTo(18.88, 4, 20, 5.12, 20, 6.5)
          ..lineTo(20, 14.5)
          ..cubicTo(20, 15.88, 18.88, 17, 17.5, 17)
          ..lineTo(10, 17)
          ..lineTo(6, 20.5)
          ..lineTo(6, 17)
          ..lineTo(6.5, 17)
          ..cubicTo(5.12, 17, 4, 15.88, 4, 14.5)
          ..close();
        canvas.drawPath(p, stroke);

      case DsIconShape.tabContacts:
        canvas.drawCircle(const Offset(12, 8), 4, stroke);
        final p = Path()
          ..moveTo(4, 21)
          ..cubicTo(4, 17, 7.6, 14, 12, 14)
          ..cubicTo(16.4, 14, 20, 17, 20, 21);
        canvas.drawPath(p, stroke);

      case DsIconShape.tabSettings:
        // Proper gear: 8 trapezoidal teeth around a body ring + center hole.
        // Each tooth is its own stroked trapezoid; the body ring sits behind.
        const center = Offset(12, 12);
        canvas.drawCircle(center, 6.2, stroke);
        canvas.drawCircle(center, 2.6, stroke);
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4;
          canvas.save();
          canvas.translate(center.dx, center.dy);
          canvas.rotate(angle);
          // tooth: trapezoid, wider at base (closer to center) than at tip
          final tooth = Path()
            ..moveTo(-2.0, -6.2) // inner-left (sits on body ring)
            ..lineTo(2.0, -6.2) // inner-right
            ..lineTo(1.4, -10.0) // outer-right (narrower)
            ..lineTo(-1.4, -10.0) // outer-left
            ..close();
          canvas.drawPath(tooth, stroke);
          canvas.restore();
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DsIconPainter old) => old.shape != shape || old.color != color || old.strokeWidth != strokeWidth;
}

/// Shared line glyphs — UI backlog §5 item 40. One drawing per glyph on
/// a 24×24 grid with one stroke weight, instead of a private painter per
/// screen (25 back chevrons used to be drawn 25 slightly different ways).
enum DsGlyph { back, chevron, plus, close, check, mic, send, backspace, keyboard, camera, gallery, video, document }

class DsGlyphPainter extends CustomPainter {
  const DsGlyphPainter(this.glyph, {required this.color, this.strokeWidth = 1.8});

  final DsGlyph glyph;
  final Color color;
  final double strokeWidth;

  /// Glyph extent on the 24 grid, for non-square boxes (e.g. a 7×12
  /// row chevron fits the stroke, not the padding).
  Rect get _bounds => switch (glyph) {
    DsGlyph.back => const Rect.fromLTRB(8, 5, 15, 19),
    DsGlyph.chevron => const Rect.fromLTRB(9, 5, 16, 19),
    _ => const Rect.fromLTRB(0, 0, 24, 24),
  };

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final square = (size.width - size.height).abs() < 0.5;
    final box = square ? const Rect.fromLTWH(0, 0, 24, 24) : _bounds;
    final scale = square
        ? size.width / 24
        : (size.width / box.width < size.height / box.height ? size.width / box.width : size.height / box.height);
    canvas.translate(
      (size.width - box.width * scale) / 2 - box.left * scale,
      (size.height - box.height * scale) / 2 - box.top * scale,
    );
    canvas.scale(scale);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = square ? strokeWidth : strokeWidth / scale * (size.shortestSide / 12).clamp(1.0, 2.0)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    Path poly(List<Offset> pts) {
      final path = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (final o in pts.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      return path;
    }

    switch (glyph) {
      case DsGlyph.back:
        canvas.drawPath(poly(const [Offset(15, 5), Offset(8, 12), Offset(15, 19)]), p);
      case DsGlyph.chevron:
        canvas.drawPath(poly(const [Offset(9, 5), Offset(16, 12), Offset(9, 19)]), p);
      case DsGlyph.plus:
        canvas.drawLine(const Offset(12, 5), const Offset(12, 19), p);
        canvas.drawLine(const Offset(5, 12), const Offset(19, 12), p);
      case DsGlyph.close:
        canvas.drawLine(const Offset(6, 6), const Offset(18, 18), p);
        canvas.drawLine(const Offset(18, 6), const Offset(6, 18), p);
      case DsGlyph.check:
        canvas.drawPath(poly(const [Offset(5, 12.5), Offset(10, 17), Offset(19, 7)]), p);
      case DsGlyph.mic:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(9, 3, 6, 11), const Radius.circular(3)), p);
        canvas.drawArc(const Rect.fromLTWH(5.5, 5, 13, 13), 0.15, 2.84, false, p);
        canvas.drawLine(const Offset(12, 18), const Offset(12, 21), p);
      case DsGlyph.send:
        canvas.drawLine(const Offset(12, 19), const Offset(12, 5.5), p);
        canvas.drawPath(poly(const [Offset(6, 11), Offset(12, 5), Offset(18, 11)]), p);
      // The emoji panel's ⌫ and the composer's "back to the keyboard".
      case DsGlyph.backspace:
        canvas.drawPath(
          poly(const [Offset(8.5, 5.5), Offset(20, 5.5), Offset(20, 18.5), Offset(8.5, 18.5), Offset(3, 12), Offset(8.5, 5.5)]),
          p,
        );
        canvas.drawLine(const Offset(11, 9.5), const Offset(16, 14.5), p);
        canvas.drawLine(const Offset(16, 9.5), const Offset(11, 14.5), p);
      case DsGlyph.keyboard:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(2.5, 6, 19, 12), const Radius.circular(2.5)), p);
        for (final x in const [6.5, 10.0, 13.5, 17.0]) {
          canvas.drawLine(Offset(x, 9.5), Offset(x + 0.01, 9.5), p);
        }
        canvas.drawLine(const Offset(8, 14.5), const Offset(16, 14.5), p);
      // The composer's attach panel.
      case DsGlyph.camera:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(2.5, 7, 19, 13.5), const Radius.circular(3.5)), p);
        canvas.drawPath(poly(const [Offset(8, 7), Offset(9.6, 4.5), Offset(14.4, 4.5), Offset(16, 7)]), p);
        canvas.drawCircle(const Offset(12, 13.6), 3.6, p);
      case DsGlyph.gallery:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 4, 18, 16), const Radius.circular(3.5)), p);
        canvas.drawCircle(const Offset(8.6, 9.4), 1.7, p);
        canvas.drawPath(poly(const [Offset(3.6, 17.4), Offset(9, 12.4), Offset(13, 16), Offset(15.6, 13.6), Offset(20.4, 18)]), p);
      case DsGlyph.video:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(2.5, 6.5, 13, 11), const Radius.circular(3)), p);
        canvas.drawPath(
          poly(const [Offset(15.5, 10.4), Offset(21, 7.6), Offset(21, 16.4), Offset(15.5, 13.6)]),
          p,
        );
      case DsGlyph.document:
        canvas.drawPath(
          poly(const [Offset(13.5, 3), Offset(6.5, 3), Offset(5.5, 4), Offset(5.5, 20), Offset(6.5, 21), Offset(17.5, 21), Offset(18.5, 20), Offset(18.5, 8), Offset(13.5, 3), Offset(13.5, 8), Offset(18.5, 8)]),
          p,
        );
        canvas.drawLine(const Offset(9, 13), const Offset(15, 13), p);
        canvas.drawLine(const Offset(9, 16.5), const Offset(13, 16.5), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsGlyphPainter old) => old.glyph != glyph || old.color != color || old.strokeWidth != strokeWidth;
}
