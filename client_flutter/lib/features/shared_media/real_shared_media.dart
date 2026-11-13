// Shared media for a real chat — ADR-017 stage 5. Reads the chat's
// messages from the local (SQLCipher) DB and shows the encrypted media,
// newest first, under month headings (Telegram, owner 2026-11-03):
//   • Media — photos and videos, square tiles 3 a row; a video's tile has
//     its length. Opens the chat gallery (media_viewer/chat_gallery.dart).
//   • Files — a coloured tile by type, name, "size · date".
//   • Voice — voice messages and round video messages (ADR-048: a round
//     video is not a photo or a video): who, when, how long.
//   • Links — text messages with a link preview.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/people.dart';
import '../../core/services/media_loader.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_spinner.dart';
import '../chat_list/chat_data.dart' as chat_data;
import '../chat_view/link_preview_card.dart';
import '../chat_view/encrypted_media_bubbles.dart';
import '../chat_view/encrypted_photo.dart';
import '../media_viewer/chat_gallery.dart';
import '../media_viewer/gallery_pages.dart' show galleryRectTween;
import '../media_viewer/photo_gallery_screen.dart';
import '../video_note/video_note_circle.dart';
import '../voice/waveform.dart' show formatVoiceDuration;
import '../../l10n/l10n.dart';

enum SharedSection { media, files, voice, links }

/// Media rows of the given kinds, newest first. Rows without media JSON
/// (text, or legacy mock rows labelled photo/voice) are skipped.
List<core.StoredMessageSummary> mediaRowsOf(List<core.StoredMessageSummary> rows, Set<String> kinds) {
  final out = rows.where((r) => r.mediaJson != null && !r.deleted && kinds.contains(r.kind)).toList();
  out.sort((a, b) => b.tsUnix.compareTo(a.tsUnix));
  return out;
}

bool _isVideoNote(core.StoredMessageSummary r) => r.kind == 'video' && isVideoNoteJson(r.mediaJson);

/// What [section] lists, newest first.
List<core.StoredMessageSummary> sharedRowsOf(List<core.StoredMessageSummary> rows, SharedSection section) =>
    switch (section) {
      SharedSection.media => [
        for (final r in mediaRowsOf(rows, {'photo', 'video'}))
          if (!_isVideoNote(r)) r,
      ],
      SharedSection.files => mediaRowsOf(rows, {'document'}),
      SharedSection.voice => [
        for (final r in mediaRowsOf(rows, {'voice', 'video'}))
          if (r.kind == 'voice' || _isVideoNote(r)) r,
      ],
      // Text messages that carry a sender-made link preview (ADR-018).
      SharedSection.links => mediaRowsOf(rows, {'text'}),
    };

/// How many of each this chat really has — the tab counts.
Map<SharedSection, int> sharedCounts(List<core.StoredMessageSummary> rows) => {
  for (final s in SharedSection.values) s: sharedRowsOf(rows, s).length,
};

/// [rows] (newest first) cut into months: ("November 2026", rows).
List<(String, List<core.StoredMessageSummary>)> byMonth(List<core.StoredMessageSummary> rows) {
  final out = <(String, List<core.StoredMessageSummary>)>[];
  for (final r in rows) {
    final m = chat_data.formatMonthYear(r.tsUnix.toInt());
    if (out.isEmpty || out.last.$1 != m) out.add((m, []));
    out.last.$2.add(r);
  }
  return out;
}

String _when(core.StoredMessageSummary r) =>
    '${chat_data.formatDaySeparator(r.tsUnix.toInt())}, ${chat_data.formatMessageTime(r.tsUnix.toInt())}';

class RealSharedMedia extends ConsumerWidget {
  const RealSharedMedia({
    super.key,
    required this.chatId,
    required this.section,
    this.contactName = '',
    this.onShowInChat,
  });

  final String chatId;
  final SharedSection section;

  /// The other person in a 1:1 chat — the gallery's and voice rows' sender.
  final String contactName;
  final ValueChanged<String>? onShowInChat;

  String Function(core.StoredMessageSummary) _senderOf(BuildContext context, WidgetRef ref) {
    final names = ref.read(peerNamesProvider).value ?? const <String, String>{};
    final you = context.l10n.you;
    return (r) => r.isMine
        ? you
        : (r.senderId == null || r.senderId!.isEmpty ? contactName : displayNameOf(r.senderId!, names));
  }

  /// The gallery over the chat's photos and videos, or over one round video.
  void _open(BuildContext context, WidgetRef ref, List<core.StoredMessageSummary> rows, String mediaJson) {
    final note = isVideoNoteJson(mediaJson);
    final items = galleryItemsOf(
      note ? [for (final r in rows) if (r.mediaJson == mediaJson) r] : rows,
      senderOf: _senderOf(context, ref),
      heroPrefix: 'shared-',
      videoNotes: note,
    );
    final index = items.indexWhere((g) => g.mediaJson == mediaJson);
    if (index < 0) return;
    final show = onShowInChat;
    openPhotoGallery(
      context,
      items,
      index,
      actions: chatGalleryActions(
        context,
        ref,
        chatId: chatId,
        showInChat: show == null
            ? null
            : (item) {
                final wire = item.wireId;
                if (wire != null) show(wire);
              },
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final async = ref.watch(messagesProvider(chatId));
    ref.watch(peerNamesProvider); // voice rows name the sender
    return async.when(
      // Status 223 — a spinner while the chat's messages load, not a blank tab.
      loading: () => Center(child: DsSpinner(color: tokens.text3, size: 22)),
      error: (e, _) => _Empty(icon: CupertinoIcons.exclamationmark_circle, text: l.mediaLoadError),
      data: (rows) {
        final list = sharedRowsOf(rows, section);
        void open(String json) => _open(context, ref, rows, json);
        if (list.isEmpty) {
          return switch (section) {
            SharedSection.media => _Empty(icon: CupertinoIcons.photo_on_rectangle, text: l.noMediaYet),
            SharedSection.files => _Empty(icon: CupertinoIcons.doc, text: l.noFilesYet),
            SharedSection.voice => _Empty(icon: CupertinoIcons.mic, text: l.noVoiceYet),
            SharedSection.links => _Empty(icon: CupertinoIcons.link, text: l.noLinksYet),
          };
        }
        if (section == SharedSection.media) return _MediaGrid(rows: list, onOpen: open);
        final senderOf = _senderOf(context, ref);
        return _MonthList(
          rows: list,
          item: (r) => switch (section) {
            SharedSection.files => EncryptedDocument(mediaJson: r.mediaJson!, color: tokens.text, date: _when(r)),
            SharedSection.links => LinkPreviewCard(json: r.mediaJson!, isOut: false),
            _ =>
              _isVideoNote(r)
                  ? _VideoNoteRow(row: r, sender: senderOf(r), onOpen: open)
                  : EncryptedVoice(
                      key: ValueKey('shared-voice-${r.id}'),
                      mediaJson: r.mediaJson!,
                      color: tokens.accent,
                      glyph: DsPalette.white,
                      title: _WhoWhen(sender: senderOf(r), when: _when(r)),
                    ),
          },
        );
      },
    );
  }
}

/// "November 2026" over a month's items.
class _MonthHeader extends StatelessWidget {
  const _MonthHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, DsSpace.x2),
    child: Text(
      text,
      key: ValueKey('shared-month-$text'),
      style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: DsTheme.of(context).text2),
    ),
  );
}

class _MediaGrid extends StatelessWidget {
  const _MediaGrid({required this.rows, required this.onOpen});

  final List<core.StoredMessageSummary> rows;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: const ValueKey('shared-photo-grid'),
      slivers: [
        for (final (month, items) in byMonth(rows)) ...[
          SliverToBoxAdapter(child: _MonthHeader(month)),
          SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final r = items[i];
              final json = r.mediaJson!;
              return Hero(
                tag: 'shared-${r.id}',
                createRectTween: galleryRectTween,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    EncryptedThumbnail(key: ValueKey('shared-tile-${r.id}'), mediaJson: json, onTap: () => onOpen(json)),
                    if (r.kind == 'video')
                      Positioned(
                        right: DsSpace.x1,
                        bottom: DsSpace.x1,
                        child: IgnorePointer(child: _VideoLength(key: ValueKey('shared-video-${r.id}'), mediaJson: json)),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: DsSpace.x4)),
      ],
    );
  }
}

/// A video's length once its metadata is read.
class _Length extends ConsumerStatefulWidget {
  const _Length({required this.mediaJson, required this.builder});
  final String mediaJson;
  final Widget Function(BuildContext context, String length) builder;

  @override
  ConsumerState<_Length> createState() => _LengthState();
}

class _LengthState extends ConsumerState<_Length> {
  late final Future<core.MediaInfo> _info = ref.read(mediaLoaderProvider).info(widget.mediaJson);

  @override
  Widget build(BuildContext context) => FutureBuilder<core.MediaInfo>(
    future: _info,
    builder: (context, snap) {
      final ms = snap.data?.durationMs ?? 0;
      return widget.builder(context, ms > 0 ? formatVoiceDuration(ms) : '');
    },
  );
}

/// "▶ 0:14" on a video tile — a play icon, not a character.
class _VideoLength extends StatelessWidget {
  const _VideoLength({super.key, required this.mediaJson});
  final String mediaJson;

  @override
  Widget build(BuildContext context) => _Length(
    mediaJson: mediaJson,
    builder: (context, length) => Container(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
      decoration: BoxDecoration(color: DsPalette.black50, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.play_fill, size: 10, color: DsPalette.white),
          if (length.isNotEmpty) ...[
            const SizedBox(width: 3),
            Text(length, style: DsText.caption.copyWith(height: 1.0, color: DsPalette.white)),
          ],
        ],
      ),
    ),
  );
}

/// Files, voice and links: rows under month headings.
class _MonthList extends StatelessWidget {
  const _MonthList({required this.rows, required this.item});
  final List<core.StoredMessageSummary> rows;
  final Widget Function(core.StoredMessageSummary row) item;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: DsSpace.x4),
      children: [
        for (final (month, items) in byMonth(rows)) ...[
          _MonthHeader(month),
          for (final r in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.gutter, vertical: DsSpace.x2),
              child: Align(alignment: Alignment.centerLeft, child: item(r)),
            ),
        ],
      ],
    );
  }
}

/// "Maria            Today, 14:22" — over a voice or video message row.
class _WhoWhen extends StatelessWidget {
  const _WhoWhen({required this.sender, required this.when});
  final String sender;
  final String when;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            sender,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
          ),
        ),
        const SizedBox(width: 8),
        Text(when, style: DsText.footnote.copyWith(color: tokens.text3)),
      ],
    );
  }
}

/// A round video message in Voice: its circle, who and when, how long.
class _VideoNoteRow extends StatelessWidget {
  const _VideoNoteRow({required this.row, required this.sender, required this.onOpen});
  final core.StoredMessageSummary row;
  final String sender;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final json = row.mediaJson!;
    return GestureDetector(
      key: ValueKey('shared-note-${row.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpen(json),
      child: Row(
        children: [
          SizedBox(
            width: 38,
            height: 38,
            child: Hero(
              tag: 'shared-${row.id}',
              createRectTween: galleryRectTween,
              child: VideoNoteCircle(key: ValueKey('shared-round-${row.id}'), child: EncryptedThumbnail(mediaJson: json)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _WhoWhen(sender: sender, when: _when(row)),
                const SizedBox(height: 2),
                _Length(
                  mediaJson: json,
                  builder: (context, length) => Text(
                    [context.l10n.videoMessage, if (length.isNotEmpty) length].join(' · '),
                    style: DsText.footnote.copyWith(color: tokens.text3),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A calm empty tab: an icon and one line.
class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Center(
      key: const ValueKey('shared-empty'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
              child: Icon(icon, size: 32, color: tokens.text3),
            ),
            const SizedBox(height: DsSpace.x3),
            Text(text, textAlign: TextAlign.center, style: DsText.callout.copyWith(color: tokens.text2)),
          ],
        ),
      ),
    );
  }
}
