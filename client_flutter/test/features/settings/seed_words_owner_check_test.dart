// Audit SEED-1 — the words saved in Passwords / iCloud Keychain come back on
// the screen only after Face ID / the passcode; a stranger holding the open
// phone can neither see them nor move the waiting words into Passwords.

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
import 'package:sinhron/core/qr_scan.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/onboarding/restore_screen.dart';
import 'package:sinhron/features/settings/account_access_screen.dart';
import 'package:sinhron/features/settings/backup_words_sheet.dart';
import 'package:sinhron/features/settings/phrase_prompt.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/account_access_test.dart' show FakeVault, t0;
import '../../core/session_test.dart' show FakeKeys, secrets;
import '../../core/settings_providers_test.dart' show MemoryStore;
import '../app_lock/app_lock_test.dart' show FakeAuth;

const twelve = 'abandon ability able about above absent absorb abstract absurd abuse access accident';

Widget host(List<Override> overrides, Widget child) => ProviderScope(
  overrides: [
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    linkedDevicesProvider.overrideWith((ref) async => const <core.LinkedDevice>[]),
    settingsStoreProvider.overrideWithValue(MemoryStore()),
    accessClockProvider.overrideWithValue(() => t0),
    secretOpsProvider.overrideWithValue(secrets(storedFor: twelve)),
    qrScannerProvider.overrideWithValue(() async => null),
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

  // The three screens with a "Paste from Passwords" button.
  final screens = <String, (Widget, ValueKey<String>)>{
    'check the words': (const PhrasePromptScreen(), const ValueKey('phrase-prompt-passwords')),
    'sign in': (const RestoreScreen(), const ValueKey('restore-passwords')),
    'turn the backup on': (const BackupWordsSheet(), const ValueKey('backup-words-passwords')),
  };

  for (final MapEntry(key: name, value: (screen, button)) in screens.entries) {
    for (final owner in [false, true]) {
      testWidgets('$name: saved words — ${owner ? 'the owner gets them after' : 'a stranger fails'} Face ID / passcode', (
        t,
      ) async {
        await size(t);
        final auth = FakeAuth()..ok = owner;
        await t.pumpWidget(
          host([
            passwordVaultProvider.overrideWithValue(FakeVault(stored: twelve)),
            appAuthenticatorProvider.overrideWithValue(auth),
          ], screen),
        );
        await t.pumpAndSettle();
        await t.tap(find.byKey(button));
        await t.pumpAndSettle();
        expect(auth.asked, 1);
        expect(find.text(twelve), owner ? findsOneWidget : findsNothing);
      });
    }
  }

  testWidgets('"Save to Passwords": a stranger cannot move the waiting words', (t) async {
    await size(t);
    final auth = FakeAuth()..ok = false;
    final vault = FakeVault();
    await t.pumpWidget(
      host([
        pendingPhraseStoreProvider.overrideWithValue(FakeKeys(twelve)),
        passwordVaultProvider.overrideWithValue(vault),
        appAuthenticatorProvider.overrideWithValue(auth),
      ], const AccountAccessScreen()),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('access-save-passwords')));
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(vault.saves, isEmpty);
  });
}
