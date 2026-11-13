// Signal-style action button: a flat rounded tile with a bold icon over a
// short label — Message / Call / Video on a contact, Share / Copy on my
// profile (owner, 2026-10-20: "иконки слишком маленькие и тонкие"). Presses
// in a touch (DsPressable); disabled fades.

import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/tokens.dart';
import 'ds_pressable.dart';

enum DsActionGlyph { share, copy, save }

/// The icon size and stroke the action tiles draw at.
const double kActionIconSize = 26;
const double kActionIconStroke = 2.1;

class DsActionButton extends StatelessWidget {
  const DsActionButton({super.key, required this.label, required this.icon, this.onTap, this.color});

  final String label;

  /// A [kActionIconSize] square glyph, drawn at [kActionIconStroke].
  final Widget icon;
  final VoidCallback? onTap;

  /// Tile colour; [DsTokens.surface] when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: DsPressable(
        onTap: onTap,
        scale: 0.95,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.4,
          duration: DsMotion.fast,
          child: Container(
            padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x3h5, DsSpace.x1, DsSpace.x3),
            decoration: BoxDecoration(color: color ?? tokens.surface, borderRadius: BorderRadius.circular(16)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: kActionIconSize, height: kActionIconSize, child: icon),
                const SizedBox(height: DsSpace.x1h5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [children] as an even row with [DsSpace.x2h5] between them.
class DsActionRow extends StatelessWidget {
  const DsActionRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final (i, c) in children.indexed) ...[
          if (i > 0) const SizedBox(width: DsSpace.x2h5),
          Expanded(child: c),
        ],
      ],
    );
  }
}

/// Share / copy / save, on the 24 grid (were the QR screen's own).
class DsActionGlyphPainter extends CustomPainter {
  DsActionGlyphPainter(this.shape, {required this.color, this.strokeWidth = 1.8});
  final DsActionGlyph shape;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (shape) {
      case DsActionGlyph.share:
        canvas.drawCircle(const Offset(6, 12), 3, stroke);
        canvas.drawCircle(const Offset(18, 6), 3, stroke);
        canvas.drawCircle(const Offset(18, 18), 3, stroke);
        canvas.drawLine(const Offset(8.6, 10.5), const Offset(15.4, 7.5), stroke);
        canvas.drawLine(const Offset(8.6, 13.5), const Offset(15.4, 16.5), stroke);
      case DsActionGlyph.copy:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(8, 8, 12, 12), const Radius.circular(2)), stroke);
        final p = Path()
          ..moveTo(16, 8)
          ..lineTo(16, 5)
          ..arcToPoint(const Offset(13, 4), radius: const Radius.circular(2))
          ..lineTo(5, 4)
          ..arcToPoint(const Offset(4, 5), radius: const Radius.circular(2))
          ..lineTo(4, 13)
          ..arcToPoint(const Offset(5, 16), radius: const Radius.circular(2))
          ..lineTo(8, 16);
        canvas.drawPath(p, stroke);
      case DsActionGlyph.save:
        // Download-arrow into tray
        canvas.drawLine(const Offset(12, 4), const Offset(12, 15), stroke);
        final arrow = Path()
          ..moveTo(7, 10)
          ..lineTo(12, 15)
          ..lineTo(17, 10);
        canvas.drawPath(arrow, stroke);
        final tray = Path()
          ..moveTo(4, 17)
          ..lineTo(4, 19)
          ..arcToPoint(const Offset(6, 21), radius: const Radius.circular(2))
          ..lineTo(18, 21)
          ..arcToPoint(const Offset(20, 19), radius: const Radius.circular(2))
          ..lineTo(20, 17);
        canvas.drawPath(tray, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(DsActionGlyphPainter old) =>
      old.shape != shape || old.color != color || old.strokeWidth != strokeWidth;
}
