// Video messages — UI backlog §3 item 31 (ADR-019 `MediaKind::Video`).
// Bubble: the poster frame (encrypted thumbnail + BlurHash, tech-debt
// 2.24) or a dark frame for older videos, with ▶, duration and size. Tap: decrypt into RAM, play full screen through the
// loopback-only [RamMediaServer]; nothing plaintext touches disk.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_loader.dart';
import '../../core/services/ram_media_server.dart';
import '../../src/rust/api/simple.dart' as core;
import '../voice/waveform.dart' show formatVoiceDuration;
import 'encrypted_media_bubbles.dart' show formatBytes;
import 'encrypted_photo.dart' show EncryptedThumbnail, mediaJsonSize, photoBubbleWidth;
import '../../l10n/l10n.dart';

class EncryptedVideo extends ConsumerStatefulWidget {
  const EncryptedVideo({super.key, required this.mediaJson, this.onTap});

  final String mediaJson;
  final VoidCallback? onTap;

  @override
  ConsumerState<EncryptedVideo> createState() => _EncryptedVideoState();
}

class _EncryptedVideoState extends ConsumerState<EncryptedVideo> {
  late final Future<core.MediaInfo> _info = ref.read(mediaLoaderProvider).info(widget.mediaJson);
  late final (int, int) _size = mediaJsonSize(widget.mediaJson);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<core.MediaInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        // Before info() answers: the size written in the JSON (no jump).
        final (iw, ih) = info == null ? _size : (info.width, info.height);
        final aspect = iw == 0 || ih == 0 ? 16 / 9 : iw / ih;
        final w = photoBubbleWidth(context);
        final h = (w / aspect).clamp(140.0, 380.0);
        return GestureDetector(
          key: const ValueKey('video-bubble'),
          behavior: HitTestBehavior.opaque,
          onTap: snap.hasError ? null : widget.onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.zero, // the bubble rounds it
            child: Container(
              width: w,
              height: h,
              color: DsPalette.art1C1E24,
              child: Stack(
                children: [
                  if (info != null && (info.hasThumbnail || info.blurhash.isNotEmpty))
                    Positioned.fill(child: EncryptedThumbnail(mediaJson: widget.mediaJson)),
                  Center(
                    child: Container(
                      width: 52,
                      height: 52,
                      decoration: const BoxDecoration(color: DsPalette.black60, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: const Icon(CupertinoIcons.play_fill, size: 24, color: DsPalette.white),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
                      decoration: BoxDecoration(color: DsPalette.black60, borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        info == null
                            ? (snap.hasError ? context.l10n.videoUnavailable : context.l10n.video)
                            : '${formatVoiceDuration(info.durationMs)} · ${formatBytes(info.sizeBytes.toInt())}',
                        style: DsTextArt.t11v2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Full-screen player. Decrypts, serves from RAM over loopback, plays;
/// tap toggles pause, ✕ closes (and stops the server).
class VideoViewerScreen extends ConsumerStatefulWidget {
  const VideoViewerScreen({super.key, required this.mediaJson});
  final String mediaJson;

  @override
  ConsumerState<VideoViewerScreen> createState() => _VideoViewerScreenState();
}

class _VideoViewerScreenState extends ConsumerState<VideoViewerScreen> {
  RamMediaServer? _server;
  VideoPlayerController? _player;
  String? _error;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final loader = ref.read(mediaLoaderProvider);
      final info = await loader.info(widget.mediaJson);
      final bytes = await loader.fetch(widget.mediaJson, thumbnail: false);
      final server = await RamMediaServer.start(bytes, mimeType: info.mimeType.isEmpty ? 'video/mp4' : info.mimeType);
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;
      final player = VideoPlayerController.networkUrl(server.uri);
      _player = player;
      await player.initialize();
      if (!mounted) return;
      setState(() {});
      await player.play();
    } catch (e) {
      if (mounted) setState(() => _error = context.l10n.videoUnavailable);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    _server?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final p = _player;
    return ColoredBox(
      color: DsPalette.black,
      child: Stack(
        children: [
          Center(
            child: _error != null
                ? Text(_error!, style: DsTextArt.t15)
                : p == null || !p.value.isInitialized
                ? Text(context.l10n.decrypting, style: DsTextArt.t15)
                : GestureDetector(
                    onTap: () => setState(() => p.value.isPlaying ? p.pause() : p.play()),
                    child: AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p)),
                  ),
          ),
          if (p != null && p.value.isInitialized)
            Positioned(
              left: 16,
              right: 16,
              bottom: pad.bottom + 16,
              child: VideoProgressIndicator(
                p,
                allowScrubbing: true,
                colors: const VideoProgressColors(playedColor: DsPalette.white),
              ),
            ),
          Positioned(
            top: pad.top + 6,
            left: 8,
            child: GestureDetector(
              key: const ValueKey('video-close'),
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).maybePop(),
              child: const Padding(
                padding: EdgeInsets.all(DsSpace.x3),
                child: Icon(CupertinoIcons.xmark, size: 20, color: DsPalette.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> openVideoViewer(BuildContext context, String mediaJson) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    transitionDuration: DsMotion.of(context, DsMotion.base),
    pageBuilder: (_, _, _) => VideoViewerScreen(mediaJson: mediaJson),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ),
);
