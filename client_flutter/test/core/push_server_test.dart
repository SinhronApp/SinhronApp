// ADR-040 — the server names its push host; Settings tells the person what
// to set in ntfy (it starts on ntfy.sh, which our server refuses).

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/core/push_server.dart';
import 'package:sinhron/core/call_reach.dart';
import 'package:sinhron/core/server_address.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/settings/notifications_screen.dart';

import 'push_test.dart' show FakePushPlatform;
import 'settings_providers_test.dart' show MemoryStore;

class _Net extends NetService {
  _Net(super.ref);
  @override
  String? get httpBaseUrl => 'https://srv';
}

void main() {
  test('the push hosts come from /v1/push/info', () {
    expect(parsePushHosts(200, '{"unifiedpush_hosts":["Push.Example.org"," "]}'), ['push.example.org']);
    expect(parsePushHosts(200, '{"unifiedpush_hosts":[]}'), isEmpty);
    // An older server: no such endpoint, or not our JSON.
    expect(parsePushHosts(404, ''), isNull);
    expect(parsePushHosts(200, '<html>'), isNull);
    expect(parsePushHosts(200, '{"x":1}'), isNull);
  });

  test('the server is asked at its own address', () async {
    final asked = <Uri>[];
    final c = ProviderContainer(
      overrides: [
        netServiceProvider.overrideWith((ref) => _Net(ref)),
        serverHttpGetProvider.overrideWithValue((u) async {
          asked.add(u);
          return (200, '{"unifiedpush_hosts":["push.example.org"]}');
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(pushHostsProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await c.read(pushHostsProvider.future), ['push.example.org']);
    expect(asked, [Uri.parse('https://srv/v1/push/info')]);
  });

  test('what to tell the person', () {
    const hosts = ['push.example.org'];
    NtfyHint? hint(String status, String? endpoint, [List<String>? h = hosts]) =>
        ntfyHintFor(status: status, hosts: h, endpoint: endpoint);
    expect(hint('noDistributor', null), const NtfyHint(NtfyStep.install, host: 'push.example.org'));
    expect(hint('authorized', null), const NtfyHint(NtfyStep.setServer, host: 'push.example.org'));
    expect(
      hint('authorized', 'https://ntfy.sh/upAbC?up=1'),
      const NtfyHint(NtfyStep.otherServer, host: 'push.example.org', otherHost: 'ntfy.sh'),
    );
    expect(hint('authorized', 'https://PUSH.example.org/upAbC?up=1'), isNull, reason: 'push works');
    expect(hint('authorized', null, []), const NtfyHint(NtfyStep.serverHasNone));
    expect(hint('authorized', null, null), isNull, reason: 'server unknown (offline)');
    expect(hint('denied', null), isNull, reason: 'notifications refused: that footer says so');
    expect(const NtfyHint(NtfyStep.install, host: 'push.example.org').serverUrl, 'https://push.example.org');
  });

  group('Settings → Sounds & vibration on Android', () {
    late FakePushPlatform platform;

    Future<ProviderContainer> open(WidgetTester t, {required String state, String? endpoint, List<String>? hosts}) async {
      platform = FakePushPlatform()
        ..state = state
        ..lastVoip = endpoint == null ? null : (endpoint, false);
      final c = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          netServiceProvider.overrideWith((ref) => _Net(ref)),
          pushPlatformProvider.overrideWithValue(platform),
          isAndroidProvider.overrideWithValue(true),
          pushHostsProvider.overrideWith((ref) async => hosts ?? ['push.example.org']),
          batteryPlatformProvider.overrideWithValue(const _Battery()),
        ],
      );
      addTearDown(c.dispose);
      t.view.physicalSize = const Size(390, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: const MediaQuery(
              data: MediaQueryData(size: Size(390, 1800)),
              child: Directionality(textDirection: TextDirection.ltr, child: NotificationsScreen()),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      return c;
    }

    // ADR-057 — the verdict comes first, in plain words.
    testWidgets('Google push: "Calls will reach you: yes", no ntfy steps', (t) async {
      await open(t, state: 'authorized', endpoint: 'fcm:cAbC:APA91b');
      expect(find.text('Calls will reach you: yes'), findsOneWidget);
      expect(find.textContaining('Google only sees that something came'), findsOneWidget);
      expect(find.byKey(const ValueKey('ntfy-copy')), findsNothing);
    });

    testWidgets('nothing wakes the phone: "not yet — what to do" with the button', (t) async {
      await open(t, state: 'noDistributor');
      expect(find.text('Calls will reach you: not yet — what to do'), findsOneWidget);
      expect(find.byKey(const ValueKey('reach-fix-turnOnAlwaysConnected')), findsOneWidget);
    });

    testWidgets('no ntfy: install it and add our server', (t) async {
      await open(t, state: 'noDistributor');
      expect(find.textContaining('Install ntfy from Google Play or F-Droid'), findsOneWidget);
      expect(find.textContaining('enter https://push.example.org'), findsOneWidget);
      expect(find.byKey(const ValueKey('ntfy-install')), findsOneWidget);
      expect(find.byKey(const ValueKey('ntfy-open')), findsNothing);
      // The old "install ntfy" footer isn't said twice.
      expect(find.textContaining('There’s no notification app'), findsNothing);
    });

    testWidgets('ntfy on another server: say so; copy, open, connect', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await open(t, state: 'authorized', endpoint: 'https://ntfy.sh/upAbC?up=1');
      expect(find.textContaining('ntfy uses another server (ntfy.sh)'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ntfy-copy')));
      await t.pump();
      expect(copied, ['https://push.example.org']);
      await t.tap(find.byKey(const ValueKey('ntfy-connect')));
      await t.pump(const Duration(seconds: 4));
      expect(platform.calls, contains('reconnect'));
    });

    testWidgets('ntfy installed: "Open ntfy" instead of "Install"', (t) async {
      final c = await open(t, state: 'authorized');
      platform.ntfy = true;
      c.invalidate(ntfyInstalledProvider);
      await t.pumpAndSettle();
      expect(find.textContaining('ntfy is installed but not connected yet'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('ntfy-open')));
      expect(platform.calls, contains('openNtfy'));
    });

    testWidgets('push reaches the phone: no ntfy steps', (t) async {
      await open(t, state: 'authorized', endpoint: 'https://push.example.org/upAbC?up=1');
      expect(find.byKey(const ValueKey('ntfy-copy')), findsNothing);
    });

    testWidgets('the server sends no Android push: say "Always connected"', (t) async {
      await open(t, state: 'noDistributor', hosts: []);
      expect(find.textContaining('doesn’t send notifications to Android'), findsOneWidget);
      expect(find.byKey(const ValueKey('ntfy-copy')), findsNothing);
    });
  });
}

/// ADR-057 — a phone with battery optimisation on, not a Samsung.
class _Battery implements BatteryPlatform {
  const _Battery();

  @override
  Future<({bool exempt, bool samsung})> status() async => (exempt: false, samsung: false);

  @override
  Future<bool> askExempt({bool samsungHint = false}) async => true;

  @override
  Future<void> openSamsung() async {}

  @override
  Future<void> openApp() async {}
}
