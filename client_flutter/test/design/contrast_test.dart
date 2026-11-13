// WCAG AA — UI backlog §7 item 56. Reading text must reach 4.5:1 on every
// surface it sits on, in every theme; white text on every accent too.

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/appearance.dart';
import 'package:sinhron/app/theme/palette.dart';
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

  // Avatar tints: initials on their fill; and, as a sender's name in a
  // group, on the incoming bubble and the chat background.
  for (final (name, tints, themes) in [
    ('light', kAvatarTints, [DsTokens.light]),
    ('dark', kAvatarTintsDark, [DsTokens.dark, oledTokens]),
  ]) {
    test('$name: avatar initials and group sender names reach AA', () {
      expect(kAvatarTints.length, kAvatarTintsDark.length);
      for (final (i, (fill, fg)) in tints.indexed) {
        expect(contrast(fg, fill), greaterThanOrEqualTo(4.5), reason: '$name tint $i: initials');
        for (final t in themes) {
          expect(contrast(fg, t.bubbleIn), greaterThanOrEqualTo(4.5), reason: '$name tint $i: name in a bubble');
          expect(contrast(fg, t.bg), greaterThanOrEqualTo(4.5), reason: '$name tint $i: name over a photo');
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

  // The calm look: dark themes put dark text on a light accent; my
  // bubble is the accent itself under white text, in every theme.
  for (final (name, base, dark) in [
    ('light', DsTokens.light, false),
    ('dark', DsTokens.dark, true),
    ('oled', oledTokens, true),
  ]) {
    test('$name: marks on the accent and text in the bubbles, every accent', () {
      for (final accent in kAccents.keys) {
        final t = withAccent(base, accent, dark: dark);
        expect(contrast(t.accentText, t.accent), greaterThanOrEqualTo(4.5), reason: '$name $accent: on the accent');
        expect(t.bubbleOutText, const Color(0xFFFFFFFF), reason: '$name $accent: my text is white');
        expect(contrast(t.bubbleOutText, t.bubbleOut), greaterThanOrEqualTo(4.5), reason: '$name $accent: my text');
        expect(contrast(t.bubbleOutMeta, t.bubbleOut), greaterThanOrEqualTo(4.5), reason: '$name $accent: my time');
        expect(contrast(t.text, t.bubbleIn), greaterThanOrEqualTo(4.5), reason: '$name: their text');
        expect(contrast(t.text3, t.bubbleIn), greaterThanOrEqualTo(4.5), reason: '$name: their time');
      }
    });
  }
}
