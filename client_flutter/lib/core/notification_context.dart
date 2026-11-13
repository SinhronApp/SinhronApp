// ADR-056 — what the iPhone's Notification Service Extension needs to turn
// a sealed preview into "<name>: <text>" while the app is closed: the
// "Notifications show" setting, the words in the app's language, chat names
// (group? muted? a personal chat with someone blocked?), people's names
// (group senders, @-mentions) and who is blocked here. The app writes it to
// the shared Keychain (`PushPlatform.setNotificationContext`) whenever any
// of it changes; the extension and CallKit (incoming call names) read it.
//
// No message text goes in here — only names the app already shows.
//
// ADR-066 — and whether a message notification gets "Reply" (`reply`: not
// with "show nothing" or App Lock; never in a message request — `q`), with
// the words for it.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/app_lock/app_lock.dart' show appLockEnabledProvider;
import '../features/banners/in_app_banner.dart';
import '../features/chat_list/chat_data.dart';
import '../l10n/l10n.dart';
import 'notification_reply.dart' show canReplyFromNotification;
import 'providers/chat_providers.dart';
import 'providers/people.dart';
import 'providers/settings_providers.dart';

/// Names are cut to this many characters.
const _maxName = 64;

/// Chats kept (most recent first — the list's order).
const maxNotificationChats = 500;

String _clip(String s) {
  final t = s.trim();
  return t.characters.length <= _maxName ? t : t.characters.take(_maxName).toString();
}

/// The JSON the extension reads (`PushContext` in ios/Shared/PushShared.swift).
String buildNotificationContext({
  required NotificationPreview mode,
  required AppL10n l,
  required List<ChatPreview> chats,
  required Map<String, String> names,
  required Set<String> blockedPeers,
  required Set<String> blockedChats,
  bool appLock = false,
}) {
  final chatMap = <String, Object>{};
  for (final c in chats.take(maxNotificationChats)) {
    final id = c.id;
    if (id == null || id.isEmpty) continue;
    chatMap[id] = {
      'n': _clip(c.name),
      if (c.group) 'g': true,
      if (c.muted) 'm': true,
      if (blockedChats.contains(id)) 'b': true,
      if (c.request) 'q': true,
      // ADR-090 — whose personal chat it is: a call push names the chat only
      // when this person signed the invite.
      if (!c.group && (c.peerId ?? '').isNotEmpty) 'p': c.peerId!.toLowerCase(),
    };
  }
  return jsonEncode({
    'mode': mode.name,
    'words': {
      'newMessage': l.bannerNewMessage,
      'text': l.bannerNewMessage,
      'photo': l.kindPhoto,
      'voice': l.kindVoice,
      'video': l.video,
      'document': l.document,
      'reply': l.notificationReply,
      'replySend': l.notificationReplySend,
      'replyPlaceholder': l.notificationReplyPlaceholder,
      'replyLater': l.notificationReplyLater,
      'replyOnOpen': l.notificationReplyOnOpen,
      'replyFailed': l.notificationReplyFailed,
      // ADR-071 (amended) — a stranger's message: no name, no text.
      'request': l.notificationNewRequest,
    },
    'reply': canReplyFromNotification(preview: mode, appLock: appLock, request: false, blocked: false),
    'chats': chatMap,
    'people': {for (final e in names.entries) e.key: _clip(e.value)},
    'blocked': (blockedPeers.toList()..sort()),
  });
}

/// The current context, or null until the chat list has loaded (the
/// extension keeps the previous one meanwhile).
final notificationContextProvider = Provider<String?>((ref) {
  final chats = ref.watch(chatsProvider).value;
  if (chats == null) return null;
  ref.watch(languageProvider);
  return buildNotificationContext(
    mode: ref.watch(notificationPreviewProvider).value ?? NotificationPreview.nameAndText,
    l: lookupAppL10n(Locale(currentLanguage)),
    chats: chats,
    names: ref.watch(peerNamesProvider).value ?? const {},
    blockedPeers: ref.watch(blockedPeersProvider).value ?? const {},
    blockedChats: blockedChatIds(ref.watch(blockedChatsProvider).value ?? ''),
    appLock: ref.watch(appLockEnabledProvider).value ?? true,
  );
});
