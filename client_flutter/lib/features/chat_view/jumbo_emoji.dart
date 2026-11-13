// A message of only 1–3 emoji ("🤣", "❤️🔥") is shown big, without a bubble —
// like Telegram, WhatsApp and Signal (owner, 2026-10-18: one emoji in a
// white bubble looked like a prototype).

import 'package:flutter/widgets.dart' show StringCharacters;

final _pictograph = RegExp(r'\p{Extended_Pictographic}|\p{Regional_Indicator}', unicode: true);
final _word = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// How many emoji [text] is made of, if only emoji (spaces aside) and at
/// most three; else 0.
int jumboEmojiCount(String text) {
  final t = text.trim();
  if (t.isEmpty || t.length > 48) return 0;
  final glyphs = [for (final c in t.characters) if (c.trim().isNotEmpty) c];
  if (glyphs.isEmpty || glyphs.length > 3) return 0;
  for (final g in glyphs) {
    if (!_pictograph.hasMatch(g) || _word.hasMatch(g)) return 0;
  }
  return glyphs.length;
}

/// Font size for [count] big emoji.
double jumboEmojiSize(int count) => switch (count) {
  1 => 56,
  2 => 46,
  _ => 40,
};
