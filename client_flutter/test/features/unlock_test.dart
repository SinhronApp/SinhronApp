// Unlock screen, launch routing and Settings → Reconnect — ADR-021
// (tech-debt 2.16 / 2.4).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/navigation.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/features/onboarding/restore_screen.dart';
import 'package:sinhron/features/settings/settings_screen.dart';
import 'package:sinhron/features/unlock/device_removed_screen.dart';
import 'package:sinhron/features/unlock/unlock_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../core/chat_actions_test.dart' show FakeChatStore;
import '../core/session_test.dart' show FakeDb, FakeKeys, good, other, secrets;
import '../core/settings_providers_test.dart' show MemoryStore;

/// A Keychain that fails to save — not the words' fault.
class _BrokenKeys extends FakeKeys {
  @override
  Future<void> write(String deviceKey) async => throw StateError('keychain');
}

const me = core.StoredIdentitySummary(fingerprint: 'fp', ed25519PubHex: 'ed', x25519PubHex: 'x', createdAtUnix: 0);

void main() {
  setUp(() => DsHaptics.enabled = false);

  late FakeDb db;
  late FakeKeys keys;
  late FakeKeys seeds;
  late List<String> connected;

  Future<ProviderContainer> pump(
    WidgetTester t,
    Widget child, {
    bool locked = false,
    core.StoredIdentitySummary? identity,
    String? storedFor,
    Size size = const Size(390, 844),
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    connected = [];
    final c = ProviderContainer(
      overrides: [
        bootDiagnosticsProvider.overrideWithValue(
          BootDiagnostics(coreVersion: 't', dbPath: 'db', mlsDbPath: '', mlsDbBytes: -1, storageLocked: locked),
        ),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        deviceKeyStoreProvider.overrideWithValue(keys),
        deviceSeedStoreProvider.overrideWithValue(seeds),
        storageOpsProvider.overrideWithValue(db.ops),
        secretOpsProvider.overrideWithValue(secrets(storedFor: storedFor)),
        connectorProvider.overrideWithValue((secret, url) async => connected.add(secret)),
        syncShutdownProvider.overrideWithValue(() async {}),
        identityProvider.overrideWith((ref) async => identity),
        chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
        chatStoreProvider.overrideWithValue(FakeChatStore()),
        hapticsProvider.overrideWithValue(Haptics(() => false)),
      ],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: MediaQueryData(size: size),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return c;
  }

  setUp(() {
    db = FakeDb()..exists = true;
    keys = FakeKeys();
    seeds = FakeKeys();
  });

  group('sign in to an existing account (ADR-025)', () {
    testWidgets('a bad phrase shows an error and stores nothing; a good one links this phone', (t) async {
      var done = 0;
      await pump(t, RestoreScreen(onDone: () => done++));
      expect(find.byKey(const ValueKey('restore-screen')), findsOneWidget);

      await t.enterText(find.byKey(const ValueKey('restore-phrase')), 'hello world');
      await t.tap(find.byKey(const ValueKey('restore-button')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('restore-error')), findsOneWidget);
      expect(seeds.value, isNull);
      expect(connected, isEmpty);

      await t.enterText(find.byKey(const ValueKey('restore-phrase')), good);
      await t.tap(find.byKey(const ValueKey('restore-button')));
      await t.pumpAndSettle();
      expect(seeds.value, hasLength(64), reason: 'its own device key');
      final bundle = 'sinhron-linked:v1:[$good|${seeds.value}]';
      expect(keys.value, bundle, reason: 'the identity key is not kept here (ADR-027)');
      expect(connected, [bundle]);
      expect(done, 1);
    });
  });

  group('launch routing (AppRoot)', () {
    testWidgets('locked DB → unlock screen', (t) async {
      db.sealedWith = 'k(dk[$good])';
      await pump(t, const AppRoot(), locked: true, identity: me);
      expect(find.byType(UnlockScreen), findsOneWidget);
      expect(find.text('Unlock Sinhron'), findsOneWidget);
    });

    testWidgets('signed in + device key → chats, connected with the key (no onboarding)', (t) async {
      keys.value = 'dk';
      await pump(t, const AppRoot(), identity: me);
      expect(find.byType(ChatListScreen), findsOneWidget);
      expect(connected, ['dk']);
    });

    testWidgets('an iPad (ADR-076): the chats on the left, "Choose a chat" on the right', (t) async {
      keys.value = 'dk';
      await pump(t, const AppRoot(), identity: me, size: const Size(1024, 1366));
      expect(t.getRect(find.byType(ChatListScreen)).width, 320);
      expect(find.byKey(const ValueKey('split-placeholder')), findsOneWidget);
    });

    // Owner, 2026-11-01 — a device removed from another one kept showing
    // the chats and "Connecting…"; now it says so and signs out.
    testWidgets('removed from another device → "signed out", Sign out erases this copy', (t) async {
      keys.value = 'dk';
      final c = await pump(t, const AppRoot(), identity: me);
      expect(find.byType(ChatListScreen), findsOneWidget);
      c.read(deviceRemovedProvider.notifier).set(true);
      await t.pumpAndSettle();
      expect(find.byType(DeviceRemovedScreen), findsOneWidget);
      expect(find.text('This device is signed out'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('device-removed-sign-out')));
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(db.erased, isTrue, reason: 'chats, MLS state and keys go; Session then clears the flag');
      expect(keys.value, isNull);
    });

    test('only the server saying "device disconnected" means removed', () {
      expect(isDeviceRemovedReason('auth rejected (code 403): device disconnected'), isTrue);
      expect(isDeviceRemovedReason('auth rejected (code 403): identity not registered'), isFalse);
      expect(isDeviceRemovedReason('connect timeout after 15000 ms'), isFalse);
      expect(isDeviceRemovedReason(null), isFalse);
    });

    testWidgets('signed in, no device key → reconnect with the phrase, not a new account', (t) async {
      await pump(t, const AppRoot(), identity: me);
      expect(find.byType(UnlockScreen), findsOneWidget);
      expect(find.text('Reconnect your account'), findsOneWidget);
    });
  });

  group('UnlockScreen', () {
    testWidgets('wrong phrase shows an error; the right one unlocks and connects', (t) async {
      db.sealedWith = 'k(dk[$good])';
      final c = await pump(t, const UnlockScreen(locked: true), locked: true);
      await t.enterText(find.byType(EditableText), other);
      await t.tap(find.byKey(const ValueKey('unlock-button')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('unlock-error')), findsOneWidget);
      expect(find.text('These words don’t match the account on this phone.'), findsOneWidget);
      expect(keys.value, isNull);

      await t.enterText(find.byType(EditableText), good);
      await t.tap(find.byKey(const ValueKey('unlock-button')));
      await t.pumpAndSettle();
      expect(keys.value, 'dk[$good]');
      expect(c.read(storageLockedProvider), isFalse);
      expect(connected, ['dk[$good]']);
    });

    // Owner audit, 2026-11-02 — any failure read "these words don't
    // match", which sent people with the right words to "Erase".
    testWidgets('a failure that is not the words is not called "wrong words"', (t) async {
      db.sealedWith = 'k(dk[$good])';
      keys = _BrokenKeys();
      await pump(t, const UnlockScreen(locked: true), locked: true);
      await t.enterText(find.byType(EditableText), good);
      await t.tap(find.byKey(const ValueKey('unlock-button')));
      await t.pumpAndSettle();
      expect(find.text('These words don’t match the account on this phone.'), findsNothing);
      expect(find.textContaining('not because of the words'), findsOneWidget);
    });

    testWidgets('erase asks first, then erases', (t) async {
      db.sealedWith = 'k(x)';
      await pump(t, const UnlockScreen(locked: true), locked: true);
      await t.tap(find.byKey(const ValueKey('unlock-erase')));
      await t.pumpAndSettle();
      expect(db.erased, isFalse, reason: 'nothing happens before the confirmation');
      await t.tap(find.text('Erase everything'));
      await t.pumpAndSettle();
      expect(db.erased, isTrue);
    });
  });

  testWidgets('Settings → Reconnect: shows the live state and reconnects with the key', (t) async {
    keys.value = 'dk';
    final c = await pump(t, const SettingsScreen());
    final row = find.byKey(const ValueKey('settings-reconnect'));
    await t.scrollUntilVisible(row, 200, scrollable: find.byType(Scrollable).first);
    // Clear the floating tab bar at the bottom.
    await t.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await t.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    await t.tap(row);
    await t.pumpAndSettle();
    expect(connected, ['dk']);

    c.read(netStatusProvider.notifier).set(NetStatus.connected);
    await t.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
  });
}
