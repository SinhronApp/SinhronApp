import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/features/search/search_overlay_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/chat_messages_test.dart' show FakeHistory;
import '../../core/settings_providers_test.dart' show MemoryStore;
import '../../core/people_test.dart' show FakePeopleStore;
import 'folders_test.dart' show chat;

final chats = [
  chat('alice', unread: 2),
  chat('bob'),
  chat('team', group: true, unread: 1),
  chat('old', archived: true),
];

Widget host(Widget child, List overrides, {MemoryStore? settings, List<ChatPreview>? list}) => ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings ?? MemoryStore()),
        chatsProvider.overrideWith((ref) async => list ?? chats),
        messagePageFetcherProvider.overrideWithValue(FakeHistory(3).fetch),
        ...overrides,
      ],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            // Navigator: sheets are routes.
            child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
          ),
        ),
      ),
    );

void phone(WidgetTester t) {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

bool visible(String name) => find.text(name).hitTestable().evaluate().isNotEmpty;

void main() {
  testWidgets('folder tabs filter the list; swipe pages; archive row only in All', (t) async {
    phone(t);
    var openedArchive = false;
    await t.pumpWidget(host(ChatListScreen(onOpenArchive: () => openedArchive = true), []));
    await t.pumpAndSettle();

    expect(visible('alice'), isTrue);
    expect(visible('team'), isTrue);
    expect(visible('old'), isFalse, reason: 'archived chats live in the archive');
    expect(find.byKey(const ValueKey('archive-row')), findsOneWidget);

    await t.tap(find.text('Groups'));
    await t.pumpAndSettle();
    expect(visible('team'), isTrue);
    expect(visible('alice'), isFalse);
    expect(find.byKey(const ValueKey('archive-row')).hitTestable(), findsNothing);

    // Swipe left → next folder (Unread).
    await t.fling(find.byKey(const ValueKey('folder-pages')), const Offset(-300, 0), 1200);
    await t.pumpAndSettle();
    expect(visible('alice'), isTrue);
    expect(visible('team'), isTrue);
    expect(visible('bob'), isFalse, reason: 'bob has nothing unread');

    await t.ensureVisible(find.text('All'));
    await t.pumpAndSettle();
    await t.tap(find.text('All'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('archive-row')));
    expect(openedArchive, isTrue);
  });

  testWidgets('someone typing shows in their row, over the preview', (t) async {
    phone(t);
    await t.pumpWidget(host(const ChatListScreen(), []));
    await t.pumpAndSettle();
    final c = ProviderScope.containerOf(t.element(find.byType(ChatListScreen)));
    expect(find.text('typing…'), findsNothing);
    c.read(typingChatsProvider.notifier).set('bob', true);
    await t.pump();
    expect(find.text('typing…'), findsOneWidget);
    c.read(typingChatsProvider.notifier).set('bob', false);
    await t.pump();
    expect(find.text('typing…'), findsNothing);
  });

  testWidgets('mentions in a preview show as names', (t) async {
    phone(t);
    final anya = 'a1' * 32;
    final list = [ChatPreview(id: 'g', name: 'Team', group: true, preview: 'ping @[$anya]', time: '', mention: true)];
    await t.pumpWidget(host(
      const ChatListScreen(),
      [peopleStoreProvider.overrideWithValue(FakePeopleStore()..names_[anya] = 'Аня')],
      list: list,
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('ping @Аня', findRichText: true), findsOneWidget);
    expect(find.textContaining('@[', findRichText: true), findsNothing, reason: 'no raw tokens');
  });

  testWidgets('a message request is marked in its row', (t) async {
    phone(t);
    final list = [
      const ChatPreview(id: 'new', name: 'Stranger', preview: 'hello', time: '', request: true),
      chat('bob'),
    ];
    await t.pumpWidget(host(const ChatListScreen(), [], list: list));
    await t.pumpAndSettle();
    expect(find.textContaining('Message request · ', findRichText: true), findsOneWidget);
  });

  test('list ticks follow my newest message: none, ✓, ✓✓, read', () {
    core.StoredChatSummary s(bool mine, int status) => core.StoredChatSummary(
      id: 'x',
      displayName: 'X',
      isGroup: false,
      muted: false,
      pinned: false,
      unreadCount: 0,
      lastMsgTsUnix: 0,
      lastMsgKind: 'text',
      lastMsgMine: mine,
      createdAtUnix: 0,
      archived: false,
      pinOrder: 0,
      markedUnread: false,
      disappearSecs: 0,
      lastMsgStatus: status,
      request: false,
      mentioned: false,
    );
    (bool, bool, bool) ticks(core.StoredChatSummary x) {
      final p = chatPreviewFromStored(x);
      return (p.sent, p.delivered, p.read);
    }

    expect(ticks(s(false, 0)), (false, false, false), reason: 'their message');
    expect(ticks(s(true, 0)), (false, false, false), reason: 'still sending');
    expect(ticks(s(true, 1)), (true, false, false));
    expect(ticks(s(true, 2)), (true, true, false));
    expect(ticks(s(true, 3)), (true, true, true));
  });

  testWidgets('long list: the archive row waits above the top until pulled down', (t) async {
    phone(t);
    final many = [for (var i = 0; i < 20; i++) chat('c$i'), chat('old', archived: true)];
    await t.pumpWidget(host(const ChatListScreen(), [], list: many));
    await t.pumpAndSettle();
    final row = find.byKey(const ValueKey('archive-row'), skipOffstage: false);
    expect(t.getSize(row).height, 76.5, reason: '_kArchiveRowHeight matches the row');
    expect(row.hitTestable(), findsNothing, reason: 'tucked above the list');
    expect(visible('c0'), isTrue, reason: 'the list starts at the first chat');

    await t.drag(find.text('c0'), const Offset(0, 90));
    await t.pumpAndSettle();
    expect(row.hitTestable(), findsOneWidget, reason: 'a pull down reveals it');
  });

  testWidgets('custom folder appears as a tab with its unread count', (t) async {
    phone(t);
    final store = MemoryStore()
      ..map['chat_folders'] = '[{"id":"f1","name":"Close","emoji":"❤️","include":["alice","bob"]}]';
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    expect(find.textContaining('❤️ Close'), findsOneWidget);
    await t.ensureVisible(find.textContaining('❤️ Close'));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('❤️ Close'));
    await t.pumpAndSettle();
    expect(visible('alice'), isTrue);
    expect(visible('bob'), isTrue);
    expect(visible('team'), isFalse);
  });

  testWidgets('long-press peek shows recent messages and runs actions', (t) async {
    phone(t);
    final store = FakeChatStore();
    await t.pumpWidget(host(const ChatListScreen(), [chatStoreProvider.overrideWithValue(store)]));
    await t.pumpAndSettle();

    await t.longPress(find.text('alice'));
    await t.pumpAndSettle();
    expect(find.textContaining('message 2', findRichText: true), findsOneWidget, reason: 'peek preview');
    await t.tap(find.byKey(const ValueKey('sheet-action-Mute')));
    await t.pumpAndSettle();
    expect(store.calls, ['muted alice true']);

    await t.longPress(find.text('alice'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Mark as read')));
    await t.pumpAndSettle();
    expect(store.calls.last, 'read alice');
  });

  testWidgets('delete always asks first', (t) async {
    phone(t);
    final store = FakeChatStore();
    await t.pumpWidget(host(const ChatListScreen(), [chatStoreProvider.overrideWithValue(store)]));
    await t.pumpAndSettle();

    await t.longPress(find.text('bob'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete chat')));
    await t.pumpAndSettle();
    expect(store.calls, isEmpty, reason: 'nothing deleted before confirming');
    await t.tap(find.byKey(const ValueKey('sheet-cancel')));
    await t.pumpAndSettle();
    expect(store.calls, isEmpty);

    await t.longPress(find.text('bob'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete chat')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete chat')));
    await t.pumpAndSettle();
    expect(store.calls, ['delete bob']);
  });

  testWidgets('search finds chats by name and messages by text, opens the chat', (t) async {
    phone(t);
    final queries = <String>[];
    Future<List<core.MessageSearchHit>> searcher(String q) async {
      queries.add(q);
      return [
        core.MessageSearchHit(
          messageId: 'm1',
          chatId: 'team',
          chatName: 'team',
          tsUnix: 0,
          body: 'see the alice plan',
          wireId: 'w1',
        ),
      ];
    }

    ChatPreview? opened;
    String? openedAt;
    await t.pumpWidget(host(
      SearchOverlayScreen(
        onOpenChat: (c) => opened = c,
        onOpenMessage: (c, wire) => (opened, openedAt) = (c, wire),
      ),
      [messageSearcherProvider.overrideWithValue(searcher)],
    ));
    await t.pumpAndSettle();
    expect(find.text('Search chats and messages'), findsOneWidget);

    await t.enterText(find.byType(EditableText), 'alice');
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
    expect(queries, ['alice'], reason: 'debounced: one search per pause');
    expect(find.text('CHATS'), findsOneWidget);
    expect(find.text('MESSAGES'), findsOneWidget);
    expect(find.textContaining('alice plan', findRichText: true), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('hit-m1')));
    expect(opened?.id, 'team');
    expect(openedAt, 'w1', reason: 'a message hit opens the chat at that message');
  });

  // Owner, 2026-10-20: recent searches — remove one or clear all.
  testWidgets('search remembers the chats opened from it; × removes one, Clear removes all', (t) async {
    phone(t);
    final settings = MemoryStore();
    final opened = <String?>[];
    Widget screen() => host(
      SearchOverlayScreen(onOpenChat: (c) => opened.add(c.id)),
      [messageSearcherProvider.overrideWithValue((_) async => const <core.MessageSearchHit>[])],
      settings: settings,
    );
    await t.pumpWidget(screen());
    await t.pumpAndSettle();
    expect(find.text('Recent'), findsNothing, reason: 'nothing opened yet');

    for (final name in ['alice', 'bob']) {
      await t.enterText(find.byType(EditableText), name);
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      await t.tap(find.text(name).last);
      await t.pumpAndSettle();
      await t.enterText(find.byType(EditableText), '');
      await t.pumpAndSettle();
    }
    expect(opened, ['alice', 'bob']);
    expect(parseRecentSearch(await settings.get('search_recent') ?? ''), ['bob', 'alice'], reason: 'newest first');
    expect(find.text('Recent'), findsOneWidget);

    // A tap on a recent chat opens it.
    await t.tap(find.byKey(const ValueKey('search-recent-alice')));
    expect(opened.last, 'alice');
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('search-recent-remove-bob')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('search-recent-bob')), findsNothing);
    expect(find.byKey(const ValueKey('search-recent-alice')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('search-recent-clear')));
    await t.pumpAndSettle();
    expect(find.text('Recent'), findsNothing);
    expect(find.text('Search chats and messages'), findsOneWidget);
    expect(await settings.get('search_recent'), '');
  });

  test('recent searches: newest first, no repeats, capped', () {
    var s = '';
    for (var i = 0; i < kRecentSearchMax + 3; i++) {
      s = withRecentSearch(s, 'c$i');
    }
    s = withRecentSearch(s, 'c5');
    final list = parseRecentSearch(s);
    expect(list.first, 'c5');
    expect(list.length, kRecentSearchMax);
    expect(list.where((id) => id == 'c5').length, 1);
    expect(parseRecentSearch(withoutRecentSearch(s, 'c5')).contains('c5'), isFalse);
  });

  test('snippetAround keeps the match visible in long messages', () {
    expect(snippetAround('short alice', 'alice'), 'short alice');
    final long = '${'x' * 100} alice';
    expect(snippetAround(long, 'alice').startsWith('…'), isTrue);
    expect(snippetAround(long, 'alice').contains('alice'), isTrue);
  });

  // Owner, 2026-10-16 (like Telegram): no connection → "Connecting…" with a
  // spinner instead of "Chats" — after a second, not for a blink.
  testWidgets('the title says "Connecting…" while the connection is lost', (t) async {
    await t.pumpWidget(host(const ChatListScreen(), []));
    await t.pumpAndSettle();
    final title = find.byKey(const ValueKey('header-title'));
    expect((t.widget(title) as Text).data, 'Chats');
    final c = ProviderScope.containerOf(t.element(find.byType(ChatListScreen)));
    c.read(netStatusProvider.notifier).set(NetStatus.disconnected);
    await t.pump(const Duration(milliseconds: 500));
    expect((t.widget(title) as Text).data, 'Chats', reason: 'not for a blink');
    await t.pump(const Duration(milliseconds: 600));
    expect((t.widget(title) as Text).data, 'Connecting…');
    expect(find.byKey(const ValueKey('header-connecting')), findsOneWidget);
    c.read(netStatusProvider.notifier).set(NetStatus.connected);
    await t.pump();
    expect((t.widget(title) as Text).data, 'Chats');
    expect(find.byKey(const ValueKey('header-connecting')), findsNothing);
  });
}
