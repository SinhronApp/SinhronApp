// ADR-059 — Settings → Secret words when sign-up said "Later", the real
// "Check the words", and the calm chat-list reminder.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/account_access.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/device_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/chat_list/access_reminder.dart';
import 'package:sinhron/features/onboarding/recovery_phrase_screen.dart';
import 'package:sinhron/features/settings/account_access_screen.dart';
import 'package:sinhron/features/settings/settings_screen.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/account_access_test.dart' show FakeVault, t0;
import '../app_lock/app_lock_test.dart' show FakeAuth;
import '../../core/session_test.dart' show FakeKeys, secrets;
import '../../core/settings_providers_test.dart' show MemoryStore;

const twelve = 'abandon ability able about above absent absorb abstract absurd abuse access accident';

Widget host(List<Override> overrides, Widget child) => ProviderScope(
  overrides: [
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    linkedDevicesProvider.overrideWith((ref) async => const <core.LinkedDevice>[]),
    ...overrides,
  ],
  child: Localizations(
    locale: const Locale('en'),
    delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 1200)),
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
      ),
    ),
  ),
);

void main() {
  setUp(() {
    DsHaptics.enabled = false;
    appNotice.value = '';
  });

  Future<void> size(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  testWidgets('not saved yet: amber hero, save to Passwords moves the words off the phone', (t) async {
    await size(t);
    final store = MemoryStore()..map['profile_name'] = 'Vera';
    final pending = FakeKeys(twelve);
    final vault = FakeVault();
    await t.pumpWidget(
      host([
        settingsStoreProvider.overrideWithValue(store),
        pendingPhraseStoreProvider.overrideWithValue(pending),
        passwordVaultProvider.overrideWithValue(vault),
        accessClockProvider.overrideWithValue(() => t0),
        secretOpsProvider.overrideWithValue(secrets(storedFor: twelve)),
        appAuthenticatorProvider.overrideWithValue(FakeAuth()), // the owner
      ], const AccountAccessScreen()),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('access-hero-waiting')), findsOneWidget);
    expect(find.text('Access not saved'), findsOneWidget);
    expect(find.text('Link a second device'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('access-save-passwords')));
    await t.pumpAndSettle();
    expect(vault.saves.single.secret, twelve);
    expect(pending.value, isNull);
    expect(find.byKey(const ValueKey('access-hero-saved')), findsOneWidget);
    expect(find.textContaining('In Passwords · 18.10.2026'), findsOneWidget);
    expect(find.byKey(const ValueKey('access-save-passwords')), findsNothing);
  });

  // Audit storage-devices:5 — whoever held the open phone read the words.
  testWidgets('someone holding the phone: no Face ID / passcode → the waiting words are not shown', (t) async {
    await size(t);
    final auth = FakeAuth()..ok = false;
    await t.pumpWidget(
      host([
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        pendingPhraseStoreProvider.overrideWithValue(FakeKeys(twelve)),
        accessClockProvider.overrideWithValue(() => t0),
        appAuthenticatorProvider.overrideWithValue(auth),
      ], const AccountAccessScreen()),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('access-write-down')));
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(find.byType(RecoveryPhraseScreen), findsNothing);

    auth.ok = true; // the owner
    await t.tap(find.byKey(const ValueKey('access-write-down')));
    await t.pumpAndSettle();
    expect(find.byType(RecoveryPhraseScreen), findsOneWidget);
  });

  // storage-devices:2 — saved before ADR-085 as a Safari password of the
  // server's domain, where a page could AutoFill-phish them: moved.
  testWidgets('iPhone: words still a Safari password → "Move to iCloud Keychain" moves them', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await size(t);
    final store = MemoryStore()..map[kAccessSavedKey] = 'passwords:${t0.millisecondsSinceEpoch}';
    final vault = FakeVault(stored: twelve);
    await t.pumpWidget(
      host([
        settingsStoreProvider.overrideWithValue(store),
        pendingPhraseStoreProvider.overrideWithValue(FakeKeys()),
        passwordVaultProvider.overrideWithValue(vault),
        accessClockProvider.overrideWithValue(() => t0),
        secretOpsProvider.overrideWithValue(secrets(storedFor: twelve)),
      ], const AccountAccessScreen()),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('as a website password'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('access-move-keychain')));
    await t.pumpAndSettle();
    expect(store.map[kAccessSavedKey], startsWith('keychain:'));
    expect(find.textContaining('In iCloud Keychain · 18.10.2026'), findsOneWidget);
    expect(find.byKey(const ValueKey('access-move-keychain')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Check the words: all 24 against this account, pasted from Passwords', (t) async {
    await size(t);
    final store = MemoryStore();
    await t.pumpWidget(
      host([
        settingsStoreProvider.overrideWithValue(store),
        pendingPhraseStoreProvider.overrideWithValue(FakeKeys()),
        passwordVaultProvider.overrideWithValue(FakeVault(stored: 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo')),
        accessClockProvider.overrideWithValue(() => t0),
        secretOpsProvider.overrideWithValue(secrets(storedFor: twelve)),
        appAuthenticatorProvider.overrideWithValue(FakeAuth()), // the owner
      ], const AccountAccessScreen()),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('access-hero-waiting')), findsNothing);
    expect(find.byKey(const ValueKey('access-hero-saved')), findsNothing, reason: 'old account: nothing invented');

    // Wrong words (pasted from Passwords): said so, nothing recorded.
    await t.tap(find.byKey(const ValueKey('access-check')));
    await t.pumpAndSettle();
    expect(find.text('Check the words'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('phrase-prompt-passwords')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('phrase-prompt-confirm')));
    await t.pumpAndSettle();
    expect(appNotice.value, 'These aren’t this account’s words');
    expect(store.map[kAccessSavedKey], isNull);

    // The right ones.
    await t.tap(find.byKey(const ValueKey('access-check')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('phrase-prompt-field')), twelve);
    await t.tap(find.byKey(const ValueKey('phrase-prompt-confirm')));
    await t.pumpAndSettle();
    expect(appDone.value.text, 'Right — these are your words');
    expect(store.map[kAccessSavedKey], startsWith('checked:'));
    expect(find.byKey(const ValueKey('access-hero-saved')), findsOneWidget);
  });

  testWidgets('Settings row says "Not saved" only while the words wait', (t) async {
    await size(t);
    final pending = FakeKeys(twelve);
    late ProviderContainer c;
    await t.pumpWidget(
      host(
        [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          pendingPhraseStoreProvider.overrideWithValue(pending),
          accessClockProvider.overrideWithValue(() => t0),
        ],
        Consumer(
          builder: (context, ref, _) {
            c = ProviderScope.containerOf(context);
            return const SettingsScreen();
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Not saved'), findsOneWidget);
    await c.read(accountAccessProvider.notifier).markSaved(AccessWay.paper);
    await t.pumpAndSettle();
    expect(find.text('Not saved'), findsNothing);
  });

  testWidgets('reminder card: due a day after "Later"; Later again → a week', (t) async {
    await size(t);
    final store = MemoryStore()..map[kAccessRemindKey] = '${t0.millisecondsSinceEpoch}';
    var now = t0.subtract(const Duration(hours: 1));
    var saves = 0;
    late ProviderContainer c;
    Widget app() => host(
      [
        settingsStoreProvider.overrideWithValue(store),
        pendingPhraseStoreProvider.overrideWithValue(FakeKeys(twelve)),
        accessClockProvider.overrideWithValue(() => now),
      ],
      Consumer(
        builder: (context, ref, _) {
          c = ProviderScope.containerOf(context);
          return AccessReminderCard(onSave: () => saves++);
        },
      ),
    );
    await t.pumpWidget(app());
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('access-reminder')), findsNothing, reason: 'not yet');

    now = t0.add(const Duration(minutes: 1));
    c.invalidate(accountAccessProvider);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('access-reminder')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('access-reminder-save')));
    expect(saves, 1);

    await t.tap(find.byKey(const ValueKey('access-reminder-later')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('access-reminder')), findsNothing);
    expect(store.map[kAccessRemindKey], '${now.add(kNextReminderAfter).millisecondsSinceEpoch}');
  });
}
