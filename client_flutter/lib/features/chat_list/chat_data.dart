// Chat-list view-model.
//
// The source is the local SQLite `chats` table, surfaced via
// `chatsProvider` in `lib/core/providers/chat_providers.dart`.
//
// There is no demo seeding (UI backlog §1 item 8): a fresh install shows
// an empty list. New code should `ref.watch(chatsProvider)` and treat the
// result as truth.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/contact_qr.dart' show contactCardOf;
import '../../core/providers/message_actions.dart' show systemLineText;
import '../../core/rich_text.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;

enum ChatPreviewKind { text, voice, photo, call }

@immutable
class ChatPreview {
  /// Stable identifier — the MLS group hex id (`kSavedChatPendingId` for
  /// the Saved messages stand-in).
  final String? id;
  final String name;
  final String preview;
  final String time;
  final ChatPreviewKind kind;
  final String? sender; // for group chats — "Alex: ..." prefix
  final bool group;
  final bool online;
  final bool typing;
  final bool muted;
  final bool pinned;
  final int unread;
  final bool sent;

  /// My newest message reached their device(s) (✓✓ grey); [read] = ✓✓ accent.
  final bool delivered;
  final bool read;

  /// Status 211 — my newest message didn't go (red "!" in the list).
  final bool failed;
  final bool mention;

  /// UI backlog §2 — chat-list organisation (storage v6).
  final bool archived;
  final int pinOrder;

  /// Unsent composer text; the row shows "Draft: …" instead of the preview.
  final String? draft;

  /// ADR-070 — the draft's formatting (the composer restores it).
  final List<TextEntity> draftEntities;

  /// Marked unread by hand (shows a dot even with 0 unread messages).
  final bool markedUnread;

  /// Wire id of the message pinned at the top of the chat (ADR-019).
  final String? pinnedMsg;

  /// Disappearing-message timer in seconds (0 = off) — §6 item 51.
  final int disappearSecs;

  /// Tech-debt 2.27 — someone else started this chat and I haven't
  /// accepted it: no read receipts, typing or my name go out, calls don't ring.
  final bool request;

  /// Unread for badges / the Unread folder: real count or a manual mark.
  bool get hasUnread => unread > 0 || markedUnread;

  const ChatPreview({
    this.id,
    required this.name,
    required this.preview,
    required this.time,
    this.kind = ChatPreviewKind.text,
    this.sender,
    this.group = false,
    this.online = false,
    this.typing = false,
    this.muted = false,
    this.pinned = false,
    this.unread = 0,
    this.sent = false,
    this.delivered = false,
    this.read = false,
    this.failed = false,
    this.mention = false,
    this.archived = false,
    this.pinOrder = 0,
    this.draft,
    this.draftEntities = const [],
    this.markedUnread = false,
    this.pinnedMsg,
    this.disappearSecs = 0,
    this.request = false,
    this.peerId,
    this.avatar,
    this.verified = false,
    this.saved = false,
  });

  /// ADR-055 — my "Saved messages" (a chat with myself, on all my devices):
  /// first in the list, bookmark avatar, no receipts / typing / calls.
  final bool saved;

  /// I confirmed their safety number and their key hasn't changed since —
  /// the verified seal next to the name (owner, 2026-10-18).
  final bool verified;

  /// Personal chats: the other person's identity key, once known (v14).
  final String? peerId;

  /// Their photo (re-encoded JPEG), when they shared one.
  final Uint8List? avatar;

  ChatPreview copyWith({
    String? name,
    bool? saved,
    String? preview,
    ChatPreviewKind? kind,
    String? sender,
    bool clearSender = false,
    bool? typing,
    String? draft,
    bool clearDraft = false,
    Uint8List? avatar,
    bool? online,
    bool? verified,
  }) => ChatPreview(
    id: id,
    name: name ?? this.name,
    preview: preview ?? this.preview,
    time: time,
    kind: kind ?? this.kind,
    sender: clearSender ? null : (sender ?? this.sender),
    group: group,
    online: online ?? this.online,
    typing: typing ?? this.typing,
    muted: muted,
    pinned: pinned,
    unread: unread,
    sent: sent,
    delivered: delivered,
    read: read,
    failed: failed,
    mention: mention,
    archived: archived,
    pinOrder: pinOrder,
    draft: clearDraft ? null : (draft ?? this.draft),
    draftEntities: clearDraft || draft != null ? const [] : draftEntities,
    markedUnread: markedUnread,
    pinnedMsg: pinnedMsg,
    disappearSecs: disappearSecs,
    request: request,
    peerId: peerId,
    avatar: avatar ?? this.avatar,
    verified: verified ?? this.verified,
    saved: saved ?? this.saved,
  );

  /// The same row with another preview line (mentions shown as names).
  ChatPreview withPreview(String text) => text == preview ? this : copyWith(preview: text);

  /// The same row while someone in the chat is typing ([label] = "typing…")
  /// — over the preview and over a draft, like in Telegram.
  ChatPreview asTyping(String label) =>
      copyWith(preview: label, kind: ChatPreviewKind.text, clearSender: true, typing: true, clearDraft: true);
}

/// Chat-list timestamp: "now" / "14:22" / "Yesterday" / "Mon" / "Apr 12"
/// — in the app's language (backlog §7 item 53).
String formatChatTime(int tsUnix, {DateTime? now}) {
  final l = lookupAppL10n(Locale(currentLanguage));
  final ref = now ?? DateTime.now();
  final ts = DateTime.fromMillisecondsSinceEpoch(tsUnix * 1000);
  final diff = ref.difference(ts);
  if (diff.inSeconds < 60 && diff.inSeconds >= -5) return l.timeNow;
  if (ts.year == ref.year && ts.month == ref.month && ts.day == ref.day) {
    return '${_twoDigit(ts.hour)}:${_twoDigit(ts.minute)}';
  }
  final yesterday = DateTime(ref.year, ref.month, ref.day - 1);
  if (ts.year == yesterday.year && ts.month == yesterday.month && ts.day == yesterday.day) {
    return l.yesterday;
  }
  if (diff.inDays < 7) return _names[currentLanguage]!.weekdaysShort[ts.weekday - 1];
  return _names[currentLanguage]!.dayMonthShort(ts.day, ts.month);
}

/// Message bubble time — always 24h "14:22".
String formatMessageTime(int tsUnix) {
  final ts = DateTime.fromMillisecondsSinceEpoch(tsUnix * 1000);
  return '${_twoDigit(ts.hour)}:${_twoDigit(ts.minute)}';
}

/// Day separator in a chat: "Today" / "Yesterday" / "Monday" /
/// "April 12" / "April 12, 2026" (Russian: "12 апреля 2026 г.").
String formatDaySeparator(int tsUnix, {DateTime? now}) {
  final l = lookupAppL10n(Locale(currentLanguage));
  final n = _names[currentLanguage]!;
  final ref = now ?? DateTime.now();
  final ts = DateTime.fromMillisecondsSinceEpoch(tsUnix * 1000);
  final diffDays = DateTime(ref.year, ref.month, ref.day).difference(DateTime(ts.year, ts.month, ts.day)).inDays;
  if (diffDays == 0) return l.today;
  if (diffDays == 1) return l.yesterday;
  if (diffDays < 7) return n.weekdays[ts.weekday - 1];
  return n.dayMonth(ts.day, ts.month, ts.year == ref.year ? null : ts.year);
}

/// A date with its year, in the app's language: "April 12, 2026" /
/// "12 апреля 2026 г." (profile "joined" — it was English month names).
String formatFullDate(int tsUnix) {
  final ts = DateTime.fromMillisecondsSinceEpoch(tsUnix * 1000);
  return _names[currentLanguage]!.dayMonth(ts.day, ts.month, ts.year);
}

/// A month heading: "November 2026" / "Ноябрь 2026" (shared media).
String formatMonthYear(int tsUnix) {
  final ts = DateTime.fromMillisecondsSinceEpoch(tsUnix * 1000);
  return currentLanguage == 'ru' ? '${_ruMonthsNominative[ts.month - 1]} ${ts.year}' : '${_enMonths[ts.month - 1]} ${ts.year}';
}

const _ruMonthsNominative = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];

class _DateNames {
  const _DateNames(this.weekdays, this.weekdaysShort, this.dayMonth, this.dayMonthShort);
  final List<String> weekdays;
  final List<String> weekdaysShort;
  final String Function(int day, int month, int? year) dayMonth;
  final String Function(int day, int month) dayMonthShort;
}

const _enMonths = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
// Russian dates use the genitive: "12 апреля".
const _ruMonths = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

final _names = <String, _DateNames>{
  'en': _DateNames(
    const ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'],
    const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
    (d, m, y) => y == null ? '${_enMonths[m - 1]} $d' : '${_enMonths[m - 1]} $d, $y',
    (d, m) => '${_enMonths[m - 1].substring(0, 3)} $d',
  ),
  'ru': _DateNames(
    const ['понедельник', 'вторник', 'среда', 'четверг', 'пятница', 'суббота', 'воскресенье'],
    const ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'],
    (d, m, y) => y == null ? '$d ${_ruMonths[m - 1]}' : '$d ${_ruMonths[m - 1]} $y г.',
    (d, m) => '$d ${_ruMonths[m - 1].substring(0, 3)}.',
  ),
};

String _twoDigit(int n) => n < 10 ? '0$n' : '$n';

/// Convert a Rust-side `StoredChatSummary` to a `ChatPreview` for the UI.
/// Fields that can't come from the local DB yet (`online` / `typing` /
/// `read` / `mention`) are conservatively `false`. They'll get re-wired
/// to a presence provider once that surface exists.
ChatPreview chatPreviewFromStored(core.StoredChatSummary s, {DateTime? now}) {
  final draft = s.draft == null ? null : decodeDraft(s.draft);
  return ChatPreview(
    id: s.id,
    name: s.displayName,
    preview: mediaPreviewFallback(s.lastMsgPreview ?? '', s.lastMsgKind),
    time: s.lastMsgTsUnix == 0 ? '' : formatChatTime(s.lastMsgTsUnix.toInt(), now: now),
    kind: _kindFromString(s.lastMsgKind),
    sender: s.lastMsgSenderLabel,
    group: s.isGroup,
    muted: s.muted,
    pinned: s.pinned,
    unread: s.unreadCount.toInt(),
    // Ticks follow my newest message: ✓ sent, ✓✓ delivered, accent ✓✓ read
    // (none while it's still sending).
    sent: s.lastMsgMine && s.lastMsgStatus >= 1,
    delivered: s.lastMsgMine && s.lastMsgStatus >= 2,
    read: s.lastMsgMine && s.lastMsgStatus >= 3,
    failed: s.lastMsgMine && s.lastMsgStatus < 0,
    archived: s.archived,
    pinOrder: s.pinOrder.toInt(),
    // ADR-070 — a formatted draft shows as its words here.
    draft: draft?.text,
    draftEntities: draft?.entities ?? const [],
    markedUnread: s.markedUnread,
    pinnedMsg: s.pinnedMsg,
    disappearSecs: s.disappearSecs.toInt(),
    request: s.request,
    mention: s.mentioned,
    peerId: s.peerId,
  );
}

/// "Контакт: Имя" for a shared contact, null for any other text — the chat
/// list, quotes and notifications show it instead of its key and server.
String? contactCardLabel(AppL10n l, String text) {
  final c = contactCardOf(text);
  if (c == null) return null;
  return c.name == null ? l.contactCardNoName : l.contactCardPreview(c.name!);
}

/// Media messages without a caption would leave the chat-list preview
/// blank — show what arrived instead.
String mediaPreviewFallback(String preview, String kind) {
  final l = lookupAppL10n(Locale(currentLanguage));
  // A shared contact reads as one, not as its key and server.
  if (kind == 'text') {
    if (contactCardLabel(l, preview) case final label?) return label;
  }
  if (preview.isNotEmpty) return preview;
  return switch (kind) {
    'photo' => l.kindPhoto,
    'sticker' => l.kindSticker,
    'voice' => l.kindVoice,
    'document' => l.document,
    'video' => l.video,
    'deleted' => l.messageDeleted,
    'system' => systemLineText(l, preview),
    _ => preview,
  };
}

ChatPreviewKind _kindFromString(String s) {
  switch (s) {
    case 'voice':
      return ChatPreviewKind.voice;
    case 'photo':
      return ChatPreviewKind.photo;
    case 'call':
      return ChatPreviewKind.call;
    default:
      return ChatPreviewKind.text;
  }
}

String chatPreviewKindToString(ChatPreviewKind k) {
  switch (k) {
    case ChatPreviewKind.voice:
      return 'voice';
    case ChatPreviewKind.photo:
      return 'photo';
    case ChatPreviewKind.call:
      return 'call';
    case ChatPreviewKind.text:
      return 'text';
  }
}

