// Settings → Devices with real data — ADR-025.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/device_providers.dart';
import 'package:sinhron/core/providers/device_transfer.dart';
import 'package:sinhron/core/providers/saved_messages.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/settings/linked_devices_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../core/device_transfer_test.dart' show FakeBackend;
import '../core/session_test.dart' show secrets;
import '../core/settings_providers_test.dart' show MemoryStore;
import 'app_lock/app_lock_test.dart' show FakeAuth;

class FakeNet extends NetService {
  FakeNet(super.ref, this.devices);

  List<core.LinkedDevice> devices;
  final revoked = <String>[];
  bool offline = false;
  bool primary = true;

  @override
  Future<bool> hasAccountKey() async => primary;

  @override
  Future<List<core.LinkedDevice>> listDevices() async {
    if (offline) throw StateError('not connected to a server');
    return devices;
  }

  @override
  Future<void> revokeDevice(String devicePkHex, {String? phrase}) async {
    revoked.add(phrase == null ? devicePkHex : '$devicePkHex+phrase');
    devices = devices.where((d) => d.devicePkHex != devicePkHex).toList();
  }
}

class FakeSaved extends SavedMessages {
  FakeSaved(super.ref);
  int ensured = 0;
  @override
  Future<String> ensure() async {
    ensured++;
    return 'saved';
  }
}

core.LinkedDevice dev(String pk, {bool primary = false, bool me = false}) =>
    core.LinkedDevice(
      devicePkHex: pk,
      isPrimary: primary,
      isThisDevice: me,
      registeredAtUnix: 1760000000,
      lastSeenUnix: 1760086400,
    );

void main() {
  setUp(() => DsHaptics.enabled = false);

  Future<FakeNet> pump(
    WidgetTester t,
    List<core.LinkedDevice> devices, {
    bool offline = false,
    bool primary = true,
    FakeBackend? transfers,
    MemoryStore? settings,
    FakeAuth? auth,
  }) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    late FakeNet net;
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(settings ?? MemoryStore()),
          appAuthenticatorProvider.overrideWithValue(auth ?? FakeAuth()),
          hapticsProvider.overrideWithValue(Haptics(() => false)),
          secretOpsProvider.overrideWithValue(secrets()),
          deviceTransferBackendProvider.overrideWithValue(transfers ?? FakeBackend([])),
          transferBaseUrlProvider.overrideWithValue(() => null),
          savedMessagesProvider.overrideWith((ref) => FakeSaved(ref)),
          netServiceProvider.overrideWith(
            (ref) => net = FakeNet(ref, devices)
              ..offline = offline
              ..primary = primary,
          ),
        ],
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const LinkedDevicesScreen()),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return net;
  }

  testWidgets('this device and the others come from the server; Remove asks, then revokes', (t) async {
    final net = await pump(t, [dev('aa' * 32, primary: true), dev('bb' * 32, me: true)]);
    expect(find.text('This device'), findsWidgets);
    expect(find.textContaining('Another device'), findsOneWidget);
    expect(find.textContaining('first device'), findsOneWidget);
    expect(find.textContaining('seen 10.10.2025'), findsOneWidget, reason: 'when the server last heard from it');

    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove device'));
    await t.pumpAndSettle();
    expect(net.revoked, ['aa' * 32]);
    expect(find.textContaining('Another device'), findsNothing);
  });

  // Audit DEV-7 — removing a device is the owner's call, like linking one.
  testWidgets('Remove / Remove all: nothing is revoked until Face ID / passcode passes', (t) async {
    final auth = FakeAuth()..ok = false;
    final net = await pump(t, [dev('aa' * 32, primary: true), dev('bb' * 32, me: true)], auth: auth);
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove device'));
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(net.revoked, isEmpty);
    expect(find.textContaining('Another device'), findsOneWidget);

    auth.ok = true;
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove device'));
    await t.pumpAndSettle();
    expect(net.revoked, ['aa' * 32]);
  });

  // Owner, 2026-11-01 — the list showed a code ("Device aaaaaaaa"), not
  // a name: each device names itself, my other devices show it.
  testWidgets('devices show the name they gave themselves', (t) async {
    final settings = MemoryStore()
      ..map[deviceNameKey('aa' * 32)] = 'iPad Air'
      ..map[deviceNameKey('bb' * 32)] = 'iPhone 16 Pro';
    await pump(t, [dev('aa' * 32, primary: true), dev('bb' * 32, me: true), dev('cc' * 32)], settings: settings);
    expect(find.text('iPad Air'), findsOneWidget);
    expect(find.text('iPhone 16 Pro'), findsOneWidget);
    expect(find.text('Another device'), findsOneWidget, reason: 'an older build that has not named itself');
  });

  test('a device writes its own name under its key once a run, only when it changed', () async {
    resetDeviceNameAnnounced();
    final c = ProviderContainer(
      overrides: [
        netServiceProvider.overrideWith((ref) => FakeNet(ref, [dev('aa' * 32, primary: true), dev('bb' * 32, me: true)])),
      ],
    );
    addTearDown(c.dispose);
    final net = c.read(netServiceProvider);
    final settings = MemoryStore();
    await announceDeviceName(net, settings, name: () async => 'iPad Air');
    expect(settings.map, {deviceNameKey('bb' * 32): 'iPad Air'});
    settings.map.clear();
    await announceDeviceName(net, settings, name: () async => 'iPad Air');
    expect(settings.map, isEmpty, reason: 'once a run');
  });

  testWidgets('a device without the account key revokes with the 24 words (ADR-027)', (t) async {
    final net = await pump(t, [dev('aa' * 32, primary: true), dev('bb' * 32, me: true)], primary: false);
    expect(find.textContaining('asks for your 24 secret words'), findsOneWidget);
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove device'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('phrase-prompt')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('phrase-prompt-field')), 'not words');
    await t.tap(find.byKey(const ValueKey('phrase-prompt-confirm')));
    await t.pumpAndSettle();
    expect(net.revoked, isEmpty, reason: 'invalid phrase → still asking');
    await t.enterText(find.byKey(const ValueKey('phrase-prompt-field')), 'a b c d e f g h i j k l');
    await t.tap(find.byKey(const ValueKey('phrase-prompt-confirm')));
    await t.pumpAndSettle();
    expect(net.revoked, ['${'aa' * 32}+phrase']);
  });

  testWidgets('offline: says so instead of showing made-up devices', (t) async {
    await pump(t, const [], offline: true);
    expect(find.textContaining('no connection to the server'), findsOneWidget);
    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('tapping another device offers to send it everything (ADR-064)', (t) async {
    final transfers = FakeBackend([]);
    await pump(t, [dev('aa' * 32, primary: true), dev('bb' * 32, me: true)], transfers: transfers);
    expect(find.textContaining('Your devices stay in step'), findsOneWidget);
    await t.tap(find.byKey(ValueKey('device-row-${'aa' * 32}')));
    await t.pumpAndSettle();
    await t.tap(find.text('Send everything to this device'));
    await t.pumpAndSettle();
    expect(transfers.started, ['aa' * 32]);
  });
}
