// ADR-059 — sign-up step 3 "Keep access to your account": one tap to the
// password manager, write the words down (2-word check, recovery sheet),
// or "Later" — none of them blocks; the account is made once, at the end.
// Plus the restore side: paste from Passwords, scan the recovery sheet.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/account_access.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/qr_scan.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/screenshot_watch.dart' show screenCaptured;
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/onboarding/phrase_check.dart';
import 'package:sinhron/features/onboarding/recovery_phrase_screen.dart';
import 'package:sinhron/features/onboarding/recovery_sheet.dart';
import 'package:sinhron/features/onboarding/restore_screen.dart';
import 'package:sinhron/features/onboarding/save_access_screen.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/widgets/ds_mnemonic_grid.dart';

import '../../core/account_access_test.dart' show FakeVault, words24, t0;
import '../../core/session_test.dart' show FakeKeys, secrets;
import '../../core/settings_providers_test.dart' show MemoryStore;
import '../app_lock/app_lock_test.dart' show FakeAuth;

final words = words24.split(' ');

class World {
  final store = MemoryStore()..map['profile_name'] = 'Vera';
  World({FakeKeys? pending}) : pending = pending ?? FakeKeys();
  final FakeKeys pending;
  FakeVault vault = FakeVault();
  final created = <String>[];
  final shared = <Uint8List>[];
  bool shareOk = true;
  String? scanned;

  List<Override> get overrides => [
    settingsStoreProvider.overrideWithValue(store),
    pendingPhraseStoreProvider.overrideWithValue(pending),
    passwordVaultProvider.overrideWithValue(vault),
    accessClockProvider.overrideWithValue(() => t0),
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    secretOpsProvider.overrideWithValue(secrets()),
    recoverySheetSharerProvider.overrideWithValue((png, {origin}) async {
      shared.add(png);
      return shareOk;
    }),
    qrScannerProvider.overrideWithValue(() async => scanned),
    appAuthenticatorProvider.overrideWithValue(FakeAuth()), // the owner
  ];

  Future<void> createAccount(WidgetRef ref, String phrase) async => created.add(phrase);
}

class _NoWrite extends FakeKeys {
  @override
  Future<void> write(String deviceKey) async => throw StateError('keychain');
}

Widget host(World w, Widget child) => ProviderScope(
  overrides: w.overrides,
  child: Localizations(
    locale: const Locale('en'),
    delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
      ),
    ),
  ),
);

Future<int> pumpSaveAccess(WidgetTester t, World w) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  var done = 0;
  await t.pumpWidget(
    host(
      w,
      SaveAccessScreen(words: words, createAccount: w.createAccount, onDone: () => done++),
    ),
  );
  await t.pumpAndSettle();
  return done;
}

void main() {
  setUp(() => DsHaptics.enabled = false);

  testWidgets('Save to Passwords: one tap, the account is made, nothing left waiting', (t) async {
    final w = World();
    var done = 0;
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(w, SaveAccessScreen(words: words, createAccount: w.createAccount, onDone: () => done++)),
    );
    await t.pumpAndSettle();
    expect(find.text('Keep access to your account'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget, reason: 'never a wall');

    await t.tap(find.byKey(const ValueKey('save-passwords')));
    await t.pumpAndSettle();

    expect(w.vault.saves.single.secret, words24);
    expect(w.vault.saves.single.account, startsWith('Vera · '));
    expect(w.created, [words24], reason: 'made once, with these words');
    expect(w.pending.value, isNull, reason: 'saved — nothing waits on the phone');
    expect(w.store.map[kAccessSavedKey], startsWith('passwords:'));
    expect(done, 1);
  });

  testWidgets('Passwords cancelled: no account yet, stay; failed: say so', (t) async {
    final w = World()..vault = FakeVault(next: VaultResult.cancelled);
    final done = await pumpSaveAccess(t, w);
    await t.tap(find.byKey(const ValueKey('save-passwords')));
    await t.pumpAndSettle();
    expect(w.created, isEmpty);
    expect(done, 0);
    expect(find.textContaining('Couldn’t save'), findsNothing);

    w.vault.next = VaultResult.failed;
    await t.tap(find.byKey(const ValueKey('save-passwords')));
    await t.pumpAndSettle();
    expect(find.textContaining('Couldn’t save to the password manager'), findsOneWidget);
    expect(w.created, isEmpty);
  });

  testWidgets('Later: straight on; the words wait on this phone; reminder tomorrow', (t) async {
    final w = World();
    var done = 0;
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(w, SaveAccessScreen(words: words, createAccount: w.createAccount, onDone: () => done++)),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('save-later')));
    await t.pumpAndSettle();

    expect(done, 1);
    expect(w.created, [words24]);
    expect(w.pending.value, words24);
    expect(w.store.map[kAccessRemindKey], '${t0.add(kFirstReminderAfter).millisecondsSinceEpoch}');
    expect(w.store.map[kAccessSavedKey], isNull);
  });

  // SEED-2 (audit 2026-11b) — the words were kept only AFTER the account was
  // made: the app killed (or an error) in between left an account whose
  // words were nowhere, for good.
  testWidgets('Later: the words are on this phone before the account is made, and stay if making it fails', (t) async {
    final w = World();
    String? whileCreating;
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        w,
        SaveAccessScreen(
          words: words,
          createAccount: (ref, phrase) async {
            whileCreating = w.pending.value;
            throw StateError('device key written, then the Keychain failed');
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('save-later')));
    await t.pumpAndSettle();

    expect(whileCreating, words24, reason: 'kept first');
    expect(w.pending.value, words24);
    expect(w.store.map[kAccessRemindKey], isNotNull);
  });

  testWidgets('Later: the words could not be kept → no account, still on this step', (t) async {
    final w = World(pending: _NoWrite());
    final done = await pumpSaveAccess(t, w);
    await t.tap(find.byKey(const ValueKey('save-later')));
    await t.pumpAndSettle();

    expect(w.created, isEmpty, reason: 'never an account whose words are nowhere');
    expect(done, 0);
    expect(find.text('Later'), findsOneWidget);
    expect(find.textContaining('Couldn’t save'), findsOneWidget, reason: 'not silent');
  });

  testWidgets('Write the words down: reveal, 2-word check, then the account', (t) async {
    final w = World();
    var done = 0;
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(w, SaveAccessScreen(words: words, createAccount: w.createAccount, onDone: () => done++)),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('save-write')));
    await t.pumpAndSettle();
    expect(find.byType(RecoveryPhraseScreen), findsOneWidget);
    expect(find.textContaining('screenshot'), findsOneWidget, reason: 'one plain line, no block');

    // Nothing to confirm until the words are shown.
    await t.tap(find.byKey(const ValueKey('words-written')));
    await t.pumpAndSettle();
    expect(find.byType(PhraseCheckScreen), findsNothing);

    await t.tap(find.byType(DsMnemonicGrid));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('words-written')));
    await t.pumpAndSettle();
    final check = t.widget<PhraseCheckScreen>(find.byType(PhraseCheckScreen));
    expect(check.quiz, hasLength(2));
    for (final q in check.quiz) {
      await t.tap(find.byKey(ValueKey('phrase-option-${q.answer}')));
      await t.pumpAndSettle();
    }

    expect(find.byType(RecoveryPhraseScreen), findsNothing);
    expect(w.created, [words24]);
    expect(w.store.map[kAccessSavedKey], startsWith('paper:'));
    expect(w.pending.value, isNull);
    expect(done, 1);
  });

  testWidgets('Recovery sheet: a PNG to the share sheet; shared = saved', (t) async {
    final w = World();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    AccessWay? saved;
    await t.pumpWidget(host(w, RecoveryPhraseScreen(words: words, onSaved: (way) => saved = way)));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('words-sheet')));
      for (var i = 0; i < 50 && w.shared.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await t.pumpAndSettle();
    expect(w.shared, hasLength(1));
    expect(w.shared.single.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'a PNG');
    expect(saved, AccessWay.sheet);
  });

  // storage-devices:8 — the 24 words on the screen: no screenshot / screen
  // share of them on Android, hidden while an iPhone records the screen,
  // and Copy puts them on the clipboard as a secret, not as plain text.
  testWidgets('words screen: Android keeps it out of screenshots; Copy goes as a secret', (t) async {
    final w = World();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final calls = <String>[];
    final plain = <String>[];
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dev.sinhron/privacy'), (c) async {
      final args = c.arguments as Map;
      calls.add('${c.method} ${args['on'] ?? args['seconds']}');
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') plain.add('${(c.arguments as Map)['text']}');
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('dev.sinhron/privacy'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await t.pumpWidget(host(w, RecoveryPhraseScreen(words: words)));
    await t.pumpAndSettle();
    expect(calls, ['wordsShown true']);
    await t.tap(find.byType(DsMnemonicGrid));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Copy the words'));
    await t.pumpAndSettle();
    await t.tap(find.text('Copy the words'));
    await t.pump();
    expect(calls.last, 'copySecret 60');
    expect(plain, isNot(contains(words24)), reason: 'not the plain system clipboard');
    await t.pumpWidget(const SizedBox());
    expect(calls.last, 'wordsShown false');
  });

  // Audit SEED-4 — Android 10+ gives a background app no clipboard to read
  // (the person is in the password manager, pasting): the 60 s wipe compared
  // first, so it never wiped.
  testWidgets('words screen: Android — the copied words are gone from the clipboard after 60 s', (t) async {
    final w = World();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? clipboard;
    final messenger = t.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('dev.sinhron/privacy'), (c) async {
      if (c.method == 'copySecret') clipboard = (c.arguments as Map)['text'] as String;
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.getData') return null; // not in front → no access
      if (c.method == 'Clipboard.setData') clipboard = (c.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(const MethodChannel('dev.sinhron/privacy'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await t.pumpWidget(host(w, RecoveryPhraseScreen(words: words)));
    await t.pumpAndSettle();
    await t.tap(find.byType(DsMnemonicGrid));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Copy the words'));
    await t.pumpAndSettle();
    await t.tap(find.text('Copy the words'));
    await t.pump();
    expect(clipboard, words24);
    await t.pump(const Duration(seconds: 61));
    await t.pump();
    expect(clipboard, isEmpty);
  });

  testWidgets('words screen: an iPhone recording the screen sees the words hidden', (t) async {
    final w = World();
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(() => screenCaptured.value = false);
    await t.pumpWidget(host(w, RecoveryPhraseScreen(words: words)));
    await t.tap(find.byType(DsMnemonicGrid));
    await t.pumpAndSettle();
    expect(t.widget<DsMnemonicGrid>(find.byType(DsMnemonicGrid)).revealed, isTrue);
    screenCaptured.value = true;
    await t.pumpAndSettle();
    expect(t.widget<DsMnemonicGrid>(find.byType(DsMnemonicGrid)).revealed, isFalse);
    // C-63 — nor does the sheet with the words open in the share sheet meanwhile.
    await t.ensureVisible(find.byKey(const ValueKey('words-sheet')));
    await t.tap(find.byKey(const ValueKey('words-sheet')));
    await t.pumpAndSettle();
    expect(w.shared, isEmpty, reason: 'not while the screen is being shown');
    screenCaptured.value = false;
    await t.pumpAndSettle();
    expect(t.widget<DsMnemonicGrid>(find.byType(DsMnemonicGrid)).revealed, isTrue);
  });

  testWidgets('Restore: paste from Passwords, or scan the sheet', (t) async {
    final w = World()..vault = FakeVault(stored: words24);
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(w, const RestoreScreen()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('restore-passwords')));
    await t.pumpAndSettle();
    expect(find.text(words24), findsOneWidget);

    // A QR that isn't the words is refused; the sheet's QR fills the box.
    // (secrets() treats 12 words as a valid phrase.)
    w.scanned = 'https://example.com';
    await t.tap(find.byKey(const ValueKey('restore-scan-sheet')));
    await t.pumpAndSettle();
    expect(find.text('This code isn’t a recovery sheet.'), findsOneWidget);
    const twelve = 'Abandon ability able about above absent absorb abstract absurd abuse access accident';
    w.scanned = twelve;
    await t.tap(find.byKey(const ValueKey('restore-scan-sheet')));
    await t.pumpAndSettle();
    expect(find.text(twelve.toLowerCase()), findsOneWidget);
  });

  test('the sheet renders: A4 PNG with the words and a QR', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final png = await renderRecoverySheet(
      words: words,
      l: lookupAppL10n(const Locale('ru')),
      name: 'Вера',
      server: 'chat.777400777.xyz',
      date: '18.10.2026',
    );
    expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(png.length, greaterThan(10000));
  });
}
