// CD6 — LiveKit room connect + SFrame E2EE.
//
// Adapter between `activeCallProvider` (signaling state machine) and
// the `livekit_client` Flutter SDK (media transport). Two stages (owner,
// 2026-10-18: "accepted, but we hear each other only after 1–3 s" — every
// step used to start after the answer, one after another):
//
//   [LiveKitCallEngine.prepare] — while the call rings:
//     1. Join token (`callRequestLivekitToken`, POST /v1/call/token — per
//        group, member-only, valid an hour) and TURN creds
//        (`callRequestTurnCreds`) in parallel, plus this phone's media
//        settings (cached after the first call) and a DNS look-up of the
//        LiveKit host.
//   [LiveKitCallEngine.connect] — on the answer (the caller: already while
//   ringing, with the mic silent — `micMuted`):
//     2. A `Room` with `E2EEOptions(keyProvider: ...)` in per-participant
//        mode (`sharedKey: false`, no LiveKit ratchet). A track the server
//        says isn't encrypted ends the call ([callTrackEncrypted]).
//     3. The microphone track is made while `room.connect(url, token)`
//        runs (not after it).
//     4. SFrame keys (tech-debt 4.1/4.9): for ourselves and every
//        participant, `callSframeKeyFor(group, identity)` (Rust: MLS leaf
//        of that identity → exporter → RFC 9605 key) → `setRawKey` under
//        that participant's identity, slot = epoch mod 16. Joiners get
//        theirs on `ParticipantConnectedEvent` — so it works for groups.
//     5. Publish the mic first, then the camera, with explicit settings
//        (ADR-041, ADR-046): 1080p on strong phones, 720p on ordinary ones,
//        360p on weak Android — capped bitrates, simulcast, H.264 where the
//        encoder list has it (else VP8), Opus speech + DTX + RED. The top
//        layer's ceiling then follows the link and the heat
//        (activeCallProvider).
//     6. Poll `mlsGroupEpoch` every 2 s — on a bump re-key everyone; the
//        16-slot ring (4-bit epoch field of the KID) covers the overlap.
//     7. ADR-045 codec agreement — started after the join returns, so it
//        no longer holds the call up.
//
// **Important:** this file targets `livekit_client: 2.7.0` (bumped
// 2026-05-23 from 2.5.0 to fix WebRTC-SDK pod version conflict — 2.7.0
// pins flutter_webrtc=1.4.0 exactly). Some API surfaces may shift
// across minor versions — if `Room.connect` / `RoomOptions` signatures
// drift, fix HERE rather than in activeCallProvider.
//
// Without Apple Developer cert (operator decision per
// `docs/plan-calls.md`), VoIP push (PushKit) doesn't fire. This engine
// works only when the app is in foreground or backgrounded with
// `UIBackgroundModes: voip` declared (CD1).

import 'dart:async';
import 'dart:io' show InternetAddress, Platform;
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
// The audio-session hook and its configurations aren't exported (2.7.0).
// ignore: implementation_imports, invalid_use_of_internal_member
import 'package:livekit_client/src/internal/events.dart' show EngineTrackAddedEvent;
// ignore: implementation_imports
import 'package:livekit_client/src/support/native_audio.dart' show NativeAudioConfiguration;
// ignore: implementation_imports
import 'package:livekit_client/src/track/audio_management.dart' as lk_audio show AudioTrackState, onConfigureNativeAudio;

import '../../src/rust/api/simple.dart' as core;
import 'call_codecs.dart';
import 'call_path.dart';
import 'call_quality.dart';
import 'call_screen_share.dart' show kScreenShareCaptureOptions, kScreenShareEncoding;
import 'call_timeline.dart';

/// The iPhone's audio session for a call, by LiveKit's track count
/// (owner, 2026-10-18: "calls with mum's iPhone often have no sound").
/// LiveKit's default switched to `playback` — no microphone — while only
/// the other side's track was there and the speaker preferred: every video
/// call, before my mic was published (and every call after a video call —
/// the speaker choice stays). Whatever is or isn't published yet, a call
/// keeps play-and-record: voice chat on the earpiece, video chat on the
/// speaker; the call over → solo ambient, as before.
NativeAudioConfiguration callAudioConfigFor(lk_audio.AudioTrackState s, {required bool speaker}) {
  if (s == lk_audio.AudioTrackState.none) return NativeAudioConfiguration.soloAmbient;
  return speaker ? NativeAudioConfiguration.playAndRecordSpeaker : NativeAudioConfiguration.playAndRecordReceiver;
}

/// The call's own speaker choice until the join has set LiveKit's (its
/// "prefer speaker" starts as true — an audio call began in video-chat mode).
bool? _joinSpeaker;

/// Installs [callAudioConfigFor] as LiveKit's audio-session choice;
/// [speaker] holds until [releaseJoinSpeaker].
void useCallAudioConfig({required bool speaker}) {
  _joinSpeaker = speaker;
  lk_audio.onConfigureNativeAudio = (s) async =>
      callAudioConfigFor(s, speaker: _joinSpeaker ?? lk.Hardware.instance.preferSpeakerOutput);
}

/// LiveKit's own choice follows the speaker button from here.
void releaseJoinSpeaker() => _joinSpeaker = null;

/// ADR-042 — how long one attempt to join the call room may take.
const kCallConnectTimeout = Duration(seconds: 15);

/// Security review 2026-11 (calls:1) — the end reason of a call whose
/// media the server tried to carry without SFrame encryption.
const kCallNotEncrypted = 'e2ee_downgrade';

/// calls:1 — will LiveKit put a frame cryptor on this track? It skips one
/// when the server's track info says "no encryption" or the codec is AV1
/// (`E2EEManager`, livekit_client 2.7.0) — both are the server's word, so
/// such a track would go out or play in the clear. [codec]: my own track's
/// codec; [mimeType]: a received track's ("video/vp8").
bool callTrackEncrypted(lk.EncryptionType type, {String? codec, String? mimeType}) {
  if (type != lk.EncryptionType.kGcm) return false;
  // Audit 2026-11b (12) — my video goes out as VP8 / H.264 / H.265 only.
  // The server can swap in VP9 / AV1 (its `enabled_publish_codecs`), and
  // for those LiveKit turns dynacast back on — see [callRoomOptions].
  if (codec != null && codec.isNotEmpty && !const {'vp8', 'h264', 'h265'}.contains(codec.toLowerCase())) return false;
  if (mimeType != null) {
    final parts = mimeType.split('/');
    if (parts.length < 2 || parts[1].toLowerCase() == 'av1') return false;
  }
  return true;
}

/// Audit 2026-11b (13) — a received track plays as soon as the connection
/// has it, but LiveKit gives it the SFrame decryptor only once it can tie
/// it to a participant's publication. A track the server never ties to one
/// (a participant it never announced) would play whatever the server sends
/// — its own sound in my call. So a track with no publication is switched
/// off the moment it arrives; LiveKit switches it on itself when it
/// subscribes (`RemoteTrack.start`), right when the decryptor goes on.
void silenceUnboundTracks(lk.Room room) {
  // ignore: invalid_use_of_internal_member
  room.engine.events.listen((event) {
    // ignore: invalid_use_of_internal_member
    if (event is! EngineTrackAddedEvent) return;
    final id = event.track.id;
    final bound = room.remoteParticipants.values.any(
      (p) => p.trackPublications.values.any((pub) => pub.track?.mediaStreamTrack.id == id),
    );
    if (!bound) event.track.enabled = false;
  });
}

/// calls:2 — the "unencrypted frame" trailer: 32 random bytes per call,
/// never sent anywhere. LiveKit's default is the public `LK-ROCKS`: any
/// frame ending in it played without decryption, so the server could slip
/// in its own picture or voice as a participant. Only the receiving side
/// reads it — nothing on the wire changes.
String callUncryptedMagicBytes() {
  final r = Random.secure();
  return String.fromCharCodes(List.generate(32, (_) => r.nextInt(256)));
}

/// calls:2 — LiveKit's key provider, but the server can't set the trailer
/// (`JoinResponse.sif_trailer`) back to one it knows.
class CallKeyProvider extends lk.BaseKeyProvider {
  CallKeyProvider(super.keyProvider, super.options);

  @override
  Future<void> setSifTrailer(Uint8List trailer) async {}
}

/// Connected LiveKit engine. Returned from [LiveKitCallEngine.connect].
/// Owns the `Room` lifecycle and the SFrame key poll timer.
class LiveKitSession {
  final lk.Room room;
  final String groupIdHex;
  final Timer? _epochPoll;
  final CallVideoPreset _preset;

  /// ADR-046 — this phone's class and camera preset (the ceiling logic
  /// needs the capture height).
  final CallDeviceClass deviceClass;
  CallVideoPreset get preset => _preset;

  /// ADR-045 — the camera's codec now (it may move up to H.265 once the
  /// others have said what they decode) and the agreement itself.
  String videoCodec;
  CodecNegotiator? codecs;

  LiveKitSession._({
    required this.room,
    required this.groupIdHex,
    required Timer? epochPoll,
    required CallVideoPreset preset,
    required this.videoCodec,
    required this.deviceClass,
  }) : _epochPoll = epochPoll,
       _preset = preset;

  /// The camera's publication (null while the camera is off).
  lk.LocalTrackPublication<lk.LocalVideoTrack>? get camera => _camera;

  lk.LocalTrackPublication<lk.LocalVideoTrack>? get _camera => room.localParticipant?.videoTrackPublications
      .where((p) => p.source == lk.TrackSource.camera)
      .firstOrNull;

  /// The camera's codec while it's being sent, else null — from the track
  /// itself: a camera turned on later starts on the default codec, and the
  /// agreement moves it up again.
  String? get cameraCodec {
    final track = _camera?.track;
    if (track == null) return null;
    return track.codec?.toLowerCase() ?? videoCodec;
  }

  /// Send the camera with [codec] from now on: a fresh camera track (same
  /// lens) published with it — about half a second without my picture.
  /// Later camera turn-ons keep this codec.
  Future<void> republishCamera(String codec) async {
    final lp = room.localParticipant;
    final pub = _camera;
    final old = pub?.track;
    if (lp == null || pub == null || old == null) {
      videoCodec = codec;
      return;
    }
    final options = old.currentOptions is lk.CameraCaptureOptions
        ? old.currentOptions as lk.CameraCaptureOptions
        : lk.CameraCaptureOptions(params: _preset.capture, maxFrameRate: _preset.maxFps);
    // The old capture goes first: some Android cameras open once.
    await lp.removePublishedTrack(pub.sid);
    final track = await lk.LocalVideoTrack.createCameraTrack(options);
    try {
      await lp.publishVideoTrack(track, publishOptions: callVideoPublishOptions(_preset, codec));
    } catch (_) {
      await callPublishFailed(room);
      rethrow;
    }
    videoCodec = codec;
  }

  /// Joined while my call still rang (no mic yet — status 223): the other
  /// side answered — the mic opens (muted if I muted it meanwhile) and the
  /// camera of a video call starts.
  Future<void> goLive({required bool mic, required bool camera}) async {
    final lp = room.localParticipant;
    if (lp == null) return;
    try {
      if (lp.audioTrackPublications.isEmpty) {
        final track = await lk.LocalAudioTrack.create(LiveKitCallEngine._micCapture);
        if (!mic) await track.mute(stopOnMute: false);
        await lp.publishAudioTrack(track);
      } else if (mic) {
        for (final pub in lp.audioTrackPublications) {
          await pub.unmute(stopOnMute: false);
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] microphone not opened: $e');
      await callPublishFailed(room);
    }
    if (camera) {
      try {
        await lp.setCameraEnabled(true);
      } catch (e) {
        // ignore: avoid_print
        print('[livekit] camera not published (audio only from here): $e');
        await callPublishFailed(room);
      }
    }
  }

  /// Tear down room + cancel timer. Idempotent.
  Future<void> disconnect() async {
    _epochPoll?.cancel();
    await codecs?.dispose();
    await closeCallRoom(room);
  }
}

/// Status 184 (owner, 2026-10-19: "the call isn't on screen, but I still
/// hear the voice; the mic says it's on after the call ended") — every
/// room [LiveKitCallEngine.connect] opened, until it's closed. A room a
/// late join or a quick hang-up left behind is closed by
/// [closeOrphanCallRooms] once no call is on.
final Set<lk.Room> openCallRooms = {};

/// My mic and camera stopped (not just the room left), then the room.
Future<void> closeCallRoom(lk.Room room) async {
  openCallRooms.remove(room);
  try {
    await room.localParticipant?.unpublishAllTracks(stopOnUnpublish: true);
  } catch (_) {}
  try {
    await room.disconnect();
  } catch (_) {
    // Already disconnected — fine.
  }
  try {
    await room.dispose();
  } catch (_) {}
}

/// Audit 2026-11b (11) — how a room's call is ended from a failed publish
/// (set at the join): what happened, and the end reason.
final callRefusers = Expando<void Function(String what, String reason)>();

/// Tracks [callPublishFailed] already stopped, per room.
final _stoppedTracks = Expando<Set<String>>();

/// Audit 2026-11b (11) — call after any failed publish (mic, camera,
/// screen). LiveKit may put a track on the connection before the server
/// confirms it (the server picks that order), and gives it the SFrame
/// cryptor only after; a server that then stays silent would go on
/// receiving the track in the clear while the app thinks nothing is sent.
/// So: a track on the connection that no publication owns is always
/// stopped. A camera / screen track: the call goes on with sound only (a
/// lost reply on a bad network must not end it). The mic: the call ends
/// as "couldn't connect" (no second try: it could put a muted mic on air).
///
/// A track with no publication may also be an honest publish still on its
/// way (queued behind the failed one, or LiveKit publishing again after a
/// reconnect), so it is looked at again after [callPublishGrace] — longer
/// than LiveKit's own publish timeout (10 s) — and stopped only if still
/// nobody's.
Future<void> callPublishFailed(lk.Room room) async {
  var bareMic = false;
  try {
    final seen = await _bareTracks(room);
    final first = {for (final t in seen) t.id};
    if (first.isEmpty) return;
    await Future<void>.delayed(callPublishGrace);
    if (!openCallRooms.contains(room)) {
      // The call is over: nothing is sent, but the capture must not stay open.
      for (final t in seen) {
        try {
          await t.stop();
        } catch (_) {}
      }
      return;
    }
    for (final track in await _bareTracks(room)) {
      if (!first.contains(track.id)) continue;
      (_stoppedTracks[room] ??= {}).add(track.id ?? '');
      if (track.kind != 'video') bareMic = true;
      try {
        await track.stop();
      } catch (_) {}
    }
  } catch (_) {}
  if (!bareMic) return;
  callRefusers[room]?.call('the microphone the server did not confirm', kCallMediaFailed);
}

/// Audit 2026-11b (61) — after a reconnect LiveKit publishes my tracks
/// again by itself (no publish call of the app fails): the same check as
/// [callPublishFailed], once those publishes had time to finish.
void checkPublishesAfterReconnect(lk.Room room) {
  room.events.listen((event) {
    if (event is! lk.RoomReconnectedEvent) return;
    unawaited(Future<void>.delayed(callPublishGrace, () => callPublishFailed(room)));
  });
}

/// See [callPublishFailed]. Tests shorten it.
Duration callPublishGrace = const Duration(seconds: 12);

/// Tracks on the connection that no publication of mine owns (and that
/// [callPublishFailed] has not stopped yet).
Future<List<rtc.MediaStreamTrack>> _bareTracks(lk.Room room) async {
  // ignore: invalid_use_of_internal_member
  final senders = await room.engine.publisher?.pc.getSenders() ?? const <rtc.RTCRtpSender>[];
  final mine = {
    for (final p in room.localParticipant?.trackPublications.values ?? const <lk.LocalTrackPublication>[])
      p.track?.mediaStreamTrack.id,
  };
  final stopped = _stoppedTracks[room] ?? const <String>{};
  return [
    for (final s in senders)
      if (s.track != null && !mine.contains(s.track!.id) && !stopped.contains(s.track!.id ?? '')) s.track!,
  ];
}

/// The call's media never came up — shown as "couldn't connect".
const kCallMediaFailed = 'livekit_failure';

/// Every call room still open, except [keep] — none should be once a call
/// is over. Returns how many were closed (diagnostics).
Future<int> closeOrphanCallRooms({lk.Room? keep}) async {
  final orphans = [for (final r in openCallRooms) if (!identical(r, keep)) r];
  for (final r in orphans) {
    await closeCallRoom(r);
  }
  return orphans.length;
}

/// This phone's class, camera preset and video codec (ADR-041/045/046).
typedef CallMediaSettings = ({CallDeviceClass deviceClass, CallVideoPreset preset, String codec});

/// What joining a call needs from the server and the phone — fetched while
/// it rings, so the answer goes straight to joining.
class CallPrep {
  CallPrep({
    required this.groupIdHex,
    required this.kind,
    required this.token,
    required this.turn,
    required this.media,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String groupIdHex;
  final String kind;
  final core.LivekitTokenInfo token;
  final core.TurnCredsInfo turn;
  final CallMediaSettings media;
  final DateTime at;

  /// Join tokens live an hour; a rejoin long into a call asks again.
  static const maxAge = Duration(minutes: 10);

  bool usableFor(String groupIdHex, {DateTime? now}) =>
      groupIdHex == this.groupIdHex && (now ?? DateTime.now()).difference(at) < maxAge;
}

/// The call room's settings: SFrame E2EE and this phone's media (ADR-041).
lk.RoomOptions callRoomOptions(lk.E2EEOptions e2eeOpts, CallMediaSettings media) => lk.RoomOptions(
    adaptiveStream: true,
    // Audit 2026-11b (12) — off: with dynacast on, one message from the
    // server (SubscribedQualityUpdate naming another codec) makes LiveKit
    // open a second sender for my camera / screen — a "backup codec" copy
    // with no SFrame cryptor, whatever `BackupVideoCodec(enabled: false)`
    // says (livekit_client 2.7.0 never reads `enabled` there).
    dynacast: false,
    // calls:3 — `encryption` (not the old `e2eeOptions`): data messages
    // (the codec agreement) are encrypted too.
    encryption: e2eeOpts,
    defaultCameraCaptureOptions: lk.CameraCaptureOptions(
      params: media.preset.capture,
      maxFrameRate: media.preset.maxFps,
    ),
    // ADR-061 — my shared screen: same codec and encryption as the
    // camera, the screen's own encoding (sharp, 15 fps at most) and the
    // iPhone's broadcast extension for the capture.
    defaultVideoPublishOptions: callVideoPublishOptions(
      media.preset,
      media.codec,
    ).copyWith(screenShareEncoding: kScreenShareEncoding),
    defaultScreenShareCaptureOptions: kScreenShareCaptureOptions,
    defaultAudioPublishOptions: kCallAudioPublishOptions,
    defaultAudioCaptureOptions: LiveKitCallEngine._micCapture,
  );

/// Stateless namespace for the engine entry point.
class LiveKitCallEngine {
  LiveKitCallEngine._();

  /// Step 1: token + TURN creds + media settings, in parallel. Safe to call
  /// while the call rings (the token is per group, not per answer); throws
  /// the first failure.
  static Future<CallPrep> prepare({
    required String httpBaseUrl,
    required String groupIdHex,
    required String kind,
  }) async {
    try {
      final (token, turn, media) = await (
        core.callRequestLivekitToken(serverBaseUrl: httpBaseUrl, groupIdHex: groupIdHex, kind: kind),
        core.callRequestTurnCreds(serverBaseUrl: httpBaseUrl),
        _mediaSettings(),
      ).wait;
      unawaited(_warmDns(token.livekitUrl));
      return CallPrep(groupIdHex: groupIdHex, kind: kind, token: token, turn: turn, media: media);
    } on ParallelWaitError catch (e) {
      final errors = e.errors;
      if (errors is (AsyncError?, AsyncError?, AsyncError?)) {
        final first = errors.$1 ?? errors.$2 ?? errors.$3;
        if (first != null) Error.throwWithStackTrace(first.error, first.stackTrace);
      }
      rethrow;
    }
  }

  /// The LiveKit host's address looked up ahead (the system caches it), so
  /// the join doesn't wait for DNS — on mobile that can be 100–300 ms.
  static Future<void> _warmDns(String url) async {
    try {
      final host = Uri.parse(url).host;
      if (host.isNotEmpty) await InternetAddress.lookup(host);
    } catch (_) {
      // Only a head start; the join resolves it anyway.
    }
  }

  /// The mic's capture settings. Noise suppression, echo cancellation and
  /// gain control are on by default; the high-pass filter (rumble, wind, a
  /// knock on the table) was off — on now. iPhone adds its own voice
  /// processing; "Voice Isolation" is the person's choice (call screen →
  /// mic mode).
  static const _micCapture = lk.AudioCaptureOptions(highPassFilter: true);

  /// CD6 — join the room and publish. Throws on any step failure before
  /// the room is joined; caller wraps in try/catch and surfaces as a
  /// CallEnd { reason: ... }.
  ///
  /// [prep] comes from [prepare] (usually done while ringing). The
  /// `livekit_url` it carries drives the WebRTC signaling connect.
  ///
  /// [micMuted]: join with the mic published but silent — my outgoing call
  /// still rings; [LiveKitSession.goLive] opens it on the answer. [camera]:
  /// a video call's camera starts now (false: [LiveKitSession.goLive]).
  ///
  /// Identity comes from the SyncClient singleton already initialized
  /// at onboarding (`sync_init_from_phrase`) — no phrase needed here.
  /// Phrase persists nowhere per spec §6.8.
  /// CE5 — network state callbacks for the caller (activeCallProvider).
  /// Invoked from `Room.events` listener inside [connect].
  /// `onReconnecting` fires on signaling/peer drop; `onReconnected`
  /// fires when LiveKit recovers. `onDisconnected` is terminal —
  /// caller should auto-end the call.
  static Future<LiveKitSession> connect({
    required CallPrep prep,
    void Function()? onReconnecting,
    void Function()? onReconnected,
    void Function(String reason)? onDisconnected,
    // ADR-042 — `reserve`: media only through our TURN over TLS on 443.
    CallPath path = CallPath.direct,
    bool micMuted = false,
    bool camera = true,
    CallTimeline? timeline,
    // Status 223 — the speaker as chosen before the join (owner: "I turn the
    // speaker on while it rings, and it still talks in the earpiece").
    // Null: video on the speaker, audio on the earpiece.
    bool? speaker,
  }) async {
    final groupIdHex = prep.groupIdHex;
    final kind = prep.kind;
    final speakerOn = speaker ?? kind == 'video';
    final token = prep.token;
    final turn = prep.turn;
    final media = prep.media;

    // ── Step 2: build the E2EE options with our custom key provider.
    //
    // `BaseKeyProvider.create` is a static factory in livekit_client
    // 2.5.0. Named args; `sharedKey: false` switches the provider into
    // per-participant mode (we manage one key per leaf). `ratchetWindowSize: 0`
    // disables LiveKit's built-in ratchet — MLS handles rotation; a
    // second ratchet on top would be redundant (spec §10.4). Our own random
    // trailer and no server trailer (calls:2, [CallKeyProvider]).
    final base = await lk.BaseKeyProvider.create(
      sharedKey: false,
      ratchetWindowSize: 0,
      uncryptedMagicBytes: callUncryptedMagicBytes(),
    );
    final keyProvider = CallKeyProvider(base.keyProvider, base.options);
    useCallAudioConfig(speaker: speakerOn);

    final e2eeOpts = lk.E2EEOptions(keyProvider: keyProvider);

    // ICE servers from the TURN response. Local-LAN-only dev environments
    // can skip TURN entirely; LiveKit will still succeed via host
    // candidates. Production cross-LAN calls need the relay.
    final reserve = path == CallPath.reserve;
    final urls = reserve ? reserveTurnUrls(turn.urls) : turn.urls;
    if (reserve && urls.isEmpty) throw StateError('this server has no reserve path (no turns: URL)');
    final iceServers = <lk.RTCIceServer>[
      lk.RTCIceServer(urls: urls, username: turn.username, credential: turn.credential),
    ];

    // Instantiate the Room and connect. RoomOptions stays in the
    // constructor (E2EE config is constructor-time); ConnectOptions lives
    // on connect() per livekit_client 2.5 deprecation guidance.
    // ADR-041 — explicit media settings for poor links and weak phones
    // (LiveKit's defaults were 720p / 30 fps / 1.7 Mbps VP8 + 48 kbps Opus).
    // ignore: avoid_print
    print('[livekit] media: ${media.deviceClass.name} device, codec=${media.codec}');
    final room = lk.Room(roomOptions: callRoomOptions(e2eeOpts, media));

    openCallRooms.add(room);

    // calls:1 — every track mine and theirs must be SFrame-encrypted; the
    // server saying otherwise ends the call (my mic and camera stop first)
    // instead of going on in the clear. Listening from before the join.
    var refused = false;
    void refuse(String what, [String reason = kCallNotEncrypted]) {
      if (refused) return;
      refused = true;
      // ignore: avoid_print
      print('[livekit] $what is not encrypted — ending the call');
      unawaited(closeCallRoom(room));
      onDisconnected?.call(reason);
    }

    callRefusers[room] = refuse;
    room.events.listen((event) {
      if (event is lk.LocalTrackPublishedEvent) {
        final pub = event.publication;
        if (!callTrackEncrypted(pub.encryptionType, codec: pub.track?.codec ?? '')) refuse('my ${pub.source.name}');
      } else if (event is lk.TrackPublishedEvent) {
        if (!callTrackEncrypted(event.publication.encryptionType)) refuse('a published track');
      } else if (event is lk.TrackSubscribedEvent) {
        final pub = event.publication;
        if (!callTrackEncrypted(pub.encryptionType, mimeType: pub.mimeType)) refuse('a received ${pub.source.name}');
      }
    });

    silenceUnboundTracks(room);
    checkPublishesAfterReconnect(room);

    // ── Step 3: the microphone track is made while the room connects
    //           (it used to start only after the join and the keys).
    // Status 223 (owner: "I called my sister and heard no ringback") — not
    // while my call still rings: a running mic starts iOS's voice
    // processing, which turns the ringback down to nothing. It opens on the
    // answer ([LiveKitSession.goLive]).
    final micFut = micMuted
        ? Future<lk.LocalAudioTrack?>.value(null)
        : lk.LocalAudioTrack.create(_micCapture).then<lk.LocalAudioTrack?>((t) => t, onError: (Object e) {
            // ignore: avoid_print
            print('[livekit] microphone not opened ahead: $e');
            return null;
          });

    // ignore: avoid_print
    print('[livekit] path: ${path.name}');
    try {
      await room
          .connect(
            token.livekitUrl,
            token.token,
            connectOptions: lk.ConnectOptions(
              rtcConfiguration: lk.RTCConfiguration(
                iceServers: iceServers,
                // Reserve: no direct UDP / TCP to the SFU — only the relay.
                iceTransportPolicy: reserve ? lk.RTCIceTransportPolicy.relay : null,
              ),
            ),
          )
          // A path that's blocked can hang the join; the caller tries the
          // reserve (or ends the call) instead of waiting forever.
          .timeout(kCallConnectTimeout);
    } catch (_) {
      unawaited(closeCallRoom(room));
      unawaited(micFut.then((t) async => await t?.stop() ?? false).catchError((Object _) => false));
      rethrow;
    }
    timeline?.mark('room');

    // ── Step 4: SFrame keys per participant (tech-debt 4.1/4.9). In
    //           per-participant mode LiveKit looks a key up by the
    //           participant's identity — which is their identity public
    //           key hex, i.e. their MLS credential — so we derive and set
    //           a key for ourselves and for everyone in the room, now and
    //           as people join. (Before: one key set under the empty id,
    //           so no frame cryptor had a key at all.)
    final keys = _CallKeys(keyProvider: keyProvider, groupIdHex: groupIdHex);
    final me = room.localParticipant?.identity;
    if (me != null) await keys.set(me, local: true, room: room);
    for (final p in room.remoteParticipants.values) {
      await keys.set(p.identity, room: room);
    }
    room.events.listen((event) async {
      if (event is lk.ParticipantConnectedEvent) {
        // ignore: avoid_print
        print('[livekit] participant connected: ${event.participant.identity}');
        await keys.set(event.participant.identity, room: room);
      } else if (event is lk.ParticipantDisconnectedEvent) {
        // ignore: avoid_print
        print('[livekit] participant left: ${event.participant.identity}');
      } else if (event is lk.RoomReconnectingEvent) {
        // ignore: avoid_print
        print('[livekit] reconnecting (signaling or peer connection lost)');
        onReconnecting?.call();
      } else if (event is lk.RoomReconnectedEvent) {
        // ignore: avoid_print
        print('[livekit] reconnected');
        onReconnected?.call();
      } else if (event is lk.RoomDisconnectedEvent) {
        final reason = event.reason?.toString() ?? 'unknown';
        // ignore: avoid_print
        print('[livekit] room disconnected: $reason');
        onDisconnected?.call(reason);
      }
    });

    // ── Step 5: publish mic (always — silent while my call still rings) +
    //           cam (a video call, once answered).
    // We are in the room by now: a device without a camera (the Simulator)
    // or a refused/busy mic must not end the call — it used to throw out
    // of here and the call ended as `livekit_failure` (2026-10-15). The
    // other side's media still plays; we just send less.
    if (!micMuted) {
      try {
        final mic = await micFut ?? await lk.LocalAudioTrack.create(_micCapture);
        await room.localParticipant?.publishAudioTrack(mic);
        timeline?.mark('mic');
      } catch (e) {
        // ignore: avoid_print
        print('[livekit] microphone not published: $e');
        await callPublishFailed(room);
      }
    }
    if (kind == 'video' && camera) {
      try {
        await room.localParticipant?.setCameraEnabled(true);
      } catch (e) {
        // ignore: avoid_print
        print('[livekit] camera not published (audio only from here): $e');
        await callPublishFailed(room);
      }
    }

    // CE3 — initial audio routing. iOS default for AVAudioSession in
    // `playAndRecord` mode routes audio to the earpiece (held-to-ear
    // phone-call expectation). For VIDEO calls users hold the phone at
    // arm's length to watch the screen, so speakerphone is the better
    // default. For AUDIO calls earpiece stays right.
    //
    // LiveKit's `Hardware.setSpeakerphoneOn` internally configures
    // `AVAudioSession.Category.playAndRecord` + mode + options via
    // `Native.configureAudio(NativeAudioConfiguration)`. Best-effort —
    // failure here doesn't tear down the call (audio still works,
    // just possibly in the wrong direction).
    try {
      await lk.Hardware.instance.setSpeakerphoneOn(speakerOn);
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] initial setSpeakerphoneOn failed: $e');
    } finally {
      releaseJoinSpeaker();
    }

    // ── Step 6: kick off the epoch poll. Every 2 seconds compare
    //           current `mlsGroupEpoch` against our snapshot. If it
    //           bumped (Commit happened mid-call), re-derive keys.
    final epochPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        await keys.rotateIfEpochChanged(room);
      } catch (_) {
        // Rotation failures are non-fatal — old key still valid in
        // keyring overlap window. Log and continue.
      }
    });

    final session = LiveKitSession._(
      room: room,
      groupIdHex: groupIdHex,
      epochPoll: epochPoll,
      preset: media.preset,
      videoCodec: media.codec,
      deviceClass: media.deviceClass,
    );
    // ── Step 7 (ADR-045): agree on the best video codec with the others —
    //           in the background; the call is up already.
    unawaited(_agreeCodecs(session, token.videoCodecs));
    return session;
  }

  static Future<void> _agreeCodecs(LiveKitSession session, List<String> server) async {
    try {
      final abilities = await CodecAbilities.probe();
      // ignore: avoid_print
      print('[livekit] codecs: server=$server hw=${abilities.hardware} dec=${abilities.decodable}');
      if (session.room.connectionState == lk.ConnectionState.disconnected) return;
      session.codecs = CodecNegotiator(
        room: session.room,
        server: server,
        abilities: abilities,
        currentCodec: () => session.cameraCodec,
        onWant: session.republishCamera,
      )..start();
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] codec agreement off: $e');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────

  static const _media = MethodChannel('dev.sinhron/media');

  /// ADR-046 — the phone's heat, 0 nominal … 3 critical (iOS
  /// `ProcessInfo.thermalState`; Android `PowerManager` thermal status
  /// mapped onto it). 0 when the OS can't say.
  static Future<ThermalLevel> thermalLevel() async {
    try {
      return (await _media.invokeMethod<int>('thermalState')) ?? 0;
    } on MissingPluginException {
      return 0;
    } on PlatformException {
      return 0;
    }
  }

  /// This phone's class (Android: RAM, cores, OS version) and the codec
  /// its encoder list allows. Any failure → the safe middle: standard
  /// preset, VP8.
  /// Once per app run: the phone doesn't change between calls.
  static Future<CallMediaSettings>? _mediaCache;
  static Future<CallMediaSettings> _mediaSettings() => _mediaCache ??= _probeMedia();

  static Future<CallMediaSettings> _probeMedia() async {
    var deviceClass = CallDeviceClass.standard;
    if (Platform.isIOS) {
      try {
        final i = await DeviceInfoPlugin().iosInfo;
        deviceClass = classifyCallDevice(isAndroid: false, iosMachine: i.utsname.machine);
      } catch (e) {
        // ignore: avoid_print
        print('[livekit] device info unavailable: $e');
      }
    } else if (Platform.isAndroid) {
      try {
        final a = await DeviceInfoPlugin().androidInfo;
        deviceClass = classifyCallDevice(
          isAndroid: true,
          ramMb: a.physicalRamSize,
          cores: Platform.numberOfProcessors,
          isLowRamDevice: a.isLowRamDevice,
          sdkInt: a.version.sdkInt,
        );
      } catch (e) {
        // ignore: avoid_print
        print('[livekit] device info unavailable: $e');
      }
    }
    var codec = 'vp8';
    try {
      final caps = await rtc.getRtpSenderCapabilities('video');
      codec = chooseVideoCodec(encoderMimeTypes: [for (final c in caps.codecs ?? const []) c.mimeType]);
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] encoder list unavailable, VP8: $e');
    }
    return (deviceClass: deviceClass, preset: callVideoPreset(deviceClass), codec: codec);
  }
}

/// SFrame keys of everyone in one call, kept in step with the MLS epoch.
class _CallKeys {
  _CallKeys({required this.keyProvider, required this.groupIdHex});

  final lk.BaseKeyProvider keyProvider;
  final String groupIdHex;
  final _identities = <String>{};
  int _epoch = -1;

  /// Derive [identity]'s current key (Rust: leaf by identity → exporter →
  /// RFC 9605 key) and set it in that participant's key-ring slot.
  Future<void> set(String identity, {bool local = false, required lk.Room room}) async {
    final k = await core.callSframeKeyFor(groupIdHex: groupIdHex, identityHex: identity);
    await keyProvider.setRawKey(
      Uint8List.fromList(_decodeHex(k.keyHex)),
      participantId: identity,
      keyIndex: k.keyIndex,
    );
    _identities.add(identity);
    _epoch = k.epoch.toInt();
    // Our outgoing frames switch to the new slot; receivers read the slot
    // from each frame, so they follow automatically.
    if (local) await room.e2eeManager?.setKeyIndex(k.keyIndex);
  }

  /// A Commit changed the epoch mid-call: re-key everyone (the old slot
  /// stays in LiveKit's 16-slot ring for frames still in flight).
  Future<void> rotateIfEpochChanged(lk.Room room) async {
    final epoch = (await core.mlsGroupEpoch(groupIdHex: groupIdHex)).toInt();
    if (epoch == _epoch) return;
    final me = room.localParticipant?.identity;
    for (final id in _identities.toList()) {
      await set(id, local: id == me, room: room);
    }
    // ignore: avoid_print
    print('[livekit] sframe keys rotated for epoch=$epoch');
  }
}

List<int> _decodeHex(String s) {
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return out;
}
