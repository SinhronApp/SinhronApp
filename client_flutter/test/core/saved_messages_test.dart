// ADR-055 — Saved messages: always there, made once on first use, quiet.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/saved_messages.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';

import 'message_actions_test.dart' show FakeMessageStore, FakeSender;
import 'settings_providers_test.dart' show MemoryStore;

const kSavedId = 'c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0';

/// Saved messages without Rust: [id] is the setting, [rows] the chat rows made.
class FakeSavedBackend implements SavedMessagesBackend {
  FakeSavedBackend({this.id});
  String? id;
  bool offline = false;
  int created = 0;
  final rows = <String>[];
  final synced = <String>[];

  @override
  Future<String?> readId() async => id;

  @override
  Future<String> createGroup() async {
    if (offline) throw StateError('net not connected');
    created++;
    await Future<void>.delayed(Duration.zero);
    return id = kSavedId;
  }

  @override
  Future<void> addChatRow(String id, String name) async => rows.add(id);

  @override
  void syncDevices(String id) => synced.add(id);

  /// ADR-074 — groups this device is in (null: can't tell); my other
  /// devices online lately; merges done.
  final member = <String, bool?>{};
  bool otherOnline = false;
  final merges = <(String, String)>[];

  @override
  Future<bool?> canPost(String id) async => member.containsKey(id) ? member[id] : true;

  @override
  Future<bool> otherDeviceOnline(Duration within) async => otherOnline;

  @override
  Future<int> merge(String from, String to) async {
    merges.add((from, to));
    rows.remove(from);
    names.remove(from);
    return 3;
  }

  /// Former Saved chats; row names (default "Maria"); groups with only me.
  Set<String> former = {};
  final names = <String, String>{};
  final onlyMeIn = <String>{};

  @override
  Future<Set<String>> readFormer() async => {...former};

  @override
  Future<void> writeFormer(Set<String> ids) async => former = {...ids};

  @override
  Future<List<({String id, String name})>> chats() async => [for (final r in rows) (id: r, name: names[r] ?? 'Maria')];

  @override
  Future<bool> onlyMe(String id) async => onlyMeIn.contains(id);
}

ChatPreview chat(String id, {String name = 'Maria'}) => ChatPreview(id: id, name: name, preview: 'hi', time: '');

void main() {
  test('the Saved chat is marked and first; a stand-in until it exists', () {
    final list = [chat('a' * 32), chat(kSavedId, name: 'whatever'), chat('b' * 32)];
    final marked = markSavedChat(list, kSavedId);
    expect(marked.first.id, kSavedId);
    expect(marked.first.saved, isTrue);
    expect(marked.first.name, 'Saved Messages');
    expect(marked.skip(1).map((c) => c.saved), everyElement(isFalse));
    expect(savedChatEntry(marked).id, kSavedId, reason: 'the real one');

    expect(markSavedChat(list, null), same(list));
    final standIn = savedChatEntry(list);
    expect(standIn.id, kSavedChatPendingId);
    expect(standIn.saved, isTrue);
    expect(looksLikeMlsGroupId(standIn.id!), isFalse, reason: 'nothing is ever sent to the stand-in');
  });

  group('making it', () {
    late FakeSavedBackend backend;
    late ProviderContainer c;
    setUp(() {
      backend = FakeSavedBackend();
      c = ProviderContainer(
        overrides: [
          savedMessagesBackendProvider.overrideWithValue(backend),
          chatsProvider.overrideWith((ref) async {
            final saved = await ref.watch(savedChatIdProvider.future);
            return markSavedChat([chat('a' * 32), for (final r in backend.rows) chat(r)], saved);
          }),
        ],
      );
      addTearDown(c.dispose);
    });

    test('first use makes one group, its row and a device sync; later uses reuse it', () async {
      final saved = c.read(savedMessagesProvider);
      final ids = await Future.wait([saved.ensure(), saved.resolve(kSavedChatPendingId)]);
      expect(ids, [kSavedId, kSavedId]);
      expect(backend.created, 1, reason: 'two taps at once still make one');
      expect(backend.rows, [kSavedId]);
      expect(backend.synced, [kSavedId], reason: 'my other devices get added');

      expect(await saved.ensure(), kSavedId);
      expect(backend.created, 1);
      final chats = await c.read(chatsProvider.future);
      expect(chats.first.saved, isTrue);
      expect(await saved.resolve('a' * 32), 'a' * 32, reason: 'other chats pass through');
    });

    test('offline: nothing is made, the error reaches the caller', () async {
      backend.offline = true;
      await expectLater(c.read(savedMessagesProvider).ensure(), throwsStateError);
      expect(backend.rows, isEmpty);
      await expectLater(c.read(savedMessagesProvider).ensure(), throwsStateError, reason: 'tries again next time');
    });

    test('ADR-074 — restored Saved chat of a phone that is gone: a new one takes its notes', () async {
      final old = 'ee' * 16;
      backend.id = old;
      backend.rows.add(old);
      final saved = c.read(savedMessagesProvider);

      expect(await saved.repair(), isNull, reason: 'this device is in it: nothing to do');
      backend.member[old] = null;
      expect(await saved.repair(), isNull, reason: "can't tell yet (not signed in)");
      backend.member[old] = false;
      backend.otherOnline = true;
      expect(await saved.repair(), isNull, reason: 'another of my devices was on lately: it adds this one');
      expect(backend.created, 0);

      backend.otherOnline = false;
      expect(await saved.repair(), kSavedId);
      expect(backend.created, 1);
      expect(backend.merges, [(old, kSavedId)]);
      expect(backend.rows, [kSavedId]);
      expect(backend.synced, [kSavedId], reason: 'my other devices are added to the new one');
      expect(backend.former, {old}, reason: 'late notes to the old group land in the new one');
      c.invalidate(savedChatIdProvider);
      expect(await saved.repair(), isNull, reason: 'done once');
    });

    test('two Saved chats (each device made its own): the other one folds into Saved', () async {
      final mine = kSavedId, theirs = 'ff' * 16, group = 'aa' * 16, emptyGroup = 'bb' * 16, old = 'cc' * 16;
      backend.id = mine;
      backend.rows.addAll([mine, theirs, group, emptyGroup, old]);
      backend.names
        ..[theirs] = 'Saved Messages'
        ..[emptyGroup] = 'Избранное';
      backend.onlyMeIn.addAll([theirs, group]);
      backend.former = {old};
      final saved = c.read(savedMessagesProvider);

      expect(await saved.tidy(), 2);
      expect(backend.merges, [(theirs, mine), (old, mine)]);
      expect(backend.rows, [mine, group, emptyGroup],
          reason: 'a group of only me with another name, and a "Saved" name with others in it, stay');
      expect(backend.former, {old, theirs});
      expect(await saved.tidy(), 0, reason: 'done once');

      backend.id = null;
      backend.rows.add(theirs);
      expect(await saved.tidy(), 0, reason: 'no Saved chat here yet: nothing to fold into');
    });

    test('a setting without its chat row (deleted chat): a new one is made', () async {
      backend.id = 'dd' * 16;
      expect(await c.read(savedMessagesProvider).ensure(), kSavedId);
      expect(backend.created, 1);
    });
  });

  test('no receipts, typing or screenshot lines in Saved messages; reactions still sync', () async {
    final store = FakeMessageStore();
    final sender = FakeSender();
    final c = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        savedMessagesBackendProvider.overrideWithValue(FakeSavedBackend(id: kSavedId)),
        chatsProvider.overrideWith(
          (ref) async => [ChatPreview(id: kSavedId, name: 'Saved', preview: '', time: '', disappearSecs: 60)],
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(savedChatIdProvider.future);
    await c.read(chatsProvider.future);
    final a = c.read(messageActionsProvider);
    store.pending = ['00000000-0000-7000-8000-000000000001'];

    await a.sendDeliveryReceipts(kSavedId);
    await a.sendReadReceipts(kSavedId);
    await a.typing(kSavedId, true);
    expect(await a.screenshotTaken(kSavedId), isFalse);
    expect(sender.actions, isEmpty);

    await a.react(kSavedId, '00000000-0000-7000-8000-000000000001', '👍');
    expect(sender.actions.single['t'], 'reaction', reason: 'my other devices see it');
  });
}
