// Link preview card under a text message — UI backlog §3 item 31,
// ADR-018. Built by the sender; we only render it (and never fetch the
// site). Tap opens the link through the chat's "Open link?" sheet.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_loader.dart';
import '../../src/rust/api/simple.dart' as core;

class LinkPreviewCard extends ConsumerStatefulWidget {
  const LinkPreviewCard({super.key, required this.json, required this.isOut, this.onOpen});

  final String json;
  final bool isOut;
  final ValueChanged<String>? onOpen;

  @override
  ConsumerState<LinkPreviewCard> createState() => _LinkPreviewCardState();
}

class _LinkPreviewCardState extends ConsumerState<LinkPreviewCard> {
  core.LinkPreviewInfo? _info;
  Uint8List? _image;
  bool _imageFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loader = ref.read(linkPreviewLoaderProvider);
    try {
      final info = await loader.info(widget.json);
      if (!mounted) return;
      setState(() => _info = info);
      if (info.hasImage) {
        // No picture within 10 s (offline) → its kept place closes.
        final img = await loader.image(widget.json).timeout(const Duration(seconds: 10));
        if (mounted) setState(() => _image = img);
      }
    } catch (_) {
      // Broken / offline → just no card (or no image); the text stays.
      if (mounted && _info != null) setState(() => _imageFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null) return const SizedBox.shrink();
    final tokens = DsTheme.of(context);
    final fg = widget.isOut ? tokens.bubbleOutText : tokens.text;
    final sub = widget.isOut ? tokens.bubbleOutMeta : tokens.text2;
    final stripe = tokens.accent;
    return GestureDetector(
      key: const ValueKey('link-preview'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.onOpen == null ? null : () => widget.onOpen!(info.url),
      child: Container(
        margin: const EdgeInsets.only(top: DsSpace.x1h5, bottom: DsSpace.x0h5),
        padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.x1h5, DsSpace.x2h5, DsSpace.x2),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: widget.isOut ? fg.withValues(alpha: 0.08) : tokens.accentSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: stripe, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              info.domain,
              style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: stripe),
            ),
            const SizedBox(height: 2),
            Text(
              info.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: fg),
            ),
            if (info.description.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                info.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: DsText.subhead.copyWith(color: sub),
              ),
            ],
            AnimatedSize(
              duration: DsMotion.of(context, DsMotion.base),
              curve: DsMotion.enter,
              child: _image == null
                  // The picture's place is kept while it loads (no jump).
                  ? SizedBox(width: double.infinity, height: info.hasImage && !_imageFailed ? DsSpace.x2 + 140 : null)
                  : Padding(
                      padding: const EdgeInsets.only(top: DsSpace.x2),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          _image!,
                          key: const ValueKey('link-preview-image'),
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: 140,
                          cacheWidth: (280 * MediaQuery.devicePixelRatioOf(context)).round(),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
