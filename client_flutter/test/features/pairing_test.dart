// QR pairing screens — tech-debt 4.2 / ADR-025.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/pairing.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/core/session.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/onboarding/pair_qr_screen.dart';
import 'package:sinhron/features/settings/add_device_screen.dart';

import '../core/session_test.dart' show FakeDb, FakeKeys, secrets;
import '../core/settings_providers_test.dart' show MemoryStore;
import 'app_lock/app_lock_test.dart' show FakeAuth;

final code = 'sinhron-pair:1:00112233445566778899aabbccddeeff:${'ab' * 32}';
/// A linked bundle starts with the account's identity key (ADR-027).
final secret = 'sinhron-linked:v1:${'c0ffee12' * 8}${'00' * 32}';

class FakePairing {
  final sent = <String>[];
  final waits = <String>[];
  var answers = <String?>[];
  String? scanned;
  var offers = 0;
  final offerSeeds = <String>[];
  Object? sendError;
  Object? waitError;

  PairingOps get ops => PairingOps(
    offer: (seed) async {
      offerSeeds.add(seed);
      return '$code#${++offers}';
    },
    wait: (base, secs) async {
      waits.add(base);
      final err = waitError;
      if (err != null) {
        waitError = null;
        throw err;
      }
      return answers.isEmpty ? Completer<String?>().future : answers.removeAt(0);
    },
    cancel: () {},
    isCode: (t) async => t.startsWith('sinhron-pair:1:'),
    send: (base, c) async {
      if (sendError != null) throw sendError!;
      sent.add('$base|$c');
    },
    sendWithPhrase: (base, c, phrase) async => sent.add('$base|$c|words'),
    scanQr: () async => scanned,
  );
}

class OnlineNet extends NetService {
  OnlineNet(super.ref);
  int syncs = 0;

  @override
  String? get httpBaseUrl => 'http://srv';

  @override
  String? get myIdentityHex => 'abcd1234' * 8;

  @override
  Future<void> syncDevices({List<String>? groupIdsHex}) async => syncs++;
}

void main() {
  setUp(() => DsHaptics.enabled = false);

  late FakeKeys keys;
  late FakeKeys seeds;
  late List<String> connected;
  late FakePairing pairing;
  late FakeAuth auth;

  Future<void> pump(WidgetTester t, Widget child) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          bootDiagnosticsProvider.overrideWithValue(
            const BootDiagnostics(coreVersion: 't', dbPath: 'db', mlsDbPath: '', mlsDbBytes: -1),
          ),
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          hapticsProvider.overrideWithValue(Haptics(() => false)),
          deviceKeyStoreProvider.overrideWithValue(keys),
          deviceSeedStoreProvider.overrideWithValue(seeds),
          storageOpsProvider.overrideWithValue((FakeDb()..exists = true).ops),
          secretOpsProvider.overrideWithValue(secrets()),
          connectorProvider.overrideWithValue((s, url) async => connected.add(s)),
          identityProvider.overrideWith((ref) async => null),
          pairingOpsProvider.overrideWithValue(pairing.ops),
          netServiceProvider.overrideWith(OnlineNet.new),
          appAuthenticatorProvider.overrideWithValue(auth),
        ],
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  setUp(() {
    keys = FakeKeys();
    seeds = FakeKeys();
    connected = [];
    pairing = FakePairing();
    auth = FakeAuth();
  });

  testWidgets('new device: shows a QR, makes a new one when it expires, signs in with what arrives', (t) async {
    var done = 0;
    pairing.answers = [null, secret];
    await pump(t, PairQrScreen(onDone: () => done++, serverUrl: 'ws://srv:8080/v1/sync'));
    await t.pumpAndSettle();
    expect(find.textContaining('c0ff ee12 c0ff ee12'), findsOneWidget, reason: 'whose account answered');
    expect(keys.value, isNull, reason: 'nothing kept before "Sign in"');
    await t.tap(find.text('Sign in'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pair-qr-screen')), findsOneWidget);
    expect(pairing.offers, 2, reason: 'the first code expired unanswered');
    expect(pairing.waits, ['http://srv:8080', 'http://srv:8080']);
    expect(keys.value, secret, reason: 'signed in with the handed-over bundle (no identity key)');
    expect(pairing.offerSeeds.toSet(), hasLength(1), reason: 'one device key across fresh codes');
    expect(seeds.value, pairing.offerSeeds.first, reason: 'the key the certificate was made for');
    expect(connected, [secret]);
    expect(done, 1);
  });

  testWidgets('storage-devices:13 — an answer from a stranger\'s account: Cancel keeps nothing, a new code', (t) async {
    var done = 0;
    pairing.answers = [secret];
    await pump(t, PairQrScreen(onDone: () => done++, serverUrl: 'ws://srv:8080/v1/sync'));
    await t.pumpAndSettle();
    expect(find.textContaining('c0ff ee12 c0ff ee12'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(keys.value, isNull, reason: 'not signed in');
    expect(seeds.value, isNull);
    expect(connected, isEmpty);
    expect(done, 0);
    expect(pairing.offers, 2, reason: 'a fresh code to try again');
  });

  testWidgets('existing device: rejects a non-code, then confirms and sends', (t) async {
    await pump(t, const AddDeviceScreen());
    await t.enterText(find.byKey(const ValueKey('add-device-code')), 'hello');
    await t.tap(find.byKey(const ValueKey('add-device-add')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('add-device-error')), findsOneWidget);
    expect(pairing.sent, isEmpty);

    await t.enterText(find.byKey(const ValueKey('add-device-code')), code);
    await t.tap(find.byKey(const ValueKey('add-device-add')));
    await t.pumpAndSettle();
    expect(find.textContaining('abcd 1234 abcd 1234'), findsOneWidget, reason: 'my address, to compare on the new device');
    await t.tap(find.text('Give access'));
    await t.pumpAndSettle();
    expect(auth.asked, 1, reason: 'Face ID / passcode first');
    expect(pairing.sent, ['http://srv|$code']);
    expect(find.byKey(const ValueKey('add-device-done')), findsOneWidget);
    await t.pump(const Duration(seconds: 21)); // the delayed device sync
  });

  // Audit storage-devices:3 — 30 s with the open phone linked a stranger's device.
  testWidgets('someone holding the phone: no Face ID / passcode → no device is linked', (t) async {
    auth.ok = false;
    await pump(t, const AddDeviceScreen());
    await t.enterText(find.byKey(const ValueKey('add-device-code')), code);
    await t.tap(find.byKey(const ValueKey('add-device-add')));
    await t.pumpAndSettle();
    await t.tap(find.text('Give access'));
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(pairing.sent, isEmpty);
    expect(find.byKey(const ValueKey('add-device-done')), findsNothing);
  });

  testWidgets('no passcode on the phone at all: nothing to ask, linking goes ahead', (t) async {
    auth
      ..ok = false
      ..supported = false;
    await pump(t, const AddDeviceScreen());
    await t.enterText(find.byKey(const ValueKey('add-device-code')), code);
    await t.tap(find.byKey(const ValueKey('add-device-add')));
    await t.pumpAndSettle();
    await t.tap(find.text('Give access'));
    await t.pumpAndSettle();
    expect(pairing.sent, ['http://srv|$code']);
    await t.pump(const Duration(seconds: 21)); // the delayed device sync
  });

  testWidgets('a device without the account key adds devices with the 24 words (ADR-027)', (t) async {
    pairing.sendError = 'no account key on this device';
    await pump(t, const AddDeviceScreen());
    await t.enterText(find.byKey(const ValueKey('add-device-code')), code);
    await t.tap(find.byKey(const ValueKey('add-device-add')));
    await t.pumpAndSettle();
    await t.tap(find.text('Give access'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('phrase-prompt')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('phrase-prompt-field')), 'a b c d e f g h i j k l');
    await t.tap(find.byKey(const ValueKey('phrase-prompt-confirm')));
    await t.pumpAndSettle();
    expect(pairing.sent, ['http://srv|$code|words']);
    expect(find.byKey(const ValueKey('add-device-done')), findsOneWidget);
    await t.pump(const Duration(seconds: 21));
  });

  // storage-devices:13 follow-up — someone else answered the QR first; the
  // server says 409 "already used" and the owner's phone must warn him,
  // not show "Couldn't send it, check the connection".
  testWidgets('existing device: a code someone else already used shows the warning', (t) async {
    pairing.sendError = 'server 409: {"error":"already used"}';
    await pump(t, const AddDeviceScreen());
    await t.enterText(find.byKey(const ValueKey('add-device-code')), code);
    await t.tap(find.byKey(const ValueKey('add-device-add')));
    await t.pumpAndSettle();
    await t.tap(find.text('Give access'));
    await t.pumpAndSettle();
    expect(
      find.text("This code was already used by another device. If that wasn't you, don't confirm anything."),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('add-device-done')), findsNothing);
  });

  testWidgets('new device: a code someone else took is replaced, with a clear note', (t) async {
    pairing.waitError = 'server 409: {"error":"already used"}';
    await pump(t, PairQrScreen(serverUrl: 'ws://srv:8080/v1/sync'));
    await t.pump();
    await t.pump();
    expect(find.text('Another device took this code. Here is a new one — show it only to your own device.'), findsOneWidget);
    await t.pump(const Duration(seconds: 4));
    expect(pairing.offers, 2, reason: 'a fresh code after the taken one');
    expect(connected, isEmpty);
  });

  testWidgets('existing device: a scanned QR goes straight to the confirmation', (t) async {
    pairing.scanned = code;
    await pump(t, const AddDeviceScreen());
    await t.tap(find.byKey(const ValueKey('add-device-scan')));
    await t.pumpAndSettle();
    expect(find.text('Give access'), findsOneWidget);
  });
}
