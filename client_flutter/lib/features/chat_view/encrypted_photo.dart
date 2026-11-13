// Photo bubble content for real (encrypted) media — ADR-017 stage 2.
//
// Paint order: BlurHash placeholder (instant, from message metadata) →
// decrypted thumbnail (≤32 KB, fetched eagerly). The full image is only
// fetched when the viewer opens. All bytes stay in RAM (MediaCache).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';

import '../../core/services/media_loader.dart';
import '../../src/rust/api/simple.dart' as core;
import '../media_viewer/gallery_pages.dart' show galleryRectTween;
import '../../l10n/l10n.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';

// Status 213 (owner: "compare how photos are sent — iMessage, Telegram"):
// wider, as in Telegram / WhatsApp (was 244).
const double kPhotoBubbleWidth = 280;

/// Bubble height for a photo of [w]×[h], clamped so extreme panoramas or
/// tall screenshots don't produce absurd bubbles.
double photoBubbleHeight(int w, int h, {double width = kPhotoBubbleWidth}) {
  if (w <= 0 || h <= 0) return 180;
  return (width * h / w).clamp(140.0, 380.0);
}

/// The picture's width on this screen: [kPhotoBubbleWidth], narrower on a
/// small phone (the bubble may take 78 % of the screen).
double photoBubbleWidth(BuildContext context) =>
    math.min(kPhotoBubbleWidth, MediaQuery.sizeOf(context).width * 0.72);

/// Width × height written in the stored media JSON — readable before the
/// async `info()` answers, so the bubble has its final height from the
/// first frame (no jump in the feed). (0, 0) when absent.
(int, int) mediaJsonSize(String mediaJson) {
  try {
    final j = jsonDecode(mediaJson);
    if (j is Map && j['width'] is int && j['height'] is int) return (j['width'] as int, j['height'] as int);
  } catch (_) {}
  return (0, 0);
}

class EncryptedPhoto extends ConsumerStatefulWidget {
  const EncryptedPhoto({super.key, required this.mediaJson, this.onTap, this.heroTag});

  final String mediaJson;
  final VoidCallback? onTap;

  /// Hero tag shared with the gallery page (backlog §3 item 27).
  final Object? heroTag;

  @override
  ConsumerState<EncryptedPhoto> createState() => _EncryptedPhotoState();
}

class _EncryptedPhotoState extends ConsumerState<EncryptedPhoto> {
  // Fetched once; a FutureBuilder future created in build() would
  // restart (and flicker the bubble size) on every rebuild.
  late final Future<core.MediaInfo> _info = ref.read(mediaLoaderProvider).info(widget.mediaJson);
  late final (int, int) _size = mediaJsonSize(widget.mediaJson);

  @override
  Widget build(BuildContext context) {
    final mediaJson = widget.mediaJson;
    final onTap = widget.onTap;
    return FutureBuilder<core.MediaInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        final width = photoBubbleWidth(context);
        final height = info == null
            ? photoBubbleHeight(_size.$1, _size.$2, width: width)
            : photoBubbleHeight(info.width, info.height, width: width);
        // The bubble rounds it (flush to its edges, as in Telegram).
        return SizedBox(
          width: width,
          height: height,
          child: widget.heroTag == null
              ? EncryptedThumbnail(mediaJson: mediaJson, onTap: onTap, full: true)
              : Hero(
                  tag: widget.heroTag!,
                  createRectTween: galleryRectTween,
                  child: EncryptedThumbnail(mediaJson: mediaJson, onTap: onTap, full: true),
                ),
        );
      },
    );
  }
}

/// Several photos sent together (one album id) as one grid bubble:
/// 2 side by side, 3 = one big + two, 4 = 2×2, more = 2 then rows of 3.
class EncryptedAlbum extends StatelessWidget {
  const EncryptedAlbum({super.key, required this.mediaJsons, required this.heroTags, this.onTap});

  final List<String> mediaJsons;
  final List<Object> heroTags;
  final ValueChanged<int>? onTap;

  static const _gap = 2.0;

  Widget _tile(int i, double w, double h) => SizedBox(
    width: w,
    height: h,
    child: Hero(
      tag: heroTags[i],
      createRectTween: galleryRectTween,
      child: EncryptedThumbnail(
        key: ValueKey('album-tile-$i'),
        mediaJson: mediaJsons[i],
        onTap: onTap == null ? null : () => onTap!(i),
        full: true,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final width = photoBubbleWidth(context);
    final n = mediaJsons.length;
    final rows = <List<int>>[];
    if (n == 3) {
      return ClipRRect(
        borderRadius: BorderRadius.zero,
        child: Row(
          children: [
            _tile(0, (width - _gap) * 0.6, 200),
            const SizedBox(width: _gap),
            Column(
              children: [
                _tile(1, (width - _gap) * 0.4, (200 - _gap) / 2),
                const SizedBox(height: _gap),
                _tile(2, (width - _gap) * 0.4, (200 - _gap) / 2),
              ],
            ),
          ],
        ),
      );
    }
    var i = 0;
    if (n == 4) {
      rows.addAll([
        [0, 1],
        [2, 3],
      ]);
    } else {
      rows.add([for (; i < (n < 2 ? n : 2); i++) i]);
      while (i < n) {
        rows.add([for (var k = 0; k < 3 && i < n; k++, i++) i]);
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.zero,
      child: Column(
        children: [
          for (var r = 0; r < rows.length; r++) ...[
            if (r > 0) const SizedBox(height: _gap),
            Row(
              children: [
                for (var k = 0; k < rows[r].length; k++) ...[
                  if (k > 0) const SizedBox(width: _gap),
                  _tile(
                    rows[r][k],
                    (width - _gap * (rows[r].length - 1)) / rows[r].length,
                    rows[r].length == 2 ? 140 : 96,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Fills its box: BlurHash placeholder → decrypted thumbnail (cover) →
/// with [full], the photo itself. Used by the chat bubble and the
/// shared-media grid.
class EncryptedThumbnail extends ConsumerStatefulWidget {
  const EncryptedThumbnail({super.key, required this.mediaJson, this.onTap, this.full = false});

  final String mediaJson;
  final VoidCallback? onTap;

  /// Status 213 — the bubble shows the photo, not its ≤32 KB thumbnail
  /// (it looked blurred next to Telegram / iMessage). Decoded at the size
  /// shown.
  final bool full;

  @override
  ConsumerState<EncryptedThumbnail> createState() => _EncryptedThumbnailState();
}

class _EncryptedThumbnailState extends ConsumerState<EncryptedThumbnail> {
  Uint8List? _blur;
  Uint8List? _thumb;
  Uint8List? _full;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loader = ref.read(mediaLoaderProvider);
    try {
      final info = await loader.info(widget.mediaJson);
      if (info.blurhash.isNotEmpty) {
        final blur = await loader.blurhash(info.blurhash, 32, 32);
        if (mounted) setState(() => _blur = blur);
      }
      if (info.hasThumbnail) {
        final thumb = await loader.fetch(widget.mediaJson, thumbnail: true);
        if (mounted) setState(() => _thumb = thumb);
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    if (!widget.full) return;
    try {
      final full = await loader.fetch(widget.mediaJson, thumbnail: false);
      if (mounted) setState(() => _full = full);
    } catch (_) {
      // The thumbnail stays; the photo opens full screen on a tap.
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _failed ? null : widget.onTap,
      child: LayoutBuilder(
        builder: (context, box) {
          // Decode at the size it's shown, not the source size (memory +
          // raster time on long media-heavy chats).
          final dpr = MediaQuery.devicePixelRatioOf(context);
          final w = box.maxWidth.isFinite ? (box.maxWidth * dpr).round() : null;
          return Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: DsPalette.art2A2D35),
              if (_blur != null) Image.memory(_blur!, fit: BoxFit.cover, gaplessPlayback: true),
              if (_thumb != null)
                Image.memory(
                  _thumb!,
                  key: const ValueKey('photo-thumb'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: w,
                ),
              if (_full != null)
                Image.memory(
                  _full!,
                  key: const ValueKey('photo-full'),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: w,
                  // Fades in over the thumbnail, no pop.
                  frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
                    opacity: sync || frame != null ? 1 : 0,
                    duration: DsMotion.base,
                    child: child,
                  ),
                ),
              if (_failed)
                Center(
                  child: Text(context.l10n.photoUnavailable, textAlign: TextAlign.center, style: DsTextArt.t13v3),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// "Save to Photos" — the user explicitly exports the decrypted photo
/// into the system library (outside Sinhron's protection from then on).
/// Asks for add-only library access. Returns false on denial / error.
Future<bool> savePhotoToLibrary(MediaLoader loader, String mediaJson) async {
  try {
    return await savePhotoBytes(await loader.fetch(mediaJson, thumbnail: false));
  } catch (_) {
    return false;
  }
}

/// A decrypted picture into the system's Photos (asks for access once).
Future<bool> savePhotoBytes(Uint8List bytes) async {
  try {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) return false;
    await Gal.putImageBytes(bytes, name: 'sinhron-${DateTime.now().millisecondsSinceEpoch}');
    return true;
  } catch (_) {
    return false;
  }
}
