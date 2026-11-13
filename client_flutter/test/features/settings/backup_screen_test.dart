// ADR-073 — Settings → Chat backup: what the screen offers in each state
// (Android before "Sign in with Google", iCloud off, an older linked
// device) and the 24-words sheet that turns the backup on for the last.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/backup/backup_service.dart';
import 'package:sinhron/core/backup/cloud_store.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/settings/backup_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

class _Store implements SettingsStore {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class _Keys implements DeviceKeyStore {
  _Keys(this.value);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String deviceKey) async => value = deviceKey;
  @override
  Future<void> delete() async => value = null;
}

class _Drive extends DriveStore {
  _Drive(this.on);
  bool on;
  @override
  Future<bool> available() async => on;
}

class _Icloud extends IcloudStore {
  _Icloud(this.on);
  final bool on;
  @override
  Future<bool> available() async => on;
}

/// Only what the screen asks before a run: can this device back up, and
/// the 24 words turning it on.
class _Core implements BackupCore {
  _Core(this.canNow);
  bool canNow;
  final tried = <String>[];

  @override
  Future<bool> can(String secret) async => canNow;

  @override
  Future<String> unlock(String phrase, String secret) async {
    tried.add(phrase);
    throw Exception('other_words');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _ops = SecretOps(
  isValidPhrase: (p) => p.split(' ').length == 24,
  deviceKeyFor: (_) => throw UnimplementedError(),
  fingerprintFor: (_) => throw UnimplementedError(),
  storedFingerprint: () async => null,
  linkedBundleFor: (_, _) => throw UnimplementedError(),
);

Future<void> _pump(WidgetTester t, {required CloudStore store, required _Core core}) async {
  t.view.physicalSize = const Size(390, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        cloudStoreProvider.overrideWithValue(store),
        backupCoreProvider.overrideWithValue(core),
        deviceKeyStoreProvider.overrideWithValue(_Keys('sinhron-linked:v1:00')),
        settingsStoreProvider.overrideWithValue(_Store()),
        secretOpsProvider.overrideWithValue(_ops),
      ],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 900)),
          child: Localizations(
            locale: const Locale('en'),
            delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => const BackupScreen()),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

bool _enabled(WidgetTester t, String key) {
  final row = t.widget(find.byKey(ValueKey(key)));
  return (row as dynamic).onTap != null;
}

void main() {
  testWidgets('Android before "Sign in with Google": not connected, sign in, nothing to run yet', (t) async {
    await _pump(t, store: _Drive(false), core: _Core(true));
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-sign-in')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-sign-out')), findsNothing);
    expect(_enabled(t, 'backup-now'), isFalse);
    expect(_enabled(t, 'backup-restore'), isFalse);
  });

  testWidgets('signed in: Google Drive, back up now, restore, sign out', (t) async {
    await _pump(t, store: _Drive(true), core: _Core(true));
    expect(find.text('Google Drive'), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-sign-in')), findsNothing);
    expect(find.byKey(const ValueKey('backup-sign-out')), findsOneWidget);
    expect(find.text('Not yet'), findsOneWidget);
    expect(_enabled(t, 'backup-now'), isTrue);
    expect(_enabled(t, 'backup-restore'), isTrue);
  });

  testWidgets('iPhone with iCloud Drive off says where to turn it on', (t) async {
    await _pump(t, store: _Icloud(false), core: _Core(true));
    expect(find.byKey(const ValueKey('backup-icloud-off')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-sign-in')), findsNothing);
    expect(_enabled(t, 'backup-now'), isFalse);
  });

  testWidgets('an older linked device: "Turn on backup here" → the 24 words; other words are refused', (t) async {
    final core = _Core(false);
    await _pump(t, store: _Icloud(true), core: core);
    expect(find.text('iCloud'), findsOneWidget);
    expect(_enabled(t, 'backup-now'), isFalse, reason: 'no key yet');
    await t.tap(find.byKey(const ValueKey('backup-unlock')));
    await t.pumpAndSettle();
    expect(find.text('Turn on backup here'), findsOneWidget);

    final field = find.descendant(of: find.byKey(const ValueKey('backup-words-field')), matching: find.byType(EditableText));
    await t.enterText(field, 'too few words');
    await t.tap(find.byKey(const ValueKey('backup-words-go')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup-words-error')), findsOneWidget);
    expect(core.tried, isEmpty, reason: 'not 24 words: never sent on');

    await t.enterText(field, List.filled(24, 'abandon').join(' '));
    await t.tap(find.byKey(const ValueKey('backup-words-go')));
    await t.pumpAndSettle();
    expect(core.tried, hasLength(1));
    expect(find.text('These are another account’s words'), findsOneWidget);
    expect(find.text('Turn on backup here'), findsOneWidget, reason: 'the sheet stays for another try');
  });
}
