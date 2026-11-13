// 24-word BIP-39 mnemonic grid. 2 columns, monospace numbering, blur-until-tap.
//
// Per spec §6.8 the recovery phrase is shown exactly once. The grid starts
// blurred by default (anti-shoulder-surfing) and reveals on tap; consumer
// screens can override starting state via [initiallyRevealed].
//
// Per README cross-cutting #1, the blur is "best-effort": we can't stop a
// screenshot, but we can stop the casual eyes-from-across-the-room read.

import 'dart:ui';

import 'package:flutter/widgets.dart';

import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import '../l10n/l10n.dart';

/// Controlled-state mnemonic grid. Parent owns [revealed] and decides what
/// to do on tap (typically: setState revealed = true, never back to false).
/// Tap behavior matches the security model: reveal-once, no "tap to hide"
/// since most users find that flow surprising.
class DsMnemonicGrid extends StatelessWidget {
  final List<String> words;
  final bool revealed;
  final VoidCallback? onTap;

  const DsMnemonicGrid({super.key, required this.words, required this.revealed, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);

    final grid = LayoutBuilder(
      builder: (context, constraints) {
        const cols = 2;
        const gap = 8.0;
        final cellWidth = (constraints.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < words.length; i++)
              SizedBox(
                width: cellWidth,
                child: _MnemonicCell(index: i + 1, word: words[i], tokens: tokens),
              ),
          ],
        );
      },
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: revealed ? null : onTap,
      child: Stack(
        children: [
          grid,
          if (!revealed) ...[
            // Blur overlay (BackdropFilter blurs everything beneath it)
            Positioned.fill(
              child: ClipRect(
                child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6), child: const SizedBox.shrink()),
              ),
            ),
            // "Tap to reveal" pill, centered
            const Positioned.fill(child: Center(child: _RevealPill())),
          ],
        ],
      ),
    );
  }
}

class _MnemonicCell extends StatelessWidget {
  final int index;
  final String word;
  final DsTokens tokens;
  const _MnemonicCell({required this.index, required this.word, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.x2h5),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tokens.dividerStrong, width: 0.5),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              index.toString().padLeft(2, '0'),
              textAlign: TextAlign.right,
              style: DsTextArt.t11w600Monov3.copyWith(color: tokens.text4),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              word,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsTextArt.t14w500Monov5.copyWith(color: tokens.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _RevealPill extends StatelessWidget {
  const _RevealPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
      decoration: BoxDecoration(
        color: DsPalette.art0F1720aB8, // rgba(15,23,32,0.72)
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _EyeIcon(),
          const SizedBox(width: 8),
          // Was English on the Russian screen (2026-10-16 UI audit).
          Text(context.l10n.tapToReveal, style: DsTextArt.t12p5w600v3),
        ],
      ),
    );
  }
}

class _EyeIcon extends StatelessWidget {
  const _EyeIcon();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 14, height: 14, child: CustomPaint(painter: _EyePainter(DsPalette.white)));
  }
}

class _EyePainter extends CustomPainter {
  final Color color;
  const _EyePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Almond eye outline — two quadratic curves meeting at sides
    final p = Path()
      ..moveTo(2, 12)
      ..quadraticBezierTo(12, 3, 22, 12)
      ..quadraticBezierTo(12, 21, 2, 12)
      ..close();
    canvas.drawPath(p, stroke);
    canvas.drawCircle(const Offset(12, 12), 3, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EyePainter old) => old.color != color;
}
