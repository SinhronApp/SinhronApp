// Design-system ratchet — UI backlog §5 items 39-40. Counts what still
// bypasses the tokens. Numbers may only go DOWN: when you migrate more,
// lower the ceiling in the same commit (and log it in docs/status.md).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Ceilings as of 2026-10-13. Before block 4: 678 TextStyle literals,
/// 840 colour literals, 110 shadows, 242 painters; after block 4: 176 /
/// 149 / 103 / 177; tech-debt 2.26 pass: shadow tokens (card, hairline,
/// lift, soft, successGlow) and 10 more named palette tints; final 2.26
/// pass: every value moved into the theme unchanged (DsTextArt,
/// DsPalette.art*, DsShadow.art* / glowOf / ring / faded), byte-identical
/// painters merged (ds_shared_glyphs.dart; compared with comments and
/// whitespace stripped). The 158 painters left each draw different
/// coordinates — distinct glyphs, not repeats. 2026-10-26: the design
/// gallery's mock screens went, and their painters with them (157 → 80).
const ceilings = {
  'hand-sized TextStyle': 0,
  'Color(0x…) literal': 0,
  'BoxShadow literal': 0,
  'CustomPainter class': 80,
  // Every EdgeInsets number goes through DsSpace (odd optical nudges are
  // DsSpace.nudgeN — same values as before).
  'EdgeInsets bare number': 0,
};

void main() {
  test('design tokens: nothing new bypasses the scale', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.contains('/src/rust/'))
        .where((f) => !f.path.contains('lib/app/theme/')); // token / palette / theme definitions
    var styles = 0, colors = 0, shadows = 0, painters = 0, spacing = 0;
    for (final f in files) {
      final s = f.readAsStringSync();
      styles += RegExp(r'TextStyle\([^)]*fontSize:\s*[0-9]').allMatches(s).length;
      colors += RegExp(r'Color\(0x').allMatches(s).length;
      shadows += RegExp(r'BoxShadow\(').allMatches(s).length;
      painters += RegExp(r'extends CustomPainter').allMatches(s).length;
      for (final m in RegExp(r'EdgeInsets\.(?:all|only|symmetric|fromLTRB)\(([^)]*)\)').allMatches(s)) {
        spacing += RegExp(r'(?<![\w.])([1-9]\d*)(?:\.0)?(?![\w.])').allMatches(m.group(1)!).length;
      }
    }
    final now = {
      'hand-sized TextStyle': styles,
      'Color(0x…) literal': colors,
      'BoxShadow literal': shadows,
      'CustomPainter class': painters,
      'EdgeInsets bare number': spacing,
    };
    // ignore: avoid_print
    print('design debt: $now');
    for (final k in ceilings.keys) {
      expect(now[k], lessThanOrEqualTo(ceilings[k]!), reason: '$k grew — use DsText / DsPalette / DsShadow / DsIcon');
    }
  });
}
