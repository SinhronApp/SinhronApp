// Owner, 2026-10-16: "the smileys tab has a couple of emoji and they don't
// even tap". The panel: emoji at the cursor, whole-emoji delete, recents,
// and in the chat — a tap types, the panel stays, the field brings the
// keyboard back.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/chat_view/emoji_data.dart';
import 'package:sinhron/features/chat_view/emoji_panel.dart';

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/chat_messages_test.dart' show FakeHistory;
import '../../core/settings_providers_test.dart' show MemoryStore;

void main() {
  test('an emoji goes in at the cursor; delete takes the whole emoji', () {
    var v = const TextEditingValue(text: 'hi there', selection: TextSelection.collapsed(offset: 2));
    v = insertEmoji(v, '👋');
    expect(v.text, 'hi👋 there');
    expect(v.selection.baseOffset, 2 + '👋'.length);
    v = insertEmoji(v, '🇷🇺');
    v = insertEmoji(v, '👨‍👩‍👧');
    expect(v.text, 'hi👋🇷🇺👨‍👩‍👧 there');
    v = deleteBackward(v);
    expect(v.text, 'hi👋🇷🇺 there', reason: 'a family is one character');
    v = deleteBackward(v);
    expect(v.text, 'hi👋 there', reason: 'a flag is one character');
    // A selection is replaced / deleted as a whole.
    v = const TextEditingValue(text: 'abc', selection: TextSelection(baseOffset: 0, extentOffset: 3));
    expect(insertEmoji(v, '🔥').text, '🔥');
    expect(deleteBackward(v).text, '');
    // No selection yet (a fresh field): at the end.
    expect(insertEmoji(const TextEditingValue(text: 'ok'), '👍').text, 'ok👍');
    expect(deleteBackward(const TextEditingValue(text: '', selection: TextSelection.collapsed(offset: 0))).text, '');
  });

  test('recents: newest first, no repeats, at most 32', () {
    expect(withRecentEmoji('', '😀'), '😀');
    expect(withRecentEmoji('😀 🔥', '🔥'), '🔥 😀');
    var s = '';
    for (final e in emojiOf(EmojiCategory.food).take(40)) {
      s = withRecentEmoji(s, e);
    }
    expect(s.split(' '), hasLength(kRecentEmojiMax));
  });

  test('every category has emoji and nothing is split', () {
    for (final c in EmojiCategory.values) {
      final list = emojiOf(c);
      expect(list.length, greaterThan(20), reason: c.name);
      for (final e in list) {
        expect(e.characters.length, 1, reason: '${c.name}: "$e" is one character');
      }
    }
    expect(EmojiCategory.values.map(emojiOf).fold<int>(0, (n, l) => n + l.length), greaterThan(1000));
  });

  testWidgets('in the chat: a tap types the emoji, the panel stays, ⌫ deletes, the field brings the keyboard back', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final c = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(FakeChatStore()),
        messagePageFetcherProvider.overrideWithValue(FakeHistory(1).fetch),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        chatsProvider.overrideWith((ref) async => const [ChatPreview(id: 'c1', name: 'Maria', preview: '', time: '')]),
      ],
    );
    addTearDown(c.dispose);
    await c.read(chatsProvider.future);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: const MediaQuery(
            data: MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ChatViewScreen(chatId: 'c1', contactName: 'Maria'),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('composer-emoji')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-panel')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('emoji-smileys-0')));
    await t.tap(find.byKey(const ValueKey('emoji-smileys-1')));
    await t.pumpAndSettle();
    // The composer's field (the panel has its own search field too).
    final composer = find.byType(EditableText).first;
    final field = t.widget<EditableText>(composer);
    expect(field.controller.text, '😀😃');
    expect(find.byKey(const ValueKey('emoji-panel')), findsOneWidget, reason: 'stays open while picking');
    await t.tap(find.byKey(const ValueKey('emoji-backspace')));
    await t.pump();
    expect(field.controller.text, '😀');
    // Recents remember what was picked.
    expect(c.read(recentEmojiProvider).value, '😃 😀');
    // A tap on the field: keyboard back, panel gone.
    await t.tap(composer);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-panel')), findsNothing);
  });
}
