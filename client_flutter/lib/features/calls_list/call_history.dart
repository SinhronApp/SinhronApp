// Calls tab data — this phone's call history (CD9 `storageCallsList`,
// written when a call ends) named after the chats it happened in.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/simple.dart' as core;
import '../chat_list/chat_data.dart' show ChatPreview;
import 'calls_list_screen.dart' show CallEntry;

/// Reads the stored history (faked in tests).
final callHistoryLoaderProvider = Provider<Future<List<core.StoredCallSummary>> Function()>(
  (ref) =>
      () => core.storageCallsList(),
);

/// Newest first. Re-read each time the Calls tab opens (autoDispose).
final callHistoryProvider = FutureProvider.autoDispose<List<core.StoredCallSummary>>((ref) async {
  try {
    return await ref.read(callHistoryLoaderProvider)();
  } catch (_) {
    return const []; // storage not open (onboarding, tests)
  }
});

/// Rows for the Calls tab: each call named like its chat (a personal
/// chat by the name its person chose). Calls whose chat was deleted are
/// left out — there is nothing to open or call back.
List<CallEntry> callEntries(List<core.StoredCallSummary> calls, List<ChatPreview> chats, Map<String, String> names) {
  final byId = {for (final c in chats) c.id: c};
  return [
    for (final call in calls)
      if (byId[call.peerChatId] case final chat?)
        CallEntry(
          chatId: chat.id ?? call.peerChatId,
          name: (chat.peerId == null ? null : names[chat.peerId]) ?? chat.name,
          isGroup: chat.group,
          outgoing: call.isOutgoing,
          video: call.kind == 'video',
          status: call.status,
          startedAtUnix: call.startedAtUnix.toInt(),
          durationSecs: call.durationSecs?.toInt(),
        ),
  ];
}
