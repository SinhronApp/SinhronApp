// ADR-032 — onboarding's server step: typed or scanned, checked, saved.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/qr_scan.dart';
import 'package:sinhron/core/server_address.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/onboarding/profile_screen.dart';
import 'package:sinhron/features/onboarding/server_invite_screen.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

void main() {
  late MemoryStore store;
  late int continued;
  late List<Uri> asked;
  late (int, String)? Function(Uri) reply;
  String? scanned;

  Future<void> pump(WidgetTester t, {String? initial}) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          qrScannerProvider.overrideWithValue(() async => scanned),
          serverHttpGetProvider.overrideWithValue((u) async {
            asked.add(u);
            final r = reply(u);
            if (r == null) throw StateError('no route to host');
            return r;
          }),
        ],
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder(
                  pageBuilder: (_, _, _) => ServerInviteScreen(initialServer: initial, onContinue: () => continued++),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  setUp(() {
    store = MemoryStore();
    continued = 0;
    asked = [];
    scanned = null;
    reply = (_) => (200, '{"status":"ok","service":"sinhron-server"}');
  });

  testWidgets('a typed address is checked, saved and goes on', (t) async {
    await pump(t);
    await t.enterText(find.byKey(const ValueKey('server-field')), 'sinhron.example.com');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('server-continue')));
    await t.pumpAndSettle();
    expect(asked.single.toString(), 'https://sinhron.example.com/_healthz');
    expect(store.map['server_url'], 'wss://sinhron.example.com/v1/sync');
    expect(continued, 1);
  });

  testWidgets('nothing to go on with an empty field; nonsense is refused before any request', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('server-continue')));
    await t.pumpAndSettle();
    expect(continued, 0);
    await t.enterText(find.byKey(const ValueKey('server-field')), 'not a server');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('server-continue')));
    await t.pumpAndSettle();
    expect(find.textContaining('doesn’t look like a server address'), findsOneWidget);
    expect(asked, isEmpty);
    expect(store.map.containsKey('server_url'), isFalse);
  });

  testWidgets('not a Sinhron server: no way on', (t) async {
    reply = (_) => (200, '<html></html>');
    await pump(t, initial: 'example.com');
    await t.tap(find.byKey(const ValueKey('server-continue')));
    await t.pumpAndSettle();
    expect(find.textContaining('isn’t a Sinhron server'), findsOneWidget);
    expect(find.byKey(const ValueKey('server-anyway')), findsNothing);
    expect(continued, 0);
  });

  testWidgets('no answer: says so, and lets the person go on anyway', (t) async {
    reply = (_) => null;
    await pump(t, initial: 'sinhron.example.com');
    await t.tap(find.byKey(const ValueKey('server-continue')));
    await t.pumpAndSettle();
    expect(find.textContaining('isn’t answering'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('server-anyway')));
    await t.pumpAndSettle();
    expect(store.map['server_url'], 'wss://sinhron.example.com/v1/sync');
    expect(continued, 1);
  });

  testWidgets('scanning the installer QR fills, checks and goes on', (t) async {
    scanned = '$kServerQrPrefix https://sinhron.example.com';
    await pump(t);
    await t.tap(find.byKey(const ValueKey('server-scan')));
    await t.pumpAndSettle();
    expect(store.map['server_url'], 'wss://sinhron.example.com/v1/sync');
    expect(continued, 1);

    scanned = 'sinhron-pair:2:a:b:c'; // the wrong QR
    await t.tap(find.byKey(const ValueKey('server-scan')));
    await t.pumpAndSettle();
    expect(find.textContaining('doesn’t look like a server address'), findsOneWidget);
    expect(continued, 1);
  });

  // Audit 07-app-input L02 — a scanned QR must not pick a server without TLS.
  testWidgets('a scanned http:// / ws:// QR is refused: nothing asked, nothing saved', (t) async {
    await pump(t);
    for (final qr in ['${kServerQrPrefix}http://evil.example', 'http://evil.example', 'ws://evil.example/v1/sync']) {
      scanned = qr;
      await t.tap(find.byKey(const ValueKey('server-scan')));
      await t.pumpAndSettle();
      expect(asked, isEmpty, reason: qr);
      expect(store.map['server_url'], isNull, reason: qr);
      expect(continued, 0, reason: qr);
    }
    expect(find.textContaining('doesn’t look like a server address'), findsOneWidget);
  });

  testWidgets('the profile step hands over the typed name before going on', (t) async {
    String? saved;
    var next = 0;
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder(
                pageBuilder: (_, _, _) => ProfileScreen(onName: (n) async => saved = n, onContinue: () => next++),
              ),
            ),
          ),
        ),
      ),
    );
    await t.enterText(find.byType(EditableText).first, '  Вера  ');
    await t.pump();
    await t.tap(find.text('Continue'));
    await t.pumpAndSettle();
    expect(saved, 'Вера');
    expect(next, 1);
  });

  // Owner, 2026-10-15: "can't paste the server address — no context menu".
  testWidgets('long-press on the server field offers Paste (iOS)', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.hasStrings') return {'value': true};
      if (call.method == 'Clipboard.getData') return {'text': 'chat.example.com'};
      return null;
    });
    await pump(t);
    await t.longPress(find.byType(EditableText));
    await t.pumpAndSettle();
    final shown = find.text('Paste').evaluate().isNotEmpty;
    debugDefaultTargetPlatformOverride = null;
    expect(shown, isTrue);
  });

  // A broken boot left the database closed: Continue did nothing at all.
  testWidgets('storage not open: Continue says so instead of doing nothing', (t) async {
    store = _BrokenStore();
    await pump(t);
    await t.enterText(find.byKey(const ValueKey('server-field')), 'sinhron.example.com');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('server-continue')));
    await t.pumpAndSettle();
    expect(continued, 0);
    expect(find.textContaining('storage didn’t open'), findsOneWidget);
  });
}

class _BrokenStore extends MemoryStore {
  @override
  Future<void> set(String key, String value) async => throw StateError('not initialized — call open() first');
}
