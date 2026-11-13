import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

Widget host(List overrides) => ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(MemoryStore()), ...overrides],
      child: const DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: Size(390, 844)),
          child: Directionality(textDirection: TextDirection.ltr, child: ChatListScreen()),
        ),
      ),
    );

void main() {
  testWidgets('empty database shows a real empty state, not demo chats', (t) async {
    await t.pumpWidget(host([chatsProvider.overrideWith((ref) async => const <ChatPreview>[])]));
    await t.pumpAndSettle();
    expect(find.text('No chats yet'), findsOneWidget);
    expect(find.text('Maria Chen'), findsNothing);
    expect(find.text('Vera Kuznetsova'), findsNothing);
  });

  // ADR-055 — Saved messages is always there, first, even before any chat.
  testWidgets('Saved messages: first row, even in an empty list', (t) async {
    await t.pumpWidget(host([chatsProvider.overrideWith((ref) async => const <ChatPreview>[])]));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-saved')), findsOneWidget);
    expect(find.text('Saved Messages'), findsOneWidget);
    expect(find.text('No chats yet'), findsOneWidget, reason: 'the hint stays under it');
  });

  testWidgets('Saved messages sits above pinned chats, shown once', (t) async {
    await t.pumpWidget(host([
      chatsProvider.overrideWith(
        (ref) async => const [
          ChatPreview(id: 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0', name: 'Saved Messages', preview: 'milk', time: '', saved: true),
          ChatPreview(id: 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', name: 'Maria', preview: 'hi', time: '', pinned: true),
        ],
      ),
    ]));
    await t.pumpAndSettle();
    final saved = t.getTopLeft(find.byKey(const ValueKey('chat-saved')));
    final maria = t.getTopLeft(find.byKey(const ValueKey('chat-a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1')));
    expect(saved.dy, lessThan(maria.dy), reason: 'above pinned chats too');
    expect(find.text('Saved Messages'), findsOneWidget, reason: 'once — not again in the list');
    expect(find.text('No chats yet'), findsNothing);
  });

  testWidgets('load error shows an error state, not demo chats', (t) async {
    await t.pumpWidget(host([chatsProvider.overrideWith((ref) async => throw StateError('db'))]));
    await t.pumpAndSettle();
    expect(find.text('Chats could not be loaded'), findsOneWidget);
    expect(find.text('Maria Chen'), findsNothing);
  });
}
