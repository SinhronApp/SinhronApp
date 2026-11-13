// Video pages of the gallery — backlog §3 item 31, viewer polish.
//
// The video is decrypted into RAM and served to AVPlayer from there over
// the loopback-only [RamMediaServer] (as before): the whole file is in
// memory before it plays, so seeking and playing never wait on the
// network, and no plaintext touches disk. The page owns its player; the
// screen's bottom chrome shows the controls of the current page's player
// through [GalleryVideoSlot].
//
// A round video message (ADR-048) is a circle here too — the picture
// cover-cropped into [VideoNoteCircle], never the whole frame (owner,
// 2026-10-19: the sender saw only the circle).

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_loader.dart';
import '../../core/services/ram_media_server.dart';
import '../../l10n/l10n.dart';
import '../chat_view/encrypted_photo.dart' show EncryptedThumbnail;
import '../video_note/video_note_circle.dart';
import '../voice/waveform.dart' show formatVoiceDuration;
import 'gallery_item.dart';
import 'gallery_pages.dart';
import 'viewer_glyphs.dart';

/// Clips this short or shorter loop, like a GIF (Telegram).
const kLoopUnder = Duration(seconds: 30);

/// Largest circle a round video gets in the gallery (iPad, landscape).
const double kGalleryRoundMax = 520;

/// A player for decrypted bytes plus how to let go of them.
class GalleryVideoHandle {
  GalleryVideoHandle(this.controller, this.close);
  final VideoPlayerController controller;
  final Future<void> Function() close;
}

typedef GalleryVideoOpener = Future<GalleryVideoHandle> Function(Uint8List bytes, String mimeType);

/// Real: RAM → loopback HTTP → AVPlayer. Tests swap in a fake platform.
final galleryVideoOpenerProvider = Provider<GalleryVideoOpener>((ref) => (bytes, mime) async {
  final server = await RamMediaServer.start(bytes, mimeType: mime.isEmpty ? 'video/mp4' : mime);
  return GalleryVideoHandle(VideoPlayerController.networkUrl(server.uri), server.close);
});

/// The player of the page on screen (null: a photo, or still opening).
typedef GalleryVideoSlot = ValueNotifier<VideoPlayerController?>;

class GalleryVideoPage extends ConsumerStatefulWidget {
  const GalleryVideoPage({
    super.key,
    required this.item,
    required this.active,
    required this.slot,
    required this.chromeVisible,
    this.onPlaying,
    this.hero,
  });

  final GalleryItem item;

  /// Wraps the poster — the Hero, so the player opens during the flight.
  final Widget Function(Widget poster)? hero;

  /// The page on screen: plays. Off screen (mid-swipe): pauses.
  final bool active;
  final GalleryVideoSlot slot;
  final ValueListenable<bool> chromeVisible;

  /// Playback started — the screen hides its chrome after a moment.
  final VoidCallback? onPlaying;

  @override
  ConsumerState<GalleryVideoPage> createState() => _GalleryVideoPageState();
}

class _GalleryVideoPageState extends ConsumerState<GalleryVideoPage> {
  GalleryVideoHandle? _handle;
  bool _opening = false;
  bool _failed = false;
  bool _ready = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _open();
  }

  @override
  void didUpdateWidget(GalleryVideoPage old) {
    super.didUpdateWidget(old);
    final c = _handle?.controller;
    if (widget.active && !old.active) {
      if (c == null) {
        _open();
      } else {
        // Back on screen: its controls again, then play.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !widget.active) return;
          widget.slot.value = c;
          c.play();
          widget.onPlaying?.call();
        });
      }
    } else if (!widget.active && old.active && c != null) {
      // Not mid-build: pausing notifies the controls.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed && !widget.active) c.pause();
      });
    }
  }

  Future<void> _open() async {
    if (_opening || _handle != null) return;
    _opening = true;
    setState(() => _failed = false);
    try {
      final loader = ref.read(mediaLoaderProvider);
      final opener = ref.read(galleryVideoOpenerProvider);
      final info = await loader.info(widget.item.mediaJson);
      final bytes = await loader.fetch(widget.item.mediaJson, thumbnail: false);
      if (_disposed) return;
      final handle = await opener(bytes, info.mimeType);
      if (_disposed) {
        await handle.controller.dispose();
        await handle.close();
        return;
      }
      _handle = handle;
      final c = handle.controller;
      await c.initialize();
      if (_disposed) return;
      await c.setLooping(c.value.duration > Duration.zero && c.value.duration <= kLoopUnder);
      setState(() => _ready = true);
      if (widget.active) {
        widget.slot.value = c;
        await c.play();
        widget.onPlaying?.call();
      }
    } catch (_) {
      if (!_disposed) setState(() => _failed = true);
    } finally {
      _opening = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final h = _handle;
    final slot = widget.slot;
    // Let the controls drop this player first (they listen to it), then
    // free it and stop serving the bytes.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (h != null && slot.value == h.controller) slot.value = null;
      await h?.controller.dispose();
      await h?.close();
    });
    super.dispose();
  }

  void _togglePlay() {
    final c = _handle?.controller;
    if (c == null || !c.value.isInitialized) {
      if (_failed) _open();
      return;
    }
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
      widget.onPlaying?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _handle?.controller;
    if (widget.item.round) return _round(context, c);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Poster first (the Hero lands on it), the moving picture on top.
        (widget.hero ?? (w) => w)(GalleryImage(mediaJson: widget.item.mediaJson, fullImage: false)),
        if (c != null && _ready)
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
        Center(child: _overlay(context, c)),
      ],
    );
  }

  /// A round video: a big circle in the middle, poster and picture both
  /// cover-cropped into it — nothing outside the circle is drawn.
  Widget _round(BuildContext context, VideoPlayerController? c) => LayoutBuilder(
    builder: (context, box) {
      final side = math.min(kGalleryRoundMax, math.min(box.maxWidth, box.maxHeight) * 0.86);
      final size = c?.value.size ?? Size.zero;
      return Center(
        child: SizedBox.square(
          key: const ValueKey('gallery-round'),
          dimension: side,
          child: Stack(
            fit: StackFit.expand,
            children: [
              (widget.hero ?? (w) => w)(VideoNoteCircle(child: EncryptedThumbnail(mediaJson: widget.item.mediaJson))),
              if (c != null && _ready)
                VideoNoteCircle(
                  key: const ValueKey('gallery-round-video'),
                  child: FittedBox(
                    fit: BoxFit.cover,
                    clipBehavior: Clip.hardEdge,
                    child: SizedBox(
                      width: size.width == 0 ? 1 : size.width,
                      height: size.height == 0 ? 1 : size.height,
                      child: VideoPlayer(c),
                    ),
                  ),
                ),
              Center(child: _overlay(context, c)),
            ],
          ),
        ),
      );
    },
  );

  /// Retry / the decrypting dots / the big play-pause, over the picture.
  Widget _overlay(BuildContext context, VideoPlayerController? c) {
    return c == null
        ? (_failed
              ? GestureDetector(
                  key: const ValueKey('gallery-video-retry'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _open,
                  child: _Bubble(child: Text(context.l10n.videoUnavailable, style: DsTextArt.t15)),
                )
              : const _Bubble(child: _Spinner()))
        : ValueListenableBuilder<bool>(
            valueListenable: widget.chromeVisible,
            builder: (context, chrome, _) => ListenableBuilder(
              listenable: c,
              builder: (context, _) {
                final v = c.value;
                final show = v.isInitialized && (!v.isPlaying || chrome);
                return IgnorePointer(
                  ignoring: !show,
                  child: AnimatedOpacity(
                    opacity: show ? 1 : 0,
                    duration: DsMotion.of(context, DsMotion.fast),
                    child: GestureDetector(
                      key: const ValueKey('gallery-video-big-play'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _togglePlay,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(color: DsPalette.black50, shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: ViewerGlyphIcon(
                          v.isPlaying ? ViewerGlyph.pause : ViewerGlyph.play,
                          color: DsPalette.white,
                          size: 28,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x2h5),
    decoration: BoxDecoration(color: DsPalette.black50, borderRadius: BorderRadius.circular(999)),
    child: child,
  );
}

/// Three dots that pulse while the video is decrypted.
class _Spinner extends StatefulWidget {
  const _Spinner();
  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _a = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (DsMotion.reduced(context)) {
      _a.value = 0.5;
    } else if (!_a.isAnimating) {
      _a.repeat();
    }
  }

  @override
  void dispose() {
    _a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('gallery-video-loading'),
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < 3; i++) ...[
        if (i > 0) const SizedBox(width: 6),
        AnimatedBuilder(
          animation: _a,
          builder: (_, _) {
            final phase = ((_a.value - i / 3) % 1 + 1) % 1;
            final o = 0.35 + 0.65 * (1 - (phase * 2 - 1).abs());
            return Opacity(
              opacity: o,
              child: Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(color: DsPalette.white, shape: BoxShape.circle),
              ),
            );
          },
        ),
      ],
    ],
  );
}

/// Play / pause, position, scrubber, length, sound — the current page's
/// player, in the gallery's bottom chrome.
class GalleryVideoControls extends StatefulWidget {
  const GalleryVideoControls({super.key, required this.controller, this.onInteract});
  final VideoPlayerController controller;

  /// Any touch — the screen keeps its chrome up a little longer.
  final VoidCallback? onInteract;

  @override
  State<GalleryVideoControls> createState() => _GalleryVideoControlsState();
}

class _GalleryVideoControlsState extends State<GalleryVideoControls> {
  /// 0..1 while the finger is on the scrubber.
  double? _scrub;
  bool _wasPlaying = false;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  VideoPlayerController get _c => widget.controller;

  void _seekTo(double f, {bool force = false}) {
    final d = _c.value.duration;
    if (d <= Duration.zero) return;
    final now = DateTime.now();
    // A seek per frame makes AVPlayer stutter; ~12 a second is smooth.
    if (!force && now.difference(_lastSeek) < const Duration(milliseconds: 80)) return;
    _lastSeek = now;
    _c.seekTo(d * f);
  }

  void _scrubStart(double f) {
    widget.onInteract?.call();
    _wasPlaying = _c.value.isPlaying;
    if (_wasPlaying) _c.pause();
    setState(() => _scrub = f);
    _seekTo(f, force: true);
  }

  void _scrubUpdate(double f) {
    setState(() => _scrub = f);
    _seekTo(f);
  }

  void _scrubEnd() {
    final f = _scrub;
    if (f != null) _seekTo(f, force: true);
    setState(() => _scrub = null);
    if (_wasPlaying) _c.play();
    widget.onInteract?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final v = _c.value;
        final total = v.duration;
        final played = total <= Duration.zero
            ? 0.0
            : (_scrub ?? (v.position.inMilliseconds / total.inMilliseconds)).clamp(0.0, 1.0);
        final pos = _scrub == null ? v.position : total * played;
        final buffered = total <= Duration.zero || v.buffered.isEmpty
            ? 0.0
            : (v.buffered.last.end.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        final muted = v.volume == 0;
        final timeStyle = DsTextArt.t12v2.copyWith(
          color: DsPalette.white,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        return Row(
          key: const ValueKey('gallery-video-controls'),
          children: [
            _IconButton(
              key: const ValueKey('gallery-video-play'),
              glyph: v.isPlaying ? ViewerGlyph.pause : ViewerGlyph.play,
              label: v.isPlaying ? context.l10n.videoPause : context.l10n.videoPlay,
              onTap: () {
                widget.onInteract?.call();
                v.isPlaying ? _c.pause() : _c.play();
              },
            ),
            SizedBox(
              width: 44,
              child: Text(
                formatVoiceDuration(pos.inMilliseconds),
                key: const ValueKey('gallery-video-position'),
                style: timeStyle,
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) {
                  double at(Offset local) => (local.dx / box.maxWidth).clamp(0.0, 1.0);
                  return GestureDetector(
                    key: const ValueKey('gallery-video-scrubber'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) => _scrubStart(at(d.localPosition)),
                    onHorizontalDragUpdate: (d) => _scrubUpdate(at(d.localPosition)),
                    onHorizontalDragEnd: (_) => _scrubEnd(),
                    onTapDown: (d) => _scrubStart(at(d.localPosition)),
                    onTapUp: (_) => _scrubEnd(),
                    child: SizedBox(
                      height: 36,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        children: [
                          _Track(fraction: 1, color: DsPalette.white25),
                          _Track(fraction: buffered, color: DsPalette.white40),
                          _Track(fraction: played, color: DsPalette.white),
                          Positioned(
                            left: (box.maxWidth * played - (_scrub == null ? 6 : 8)).clamp(0.0, box.maxWidth),
                            child: AnimatedContainer(
                              duration: DsMotion.of(context, DsMotion.fast),
                              width: _scrub == null ? 12 : 16,
                              height: _scrub == null ? 12 : 16,
                              decoration: const BoxDecoration(color: DsPalette.white, shape: BoxShape.circle),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(
                formatVoiceDuration(total.inMilliseconds),
                textAlign: TextAlign.right,
                style: timeStyle,
              ),
            ),
            _IconButton(
              key: const ValueKey('gallery-video-mute'),
              glyph: muted ? ViewerGlyph.soundOff : ViewerGlyph.soundOn,
              label: muted ? context.l10n.videoSoundOn : context.l10n.videoSoundOff,
              onTap: () {
                widget.onInteract?.call();
                _c.setVolume(muted ? 1 : 0);
              },
            ),
          ],
        );
      },
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) => FractionallySizedBox(
    widthFactor: fraction,
    child: Container(
      height: 3,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
    ),
  );
}

class _IconButton extends StatelessWidget {
  const _IconButton({super.key, required this.glyph, required this.label, required this.onTap});
  final ViewerGlyph glyph;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Center(child: ViewerGlyphIcon(glyph, color: DsPalette.white, size: 22)),
      ),
    ),
  );
}

/// Keeps a Future from being reported as unawaited where the result
/// doesn't matter (prefetching).
void quietly(Future<void> f) => unawaited(f.then((_) {}, onError: (Object _) {}));
