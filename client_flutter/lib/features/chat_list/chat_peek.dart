// The long-press peek of a chat (owner, 2026-11-03: "like Telegram's"): a
// tall card in the chat's own look — its wallpaper, the person's photo and
// name, and the last [kPeekMessages] messages as bubbles, the newest at the
// bottom, scrolling. Photos and videos are their thumbnails, a round video
// a small circle, voice a play mark and its length, a file its icon and
// name. It only reads the local store: nothing is marked read, no receipt
// goes out.

import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/appearance.dart' show ChatWallpaper;
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/contact_qr.dart' show contactCardOf;
import '../../core/providers/chat_messages.dart';
import '../../core/providers/message_actions.dart' show systemLineText;
import '../../core/providers/people.dart';
import '../../core/rich_text.dart';
import '../../core/services/media_loader.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_avatar.dart';
import '../chat_view/encrypted_photo.dart' show EncryptedThumbnail;
import '../chat_view/message_text.dart';
import '../stickers/sticker_message.dart';
import '../video_note/video_note_bubble.dart' show isVideoNoteJson;
import '../voice/waveform.dart' show formatVoiceDuration;
import 'chat_data.dart';

/// How many of the newest messages the peek shows.
const kPeekMessages = 30;

class ChatPeekPreview extends ConsumerStatefulWidget {
  const ChatPeekPreview({super.key, required this.chat});
  final ChatPreview chat;

  @override
  ConsumerState<ChatPeekPreview> createState() => _ChatPeekPreviewState();
}

class _ChatPeekPreviewState extends ConsumerState<ChatPeekPreview> {
  late final Future<List<core.StoredMessageSummary>> _recent = ref.read(messagePageFetcherProvider)(
    widget.chat.id!,
    limit: kPeekMessages,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final chat = widget.chat;
    final h = MediaQuery.sizeOf(context).height;
    final photo = chat.avatar ?? (chat.group ? null : peerAvatarOf(ref, chat.peerId));
    return SizedBox(
      key: const ValueKey('chat-peek'),
      // Most of a phone's screen; a sensible card on an iPad. The sheet
      // gives it less when its actions need the room.
      height: math.min(h * 0.58, 620),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1h5, DsSpace.x4, DsSpace.x2h5),
            child: Row(
              children: [
                DsAvatar(name: chat.name, size: 40, group: chat.group, image: photo, saved: chat.saved),
                const SizedBox(width: DsSpace.x3),
                Expanded(
                  child: Text(
                    chat.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.headline.copyWith(color: tokens.text),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: tokens.divider),
          Expanded(
            child: ColoredBox(
              color: tokens.bg,
              child: ChatWallpaper(
                chatId: chat.id,
                child: FutureBuilder<List<core.StoredMessageSummary>>(
                  future: _recent,
                  builder: (context, snap) {
                    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
                    final rows = [
                      for (final m in snap.data ?? const <core.StoredMessageSummary>[])
                        if (m.expireAt == null || m.expireAt!.toInt() > now) m,
                    ];
                    if (rows.isEmpty) {
                      return Center(
                        child: Text(
                          snap.connectionState == ConnectionState.done ? context.l10n.noMessagesYet : '',
                          style: DsText.callout.copyWith(color: tokens.text3),
                        ),
                      );
                    }
                    return ListView.builder(
                      key: const ValueKey('chat-peek-list'),
                      reverse: true,
                      // Always takes the drag: it scrolls, the sheet stays.
                      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x2h5),
                      itemCount: rows.length,
                      itemBuilder: (_, i) => _PeekBubble(rows[rows.length - 1 - i]),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One message of the peek, drawn like the chat draws it, smaller.
class _PeekBubble extends StatelessWidget {
  const _PeekBubble(this.m);
  final core.StoredMessageSummary m;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final mine = m.isMine;
    final time = formatMessageTime(m.tsUnix.toInt());
    if (m.kind == 'system') {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: DsSpace.x1h5),
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x1),
          decoration: BoxDecoration(
            color: tokens.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(tokens.radiusPill),
          ),
          child: Text(
            systemLineText(l, m.body),
            textAlign: TextAlign.center,
            style: DsText.footnote.copyWith(color: tokens.text2),
          ),
        ),
      );
    }
    final fg = mine ? tokens.bubbleOutText : tokens.text;
    final meta = mine ? tokens.bubbleOutMeta : tokens.text3;
    final fill = mine ? tokens.bubbleOut : tokens.bubbleIn;
    final media = m.deleted ? null : m.mediaJson;
    final caption = m.deleted ? '' : m.body;
    final radius = BorderRadius.circular(tokens.radiusBubble);

    Widget bubble({required Widget child, EdgeInsets? padding}) => Container(
      padding: padding ?? const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x1h5, DsSpace.x3, DsSpace.x1h5),
      decoration: BoxDecoration(color: fill, borderRadius: radius),
      child: child,
    );
    Widget words(String text, {List<TextEntity>? entities}) => MessageText(
      text: text,
      entities: entities,
      style: DsText.body.copyWith(color: fg),
      linkColor: mine ? fg : tokens.accent,
      trailing: TextSpan(
        children: [
          const TextSpan(text: '   '),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Text(time, style: DsText.caption.copyWith(color: meta)),
          ),
        ],
      ),
    );
    List<TextEntity>? entities() => m.entitiesJson == null ? null : FormattedText.parseEntities(m.entitiesJson);
    Widget timePill() => Container(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
      decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(tokens.radiusPill)),
      child: Text(time, style: DsText.caption.copyWith(color: DsPalette.white)),
    );

    final Widget content;
    if (m.deleted) {
      content = bubble(
        child: Text(
          l.messageDeleted,
          style: DsText.body.copyWith(color: meta, fontStyle: FontStyle.italic),
        ),
      );
    } else if (media != null && m.kind == 'video' && isVideoNoteJson(media)) {
      content = Stack(
        alignment: Alignment.bottomCenter,
        children: [
          ClipOval(
            child: SizedBox.square(
              key: const ValueKey('peek-round'),
              dimension: 120,
              child: EncryptedThumbnail(mediaJson: media),
            ),
          ),
          Padding(padding: const EdgeInsets.only(bottom: DsSpace.x1h5), child: timePill()),
        ],
      );
    } else if (media != null && (m.kind == 'photo' || m.kind == 'video')) {
      final picture = SizedBox(
        width: 220,
        height: 165,
        child: Stack(
          fit: StackFit.expand,
          children: [
            EncryptedThumbnail(key: const ValueKey('peek-thumb'), mediaJson: media),
            if (m.kind == 'video')
              Center(
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(color: DsPalette.black40, shape: BoxShape.circle),
                  child: const Icon(CupertinoIcons.play_fill, size: 22, color: DsPalette.white),
                ),
              ),
            if (caption.isEmpty) Positioned(right: DsSpace.x1h5, bottom: DsSpace.x1h5, child: timePill()),
          ],
        ),
      );
      content = caption.isEmpty
          ? ClipRRect(borderRadius: radius, child: picture)
          : Container(
              width: 220,
              decoration: BoxDecoration(color: fill, borderRadius: radius),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  picture,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x1h5, DsSpace.x3, DsSpace.x1h5),
                    child: words(caption, entities: entities()),
                  ),
                ],
              ),
            );
    } else if (media != null && m.kind == 'sticker') {
      content = Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          IgnorePointer(child: StickerMessage(mediaJson: media, size: 110)),
          timePill(),
        ],
      );
    } else if (media != null && (m.kind == 'voice' || m.kind == 'document')) {
      final voice = m.kind == 'voice';
      content = bubble(
        padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x2, DsSpace.x3, DsSpace.x2),
        child: _MediaLine(
          mediaJson: media,
          voice: voice,
          fg: fg,
          meta: meta,
          badge: tokens.accent,
          time: time,
        ),
      );
    } else {
      final card = contactCardOf(m.body);
      content = bubble(
        child: card != null
            ? words(mediaPreviewFallback(m.body, 'text'))
            : words(m.body.isEmpty ? mediaPreviewFallback('', m.kind) : m.body, entities: entities()),
      );
    }
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: DsSpace.x1),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(MediaQuery.sizeOf(context).width * 0.76, 320)),
          child: content,
        ),
      ),
    );
  }
}

/// Voice: a play mark and its length; a file: its icon and name. Read
/// from the media's own description (local, no download).
class _MediaLine extends ConsumerStatefulWidget {
  const _MediaLine({
    required this.mediaJson,
    required this.voice,
    required this.fg,
    required this.meta,
    required this.badge,
    required this.time,
  });
  final String mediaJson;
  final bool voice;
  final Color fg;
  final Color meta;
  final Color badge;
  final String time;

  @override
  ConsumerState<_MediaLine> createState() => _MediaLineState();
}

class _MediaLineState extends ConsumerState<_MediaLine> {
  late final Future<core.MediaInfo> _info = ref.read(mediaLoaderProvider).info(widget.mediaJson);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return FutureBuilder<core.MediaInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        final label = widget.voice
            ? (info != null && info.durationMs > 0 ? formatVoiceDuration(info.durationMs) : l.kindVoice)
            : (info != null && info.fileName.isNotEmpty ? info.fileName : l.document);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: widget.badge,
                shape: widget.voice ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: widget.voice ? null : BorderRadius.circular(DsSpace.x2),
              ),
              child: Icon(
                widget.voice ? CupertinoIcons.play_fill : CupertinoIcons.doc_fill,
                key: ValueKey(widget.voice ? 'peek-voice' : 'peek-document'),
                size: 18,
                color: DsTheme.of(context).accentText,
              ),
            ),
            const SizedBox(width: DsSpace.x2h5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DsText.callout.copyWith(color: widget.fg, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: DsSpace.x2h5),
            Text(widget.time, style: DsText.caption.copyWith(color: widget.meta)),
          ],
        );
      },
    );
  }
}
