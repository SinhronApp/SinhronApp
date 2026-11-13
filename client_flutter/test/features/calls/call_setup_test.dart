// Owner, 2026-10-18: "the call is accepted, but we hear each other only
// after 1–3 seconds" — the join token is fetched while it rings, the screen
// says "Connecting…" until the other side's sound arrives, and each step is
// timed; "the system banner and the app's screen both came up" — the app
// rings itself only when the system doesn't.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_diagnostics.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/call_timeline.dart';
import 'package:sinhron/features/calls/callkit_bridge.dart';
import 'package:sinhron/features/calls/livekit_engine.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import 'active_call_provider_test.dart' show FakeNetService;

/// Records what was fetched; the fetch itself never finishes (no server).
class _FakeEngine extends CallEngine {
  final prepared = <String>[];

  @override
  Future<CallPrep> prepare({required String httpBaseUrl, required String groupIdHex, required String kind}) {
    prepared.add('$groupIdHex $kind');
    return Completer<CallPrep>().future;
  }
}

const _channel = MethodChannel('dev.sinhron/callkit');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEngine engine;
  late FakeNetService net;
  late ProviderContainer c;

  setUp(() {
    engine = _FakeEngine();
    c = ProviderContainer(
      overrides: [
        netServiceProvider.overrideWith((ref) => net = FakeNetService(ref)),
        callEngineProvider.overrideWithValue(engine),
      ],
    );
    c.read(activeCallProvider);
  });

  tearDown(() {
    c.dispose();
    CallKitBridge.debugNative = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  core.NetEvent invite(String id, {String kind = 'audio'}) => core.NetEvent(
    kind: 'call_invite',
    callInvite: core.NetCallInvite(
      callId: id,
      groupIdHex: 'g1',
      kind: kind,
      livekitRoom: 'sinhron-call-$id',
      ttlSecs: 30,
      callerIdentityHex: 'ca' * 32, // ADR-090: a signed invite
    ),
  );

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('an incoming call fetches the join token while it rings', () async {
    net.pushEvent(invite('01900000-0000-7000-8000-0000000000c1', kind: 'video'));
    await settle();
    expect(c.read(activeCallProvider).phase, CallPhase.incomingRinging);
    expect(engine.prepared, ['g1 video'], reason: 'before Accept, not after');
  });

  test('off a phone (no system call UI) the app rings itself', () async {
    net.pushEvent(invite('01900000-0000-7000-8000-0000000000c2'));
    await settle();
    expect(c.read(activeCallProvider).ringsInApp, isTrue);
  });

  test('the system shows the call → no app ringing screen; Android back in front → the app takes over', () async {
    CallKitBridge.debugNative = true;
    final asked = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      asked.add(call.method);
      return call.method == 'reportIncoming'; // CallKit / the notification shows it
    });
    const id = '01900000-0000-7000-8000-0000000000c3';
    net.pushEvent(invite(id));
    await settle();
    expect(asked, contains('reportIncoming'));
    expect(c.read(activeCallProvider).phase, CallPhase.incomingRinging);
    expect(c.read(activeCallProvider).ringsInApp, isFalse, reason: 'one ringing UI: the system one');

    // Android: the app came to the front — the notification is gone.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(const MethodCall('onShowIncoming', {'call_id': id})),
      (_) {},
    );
    await settle();
    expect(c.read(activeCallProvider).ringsInApp, isTrue);
  });

  // Status 212 (owner: "it says connecting, then it's gone, then it's back")
  // — a hiccup LiveKit fixes within 2 s shows nothing; a longer one does.
  test('"Reconnecting…" only after the link stays gone 2 s', () async {
    const id = '01900000-0000-7000-8000-0000000000c9';
    net.pushEvent(invite(id));
    await settle();
    c.read(activeCallProvider.notifier).debugAnswered();
    await settle();
    final n = c.read(activeCallProvider.notifier);
    n.debugLinkLost();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    n.debugLinkBack();
    await Future<void>.delayed(ActiveCallNotifier.kReconnectGrace);
    expect(c.read(activeCallProvider).networkStatus, CallNetworkStatus.connected, reason: 'a hiccup: nothing shown');

    n.debugLinkLost();
    await Future<void>.delayed(ActiveCallNotifier.kReconnectGrace + const Duration(milliseconds: 200));
    expect(c.read(activeCallProvider).networkStatus, CallNetworkStatus.reconnecting);
    n.debugLinkBack();
    expect(c.read(activeCallProvider).networkStatus, CallNetworkStatus.connected);
    await n.end();
  });

  test('answered: "connecting" until the sound comes; the timeline says when', () async {
    const id = '01900000-0000-7000-8000-0000000000c4';
    net.pushEvent(invite(id));
    await settle();
    c.read(activeCallProvider.notifier).debugAnswered();
    await settle();
    final n = c.read(activeCallProvider.notifier);
    expect(c.read(activeCallProvider).phase, CallPhase.connected);
    expect(c.read(activeCallProvider).connecting, isTrue);
    expect(n.timeline.started, isTrue);

    n.debugHeard();
    final s = c.read(activeCallProvider);
    expect(s.connecting, isFalse);
    expect(s.audioAt, isNotNull);
    expect(n.timeline.at('sound'), isNotNull);
    expect(n.timeline.line, contains('sound'));
  });

  // Audit 2026-11b #20 — "accepted" is the other side's answer to MY call;
  // a server that sends it to a phone that is being rung answered for the
  // person: the phone joined the room with the mic on.
  test('an incoming ring is not answered by a frame from the server', () async {
    const id = '01900000-0000-7000-8000-0000000000ca';
    net.pushEvent(invite(id, kind: 'video'));
    await settle();
    for (final accept in [true, false]) {
      net.pushEvent(core.NetEvent(kind: 'call_accept', callAccept: core.NetCallAccept(callId: id, accept: accept)));
      await settle();
      expect(c.read(activeCallProvider).phase, CallPhase.incomingRinging);
      expect(c.read(activeCallProvider).connectedAt, isNull);
    }
  });

  test('a group call: the next members’ answers do not restart it', () async {
    const id = '01900000-0000-7000-8000-0000000000c5';
    net.pushEvent(invite(id));
    await settle();
    c.read(activeCallProvider.notifier).debugAnswered();
    await settle();
    final at = c.read(activeCallProvider).connectedAt;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    net.pushEvent(core.NetEvent(kind: 'call_accept', callAccept: core.NetCallAccept(callId: id, accept: true)));
    await settle();
    expect(c.read(activeCallProvider).connectedAt, at);
  });

  group('timeline', () {
    test('marks count from the answer, once each; a step done while ringing is 0', () {
      var now = DateTime(2026, 10, 18, 12);
      final t = CallTimeline(clock: () => now);
      t.mark('prep'); // before the answer: ignored
      expect(t.line, isEmpty);
      t.start();
      t.mark('prep'); // fetched while ringing
      now = now.add(const Duration(milliseconds: 420));
      t.mark('room');
      now = now.add(const Duration(milliseconds: 130));
      t.mark('mic');
      t.mark('room'); // a second time doesn't move it
      now = now.add(const Duration(milliseconds: 240));
      t.mark('sound');
      expect(t.line, 'prep 0 ms · room 420 ms · mic 550 ms · sound 790 ms');
      expect(t.at('sound'), 790);
    });

    test('the diagnostics panel shows it', () {
      final lines = diagnosticsLines(
        CallStatsSnapshot(at: DateTime(2026)),
        room: 'connected',
        plan: 'direct',
        people: 2,
        setup: 'prep 0 ms · room 420 ms',
      );
      expect(lines, contains('setup: prep 0 ms · room 420 ms'));
      expect(diagnosticsLines(CallStatsSnapshot(at: DateTime(2026)), room: 'c', plan: 'direct', people: 1).any((l) => l.startsWith('setup')), isFalse);
    });
  });

  test('a prefetched token is used only for its group and while fresh', () {
    final prep = CallPrep(
      groupIdHex: 'g1',
      kind: 'audio',
      token: core.LivekitTokenInfo(
        token: 't',
        livekitUrl: 'wss://lk.example',
        room: 'r',
        expiresAtUnix: 0,
        ttlSecs: 3600,
        videoCodecs: const [],
      ),
      turn: const core.TurnCredsInfo(username: 'u', credential: 'c', urls: [], ttlSecs: 0),
      media: (deviceClass: CallDeviceClass.standard, preset: callVideoPreset(CallDeviceClass.standard), codec: 'vp8'),
      at: DateTime(2026, 10, 18, 12),
    );
    expect(prep.usableFor('g1', now: DateTime(2026, 10, 18, 12, 5)), isTrue);
    expect(prep.usableFor('g2', now: DateTime(2026, 10, 18, 12, 5)), isFalse);
    expect(prep.usableFor('g1', now: DateTime(2026, 10, 18, 12, 30)), isFalse, reason: 'tokens live an hour; rejoins ask again');
  });
}
