// The one "verified" mark (owner, 2026-10-18: "the check is different and
// not everywhere — and a green ✓ character? that's the 2000s"). An accent
// seal with a white tick, drawn — next to a name wherever a person you
// checked appears: chat list, chat header, chat info, contacts, new group.

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import 'ds_shared_glyphs.dart';

class DsVerifiedBadge extends StatelessWidget {
  /// Diameter. ~0.85× the cap height of the name next to it reads best.
  final double size;

  /// For VoiceOver ("Verified"); the name's own label says who.
  final String? semanticLabel;

  const DsVerifiedBadge({super.key, this.size = 14, this.semanticLabel});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final seal = SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: DsVerifiedSealGlyph(color: tokens.accent, onColor: tokens.accentText)),
    );
    return semanticLabel == null ? ExcludeSemantics(child: seal) : Semantics(label: semanticLabel, child: seal);
  }
}
