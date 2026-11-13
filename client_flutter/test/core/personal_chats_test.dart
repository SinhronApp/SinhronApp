// Owner, 2026-11-03 — two personal chats with one person: found, folded.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/personal_chats.dart';

const me = 'e0e0';
const grisha = 'a1a1';
const anna = 'b2b2';

/// Personal chats without Rust: rows, each group's members, where this
/// device can post, merges done.
class FakePersonalBackend implements PersonalChatsBackend {
  final rows = <PersonalRow>[];
  final members_ = <String, Set<String>>{};
  final inactive = <String>{};
  final merges = <(String, String)>[];
  final peers = <String, String>{};
  final renamed = <String, String>{};
  Set<String> blocked_ = {};
  String? saved;
  Map<String, String> former = {};

  void add(String id, {String name = 'Grisha', String? with_, bool group = false, bool request = false, String? peer}) {
    rows.add((id: id, name: name, group: group, request: request, peer: peer));
    members_[id] = {me, ?with_};
  }

  @override
  String get me => 'e0e0';
  @override
  Future<List<PersonalRow>> chats() async => [...rows];
  @override
  Future<String?> savedId() async => saved;
  @override
  Future<Set<String>> blocked() async => blocked_;
  @override
  Future<Set<String>> members(String id) async => members_[id] ?? const {};
  @override
  Future<bool> active(String id) async => !inactive.contains(id);
  @override
  Future<int> merge(String from, String to) async {
    merges.add((from, to));
    rows.removeWhere((r) => r.id == from);
    return 2;
  }

  @override
  Future<void> setPeer(String id, String peer) async => peers[id] = peer;
  @override
  Future<void> renameIf(String id, String from, String to) async => renamed[id] = to;
  @override
  Future<Map<String, String>> readFormer() async => {...former};
  @override
  Future<void> writeFormer(Map<String, String> m) async => former = {...m};
}

String g(String c) => c * 32;

void main() {
  late FakePersonalBackend b;
  late ProviderContainer c;
  setUp(() {
    b = FakePersonalBackend();
    c = ProviderContainer(
      overrides: [personalChatsBackendProvider.overrideWithValue(b), chatsProvider.overrideWith((ref) async => [])],
    );
    addTearDown(c.dispose);
  });

  test('two chats with one person become one: the lowest group id, on every device the same', () async {
    final old = g('3'), fresh = g('1'), other = g('5');
    b.add(old, with_: grisha);
    b.add(fresh, with_: grisha, peer: grisha);
    b.add(other, with_: anna, name: 'Anna');
    b.former = {g('9'): old};

    expect(await c.read(personalChatsProvider).tidy(), 1);
    expect(b.merges, [(old, fresh)]);
    expect(b.rows.map((r) => r.id), [fresh, other]);
    expect(b.peers, isEmpty, reason: 'the kept chat knows its person');
    expect(b.former, {g('9'): fresh, old: fresh});
    expect(personalRedirect(b.former, old, [fresh, other]), fresh, reason: 'what they write into the old group lands here');
    expect(personalRedirect(b.former, old, [other]), isNull, reason: 'the kept chat deleted: the old one comes back (211)');
    expect(personalRedirect(b.former, g('7'), [fresh]), isNull);
    expect(await c.read(personalChatsProvider).tidy(), 0, reason: 'done once');
  });

  test('a message request never takes over the chat I have (critic:2)', () async {
    final real = g('f'), fake = g('0');
    b.add(real, with_: grisha, peer: grisha);
    b.add(fake, with_: grisha, name: 'Гриша', request: true); // lower id, a stranger's invite
    expect(await c.read(personalChatsProvider).find(grisha), real, reason: '"Message" opens the accepted chat');
    expect(await c.read(personalChatsProvider).tidy(), 1);
    expect(b.merges, [(fake, real)], reason: 'the real chat and its history stay');
    expect(b.rows.single, (id: real, name: 'Grisha', group: false, request: false, peer: grisha));
    expect(b.former, {fake: real});
  });

  test('a chain: a chat folded into one that is folded later goes to the last one', () async {
    b.add(g('2'), with_: grisha);
    b.former = {g('4'): g('3')};
    b.add(g('3'), with_: grisha);
    expect(await c.read(personalChatsProvider).tidy(), 1);
    expect(b.former, {g('4'): g('2'), g('3'): g('2')});
  });

  test('waits while this device is not in both groups, or one is not named yet', () async {
    b.add(g('1'), with_: grisha);
    b.add(g('2'), with_: grisha);
    b.inactive.add(g('1'));
    expect(await c.read(personalChatsProvider).tidy(), 0, reason: "can't post to one: maybe not added yet");
    b.inactive.clear();

    b.rows[1] = (id: g('2'), name: 'New chat', group: false, request: true, peer: null);
    expect(await c.read(personalChatsProvider).tidy(), 0, reason: 'a group of two looks personal until its name comes');
    expect(await c.read(personalChatsProvider).tidy(fresh: g('2')), 1, reason: 'back with a message (211): folded');
    expect(b.merges, [(g('2'), g('1'))]);
  });

  test('the kept chat without a name takes the other one\'s', () async {
    b.add(g('1'), with_: grisha, name: 'Новый чат');
    b.add(g('2'), with_: grisha);
    expect(await c.read(personalChatsProvider).tidy(fresh: g('1')), 1);
    expect(b.renamed, {g('1'): 'Grisha'});
  });

  test('groups, Saved, blocked people and other servers\' ids are left alone', () async {
    b.add(g('1'), with_: grisha, group: true, name: 'Family');
    b.add(g('2'), with_: grisha);
    b.add(g('3'));
    b.add(g('4'));
    b.saved = g('3');
    b.add(g('5'), with_: anna);
    b.add(g('6'), with_: anna);
    b.blocked_ = {anna};
    b.add('demo-chat', with_: grisha);
    b.members_[g('7')] = {me, grisha, anna};
    b.add(g('7'), with_: grisha); // three people, not personal
    b.members_[g('7')] = {me, grisha, anna};
    expect(await c.read(personalChatsProvider).tidy(), 0);
    expect(b.merges, isEmpty);
  });

  test('"Message": the chat with them is found, by person or by members', () async {
    b.add(g('4'), with_: grisha); // came by invite: no person on the row
    b.add(g('5'), with_: anna, peer: anna);
    b.add(g('6'), with_: grisha, group: true);
    final p = c.read(personalChatsProvider);
    expect(await p.find(grisha.toUpperCase()), g('4'));
    expect(await p.find(anna), g('5'));
    expect(await p.find('c3c3'), isNull);
    b.add(g('2'), with_: grisha, peer: grisha);
    expect(await p.find(grisha), g('2'), reason: 'two: the one tidy keeps');
  });
}
