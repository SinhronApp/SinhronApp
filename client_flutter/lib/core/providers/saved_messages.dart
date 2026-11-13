// ADR-055 — "Saved messages" (Избранное): a chat with yourself, on all
// your devices. It is an ordinary MLS group whose only members are my own
// devices: made on first use (`sync_create_saved_group`), and device sync
// (ADR-025) adds every device I link later, like in any chat. The server
// stores ciphertext and sees a group of one person's devices — nothing
// else. Which group it is lives in the local setting `saved_chat_id`; a
// newly linked device learns it from the history hand-off ("saved" flag,
// set in Rust).
//
// ADR-074 — restored from a backup (ADR-073) of a phone that is gone, the
// Saved chat names that phone's group, which no device of mine can add
// this one to: [SavedMessages.repair] makes a new one and moves the notes
// into it — unless another of my devices was online lately (it will).
//
// Two devices that each made their own Saved chat before they met settle
// on one (Rust `adopt_saved_chat`); the other used to stay as a second
// "Saved Messages" row (owner, 2026-10-26). [SavedMessages.tidy] moves
// its notes into the chosen one and drops the row; what still arrives in
// a former Saved group lands in the current one ([formerSavedChats]).

import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat_list/chat_data.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../services/net_service.dart';
import 'chat_providers.dart';

/// The local setting naming the Saved chat (mirrors Rust `SAVED_CHAT_SETTING`).
const kSavedChatSetting = 'saved_chat_id';

/// Former Saved chats of this device, comma-separated (mirrors Rust
/// `SAVED_FORMER_SETTING`).
const kSavedFormerSetting = 'saved_chat_former';

/// The Saved row before its group exists — opening it (or saving into it)
/// makes the group. Never an MLS id, so nothing sends to it.
const kSavedChatPendingId = 'saved-messages';

/// The FFI and network calls behind Saved messages (a seam for tests).
class SavedMessagesBackend {
  SavedMessagesBackend(this._ref);
  final Ref _ref;

  Future<String?> readId() => core.storageSettingGet(key: kSavedChatSetting);

  /// The group (this device only), announced; Rust remembers it as Saved.
  Future<String> createGroup() {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('net not connected');
    return core.syncCreateSavedGroup(serverBaseUrl: base);
  }

  /// ADR-025 — my other devices join (and get the "saved" marker).
  void syncDevices(String id) => unawaited(_ref.read(netServiceProvider).syncDevices(groupIdsHex: [id]));

  /// ADR-074 — can this device post to [id]? Null when it can't tell now
  /// (not signed in yet); false when it isn't in that group.
  Future<bool?> canPost(String id) async {
    try {
      return await core.syncGroupIsActive(groupIdHex: id);
    } catch (e) {
      return '$e'.contains('unknown group') ? false : null;
    }
  }

  /// ADR-074 — was another of my devices online within [within]? (It
  /// would add this one to the Saved group.) True when unknown.
  Future<bool> otherDeviceOnline(Duration within) async {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) return true;
    try {
      // The server tells "last seen" to the day only (server-http:7):
      // count from the start of that day, so it never waits less.
      final since = DateTime.now().subtract(within).millisecondsSinceEpoch ~/ 1000 ~/ 86400 * 86400;
      return (await core.devicesList(serverBaseUrl: base)).any((d) => !d.isThisDevice && d.lastSeenUnix.toInt() >= since);
    } catch (_) {
      return true;
    }
  }

  /// ADR-074 — the notes of [from] go into [to]; [from]'s row goes.
  Future<int> merge(String from, String to) => core.storageChatMergeInto(from: from, to: to);

  Future<Set<String>> readFormer() async =>
      ((await core.storageSettingGet(key: kSavedFormerSetting)) ?? '').split(',').where((s) => s.isNotEmpty).toSet();

  Future<void> writeFormer(Set<String> ids) => core.storageSettingSet(key: kSavedFormerSetting, value: ids.join(','));

  Future<List<({String id, String name})>> chats() async => [
    for (final c in await core.storageChatsList()) (id: c.id, name: c.displayName),
  ];

  /// Is nobody but me in group [id]? False when unknown (not a member).
  Future<bool> onlyMe(String id) async {
    try {
      return (await core.syncGroupMembers(groupIdHex: id)).length == 1;
    } catch (_) {
      return false;
    }
  }

  Future<void> addChatRow(String id, String name) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return core.storageChatUpsert(
      id: id,
      displayName: name,
      isGroup: false,
      muted: false,
      pinned: false,
      unreadCount: 0,
      lastMsgPreview: null,
      lastMsgTsUnix: now,
      lastMsgKind: 'text',
      lastMsgSenderLabel: null,
      lastMsgMine: true,
      createdAtUnix: now,
    );
  }
}

final savedMessagesBackendProvider = Provider<SavedMessagesBackend>((ref) => SavedMessagesBackend(ref));

/// ADR-074 — a restored Saved chat this device can't post to waits this
/// long for another of my devices (to add this one) before a new one
/// takes over its notes.
const kSavedWaitForOwnDevice = Duration(hours: 48);

/// The Saved chat's id on this device, or null before it exists.
final savedChatIdProvider = FutureProvider<String?>((ref) async {
  try {
    final id = await ref.watch(savedMessagesBackendProvider).readId();
    return id == null || id.isEmpty ? null : id;
  } catch (_) {
    return null; // storage not open yet
  }
});

/// Is [chatId] my Saved messages? (From the loaded setting.)
bool isSavedChat(Ref ref, String chatId) => ref.read(savedChatIdProvider).value == chatId;

/// Mark the Saved chat in a loaded chat list and put it first.
List<ChatPreview> markSavedChat(List<ChatPreview> chats, String? savedId) {
  if (savedId == null) return chats;
  final i = chats.indexWhere((c) => c.id == savedId);
  if (i < 0) return chats;
  final l = lookupAppL10n(Locale(currentLanguage));
  final c = chats[i];
  final saved = c.copyWith(name: l.savedMessages, saved: true, preview: c.preview.isEmpty ? l.savedMessagesHint : null);
  return [saved, for (var j = 0; j < chats.length; j++) if (j != i) chats[j]];
}

/// The Saved row for the chat list: the real chat when it exists, else a
/// stand-in that makes it on first tap. "Always there", like in Telegram.
ChatPreview savedChatEntry(List<ChatPreview> chats) {
  final real = chats.where((c) => c.saved).firstOrNull;
  if (real != null) return real;
  final l = lookupAppL10n(Locale(currentLanguage));
  return ChatPreview(id: kSavedChatPendingId, name: l.savedMessages, preview: l.savedMessagesHint, time: '', saved: true);
}

/// Makes the Saved chat when it doesn't exist yet.
class SavedMessages {
  SavedMessages(this._ref);
  final Ref _ref;
  Future<String>? _creating;

  /// The Saved chat's id — made now (group, announce, chat row, device
  /// sync) if this device has none. One at a time.
  Future<String> ensure() async {
    final have = await _existing();
    if (have != null) return have;
    return _creating ??= _create().whenComplete(() => _creating = null);
  }

  /// ADR-074 — the Saved chat this device can't post to (a backup of a
  /// phone that is gone): a new one, with its notes. Nothing if this
  /// device is in it, can't tell yet, or another device of mine was on
  /// within [kSavedWaitForOwnDevice]. Returns the new id when it made one.
  Future<String?> repair() async {
    final b = _ref.read(savedMessagesBackendProvider);
    final String? id;
    try {
      id = await _ref.read(savedChatIdProvider.future);
    } catch (_) {
      return null;
    }
    if (id == null || await b.canPost(id) != false) return null;
    if (await b.otherDeviceOnline(kSavedWaitForOwnDevice)) return null;
    final fresh = await (_creating ??= _create().whenComplete(() => _creating = null));
    final moved = await b.merge(id, fresh);
    await b.writeFormer({...await b.readFormer(), id});
    // ignore: avoid_print
    print('[sinhron][saved] the restored Saved chat goes on in a new group ($moved notes)');
    _ref.invalidate(chatsProvider);
    return fresh;
  }

  /// One Saved chat in the list: a second one — a former Saved group, or
  /// a "Saved messages" chat with nobody but me in it (made by my other
  /// device before the two met) — gives its notes to the current one and
  /// its row goes. Returns how many chats were folded in.
  Future<int> tidy() async {
    final b = _ref.read(savedMessagesBackendProvider);
    final String? saved;
    try {
      saved = await b.readId();
    } catch (_) {
      return 0;
    }
    if (saved == null || saved.isEmpty) return 0;
    final former = await b.readFormer();
    final names = {for (final code in const ['ru', 'en']) lookupAppL10n(Locale(code)).savedMessages.toLowerCase()};
    final folded = <String>{};
    var moved = 0;
    final chats = await b.chats();
    if (!chats.any((c) => c.id == saved)) return 0;
    for (final c in chats) {
      if (c.id == saved) continue;
      final dup = former.contains(c.id) || (names.contains(c.name.trim().toLowerCase()) && await b.onlyMe(c.id));
      if (!dup) continue;
      moved += await b.merge(c.id, saved);
      folded.add(c.id);
    }
    if (folded.isEmpty) return 0;
    await b.writeFormer({...former, ...folded});
    // ignore: avoid_print
    print('[sinhron][saved] folded ${folded.length} other Saved chat(s) into this one ($moved notes)');
    _ref.invalidate(chatsProvider);
    return folded.length;
  }

  /// [chatId], with the stand-in row resolved to the real chat.
  Future<String> resolve(String chatId) => chatId == kSavedChatPendingId ? ensure() : Future.value(chatId);

  Future<String?> _existing() async {
    final id = await _ref.read(savedChatIdProvider.future);
    if (id == null) return null;
    final chats = await _ref.read(chatsProvider.future);
    // Deleted from the list: a new one is made (the old group stays behind).
    return chats.any((c) => c.id == id) ? id : null;
  }

  Future<String> _create() async {
    final backend = _ref.read(savedMessagesBackendProvider);
    final id = await backend.createGroup();
    await backend.addChatRow(id, lookupAppL10n(Locale(currentLanguage)).savedMessages);
    _ref.invalidate(savedChatIdProvider);
    _ref.invalidate(chatsProvider);
    backend.syncDevices(id);
    return id;
  }
}

final savedMessagesProvider = Provider<SavedMessages>((ref) => SavedMessages(ref));

/// Where a push for [groupHex] goes when no chat row has that id: a former
/// Saved group (its row was folded in) → the current Saved chat.
Future<String?> formerSavedRedirect(String groupHex) async {
  try {
    final former = ((await core.storageSettingGet(key: kSavedFormerSetting)) ?? '').split(',');
    if (!former.contains(groupHex)) return null;
    final saved = await core.storageSettingGet(key: kSavedChatSetting);
    return saved == null || saved.isEmpty ? null : saved;
  } catch (_) {
    return null;
  }
}
