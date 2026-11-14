// Chat-list data providers — Riverpod surface over `sinhron_storage`
// (SQLite via FFI). Introduced in WU 73.
//
// Pattern note: this is a `FutureProvider` + manual `ref.invalidate` after
// writes (same as `identityProvider`), NOT a `StreamProvider`. Reason:
// there is no real event stream from Rust yet — once MLS sync lands and
// the Core can emit a "chats changed" signal, we'll convert this to a
// `StreamProvider` (or an `AsyncNotifier` that owns the stream). The call
// sites that do `ref.invalidate(chatsProvider)` after a write today won't
// need to change — they'll just become redundant once the stream pushes.
//
// No demo seeding: a fresh install starts with an empty list and the
// table is the source of truth from the first launch.

import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rich_text.dart';
import '../server_clock.dart';
import '../../features/chat_list/chat_data.dart';
import '../../l10n/l10n.dart';
import '../../features/stickers/sticker_codec.dart';
import '../../features/stickers/sticker_store.dart';
import '../../src/rust/api/simple.dart' as core;
import '../services/media_loader.dart';
import '../services/net_service.dart';
import 'chat_messages.dart';
import 'message_actions.dart';
import 'pending_media.dart';
import 'saved_messages.dart';
import 'settings_providers.dart' show contactAliasesProvider;

/// A chat's messages changed (sent, received, media/preview attached):
/// refresh the chat view's newest page + the full list used by shared
/// media. Use instead of invalidating messagesProvider directly.
void markChatChanged(WidgetRef ref, String chatId) {
  ref.invalidate(messagesProvider(chatId));
  ref.read(chatRevisionProvider(chatId).notifier).bump();
}

/// [markChatChanged] for code that holds a plain `Ref` (notifiers,
/// services).
void markChatChangedFromRef(Ref ref, String chatId) {
  ref.invalidate(messagesProvider(chatId));
  ref.read(chatRevisionProvider(chatId).notifier).bump();
}

/// All chats, ordered pinned-first then most-recently-active. Maps
/// Rust-side `StoredChatSummary` rows to the existing `ChatPreview` UI
/// type so screens don't need to know about the SQLite layer.
///
/// No demo seeding any more (UI backlog §1 item 8): a fresh install
/// shows a real empty state, never fake conversations.
///
/// ADR-055 — my Saved messages, once made, is marked and comes first.
final chatsProvider = FutureProvider<List<ChatPreview>>((ref) async {
  final rows = await core.storageChatsList();
  final savedId = await ref.watch(savedChatIdProvider.future);
  // A personal chat is called by my own name for its person, if I gave one.
  final aliases = await ref.watch(contactAliasesProvider.future);
  ChatPreview named(ChatPreview c) {
    final alias = c.group ? null : aliases[c.peerId?.toLowerCase()];
    return alias == null ? c : c.copyWith(name: alias);
  }

  return markSavedChat([for (final r in rows) named(chatPreviewFromStored(r))], savedId);
});

/// Tech-debt 2.27 — is [chatId] an unanswered message request? (From the
/// loaded chat list; unknown chats count as not.)
bool isMessageRequest(Ref ref, String chatId) =>
    (ref.read(chatsProvider).value ?? const <ChatPreview>[]).any((c) => c.id == chatId && c.request);

/// Tech-debt 2.20 — incoming messages re-read the chat list through this,
/// not `invalidate(chatsProvider)` directly. One read at a time: the first
/// change refreshes at once; changes that arrive while that read is in
/// flight fold into a single re-read when it finishes. A reconnect that
/// drains hundreds of queued messages reads the list a handful of times,
/// not once per message. No timers (nothing lingers after a test).
class ChatsRefresher {
  ChatsRefresher({required void Function() invalidate, required Future<void> Function() read})
    : _invalidate = invalidate,
      _read = read;
  final void Function() _invalidate;
  final Future<void> Function() _read;
  bool _inFlight = false;
  bool _dirty = false;

  void schedule() {
    if (_inFlight) {
      _dirty = true;
      return;
    }
    _inFlight = true;
    _invalidate();
    _read().then((_) {}, onError: (Object _) {}).whenComplete(() {
      _inFlight = false;
      if (_dirty) {
        _dirty = false;
        schedule();
      }
    });
  }
}

final chatsRefresherProvider = Provider<ChatsRefresher>(
  (ref) => ChatsRefresher(invalidate: () => ref.invalidate(chatsProvider), read: () => ref.read(chatsProvider.future)),
);

/// Create an MLS-encrypted chat with a known recipient.
///
/// Flow:
///   1. `sync_create_group` — generate a fresh MLS group, returns
///      opaque group_id_hex.
///   2. `sync_fetch_kp_and_invite` — GET recipient's KeyPackage from
///      the server, run MLS Add proposal → produces (commit, welcome).
///   3. `net_send_welcome` — push the welcome through WS so the
///      recipient's session can `sync_join_via_welcome`.
///   4. Upsert local chat row keyed by group_id_hex so subsequent
///      Pushes route here.
///
/// `httpBaseUrl` should be the HTTP origin (e.g. `http://localhost:8080`).
/// Returns the new chat id (= group_id_hex) for navigation.
Future<String> createMlsChat(
  WidgetRef ref, {
  required String recipientIdentityHex,
  required String displayName,
  required String httpBaseUrl,
}) async {
  // 1. Create the MLS group.
  final groupIdHex = await core.syncCreateGroup();

  // 2. Fetch recipient KP from server + invite via MLS Add.
  final invite = await core.syncFetchKpAndInvite(
    serverBaseUrl: httpBaseUrl,
    groupIdHex: groupIdHex,
    targetIdentityPubkeyHex: recipientIdentityHex,
  );

  // 3. Send Welcome via WS so the recipient's session joins.
  await core.netSendWelcome(
    recipientIdentityPubkeyHex: recipientIdentityHex,
    groupIdHex: groupIdHex,
    welcomeB64: invite.welcomeB64,
  );

  // 4. Local chat row — id = group_id_hex so encryption + fanout route
  //    consistently.
  final now = DateTime.now();
  await core.storageChatUpsert(
    id: groupIdHex,
    displayName: displayName,
    isGroup: false,
    muted: false,
    pinned: false,
    unreadCount: 0,
    lastMsgPreview: lookupAppL10n(Locale(currentLanguage)).chatsEncryptedStarted,
    lastMsgTsUnix: now.millisecondsSinceEpoch ~/ 1000,
    lastMsgKind: 'text',
    lastMsgSenderLabel: null,
    lastMsgMine: true,
    createdAtUnix: now.millisecondsSinceEpoch ~/ 1000,
  );
  // Its person, from the start: "Message" finds this chat again before
  // their profile comes (owner, 2026-11-03 — it made a second one).
  await core.storageChatSetPeer(chatId: groupIdHex, peerId: recipientIdentityHex.toLowerCase());
  // ADR-025 — bring our own other devices into the new chat (pending
  // Commit + Welcome to ourselves). Not awaited: it waits for server Acks.
  // After the chat row: the history it sends them carries the chat's name
  // from that row (see createMlsGroup).
  unawaited(ref.read(netServiceProvider).syncDevices(groupIdsHex: [groupIdHex]));
  ref.invalidate(chatsProvider);
  return groupIdHex;
}

/// ADR-034 — an MLS group with several people, made in ONE Commit:
///   1. `sync_create_group`;
///   2. `sync_fetch_kps_and_invite_people` — every device of every member,
///      one Welcome, one announce (nobody is added unless all can be);
///   3. `net_send_welcome` — a copy for each member, addressed to their
///      devices;
///   4. local chat row (`isGroup: true`), then the group's name as a
///      `group_name` action — the Welcome carries no name, so members
///      see a placeholder until it arrives (right after the Welcome).
/// Returns the chat id (= group_id_hex).
Future<String> createMlsGroup(
  WidgetRef ref, {
  required String name,
  required List<String> memberIdentityHexes,
  required String httpBaseUrl,
}) async {
  final groupIdHex = await core.syncCreateGroup();
  final invite = await core.syncFetchKpsAndInvitePeople(
    serverBaseUrl: httpBaseUrl,
    groupIdHex: groupIdHex,
    memberIdentityHexes: memberIdentityHexes,
  );
  await _sendWelcomes(memberIdentityHexes, groupIdHex, invite.welcomeB64);

  final now = DateTime.now();
  await core.storageChatUpsert(
    id: groupIdHex,
    displayName: name,
    isGroup: true,
    muted: false,
    pinned: false,
    unreadCount: 0,
    lastMsgPreview: lookupAppL10n(Locale(currentLanguage)).chatsEncryptedStarted,
    lastMsgTsUnix: now.millisecondsSinceEpoch ~/ 1000,
    lastMsgKind: 'text',
    lastMsgSenderLabel: null,
    lastMsgMine: true,
    createdAtUnix: now.millisecondsSinceEpoch ~/ 1000,
  );
  ref.invalidate(chatsProvider);
  await _sendGroupName(ref, groupIdHex, name);
  // ADR-025 — our own other devices join through device sync. Only now:
  // the history it hands them carries the group's name read from the chat
  // row. Started before the row existed (until 2026-11-14) it sent an
  // empty name, and my other device kept "Group ab12…" for good — the
  // `group_name` above is from an epoch that device was not in.
  unawaited(ref.read(netServiceProvider).syncDevices(groupIdsHex: [groupIdHex]));
  return groupIdHex;
}

/// ADR-034 — add people to an existing group: one Commit the server orders
/// (it reaches every current member), a Welcome for each new person, then
/// the group's name again so they see it, and my profile.
Future<void> addGroupMembers(
  WidgetRef ref, {
  required String chatId,
  required String name,
  required List<String> memberIdentityHexes,
  required String httpBaseUrl,
}) async {
  final invite = await core.syncAddGroupMembers(
    serverBaseUrl: httpBaseUrl,
    groupIdHex: chatId,
    memberIdentityHexes: memberIdentityHexes,
  );
  await _sendWelcomes(memberIdentityHexes, chatId, invite.welcomeB64);
  await _sendGroupName(ref, chatId, name);
  // The newcomers learn my name, photo and bio (the "already told" mark
  // counts members, so this sends once).
  unawaited(ref.read(peopleProvider).ensureShared(chatId));
  ref.invalidate(chatsProvider);
}

Future<void> _sendWelcomes(List<String> people, String groupIdHex, String welcomeB64) async {
  for (final person in people.toSet()) {
    await core.netSendWelcome(recipientIdentityPubkeyHex: person, groupIdHex: groupIdHex, welcomeB64: welcomeB64);
  }
}

/// Best effort: the group exists either way; a lost name leaves members
/// with the placeholder.
Future<void> _sendGroupName(WidgetRef ref, String chatId, String name) async {
  try {
    await ref.read(messageSenderProvider).sendAction(chatId, newWireId(), {'t': 'group_name', 'name': name});
  } catch (e) {
    // ignore: avoid_print
    print('[sinhron] group name not sent: $e');
  }
}

/// True iff [chatId] looks like an MLS group_id_hex (≥40 hex chars).
/// Used by `sendMessage` to route MLS-encrypted sends through
/// `net_send_encrypted` instead of the legacy `net_send_submit`+hash
/// path used for seed/demo chats.
bool looksLikeMlsGroupId(String chatId) => _looksLikeMlsGroupId(chatId);

bool _looksLikeMlsGroupId(String chatId) {
  // OpenMLS group ids are 16 random bytes = 32 hex. The old bound (40)
  // rejected every real chat ("not encrypted", nothing could be sent);
  // legacy ids are `chat-…` or 16 hex, so 32 still keeps them out.
  if (chatId.length < 32) return false;
  return RegExp(r'^[0-9a-f]+$').hasMatch(chatId);
}

/// Messages for a specific chat, oldest-first (display order in ChatView).
///
/// Family-keyed by `chatId` so each open chat gets its own cache slot.
/// Riverpod auto-disposes the entry when no widget watches it (default
/// `autoDispose` behavior on family providers in 3.x).
///
/// Like `chatsProvider`, this is a FutureProvider + manual invalidate
/// rather than a StreamProvider — see ADR-009 for the rationale. Once
/// MLS sync lands and emits a "message arrived for chat X" signal, we
/// upgrade this to a true stream without changing call sites.
final messagesProvider = FutureProvider.family<List<core.StoredMessageSummary>, String>((ref, chatId) async {
  return await core.storageMessagesList(chatId: chatId, limit: null);
});

/// Persist an outgoing text message and refresh the relevant providers.
///
/// Updates both `messagesProvider(chatId)` (so ChatView sees the new
/// bubble) AND `chatsProvider` (so ChatList's last-message preview /
/// timestamp catches up — those are denormalized columns on `chats` that
/// `storage::message_append` updates inside the same transaction).
Future<void> sendMessage(
  WidgetRef ref, {
  required String chatId,
  required String body,
  ReplyTarget? reply,
  List<TextEntity>? entities,
}) async {
  // Never send unencrypted (UI backlog §1 item 8): legacy non-MLS demo
  // chats used to put plaintext on the wire.
  if (!_looksLikeMlsGroupId(chatId)) {
    throw UnsupportedError('this chat is not end-to-end encrypted');
  }
  // Stored first ("sending" ✓ pending), then MLS envelope with the
  // optional reply quote / link preview (ADR-017/018/019); the server
  // ack flips it to "sent".
  await ref.read(messageActionsProvider).sendText(chatId, body, reply: reply, entities: entities);
}

/// ADR-070 — a caption's formatting for Rust (`[]` = plain).
String _captionJson(String caption, List<TextEntity>? entities) =>
    FormattedText(caption, entities ?? const []).entitiesJson;

/// Largest file we try to send (mirrors Rust `media::MAX_MEDIA_BYTES`):
/// Padmé size padding (≤2 % here) + AES-GCM must stay under the
/// server's default SINHRON_MEDIA_MAX_BYTES of 100 MiB.
const int kMaxMediaBytes = 95 * 1024 * 1024;

/// Media sends need an MLS chat and a connected server — nothing is ever
/// sent unencrypted. Returns the server base URL.
String _mediaPreflight(WidgetRef ref, String chatId, int size) {
  if (!_looksLikeMlsGroupId(chatId)) {
    throw UnsupportedError('media needs an end-to-end encrypted chat');
  }
  if (size > kMaxMediaBytes) {
    throw ArgumentError('file is larger than ${kMaxMediaBytes ~/ (1024 * 1024)} MB');
  }
  final base = ref.read(netServiceProvider).httpBaseUrl;
  if (base == null) throw StateError('not connected to a server');
  return base;
}

/// One media send: [upload] encrypts + uploads + sends over MLS and
/// returns the media JSON; then the local row is stored. Runs under
/// [pendingMediaProvider] so the chat shows "Sending…" / "Not sent —
/// tap to retry". The job captures only plain data (no WidgetRef), so a
/// retry still works after the chat screen is gone.
Future<void> _sendMedia(
  WidgetRef ref, {
  required String chatId,
  required String kind,
  required String label,
  required String caption,
  List<TextEntity>? captionEntities,
  ReplyTarget? reply,
  required Future<String> Function(String wireMessageId, String? replyJson, int expireSecs) upload,
}) {
  // ADR-070 — what Rust sent with the caption, stored beside it.
  final entitiesJson = FormattedText(caption, captionEntities ?? const []).entitiesJson;
  final actions = ref.read(messageActionsProvider);
  final store = ref.read(messageStoreProvider);
  final replyJson = reply?.toJson();
  return ref
      .read(pendingMediaProvider.notifier)
      .run(
        chatId: chatId,
        kind: kind,
        label: label,
        job: (reportWireId) async {
          final now = serverNow(); // the server's clock, as for text
          final id = 'msg-${now.microsecondsSinceEpoch.toRadixString(36)}';
          final wireId = newWireId();
          reportWireId(wireId);
          final expire = actions.chatTimer(chatId);
          final mediaJson = await upload(wireId, replyJson, expire);
          await store.insert(
            core.NewMessageRow(
              id: id,
              chatId: chatId,
              tsUnix: now.millisecondsSinceEpoch ~/ 1000,
              body: caption,
              kind: kind,
              isMine: true,
              mediaJson: mediaJson,
              wireId: wireId,
              replyJson: replyJson,
              expireAt: expire > 0 ? now.millisecondsSinceEpoch ~/ 1000 + expire : null,
              entitiesJson: entitiesJson,
            ),
          );
          await actions.trackStoredOutgoing(chatId, wireId, mediaJson: mediaJson, replyJson: replyJson, expire: expire);
        },
      );
}

/// Forward a message to another chat (ADR-019). Text is re-sent; media
/// is decrypted and re-uploaded under a fresh key, so the server can't
/// link the two chats through a shared blob.
Future<void> forwardMessage(
  WidgetRef ref, {
  required String toChatId,
  required String kind,
  required String text,
  String? mediaJson,
  List<TextEntity>? entities,
}) async {
  if (mediaJson == null || kind == 'text') {
    await sendMessage(ref, chatId: toChatId, body: text, entities: entities);
    return;
  }
  if (kind == 'sticker') {
    final store = ref.read(stickerStoreProvider);
    final meta = await store.meta(mediaJson);
    await sendSticker(
      ref,
      chatId: toChatId,
      format: meta.format,
      data: await store.fetchSticker(mediaJson),
      emoji: meta.emoji,
      // Only a built-in pack (everyone has it) or one this person added.
      packId: meta.packId,
      packTitle: meta.packTitle,
      packCount: meta.packCount,
    );
    return;
  }
  final loader = ref.read(mediaLoaderProvider);
  final info = await loader.info(mediaJson);
  final bytes = await loader.fetch(mediaJson, thumbnail: false);
  switch (kind) {
    case 'photo':
      await sendPhoto(ref, chatId: toChatId, bytes: bytes, caption: text, captionEntities: entities);
    case 'document':
      await sendDocument(
        ref,
        chatId: toChatId,
        bytes: bytes,
        fileName: info.fileName,
        mimeType: info.mimeType,
        caption: text,
        captionEntities: entities,
      );
    case 'voice':
      await sendVoice(ref, chatId: toChatId, bytes: bytes, durationMs: info.durationMs, waveform: info.waveform);
    case 'video':
      await sendVideo(
        ref,
        chatId: toChatId,
        bytes: bytes,
        mimeType: info.mimeType,
        durationMs: info.durationMs,
        width: info.width,
        height: info.height,
        caption: text,
        captionEntities: entities,
        round: info.round, // a round video stays round (ADR-048)
      );
    default:
      throw UnsupportedError('cannot forward $kind');
  }
}

/// Send a photo (ADR-017). Rust re-encodes it (EXIF/GPS stripped,
/// ≤2048 px), builds a ≤32 KB thumbnail + BlurHash, encrypts both,
/// uploads the ciphertext and sends the MLS envelope.
Future<void> sendPhoto(
  WidgetRef ref, {
  required String chatId,
  required Uint8List bytes,
  String caption = '',
  List<TextEntity>? captionEntities,
  ReplyTarget? reply,
  String albumId = '',
}) {
  final base = _mediaPreflight(ref, chatId, bytes.length);
  return _sendMedia(
    ref,
    chatId: chatId,
    kind: 'photo',
    label: 'Photo',
    caption: caption,
    captionEntities: captionEntities,
    reply: reply,
    upload: (wireId, replyJson, expireSecs) => core.netSendPhoto(
      serverBaseUrl: base,
      groupIdHex: chatId,
      messageId: wireId,
      data: bytes,
      caption: caption,
      replyJson: replyJson,
      albumId: albumId,
      expireSecs: expireSecs,
      captionEntitiesJson: _captionJson(caption, captionEntities),
    ),
  );
}

/// Send any file as a document. Name and MIME type travel only inside
/// the encrypted envelope.
Future<void> sendDocument(
  WidgetRef ref, {
  required String chatId,
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
  String caption = '',
  List<TextEntity>? captionEntities,
  ReplyTarget? reply,
}) {
  final base = _mediaPreflight(ref, chatId, bytes.length);
  return _sendMedia(
    ref,
    chatId: chatId,
    kind: 'document',
    label: fileName,
    caption: caption,
    captionEntities: captionEntities,
    reply: reply,
    upload: (wireId, replyJson, expireSecs) => core.netSendMedia(
      serverBaseUrl: base,
      groupIdHex: chatId,
      messageId: wireId,
      kind: 'document',
      data: bytes,
      thumbnail: null,
      mimeType: mimeType,
      fileName: fileName,
      blurhash: '',
      width: 0,
      height: 0,
      durationMs: 0,
      waveform: Uint8List(0),
      caption: caption,
      replyJson: replyJson,
      albumId: '',
      expireSecs: expireSecs,
      captionEntitiesJson: _captionJson(caption, captionEntities),
    ),
  );
}

/// Pending-send label of a round video (the pending bubble says
/// "video message" for it).
const kVideoNoteLabel = 'Video message';

/// Send a video (backlog §3 item 31); duration and size travel in the
/// envelope. [round]: a round video message (ADR-048) — square, ≤60 s, no
/// caption; older apps show it as a normal video.
Future<void> sendVideo(
  WidgetRef ref, {
  required String chatId,
  required Uint8List bytes,
  required String mimeType,
  required int durationMs,
  required int width,
  required int height,
  Uint8List? poster,
  String caption = '',
  List<TextEntity>? captionEntities,
  ReplyTarget? reply,
  bool round = false,
}) {
  final base = _mediaPreflight(ref, chatId, bytes.length);
  if (round) caption = '';
  return _sendMedia(
    ref,
    chatId: chatId,
    kind: 'video',
    label: round ? kVideoNoteLabel : 'Video',
    caption: caption,
    captionEntities: captionEntities,
    reply: reply,
    // Tech-debt 2.24 — the poster frame becomes the encrypted thumbnail +
    // BlurHash in Rust (`net_send_video`).
    upload: (wireId, replyJson, expireSecs) => core.netSendVideo(
      serverBaseUrl: base,
      groupIdHex: chatId,
      messageId: wireId,
      data: bytes,
      mimeType: mimeType,
      durationMs: durationMs,
      width: width,
      height: height,
      posterJpeg: poster,
      caption: caption,
      replyJson: replyJson,
      round: round,
      expireSecs: expireSecs,
      captionEntitiesJson: _captionJson(caption, captionEntities),
    ),
  );
}

/// Send a sticker (ADR-049): a photo message with sticker info, so older
/// apps show its still picture. Animated ones carry a 512 px still frame
/// besides the animation; every send is a fresh encrypted upload. A pack
/// the person added goes along (once, encrypted) so the other side can add
/// it; a built-in one travels by id.
Future<void> sendSticker(
  WidgetRef ref, {
  required String chatId,
  required String format,
  required Uint8List data,
  required String emoji,
  String packId = '',
  String packTitle = '',
  int packCount = 0,
  ReplyTarget? reply,
  Uint8List? preview,
}) {
  final base = _mediaPreflight(ref, chatId, data.length);
  final store = ref.read(stickerStoreProvider);
  final pic = stickerSendPicture(format, preview);
  return _sendMedia(
    ref,
    chatId: chatId,
    kind: 'sticker',
    label: emoji.isEmpty ? 'Sticker' : 'Sticker $emoji',
    caption: '',
    reply: reply,
    upload: (wireId, replyJson, expireSecs) async {
      final still = !stickerFormatAnimated(format)
          ? Uint8List(0)
          : pic ?? await stickerStillPng(data, format, emoji: emoji, px: 512);
      final thumb = await fitStickerThumb(
        (px) => pic != null ? imageStillPng(pic, px: px) : stickerStillPng(data, format, emoji: emoji, px: px),
      );
      final json = await store.send(
        serverBaseUrl: base,
        groupIdHex: chatId,
        messageId: wireId,
        format: format,
        data: data,
        stillPng: still,
        thumbnailPng: thumb,
        emoji: emoji,
        packId: packId,
        packTitle: packTitle,
        packCount: packCount,
        replyJson: replyJson,
        expireSecs: expireSecs,
      );
      _shareStickerPackSoon(store, packId);
      return json;
    },
  );
}

/// My own pack goes up (encrypted, once in a while) after a sticker from
/// it is sent — not before, so the sticker isn't held up by the whole pack
/// (owner, 2026-10-20). Later stickers carry it; one share at a time.
void _shareStickerPackSoon(StickerStore store, String packId) {
  if (packId.isEmpty || packId.startsWith('sinhron.') || !_sharingPacks.add(packId)) return;
  unawaited(
    store.share(packId).then((_) {}, onError: (Object _) {}).whenComplete(() => _sharingPacks.remove(packId)),
  );
}

final _sharingPacks = <String>{};

/// Send a recorded voice message (AAC in M4A) with its waveform.
Future<void> sendVoice(
  WidgetRef ref, {
  required String chatId,
  required Uint8List bytes,
  required int durationMs,
  required Uint8List waveform,
  ReplyTarget? reply,
}) {
  final base = _mediaPreflight(ref, chatId, bytes.length);
  return _sendMedia(
    ref,
    chatId: chatId,
    kind: 'voice',
    label: 'Voice message',
    caption: '',
    reply: reply,
    upload: (wireId, replyJson, expireSecs) => core.netSendMedia(
      serverBaseUrl: base,
      groupIdHex: chatId,
      messageId: wireId,
      kind: 'voice',
      data: bytes,
      thumbnail: null,
      mimeType: 'audio/mp4',
      fileName: '',
      blurhash: '',
      width: 0,
      height: 0,
      durationMs: durationMs,
      waveform: waveform,
      caption: '',
      replyJson: replyJson,
      albumId: '',
      expireSecs: expireSecs,
    ),
  );
}
