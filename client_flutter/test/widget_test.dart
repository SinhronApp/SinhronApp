import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/widgets/ds_avatar.dart';
import 'package:sinhron/widgets/ds_chat_row.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await loadAppFonts();
  });

  group('DsAvatar', () {
    testWidgets('text initials light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(80, 80),
          child: const DsAvatar(name: 'Maria Chen', size: 50),
        ),
      );
      await expectLater(
        find.byType(DsAvatar),
        matchesGoldenFile('goldens/ds_avatar_text_light.png'),
      );
    });

    testWidgets('text initials dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(80, 80),
          child: const DsAvatar(name: 'Maria Chen', size: 50),
        ),
      );
      await expectLater(
        find.byType(DsAvatar),
        matchesGoldenFile('goldens/ds_avatar_text_dark.png'),
      );
    });

    testWidgets('group + online indicator light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(80, 80),
          child: const DsAvatar(
            name: 'Engineering',
            size: 50,
            group: true,
            online: true,
          ),
        ),
      );
      await expectLater(
        find.byType(DsAvatar),
        matchesGoldenFile('goldens/ds_avatar_group_online_light.png'),
      );
    });
  });

  group('DsChatRow', () {
    const unreadChat = ChatPreview(
      name: 'Maria Chen',
      preview: 'Sounds great — see you at 9 tomorrow ☕',
      time: '12:42',
      unread: 2,
      pinned: true,
      online: true,
    );
    const groupChat = ChatPreview(
      name: 'Engineering',
      group: true,
      sender: 'Alex',
      preview: 'pushed the new SFrame implementation',
      time: '12:08',
      unread: 7,
      pinned: true,
    );
    const typingChat = ChatPreview(name: 'Jordan Pierce', preview: 'typing…', typing: true, time: 'now', online: true);
    const mutedReadChat = ChatPreview(name: 'Mom', preview: 'Got it ❤️', time: '10:14', sent: true, read: true);

    testWidgets('unread + online + pinned light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 80),
          child: SizedBox(
            width: 390,
            child: DsChatRow(chat: unreadChat, isLast: true),
          ),
        ),
      );
      await expectLater(
        find.byType(DsChatRow),
        matchesGoldenFile('goldens/ds_chat_row_unread_light.png'),
      );
    });

    testWidgets('group chat with sender light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 80),
          child: SizedBox(
            width: 390,
            child: DsChatRow(chat: groupChat, isLast: true),
          ),
        ),
      );
      await expectLater(
        find.byType(DsChatRow),
        matchesGoldenFile('goldens/ds_chat_row_group_light.png'),
      );
    });

    testWidgets('typing indicator light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 80),
          child: SizedBox(
            width: 390,
            child: DsChatRow(chat: typingChat, isLast: true),
          ),
        ),
      );
      await expectLater(
        find.byType(DsChatRow),
        matchesGoldenFile('goldens/ds_chat_row_typing_light.png'),
      );
    });

    testWidgets('sent + read dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(390, 80),
          child: SizedBox(
            width: 390,
            child: DsChatRow(chat: mutedReadChat, isLast: true),
          ),
        ),
      );
      await expectLater(
        find.byType(DsChatRow),
        matchesGoldenFile('goldens/ds_chat_row_sent_read_dark.png'),
      );
    });
  });

  group('DsTokens semantics', () {
    test('light vs dark are different instances with different bg', () {
      expect(DsTokens.light.bg, isNot(equals(DsTokens.dark.bg)));
      expect(DsTokens.light.accent, isNot(equals(DsTokens.dark.accent)));
    });

    test('radii are theme-invariant', () {
      expect(DsTokens.light.radiusCard, DsTokens.dark.radiusCard);
      expect(DsTokens.light.radiusPill, DsTokens.dark.radiusPill);
    });
  });
}
