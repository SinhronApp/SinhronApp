// Owner, 2026-11-03 — "mum has two chats with me". A personal chat is an
// MLS group of two people; a second one appeared when "Message" (a QR, a
// link, a contact) didn't see the first one (its row had no person yet), or
// when a deleted chat came back next to the new one (status 211). Now:
//  - [PersonalChats.find] looks for a chat with that person by the row's
//    person or, when the row doesn't know it, by the group's members;
//  - [PersonalChats.tidy] folds two chats with one person into one, like
//    the second Saved chat (ADR-055, `SavedMessages.tidy`): the LOWEST group
//    id is kept, so every device of both people picks the same one — but an
//    accepted chat always wins over a message request (critic:2: a request
//    never takes over the chat I have, nor gets accepted by folding). The
//    other group stays (its devices may still write there): what arrives
//    in it lands in the kept chat ([formerPersonalRedirect]).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../services/net_service.dart';
import 'chat_providers.dart';
import 'people.dart' show peopleStoreProvider;
import 'saved_messages.dart' show kSavedChatSetting;

/// Folded personal chats of this device: JSON `{"folded group": "kept chat"}`.
const kPersonalFormerSetting = 'personal_chat_former';

typedef PersonalRow = ({String id, String name, bool group, bool request, String? peer});

/// The FFI calls behind [PersonalChats] (a seam for tests).
class PersonalChatsBackend {
  PersonalChatsBackend(this._ref);
  final Ref _ref;

  String get me => (_ref.read(netServiceProvider).myIdentityHex ?? '').toLowerCase();

  Future<List<PersonalRow>> chats() async => [
    for (final c in await core.storageChatsList())
      (id: c.id, name: c.displayName, group: c.isGroup, request: c.request, peer: c.peerId),
  ];

  Future<String?> savedId() => core.storageSettingGet(key: kSavedChatSetting);

  Future<Set<String>> blocked() async => {for (final p in await _ref.read(peopleStoreProvider).blocked()) p.toLowerCase()};

  /// The group's members (identity keys, lower case); empty when unknown.
  Future<Set<String>> members(String id) async {
    try {
      return {for (final m in await core.syncGroupMembers(groupIdHex: id)) m.toLowerCase()};
    } catch (_) {
      return const {};
    }
  }

  /// Can this device post to [id]? False when it isn't in that group.
  Future<bool> active(String id) async {
    try {
      return await core.syncGroupIsActive(groupIdHex: id);
    } catch (_) {
      return false;
    }
  }

  Future<int> merge(String from, String to) => core.storageChatMergeInto(from: from, to: to);
  Future<void> setPeer(String id, String peer) => core.storageChatSetPeer(chatId: id, peerId: peer);
  Future<void> renameIf(String id, String from, String to) => core.storageChatRenameIf(chatId: id, from: from, to: to);

  Future<Map<String, String>> readFormer() async => decodeFormer(await core.storageSettingGet(key: kPersonalFormerSetting));
  Future<void> writeFormer(Map<String, String> m) => core.storageSettingSet(key: kPersonalFormerSetting, value: jsonEncode(m));
}

final personalChatsBackendProvider = Provider<PersonalChatsBackend>((ref) => PersonalChatsBackend(ref));

Map<String, String> decodeFormer(String? raw) {
  try {
    final m = jsonDecode(raw ?? '{}');
    return m is Map ? {for (final e in m.entries) '${e.key}': '${e.value}'} : {};
  } catch (_) {
    return {};
  }
}

/// "New chat" in every language: a row not named yet (its person's profile,
/// or a group-of-two's name, hasn't come).
final Set<String> _placeholders = {for (final code in const ['ru', 'en']) lookupAppL10n(Locale(code)).newChatPlaceholder};

class PersonalChats {
  PersonalChats(this._ref);
  final Ref _ref;
  Future<int>? _last;

  PersonalChatsBackend get _b => _ref.read(personalChatsBackendProvider);

  /// The other person of a personal chat [row] (from its members), or null.
  Future<String?> _otherOf(PersonalRow row, String me, String? saved) async {
    if (row.group || row.id == saved || !looksLikeMlsGroupId(row.id)) return null;
    final m = await _b.members(row.id);
    if (m.length != 2 || !m.contains(me)) return null;
    return m.firstWhere((k) => k != me);
  }

  /// Our personal chat with [peer] on this device (the one [tidy] keeps), or
  /// null. Rows that don't know their person yet are matched by members.
  Future<String?> find(String peer) async {
    final key = peer.toLowerCase();
    final me = _b.me;
    final saved = await _b.savedId();
    final rows = <PersonalRow>[];
    for (final r in await _b.chats()) {
      if (r.group || r.id == saved || !looksLikeMlsGroupId(r.id)) continue;
      final known = (r.peer ?? '').toLowerCase();
      if (known == key || (known.isEmpty && me.isNotEmpty && await _otherOf(r, me, saved) == key)) rows.add(r);
    }
    rows.sort(_keptFirst);
    return rows.firstOrNull?.id;
  }

  /// The chat [tidy] keeps first: accepted before a request, then the
  /// lowest group id.
  static int _keptFirst(PersonalRow x, PersonalRow y) =>
      x.request != y.request ? (x.request ? 1 : -1) : x.id.compareTo(y.id);

  /// Two personal chats with one person → one: the lowest group id is kept
  /// (an accepted chat before a request), the others' messages move into it and their rows go. Waits while this
  /// device can't post to one of them, or one isn't named yet (a group of
  /// two looks personal until its name comes) — except [fresh], a chat that
  /// just came back with a message. Blocked people and Saved are left
  /// alone. One run at a time. Returns how many chats were folded in.
  Future<int> tidy({String? fresh}) {
    final run = (_last ?? Future.value(0)).catchError((Object _) => 0).then((_) => _tidy(fresh));
    _last = run;
    return run;
  }

  Future<int> _tidy(String? fresh) async {
    final b = _b;
    final me = b.me;
    if (me.isEmpty) return 0;
    final saved = await b.savedId();
    final blocked = await b.blocked();
    final byPeer = <String, List<PersonalRow>>{};
    for (final r in await b.chats()) {
      final other = await _otherOf(r, me, saved);
      if (other != null && !blocked.contains(other)) (byPeer[other] ??= []).add(r);
    }
    Map<String, String>? former;
    var folded = 0, moved = 0;
    for (final MapEntry(key: other, value: rows) in byPeer.entries) {
      if (rows.length < 2) continue;
      if (rows.any((r) => r.id != fresh && _placeholders.contains(r.name.trim()))) continue;
      var allActive = true;
      for (final r in rows) {
        if (!await b.active(r.id)) allActive = false;
      }
      if (!allActive) continue;
      rows.sort(_keptFirst);
      final keep = rows.first;
      former ??= await b.readFormer();
      var keepName = keep.name.trim();
      for (final r in rows.skip(1)) {
        moved += await b.merge(r.id, keep.id);
        former.updateAll((_, to) => to == r.id ? keep.id : to);
        former[r.id] = keep.id;
        final name = r.name.trim();
        if (_placeholders.contains(keepName) && !_placeholders.contains(name)) {
          await b.renameIf(keep.id, keep.name, name);
          keepName = name;
        }
        folded++;
      }
      if ((keep.peer ?? '').toLowerCase() != other) await b.setPeer(keep.id, other);
    }
    if (folded == 0) return 0;
    await b.writeFormer(former!);
    // ignore: avoid_print
    print('[sinhron][chats] folded $folded second personal chat(s) ($moved messages)');
    _ref.invalidate(chatsProvider);
    return folded;
  }
}

final personalChatsProvider = Provider<PersonalChats>((ref) => PersonalChats(ref));

/// Where a push for [groupHex] goes when no chat row has that id: a folded
/// personal chat → the chat it was folded into, while that one is here
/// ([chatIds]); deleted, the folded chat comes back on its own (status 211).
Future<String?> formerPersonalRedirect(String groupHex, Iterable<String> chatIds) async {
  try {
    return personalRedirect(decodeFormer(await core.storageSettingGet(key: kPersonalFormerSetting)), groupHex, chatIds);
  } catch (_) {
    return null;
  }
}

/// [formerPersonalRedirect] over a loaded setting.
String? personalRedirect(Map<String, String> former, String groupHex, Iterable<String> chatIds) {
  final to = former[groupHex];
  return to != null && chatIds.contains(to) ? to : null;
}
