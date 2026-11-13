// Sinhron brand glyph — "two-arcs-in-sync".
//
// Composition (per design/app/entry.jsx SinhronMark, 56×56 viewBox):
//   - Left ring at (22, 28) r=14, accent stroke 3px, transparent fill
//   - Right disk at (34, 28) r=14, accent fill + accent stroke 3px
//   - White (bg-colored) half-arc from (22, 14) curving to (22, 42), stroke 3px
//     This is the "sync" line that bisects the two circles, suggesting the
//     left empty ring is "becoming" the right filled disk.
//
// Reused across: onboarding splash setup-up state, biometric prompt, lockscreen.

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';

class SinhronMark extends StatelessWidget {
  final double size;
  const SinhronMark({super.key, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SinhronMarkPainter(accent: tokens.accent, bg: tokens.bg),
      ),
    );
  }
}

class _SinhronMarkPainter extends CustomPainter {
  final Color accent;
  final Color bg;

  _SinhronMarkPainter({required this.accent, required this.bg});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 56;
    canvas.save();
    canvas.scale(scale);

    final accentStroke = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final accentFill = Paint()
      ..color = accent
      ..style = PaintingStyle.fill;

    final bgStroke = Paint()
      ..color = bg
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Left ring (empty)
    canvas.drawCircle(const Offset(22, 28), 14, accentStroke);
    // Right disk (filled + stroked — stroke is no-op visually but matches SVG)
    canvas.drawCircle(const Offset(34, 28), 14, accentFill);
    canvas.drawCircle(const Offset(34, 28), 14, accentStroke);

    // Sync arc — half-circle from (22, 14) to (22, 42) curving right
    final arc = Path()
      ..moveTo(22, 14)
      ..arcToPoint(const Offset(22, 42), radius: const Radius.circular(14));
    canvas.drawPath(arc, bgStroke);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_SinhronMarkPainter old) =>
      old.accent != accent || old.bg != bg;
}
