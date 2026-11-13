// Chat info — the real "Info" screen for a chat (tech-debt 2.22 / 2.27).
//
// Replaces the demo contact / group info screens for real chats: no made-up
// phone numbers or bios — only what this device actually knows.
//
//   • Header: avatar, name, "N members" or "Personal chat".
//   • Members (groups): each person's own name (from their `profile`),
//     "you", verified mark; tap → their profile (photo, bio — owner,
//     2026-10-19), verify their safety number, or block them.
//   • Settings: disappearing messages, mute, own wallpaper, media & files.
//   • Personal chats: their bio, groups in common, add to / remove from
//     contacts (ADR-052 — contacts are their own list), safety number,
//     block / unblock.
//   • Groups (ADR-035): the admin renames the group and removes people;
//     anyone leaves. After a removal the chat stays, read-only.
//   • Delete chat (this device).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/appearance.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/chat_actions.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/message_actions.dart';
import '../../core/providers/people.dart';
import '../../core/providers/presence.dart';
import '../../core/services/net_service.dart';
import '../../features/chat_list/chat_data.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_avatar.dart';
import '../contact_info/contact_info_screen.dart' show ContactCommonGroup;
import '../contact_info/contact_profile_screen.dart'
    show commonGroupsOf, editContactName, openAvatarFullScreen, toggleContact;
import '../contact_info/share_contact.dart';
import '../../widgets/ds_verified_badge.dart';
import '../settings/_shared.dart';
import '../settings/appearance_screen.dart' show WallpaperGrid, wallpaperLabel;
import '../verify/verify_contact.dart';
import '../report/report_flow.dart';
import 'group_rename_screen.dart';

/// Members of a chat's MLS group (identity keys, hex). Faked in tests.
final chatMembersLoaderProvider = Provider<Future<List<String>> Function(String chatId)>(
  (ref) =>
      (chatId) => core.syncGroupMembers(groupIdHex: chatId),
);

final chatMembersProvider = FutureProvider.family<List<String>, String>((ref, chatId) async {
  try {
    return await ref.read(chatMembersLoaderProvider)(chatId);
  } catch (_) {
    return const [];
  }
});

/// My identity key (hex) — to mark "you" in member lists. Faked in tests.
final myIdentityProvider = Provider<String? Function()>(
  (ref) =>
      () => ref.read(netServiceProvider).myIdentityHex,
);

class ChatInfoScreen extends ConsumerWidget {
  const ChatInfoScreen({
    super.key,
    required this.chatId,
    this.onBack,
    this.onSharedMedia,
    this.onVerify,
    this.onDeleted,
    this.onAddMembers,
    this.onOpenGroup,
    this.onOpenProfile,
  });

  final String chatId;
  final VoidCallback? onBack;
  final VoidCallback? onSharedMedia;

  /// Open the safety number screen (peer = null for a personal chat).
  final void Function(String name, String? peerKeyHex)? onVerify;

  /// After "Delete chat" — leave the chat screens.
  final VoidCallback? onDeleted;

  /// ADR-034 — groups: pick people to add (one Commit to every member).
  final VoidCallback? onAddMembers;

  /// Personal chats: open a group we are both in.
  final void Function(String chatId, String name)? onOpenGroup;

  /// Groups: a member's profile (photo, bio, common groups) — there was
  /// no way to see what they wrote about themselves.
  final void Function(String peerId, String name)? onOpenProfile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final chat = (ref.watch(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.id == chatId).firstOrNull;
    final members = ref.watch(chatMembersProvider(chatId)).value ?? const <String>[];
    final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
    final blocked = ref.watch(blockedPeersProvider).value ?? const <String>{};
    final me = ref.read(myIdentityProvider)();
    final isGroup = chat?.group ?? members.length > 2;
    final name = chat?.name ?? '';
    final others = [
      for (final m in members)
        if (m != me) m,
    ];
    // Members not readable yet (MLS still loading): the chat knows its
    // person anyway — their bio and photo used to vanish then.
    final peer = isGroup
        ? null
        : others.length == 1
        ? others.single
        : (others.isEmpty && (chat?.peerId ?? '').isNotEmpty ? chat!.peerId!.toLowerCase() : null);
    final timer = chat?.disappearSecs ?? 0;
    final role = isGroup ? ref.watch(groupRoleProvider(chatId)).value : null;
    final active = role?.active ?? true;
    final canManage = role?.canManage(me) ?? false;
    final bio = peer == null ? '' : (ref.watch(peerBiosProvider).value?[peer.toLowerCase()] ?? '');
    final isContact =
        peer != null &&
        (ref.watch(contactsProvider).value ?? const <ContactRecord>[]).any(
          (c) => c.peerId.toLowerCase() == peer.toLowerCase(),
        );
    final common = peer == null ? const <ContactCommonGroup>[] : commonGroupsOf(ref, peer);
    final ownWallpaper = ref.watch(chatWallpaperProvider(chatId)).value ?? '';

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(title: l.chatInfoTitle, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x2, bottom: DsSpace.x6),
                children: [
                  _Header(
                    name: name,
                    subtitle: isGroup
                        // Members not readable (yet): no "0 members" — that read as everyone gone.
                        ? (!active ? l.groupNotMember : (members.isEmpty ? '' : l.contactGroupMembers(members.length)))
                        // ADR-031 — "online" / "last seen" when this contact shares it.
                        : (chat == null || chat.request || peer == null
                                  ? ''
                                  : ref.watch(peerPresenceProvider.select((m) => presenceLabel(l, m[peer]))))
                              .ifEmpty(l.chatInfoPersonal),
                    avatar: peer == null ? null : ref.watch(peerAvatarsProvider).value?[peer],
                    verified: !isGroup && ref.watch(verifyStateProvider(chatId)).value == VerifyState.verified,
                  ),
                  // ADR-052 — what they wrote about themselves.
                  if (bio.isNotEmpty)
                    SettingsSection(
                      title: l.contactAbout,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, DsSpace.x3),
                          child: SizedBox(
                            width: double.infinity,
                            child: Text(
                              bio,
                              key: const ValueKey('info-bio'),
                              style: DsText.body.copyWith(color: tokens.text),
                            ),
                          ),
                        ),
                      ],
                    ),
                  if (isGroup && active)
                    SettingsSection(
                      title: l.groupInfoMembers,
                      children: [
                        for (final (i, m) in members.indexed)
                          SettingsRow(
                            key: ValueKey('member-$m'),
                            label: m == me ? l.groupInfoMemberYou(names[m] ?? l.you) : (names[m] ?? l.chatInfoUnnamed),
                            value: blocked.contains(m)
                                ? l.chatInfoBlocked
                                : m == role?.admin
                                ? l.groupAdmin
                                : (m != me && _verified(ref, m) ? l.verifiedTitle : null),
                            onTap: m == me
                                ? null
                                : () => _memberSheet(context, ref, m, displayNameOf(m, names), canRemove: canManage),
                            isLast: !(onAddMembers != null && canManage) && i == members.length - 1,
                          ),
                        if (onAddMembers != null && canManage)
                          SettingsRow(
                            key: const ValueKey('info-add-member'),
                            glyph: CupertinoIcons.person_add,
                            tint: SettingsRowTint.download,
                            label: l.groupInfoAddMember,
                            onTap: onAddMembers,
                            isLast: true,
                          ),
                      ],
                    ),
                  SettingsSection(
                    children: [
                      SettingsRow(
                        key: const ValueKey('info-timer'),
                        glyph: CupertinoIcons.timer,
                        tint: SettingsRowTint.chats,
                        label: l.disappearingMessages,
                        value: timerChoiceLabel(l, timer),
                        onTap: () => _chooseTimer(context, ref, timer),
                      ),
                      SettingsRow(
                        key: const ValueKey('info-mute'),
                        glyph: CupertinoIcons.bell_slash,
                        tint: SettingsRowTint.notif,
                        label: l.mute,
                        toggle: chat?.muted ?? false,
                        onToggle: (v) => ref.read(chatActionsProvider).setMuted(chatId, v),
                      ),
                      // Owner, 2026-11-03 — this chat's own wallpaper.
                      SettingsRow(
                        key: const ValueKey('info-wallpaper'),
                        glyph: CupertinoIcons.photo,
                        tint: SettingsRowTint.appear,
                        label: l.wallpaper,
                        value: ownWallpaper.isEmpty ? null : wallpaperLabel(l, parseWallpaper(ownWallpaper)),
                        onTap: () => _chooseWallpaper(context, ref, ownWallpaper),
                      ),
                      SettingsRow(
                        key: const ValueKey('info-media'),
                        glyph: CupertinoIcons.photo_on_rectangle,
                        tint: SettingsRowTint.storage,
                        label: l.groupInfoMediaFiles,
                        onTap: onSharedMedia,
                        isLast: true,
                      ),
                    ],
                  ),
                  if (canManage)
                    SettingsSection(
                      children: [
                        SettingsRow(
                          key: const ValueKey('info-rename'),
                          glyph: CupertinoIcons.pencil,
                          tint: SettingsRowTint.appear,
                          label: l.groupRename,
                          value: name,
                          onTap: () => _rename(context, ref, name),
                          isLast: true,
                        ),
                      ],
                    ),
                  if (common.isNotEmpty)
                    SettingsSection(
                      title: l.contactGroupsInCommon(common.length),
                      children: [
                        for (final (i, g) in common.indexed)
                          SettingsRow(
                            key: ValueKey('info-group-${g.chatId}'),
                            label: g.name,
                            value: l.contactGroupMembers(g.members),
                            onTap: onOpenGroup == null ? null : () => onOpenGroup!(g.chatId, g.name),
                            isLast: i == common.length - 1,
                          ),
                      ],
                    ),
                  if (peer != null)
                    SettingsSection(
                      children: [
                        SettingsRow(
                          key: const ValueKey('info-edit-name'),
                          glyph: CupertinoIcons.pencil,
                          tint: SettingsRowTint.appear,
                          label: l.contactEditName,
                          onTap: () => editContactName(context, ref, peer, name),
                        ),
                        SettingsRow(
                          key: const ValueKey('info-contact'),
                          glyph: isContact ? CupertinoIcons.person_badge_minus : CupertinoIcons.person_badge_plus,
                          tint: SettingsRowTint.download,
                          label: isContact ? l.contactRemove : l.contactAdd,
                          onTap: () => toggleContact(context, ref, peer, name, isContact: isContact),
                        ),
                        SettingsRow(
                          key: const ValueKey('info-share-contact'),
                          glyph: CupertinoIcons.share,
                          tint: SettingsRowTint.chats,
                          label: l.shareContact,
                          onTap: () => shareContactInChat(context, ref, peerId: peer),
                        ),
                        SettingsRow(
                          key: const ValueKey('info-verify'),
                          glyph: CupertinoIcons.checkmark_shield,
                          tint: SettingsRowTint.privacy,
                          label: l.safetyNumberTitle,
                          onTap: onVerify == null ? null : () => onVerify!(name, null),
                        ),
                        SettingsRow(
                          key: const ValueKey('info-block'),
                          glyph: CupertinoIcons.hand_raised,
                          tint: SettingsRowTint.lock,
                          label: blocked.contains(peer) ? l.blockedUnblock : l.chatInfoBlock,
                          onTap: () => _toggleBlock(context, ref, peer, name, personalChat: true),
                        ),
                        // ADR-037 — report to the server's operator.
                        SettingsRow(
                          key: const ValueKey('info-report'),
                          glyph: CupertinoIcons.exclamationmark_bubble,
                          tint: SettingsRowTint.recovery,
                          label: l.reportAction,
                          onTap: () => reportPerson(context, ref, peer: peer, name: name, personalChatId: chatId),
                          isLast: true,
                        ),
                      ],
                    ),
                  SettingsSection(
                    children: [
                      if (isGroup && active)
                        SettingsRow(
                          key: const ValueKey('info-leave'),
                          glyph: CupertinoIcons.square_arrow_right,
                          tint: SettingsRowTint.danger,
                          label: l.groupLeave,
                          onTap: () => _leave(context, ref, name),
                          isLast: true,
                        )
                      else
                        SettingsRow(
                          key: const ValueKey('info-delete'),
                          glyph: CupertinoIcons.trash,
                          tint: SettingsRowTint.danger,
                          label: l.deleteChat,
                          onTap: () => _delete(context, ref, name),
                          isLast: true,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// This member's safety number was checked on this device and still matches.
  bool _verified(WidgetRef ref, String peer) =>
      ref.watch(verifyStateProvider(verifySubject(chatId, peer))).value == VerifyState.verified;

  Future<void> _chooseTimer(BuildContext context, WidgetRef ref, int current) async {
    final picked = await showDsActionSheet<int>(
      context,
      title: context.l10n.timerSheetTitle,
      actions: [
        for (final e in kTimerChoices.keys)
          DsSheetAction(timerChoiceLabel(context.l10n, e), e, checked: e == current),
      ],
    );
    if (picked == null || picked == current) return;
    unawaited(ref.read(messageActionsProvider).setTimer(chatId, picked).catchError((Object _) {}));
  }

  /// The same tiles as Settings → Appearance (no photo: there is one for
  /// all chats), plus "Same as all chats" to drop this chat's own.
  Future<void> _chooseWallpaper(BuildContext context, WidgetRef ref, String current) async {
    final l = context.l10n;
    final picked = await showDsActionSheet<String>(
      context,
      title: l.wallpaper,
      header: Builder(
        builder: (sheet) => WallpaperGrid(
          selected: current.isEmpty ? null : parseWallpaper(current),
          withPhoto: false,
          onPick: (w) => Navigator.of(sheet).pop(w.name),
        ),
      ),
      actions: [DsSheetAction(l.wallSameAsAll, '', checked: current.isEmpty)],
    );
    if (picked == null || picked == current) return;
    await ref.read(chatWallpaperProvider(chatId).notifier).save(picked);
  }

  Future<void> _memberSheet(
    BuildContext context,
    WidgetRef ref,
    String peer,
    String name, {
    required bool canRemove,
  }) async {
    final l = context.l10n;
    final blocked = (ref.read(blockedPeersProvider).value ?? const <String>{}).contains(peer);
    final choice = await showDsActionSheet<String>(
      context,
      title: name,
      actions: [
        if (onOpenProfile != null) DsSheetAction(l.chatInfoMemberProfile, 'profile'),
        DsSheetAction(l.chatInfoVerify, 'verify'),
        DsSheetAction(blocked ? l.blockedUnblock : l.chatInfoBlock, 'block', destructive: !blocked),
        DsSheetAction(l.reportAction, 'report', destructive: true),
        if (canRemove) DsSheetAction(l.groupRemoveMember, 'remove', destructive: true),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case 'profile':
        onOpenProfile?.call(peer, name);
      case 'verify':
        onVerify?.call(name, peer);
      case 'block':
        await _toggleBlock(context, ref, peer, name, personalChat: false);
      case 'report':
        await reportPerson(context, ref, peer: peer, name: name);
      case 'remove':
        final ok = await showDsActionSheet<bool>(
          context,
          title: l.groupRemoveConfirm(name),
          actions: [DsSheetAction(l.groupRemoveMember, true, destructive: true)],
        );
        if (ok != true || !context.mounted) return;
        await _attempt(context, () async {
          await ref.read(messageActionsProvider).removeMembers(chatId, [peer]);
          ref.invalidate(chatMembersProvider(chatId));
        });
    }
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, String current) async {
    final name = await promptGroupName(context, current);
    if (name == null || !context.mounted) return;
    await _attempt(context, () => ref.read(messageActionsProvider).renameGroup(chatId, name));
  }

  Future<void> _leave(BuildContext context, WidgetRef ref, String name) async {
    final l = context.l10n;
    final ok = await showDsActionSheet<bool>(
      context,
      title: l.groupLeaveConfirm(name),
      actions: [DsSheetAction(l.groupLeave, true, destructive: true)],
    );
    if (ok != true || !context.mounted) return;
    var left = false;
    await _attempt(context, () async {
      await ref.read(messageActionsProvider).leaveGroup(chatId);
      left = true;
    });
    if (left) onDeleted?.call();
  }

  /// Run a group change; if it fails (offline, server refused) say so.
  Future<void> _attempt(BuildContext context, Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {
      if (!context.mounted) return;
      await showDsActionSheet<void>(context, title: context.l10n.groupActionFailed, actions: const []);
    }
  }

  Future<void> _toggleBlock(
    BuildContext context,
    WidgetRef ref,
    String peer,
    String name, {
    required bool personalChat,
  }) async {
    final people = ref.read(peopleProvider);
    final isBlocked = (ref.read(blockedPeersProvider).value ?? const <String>{}).contains(peer);
    if (!isBlocked) {
      final ok = await showDsActionSheet<bool>(
        context,
        title: context.l10n.chatInfoBlockConfirm(name),
        actions: [DsSheetAction(context.l10n.chatInfoBlock, true, destructive: true)],
      );
      if (ok != true || !context.mounted) return;
    }
    await _attempt(context, () => people.setBlocked(peer, !isBlocked, personalChatId: personalChat ? chatId : null));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String name) async {
    final ok = await showDsActionSheet<bool>(
      context,
      title: context.l10n.deleteChatConfirm(name),
      actions: [DsSheetAction(context.l10n.deleteChat, true, destructive: true)],
    );
    if (ok != true || !context.mounted) return;
    var deleted = false;
    await _attempt(context, () async {
      await ref.read(chatActionsProvider).delete(chatId);
      deleted = true;
    });
    if (deleted) onDeleted?.call();
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.name, required this.subtitle, this.avatar, this.verified = false});
  final String name;
  final String subtitle;
  final Uint8List? avatar;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x3, DsSpace.gutter, DsSpace.x5),
      child: Column(
        children: [
          // Their photo full screen on tap (owner, 2026-10-18).
          Semantics(
            button: avatar != null,
            label: avatar != null ? context.l10n.a11yOpenPhoto : null,
            child: GestureDetector(
              key: const ValueKey('info-avatar'),
              behavior: HitTestBehavior.opaque,
              onTap: avatar == null ? null : () => openAvatarFullScreen(context, name, avatar!),
              child: Hero(
                tag: 'avatar-full',
                child: DsAvatar(name: name.isEmpty ? '?' : name, size: 84, image: avatar),
              ),
            ),
          ),
          const SizedBox(height: DsSpace.x3),
          Text.rich(
            TextSpan(
              text: name,
              children: [
                if (verified)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(left: DsSpace.x1h5),
                      child: DsVerifiedBadge(
                        key: const ValueKey('info-verified'),
                        size: 20,
                        semanticLabel: context.l10n.verifiedTitle,
                      ),
                    ),
                  ),
              ],
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DsText.title2.copyWith(color: tokens.text),
          ),
          const SizedBox(height: DsSpace.x1),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: DsText.subhead.copyWith(color: tokens.text3),
          ),
        ],
      ),
    );
  }
}
