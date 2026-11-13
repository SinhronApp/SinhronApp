// Gallery pages — the picture itself, its zoom and the Hero flight.
//
//   • GalleryImage: thumbnail at once (already in RAM from the bubble, so
//     the first frame is never "Decrypting…"), the full photo cross-fades
//     in over it once decrypted.
//   • ZoomableView: pinch zoom with rubber-banding past 1× and the max,
//     pan with inertia while zoomed, double tap zooms into the tapped
//     point (and back). Single-finger drags are left to the page swipe and
//     the drag-to-dismiss while not zoomed.
//   • galleryHeroShuttle: the thumbnail grows from the bubble's cropped,
//     rounded box into the full-screen fitted picture (and back), so there
//     is no jump from "cover" to "contain" at either end. A round video
//     (ADR-048) flies as a circle — never its whole frame.
//
// Decrypted bytes stay in RAM (MediaLoader → MediaCache).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_cache.dart';
import '../../core/services/media_loader.dart';
import '../../l10n/l10n.dart';
import '../video_note/video_note_circle.dart';
import 'gallery_item.dart';

/// Width / height of [image] once decoded — synchronously when it is in
/// the ImageCache already. Returns the cancel.
VoidCallback watchAspect(ImageProvider image, ValueChanged<double> onAspect) {
  final stream = image.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) {
      final w = info.image.width, h = info.image.height;
      info.dispose();
      if (w > 0 && h > 0) onAspect(w / h);
    },
    onError: (_, _) {},
  );
  stream.addListener(listener);
  return () => stream.removeListener(listener);
}

/// [aspect] fitted inside [box]: whole picture visible ([cover] false) or
/// the box filled and the rest cropped ([cover] true). Centred.
Rect fitRect(Size box, double aspect, {required bool cover}) {
  if (box.isEmpty || aspect <= 0) return Offset.zero & box;
  final wider = box.width / box.height > aspect;
  final Size s;
  if (wider == cover) {
    s = Size(box.width, box.width / aspect);
  } else {
    s = Size(box.height * aspect, box.height);
  }
  return Rect.fromCenter(center: box.center(Offset.zero), width: s.width, height: s.height);
}

/// Marks the viewer side of a Hero so the shuttle knows what it carries.
class GalleryHeroChild extends StatelessWidget {
  const GalleryHeroChild({super.key, required this.item, required this.child});
  final GalleryItem item;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Curve of the flight — the Hero box and the crop morph share it.
const Curve kGalleryFlightCurve = DsMotion.emphasized;

/// The box flies along [kGalleryFlightCurve] instead of linearly.
RectTween galleryRectTween(Rect? begin, Rect? end) => _CurvedRectTween(begin: begin, end: end);

class _CurvedRectTween extends RectTween {
  _CurvedRectTween({super.begin, super.end});
  @override
  Rect? lerp(double t) => super.lerp(kGalleryFlightCurve.transform(t.clamp(0.0, 1.0)));
}

Widget galleryHeroShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final viewerSide = direction == HeroFlightDirection.push ? toHeroContext : fromHeroContext;
  final child = (viewerSide.widget as Hero).child;
  if (child is! GalleryHeroChild) return child;
  if (child.item.round) return _RoundShuttle(item: child.item);
  return _MorphShuttle(item: child.item, animation: animation, direction: direction);
}

/// A round video in flight: its poster in a circle the whole way.
class _RoundShuttle extends ConsumerWidget {
  const _RoundShuttle({required this.item});
  final GalleryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = peekMedia(ref.read(mediaCacheProvider), item.mediaJson, thumbnail: true);
    return VideoNoteCircle(
      key: const ValueKey('gallery-round-shuttle'),
      child: thumb == null
          ? const SizedBox.shrink()
          : Image(image: MemoryImage(thumb), fit: BoxFit.cover, gaplessPlayback: true),
    );
  }
}

class _MorphShuttle extends ConsumerStatefulWidget {
  const _MorphShuttle({required this.item, required this.animation, required this.direction});
  final GalleryItem item;
  final Animation<double> animation;
  final HeroFlightDirection direction;

  @override
  ConsumerState<_MorphShuttle> createState() => _MorphShuttleState();
}

class _MorphShuttleState extends ConsumerState<_MorphShuttle> {
  Uint8List? _thumb;
  double? _aspect;
  VoidCallback? _cancel;

  bool _initing = true;

  @override
  void initState() {
    super.initState();
    final cache = ref.read(mediaCacheProvider);
    _thumb = peekMedia(cache, widget.item.mediaJson, thumbnail: true);
    final t = _thumb;
    if (t != null) {
      _cancel = watchAspect(MemoryImage(t), (a) {
        // A decoded thumbnail answers synchronously, inside initState.
        if (_initing) {
          _aspect = a;
        } else if (mounted) {
          setState(() => _aspect = a);
        }
      });
    }
    _initing = false;
  }

  @override
  void dispose() {
    _cancel?.call();
    super.dispose();
  }

  /// 0 = the bubble, 1 = the viewer — matched to the Hero box's tween
  /// (its pop flight runs on the reversed route animation).
  double get _t {
    final v = widget.animation.value.clamp(0.0, 1.0);
    return widget.direction == HeroFlightDirection.push
        ? kGalleryFlightCurve.transform(v)
        : 1 - kGalleryFlightCurve.transform(1 - v);
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb;
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          final size = box.biggest;
          final t = _t;
          final aspect = _aspect ?? (size.height > 0 ? size.width / size.height : 1);
          final cover = fitRect(size, aspect, cover: true);
          final contain = fitRect(size, aspect, cover: false);
          final draw = Rect.lerp(cover, contain, t)!;
          final clip = Rect.lerp(Offset.zero & size, contain, t)!;
          return Stack(
            children: [
              Positioned.fromRect(
                rect: clip,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14 * (1 - t)),
                  child: Stack(
                    children: [
                      Positioned(
                        left: draw.left - clip.left,
                        top: draw.top - clip.top,
                        width: draw.width,
                        height: draw.height,
                        child: thumb == null
                            ? const ColoredBox(color: DsPalette.art1C1E24)
                            : Image(image: MemoryImage(thumb), fit: BoxFit.fill, gaplessPlayback: true),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The picture of a gallery page: thumbnail at once, full photo over it.
/// [fullImage] false: the poster only (videos).
class GalleryImage extends ConsumerStatefulWidget {
  const GalleryImage({super.key, required this.mediaJson, this.fullImage = true, this.onAspect});

  final String mediaJson;
  final bool fullImage;
  final ValueChanged<double>? onAspect;

  @override
  ConsumerState<GalleryImage> createState() => _GalleryImageState();
}

class _GalleryImageState extends ConsumerState<GalleryImage> {
  Uint8List? _thumb;
  Uint8List? _full;
  bool _failed = false;
  bool _noPoster = false;
  final _cancels = <VoidCallback>[];

  @override
  void initState() {
    super.initState();
    final cache = ref.read(mediaCacheProvider);
    _thumb = peekMedia(cache, widget.mediaJson, thumbnail: true);
    if (widget.fullImage) _full = peekMedia(cache, widget.mediaJson, thumbnail: false);
    _watch(_thumb, null);
    _load();
  }

  void _watch(Uint8List? bytes, int? cacheWidth) {
    final cb = widget.onAspect;
    if (bytes == null || cb == null) return;
    final provider = ResizeImage.resizeIfNeeded(cacheWidth, null, MemoryImage(bytes));
    // Reported after the frame: the first answer can come synchronously.
    _cancels.add(watchAspect(provider, (a) => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(a);
    })));
  }

  Future<void> _load() async {
    if (_full != null) return;
    final loader = ref.read(mediaLoaderProvider);
    try {
      final info = await loader.info(widget.mediaJson);
      if (_thumb == null && info.hasThumbnail) {
        final t = await loader.fetch(widget.mediaJson, thumbnail: true);
        if (!mounted) return;
        setState(() => _thumb = t);
        _watch(t, null);
      } else if (!info.hasThumbnail && !widget.fullImage && mounted) {
        setState(() => _noPoster = true);
      }
      if (!widget.fullImage) return;
      final full = await loader.fetch(widget.mediaJson, thumbnail: false);
      if (mounted) setState(() => _full = full);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    for (final c in _cancels) {
      c();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _thumb, full = _full;
    // ≤2048 px source; decode at 2× the screen width so pinch-zoom stays
    // sharp without holding a full-size bitmap per photo.
    final mq = MediaQuery.of(context);
    final cacheWidth = (math.max(mq.size.width, mq.size.height) * mq.devicePixelRatio * 2).round().clamp(1, 2048);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null)
          Image(
            key: const ValueKey('gallery-thumb'),
            image: MemoryImage(thumb),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
          ),
        if (full != null)
          Image.memory(
            full,
            key: const ValueKey('gallery-full'),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            cacheWidth: cacheWidth,
            frameBuilder: (context, child, frame, sync) => sync || thumb == null
                ? child
                : AnimatedOpacity(
                    opacity: frame == null ? 0 : 1,
                    duration: DsMotion.of(context, DsMotion.fast),
                    child: child,
                  ),
          ),
        if (thumb == null && full == null && !_noPoster)
          Center(
            child: Text(
              _failed ? context.l10n.photoUnavailable : context.l10n.decrypting,
              style: DsTextArt.t15,
            ),
          ),
      ],
    );
  }
}

/// Pinch / pan / double-tap zoom with rubber bands. The child fills the
/// box; [contentAspect] (the picture's width / height, fitted inside)
/// bounds the pan so a zoomed photo never slides into its black bars.
class ZoomableView extends StatefulWidget {
  const ZoomableView({
    super.key,
    required this.child,
    required this.onZoomChanged,
    this.contentAspect,
    this.maxScale = 5,
  });

  final Widget child;
  final ValueChanged<bool> onZoomChanged;
  final double? contentAspect;
  final double maxScale;

  @override
  State<ZoomableView> createState() => ZoomableViewState();
}

class ZoomableViewState extends State<ZoomableView> with SingleTickerProviderStateMixin {
  double _s = 1;
  Offset _o = Offset.zero;
  Size _box = Size.zero;

  late final AnimationController _settle;
  Curve _curve = DsMotion.enter;
  double _fromS = 1, _toS = 1;
  Offset _fromO = Offset.zero, _toO = Offset.zero;

  double _s0 = 1;
  Offset _anchor = Offset.zero; // content point under the fingers
  Offset _focal = Offset.zero;
  Offset _tapAt = Offset.zero;
  bool _reported = false;

  double get scale => _s;
  bool get zoomed => _s > 1.01;

  @override
  void initState() {
    super.initState();
    _settle = AnimationController(vsync: this)..addListener(_tick);
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  Rect get _content {
    final a = widget.contentAspect;
    return a == null ? Offset.zero & _box : fitRect(_box, a, cover: false);
  }

  /// [o] moved so the scaled content covers the box where it can and is
  /// centred where it can't.
  Offset _clamp(double s, Offset o) {
    final c = _content;
    double axis(double o, double lo, double hi, double extent) {
      final len = (hi - lo) * s;
      if (len <= extent) return (extent - len) / 2 - lo * s;
      return o.clamp(extent - hi * s, -lo * s);
    }

    return Offset(axis(o.dx, c.left, c.right, _box.width), axis(o.dy, c.top, c.bottom, _box.height));
  }

  void _set(double s, Offset o) {
    setState(() {
      _s = s;
      _o = o;
    });
    final z = zoomed;
    if (z != _reported) {
      _reported = z;
      widget.onZoomChanged(z);
    }
  }

  void _tick() {
    final t = _curve.transform(_settle.value);
    _set(_fromS + (_toS - _fromS) * t, Offset.lerp(_fromO, _toO, t)!);
  }

  void _animateTo(double s, Offset o, {Duration duration = DsMotion.base, Curve curve = DsMotion.enter}) {
    _fromS = _s;
    _fromO = _o;
    _toS = s;
    _toO = o;
    _curve = curve;
    final d = DsMotion.of(context, duration);
    if (d == Duration.zero || ((s - _s).abs() < 0.001 && (o - _o).distance < 0.5)) {
      _settle.stop();
      _set(s, o);
      return;
    }
    _settle.duration = d;
    _settle.forward(from: 0);
  }

  /// Back to 1× (page swipes, programmatic).
  void reset() => _animateTo(1, Offset.zero);

  void _onScaleStart(ScaleStartDetails d) {
    _settle.stop();
    _s0 = _s;
    _focal = d.localFocalPoint;
    _anchor = (d.localFocalPoint - _o) / _s;
  }

  double _rubberScale(double raw) {
    if (raw < 1) return math.max(0.5, 1 - (1 - raw) * 0.4);
    final max = widget.maxScale;
    if (raw > max) return max + (raw - max) * 0.25;
    return raw;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    final s = _rubberScale(_s0 * d.scale);
    _focal = d.localFocalPoint;
    final o = d.localFocalPoint - _anchor * s;
    final c = _clamp(s, o);
    // Past the edge the picture still follows, at a third of the finger.
    _set(s, c + (o - c) * 0.33);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    final s = _s.clamp(1.0, widget.maxScale);
    if ((s - _s).abs() > 0.001) {
      final anchor = (_focal - _o) / _s;
      _animateTo(s, s <= 1.0 ? Offset.zero : _clamp(s, _focal - anchor * s), curve: DsMotion.emphasized);
      return;
    }
    final v = d.velocity.pixelsPerSecond;
    final fling = zoomed && v.distance > 200;
    _animateTo(
      s,
      _clamp(s, fling ? _o + v * 0.22 : _o),
      duration: fling ? DsMotion.slow : DsMotion.base,
      curve: fling ? Curves.decelerate : DsMotion.enter,
    );
  }

  void _onDoubleTap() {
    if (zoomed) {
      _animateTo(1, Offset.zero, curve: DsMotion.emphasized);
      return;
    }
    final c = _content;
    final fill = c.isEmpty ? 1.0 : math.max(_box.width / c.width, _box.height / c.height);
    final s = math.min(widget.maxScale, math.max(2.5, fill));
    final p = _tapAt;
    _animateTo(s, _clamp(s, p - ((p - _o) / _s) * s), curve: DsMotion.emphasized);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // Rotated / resized: the old zoom means nothing in the new box.
        if (_box != box.biggest && _box != Size.zero && (zoomed || _o != Offset.zero)) {
          _settle.stop();
          _s = 1;
          _o = Offset.zero;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_reported) return;
            _reported = false;
            widget.onZoomChanged(false);
          });
        }
        _box = box.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: (d) => _tapAt = d.localPosition,
          onDoubleTap: _onDoubleTap,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: ClipRect(
            child: Transform(
              transform: Matrix4.identity()
                ..translateByDouble(_o.dx, _o.dy, 0, 1)
                ..scaleByDouble(_s, _s, 1, 1),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
