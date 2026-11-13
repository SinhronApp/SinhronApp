// ADR-061 — showing my phone's screen in a call (owner, 2026-10-18: "и
// также экран показывать, на обеих платформах, во время звонка").
//
// The screen goes out as a second LiveKit video track (source
// `screenShareVideo`) next to the camera, through the same SFrame frame
// cryptor (livekit_client attaches one to every published track) and with
// the same codec as the camera (H.264 / VP8 from the room's defaults; never
// AV1, never an unencrypted backup copy — ADR-041/045).
//
//  - iPhone: the whole screen, also with Sinhron in the background, through
//    the Broadcast Upload Extension `ios/ScreenShare` (ReplayKit). The button
//    opens the system "Screen Broadcast" sheet; once the person taps "Start
//    Broadcast" the extension streams frames over a socket in the App Group
//    and LiveKit publishes the track by itself.
//  - Android: MediaProjection — the system consent dialog, then a foreground
//    service of type mediaProjection (Android 14 rules: consent first, then
//    the service, then the capture), then the track.
//
// Text must stay readable: the screen keeps its resolution (up to a cap by
// phone class) and gives up frames instead — 15 fps at most, fewer on a
// poor link or a hot phone (ADR-041/046 ceilings).
//
// UI: the "Показать экран" button sits with the call screen's other
// buttons ([screenShareTap] wires it — it floated on the right edge over
// the name, owner 2026-10-19); this layer adds a red "Вы показываете
// экран · Остановить" banner while mine is on, and someone else's screen
// big over the call (pinch to zoom, rotate, back to the call, hang up).

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/foundation.dart'
    show ValueListenable, ValueNotifier, defaultTargetPlatform, TargetPlatform, immutable, visibleForTesting;
import 'package:flutter/services.dart' show DeviceOrientation, MethodChannel, MissingPluginException, SystemChrome;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/people.dart';
import '../../l10n/l10n.dart';
import 'active_call_provider.dart';
import 'call_quality.dart';
import 'livekit_engine.dart';

// ─── Policy: how sharp, how smooth ────────────────────────────────────

/// The longest side my screen is encoded at, by phone class: a phone
/// screen is ~1080 × 2400; 1920 keeps small text sharp on strong phones,
/// 1600 / 1280 spare ordinary / weak encoders.
const kScreenShareMaxLongSide = {
  CallDeviceClass.high: 1920,
  CallDeviceClass.standard: 1600,
  CallDeviceClass.low: 1280,
};

/// What the room publishes the screen with before the link is known
/// (LiveKit adds a half-size 3 fps layer under it for viewers on a bad
/// link). [screenShareLayerFor] then moves it with the link and the heat.
const kScreenShareEncoding = lk.VideoEncoding(maxBitrate: 1500 * 1000, maxFramerate: 15);

/// iPhone: capture through the Broadcast Upload Extension (the whole
/// screen, also outside Sinhron), not the in-app recorder.
const kScreenShareCaptureOptions = lk.ScreenShareCaptureOptions(
  useiOSBroadcastExtension: true,
  maxFrameRate: 15,
  params: lk.VideoParameters(dimensions: lk.VideoDimensionsPresets.h1080_169, encoding: kScreenShareEncoding),
);

/// The screen's top layer now: resolution kept (only scaled to the cap),
/// bitrate by link, frames given up first — a still screen with sharp text
/// beats a smooth blurry one.
///  - bitrate: excellent 2.5 Mbps, good / not measured 1.5 Mbps, poor /
///    lost 600 kbps; a weak phone 1 Mbps at most; a hot one (serious+)
///    1.5 Mbps at most;
///  - frames: 15 fps; poor link 8; weak phone 10; serious heat 10,
///    critical 5;
///  - size: the long side down to [kScreenShareMaxLongSide] (critical heat:
///    1280). Unknown capture size → not scaled.
({double scaleDownBy, int maxBitrate, int maxFramerate}) screenShareLayerFor({
  required CallDeviceClass device,
  required CallLinkQuality link,
  ThermalLevel thermal = 0,
  int? width,
  int? height,
}) {
  var bitrate = switch (link) {
    CallLinkQuality.excellent => 2500 * 1000,
    CallLinkQuality.good || CallLinkQuality.unknown => 1500 * 1000,
    CallLinkQuality.poor || CallLinkQuality.lost => 600 * 1000,
  };
  var fps = link.isBad ? 8 : 15;
  var longCap = kScreenShareMaxLongSide[device]!;
  if (device == CallDeviceClass.low) {
    bitrate = bitrate.clamp(0, 1000 * 1000);
    fps = fps.clamp(0, 10);
  }
  if (thermal >= 2) {
    bitrate = bitrate.clamp(0, 1500 * 1000);
    fps = fps.clamp(0, 10);
  }
  if (thermal >= 3) {
    fps = 5;
    longCap = longCap.clamp(0, 1280);
  }
  final long = (width ?? 0) > (height ?? 0) ? (width ?? 0) : (height ?? 0);
  final scale = long > longCap ? long / longCap : 1.0;
  return (scaleDownBy: scale, maxBitrate: bitrate, maxFramerate: fps);
}

// ─── Seams ────────────────────────────────────────────────────────────

/// What the OS needs around a capture.
abstract class ScreenSharePlatform {
  /// Before the track: Android asks for consent and starts the foreground
  /// service (false = refused / not possible); iPhone has nothing to do.
  Future<bool> prepare();

  /// After the track: Android stops the foreground service.
  Future<void> release();

  /// The track appears only later (iPhone: after "Start Broadcast" in the
  /// system sheet), not when [ScreenShareRoom.setEnabled] returns.
  bool get startsLater;

  /// "Stop" outside the app (Android: the notification's button).
  Stream<void> get stopRequests;

  /// The phone's heat (ADR-046 scale).
  Future<ThermalLevel> thermal();
}

/// The call room as far as screen sharing goes.
abstract class ScreenShareRoom {
  /// My screen track is published.
  bool get sharing;

  /// Publish / unpublish my screen (iPhone: on → the broadcast sheet).
  Future<void> setEnabled(bool on);

  /// The captured frame size, when the platform says.
  ({int width, int height})? get captureSize;

  /// This phone's class (ADR-046).
  CallDeviceClass get deviceClass;

  /// Put [layer] on the screen track's top simulcast layer.
  Future<void> applyLayer(({double scaleDownBy, int maxBitrate, int maxFramerate}) layer);

  /// Calls [onChange] when my tracks come and go. Returns the cancel.
  void Function() listen(void Function() onChange);
}

class _AndroidScreenSharePlatform implements ScreenSharePlatform {
  _AndroidScreenSharePlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onStop') _stops.add(null);
    });
  }

  static const _channel = MethodChannel('dev.sinhron/screen_share');
  final _stops = StreamController<void>.broadcast();

  @override
  bool get startsLater => false;

  @override
  Stream<void> get stopRequests => _stops.stream;

  @override
  Future<bool> prepare() async {
    // Consent first (flutter_webrtc keeps the grant for the capture), then
    // the foreground service — Android 14 refuses the other order.
    if (!await rtc.Helper.requestCapturePermission()) return false;
    try {
      return await _channel.invokeMethod<bool>('start') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // nothing to stop
    }
  }

  @override
  Future<ThermalLevel> thermal() => LiveKitCallEngine.thermalLevel();
}

class _IosScreenSharePlatform implements ScreenSharePlatform {
  const _IosScreenSharePlatform();

  @override
  bool get startsLater => true;

  @override
  Stream<void> get stopRequests => const Stream.empty();

  @override
  Future<bool> prepare() async => true;

  // The broadcast ends by itself once the track stops: the extension sees
  // the app's socket close.
  @override
  Future<void> release() async {}

  @override
  Future<ThermalLevel> thermal() => LiveKitCallEngine.thermalLevel();
}

final screenSharePlatformProvider = Provider<ScreenSharePlatform>(
  (ref) => defaultTargetPlatform == TargetPlatform.android
      ? _AndroidScreenSharePlatform()
      : const _IosScreenSharePlatform(),
);

/// The LiveKit side.
class LiveKitScreenShareRoom implements ScreenShareRoom {
  LiveKitScreenShareRoom(this.room, {required this.deviceClass});
  final lk.Room room;

  @override
  final CallDeviceClass deviceClass;

  lk.LocalTrackPublication<lk.LocalVideoTrack>? get _screen => room.localParticipant?.videoTrackPublications
      .where((p) => p.source == lk.TrackSource.screenShareVideo)
      .firstOrNull;

  @override
  bool get sharing => _screen?.track != null;

  @override
  Future<void> setEnabled(bool on) async {
    // Status 223 — iPhone / iPad: our own "Screen Broadcast" picker, placed
    // in the window (LiveKit's is in none, and on iPad that crashed the
    // app). LiveKit publishes the track itself once the broadcast starts.
    if (on && defaultTargetPlatform == TargetPlatform.iOS && room.localParticipant != null) {
      try {
        if (await const MethodChannel('dev.sinhron/screen_share').invokeMethod<bool>('pick') == true) return;
      } on MissingPluginException {
        // an older native side: LiveKit's own picker
      }
    }
    try {
      await room.localParticipant?.setScreenShareEnabled(on, screenShareCaptureOptions: kScreenShareCaptureOptions);
    } catch (_) {
      await callPublishFailed(room);
      rethrow;
    }
  }

  @override
  ({int width, int height})? get captureSize {
    final pub = _screen;
    if (pub == null) return null;
    try {
      final s = pub.track?.mediaStreamTrack.getSettings() ?? const {};
      final w = s['width'], h = s['height'];
      if (w is num && h is num && w > 0 && h > 0) return (width: w.toInt(), height: h.toInt());
    } catch (_) {
      // not reported on this platform
    }
    final d = pub.dimensions;
    // The default capture params (1920×1080) are a guess, not the screen.
    if (d == null || d.width <= 0 || (d.width == 1920 && d.height == 1080)) return null;
    return (width: d.width, height: d.height);
  }

  @override
  Future<void> applyLayer(({double scaleDownBy, int maxBitrate, int maxFramerate}) layer) async {
    final sender = _screen?.track?.sender;
    if (sender == null) return;
    final params = sender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) return;
    final top = encodings.firstWhere((e) => e.rid == 'f', orElse: () => encodings.last);
    top
      ..scaleResolutionDownBy = layer.scaleDownBy
      ..maxBitrate = layer.maxBitrate
      ..maxFramerate = layer.maxFramerate;
    // The low layer stays below the top one.
    for (final e in encodings) {
      if (!identical(e, top)) e.scaleResolutionDownBy = layer.scaleDownBy * 2;
    }
    await sender.setParameters(params);
  }

  @override
  void Function() listen(void Function() onChange) => room.events.listen((e) {
    if (e is lk.LocalTrackPublishedEvent || e is lk.LocalTrackUnpublishedEvent) onChange();
  });
}

/// The current call's room for screen sharing (null outside a connected
/// call). Tests override it.
final screenShareRoomProvider = Provider<ValueListenable<ScreenShareRoom?>>((ref) {
  final notifier = ref.read(activeCallProvider.notifier);
  final rooms = notifier.room;
  final out = ValueNotifier<ScreenShareRoom?>(null);
  void sync() {
    final r = rooms.value;
    if (r == null) {
      out.value = null;
    } else if (out.value is! LiveKitScreenShareRoom || (out.value! as LiveKitScreenShareRoom).room != r) {
      out.value = LiveKitScreenShareRoom(r, deviceClass: notifier.deviceClass);
    }
  }

  rooms.addListener(sync);
  sync();
  ref.onDispose(() {
    rooms.removeListener(sync);
    out.dispose();
  });
  return out;
});

// ─── State ────────────────────────────────────────────────────────────

enum ScreenSharePhase {
  off,

  /// Waiting for the system: Android's consent dialog, the iPhone's
  /// broadcast sheet (the person may also just close it).
  asking,
  on,
}

@immutable
class ScreenShareState {
  const ScreenShareState({this.phase = ScreenSharePhase.off, this.failed = false});
  final ScreenSharePhase phase;

  /// The last try didn't start (not a refusal — those are quiet).
  final bool failed;

  bool get sharing => phase == ScreenSharePhase.on;
}

/// How long the iPhone's broadcast sheet may stay unanswered before the
/// button forgets it (closing the sheet tells the app nothing).
const kScreenShareAskTimeout = Duration(seconds: 60);

/// How often the heat is read again while sharing.
const kScreenShareHeatTick = Duration(seconds: 10);

class ScreenShareNotifier extends Notifier<ScreenShareState> {
  ValueListenable<ScreenShareRoom?>? _rooms;
  ScreenShareRoom? _room;
  void Function()? _cancelRoom;
  StreamSubscription<void>? _stopSub;
  Timer? _askTimer;
  Timer? _heatTick;
  ThermalLevel _thermal = 0;

  ScreenSharePlatform get _platform => ref.read(screenSharePlatformProvider);

  @override
  ScreenShareState build() {
    final rooms = ref.watch(screenShareRoomProvider);
    _rooms = rooms;
    rooms.addListener(_onRoom);
    _stopSub = ref.watch(screenSharePlatformProvider).stopRequests.listen((_) => unawaited(stop()));
    // Hang-up (or the call ending any way): my screen goes at once.
    ref.listen(activeCallProvider, (prev, next) {
      if (next.phase != CallPhase.connected) {
        if (state.phase != ScreenSharePhase.off) unawaited(stop());
      } else if (prev?.linkQuality != next.linkQuality) {
        unawaited(_applyLayer());
      }
    });
    ref.onDispose(() {
      rooms.removeListener(_onRoom);
      _cancelRoom?.call();
      _stopSub?.cancel();
      _askTimer?.cancel();
      _heatTick?.cancel();
    });
    _attach(rooms.value);
    return const ScreenShareState();
  }

  void _onRoom() {
    final next = _rooms?.value;
    if (identical(next, _room)) return;
    final was = state.phase;
    _attach(next);
    if (next == null && was != ScreenSharePhase.off) {
      _set(const ScreenShareState());
      unawaited(_platform.release());
    }
  }

  void _attach(ScreenShareRoom? room) {
    _cancelRoom?.call();
    _cancelRoom = null;
    _room = room;
    if (room != null) _cancelRoom = room.listen(_sync);
  }

  void _set(ScreenShareState s) {
    state = s;
    if (s.phase != ScreenSharePhase.asking) _askTimer?.cancel();
    if (s.phase == ScreenSharePhase.on) {
      _heatTick ??= Timer.periodic(kScreenShareHeatTick, (_) => unawaited(_applyLayer(readHeat: true)));
    } else {
      _heatTick?.cancel();
      _heatTick = null;
    }
  }

  /// The room's truth: my screen track is there or not (iPhone: it comes
  /// after "Start Broadcast"; it goes when the broadcast is stopped from
  /// the red status bar).
  void _sync() {
    final on = _room?.sharing ?? false;
    if (on && state.phase != ScreenSharePhase.on) {
      _set(const ScreenShareState(phase: ScreenSharePhase.on));
      unawaited(_applyLayer(readHeat: true));
    } else if (!on && state.phase == ScreenSharePhase.on) {
      _set(const ScreenShareState());
      unawaited(_platform.release());
    }
  }

  /// "Показать экран".
  Future<void> start() async {
    final room = _room;
    if (room == null || state.phase == ScreenSharePhase.on) return;
    if (ref.read(activeCallProvider).phase != CallPhase.connected) return;
    _set(const ScreenShareState(phase: ScreenSharePhase.asking));
    final platform = _platform;
    try {
      if (!await platform.prepare()) {
        if (state.phase == ScreenSharePhase.asking) _set(const ScreenShareState());
        return;
      }
      if (!identical(room, _room)) {
        await platform.release(); // the call ended meanwhile
        return;
      }
      await room.setEnabled(true);
      _sync();
      if (state.phase == ScreenSharePhase.asking) {
        if (!platform.startsLater) throw StateError('no screen track');
        _askTimer?.cancel();
        _askTimer = Timer(kScreenShareAskTimeout, () {
          if (state.phase == ScreenSharePhase.asking) _set(const ScreenShareState());
        });
      }
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] screen share failed: $e');
      await platform.release();
      _set(const ScreenShareState(failed: true));
    }
  }

  /// "Остановить" — also on hang-up and from outside the app.
  Future<void> stop() async {
    final was = state.phase;
    _set(const ScreenShareState());
    try {
      await _room?.setEnabled(false);
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] screen share stop: $e');
    }
    if (was != ScreenSharePhase.off) await _platform.release();
  }

  Future<void> _applyLayer({bool readHeat = false}) async {
    final room = _room;
    if (room == null || state.phase != ScreenSharePhase.on) return;
    try {
      if (readHeat) _thermal = await _platform.thermal();
      final size = room.captureSize;
      final layer = screenShareLayerFor(
        device: room.deviceClass,
        link: ref.read(activeCallProvider).linkQuality,
        thermal: _thermal,
        width: size?.width,
        height: size?.height,
      );
      await room.applyLayer(layer);
      // ignore: avoid_print
      print('[livekit] screen layer: ${layer.maxBitrate ~/ 1000} kbps, ${layer.maxFramerate} fps, /${layer.scaleDownBy}');
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] screen layer not set: $e');
    }
  }
}

final screenShareProvider = NotifierProvider<ScreenShareNotifier, ScreenShareState>(ScreenShareNotifier.new);

// ─── Someone else's screen ────────────────────────────────────────────

/// The first other participant who shares their screen (and its track,
/// once subscribed).
({String identity, lk.VideoTrack track})? remoteScreenOf(lk.Room room) {
  for (final p in room.remoteParticipants.values) {
    for (final pub in p.videoTrackPublications) {
      final t = pub.track;
      if (pub.source == lk.TrackSource.screenShareVideo && t != null && !pub.muted) {
        return (identity: p.identity, track: t);
      }
    }
  }
  return null;
}

// ─── UI ───────────────────────────────────────────────────────────────

/// What the call screen's "Показать экран" button does now: start, or stop
/// mine while it's shown. Null while there's no room (nothing to share in).
VoidCallback? screenShareTap(WidgetRef ref, {required bool roomUp}) {
  if (!roomUp) return null;
  final share = ref.watch(screenShareProvider);
  final notifier = ref.read(screenShareProvider.notifier);
  return share.sharing ? notifier.stop : notifier.start;
}

/// Everything screen-sharing over the call screen, as one overlay: my
/// banner, someone else's screen (the button is the call screen's). [room] is the live call room
/// (null before media is up: nothing to show yet).
class CallScreenShareLayer extends ConsumerStatefulWidget {
  CallScreenShareLayer({super.key, required lk.Room? room})
    : changes = room,
      findRemote = room == null ? null : (() => _remoteVideoOf(room));

  /// Tests: any listenable and a stand-in for the remote screen.
  @visibleForTesting
  const CallScreenShareLayer.custom({super.key, required this.changes, required this.findRemote});

  /// Rebuild when this changes (the room: people, tracks).
  final Listenable? changes;

  /// Someone else's shared screen now (null = nobody); null before media.
  final ({String identity, Widget video})? Function()? findRemote;

  static ({String identity, Widget video})? _remoteVideoOf(lk.Room room) {
    final r = remoteScreenOf(room);
    if (r == null) return null;
    return (identity: r.identity, video: lk.VideoTrackRenderer(r.track, fit: lk.VideoViewFit.contain));
  }

  @override
  ConsumerState<CallScreenShareLayer> createState() => _CallScreenShareLayerState();
}

class _CallScreenShareLayerState extends ConsumerState<CallScreenShareLayer> {
  /// The screen I closed ("К звонку") — reopened from the pill.
  String? _dismissed;

  @override
  Widget build(BuildContext context) {
    final share = ref.watch(screenShareProvider);
    final notifier = ref.read(screenShareProvider.notifier);
    ref.listen(screenShareProvider, (prev, next) {
      if (next.failed && !(prev?.failed ?? false)) {
        // A short line over the call; the button stays for another try.
        showCallScreenShareFailed(context);
      }
    });
    final changes = widget.changes;
    final findRemote = widget.findRemote;
    if (changes == null || findRemote == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: changes,
      builder: (context, _) {
        final remote = findRemote();
        if (remote == null) _dismissed = null;
        final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
        final name = remote == null ? '' : displayNameOf(remote.identity, names);
        final viewing = remote != null && _dismissed != remote.identity;
        final pad = MediaQuery.paddingOf(context);
        return Stack(
          children: [
            if (remote != null && !viewing)
              Positioned(
                top: pad.top + DsSpace.x14,
                left: pad.left + DsSpace.x3,
                right: pad.right + DsSpace.x3,
                child: Center(
                  child: _Pill(
                    key: const ValueKey('call-screen-watch'),
                    label: context.l10n.callScreenWatch(name),
                    color: DsPalette.blue,
                    onTap: () => setState(() => _dismissed = null),
                  ),
                ),
              ),
            if (viewing)
              Positioned.fill(
                child: ScreenShareViewer(
                  name: name,
                  video: remote.video,
                  onClose: () => setState(() => _dismissed = remote.identity),
                  onHangUp: () => unawaited(ref.read(activeCallProvider.notifier).end()),
                ),
              ),
            if (share.sharing)
              Positioned(
                top: pad.top + DsSpace.x1,
                left: pad.left + DsSpace.x3,
                right: pad.right + DsSpace.x3,
                child: Center(child: ScreenShareBanner(onStop: notifier.stop)),
              ),
          ],
        );
      },
    );
  }
}

/// "Не удалось показать экран" for a moment over the call.
void showCallScreenShareFailed(BuildContext context) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;
  final text = context.l10n.callScreenShareFailed;
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: DsSpace.x6,
      right: DsSpace.x6,
      bottom: MediaQuery.paddingOf(context).bottom + DsSpace.x24 * 2,
      child: Center(
        child: Container(
          key: const ValueKey('call-screen-failed'),
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x2h5),
          decoration: BoxDecoration(color: DsPalette.toastGlass, borderRadius: BorderRadius.circular(999)),
          child: Text(text, style: DsTextArt.t14w600, textAlign: TextAlign.center),
        ),
      ),
    ),
  );
  overlay.insert(entry);
  Timer(const Duration(seconds: 3), () {
    if (entry.mounted) entry.remove();
  });
}

/// A phone with an arrow going up — built from boxes and an icon, no
/// painter.
class ScreenShareGlyph extends StatelessWidget {
  const ScreenShareGlyph({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: DsSpace.x3h5,
    height: DsSpace.x5h5,
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 2),
      borderRadius: BorderRadius.circular(DsSpace.x1),
    ),
    alignment: Alignment.center,
    child: Icon(CupertinoIcons.arrow_up, size: 11, color: color),
  );
}

/// "Вы показываете экран · Остановить".
class ScreenShareBanner extends StatelessWidget {
  const ScreenShareBanner({super.key, required this.onStop});
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Container(
      key: const ValueKey('call-screen-banner'),
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1, DsSpace.x1, DsSpace.x1),
      decoration: BoxDecoration(color: DsPalette.red, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ScreenShareGlyph(color: DsPalette.white),
          const SizedBox(width: DsSpace.x2),
          Flexible(
            child: Text(l.callSharingScreen, style: DsTextArt.t14w600, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: DsSpace.x2),
          Semantics(
            button: true,
            child: GestureDetector(
              key: const ValueKey('call-screen-stop'),
              behavior: HitTestBehavior.opaque,
              onTap: onStop,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.x2),
                decoration: BoxDecoration(color: DsPalette.white, borderRadius: BorderRadius.circular(999)),
                child: Text(l.callStopSharing, style: DsTextArt.t14w600.copyWith(color: DsPalette.red)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Someone's screen, big: pinch to zoom (and pan), rotate, back to the
/// call, hang up. While it's open the phone may turn sideways (the call
/// screen itself stays upright).
class ScreenShareViewer extends StatefulWidget {
  const ScreenShareViewer({
    super.key,
    required this.name,
    required this.video,
    required this.onClose,
    required this.onHangUp,
    @visibleForTesting this.lockOrientation = true,
  });
  final String name;
  final Widget video;
  final VoidCallback onClose;
  final VoidCallback onHangUp;

  /// Let the phone rotate while open (off in tests).
  final bool lockOrientation;

  @override
  State<ScreenShareViewer> createState() => _ScreenShareViewerState();
}

class _ScreenShareViewerState extends State<ScreenShareViewer> {
  int _turns = 0;
  final _zoom = TransformationController();

  @override
  void initState() {
    super.initState();
    if (widget.lockOrientation) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  @override
  void dispose() {
    // Back to the call screen's upright lock (LiveCallScreen, CE4).
    if (widget.lockOrientation) {
      unawaited(SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]));
    }
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final pad = MediaQuery.paddingOf(context);
    return ColoredBox(
      key: const ValueKey('call-screen-viewer'),
      color: DsPalette.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _zoom,
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: RotatedBox(key: ValueKey('call-screen-turns-$_turns'), quarterTurns: _turns, child: widget.video),
              ),
            ),
          ),
          Positioned(
            top: pad.top + DsSpace.x2,
            left: pad.left + DsSpace.x3,
            right: pad.right + DsSpace.x3,
            child: Row(
              children: [
                _Pill(
                  key: const ValueKey('call-screen-back'),
                  label: l.callScreenBackToCall,
                  color: DsPalette.black60,
                  onTap: widget.onClose,
                ),
                const SizedBox(width: DsSpace.x2),
                Expanded(
                  child: Text(
                    l.callScreenOf(widget.name),
                    style: DsTextArt.t13w600,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(width: DsSpace.x2),
                _Pill(
                  key: const ValueKey('call-screen-rotate'),
                  label: l.callScreenRotate,
                  color: DsPalette.black60,
                  onTap: () => setState(() {
                    _turns = (_turns + 1) % 4;
                    _zoom.value = Matrix4.identity();
                  }),
                ),
              ],
            ),
          ),
          Positioned(
            right: pad.right + DsSpace.x4,
            bottom: pad.bottom + DsSpace.x4,
            child: _Pill(
              key: const ValueKey('call-screen-hangup'),
              label: l.callEnd,
              color: DsPalette.red,
              onTap: widget.onHangUp,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: DsSpace.x11),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
        child: Text(label, style: DsTextArt.t14w600, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ),
  );
}
