// CD3 — active call Riverpod state.
//
// One source of truth for "is there a call going on, and what's its
// state?". UI surfaces (call_screen, active_call_bar, ChatList overlay)
// watch this provider; outgoing actions (Call button, Hangup, Accept,
// Decline) all funnel through [ActiveCallNotifier].
//
// Lifecycle of a 1:1 call (caller side):
//
//   Idle ─[invite()]──▶ OutgoingRinging ─[CallRing rx]─▶ same
//        ─[invite() fails]─▶ Idle (with error)
//        OutgoingRinging ─[CallAccept rx]──▶ Connected
//        OutgoingRinging ─[CallEnd rx]─────▶ Ended → Idle after 2s
//        Connected ─[end() / CallEnd rx]──▶ Ended → Idle after 2s
//
// Callee side starts in IncomingRinging via [_onIncomingInvite] when a
// `call_invite` event arrives from NetService.callEvents.
//
//   IncomingRinging ─[accept()]──▶ Connected
//                   ─[decline()]─▶ Ended → Idle
//                   ─[CallEnd rx]▶ Ended → Idle  (caller hung up first)
//
// LiveKit (CD6): the token and TURN creds are fetched while the call rings
// (both sides); the caller also joins the room then, with the mic silent,
// and opens it on CallAccept; the callee joins on Accept, alongside telling
// the server (owner, 2026-10-18: "accepted, but we hear each other only
// after 1–3 s"). [timeline] marks each step; [ActiveCallState.audioAt] says
// when the other side's sound arrived ("Connecting…" until then).

import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart' show ValueNotifier, immutable, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk_audio show Hardware, MediaDevice;
import 'package:livekit_client/livekit_client.dart' as lk_room show Room;
import 'package:livekit_client/livekit_client.dart'
    as lk_quality
    show CancelListenFunc, ParticipantConnectionQualityUpdatedEvent;
import 'package:livekit_client/livekit_client.dart'
    as lk_events
    show
        ActiveSpeakersChangedEvent,
        ParticipantConnectedEvent,
        ParticipantDisconnectedEvent,
        TrackMutedEvent,
        TrackPublishedEvent,
        TrackSubscribedEvent,
        TrackUnmutedEvent,
        TrackUnpublishedEvent;
import 'package:livekit_client/livekit_client.dart'
    as lk_track
    show CameraPosition, LocalVideoTrack, LocalVideoTrackExt, Participant, TrackSource;
import 'package:uuid/uuid.dart';

import '../../core/providers/chat_providers.dart';
import '../banners/in_app_banner.dart' show NotificationPreview, maybeNotifyMissedCall, notificationPreviewProvider;
import '../../core/providers/message_actions.dart' show messageActionsProvider;
import '../../core/providers/people.dart' show blockedChatIds, blockedPeersProvider;
import '../../core/providers/settings_providers.dart';
import '../../core/services/net_service.dart';
import '../../core/services/permissions.dart';
import '../../src/rust/api/simple.dart' as core;
import 'call_path.dart';
import 'call_quality.dart';
import 'call_timeline.dart';
import 'callkit_bridge.dart';
import 'livekit_engine.dart';
import 'ringback.dart';
import '../../core/background_connection.dart' show backgroundConnectionProvider;
import '../../core/haptics.dart';
import 'silent_mic_watch.dart';
import '../../l10n/l10n.dart';

/// Fallback HTTP base URL for calls when the app isn't connected to a
/// server yet (tests, dev builds). Normally calls use the server chosen in
/// the app — the same one messages go to (`NetService.httpBaseUrl`). The
/// call FFI hits `/v1/call/token` + `/v1/call/turn` against that base; the
/// LiveKit room URL returned by the token mint then drives the actual
/// WebRTC signaling connect.
const String _kCallHttpBaseUrl = String.fromEnvironment('SINHRON_HTTP_URL', defaultValue: 'http://localhost:8080');

/// High-level lifecycle phase. UI route is driven by this.
enum CallPhase {
  /// No call in progress.
  idle,

  /// We invited a peer; awaiting `CallRing` from server then `CallAccept`
  /// from the peer.
  outgoingRinging,

  /// Peer invited us; awaiting our user's decision.
  incomingRinging,

  /// Both sides agreed. LiveKit room is connecting / connected — actual
  /// media flow status surfaces in a separate field once D6 lands.
  connected,

  /// Call has ended (hangup / decline / no_answer / network / etc.).
  /// Held briefly so UI can show "Call ended" before returning to idle.
  ended,
}

/// CE5 — secondary network-status overlay, ortho to [CallPhase].
/// `connected` is normal; `reconnecting` means LiveKit lost the signal
/// path and is trying to recover (no auto-end yet); `lost` is permanent
/// and the call has been auto-ended (we just haven't returned to idle
/// yet).
enum CallNetworkStatus { connected, reconnecting, lost }

enum CallKind { audio, video }

extension on CallKind {
  String get wireString => this == CallKind.audio ? 'audio' : 'video';
}

CallKind callKindFromWire(String s) => s == 'video' ? CallKind.video : CallKind.audio;

/// Immutable snapshot of the active call. UI reads this from
/// [activeCallProvider]. `null` when no call.
@immutable
class ActiveCallState {
  /// Local lifecycle phase.
  final CallPhase phase;

  /// UUIDv7 chosen by the caller. Unique per call attempt.
  final String? callId;

  /// MLS group_id (hex). Same as the chat's group_id — 1:1 chat = 1:1 group.
  final String? groupIdHex;

  /// Audio-only vs video.
  final CallKind kind;

  /// Whether WE initiated the call. Drives "Caller" vs "Callee" UI.
  final bool isCaller;

  /// Server-supplied LiveKit room name. Used in CD6 to connect.
  final String? livekitRoom;

  /// When the call moved to Connected. Used to compute call duration
  /// shown in the active-call bar.
  final DateTime? connectedAt;

  /// Last terminal reason (`hangup` / `no_answer` / `rejected` / …).
  /// Set when phase=ended.
  final String? endReason;

  /// Surfaced error from a failed invite/accept (permission denied,
  /// no group, etc.). Null on success paths.
  final String? error;

  /// CE5 — current network status of the LiveKit media path. Defaults
  /// to `connected` outside an active session (read by UI only when
  /// phase=connected).
  final CallNetworkStatus networkStatus;

  /// Sound goes to the loudspeaker (owner, 2026-10-15: the icon was a guess
  /// — video calls turn it on by themselves; headphones / Bluetooth take
  /// the sound and the speaker is then off).
  final bool speakerOn;

  /// ADR-041 — my camera is being sent (live from the room).
  final bool cameraOn;

  /// ADR-041 — LiveKit's grade of MY link, and whether anyone else's is
  /// poor/lost. The call screen shows bars and one line about it.
  final CallLinkQuality linkQuality;
  final bool peerLinkBad;

  /// ADR-041 — my link stayed poor, so the app switched my camera off to
  /// keep the voice (cleared when I turn it back on).
  final bool autoAudioOnly;

  /// ADR-042 — the call is rejoining through the reserve path (443).
  final bool switchingPath;

  /// Status 213 — my call reached their phone (the server saw the invite
  /// delivered): "Ringing…" instead of "Calling…".
  final bool peerRinging;

  /// Tech-debt 2.38 — the link keeps dropping on the reserve path too.
  final bool keepsDropping;

  /// My microphone is off — kept here so the call screen, reopened from
  /// the call bar, shows it (it reset to "on" — 2026-10-16 UI audit).
  final bool micMuted;

  /// An incoming call the app rings itself — its own call screen — because
  /// the system isn't showing it (owner, 2026-10-18: the system banner and
  /// the app's screen both came up). iPhone: CallKit shows every incoming
  /// call (false here, except the Simulator); Android: the app's screen
  /// while it's in front, the call notification otherwise.
  final bool ringsInApp;

  /// When the other side's sound started arriving (a group call: when I
  /// joined the room). Null while connecting — the screen says
  /// "Connecting…" instead of a timer that runs over silence.
  final DateTime? audioAt;

  /// A 1:1 call: the other person's microphone is off (muted, or not sent
  /// at all). The call screen and the call bar show a crossed mic (owner,
  /// 2026-10-19: "no sign that the other side muted"). Group calls: false —
  /// each tile shows its own.
  final bool peerMicOff;

  /// When the call ended here (null before). With [audioAt] it gives the
  /// talk time the "Call ended" screen, the call bar and the history show.
  final DateTime? endedAt;

  /// Answered, but no sound yet.
  bool get connecting => phase == CallPhase.connected && audioAt == null;

  /// How long we talked: from the other side's sound (the timer's start —
  /// [audioAt], or the answer if the sound never came) to the end, or to
  /// [now] while it goes on. Null for a call that never connected. Owner,
  /// 2026-10-19: the ended screen said "00:00" after minutes of talk, while
  /// the history counted from the answer.
  Duration? talkTime({DateTime? now}) {
    final from = audioAt ?? connectedAt;
    if (from == null) return null;
    final d = (endedAt ?? now ?? DateTime.now()).difference(from);
    return d.isNegative ? Duration.zero : d;
  }

  CallNotice get notice => callNoticeFor(
    mine: linkQuality,
    peerBad: peerLinkBad,
    autoAudioOnly: autoAudioOnly,
    switchingPath: switchingPath,
    keepsDropping: keepsDropping,
  );

  const ActiveCallState({
    this.phase = CallPhase.idle,
    this.callId,
    this.groupIdHex,
    this.kind = CallKind.audio,
    this.isCaller = false,
    this.livekitRoom,
    this.connectedAt,
    this.endReason,
    this.error,
    this.networkStatus = CallNetworkStatus.connected,
    this.speakerOn = false,
    this.cameraOn = false,
    this.linkQuality = CallLinkQuality.unknown,
    this.peerLinkBad = false,
    this.autoAudioOnly = false,
    this.switchingPath = false,
    this.peerRinging = false,
    this.keepsDropping = false,
    this.micMuted = false,
    this.ringsInApp = false,
    this.audioAt,
    this.peerMicOff = false,
    this.endedAt,
  });

  const ActiveCallState.idle() : this();

  /// True iff the call is in any pre-terminal state (UI shows call_screen
  /// in any of these).
  bool get isActive =>
      phase == CallPhase.outgoingRinging || phase == CallPhase.incomingRinging || phase == CallPhase.connected;

  ActiveCallState copyWith({
    CallPhase? phase,
    String? callId,
    String? groupIdHex,
    CallKind? kind,
    bool? isCaller,
    String? livekitRoom,
    DateTime? connectedAt,
    String? endReason,
    String? error,
    bool clearError = false,
    CallNetworkStatus? networkStatus,
    bool? speakerOn,
    bool? cameraOn,
    CallLinkQuality? linkQuality,
    bool? peerLinkBad,
    bool? autoAudioOnly,
    bool? switchingPath,
    bool? peerRinging,
    bool? keepsDropping,
    bool? micMuted,
    bool? ringsInApp,
    DateTime? audioAt,
    bool? peerMicOff,
    DateTime? endedAt,
  }) {
    return ActiveCallState(
      phase: phase ?? this.phase,
      callId: callId ?? this.callId,
      groupIdHex: groupIdHex ?? this.groupIdHex,
      kind: kind ?? this.kind,
      isCaller: isCaller ?? this.isCaller,
      livekitRoom: livekitRoom ?? this.livekitRoom,
      connectedAt: connectedAt ?? this.connectedAt,
      endReason: endReason ?? this.endReason,
      error: clearError ? null : (error ?? this.error),
      networkStatus: networkStatus ?? this.networkStatus,
      speakerOn: speakerOn ?? this.speakerOn,
      cameraOn: cameraOn ?? this.cameraOn,
      linkQuality: linkQuality ?? this.linkQuality,
      peerLinkBad: peerLinkBad ?? this.peerLinkBad,
      autoAudioOnly: autoAudioOnly ?? this.autoAudioOnly,
      switchingPath: switchingPath ?? this.switchingPath,
      peerRinging: peerRinging ?? this.peerRinging,
      keepsDropping: keepsDropping ?? this.keepsDropping,
      micMuted: micMuted ?? this.micMuted,
      ringsInApp: ringsInApp ?? this.ringsInApp,
      audioAt: audioAt ?? this.audioAt,
      peerMicOff: peerMicOff ?? this.peerMicOff,
      endedAt: endedAt ?? this.endedAt,
    );
  }
}

/// A participant's microphone: muted (true), on (false), or not sent at
/// all (null — no mic, or not published yet).
bool? participantMicMuted(lk_track.Participant p) =>
    p.getTrackPublicationBySource(lk_track.TrackSource.microphone)?.muted;

/// A 1:1 call: everyone else (the one person) has the mic off or sends
/// none. Nobody there yet, or a group call → false.
bool peerMicOffFrom(List<bool?> mics, {required bool group}) =>
    !group && mics.isNotEmpty && mics.every((m) => m ?? true);

/// Where a finished call goes: this phone's call history and, for a call I
/// missed, a line in its chat (overnight item 5). Faked in tests.
abstract class CallLog {
  Future<void> append({
    required String id,
    required String chatId,
    required bool video,
    required String status,
    required bool outgoing,
    required int startedAtUnix,
    required int endedAtUnix,
    int? durationSecs,
  });

  /// "Missed call" / "Missed video call" in the chat.
  Future<void> missedLine(String chatId, {required bool video});
}

class CoreCallLog implements CallLog {
  CoreCallLog(this._ref);
  final Ref _ref;

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
  }) => core.storageCallAppend(
    id: id,
    peerChatId: chatId,
    kind: video ? 'video' : 'audio',
    status: status,
    isOutgoing: outgoing,
    startedAtUnix: startedAtUnix,
    endedAtUnix: endedAtUnix,
    durationSecs: durationSecs,
  );

  @override
  Future<void> missedLine(String chatId, {required bool video}) async {
    await _ref.read(messageActionsProvider).callLine(chatId, video ? 'call-missed:video' : 'call-missed:audio');
    // ADR-066 — and a notification when Sinhron is off screen.
    maybeNotifyMissedCall(_ref, chatId, video: video);
  }
}

final callLogProvider = Provider<CallLog>((ref) => CoreCallLog(ref));

/// The media side of a call (LiveKit) — faked in tests.
/// Status 184 — when the call rooms are checked after a call ends.
const kRoomSweepDelays = [Duration(milliseconds: 300), Duration(seconds: 3), Duration(seconds: 10)];

class CallEngine {
  const CallEngine();

  Future<CallPrep> prepare({required String httpBaseUrl, required String groupIdHex, required String kind}) =>
      LiveKitCallEngine.prepare(httpBaseUrl: httpBaseUrl, groupIdHex: groupIdHex, kind: kind);

  Future<LiveKitSession> connect({
    required CallPrep prep,
    void Function()? onReconnecting,
    void Function()? onReconnected,
    void Function(String reason)? onDisconnected,
    CallPath path = CallPath.direct,
    bool micMuted = false,
    bool camera = true,
    CallTimeline? timeline,
    bool? speaker,
  }) => LiveKitCallEngine.connect(
    prep: prep,
    onReconnecting: onReconnecting,
    onReconnected: onReconnected,
    onDisconnected: onDisconnected,
    path: path,
    micMuted: micMuted,
    camera: camera,
    timeline: timeline,
    speaker: speaker,
  );
}

final callEngineProvider = Provider<CallEngine>((ref) => const CallEngine());

/// 2026-10-26 — the server's CallEnd reasons when I answered / declined on
/// another of my devices: this one stops ringing.
const kAnsweredElsewhere = 'answered_elsewhere';
const kDeclinedElsewhere = 'declined_elsewhere';

/// History status of a finished call: `completed` once it connected;
/// otherwise `declined` (one side said no), `busy`, `no_answer` (my call
/// nobody took) or `missed` (a call to me I didn't take — whatever the
/// reason the caller gave).
String callStatusFromReason(String reason, {required bool connected, required bool outgoing}) {
  if (connected) return 'completed';
  if (reason == 'declined' || reason == kDeclinedElsewhere) return 'declined'; // I declined it (here or on my other device)
  if (reason == kAnsweredElsewhere) return kAnsweredElsewhere;
  if (outgoing) {
    return switch (reason) {
      'rejected' => 'declined',
      'busy' => 'busy',
      'no_answer' => 'no_answer',
      _ => 'cancelled', // I hung up before they answered
    };
  }
  return 'missed';
}

/// Riverpod 3.x `Notifier`-style surface. Public methods:
///   • [invite] — start an outgoing call. Caller picks the group_id +
///     kind; UUIDv7 generated internally.
///   • [accept] — picks up an incoming invite.
///   • [decline] — rejects an incoming invite.
///   • [end] — hang up an in-progress call.
/// How long "Call ended" stays on screen before the call screen closes.
const kCallEndedHold = Duration(milliseconds: 800);

class ActiveCallNotifier extends Notifier<ActiveCallState> {
  StreamSubscription<core.NetEvent>? _sub;
  Timer? _idleResetTimer;

  /// Nobody answered: the server ends a ringing call after its TTL (30 s)
  /// with `no_answer`; this is the fallback when that never arrives
  /// (offline, server restarted). Tests shorten it.
  static Duration ringTimeout = const Duration(seconds: 45);
  Timer? _ringTimer;

  void _startRingTimer() {
    _ringTimer?.cancel();
    final callId = state.callId;
    _ringTimer = Timer(ringTimeout, () {
      if (state.callId != callId) return;
      if (state.phase == CallPhase.outgoingRinging) {
        unawaited(end(reason: 'no_answer'));
      } else if (state.phase == CallPhase.incomingRinging) {
        _transitionToEnded('no_answer'); // the caller's end never came
      }
    });
  }

  /// CD6 — live LiveKit session. `null` outside Active calls. Set when
  /// we transition to Connected (server-confirmed CallAccept); torn
  /// down on End / decline / timeout.
  /// The live room for the call screen's video (null outside a
  /// connected call). Listenable so the screen appears when media does.
  final room = ValueNotifier<lk_room.Room?>(null);

  LiveKitSession? _session;

  /// The join in progress (null when none) and its call — a second start
  /// for the same call waits for it.
  Future<void>? _starting;
  String? _startingCall;

  /// The session was joined while my call rang: mic silent, no camera yet.
  bool _early = false;

  /// Token + TURN creds fetched while ringing, for [_prepCall].
  Future<CallPrep>? _prep;
  String? _prepCall;
  bool _prepReady = false;

  /// Setup marks of the call now (diagnostics panel, `[call-timing]` log).
  final timeline = CallTimeline();

  /// The other side's voice level, 0..1 (LiveKit's speaker updates) — the
  /// call screen's bars follow it.
  final peerVoice = ValueNotifier<double>(0);

  /// ADR-046 — this phone's class for the live call (screen sharing sizes
  /// its picture by it — ADR-061). Standard outside a call.
  CallDeviceClass get deviceClass => _session?.deviceClass ?? CallDeviceClass.standard;

  @override
  ActiveCallState build() {
    final net = ref.read(netServiceProvider);
    _sub = net.callEvents.listen(_handleEvent);
    // Owner, 2026-10-19 — a ringback while my call rings over there; silent
    // the moment they answer, decline or the call ends.
    final ringback = ref.read(ringbackProvider);
    listenSelf((prev, next) {
      final was = prev != null && ringbackWanted(prev);
      final now = ringbackWanted(next);
      if (now && !was) unawaited(ringback.start());
      if (was && !now) unawaited(ringback.stop());
    });
    // CE1 — register CallKit event listener. User actions in the
    // native CallKit UI (Accept / End / Mute) route back here.
    callKitBridge.registerEventCallback(_handleCallKitEvent);
    // Tech-debt 2.27 — load the call screening settings up front so an
    // invite can be checked synchronously.
    ref.read(incomingCallsProvider.future).ignore();
    // The system call UI's name follows Settings → what notifications show.
    ref.read(notificationPreviewProvider.future).ignore();
    ref.read(blockedChatsProvider.future).ignore();
    ref.onDispose(() {
      _sub?.cancel();
      _idleResetTimer?.cancel();
      _ringTimer?.cancel();
      _reconnectingWatchdog?.cancel();
      _deviceSub?.cancel();
      _fallbackTimer?.cancel();
      for (final t in _roomSweeps) {
        t.cancel();
      }
      unawaited(ringback.stop());
      _teardownLiveKit();
      peerVoice.dispose();
    });
    return const ActiveCallState.idle();
  }

  /// CE1 — route native CallKit user actions into the FSM.
  void _handleCallKitEvent(CallKitEvent event) {
    if (event.kind == CallKitEventKind.pushCall) {
      // Status 223 — iOS woke the app for a call: open the connection (the
      // invite comes in, and "answered on another device" can reach it).
      // It stays open while the call rings or runs, else closes again.
      final bg = ref.read(backgroundConnectionProvider);
      unawaited(bg.openForPush());
      Timer(const Duration(seconds: 50), () => unawaited(bg.closeAfterPush()));
      return;
    }
    if (event.callId != state.callId) return;
    switch (event.kind) {
      case CallKitEventKind.accept:
        // User tapped Accept in CallKit UI.
        if (state.phase == CallPhase.incomingRinging) {
          // ignore: discarded_futures
          accept(fromSystem: true);
        }
        break;
      case CallKitEventKind.end:
        // User tapped End in CallKit UI. Still ringing = Decline (also a
        // decline tapped on the lock screen before the app had the invite —
        // overnight item 9); otherwise the Hangup button.
        // ignore: discarded_futures
        state.phase == CallPhase.incomingRinging ? decline() : end();
        break;
      case CallKitEventKind.mute:
        // User toggled mute in CallKit UI. Route to LiveKit room.
        // ignore: discarded_futures
        setMicrophoneMuted(event.muted);
        break;
      case CallKitEventKind.showInApp:
        // Android: the app came to the front while its call notification
        // rang (the notification is gone now) — the app's own screen rings.
        if (state.phase == CallPhase.incomingRinging && !state.ringsInApp) state = state.copyWith(ringsInApp: true);
        break;
      case CallKitEventKind.pushCall:
        break; // handled above
    }
  }

  /// Start an outgoing call. Returns the new `call_id` on success.
  /// Throws if no peer / not connected / permissions denied.
  Future<String> invite({required String groupIdHex, required CallKind kind}) async {
    if (state.isActive) {
      throw StateError('another call is in progress: phase=${state.phase}');
    }
    // No calling someone I blocked (owner, 2026-10-18: it still worked).
    if (await _blockedPersonalChat(groupIdHex)) throw StateError('blocked');

    // Permission gates BEFORE we hit the wire — better UX than failing
    // half-way through the LiveKit room connect.
    const perms = CallPermissionsService();
    final mic = await perms.requestMic();
    if (mic != CallPermission.granted) {
      state = state.copyWith(phase: CallPhase.idle, error: 'microphone permission required');
      throw StateError('microphone permission ${mic.name}');
    }
    if (kind == CallKind.video) {
      final cam = await perms.requestCamera();
      if (cam != CallPermission.granted) {
        state = state.copyWith(phase: CallPhase.idle, error: 'camera permission required');
        throw StateError('camera permission ${cam.name}');
      }
    }

    final callId = const Uuid().v7();
    // Optimistically move to OutgoingRinging so the call screen can
    // render the "Calling…" state immediately. If the server rejects
    // the invite, the catch below reverts.
    state = ActiveCallState(
      phase: CallPhase.outgoingRinging,
      callId: callId,
      groupIdHex: groupIdHex,
      kind: kind,
      speakerOn: kind == CallKind.video, // status 223 — the starting choice; buttons change it before the join
      isCaller: true,
      livekitRoom: 'sinhron-call-$callId',
    );

    try {
      await core.netSendCallInvite(callId: callId, groupIdHex: groupIdHex, kind: kind.wireString, ttlSecs: 30);
    } catch (e) {
      // Hung up while the invite was going out — nothing to report.
      if (state.callId != callId) return callId;
      state = const ActiveCallState.idle().copyWith(error: 'invite failed: $e');
      rethrow;
    }
    // Hung up while the invite was going out (2026-10-16 UI audit): no
    // ring timer, no CallKit call that nothing would end.
    if (state.callId != callId || state.phase != CallPhase.outgoingRinging) return callId;
    if (_isGroupChat(groupIdHex)) {
      ref
          .read(ongoingGroupCallsProvider.notifier)
          .put(
            OngoingCall(
              callId: callId,
              groupIdHex: groupIdHex,
              kind: kind,
              livekitRoom: 'sinhron-call-$callId',
              since: DateTime.now(),
            ),
          );
    }
    _startRingTimer();
    // CE1 — declare outgoing call to CallKit so system audio session
    // gets reserved + outgoing call UI surfaces. Fire-and-forget.
    // ignore: discarded_futures
    callKitBridge.startCall(
      callId: callId,
      peerName: _systemCallName(groupIdHex),
      video: kind == CallKind.video,
    );
    // Join the room while it rings, mic silent: on the answer only the mic
    // opens (it used to fetch a token, join and publish only then).
    _prefetch();
    unawaited(_startLiveKitSession(early: true));
    return callId;
  }

  Future<bool> _blockedPersonalChat(String chatId) async {
    try {
      final chat = (await ref.read(chatsProvider.future)).where((c) => c.id == chatId).firstOrNull;
      final peer = chat?.peerId?.toLowerCase();
      if (chat == null || chat.group || peer == null) return false;
      return (await ref.read(blockedPeersProvider.future)).contains(peer);
    } catch (_) {
      return false; // storage not open (tests) — no opinion
    }
  }

  /// Callee accepts a pending IncomingRinging invite. [fromSystem]: the
  /// accept came from CallKit / the call notification, which already knows;
  /// otherwise (the app's own Accept button) tell it, so its banner closes.
  Future<void> accept({bool fromSystem = false}) async {
    final callId = state.callId;
    if (callId == null || state.phase != CallPhase.incomingRinging) {
      throw StateError('no incoming call to accept (phase=${state.phase})');
    }
    // A second tap (Accept here and on the system banner, or a double tap)
    // while the first is still asking for the mic / reaching the server
    // would join the room twice (2026-10-16 UI audit).
    if (_accepting == callId) return;
    _accepting = callId;
    try {
      await _accept(callId, fromSystem: fromSystem);
    } finally {
      if (_accepting == callId) _accepting = null;
    }
  }

  String? _accepting;

  Future<void> _accept(String callId, {required bool fromSystem}) async {
    if (!fromSystem) unawaited(callKitBridge.answer(callId));

    // Permission gates on accept side too — callee may not have
    // pre-granted camera even if they have mic.
    const perms = CallPermissionsService();
    final mic = await perms.requestMic();
    if (mic != CallPermission.granted) {
      // Auto-decline with reason — informs caller we couldn't pick up.
      await _autoEndWithReason('mic_permission_denied');
      return;
    }
    if (state.kind == CallKind.video) {
      final cam = await perms.requestCamera();
      if (cam != CallPermission.granted) {
        await _autoEndWithReason('camera_permission_denied');
        return;
      }
    }

    // The caller may have hung up while the permission sheet was up.
    if (state.callId != callId || state.phase != CallPhase.incomingRinging) return;
    _ringTimer?.cancel();
    timeline.start();
    if (_prepReady) timeline.mark('prep');
    final ringing = state;
    state = state.copyWith(phase: CallPhase.connected, connectedAt: DateTime.now(), clearError: true);
    // CD6 — join the room now, alongside telling the server (that used to
    // come first, a round trip before anything else started). The token
    // was fetched while it rang. Engine errors surface via state.error.
    unawaited(_startLiveKitSession());
    try {
      await core.netSendCallAccept(callId: callId, accept: true);
    } catch (e) {
      if (state.callId != callId) return;
      // The answer didn't reach the server: leave the room, ring again.
      await _teardownLiveKit();
      if (state.callId != callId || state.phase != CallPhase.connected) return;
      state = ringing.copyWith(error: 'accept send failed: $e');
      _startRingTimer();
      rethrow;
    }
    if (state.callId != callId) return;
    timeline.mark('accept');
    _keepAlive();
  }

  /// Join a group call that is already going (I declined, missed it, or
  /// stepped out) — "Join" in the chat. The server lets any group member
  /// back in while the call runs.
  Future<void> join(OngoingCall c) async {
    if (state.isActive) {
      throw StateError('another call is in progress: phase=${state.phase}');
    }
    const perms = CallPermissionsService();
    if (await perms.requestMic() != CallPermission.granted) {
      state = state.copyWith(error: 'microphone permission required');
      throw StateError('microphone permission denied');
    }
    state = ActiveCallState(
      phase: CallPhase.connected,
      callId: c.callId,
      groupIdHex: c.groupIdHex,
      kind: c.kind,
      speakerOn: c.kind == CallKind.video, // status 223 — the starting choice; buttons change it before the join
      isCaller: false,
      livekitRoom: c.livekitRoom,
      connectedAt: DateTime.now(),
    );
    timeline.start();
    // Into the room alongside telling the server (as with Accept).
    unawaited(_startLiveKitSession());
    try {
      await core.netSendCallAccept(callId: c.callId, accept: true);
    } catch (e) {
      // The call is gone (or we're offline): forget it.
      ref.read(ongoingGroupCallsProvider.notifier).endCall(c.callId);
      await _teardownLiveKit();
      state = const ActiveCallState.idle().copyWith(error: 'join failed: $e');
      rethrow;
    }
    timeline.mark('accept');
    _keepAlive();
  }

  /// From the loaded chat list (a call can only be joined in a chat I have).
  bool _isGroupChat(String groupIdHex) =>
      (ref.read(chatsProvider).value ?? const []).any((c) => c.id == groupIdHex && c.group);

  /// Callee declines a pending IncomingRinging invite. Server translates
  /// this to a CallEnd{reason="rejected"} on the caller side.
  Future<void> decline() async {
    final callId = state.callId;
    if (callId == null || state.phase != CallPhase.incomingRinging) {
      throw StateError('no incoming call to decline (phase=${state.phase})');
    }
    try {
      await core.netSendCallAccept(callId: callId, accept: false);
    } catch (_) {
      // Ignore network errors — local state cleanup still proceeds.
    }
    _transitionToEnded('declined');
  }

  /// Either-side hangup. Works in Outgoing/Incoming/Connected.
  Future<void> end({String reason = 'hangup'}) async {
    final callId = state.callId;
    if (callId == null || state.phase == CallPhase.idle || state.phase == CallPhase.ended) return;
    // Camera and microphone off first (owner, 2026-10-16: after "hang up"
    // the other side kept seeing me live for seconds — the media stopped
    // only after the server had the end, on a slow link that took long).
    _transitionToEnded(reason);
    try {
      await core.netSendCallEnd(callId: callId, reason: reason);
    } catch (_) {
      // The call is over here either way; the server ends it on its own.
    }
  }

  // ── Inbound event handling ────────────────────────────────────────

  void _handleEvent(core.NetEvent event) {
    switch (event.kind) {
      case 'call_invite':
        final ci = event.callInvite;
        if (ci != null) unawaited(_onIncomingInvite(ci));
        break;
      case 'call_ring':
        // Server confirmed our outgoing invite; [delivered]: their phone has
        // it (now or once it woke) — the screen says "Ringing…".
        final cr = event.callRing;
        if (cr != null && ringReachedThem(state, callId: cr.callId, delivered: cr.delivered)) {
          state = state.copyWith(peerRinging: true);
        }
        break;
      case 'call_accept':
        final ca = event.callAccept;
        if (ca != null) _onRemoteAccept(ca);
        break;
      case 'call_end':
        final ce = event.callEnd;
        if (ce != null) {
          ref.read(ongoingGroupCallsProvider.notifier).endCall(ce.callId);
          _onRemoteEnd(ce);
        }
        break;
    }
  }

  /// Calls off, a personal chat with someone blocked here, a message
  /// request, or a chat this device doesn't have → don't ring (tech-debt
  /// 2.27). Settings and the chat list are awaited, not read half-loaded:
  /// at cold start a "not loaded yet" must not let a screened call ring.
  Future<bool> _screenedOut(String groupIdHex, {String callerIdentityHex = ''}) async {
    Future<T?> load<T>(Future<T> f) async {
      try {
        return await f;
      } catch (_) {
        return null; // storage not open (tests, onboarding) — no opinion
      }
    }

    // ADR-090 (calls:5) — no caller means the caller didn't sign this invite
    // (or isn't in the chat): only the server wrote it. It doesn't ring.
    if (callerIdentityHex.isEmpty) return true;
    if (await load(ref.read(incomingCallsProvider.future)) == false) return true;
    final blocked = await load(ref.read(blockedChatsProvider.future)) ?? '';
    if (blockedChatIds(blocked).contains(groupIdHex)) return true;
    // Tech-debt 2.27 — a group call from someone I blocked.
    final people = await load(ref.read(blockedPeersProvider.future)) ?? const <String>{};
    if (people.contains(callerIdentityHex.toLowerCase())) return true;
    final chats = await load(ref.read(chatsProvider.future));
    if (chats != null) {
      final chat = chats.where((c) => c.id == groupIdHex).firstOrNull;
      // Deleted / never-joined chats and requests don't ring.
      if (chat == null || chat.request) return true;
      // A personal chat with someone I blocked, wherever I blocked them.
      final peer = chat.peerId?.toLowerCase();
      if (!chat.group && peer != null) {
        final people = await load(ref.read(blockedPeersProvider.future)) ?? const <String>{};
        if (people.contains(peer)) return true;
      }
    }
    return false;
  }

  /// Calls that ended while their invite was still being screened.
  final Set<String> _endedWhileScreening = {};

  Future<void> _onIncomingInvite(core.NetCallInvite ci) async {
    // Loaded before the system UI names the caller ("nothing" → "Sinhron").
    await ref.read(notificationPreviewProvider.future).catchError((Object _) => NotificationPreview.nameAndText);
    if (await _screenedOut(ci.groupIdHex, callerIdentityHex: ci.callerIdentityHex)) {
      // Ignored, not declined: a decline would tell the caller this device
      // is online and screening them, and (calls are per person on the
      // server) end the call on my other devices that would ring. A VoIP
      // push may have put it on the lock screen already — take it down.
      unawaited(callKitBridge.dismiss(ci.callId));
      return;
    }
    if (_endedWhileScreening.remove(ci.callId)) {
      unawaited(callKitBridge.dismiss(ci.callId));
      return;
    }
    // A group call: remember it, so the chat can offer "Join" after I
    // decline or miss the ring (it goes away with the call's CallEnd).
    if (_isGroupChat(ci.groupIdHex)) {
      ref
          .read(ongoingGroupCallsProvider.notifier)
          .put(
            OngoingCall(
              callId: ci.callId,
              groupIdHex: ci.groupIdHex,
              kind: callKindFromWire(ci.kind),
              livekitRoom: ci.livekitRoom,
              since: DateTime.now(),
            ),
          );
    }
    // Status 223 — a second copy of the call I'm already ringing / in (the
    // server replays ringing invites when one of my devices connects): not
    // a new call — it used to answer "busy" and end it for the caller.
    if (ci.callId == state.callId) return;
    // If we're already in a call, auto-decline the new one (server
    // rejected it as 409 group-busy already; but our group could
    // differ, so we double-check).
    if (state.isActive) {
      // Busy: the caller hears "busy" (a 1:1 call ends; in a group the
      // server tells nobody and the call goes on). Fire-and-forget — a
      // failure must not disturb the call I'm in. Here it's a missed call.
      try {
        unawaited(core.netSendCallEnd(callId: ci.callId, reason: 'busy').catchError((_) {}));
      } catch (_) {}
      final video = ci.kind == 'video';
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      unawaited(
        _log(
          (l) => l.append(
            id: ci.callId,
            chatId: ci.groupIdHex,
            video: video,
            status: 'missed',
            outgoing: false,
            startedAtUnix: now,
            endedAtUnix: now,
          ),
        ),
      );
      unawaited(_log((l) => l.missedLine(ci.groupIdHex, video: video)));
      return;
    }
    state = ActiveCallState(
      phase: CallPhase.incomingRinging,
      callId: ci.callId,
      groupIdHex: ci.groupIdHex,
      kind: callKindFromWire(ci.kind),
      speakerOn: callKindFromWire(ci.kind) == CallKind.video, // status 223 — the starting choice; buttons change it before the join
      isCaller: false,
      livekitRoom: ci.livekitRoom,
    );
    _startRingTimer();
    // The token and TURN creds now, while it rings — Accept then joins.
    _prefetch();
    // CE1 — the system's incoming-call UI: CallKit (iPhone), the call
    // notification (Android, app not in front). Only when it isn't showing
    // does the app open its own ringing screen — one UI, not both (owner,
    // 2026-10-18).
    unawaited(
      callKitBridge
          .reportIncoming(callId: ci.callId, peerName: _systemCallName(ci.groupIdHex), video: ci.kind == 'video')
          .then((bySystem) {
            if (!bySystem && state.callId == ci.callId && state.phase == CallPhase.incomingRinging) {
              state = state.copyWith(ringsInApp: true);
            }
          }),
    );
  }

  void _onRemoteAccept(core.NetCallAccept ca) {
    if (state.callId != ca.callId) return;
    // Only my own outgoing ring is answered by this frame (audit 2026-11b
    // #20): on an incoming ring it made the phone "answer" by itself, mic
    // on — only accept() answers that. A group call: the next members'
    // answers change nothing here (they used to restart the timer).
    if (!state.isCaller || state.phase != CallPhase.outgoingRinging) return;
    if (!ca.accept) {
      // accept=false from the other side = decline.
      _transitionToEnded('rejected');
      return;
    }
    _answered();
  }

  /// Tests: the call is answered, without the permission sheet / the server.
  @visibleForTesting
  void debugAnswered() => _answered();

  void _answered() {
    _ringTimer?.cancel();
    timeline.start();
    if (_prepReady) timeline.mark('prep');
    state = state.copyWith(phase: CallPhase.connected, connectedAt: DateTime.now(), clearError: true);
    // Status 213 — a short tap when they answer (as FaceTime does): the
    // phone may be at the ear, away from the screen.
    unawaited(ref.read(hapticsProvider).play(Haptic.success));
    _keepAlive();
    // CD6 — caller side: callee accepted. Usually we're in the room
    // already (joined while ringing): the mic opens, the camera starts.
    unawaited(_goLive());
  }

  void _onRemoteEnd(core.NetCallEnd ce) {
    final elsewhere = ce.reason == kAnsweredElsewhere || ce.reason == kDeclinedElsewhere;
    if (state.callId != ce.callId) {
      // A call a push already put on screen that this app hasn't taken up.
      // Status 223 — any other end (they hung up, nobody answered) stops its
      // ring too; it used to ring on until the 45 s fallback.
      unawaited(
        elsewhere
            ? callKitBridge.endedElsewhere(ce.callId, answered: ce.reason == kAnsweredElsewhere)
            : callKitBridge.dismiss(ce.callId),
      );
      _endedWhileScreening.add(ce.callId);
      if (_endedWhileScreening.length > 32) _endedWhileScreening.remove(_endedWhileScreening.first);
      return;
    }
    // About my other devices: this one is in the call (it answered here).
    if (elsewhere && state.phase != CallPhase.incomingRinging) return;
    _transitionToEnded(ce.reason);
  }

  Future<void> _autoEndWithReason(String reason) async {
    final callId = state.callId;
    if (callId == null) return;
    try {
      await core.netSendCallEnd(callId: callId, reason: reason);
    } catch (_) {}
    _transitionToEnded(reason);
  }

  /// Status 184 (owner, 2026-10-19: "the call isn't shown but I hear the
  /// voice; the mic is still on after the call ended") — once no call is
  /// on, no call room may stay open: right after the end, and again after
  /// 3 s and 10 s for a join that finished late.
  final List<Timer> _roomSweeps = [];

  void _sweepRoomsSoon() {
    for (final t in _roomSweeps) {
      t.cancel();
    }
    _roomSweeps
      ..clear()
      ..addAll([
        for (final d in kRoomSweepDelays)
          Timer(d, () {
            if (!state.isActive) unawaited(closeOrphanCallRooms(keep: _session?.room));
          }),
      ]);
  }

  void _transitionToEnded(String reason) {
    _ringTimer?.cancel();
    _prep = null;
    _prepCall = null;
    _prepReady = false;
    final priorState = state;
    final ended = state = state.copyWith(phase: CallPhase.ended, endReason: reason, endedAt: DateTime.now());
    // CD6 — tear down LiveKit room before we drop the call_id from
    // local state. Fire-and-forget; disconnect is idempotent.
    unawaited(_teardownLiveKit());
    _sweepRoomsSoon();
    // CE1 — tell CallKit the call ended. Idempotent native-side if
    // CallKit never had this call_id registered (e.g. background
    // incoming without PushKit).
    if (priorState.callId != null) {
      if (reason == kAnsweredElsewhere || reason == kDeclinedElsewhere) {
        // ignore: discarded_futures
        callKitBridge.endedElsewhere(priorState.callId!, answered: reason == kAnsweredElsewhere);
      } else {
        // ignore: discarded_futures
        callKitBridge.endCall(priorState.callId!);
      }
    }
    // CD9 — persist a row in the calls history table, from the ended
    // state (callId, groupIdHex, kind, and its end time). Reason maps to
    // status: in v1 we keep them aligned (status = reason verbatim,
    // already truncated to 64 chars at server-side). Duration is only
    // meaningful for completed calls (those that reached Connected).
    unawaited(_persistCallHistory(ended, reason));
    // Hold the "Ended" screen just long enough to read it, then close
    // (2 s felt like the call wouldn't end — owner, 2026-10-16).
    _idleResetTimer?.cancel();
    _idleResetTimer = Timer(kCallEndedHold, () {
      if (state.phase == CallPhase.ended) {
        state = const ActiveCallState.idle();
      }
    });
  }

  /// CD9 — append the call to local history. Best-effort; failures
  /// don't propagate (we already moved to Ended state).
  Future<void> _persistCallHistory(ActiveCallState call, String reason) async {
    final callId = call.callId;
    final groupId = call.groupIdHex;
    if (callId == null || groupId == null) return;

    final now = call.endedAt ?? DateTime.now();
    final nowUnix = now.millisecondsSinceEpoch ~/ 1000;
    // started_at: if we have a connectedAt, use it; otherwise approximate
    // as now (we don't track invite-time separately).
    final startedAt = call.connectedAt != null ? call.connectedAt!.millisecondsSinceEpoch ~/ 1000 : nowUnix;
    // The talk time the call screen showed (from the sound, not the answer).
    final duration = call.talkTime(now: now)?.inSeconds;
    // Normalize status from reason for easier UI grouping.
    final status = callStatusFromReason(reason, connected: call.connectedAt != null, outgoing: call.isCaller);
    // Answered on my other device: that one keeps the call in its history;
    // here it's neither missed nor a call of its own.
    if (status == kAnsweredElsewhere) return;
    final video = call.kind == CallKind.video;
    await _log(
      (l) => l.append(
        id: callId,
        chatId: groupId,
        video: video,
        status: status,
        outgoing: call.isCaller,
        startedAtUnix: startedAt,
        endedAtUnix: nowUnix,
        durationSecs: duration,
      ),
    );
    if (status == 'missed') await _log((l) => l.missedLine(groupId, video: video));
  }

  /// ADR-040 — Android: keep the connected call alive in background — with
  /// the camera too once it's on (owner, 2026-10-18: "the camera must not
  /// close when the call is minimised"): an audio call that turned video
  /// is announced again, so the call's foreground service gains the camera
  /// type (Android 14 cuts a background camera without it).
  void _keepAlive() {
    final s = state;
    final id = s.callId;
    if (id == null) return;
    unawaited(
      callKitBridge.callConnected(
        callId: id,
        peerName: _systemCallName(s.groupIdHex ?? ''),
        video: callKeepsCamera(s),
      ),
    );
  }

  /// Best-effort: history and chat lines never break the call flow.
  Future<void> _log(Future<void> Function(CallLog) write) async {
    try {
      await write(ref.read(callLogProvider));
    } catch (e) {
      // ignore: avoid_print
      print('[call-history] $e');
    }
  }

  // ── CD6 — LiveKit engine glue ──────────────────────────────────────

  /// CE5 — permanent-drop watchdog: if we stay in `reconnecting` longer
  /// than this, give up and end the call.
  static const Duration _reconnectingTimeout = Duration(seconds: 30);
  Timer? _reconnectingWatchdog;

  /// How long the link may be gone before the screen says "Reconnecting…".
  static const Duration kReconnectGrace = Duration(seconds: 2);
  Timer? _reconnectShow;

  String get _httpBase => ref.read(netServiceProvider).httpBaseUrl ?? _kCallHttpBaseUrl;
  String get _wireKind => state.kind == CallKind.video ? 'video' : 'audio';

  /// Fetch the join token + TURN creds for the ringing call (both sides),
  /// so the answer doesn't wait for them. A failure is retried at the join.
  void _prefetch() {
    final groupId = state.groupIdHex;
    final callId = state.callId;
    if (groupId == null || callId == null) return;
    _prepReady = false;
    final f = ref.read(callEngineProvider).prepare(httpBaseUrl: _httpBase, groupIdHex: groupId, kind: _wireKind);
    _prep = f;
    _prepCall = callId;
    f.then((_) {
      if (identical(_prep, f)) {
        _prepReady = true;
        timeline.mark('prep');
      }
    }, onError: (Object e) {
      // ignore: avoid_print
      print('[livekit] token ahead failed: $e — fetched again at the join');
    });
  }

  /// The prefetched token if it's for this call and fresh, else a new one.
  Future<CallPrep> _takePrep(String groupId) async {
    final engine = ref.read(callEngineProvider);
    final f = _prep;
    if (f != null && _prepCall == state.callId) {
      try {
        final p = await f;
        if (p.usableFor(groupId)) return p;
      } catch (_) {
        // Fetched again below.
      }
    }
    final p = await engine.prepare(httpBaseUrl: _httpBase, groupIdHex: groupId, kind: _wireKind);
    timeline.mark('prep');
    return p;
  }

  /// Connect to LiveKit room + start media streams. Called when the call
  /// connects — or, [early], by the caller while it still rings (mic
  /// silent, no camera; [_goLive] finishes on the answer). A second start
  /// while one runs waits for it; with a session up it's a no-op.
  Future<void> _startLiveKitSession({CallPath? path, bool early = false}) {
    // `_session` is only set after the connect finishes; a second start in
    // the meantime (in-app Accept + CallKit accept) joined twice and LiveKit
    // dropped one as `duplicateIdentity`.
    if (_session != null) return Future.value();
    final running = _starting;
    if (running != null && _startingCall == state.callId) return running;
    // (A join left over from an earlier call leaves by itself — it checks
    // the call it was for.)
    _startingCall = state.callId;
    late final Future<void> f;
    f = _joinRoom(path: path, early: early).whenComplete(() {
      if (identical(_starting, f)) _starting = null;
    });
    return _starting = f;
  }

  Future<void> _joinRoom({CallPath? path, required bool early}) async {
    final groupId = state.groupIdHex;
    final callId = state.callId;
    if (groupId == null || callId == null) return;
    // Status 184 — a room an earlier call left open goes before this one.
    await closeOrphanCallRooms(keep: _session?.room);
    // ADR-042 — which path: the reserve when asked for in Settings or
    // needed in the last day, else WebRTC's own choice.
    _path = path ?? await _initialPath();
    _churn = PathChurn();
    _reserveChurn = PathChurn();
    Future<LiveKitSession> join(CallPath p) async => ref
        .read(callEngineProvider)
        .connect(
          prep: await _takePrep(groupId),
          // CE5 — network event hooks.
          onReconnecting: _onLiveKitReconnecting,
          onReconnected: _onLiveKitReconnected,
          onDisconnected: _onLiveKitDisconnected,
          path: p,
          // Status 223 — muted before it connected: the mic opens muted.
          micMuted: early || state.micMuted,
          camera: !early,
          timeline: early ? null : timeline,
          speaker: state.speakerOn,
        );
    // Still wanted: the same call, answered — or, joining ahead, still on.
    // (An Accept the server never got rings again: not in the room then.)
    bool still() => state.callId == callId && (early ? state.isActive : state.phase == CallPhase.connected);
    try {
      LiveKitSession s;
      try {
        s = await join(_path);
      } catch (e) {
        if (!still()) rethrow;
        if (_path == CallPath.direct) {
          // The direct path didn't come up: once more through the reserve.
          // ignore: avoid_print
          print('[livekit] direct path failed ($e) — trying the reserve (443)');
          _path = CallPath.reserve;
          s = await join(_path);
          unawaited(_rememberReserve());
        } else {
          // Status 183 — the reserve (chosen for a VPN, or remembered) didn't
          // come up: the direct path gets its chance too.
          // ignore: avoid_print
          print('[livekit] reserve path failed ($e) — trying the direct path');
          _path = CallPath.direct;
          s = await join(_path);
        }
      }
      // The call ended (or was declined) while joining: leave at once — the
      // teardown ran before there was a session to tear down.
      if (!still()) {
        unawaited(s.disconnect());
        return;
      }
      _session = s;
      _early = early && state.phase != CallPhase.connected;
      room.value = s.room;
      // The engine routes video calls to the loudspeaker, audio to the ear.
      // A fresh room starts on a working link — a "Reconnecting…" left from
      // the room before (the reserve switch) stayed up for good.
      _reconnectShow?.cancel();
      // The speaker as I chose it, also while the join ran.
      final speaker = state.speakerOn;
      try {
        if ((lk_audio.Hardware.instance.speakerOn ?? speaker) != speaker) {
          await lk_audio.Hardware.instance.setSpeakerphoneOn(speaker);
        }
      } catch (_) {}
      state = state.copyWith(
        speakerOn: speaker,
        cameraOn: s.room.localParticipant?.isCameraEnabled() ?? false,
        networkStatus: CallNetworkStatus.connected,
      );
      _watchLinkQuality(s.room);
      _watchSound(s.room);
      _startVideoCeiling();
      _micGuard?.stop();
      _micGuard = SilentMicGuard(
        s.room,
        live: () => _session == s && !_early && state.phase == CallPhase.connected && !state.micMuted,
        onRepair: (r) => timeline.mark('mic-${r.name}'),
      )..start();
      _deviceSub ??= lk_audio.Hardware.instance.onDeviceChange.stream.listen(_onAudioDevices);
      // ignore: avoid_print
      print('[livekit] connected to room=${s.room.name}${_early ? ' (ringing, mic silent)' : ''}');
      // Answered while the early join ran: go live now.
      if (early && !_early) await _openEarlySession(s);
    } catch (e) {
      if (early && state.phase != CallPhase.connected) {
        // Only a head start: the answer joins again.
        // ignore: avoid_print
        print('[livekit] joining ahead failed: $e — joining on the answer');
        return;
      }
      // ignore: avoid_print
      print('[livekit] connect failed: $e');
      state = state.copyWith(error: 'livekit connect failed: $e');
      // Auto-end the call — without media there's nothing useful left.
      unawaited(end(reason: 'livekit_failure'));
    }
  }

  /// The other side answered my call: open the mic of the room joined
  /// while ringing (or join now if that didn't happen / failed).
  Future<void> _goLive() async {
    final starting = _starting;
    if (starting != null) await starting;
    if (state.phase != CallPhase.connected) return;
    final s = _session;
    if (s == null) return _startLiveKitSession();
    if (_early) await _openEarlySession(s);
  }

  Future<void> _openEarlySession(LiveKitSession s) async {
    _early = false;
    timeline.mark('room');
    await s.goLive(mic: !state.micMuted, camera: state.kind == CallKind.video);
    if (!identical(_session, s) || state.phase != CallPhase.connected) return;
    timeline.mark('mic');
    state = state.copyWith(cameraOn: s.room.localParticipant?.isCameraEnabled() ?? false);
    if (state.cameraOn) _keepAlive();
    _checkSound();
  }

  // ── "Connecting…" until the other side's sound arrives ─────────────

  void Function()? _soundCancel;
  Timer? _soundFallback;

  /// Watch for the other side's sound (and their voice level for the bars).
  void _watchSound(lk_room.Room room) {
    _soundCancel?.call();
    _soundCancel = room.events.listen((e) {
      if (e is lk_events.ActiveSpeakersChangedEvent || e is lk_events.ParticipantDisconnectedEvent) {
        var level = 0.0;
        for (final p in room.remoteParticipants.values) {
          if (p.isSpeaking && p.audioLevel > level) level = p.audioLevel;
        }
        peerVoice.value = level;
      }
      if (e is lk_events.TrackSubscribedEvent ||
          e is lk_events.TrackUnmutedEvent ||
          e is lk_events.ParticipantConnectedEvent) {
        _checkSound();
      }
      if (e is lk_events.TrackMutedEvent ||
          e is lk_events.TrackUnmutedEvent ||
          e is lk_events.TrackPublishedEvent ||
          e is lk_events.TrackUnpublishedEvent ||
          e is lk_events.ParticipantConnectedEvent ||
          e is lk_events.ParticipantDisconnectedEvent) {
        _checkPeerMic(room);
      }
    });
    _checkSound();
    _checkPeerMic(room);
  }

  /// Whether the other side's mic is off now (LiveKit tells the room when
  /// someone mutes — also with SFrame, it's signalling, not media).
  void _checkPeerMic(lk_room.Room room) {
    if (state.phase != CallPhase.connected) return;
    final off = peerMicOffFrom(
      [for (final p in room.remoteParticipants.values) participantMicMuted(p)],
      group: _isGroupChat(state.groupIdHex ?? ''),
    );
    if (off != state.peerMicOff) state = state.copyWith(peerMicOff: off);
  }

  /// Their mic track is here and open → sound. Someone in the room whose
  /// mic is off (or broken) doesn't keep "Connecting…" up: 3 s after their
  /// track (or, without one, them) arrived, the call counts as connected.
  void _checkSound() {
    final r = _session?.room;
    if (r == null || state.phase != CallPhase.connected || state.audioAt != null) return;
    // A group call: in the room is "connected" (the grid shows who's there).
    final group = _isGroupChat(state.groupIdHex ?? '');
    final people = r.remoteParticipants.values;
    final open = people.any((p) => p.audioTrackPublications.any((t) => t.subscribed && !t.muted));
    if (group || open) return _heard();
    if (people.isEmpty) return;
    _soundFallback ??= Timer(const Duration(seconds: 3), () {
      _soundFallback = null;
      if (state.phase == CallPhase.connected && state.audioAt == null && _session != null) _heard();
    });
  }

  void _heard() {
    _soundFallback?.cancel();
    _soundFallback = null;
    state = state.copyWith(audioAt: DateTime.now());
    final id = state.callId;
    if (state.isCaller && id != null) unawaited(callKitBridge.outgoingConnected(id));
    final room = _session?.room;
    if (room != null) _checkPeerMic(room);
    timeline.mark('sound');
    // ignore: avoid_print
    print('[call-timing] ${state.isCaller ? 'caller' : 'callee'}: ${timeline.line}');
  }

  /// Tests: the other side's sound arrived.
  @visibleForTesting
  void debugHeard() => _heard();

  /// Tests: LiveKit lost the link / got it back.
  @visibleForTesting
  void debugLinkLost() => _onLiveKitReconnecting();
  @visibleForTesting
  void debugLinkBack() => _onLiveKitReconnected();

  /// The name iOS shows for the call and keeps in its call history
  /// (CallKit) — and Android's call notification: the chat's name (owner,
  /// 2026-10-16: it said "Call · eb8c2765"), or just "Sinhron" when
  /// Settings → notifications show nothing.
  String _systemCallName(String groupIdHex) {
    if (ref.read(notificationPreviewProvider).value == NotificationPreview.nothing) return 'Sinhron';
    final chat = (ref.read(chatsProvider).value ?? const []).where((c) => c.id == groupIdHex).firstOrNull;
    final name = chat?.name.trim() ?? '';
    return name.isNotEmpty ? name : lookupAppL10n(Locale(currentLanguage)).callKitPeerName;
  }

  // ── ADR-042 — the reserve path ─────────────────────────────────────

  CallPath _path = CallPath.direct;
  PathChurn _churn = PathChurn();
  Timer? _stallTimer;
  bool _switchingPath = false;

  /// The path this call is on (tests).
  CallPath get path => _path;
  @visibleForTesting
  set debugPath(CallPath p) => _path = p;

  Future<CallPath> _initialPath() async {
    try {
      final always = await ref.read(callsReserveAlwaysProvider.future);
      final at = DateTime.tryParse(await ref.read(callsReserveNeededAtProvider.future));
      return initialCallPath(alwaysReserve: always, reserveNeededAt: at, now: DateTime.now());
    } catch (_) {
      return CallPath.direct;
    }
  }

  Future<void> _rememberReserve() async {
    try {
      await ref.read(callsReserveNeededAtProvider.notifier).save(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  /// The reserve path drops too (tech-debt 2.38: a VPN "by rules" sent the
  /// call around it — LiveKit rejoined 23 times in 3 minutes). Twice in
  /// 30 s → tell the person what helps; quiet again after a calm minute.
  PathChurn _reserveChurn = PathChurn();
  Timer? _calmTimer;
  static const Duration _calmAfter = Duration(seconds: 60);

  /// LiveKit lost the link on the direct path ([now] from tests): twice in
  /// 30 s, or once for 8 s → rejoin through the reserve.
  void onPathDrop({DateTime? now}) {
    if (_switchingPath) return;
    final t = now ?? DateTime.now();
    if (_path == CallPath.reserve) {
      if (_reserveChurn.dropped(t) && !state.keepsDropping) state = state.copyWith(keepsDropping: true);
      _calmTimer?.cancel();
      _calmTimer = Timer(_calmAfter, () {
        _reserveChurn = PathChurn();
        if (state.keepsDropping) state = state.copyWith(keepsDropping: false);
      });
      return;
    }
    if (_churn.dropped(t)) {
      unawaited(switchToReserve());
      return;
    }
    _stallTimer?.cancel();
    _stallTimer = Timer(_churn.longStall, () {
      if (_churn.stalled(DateTime.now())) unawaited(switchToReserve());
    });
  }

  /// Leave the room and join again through the reserve. Public for tests.
  Future<void> switchToReserve() async {
    if (_switchingPath || _path == CallPath.reserve || state.phase != CallPhase.connected) return;
    _switchingPath = true;
    _stallTimer?.cancel();
    state = state.copyWith(switchingPath: true);
    // ignore: avoid_print
    print('[livekit] direct path keeps dropping — rejoining through the reserve (443)');
    unawaited(_rememberReserve());
    try {
      await _teardownLiveKit();
      if (state.phase == CallPhase.connected) await _startLiveKitSession(path: CallPath.reserve);
    } finally {
      _switchingPath = false;
      state = state.copyWith(switchingPath: false);
    }
  }

  /// CE5 — LiveKit reports signal loss. UI overlay shows "Reconnecting…";
  /// we arm a 30s watchdog: if no `RoomReconnectedEvent` arrives, the
  /// call auto-ends with reason="network_lost".
  void _onLiveKitReconnecting() {
    onPathDrop();
    // Status 212 — "Reconnecting…" only if the link stays gone a moment:
    // a hiccup LiveKit fixes in a second used to flash it (owner: "it says
    // connecting, then it's gone, then it's back"). Not while it rings.
    _reconnectShow?.cancel();
    _reconnectShow = Timer(kReconnectGrace, () {
      if (state.phase == CallPhase.connected) state = state.copyWith(networkStatus: CallNetworkStatus.reconnecting);
    });
    _reconnectingWatchdog?.cancel();
    _reconnectingWatchdog = Timer(_reconnectingTimeout, () {
      // Still in reconnecting → permanent loss.
      if (state.networkStatus == CallNetworkStatus.reconnecting && state.phase == CallPhase.connected) {
        state = state.copyWith(networkStatus: CallNetworkStatus.lost);
        unawaited(end(reason: 'network_lost'));
      }
    });
  }

  void _onLiveKitReconnected() {
    _reconnectShow?.cancel();
    _reconnectShow = null;
    _churn.recovered();
    _stallTimer?.cancel();
    _reconnectingWatchdog?.cancel();
    _reconnectingWatchdog = null;
    state = state.copyWith(networkStatus: CallNetworkStatus.connected);
  }

  void _onLiveKitDisconnected(String reason) {
    // calls:1 — the server tried to carry the call unencrypted: it ends.
    // …or my microphone could not be published: "couldn't connect".
    if (reason == kCallNotEncrypted || reason == kCallMediaFailed) {
      unawaited(end(reason: reason));
      return;
    }
    // Our own leave while moving to the reserve path — the call goes on.
    if (_switchingPath) return;
    // The room joined while my call rang dropped: the answer joins again.
    if (state.phase == CallPhase.outgoingRinging) {
      unawaited(_teardownLiveKit());
      return;
    }
    _reconnectingWatchdog?.cancel();
    _reconnectingWatchdog = null;
    // If we initiated the disconnect (LocalEnd already moved phase →
    // ended), don't double-end. The teardown sequence handles cleanup.
    if (state.phase == CallPhase.connected) {
      unawaited(end(reason: 'remote_disconnected'));
    }
  }

  // ── ADR-041 — link quality and the audio-only fallback ────────────

  AudioOnlyFallback _fallback = AudioOnlyFallback();
  Timer? _fallbackTimer;

  /// A live call whose mic sends nothing gets its audio restarted.
  SilentMicGuard? _micGuard;
  lk_quality.CancelListenFunc? _qualityCancel;
  final _peerQuality = <String, CallLinkQuality>{};

  void _watchLinkQuality(lk_room.Room? room) {
    if (room == null) return;
    _fallback = AudioOnlyFallback();
    _peerQuality.clear();
    _qualityCancel?.call();
    _qualityCancel = room.events.on<lk_quality.ParticipantConnectionQualityUpdatedEvent>((e) {
      final q = callLinkQualityFrom(e.connectionQuality);
      if (e.participant.identity == room.localParticipant?.identity) {
        onLinkQuality(q);
      } else {
        _peerQuality[e.participant.identity] = q;
        // Someone who left keeps no vote.
        _peerQuality.removeWhere((id, _) => !room.remoteParticipants.values.any((p) => p.identity == id));
        state = state.copyWith(peerLinkBad: _peerQuality.values.any((v) => v.isBad));
      }
    });
  }

  /// My link's grade changed (from LiveKit; tests call it directly).
  void onLinkQuality(CallLinkQuality q, {DateTime? now}) {
    state = state.copyWith(linkQuality: q);
    unawaited(_applyAudioBitrate(callAudioBitrateFor(q)));
    unawaited(updateVideoCeiling(now: now));
    _fallback.report(q, now ?? DateTime.now());
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    if (q.isBad && state.cameraOn) _fallbackTimer = Timer(_fallback.holdNow, () => checkAudioOnlyFallback());
  }

  int? _audioBitrate;

  /// The voice follows the link: the microphone track's sender gets a new
  /// Opus ceiling (no renegotiation, takes effect within a second).
  Future<void> _applyAudioBitrate(int bps) async {
    if (bps == _audioBitrate) return;
    final room = _session?.room;
    if (room == null) return;
    try {
      for (final pub in room.localParticipant?.audioTrackPublications ?? const []) {
        final sender = pub.track?.sender;
        if (sender == null) continue;
        final params = sender.parameters;
        final encodings = params.encodings;
        if (encodings == null || encodings.isEmpty) continue;
        for (final e in encodings) {
          e.maxBitrate = bps;
        }
        await sender.setParameters(params);
      }
      _audioBitrate = bps;
      // ignore: avoid_print
      print('[livekit] voice bitrate → ${bps ~/ 1000} kbps');
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] voice bitrate not set: $e');
    }
  }

  // ── ADR-046 — my best picture follows the link and the heat ─────────

  VideoCeilingController _ceiling = VideoCeilingController();
  Timer? _ceilingTick;
  ThermalLevel _thermal = 0;
  Object? _ceilingSender;
  VideoCeiling? _ceilingApplied;

  /// The ceiling now on my camera's top layer (null: not set / weak phone).
  @visibleForTesting
  VideoCeiling? get videoCeiling => _ceilingApplied;

  /// Every 5 s: read the phone's heat and re-check the ceiling — also puts
  /// it back on a camera that was republished (codec change, camera
  /// turned on again), which starts from the preset's full top layer.
  void _startVideoCeiling() {
    _ceiling = VideoCeilingController();
    _thermal = 0;
    _ceilingSender = null;
    _ceilingApplied = null;
    _ceilingTick?.cancel();
    _ceilingTick = Timer.periodic(const Duration(seconds: 5), (_) async {
      _thermal = await LiveKitCallEngine.thermalLevel();
      await updateVideoCeiling();
    });
    unawaited(updateVideoCeiling());
  }

  /// Work out the ceiling (device, link, heat — [videoCeilingFor], with the
  /// controller's 10 s wait before going up) and set it on the top
  /// simulcast layer of my camera: scale, bitrate, frame rate, through
  /// `RtpSender.setParameters` — no renegotiation, no gap in the picture.
  /// LiveKit's dynacast only flips layers on and off, so it keeps these.
  Future<void> updateVideoCeiling({DateTime? now}) async {
    final s = _session;
    if (s == null) return;
    final target = videoCeilingFor(device: s.deviceClass, link: state.linkQuality, thermal: _thermal);
    final changed = _ceiling.update(target, now ?? DateTime.now());
    final ceiling = _ceiling.current;
    final sender = s.camera?.track?.sender;
    if (ceiling == null || sender == null) return;
    if (changed == null && identical(sender, _ceilingSender) && ceiling == _ceilingApplied) return;
    try {
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.length < 2) return;
      final top = encodings.firstWhere((e) => e.rid == 'f', orElse: () => encodings.last);
      final layer = topLayerFor(ceiling, s.preset.capture.dimensions.height);
      top
        ..scaleResolutionDownBy = layer.scaleDownBy
        ..maxBitrate = layer.maxBitrate
        ..maxFramerate = layer.maxFramerate;
      await sender.setParameters(params);
      _ceilingSender = sender;
      _ceilingApplied = ceiling;
      // ignore: avoid_print
      print('[livekit] video ceiling → ${ceiling.height}p (link ${state.linkQuality.name}, heat $_thermal)');
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] video ceiling not set: $e');
    }
  }

  /// The bad stretch lasted long enough: my camera goes off, the screen
  /// says why. Public for tests (they pass [now]).
  Future<void> checkAudioOnlyFallback({DateTime? now}) async {
    if (state.phase != CallPhase.connected) return;
    if (!_fallback.due(now: now ?? DateTime.now(), cameraOn: state.cameraOn)) return;
    _fallback.fired();
    // ignore: avoid_print
    print('[livekit] link poor for ${_fallback.holdNow.inSeconds}s — camera off, audio only');
    if (await _setCamera(false)) state = state.copyWith(cameraOn: false, autoAudioOnly: true);
  }

  /// Tear down the LiveKit session if any. Safe to call multiple times.
  Future<void> _teardownLiveKit() async {
    _reconnectShow?.cancel();
    _reconnectShow = null;
    _micGuard?.stop();
    _micGuard = null;
    _reconnectingWatchdog?.cancel();
    _reconnectingWatchdog = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _calmTimer?.cancel();
    _calmTimer = null;
    _audioBitrate = null;
    _ceilingTick?.cancel();
    _ceilingTick = null;
    _ceilingSender = null;
    _ceilingApplied = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _qualityCancel?.call();
    _qualityCancel = null;
    _soundCancel?.call();
    _soundCancel = null;
    _soundFallback?.cancel();
    _soundFallback = null;
    peerVoice.value = 0;
    _early = false;
    final s = _session;
    _session = null;
    room.value = null;
    if (s == null) return;
    try {
      await s.disconnect();
    } catch (_) {
      // Disconnect failures are non-fatal.
    }
  }

  // ── CD7 — UI-side control routing ──────────────────────────────────

  /// Mute / unmute the local mic stream. UI calls this from the
  /// CallScreen mute button. No-op if no live LiveKit session.
  Future<void> setMicrophoneMuted(bool muted) async {
    if (state.isActive) state = state.copyWith(micMuted: muted);
    // Still ringing: the mic of a room joined ahead stays silent; the
    // answer opens it only if I didn't mute it.
    if (state.phase != CallPhase.connected) return;
    final lp = _session?.room.localParticipant;
    if (lp == null) return;
    try {
      await lp.setMicrophoneEnabled(!muted);
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] setMicrophoneEnabled failed: $e');
      if (_session != null) await callPublishFailed(_session!.room);
    }
  }

  /// Camera on / off during a call (an audio call can turn video on; the
  /// button used to only change the picture). Returns whether it worked —
  /// no camera (Simulator) or a refused permission → false, stay on audio.
  Future<bool> setCameraEnabled(bool on) async {
    if (_session?.room.localParticipant == null) return false;
    if (on) {
      const perms = CallPermissionsService();
      if (await perms.requestCamera() != CallPermission.granted) return false;
    }
    final ok = await _setCamera(on);
    if (ok) {
      // My choice now: the fallback steps in again only after a longer
      // stretch of bad link (ADR-041).
      if (on) _fallback.userTurnedCameraOn(DateTime.now());
      state = state.copyWith(cameraOn: on, autoAudioOnly: false);
      if (on && state.linkQuality.isBad) onLinkQuality(state.linkQuality);
      // In the background too (Android: the service gains the camera type).
      if (on && state.phase == CallPhase.connected) _keepAlive();
    }
    return ok;
  }

  Future<bool> _setCamera(bool on) async {
    final lp = _session?.room.localParticipant;
    if (lp == null) return false;
    try {
      await lp.setCameraEnabled(on);
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] setCameraEnabled($on) failed: $e');
      if (_session != null) await callPublishFailed(_session!.room);
      return false;
    }
  }

  /// CD7 — front ↔ back camera. Tracked locally (livekit_client doesn't
  /// expose the current position via a getter). UI calls from the
  /// camera-flip button; only meaningful for video calls.
  bool _frontCamera = true;
  Future<void> switchCamera() async {
    final lp = _session?.room.localParticipant;
    if (lp == null) return;
    final newPosition = _frontCamera ? lk_track.CameraPosition.back : lk_track.CameraPosition.front;
    try {
      for (final pub in lp.videoTrackPublications) {
        final track = pub.track;
        // The camera, not my shared screen (ADR-061).
        if (track is lk_track.LocalVideoTrack && pub.source == lk_track.TrackSource.camera) {
          // `LocalVideoTrackExt.setCameraPosition` lives on the
          // extension; called the same way.
          await track.setCameraPosition(newPosition);
          _frontCamera = !_frontCamera;
          break; // one local cam at a time
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] switchCamera failed: $e');
    }
  }

  /// Speaker / earpiece toggle. iOS-only; calls through to the audio
  /// session. `speaker=true` routes to the loud speaker, `false` to the
  /// earpiece. NOTE: the underlying API differs per platform — on iOS
  /// LiveKit uses AVAudioSession; we delegate to the room's Hardware
  /// helper if available.
  Future<void> setSpeakerOn(bool speaker) async {
    // Status 223 — before the call is up: remembered; the join uses it.
    if (_session == null) {
      if (state.isActive) state = state.copyWith(speakerOn: speaker);
      return;
    }
    try {
      // livekit_client exposes Hardware singleton for audio routing.
      await lk_audio.Hardware.instance.setSpeakerphoneOn(speaker);
      state = state.copyWith(speakerOn: speaker && !_externalOutput);
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] setSpeakerphoneOn failed: $e');
    }
  }

  StreamSubscription<List<lk_audio.MediaDevice>>? _deviceSub;
  bool _externalOutput = false;

  /// Headphones / Bluetooth came or went: the sound follows them, so the
  /// speaker icon does too.
  void _onAudioDevices(List<lk_audio.MediaDevice> devices) {
    _externalOutput = hasExternalAudioOutput(devices);
    if (!state.isActive) return;
    state = state.copyWith(speakerOn: (lk_audio.Hardware.instance.speakerOn ?? false) && !_externalOutput);
  }
}

/// CD3 — global Riverpod entry point for the active call state machine.
/// All call-related UI watches this. Override in tests via
/// [activeCallProvider.overrideWith].
final activeCallProvider = NotifierProvider<ActiveCallNotifier, ActiveCallState>(ActiveCallNotifier.new);

/// Nothing else touches the phone's audio session while a call is on —
/// ringing, talking or just ended (in-app sounds, a voice message's
/// "speech" session): that took the microphone from the call (ADR-063).
bool callOwnsAudio(ActiveCallState s) => s.phase != CallPhase.idle;

/// Status 213 — the server says my ringing call reached their phone.
bool ringReachedThem(ActiveCallState s, {required String callId, required bool delivered}) =>
    delivered && callId == s.callId && s.phase == CallPhase.outgoingRinging && !s.peerRinging;

/// The ringback plays: my 1:1 call is ringing at the other end. (A group
/// call shows who joined instead.)
bool ringbackWanted(ActiveCallState s) => s.phase == CallPhase.outgoingRinging && s.isCaller;

/// The call's background keep-alive needs the camera: a video call, or an
/// audio call whose camera I turned on. (The camera is never stopped when
/// the call screen is minimised — it belongs to the call, not the screen.)
bool callKeepsCamera(ActiveCallState s) => s.kind == CallKind.video || s.cameraOn;

/// Wired or Bluetooth output present (iOS then plays the call there, not on
/// the loudspeaker). Labels come from the OS: "Headphones", "AirPods Pro",
/// "… Bluetooth", "Car audio"…
bool hasExternalAudioOutput(List<lk_audio.MediaDevice> devices) {
  const external = ['headphone', 'headset', 'bluetooth', 'airpods', 'earpods', 'car', 'hands-free', 'hfp', 'a2dp'];
  return devices.any((d) {
    if (d.kind != 'audiooutput') return false;
    final l = d.label.toLowerCase();
    return external.any(l.contains);
  });
}

/// A group call going on in a chat (owner, 2026-10-15: "join a call that is
/// already going"). Known from its invite — also when I declined or missed
/// the ring — and forgotten when the server says it ended.
@immutable
class OngoingCall {
  const OngoingCall({
    required this.callId,
    required this.groupIdHex,
    required this.kind,
    required this.livekitRoom,
    required this.since,
  });
  final String callId;
  final String groupIdHex;
  final CallKind kind;
  final String livekitRoom;
  final DateTime since;
}

/// Group chat id → the call going on in it.
class OngoingGroupCalls extends Notifier<Map<String, OngoingCall>> {
  /// A call we never heard end (offline at the time) stops being offered.
  static const maxAge = Duration(hours: 12);

  @override
  Map<String, OngoingCall> build() => const {};

  void put(OngoingCall c) => state = {...state, c.groupIdHex: c};

  void endCall(String callId) {
    if (!state.values.any((c) => c.callId == callId)) return;
    state = {
      for (final e in state.entries)
        if (e.value.callId != callId) e.key: e.value,
    };
  }

  final _checked = <String, DateTime>{};

  /// Ask the server whether anyone is still in [groupIdHex]'s call, and
  /// forget it if not (owner, 2026-10-18: "the call ended — it still says
  /// Join": a CallEnd only reaches devices online at that moment). Not in
  /// a call's first [startGrace] (the caller may not be in the room yet),
  /// at most every [recheck]; "don't know" (older server, offline) keeps it.
  Future<void> verify(String groupIdHex, {DateTime? now}) async {
    final c = state[groupIdHex];
    if (c == null) return;
    final t = now ?? DateTime.now();
    if (t.difference(c.since) < startGrace) return;
    final last = _checked[c.callId];
    if (last != null && t.difference(last) < recheck) return;
    _checked[c.callId] = t;
    final live = await ref.read(callLiveCheckProvider)(groupIdHex);
    if (live == false) endCall(c.callId);
  }

  static const startGrace = Duration(seconds: 20);
  static const recheck = Duration(seconds: 20);

  /// The call to offer in [groupIdHex], if any (and not too old).
  OngoingCall? inChat(String groupIdHex, {DateTime? now}) {
    final c = state[groupIdHex];
    if (c == null) return null;
    return (now ?? DateTime.now()).difference(c.since) > maxAge ? null : c;
  }
}

final ongoingGroupCallsProvider = NotifierProvider<OngoingGroupCalls, Map<String, OngoingCall>>(OngoingGroupCalls.new);

/// Is anyone in [groupIdHex]'s call right now — LiveKit's count via
/// `POST /v1/call/live`; null: don't know. Overridden in tests.
final callLiveCheckProvider = Provider<Future<bool?> Function(String groupIdHex)>(
  (ref) => (groupIdHex) async {
    final base = ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) return null;
    try {
      return await core.callIsLive(serverBaseUrl: base, groupIdHex: groupIdHex);
    } catch (_) {
      return null;
    }
  },
);
