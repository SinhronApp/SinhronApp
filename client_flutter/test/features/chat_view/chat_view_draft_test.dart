import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/chat_messages_test.dart' show FakeHistory;

void main() {
  testWidgets('opening a chat marks it read and restores the draft; leaving saves it', (t) async {
    final store = FakeChatStore();
    final c = ProviderContainer(overrides: [
      chatStoreProvider.overrideWithValue(store),
      messagePageFetcherProvider.overrideWithValue(FakeHistory(3).fetch),
      chatsProvider.overrideWith(
        (ref) async => const [ChatPreview(id: 'c1', name: 'Maria', preview: '', time: '', draft: 'half-written')],
      ),
    ]);
    addTearDown(c.dispose);
    await c.read(chatsProvider.future); // the list is loaded before a chat opens

    Widget app(bool open) => UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(390, 844)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: open ? const ChatViewScreen(chatId: 'c1', contactName: 'Maria') : const SizedBox(),
              ),
            ),
          ),
        );

    await t.pumpWidget(app(true));
    await t.pumpAndSettle();
    expect(find.text('half-written'), findsOneWidget, reason: 'draft restored');
    expect(store.calls, ['read c1']);
    expect(c.read(openChatProvider), 'c1');

    await t.enterText(find.byType(EditableText), 'finished thought');
    await t.pumpWidget(app(false));
    await t.pumpAndSettle();
    expect(store.calls, ['read c1', 'draft c1 finished thought']);
    expect(c.read(openChatProvider), isNull);
  });

  testWidgets('an unchanged draft is not rewritten', (t) async {
    final store = FakeChatStore();
    final c = ProviderContainer(overrides: [
      chatStoreProvider.overrideWithValue(store),
      messagePageFetcherProvider.overrideWithValue(FakeHistory(1).fetch),
      chatsProvider.overrideWith((ref) async => const [ChatPreview(id: 'c1', name: 'M', preview: '', time: '')]),
    ]);
    addTearDown(c.dispose);
    await c.read(chatsProvider.future);
    Widget app(bool open) => UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(390, 844)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: open ? const ChatViewScreen(chatId: 'c1', contactName: 'M') : const SizedBox(),
              ),
            ),
          ),
        );
    await t.pumpWidget(app(true));
    await t.pumpAndSettle();
    await t.pumpWidget(app(false));
    await t.pumpAndSettle();
    expect(store.calls, ['read c1']);
  });
}
