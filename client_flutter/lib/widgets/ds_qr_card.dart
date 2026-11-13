// Signal-style QR card (owner, 2026-10-20: "окно с QR некрасивое"): the code
// on a white rounded tile inside a card in the accent colour, with a line
// or two under it in the accent's text colour. The tile stays white in
// every theme — scanners need dark modules on light.

import 'package:flutter/widgets.dart';

import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';

class DsQrCard extends StatelessWidget {
  const DsQrCard({super.key, required this.code, this.title, this.subtitle, this.titleMono = true, this.size = 216});

  /// The matrix, painted edge to edge in a [size] square.
  final Widget code;

  /// Under the tile: the address / handle ([titleMono]) and a hint.
  final String? title;
  final String? subtitle;
  final bool titleMono;
  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final on = tokens.accentText;
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x7, DsSpace.x6, DsSpace.x6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [tokens.accent, Color.lerp(tokens.accent, DsPalette.black, 0.18)!],
        ),
        boxShadow: [DsShadow.glowOf(tokens.accent, alpha: 0.2, y: 8, blur: 24)],
      ),
      child: Column(
        children: [
          Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(DsSpace.x3h5),
            decoration: BoxDecoration(color: DsPalette.white, borderRadius: BorderRadius.circular(22)),
            child: code,
          ),
          if (title != null) ...[
            const SizedBox(height: DsSpace.x5),
            Text(
              title!,
              textAlign: TextAlign.center,
              style: (titleMono ? DsTextArt.t14w500Mono : DsText.headline).copyWith(
                fontWeight: FontWeight.w600,
                color: on,
              ),
            ),
          ],
          if (subtitle != null) ...[
            const SizedBox(height: DsSpace.x1),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: DsText.footnote.copyWith(color: on.withValues(alpha: 0.78)),
            ),
          ],
        ],
      ),
    );
  }
}
