// Quality polish — activeCallProvider FSM behavior tests.
//
// Scope: covers state transitions driven by INCOMING events from the
// (mocked) NetService. Outgoing flows (invite/accept/decline) call
// platform-channel APIs (permission_handler, FFI) which aren't
// trivially mockable in widget-test mode, so они out of scope here.
//
// The mock NetService extends the real one but overrides the public
// `callEvents` getter to return a stream we control. Pushing events
// via [FakeNetService.pushEvent] drives the FSM as if real WS frames
// arrived from the server.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';

import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/core/providers/people.dart' show blockedPeersProvider;
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_path.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/callkit_bridge.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/settings_providers_test.dart' show MemoryStore;

/// Test-only NetService stub. The base class stores a private
/// `StreamController` for call events; we override the public
/// `callEvents` getter to return OUR stream so tests can push fake
/// events at will.
class FakeNetService extends NetService {
  FakeNetService(super.ref);

  final StreamController<core.NetEvent> _ctrl =
      StreamController<core.NetEvent>.broadcast();

  @override
  Stream<core.NetEvent> get callEvents => _ctrl.stream;

  void pushEvent(core.NetEvent event) {
    _ctrl.add(event);
  }

  @override
  Future<void> shutdown() async {
    if (!_ctrl.isClosed) {
      await _ctrl.close();
    }
  }
}

/// Records history rows and missed-call lines (no storage in tests).
class FakeCallLog implements CallLog {
  final rows = <String>[];
  final lines = <String>[];

  @override
  Future<void> append({
    required String id,
    required String chatId,
    required bool video,
    required String status,
    required bool outgoing,
    required int startedAtUnix,
    required int endedAtUnix,
    int? durationSecs,
  }) async => rows.add('$chatId ${outgoing ? 'out' : 'in'} ${video ? 'video' : 'audio'} $status');

  @override
  Future<void> missedLine(String chatId, {required bool video}) async =>
      lines.add('$chatId ${video ? 'video' : 'audio'}');
}

late FakeCallLog callLog;

/// Helper: spin up a ProviderContainer with our fake NetService wired
/// into [netServiceProvider]. Returns the container + fake so tests
/// can both `read(activeCallProvider)` and push events.
({ProviderContainer container, FakeNetService fake}) _makeContainer({
  SettingsStore? settings,
  List<ChatPreview>? chats,
  Set<String>? blockedPeers,
}) {
  late FakeNetService fake;
  final container = ProviderContainer(
    overrides: [
      netServiceProvider.overrideWith((ref) {
        fake = FakeNetService(ref);
        return fake;
      }),
      if (settings != null) settingsStoreProvider.overrideWithValue(settings),
      if (chats != null) chatsProvider.overrideWith((ref) async => chats),
      callLogProvider.overrideWithValue(callLog = FakeCallLog()),
      if (blockedPeers != null) blockedPeersProvider.overrideWith((ref) async => blockedPeers),
    ],
  );
  // Touching the provider once primes its build() — that's where the
  // callEvents subscription gets wired up via ref.read(netServiceProvider).
  // ignore: unused_local_variable
  final initial = container.read(activeCallProvider);
  return (container: container, fake: fake);
}

core.NetEvent _invite({
  required String callId,
  required String groupIdHex,
  required String kind,
  // ADR-090 — the caller Rust checked the invite's signature for ('' = none).
  String? caller,
}) {
  return core.NetEvent(
    kind: 'call_invite',
    callInvite: core.NetCallInvite(
      callId: callId,
      groupIdHex: groupIdHex,
      kind: kind,
      livekitRoom: 'sinhron-call-$callId',
      ttlSecs: 30,
      callerIdentityHex: caller ?? 'ca' * 32,
    ),
  );
}

core.NetEvent _end({required String callId, String reason = 'hangup'}) {
  return core.NetEvent(
    kind: 'call_end',
    callEnd: core.NetCallEnd(callId: callId, reason: reason),
  );
}

void main() {
  // CallKitBridge.registerEventCallback (called in ActiveCallNotifier.build)
  // touches a MethodChannel — that needs a binary messenger which is only
  // available after WidgetsFlutterBinding initialization. Set this up
  // once for the whole file.
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  // ──────────────────────────────────────────────────────────────────
  // Group 1: incoming call from quiet state
  // ──────────────────────────────────────────────────────────────────

  test('initial state is idle', () {
    final t = _makeContainer();
    final state = t.container.read(activeCallProvider);
    expect(state.phase, CallPhase.idle);
    expect(state.callId, isNull);
    expect(state.networkStatus, CallNetworkStatus.connected);
    t.container.dispose();
  });

  test('incoming CallInvite drives phase → incomingRinging', () async {
    final t = _makeContainer();
    t.fake.pushEvent(_invite(
      callId: '01900000-0000-7000-8000-000000000001',
      groupIdHex: 'abc123',
      kind: 'audio',
    ));
    // Stream events fire asynchronously — give the listener a tick.
    await Future<void>.delayed(Duration.zero);

    final state = t.container.read(activeCallProvider);
    expect(state.phase, CallPhase.incomingRinging);
    expect(state.callId, '01900000-0000-7000-8000-000000000001');
    expect(state.groupIdHex, 'abc123');
    expect(state.kind, CallKind.audio);
    expect(state.isCaller, isFalse);
    t.container.dispose();
  });

  // Tech-debt 2.27 — call screening.
  test('incoming calls switched off → the invite is declined, nothing rings', () async {
    final store = MemoryStore()..map['incoming_calls'] = 'false';
    final t = _makeContainer(settings: store);
    await Future<void>.delayed(Duration.zero); // settings load
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-00000000000a', groupIdHex: 'abc123', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.container.dispose();
  });

  test('a call from a personal chat with someone blocked does not ring; others do', () async {
    final store = MemoryStore()..map['blocked_chats'] = 'dead01,abc123';
    final t = _makeContainer(settings: store);
    await Future<void>.delayed(Duration.zero);
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-00000000000b', groupIdHex: 'abc123', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-00000000000c', groupIdHex: 'beef02', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.incomingRinging);
    t.container.dispose();
  });

  // Tech-debt 2.27 — a group call from someone I blocked: the invite names
  // the caller (server-set), the phone stays quiet; others still ring.
  test('a group call from a blocked member does not ring', () async {
    final t = _makeContainer(blockedPeers: {'ee' * 32});
    await Future<void>.delayed(Duration.zero);
    t.fake.pushEvent(
      _invite(callId: '01900000-0000-7000-8000-0000000000a1', groupIdHex: 'family1', kind: 'audio', caller: 'EE' * 32),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.fake.pushEvent(
      _invite(callId: '01900000-0000-7000-8000-0000000000a2', groupIdHex: 'family1', kind: 'audio', caller: 'aa' * 32),
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.incomingRinging);
    t.container.dispose();
  });

  // ADR-090 (calls:5) — an invite its caller didn't sign (Rust names no
  // caller): only the server wrote it — no ring, no system call screen.
  test('an invite the caller did not sign does not ring', () async {
    final t = _makeContainer();
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-0000000000f1', groupIdHex: 'abc123', kind: 'audio', caller: ''));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.container.dispose();
  });

  test('a call from a message request does not ring', () async {
    final t = _makeContainer(
      chats: const [ChatPreview(id: 'abc123', name: 'Stranger', preview: '', time: '', request: true)],
    );
    await t.container.read(chatsProvider.future);
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-00000000000d', groupIdHex: 'abc123', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.container.dispose();
  });

  test('a call for a chat this device does not have does not ring', () async {
    final t = _makeContainer(
      chats: const [ChatPreview(id: 'known1', name: 'Known', preview: '', time: '')],
    );
    await t.container.read(chatsProvider.future);
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-00000000000e', groupIdHex: 'deleted9', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle, reason: 'deleted / unknown chat');
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-00000000000f', groupIdHex: 'known1', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase, CallPhase.incomingRinging);
    t.container.dispose();
  });

  test('incoming video call sets kind=video', () async {
    final t = _makeContainer();
    t.fake.pushEvent(_invite(
      callId: '01900000-0000-7000-8000-000000000002',
      groupIdHex: 'group2',
      kind: 'video',
    ));
    await Future<void>.delayed(Duration.zero);

    final state = t.container.read(activeCallProvider);
    expect(state.phase, CallPhase.incomingRinging);
    expect(state.kind, CallKind.video);
    t.container.dispose();
  });

  test('CallInvite for unknown wire kind falls back to audio', () async {
    final t = _makeContainer();
    t.fake.pushEvent(_invite(
      callId: '01900000-0000-7000-8000-000000000003',
      groupIdHex: 'g',
      kind: 'screen-share', // not "audio" or "video"
    ));
    await Future<void>.delayed(Duration.zero);

    // callKindFromWire defaults to audio for anything not "video".
    expect(t.container.read(activeCallProvider).kind, CallKind.audio);
    t.container.dispose();
  });

  // ──────────────────────────────────────────────────────────────────
  // Group 2: terminal transitions from remote-driven events
  // ──────────────────────────────────────────────────────────────────

  test('CallEnd from remote during incomingRinging → ended → idle',
      () async {
    final t = _makeContainer();
    final callId = '01900000-0000-7000-8000-00000000001a';
    t.fake.pushEvent(_invite(
      callId: callId,
      groupIdHex: 'g',
      kind: 'audio',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).phase,
        CallPhase.incomingRinging);

    // Caller hangs up before callee answered.
    t.fake.pushEvent(_end(callId: callId, reason: 'hangup'));
    await Future<void>.delayed(Duration.zero);
    final endedState = t.container.read(activeCallProvider);
    expect(endedState.phase, CallPhase.ended);
    expect(endedState.endReason, 'hangup');

    // The 2-second timer eventually flips back to idle. Wait for it rather
    // than for a fixed 3 s — on a loaded machine timers fire late (this
    // was flaky).
    for (var i = 0; i < 100 && t.container.read(activeCallProvider).phase != CallPhase.idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.container.dispose();
  });

  test('CallEnd ignored for stale call_id', () async {
    final t = _makeContainer();
    t.fake.pushEvent(_invite(
      callId: '01900000-0000-7000-8000-00000000002a',
      groupIdHex: 'g',
      kind: 'audio',
    ));
    await Future<void>.delayed(Duration.zero);

    // Push CallEnd for a DIFFERENT call_id — should be ignored.
    t.fake.pushEvent(_end(
      callId: '01900000-0000-7000-8000-stale-id-different',
      reason: 'hangup',
    ));
    await Future<void>.delayed(Duration.zero);

    // Still in incomingRinging — stale CallEnd didn't tear us down.
    expect(t.container.read(activeCallProvider).phase,
        CallPhase.incomingRinging);
    t.container.dispose();
  });

  // ──────────────────────────────────────────────────────────────────
  // Group 3: CallRing (server delivered our invite)
  // ──────────────────────────────────────────────────────────────────

  test('CallRing event is a no-op on state (no phase change)', () async {
    final t = _makeContainer();
    // The handler routes call_ring to switch case but does NOT update
    // state. Just confirms we don't accidentally treat it as terminal.
    t.fake.pushEvent(core.NetEvent(
      kind: 'call_ring',
      callRing: core.NetCallRing(callId: 'whatever', delivered: true),
    ));
    await Future<void>.delayed(Duration.zero);

    final state = t.container.read(activeCallProvider);
    expect(state.phase, CallPhase.idle); // unchanged
    expect(state.peerRinging, isFalse, reason: 'not my call');
    t.container.dispose();
  });

  // Status 213 — "Ringing…" once their phone has my call (not before, not
  // for another call, not after the answer).
  test('the ring reached them: only for my ringing call, only when delivered', () {
    const mine = ActiveCallState(phase: CallPhase.outgoingRinging, callId: 'c1', isCaller: true);
    expect(ringReachedThem(mine, callId: 'c1', delivered: true), isTrue);
    expect(ringReachedThem(mine, callId: 'c1', delivered: false), isFalse, reason: 'their phone is off / blocked');
    expect(ringReachedThem(mine, callId: 'c2', delivered: true), isFalse);
    expect(ringReachedThem(mine.copyWith(phase: CallPhase.connected), callId: 'c1', delivered: true), isFalse);
  });

  // ──────────────────────────────────────────────────────────────────
  // Group 4: busy detection (concurrent invite auto-declined)
  // ──────────────────────────────────────────────────────────────────

  test(
      'second incoming CallInvite while first is incomingRinging is ignored',
      () async {
    final t = _makeContainer();
    t.fake.pushEvent(_invite(
      callId: 'first',
      groupIdHex: 'g1',
      kind: 'audio',
    ));
    await Future<void>.delayed(Duration.zero);
    expect(t.container.read(activeCallProvider).callId, 'first');

    // Second invite during incomingRinging → handler short-circuits
    // because state.isActive is true. Original state preserved.
    t.fake.pushEvent(_invite(
      callId: 'second',
      groupIdHex: 'g2',
      kind: 'video',
    ));
    await Future<void>.delayed(Duration.zero);

    final state = t.container.read(activeCallProvider);
    expect(state.callId, 'first');
    expect(state.kind, CallKind.audio); // still the first call's audio
    t.container.dispose();
  });

  // ──────────────────────────────────────────────────────────────────
  // Group 5: state immutability
  // ──────────────────────────────────────────────────────────────────

  test('copyWith clearError nulls the error field', () {
    const base = ActiveCallState(error: 'something went wrong');
    final cleared = base.copyWith(clearError: true);
    expect(cleared.error, isNull);
  });

  // Tech-debt 2.38 — a friend in Russia with a VPN "by rules": LiveKit
  // rejoined 23 times in 3 minutes and nobody said why.
  test('the reserve path dropping twice in 30 s tells the person what helps', () {
    final t = _makeContainer();
    addTearDown(t.container.dispose);
    final n = t.container.read(activeCallProvider.notifier)..debugPath = CallPath.reserve;
    final t0 = DateTime(2026, 10, 16, 12);
    n.onPathDrop(now: t0);
    expect(t.container.read(activeCallProvider).keepsDropping, isFalse, reason: 'one drop is a hiccup');
    n.onPathDrop(now: t0.add(const Duration(seconds: 10)));
    expect(t.container.read(activeCallProvider).keepsDropping, isTrue);
    expect(t.container.read(activeCallProvider).notice, CallNotice.keepsDropping);
    expect(n.path, CallPath.reserve, reason: 'nowhere further to switch');
  });

  test('copyWith preserves untouched fields', () {
    const base = ActiveCallState(
      phase: CallPhase.connected,
      callId: 'cid',
      groupIdHex: 'g',
      kind: CallKind.video,
      isCaller: true,
    );
    final updated = base.copyWith(phase: CallPhase.ended);
    expect(updated.phase, CallPhase.ended);
    expect(updated.callId, 'cid');
    expect(updated.groupIdHex, 'g');
    expect(updated.kind, CallKind.video);
    expect(updated.isCaller, isTrue);
  });

  // Owner, 2026-10-16: media stopped only after the server had the end —
  // seconds on a slow link. Now the call is over here at once (LiveKit torn
  // down), the end goes to the server after, and the screen closes soon.
  test('end(): ended at once, before the server hears it; idle after a short hold', () async {
    final t = _makeContainer();
    const callId = '01900000-0000-7000-8000-0000000000e1';
    t.fake.pushEvent(_invite(callId: callId, groupIdHex: 'g', kind: 'video'));
    await Future<void>.delayed(Duration.zero);
    final done = t.container.read(activeCallProvider.notifier).end();
    expect(t.container.read(activeCallProvider).phase, CallPhase.ended, reason: 'synchronously, not after the send');
    await done;
    expect(kCallEndedHold, lessThanOrEqualTo(const Duration(seconds: 1)));
    for (var i = 0; i < 50 && t.container.read(activeCallProvider).phase != CallPhase.idle; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(t.container.read(activeCallProvider).phase, CallPhase.idle);
    t.container.dispose();
  });

  // Owner, 2026-10-16: the iPhone's call history said "Call · eb8c2765".
  test('the system call UI gets the chat\'s name, or "Sinhron" when notifications show nothing', () async {
    final calls = <MethodCall>[];
    CallKitBridge.debugNative = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.sinhron/callkit'),
      (c) async {
        calls.add(c);
        return true;
      },
    );
    addTearDown(() {
      CallKitBridge.debugNative = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.sinhron/callkit'),
        null,
      );
    });
    Future<String?> ringFrom(MemoryStore store, String callId) async {
      calls.clear();
      final t = _makeContainer(
        settings: store,
        chats: const [ChatPreview(id: 'g-mama', name: 'Мама', preview: '', time: '')],
      );
      await t.container.read(chatsProvider.future);
      t.fake.pushEvent(_invite(callId: callId, groupIdHex: 'g-mama', kind: 'audio'));
      for (var i = 0; i < 20 && !calls.any((c) => c.method == 'reportIncoming'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      t.container.dispose();
      final report = calls.where((c) => c.method == 'reportIncoming').firstOrNull;
      return (report?.arguments as Map?)?['peer_name'] as String?;
    }

    expect(await ringFrom(MemoryStore(), '01900000-0000-7000-8000-0000000000f1'), 'Мама');
    expect(
      await ringFrom(MemoryStore()..map['notification_preview'] = 'nothing', '01900000-0000-7000-8000-0000000000f2'),
      'Sinhron',
    );
  });

  test('isActive predicate excludes idle + ended', () {
    expect(const ActiveCallState().isActive, isFalse);
    expect(
      const ActiveCallState(phase: CallPhase.outgoingRinging).isActive,
      isTrue,
    );
    expect(
      const ActiveCallState(phase: CallPhase.incomingRinging).isActive,
      isTrue,
    );
    expect(
      const ActiveCallState(phase: CallPhase.connected).isActive,
      isTrue,
    );
    expect(
      const ActiveCallState(phase: CallPhase.ended).isActive,
      isFalse,
    );
  });

  test('callKindFromWire matches wire format', () {
    expect(callKindFromWire('audio'), CallKind.audio);
    expect(callKindFromWire('video'), CallKind.video);
    expect(callKindFromWire('anything-else'), CallKind.audio);
  });

  // Owner, 2026-10-15: "join a group call that is already going".
  test('a group call is remembered for "Join" until it ends; a personal one is not', () async {
    final t = _makeContainer(
      chats: const [
        ChatPreview(id: 'team01', name: 'Дача', preview: '', time: '', group: true),
        ChatPreview(id: 'pair01', name: 'Вера', preview: '', time: ''),
      ],
    );
    await t.container.read(chatsProvider.future);
    const groupCall = '01900000-0000-7000-8000-0000000000a1';
    t.fake.pushEvent(_invite(callId: groupCall, groupIdHex: 'team01', kind: 'video'));
    t.fake.pushEvent(_invite(callId: '01900000-0000-7000-8000-0000000000a2', groupIdHex: 'pair01', kind: 'audio'));
    await Future<void>.delayed(Duration.zero);
    final ongoing = t.container.read(ongoingGroupCallsProvider.notifier);
    final c = ongoing.inChat('team01')!;
    expect((c.callId, c.kind, c.livekitRoom), (groupCall, CallKind.video, 'sinhron-call-$groupCall'));
    expect(ongoing.inChat('pair01'), isNull, reason: 'only group calls can be joined later');

    t.fake.pushEvent(_end(callId: groupCall));
    await Future<void>.delayed(Duration.zero);
    expect(ongoing.inChat('team01'), isNull, reason: 'the call ended');
    t.container.dispose();
  });

  test('a remembered call that we never heard end stops being offered', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final ongoing = c.read(ongoingGroupCallsProvider.notifier);
    final t0 = DateTime(2026, 10, 15, 20);
    ongoing.put(OngoingCall(callId: 'x', groupIdHex: 'g', kind: CallKind.audio, livekitRoom: 'r', since: t0));
    expect(ongoing.inChat('g', now: t0.add(const Duration(hours: 1))), isNotNull);
    expect(ongoing.inChat('g', now: t0.add(OngoingGroupCalls.maxAge + const Duration(minutes: 1))), isNull);
  });

  // ──────────────────────────────────────────────────────────────────
  // Overnight item 5 — how calls end: missed, declined, busy, no answer
  // ──────────────────────────────────────────────────────────────────

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('a call to me that the caller gave up on is missed: history + a line in the chat', () async {
    final t = _makeContainer();
    const id = '01900000-0000-7000-8000-0000000000c1';
    t.fake.pushEvent(_invite(callId: id, groupIdHex: 'g1', kind: 'video'));
    await settle();
    t.fake.pushEvent(_end(callId: id, reason: 'hangup'));
    await settle();
    expect(callLog.rows, ['g1 in video missed']);
    expect(callLog.lines, ['g1 video']);
    t.container.dispose();
  });

  // Owner, 2026-10-26 — answered on my iPhone, the iPad kept ringing and
  // then showed a missed call.
  test('answered on my other device: this one stops ringing, nothing missed', () async {
    final t = _makeContainer();
    const id = '01900000-0000-7000-8000-0000000000e1';
    t.fake.pushEvent(_invite(callId: id, groupIdHex: 'g1', kind: 'audio'));
    await settle();
    t.fake.pushEvent(_end(callId: id, reason: kAnsweredElsewhere));
    await settle();
    final s = t.container.read(activeCallProvider);
    expect(s.phase, CallPhase.ended);
    expect(callLog.rows, isEmpty, reason: 'the device that answered keeps it in its history');
    expect(callLog.lines, isEmpty, reason: 'no "missed call" line');
    t.container.dispose();
  });

  test('declined on my other device: "declined" here, no missed line', () async {
    final t = _makeContainer();
    const id = '01900000-0000-7000-8000-0000000000e2';
    t.fake.pushEvent(_invite(callId: id, groupIdHex: 'g1', kind: 'video'));
    await settle();
    t.fake.pushEvent(_end(callId: id, reason: kDeclinedElsewhere));
    await settle();
    expect(callLog.rows, ['g1 in video declined']);
    expect(callLog.lines, isEmpty);
    t.container.dispose();
  });

  test('a call I declined is "declined" — no missed line', () async {
    final t = _makeContainer();
    const id = '01900000-0000-7000-8000-0000000000c2';
    t.fake.pushEvent(_invite(callId: id, groupIdHex: 'g1', kind: 'audio'));
    await settle();
    await t.container.read(activeCallProvider.notifier).decline();
    await settle();
    expect(callLog.rows, ['g1 in audio declined']);
    expect(callLog.lines, isEmpty);
    t.container.dispose();
  });

  test('busy: a second call while one rings is missed here; the first goes on', () async {
    final t = _makeContainer();
    const first = '01900000-0000-7000-8000-0000000000c3';
    const second = '01900000-0000-7000-8000-0000000000c4';
    t.fake.pushEvent(_invite(callId: first, groupIdHex: 'g1', kind: 'audio'));
    await settle();
    t.fake.pushEvent(_invite(callId: second, groupIdHex: 'g2', kind: 'audio'));
    await settle();
    final s = t.container.read(activeCallProvider);
    expect(s.callId, first);
    expect(s.phase, CallPhase.incomingRinging);
    expect(callLog.rows, ['g2 in audio missed']);
    expect(callLog.lines, ['g2 audio']);
    t.container.dispose();
  });

  test('ringing with no end from the server stops by itself (missed)', () async {
    final saved = ActiveCallNotifier.ringTimeout;
    ActiveCallNotifier.ringTimeout = const Duration(milliseconds: 50);
    addTearDown(() => ActiveCallNotifier.ringTimeout = saved);
    final t = _makeContainer();
    const id = '01900000-0000-7000-8000-0000000000c5';
    t.fake.pushEvent(_invite(callId: id, groupIdHex: 'g1', kind: 'audio'));
    await settle();
    for (var i = 0; i < 40 && t.container.read(activeCallProvider).phase != CallPhase.ended; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(t.container.read(activeCallProvider).endReason, 'no_answer');
    await settle();
    expect(callLog.rows, ['g1 in audio missed']);
    t.container.dispose();
  });

  test('history status from how the call ended', () {
    String s(String r, {bool c = false, bool out = false}) => callStatusFromReason(r, connected: c, outgoing: out);
    expect(s('hangup', c: true), 'completed');
    expect(s('declined'), 'declined');
    expect(s('rejected', out: true), 'declined');
    expect(s('busy', out: true), 'busy');
    expect(s('no_answer', out: true), 'no_answer');
    expect(s('hangup', out: true), 'cancelled');
    for (final r in ['hangup', 'no_answer', 'busy', 'network_lost']) {
      expect(s(r), 'missed', reason: 'a call to me I did not take: $r');
    }
    expect(s(kAnsweredElsewhere), kAnsweredElsewhere, reason: 'not missed: answered on my other device');
    expect(s(kDeclinedElsewhere), 'declined');
    expect(s(kAnsweredElsewhere, c: true), 'completed', reason: 'this device is in the call');
  });

  // Overnight item 9 — Decline on the lock screen (CallKit "end" while it
  // still rings) declines; it used to hang up.
  test('CallKit end while ringing = decline', () async {
    final t = _makeContainer();
    const id = '01900000-0000-7000-8000-0000000000d1';
    t.fake.pushEvent(_invite(callId: id, groupIdHex: 'g1', kind: 'audio'));
    await settle();
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      'dev.sinhron/callkit',
      codec.encodeMethodCall(const MethodCall('onEnd', {'call_id': id})),
      (_) {},
    );
    await settle();
    expect(t.container.read(activeCallProvider).endReason, 'declined');
    expect(callLog.rows, ['g1 in audio declined']);
    t.container.dispose();
  });
}
