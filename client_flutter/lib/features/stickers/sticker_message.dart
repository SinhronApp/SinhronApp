// Stickers in the chat — ADR-049: a sticker message (big, no bubble — the
// bubble code puts the time pill under it), and a lone emoji that has a
// built-in animation plays it once (a tap plays it again), like Telegram.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/stickers.dart' as core;
import 'sticker_store.dart';
import 'sticker_view.dart';

/// Side of a sticker in the chat.
const double kStickerMessageSize = 168;

class StickerMessage extends ConsumerStatefulWidget {
  const StickerMessage({super.key, required this.mediaJson, this.size = kStickerMessageSize, this.onTap});
  final String mediaJson;
  final double size;

  /// Open its pack ("Add pack").
  final VoidCallback? onTap;

  @override
  ConsumerState<StickerMessage> createState() => _StickerMessageState();
}

class _StickerMessageState extends ConsumerState<StickerMessage> {
  late final Future<core.StickerMeta> _meta = ref.read(stickerStoreProvider).meta(widget.mediaJson);

  /// The still it carries: shown at once while the sticker loads, and
  /// instead of it where it can't play (a video sticker on iPhone) or
  /// didn't load — the emoji only if there's no still at all.
  late final Future<Uint8List?> _still = ref.read(stickerStoreProvider).fetchStill(widget.mediaJson);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('sticker-message'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: FutureBuilder<core.StickerMeta>(
        future: _meta,
        builder: (context, snap) {
          final m = snap.data;
          if (m == null) return SizedBox.square(dimension: widget.size);
          return FutureBuilder<Uint8List?>(
            future: _still,
            builder: (context, still) => StickerView(
              cacheKey: 'msg:${widget.mediaJson.hashCode}:${widget.mediaJson.length}',
              format: m.format,
              load: () => ref.read(stickerStoreProvider).fetchSticker(widget.mediaJson),
              size: widget.size,
              emoji: m.emoji,
              preview: still.data,
              // Still on its way: wait for it rather than flash the emoji.
              stillPending: still.connectionState != ConnectionState.done,
            ),
          );
        },
      ),
    );
  }
}

/// A lone emoji: its built-in animation (once, again on tap), or [fallback]
/// when there is none.
class AnimatedJumboEmoji extends ConsumerStatefulWidget {
  const AnimatedJumboEmoji({super.key, required this.emoji, required this.fallback, this.size = 104});
  final String emoji;
  final Widget fallback;
  final double size;

  @override
  ConsumerState<AnimatedJumboEmoji> createState() => _AnimatedJumboEmojiState();
}

class _AnimatedJumboEmojiState extends ConsumerState<AnimatedJumboEmoji> {
  final _view = GlobalKey<StickerViewState>();

  @override
  Widget build(BuildContext context) {
    final packs = ref.watch(builtinStickerPacksProvider).value;
    final s = packs == null ? null : animatedEmojiFor(packs, widget.emoji);
    if (s == null) return widget.fallback;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _view.currentState?.replay(),
      child: StickerView.of(s, key: _view, size: widget.size, repeat: false),
    );
  }
}
