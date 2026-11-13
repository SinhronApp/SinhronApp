import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/folders.dart';

import 'settings_providers_test.dart' show MemoryStore;

/// Records every storage call.
class FakeChatStore implements ChatStore {
  final calls = <String>[];
  @override
  Future<void> setMuted(String id, bool v) async => calls.add('muted $id $v');
  @override
  Future<void> setArchived(String id, bool v) async => calls.add('archived $id $v');
  @override
  Future<void> setPinned(String id, bool v) async => calls.add('pinned $id $v');
  @override
  Future<void> reorderPinned(List<String> ids) async => calls.add('reorder ${ids.join(',')}');
  @override
  Future<void> markRead(String id) async => calls.add('read $id');
  @override
  Future<void> markUnread(String id) async => calls.add('unread $id');
  @override
  Future<void> setDraft(String id, String? draft) async => calls.add('draft $id $draft');
  @override
  Future<void> delete(String id) async => calls.add('delete $id');
  @override
  Future<void> setRequest(String id, bool request) async => calls.add('request $id $request');
}

void main() {
  late FakeChatStore store;
  late ProviderContainer c;
  var listLoads = 0;

  setUp(() {
    store = FakeChatStore();
    listLoads = 0;
    c = ProviderContainer(overrides: [
      chatStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      chatsProvider.overrideWith((ref) async {
        listLoads++;
        return const <ChatPreview>[];
      }),
    ]);
    addTearDown(c.dispose);
  });

  test('every action hits storage and refreshes the chat list', () async {
    final sub = c.listen(chatsProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(chatsProvider.future);
    final a = c.read(chatActionsProvider);
    await a.setMuted('x', true);
    await a.setArchived('x', true);
    await a.setPinned('y', true);
    await a.markRead('x');
    await a.markUnread('y');
    await a.setDraft('x', 'hi');
    await a.markAllRead(['p', 'q']);
    expect(store.calls, [
      'muted x true',
      'archived x true',
      'pinned y true',
      'read x',
      'unread y',
      'draft x hi',
      'read p',
      'read q',
    ]);
    await c.read(chatsProvider.future);
    expect(listLoads, greaterThan(1), reason: 'list re-read after changes');
  });

  test('movePinned swaps neighbours and ignores out-of-range moves', () async {
    final a = c.read(chatActionsProvider);
    await a.movePinned(['a', 'b', 'c'], 'c', -1);
    await a.movePinned(['a', 'b', 'c'], 'a', 1);
    await a.movePinned(['a', 'b', 'c'], 'a', -1);
    await a.movePinned(['a', 'b', 'c'], 'zz', 1);
    expect(store.calls, ['reorder a,c,b', 'reorder b,a,c']);
  });

  test('reordering only some pinned chats (one folder) keeps the others in place', () async {
    final c2 = ProviderContainer(overrides: [
      chatStoreProvider.overrideWithValue(store),
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      chatsProvider.overrideWith((ref) async => [
            for (final id in ['p1', 'x', 'p2', 'y', 'p3'])
              ChatPreview(id: id, name: id, preview: '', time: '', pinned: true),
          ]),
    ]);
    addTearDown(c2.dispose);
    await c2.read(chatsProvider.future);
    // A folder holding p1, p2, p3 moves p3 to the top.
    await c2.read(chatActionsProvider).reorderPinned(['p3', 'p1', 'p2']);
    expect(store.calls.last, 'reorder p3,x,p1,y,p2', reason: 'x and y keep their slots');
  });

  test('delete also forgets the chat in custom folders', () async {
    await c.read(customFoldersProvider.future);
    await c.read(customFoldersProvider.notifier).upsert(const ChatFolder(id: 'f', name: 'F', includeChatIds: {'x', 'y'}));
    await c.read(chatActionsProvider).delete('x');
    expect(store.calls, ['delete x']);
    expect(c.read(customFoldersProvider).value!.single.includeChatIds, {'y'});
  });

  test('open chat is cleared only by the screen that set it', () {
    final n = c.read(openChatProvider.notifier);
    n.set('a');
    n.set('b');
    n.clearIf('a');
    expect(c.read(openChatProvider), 'b');
    n.clearIf('b');
    expect(c.read(openChatProvider), isNull);
  });
}
