// Chat-list actions (pin, mute, archive, read/unread, delete, reorder,
// drafts) — UI backlog §2 items 12-16. One seam over the storage FFI so
// widget tests can run without the Rust library.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat_list/chat_data.dart' show ChatPreview;
import '../../features/chat_list/folders.dart';
import '../../src/rust/api/simple.dart' as core;
import '../push.dart' show pushPlatformProvider;
import 'device_transfer.dart' show deviceSyncProvider;
import 'chat_providers.dart';
import 'message_actions.dart' show peopleProvider;
import 'people.dart' show accessKeysRefresherProvider;

abstract class ChatStore {
  Future<void> setMuted(String id, bool v);
  Future<void> setArchived(String id, bool v);
  Future<void> setPinned(String id, bool v);
  Future<void> reorderPinned(List<String> ids);
  Future<void> markRead(String id);
  Future<void> markUnread(String id);
  Future<void> setDraft(String id, String? draft);
  Future<void> delete(String id);
  Future<void> setRequest(String id, bool request);
}

class CoreChatStore implements ChatStore {
  @override
  Future<void> setMuted(String id, bool v) => core.storageChatSetMuted(id: id, muted: v);
  @override
  Future<void> setRequest(String id, bool request) => core.storageChatSetRequest(id: id, request: request);
  @override
  Future<void> setArchived(String id, bool v) => core.storageChatSetArchived(id: id, archived: v);
  @override
  Future<void> setPinned(String id, bool v) => core.storageChatSetPinned(id: id, pinned: v);
  @override
  Future<void> reorderPinned(List<String> ids) => core.storageChatsReorderPinned(ids: ids);
  @override
  Future<void> markRead(String id) => core.storageChatMarkRead(id: id);
  @override
  Future<void> markUnread(String id) => core.storageChatMarkUnread(id: id);
  @override
  Future<void> setDraft(String id, String? draft) => core.storageChatSetDraft(id: id, draft: draft);
  @override
  Future<void> delete(String id) => core.storageChatDelete(id: id);
}

final chatStoreProvider = Provider<ChatStore>((ref) => CoreChatStore());

/// Which chat is open right now — incoming messages there are read
/// immediately (no unread badge for the chat you're looking at).
class OpenChat extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? id) => state = id;

  /// Clear only if [id] is still the open chat (another may have opened).
  /// No-op once the container is gone (app / test teardown).
  void clearIf(String id) {
    if (ref.mounted && state == id) state = null;
  }
}

final openChatProvider = NotifierProvider<OpenChat, String?>(OpenChat.new);

class ChatActions {
  ChatActions(this._ref);
  final Ref _ref;

  ChatStore get _store => _ref.read(chatStoreProvider);

  Future<void> _then(Future<void> f) async {
    await f;
    _ref.invalidate(chatsProvider);
  }

  Future<void> setMuted(String id, bool v) => _then(_store.setMuted(id, v));
  Future<void> setArchived(String id, bool v) => _then(_store.setArchived(id, v));
  Future<void> setPinned(String id, bool v) => _then(_store.setPinned(id, v));
  /// New order for pinned chats. [ids] may be only some of them (a custom
  /// folder shows its own): they take their new order in the slots they
  /// held, everyone else stays put — so the All folder isn't scrambled.
  Future<void> reorderPinned(List<String> ids) {
    final all = [
      for (final c in _ref.read(chatsProvider).value ?? const <ChatPreview>[])
        if (c.pinned && c.id != null) c.id!,
    ];
    final moving = ids.toSet();
    if (all.isEmpty || !all.toSet().containsAll(moving)) return _then(_store.reorderPinned(ids));
    final next = ids.iterator;
    final merged = [for (final id in all) moving.contains(id) && next.moveNext() ? next.current : id];
    return _then(_store.reorderPinned(merged));
  }
  /// Status 223 — read: its notifications leave the notification centre
  /// too (my other devices learn it through device sync, ADR-064).
  Future<void> markRead(String id) async {
    await _then(_store.markRead(id));
    _afterRead(id);
    // Tell my other devices now, not at the next 20-second round.
    try {
      unawaited(_ref.read(deviceSyncProvider).flush());
    } catch (_) {
      // no device sync here (tests) — the 20-second round tells them
    }
  }

  /// Its notifications leave the notification centre — never in the way of
  /// reading itself.
  void _afterRead(String id) {
    try {
      unawaited(_ref.read(pushPlatformProvider).clearChat(id).catchError((Object _) {}));
    } catch (_) {
      // no push platform here (tests)
    }
  }

  Future<void> markUnread(String id) => _then(_store.markUnread(id));
  Future<void> setDraft(String id, String? draft) => _then(_store.setDraft(id, draft));

  /// Accept a message request (tech-debt 2.27). Read receipts and my name
  /// go out from the next time the chat is open. ADR-052 — the person
  /// becomes a contact (if their profile hasn't come yet, it does when it
  /// comes: `People.onProfile`). ADR-071 — and my access key goes to them.
  Future<void> acceptRequest(String id) async {
    final chat = (_ref.read(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.id == id).firstOrNull;
    await _then(_store.setRequest(id, false));
    await _ref.read(chatsProvider.future); // gates read the fresh list
    final peer = chat?.peerId ?? '';
    if (chat != null && !chat.group && peer.isNotEmpty) {
      await _ref.read(peopleProvider).addContact(peer, name: chat.name);
    }
    // ADR-071 — now they get my access key: their messages wake my phone.
    unawaited(_ref.read(accessKeysRefresherProvider)().catchError((Object _) {}));
  }

  /// Mark every chat of [ids] read (folder "Mark all as read").
  Future<void> markAllRead(Iterable<String> ids) async {
    for (final id in ids) {
      await _store.markRead(id);
      _afterRead(id);
    }
    _ref.invalidate(chatsProvider);
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    await _ref.read(customFoldersProvider.notifier).forgetChat(id);
    _ref.invalidate(chatsProvider);
  }

  /// Move a pinned chat one place up (-1) or down (+1) in [pinnedIds].
  Future<void> movePinned(List<String> pinnedIds, String id, int delta) {
    final list = [...pinnedIds];
    final i = list.indexOf(id);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= list.length) return Future.value();
    list
      ..removeAt(i)
      ..insert(j, id);
    return reorderPinned(list);
  }
}

final chatActionsProvider = Provider<ChatActions>((ref) => ChatActions(ref));
