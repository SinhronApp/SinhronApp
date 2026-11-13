// Tech-debt 2.32 — what the Storage screen shows: this phone's local media
// copies (ADR-033) by type and by chat, and the message database.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/chat_providers.dart';
import '../../core/providers/people.dart';
import '../../src/rust/api/simple.dart' as core;
import '../chat_list/chat_data.dart' show ChatPreview;
import 'storage_screen.dart' show StorageChat, StorageUsage;

/// Storage FFI (faked in tests).
class StorageSpaceOps {
  const StorageSpaceOps({required this.usage, required this.clearCopies, this.clearOlderThan});
  final Future<core.StorageUsageSummary> Function() usage;
  final Future<int> Function() clearCopies;

  /// Tech-debt 2.32 — delete copies unused for [days] days.
  final Future<int> Function(int days)? clearOlderThan;
}

final storageSpaceOpsProvider = Provider<StorageSpaceOps>(
  (ref) => StorageSpaceOps(
    usage: core.storageUsage,
    clearCopies: core.storageClearMediaCopies,
    clearOlderThan: (days) => core.storageClearMediaCopiesOlderThan(days: days),
  ),
);

/// Read each time the screen opens (autoDispose); refreshed after clearing.
final storageUsageProvider = FutureProvider.autoDispose<StorageUsage>((ref) async {
  final summary = await ref.read(storageSpaceOpsProvider).usage();
  final chats = await ref.read(chatsProvider.future).catchError((Object _) => const <ChatPreview>[]);
  final names = ref.read(peerNamesProvider).value ?? const <String, String>{};
  return storageUsageFrom(summary, chats, names);
});

/// Chats by their names (a personal chat by the name its person chose).
/// Deleting a chat deletes its copies, so every row normally has a chat;
/// one that doesn't (list not loaded) is left out of the per-chat list.
StorageUsage storageUsageFrom(core.StorageUsageSummary s, List<ChatPreview> chats, Map<String, String> names) {
  final byId = {for (final c in chats) c.id: c};
  final rows = <StorageChat>[];
  for (final c in s.byChat) {
    final chat = byId[c.chatId];
    if (chat == null) continue;
    rows.add(
      StorageChat(
        name: (chat.peerId == null ? null : names[chat.peerId]) ?? chat.name,
        bytes: c.bytes,
        isGroup: chat.group,
      ),
    );
  }
  return StorageUsage(
    photos: s.photos,
    videos: s.videos,
    voice: s.voice,
    documents: s.documents,
    other: s.misc + s.unreferenced,
    database: s.database,
    chats: rows,
  );
}
