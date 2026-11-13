import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/qr_scan.dart';
import 'package:sinhron/features/verify/verify_contact.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/settings_providers_test.dart' show MemoryStore;

const chat = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const number = '12345 67890 11111 22222 33333 44444 55555 66666 77777 88888 99999 00000';

void main() {
  late MemoryStore store;
  var peer = 'bb' * 32;
  String? scanned;

  Widget host() => ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          qrScannerProvider.overrideWithValue(() async => scanned),
          safetyInfoLoaderProvider.overrideWithValue(
            (_) async => core.SafetyInfo(myKeyHex: 'aa' * 32, peerKeyHex: peer, number: number),
          ),
        ],
        child: const DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: MediaQueryData(size: Size(390, 1200)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: VerifyContactScreen(chatId: chat, contactName: 'Maria'),
            ),
          ),
        ),
      );

  setUp(() {
    store = MemoryStore();
    peer = 'bb' * 32;
    scanned = null;
  });

  testWidgets('shows the number, marks verified pinned to their key', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('verify-status-unverified')), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
    expect(find.text('00000'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('verify-mark')));
    await t.pumpAndSettle();
    expect(store.map['verified:$chat'], peer);
    expect(find.byKey(const ValueKey('verify-status-verified')), findsOneWidget);
    // Owner, 2026-11-03: a check icon in the badge, not a ✓ character.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('verify-status-verified')),
        matching: find.byIcon(CupertinoIcons.checkmark_alt),
      ),
      findsOneWidget,
    );
    expect(find.text('✓'), findsNothing);

    await t.tap(find.byKey(const ValueKey('verify-toggle-view')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('safety-qr')), findsOneWidget);
  });

  testWidgets('a changed key drops the verification and warns', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    store.map['verified:$chat'] = 'cc' * 32; // verified an older key
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('verify-status-changed')), findsOneWidget);
    expect(find.text('Check number changed'), findsOneWidget);
  });

  testWidgets('scanning their QR verifies on a match and warns otherwise', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host());
    await t.pumpAndSettle();

    // Cancelled scan: nothing happens.
    await t.tap(find.byKey(const ValueKey('verify-scan')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('verify-scan-match')), findsNothing);

    scanned = 'https://example.com';
    await t.tap(find.byKey(const ValueKey('verify-scan')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('verify-scan-notSafetyCode')), findsOneWidget);

    scanned = 'sinhron-verify:1:${'cc' * 32}:${'aa' * 32}'; // someone else's key
    await t.tap(find.byKey(const ValueKey('verify-scan')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('verify-scan-mismatch')), findsOneWidget);
    expect(store.map['verified:$chat'], isNull);

    scanned = 'sinhron-verify:1:$peer:${'aa' * 32}'; // their screen: their key, then mine
    await t.tap(find.byKey(const ValueKey('verify-scan')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('verify-scan-match')), findsOneWidget);
    expect(store.map['verified:$chat'], peer);
    expect(find.byKey(const ValueKey('verify-status-verified')), findsOneWidget);
  });

  test('a scan matches only the same pair seen from the other side', () {
    const mine = core.SafetyInfo(myKeyHex: 'aa', peerKeyHex: 'bb', number: number);
    expect(checkScannedVerify('sinhron-verify:1:bb:aa', mine), ScanMatch.match);
    expect(checkScannedVerify(' sinhron-verify:1:BB:AA\n', mine), ScanMatch.match);
    expect(checkScannedVerify('sinhron-verify:1:aa:bb', mine), ScanMatch.mismatch, reason: 'my own QR');
    expect(checkScannedVerify('sinhron-verify:2:bb:aa', mine), ScanMatch.notSafetyCode);
    expect(checkScannedVerify('sinhron-pair:2:x:y:z', mine), ScanMatch.notSafetyCode);
  });

  test('QR payload carries both keys', () {
    final p = verifyQrPayload(const core.SafetyInfo(myKeyHex: 'aa', peerKeyHex: 'bb', number: number));
    expect(p, 'sinhron-verify:1:aa:bb');
  });
}
