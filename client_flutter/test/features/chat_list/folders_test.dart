import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/folders.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;


ChatPreview chat(
  String id, {
  bool group = false,
  int unread = 0,
  bool muted = false,
  bool archived = false,
  bool markedUnread = false,
}) =>
    ChatPreview(
      id: id,
      name: id,
      preview: '',
      time: '',
      group: group,
      unread: unread,
      muted: muted,
      archived: archived,
      markedUnread: markedUnread,
    );

void main() {
  final chats = [
    chat('alice', unread: 2),
    chat('bob'),
    chat('team', group: true, muted: true, unread: 5),
    chat('family', group: true, markedUnread: true),
    chat('old', archived: true, unread: 9),
  ];
  List<String> ids(ChatFolder f) => [for (final c in chatsInFolder(f, chats)) c.id!];

  test('built-in folders: archived chats never appear', () {
    expect(ids(kFolderAll), ['alice', 'bob', 'team', 'family']);
    expect(ids(kFolderPersonal), ['alice', 'bob']);
    expect(ids(kFolderGroups), ['team', 'family']);
    expect(ids(kFolderUnread), ['alice', 'team', 'family'], reason: 'marked-unread counts as unread');
    expect(unreadInFolder(kFolderAll, chats), 3);
    expect(unreadInFolder(kFolderPersonal, chats), 1);
  });

  test('custom rules: explicit include, exclusion wins, hide muted / read', () {
    const f = ChatFolder(
      id: 'f1',
      name: 'Work',
      includeGroups: true,
      includeChatIds: {'bob', 'old'},
      excludeChatIds: {'family'},
      muted: FolderRule.hide,
    );
    expect(ids(f), ['bob'], reason: 'team is muted, family excluded, old archived');
    expect(ids(f.copyWith(muted: FolderRule.show)), ['bob', 'team']);
    expect(ids(f.copyWith(muted: FolderRule.show, excludeRead: true)), ['team']);
  });

  test('muted / archived chats: show, hide or only them', () {
    const every = ChatFolder(id: 'x', name: 'X', includePersonal: true, includeGroups: true);
    expect(ids(every.copyWith(muted: FolderRule.only)), ['team']);
    expect(ids(every.copyWith(archived: FolderRule.show)), ['alice', 'bob', 'team', 'family', 'old']);
    expect(ids(every.copyWith(archived: FolderRule.only)), ['old']);
    expect(ids(every.copyWith(archived: FolderRule.only, includeGroups: false)), ['old']);
    expect(ids(every.copyWith(archived: FolderRule.only, includePersonal: false)), isEmpty);
  });

  test('a folder saved before 2026-10-18 keeps its "hide muted" switch', () {
    final old = ChatFolder.fromJson(
      jsonDecode('{"id":"f","name":"F","personal":true,"groups":true,"excludeMuted":true}') as Map<String, Object?>,
    );
    expect(old.muted, FolderRule.hide);
    expect(old.archived, FolderRule.hide, reason: 'archived chats stay out by default');
    expect(ids(old), ['alice', 'bob', 'family']);
  });

  test('JSON round-trip keeps every rule', () {
    const f = ChatFolder(
      id: 'f1',
      name: 'Близкие',
      emoji: '❤️',
      includePersonal: true,
      includeChatIds: {'team'},
      excludeChatIds: {'bob'},
      excludeRead: true,
      muted: FolderRule.only,
      archived: FolderRule.show,
    );
    final back = ChatFolder.fromJson(jsonDecode(jsonEncode(f.toJson())) as Map<String, Object?>);
    expect(back.toJson(), f.toJson());
    expect(back.builtIn, isFalse);
  });

  test('custom folders persist in the encrypted settings table', () async {
    final store = MemoryStore();
    ProviderContainer make() => ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
    final c = make();
    addTearDown(c.dispose);
    expect(await c.read(customFoldersProvider.future), isEmpty);
    expect(c.read(tabFoldersProvider).map((f) => f.id), ['all', 'personal', 'groups', 'unread']);

    final n = c.read(customFoldersProvider.notifier);
    await n.upsert(const ChatFolder(id: 'a', name: 'A', includeChatIds: {'x'}));
    await n.upsert(const ChatFolder(id: 'b', name: 'B', excludeChatIds: {'x', 'y'}));
    await n.upsert(const ChatFolder(id: 'a', name: 'A2', includeChatIds: {'x'}));
    await n.forgetChat('x');
    expect(c.read(tabFoldersProvider).map((f) => f.id), ['all', 'personal', 'groups', 'unread', 'a', 'b']);

    // A fresh container (app restart) reads the same folders back.
    final c2 = make();
    addTearDown(c2.dispose);
    final again = await c2.read(customFoldersProvider.future);
    expect(again.map((f) => f.name), ['A2', 'B']);
    expect(again[1].excludeChatIds, {'y'}, reason: 'deleted chat forgotten');
    expect(again[0].includeChatIds, isEmpty);

    await c2.read(customFoldersProvider.notifier).delete('b');
    expect((await make().read(customFoldersProvider.future)).map((f) => f.id), ['a']);
  });

  test('corrupt folder JSON falls back to no custom folders', () async {
    final store = MemoryStore()..map['chat_folders'] = '{not json';
    final c = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
    addTearDown(c.dispose);
    expect(await c.read(customFoldersProvider.future), isEmpty);
  });

  group('folder layout (owner, 2026-10-18: hide any folder, move any folder)', () {
    late MemoryStore store;
    ProviderContainer make() {
      final c = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
      addTearDown(c.dispose);
      return c;
    }

    Future<List<String>> tabs(ProviderContainer c) async {
      await c.read(customFoldersProvider.future);
      await c.read(folderLayoutProvider.future);
      return [for (final f in c.read(tabFoldersProvider)) f.id];
    }

    setUp(() => store = MemoryStore()..map['chat_folders'] = '[{"id":"w","name":"Work","groups":true}]');

    test('built-in folders hide and come back; the choice survives a restart', () async {
      final c = make();
      expect(await tabs(c), ['all', 'personal', 'groups', 'unread', 'w']);
      await c.read(folderLayoutProvider.notifier).setHidden('all', true);
      await c.read(folderLayoutProvider.notifier).setHidden('unread', true);
      expect(await tabs(c), ['personal', 'groups', 'w']);
      expect(c.read(orderedFoldersProvider).map((f) => f.id), ['all', 'personal', 'groups', 'unread', 'w'],
          reason: 'Settings still lists hidden folders');

      final again = make();
      expect(await tabs(again), ['personal', 'groups', 'w']);
      await again.read(folderLayoutProvider.notifier).setHidden('all', false);
      expect(await tabs(again), ['all', 'personal', 'groups', 'w']);
    });

    test('every folder hidden → All chats, without tabs', () async {
      final c = make();
      for (final id in ['all', 'personal', 'groups', 'unread', 'w']) {
        await c.read(folderLayoutProvider.notifier).setHidden(id, true);
      }
      expect(await tabs(c), ['all']);
    });

    test('any folder moves, All too; new folders join at the end', () async {
      final c = make();
      await c.read(folderLayoutProvider.notifier).setOrder(['w', 'unread', 'all', 'personal', 'groups']);
      expect(await tabs(c), ['w', 'unread', 'all', 'personal', 'groups']);
      await c.read(customFoldersProvider.notifier).upsert(const ChatFolder(id: 'n', name: 'New'));
      expect(await tabs(c), ['w', 'unread', 'all', 'personal', 'groups', 'n']);
      expect(await tabs(make()), ['w', 'unread', 'all', 'personal', 'groups', 'n'], reason: 'after a restart');
    });

    test('moving tabs keeps hidden folders in their places', () {
      expect(
        mergeVisibleOrder(['all', 'personal', 'groups', 'unread', 'w'], {'personal'}, ['w', 'all', 'groups', 'unread']),
        ['w', 'personal', 'all', 'groups', 'unread'],
      );
    });

    test('corrupt layout JSON falls back to the default order', () async {
      store.map['chat_folder_layout'] = '[oops';
      expect(await tabs(make()), ['all', 'personal', 'groups', 'unread', 'w']);
    });
  });
}
