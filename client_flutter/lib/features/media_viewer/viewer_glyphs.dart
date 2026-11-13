// Line glyphs of the full-screen media viewer chrome (24-unit grid,
// white on black): the action row and the video controls. One painter for
// both viewers (media_viewer_screen.dart, photo_gallery_screen.dart).

import 'package:flutter/widgets.dart';

enum ViewerGlyph { share, save, forward, trash, showInChat, play, pause, soundOn, soundOff }

class ViewerGlyphIcon extends StatelessWidget {
  const ViewerGlyphIcon(this.glyph, {super.key, required this.color, this.size = 26});

  final ViewerGlyph glyph;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: ViewerGlyphPainter(glyph: glyph, color: color)),
  );
}

class ViewerGlyphPainter extends CustomPainter {
  final ViewerGlyph glyph;
  final Color color;
  ViewerGlyphPainter({required this.glyph, required this.color});

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
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    switch (glyph) {
      case ViewerGlyph.share:
        // iOS-style box-with-up-arrow
        final box = Path()
          ..moveTo(7, 10)
          ..lineTo(5, 10)
          ..lineTo(5, 20)
          ..lineTo(19, 20)
          ..lineTo(19, 10)
          ..lineTo(17, 10);
        canvas.drawPath(box, stroke);
        canvas.drawLine(const Offset(12, 3), const Offset(12, 15), stroke);
        final arrowHead = Path()
          ..moveTo(8, 7)
          ..lineTo(12, 3)
          ..lineTo(16, 7);
        canvas.drawPath(arrowHead, stroke);
      case ViewerGlyph.save:
        final p = Path()
          ..moveTo(12, 4)
          ..lineTo(12, 16);
        canvas.drawPath(p, stroke);
        final arrow = Path()
          ..moveTo(7, 11)
          ..lineTo(12, 16)
          ..lineTo(17, 11);
        canvas.drawPath(arrow, stroke);
        canvas.drawLine(const Offset(5, 20), const Offset(19, 20), stroke);
      case ViewerGlyph.forward:
        final p = Path()
          ..moveTo(15, 8)
          ..lineTo(20, 12)
          ..lineTo(15, 16);
        canvas.drawPath(p, stroke);
        final tail = Path()
          ..moveTo(20, 12)
          ..lineTo(8, 12)
          ..cubicTo(5, 12, 4, 14, 4, 17);
        canvas.drawPath(tail, stroke);
      case ViewerGlyph.trash:
        canvas.drawLine(const Offset(3, 6), const Offset(21, 6), stroke);
        final bin = Path()
          ..moveTo(5, 6)
          ..lineTo(6, 20)
          ..cubicTo(6, 20.5, 6.5, 21, 7, 21)
          ..lineTo(17, 21)
          ..cubicTo(17.5, 21, 18, 20.5, 18, 20)
          ..lineTo(19, 6);
        canvas.drawPath(bin, stroke);
        final handle = Path()
          ..moveTo(9, 6)
          ..lineTo(9, 4)
          ..lineTo(15, 4)
          ..lineTo(15, 6);
        canvas.drawPath(handle, stroke);
        canvas.drawLine(const Offset(10, 10), const Offset(10, 17), stroke);
        canvas.drawLine(const Offset(14, 10), const Offset(14, 17), stroke);
      case ViewerGlyph.showInChat:
        // Speech bubble with two text lines.
        final bubble = Path()
          ..moveTo(6, 4)
          ..lineTo(18, 4)
          ..cubicTo(19.7, 4, 21, 5.3, 21, 7)
          ..lineTo(21, 14)
          ..cubicTo(21, 15.7, 19.7, 17, 18, 17)
          ..lineTo(11, 17)
          ..lineTo(7, 20.5)
          ..lineTo(7, 17)
          ..lineTo(6, 17)
          ..cubicTo(4.3, 17, 3, 15.7, 3, 14)
          ..lineTo(3, 7)
          ..cubicTo(3, 5.3, 4.3, 4, 6, 4)
          ..close();
        canvas.drawPath(bubble, stroke);
        canvas.drawLine(const Offset(7.5, 9), const Offset(16.5, 9), stroke);
        canvas.drawLine(const Offset(7.5, 12.5), const Offset(13, 12.5), stroke);
      case ViewerGlyph.play:
        final tri = Path()
          ..moveTo(7, 4.5)
          ..lineTo(19.5, 12)
          ..lineTo(7, 19.5)
          ..close();
        canvas.drawPath(tri, fill);
      case ViewerGlyph.pause:
        canvas.drawRRect(RRect.fromLTRBR(6, 4.5, 10, 19.5, const Radius.circular(1)), fill);
        canvas.drawRRect(RRect.fromLTRBR(14, 4.5, 18, 19.5, const Radius.circular(1)), fill);
      case ViewerGlyph.soundOn:
      case ViewerGlyph.soundOff:
        final speaker = Path()
          ..moveTo(3, 9.5)
          ..lineTo(7, 9.5)
          ..lineTo(12, 5)
          ..lineTo(12, 19)
          ..lineTo(7, 14.5)
          ..lineTo(3, 14.5)
          ..close();
        canvas.drawPath(speaker, fill);
        if (glyph == ViewerGlyph.soundOn) {
          canvas.drawArc(Rect.fromCircle(center: const Offset(12, 12), radius: 4.5), -0.9, 1.8, false, stroke);
          canvas.drawArc(Rect.fromCircle(center: const Offset(12, 12), radius: 8), -0.9, 1.8, false, stroke);
        } else {
          canvas.drawLine(const Offset(15.5, 9), const Offset(21, 15), stroke);
          canvas.drawLine(const Offset(21, 9), const Offset(15.5, 15), stroke);
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ViewerGlyphPainter old) => old.glyph != glyph || old.color != color;
}
