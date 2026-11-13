// Tech-debt 2.22 / 2.27 — names in group chats, pins for everyone, blocking.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as ft show group; // `group` is a chat id here
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/chat_info/chat_info_screen.dart' show chatMembersLoaderProvider;
import 'package:sinhron/features/chat_list/chat_data.dart';

import 'chat_actions_test.dart' show FakeChatStore;
import 'message_actions_test.dart' show FakeGroupOps, FakeMessageStore, FakeSender, w;
import 'settings_providers_test.dart' show MemoryStore;

class FakePeopleStore implements PeopleStore {
  final names_ = <String, String>{};
  final sent = <String, String>{};
  final blocked_ = <String>{};

  @override
  Future<Map<String, String>> names() async => Map.of(names_);
  @override
  Future<bool> setName(String peerId, String name, int ts) async {
    if (names_[peerId] == name) return false;
    names_[peerId] = name;
    return true;
  }

  @override
  Future<String?> profileSent(String chatId) async => sent[chatId];
  @override
  Future<void> setProfileSent(String chatId, String name) async => sent[chatId] = name;
  @override
  Future<Set<String>> blocked() async => Set.of(blocked_);
  @override
  Future<void> setBlocked(String peerId, bool blocked, int ts) async =>
      blocked ? blocked_.add(peerId) : blocked_.remove(peerId);

  final avatars_ = <String, Uint8List>{};
  final chatPeers = <String, String>{};
  @override
  Future<Map<String, Uint8List>> avatars() async => Map.of(avatars_);
  @override
  Future<bool> setAvatar(String peerId, Uint8List image, int ts) async {
    if (image.isEmpty) return avatars_.remove(peerId) != null;
    avatars_[peerId] = image; // the real store re-encodes in Rust first
    return true;
  }

  @override
  Future<void> setChatPeer(String chatId, String peerId) async => chatPeers[chatId] = peerId;

  final bios_ = <String, String>{};
  @override
  Future<Map<String, String>> bios() async => Map.of(bios_);
  @override
  Future<bool> setBio(String peerId, String bio, int ts) async {
    if (bio.isEmpty) return bios_.remove(peerId) != null;
    if (bios_[peerId] == bio) return false;
    bios_[peerId] = bio;
    return true;
  }

  /// peer → record, in the order added (the real store keeps the date).
  final contacts_ = <String, ContactRecord>{};
  @override
  Future<List<ContactRecord>> contacts() async => contacts_.values.toList();
  @override
  Future<bool> addContact(String peerId, String name, int ts) async {
    final old = contacts_[peerId];
    if (old != null) {
      if (old.name.isEmpty && name.isNotEmpty) {
        contacts_[peerId] = ContactRecord(peerId: peerId, name: name, favourite: old.favourite, addedTs: old.addedTs);
      }
      return false;
    }
    contacts_[peerId] = ContactRecord(peerId: peerId, name: name, addedTs: ts);
    return true;
  }

  @override
  Future<bool> removeContact(String peerId) async => contacts_.remove(peerId) != null;
  @override
  Future<bool> setFavourite(String peerId, bool favourite) async {
    final old = contacts_[peerId];
    if (old == null) return false;
    contacts_[peerId] = ContactRecord(peerId: peerId, name: old.name, favourite: favourite, addedTs: old.addedTs);
    return true;
  }
}

/// NetService that knows who I am (my identity key).
class _Me extends NetService {
  _Me(super.ref, this.me);
  final String me;
  @override
  String? get myIdentityHex => me;
}

final group = 'ab' * 20; // looks like an MLS group id
final alice = 'a1' * 32;
final dm = 'dd' * 20; // a personal chat
final stranger = 'cd' * 20; // a message request

void main() {
  late FakeMessageStore store;
  late FakeSender sender;
  late FakePeopleStore people;
  late MemoryStore settings;
  late ProviderContainer c;
  String? pinned;

  setUp(() async {
    store = FakeMessageStore();
    sender = FakeSender();
    people = FakePeopleStore();
    settings = MemoryStore();
    pinned = null;
    c = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        peopleStoreProvider.overrideWithValue(people),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        chatsProvider.overrideWith(
          (ref) async => [
            ChatPreview(id: group, name: 'Family', group: true, preview: '', time: '', pinnedMsg: pinned),
            const ChatPreview(id: 'demo-chat', name: 'Demo', preview: '', time: ''),
            ChatPreview(id: dm, name: 'Аня', preview: '', time: ''),
            ChatPreview(id: stranger, name: 'Stranger', preview: '', time: '', request: true),
          ],
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(chatsProvider.future);
    await c.read(readReceiptsProvider.future);
  });

  // Tech-debt 2.27 (review): on a slow link my first line waited for my
  // name to go out before it even showed in the chat.
  test('my first message shows at once; my name still goes out before it', () async {
    await c.read(profileNameProvider.notifier).save('Вера');
    final slow = Completer<void>();
    sender.hold = slow.future;
    final sending = c.read(messageActionsProvider).sendText(group, 'привет');
    await Future<void>.delayed(Duration.zero);
    expect(store.rows.map((r) => r.body), ['привет'], reason: 'on screen before the name went out');
    expect(sender.sent, isEmpty);
    slow.complete();
    await sending;
    expect(sender.actions.first['t'], 'profile');
    expect(sender.sent.single, startsWith('привет|'));
  });

  test('my name goes to each real chat once per name, and again after a rename', () async {
    final p = c.read(peopleProvider);
    expect(await p.ensureShared(group), isFalse, reason: 'no name yet');
    await c.read(profileNameProvider.notifier).save('Вера');
    expect(await p.ensureShared(group), isTrue);
    expect(await p.ensureShared(group), isFalse, reason: 'already knows it');
    expect(await p.ensureShared('demo-chat'), isFalse, reason: 'not an MLS chat');
    expect(await p.ensureShared(stranger), isFalse, reason: 'a message request does not get my name');
    expect(sender.actions, [
      {'t': 'profile', 'name': 'Вера'},
    ]);

    await c.read(profileNameProvider.notifier).save('Вера К.');
    expect(await p.shareEverywhere(), 2, reason: 'the group and the personal chat');
    expect(sender.actions.last, {'t': 'profile', 'name': 'Вера К.'});
  });

  test('my photo travels with my name; a new photo is announced, the same one is not', () async {
    final p = c.read(peopleProvider);
    await c.read(profileNameProvider.notifier).save('Вера');
    await c.read(profileAvatarProvider.notifier).save('AQID');
    expect(await p.ensureShared(group), isTrue);
    expect(sender.actions.last, {'t': 'profile', 'name': 'Вера', 'avatar': 'AQID'});
    expect(await p.ensureShared(group), isFalse);
    await c.read(profileAvatarProvider.notifier).save('BAUG');
    expect(await p.ensureShared(group), isTrue, reason: 'new photo');
    await c.read(profileAvatarProvider.notifier).save('');
    expect(await p.ensureShared(group), isTrue, reason: 'photo removed');
    expect(sender.actions.last, {'t': 'profile', 'name': 'Вера'});
  });

  test("their photo is kept by key; in a personal chat they become its person", () async {
    final a = c.read(messageActionsProvider);
    await a.onIncomingAction(group, 'profile', '{"name":"Аня","avatar":"AQID"}', alice);
    expect(people.avatars_[alice], [1, 2, 3]);
    expect((await c.read(peerAvatarsProvider.future))[alice], [1, 2, 3]);
    expect(people.chatPeers, isEmpty, reason: 'a group has no single person');
    await a.onIncomingAction(group, 'profile', '{"name":"Аня","avatar":""}', alice);
    expect(people.avatars_.containsKey(alice), isFalse, reason: 'photo removed');
    await a.onIncomingAction(dm, 'profile', '{"name":"Аня"}', alice);
    expect(people.chatPeers[dm], alice);
  });

  test('sending a message announces my name first', () async {
    await c.read(profileNameProvider.notifier).save('Вера');
    await c.read(messageActionsProvider).sendText(group, 'привет');
    expect(sender.actions.single, {'t': 'profile', 'name': 'Вера'});
    expect(sender.sent.single, startsWith('привет'));
  });

  test("a member's profile is stored and shown; unknown people are a plain \"Member\"", () async {
    final a = c.read(messageActionsProvider);
    await a.onIncomingAction(group, 'profile', '{"name":"Аня"}', alice);
    expect(people.names_[alice], 'Аня');
    expect(displayNameOf(alice, await c.read(peerNamesProvider.future)), 'Аня');
    expect(displayNameOf('cd' * 32, const {}), 'Member', reason: 'not a code like "cdcd cdcd"');
    expect(await a.onIncomingAction(group, 'profile', '{"name":"X"}', null), isFalse, reason: 'needs a sender');
  });

  test('my own name for someone wins everywhere; clearing it brings theirs back', () async {
    final store = MemoryStore();
    final pc = ProviderContainer(
      overrides: [settingsStoreProvider.overrideWithValue(store), peopleStoreProvider.overrideWithValue(people)],
    );
    addTearDown(pc.dispose);
    people.names_[alice] = 'Аня';
    final aliases = pc.read(contactAliasesProvider.notifier);
    await aliases.set(alice.toUpperCase(), '  Анечка\nсестра  ');
    expect(store.map['contact_aliases'], contains('Анечка сестра'), reason: 'one line, kept on this device');
    expect(displayNameOf(alice, await pc.read(peerNamesProvider.future)), 'Анечка сестра');
    expect((await people.names())[alice], 'Аня', reason: 'their own name is still there for "restore"');
    await aliases.set(alice, 'x' * 100);
    expect((await pc.read(peerNamesProvider.future))[alice], 'x' * kMaxContactNameChars);
    await aliases.set(alice, '   ');
    expect(displayNameOf(alice, await pc.read(peerNamesProvider.future)), 'Аня');
    expect(store.map['contact_aliases'], '{}');
    expect(withAliases({'AB': 'Боб'}, {'ab': 'Бобик'}), {'AB': 'Бобик', 'ab': 'Бобик'}, reason: 'any key case');
  });

  test('pins travel to the chat and come back from it', () async {
    final a = c.read(messageActionsProvider);
    await a.pin(group, w);
    expect(store.calls.last, 'pin $w');
    expect(sender.actions.last, {'t': 'pin', 'target': w, 'pinned': true});

    await a.pin('demo-chat', w);
    expect(sender.actions.length, 1, reason: 'demo chats stay local');

    await a.onIncomingAction(group, 'pin', '{"target":"$w","pinned":true}', alice);
    expect(store.calls.last, 'pin $w');
  });

  test('an unpin from someone else only clears the message it names', () async {
    pinned = w;
    store.pinned[group] = w;
    c.invalidate(chatsProvider);
    await c.read(chatsProvider.future);
    final a = c.read(messageActionsProvider);
    final before = store.calls.length;
    await a.onIncomingAction(group, 'pin', '{"target":"0f8fad5b-d9cb-469f-a165-000000000000","pinned":false}', alice);
    expect(store.calls.length, before, reason: 'a different message is pinned');
    await a.onIncomingAction(group, 'pin', '{"target":"$w","pinned":false}', alice);
    expect(store.calls.last, 'pin null');
  });

  test('unblocking from anywhere (the Blocked list has no chat) lets their calls ring again', () async {
    final p = c.read(peopleProvider);
    await p.setBlocked(alice, true, personalChatId: 'dm1');
    expect(settings.map['blocked_chats'], 'dm1=$alice');
    expect(blockedChatIds(settings.map['blocked_chats']!), {'dm1'});
    await p.setBlocked(alice, false);
    expect(settings.map['blocked_chats'], '');
  });

  test('nothing optional goes to a personal chat with someone blocked', () async {
    await c.read(profileNameProvider.notifier).save('Вера');
    await c.read(blockedChatsProvider.notifier).save('$group=$alice');
    store.pending = [w];
    expect(await c.read(peopleProvider).ensureShared(group), isFalse, reason: 'no name');
    await c.read(messageActionsProvider).sendReadReceipts(group);
    await c.read(messageActionsProvider).typing(group, true);
    await c.read(messageActionsProvider).react(group, w, '👍');
    expect(sender.actions, isEmpty, reason: 'no receipts, typing or reactions');
  });

  test('blocking is local and reversible', () async {
    final p = c.read(peopleProvider);
    expect(await p.isBlocked(alice), isFalse);
    await p.setBlocked(alice, true);
    expect(await p.isBlocked(alice), isTrue);
    expect(await c.read(blockedPeersProvider.future), {alice});
    await p.setBlocked(alice, false);
    expect(await p.isBlocked(alice), isFalse);
    expect(await p.isBlocked(null), isFalse);
  });

  // Owner, 2026-10-18: blocked from a group's member list, they still saw
  // me online, kept my photo, and their calls rang.
  test('blocking finds their personal chat, says "not around" there and takes my photo back', () async {
    final c2 = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(FakeMessageStore()),
        messageSenderProvider.overrideWithValue(sender),
        peopleStoreProvider.overrideWithValue(people),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        chatsProvider.overrideWith(
          (ref) async => [
            ChatPreview(id: group, name: 'Family', group: true, preview: '', time: '', peerId: alice),
            ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice.toUpperCase()),
          ],
        ),
      ],
    );
    addTearDown(c2.dispose);
    await c2.read(profileNameProvider.notifier).save('Вера');
    people.sent[dm] = 'Вера\u0000123:456';
    await c2.read(peopleProvider).setBlocked(alice, true); // no chat given
    expect(settings.map['blocked_chats'], '$dm=$alice', reason: 'their personal chat, not the group');
    expect(sender.actions, [
      {'t': 'presence', 'hidden': true},
      {'t': 'profile', 'name': 'Вера'},
    ], reason: 'offline for them, and a profile without the photo');
    expect(people.sent[dm], '', reason: 'unblocking shares the photo again');
  });

  // ADR-071 — blocking revokes the access key I gave them on the server
  // (so nothing of theirs wakes my phone); unblocking brings it back. Both
  // go through the same refresh, which re-sends every decision.
  test('block and unblock each update my access keys on the server', () async {
    var refreshes = 0;
    final c2 = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(FakeMessageStore()),
        messageSenderProvider.overrideWithValue(sender),
        peopleStoreProvider.overrideWithValue(people),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        accessKeysRefresherProvider.overrideWithValue(() async {
          refreshes++;
        }),
        chatsProvider.overrideWith(
          (ref) async => [ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice)],
        ),
      ],
    );
    addTearDown(c2.dispose);
    await c2.read(peopleProvider).setBlocked(alice, true, personalChatId: dm);
    expect(people.blocked_, {alice}, reason: 'stored before the server is asked');
    expect(refreshes, 1);
    await c2.read(peopleProvider).setBlocked(alice, false, personalChatId: dm);
    expect(people.blocked_, isEmpty);
    expect(refreshes, 2);
  });

  test('a failing refresh (offline) never breaks blocking', () async {
    final c2 = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(FakeMessageStore()),
        messageSenderProvider.overrideWithValue(sender),
        peopleStoreProvider.overrideWithValue(people),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        accessKeysRefresherProvider.overrideWithValue(() async => throw StateError('offline')),
        chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
      ],
    );
    addTearDown(c2.dispose);
    await c2.read(peopleProvider).setBlocked(alice, true);
    await Future<void>.delayed(Duration.zero);
    expect(people.blocked_, {alice});
  });

  // ADR-052 — contacts are their own list.
  ft.group('contacts', () {
    test('adding, starring and removing; the name I knew them by stays until theirs comes', () async {
      final p = c.read(peopleProvider);
      expect(await p.addContact(alice.toUpperCase(), name: ' Аня '), isTrue);
      expect(await p.addContact(alice), isFalse, reason: 'already there (keys compare lower case)');
      expect((await c.read(contactsProvider.future)).single.name, 'Аня');
      await p.setFavourite(alice, true);
      expect((await c.read(contactsProvider.future)).single.favourite, isTrue);
      expect(await p.removeContact(alice), isTrue);
      expect(await c.read(contactsProvider.future), isEmpty);
      expect(await p.addContact(''), isFalse);
    });

    test('deleting the chat never removes the contact', () async {
      final chatStore = FakeChatStore();
      final c2 = ProviderContainer(
        overrides: [
          chatStoreProvider.overrideWithValue(chatStore),
          peopleStoreProvider.overrideWithValue(people),
          settingsStoreProvider.overrideWithValue(settings),
          messageSenderProvider.overrideWithValue(sender),
          chatsProvider.overrideWith(
            (ref) async => [ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice)],
          ),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(peopleProvider).addContact(alice, name: 'Аня');
      await c2.read(chatActionsProvider).delete(dm);
      expect(chatStore.calls, ['delete $dm']);
      expect((await c2.read(contactsProvider.future)).map((r) => r.peerId), [alice]);
    });

    test('accepting a message request makes them a contact; just reading it does not', () async {
      final chatStore = FakeChatStore();
      var refreshes = 0;
      final c2 = ProviderContainer(
        overrides: [
          // ADR-071 — accepting hands them my access key.
          accessKeysRefresherProvider.overrideWithValue(() async {
            refreshes++;
          }),
          chatStoreProvider.overrideWithValue(chatStore),
          peopleStoreProvider.overrideWithValue(people),
          settingsStoreProvider.overrideWithValue(settings),
          messageSenderProvider.overrideWithValue(sender),
          chatsProvider.overrideWith(
            (ref) async => [ChatPreview(id: stranger, name: 'Боб', preview: '', time: '', request: true, peerId: alice)],
          ),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(chatsProvider.future);
      await c2.read(chatActionsProvider).markRead(stranger);
      expect(people.contacts_, isEmpty);
      expect(refreshes, 0, reason: 'a request gets no key');
      await c2.read(chatActionsProvider).acceptRequest(stranger);
      expect(people.contacts_.keys, [alice]);
      expect(people.contacts_[alice]!.name, 'Боб');
      expect(refreshes, 1);
    });

    test("an accepted chat's person becomes a contact when their profile first names them — once", () async {
      final a = c.read(messageActionsProvider);
      await a.onIncomingAction(stranger, 'profile', '{"name":"Незнакомец"}', 'cd' * 32);
      expect(people.contacts_, isEmpty, reason: 'a message request is not a contact');
      await a.onIncomingAction(group, 'profile', '{"name":"Аня"}', alice);
      expect(people.contacts_, isEmpty, reason: 'nor is everyone in my groups');
      await a.onIncomingAction(dm, 'profile', '{"name":"Аня"}', alice);
      expect(people.contacts_[alice]?.name, 'Аня');
      await c.read(peopleProvider).removeContact(alice);
      // The chat knows its person now (chatsProvider would say so): a later
      // profile doesn't bring back someone I removed.
      final c2 = ProviderContainer(
        overrides: [
          messageStoreProvider.overrideWithValue(FakeMessageStore()),
          messageSenderProvider.overrideWithValue(sender),
          peopleStoreProvider.overrideWithValue(people),
          settingsStoreProvider.overrideWithValue(settings),
          linkPreviewBaseUrlProvider.overrideWithValue(() => null),
          chatsProvider.overrideWith(
            (ref) async => [ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice)],
          ),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(chatsProvider.future);
      await c2.read(messageActionsProvider).onIncomingAction(dm, 'profile', '{"name":"Аня Б."}', alice);
      expect(people.contacts_, isEmpty);
    });
  });

  // ADR-052 — the bio nobody saw.
  ft.group('bio', () {
    test('my bio travels with my name and photo; a new one is announced, the same one is not', () async {
      final p = c.read(peopleProvider);
      await c.read(profileNameProvider.notifier).save('Вера');
      expect(await p.ensureShared(group), isTrue);
      expect(sender.actions.last, {'t': 'profile', 'name': 'Вера'}, reason: 'no bio: as before');
      await c.read(profileAboutProvider.notifier).save('  Пишите\nднём ');
      expect(await p.ensureShared(group), isTrue, reason: 'the bio is new');
      expect(sender.actions.last, {'t': 'profile', 'name': 'Вера', 'bio': 'Пишите днём'});
      expect(await p.ensureShared(group), isFalse);
      await c.read(profileAboutProvider.notifier).save('');
      expect(await p.ensureShared(group), isTrue, reason: 'bio removed');
      expect(sender.actions.last, {'t': 'profile', 'name': 'Вера'});
    });

    test('strangers and people I blocked do not get it', () async {
      final p = c.read(peopleProvider);
      await c.read(profileNameProvider.notifier).save('Вера');
      await c.read(profileAboutProvider.notifier).save('Пишите днём');
      expect(await p.ensureShared(stranger), isFalse, reason: 'a message request');
      await c.read(blockedChatsProvider.notifier).save('$dm=$alice');
      expect(await p.ensureShared(dm), isFalse, reason: 'blocked');
      expect(sender.actions, isEmpty);
    });

    test('blocking sends a profile without it — clearing it on their side', () async {
      final c2 = ProviderContainer(
        overrides: [
          messageStoreProvider.overrideWithValue(FakeMessageStore()),
          messageSenderProvider.overrideWithValue(sender),
          peopleStoreProvider.overrideWithValue(people),
          settingsStoreProvider.overrideWithValue(settings),
          linkPreviewBaseUrlProvider.overrideWithValue(() => null),
          chatsProvider.overrideWith(
            (ref) async => [ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice)],
          ),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(profileNameProvider.notifier).save('Вера');
      await c2.read(profileAboutProvider.notifier).save('Пишите днём');
      await c2.read(peopleProvider).setBlocked(alice, true);
      expect(sender.actions.last, {'t': 'profile', 'name': 'Вера'});
    });

    test('their bio is kept by key, shown, and cleared by a profile without one', () async {
      final a = c.read(messageActionsProvider);
      await a.onIncomingAction(group, 'profile', '{"name":"Аня","bio":"Дизайнер"}', alice.toUpperCase());
      expect((await c.read(peerBiosProvider.future))[alice], 'Дизайнер');
      await a.onIncomingAction(group, 'profile', '{"name":"Аня"}', alice);
      expect(people.bios_, isEmpty);
    });

    // Owner, 2026-10-19: "I don't see the bio when I open someone's
    // profile." Their bio went out once per chat; a phone still on a build
    // without bios dropped it, and the "already told" mark kept it from
    // ever going again — nor did anyone who joined later get it.
    ft.group('reaches people who missed it', () {
      late List<String> members;
      late FakeGroupOps ops;
      late ProviderContainer c2;
      final bob = 'b0' * 32;

      setUp(() async {
        members = ['aa' * 32, alice];
        ops = FakeGroupOps();
        c2 = ProviderContainer(
          overrides: [
            messageStoreProvider.overrideWithValue(FakeMessageStore()),
            messageSenderProvider.overrideWithValue(sender),
            peopleStoreProvider.overrideWithValue(people),
            settingsStoreProvider.overrideWithValue(settings),
            groupOpsProvider.overrideWithValue(ops),
            linkPreviewBaseUrlProvider.overrideWithValue(() => null),
            chatMembersLoaderProvider.overrideWithValue((_) async => members),
            chatsProvider.overrideWith(
              (ref) async => [
                ChatPreview(id: group, name: 'Family', group: true, preview: '', time: ''),
                ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice),
              ],
            ),
          ],
        );
        addTearDown(c2.dispose);
        await c2.read(chatsProvider.future);
        await c2.read(profileNameProvider.notifier).save('Вера');
        await c2.read(profileAboutProvider.notifier).save('Пишите днём');
      });

      test('a chat told by an older build hears it once more, then not again', () async {
        // What 0.4 – 0.6 stored: name, then the bio's fingerprint.
        people.sent[dm] = 'Вера';
        people.sent[group] = 'Вера\u0001123';
        final p = c2.read(peopleProvider);
        expect(await p.shareEverywhere(), 2);
        expect(sender.actions, everyElement({'t': 'profile', 'name': 'Вера', 'bio': 'Пишите днём'}));
        expect(await p.shareEverywhere(), 0, reason: 'now they know');
        expect(sender.actions, hasLength(2));
      });

      test('someone who joins a group later gets it, at once', () async {
        final p = c2.read(peopleProvider);
        expect(await p.ensureShared(group), isTrue);
        expect(await p.ensureShared(group), isFalse);
        members = [...members, bob];
        await c2.read(messageActionsProvider).onGroupCommit(group); // Боб added
        expect(sender.actions, hasLength(2));
        expect(sender.actions.last['bio'], 'Пишите днём');
        await c2.read(messageActionsProvider).onGroupCommit(group); // e.g. my own commit's echo
        expect(sender.actions, hasLength(2), reason: 'same members: nothing new to tell');
      });

      test('members unreadable for a moment: the same profile is not sent twice', () async {
        final p = c2.read(peopleProvider);
        final known = members;
        members = const [];
        expect(await p.ensureShared(group), isTrue);
        members = known;
        expect(await p.ensureShared(group), isFalse, reason: 'same profile; the members are just remembered now');
        expect(people.sent[group], contains('\u0003'));
        members = [...known, bob];
        expect(await p.ensureShared(group), isTrue);
      });

      test('a pass already running: no double send, and a new bio still goes out', () async {
        final p = c2.read(peopleProvider);
        final slow = Completer<void>();
        sender.hold = slow.future;
        final first = p.shareEverywhere();
        await Future<void>.delayed(Duration.zero);
        final second = p.shareEverywhere(); // a reconnect during the pass
        await c2.read(profileAboutProvider.notifier).save('Пишите вечером');
        final third = p.shareEverywhere(); // the bio changed meanwhile
        expect(identical(second, third), isTrue, reason: 'calls during a pass share the next one');
        slow.complete();
        expect(await first, 2, reason: 'the group with the old bio (held), the personal chat with the new');
        expect(await second, 1, reason: 'the group again — the running pass had read the old bio');
        expect(sender.actions.map((a) => a['bio']), ['Пишите днём', 'Пишите вечером', 'Пишите вечером']);
      });
    });

    test('a bio is one line, at most the wire limit', () {
      expect(oneLineBio(' a\r\nb\tc '), 'a b c');
      expect(oneLineBio('я' * (kMaxBioChars + 10)).length, kMaxBioChars);
      expect(oneLineBio('👩‍💻' * (kMaxBioChars + 1)), '👩‍💻' * kMaxBioChars, reason: 'cut between characters, not inside one');
    });
  });

  // Owner, 2026-11-01 — "why do all my contacts have my photo?": my own
  // profile from my other device was taken for the other person's.
  ft.group('my own profile from my other device', () {
    final me = 'e0' * 32;
    late ProviderContainer c3;
    late List<ChatPreview> chats;

    setUp(() async {
      chats = [
        ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: me),
        ChatPreview(id: group, name: 'Family', group: true, preview: '', time: ''),
      ];
      c3 = ProviderContainer(
        overrides: [
          messageStoreProvider.overrideWithValue(FakeMessageStore()),
          messageSenderProvider.overrideWithValue(sender),
          peopleStoreProvider.overrideWithValue(people),
          settingsStoreProvider.overrideWithValue(settings),
          linkPreviewBaseUrlProvider.overrideWithValue(() => null),
          netServiceProvider.overrideWith((ref) => _Me(ref, me)),
          chatMembersLoaderProvider.overrideWithValue((_) async => [me.toUpperCase(), alice]),
          chatsProvider.overrideWith((ref) async => chats),
        ],
      );
      addTearDown(c3.dispose);
      await c3.read(chatsProvider.future);
    });

    test('never makes me the person of a chat, nor stores my photo as theirs', () async {
      await c3.read(messageActionsProvider).onIncomingAction(dm, 'profile', '{"name":"Вера","avatar":"AQID"}', me);
      expect(people.chatPeers, isEmpty);
      expect(people.avatars_, isEmpty);
      expect(people.contacts_, isEmpty);
    });

    test('a chat that got me as its person gets the real one back; I leave my contacts', () async {
      people.contacts_[me] = ContactRecord(peerId: me, name: 'Вера');
      people.contacts_[alice] = ContactRecord(peerId: alice, name: 'Аня');
      expect(await c3.read(peopleProvider).repairSelfPeers(chats), 1);
      expect(people.chatPeers, {dm: alice}, reason: 'the group is left alone');
      expect(people.contacts_.keys, [alice]);
      people.chatPeers.clear();
      chats = [ChatPreview(id: dm, name: 'Аня', preview: '', time: '', peerId: alice)];
      expect(await c3.read(peopleProvider).repairSelfPeers(chats), 0, reason: 'nothing to repair');
    });

    // Owner, 2026-11-03 — "Message" made a second chat: the row had no person.
    test('a chat that does not know its person learns it from its members', () async {
      final request = 'ee' * 20;
      chats = [
        ChatPreview(id: dm, name: 'Аня', preview: '', time: ''),
        ChatPreview(id: request, name: 'New chat', preview: '', time: '', request: true),
      ];
      expect(await c3.read(peopleProvider).repairSelfPeers(chats), 2);
      expect(people.chatPeers, {dm: alice, request: alice});
      expect(people.contacts_.keys, [alice], reason: 'the accepted chat\'s person becomes a contact');
    });
  });
}
