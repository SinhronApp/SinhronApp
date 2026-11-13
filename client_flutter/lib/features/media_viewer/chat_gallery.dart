// The gallery over a real chat's photos and videos — the chat and its
// "Media & files" open the same viewer with the same actions (forward,
// delete, show in chat).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_notice.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/message_actions.dart';
import '../../core/providers/people.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../chat_list/chat_data.dart' as chat_data;
import '../chat_view/forward_sheet.dart';
import '../video_note/video_note_circle.dart' show isVideoNoteJson;
import 'photo_gallery_screen.dart';

/// Photos and videos of [rows], oldest first (same-second album photos
/// keep their stored order). [senderOf] names who sent each one. Round
/// video messages (ADR-048) aren't photos or videos — swiping through the
/// chat's pictures skips them (owner, 2026-11-03); [videoNotes] keeps them
/// (shared media opens one on its own).
List<GalleryItem> galleryItemsOf(
  List<core.StoredMessageSummary> rows, {
  required String Function(core.StoredMessageSummary row) senderOf,
  String heroPrefix = 'photo-',
  bool videoNotes = false,
}) {
  final media = [
    for (var i = 0; i < rows.length; i++)
      if ((rows[i].kind == 'photo' || rows[i].kind == 'video') &&
          !rows[i].deleted &&
          rows[i].mediaJson != null &&
          (videoNotes || !(rows[i].kind == 'video' && isVideoNoteJson(rows[i].mediaJson))))
        (i, rows[i]),
  ];
  media.sort((a, b) {
    final c = a.$2.tsUnix.compareTo(b.$2.tsUnix);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  return [
    for (final (_, r) in media)
      GalleryItem(
        mediaJson: r.mediaJson!,
        heroTag: '$heroPrefix${r.id}',
        caption: r.body,
        sender: senderOf(r),
        date: '${chat_data.formatDaySeparator(r.tsUnix.toInt())} · ${chat_data.formatMessageTime(r.tsUnix.toInt())}',
        isVideo: r.kind == 'video',
        round: r.kind == 'video' && isVideoNoteJson(r.mediaJson),
        rowId: r.id,
        wireId: r.wireId,
        isMine: r.isMine,
        sentTs: r.tsUnix.toInt(),
      ),
  ];
}

/// Forward / delete / show-in-chat for [chatId]. [context] is the screen
/// under the gallery (its sheets open over the gallery); [ref] that
/// screen's.
GalleryActions chatGalleryActions(
  BuildContext context,
  WidgetRef ref, {
  required String chatId,
  void Function(GalleryItem item)? showInChat,
}) {
  return GalleryActions(
    showInChat: showInChat,
    forward: (item) async {
      final chats = (ref.read(chatsProvider).value ?? const <chat_data.ChatPreview>[])
          .where((c) => c.id != null && c.id != chatId && !c.archived)
          .toList();
      final to = await showForwardSheet(context, withPhotos(chats, ref.read(peerAvatarsProvider).value ?? const {}));
      if (to == null) return null;
      try {
        await forwardMessage(
          ref,
          toChatId: to.id!,
          kind: item.isVideo ? 'video' : 'photo',
          text: item.caption,
          mediaJson: item.mediaJson,
        );
        return true;
      } catch (_) {
        return false;
      }
    },
    delete: (item) async {
      final rowId = item.rowId;
      if (rowId == null) return false;
      final sent = item.sentTs;
      final changeable =
          sent == null || DateTime.now().millisecondsSinceEpoch ~/ 1000 - sent <= kEditWindow.inSeconds;
      final forAll = item.isMine && item.wireId != null && changeable;
      final l = context.l10n;
      final picked = await showDsActionSheet<String>(
        context,
        title: l.deleteMessagesConfirm(1),
        actions: [
          if (forAll) DsSheetAction(l.deleteForEveryone, 'all', destructive: true),
          DsSheetAction(l.deleteForMe, 'me', destructive: true),
        ],
      );
      if (picked == null) return false;
      final actions = ref.read(messageActionsProvider);
      try {
        if (picked == 'all') {
          await actions.deleteForEveryone(chatId, item.wireId!);
        } else {
          await actions.deleteForMe(chatId, [rowId]);
        }
        return true;
      } catch (_) {
        appNotice.value = l.groupActionFailed; // "false" alone looked like "cancelled"
        return false;
      }
    },
  );
}
