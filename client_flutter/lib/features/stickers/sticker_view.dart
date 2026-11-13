// One sticker on screen — ADR-049.
//
//   • tgs (Lottie): parsed once per sticker (LottieCompositions), drawn at
//     the animation's own frame rate, paused while scrolled off screen or
//     when the phone asks for less motion (then the first frame stays).
//   • png / webp: the picture (an animated WebP plays by itself).
//   • webm: on Android a muted looping video, served from RAM over the
//     loopback-only server like video messages; on iPhone (AVPlayer has no
//     WebM) its still preview — or its emoji.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:lottie/lottie.dart';
import 'package:video_player/video_player.dart';

import '../../core/services/ram_media_server.dart';
import 'sticker_codec.dart';
import 'sticker_store.dart';

/// Can this phone play WebM video stickers?
bool get webmStickersPlay => !kIsWeb && Platform.isAndroid;

class StickerView extends StatefulWidget {
  const StickerView({
    super.key,
    required this.cacheKey,
    required this.format,
    required this.load,
    this.size = 160,
    this.animate = true,
    this.repeat = true,
    this.preview,
    this.stillPending = false,
    this.emoji = '',
    this.onPlayed,
  });

  StickerView.of(Sticker s, {Key? key, double size = 160, bool animate = true, bool repeat = true})
    : this(
        key: key,
        cacheKey: s.key,
        format: s.format,
        load: s.bytes,
        size: size,
        animate: animate,
        repeat: repeat,
        preview: s.preview,
        emoji: s.emoji,
      );

  /// Unique per sticker file (parsed animations are cached by it).
  final String cacheKey;
  final String format;
  final Future<Uint8List> Function() load;
  final double size;

  /// Move at all (false: the first frame, e.g. in the panel's grid).
  final bool animate;

  /// Loop while on screen; false plays once (big emoji).
  final bool repeat;

  /// Shown while loading, and for a webm this phone can't play.
  final Uint8List? preview;

  /// [preview] is still being fetched: show nothing yet, not the emoji.
  final bool stillPending;
  final String emoji;

  /// A one-shot animation finished.
  final VoidCallback? onPlayed;

  @override
  State<StickerView> createState() => StickerViewState();
}

class StickerViewState extends State<StickerView> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this);
  LottieComposition? _lottie;
  Uint8List? _bytes;
  VideoPlayerController? _video;
  RamMediaServer? _server;
  bool _failed = false;
  bool _onScreen = true;
  ScrollPosition? _scroll;

  @override
  void initState() {
    super.initState();
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed && !widget.repeat) widget.onPlayed?.call();
    });
    unawaited(_open());
  }

  /// Play again from the start (a tap on a big emoji).
  void replay() {
    if (_lottie == null) return;
    _anim.forward(from: 0);
  }

  Future<void> _open() async {
    try {
      switch (widget.format) {
        case 'tgs':
          final c = await lottieCompositions.get(widget.cacheKey, widget.load);
          if (!mounted) return;
          _anim.duration = c.duration;
          setState(() => _lottie = c);
          _sync();
        case 'webm':
          if (!webmStickersPlay) return;
          final bytes = await widget.load();
          final server = await RamMediaServer.start(bytes, mimeType: 'video/webm');
          final v = VideoPlayerController.networkUrl(server.uri);
          if (!mounted) {
            unawaited(server.close());
            return;
          }
          _server = server;
          _video = v;
          await v.initialize();
          await v.setVolume(0);
          await v.setLooping(widget.repeat);
          if (!mounted) return;
          setState(() {});
          _sync();
        default:
          final bytes = await widget.load();
          if (!await stickerPictureOk(bytes)) throw const FormatException('sticker picture too big');
          if (mounted) setState(() => _bytes = bytes);
      }
    } catch (_) {
      // One more go after a pause (a slow link, a blob still uploading),
      // then the still / emoji.
      if (!_retried && mounted) {
        _retried = true;
        _retry = Timer(retryDelay, () {
          if (mounted) unawaited(_open());
        });
        return;
      }
      if (mounted) setState(() => _failed = true);
    }
  }

  bool _retried = false;
  Timer? _retry;

  /// Pause before the one retry of a sticker that didn't load.
  static Duration retryDelay = const Duration(seconds: 2);

  bool get _moving =>
      widget.animate && _onScreen && TickerMode.valuesOf(context).enabled && !MediaQuery.disableAnimationsOf(context);

  /// Start / stop to match [_moving].
  void _sync() {
    if (!mounted) return;
    final go = _moving;
    if (_lottie != null) {
      if (go && !_anim.isAnimating && (widget.repeat || _anim.value < 1)) {
        widget.repeat ? _anim.repeat() : _anim.forward();
      } else if (!go && _anim.isAnimating) {
        _anim.stop();
      }
    }
    final v = _video;
    if (v != null && v.value.isInitialized) {
      if (go && !v.value.isPlaying) {
        unawaited(v.play());
      } else if (!go && v.value.isPlaying) {
        unawaited(v.pause());
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _scroll) {
      _scroll?.removeListener(_checkOnScreen);
      _scroll = pos?..addListener(_checkOnScreen);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOnScreen());
  }

  @override
  void didUpdateWidget(StickerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  /// Paused while scrolled out of its list's viewport (the list keeps a
  /// few rows built beyond the edges).
  void _checkOnScreen() {
    if (!mounted) return;
    final box = context.findRenderObject();
    final scrollable = _scroll?.context.notificationContext?.findRenderObject();
    var visible = true;
    if (box is RenderBox && box.attached && scrollable is RenderBox && scrollable.attached) {
      final r = MatrixUtils.transformRect(box.getTransformTo(scrollable), Offset.zero & box.size);
      visible = r.overlaps(Offset.zero & scrollable.size);
    }
    if (visible != _onScreen) {
      _onScreen = visible;
    }
    _sync();
  }

  @override
  void dispose() {
    _scroll?.removeListener(_checkOnScreen);
    _anim.dispose();
    final v = _video, s = _server;
    _retry?.cancel();
    if (v != null) unawaited(v.dispose());
    if (s != null) unawaited(s.close());
    super.dispose();
  }

  /// The sticker's emoji, big — when there's nothing else to show.
  Widget _emoji() => Center(
    child: Text(widget.emoji.isEmpty ? '🙂' : widget.emoji, style: TextStyle(fontSize: widget.size * 0.62)),
  );

  Widget _still() {
    final p = widget.preview;
    if (p != null && p.isNotEmpty) {
      return Image.memory(
        p,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _emoji(),
      );
    }
    if (widget.stillPending) return const SizedBox.shrink();
    if (_failed || (widget.format == 'webm' && !webmStickersPlay)) return _emoji();
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    // TickerMode / reduce-motion may have changed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    final Widget child;
    final lottie = _lottie;
    final video = _video;
    if (lottie != null) {
      child = Lottie(
        composition: lottie,
        controller: _anim,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        frameRate: FrameRate.composition,
      );
    } else if (video != null && video.value.isInitialized) {
      child = FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(
          width: video.value.size.width,
          height: video.value.size.height,
          child: VideoPlayer(video),
        ),
      );
    } else if (_bytes != null) {
      child = Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _emoji(),
      );
    } else {
      child = _still();
    }
    return RepaintBoundary(
      child: SizedBox(width: widget.size, height: widget.size, child: child),
    );
  }
}
