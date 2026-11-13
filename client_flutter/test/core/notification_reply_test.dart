// ADR-066 — a notification's tap opens its chat; "Reply" from the
// notification sends the answer like a message typed in the chat.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/background_connection.dart';
import 'package:sinhron/core/notification_context.dart';
import 'package:sinhron/core/notification_reply.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/core/rich_text.dart' show TextEntity;
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/app_lock/app_lock.dart' show appLockEnabledProvider;
import 'package:sinhron/features/banners/in_app_banner.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

import 'push_test.dart' show FakePushPlatform;
import 'settings_providers_test.dart' show MemoryStore;

ChatPreview _chat(String id, {bool request = false, bool muted = false}) => ChatPreview(
  id: id,
  name: 'Maria',
  preview: '',
  time: '',
  kind: ChatPreviewKind.text,
  request: request,
  muted: muted,
);

class _Call extends ActiveCallNotifier {
  @override
  ActiveCallState build() => const ActiveCallState.idle();
}

class _Actions extends MessageActions {
  _Actions(super.ref, this.log);
  final List<String> log;
  Object? fail;

  @override
  Future<void> sendText(String chatId, String text, {List<TextEntity>? entities, ReplyTarget? reply}) async {
    log.add('send $chatId $text');
    if (fail != null) throw fail!;
  }

  @override
  Future<void> sendReadReceipts(String chatId) async => log.add('receipts $chatId');
}

class _ChatActions extends ChatActions {
  _ChatActions(super.ref, this.log);
  final List<String> log;

  @override
  Future<void> markRead(String id) async => log.add('read $id');
}

final _raise = Provider<void Function(String)>(
  (ref) => (id) => maybeShowBanner(ref, chatId: id, title: 'Maria', body: 'hi', kind: 'text'),
);
final _raiseGroup = Provider<void Function(String)>(
  (ref) => (id) => maybeShowBanner(ref, chatId: id, title: 'Семья', body: 'привет', kind: 'text', group: true, sender: 'Анна'),
);
final _missed = Provider<void Function(String)>((ref) => (id) => maybeNotifyMissedCall(ref, id, video: false));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationReply.fromMap', () {
    test('id, chat and trimmed text', () {
      expect(
        NotificationReply.fromMap({'id': 'r1', 'chatId': 'ab', 'text': '  да, иду \n'}),
        const NotificationReply(id: 'r1', chatId: 'ab', text: 'да, иду'),
      );
    });

    test('something missing or empty → nothing', () {
      for (final bad in <Object?>[
        null,
        'text',
        {'chatId': 'ab', 'text': 'hi'},
        {'id': '', 'chatId': 'ab', 'text': 'hi'},
        {'id': 'r1', 'chatId': '', 'text': 'hi'},
        {'id': 'r1', 'chatId': 'ab', 'text': '   '},
        {'id': 'r1', 'chatId': 'ab', 'text': 3},
        {'id': 'r1', 'chatId': 'a' * 129, 'text': 'hi'},
      ]) {
        expect(NotificationReply.fromMap(bad), isNull, reason: '$bad');
      }
    });

    test('a very long reply is cut', () {
      expect(NotificationReply.fromMap({'id': 'r', 'chatId': 'ab', 'text': 'x' * 5000})!.text.length, maxReplyChars);
    });
  });

  test('who wrote goes in front: with text and with name only, not with nothing or no name', () {
    expect(withSender('привет', 'Анна', NotificationPreview.nameAndText), 'Анна: привет');
    expect(withSender('Новое сообщение', 'Анна', NotificationPreview.nameOnly), 'Анна: Новое сообщение');
    expect(withSender('Новое сообщение', 'Анна', NotificationPreview.nothing), 'Новое сообщение');
    expect(withSender('привет', null, NotificationPreview.nameAndText), 'привет');
    expect(withSender('привет', '  ', NotificationPreview.nameAndText), 'привет');
  });

  test('"Reply" only with a name shown, without App Lock, not in a request or with someone blocked', () {
    bool can({
      NotificationPreview p = NotificationPreview.nameAndText,
      bool lock = false,
      bool request = false,
      bool blocked = false,
    }) => canReplyFromNotification(preview: p, appLock: lock, request: request, blocked: blocked);
    expect(can(), isTrue);
    expect(can(p: NotificationPreview.nameOnly), isTrue);
    expect(can(p: NotificationPreview.nothing), isFalse);
    expect(can(lock: true), isFalse);
    expect(can(request: true), isFalse);
    expect(can(blocked: true), isFalse);
  });

  group('sending a reply', () {
    late ProviderContainer c;
    late List<String> log;
    late _Actions actions;
    late List<ChatPreview> chats;
    late FakePushPlatform platform;

    setUp(() {
      log = [];
      chats = [_chat('ab'), _chat('rq', request: true)];
      platform = FakePushPlatform();
      c = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          pushPlatformProvider.overrideWithValue(platform),
          chatsProvider.overrideWith((ref) async => chats),
          messageActionsProvider.overrideWith((ref) => actions = _Actions(ref, log)),
          chatActionsProvider.overrideWith((ref) => _ChatActions(ref, log)),
          activeCallProvider.overrideWith(_Call.new),
          stayConnectedInBackgroundProvider.overrideWithValue(() => false),
          pushResumeProvider.overrideWithValue(() async => log.add('connect')),
          connectionSwitchProvider.overrideWithValue(
            ConnectionSwitch(close: () async => log.add('close'), open: () async => log.add('open')),
          ),
          notificationReplierProvider.overrideWith(
            (ref) => NotificationReplier(ref, connectWithin: Duration.zero, linger: Duration.zero),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.read(messageActionsProvider);
    });

    Future<ReplyOutcome> send(String chatId, [String text = 'иду']) =>
        c.read(notificationReplierProvider).send(NotificationReply(id: 'r', chatId: chatId, text: text));

    test('connects with no screen, sends to that chat, marks it read, closes again', () async {
      c.read(netStatusProvider.notifier).set(NetStatus.connected);
      expect(await send('ab'), ReplyOutcome.sent);
      expect(log, ['connect', 'send ab иду', 'read ab', 'receipts ab', 'close']);
    });

    test('no connection: the message waits in the chat (queued) — still closes', () async {
      actions.fail = Exception('offline');
      expect(await send('ab'), ReplyOutcome.queued);
      expect(log, ['connect', 'send ab иду', 'close']);
    });

    test('an unknown chat or a message request: not sent, no connection', () async {
      expect(await send('zz'), ReplyOutcome.failed);
      expect(await send('rq'), ReplyOutcome.failed);
      expect(log, isEmpty);
    });

    test('blocked meanwhile (sendText refuses): failed', () async {
      actions.fail = StateError('blocked');
      expect(await send('ab'), ReplyOutcome.failed);
    });

    test('a push that finishes meanwhile leaves the connection to the reply', () async {
      final bg = c.read(backgroundConnectionProvider);
      await bg.openForReply();
      await bg.closeAfterPush();
      expect(log, ['connect'], reason: 'the reply still needs it');
      expect(bg.openForAPush, isTrue, reason: 'messages now get notifications drawn by the app');
      await bg.closeAfterReply();
      expect(log, ['connect', 'close']);
      expect(bg.openForAPush, isFalse);
    });

    test('replies from before Dart started and new ones go one by one, each once; the native side hears how', () async {
      c.read(netStatusProvider.notifier).set(NetStatus.connected);
      platform.pendingReplies.add(const NotificationReply(id: 'r1', chatId: 'ab', text: 'one'));
      final done = listenForNotificationReplies(c, canConnect: true);
      await Future<void>.delayed(Duration.zero);
      platform.repliesCtl.add(const NotificationReply(id: 'r2', chatId: 'ab', text: 'two'));
      platform.repliesCtl.add(const NotificationReply(id: 'r1', chatId: 'ab', text: 'one'));
      platform.repliesCtl.add(const NotificationReply(id: 'r3', chatId: 'zz', text: 'three'));
      await done;
      for (var i = 0; i < 20 && platform.replyOutcomes.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(log.where((l) => l.startsWith('send')), ['send ab one', 'send ab two']);
      expect(platform.replyOutcomes, ['r1 sent', 'r2 sent', 'r3 failed']);
    });

    test('the chats DB can\'t open: every reply is answered "failed"', () async {
      platform.pendingReplies.add(const NotificationReply(id: 'r1', chatId: 'ab', text: 'one'));
      await listenForNotificationReplies(c, canConnect: false);
      expect(platform.replyOutcomes, ['r1 failed']);
      expect(log, isEmpty);
    });

    test('a message the app draws itself gets "Reply" — not with App Lock or in a request', () async {
      final store = MemoryStore();
      final c2 = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          pushPlatformProvider.overrideWithValue(platform),
          chatsProvider.overrideWith((ref) async => chats),
          stayConnectedInBackgroundProvider.overrideWithValue(() => true),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(chatsProvider.future);
      await c2.read(appLockEnabledProvider.future);
      c2.read(_raise)('ab');
      c2.read(_raise)('rq');
      // ADR-071 (amended) — a request: one quiet "New message request".
      expect(platform.calls, ['show ab Maria hi', 'show rq Sinhron New message request']);
      expect(platform.replyFlags, [true, false]);
      expect(platform.quietFlags, [false, true]);
      store.map['app_lock'] = '1';
      c2.invalidate(appLockEnabledProvider);
      await c2.read(appLockEnabledProvider.future);
      c2.read(_raise)('ab');
      expect(platform.replyFlags.last, isFalse, reason: 'App Lock: the answer would skip Face ID');
    });

    test('a group\'s notification says who wrote; "show nothing" doesn\'t', () async {
      final store = MemoryStore();
      final c2 = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          pushPlatformProvider.overrideWithValue(platform),
          chatsProvider.overrideWith((ref) async => chats),
          stayConnectedInBackgroundProvider.overrideWithValue(() => true),
        ],
      );
      addTearDown(c2.dispose);
      await c2.read(notificationPreviewProvider.future);
      c2.read(_raiseGroup)('ab');
      await c2.read(notificationPreviewProvider.notifier).save(NotificationPreview.nothing);
      c2.read(_raiseGroup)('ab');
      expect(platform.calls, ['show ab Семья Анна: привет', 'show ab Sinhron New message']);
    });

    test('a call missed off screen: a notification that opens the chat (muted chats stay quiet)', () async {
      chats = [_chat('ab'), _chat('mu', muted: true)];
      await c.read(chatsProvider.future);
      c.read(_missed)('ab');
      c.read(_missed)('mu');
      expect(platform.calls, ['show ab Maria Missed call']);
      expect(platform.replyFlags, [false]);
    });
  });

  group('a tapped notification', () {
    test('waits for the chat list (a cold start), then finds the chat', () async {
      var calls = 0;
      final found = await waitForChat(
        'ab',
        every: const Duration(milliseconds: 1),
        chats: () async {
          calls++;
          if (calls == 1) throw StateError('db not open yet');
          return calls < 4 ? <ChatPreview>[] : [_chat('ab')];
        },
      );
      expect(found?.id, 'ab');
      expect(calls, 4);
    });

    test('a chat that never comes: nothing after a while', () async {
      final found = await waitForChat(
        'ab',
        within: const Duration(milliseconds: 20),
        every: const Duration(milliseconds: 2),
        chats: () async => [_chat('cd')],
      );
      expect(found, isNull);
    });

    testWidgets('opens it once, also when the tap comes as an event and at start', (t) async {
      final platform = FakePushPlatform()..openedAtStart = 'ab';
      final opened = <String>[];
      final c = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          pushPlatformProvider.overrideWithValue(platform),
          netServiceProvider.overrideWith((ref) => NetService(ref)),
          chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
          notificationExtensionProvider.overrideWithValue(false),
        ],
      );
      addTearDown(c.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: PushSync(onOpenChat: opened.add, child: const SizedBox()),
        ),
      );
      await t.pump();
      platform.openedCtl.add('ab');
      platform.openedCtl.add('cd');
      platform.openedCtl.add('');
      await t.pump();
      expect(opened, ['ab', 'cd']);
    });
  });

  group('the channel', () {
    const channel = MethodChannel('dev.sinhron/push');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    Future<Object?> fromNative(String method, Object? args) async {
      final reply = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        reply.complete,
      );
      final data = await reply.future;
      return data == null ? null : const StandardMethodCodec().decodeEnvelope(data);
    }

    setUp(() {
      messenger.setMockMethodCallHandler(channel, (call) async => switch (call.method) {
        'takeReplies' => [
          {'id': 'r1', 'chatId': 'ab', 'text': 'hi'},
          {'id': 'r2', 'chatId': 'ab', 'text': ' '},
        ],
        _ => null,
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    });

    test('a tap before anyone listens is kept for takeOpened (a cold start)', () async {
      final p = ChannelPushPlatform();
      await fromNative('opened', {'chatId': 'ab'});
      expect(await p.takeOpened(), 'ab');
      expect(await p.takeOpened(), isNull);
    });

    test('a reply is taken only while Dart listens; takeReplies skips empty ones', () async {
      final p = ChannelPushPlatform();
      final reply = {'id': 'r9', 'chatId': 'ab', 'text': 'hi'};
      expect(await fromNative('reply', reply), false);
      final got = <NotificationReply>[];
      final sub = p.replies.listen(got.add);
      addTearDown(sub.cancel);
      expect(await fromNative('reply', reply), true);
      await Future<void>.delayed(Duration.zero);
      expect(got.single.id, 'r9');
      expect((await p.takeReplies()).map((r) => r.id), ['r1']);
    });
  });

  test('the extension hears whether "Reply" is on and which chats are requests', () {
    final en = lookupAppL10n(const Locale('en'));
    Map<String, dynamic> ctx({NotificationPreview mode = NotificationPreview.nameAndText, bool lock = false}) =>
        jsonDecode(
              buildNotificationContext(
                mode: mode,
                l: en,
                chats: [_chat('ab'), _chat('rq', request: true)],
                names: const {},
                blockedPeers: const {},
                blockedChats: const {},
                appLock: lock,
              ),
            )
            as Map<String, dynamic>;
    expect(ctx()['reply'], isTrue);
    expect(ctx(lock: true)['reply'], isFalse);
    expect(ctx(mode: NotificationPreview.nothing)['reply'], isFalse);
    expect(ctx()['chats'], {
      'ab': {'n': 'Maria'},
      'rq': {'n': 'Maria', 'q': true},
    });
    final words = ctx()['words'] as Map;
    expect(words['reply'], 'Reply');
    expect(words['replyOnOpen'], en.notificationReplyOnOpen);
  });
}
