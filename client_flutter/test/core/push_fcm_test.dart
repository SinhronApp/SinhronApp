// ADR-057 — Android reachable always: Google push (FCM) with the phone's own
// key, "always connected" by itself when there is no other push, and a push
// that wakes the connection for a moment and closes it again.

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/background_connection.dart';
import 'package:sinhron/core/call_reach.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/core/push_server.dart';
import 'package:sinhron/core/push_wake.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';

import 'push_test.dart' show FakePushPlatform;
import 'settings_providers_test.dart' show MemoryStore;

class _Net extends NetService {
  _Net(super.ref);
  @override
  String? get httpBaseUrl => 'https://srv';

  NetStatus now = NetStatus.idle;
  @override
  NetStatus get status => now;
}

class _Call extends ActiveCallNotifier {
  @override
  ActiveCallState build() => const ActiveCallState.idle();
  void put(ActiveCallState s) => state = s;
}

class _Battery implements BatteryPlatform {
  bool exempt = false;
  bool samsung = true;
  bool screen = true;
  final asked = <bool>[];

  @override
  Future<({bool exempt, bool samsung})> status() async => (exempt: exempt, samsung: samsung);

  @override
  Future<bool> askExempt({bool samsungHint = false}) async {
    if (!screen) return false;
    asked.add(samsungHint);
    return true;
  }

  @override
  Future<void> openSamsung() async {}

  @override
  Future<void> openApp() async {}
}

const _ids = {'project_id': 'p', 'app_id': '1:2:android:3', 'api_key': 'AIza', 'sender_id': '2'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePushPlatform platform;
  late List<String> sent;
  late List<String> log;
  late MemoryStore settings;
  late ProviderContainer c;
  late _Battery battery;
  FcmIds? info;

  setUp(() {
    platform = FakePushPlatform();
    sent = [];
    log = [];
    settings = MemoryStore();
    info = (ids: _ids);
    battery = _Battery();
    c = ProviderContainer(
      overrides: [
        isAndroidProvider.overrideWithValue(true),
        settingsStoreProvider.overrideWithValue(settings),
        netServiceProvider.overrideWith((ref) => _Net(ref)),
        pushPlatformProvider.overrideWithValue(platform),
        fcmIdsFetcherProvider.overrideWithValue(() async => info),
        pushTokenSenderProvider.overrideWithValue(
          (base, kind, token, sandbox, lang, keys, key) async =>
              sent.add('$kind ${token.isEmpty ? '-' : token}${key == null ? '' : ' key=$key'}'),
        ),
        notificationExtensionProvider.overrideWithValue(false),
        batteryPlatformProvider.overrideWithValue(battery),
        activeCallProvider.overrideWith(_Call.new),
        stayConnectedInBackgroundProvider.overrideWithValue(() => false),
        pushResumeProvider.overrideWithValue(() async => log.add('resume')),
        pushWakeProvider.overrideWith((ref) => PushWake(ref, connectWithin: Duration.zero, linger: Duration.zero)),
        connectionSwitchProvider.overrideWithValue(
          ConnectionSwitch(
            close: () async => log.add('close'),
            open: () async => log.add('open'),
            refresh: () async => log.add('refresh'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
  });

  Future<void> tick() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('the server\'s Firebase ids go to the phone; its token goes up with the phone key, for messages and calls', () async {
    const tok = 'fcm:cAbC:APA91b-x_y';
    platform.fcmToken = tok;
    platform.pushKeys[tok] = '0a' * 32;
    final push = c.read(pushServiceProvider);
    await push.start();
    await push.onConnected();
    expect(platform.fcmIds, [_ids]);
    // The native side reports the new route as token / voipToken.
    platform.tokensCtl.add((tok, false));
    platform.voipCtl.add((tok, false));
    await tick();
    expect(sent, containsAll(['alert $tok key=${'0a' * 32}', 'voip $tok key=${'0a' * 32}']));
    // Switched off: the removal carries no key (the server would refuse it).
    await push.setEnabled(false);
    expect(sent.last, 'alert -');
  });

  test('a server without Firebase: Google push off here; offline: left as it is', () async {
    info = (ids: null);
    await c.read(pushServiceProvider).syncFcm();
    expect(platform.fcmIds, [null]);
    info = null;
    await c.read(pushServiceProvider).syncFcm();
    expect(platform.fcmIds, [null], reason: 'unknown — nothing changes');
  });

  test('no other push: "always connected" comes on by itself, off once Google push came', () async {
    info = (ids: null);
    final push = c.read(pushServiceProvider);
    await push.start();
    await push.onConnected();
    expect(platform.calls, contains('keepAlive true'));
    expect(c.read(keepConnectedProvider).value, isTrue);
    expect(settings.map['android_keep_connected'], isNull, reason: 'not the person\'s choice');
    platform.voipCtl.add(('fcm:cAbC:APA91b-x_y', false));
    await tick();
    expect(platform.calls.last, 'keepAlive false');
    expect(c.read(keepConnectedProvider).value, isFalse);
  });

  test('the person\'s own "always connected" choice is never changed', () async {
    info = (ids: null);
    final push = c.read(pushServiceProvider);
    await push.setKeepConnected(false);
    platform.calls.clear();
    await push.start();
    await push.onConnected();
    expect(platform.calls, isNot(contains('keepAlive true')));
    expect(c.read(keepConnectedProvider).value, isFalse);
  });

  test('an "on" chosen for lack of push follows the phone once Google push works (bug 2026-10-19)', () async {
    // Chosen before 2026-10-19 (no record of the push then) — a real phone.
    settings.map['android_keep_connected'] = '1';
    final push = c.read(pushServiceProvider);
    await push.start();
    expect(c.read(keepConnectedProvider).value, isTrue);
    expect(platform.calls, contains('keepAlive true'));
    // ntfy alone doesn't count (it may still point at ntfy.sh).
    platform.voipCtl.add(('https://push.example.org/up1', false));
    await tick();
    expect(c.read(keepConnectedProvider).value, isTrue);
    platform.voipCtl.add(('fcm:cAbC:APA91b-x_y', false));
    await tick();
    expect(platform.calls.last, 'keepAlive false');
    expect(c.read(keepConnectedProvider).value, isFalse);
    expect(await c.read(keepConnectedProvider.notifier).chosen(), isFalse, reason: 'follows the phone again');
    // Google push gone again: back on by itself.
    platform.removedCtl.add(null);
    await tick();
    expect(platform.calls.last, 'keepAlive true');
  });

  test('an "on" chosen while Google push already worked stays on', () async {
    platform.lastVoip = ('fcm:cAbC:APA91b-x_y', false);
    final push = c.read(pushServiceProvider);
    await push.start();
    await push.setKeepConnected(true);
    platform.calls.clear();
    await push.onConnected();
    platform.voipCtl.add(('fcm:cAbC:APA91b-x_y', false));
    await tick();
    expect(platform.calls, isNot(contains('keepAlive false')));
    expect(c.read(keepConnectedProvider).value, isTrue);
  });

  group('a push while the connection is already open (bug 2026-10-19)', () {
    late _Net net;
    setUp(() {
      net = c.read(netServiceProvider) as _Net;
      net.now = NetStatus.connected;
    });

    test('the message came down the socket: no plain "New message" on top', () async {
      net.lastPushAt = DateTime.now().subtract(const Duration(seconds: 2));
      await c.read(pushWakeProvider).run();
      expect(log, ['resume', 'close']);
      expect(platform.calls, ['wakeDone handled']);
    });

    test('nothing came: the socket may be dead — a new one, then the plain notification if still nothing', () async {
      net.lastPushAt = DateTime.now().subtract(const Duration(minutes: 5));
      await c.read(pushWakeProvider).run();
      expect(log, ['resume', 'refresh', 'close']);
      expect(platform.calls, ['wakeDone']);
    });

    test('a call rings: its socket is left alone', () async {
      (c.read(activeCallProvider.notifier) as _Call).put(
        const ActiveCallState(phase: CallPhase.incomingRinging, callId: 'c', groupIdHex: 'g'),
      );
      await c.read(pushWakeProvider).run();
      expect(log, ['resume']);
    });

    test('closed connection: only what comes after the push counts', () async {
      final bg = c.read(backgroundConnectionProvider);
      await bg.onLifecycle(AppLifecycleState.paused);
      log.clear();
      net.lastPushAt = DateTime.now().subtract(const Duration(seconds: 2));
      await c.read(pushWakeProvider).run();
      expect(log, ['open', 'close']);
      expect(platform.calls, ['wakeDone']);
    });
  });

  test('a push wakes the connection, then it closes BEFORE the phone is told it may sleep', () async {
    final wake = c.read(pushWakeProvider);
    await wake.run();
    expect([...log, ...platform.calls], ['resume', 'close', 'wakeDone']);
    // A second push: the closed connection opens again.
    log.clear();
    platform.calls.clear();
    await wake.run();
    expect([...log, ...platform.calls], ['open', 'close', 'wakeDone']);
  });

  test('a call that rings keeps the woken connection (the invite and Decline need it)', () async {
    (c.read(activeCallProvider.notifier) as _Call).put(
      const ActiveCallState(phase: CallPhase.incomingRinging, callId: 'c', groupIdHex: 'g'),
    );
    await c.read(pushWakeProvider).run();
    expect(log, ['resume']);
    expect(platform.calls, ['wakeDone']);
  });

  test('woken off screen, the app draws the notifications itself', () async {
    final bg = c.read(backgroundConnectionProvider);
    expect(bg.openForAPush, isFalse);
    final done = Completer<void>();
    unawaited(bg.openForPush().then((_) => done.complete()));
    await done.future;
    expect(bg.openForAPush, isTrue);
    await bg.closeAfterPush();
    expect(bg.openForAPush, isFalse);
  });

  test('a wake that started the engine is picked up once Dart listens', () async {
    platform.wokeAtStart = true;
    await listenForPushWakes(c, canConnect: false);
    expect(platform.calls, ['wakeDone'], reason: 'locked DB: answer at once, the phone shows "New message"');
  });

  test('first run: the battery question once (with the Samsung note); not without a screen', () async {
    battery.screen = false;
    await c.read(pushServiceProvider).onConnected();
    expect(battery.asked, isEmpty);
    expect(settings.map['android_battery_asked'], isNull, reason: 'asked next time, with a screen');
    battery.screen = true;
    await c.read(pushServiceProvider).onConnected();
    await c.read(pushServiceProvider).onConnected();
    expect(battery.asked, [true]);
  });

  group('will calls reach me', () {
    CallReach reach({
      String status = 'authorized',
      bool callsOn = true,
      String? route,
      bool ntfyOk = true,
      bool keep = false,
      bool exempt = false,
      bool samsung = false,
    }) => callReachFor(
      status: status,
      callsOn: callsOn,
      route: route,
      ntfyOk: ntfyOk,
      keepConnected: keep,
      exempt: exempt,
      samsung: samsung,
    );

    test('Google push: yes, even with battery optimisation on', () {
      final r = reach(route: 'fcm:x');
      expect((r.ok, r.via), (true, ReachVia.google));
    });

    test('nothing wakes the phone: turn on "always connected"; then let it run in background', () {
      expect(reach().fixes, [ReachFix.turnOnAlwaysConnected]);
      expect(reach(keep: true).fixes, [ReachFix.allowBackground]);
      expect(reach(keep: true, exempt: true).ok, isTrue);
      expect(reach(route: 'https://push.example.org/u', ntfyOk: false).via, ReachVia.none, reason: 'ntfy on ntfy.sh');
    });

    test('notifications refused or calls off: say so', () {
      expect(reach(route: 'fcm:x', status: 'denied').fixes, [ReachFix.allowNotifications]);
      expect(reach(route: 'fcm:x', callsOn: false).fixes, [ReachFix.turnOnCalls]);
    });
  });

  group('push info', () {
    test('Firebase ids from /v1/push/info', () {
      final got = parseFcmIds(200, '{"unifiedpush_hosts":[],"fcm":{"project_id":"p","app_id":"1:2:android:3","api_key":"AIza","sender_id":"2"}}');
      expect(got?.ids, _ids);
      expect(parseFcmIds(200, '{"unifiedpush_hosts":[],"fcm":null}'), (ids: null));
      expect(parseFcmIds(200, '{"unifiedpush_hosts":[]}'), (ids: null), reason: 'an older server');
      expect(parseFcmIds(200, '{"fcm":{"project_id":"p"}}'), (ids: null), reason: 'incomplete');
      expect(parseFcmIds(404, ''), isNull);
      expect(parseFcmIds(200, 'not json'), isNull);
    });

    test('with Google push the ntfy steps are not shown', () {
      expect(ntfyHintFor(status: 'authorized', hosts: ['push.example.org'], endpoint: 'fcm:abc'), isNull);
    });
  });

  // Audit 15/PA-11.
  test('no token event and /v1/push/info silent: the message token is still sent on connect', () async {
    const tok = 'fcm:cAbC:APA91b-x_y';
    platform.lastVoip = (tok, false);
    platform.pushKeys[tok] = '0a' * 32;
    info = null;
    final push = c.read(pushServiceProvider);
    await push.start();
    await push.onConnected();
    expect(sent, containsAll(['alert $tok key=${'0a' * 32}', 'voip $tok key=${'0a' * 32}']));
  });
}
