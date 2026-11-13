// ADR-066 — "Reply" on a message notification (like Telegram / WhatsApp):
// the person types into the notification and the answer goes to that chat
// without the app coming on screen.
//
// The native side (Android `NotificationReply.kt`, iPhone `PushBridge` in
// AppDelegate.swift) keeps the text — encrypted (Keystore / Keychain) — until
// Dart takes it: as a `reply` event while Dart runs, or from `takeReplies`
// when this engine starts (Android may start one with no screen for it; an
// iPhone that had closed the app sends it when Sinhron next opens). Here the
// reply is sent like a message typed in the chat — the same MLS encryption,
// the same "sending → sent" row, the same queue when the connection is down
// — and the native side hears how it went (`replyDone`): sent → the
// notification goes; queued → "it will go when Sinhron connects"; failed →
// "not sent — open the chat". Nothing new reaches Apple, Google or the
// server: the server gets the ordinary sealed message.
//
// No "Reply" when notifications show nothing (Settings → Notifications), when
// App Lock is on (the answer would skip Face ID / the code), in a message
// request or a chat with someone blocked.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/app_lock/app_lock.dart' show appLockEnabledProvider;
import '../features/banners/in_app_banner.dart' show NotificationPreview, notificationPreviewProvider;
import '../features/chat_list/chat_data.dart';
import 'background_connection.dart';
import 'providers/chat_actions.dart';
import 'providers/chat_providers.dart';
import 'providers/message_actions.dart';
import 'providers/people.dart' show isBlockedChat;
import 'push.dart';
import 'services/net_service.dart';

/// Longer replies are cut (a notification field is for a line or two).
const maxReplyChars = 4096;

/// One reply typed into a notification.
class NotificationReply {
  const NotificationReply({required this.id, required this.chatId, required this.text});

  /// The native side's id for it (to tell it how it went).
  final String id;
  final String chatId;
  final String text;

  /// From the channel's `{id, chatId, text}`; null when something is missing
  /// or the text is empty.
  static NotificationReply? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final chatId = raw['chatId'];
    final text = raw['text'];
    if (id is! String || id.isEmpty || chatId is! String || chatId.isEmpty || chatId.length > 128 || text is! String) {
      return null;
    }
    var t = text.trim();
    if (t.isEmpty) return null;
    if (t.length > maxReplyChars) t = t.substring(0, maxReplyChars);
    return NotificationReply(id: id, chatId: chatId, text: t);
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationReply && other.id == id && other.chatId == chatId && other.text == text;

  @override
  int get hashCode => Object.hash(id, chatId, text);
}

/// How a reply went (the native side words the notification).
enum ReplyOutcome {
  /// Encrypted and handed to the server.
  sent,

  /// Stored in the chat; goes out by itself when the connection is back.
  queued,

  /// Not sent (the chat is gone, blocked, a request; the app can't open its
  /// data) — open the chat.
  failed,
}

/// Does a notification of [chat] get a "Reply" field?
bool canReplyFromNotification({
  required NotificationPreview preview,
  required bool appLock,
  required bool request,
  required bool blocked,
}) => preview != NotificationPreview.nothing && !appLock && !request && !blocked;

class NotificationReplier {
  NotificationReplier(
    this._ref, {
    this.connectWithin = const Duration(seconds: 8),
    this.linger = const Duration(seconds: 2),
  });
  final Ref _ref;

  /// How long to wait for the connection before the message is left queued.
  final Duration connectWithin;

  /// How long to stay connected after sending (the server's ack).
  final Duration linger;

  Future<ReplyOutcome> send(NotificationReply r) async {
    final ChatPreview? chat;
    try {
      chat = (await _ref.read(chatsProvider.future)).where((c) => c.id == r.chatId).firstOrNull;
    } catch (_) {
      return ReplyOutcome.failed;
    }
    if (chat == null || chat.request || isBlockedChat(_ref, r.chatId)) return ReplyOutcome.failed;
    final bg = _ref.read(backgroundConnectionProvider);
    await bg.openForReply();
    try {
      final until = DateTime.now().add(connectWithin);
      while (_ref.read(netStatusProvider) != NetStatus.connected && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      try {
        await _ref.read(messageActionsProvider).sendText(r.chatId, r.text);
      } on StateError {
        return ReplyOutcome.failed; // blocked meanwhile
      } catch (_) {
        // The row is in the chat and queued (`sendText`).
        return ReplyOutcome.queued;
      }
      // Answered = read, as in Telegram.
      try {
        await _ref.read(chatActionsProvider).markRead(r.chatId);
        await _ref.read(messageActionsProvider).sendReadReceipts(r.chatId);
      } catch (_) {}
      await Future<void>.delayed(linger);
      return ReplyOutcome.sent;
    } finally {
      await bg.closeAfterReply();
    }
  }
}

final notificationReplierProvider = Provider<NotificationReplier>((ref) => NotificationReplier(ref));

/// From main() (both platforms): this engine sends replies typed into
/// notifications, one at a time, in the order they came. [canConnect] false
/// (the chats DB is locked, the core didn't load): each one is answered
/// "failed" — the notification says to open the chat.
Future<void> listenForNotificationReplies(ProviderContainer c, {required bool canConnect}) async {
  final platform = c.read(pushPlatformProvider);
  // Loaded up front: an engine with no screen reads them for the first
  // notification it draws ("Reply" or not).
  if (canConnect) {
    try {
      await c.read(appLockEnabledProvider.future);
      await c.read(notificationPreviewProvider.future);
    } catch (_) {}
  }
  var queue = Future<void>.value();
  // The event and `takeReplies` can both bring one reply around a start.
  final seen = <String>{};
  void handle(NotificationReply r) {
    if (!seen.add(r.id)) return;
    queue = queue.then((_) async {
      var outcome = ReplyOutcome.failed;
      if (canConnect) {
        try {
          outcome = await c.read(notificationReplierProvider).send(r);
        } catch (_) {}
      }
      await platform.replyDone(r.id, outcome);
    });
  }

  platform.replies.listen(handle);
  for (final r in await platform.takeReplies()) {
    handle(r);
  }
  await queue;
}
