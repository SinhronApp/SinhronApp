// Outgoing media bubble while encrypting/uploading — ADR-017.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/chat_providers.dart' show kVideoNoteLabel;
import '../../core/providers/pending_media.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_shared_glyphs.dart';

/// Outgoing media still encrypting/uploading (with %), or failed with
/// retry.
class PendingMediaBubble extends ConsumerStatefulWidget {
  final PendingMedia item;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  /// × — stop the upload and drop it (owner, 2026-10-18: a send couldn't
  /// be called back while it uploaded or waited for a connection).
  final VoidCallback? onCancel;

  const PendingMediaBubble({
    super.key,
    required this.item,
    required this.onRetry,
    required this.onDismiss,
    this.onCancel,
  });

  @override
  ConsumerState<PendingMediaBubble> createState() => PendingMediaBubbleState();
}

class PendingMediaBubbleState extends ConsumerState<PendingMediaBubble> {
  Timer? _poll;
  double _progress = -1;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    _tick();
  }

  void _tick() {
    final wireId = widget.item.wireId;
    if (!mounted || wireId == null || widget.item.state != PendingMediaState.sending) return;
    final p = ref.read(uploadProgressProvider)(wireId);
    if (p != _progress) setState(() => _progress = p);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final item = widget.item;
    final failed = item.state == PendingMediaState.failed;
    final l = context.l10n;
    final what = switch (item.kind) {
      'photo' => l.whatPhoto,
      'sticker' => l.whatSticker,
      'voice' => l.whatVoice,
      'video' => item.label == kVideoNoteLabel ? l.whatVideoNote : l.whatVideo,
      _ => item.label,
    };
    final String text;
    if (failed) {
      text = l.notSentRetry(what);
    } else if (_progress > 0) {
      text = l.sendingPercent(what, (_progress * 100).floor());
    } else if (_progress == 0) {
      text = l.preparing(what);
    } else {
      text = l.sending(what);
    }
    return Align(
      alignment: Alignment.centerRight,
      child: GestureDetector(
        key: ValueKey('pending-${item.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: failed ? widget.onRetry : null,
        onLongPress: failed ? widget.onDismiss : null,
        child: Container(
          margin: const EdgeInsets.fromLTRB(DsSpace.x15, DsSpace.x1, DsSpace.x3, DsSpace.x1),
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3, vertical: DsSpace.nudge9),
          decoration: BoxDecoration(
            color: failed ? DsPalette.artE5484Da22 : tokens.bgSoft,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(text, style: DsText.callout.copyWith(color: failed ? DsPalette.alert : tokens.text2)),
              ),
              if (widget.onCancel != null) ...[
                const SizedBox(width: DsSpace.x2),
                Semantics(
                  button: true,
                  label: l.cancelSending,
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: ValueKey('pending-cancel-${item.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: failed ? widget.onDismiss : widget.onCancel,
                    // A finger-sized target around a small ×.
                    child: Padding(
                      padding: const EdgeInsets.all(DsSpace.x1),
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: failed ? DsPalette.alert : tokens.text3,
                        ),
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CustomPaint(painter: DsXmarkGlyph(color: tokens.bg)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
