// Owner, 2026-10-18 — one emoji in a white bubble looked like a prototype:
// 1–3 emoji alone are shown big, without a bubble (Telegram / Signal).

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_view/jumbo_emoji.dart';

void main() {
  test('only 1–3 emoji, spaces aside, count as big', () {
    expect(jumboEmojiCount('🤣'), 1);
    expect(jumboEmojiCount(' 👍 '), 1);
    expect(jumboEmojiCount('❤️🔥'), 2);
    expect(jumboEmojiCount('🤣 🤣 🤣'), 3);
    expect(jumboEmojiCount('👨‍👩‍👧‍👦'), 1, reason: 'a family is one glyph');
    expect(jumboEmojiCount('🇷🇺'), 1, reason: 'a flag is one glyph');
    expect(jumboEmojiCount('👍🏽'), 1, reason: 'with a skin tone');
  });

  test('anything else stays a normal bubble', () {
    expect(jumboEmojiCount('🤣🤣🤣🤣'), 0, reason: 'four is a line of text');
    expect(jumboEmojiCount('ok 👍'), 0);
    expect(jumboEmojiCount('1️⃣'), 0, reason: 'a keycap is a digit');
    expect(jumboEmojiCount(''), 0);
    expect(jumboEmojiCount('?'), 0);
    expect(jumboEmojiSize(1), greaterThan(jumboEmojiSize(3)));
  });
}
