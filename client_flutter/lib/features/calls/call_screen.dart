// 1:1 Call screen — full-screen call UI with 3 states:
//   incoming → ringing with Accept / Decline
//   active   → live call (audio or video) with mute / speaker / video /
//              switch-camera / end controls
//   ended    → short summary card before popping back
//
// Per spec §6.5, every call is E2EE via SFrame on top of WebRTC. We surface
// the "encrypted" label in every state — it's a meaningful trust signal in
// a context (calls) where most messengers don't communicate it.
//
// Composition is state-driven inside one widget — keeps the auto-transition
// (incoming → active on Accept, active → ended on End) clean, and means a
// single screen replaces what Phase 2 will eventually be 3 separate routes
// driven by LiveKit events.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_pressable.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_shared_glyphs.dart';
import 'call_quality.dart';
import 'call_voice_bars.dart';

enum CallState { incoming, outgoing, active, ended }

enum CallMedia { audio, video }

class CallScreen extends StatefulWidget {
  final String contactName;

  /// Their photo, if they shared one (else initials).
  final Uint8List? contactPhoto;
  final CallState initialState;
  final CallMedia initialMedia;
  final VoidCallback? onClose;

  /// CD7 — invoked when the user taps the mute toggle. Receives the
  /// NEW value (true = newly muted, false = newly unmuted). Caller
  /// (LiveCallScreen) routes this to
  /// `room.localParticipant.setMicrophoneEnabled(!muted)`. When `null`,
  /// CallScreen uses its own local state (demo / preview).
  final void Function(bool muted)? onToggleMute;

  /// CD7 — speaker / earpiece switch. Receives the NEW value.
  /// `null` = local-only.
  final void Function(bool speaker)? onToggleSpeaker;

  /// Live calls: where the sound really goes (the call knows; headphones
  /// change it). `null` = demo, the button keeps its own state.
  final bool? speakerOn;

  /// A headset / Bluetooth is around (owner, 2026-10-16): the speaker
  /// button shows where the sound goes ([audioRouteLabel], e.g. "AirPods")
  /// and opens the choice instead of toggling — `call_audio.dart`. Also a
  /// button on video calls then. `null` = only earpiece and speaker.
  final VoidCallback? onPickAudioRoute;
  final String? audioRouteLabel;

  /// The sound is on a headset / Bluetooth / car now (the button's glyph).
  final bool audioRouteExternal;

  /// iPhone: the mic mode ("Voice Isolation") and opening its system menu
  /// (2026-10-16, "the best possible sound"). `null` = no such choice.
  final String? micModeLabel;
  final VoidCallback? onMicMode;

  /// CD7 — flip front ↔ back camera. Caller routes to
  /// `room.localParticipant.switchCamera()`. `null` = local-only.
  final VoidCallback? onSwitchCamera;

  /// Live calls: Accept goes to the call (`ActiveCallNotifier.accept`) and
  /// the screen follows [initialState] as the call moves on. `null` =
  /// demo / preview, Accept just flips the picture.
  final VoidCallback? onAccept;

  /// Live calls: turn my camera on/off in the room; returns whether it
  /// worked (no camera / refused → stays on audio). `null` = demo.
  final Future<bool> Function(bool on)? onToggleCamera;

  /// The other side is sending video: show it even if my camera is off
  /// (it used to depend on who pressed what).
  final bool remoteVideoOn;

  const CallScreen({
    super.key,
    this.contactName = '',
    this.contactPhoto,
    this.initialState = CallState.incoming,
    this.initialMedia = CallMedia.audio,
    this.onClose,
    this.onToggleMute,
    this.onToggleSpeaker,
    this.speakerOn,
    this.onPickAudioRoute,
    this.audioRouteLabel,
    this.audioRouteExternal = false,
    this.micModeLabel,
    this.onMicMode,
    this.onSwitchCamera,
    this.onAccept,
    this.onToggleCamera,
    this.remoteVideoOn = false,
    this.remoteVideo,
    this.selfVideo,
    this.endedLabel,
    this.cameraOn,
    this.connectedAt,
    this.endedAt,
    this.muted,
    this.linkQuality,
    this.notice = CallNotice.none,
    this.onMinimize,
    this.connecting = false,
    this.holdLayout = false,
    this.peerRinging = false,
    this.voiceLevel,
    this.peerMicOff = false,
    this.onShareScreen,
    this.sharingScreen = false,
  });

  /// Live calls: "Show screen" (ADR-061) — a button among the others; it
  /// floated on the right edge over the name (owner, 2026-10-19). `null` =
  /// no such button (no room yet, demos). [sharingScreen]: mine is shown
  /// now, the button says "Stop".
  final VoidCallback? onShareScreen;
  final bool sharingScreen;

  /// A 1:1 call: the other person's mic is off — a crossed mic on their
  /// photo (owner, 2026-10-19: "no sign that the other side muted").
  final bool peerMicOff;

  /// Back to the app with the call going on (owner, 2026-10-18: "to get to
  /// the chat I had to hang up"); a call bar on every screen brings it back.
  /// `null` = no such button (incoming, ended, demos).
  final VoidCallback? onMinimize;

  /// Answered, but the other side's sound isn't here yet: "Connecting…"
  /// instead of a timer running over silence.
  final bool connecting;

  /// Status 212 — the room is being rejoined (path switch): the layout
  /// (video or audio) stays as it was instead of flipping for a moment.
  final bool holdLayout;

  /// Status 213 — my call reached their phone ("Ringing…").
  final bool peerRinging;

  /// The other side's voice level 0..1 — bars under their photo. `null` =
  /// no bars (demos).
  final ValueListenable<double>? voiceLevel;

  /// Live calls: when it connected (the timer counts from it, also after
  /// the screen is reopened) and whether my mic is off. `null` = demo.
  final DateTime? connectedAt;
  final bool? muted;

  /// Live calls: when it ended. "Call ended · 02:37" counts [connectedAt]
  /// → this — the screen is often built anew at the end (the room goes
  /// away), and its own timer then said "00:00" (owner, 2026-10-19).
  final DateTime? endedAt;

  /// Live calls: whether my camera really is on — the call may switch it
  /// off by itself on a poor link (ADR-041). `null` = demo, local state.
  final bool? cameraOn;

  /// Live calls: my link's grade as signal bars by the timer (ADR-041).
  /// `null` = demo, no bars.
  final CallLinkQuality? linkQuality;

  /// One line about the link under the timer ("Weak connection", "camera
  /// off to keep the voice").
  final CallNotice notice;

  /// Why the call ended, when it never connected ("No answer", "Busy",
  /// "Declined"). Null → "Call ended · duration".
  final String? endedLabel;

  /// Live media (tech-debt 4.9): the participant grid and our camera. When
  /// null (demos, audio) the placeholder art is shown.
  final Widget? remoteVideo;
  final Widget? selfVideo;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with SingleTickerProviderStateMixin {
  late CallState _state = widget.initialState;
  late CallMedia _media = widget.initialMedia;
  late bool _muted = widget.muted ?? false;
  late bool _speaker = widget.speakerOn ?? false;

  /// The layout last shown — kept while [CallScreen.holdLayout].
  bool _wasVideo = false;

  // Active-call timer
  Duration _elapsed = Duration.zero;
  Timer? _ticker;

  // Pulse animation for the avatar in incoming state
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
    if (_state == CallState.active) {
      final since = widget.connectedAt;
      if (since != null) _elapsed = DateTime.now().difference(since);
      _startTicker();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final since = widget.connectedAt;
      setState(() => _elapsed = since == null ? _elapsed + const Duration(seconds: 1) : DateTime.now().difference(since));
    });
  }

  // A live call's state comes from the call itself (LiveCallScreen passes
  // it in); the screen used to read it once and then ignore the call.
  @override
  void didUpdateWidget(CallScreen old) {
    super.didUpdateWidget(old);
    final muted = widget.muted;
    if (muted != null && muted != old.muted && muted != _muted) setState(() => _muted = muted);
    final speaker = widget.speakerOn;
    // Only when the call's own state moved (rebuilds while my tap is still
    // being applied must not flip the button back).
    if (speaker != null && speaker != old.speakerOn && speaker != _speaker) setState(() => _speaker = speaker);
    final camera = widget.cameraOn;
    if (camera != null && camera != old.cameraOn) {
      final media = camera ? CallMedia.video : CallMedia.audio;
      if (media != _media) setState(() => _media = media);
    }
    // Status 212 — "Call ended" stays to the end: when the call went idle
    // its screen showed "Calling…" for a moment before closing.
    if (_state == CallState.ended) return;
    if (widget.initialState != old.initialState && widget.initialState != _state) {
      setState(() => _state = widget.initialState);
      if (_state == CallState.active) {
        _elapsed = Duration.zero;
        _startTicker();
      } else {
        _ticker?.cancel();
      }
    }
  }

  void _accept() {
    if (widget.onAccept != null) {
      widget.onAccept!(); // the call connects; the new state arrives from it
      return;
    }
    setState(() => _state = CallState.active);
    _startTicker();
  }

  Future<void> _switchToVideo() async {
    final toggle = widget.onToggleCamera;
    // No camera / refused: stay on audio.
    if (toggle != null && !await toggle(true)) return;
    if (mounted) setState(() => _media = CallMedia.video);
  }

  void _switchToAudio() {
    widget.onToggleCamera?.call(false);
    setState(() => _media = CallMedia.audio);
  }

  void _hangUp() {
    _ticker?.cancel();
    setState(() => _state = CallState.ended);
    // End the call now — camera and mic off at once; the call closes the
    // screen after a short "Call ended" (it used to wait 1.6 s first, with
    // the other side still seeing me — owner, 2026-10-16).
    widget.onClose?.call();
  }

  void _decline() {
    widget.onClose?.call();
  }

  /// CD7 — flip local mute state THEN notify the parent so it can call
  /// `room.localParticipant.setMicrophoneEnabled` on the LiveKit room.
  /// We update local state first so the button visual flips instantly
  /// without waiting for the LiveKit ack.
  void _onToggleMute() {
    final newMuted = !_muted;
    setState(() => _muted = newMuted);
    widget.onToggleMute?.call(newMuted);
  }

  /// CD7 — same pattern for speaker / earpiece routing.
  void _onToggleSpeaker() {
    final newSpeaker = !_speaker;
    setState(() => _speaker = newSpeaker);
    widget.onToggleSpeaker?.call(newSpeaker);
  }

  String get _durationLabel => callClock(_elapsed);

  /// The talk time on the "Call ended" screen: the call's own times when
  /// it has them, else what this screen counted.
  String get _endedDurationLabel {
    final from = widget.connectedAt, to = widget.endedAt;
    return callClock(from != null && to != null && !to.isBefore(from) ? to.difference(from) : _elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final video =
        _state == CallState.active &&
        (widget.holdLayout ? _wasVideo : (_media == CallMedia.video || widget.remoteVideoOn));
    _wasVideo = video;
    // Ringing → connecting → talking → ended cross-fade (they used to cut).
    return AnimatedSwitcher(
      duration: DsMotion.of(context, DsMotion.base),
      switchInCurve: DsMotion.enter,
      switchOutCurve: DsMotion.exit,
      layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, ?current]),
      child: KeyedSubtree(
        key: ValueKey(video ? 'video' : _state.name),
        child: _view(video),
      ),
    );
  }

  Widget _view(bool video) {
    return switch (_state) {
      CallState.incoming || CallState.outgoing => _IncomingView(
        name: widget.contactName,
        photo: widget.contactPhoto,
        media: _media,
        pulse: _pulseCtrl,
        outgoing: _state == CallState.outgoing,
        ringing: widget.peerRinging,
        muted: _muted,
        speaker: _speaker,
        onToggleMute: _state == CallState.outgoing ? _onToggleMute : null,
        onToggleSpeaker: _state == CallState.outgoing ? _onToggleSpeaker : null,
        onAccept: _accept,
        onDecline: _decline,
        onMinimize: _state == CallState.outgoing ? widget.onMinimize : null,
      ),
      CallState.active =>
        video
            ? _ActiveVideoView(
                remoteVideo: widget.remoteVideoOn || widget.onToggleCamera == null ? widget.remoteVideo : null,
                selfVideo: _media == CallMedia.video ? widget.selfVideo : null,
                cameraOn: _media == CallMedia.video,
                name: widget.contactName,
                photo: widget.contactPhoto,
                peerMicOff: widget.peerMicOff,
                duration: _durationLabel,
                connecting: widget.connecting,
                linkQuality: widget.linkQuality,
                notice: widget.notice,
                muted: _muted,
                onToggleMute: _onToggleMute,
                onToggleCamera: _media == CallMedia.video ? _switchToAudio : _switchToVideo,
                onSwitchCamera: widget.onSwitchCamera,
                onPickAudioRoute: widget.onPickAudioRoute,
                audioRouteLabel: widget.audioRouteLabel,
                audioRouteExternal: widget.audioRouteExternal,
                speaker: _speaker,
                onToggleSpeaker: _onToggleSpeaker,
                onShareScreen: widget.onShareScreen,
                sharingScreen: widget.sharingScreen,
                onHangUp: _hangUp,
                onMinimize: widget.onMinimize,
              )
            : _ActiveAudioView(
                name: widget.contactName,
                photo: widget.contactPhoto,
                duration: _durationLabel,
                connecting: widget.connecting,
                voiceLevel: widget.voiceLevel,
                peerMicOff: widget.peerMicOff,
                linkQuality: widget.linkQuality,
                notice: widget.notice,
                muted: _muted,
                speaker: _speaker,
                onToggleMute: _onToggleMute,
                onToggleSpeaker: widget.onPickAudioRoute ?? _onToggleSpeaker,
                speakerLabel: widget.onPickAudioRoute == null ? null : widget.audioRouteLabel,
                speakerExternal: widget.audioRouteExternal,
                micModeLabel: widget.micModeLabel,
                onMicMode: widget.onMicMode,
                onSwitchToVideo: _switchToVideo,
                onShareScreen: widget.onShareScreen,
                sharingScreen: widget.sharingScreen,
                onHangUp: _hangUp,
                onMinimize: widget.onMinimize,
              ),
      CallState.ended => _EndedView(name: widget.contactName, photo: widget.contactPhoto, duration: _endedDurationLabel, label: widget.endedLabel),
    };
  }
}

/// What the video call's overlays take: the top row (minimise, lock, timer)
/// and the button bar at the bottom (up to two-line labels). The group grid
/// keeps its tiles between them.
const double kCallTopClearance = 52;
const double kCallBarClearance = 136;

/// "02:37" — a call's length as the timer shows it (minutes go past 59).
String callClock(Duration d) {
  final m = d.inMinutes;
  final s = d.inSeconds % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

// ═════════════════════════════════════════════════════════════════════
// INCOMING
// ═════════════════════════════════════════════════════════════════════

class _IncomingView extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final CallMedia media;
  final AnimationController pulse;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// My own call, ringing on their side: "Calling…" and only a hang-up.
  final bool outgoing;

  /// Status 213 — their phone has it: "Ringing…" instead of "Calling…".
  final bool ringing;
  final VoidCallback? onMinimize;

  /// Status 223 (owner: "as in WhatsApp, mute or turn the speaker on before
  /// it connects") — my call still ringing: the mic and speaker buttons.
  final bool muted;
  final bool speaker;
  final VoidCallback? onToggleMute;
  final VoidCallback? onToggleSpeaker;

  const _IncomingView({
    required this.name,
    this.photo,
    required this.media,
    required this.pulse,
    required this.onAccept,
    required this.onDecline,
    this.outgoing = false,
    this.ringing = false,
    this.onMinimize,
    this.muted = false,
    this.speaker = false,
    this.onToggleMute,
    this.onToggleSpeaker,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(DsPalette.navy, tokens.accent, 0.15)!, DsPalette.navy],
        ),
      ),
      padding: _CallBody.paddingOf(mq),
      child: Column(
        children: [
          _TopRow(onMinimize: onMinimize),
          Expanded(
            child: _CallBody(
              info: _info(context),
              controls: _controls(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 18),
      Text(
        outgoing
            ? (ringing ? context.l10n.callRinging : context.l10n.callCalling)
            : media == CallMedia.video
            ? context.l10n.callIncomingVideo
            : context.l10n.callIncomingAudio,
        style: DsTextArt.t14w500,
      ),
      const SizedBox(height: 36),
      // Fixed box: the rings grow to 190 px and the Stack used to resize
      // with them every frame, so the name below jumped.
      SizedBox(
        width: 190,
        height: 190,
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, _) {
            // Reduce Motion: still rings.
            final t = DsMotion.reduced(context) ? 0.0 : pulse.value;
            return Stack(
              alignment: Alignment.center,
              children: [
                for (var i = 0; i < 3; i++)
                  Opacity(
                    opacity: (1.0 - ((t + i / 3) % 1.0)) * 0.5,
                    child: Container(
                      width: 130 + 60 * ((t + i / 3) % 1.0),
                      height: 130 + 60 * ((t + i / 3) % 1.0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: DsPalette.white40, width: 1),
                      ),
                    ),
                  ),
                DsAvatar(name: name, size: 130, image: photo),
              ],
            );
          },
        ),
      ),
      const SizedBox(height: 28),
      // A long name ("Константин Константинопольский") touched the screen
      // edges (2026-10-16 UI audit): centred, two lines at most.
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
        child: Text(
          name,
          style: DsTextArt.t32w600,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: DsSpace.x4),
    ],
  );

  Widget _controls(BuildContext context) => Padding(
    // Three buttons while my call rings: less side room (an SE on its side).
    padding: EdgeInsets.symmetric(horizontal: outgoing ? DsSpace.x2 : DsSpace.x8),
    child: Row(
      mainAxisAlignment: outgoing ? MainAxisAlignment.spaceEvenly : MainAxisAlignment.spaceBetween,
      children: [
        if (outgoing && onToggleMute != null)
          _CircleButton(
            key: const ValueKey('call-outgoing-mute'),
            glyph: muted ? _CallGlyph.micMuted : _CallGlyph.mic,
            bg: muted ? DsPalette.white : DsPalette.white20,
            fg: muted ? DsPalette.navy : null,
            label: muted ? context.l10n.callUnmute : context.l10n.callMute,
            onTap: onToggleMute!,
          ),
        _CircleButton(
          key: const ValueKey('call-decline'),
          glyph: _CallGlyph.decline,
          bg: DsPalette.red,
          label: outgoing ? context.l10n.callEnd : context.l10n.callDecline,
          onTap: onDecline,
          size: 68,
        ),
        if (outgoing && onToggleSpeaker != null)
          _CircleButton(
            key: const ValueKey('call-outgoing-speaker'),
            glyph: _CallGlyph.speaker,
            bg: speaker ? DsPalette.white : DsPalette.white20,
            fg: speaker ? DsPalette.navy : null,
            label: context.l10n.callSpeaker,
            onTap: onToggleSpeaker!,
          ),
        if (!outgoing)
          _CircleButton(
            key: const ValueKey('call-accept'),
            glyph: _CallGlyph.accept,
            bg: DsPalette.green,
            label: context.l10n.callAccept,
            onTap: onAccept,
            size: 68,
          ),
      ],
    ),
  );
}

// ═════════════════════════════════════════════════════════════════════
// ACTIVE AUDIO
// ═════════════════════════════════════════════════════════════════════

class _ActiveAudioView extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final String duration;
  final bool connecting;
  final ValueListenable<double>? voiceLevel;
  final bool peerMicOff;
  final CallLinkQuality? linkQuality;
  final CallNotice notice;
  final bool muted;
  final bool speaker;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleSpeaker;

  /// Where the sound goes, when there's a choice ("AirPods"); else "Speaker".
  final String? speakerLabel;
  final bool speakerExternal;
  final String? micModeLabel;
  final VoidCallback? onMicMode;
  final VoidCallback onSwitchToVideo;
  final VoidCallback? onShareScreen;
  final bool sharingScreen;
  final VoidCallback onHangUp;
  final VoidCallback? onMinimize;

  const _ActiveAudioView({
    required this.name,
    this.photo,
    required this.duration,
    this.connecting = false,
    this.voiceLevel,
    this.peerMicOff = false,
    this.linkQuality,
    this.notice = CallNotice.none,
    required this.muted,
    required this.speaker,
    required this.onToggleMute,
    required this.onToggleSpeaker,
    this.speakerLabel,
    this.speakerExternal = false,
    this.micModeLabel,
    this.onMicMode,
    required this.onSwitchToVideo,
    this.onShareScreen,
    this.sharingScreen = false,
    required this.onHangUp,
    this.onMinimize,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(DsPalette.navy, tokens.accent, 0.12)!, DsPalette.navy],
        ),
      ),
      padding: _CallBody.paddingOf(mq),
      child: Column(
        children: [
          _TopRow(onMinimize: onMinimize),
          Expanded(
            child: _CallBody(
              info: _info(context),
              controls: _controls(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 28),
      CallPeerAvatar(name: name, photo: photo, size: 116, micOff: peerMicOff),
      const SizedBox(height: DsSpace.x3),
      // Their voice as bars (resting low in silence) — or, their mic
      // off, "Mic off"; the same height without them, so nothing jumps.
      SizedBox(
        height: 28,
        child: peerMicOff
            ? Center(
                child: Text(
                  context.l10n.callPeerMicOff,
                  key: const ValueKey('call-peer-mic-off'),
                  style: DsTextArt.t13w600,
                ),
              )
            : voiceLevel == null || connecting
            ? null
            : CallVoiceBars(level: voiceLevel!),
      ),
      const SizedBox(height: DsSpace.x3),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
        child: Text(
          name,
          style: DsTextArt.t28w600,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      const SizedBox(height: 6),
      _StatusLine(connecting: connecting, duration: duration, linkQuality: linkQuality),
      if (notice != CallNotice.none) ...[
        const SizedBox(height: DsSpace.x4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
          child: CallNoticePill(notice: notice),
        ),
      ],
      const SizedBox(height: DsSpace.x4),
    ],
  );

  // Bottom controls. The mic mode (iPhone "Voice Isolation") sits with the
  // sound controls, above them — not over the hang-up button (owner,
  // 2026-10-18); hang-up stands alone below. The row shares its width
  // evenly: four buttons fit an iPhone SE (owner, 2026-10-19).
  Widget _controls(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
    child: Column(
      children: [
        if (micModeLabel != null && onMicMode != null) ...[
          _MicModePill(label: micModeLabel!, onTap: onMicMode!),
          const SizedBox(height: DsSpace.x5),
        ],
        _SlotRow(
          children: [
            _CircleButton(
              key: const ValueKey('call-audio-mute'),
              glyph: muted ? _CallGlyph.micMuted : _CallGlyph.mic,
              bg: muted ? DsPalette.white : DsPalette.white20,
              fg: muted ? DsPalette.navy : null,
              label: muted ? context.l10n.callUnmute : context.l10n.callMute,
              onTap: onToggleMute,
            ),
            _CircleButton(
              key: const ValueKey('call-video'),
              glyph: _CallGlyph.video,
              bg: DsPalette.white20,
              label: context.l10n.video,
              onTap: onSwitchToVideo,
            ),
            _CircleButton(
              key: const ValueKey('call-speaker'),
              glyph: speakerExternal ? _CallGlyph.headphones : _CallGlyph.speaker,
              bg: speaker ? DsPalette.white : DsPalette.white20,
              fg: speaker ? DsPalette.navy : null,
              label: speakerLabel ?? context.l10n.callSpeaker,
              onTap: onToggleSpeaker,
            ),
            if (onShareScreen != null)
              _ShareScreenButton(sharing: sharingScreen, onTap: onShareScreen!),
          ],
        ),
        const SizedBox(height: 28),
        _CircleButton(
          key: const ValueKey('call-hangup'),
          glyph: _CallGlyph.decline,
          bg: DsPalette.red,
          label: context.l10n.callEnd,
          onTap: onHangUp,
          size: 68,
        ),
      ],
    ),
  );
}

// ═════════════════════════════════════════════════════════════════════
// ACTIVE VIDEO
// ═════════════════════════════════════════════════════════════════════

class _ActiveVideoView extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final bool peerMicOff;
  final String duration;
  final CallLinkQuality? linkQuality;
  final CallNotice notice;
  final bool muted;
  final bool cameraOn;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleCamera;
  final VoidCallback? onSwitchCamera;
  final VoidCallback? onPickAudioRoute;
  final String? audioRouteLabel;
  final bool audioRouteExternal;

  /// Owner, 2026-10-19: "turning video on mid-call, the speaker button is
  /// gone — only in an audio call". Without a headset choice the video
  /// call has the same earpiece / speaker toggle.
  final bool speaker;
  final VoidCallback? onToggleSpeaker;
  final VoidCallback onHangUp;
  final Widget? remoteVideo;
  final Widget? selfVideo;
  final bool connecting;
  final VoidCallback? onMinimize;
  final VoidCallback? onShareScreen;
  final bool sharingScreen;

  const _ActiveVideoView({
    this.remoteVideo,
    this.selfVideo,
    this.connecting = false,
    this.onMinimize,
    this.onShareScreen,
    this.sharingScreen = false,
    this.onSwitchCamera,
    this.onPickAudioRoute,
    this.audioRouteLabel,
    this.speaker = true,
    this.onToggleSpeaker,
    this.audioRouteExternal = false,
    required this.name,
    this.photo,
    this.peerMicOff = false,
    required this.duration,
    this.linkQuality,
    this.notice = CallNotice.none,
    required this.muted,
    required this.cameraOn,
    required this.onToggleMute,
    required this.onToggleCamera,
    required this.onHangUp,
  });

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Landscape: clear of the notch / rounded corners at the sides too.
    final left = mq.padding.left + DsSpace.x3, right = mq.padding.right + DsSpace.x3;
    final selfOn = cameraOn && selfVideo != null;
    return Stack(
      children: [
        // Remote video (live room) or the placeholder art.
        if (remoteVideo != null)
          Positioned.fill(
            child: ColoredBox(color: DsPalette.black, child: remoteVideo!),
          ),
        if (remoteVideo == null)
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [DsPalette.art2D2640, DsPalette.art0F1F3D],
                ),
              ),
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: CallPeerAvatar(name: name, photo: photo, size: 180, micOff: peerMicOff),
                ),
              ),
            ),
          ),
        // Top overlay: minimise, encryption pill, duration — clear of the
        // diagnostics "i" at the top right (live calls).
        Positioned(
          top: mq.padding.top + DsSpace.x2,
          left: left,
          right: right + _TopRow.side + DsSpace.x2,
          child: Row(
            children: [
              if (onMinimize != null) ...[_MinimizeButton(onTap: onMinimize!), const SizedBox(width: DsSpace.x2)],
              // Takes the room left of the timer; gives way (ellipsis) on
              // narrow phones (with a Spacer beside it, it got only half).
              const Expanded(child: Align(alignment: Alignment.centerLeft, child: _EncryptedBadge())),
              const SizedBox(width: DsSpace.x2),
              Container(
                padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.nudge5, DsSpace.x2h5, DsSpace.nudge5),
                decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(999)),
                child: connecting
                    ? const _ConnectingLabel(small: true)
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _PulseDot(),
                          const SizedBox(width: 6),
                          Text(duration, style: DsTextArt.t13w600Mono),
                          if (linkQuality != null) ...[const SizedBox(width: 8), CallSignalBars(quality: linkQuality!)],
                        ],
                      ),
              ),
            ],
          ),
        ),
        // The link line and "their mic is off" — left of the self-view so
        // neither hides the other.
        if (notice != CallNotice.none || peerMicOff)
          Positioned(
            top: mq.padding.top + 60,
            left: left + DsSpace.x1,
            right: selfOn ? right + 120 : right + DsSpace.x1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (notice != CallNotice.none) CallNoticePill(notice: notice),
                if (notice != CallNotice.none && peerMicOff) const SizedBox(height: DsSpace.x2),
                if (peerMicOff) const _PeerMicOffPill(),
              ],
            ),
          ),
        // Self-view PiP — only while my camera is on (it showed demo
        // initials "VK" before).
        // Flip the camera on the picture itself (as FaceTime does): six
        // buttons in the bar left "Перевернуть" unreadable on an iPhone SE.
        if (selfOn)
          Positioned(
            top: mq.padding.top + 60,
            right: right + DsSpace.x1,
            child: SizedBox(
              width: 100,
              height: 140,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(borderRadius: BorderRadius.circular(14), child: selfVideo),
                  ),
                  Positioned(
                    right: DsSpace.x1h5,
                    bottom: DsSpace.x1h5,
                    child: _FlipButton(onTap: onSwitchCamera ?? () {}),
                  ),
                ],
              ),
            ),
          ),
        // Bottom floating controls: every button gets an equal slot, so up
        // to six (mic, camera, flip, sound, screen, end) fit an iPhone SE —
        // they ran off the screen (owner, 2026-10-19).
        Positioned(
          left: left,
          right: right,
          bottom: mq.padding.bottom + DsSpace.x5,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x3),
                decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(36)),
                child: _SlotRow(
                  children: [
                    // One mic button (a second "mic" used to mean "audio only").
                    // White = on/active state, with a label so it's clear.
                    _CircleButton(
                      key: const ValueKey('call-mute'),
                      glyph: muted ? _CallGlyph.micMuted : _CallGlyph.mic,
                      bg: muted ? DsPalette.white : DsPalette.white20,
                      fg: muted ? DsPalette.navy : null,
                      size: 52,
                      label: muted ? context.l10n.callUnmute : context.l10n.callMute,
                      onTap: onToggleMute,
                    ),
                    _CircleButton(
                      key: const ValueKey('call-camera'),
                      glyph: _CallGlyph.video,
                      bg: cameraOn ? DsPalette.white : DsPalette.white20,
                      fg: cameraOn ? DsPalette.navy : null,
                      size: 52,
                      label: context.l10n.video,
                      onTap: onToggleCamera,
                    ),
                    // No picture of me (no camera track yet): flip here.
                    if (cameraOn && selfVideo == null)
                      _CircleButton(
                        key: const ValueKey('call-flip'),
                        glyph: _CallGlyph.cameraSwitch,
                        bg: DsPalette.white20,
                        size: 52,
                        label: context.l10n.callFlipCamera,
                        onTap: onSwitchCamera ?? () {},
                      ),
                    if (onPickAudioRoute != null)
                      _CircleButton(
                        key: const ValueKey('call-audio-route'),
                        glyph: audioRouteExternal ? _CallGlyph.headphones : _CallGlyph.speaker,
                        bg: DsPalette.white20,
                        size: 52,
                        label: audioRouteLabel ?? context.l10n.callSpeaker,
                        onTap: onPickAudioRoute!,
                      )
                    else if (onToggleSpeaker != null)
                      _CircleButton(
                        key: const ValueKey('call-video-speaker'),
                        glyph: _CallGlyph.speaker,
                        bg: speaker ? DsPalette.white : DsPalette.white20,
                        fg: speaker ? DsPalette.navy : null,
                        size: 52,
                        label: context.l10n.callSpeaker,
                        onTap: onToggleSpeaker!,
                      ),
                    if (onShareScreen != null) _ShareScreenButton(sharing: sharingScreen, onTap: onShareScreen!, size: 52),
                    _CircleButton(
                      key: const ValueKey('call-hangup'),
                      glyph: _CallGlyph.decline,
                      bg: DsPalette.red,
                      size: 56,
                      label: context.l10n.callEnd,
                      onTap: onHangUp,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Flip the camera", round, on my own picture.
class _FlipButton extends StatelessWidget {
  const _FlipButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.l10n.callFlipCamera,
    excludeSemantics: true,
    onTap: onTap,
    child: DsPressable(
      key: const ValueKey('call-flip'),
      scale: 0.92,
      onTap: onTap,
      child: Container(
        width: _TopRow.side,
        height: _TopRow.side,
        decoration: const BoxDecoration(color: DsPalette.black40, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: const SizedBox.square(
          dimension: 18,
          child: CustomPaint(painter: _CallGlyphPainter(glyph: _CallGlyph.cameraSwitch, color: DsPalette.white)),
        ),
      ),
    ),
  );
}

/// "Mic off" with a crossed mic, over a video call (their camera may be on).
class _PeerMicOffPill extends StatelessWidget {
  const _PeerMicOffPill();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('call-peer-mic-off'),
    padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x1, DsSpace.x3, DsSpace.x1),
    decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(999)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CallMicOffBadge(size: 22),
        const SizedBox(width: DsSpace.x1h5),
        Flexible(
          child: Text(
            context.l10n.callPeerMicOff,
            style: DsTextArt.t13w600,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

// ═════════════════════════════════════════════════════════════════════
// ENDED
// ═════════════════════════════════════════════════════════════════════

class _EndedView extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final String duration;
  final String? label;
  const _EndedView({required this.name, this.photo, required this.duration, this.label});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // The whole screen (it took the width of its text — a strip at the
    // left, black beside it), fading in quickly.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: DsMotion.of(context, DsMotion.fast),
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [DsPalette.navy, DsPalette.art050B17],
        ),
      ),
      padding: EdgeInsets.only(top: mq.padding.top + DsSpace.x6, bottom: mq.padding.bottom + DsSpace.x8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          DsAvatar(name: name, size: 100, image: photo),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
            child: Text(
              name,
              style: DsTextArt.t24w600,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label ?? context.l10n.callEnded(duration),
            key: const ValueKey('call-ended-label'),
            style: DsTextArt.t14w500v2,
          ),
        ],
      ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Shared pieces
// ═════════════════════════════════════════════════════════════════════

/// ADR-041 — my link as three signal bars (white / amber / red).
class CallSignalBars extends StatelessWidget {
  const CallSignalBars({super.key, required this.quality});

  final CallLinkQuality quality;

  @override
  Widget build(BuildContext context) {
    final on = switch (quality) {
      CallLinkQuality.poor => DsPalette.artE8A317,
      CallLinkQuality.lost => DsPalette.red,
      _ => DsPalette.white,
    };
    final dim = quality == CallLinkQuality.unknown;
    return Semantics(
      label: context.l10n.callLinkQuality,
      value: '${quality.bars}/3',
      child: SizedBox(
        key: const ValueKey('call-signal'),
        height: 12,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 2),
              Container(
                width: 3,
                height: 4.0 + 4 * i,
                decoration: BoxDecoration(
                  color: i < quality.bars && !dim ? on : DsPalette.white20,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// ADR-041 — "Weak connection" / "…on the other side" / "camera off to
/// keep the voice", as a pill under the timer.
class CallNoticePill extends StatelessWidget {
  const CallNoticePill({super.key, required this.notice});

  final CallNotice notice;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final text = switch (notice) {
      CallNotice.weakMine => l.callWeakLink,
      CallNotice.weakPeer => l.callWeakLinkPeer,
      CallNotice.autoAudioOnly => l.callAutoAudioOnly,
      CallNotice.switchingPath => l.callSwitchingPath,
      CallNotice.keepsDropping => l.callKeepsDropping,
      CallNotice.none => '',
    };
    return Container(
      key: const ValueKey('call-notice'),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.x1h5),
      decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: DsTextArt.t13w600, textAlign: TextAlign.center),
    );
  }
}

class _EncryptedBadge extends StatelessWidget {
  const _EncryptedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x1, DsSpace.x2h5, DsSpace.x1),
      decoration: BoxDecoration(color: DsPalette.art1FAF6Ea33, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CustomPaint(painter: DsLockGlyph(color: DsPalette.callGreen)),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              context.l10n.e2eTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.caption.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: DsPalette.callGreen),
            ),
          ),
        ],
      ),
    );
  }
}

/// The top of the ringing / audio screens: minimise at the left, the
/// encryption pill in the middle, room on the right for the diagnostics "i"
/// (live calls put it there).
class _TopRow extends StatelessWidget {
  const _TopRow({this.onMinimize});
  final VoidCallback? onMinimize;

  /// The round buttons' size (minimise, the diagnostics "i").
  static const double side = 32;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3),
    child: SizedBox(
      height: side,
      child: Row(
        children: [
          SizedBox(width: side, child: onMinimize == null ? null : _MinimizeButton(onTap: onMinimize!)),
          const SizedBox(width: DsSpace.x2),
          const Expanded(child: Center(child: _EncryptedBadge())),
          const SizedBox(width: DsSpace.x2 + side),
        ],
      ),
    ),
  );
}

/// "⌄" — back to the app, the call goes on (the call bar returns to it).
class _MinimizeButton extends StatelessWidget {
  const _MinimizeButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.l10n.callMinimize,
    excludeSemantics: true,
    onTap: onTap,
    child: DsPressable(
      key: const ValueKey('call-minimize'),
      scale: 0.92,
      onTap: onTap,
      child: Container(
        width: _TopRow.side,
        height: _TopRow.side,
        decoration: const BoxDecoration(color: DsPalette.white20, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: const SizedBox.square(
          dimension: 18,
          child: CustomPaint(painter: _CallGlyphPainter(glyph: _CallGlyph.minimize, color: DsPalette.white)),
        ),
      ),
    ),
  );
}

/// Under the name: the timer and my link's bars — or, while the other
/// side's sound isn't here yet, "Connecting…" (a soft cross-fade between).
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.connecting, required this.duration, this.linkQuality});
  final bool connecting;
  final String duration;
  final CallLinkQuality? linkQuality;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 22,
    child: AnimatedSwitcher(
      duration: DsMotion.of(context, DsMotion.base),
      child: connecting
          ? const _ConnectingLabel(key: ValueKey('connecting'))
          : Row(
              key: const ValueKey('timer'),
              mainAxisSize: MainAxisSize.min,
              children: [
                const _PulseDot(),
                const SizedBox(width: 8),
                Text(duration, style: DsTextArt.t16w500Mono),
                if (linkQuality != null) ...[const SizedBox(width: 10), CallSignalBars(quality: linkQuality!)],
              ],
            ),
    ),
  );
}

/// "Connecting…" with its three dots breathing in turn — gentle, and still
/// under Reduce Motion.
class _ConnectingLabel extends StatefulWidget {
  const _ConnectingLabel({super.key, this.small = false});
  final bool small;

  @override
  State<_ConnectingLabel> createState() => _ConnectingLabelState();
}

class _ConnectingLabelState extends State<_ConnectingLabel> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (DsMotion.reduced(context)) {
      _ctrl.stop();
    } else if (!_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.small ? DsTextArt.t13w600 : DsTextArt.t16w500.copyWith(color: DsPalette.white80);
    final text = context.l10n.callConnecting;
    // The label without its "…" and three dots of our own.
    final base = text.endsWith('…') ? text.substring(0, text.length - 1) : text;
    final reduced = DsMotion.reduced(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: AnimatedBuilder(
        key: const ValueKey('call-connecting'),
        animation: _ctrl,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(base, style: style),
            for (var i = 0; i < 3; i++)
              Opacity(
                opacity: reduced ? 1 : 0.25 + 0.75 * _dot(_ctrl.value, i),
                child: Text('.', style: style),
              ),
          ],
        ),
      ),
    );
  }

  /// Dot [i]'s brightness at [t] (0..1 of the cycle): a soft rise and fall.
  static double _dot(double t, int i) {
    final x = (t - i * 0.18) % 1.0;
    return x < 0.5 ? Curves.easeInOut.transform(x * 2) : Curves.easeInOut.transform((1 - x) * 2);
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot();
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: DsPalette.red.withValues(alpha: 0.55 + 0.45 * _ctrl.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}

enum _CallGlyph { accept, decline, mic, micMuted, speaker, headphones, video, cameraSwitch, minimize, shareScreen }

/// Crossed-mic badge: a participant tile, their photo, the call bar.
class CallMicOffBadge extends StatelessWidget {
  const CallMicOffBadge({super.key, this.size = 20, this.ring});
  final double size;

  /// A ring in the background's colour, so the badge stands off a photo.
  final Color? ring;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.callPeerMicOff,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.15),
        decoration: BoxDecoration(
          color: DsPalette.red,
          shape: BoxShape.circle,
          border: ring == null ? null : Border.all(color: ring!, width: size * 0.08),
        ),
        child: CustomPaint(painter: _CallGlyphPainter(glyph: _CallGlyph.micMuted, color: DsPalette.white)),
      ),
    );
  }
}

/// The other person's photo with a crossed mic at its lower right while
/// their mic is off.
class CallPeerAvatar extends StatelessWidget {
  const CallPeerAvatar({super.key, required this.name, this.photo, required this.size, this.micOff = false});
  final String name;
  final Uint8List? photo;
  final double size;
  final bool micOff;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        DsAvatar(name: name, size: size, image: photo),
        if (micOff)
          Positioned(
            right: 0,
            bottom: 0,
            child: CallMicOffBadge(key: const ValueKey('peer-mic-off'), size: size * 0.3, ring: DsPalette.navy),
          ),
      ],
    ),
  );
}

/// The call's "flip camera" glyph, for the round video recorder (ADR-048).
class CallCameraSwitchGlyph extends StatelessWidget {
  const CallCameraSwitchGlyph({super.key, required this.color, this.size = 24});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _CallGlyphPainter(glyph: _CallGlyph.cameraSwitch, color: color)),
  );
}

class _CircleButton extends StatelessWidget {
  final _CallGlyph glyph;
  final Color bg;
  final Color? fg;
  final String? label;
  final double size;
  final VoidCallback onTap;
  const _CircleButton({
    super.key,
    required this.glyph,
    required this.bg,
    required this.onTap,
    this.fg,
    this.label,
    this.size = 58,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = fg ?? DsPalette.white;
    // In a row of equal slots the button takes its slot's width: the circle
    // shrinks to fit and the label wraps to two lines (a word too long for
    // the slot gets smaller, never cut) — nothing runs off a small phone
    // (owner, 2026-10-19). Alone it keeps its size.
    return LayoutBuilder(
      builder: (context, box) {
        final room = box.maxWidth.isFinite ? math.min(box.maxWidth, size + DsSpace.x8) : size + DsSpace.x8;
        final side = math.min(size, room);
        // The whole button — circle and label — takes the tap (only the
        // circle did, so a tap on the label "missed").
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: side,
                height: side,
                decoration: BoxDecoration(
                  color: bg,
                  shape: BoxShape.circle,
                  boxShadow: glyph == _CallGlyph.accept || glyph == _CallGlyph.decline
                      ? [DsShadow.glowOf(bg, alpha: 0.35, y: 4, blur: 12)]
                      : null,
                ),
                child: Center(
                  child: SizedBox(
                    width: side * 0.42,
                    height: side * 0.42,
                    child: CustomPaint(
                      painter: _CallGlyphPainter(glyph: glyph, color: iconColor),
                    ),
                  ),
                ),
              ),
              if (label != null) ...[
                const SizedBox(height: 8),
                _ButtonLabel(text: label!, width: room),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// A button's label: centred, up to two lines in [width]; a single word
/// wider than that is scaled down instead of broken in the middle.
class _ButtonLabel extends StatelessWidget {
  const _ButtonLabel({required this.text, required this.width});
  final String text;
  final double width;

  @override
  Widget build(BuildContext context) {
    final style = DsTextArt.t12w500v2.copyWith(height: 1.15);
    final scaler = MediaQuery.textScalerOf(context);
    var widest = 0.0;
    for (final word in text.split(' ')) {
      final tp = TextPainter(
        text: TextSpan(text: word, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, tp.width);
      tp.dispose();
    }
    return SizedBox(
      width: width,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          width: math.max(width, widest.ceilToDouble() + 1),
          child: Text(text, style: style, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
        ),
      ),
    );
  }
}

/// A row of call buttons, each in an equal slot.
class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final c in children)
        Expanded(
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: DsSpace.nudge1), child: Center(child: c)),
        ),
    ],
  );
}

/// "Show screen" / "Stop" among the call's buttons (white while mine is
/// shown).
class _ShareScreenButton extends StatelessWidget {
  const _ShareScreenButton({required this.sharing, required this.onTap, this.size = 58});
  final bool sharing;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) => _CircleButton(
    key: const ValueKey('call-share-screen'),
    glyph: _CallGlyph.shareScreen,
    bg: sharing ? DsPalette.white : DsPalette.white20,
    fg: sharing ? DsPalette.navy : null,
    size: size,
    label: sharing ? context.l10n.callStopSharing : context.l10n.callShareScreen,
    onTap: onTap,
  );
}

/// The ringing and audio screens below the top row: what the call is (the
/// photo, name, timer) and its buttons. Portrait: the info on top — scaled
/// down when it doesn't fit — and the buttons at the bottom. Landscape: side
/// by side (it ran off the screen — owner, 2026-10-19).
/// Below this height (a phone on its side) the call screen puts the photo
/// and the buttons side by side; above it (an iPad) they stay in a column.
const double kCallSideBySideMaxHeight = 560;

class _CallBody extends StatelessWidget {
  const _CallBody({required this.info, required this.controls});
  final Widget info;
  final Widget controls;

  /// The screens' padding: the status bar, the home bar, and in landscape
  /// the notch at the sides.
  static EdgeInsets paddingOf(MediaQueryData mq) => EdgeInsets.only(
    top: mq.padding.top + DsSpace.x2,
    bottom: mq.padding.bottom + (mq.size.width > mq.size.height ? DsSpace.x3 : DsSpace.x8),
    left: mq.padding.left,
    right: mq.padding.right,
  );

  static Widget _fit(Widget child, Alignment alignment) => LayoutBuilder(
    builder: (context, box) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: alignment,
      child: SizedBox(width: box.maxWidth, child: child),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      // An iPad's width: the buttons stay together (ADR-076), as in video.
      final buttons = Center(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: controls),
      );
      // Side by side only on a phone on its side (too low for a column).
      // Owner, 2026-11-03 (iPad on its side): the photo far left, the
      // hang-up far right, nothing between — an iPad keeps the column,
      // everything centred as in FaceTime.
      if (box.maxWidth > box.maxHeight * 1.2 && box.maxHeight < kCallSideBySideMaxHeight) {
        return Row(
          children: [
            Expanded(child: _fit(info, Alignment.center)),
            Expanded(child: _fit(buttons, Alignment.center)),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: _fit(info, Alignment.topCenter)),
          buttons,
        ],
      );
    },
  );
}

class _CallGlyphPainter extends CustomPainter {
  final _CallGlyph glyph;
  final Color color;
  const _CallGlyphPainter({required this.glyph, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (glyph) {
      case _CallGlyph.accept:
        // Tilted phone handset (Lucide)
        final p = Path()
          ..moveTo(5, 4.5)
          ..lineTo(8.5, 4.5)
          ..lineTo(10, 9)
          ..lineTo(8, 11)
          ..cubicTo(8, 13.5, 10.5, 16, 13, 16)
          ..lineTo(15, 14)
          ..lineTo(19.5, 15.5)
          ..lineTo(19.5, 19)
          ..cubicTo(19.5, 19.5, 19, 20, 18.5, 20)
          ..cubicTo(10.5, 20, 4, 13.5, 4, 5.5)
          ..cubicTo(4, 5, 4.5, 4.5, 5, 4.5)
          ..close();
        canvas.drawPath(p, stroke);
      case _CallGlyph.decline:
        // Same handset, rotated 135° to look "hung up"
        canvas.translate(12, 12);
        canvas.rotate(2.356); // 135° in radians
        canvas.translate(-12, -12);
        final p = Path()
          ..moveTo(5, 4.5)
          ..lineTo(8.5, 4.5)
          ..lineTo(10, 9)
          ..lineTo(8, 11)
          ..cubicTo(8, 13.5, 10.5, 16, 13, 16)
          ..lineTo(15, 14)
          ..lineTo(19.5, 15.5)
          ..lineTo(19.5, 19)
          ..cubicTo(19.5, 19.5, 19, 20, 18.5, 20)
          ..cubicTo(10.5, 20, 4, 13.5, 4, 5.5)
          ..cubicTo(4, 5, 4.5, 4.5, 5, 4.5)
          ..close();
        canvas.drawPath(p, stroke);
      case _CallGlyph.mic:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(9, 3, 6, 11), const Radius.circular(3)), fill);
        final cup = Path()
          ..moveTo(5, 11)
          ..cubicTo(5, 15, 8.13, 18, 12, 18)
          ..cubicTo(15.87, 18, 19, 15, 19, 11);
        canvas.drawPath(cup, stroke);
        canvas.drawLine(const Offset(12, 18), const Offset(12, 21), stroke);
      case _CallGlyph.micMuted:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(9, 3, 6, 11), const Radius.circular(3)), fill);
        final cup = Path()
          ..moveTo(5, 11)
          ..cubicTo(5, 15, 8.13, 18, 12, 18)
          ..cubicTo(15.87, 18, 19, 15, 19, 11);
        canvas.drawPath(cup, stroke);
        canvas.drawLine(const Offset(12, 18), const Offset(12, 21), stroke);
        // Slash
        canvas.drawLine(const Offset(3, 3), const Offset(21, 21), stroke);
      case _CallGlyph.speaker:
        final body = Path()
          ..moveTo(3, 9)
          ..lineTo(7, 9)
          ..lineTo(12, 5)
          ..lineTo(12, 19)
          ..lineTo(7, 15)
          ..lineTo(3, 15)
          ..close();
        canvas.drawPath(body, fill);
        final wave1 = Path()
          ..moveTo(15, 9)
          ..arcToPoint(const Offset(15, 15), radius: const Radius.circular(4));
        canvas.drawPath(wave1, stroke);
        final wave2 = Path()
          ..moveTo(18, 7)
          ..arcToPoint(const Offset(18, 17), radius: const Radius.circular(6));
        canvas.drawPath(wave2, stroke);
      case _CallGlyph.headphones:
        // Headband, then the two ear cups.
        final band = Path()
          ..moveTo(4, 15)
          ..lineTo(4, 12)
          ..arcToPoint(const Offset(20, 12), radius: const Radius.circular(8))
          ..lineTo(20, 15);
        canvas.drawPath(band, stroke);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 14, 5, 7), const Radius.circular(2)), fill);
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(16, 14, 5, 7), const Radius.circular(2)), fill);
      case _CallGlyph.video:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 7, 13, 10), const Radius.circular(2)), stroke);
        final play = Path()
          ..moveTo(21, 8)
          ..lineTo(16, 11)
          ..lineTo(16, 13)
          ..lineTo(21, 16)
          ..close();
        canvas.drawPath(play, stroke);
      case _CallGlyph.cameraSwitch:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 7, 18, 12), const Radius.circular(2)), stroke);
        canvas.drawCircle(const Offset(12, 13), 3.2, stroke);
        final arrow = Path()
          ..moveTo(15, 12)
          ..lineTo(17, 13)
          ..lineTo(15, 14);
        canvas.drawPath(arrow, stroke);
        canvas.drawCircle(const Offset(7, 9), 0.8, fill);
      case _CallGlyph.shareScreen:
        // A phone with an arrow going up out of it.
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(6, 2, 12, 20), const Radius.circular(2.5)), stroke);
        final arrow = Path()
          ..moveTo(12, 16)
          ..lineTo(12, 7)
          ..moveTo(8.5, 10.5)
          ..lineTo(12, 7)
          ..lineTo(15.5, 10.5);
        canvas.drawPath(arrow, stroke);
      case _CallGlyph.minimize:
        // A chevron pointing down: the screen folds away.
        final chevron = Path()
          ..moveTo(6, 9)
          ..lineTo(12, 15)
          ..lineTo(18, 9);
        canvas.drawPath(chevron, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CallGlyphPainter old) => old.glyph != glyph || old.color != color;
}

/// "Mic: Voice Isolation" under the controls (iPhone) — opens the system's
/// mic-mode menu; Voice Isolation keeps only the voice (street, café, fan
/// gone).
class _MicModePill extends StatelessWidget {
  const _MicModePill({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: DsPressable(
      key: const ValueKey('call-mic-mode'),
      scale: 0.96,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
        decoration: BoxDecoration(color: DsPalette.white20, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: DsTextArt.t13w600),
      ),
    ),
  );
}
