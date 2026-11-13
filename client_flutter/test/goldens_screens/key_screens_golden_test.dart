// Key screens as golden images — UI backlog §9 item 60: chat list, chat,
// settings and the in-app banner, in light and dark, in English and
// Russian. Any unintended visual change fails the test; intended ones
// are re-recorded with `flutter test --update-goldens` and looked at.
//
// Message times are local wall-clock — the images are recorded on
// macOS in UTC+3, like the other goldens in this repo.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/account_access.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/banners/in_app_banner.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_folders_screen.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/my_profile/my_profile_screen.dart';
import 'package:sinhron/features/onboarding/save_access_screen.dart';
import 'package:sinhron/features/settings/recovery_phrase_status_screen.dart';
import 'package:sinhron/features/settings/settings_screen.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../core/account_access_test.dart' show FakeVault, words24;
import '../core/chat_actions_test.dart' show FakeChatStore;
import '../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../core/settings_providers_test.dart' show MemoryStore;
import '../test_harness.dart';

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

List<ChatPreview> chatsFor(String lang) => lang == 'ru'
    ? const [
        ChatPreview(id: chatId, name: 'Мария Чен', preview: 'До завтра, в девять у входа', time: '14:22', unread: 2),
        ChatPreview(
          id: 'b',
          name: 'Команда',
          preview: 'Макет готов, смотрите',
          time: '13:05',
          group: true,
          pinned: true,
        ),
        ChatPreview(id: 'c', name: 'Алексей', preview: 'Спасибо!', time: 'Вчера', muted: true, unread: 5),
        ChatPreview(id: 'd', name: 'Ольга', preview: 'Фото', time: 'пн', kind: ChatPreviewKind.photo),
      ]
    : const [
        ChatPreview(
          id: chatId,
          name: 'Maria Chen',
          preview: 'See you tomorrow at nine by the door',
          time: '14:22',
          unread: 2,
        ),
        ChatPreview(
          id: 'b',
          name: 'Team',
          preview: 'Mockups are ready, take a look',
          time: '13:05',
          group: true,
          pinned: true,
        ),
        ChatPreview(id: 'c', name: 'Alex', preview: 'Thanks!', time: 'Yesterday', muted: true, unread: 5),
        ChatPreview(id: 'd', name: 'Olga', preview: 'Photo', time: 'Mon', kind: ChatPreviewKind.photo),
      ];

core.StoredMessageSummary row(int i, String body, {bool mine = false, String? reactions, String? reply}) =>
    core.StoredMessageSummary(
      id: 'm$i',
      chatId: chatId,
      // 9 Oct 2025, 11:53 local, a minute apart — far enough back for a
      // fixed date line. Built from local time, so the snapshots read the
      // same in any time zone (they were 1760000000 = 11:53 at UTC+3).
      tsUnix: DateTime(2025, 10, 9, 11, 53, 20).millisecondsSinceEpoch ~/ 1000 + i * 60,
      body: body,
      kind: 'text',
      isMine: mine,
      wireId: '00000000-0000-4000-8000-00000000000$i',
      status: 3,
      deleted: false,
      reactionsJson: reactions,
      replyJson: reply,
    );

List<core.StoredMessageSummary> messagesFor(String lang) => lang == 'ru'
    ? [
        row(1, 'Привет! Как дела?', reactions: '{"+":["me"]}'),
        row(2, 'Отлично, спасибо. А у тебя?', mine: true),
        row(
          3,
          'Тоже хорошо. Завтра в девять?',
          reply: '{"id":"00000000-0000-4000-8000-000000000002","snippet":"Отлично, спасибо","kind":"text"}',
        ),
        row(4, 'Да, у входа', mine: true),
      ]
    : [
        row(1, 'Hi! How are you?', reactions: '{"+":["me"]}'),
        row(2, 'Great, thanks. And you?', mine: true),
        row(
          3,
          'All good. Tomorrow at nine?',
          reply: '{"id":"00000000-0000-4000-8000-000000000002","snippet":"Great, thanks","kind":"text"}',
        ),
        row(4, 'Yes, by the door', mine: true),
      ];

Widget host(Widget child, {required bool dark, required String lang, Map<String, String> settings = const {}}) =>
    ProviderScope(
  overrides: [
    settingsStoreProvider.overrideWithValue(
      MemoryStore()
        ..map['profile_name'] = lang == 'ru' ? 'Вера' : 'Vera'
        ..map.addAll(settings),
    ),
    chatsProvider.overrideWith((ref) async => chatsFor(lang)),
    messageStoreProvider.overrideWithValue(FakeMessageStore()),
    messageSenderProvider.overrideWithValue(FakeSender()),
    chatStoreProvider.overrideWithValue(FakeChatStore()),
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    passwordVaultProvider.overrideWithValue(FakeVault()),
    messagePageFetcherProvider.overrideWithValue(
      (String id, {int? beforeTs, String? beforeId, required int limit}) async =>
          beforeId == null ? messagesFor(lang) : const [],
    ),
  ],
  child: Localizations(
    locale: Locale(lang),
    delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    child: wrapForGolden(
      isDark: dark,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(top: 47, bottom: 34)),
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
      ),
    ),
  ),
);

void main() {
  setUpAll(loadAppFonts);
  setUp(() => DsHaptics.enabled = false);

  Future<void> shoot(
    WidgetTester t,
    String name,
    Widget screen, {
    required bool dark,
    required String lang,
    Map<String, String> settings = const {},
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    currentLanguage = lang;
    addTearDown(() => currentLanguage = 'en');
    await t.pumpWidget(host(screen, dark: dark, lang: lang, settings: settings));
    await t.pumpAndSettle();
    await expectLater(find.byType(Navigator).first, matchesGoldenFile('goldens/$name.png'));
  }

  for (final (lang, dark) in [('en', false), ('en', true), ('ru', false), ('ru', true)]) {
    final suffix = '${lang}_${dark ? 'dark' : 'light'}';
    testWidgets(
      'chat list $suffix',
      (t) => shoot(t, 'chat_list_$suffix', const ChatListScreen(), dark: dark, lang: lang),
    );
    testWidgets(
      'chat $suffix',
      (t) => shoot(
        t,
        'chat_$suffix',
        ChatViewScreen(chatId: chatId, contactName: lang == 'ru' ? 'Мария Чен' : 'Maria Chen'),
        dark: dark,
        lang: lang,
      ),
    );
  }

  testWidgets(
    'settings ru light',
    (t) => shoot(t, 'settings_ru_light', _wiredSettings(), dark: false, lang: 'ru'),
  );
  testWidgets('settings en dark', (t) => shoot(t, 'settings_en_dark', _wiredSettings(), dark: true, lang: 'en'));
  // The bottom of the list: Help & rules, Advanced (server, connection,
  // proxy), About.
  testWidgets('settings ru light, bottom', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    currentLanguage = 'ru';
    addTearDown(() => currentLanguage = 'en');
    await t.pumpWidget(host(_wiredSettings(), dark: false, lang: 'ru'));
    await t.pumpAndSettle();
    await t.drag(find.byType(ListView), const Offset(0, -560));
    await t.pumpAndSettle();
    await expectLater(find.byType(Navigator).first, matchesGoldenFile('goldens/settings_ru_light_bottom.png'));
  });
  // Owner, 2026-10-18 — my photo in the Chats header opens My profile.
  for (final (lang, dark) in [('ru', false), ('en', true)]) {
    final suffix = '${lang}_${dark ? 'dark' : 'light'}';
    testWidgets(
      'my profile $suffix',
      (t) => shoot(
        t,
        'my_profile_$suffix',
        MyProfileScreen(
          name: lang == 'ru' ? 'Вера' : 'Vera',
          about: lang == 'ru' ? 'Дизайнер, Лиссабон' : 'Designer, Lisbon',
          address: '9a3e 4d12 8b71 c0f5',
          qrPayload: 'sinhron:contact:9a3e4d128b71c0f5',
          onBack: () {},
          onEdit: () {},
          onShare: () {},
          onCopyAddress: () {},
        ),
        dark: dark,
        lang: lang,
      ),
    );
  }

  // Settings → Chat folders (2026-10-18): a custom folder, a hidden
  // built-in, the suggestions.
  for (final (lang, dark) in [('ru', false), ('en', true)]) {
    final suffix = '${lang}_${dark ? 'dark' : 'light'}';
    testWidgets(
      'chat folders $suffix',
      (t) => shoot(
        t,
        'chat_folders_$suffix',
        const ChatFoldersScreen(),
        dark: dark,
        lang: lang,
        settings: {
          'chat_folders': '[{"id":"w","name":"${lang == 'ru' ? 'Работа' : 'Work'}","emoji":"💼","groups":true}]',
          'chat_folder_layout': '{"order":["all","w","personal","groups","unread"],"hidden":["unread"]}',
        },
      ),
    );
  }

  // ADR-059 — sign-up step 3 "Keep access to your account" and Settings →
  // Secret words while the words still wait on the phone.
  for (final (lang, dark) in [('ru', false), ('en', true)]) {
    final suffix = '${lang}_${dark ? 'dark' : 'light'}';
    testWidgets(
      'save access $suffix',
      (t) => shoot(t, 'save_access_$suffix', SaveAccessScreen(words: words24.split(' ')), dark: dark, lang: lang),
    );
    testWidgets(
      'secret words waiting $suffix',
      (t) => shoot(
        t,
        'secret_words_waiting_$suffix',
        const RecoveryPhraseStatusScreen(
          access: AccessState(wordsOnPhone: true),
          passwordsAvailable: true,
        ),
        dark: dark,
        lang: lang,
      ),
    );
  }

  for (final dark in [false, true]) {
    testWidgets('in-app banner ru ${dark ? 'dark' : 'light'}', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      currentLanguage = 'ru';
      addTearDown(() => currentLanguage = 'en');
      late ProviderContainer c;
      await t.pumpWidget(
        host(
          Consumer(
            builder: (context, ref, _) {
              c = ProviderScope.containerOf(context);
              return InAppBannerHost(onOpen: (_) {}, child: const ChatListScreen());
            },
          ),
          dark: dark,
          lang: 'ru',
        ),
      );
      await t.pumpAndSettle();
      c
          .read(inAppBannerProvider.notifier)
          .show(const InAppBanner(chatId: 'c', title: 'Алексей', body: 'Ты где? Мы уже на месте, ждём тебя у входа'));
      await t.pumpAndSettle();
      await expectLater(
        find.byType(Navigator).first,
        matchesGoldenFile('goldens/in_app_banner_ru_${dark ? 'dark' : 'light'}.png'),
      );
    });
  }
}

/// Settings as the app wires it: every row that opens a screen has its tap
/// (a row without one shows no chevron — 2026-10-18).
SettingsScreen _wiredSettings() {
  void open() {}
  return SettingsScreen(
    onAppearanceTap: open,
    onStorageTap: open,
    onTermsTap: open,
    onPrivacyPolicyTap: open,
    onSupportTap: open,
    onLinkedDevicesTap: open,
    onPrivacyTap: open,
    onServerTap: open,
    onNotificationsTap: open,
    onAppLockTap: open,
    onRecoveryPhraseTap: open,
    onProfileTap: open,
    onChatFoldersTap: open,
    onArchiveTap: open,
    onProxyTap: open,
  );
}
