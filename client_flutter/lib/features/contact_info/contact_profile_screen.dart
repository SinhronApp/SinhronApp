// A person's profile (ADR-052) — from the Contacts tab, a group's member
// list, anywhere a person is shown without "their chat" around them.
//
// Reads what this device knows about [peerId] (name, photo, bio, presence,
// our personal chat, groups we share, contact / favourite / blocked) and
// fills [ContactProfileView]. Without a personal chat (deleted, or never
// started) "Message" starts one; calls, the safety number and media need it.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/message_actions.dart' show peopleProvider;
import '../../core/providers/people.dart';
import '../../core/providers/presence.dart';
import '../../core/providers/settings_providers.dart' show contactAliasesProvider;
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_name_sheet.dart';
import '../chat_info/chat_info_screen.dart' show chatMembersProvider;
import '../chat_list/chat_data.dart';
import '../chat_view/encrypted_photo.dart' show savePhotoBytes;
import '../documents/document_share.dart' show shareDecryptedFile, shareOrigin;
import '../media_viewer/media_viewer_screen.dart';
import '../verify/verify_contact.dart';
import 'contact_info_screen.dart';
import 'share_contact.dart';

/// Our accepted personal chat with [peerId], if there is one.
ChatPreview? personalChatWith(List<ChatPreview> chats, String peerId) {
  final key = peerId.toLowerCase();
  return chats
      .where((c) => !c.group && !c.request && c.id != null && c.peerId?.toLowerCase() == key)
      .firstOrNull;
}

/// The groups [peerId] and I are both in (from each group's MLS members).
List<ContactCommonGroup> commonGroupsOf(WidgetRef ref, String peerId) {
  final key = peerId.toLowerCase();
  final chats = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
  return [
    for (final c in chats)
      if (c.group && c.id != null)
        if (ref.watch(chatMembersProvider(c.id!)).value case final members?)
          if (members.any((m) => m.toLowerCase() == key))
            ContactCommonGroup(chatId: c.id!, name: c.name, members: members.length),
  ];
}

/// Their photo full screen (owner, 2026-10-18), over whatever is open.
void openAvatarFullScreen(BuildContext context, String name, Uint8List photo) {
  Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: DsMotion.of(context, DsMotion.base),
      reverseTransitionDuration: DsMotion.of(context, DsMotion.base),
      pageBuilder: (ctx, _, _) => MediaViewerScreen(
        senderName: name,
        date: '',
        onClose: () => Navigator.of(ctx).pop(),
        image: Hero(tag: 'avatar-full', child: Image.memory(photo, fit: BoxFit.contain, gaplessPlayback: true)),
        // Status 213 — really shared / saved (it only flashed a notice).
        share: () => shareDecryptedFile(photo, fileName: 'photo.jpg', mimeType: 'image/jpeg', origin: shareOrigin()),
        save: () => savePhotoBytes(photo),
      ),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
}

class ContactProfileScreen extends ConsumerWidget {
  const ContactProfileScreen({
    super.key,
    required this.peerId,
    this.fallbackName = '',
    this.onBack,
    this.onMessage,
    this.onCall,
    this.onSafetyNumber,
    this.onSharedMedia,
    this.onOpenGroup,
  });

  /// Identity key (hex).
  final String peerId;

  /// Shown until anything better is known (the row they were tapped in).
  final String fallbackName;
  final VoidCallback? onBack;

  /// Open our chat, or start one ([chatId] null).
  final void Function(String? chatId, String name)? onMessage;
  final void Function(String chatId, String name, bool video)? onCall;
  final void Function(String chatId, String name)? onSafetyNumber;
  final void Function(String chatId, String name)? onSharedMedia;
  final void Function(String chatId, String name)? onOpenGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final key = peerId.toLowerCase();
    final chats = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
    final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
    final record = (ref.watch(contactsProvider).value ?? const <ContactRecord>[])
        .where((c) => c.peerId.toLowerCase() == key)
        .firstOrNull;
    final blocked = (ref.watch(blockedPeersProvider).value ?? const <String>{}).any((b) => b.toLowerCase() == key);
    final chat = personalChatWith(chats, key);
    final chatId = chat?.id;
    final name =
        names[key] ??
        names[peerId] ??
        (record != null && record.name.isNotEmpty ? record.name : null) ??
        chat?.name ??
        (fallbackName.isNotEmpty ? fallbackName : shortKey(key));
    // A value, so it redraws when "online" runs out.
    final seen = ref.watch(peerPresenceProvider.select((m) => presenceShown(l, m[key] ?? m[peerId])));
    final groups = commonGroupsOf(ref, key);
    final people = ref.read(peopleProvider);

    return ContactProfileView(
      name: name,
      keyLabel: shortKey(key),
      status: blocked ? l.chatInfoBlocked : seen.label,
      online: !blocked && seen.online,
      photo: ref.watch(peerAvatarsProvider).value?[key],
      bio: ref.watch(peerBiosProvider).value?[key] ?? '',
      verified: chatId != null && ref.watch(verifyStateProvider(chatId)).value == VerifyState.verified,
      isContact: record != null,
      favourite: record?.favourite ?? false,
      blocked: blocked,
      commonGroups: groups,
      onBack: onBack,
      onPhoto: () {
        final photo = ref.read(peerAvatarsProvider).value?[key];
        if (photo != null) openAvatarFullScreen(context, name, photo);
      },
      onMessage: blocked || onMessage == null ? null : () => onMessage!(chatId, name),
      onCall: blocked || chatId == null || onCall == null ? null : () => onCall!(chatId, name, false),
      onVideo: blocked || chatId == null || onCall == null ? null : () => onCall!(chatId, name, true),
      onSafetyNumber: chatId == null || onSafetyNumber == null ? null : () => onSafetyNumber!(chatId, name),
      onSharedMedia: chatId == null || onSharedMedia == null ? null : () => onSharedMedia!(chatId, name),
      onOpenGroup: onOpenGroup == null
          ? null
          : (id) => onOpenGroup!(id, groups.where((g) => g.chatId == id).firstOrNull?.name ?? ''),
      onEditName: () => editContactName(context, ref, key, name),
      onShare: () => shareContactInChat(context, ref, peerId: key),
      onToggleFavourite: () => people.setFavourite(key, !(record?.favourite ?? false)),
      onToggleContact: () => toggleContact(context, ref, key, name, isContact: record != null),
      onToggleBlock: () => _toggleBlock(context, ref, key, name, blocked: blocked, personalChatId: chatId),
    );
  }

  Future<void> _toggleBlock(
    BuildContext context,
    WidgetRef ref,
    String peer,
    String name, {
    required bool blocked,
    String? personalChatId,
  }) async {
    final people = ref.read(peopleProvider);
    if (!blocked) {
      final ok = await showDsActionSheet<bool>(
        context,
        title: context.l10n.chatInfoBlockConfirm(name),
        actions: [DsSheetAction(context.l10n.chatInfoBlock, true, destructive: true)],
      );
      if (ok != true) return;
    }
    await people.setBlocked(peer, !blocked, personalChatId: personalChatId);
  }
}

/// "Add to contacts" / "Remove from contacts" (asks first; the chat stays).
Future<void> toggleContact(
  BuildContext context,
  WidgetRef ref,
  String peer,
  String name, {
  required bool isContact,
}) async {
  final people = ref.read(peopleProvider);
  if (!isContact) {
    await people.addContact(peer, name: name);
    return;
  }
  final ok = await showDsActionSheet<bool>(
    context,
    title: context.l10n.contactRemoveConfirm(name),
    actions: [DsSheetAction(context.l10n.contactRemove, true, destructive: true)],
  );
  if (ok == true) await people.removeContact(peer);
}

/// Owner, 2026-11-03 — "Edit name": my own name for [peer], on this device
/// only ([contactAliasesProvider]). Saving their own name back, or an empty
/// one, or "Restore" clears it — then their own name shows again.
Future<void> editContactName(BuildContext context, WidgetRef ref, String peer, String current) async {
  final key = peer.toLowerCase();
  final aliased = (await ref.read(contactAliasesProvider.future)).containsKey(key);
  var own = <String, String>{};
  try {
    own = await ref.read(peopleStoreProvider).names();
  } catch (_) {}
  final theirs = own[key] ?? own[peer];
  if (!context.mounted) return;
  final picked = await showNameSheet(context, current: current, restore: aliased ? displayNameOf(key, own) : null);
  if (picked == null || (!aliased && picked.trim() == current)) return;
  await ref.read(contactAliasesProvider.notifier).set(key, picked.trim() == theirs ? '' : picked);
}
