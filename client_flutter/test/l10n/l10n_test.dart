import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

import '../core/settings_providers_test.dart' show MemoryStore;

void main() {
  test('every English string has a Russian translation', () {
    Map<String, dynamic> load(String p) => jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;
    final en = load('lib/l10n/app_en.arb').keys.where((k) => !k.startsWith('@'));
    final ru = load('lib/l10n/app_ru.arb').keys.where((k) => !k.startsWith('@')).toSet();
    final missing = en.where((k) => !ru.contains(k)).toList();
    expect(missing, isEmpty, reason: 'missing in app_ru.arb: $missing');
  });

  test('Russian plurals', () {
    final ru = lookupAppL10n(const Locale('ru'));
    expect(ru.deleteMessagesConfirm(1), 'Удалить 1 сообщение?');
    expect(ru.deleteMessagesConfirm(3), 'Удалить 3 сообщения?');
    expect(ru.deleteMessagesConfirm(5), 'Удалить 5 сообщений?');
    expect(ru.deleteMessagesConfirm(21), 'Удалить 21 сообщение?');
    expect(ru.timerDays(2), '2 дня');
    expect(ru.lockAfterMinutes(5), 'Через 5 минут');
    final en = lookupAppL10n(const Locale('en'));
    expect(en.deleteMessagesConfirm(1), 'Delete this message?');
    expect(en.deleteMessagesConfirm(4), 'Delete 4 messages?');
  });

  test('dates follow the app language', () {
    final now = DateTime(2026, 10, 13, 12);
    int ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    addTearDown(() => currentLanguage = 'en');
    currentLanguage = 'ru';
    expect(formatDaySeparator(ts(DateTime(2026, 10, 13, 9)), now: now), 'Сегодня');
    expect(formatDaySeparator(ts(DateTime(2026, 4, 12)), now: now), '12 апреля');
    expect(formatDaySeparator(ts(DateTime(2025, 4, 12)), now: now), '12 апреля 2025 г.');
    expect(formatChatTime(ts(DateTime(2026, 10, 12, 9)), now: now), 'Вчера');
    currentLanguage = 'en';
    expect(formatDaySeparator(ts(DateTime(2026, 4, 12)), now: now), 'April 12');
    expect(formatChatTime(ts(DateTime(2026, 10, 12, 9)), now: now), 'Yesterday');
  });

  test('phone language → app language', () {
    expect(resolveLocale(const [Locale('ru', 'RU')]), const Locale('ru'));
    expect(resolveLocale(const [Locale('uk')]), const Locale('ru'));
    expect(resolveLocale(const [Locale('de'), Locale('en')]), const Locale('en'));
    expect(resolveLocale(const [Locale('fr')]), const Locale('en'));
    expect(chosenLocale('ru'), const Locale('ru'));
    expect(chosenLocale('system'), isNull);
  });

  testWidgets('chat list in Russian', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(ProviderScope(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
      ],
      child: Localizations(
        locale: Locale('ru'),
        delegates: [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
        child: const DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: MediaQueryData(size: Size(390, 844)),
            child: Directionality(textDirection: TextDirection.ltr, child: ChatListScreen()),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('Чаты'), findsWidgets);
    expect(find.text('Все'), findsOneWidget);
    expect(find.text('Непрочитанные'), findsOneWidget);
    expect(find.text('Чатов пока нет'), findsOneWidget);
    expect(find.text('Настройки'), findsOneWidget, reason: 'tab bar');
  });
}
