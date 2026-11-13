// "Share contact" (owner, 2026-11-03: like Telegram) — from a profile or a
// personal chat's info: pick a chat, and the person's contact QR text goes
// there as one ordinary message. The chat shows it as a card with "Message"
// (chat_view_screen.dart, `contactCardOf`); no new wire format.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_notice.dart';
import '../../core/contact_qr.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/people.dart';
import '../../core/providers/saved_messages.dart';
import '../../core/server_address.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../chat_list/chat_data.dart';
import '../chat_view/forward_sheet.dart';

/// Send [peerId]'s contact card to a chat picked in the forward sheet —
/// with the name they chose, never mine for them ("only you see this";
/// security-review-2026-11 app-surface:5).
Future<void> shareContactInChat(BuildContext context, WidgetRef ref, {required String peerId}) async {
  final l = context.l10n;
  final key = peerId.toLowerCase();
  final all = ref.read(chatsProvider).value ?? const <ChatPreview>[];
  final chats = [
    savedChatEntry(all),
    // Not back into their own chat.
    ...all.where((c) => c.id != null && !c.archived && !c.saved && !(!c.group && c.peerId?.toLowerCase() == key)),
  ];
  final picked = await showForwardSheet(
    context,
    withPhotos(chats, ref.read(peerAvatarsProvider).value ?? const {}),
    title: l.shareContactTo,
  );
  if (picked == null) return;
  try {
    final toId = await ref.read(savedMessagesProvider).resolve(picked.id!);
    final host = serverHostOf(await ref.read(serverUrlProvider.future));
    final own = await ref.read(peopleStoreProvider).names().catchError((Object _) => const <String, String>{});
    await sendMessage(ref, chatId: toId, body: contactQrPayload(key, host, name: own[key] ?? own[peerId] ?? ''));
  } catch (_) {
    // No connection: the message waits in that chat ("Not sent") and goes
    // out by itself when it is back. Blocked / Saved not made: nothing sent.
    appNotice.value = l.statusFailed;
    return;
  }
  showDone(l.contactSent);
}
