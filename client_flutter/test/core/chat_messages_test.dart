import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

core.StoredMessageSummary msg(int n, {String chat = 'c'}) => core.StoredMessageSummary(
      id: 'm${n.toString().padLeft(5, '0')}',
      chatId: chat,
      tsUnix: 1000 + n,
      body: 'message $n',
      kind: 'text',
      isMine: n.isEven,
      senderLabel: null,
      mediaJson: null,
      wireId: 'w$n',
      status: n.isEven ? 1 : 0,
      deleted: false,
    );

/// In-memory history with the same paging contract as storage::messages_page.
class FakeHistory {
  FakeHistory(int count) : all = [for (var i = 0; i < count; i++) msg(i)];
  final List<core.StoredMessageSummary> all;
  final calls = <String>[];

  Future<List<core.StoredMessageSummary>> fetch(String chatId,
      {int? beforeTs, String? beforeId, required int limit}) async {
    calls.add(beforeId ?? 'newest');
    final older = beforeId == null
        ? all
        : all.where((m) => m.tsUnix < beforeTs! || (m.tsUnix == beforeTs && m.id.compareTo(beforeId) < 0)).toList();
    final start = older.length > limit ? older.length - limit : 0;
    return older.sublist(start);
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('first page is the newest 50; older pages prepend; end detected', () async {
    final h = FakeHistory(120);
    final c = ProviderContainer(overrides: [messagePageFetcherProvider.overrideWithValue(h.fetch)]);
    addTearDown(c.dispose);
    final sub = c.listen(chatMessagesProvider('c'), (_, _) {});
    addTearDown(sub.close);
    await settle();
    var s = c.read(chatMessagesProvider('c'));
    expect(s.loading, isFalse);
    expect(s.messages.length, 50);
    expect(s.messages.first.id, 'm00070');
    expect(s.messages.last.id, 'm00119');
    expect(s.hasMore, isTrue);

    final n = c.read(chatMessagesProvider('c').notifier);
    await n.loadMore();
    s = c.read(chatMessagesProvider('c'));
    expect(s.messages.length, 100);
    expect(s.messages.first.id, 'm00020');

    await n.loadMore();
    s = c.read(chatMessagesProvider('c'));
    expect(s.messages.length, 120);
    expect(s.hasMore, isFalse, reason: 'short page = beginning of the chat');

    await n.loadMore(); // no-op at the beginning
    expect(h.calls.length, 3);
  });

  test('a change refreshes only the newest page and keeps older pages', () async {
    final h = FakeHistory(120);
    final c = ProviderContainer(overrides: [messagePageFetcherProvider.overrideWithValue(h.fetch)]);
    addTearDown(c.dispose);
    final sub = c.listen(chatMessagesProvider('c'), (_, _) {});
    addTearDown(sub.close);
    await settle();
    await c.read(chatMessagesProvider('c').notifier).loadMore();
    expect(c.read(chatMessagesProvider('c')).messages.length, 100);

    h.all.add(msg(120)); // a new message arrives
    c.read(chatRevisionProvider('c').notifier).bump();
    await settle();
    final s = c.read(chatMessagesProvider('c'));
    expect(s.messages.length, 101, reason: 'older page kept, new one appended');
    expect(s.messages.last.id, 'm00120');
    expect(s.messages.map((m) => m.id).toSet().length, 101, reason: 'no duplicates');
  });

  test('short chat: everything in one page, nothing more to load', () async {
    final h = FakeHistory(7);
    final c = ProviderContainer(overrides: [messagePageFetcherProvider.overrideWithValue(h.fetch)]);
    addTearDown(c.dispose);
    final sub = c.listen(chatMessagesProvider('c'), (_, _) {});
    addTearDown(sub.close);
    await settle();
    final s = c.read(chatMessagesProvider('c'));
    expect(s.messages.length, 7);
    expect(s.hasMore, isFalse);
  });
}
