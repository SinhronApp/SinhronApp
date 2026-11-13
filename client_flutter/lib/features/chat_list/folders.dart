// Chat folders (Telegram-style) — UI backlog §2 items 9-11; made fully
// customisable on 2026-10-18 (owner: hide any folder, the defaults too;
// drag folders around; a "Chat folders" screen in Settings).
//
// Built-in folders (All, Personal, Groups, Unread) plus custom folders
// with rules. Every folder can be hidden and moved; the order and the
// hidden set are a separate [FolderLayout]. Custom folders and the
// layout persist as JSON in the encrypted settings table; nothing about
// them leaves the device.

import 'dart:convert';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/settings_providers.dart';
import '../../l10n/l10n.dart';
import 'chat_data.dart';

/// What a folder does with muted / archived chats: keep them, leave them
/// out, or show nothing else.
enum FolderRule { show, hide, only }

class ChatFolder {
  const ChatFolder({
    required this.id,
    required this.name,
    this.emoji = '',
    this.includePersonal = false,
    this.includeGroups = false,
    this.includeChatIds = const {},
    this.excludeChatIds = const {},
    this.muted = FolderRule.show,
    this.archived = FolderRule.hide,
    this.excludeRead = false,
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String emoji;

  /// Include every 1:1 chat / every group chat.
  final bool includePersonal;
  final bool includeGroups;

  /// Explicitly included / excluded chats (exclusion wins).
  final Set<String> includeChatIds;
  final Set<String> excludeChatIds;

  /// Muted chats: kept by default. Archived chats: left out by default —
  /// they live in the archive unless a folder asks for them.
  final FolderRule muted;
  final FolderRule archived;

  /// Only chats with something unread.
  final bool excludeRead;

  /// Built-ins can't be edited or deleted — only hidden and moved.
  final bool builtIn;

  static bool _passes(FolderRule r, bool value) => switch (r) {
        FolderRule.show => true,
        FolderRule.hide => !value,
        FolderRule.only => value,
      };

  bool matches(ChatPreview c) {
    final id = c.id;
    if (id != null && excludeChatIds.contains(id)) return false;
    if (!_passes(archived, c.archived)) return false;
    if (!_passes(muted, c.muted)) return false;
    if (excludeRead && !c.hasUnread) return false;
    if (id != null && includeChatIds.contains(id)) return true;
    return (includePersonal && !c.group) || (includeGroups && c.group);
  }

  ChatFolder copyWith({
    String? name,
    String? emoji,
    bool? includePersonal,
    bool? includeGroups,
    Set<String>? includeChatIds,
    Set<String>? excludeChatIds,
    FolderRule? muted,
    FolderRule? archived,
    bool? excludeRead,
  }) =>
      ChatFolder(
        id: id,
        name: name ?? this.name,
        emoji: emoji ?? this.emoji,
        includePersonal: includePersonal ?? this.includePersonal,
        includeGroups: includeGroups ?? this.includeGroups,
        includeChatIds: includeChatIds ?? this.includeChatIds,
        excludeChatIds: excludeChatIds ?? this.excludeChatIds,
        muted: muted ?? this.muted,
        archived: archived ?? this.archived,
        excludeRead: excludeRead ?? this.excludeRead,
        builtIn: builtIn,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'emoji': emoji,
        'personal': includePersonal,
        'groups': includeGroups,
        'include': includeChatIds.toList(),
        'exclude': excludeChatIds.toList(),
        'muted': muted.name,
        'archived': archived.name,
        'excludeRead': excludeRead,
      };

  static FolderRule _rule(Object? v, FolderRule fallback) =>
      FolderRule.values.where((r) => r.name == v).firstOrNull ?? fallback;

  static ChatFolder fromJson(Map<String, Object?> j) => ChatFolder(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        emoji: (j['emoji'] as String?) ?? '',
        includePersonal: j['personal'] == true,
        includeGroups: j['groups'] == true,
        includeChatIds: {...((j['include'] as List?) ?? const []).cast<String>()},
        excludeChatIds: {...((j['exclude'] as List?) ?? const []).cast<String>()},
        // Folders saved before 2026-10-18 had a plain "hide muted" switch.
        muted: _rule(j['muted'], j['excludeMuted'] == true ? FolderRule.hide : FolderRule.show),
        archived: _rule(j['archived'], FolderRule.hide),
        excludeRead: j['excludeRead'] == true,
      );
}

const kFolderAll = ChatFolder(id: 'all', name: 'All', includePersonal: true, includeGroups: true, builtIn: true);
const kFolderPersonal = ChatFolder(id: 'personal', name: 'Personal', includePersonal: true, builtIn: true);
const kFolderGroups = ChatFolder(id: 'groups', name: 'Groups', includeGroups: true, builtIn: true);
const kFolderUnread = ChatFolder(
  id: 'unread',
  name: 'Unread',
  includePersonal: true,
  includeGroups: true,
  excludeRead: true,
  builtIn: true,
);
const kBuiltInFolders = [kFolderAll, kFolderPersonal, kFolderGroups, kFolderUnread];

/// Ready-made folders offered in Settings → Chat folders, one tap to add.
/// They become ordinary custom folders (name in the current language,
/// editable); a fixed id tells which ones are already added.
List<ChatFolder> suggestedFolders(AppL10n l) => [
      ChatFolder(
        id: 's_muted',
        name: l.folderMuted,
        emoji: '🔕',
        includePersonal: true,
        includeGroups: true,
        muted: FolderRule.only,
      ),
      ChatFolder(
        id: 's_notmuted',
        name: l.folderNotMuted,
        emoji: '🔔',
        includePersonal: true,
        includeGroups: true,
        muted: FolderRule.hide,
      ),
      ChatFolder(
        id: 's_archived',
        name: l.folderArchived,
        emoji: '🗂️',
        includePersonal: true,
        includeGroups: true,
        archived: FolderRule.only,
      ),
    ];

/// One line under a suggested folder's name.
String suggestedFolderHint(AppL10n l, String id) => switch (id) {
      's_muted' => l.folderMutedHint,
      's_notmuted' => l.folderNotMutedHint,
      's_archived' => l.folderArchivedHint,
      _ => '',
    };

/// Display name: built-ins are translated, custom folders as typed.
String folderTitle(BuildContext context, ChatFolder f) => switch (f.id) {
      'all' when f.builtIn => context.l10n.folderAll,
      'personal' when f.builtIn => context.l10n.folderPersonal,
      'groups' when f.builtIn => context.l10n.folderGroups,
      'unread' when f.builtIn => context.l10n.folderUnread,
      _ => f.name,
    };

/// The face of a folder in Settings lists: the emoji the person picked,
/// else an icon (owner's rule 2026-11-03 — interface marks are icons).
({String emoji, IconData icon}) folderFace(ChatFolder f) => (
  emoji: f.emoji,
  icon: switch (f.id) {
    'all' when f.builtIn => CupertinoIcons.chat_bubble_2,
    'personal' when f.builtIn => CupertinoIcons.person,
    'groups' when f.builtIn => CupertinoIcons.person_2,
    'unread' when f.builtIn => CupertinoIcons.circle_fill,
    _ => CupertinoIcons.folder,
  },
);

/// "❤️ Close" — the tab / row label.
String folderLabel(BuildContext context, ChatFolder f) =>
    f.emoji.isEmpty ? folderTitle(context, f) : '${f.emoji} ${folderTitle(context, f)}';

/// Chats of a folder, keeping the list order (pinned first).
List<ChatPreview> chatsInFolder(ChatFolder f, List<ChatPreview> chats) =>
    chats.where(f.matches).toList(growable: false);

/// Chats with something unread in a folder (badge on its tab).
int unreadInFolder(ChatFolder f, List<ChatPreview> chats) =>
    chats.where((c) => f.matches(c) && c.hasUnread).length;

/// Custom folders (persisted) — built-ins are added by [orderedFoldersProvider].
class CustomFolders extends AsyncNotifier<List<ChatFolder>> {
  static const _key = 'chat_folders';

  @override
  Future<List<ChatFolder>> build() async {
    try {
      final raw = await ref.read(settingsStoreProvider).get(_key);
      if (raw == null || raw.isEmpty) return const [];
      return [
        for (final j in (jsonDecode(raw) as List).cast<Map<String, Object?>>()) ChatFolder.fromJson(j),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _save(List<ChatFolder> folders) async {
    await ref.read(settingsStoreProvider).set(_key, jsonEncode([for (final f in folders) f.toJson()]));
    state = AsyncData(folders);
  }

  List<ChatFolder> get _current => state.value ?? const [];

  /// Insert or replace by id.
  Future<void> upsert(ChatFolder folder) {
    final list = [..._current];
    final i = list.indexWhere((f) => f.id == folder.id);
    if (i >= 0) {
      list[i] = folder;
    } else {
      list.add(folder);
    }
    return _save(list);
  }

  Future<void> delete(String id) => _save(_current.where((f) => f.id != id).toList());

  /// Remove a deleted chat from every folder's explicit lists.
  Future<void> forgetChat(String chatId) => _save([
        for (final f in _current)
          f.copyWith(
            includeChatIds: {...f.includeChatIds}..remove(chatId),
            excludeChatIds: {...f.excludeChatIds}..remove(chatId),
          ),
      ]);
}

final customFoldersProvider = AsyncNotifierProvider<CustomFolders, List<ChatFolder>>(CustomFolders.new);

/// Where the folders stand and which are hidden — built-ins included.
class FolderLayout {
  const FolderLayout({this.order = const [], this.hidden = const {}});

  /// Folder ids in the user's order. Folders not named (never moved, or
  /// created since) follow in their default order.
  final List<String> order;
  final Set<String> hidden;

  Map<String, Object?> toJson() => {'order': order, 'hidden': hidden.toList()};

  static FolderLayout fromJson(Map<String, Object?> j) => FolderLayout(
        order: ((j['order'] as List?) ?? const []).cast<String>(),
        hidden: {...((j['hidden'] as List?) ?? const []).cast<String>()},
      );
}

class FolderLayoutNotifier extends AsyncNotifier<FolderLayout> {
  static const _key = 'chat_folder_layout';

  @override
  Future<FolderLayout> build() async {
    try {
      final raw = await ref.read(settingsStoreProvider).get(_key);
      if (raw == null || raw.isEmpty) return const FolderLayout();
      return FolderLayout.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } catch (_) {
      return const FolderLayout();
    }
  }

  FolderLayout get _current => state.value ?? const FolderLayout();

  Future<void> _save(FolderLayout l) async {
    await ref.read(settingsStoreProvider).set(_key, jsonEncode(l.toJson()));
    state = AsyncData(l);
  }

  /// Every folder id in the new order (drag to reorder).
  Future<void> setOrder(List<String> ids) => _save(FolderLayout(order: ids, hidden: _current.hidden));

  Future<void> setHidden(String id, bool hidden) => _save(
        FolderLayout(
          order: _current.order,
          hidden: hidden ? {..._current.hidden, id} : ({..._current.hidden}..remove(id)),
        ),
      );
}

final folderLayoutProvider = AsyncNotifierProvider<FolderLayoutNotifier, FolderLayout>(FolderLayoutNotifier.new);

/// [folders] in the saved [order]; folders the order doesn't name keep
/// their default place after the named ones.
List<ChatFolder> applyFolderOrder(List<ChatFolder> folders, List<String> order) {
  final byId = {for (final f in folders) f.id: f};
  final named = {...order};
  return [
    for (final id in order)
      if (byId[id] != null) byId[id]!,
    for (final f in folders)
      if (!named.contains(f.id)) f,
  ];
}

/// The full order after the visible folders were rearranged into
/// [visibleIds]: hidden folders keep their slots.
List<String> mergeVisibleOrder(List<String> allIds, Set<String> hidden, List<String> visibleIds) {
  final next = visibleIds.iterator;
  return [
    for (final id in allIds)
      if (hidden.contains(id) || !visibleIds.contains(id)) id else if (next.moveNext()) next.current,
  ];
}

/// Every folder in the user's order, hidden ones too (Settings → Chat folders).
final orderedFoldersProvider = Provider<List<ChatFolder>>((ref) {
  final custom = ref.watch(customFoldersProvider).value ?? const <ChatFolder>[];
  final order = ref.watch(folderLayoutProvider).value?.order ?? const <String>[];
  return applyFolderOrder([...kBuiltInFolders, ...custom], order);
});

/// Hidden folder ids.
final hiddenFoldersProvider = Provider<Set<String>>(
  (ref) => ref.watch(folderLayoutProvider).value?.hidden ?? const <String>{},
);

/// Tabs shown above the chat list: the folders not hidden, in order.
/// Never empty — with every folder hidden the list shows All chats
/// (without a tab strip, as Telegram does with only "All chats").
final tabFoldersProvider = Provider<List<ChatFolder>>((ref) {
  final hidden = ref.watch(hiddenFoldersProvider);
  final shown = [
    for (final f in ref.watch(orderedFoldersProvider))
      if (!hidden.contains(f.id)) f,
  ];
  return shown.isEmpty ? const [kFolderAll] : shown;
});

/// New, unsaved folder id.
String newFolderId() => 'f${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
