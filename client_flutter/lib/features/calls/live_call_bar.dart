// CD8 — the call bar over every screen (owner, 2026-10-18: "to get from a
// call to the chat I had to hang up").
//
// [CallBarHost] wraps the app's navigator once (app.dart). While a call
// goes on and no call screen is open — minimised with "⌄", or a call that
// rings on CallKit while I'm elsewhere in the app — a green strip sits at
// the top, under the status bar, and the screens move down below it:
// "Идёт звонок · 02:14 · вернуться" ("Соединяем…", "Вызов…", "Входящий
// звонок · ответить"). A tap opens the call screen again. A video call with
// the other side's camera on also gets a small picture of them, which can
// be dragged to any corner; a tap returns too.
//
// It used to be a pill at the bottom of the chat list only.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import 'active_call_provider.dart';
import 'call_screen.dart' show CallMicOffBadge, callClock;
import 'live_call_screen.dart';

class CallBarHost extends ConsumerWidget {
  const CallBarHost({super.key, required this.navigatorKey, required this.child});

  /// The app's navigator (the host sits above it).
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  void _open(WidgetRef ref) {
    final nav = navigatorKey.currentState;
    if (nav == null || LiveCallScreen.open.value > 0) return;
    final name = callContactName(ref, ref.read(activeCallProvider));
    nav.push(callScreenRoute((_) => LiveCallScreen(contactName: name)));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = ref.watch(activeCallProvider);
    return ValueListenableBuilder<int>(
      valueListenable: LiveCallScreen.open,
      builder: (context, open, _) {
        final show = open == 0 && (call.isActive || call.phase == CallPhase.ended);
        final mq = MediaQuery.of(context);
        return Column(
          children: [
            AnimatedSize(
              duration: DsMotion.of(context, DsMotion.base),
              curve: DsMotion.emphasized,
              alignment: Alignment.topCenter,
              child: show
                  ? LiveCallBar(call: call, onTap: () => _open(ref))
                  : const SizedBox(width: double.infinity),
            ),
            Expanded(
              // The bar took the status bar's room: the screens below start
              // under it.
              child: MediaQuery(
                data: show ? mq.removePadding(removeTop: true) : mq,
                child: Stack(
                  children: [
                    Positioned.fill(child: child),
                    if (show && call.phase == CallPhase.connected && call.kind == CallKind.video)
                      _CallPip(notifier: ref.read(activeCallProvider.notifier), onTap: () => _open(ref)),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The green strip: what the call is doing, and "tap to return".
class LiveCallBar extends StatefulWidget {
  const LiveCallBar({super.key, required this.call, required this.onTap});
  final ActiveCallState call;
  final VoidCallback onTap;

  @override
  State<LiveCallBar> createState() => _LiveCallBarState();
}

class _LiveCallBarState extends State<LiveCallBar> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(LiveCallBar old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// A second tick only while the timer shows.
  void _syncTicker() {
    final counting = widget.call.phase == CallPhase.connected && !widget.call.connecting;
    if (counting && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!counting) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final text = callBarLabel(context.l10n, call);
    final top = MediaQuery.paddingOf(context).top;
    // Their mic is off: a crossed mic instead of the dot (owner, 2026-10-19).
    final micOff = call.phase == CallPhase.connected && !call.connecting && call.peerMicOff;
    return Semantics(
      button: true,
      label: micOff ? '$text · ${context.l10n.callPeerMicOff}' : text,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: GestureDetector(
        key: const ValueKey('call-bar'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          color: call.phase == CallPhase.ended ? DsPalette.art2D2640 : DsPalette.green,
          padding: EdgeInsets.only(top: top + DsSpace.x1h5, bottom: DsSpace.x2, left: DsSpace.x4, right: DsSpace.x4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (micOff)
                const CallMicOffBadge(key: ValueKey('call-bar-mic-off'), size: 18)
              else
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(color: DsPalette.white, shape: BoxShape.circle),
                ),
              const SizedBox(width: DsSpace.x2),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // Tabular digits: the timer doesn't wobble each second.
                  style: DsText.subhead.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                    color: DsPalette.white,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Идёт звонок · 02:14 · вернуться" and the like, in the phone's language.
String callBarLabel(AppL10n l, ActiveCallState call, {DateTime? now}) {
  String clock() => callClock(call.talkTime(now: now) ?? Duration.zero);

  return switch (call.phase) {
    CallPhase.incomingRinging => '${l.callBarIncoming} · ${l.callBarAnswer}',
    CallPhase.outgoingRinging || CallPhase.idle => '${l.callCalling} · ${l.callBarReturn}',
    CallPhase.connected when call.connecting => '${l.callConnecting} · ${l.callBarReturn}',
    CallPhase.connected =>
      '${call.kind == CallKind.video ? l.callOngoingVideo : l.callOngoing} · ${clock()} · ${l.callBarReturn}',
    // How long it lasted, as on the call screen (it said only "ended").
    CallPhase.ended => call.talkTime() == null ? l.callBarEnded : l.callEnded(clock()),
  };
}

/// The other side's camera, small, over the app while the call screen is
/// minimised — drag it to a corner, tap to go back to the call. Nothing
/// while their camera is off.
class _CallPip extends StatefulWidget {
  const _CallPip({required this.notifier, required this.onTap});
  final ActiveCallNotifier notifier;
  final VoidCallback onTap;

  @override
  State<_CallPip> createState() => _CallPipState();
}

class _CallPipState extends State<_CallPip> {
  static const _w = 96.0, _h = 136.0;

  /// Which corner it rests in (top right first: under the call bar, clear
  /// of the composer).
  Alignment _corner = Alignment.topRight;
  Offset? _drag; // top-left while dragging

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<lk.Room?>(
      valueListenable: widget.notifier.room,
      builder: (context, room, _) {
        if (room == null) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: room,
          builder: (context, _) {
            final track = room.remoteParticipants.values
                .expand((p) => p.videoTrackPublications)
                .where((t) => t.subscribed && !t.muted)
                .firstOrNull
                ?.track;
            if (track == null) return const SizedBox.shrink();
            return LayoutBuilder(builder: (context, box) => _place(context, box, track));
          },
        );
      },
    );
  }

  Widget _place(BuildContext context, BoxConstraints box, lk.VideoTrack track) {
    final pad = MediaQuery.paddingOf(context);
    final minX = DsSpace.x3 + pad.left, minY = DsSpace.x3 + pad.top + 52; // below a screen's top bar
    final maxX = box.maxWidth - _w - DsSpace.x3 - pad.right;
    final maxY = box.maxHeight - _h - DsSpace.x3 - pad.bottom - 64; // above a composer / tab bar
    final rest = Offset(_corner.x < 0 ? minX : maxX, _corner.y < 0 ? minY : maxY);
    final at = _drag ?? rest;
    return AnimatedPositioned(
      duration: _drag == null ? DsMotion.of(context, DsMotion.base) : Duration.zero,
      curve: DsMotion.emphasized,
      left: at.dx,
      top: at.dy,
      child: Semantics(
        button: true,
        label: context.l10n.callBarTapToReturn,
        child: GestureDetector(
          key: const ValueKey('call-pip'),
          onTap: widget.onTap,
          onPanUpdate: (d) => setState(() => _drag = (_drag ?? rest) + d.delta),
          onPanEnd: (_) => setState(() {
            final p = _drag ?? rest;
            final centre = Offset(p.dx + _w / 2, p.dy + _h / 2);
            _corner = Alignment(centre.dx < box.maxWidth / 2 ? -1 : 1, centre.dy < box.maxHeight / 2 ? -1 : 1);
            _drag = null;
          }),
          child: Container(
            width: _w,
            height: _h,
            decoration: BoxDecoration(
              color: DsPalette.navy,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DsPalette.white40),
              boxShadow: const [DsShadow.art10],
            ),
            clipBehavior: Clip.antiAlias,
            child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.cover),
          ),
        ),
      ),
    );
  }
}
