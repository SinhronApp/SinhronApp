// Message actions — ADR-019 (UI backlog §3 items 22-26, 32).
//
// Replies, reactions, edits, deletes, delivery/read receipts and
// "typing…", end-to-end encrypted inside the MLS envelope. Messages are
// addressed by their wire UUID (the id both sides already know).
//
// Two seams keep this testable without the Rust library:
//   • [MessageStore]  — the SQLCipher rows (storage v7)
//   • [MessageSender] — MLS encrypt + WebSocket submit
//
// Authorship rules (who may edit / delete what) are enforced in storage
// against the MLS-authenticated sender id — a peer can only change its
// own messages.

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rich_text.dart';
import '../server_clock.dart';
import '../../src/rust/api/simple.dart' as core;
import '../services/net_service.dart';
import '../short_id.dart';
import '../../l10n/l10n.dart';
import 'chat_actions.dart';
import 'chat_providers.dart';
import 'people.dart';
import 'saved_messages.dart' show isSavedChat;
import 'settings_providers.dart';
import '../../features/chat_list/chat_data.dart' show ChatPreview;

/// Reactor id for my own reactions in `reactions_json`.
const kMe = 'me';

/// Edit / delete for everyone only this long after sending — the same
/// limit as `sinhron_storage::EDIT_WINDOW_SECS`, which enforces it (incoming
/// actions get a day more for delivery delays).
const kEditWindow = Duration(hours: 24);

/// Quick reactions shown in the long-press bar.
const kQuickReactions = ['❤️', '👍', '😂', '😮', '😢', '🙏', '🔥'];

/// Disappearing-message choices (seconds → label), §6 item 51.
const kTimerChoices = {
  0: 'Off',
  300: '5 minutes',
  3600: '1 hour',
  86400: '1 day',
  604800: '1 week',
  2419200: '4 weeks',
};

/// A system row's text in the current language. Rows store codes like
/// `timer:86400:me`; anything else is shown as it is.
String systemLineText(AppL10n l, String body) {
  // ADR-030 — screenshots of a chat with disappearing messages.
  if (body == 'screenshot:me') return l.screenshotByMe;
  // ADR-035 — group membership and names.
  if (body == 'you-removed') return l.groupYouWereRemoved;
  // Overnight item 5 — a call I missed.
  if (body == 'call-missed:audio') return l.chatMissedCall;
  if (body == 'call-missed:video') return l.chatMissedVideoCall;
  final left = RegExp(r'^member-left:(.*)$').firstMatch(body);
  if (left != null) return l.groupMemberLeft(left.group(1)!);
  final added = RegExp(r'^member-added:by:([^:]*):(.*)$').firstMatch(body);
  if (added != null) return l.groupSomeoneAdded(added.group(1)!, added.group(2)!);
  final removed = RegExp(r'^member-removed:(me|by:[^:]*):(.*)$').firstMatch(body);
  if (removed != null) {
    final by = removed.group(1)!;
    return by == 'me'
        ? l.groupYouRemoved(removed.group(2)!)
        : l.groupSomeoneRemoved(by.substring(3), removed.group(2)!);
  }
  final renamed = RegExp(r'^group-renamed:(me|by:[^:]*):(.*)$').firstMatch(body);
  if (renamed != null) {
    final by = renamed.group(1)!;
    return by == 'me'
        ? l.groupYouRenamed(renamed.group(2)!)
        : l.groupSomeoneRenamed(by.substring(3), renamed.group(2)!);
  }
  final shot = RegExp(r'^screenshot:peer:(.*)$').firstMatch(body);
  if (shot != null) return l.screenshotByPeer(shot.group(1)!);
  if (body == 'recording:me') return l.screenRecordingByMe;
  final rec = RegExp(r'^recording:peer:(.*)$').firstMatch(body);
  if (rec != null) return l.screenRecordingByPeer(rec.group(1)!);
  final m = RegExp(r'^timer:(\d+):(me|peer)$').firstMatch(body);
  if (m == null) return body;
  final secs = int.parse(m.group(1)!);
  final me = m.group(2) == 'me';
  if (secs == 0) return me ? l.timerOffByMe : l.timerOffByPeer;
  final label = timerChoiceLabel(l, secs);
  return me ? l.timerSetByMe(label) : l.timerSetByPeer(label);
}

/// Localised timer choice ("1 day" / "1 день").
String timerChoiceLabel(AppL10n l, int secs) {
  if (secs <= 0) return l.timerOff;
  if (secs % 604800 == 0) return l.timerWeeks(secs ~/ 604800);
  if (secs % 86400 == 0) return l.timerDays(secs ~/ 86400);
  if (secs % 3600 == 0) return l.timerHours(secs ~/ 3600);
  return l.timerMinutes((secs / 60).round());
}

String timerLabel(int secs) =>
    kTimerChoices[secs] ??
    (secs >= 86400
        ? '${secs ~/ 86400} days'
        : secs >= 3600
        ? '${secs ~/ 3600} h'
        : '${secs ~/ 60} min');

/// Status values of my messages (see `StoredMessage.status`).
abstract final class MsgStatus {
  static const failed = -1;
  static const sending = 0;
  static const sent = 1;
  static const delivered = 2;
  static const read = 3;
}

/// Receipt bookkeeping for incoming messages.
abstract final class ReceiptStatus {
  static const none = 0;
  static const delivered = 1;
  static const read = 2;
}

/// UUIDv7 for the wire (server requires UUID message ids): the first 48
/// bits are the send time by the server's clock ([serverNowMs]), so the
/// other side places the message by when it was written, not when it
/// arrived (owner, 2026-10-16 — a slow link put old messages below new
/// ones), and a phone with a wrong clock doesn't shift it. The rest random.
String newWireId([Random? rng, int? nowMs]) {
  final r = rng ?? Random.secure();
  final ms = nowMs ?? serverNowMs();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  for (var i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xff;
  }
  b[6] = (b[6] & 0x0f) | 0x70;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// What a reply quotes. Travels as `{"id","snippet","kind"}`.
class ReplyTarget {
  const ReplyTarget({required this.wireId, required this.snippet, required this.kind, this.mine = false});

  final String wireId;
  final String snippet;
  final String kind;

  /// Quoting my own message (only for the composer label).
  final bool mine;

  String toJson() => jsonEncode({'id': wireId, 'snippet': snippetOf(snippet), 'kind': kind});

  static ReplyTarget? fromJson(String? j) {
    if (j == null || j.isEmpty) return null;
    try {
      final m = jsonDecode(j) as Map<String, Object?>;
      return ReplyTarget(
        wireId: m['id'] as String,
        snippet: (m['snippet'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'text',
      );
    } catch (_) {
      return null;
    }
  }

  /// First ≤200 characters, one line.
  static String snippetOf(String text) {
    final flat = text.replaceAll('\n', ' ').trim();
    final chars = flat.runes.toList();
    return chars.length <= 200 ? flat : String.fromCharCodes(chars.take(200));
  }
}

/// `{"❤️": ["me", "<id>"]}` → emoji → reactors, in insertion order.
Map<String, List<String>> parseReactions(String? json) {
  if (json == null || json.isEmpty) return const {};
  try {
    final m = jsonDecode(json) as Map<String, Object?>;
    return {for (final e in m.entries) e.key: (e.value as List).cast<String>()};
  } catch (_) {
    return const {};
  }
}

/// My current reaction on a message, if any.
String? myReaction(String? reactionsJson) {
  for (final e in parseReactions(reactionsJson).entries) {
    if (e.value.contains(kMe)) return e.key;
  }
  return null;
}

// ─── Seams ──────────────────────────────────────────────────────────

abstract class MessageStore {
  Future<void> insert(core.NewMessageRow row);
  Future<void> setMediaJson(String id, String json);
  Future<bool> setReaction(String chatId, String wireId, String reactor, String? emoji);
  /// ADR-070 — [entitiesJson]: the new formatting (null = an older app's edit).
  Future<bool> applyEdit(String chatId, String wireId, String? peer, String text, int ts, {String? entitiesJson});
  Future<bool> applyDelete(String chatId, String wireId, String? peer, int now);
  Future<void> deleteLocal(String chatId, List<String> ids);
  Future<int> raiseStatus(List<String> wireIds, int status);
  Future<int> raiseStatusInChat(String chatId, List<String> wireIds, int status);
  Future<List<String>> pendingReceipts(String chatId, int below);
  Future<void> markReceipted(String chatId, List<String> wireIds, int status);

  /// Status 213 — "Message info": when [peer] got / read these of mine.
  Future<void> recordReceipts(String chatId, List<String> wireIds, String peer, {required bool read, required int ts});
  Future<List<core.StoredReceipt>> receiptsFor(String wireId);
  Future<void> setPinnedMessage(String chatId, String? wireId);

  /// Unpin only if [wireId] is the pinned message; returns whether it was.
  Future<bool> unpinIf(String chatId, String wireId);

  /// Rename a personal chat only while it has the placeholder name [from].
  Future<bool> renameIf(String chatId, String from, String to);

  /// ADR-034 — a group's name: for a group, or a chat that still has one
  /// of the [placeholders] (it becomes a group). Returns whether it changed.
  Future<bool> setGroupName(String chatId, String name, List<String> placeholders);
  Future<void> setDisappear(String chatId, int secs);

  /// Delete expired messages; returns the chats that changed.
  Future<List<String>> expire(int nowUnix);
}

class CoreMessageStore implements MessageStore {
  @override
  Future<void> insert(core.NewMessageRow row) => core.storageMessageInsert(row: row);
  @override
  Future<void> setMediaJson(String id, String json) => core.storageMessageSetMedia(id: id, mediaJson: json);
  @override
  Future<bool> setReaction(String chatId, String wireId, String reactor, String? emoji) =>
      core.storageMessageSetReaction(chatId: chatId, wireId: wireId, reactor: reactor, emoji: emoji);
  @override
  Future<bool> applyEdit(String chatId, String wireId, String? peer, String text, int ts, {String? entitiesJson}) =>
      core.storageMessageApplyEdit(
        chatId: chatId,
        wireId: wireId,
        peerSenderId: peer,
        text: text,
        editedTs: ts,
        entitiesJson: entitiesJson,
      );
  @override
  Future<bool> applyDelete(String chatId, String wireId, String? peer, int now) =>
      core.storageMessageApplyDelete(chatId: chatId, wireId: wireId, peerSenderId: peer, nowUnix: now);
  @override
  Future<void> deleteLocal(String chatId, List<String> ids) =>
      core.storageMessagesDeleteLocal(chatId: chatId, ids: ids);
  @override
  Future<int> raiseStatus(List<String> wireIds, int status) =>
      core.storageMessagesRaiseStatus(wireIds: wireIds, status: status);
  @override
  Future<int> raiseStatusInChat(String chatId, List<String> wireIds, int status) =>
      core.storageMessagesRaiseStatusInChat(chatId: chatId, wireIds: wireIds, status: status);
  @override
  Future<List<String>> pendingReceipts(String chatId, int below) =>
      core.storageMessagesPendingReceipts(chatId: chatId, below: below, limit: 200);
  @override
  Future<void> markReceipted(String chatId, List<String> wireIds, int status) =>
      core.storageMessagesMarkReceipted(chatId: chatId, wireIds: wireIds, status: status);
  @override
  Future<void> recordReceipts(String chatId, List<String> wireIds, String peer, {required bool read, required int ts}) =>
      core.storageReceiptsRecord(chatId: chatId, wireIds: wireIds, peer: peer, read: read, tsUnix: ts);
  @override
  Future<List<core.StoredReceipt>> receiptsFor(String wireId) => core.storageReceiptsFor(wireId: wireId);
  @override
  Future<void> setPinnedMessage(String chatId, String? wireId) =>
      core.storageChatSetPinnedMessage(chatId: chatId, wireId: wireId);
  @override
  Future<bool> unpinIf(String chatId, String wireId) => core.storageChatUnpinIf(chatId: chatId, wireId: wireId);
  @override
  Future<bool> renameIf(String chatId, String from, String to) =>
      core.storageChatRenameIf(chatId: chatId, from: from, to: to);
  @override
  Future<bool> setGroupName(String chatId, String name, List<String> placeholders) =>
      core.storageChatSetGroupName(chatId: chatId, name: name, placeholders: placeholders);
  @override
  Future<void> setDisappear(String chatId, int secs) => core.storageChatSetDisappear(chatId: chatId, secs: secs);
  @override
  Future<List<String>> expire(int nowUnix) => core.storageMessagesExpire(nowUnix: nowUnix);
}

abstract class MessageSender {
  /// Returns the link-preview JSON to store, if one was built.
  /// [entitiesJson]: the text's formatting (ADR-070; `[]` = none).
  Future<String?> sendText(
    String chatId,
    String wireId,
    String text, {
    String? replyJson,
    String? previewBaseUrl,
    int expireSecs = 0,
    String? entitiesJson,
  });
  Future<void> sendAction(String chatId, String wireId, Map<String, Object?> action);

  /// An uploaded media message or sticker again ([mediaJson]: what its
  /// send returned), under the same wire id — nothing is uploaded twice.
  Future<void> resendMedia(String chatId, String wireId, String mediaJson, {String? replyJson, int expireSecs = 0});

  /// Stop [wireId]'s send if it hasn't reached the network yet (Rust checks
  /// before the upload and before encrypt + submit).
  void cancelSend(String wireId);
}

class CoreMessageSender implements MessageSender {
  @override
  Future<String?> sendText(
    String chatId,
    String wireId,
    String text, {
    String? replyJson,
    String? previewBaseUrl,
    int expireSecs = 0,
    String? entitiesJson,
  }) => core.netSendMessage(
    groupIdHex: chatId,
    messageId: wireId,
    text: text,
    replyJson: replyJson,
    previewBaseUrl: previewBaseUrl,
    expireSecs: expireSecs,
    entitiesJson: entitiesJson,
  );
  @override
  Future<void> sendAction(String chatId, String wireId, Map<String, Object?> action) =>
      core.netSendAction(groupIdHex: chatId, messageId: wireId, actionJson: jsonEncode(action));
  @override
  Future<void> resendMedia(String chatId, String wireId, String mediaJson, {String? replyJson, int expireSecs = 0}) =>
      core.netResendMedia(
        groupIdHex: chatId,
        messageId: wireId,
        mediaJson: mediaJson,
        replyJson: replyJson,
        expireSecs: expireSecs,
      );
  @override
  void cancelSend(String wireId) => core.netCancelSend(messageId: wireId);
}

/// What Rust fails a cancelled send with (`SEND_CANCELLED`).
bool isCancelledSend(Object e) => '$e'.contains('send cancelled');

final messageStoreProvider = Provider<MessageStore>((ref) => CoreMessageStore());
final messageSenderProvider = Provider<MessageSender>((ref) => CoreMessageSender());

/// Server base URL for link previews — null when previews are off
/// (ADR-018, off by default) or we're offline. Overridden in tests.
final linkPreviewBaseUrlProvider = Provider<String? Function()>(
  (ref) =>
      () => (ref.read(linkPreviewsEnabledProvider).value ?? false) ? ref.read(netServiceProvider).httpBaseUrl : null,
);

/// Read receipts on/off (privacy screen). Reciprocal, like Signal: off
/// means you neither send nor see "read".
final readReceiptsProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('read_receipts', true));

/// "Typing…" on/off — same reciprocity.
final typingIndicatorsProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('typing_indicators', true));

// ─── Typing state ───────────────────────────────────────────────────

/// Chats where the other side is typing right now → until when.
class TypingChats extends Notifier<Map<String, DateTime>> {
  static const ttl = Duration(seconds: 6);
  Timer? _sweep;

  @override
  Map<String, DateTime> build() {
    ref.onDispose(() => _sweep?.cancel());
    return const {};
  }

  void set(String chatId, bool active, {DateTime? now}) {
    final next = {...state};
    if (active) {
      next[chatId] = (now ?? DateTime.now()).add(ttl);
    } else {
      next.remove(chatId);
    }
    state = next;
    _sweep?.cancel();
    if (next.isNotEmpty) _sweep = Timer(ttl, expire);
  }

  /// Drop indicators whose sender went quiet without "stopped".
  void expire({DateTime? now}) {
    if (!ref.mounted) return;
    final t = now ?? DateTime.now();
    final next = {
      for (final e in state.entries)
        if (e.value.isAfter(t)) e.key: e.value,
    };
    if (next.length != state.length) state = next;
  }
}

final typingChatsProvider = NotifierProvider<TypingChats, Map<String, DateTime>>(TypingChats.new);

/// Who is typing in each chat (identity hex → until when) — a group shows
/// "Аня и Борис печатают…" (owner, 2026-10-18: "several people type in a
/// group — then what?").
class TypingPeople extends Notifier<Map<String, Map<String, DateTime>>> {
  Timer? _sweep;

  @override
  Map<String, Map<String, DateTime>> build() {
    ref.onDispose(() => _sweep?.cancel());
    return const {};
  }

  void set(String chatId, String? senderId, bool active, {DateTime? now}) {
    if (senderId == null || senderId.isEmpty) return;
    final inChat = {...?state[chatId]};
    if (active) {
      inChat[senderId] = (now ?? DateTime.now()).add(TypingChats.ttl);
    } else {
      inChat.remove(senderId);
    }
    state = {...state, chatId: inChat}..removeWhere((_, v) => v.isEmpty);
    _sweep?.cancel();
    if (state.isNotEmpty) _sweep = Timer(TypingChats.ttl, expire);
  }

  /// A message came in: nobody there is "typing" any more.
  void clear(String chatId) {
    if (state.containsKey(chatId)) state = {...state}..remove(chatId);
  }

  void expire({DateTime? now}) {
    if (!ref.mounted) return;
    final t = now ?? DateTime.now();
    final next = <String, Map<String, DateTime>>{};
    for (final e in state.entries) {
      final live = {
        for (final p in e.value.entries)
          if (p.value.isAfter(t)) p.key: p.value,
      };
      if (live.isNotEmpty) next[e.key] = live;
    }
    state = next;
  }
}

final typingPeopleProvider = NotifierProvider<TypingPeople, Map<String, Map<String, DateTime>>>(TypingPeople.new);

/// The header line while people type: a personal chat "typing…", a group
/// names them — one, two, or how many.
String typingLine(AppL10n l, List<String> names, {required bool group}) {
  if (!group || names.isEmpty) return l.typing;
  return switch (names.length) {
    1 => l.typingOne(names[0]),
    2 => l.typingTwo(names[0], names[1]),
    final n => l.typingMany(n),
  };
}

// ─── Actions ────────────────────────────────────────────────────────

/// ADR-035 — group membership in MLS and on the server (FFI; faked in tests).
abstract class GroupOps {
  /// One Commit removing these people (identity hex) from the group.
  Future<void> removeMembers(String chatId, List<String> who);

  /// Stop this account receiving the group's messages (server fan-out).
  Future<void> leaveServer(String chatId);

  /// Still a member? False after a Commit removed me.
  Future<bool> isActive(String chatId);

  /// ADR-088 — the group's admin (identity hex), recorded in the MLS state
  /// every member shares, so all phones agree.
  Future<String?> admin(String chatId);
}

class CoreGroupOps implements GroupOps {
  CoreGroupOps(this._ref);
  final Ref _ref;

  @override
  Future<void> removeMembers(String chatId, List<String> who) async {
    // ADR-083 — the server drops them from the chat's roster too.
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('offline');
    await core.syncRemoveGroupMembers(serverBaseUrl: base, groupIdHex: chatId, memberIdentityHexes: who);
  }

  @override
  Future<void> leaveServer(String chatId) async {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('offline');
    await core.syncLeaveGroupServer(serverBaseUrl: base, groupIdHex: chatId);
  }

  @override
  Future<bool> isActive(String chatId) => core.syncGroupIsActive(groupIdHex: chatId);

  @override
  Future<String?> admin(String chatId) => core.syncGroupAdmin(groupIdHex: chatId);
}

final groupOpsProvider = Provider<GroupOps>((ref) => CoreGroupOps(ref));

/// ADR-035 — my standing in a group: still in it, and who manages it.
class GroupRole {
  const GroupRole({required this.active, this.admin});
  final bool active;

  /// The admin (identity hex, ADR-088); null only outside MLS (tests, demo).
  final String? admin;

  /// May I rename it, add and remove people? The admin — or anyone when
  /// there is none (not an MLS group).
  bool canManage(String? me) => active && (admin == null || admin == me);
}

final groupRoleProvider = FutureProvider.family<GroupRole, String>((ref, chatId) async {
  final ops = ref.read(groupOpsProvider);
  try {
    return GroupRole(active: await ops.isActive(chatId), admin: await ops.admin(chatId));
  } catch (_) {
    return const GroupRole(active: true); // not an MLS group here (tests, demo)
  }
});

class MessageActions {
  MessageActions(this._ref);
  final Ref _ref;

  MessageStore get _store => _ref.read(messageStoreProvider);
  MessageSender get _sender => _ref.read(messageSenderProvider);

  /// My outgoing wire ids → chat (so a server ack can refresh it).
  final Map<String, String> _outgoing = {};

  /// Acks that arrived before their row was stored (media).
  final Set<String> _earlyAcks = {};

  final Map<String, DateTime> _typingSentAt = {};

  void _changed(String chatId) {
    markChatChangedFromRef(_ref, chatId);
    _ref.read(chatsRefresherProvider).schedule(); // bursts of acks / receipts fold together
  }

  bool _setting(AsyncNotifierProvider<BoolSetting, bool> p, bool fallback) => _ref.read(p).value ?? fallback;

  /// The setting's real value — waits for it to load, so a privacy switch
  /// that is off can't read as "on" at cold start (review fix).
  Future<bool> _settingLoaded(AsyncNotifierProvider<BoolSetting, bool> p, bool fallback) async {
    try {
      return await _ref.read(p.future);
    } catch (_) {
      return _setting(p, fallback);
    }
  }

  /// Chats where nothing optional goes out: unaccepted requests and
  /// personal chats with someone blocked (tech-debt 2.27).
  bool _quietChat(String chatId) => isMessageRequest(_ref, chatId) || isBlockedChat(_ref, chatId);

  /// ADR-055 — nobody to tell in Saved messages: no receipts, typing or
  /// screenshot lines there (reactions, pins and edits still sync).
  bool _noSignals(String chatId) => _quietChat(chatId) || isSavedChat(_ref, chatId);

  /// Send a text message (optionally a reply). The row is stored first
  /// ("sending"), then encrypted + sent; a failure marks it failed.
  /// ADR-070 — [entities]: its formatting. Every message from this app
  /// carries it (none = `[]`), so `*stars*` typed as text stay stars.
  Future<void> sendText(String chatId, String text, {ReplyTarget? reply, List<TextEntity>? entities}) async {
    // The server's clock: my message keeps its place for everyone even if
    // this phone's clock is off.
    // Nothing goes to someone I blocked (the chat shows "Unblock" instead
    // of the composer; this catches forwards and the like).
    if (isBlockedChat(_ref, chatId)) throw StateError('blocked');
    final now = serverNow();
    final expire = chatTimer(chatId);
    final id = 'msg-${now.microsecondsSinceEpoch.toRadixString(36)}';
    final wire = newWireId();
    final replyJson = reply?.toJson();
    final entitiesJson = FormattedText(text, entities ?? const []).entitiesJson;
    await _store.insert(
      core.NewMessageRow(
        id: id,
        chatId: chatId,
        tsUnix: now.millisecondsSinceEpoch ~/ 1000,
        body: text,
        kind: 'text',
        isMine: true,
        wireId: wire,
        replyJson: replyJson,
        expireAt: expire > 0 ? now.millisecondsSinceEpoch ~/ 1000 + expire : null,
        entitiesJson: entitiesJson,
      ),
    );
    _outgoing[wire] = chatId;
    _changed(chatId);
    // On the queue before it goes, off it only with the server's ack
    // (owner, 2026-10-20: a message sent with no connection hung "sending"
    // after the connection came back). A send "succeeds" as soon as the
    // frame is handed to the connection — gone if that connection was
    // already dead or is replaced on resume — so only the ack proves it.
    await _queueText(chatId, wire, text, replyJson, expire, entitiesJson);
    // Tech-debt 2.22 — the chat learns my name before my first message; the
    // row is already on screen, so a slow link doesn't hold the message back
    // (tech-debt 2.27, review).
    await _ref.read(peopleProvider).ensureShared(chatId);
    try {
      final preview = await _sender.sendText(
        chatId,
        wire,
        text,
        replyJson: replyJson,
        previewBaseUrl: _ref.read(linkPreviewBaseUrlProvider)(),
        expireSecs: expire,
        entitiesJson: entitiesJson,
      );
      _tried[wire] = (at: DateTime.now(), n: 1);
      if (preview != null) {
        await _store.setMediaJson(id, preview);
        _changed(chatId);
      }
    } catch (e) {
      // Cancelled while it was on its way: the row is already gone.
      if (isCancelledSend(e) || _cancelledWires.contains(wire)) {
        await _unqueue(wire);
        return;
      }
      await _store.raiseStatus([wire], MsgStatus.failed);
      // Already queued: goes out by itself when the connection is back
      // (2026-10-16 UI audit: the text came back into the composer next to
      // its failed copy, and sending it again made two).
      _changed(chatId);
      rethrow;
    }
  }

  /// A media row was stored after its upload — register it for its ack.
  /// Status 211 (tech-debt 2.59) — and put it on the resend queue like a
  /// text ([mediaJson]: what the upload returned): a frame handed to a dead
  /// connection kept its clock forever.
  Future<void> trackStoredOutgoing(
    String chatId,
    String wire, {
    String? mediaJson,
    String? replyJson,
    int expire = 0,
  }) async {
    _outgoing[wire] = chatId;
    if (_earlyAcks.remove(wire)) {
      await _store.raiseStatus([wire], MsgStatus.sent);
      _changed(chatId);
      return;
    }
    if (mediaJson == null) return;
    _tried[wire] = (at: DateTime.now(), n: 1);
    final list = await _pending();
    list.add({
      'chat': chatId,
      'wire': wire,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'media': mediaJson,
      'reply': replyJson,
      'expire': expire,
      'out': true,
    });
    await _savePending(list.length > 500 ? list.sublist(list.length - 500) : list);
  }

  /// Server ack for a submitted frame (frame id = wire id). An ok takes a
  /// text off the resend queue; a refusal leaves it for a few more tries.
  /// [busy] (429, "too many at once"): not a refusal — it stays "sending"
  /// and goes again after [resendDelay] (status 211).
  Future<void> onAck(String frameId, {required bool ok, bool busy = false}) async {
    final receipt = _receiptsOut.remove(frameId);
    if (receipt != null) {
      if (ok) await _store.markReceipted(receipt.chat, receipt.ids, receipt.status);
      return;
    }
    final chatId = _outgoing[frameId];
    if (busy) return;
    if (ok) {
      _acked.add(frameId);
      _tried.remove(frameId);
      await _unqueue(frameId);
    } else {
      await _nack(frameId);
    }
    final n = await _store.raiseStatus([frameId], ok ? MsgStatus.sent : MsgStatus.failed);
    if (n == 0) {
      // Row not stored yet (media) — remember briefly.
      if (ok) _earlyAcks.add(frameId);
      if (_earlyAcks.length > 256) _earlyAcks.remove(_earlyAcks.first);
      return;
    }
    if (chatId != null) _changed(chatId);
  }

  /// Changes that must reach the others even if the connection is gone
  /// right now. Typing, receipts, presence belong to the moment — dropped.
  static const _durable = {'edit', 'delete', 'reaction', 'pin', 'timer', 'group_name'};

  /// 2026-10-16 UI audit: "delete for everyone" (and edit, react) offline
  /// vanished here but stayed on the other phone, with no error. Now a
  /// change that can't go out waits on this phone (settings
  /// `pending_actions`) and goes out, in order, when the connection is back
  /// ([flushPendingActions]); the same wire id, so a copy that did get
  /// through isn't applied twice.
  Future<void> _sendAction(String chatId, Map<String, Object?> action) async {
    final wire = newWireId();
    try {
      await _sender.sendAction(chatId, wire, action);
    } catch (_) {
      if (!_durable.contains(action['t'])) rethrow;
      await _queueAction(chatId, wire, action);
    }
  }

  static const _pendingKey = 'pending_actions';

  Future<List<Map<String, Object?>>> _pending() async {
    try {
      final raw = await _ref.read(settingsStoreProvider).get(_pendingKey);
      if (raw == null || raw.isEmpty) return [];
      return [for (final e in jsonDecode(raw) as List) (e as Map).cast<String, Object?>()];
    } catch (_) {
      return [];
    }
  }

  Future<void> _savePending(List<Map<String, Object?>> list) =>
      _ref.read(settingsStoreProvider).set(_pendingKey, list.isEmpty ? '' : jsonEncode(list));

  Future<void> _queueText(
    String chatId,
    String wire,
    String text,
    String? replyJson,
    int expire,
    String? entitiesJson,
  ) async {
    final list = await _pending();
    list.add({
      'chat': chatId,
      'wire': wire,
      'ts': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'text': text,
      'reply': replyJson,
      'expire': expire,
      'entities': ?entitiesJson,
    });
    await _savePending(list.length > 500 ? list.sublist(list.length - 500) : list);
  }

  /// Drop [wire]'s entry from the queue (it was confirmed or cancelled).
  Future<void> _unqueue(String wire) async {
    final list = await _pending();
    final before = list.length;
    list.removeWhere((e) => e['wire'] == wire);
    if (list.length != before) await _savePending(list);
  }

  /// The server refused a queued text: a few more tries, then it stays
  /// failed (not member of the group any more, too big …).
  Future<void> _nack(String wire) async {
    final list = await _pending();
    final i = list.indexWhere((e) => e['wire'] == wire && _isMessage(e));
    if (i < 0) return;
    final n = ((list[i]['nacks'] as num?)?.toInt() ?? 0) + 1;
    if (n >= kMaxTextRefusals) {
      list.removeAt(i);
    } else {
      list[i]['nacks'] = n;
    }
    await _savePending(list);
  }

  /// A text or media message (not a reaction, edit …): waits for its ack.
  static bool _isMessage(Map<String, Object?> e) => e['text'] is String || e['media'] is String;

  /// Texts the server refused this many times stay failed.
  static const kMaxTextRefusals = 3;

  /// A queued text older than this is given up (marked failed).
  static const kMaxTextAge = Duration(days: 7);

  /// After the n-th unconfirmed try in this run, wait this long before the
  /// next one — unless the connection comes back ([onReconnected]).
  static Duration resendDelay(int n) => switch (n) {
    <= 1 => const Duration(seconds: 20),
    2 => const Duration(minutes: 1),
    3 => const Duration(minutes: 5),
    _ => const Duration(minutes: 30),
  };

  /// Texts handed to the connection in this run and not confirmed yet:
  /// when, and how many times.
  final _tried = <String, ({DateTime at, int n})>{};

  /// Confirmed by the server in this run — a flush under way drops them.
  final _acked = <String>{};

  /// The connection is back: whatever was handed to the old one may be
  /// lost, so every unconfirmed text goes again now.
  Future<int> onReconnected() {
    _tried.clear();
    unawaited(_resendDeliveryReceipts().catchError((Object _) {}));
    return flushPendingActions();
  }

  Future<void> _queueAction(String chatId, String wire, Map<String, Object?> action) async {
    final list = await _pending();
    list.add({'chat': chatId, 'wire': wire, 'action': action});
    // A bounded queue: the oldest go first if someone piles up hundreds.
    await _savePending(list.length > 500 ? list.sublist(list.length - 500) : list);
  }

  bool _flushing = false;

  /// Wire ids cancelled in this run — a flush already under way skips them
  /// and doesn't write them back.
  final _cancelledWires = <String>{};

  /// Send what waited for the connection, oldest first; a chat stops at its
  /// first change that still can't go out (the other chats go on). Returns how many went out. Texts stay queued
  /// after going out until their ack ([onAck]); one tried recently in this
  /// run waits for [resendDelay]; one older than [kMaxTextAge] is given up.
  Future<int> flushPendingActions() async {
    if (_flushing) return 0;
    _flushing = true;
    var sent = 0;
    try {
      final list = await _pending();
      final gone = <Object?>{}; // went out, gave up, or cancelled
      final waiting = <Map<String, Object?>>[]; // texts out, awaiting their ack
      // Status 211 — a chat whose change can't go out now keeps the rest of
      // its changes in order, but no longer holds back the other chats.
      final stuck = <String>{};
      while (list.isNotEmpty) {
        final e = list.first;
        final chat = e['chat'] as String;
        final wire = e['wire'] as String;
        if (_cancelledWires.contains(wire) || _acked.contains(wire)) {
          gone.add(list.removeAt(0)['wire']);
          continue;
        }
        if (stuck.contains(chat)) {
          waiting.add(list.removeAt(0));
          continue;
        }
        final isText = _isMessage(e);
        if (isText) {
          final ts = (e['ts'] as num?)?.toInt();
          final now = DateTime.now();
          if (ts != null && now.difference(DateTime.fromMillisecondsSinceEpoch(ts * 1000)) > kMaxTextAge) {
            await _store.raiseStatus([wire], MsgStatus.failed);
            _changed(chat);
            gone.add(list.removeAt(0)['wire']);
            continue;
          }
          final t = _tried[wire];
          if (t != null && now.difference(t.at) < resendDelay(t.n)) {
            waiting.add(list.removeAt(0));
            continue;
          }
        }
        try {
          if (e['media'] case final String media) {
            _outgoing[wire] = chat;
            await _sender.resendMedia(
              chat,
              wire,
              media,
              replyJson: e['reply'] as String?,
              expireSecs: (e['expire'] as num?)?.toInt() ?? 0,
            );
            await _store.raiseStatus([wire], MsgStatus.sending);
            final t = _tried[wire];
            _tried[wire] = (at: DateTime.now(), n: (t?.n ?? 0) + 1);
            _changed(chat);
          } else if (isText) {
            _outgoing[wire] = chat;
            await _sender.sendText(
              chat,
              wire,
              e['text'] as String,
              replyJson: e['reply'] as String?,
              previewBaseUrl: _ref.read(linkPreviewBaseUrlProvider)(),
              expireSecs: (e['expire'] as num?)?.toInt() ?? 0,
              entitiesJson: e['entities'] as String?,
            );
            await _store.raiseStatus([wire], MsgStatus.sending);
            final t = _tried[wire];
            _tried[wire] = (at: DateTime.now(), n: (t?.n ?? 0) + 1);
            e['out'] = true; // may have arrived: a cancel now also deletes it there
            _changed(chat);
          } else {
            await _sender.sendAction(chat, wire, (e['action'] as Map).cast<String, Object?>());
          }
        } catch (err) {
          if (isCancelledSend(err)) {
            gone.add(list.removeAt(0)['wire']);
            continue;
          }
          // One that keeps failing for another reason doesn't hold the
          // rest back forever (a text waits out its age instead).
          final tries = ((e['tries'] as num?)?.toInt() ?? 0) + 1;
          if (isText || tries < 10) {
            e['tries'] = tries;
            stuck.add(chat);
            waiting.add(list.removeAt(0));
            continue;
          }
        }
        if (isText) {
          waiting.add(list.removeAt(0)); // until its ack
        } else {
          gone.add(list.removeAt(0)['wire']);
        }
        sent++;
      }
      list.insertAll(0, waiting);
      // Re-read before writing: a cancel or a newly queued change may have
      // landed while this ran (it used to be overwritten). Entries still
      // here keep their try count from this run.
      final kept = {for (final e in list) e['wire']: e};
      final latest = await _pending();
      await _savePending([
        for (final e in latest)
          if (!gone.contains(e['wire']) && !_cancelledWires.contains(e['wire']) && !_acked.contains(e['wire']))
            kept[e['wire']] ?? e,
      ]);
    } finally {
      _flushing = false;
    }
    return sent;
  }

  /// Set / switch / remove (null) my reaction.
  Future<void> react(String chatId, String wireId, String? emoji) async {
    if (!await _store.setReaction(chatId, wireId, kMe, emoji)) return;
    _changed(chatId);
    if (_quietChat(chatId)) return; // a reaction would show a stranger I read it
    await _sendAction(chatId, {'t': 'reaction', 'target': wireId, 'emoji': emoji ?? ''});
  }

  /// Edit my own text message (ADR-070: with its new [entities]).
  Future<bool> edit(String chatId, String wireId, String text, {List<TextEntity>? entities}) async {
    final f = FormattedText(text, entities ?? const []).trimmed().normalized();
    if (f.text.isEmpty) return false;
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entitiesJson = f.entitiesJson;
    if (!await _store.applyEdit(chatId, wireId, null, f.text, ts, entitiesJson: entitiesJson)) return false;
    _changed(chatId);
    await _sendAction(chatId, {'t': 'edit', 'target': wireId, 'text': f.text, 'entities': jsonDecode(entitiesJson)});
    return true;
  }

  /// Delete my own message for everyone (tombstone on both sides).
  Future<bool> deleteForEveryone(String chatId, String wireId) async {
    if (!await _store.applyDelete(chatId, wireId, null, DateTime.now().millisecondsSinceEpoch ~/ 1000)) return false;
    _changed(chatId);
    await _sendAction(chatId, {'t': 'delete', 'target': wireId});
    return true;
  }

  /// "Cancel sending" (owner, 2026-10-18): a message of mine that is still
  /// waiting — no connection (it sits in the queue), or not confirmed by the
  /// server yet — goes away. The queue forgets it, the send in flight is
  /// stopped before it reaches the network, and the row is removed here.
  /// If it may already have gone out ([status] still "sending": submitted,
  /// no ack yet) a delete-for-everyone follows it, queued like any other
  /// change, so the other phone drops it too if it did arrive.
  Future<void> cancelSend(String chatId, {required String id, required String wireId, required int status}) async {
    _cancelledWires.add(wireId);
    _sender.cancelSend(wireId);
    _outgoing.remove(wireId);
    final list = await _pending();
    final entry = list.where((e) => e['wire'] == wireId).firstOrNull;
    list.removeWhere((e) => e['wire'] == wireId);
    if (entry != null) await _savePending(list);
    // Never handed to a connection: it can't be anywhere else.
    final neverOut = entry != null && entry['out'] != true && !_tried.containsKey(wireId);
    _tried.remove(wireId);
    await _store.deleteLocal(chatId, [id]);
    _changed(chatId);
    if (status == MsgStatus.sending && !neverOut && looksLikeMlsGroupId(chatId)) {
      await _sendAction(chatId, {'t': 'delete', 'target': wireId});
    }
  }

  /// Status 211 — "Retry" on a text that didn't go: back on the queue with
  /// fresh tries and age, and out now if the connection is up. The same
  /// wire id, so a copy that did arrive isn't shown twice.
  /// A media message goes the same way with its [mediaJson] (no re-upload).
  Future<void> retrySend(
    String chatId, {
    required String wireId,
    required String text,
    String? mediaJson,
    String? replyJson,
    String? entitiesJson,
  }) async {
    _cancelledWires.remove(wireId);
    _acked.remove(wireId);
    _outgoing[wireId] = chatId;
    final list = await _pending();
    list.removeWhere((e) => e['wire'] == wireId);
    await _savePending(list);
    if (mediaJson != null) {
      await trackStoredOutgoing(chatId, wireId, mediaJson: mediaJson, replyJson: replyJson, expire: chatTimer(chatId));
    } else {
      await _queueText(chatId, wireId, text, replyJson, chatTimer(chatId), entitiesJson);
    }
    _tried.remove(wireId);
    await _store.raiseStatus([wireId], MsgStatus.sending);
    _changed(chatId);
    await flushPendingActions();
  }

  /// Remove messages from this device only.
  Future<void> deleteForMe(String chatId, List<String> ids) async {
    await _store.deleteLocal(chatId, ids);
    _changed(chatId);
  }

  /// Pin (or unpin with null) a message at the top of the chat — for
  /// everyone in it, my other devices included (tech-debt 2.22).
  /// [unpinning] — the message being unpinned, when the caller knows it
  /// (the in-memory list can be a step behind).
  Future<void> pin(String chatId, String? wireId, {String? unpinning}) async {
    final previous = unpinning ?? pinnedMessage(chatId);
    await _store.setPinnedMessage(chatId, wireId);
    _ref.invalidate(chatsProvider);
    final target = wireId ?? previous;
    if (target == null || !looksLikeMlsGroupId(chatId)) return;
    if (_quietChat(chatId)) return; // stays local in requests / blocked chats
    try {
      await _sendAction(chatId, {'t': 'pin', 'target': target, 'pinned': wireId != null});
    } catch (_) {
      // Offline: pinned here; the others see it next time someone pins.
    }
  }

  /// Wire id of the chat's pinned message, if any.
  String? pinnedMessage(String chatId) =>
      (_ref.read(chatsProvider).value ?? const []).where((c) => c.id == chatId).firstOrNull?.pinnedMsg;

  /// The chat's disappearing timer (seconds, 0 = off).
  int chatTimer(String chatId) =>
      (_ref.read(chatsProvider).value ?? const []).where((c) => c.id == chatId).firstOrNull?.disappearSecs ?? 0;

  // ── ADR-035 — leave, remove, rename ───────────────────────────────

  /// How long to wait before committing a leaver's removal — spread out so
  /// the members don't all race to do it. Tests set zero.
  static Duration Function() peerLeftJitter = () => Duration(milliseconds: 300 + Random().nextInt(2000));

  GroupOps get _groups => _ref.read(groupOpsProvider);

  /// A name for a system line (no ':' — it separates the line's fields).
  /// The line keeps it for good, so a nameless person stays a short code
  /// here, not "Member": "Member removed Member" would tell nobody apart.
  String _nameOf(String peer) {
    final names = _ref.read(peerNamesProvider).value ?? const <String, String>{};
    return (names[peer] ?? names[peer.toLowerCase()] ?? shortKey(peer)).replaceAll(':', ' ');
  }

  /// Remove people from the group (admin). The Commit takes them out of the
  /// MLS group; then the others read who did it.
  Future<void> removeMembers(String chatId, List<String> who) async {
    if (who.isEmpty) return;
    await _groups.removeMembers(chatId, who);
    await _sendAction(chatId, {'t': 'removed', 'who': who});
    await _systemLine(chatId, 'member-removed:me:${who.map(_nameOf).join(', ')}');
    _ref.invalidate(groupRoleProvider(chatId));
    _changed(chatId);
  }

  /// Rename the group for everyone (admin).
  Future<void> renameGroup(String chatId, String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final current = (_ref.read(chatsProvider).value ?? const []).where((c) => c.id == chatId).firstOrNull?.name ?? '';
    if (clean == current) return;
    await _sendAction(chatId, {'t': 'group_name', 'name': clean});
    await _store.setGroupName(chatId, clean, const []);
    await _systemLine(chatId, 'group-renamed:me:$clean');
    _ref.invalidate(chatsProvider);
    _changed(chatId);
  }

  /// ADR-037 — tell a group I left without leaving it here (account
  /// deletion: the server and this phone are wiped next).
  Future<void> announceLeave(String chatId) => _sendAction(chatId, {'t': 'leave'});

  /// Leave the group: tell the others (one of them commits my removal —
  /// MLS can't commit its own), stop the server sending to me, and drop
  /// the chat here.
  Future<void> leaveGroup(String chatId) async {
    try {
      await _sendAction(chatId, {'t': 'leave'});
    } catch (_) {
      // Offline: the server step below still takes me out of the fan-out.
    }
    await _groups.leaveServer(chatId);
    await _ref.read(chatActionsProvider).delete(chatId);
    _ref.invalidate(chatsProvider);
  }

  /// People who said they leave, per chat: their removal Commit needs no
  /// "X removed Y" line (the "Y left" one is there).
  final Set<String> _leaving = {};

  /// A Commit arrived in [chatId]: if it removed me, say so once and stop
  /// receiving the group. [membership] (`{"by", "added", "removed"}`, from
  /// Rust): who let people in or took them out — a line for everyone, so
  /// nobody is added or removed quietly (mls-identity:3).
  Future<void> onGroupCommit(String chatId, [String? membership]) async {
    _ref.invalidate(groupRoleProvider(chatId));
    try {
      final m = jsonDecode(membership ?? '{}') as Map<String, dynamic>;
      final by = _nameOf('${m['by'] ?? ''}');
      final me = (_ref.read(netServiceProvider).myIdentityHex ?? '').toLowerCase();
      List<String> people(String key) => [
        for (final p in (m[key] as List? ?? const []).whereType<String>())
          if (p != me) p,
      ];
      final added = people('added');
      final removed = [
        for (final p in people('removed'))
          if (!_leaving.remove('$chatId:$p')) p,
      ];
      if (added.isNotEmpty) await _systemLine(chatId, 'member-added:by:$by:${added.map(_nameOf).join(', ')}');
      if (removed.isNotEmpty) await _systemLine(chatId, 'member-removed:by:$by:${removed.map(_nameOf).join(', ')}');
      if (added.isNotEmpty || removed.isNotEmpty) _changed(chatId);
    } catch (_) {
      // Not that shape: nothing to say.
    }
    if (await _groups.isActive(chatId)) {
      // Someone may have joined: they learn my name, photo and bio now, not
      // only after my next message there (owner, 2026-10-19). A no-op when
      // the members are the same.
      await _ref.read(peopleProvider).ensureShared(chatId);
      return;
    }
    await _systemLine(chatId, 'you-removed');
    _changed(chatId);
    try {
      await _groups.leaveServer(chatId);
    } catch (_) {
      // Offline: the server keeps sending until next time; nothing decrypts.
    }
  }

  /// [peer] left: a line, then (if they're still in the MLS group) one of
  /// us commits their removal. Several members may try at once — the
  /// server orders Commits, the losers' attempts just fail.
  Future<void> _onPeerLeft(String chatId, String peer) async {
    _leaving.add('$chatId:${peer.toLowerCase()}');
    await _systemLine(chatId, 'member-left:${_nameOf(peer)}');
    unawaited(
      Future<void>.delayed(peerLeftJitter(), () async {
        try {
          if (await _groups.isActive(chatId)) await _groups.removeMembers(chatId, [peer]);
        } catch (_) {
          // Someone else was first (or it's already done).
        }
        _ref.invalidate(groupRoleProvider(chatId));
      }),
    );
  }

  /// Local "timer changed" line in the chat.
  Future<void> _systemLine(String chatId, String text) async {
    final now = serverNow();
    await _store.insert(
      core.NewMessageRow(
        id: 'sys-${now.microsecondsSinceEpoch.toRadixString(36)}',
        chatId: chatId,
        tsUnix: now.millisecondsSinceEpoch ~/ 1000,
        body: text,
        kind: 'system',
        isMine: true,
      ),
    );
  }

  /// ADR-030 — I took a screenshot while [chatId] was open. Only chats
  /// with disappearing messages say so (as in Telegram's secret chats):
  /// a line for me, and the same news for everyone else in the chat.
  /// [recording]: the screen is being recorded (or mirrored) with the chat
  /// open — same rules, its own line.
  Future<bool> screenshotTaken(String chatId, {bool recording = false}) async {
    if (!looksLikeMlsGroupId(chatId)) return false;
    final chat = (_ref.read(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.id == chatId).firstOrNull;
    if (chat == null || chat.disappearSecs == 0) return false;
    if (_noSignals(chatId)) return false; // a stranger / blocked person learns nothing
    await _systemLine(chatId, recording ? 'recording:me' : 'screenshot:me');
    _changed(chatId);
    await _sendAction(chatId, {'t': 'screenshot', if (recording) 'recording': true});
    return true;
  }

  /// Set the chat's disappearing timer (0 = off) — on both sides.
  /// A call line in the chat (`call-missed:audio|video`) — from the call
  /// provider when a call to me went unanswered.
  Future<void> callLine(String chatId, String code) async {
    await _systemLine(chatId, code);
    _ref.invalidate(chatsProvider);
    _changed(chatId);
  }

  Future<void> setTimer(String chatId, int secs) async {
    await _store.setDisappear(chatId, secs);
    // Stored as a code, shown in the reader's language (systemLineText).
    await _systemLine(chatId, 'timer:$secs:me');
    _changed(chatId);
    await _sendAction(chatId, {'t': 'timer', 'secs': secs});
    // Tech-debt 2.5 — the server drops its stored copies on the same timer.
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base != null && looksLikeMlsGroupId(chatId)) {
      try {
        unawaited(
          core.syncSetChatRetention(serverBaseUrl: base, groupIdHex: chatId, afterSecs: secs).catchError((Object e) {
            // ignore: avoid_print
            print('[sinhron] chat retention not set: $e');
          }),
        );
      } catch (_) {}
    }
  }

  /// Remove messages whose time is up; refresh their chats.
  Future<void> expireNow({DateTime? now}) async {
    final t = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    for (final c in await _store.expire(t)) {
      _changed(c);
    }
  }

  /// Delivery receipts for everything received in a chat (always on —
  /// it's what turns ✓ into ✓✓ for the sender).
  Future<void> sendDeliveryReceipts(String chatId) async {
    if (isSavedChat(_ref, chatId)) return;
    final ids = await _store.pendingReceipts(chatId, ReceiptStatus.delivered);
    if (ids.isEmpty) return;
    await _sendReceipt(chatId, ids, ReceiptStatus.delivered);
  }

  /// Receipts handed to the connection, by wire id, until the server's ack.
  final _receiptsOut = <String, ({String chat, List<String> ids, int status})>{};

  /// Status 211 — a receipt counts as sent only with the server's ack (one
  /// handed to a dead connection was lost, and the sender's ✓ never became
  /// ✓✓). Until then its rows stay pending: the next message in the chat,
  /// or the connection coming back ([onReconnected]), sends them again —
  /// a repeat only raises a status that's already raised.
  Future<void> _sendReceipt(String chatId, List<String> ids, int status) async {
    final wire = newWireId();
    _receiptsOut[wire] = (chat: chatId, ids: ids, status: status);
    if (_receiptsOut.length > 256) _receiptsOut.remove(_receiptsOut.keys.first);
    try {
      await _sender.sendAction(chatId, wire, {'t': 'receipt', 'read': status == ReceiptStatus.read, 'ids': ids});
    } catch (_) {
      _receiptsOut.remove(wire);
      rethrow;
    }
  }

  /// The connection is back: delivery receipts that didn't get through go
  /// now, for every chat (not only when its next message comes).
  Future<void> _resendDeliveryReceipts() async {
    for (final c in await _ref.read(chatsProvider.future)) {
      if (c.id case final id?) await sendDeliveryReceipts(id);
    }
    final open = _ref.read(openChatProvider);
    if (open != null) await sendReadReceipts(open);
  }

  /// Read receipts for a chat the user is looking at — only when the
  /// setting is on.
  Future<void> sendReadReceipts(String chatId) async {
    if (!await _settingLoaded(readReceiptsProvider, true)) return;
    if (_noSignals(chatId)) return; // not to strangers or blocked people (2.27)
    final ids = await _store.pendingReceipts(chatId, ReceiptStatus.read);
    if (ids.isEmpty) return;
    await _sendReceipt(chatId, ids, ReceiptStatus.read);
  }

  /// "Typing…" — at most one "active" per 4 s per chat; "stopped" always.
  Future<void> typing(String chatId, bool active, {DateTime? now}) async {
    if (!await _settingLoaded(typingIndicatorsProvider, true)) return;
    if (_noSignals(chatId)) return;
    final t = now ?? DateTime.now();
    if (active) {
      final last = _typingSentAt[chatId];
      if (last != null && t.difference(last) < const Duration(seconds: 4)) return;
      _typingSentAt[chatId] = t;
    } else {
      if (_typingSentAt.remove(chatId) == null) return;
    }
    await _sendAction(chatId, {'t': 'typing', 'active': active});
  }

  /// An action arrived from a peer ([senderId] is MLS-authenticated).
  /// Returns whether anything changed.
  Future<bool> onIncomingAction(String chatId, String kind, String actionJson, String? senderId) async {
    final Map<String, Object?> a;
    try {
      a = jsonDecode(actionJson) as Map<String, Object?>;
    } catch (_) {
      return false;
    }
    // Without an authenticated sender nothing can be attributed.
    final peer = senderId ?? '';
    // My other device's edit / delete is mine: its rows here are is_mine = 1.
    final author = senderId != null && senderId == _ref.read(netServiceProvider).myIdentityHex ? null : peer;
    final target = (a['target'] as String?) ?? '';
    var changed = false;
    switch (kind) {
      case 'reaction':
        if (peer.isEmpty) return false;
        final e = (a['emoji'] as String?) ?? '';
        changed = await _store.setReaction(chatId, target, peer, e.isEmpty ? null : e);
      case 'edit':
        changed = await _store.applyEdit(
          chatId,
          target,
          author,
          (a['text'] as String?) ?? '',
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
          // ADR-070 — absent: an older app's edit (markers may be read).
          entitiesJson: a['entities'] is List ? jsonEncode(a['entities']) : null,
        );
      case 'delete':
        changed = await _store.applyDelete(chatId, target, author, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      case 'receipt':
        final read = a['read'] == true;
        final ids = ((a['ids'] as List?) ?? const []).cast<String>();
        // Reciprocity: with my read receipts off I don't see theirs.
        final show = read && await _settingLoaded(readReceiptsProvider, true) ? MsgStatus.read : MsgStatus.delivered;
        changed = await _store.raiseStatusInChat(chatId, ids, show) > 0;
        // Status 213 — who and when, for "Message info" (a group: each).
        if (peer.isNotEmpty && ids.isNotEmpty) {
          await _store.recordReceipts(
            chatId,
            ids,
            peer,
            read: show == MsgStatus.read,
            ts: serverNow().millisecondsSinceEpoch ~/ 1000,
          );
        }
      case 'timer':
        final secs = (a['secs'] as num?)?.toInt() ?? 0;
        await _store.setDisappear(chatId, secs);
        await _systemLine(chatId, 'timer:$secs:peer');
        changed = true;
      // ADR-030 — someone took a screenshot of this chat.
      case 'screenshot':
        if (peer.isEmpty) return false;
        final chat = (_ref.read(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.id == chatId).firstOrNull;
        final names = _ref.read(peerNamesProvider).value ?? const <String, String>{};
        final who = names[peer] ?? (chat != null && !chat.group ? chat.name : shortKey(peer));
        await _systemLine(chatId, '${a['recording'] == true ? 'recording' : 'screenshot'}:peer:$who');
        changed = true;
      // Tech-debt 2.22 — a member's display name; a pin for the chat.
      case 'profile':
        if (peer.isEmpty) return false;
        final name = (a['name'] as String?) ?? '';
        final chat = (_ref.read(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.id == chatId).firstOrNull;
        await _ref
            .read(peopleProvider)
            .onProfile(
              peer,
              name,
              avatarB64: (a['avatar'] as String?) ?? '',
              bio: (a['bio'] as String?) ?? '',
              personalChatId: chat != null && !chat.group ? chatId : null,
            );
        // A personal chat is called "Group xxxx" (they started it) or
        // "Chat <their key>" (I started it by key or an old QR) until they
        // say who they are. Only placeholders are replaced, never a name.
        if (chat != null && !chat.group && name.trim().isNotEmpty) {
          final placeholders = [
            for (final lang in const ['en', 'ru']) ...[
              lookupAppL10n(Locale(lang)).netGroupDefaultName(shortId(chatId)),
              if (peer.length >= 8) lookupAppL10n(Locale(lang)).navNewChatName(peer.substring(0, 8)),
              lookupAppL10n(Locale(lang)).newChatPlaceholder,
              lookupAppL10n(Locale(lang)).newGroupPlaceholder,
            ],
          ];
          for (final placeholder in placeholders) {
            if (chat.name == placeholder && await _store.renameIf(chatId, placeholder, name.trim())) {
              _ref.invalidate(chatsProvider);
              break;
            }
          }
        }
        return false;
      // ADR-034 — the group's name (from its creator, or after an add).
      case 'group_name':
        final name = ((a['name'] as String?) ?? '').trim();
        if (peer.isEmpty || name.isEmpty) return false;
        final placeholders = [
          for (final lang in const ['en', 'ru']) ...[
            lookupAppL10n(Locale(lang)).netGroupDefaultName(shortId(chatId)),
            lookupAppL10n(Locale(lang)).newGroupPlaceholder,
            lookupAppL10n(Locale(lang)).newChatPlaceholder,
          ],
        ];
        if (await _store.setGroupName(chatId, name, placeholders)) {
          _ref.invalidate(chatsProvider);
          changed = true;
        } else {
          // ADR-035 — a real rename: only from whoever manages the group.
          final role = await _ref.read(groupRoleProvider(chatId).future);
          if (!role.canManage(peer)) return false;
          // No placeholders = a rename (storage: chat_set_group_name).
          if (!await _store.setGroupName(chatId, name, const [])) return false;
          await _systemLine(chatId, 'group-renamed:by:${_nameOf(peer)}:$name');
          _ref.invalidate(chatsProvider);
          changed = true;
        }
      case 'leave':
        if (peer.isEmpty) return false;
        await _onPeerLeft(chatId, peer);
        changed = true;
      // The removal Commit itself says who removed whom (onGroupCommit);
      // this line (old apps still send it) would only repeat it.
      case 'removed':
        return false;
      case 'pin':
        if (target.isEmpty) return false;
        if (a['pinned'] == false) {
          // Compare-and-clear in storage: the in-memory list may be stale.
          if (!await _store.unpinIf(chatId, target)) return false;
        } else {
          await _store.setPinnedMessage(chatId, target);
        }
        changed = true;
      case 'typing':
        if (_setting(typingIndicatorsProvider, true)) {
          _ref.read(typingChatsProvider.notifier).set(chatId, a['active'] == true);
          _ref.read(typingPeopleProvider.notifier).set(chatId, senderId, a['active'] == true);
        }
        return false;
      default:
        return false;
    }
    if (changed) _changed(chatId);
    return changed;
  }

  /// A new message from a peer was stored: it stops their "typing",
  /// is acknowledged as delivered, and as read if the chat is open.
  Future<void> afterIncomingMessage(String chatId) async {
    _ref.read(typingChatsProvider.notifier).set(chatId, false);
    _ref.read(typingPeopleProvider.notifier).clear(chatId);
    try {
      await sendDeliveryReceipts(chatId);
      if (_ref.read(openChatProvider) == chatId) await sendReadReceipts(chatId);
    } catch (_) {
      // Offline — receipts go out next time (rows stay "pending").
    }
  }
}

final messageActionsProvider = Provider<MessageActions>((ref) {
  final actions = MessageActions(ref);
  // Changes made offline go out as soon as the connection is back.
  ref.listen(netStatusProvider, fireImmediately: true, (_, s) {
    if (s == NetStatus.connected) {
      unawaited(actions.onReconnected().catchError((Object _) => 0));
      // A profile that didn't go (offline, a new round, a new member) goes
      // now — not only when that chat is next opened (owner, 2026-10-19).
      unawaited(ref.read(peopleProvider).shareEverywhere().catchError((Object _) => 0));
    }
  });
  return actions;
});

/// Names and blocking (tech-debt 2.22 / 2.27); actions go out through the
/// same sender as reactions.
final peopleProvider = Provider<People>(
  (ref) =>
      People(ref, send: (chatId, action) => ref.read(messageSenderProvider).sendAction(chatId, newWireId(), action)),
);

/// Deletes expired disappearing messages: on start, every 15 s, and
/// whenever the app comes back to the foreground (§6 item 51).
class ExpiryJanitor extends ConsumerStatefulWidget {
  const ExpiryJanitor({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ExpiryJanitor> createState() => _ExpiryJanitorState();
}

class _ExpiryJanitorState extends ConsumerState<ExpiryJanitor> with WidgetsBindingObserver {
  Timer? _tick;

  void _run() {
    // Storage may not be open (onboarding, tests) — just skip.
    final actions = ref.read(messageActionsProvider);
    actions.expireNow().catchError((Object _) {});
    // Texts the server hasn't confirmed go again (after [resendDelay]).
    if (ref.read(netStatusProvider) == NetStatus.connected) {
      actions.flushPendingActions().catchError((Object _) => 0);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(_run);
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _run());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _run();
  }

  @override
  void dispose() {
    _tick?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
