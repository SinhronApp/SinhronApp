// Dynamic Type — UI backlog §7 item 54. Key screens at large text sizes
// must lay out without overflow (any overflow fails the test).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/settings/privacy_security_screen.dart';
import 'package:sinhron/features/settings/settings_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../core/chat_actions_test.dart' show FakeChatStore;
import '../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../core/settings_providers_test.dart' show MemoryStore;

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

final chats = [
  const ChatPreview(
    id: chatId,
    name: 'Мария Константинопольская',
    preview: 'Длинное сообщение, которое не помещается в одну строку',
    time: '14:22',
    unread: 12,
  ),
  const ChatPreview(id: 'b', name: 'Team', preview: 'ok', time: 'Yesterday', group: true, muted: true, pinned: true),
];

core.StoredMessageSummary row(int i, String body, {bool mine = false}) => core.StoredMessageSummary(
  id: 'm$i',
  chatId: chatId,
  tsUnix: 1760000000 + i,
  body: body,
  kind: 'text',
  isMine: mine,
  wireId: '00000000-0000-4000-8000-00000000000$i',
  status: 3,
  deleted: false,
  reactionsJson: i == 1 ? '{"❤️":["me"],"👍":["x"]}' : null,
  replyJson: i == 2 ? '{"id":"00000000-0000-4000-8000-000000000001","snippet":"Привет","kind":"text"}' : null,
);

Widget host(Widget child, double scale) => ProviderScope(
  overrides: [
    settingsStoreProvider.overrideWithValue(MemoryStore()),
    chatsProvider.overrideWith((ref) async => chats),
    messageStoreProvider.overrideWithValue(FakeMessageStore()),
    messageSenderProvider.overrideWithValue(FakeSender()),
    chatStoreProvider.overrideWithValue(FakeChatStore()),
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    messagePageFetcherProvider.overrideWithValue(
      (String id, {int? beforeTs, String? beforeId, required int limit}) async => beforeId == null
          ? [row(1, 'Привет! Как дела?'), row(2, 'Отлично, спасибо — а у тебя?', mine: true), row(3, '👍')]
          : const [],
    ),
  ],
  child: DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: MediaQueryData(size: const Size(375, 812), textScaler: TextScaler.linear(scale)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
      ),
    ),
  ),
);

void main() {
  for (final scale in [1.5, 2.0]) {
    for (final (name, screen) in [
      ('chat list', const ChatListScreen()),
      ('chat', const ChatViewScreen(chatId: chatId, contactName: 'Мария Константинопольская')),
      ('settings', const SettingsScreen()),
      ('privacy', const PrivacySecurityScreen()),
    ]) {
      testWidgets('$name at ${scale}x text has no overflow', (t) async {
        t.view.physicalSize = const Size(375, 812);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(host(screen, scale));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
      });
    }
  }
}
