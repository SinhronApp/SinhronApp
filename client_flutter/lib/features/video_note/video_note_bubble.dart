// Round video messages ("кружки") — ADR-048. The bubble.
//
// A circle with the poster frame (encrypted thumbnail + BlurHash). Once it
// is on screen it decrypts the clip into RAM and plays it muted, looping —
// served over the loopback-only [RamMediaServer], nothing plaintext on
// disk. Tap: from the start with sound, a little bigger, with a progress
// ring; tap again pauses. Drag around the ring to rewind. At the end it
// goes back to the muted loop.
//
// [InlineVideo] is the seam — widget tests fake it (no video_player
// under `flutter test`).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_loader.dart';
import '../../core/services/ram_media_server.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_shared_glyphs.dart';
import '../chat_view/encrypted_photo.dart' show EncryptedThumbnail;
import '../voice/voice_player.dart';
import '../voice/waveform.dart' show formatVoiceDuration;
import 'video_note_circle.dart';

export 'video_note_circle.dart' show VideoNoteCircle, isVideoNoteJson;

/// Diameter in the chat, and while it plays with sound.
const double kVideoNoteBubble = 200;
const double kVideoNoteBubbleExpanded = 248;


/// A small player over decrypted bytes.
abstract class InlineVideo implements Listenable {
  Future<void> open(Uint8List bytes, String mimeType);
  bool get playing;
  Duration get position;
  Duration get duration;
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setLooping(bool looping);

  /// The picture, covering whatever box it gets.
  Widget view();
  Future<void> dispose();
}

typedef InlineVideoFactory = InlineVideo Function();

final inlineVideoProvider = Provider<InlineVideoFactory>((ref) => RamInlineVideo.new);

/// video_player over [RamMediaServer]. Mixes with other audio, so a muted
/// circle scrolling by doesn't stop the user's music.
class RamInlineVideo extends ChangeNotifier implements InlineVideo {
  RamMediaServer? _server;
  VideoPlayerController? _player;
  bool _disposed = false;

  @override
  Future<void> open(Uint8List bytes, String mimeType) async {
    final server = await RamMediaServer.start(bytes, mimeType: mimeType);
    if (_disposed) {
      await server.close();
      return;
    }
    _server = server;
    final player = VideoPlayerController.networkUrl(
      server.uri,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _player = player;
    player.addListener(notifyListeners);
    await player.initialize();
  }

  VideoPlayerValue? get _v => _player?.value;

  @override
  bool get playing => _v?.isPlaying ?? false;
  @override
  Duration get position => _v?.position ?? Duration.zero;
  @override
  Duration get duration => _v?.duration ?? Duration.zero;
  @override
  Future<void> play() async => _player?.play();
  @override
  Future<void> pause() async => _player?.pause();
  @override
  Future<void> seekTo(Duration position) async => _player?.seekTo(position);
  @override
  Future<void> setVolume(double volume) async => _player?.setVolume(volume);
  @override
  Future<void> setLooping(bool looping) async => _player?.setLooping(looping);

  @override
  Widget view() {
    final p = _player;
    if (p == null || !p.value.isInitialized) return const SizedBox.expand();
    final size = p.value.size;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.width == 0 ? 1 : size.width,
          height: size.height == 0 ? 1 : size.height,
          child: VideoPlayer(p),
        ),
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    final p = _player;
    _player = null;
    p?.removeListener(notifyListeners);
    super.dispose();
    await p?.dispose();
    await _server?.close();
    _server = null;
  }
}

/// Where on the ring [local] is: 0 at 12 o'clock, clockwise to 1.
double videoNoteRingFraction(Offset local, Size box) {
  final a = math.atan2(local.dx - box.width / 2, box.height / 2 - local.dy);
  return (a < 0 ? a + 2 * math.pi : a) / (2 * math.pi);
}

/// Only one circle talks at a time: the one that last turned its sound on.
final ValueNotifier<Object?> _soundOwner = ValueNotifier<Object?>(null);

/// Round videos played with sound since the app started: the muted mark
/// after the length goes once the owner has heard one (owner, 2026-11-03 —
/// it stayed after watching). Not kept across launches.
@visibleForTesting
final heardVideoNotes = <String>{};

class VideoNoteBubble extends ConsumerStatefulWidget {
  const VideoNoteBubble({super.key, required this.mediaJson, this.meta, this.autoplay = true});

  final String mediaJson;

  /// Time + ticks, bottom right on the circle.
  final Widget? meta;

  /// Play muted once on screen (off with reduce motion).
  final bool autoplay;

  @override
  ConsumerState<VideoNoteBubble> createState() => _VideoNoteBubbleState();
}

class _VideoNoteBubbleState extends ConsumerState<VideoNoteBubble> {
  late final Future<core.MediaInfo> _info = ref.read(mediaLoaderProvider).info(widget.mediaJson);
  InlineVideo? _video;
  Future<InlineVideo?>? _opening;
  Timer? _autoplay;
  bool _sound = false;
  int _durationMs = 0;

  /// 0..1 while a finger drags around the ring.
  double? _scrub;
  bool _wasPlaying = false;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _info.then((i) {
      if (mounted) setState(() => _durationMs = i.durationMs);
    }, onError: (_) {});
    _soundOwner.addListener(_onSoundOwner);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Waits a moment: a circle flicked past while scrolling isn't loaded.
    if (_autoplay == null && _video == null && widget.autoplay && !MediaQuery.disableAnimationsOf(context)) {
      _autoplay = Timer(const Duration(milliseconds: 350), () {
        if (mounted && !_sound) unawaited(_ensureOpen().then((v) => v == null ? null : _mutedLoop(v)));
      });
    }
  }

  @override
  void dispose() {
    _autoplay?.cancel();
    _soundOwner.removeListener(_onSoundOwner);
    if (_soundOwner.value == this) _soundOwner.value = null;
    final v = _video;
    _video = null;
    v?.removeListener(_onTick);
    unawaited(v?.dispose());
    super.dispose();
  }

  Future<InlineVideo?> _ensureOpen() => _opening ??= _open();

  Future<InlineVideo?> _open() async {
    try {
      final loader = ref.read(mediaLoaderProvider);
      final make = ref.read(inlineVideoProvider);
      final info = await _info;
      final bytes = await loader.fetch(widget.mediaJson, thumbnail: false);
      if (!mounted) return null;
      final v = make();
      await v.open(bytes, info.mimeType.isEmpty ? 'video/mp4' : info.mimeType);
      if (!mounted) {
        await v.dispose();
        return null;
      }
      v.addListener(_onTick);
      setState(() => _video = v);
      return v;
    } catch (_) {
      _opening = null; // the poster stays; a tap tries again
      return null;
    }
  }

  Future<void> _mutedLoop(InlineVideo v) async {
    await v.setVolume(0);
    await v.setLooping(true);
    await v.play();
  }

  Future<void> _onTap() async {
    final v = _video;
    if (_sound && v != null) {
      await (v.playing ? v.pause() : v.play());
      return;
    }
    setState(() {
      _sound = true;
      heardVideoNotes.add(widget.mediaJson);
    });
    _soundOwner.value = this;
    unawaited(ref.read(voicePlayerProvider.notifier).stop());
    final opened = v ?? await _ensureOpen();
    if (opened == null || !mounted || !_sound) {
      if (mounted) setState(() => _sound = false);
      return;
    }
    await opened.setLooping(false);
    await opened.setVolume(1);
    await opened.seekTo(Duration.zero);
    await opened.play();
  }

  void _seekScrub(InlineVideo v, {bool force = false}) {
    final f = _scrub;
    final d = v.duration;
    if (f == null || d <= Duration.zero) return;
    final now = DateTime.now();
    // A seek per frame makes AVPlayer stutter; ~12 a second is smooth.
    if (!force && now.difference(_lastSeek) < const Duration(milliseconds: 80)) return;
    _lastSeek = now;
    unawaited(v.seekTo(d * f));
  }

  void _scrubStart(Offset local, Size box) {
    final v = _video;
    if (v == null || !_sound) return;
    _wasPlaying = v.playing;
    if (_wasPlaying) unawaited(v.pause());
    setState(() => _scrub = videoNoteRingFraction(local, box));
    _seekScrub(v, force: true);
  }

  void _scrubUpdate(Offset local, Size box) {
    final v = _video;
    final prev = _scrub;
    if (v == null || prev == null) return;
    var f = videoNoteRingFraction(local, box);
    // Past 12 o'clock it stops at the start / the end instead of jumping
    // round the circle.
    if ((f - prev).abs() > 0.5) f = prev > 0.5 ? 1.0 : 0.0;
    setState(() => _scrub = f);
    _seekScrub(v);
  }

  void _scrubEnd() {
    final v = _video;
    if (v == null || _scrub == null) return;
    _seekScrub(v, force: true);
    setState(() => _scrub = null);
    if (_wasPlaying) unawaited(v.play());
  }

  /// Played to the end with sound → back to the small muted loop.
  void _onTick() {
    final v = _video;
    if (v == null || !_sound || _scrub != null) return;
    final d = v.duration;
    if (!v.playing && d > Duration.zero && v.position >= d - const Duration(milliseconds: 150)) {
      _backToMuted(v);
    }
  }

  void _onSoundOwner() {
    final v = _video;
    if (_sound && _soundOwner.value != this && v != null) _backToMuted(v);
  }

  void _backToMuted(InlineVideo v) {
    if (!mounted) return;
    setState(() => _sound = false);
    if (_soundOwner.value == this) _soundOwner.value = null;
    unawaited(v.seekTo(Duration.zero).then((_) => _mutedLoop(v)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final v = _video;
    final side = _sound ? kVideoNoteBubbleExpanded : kVideoNoteBubble;
    return Semantics(
      button: true,
      label: context.l10n.a11yVideoNotePlay(formatVoiceDuration(_durationMs)),
      child: GestureDetector(
        key: const ValueKey('video-note-bubble'),
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: AnimatedContainer(
          duration: DsMotion.of(context, DsMotion.base),
          curve: DsMotion.emphasized,
          width: side,
          height: side,
          child: Stack(
            children: [
              Positioned.fill(
                child: VideoNoteCircle(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      EncryptedThumbnail(mediaJson: widget.mediaJson),
                      if (v != null) KeyedSubtree(key: const ValueKey('video-note-playing'), child: v.view()),
                    ],
                  ),
                ),
              ),
              if (v != null && _sound)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: v,
                    builder: (_, _) {
                      final d = v.duration.inMilliseconds;
                      return CustomPaint(
                        key: const ValueKey('video-note-ring'),
                        painter: DsProgressRingPainter(
                          pct: _scrub ?? (d == 0 ? 0 : (v.position.inMilliseconds / d).clamp(0.0, 1.0)),
                          trackColor: DsPalette.white25,
                          fillColor: tokens.accent,
                          // Thicker under the finger.
                          strokeWidth: _scrub == null ? 3 : 6,
                        ),
                      );
                    },
                  ),
                ),
              if (v != null && _sound)
                Center(
                  child: AnimatedBuilder(
                    animation: v,
                    builder: (_, _) => v.playing || _scrub != null
                        ? const SizedBox.shrink()
                        : Container(
                            width: 52,
                            height: 52,
                            decoration: const BoxDecoration(color: DsPalette.black60, shape: BoxShape.circle),
                            alignment: Alignment.center,
                            child: const Icon(CupertinoIcons.play_fill, size: 24, color: DsPalette.white),
                          ),
                  ),
                ),
              if (v != null && _sound)
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final size = box.biggest;
                      return RawGestureDetector(
                        key: const ValueKey('video-note-scrubber'),
                        behavior: HitTestBehavior.translucent,
                        gestures: {
                          _RingPanRecognizer: GestureRecognizerFactoryWithHandlers<_RingPanRecognizer>(
                            () => _RingPanRecognizer(debugOwner: this),
                            (r) {
                              r.accepts = (local) =>
                                  (local - size.center(Offset.zero)).distance >= size.shortestSide / 4;
                              r
                                ..onStart = ((d) => _scrubStart(d.localPosition, size))
                                ..onUpdate = ((d) => _scrubUpdate(d.localPosition, size))
                                ..onEnd = ((_) => _scrubEnd())
                                ..onCancel = _scrubEnd;
                            },
                          ),
                        },
                      );
                    },
                  ),
                ),
              Positioned(
                left: side * 0.12,
                bottom: side * 0.06,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
                  decoration: BoxDecoration(color: DsPalette.black60, borderRadius: BorderRadius.circular(8)),
                  child: v == null || !_sound
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formatVoiceDuration(_durationMs),
                              key: const ValueKey('video-note-duration'),
                              style: DsTextArt.t11v2,
                            ),
                            // Playing muted, not heard yet.
                            if (v != null && !_sound && !heardVideoNotes.contains(widget.mediaJson)) ...[
                              const SizedBox(width: 3),
                              const Icon(
                                CupertinoIcons.speaker_slash_fill,
                                key: ValueKey('video-note-muted'),
                                size: 11,
                                color: DsPalette.white,
                              ),
                            ],
                          ],
                        )
                      : AnimatedBuilder(
                          animation: v,
                          builder: (_, _) {
                            final at = _scrub == null ? v.position : v.duration * _scrub!;
                            final left = v.duration - at;
                            return Text(
                              formatVoiceDuration(left.isNegative ? 0 : left.inMilliseconds),
                              key: const ValueKey('video-note-duration'),
                              style: DsTextArt.t11v2,
                            );
                          },
                        ),
                ),
              ),
              if (widget.meta != null)
                Positioned(
                  right: side * 0.1,
                  bottom: side * 0.06,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
                    decoration: BoxDecoration(color: DsPalette.black60, borderRadius: BorderRadius.circular(8)),
                    child: widget.meta,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A drag that starts on the outer half of the circle — the ring. One that
/// starts mid-picture still scrolls the chat. It also takes the gesture a
/// little sooner than the list's scroll and swipe-to-reply would.
class _RingPanRecognizer extends PanGestureRecognizer {
  _RingPanRecognizer({super.debugOwner});

  bool Function(Offset local) accepts = _never;
  static bool _never(Offset _) => false;

  @override
  bool isPointerAllowed(PointerEvent event) => accepts(event.localPosition) && super.isPointerAllowed(event);

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      globalDistanceMoved.abs() > computeHitSlop(pointerDeviceKind, gestureSettings) / 2;
}
