// People in chats — tech-debt 2.22 / 2.27.
//
// • Names: everyone announces their own display name in each chat with a
//   `profile` action (sent once per chat, again when it changes). Names are
//   per identity key, shared by every chat. Until someone announces one, a
//   short form of their key is shown.
// • Bios (ADR-052): the "About" line travels in the same `profile`, so the
//   people who get my name and photo get it too — and blocked people get a
//   profile without it, which clears it on their side.
// • "Already told" is per chat AND per set of members, so someone who joins
//   later learns it too; a new [People._profileRound] makes every chat hear
//   it once more (owner, 2026-10-19: a bio that reached a phone still on a
//   build without bios was dropped there and never sent again).
// • Contacts (ADR-052) are a list of their own, stored on this device: a
//   person is added when I add them (QR, link, key, accepting their chat,
//   "Add to contacts") and stays when the chat is deleted.
// • Blocking: a blocked person's messages, actions and calls are dropped
//   before they reach the UI. ADR-071 — and the access key I gave them is
//   revoked on the server, so nothing of theirs wakes my phone. The server
//   only sees a hash go "revoked", never whose it is.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale, StringCharacters;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/gen/app_l10n.dart' show lookupAppL10n;
import '../../l10n/l10n.dart' show currentLanguage;
import '../../src/rust/api/simple.dart' as core;
import '../../features/chat_info/chat_info_screen.dart' show chatMembersLoaderProvider;
import '../../features/chat_list/chat_data.dart' show ChatPreview;
import '../contact_qr.dart' show keyFingerprint;
import '../services/net_service.dart' show netServiceProvider;
import 'chat_providers.dart';
import 'core_providers.dart' show identityFingerprintProvider;
import 'saved_messages.dart' show isSavedChat;
import 'settings_providers.dart';

/// ADR-071 — after a block / unblock: the server's set of my per-contact
/// access keys follows (the blocked person's key revoked, an unblocked
/// one's back) and keys go out again. Best effort — offline, the next
/// connect does it. Faked in tests.
final accessKeysRefresherProvider = Provider<Future<void> Function()>(
  (ref) => () => ref.read(netServiceProvider).refreshAccessKeys(),
);

/// Storage seam (faked in tests).
abstract class PeopleStore {
  Future<Map<String, String>> names();

  /// Returns whether the name changed.
  Future<bool> setName(String peerId, String name, int ts);
  Future<String?> profileSent(String chatId);
  Future<void> setProfileSent(String chatId, String name);
  Future<Set<String>> blocked();
  Future<void> setBlocked(String peerId, bool blocked, int ts);

  /// Tech-debt 2.21 — photos (re-encoded in Rust before they are stored).
  Future<Map<String, Uint8List>> avatars();
  Future<bool> setAvatar(String peerId, Uint8List image, int ts);
  Future<void> setChatPeer(String chatId, String peerId);

  /// ADR-052 — bios (one clean line, cleaned again in Rust).
  Future<Map<String, String>> bios();
  Future<bool> setBio(String peerId, String bio, int ts);

  /// ADR-052 — contacts, their own list.
  Future<List<ContactRecord>> contacts();

  /// Returns whether they were new ([name] fills in only where none was).
  Future<bool> addContact(String peerId, String name, int ts);
  Future<bool> removeContact(String peerId);
  Future<bool> setFavourite(String peerId, bool favourite);
}

/// One person in my contacts (ADR-052).
class ContactRecord {
  const ContactRecord({required this.peerId, this.name = '', this.favourite = false, this.addedTs = 0});

  /// Identity key, lower-case hex.
  final String peerId;

  /// The name I first knew them by ('' = none) — their own name wins.
  final String name;
  final bool favourite;
  final int addedTs;
}

class CorePeopleStore implements PeopleStore {
  @override
  Future<Map<String, String>> names() async => {
    for (final p in await core.storagePeerNames()) p.peerId: p.name,
  };
  @override
  Future<bool> setName(String peerId, String name, int ts) =>
      core.storagePeerNameSet(peerId: peerId, name: name, tsUnix: ts);
  @override
  Future<String?> profileSent(String chatId) => core.storageChatProfileSent(chatId: chatId);
  @override
  Future<void> setProfileSent(String chatId, String name) =>
      core.storageChatSetProfileSent(chatId: chatId, name: name);
  @override
  Future<Set<String>> blocked() async => (await core.storagePeersBlocked()).toSet();
  @override
  Future<Map<String, Uint8List>> avatars() async => {
    for (final a in await core.storagePeerAvatars()) a.peerId: a.jpeg,
  };
  @override
  Future<bool> setAvatar(String peerId, Uint8List image, int ts) =>
      core.storagePeerAvatarSet(peerId: peerId, image: image, tsUnix: ts);
  @override
  Future<void> setChatPeer(String chatId, String peerId) => core.storageChatSetPeer(chatId: chatId, peerId: peerId);
  @override
  Future<void> setBlocked(String peerId, bool blocked, int ts) =>
      core.storagePeerSetBlocked(peerId: peerId, blocked: blocked, tsUnix: ts);
  @override
  Future<Map<String, String>> bios() async => {for (final b in await core.storagePeerBios()) b.peerId: b.bio};
  @override
  Future<bool> setBio(String peerId, String bio, int ts) => core.storagePeerBioSet(peerId: peerId, bio: bio, tsUnix: ts);
  @override
  Future<List<ContactRecord>> contacts() async => [
    for (final c in await core.storageContacts())
      ContactRecord(peerId: c.peerId, name: c.name, favourite: c.favourite, addedTs: c.addedTs),
  ];
  @override
  Future<bool> addContact(String peerId, String name, int ts) =>
      core.storageContactAdd(peerId: peerId, name: name, tsUnix: ts);
  @override
  Future<bool> removeContact(String peerId) => core.storageContactRemove(peerId: peerId);
  @override
  Future<bool> setFavourite(String peerId, bool favourite) =>
      core.storageContactSetFavourite(peerId: peerId, favourite: favourite);
}

final peopleStoreProvider = Provider<PeopleStore>((ref) => CorePeopleStore());

/// identity key (hex) → the name to show: the one I gave them on this
/// device ([contactAliasesProvider]), else the one they chose. Their own
/// is in [PeopleStore.names] (the "restore" button).
final peerNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  final aliases = await ref.watch(contactAliasesProvider.future);
  Map<String, String> own;
  try {
    own = await ref.read(peopleStoreProvider).names();
  } catch (_) {
    own = const {}; // storage not open (onboarding, tests)
  }
  return withAliases(own, aliases);
});

/// [names] with my own names for people ([aliases], lower-case keys) over
/// theirs — under the key as stored too, whatever its case.
Map<String, String> withAliases(Map<String, String> names, Map<String, String> aliases) => aliases.isEmpty
    ? names
    : {
        for (final e in names.entries) e.key: aliases[e.key.toLowerCase()] ?? e.value,
        ...aliases,
      };

/// identity key (hex) → their photo (JPEG this device re-encoded).
final peerAvatarsProvider = FutureProvider<Map<String, Uint8List>>((ref) async {
  try {
    return await ref.read(peopleStoreProvider).avatars();
  } catch (_) {
    return const {};
  }
});

/// identity key (hex, lower case) → the bio they shared (ADR-052).
final peerBiosProvider = FutureProvider<Map<String, String>>((ref) async {
  try {
    return await ref.read(peopleStoreProvider).bios();
  } catch (_) {
    return const {};
  }
});

/// My contacts (ADR-052), as stored — [contactEntries] adds names and chats.
final contactsProvider = FutureProvider<List<ContactRecord>>((ref) async {
  try {
    return await ref.read(peopleStoreProvider).contacts();
  } catch (_) {
    return const [];
  }
});

/// Longest bio I send (the wire limit — `MAX_PROFILE_BIO_CHARS` in Rust).
const int kMaxBioChars = 200;

/// My own photo (decoded `profile_avatar`), null without one — the same
/// picture everywhere I appear (Settings, my card, headers, QR), not only in
/// the profile editor (owner, 2026-10-18).
final myAvatarProvider = Provider<Uint8List?>((ref) {
  final b64 = ref.watch(profileAvatarProvider).value ?? '';
  if (b64.isEmpty) return null;
  try {
    return base64Decode(b64);
  } catch (_) {
    return null;
  }
});

/// [peerId]'s photo, if they shared one (null for groups / unknown).
Uint8List? peerAvatarOf(WidgetRef ref, String? peerId) =>
    peerId == null || peerId.isEmpty ? null : ref.watch(peerAvatarsProvider).value?[peerId.toLowerCase()];

/// My key as people see it ("a8d5 b2a7 53f3 1f66"): the start of my
/// identity key — the same in Settings, my profile, my contact card and my
/// QR. Settings used to show the stored identity's own fingerprint, a
/// different number (owner, 2026-10-18). Null before an identity exists.
String? myKeyLabel(WidgetRef ref) {
  final stored = ref.watch(identityFingerprintProvider);
  final hex = ref.watch(netServiceProvider).myIdentityHex;
  return hex != null && hex.isNotEmpty ? keyFingerprint(hex) : stored;
}

/// Chat id → the other person's photo, for lists keyed by chat (calls).
Map<String, Uint8List> chatPhotos(List<ChatPreview> chats, Map<String, Uint8List> photos) => {
  for (final c in chats)
    if (!c.group && c.id != null && c.peerId != null && photos[c.peerId!.toLowerCase()] != null)
      c.id!: photos[c.peerId!.toLowerCase()]!,
};

/// [chats] with each personal chat's photo filled in (lists that get the
/// raw chats: search, forward).
List<ChatPreview> withPhotos(List<ChatPreview> chats, Map<String, Uint8List> photos) => [
  for (final c in chats)
    c.avatar != null || c.group || c.peerId == null ? c : c.copyWith(avatar: photos[c.peerId!.toLowerCase()]),
];

/// People blocked on this device (identity keys, hex).
final blockedPeersProvider = FutureProvider<Set<String>>((ref) async {
  try {
    return await ref.read(peopleStoreProvider).blocked();
  } catch (_) {
    return const {};
  }
});

/// `blocked_chats` setting: comma list of `chat=peer` (personal chats with a
/// blocked person; their calls don't ring and nothing goes out to them).
/// Older entries may be a bare `chat`.
Set<String> blockedChatIds(String setting) => {
  for (final e in setting.split(','))
    if (e.isNotEmpty) e.split('=').first,
};

/// Is [chatId] a personal chat with someone blocked on this device?
bool isBlockedChat(Ref ref, String chatId) => blockedChatIds(ref.read(blockedChatsProvider).value ?? '').contains(chatId);

/// A bio as it goes out and is kept: one line, trimmed, at most
/// [kMaxBioChars] (Rust cleans it again — invisible characters, etc.).
String oneLineBio(String bio) {
  final line = bio.replaceAll(RegExp(r'[\r\n\t\u2028\u2029]+'), ' ').trim();
  final chars = line.characters;
  return chars.length <= kMaxBioChars ? line : chars.take(kMaxBioChars).toString().trimRight();
}

/// "ab12 cd34" — how someone without a name is shown.
String shortKey(String peerId) {
  final k = peerId.toLowerCase();
  if (k.length < 8) return k;
  return '${k.substring(0, 4)} ${k.substring(4, 8)}';
}

/// The name to show for [peerId]: their own name, else "Member" — not a
/// code like "ab12 cd34", which meant nothing to people (until their
/// profile arrives, usually seconds).
String displayNameOf(String peerId, Map<String, String> names) =>
    names[peerId] ?? names[peerId.toLowerCase()] ?? lookupAppL10n(Locale(currentLanguage)).memberUnnamed;

/// Sends and receives `profile` actions; blocks and unblocks people.
class People {
  People(this._ref, {required this.send});
  final Ref _ref;

  /// Sends an action to a chat (wire id is generated by the caller's sender).
  final Future<void> Function(String chatId, Map<String, Object?> action) send;

  PeopleStore get _store => _ref.read(peopleStoreProvider);
  int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String get _myName => (_ref.read(profileNameProvider).value ?? '').trim();
  String get _myAvatar => _ref.read(profileAvatarProvider).value ?? '';
  String get _myBio => oneLineBio(_ref.read(profileAboutProvider).value ?? '');

  /// Raise it when every chat must get my profile once more — after a field
  /// that older builds dropped (round 2: the bio, owner 2026-10-19 — sent
  /// while their phone still ran a build without bios, it was lost there
  /// and the "already told" mark kept it from ever going again).
  static const int _profileRound = 2;

  /// What a chat has been told: name + a fingerprint of the photo and of
  /// the bio, so a new one is announced too (and an unchanged one isn't
  /// re-sent).
  static String _sentKey(String name, String avatarB64, [String bio = '']) {
    final base = avatarB64.isEmpty ? name : '$name\u0000${avatarB64.length}:${_fnv(avatarB64)}';
    return '$_profileRound\u0002${bio.isEmpty ? base : '$base\u0001${_fnv(bio)}'}';
  }

  /// Who was in the chat when it was told (a fingerprint of the member
  /// keys), so a member who joins later gets my profile too. Null when
  /// the members can't be read (MLS not ready) — then only the profile
  /// part is compared.
  Future<String?> _membersMark(String chatId) async {
    try {
      final members = [for (final m in await _ref.read(chatMembersLoaderProvider)(chatId)) m.toLowerCase()]..sort();
      return members.isEmpty ? null : _fnv(members.join(',')).toRadixString(36);
    } catch (_) {
      return null;
    }
  }

  static int _fnv(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h;
  }

  /// Announce my name (photo, bio) in [chatId] unless it already knows them
  /// — the same profile, told to the same members. No-op for chats that
  /// aren't real MLS groups or when I have no name.
  Future<bool> ensureShared(String chatId) async {
    // Settings may still be loading right after start (review fix).
    try {
      await _ref.read(profileNameProvider.future);
      await _ref.read(profileAvatarProvider.future);
      await _ref.read(profileAboutProvider.future);
    } catch (_) {}
    final name = _myName;
    final avatar = _myAvatar;
    final bio = _myBio;
    if (name.isEmpty || !looksLikeMlsGroupId(chatId)) return false;
    if (isMessageRequest(_ref, chatId)) return false; // strangers don't get my name
    if (isSavedChat(_ref, chatId)) return false; // ADR-055 — my own devices know it
    if (isBlockedChat(_ref, chatId)) return false; // nor do people I blocked
    try {
      final profile = _sentKey(name, avatar, bio);
      final members = await _membersMark(chatId);
      final key = members == null ? profile : '$profile\u0003$members';
      final sent = await _store.profileSent(chatId) ?? '';
      if (sent == key) return false;
      final told = sent.split('\u0003');
      if (told.first == profile && (members == null || told.length == 1)) {
        // Same profile; the members just couldn't be read last time.
        if (members != null) await _store.setProfileSent(chatId, key);
        return false;
      }
      await send(chatId, {
        't': 'profile',
        'name': name,
        if (avatar.isNotEmpty) 'avatar': avatar,
        if (bio.isNotEmpty) 'bio': bio,
      });
      await _store.setProfileSent(chatId, key);
      return true;
    } catch (_) {
      return false; // offline — next send or chat open tries again
    }
  }

  Future<int>? _sharing;
  Future<int>? _sharingNext;

  /// After my name, photo or bio changed, and on every (re)connect: tell
  /// every chat that doesn't know it yet. One pass at a time — two at once
  /// would both see "not told" and send twice; a call during a pass runs
  /// one more after it (the running one may have read the old bio).
  Future<int> shareEverywhere() {
    final running = _sharing;
    if (running != null) {
      return _sharingNext ??= running.catchError((Object _) => 0).then((_) {
        _sharingNext = null;
        return shareEverywhere();
      });
    }
    return _sharing = _shareAll().whenComplete(() => _sharing = null);
  }

  Future<int> _shareAll() async {
    var n = 0;
    // Await the list: it may not be loaded when the profile screen is the
    // only thing open (a bare `.value` would be null → nothing announced).
    List<ChatPreview> chats;
    try {
      chats = await _ref.read(chatsProvider.future);
    } catch (_) {
      chats = _ref.read(chatsProvider).value ?? const [];
    }
    await repairSelfPeers(chats);
    for (final c in chats) {
      final id = c.id;
      if (id != null && await ensureShared(id)) n++;
    }
    return n;
  }

  /// Owner, 2026-11-01 — "every contact has my photo": my own profile from
  /// my other device was taken for the other person's, so personal chats
  /// got me as their person (and I could land in my own contacts). Such a
  /// chat gets its real person back from its members; I leave my contacts.
  /// Owner, 2026-11-03 — a chat that doesn't know its person yet (it came
  /// by invite, or they never answered) learns it the same way, so
  /// "Message" finds it instead of making a second one; accepted, the
  /// person becomes a contact (as [onProfile] did on their first profile).
  Future<int> repairSelfPeers(List<ChatPreview> chats) async {
    final me = (_ref.read(netServiceProvider).myIdentityHex ?? '').toLowerCase();
    if (me.isEmpty) return 0;
    var fixed = 0;
    for (final c in chats) {
      final id = c.id;
      final peer = (c.peerId ?? '').toLowerCase();
      if (c.group || id == null || (peer.isNotEmpty && peer != me) || !looksLikeMlsGroupId(id)) continue;
      if (isSavedChat(_ref, id)) continue;
      try {
        final members = {for (final m in await _ref.read(chatMembersLoaderProvider)(id)) m.toLowerCase()};
        final others = {...members}..remove(me);
        if (others.length != 1 || (peer.isEmpty && members.length != 2)) continue;
        await _store.setChatPeer(id, others.single);
        if (peer.isEmpty && !c.request) await addContact(others.single);
        fixed++;
      } catch (_) {}
    }
    if (fixed > 0) _ref.invalidate(chatsProvider);
    try {
      final contacts = await _ref.read(contactsProvider.future);
      if (contacts.any((k) => k.peerId.toLowerCase() == me)) await removeContact(me);
    } catch (_) {}
    return fixed;
  }

  /// A `profile` action arrived from [peerId] (photo as base64, '' = none;
  /// bio '' = none — a profile is the whole picture, so a missing photo or
  /// bio clears the old one). In a personal chat ([personalChatId]) they are
  /// its other person; the first time an accepted chat learns who that is,
  /// they become a contact (chats from before contacts were their own list,
  /// or accepted before their profile came).
  Future<bool> onProfile(
    String peerId,
    String name, {
    String avatarB64 = '',
    String bio = '',
    String? personalChatId,
  }) async {
    if (peerId.isEmpty || name.trim().isEmpty) return false;
    // Never me: I am nobody's "other person" (see [repairSelfPeers]).
    if (peerId.toLowerCase() == (_ref.read(netServiceProvider).myIdentityHex ?? '').toLowerCase()) return false;
    try {
      final changed = await _store.setName(peerId, name, _now());
      if (changed) _ref.invalidate(peerNamesProvider);
      Uint8List image;
      try {
        image = avatarB64.isEmpty ? Uint8List(0) : base64Decode(avatarB64);
      } catch (_) {
        image = Uint8List(0);
      }
      if (await _store.setAvatar(peerId, image, _now())) _ref.invalidate(peerAvatarsProvider);
      if (await _store.setBio(peerId.toLowerCase(), oneLineBio(bio), _now())) _ref.invalidate(peerBiosProvider);
      if (personalChatId != null) {
        final chat = (_ref.read(chatsProvider).value ?? const <ChatPreview>[])
            .where((c) => c.id == personalChatId)
            .firstOrNull;
        await _store.setChatPeer(personalChatId, peerId);
        _ref.invalidate(chatsProvider);
        if (chat != null && !chat.request && (chat.peerId ?? '').isEmpty) {
          await addContact(peerId, name: name);
        }
      }
      return changed;
    } catch (_) {
      return false;
    }
  }

  /// Block / unblock [peerId]. [personalChatId] is our 1:1 chat with
  /// them, if any — its call invites are then declined too. Blocked from
  /// somewhere else (a group's member list, a report) their personal chats
  /// are found by key: it used to record none, so they still saw me
  /// "online" and their calls rang (owner, 2026-10-18).
  Future<void> setBlocked(String peerId, bool blocked, {String? personalChatId}) async {
    final personal = <String>{?personalChatId, ...await _personalChatsWith(peerId)};
    if (blocked) await _goQuiet(personal);
    await _store.setBlocked(peerId, blocked, _now());
    _ref.invalidate(blockedPeersProvider);
    // ADR-071 — revoke (or restore) their key on the server.
    unawaited(_ref.read(accessKeysRefresherProvider)().catchError((Object _) {}));
    final entries = (await _ref.read(blockedChatsProvider.future)).split(',').where((e) => e.isNotEmpty).toList();
    if (blocked) {
      if (personal.isEmpty) return;
      entries
        ..removeWhere((e) => personal.contains(e.split('=').first))
        ..addAll([for (final c in personal) '$c=$peerId']);
    } else {
      // Unblocking from anywhere (the Blocked list has no chat id) clears
      // every personal chat recorded for them, so their calls ring again.
      entries.removeWhere((e) {
        final parts = e.split('=');
        return (parts.length > 1 && parts[1] == peerId) || parts.first == personalChatId;
      });
    }
    await _ref.read(blockedChatsProvider.notifier).save(entries.join(','));
  }

  /// Our personal chats with [peerId] (by the key the chat learned).
  Future<Set<String>> _personalChatsWith(String peerId) async {
    List<ChatPreview> chats;
    try {
      chats = await _ref.read(chatsProvider.future);
    } catch (_) {
      chats = _ref.read(chatsProvider).value ?? const [];
    }
    final key = peerId.toLowerCase();
    return {
      for (final c in chats)
        if (!c.group && c.id != null && c.peerId?.toLowerCase() == key) c.id!,
    };
  }

  /// Just before blocking: tell them I'm not around (their "online" for me
  /// goes to "last seen") and take my photo back — a profile without it
  /// clears it on their side. Best effort: offline it just doesn't go. The
  /// "already told" mark is reset, so unblocking shares the photo again.
  Future<void> _goQuiet(Set<String> chats) async {
    for (final chatId in chats) {
      if (!looksLikeMlsGroupId(chatId)) continue;
      try {
        await send(chatId, {'t': 'presence', 'hidden': true});
        final name = _myName;
        if (name.isNotEmpty) await send(chatId, {'t': 'profile', 'name': name});
        await _store.setProfileSent(chatId, '');
      } catch (_) {
        // Offline — nothing more to do; nothing else goes to them from now on.
      }
    }
  }

  /// ADR-052 — add [peerId] to my contacts ([name]: how I first knew them,
  /// kept until they share their own). Returns whether they were new.
  Future<bool> addContact(String peerId, {String? name}) async {
    if (peerId.isEmpty) return false;
    try {
      final added = await _store.addContact(peerId.toLowerCase(), name?.trim() ?? '', _now());
      _ref.invalidate(contactsProvider);
      return added;
    } catch (_) {
      return false; // storage not open
    }
  }

  /// Remove [peerId] from my contacts. Chats with them stay.
  Future<bool> removeContact(String peerId) async {
    try {
      final removed = await _store.removeContact(peerId.toLowerCase());
      _ref.invalidate(contactsProvider);
      return removed;
    } catch (_) {
      return false;
    }
  }

  /// Star / unstar a contact (the Favourites section).
  Future<void> setFavourite(String peerId, bool favourite) async {
    try {
      await _store.setFavourite(peerId.toLowerCase(), favourite);
      _ref.invalidate(contactsProvider);
    } catch (_) {}
  }

  Future<bool> isBlocked(String? peerId) async {
    if (peerId == null || peerId.isEmpty) return false;
    try {
      return (await _store.blocked()).contains(peerId);
    } catch (_) {
      return false;
    }
  }
}
