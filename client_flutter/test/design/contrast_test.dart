// WCAG AA — UI backlog §7 item 56. Reading text must reach 4.5:1 on every
// surface it sits on, in every theme; white text on every accent too.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/appearance.dart';
import 'package:sinhron/app/theme/tokens.dart';

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final (x, y) = (_lum(a), _lum(b));
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  for (final (name, t) in [('light', DsTokens.light), ('dark', DsTokens.dark), ('oled', oledTokens)]) {
    test('$name: text, secondary text, links and errors reach AA', () {
      for (final (role, fg) in [
        ('text', t.text),
        ('text2', t.text2),
        ('text3', t.text3),
        ('accent', t.accent),
        ('danger', t.danger),
        ('success', t.success),
      ]) {
        for (final (surf, bg) in [('bg', t.bg), ('bgSoft', t.bgSoft), ('surface', t.surface)]) {
          expect(contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '$name $role on $surf');
        }
      }
    });
  }

  test('white text on every accent (buttons, my bubbles)', () {
    const white = Color(0xFFFFFFFF);
    expect(contrast(white, DsTokens.light.accent), greaterThanOrEqualTo(4.5));
    for (final e in kAccents.entries) {
      expect(contrast(white, e.value), greaterThanOrEqualTo(4.5), reason: e.key);
    }
  });
}
