// Empty states with illustrations — UI backlog §5 item 45. A small
// drawn scene (in theme colours, so it works in dark / OLED and with
// any accent) above a title and one line of guidance, gently floating
// in. Used instead of bare text for "no chats", "no media", "no results".

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/tokens.dart';

enum DsIllustration { chats, media, search, archive }

class DsEmptyState extends StatelessWidget {
  const DsEmptyState({super.key, required this.illustration, required this.title, this.body, this.action});

  final DsIllustration illustration;
  final String title;
  final String? body;

  /// Optional call to action under the text.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: DsMotion.of(context, DsMotion.slow),
      curve: DsMotion.emphasized,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: ValueKey('illustration-${illustration.name}'),
                width: 132,
                height: 104,
                child: CustomPaint(
                  painter: _IllustrationPainter(
                    illustration,
                    accent: tokens.accent,
                    soft: tokens.accentSoft,
                    line: tokens.text3,
                    paper: tokens.surface,
                  ),
                ),
              ),
              const SizedBox(height: DsSpace.x5),
              Text(
                title,
                textAlign: TextAlign.center,
                style: DsText.headline.copyWith(color: tokens.text),
              ),
              if (body != null) ...[
                const SizedBox(height: DsSpace.x2),
                Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: DsText.callout.copyWith(color: tokens.text3),
                ),
              ],
              if (action != null) ...[const SizedBox(height: DsSpace.x5), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class _IllustrationPainter extends CustomPainter {
  _IllustrationPainter(this.kind, {required this.accent, required this.soft, required this.line, required this.paper});

  final DsIllustration kind;
  final Color accent;
  final Color soft;
  final Color line;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 132;
    canvas.scale(s);
    final fillSoft = Paint()..color = soft;
    final fillAccent = Paint()..color = accent;
    final fillPaper = Paint()..color = paper;
    final stroke = Paint()
      ..color = line.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    // Soft blob behind every scene.
    canvas.drawOval(const Rect.fromLTWH(14, 8, 104, 88), fillSoft);

    switch (kind) {
      case DsIllustration.chats:
        final a = RRect.fromRectAndRadius(const Rect.fromLTWH(22, 22, 62, 36), const Radius.circular(18));
        canvas.drawRRect(a, fillPaper);
        canvas.drawRRect(a, stroke);
        for (var i = 0; i < 3; i++) {
          canvas.drawCircle(Offset(40 + i * 13.0, 40), 3, Paint()..color = line.withValues(alpha: 0.6));
        }
        final b = RRect.fromRectAndRadius(const Rect.fromLTWH(52, 54, 58, 32), const Radius.circular(16));
        canvas.drawRRect(b, fillAccent);
        canvas.drawLine(
          const Offset(64, 66),
          const Offset(98, 66),
          Paint()
            ..color = paper
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
        canvas.drawLine(
          const Offset(64, 75),
          const Offset(86, 75),
          Paint()
            ..color = paper.withValues(alpha: 0.7)
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round,
        );
      case DsIllustration.media:
        final back = RRect.fromRectAndRadius(const Rect.fromLTWH(30, 20, 60, 48), const Radius.circular(8));
        canvas.save();
        canvas.translate(60, 44);
        canvas.rotate(-0.12);
        canvas.translate(-60, -44);
        canvas.drawRRect(back, fillPaper);
        canvas.drawRRect(back, stroke);
        canvas.restore();
        final front = RRect.fromRectAndRadius(const Rect.fromLTWH(44, 32, 62, 50), const Radius.circular(8));
        canvas.drawRRect(front, fillPaper);
        canvas.drawRRect(front, stroke);
        canvas.drawCircle(const Offset(60, 48), 6, fillAccent);
        final hill = Path()
          ..moveTo(48, 78)
          ..lineTo(68, 58)
          ..lineTo(80, 70)
          ..lineTo(88, 62)
          ..lineTo(102, 78)
          ..close();
        canvas.drawPath(hill, Paint()..color = accent.withValues(alpha: 0.55));
      case DsIllustration.search:
        canvas.drawCircle(const Offset(60, 48), 24, fillPaper);
        canvas.drawCircle(const Offset(60, 48), 24, stroke..strokeWidth = 4);
        canvas.drawLine(
          const Offset(78, 66),
          const Offset(96, 84),
          Paint()
            ..color = accent
            ..strokeWidth = 8
            ..strokeCap = StrokeCap.round,
        );
        for (final (dx, dy, r) in [(98.0, 26.0, 3.0), (26.0, 70.0, 2.5), (104.0, 50.0, 2.0)]) {
          final star = Paint()..color = accent.withValues(alpha: 0.7);
          canvas.drawCircle(Offset(dx, dy), r, star);
        }
      case DsIllustration.archive:
        final box = RRect.fromRectAndRadius(const Rect.fromLTWH(34, 40, 64, 44), const Radius.circular(8));
        canvas.drawRRect(box, fillPaper);
        canvas.drawRRect(box, stroke);
        final lid = RRect.fromRectAndRadius(const Rect.fromLTWH(30, 28, 72, 14), const Radius.circular(6));
        canvas.drawRRect(lid, fillAccent);
        canvas.drawLine(const Offset(56, 56), const Offset(76, 56), stroke..strokeWidth = 3);
        // A little arc of motion above the lid.
        canvas.drawArc(
          const Rect.fromLTWH(48, 6, 36, 30),
          math.pi * 1.1,
          math.pi * 0.8,
          false,
          stroke..strokeWidth = 2,
        );
    }
  }

  @override
  bool shouldRepaint(_IllustrationPainter old) =>
      old.kind != kind || old.accent != accent || old.soft != soft || old.line != line || old.paper != paper;
}
