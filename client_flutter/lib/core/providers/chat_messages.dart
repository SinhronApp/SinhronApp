// Paged message history for the chat view — UI backlog §1 (items 1-2, 6).
//
// The chat view shows the newest page (50) and pulls older pages as the
// user scrolls up; a change in the chat (send / receive / media landed)
// refreshes only the newest page and merges it, so long histories never
// reload in full and the scroll position stays put.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/simple.dart' as core;

const int kMessagePageSize = 50;

typedef MessagePageFetcher = Future<List<core.StoredMessageSummary>> Function(
  String chatId, {
  int? beforeTs,
  String? beforeId,
  required int limit,
});

/// FFI-backed page fetcher; overridden in tests.
final messagePageFetcherProvider = Provider<MessagePageFetcher>(
  (ref) => (chatId, {beforeTs, beforeId, required limit}) => core.storageMessagesPage(
        chatId: chatId,
        beforeTsUnix: beforeTs,
        beforeId: beforeId,
        limit: limit,
      ),
);

/// Bumped whenever a chat's messages change (see [markChatChanged]).
class ChatRevision extends Notifier<int> {
  ChatRevision(this.chatId);
  final String chatId;

  @override
  int build() => 0;

  void bump() => state++;
}

final chatRevisionProvider =
    NotifierProvider.family<ChatRevision, int, String>(ChatRevision.new);

class ChatMessagesState {
  const ChatMessagesState({
    this.messages = const [],
    this.loading = true,
    this.hasMore = true,
    this.loadingMore = false,
    this.error,
  });

  /// Oldest-first (display order).
  final List<core.StoredMessageSummary> messages;
  final bool loading;
  final bool hasMore;
  final bool loadingMore;
  final Object? error;

  ChatMessagesState copyWith({
    List<core.StoredMessageSummary>? messages,
    bool? loading,
    bool? hasMore,
    bool? loadingMore,
    Object? error,
    bool clearError = false,
  }) =>
      ChatMessagesState(
        messages: messages ?? this.messages,
        loading: loading ?? this.loading,
        hasMore: hasMore ?? this.hasMore,
        loadingMore: loadingMore ?? this.loadingMore,
        error: clearError ? null : (error ?? this.error),
      );
}

class ChatMessagesNotifier extends Notifier<ChatMessagesState> {
  ChatMessagesNotifier(this.chatId);
  final String chatId;

  MessagePageFetcher get _fetch => ref.read(messagePageFetcherProvider);

  @override
  ChatMessagesState build() {
    ref.listen(chatRevisionProvider(chatId), (_, _) => refreshLatest());
    Future.microtask(refreshLatest);
    return const ChatMessagesState();
  }

  /// Re-read the newest page and merge it with what's loaded: anything
  /// older than that page stays, the page replaces the rest (so new,
  /// edited and media-attached rows all show up).
  Future<void> refreshLatest() async {
    try {
      final page = await _fetch(chatId, limit: kMessagePageSize);
      final current = state;
      final List<core.StoredMessageSummary> merged;
      if (page.isEmpty || current.messages.isEmpty) {
        merged = page;
      } else {
        final firstNew = page.first;
        final older = current.messages.where((m) => _before(m, firstNew));
        final ids = {for (final m in page) m.id};
        merged = [...older.where((m) => !ids.contains(m.id)), ...page];
      }
      state = current.copyWith(
        messages: merged,
        loading: false,
        // A short newest page means there's nothing older at all.
        hasMore: current.messages.isEmpty ? page.length == kMessagePageSize : current.hasMore,
        clearError: true,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e);
    }
  }

  /// Load the next older page (no-op while one is in flight or when the
  /// beginning of the chat is reached).
  Future<void> loadMore() async {
    final s = state;
    if (s.loading || s.loadingMore || !s.hasMore || s.messages.isEmpty) return;
    state = s.copyWith(loadingMore: true);
    try {
      final oldest = s.messages.first;
      final page = await _fetch(
        chatId,
        beforeTs: oldest.tsUnix.toInt(),
        beforeId: oldest.id,
        limit: kMessagePageSize,
      );
      final ids = {for (final m in state.messages) m.id};
      state = state.copyWith(
        messages: [...page.where((m) => !ids.contains(m.id)), ...state.messages],
        hasMore: page.length == kMessagePageSize,
        loadingMore: false,
      );
    } catch (e) {
      state = state.copyWith(loadingMore: false, error: e);
    }
  }

  static bool _before(core.StoredMessageSummary a, core.StoredMessageSummary b) {
    final c = a.tsUnix.compareTo(b.tsUnix);
    return c < 0 || (c == 0 && a.id.compareTo(b.id) < 0);
  }
}

final chatMessagesProvider =
    NotifierProvider.autoDispose.family<ChatMessagesNotifier, ChatMessagesState, String>(
  ChatMessagesNotifier.new,
);
