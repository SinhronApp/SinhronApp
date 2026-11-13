// Glyphs that several screens drew with byte-identical painters — one copy
// here (tech-debt 2.26). Same code, same pixels; the names say what they draw.

import 'package:flutter/widgets.dart';

class DsBellOffGlyph extends CustomPainter {
  final Color color;
  DsBellOffGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
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
    final clapper = Path()
      ..moveTo(10, 19)
      ..arcToPoint(const Offset(14, 19), radius: const Radius.circular(2));
    canvas.drawPath(clapper, stroke);
    canvas.drawLine(const Offset(4, 4), const Offset(20, 20), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsBellOffGlyph old) => old.color != color;
}

class DsArchiveGlyph extends CustomPainter {
  final Color color;
  DsArchiveGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 4, 18, 4), const Radius.circular(1)), stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(4.5, 8, 15, 12), const Radius.circular(2)), stroke);
    canvas.drawLine(const Offset(10, 13), const Offset(14, 13), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsArchiveGlyph old) => old.color != color;
}

class DsTrashGlyph extends CustomPainter {
  final Color color;
  DsTrashGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(const Offset(3, 6), const Offset(21, 6), stroke);
    final body = Path()
      ..moveTo(8, 6)
      ..lineTo(8, 4)
      ..arcToPoint(const Offset(9, 3), radius: const Radius.circular(1))
      ..lineTo(15, 3)
      ..arcToPoint(const Offset(16, 4), radius: const Radius.circular(1))
      ..lineTo(16, 6)
      ..moveTo(6, 6)
      ..lineTo(7, 20)
      ..arcToPoint(const Offset(8, 21), radius: const Radius.circular(1))
      ..lineTo(16, 21)
      ..arcToPoint(const Offset(17, 20), radius: const Radius.circular(1))
      ..lineTo(18, 6);
    canvas.drawPath(body, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsTrashGlyph old) => old.color != color;
}

class DsMicMutedGlyph extends CustomPainter {
  final Color color;
  DsMicMutedGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(9, 2.5, 6, 12), const Radius.circular(3)), stroke);
    final cup = Path()
      ..moveTo(5, 11)
      ..cubicTo(5, 15, 8.13, 18, 12, 18)
      ..cubicTo(15.87, 18, 19, 15, 19, 11);
    canvas.drawPath(cup, stroke);
    canvas.drawLine(const Offset(12, 18), const Offset(12, 21), stroke);
    final slash = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(3, 3), const Offset(21, 21), slash);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsMicMutedGlyph old) => old.color != color;
}

class DsLockGlyph extends CustomPainter {
  final Color color;
  DsLockGlyph({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(4.5, 11, 15, 10), const Radius.circular(2.2)), stroke);
    final shackle = Path()
      ..moveTo(8, 11)
      ..lineTo(8, 8)
      ..arcToPoint(const Offset(16, 8), radius: const Radius.circular(4))
      ..lineTo(16, 11);
    canvas.drawPath(shackle, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsLockGlyph old) => old.color != color;
}

class DsCheckmarkGlyph extends CustomPainter {
  final Color color;
  const DsCheckmarkGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(5, 12)
      ..lineTo(10, 17)
      ..lineTo(20, 7);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsCheckmarkGlyph old) => old.color != color;
}

class DsKeyGlyphGlyph extends CustomPainter {
  final Color color;
  DsKeyGlyphGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(8, 14), 4, stroke);
    canvas.drawLine(const Offset(11, 12), const Offset(20, 3), stroke);
    canvas.drawLine(const Offset(16, 5), const Offset(19, 8), stroke);
    canvas.drawLine(const Offset(14, 7), const Offset(17, 10), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsKeyGlyphGlyph old) => old.color != color;
}

class DsSearchGlyphGlyph extends CustomPainter {
  final Color color;
  DsSearchGlyphGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(11, 11), 7, paint);
    canvas.drawLine(const Offset(16.5, 16.5), const Offset(21, 21), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsSearchGlyphGlyph old) => old.color != color;
}

class DsVerifiedSealGlyph extends CustomPainter {
  final Color color;
  final Color onColor;
  DsVerifiedSealGlyph({required this.color, required this.onColor});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final whiteStroke = Paint()
      ..color = onColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(12, 12), 11, fill);
    final tick = Path()
      ..moveTo(8, 12.5)
      ..lineTo(11, 15.5)
      ..lineTo(16.5, 9.5);
    canvas.drawPath(tick, whiteStroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsVerifiedSealGlyph old) => old.color != color || old.onColor != onColor;
}

class DsQrShareGlyphGlyph extends CustomPainter {
  final Color color;
  DsQrShareGlyphGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 3, 7, 7), const Radius.circular(1.5)), stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(14, 3, 7, 7), const Radius.circular(1.5)), stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 14, 7, 7), const Radius.circular(1.5)), stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(14, 14, 3, 3), const Radius.circular(0.5)), stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(17, 17, 4, 4), const Radius.circular(0.5)), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsQrShareGlyphGlyph old) => old.color != color;
}

class DsClockGlyph extends CustomPainter {
  final Color color;
  DsClockGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(12, 13), 8, stroke);
    canvas.drawLine(const Offset(12, 9), const Offset(12, 13), stroke);
    canvas.drawLine(const Offset(12, 13), const Offset(15, 15), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsClockGlyph old) => old.color != color;
}

class DsDoubleCheckGlyph extends CustomPainter {
  final Color color;
  final bool double_;
  DsDoubleCheckGlyph({required this.color, required this.double_});
  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 22;
    final sy = size.height / 14;
    canvas.save();
    canvas.scale(sx, sy);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final c1 = Path()
      ..moveTo(1, 7)
      ..lineTo(5.5, 11.5)
      ..lineTo(13, 4);
    canvas.drawPath(c1, paint);
    if (double_) {
      final c2 = Path()
        ..moveTo(9, 7)
        ..lineTo(13.5, 11.5)
        ..lineTo(21, 4);
      canvas.drawPath(c2, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsDoubleCheckGlyph old) => old.color != color || old.double_ != double_;
}

class DsFileGlyph extends CustomPainter {
  final Color color;
  DsFileGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final outer = Path()
      ..moveTo(14, 3)
      ..lineTo(6.5, 3)
      ..cubicTo(5.67, 3, 5, 3.67, 5, 4.5)
      ..lineTo(5, 19.5)
      ..cubicTo(5, 20.33, 5.67, 21, 6.5, 21)
      ..lineTo(17.5, 21)
      ..cubicTo(18.33, 21, 19, 20.33, 19, 19.5)
      ..lineTo(19, 8)
      ..close();
    canvas.drawPath(outer, stroke);
    final fold = Path()
      ..moveTo(14, 3)
      ..lineTo(14, 8)
      ..lineTo(19, 8);
    canvas.drawPath(fold, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsFileGlyph old) => old.color != color;
}

class DsServerStackGlyph extends CustomPainter {
  final Color color;
  const DsServerStackGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 4, 18, 6), const Radius.circular(1.5)), stroke);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 14, 18, 6), const Radius.circular(1.5)), stroke);
    canvas.drawCircle(const Offset(7, 7), 1.2, fill);
    canvas.drawCircle(const Offset(7, 17), 1.2, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsServerStackGlyph old) => old.color != color;
}

class DsShieldTickGlyph extends CustomPainter {
  final Color color;
  DsShieldTickGlyph({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(12, 3)
      ..lineTo(20, 6)
      ..lineTo(20, 12)
      ..cubicTo(20, 17, 16.5, 20, 12, 21)
      ..cubicTo(7.5, 20, 4, 17, 4, 12)
      ..lineTo(4, 6)
      ..close();
    canvas.drawPath(p, stroke);
    final tick = Path()
      ..moveTo(8.5, 12)
      ..lineTo(11, 14.5)
      ..lineTo(15.5, 10);
    canvas.drawPath(tick, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsShieldTickGlyph old) => old.color != color;
}

class DsChipCheckGlyph extends CustomPainter {
  final Color color;
  DsChipCheckGlyph({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(4, 12)
      ..lineTo(10, 17)
      ..lineTo(20, 6);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsChipCheckGlyph old) => old.color != color;
}

class DsClockMarksGlyph extends CustomPainter {
  final Color color;
  DsClockMarksGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(12, 13), 8, stroke);
    canvas.drawLine(const Offset(12, 9), const Offset(12, 13), stroke);
    canvas.drawLine(const Offset(12, 13), const Offset(15, 15), stroke);
    // Side marks
    canvas.drawLine(const Offset(8, 3), const Offset(6, 6), stroke);
    canvas.drawLine(const Offset(16, 3), const Offset(18, 6), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsClockMarksGlyph old) => old.color != color;
}

/// A thin ×: clear a search field, remove a picked person.
class DsXmarkGlyph extends CustomPainter {
  final Color color;
  DsXmarkGlyph({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 14;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(3.5, 3.5), const Offset(10.5, 10.5), paint);
    canvas.drawLine(const Offset(10.5, 3.5), const Offset(3.5, 10.5), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsXmarkGlyph old) => old.color != color;
}

/// A progress ring: a faint full circle and an arc from 12 o'clock
/// clockwise to [pct] (0..1). Document upload, disappearing countdown,
/// round video messages (recording and playback — ADR-048).
class DsProgressRingPainter extends CustomPainter {
  final double pct;
  final Color trackColor;
  final Color fillColor;
  final double strokeWidth;
  DsProgressRingPainter({required this.pct, required this.trackColor, required this.fillColor, this.strokeWidth = 2});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 1 px in for thin rings (as the two painters this replaced drew),
    // half the stroke for thick ones.
    final radius = size.width / 2 - (strokeWidth > 2 ? strokeWidth / 2 : 1);
    final track = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, track);
    final fill = Paint()
      ..color = fillColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -1.5707963, pct * 6.2831853, false, fill);
  }

  @override
  bool shouldRepaint(DsProgressRingPainter old) =>
      old.pct != pct || old.trackColor != trackColor || old.fillColor != fillColor || old.strokeWidth != strokeWidth;
}
