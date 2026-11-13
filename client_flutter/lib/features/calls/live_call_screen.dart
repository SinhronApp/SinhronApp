// CD4 — live call screen. Adapter between [activeCallProvider] state
// and the visual [CallScreen] widget.
//
// `CallScreen` is a self-contained visual widget designed in Phase 1 with
// its own local state (mock timer, mock states). For real calls we need:
//   • State driven by [ActiveCallNotifier] (provider's CallPhase).
//   • Hangup → `activeCallProvider.notifier.end()` rather than just
//     popping the route.
//   • Auto-pop when phase → idle (after the 2s "Call ended" hold).
//
// This wrapper does the bridging without modifying the underlying
// CallScreen widget — keeps the visual design system clean.

import 'dart:async' show scheduleMicrotask;

import 'package:flutter/services.dart' show DeviceOrientation, SystemChrome;
import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/motion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:livekit_client/livekit_client.dart' as lk show Room;

import '../../core/providers/chat_providers.dart';
import '../../core/providers/people.dart' show peerAvatarOf;
import '../../widgets/ds_picker_sheet.dart';
import 'active_call_provider.dart';
import 'call_audio.dart';
import 'call_quality.dart' show CallNotice;
import 'call_video.dart';
import 'call_diagnostics.dart';
import 'call_screen.dart';
import 'call_screen_share.dart';
import 'livekit_engine.dart' show kCallNotEncrypted;
import '../../l10n/l10n.dart';
import '../../app/theme/tokens.dart';

/// CE4 — wrapper that locks orientation to portrait while the call
/// screen is visible. Stateful only for the lock lifecycle; rendering
/// delegates to the inner ConsumerWidget.
/// How the call screen opens and closes: a quick fade. The sideways slide
/// showed a strip of the screen behind it when a call ended.
Route<void> callScreenRoute(WidgetBuilder builder) => PageRouteBuilder<void>(
  transitionDuration: DsMotion.base,
  reverseTransitionDuration: DsMotion.base,
  pageBuilder: (context, _, _) => builder(context),
  transitionsBuilder: (_, animation, _, child) => FadeTransition(opacity: animation, child: child),
);

class LiveCallScreen extends StatefulWidget {
  final String contactName;
  const LiveCallScreen({super.key, this.contactName = ''});

  /// How many call screens are open now — the call bar shows only while
  /// none is (the screen was minimised, or the call came while elsewhere).
  static final open = ValueNotifier<int>(0);

  @override
  State<LiveCallScreen> createState() => _LiveCallScreenState();
}

/// Whether the app opens the call screen by itself (one ringing UI —
/// owner, 2026-10-18): for an incoming call the app rings itself (the
/// system isn't showing it — [ActiveCallState.ringsInApp]), and for one
/// answered in the system UI (CallKit, the notification's Answer). Never
/// while a call screen is open.
bool callScreenToOpen(ActiveCallState? prev, ActiveCallState next, {required bool screenOpen}) {
  if (screenOpen) return false;
  final sameCall = prev?.callId == next.callId;
  final ringsHere = next.phase == CallPhase.incomingRinging && next.ringsInApp;
  final rangHere = sameCall && prev?.phase == CallPhase.incomingRinging && prev!.ringsInApp;
  if (ringsHere && !rangHere) return true;
  return sameCall && prev?.phase == CallPhase.incomingRinging && next.phase == CallPhase.connected;
}

/// Whom the call is with: the chat's name (it said "Incoming call").
String callContactName(WidgetRef ref, ActiveCallState call) {
  final chat = (ref.read(chatsProvider).value ?? const []).where((c) => c.id == call.groupIdHex).firstOrNull;
  final name = chat?.name.trim() ?? '';
  return name.isNotEmpty
      ? name
      : lookupAppL10n(Locale(currentLanguage)).callKitPeerName;
}

class _LiveCallScreenState extends State<LiveCallScreen> {
  @override
  void initState() {
    super.initState();
    // After this frame: the bar listens, and a build can't rebuild others.
    scheduleMicrotask(() => LiveCallScreen.open.value++);
    // CE4 — lock to portrait while on the call screen. Video calls in
    // landscape work but add UI layout headaches; v1 ships portrait-
    // only (matches the Phase 1 design mocks). Restored on dispose.
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  }

  @override
  void dispose() {
    scheduleMicrotask(() => LiveCallScreen.open.value--);
    // Restore full rotation set — the rest of the app supports landscape.
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _LiveCallBody(contactName: widget.contactName);
  }
}

class _LiveCallBody extends ConsumerWidget {
  final String contactName;
  const _LiveCallBody({required this.contactName});

  /// What the screen listens to before the room is up and after it's gone.
  static final Listenable _noRoom = ChangeNotifier();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(activeCallProvider);

    // Close when a call that was going ends. Not merely "idle": an outgoing
    // call opens this screen while the state is still idle (the mic
    // permission is asked first), and the old check closed it at once.
    // A failed invite is closed by the caller (`_startLiveCallOrDemo`).
    ref.listen(activeCallProvider, (prev, next) {
      if (prev != null && prev.phase != CallPhase.idle && next.phase == CallPhase.idle) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
        });
      }
    });

    final notifier = ref.read(activeCallProvider.notifier);

    // CE5 — overlay "Reconnecting…" pill when LiveKit is recovering.
    // Stacked above the CallScreen so all controls remain interactive
    // (user can hang up mid-reconnect if they want).
    // Status 212 — also while the call moves to the reserve path (the room
    // is gone for a moment: the screen used to go blank and come back).
    final showReconnecting =
        call.phase == CallPhase.connected &&
        (call.networkStatus == CallNetworkStatus.reconnecting || call.switchingPath);

    return Stack(
      children: [
        _buildCallScreen(context, ref, call, notifier),
        // ADR-061 — screen sharing: its button, my banner, someone's screen.
        if (call.phase == CallPhase.connected)
          ValueListenableBuilder(
            valueListenable: notifier.room,
            builder: (context, room, _) => Positioned.fill(child: CallScreenShareLayer(room: room)),
          ),
        // Under the top row, clear of the notch (a fixed 80 sat on the
        // top row of a notched iPhone).
        if (showReconnecting)
          Positioned(
            top: MediaQuery.paddingOf(context).top + DsSpace.x12,
            left: 0,
            right: 0,
            child: const Center(child: _ReconnectingPill()),
          ),
        // The friend's idea (2026-10-16): a small button → live diagnostics.
        if (call.phase == CallPhase.connected)
          ValueListenableBuilder(
            valueListenable: notifier.room,
            builder: (context, room, _) => room == null
                ? const SizedBox.shrink()
                : _Diagnostics(room: room, plan: notifier.path.name, setup: () => notifier.timeline.line),
          ),
      ],
    );
  }

  Widget _buildCallScreen(BuildContext context, WidgetRef ref, ActiveCallState call, ActiveCallNotifier notifier) {
    // Live video once the LiveKit room is up (tech-debt 4.9). The room
    // notifies when tracks come and go — the other side turning their
    // camera on shows up without me pressing anything. One tree with or
    // without a room: the call screen keeps its state when the room comes
    // and goes (at the end it was built anew — "Call ended · 00:00").
    return ValueListenableBuilder(
      valueListenable: notifier.room,
      builder: (context, room, _) => ListenableBuilder(
        listenable: room ?? _noRoom,
        builder: (context, _) => _callScreen(context, ref, call, notifier, room),
      ),
    );
  }

  Widget _callScreen(
    BuildContext context,
    WidgetRef ref,
    ActiveCallState call,
    ActiveCallNotifier notifier,
    lk.Room? room,
  ) {
    // A group call always shows everyone (tiles with names, who speaks,
    // who's muted) — it used to open the 1:1 audio screen.
    final isGroup =
        call.groupIdHex != null &&
        (ref.watch(chatsProvider).value ?? const []).any((c) => c.id == call.groupIdHex && c.group);
    // Where the sound goes, once the media is up (headphones, Bluetooth…).
    final audio = room == null ? const CallAudioState() : ref.watch(callAudioProvider);
    final route = audio.current;
    return CallScreen(
      remoteVideo: room == null
          ? null
          : CallVideoGrid(room: room, waitingLabel: isGroup ? context.l10n.callWaitingForPeople : null),
      selfVideo: room == null ? null : CallSelfView(room: room),
      contactName: contactName,
      contactPhoto: peerAvatarOf(
        ref,
        (ref.watch(chatsProvider).value ?? const []).where((c) => c.id == call.groupIdHex).firstOrNull?.peerId,
      ),
      initialState: _phaseToCallState(call.phase),
      // The room is rejoining: keep the picture as it is (video stays video).
      holdLayout: call.switchingPath,
      peerRinging: call.peerRinging,
      endedLabel: call.phase == CallPhase.ended ? callEndedLabel(context.l10n, call) : null,
      // Accept answers the real call (it only flipped the picture before).
      onAccept: call.phase == CallPhase.incomingRinging
          ? () {
              // ignore: discarded_futures
              notifier.accept();
            }
          : null,
      initialMedia: call.kind == CallKind.video ? CallMedia.video : CallMedia.audio,
      // Back to the app, the call goes on; the call bar returns here. Not
      // while it rings for me (answer or decline first).
      onMinimize: call.phase == CallPhase.incomingRinging || call.phase == CallPhase.ended
          ? null
          : () => Navigator.of(context).maybePop(),
      connecting: call.connecting,
      voiceLevel: room == null ? null : notifier.peerVoice,
      peerMicOff: room != null && call.peerMicOff && !call.connecting,
      // ADR-061 — "Show screen" among the buttons, once the room is up.
      onShareScreen: screenShareTap(ref, roomUp: room != null && call.phase == CallPhase.connected),
      sharingScreen: room != null && ref.watch(screenShareProvider).sharing,
      onClose: () {
        // CallScreen calls onClose either when user taps decline (from
        // Incoming) or when "ended" auto-transitions. In both cases we
        // route through the provider to make sure server gets notified.
        if (call.phase == CallPhase.incomingRinging) {
          // ignore: discarded_futures
          notifier.decline();
        } else if (call.isActive) {
          // ignore: discarded_futures
          notifier.end();
        } else {
          // Already ended; just pop.
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }
      },
      // CD7 — wire control buttons into the live LiveKit room. Each
      // callback is fire-and-forget — the underlying setters return
      // futures, but UI doesn't await (the button state already flipped
      // optimistically inside CallScreen).
      onToggleMute: (muted) {
        // ignore: discarded_futures
        notifier.setMicrophoneMuted(muted);
      },
      speakerOn: route == null ? call.speakerOn : route.kind == AudioOutputKind.speaker,
      // The timer counts from when their sound came (not over the silence
      // of "Connecting…").
      connectedAt: call.audioAt ?? call.connectedAt,
      endedAt: call.endedAt,
      muted: call.micMuted,
      onToggleSpeaker: (speaker) {
        // ignore: discarded_futures
        notifier.setSpeakerOn(speaker);
      },
      onPickAudioRoute: audio.external ? () => _pickAudioRoute(context, ref, audio) : null,
      audioRouteLabel: route == null ? null : audioOutputLabel(context.l10n, route),
      audioRouteExternal: route?.kind.external ?? false,
      micModeLabel: audio.micMode == null ? null : micModeLabel(context.l10n, audio.micMode!),
      onMicMode: audio.micMode == null ? null : () => ref.read(callAudioProvider.notifier).chooseMicMode(),
      onSwitchCamera: () {
        // ignore: discarded_futures
        notifier.switchCamera();
      },
      onToggleCamera: notifier.setCameraEnabled,
      remoteVideoOn: room != null && (isGroup || _remoteVideoOn(room)),
      // ADR-041 — the call's truth about my camera (it may go off by itself
      // on a poor link), my link's bars and the one-line notice.
      cameraOn: room == null ? null : call.cameraOn,
      linkQuality: room == null ? null : call.linkQuality,
      notice: room == null ? CallNotice.none : call.notice,
    );
  }

  /// iPhone: the system's route menu; Android: our list of outputs.
  static Future<void> _pickAudioRoute(BuildContext context, WidgetRef ref, CallAudioState audio) async {
    final platform = ref.read(callAudioPlatformProvider);
    if (platform.systemPicker) return platform.showSystemPicker();
    final l = context.l10n;
    final labels = [for (final o in audio.outputs) audioOutputLabel(l, o)];
    final picked = await showDsPickerSheet(
      context: context,
      title: l.callAudioOutput,
      options: labels,
      current: audio.current == null ? '' : audioOutputLabel(l, audio.current!),
    );
    final i = picked == null ? -1 : labels.indexOf(picked);
    if (i >= 0) await ref.read(callAudioProvider.notifier).choose(audio.outputs[i]);
  }

  /// Someone else in the room is sending video (subscribed, not muted).
  static bool _remoteVideoOn(lk.Room room) =>
      room.remoteParticipants.values.any((p) => p.videoTrackPublications.any((t) => t.subscribed && !t.muted));

  /// Translate provider phase → the CallScreen widget's internal enum.
  /// CallScreen has 3 states; we collapse our 5 into them.
  CallState _phaseToCallState(CallPhase phase) {
    switch (phase) {
      // Mine, still ringing on their side: "Calling…", hang-up only (it
      // used to show Accept / Decline on the caller's own phone).
      case CallPhase.idle:
      case CallPhase.outgoingRinging:
        return CallState.outgoing;
      case CallPhase.incomingRinging:
        return CallState.incoming;
      case CallPhase.connected:
        return CallState.active;
      case CallPhase.ended:
        return CallState.ended;
    }
  }
}

/// CE5 — small pill shown above the call screen when LiveKit is
/// recovering connection. Yellow accent + "Reconnecting…" label.
class _ReconnectingPill extends StatelessWidget {
  const _ReconnectingPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x2),
      decoration: BoxDecoration(
        color: DsPalette.artE8A317, // amber-ish
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [DsShadow.art10],
      ),
      child: Text(context.l10n.callReconnecting, style: DsTextArt.t13w600v2),
    );
  }
}

/// Overnight item 5 — why a call that never connected ended, for the
/// ended screen. Null → the usual "Call ended · duration".
String? callEndedLabel(AppL10n l, ActiveCallState call) {
  // Answered, but the media never came up (both paths failed) — not a
  // plain "Call ended · 0:03" (VPN calls, 2026-10-20).
  if (call.endReason == 'livekit_failure') return l.callCouldntConnect;
  if (call.endReason == kCallNotEncrypted) return l.callNotEncrypted;
  if (call.connectedAt != null) return null;
  return switch (call.endReason) {
    'no_answer' => call.isCaller ? l.callNoAnswer : l.callMissedShort,
    'busy' => l.callBusy,
    'rejected' => l.callDeclinedByPeer,
    _ => null,
  };
}

/// "i" at the top right → the call's diagnostics over the call screen.
class _Diagnostics extends StatefulWidget {
  const _Diagnostics({required this.room, required this.plan, this.setup});
  final lk.Room room;
  final String plan;
  final String Function()? setup;

  @override
  State<_Diagnostics> createState() => _DiagnosticsState();
}

class _DiagnosticsState extends State<_Diagnostics> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return Stack(
      children: [
        Positioned(
          top: top + DsSpace.x2,
          right: MediaQuery.paddingOf(context).right + DsSpace.x3,
          child: GestureDetector(
            key: const ValueKey('call-diagnostics-toggle'),
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Semantics(
              button: true,
              label: context.l10n.callDiagnostics,
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _open ? DsPalette.white : DsPalette.black40,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  'i',
                  style: DsTextArt.t14w500v2.copyWith(color: _open ? DsPalette.black : DsPalette.white),
                ),
              ),
            ),
          ),
        ),
        if (_open)
          Positioned(
            top: top + DsSpace.x2 + 40,
            left: DsSpace.x3,
            right: DsSpace.x3,
            child: CallDiagnosticsPanel(
              room: widget.room,
              plan: widget.plan,
              setup: widget.setup,
              audioSession: iosAudioSessionState,
            ),
          ),
      ],
    );
  }
}
