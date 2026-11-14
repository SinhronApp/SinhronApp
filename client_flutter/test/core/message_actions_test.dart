import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/message_time.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/rich_text.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart' show NetStatus, netStatusProvider;
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import 'chat_actions_test.dart' show FakeChatStore;
import 'settings_providers_test.dart' show MemoryStore;

/// Records calls; answers like storage would for the happy path.
class FakeMessageStore implements MessageStore {
  final calls = <String>[];
  final rows = <core.NewMessageRow>[];
  final pinned = <String, String?>{};
  List<String> pending = [];
  bool accept = true;
  int statusRows = 1;

  @override
  Future<void> insert(core.NewMessageRow row) async {
    rows.add(row);
    calls.add('insert ${row.id}');
  }

  @override
  Future<void> setMediaJson(String id, String json) async => calls.add('media $id');
  @override
  Future<bool> setReaction(String chatId, String wireId, String reactor, String? emoji) async {
    calls.add('react $wireId $reactor $emoji');
    return accept;
  }

  /// ADR-070 — the last edit's formatting JSON (null = an older app's).
  String? lastEditEntities;

  @override
  Future<bool> applyEdit(String chatId, String wireId, String? peer, String text, int ts, {String? entitiesJson}) async {
    calls.add('edit $wireId ${peer ?? 'me'} $text');
    lastEditEntities = entitiesJson;
    return accept;
  }

  @override
  Future<bool> applyDelete(String chatId, String wireId, String? peer, int now) async {
    calls.add('delete $wireId ${peer ?? 'me'}');
    return accept;
  }

  @override
  Future<void> deleteLocal(String chatId, List<String> ids) async => calls.add('local ${ids.join(',')}');
  @override
  Future<int> raiseStatus(List<String> wireIds, int status) async {
    calls.add('status ${wireIds.join(',')} $status');
    return statusRows;
  }

  @override
  Future<int> raiseStatusInChat(String chatId, List<String> wireIds, int status) async {
    calls.add('status-in $chatId ${wireIds.join(',')} $status');
    return 1;
  }

  @override
  Future<List<String>> pendingReceipts(String chatId, int below) async => pending;
  @override
  Future<void> markReceipted(String chatId, List<String> wireIds, int status) async =>
      calls.add('receipted ${wireIds.join(',')} $status');

  /// Status 213 — receipt times by peer (wire → peer → (delivered, read)).
  final receiptTimes = <String, Map<String, (int?, int?)>>{};
  @override
  Future<void> recordReceipts(String chatId, List<String> wireIds, String peer, {required bool read, required int ts}) async {
    for (final w in wireIds) {
      final old = receiptTimes[w]?[peer];
      (receiptTimes[w] ??= {})[peer] = (old?.$1 ?? ts, old?.$2 ?? (read ? ts : null));
    }
  }

  @override
  Future<List<core.StoredReceipt>> receiptsFor(String wireId) async => [
    for (final e in (receiptTimes[wireId] ?? const <String, (int?, int?)>{}).entries)
      core.StoredReceipt(peer: e.key, deliveredAt: e.value.$1, readAt: e.value.$2),
  ];
  @override
  Future<void> setPinnedMessage(String chatId, String? wireId) async {
    calls.add('pin $wireId');
    pinned[chatId] = wireId;
  }

  final renames = <String>[];
  @override
  Future<bool> renameIf(String chatId, String from, String to) async {
    renames.add('$from→$to');
    return true;
  }

  final groupNames = <String>[];

  /// False = the chat already has a real name (a later rename).
  bool firstName = true;
  @override
  Future<bool> setGroupName(String chatId, String name, List<String> placeholders) async {
    // No placeholders = a rename (storage: chat_set_group_name).
    if (placeholders.isEmpty) {
      renames.add('→$name');
      return true;
    }
    groupNames.add('$chatId=$name (${placeholders.join('|')})');
    return firstName;
  }

  @override
  Future<bool> unpinIf(String chatId, String wireId) async {
    if (pinned[chatId] != wireId) return false;
    pinned[chatId] = null;
    calls.add('pin null');
    return true;
  }

  @override
  Future<void> setDisappear(String chatId, int secs) async => calls.add('timer $secs');
  List<String> expired = [];
  @override
  Future<List<String>> expire(int nowUnix) async {
    calls.add('expire');
    return expired;
  }
}

class FakeSender implements MessageSender {
  final sent = <String>[];
  final actions = <Map<String, Object?>>[];
  String? preview;
  bool fail = false;
  Object? failWith;

  /// Chats whose sends fail (a broken group), the others go.
  final failIn = <String>{};
  int lastExpire = 0;

  /// ADR-070 — the formatting JSON of the last text sent.
  String? lastEntities;

  @override
  Future<String?> sendText(
    String chatId,
    String wireId,
    String text, {
    String? replyJson,
    String? previewBaseUrl,
    int expireSecs = 0,
    String? entitiesJson,
  }) async {
    if (fail || failIn.contains(chatId)) throw StateError('offline');
    if (failWith != null) throw failWith!;
    lastExpire = expireSecs;
    lastEntities = entitiesJson;
    sent.add('$text|${replyJson ?? ''}|${previewBaseUrl ?? ''}');
    return preview;
  }

  /// A slow link: actions wait for this before going out.
  Future<void>? hold;

  /// Offline: actions throw like the real sender ("net not connected").
  bool actionsFail = false;
  final actionWires = <String>[];

  @override
  Future<void> sendAction(String chatId, String wireId, Map<String, Object?> action) async {
    if (hold != null) await hold;
    if (actionsFail) throw StateError('net not connected');
    actionWires.add(wireId);
    // No expect() here: actions can go out from async gaps while a widget
    // test is pumping ("Guarded function conflict"). Bad ids are recorded.
    if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(wireId)) {
      badWireIds.add(wireId);
    }
    actions.add(action);
  }

  final badWireIds = <String>[];

  final cancelled = <String>[];
  final resent = <String>[];
  @override
  Future<void> resendMedia(String chatId, String wireId, String mediaJson, {String? replyJson, int expireSecs = 0}) async {
    if (fail || failIn.contains(chatId)) throw StateError('offline');
    resent.add('$wireId|$mediaJson');
  }

  @override
  void cancelSend(String wireId) => cancelled.add(wireId);
}

const w = '0f8fad5b-d9cb-469f-a165-70867728950e';

void main() {
  late FakeMessageStore store;
  late FakeSender sender;
  late MemoryStore settings;
  late ProviderContainer c;
  MessageActions actions() => c.read(messageActionsProvider);

  setUp(() async {
    store = FakeMessageStore();
    sender = FakeSender();
    settings = MemoryStore();
    c = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => 'https://srv'),
        chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
      ],
    );
    addTearDown(c.dispose);
    await c.read(readReceiptsProvider.future);
    await c.read(typingIndicatorsProvider.future);
  });

  // Owner, 2026-10-16: messages sort by when they were written, by the
  // server's clock — the id carries that time (UUIDv7).
  test('wire ids are UUIDv7 carrying the send time', () {
    final a = newWireId(Random(1), 1760600000123);
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(a), isTrue);
    expect(uuidV7Seconds(a), 1760600000);
    expect(newWireId(), isNot(newWireId()));
  });

  test('reply quote JSON, snippet cut, reactions parsing', () {
    final r = ReplyTarget(wireId: w, snippet: 'line one\nline two ${'x' * 300}', kind: 'text');
    final back = ReplyTarget.fromJson(r.toJson())!;
    expect(back.wireId, w);
    expect(back.snippet.startsWith('line one line two'), isTrue);
    expect(back.snippet.runes.length, 200);
    expect(ReplyTarget.fromJson('garbage'), isNull);
    expect(parseReactions('{"❤️":["me","ab"],"👍":["cd"]}'), {
      '❤️': ['me', 'ab'],
      '👍': ['cd'],
    });
    expect(myReaction('{"❤️":["ab"],"👍":["me"]}'), '👍');
    expect(myReaction(null), isNull);
  });

  // 2026-10-16 UI audit — "delete for everyone" offline vanished here and
  // stayed on the other phone. It waits and goes out when the link is back.
  test('offline: delete / edit / react wait and go out on reconnect, once, in order', () async {
    sender.actionsFail = true;
    expect(await actions().deleteForEveryone('chat', w), isTrue, reason: 'gone here at once');
    expect(await actions().edit('chat', w, 'fixed'), isTrue, reason: 'no "couldn\'t edit"');
    await actions().react('chat', w, '👍');
    // Typing is about this moment — not kept.
    await actions().typing('chat', true).catchError((Object _) {});
    expect(sender.actions, isEmpty);
    expect(await actions().flushPendingActions(), 0, reason: 'still offline: kept');

    sender.actionsFail = false;
    c.read(netStatusProvider.notifier).set(NetStatus.connected);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect([for (final a in sender.actions) a['t']], ['delete', 'edit', 'reaction']);
    final firstWires = [...sender.actionWires];
    expect(await actions().flushPendingActions(), 0, reason: 'sent once');
    expect(sender.actionWires, firstWires);
  });

  test('a text that failed offline goes out on reconnect with the same id, once', () async {
    sender.fail = true;
    await expectLater(actions().sendText('chat', 'привет'), throwsStateError);
    final wire = store.rows.single.wireId;
    expect(sender.sent, isEmpty);
    sender.fail = false;
    expect(await actions().flushPendingActions(), 1);
    expect(sender.sent.single, startsWith('привет|'));
    expect(await actions().flushPendingActions(), 0);
    expect(store.rows.single.wireId, wire, reason: 'no second row');
  });

  // Owner, 2026-10-20: sent with no connection, the message hung "sending"
  // after the connection was back. Handing a frame to a dead connection
  // "succeeds", so only the server's ack takes a text off the queue.
  test('a text that went out but was never confirmed goes again on reconnect, same id; the ack ends it', () async {
    await actions().sendText('chat', 'в туннеле');
    final wire = store.rows.single.wireId!;
    expect(sender.sent, hasLength(1));
    expect(await actions().flushPendingActions(), 0, reason: 'just went out: waits for its ack first');

    expect(await actions().onReconnected(), 1, reason: 'the old connection may have lost it');
    expect(sender.sent, hasLength(2));
    expect(store.rows.single.wireId, wire, reason: 'same row, same id — the receiver drops a copy');

    await actions().onAck(wire, ok: true);
    expect(await actions().onReconnected(), 0, reason: 'confirmed: off the queue');
    expect(await settings.get('pending_actions'), '');
  });

  test('a refused text is tried a few times, then stays failed', () async {
    await actions().sendText('chat', 'нет');
    final wire = store.rows.single.wireId!;
    for (var i = 0; i < MessageActions.kMaxTextRefusals; i++) {
      await actions().onAck(wire, ok: false);
    }
    expect(await actions().onReconnected(), 0);
    expect(store.calls.last, 'status $wire ${MsgStatus.failed}');
  });

  test('a queued text older than a week is given up and marked failed', () async {
    sender.fail = true;
    await expectLater(actions().sendText('chat', 'old'), throwsStateError);
    final wire = store.rows.single.wireId!;
    final old = (jsonDecode(settings.map['pending_actions']!) as List).cast<Map<String, Object?>>();
    old.single['ts'] = DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch ~/ 1000;
    settings.map['pending_actions'] = jsonEncode(old);
    sender.fail = false;
    expect(await actions().onReconnected(), 0);
    expect(sender.sent, isEmpty);
    expect(store.calls.last, 'status $wire ${MsgStatus.failed}');
    expect(await settings.get('pending_actions'), '');
  });

  // Owner, 2026-10-18 — a message waiting for a connection can be called back.
  test('cancel a text waiting offline: off the queue, gone here, nothing goes out', () async {
    sender.fail = true;
    await expectLater(actions().sendText('chat', 'oops'), throwsStateError);
    final row = store.rows.single;
    await actions().cancelSend('chat', id: row.id, wireId: row.wireId!, status: MsgStatus.failed);
    expect(sender.cancelled, [row.wireId]);
    expect(store.calls, contains('local ${row.id}'));
    sender.fail = false;
    expect(await actions().flushPendingActions(), 0, reason: 'the queue forgot it');
    expect(sender.sent, isEmpty);
    expect(sender.actions, isEmpty, reason: 'it never left — no delete needed');
  });

  test('cancel a text the server has not confirmed: gone here, delete-for-everyone follows', () async {
    final chat = 'ab' * 16;
    await actions().sendText(chat, 'maybe out');
    final row = store.rows.single;
    await actions().cancelSend(chat, id: row.id, wireId: row.wireId!, status: MsgStatus.sending);
    expect(store.calls, contains('local ${row.id}'));
    expect(sender.actions.single, {'t': 'delete', 'target': row.wireId});
  });

  test('a send that Rust stopped (cancelled) is not marked failed or queued', () async {
    sender.failWith = StateError('send cancelled');
    await actions().sendText('chat', 'stopped');
    expect(store.calls.where((c) => c.contains('${MsgStatus.failed}')), isEmpty);
    sender.failWith = null;
    expect(await actions().flushPendingActions(), 0);
  });

  test('sendText stores first, sends with reply + preview, ack marks sent', () async {
    sender.preview = '{"type":"link"}';
    const reply = ReplyTarget(wireId: w, snippet: 'hi', kind: 'text');
    await actions().sendText('chat', 'hello https://x.org', reply: reply);
    final row = store.rows.single;
    expect((row.isMine, row.kind, row.body), (true, 'text', 'hello https://x.org'));
    expect(row.replyJson, contains(w));
    expect(sender.sent.single, 'hello https://x.org|${reply.toJson()}|https://srv');
    expect(store.calls, contains('media ${row.id}'), reason: 'preview stored on the row');

    await actions().onAck(row.wireId!, ok: true);
    expect(store.calls.last, 'status ${row.wireId} ${MsgStatus.sent}');
  });

  test('a failed send marks the message failed and rethrows', () async {
    sender.fail = true;
    await expectLater(actions().sendText('chat', 'x'), throwsStateError);
    expect(store.calls.last, 'status ${store.rows.single.wireId} ${MsgStatus.failed}');
  });

  test('an ack that beats the media row is applied once the row exists', () async {
    store.statusRows = 0;
    await actions().onAck(w, ok: true);
    store.statusRows = 1;
    store.calls.clear();
    await actions().trackStoredOutgoing('chat', w);
    expect(store.calls, ['status $w ${MsgStatus.sent}']);
    store.calls.clear();
    await actions().trackStoredOutgoing('chat', w);
    expect(store.calls, isEmpty, reason: 'applied only once');
  });

  test('react / edit / delete apply locally, then go out encrypted', () async {
    final a = actions();
    await a.react('chat', w, '🔥');
    await a.react('chat', w, null);
    expect(await a.edit('chat', w, '  fixed  '), isTrue);
    expect(await a.edit('chat', w, '   '), isFalse, reason: 'blank edit refused');
    expect(await a.deleteForEveryone('chat', w), isTrue);
    await a.deleteForMe('chat', ['m1', 'm2']);
    await a.pin('chat', w);
    expect(store.calls, [
      'react $w me 🔥',
      'react $w me null',
      'edit $w me fixed',
      'delete $w me',
      'local m1,m2',
      'pin $w',
    ]);
    expect(sender.actions, [
      {'t': 'reaction', 'target': w, 'emoji': '🔥'},
      {'t': 'reaction', 'target': w, 'emoji': ''},
      {'t': 'edit', 'target': w, 'text': 'fixed', 'entities': []},
      {'t': 'delete', 'target': w},
    ]);
  });

  // ADR-070 — formatting goes out beside the clean text and is stored with
  // it; every message from this app says it is formatted (even with none).
  test('formatted text: stored and sent with its ranges; plain is "[]"', () async {
    await actions().sendText('chat', 'Hello world', entities: const [TextEntity(EntityType.bold, 0, 5)]);
    expect(store.rows.single.body, 'Hello world', reason: 'no markers in the text');
    expect(store.rows.single.entitiesJson, '[{"t":"bold","o":0,"l":5}]');
    expect(sender.lastEntities, '[{"t":"bold","o":0,"l":5}]');
    await actions().sendText('chat', '*stars stay*');
    expect(store.rows.last.entitiesJson, '[]');
    expect(sender.lastEntities, '[]');
  });

  test('a formatted text that failed offline keeps its formatting in the queue', () async {
    sender.fail = true;
    await expectLater(
      actions().sendText('chat', 'код', entities: const [TextEntity(EntityType.code, 0, 3)]),
      throwsStateError,
    );
    sender.fail = false;
    sender.lastEntities = null;
    expect(await actions().flushPendingActions(), 1);
    expect(sender.lastEntities, '[{"t":"code","o":0,"l":3}]');
  });

  // Status 211 — one chat's stuck message no longer holds back the others.
  test('a message that can\'t go out holds back only its own chat', () async {
    sender.fail = true;
    await expectLater(actions().sendText('broken', 'one'), throwsStateError);
    await expectLater(actions().sendText('broken', 'two'), throwsStateError);
    await expectLater(actions().sendText('chat', 'three'), throwsStateError);
    sender.fail = false;
    sender.failIn.add('broken');
    expect(await actions().flushPendingActions(), 1);
    expect(sender.sent.map((x) => x.split('|').first), ['three']);
    sender.failIn.clear();
    expect(await actions().flushPendingActions(), 2, reason: 'in order, once it can');
    expect(sender.sent.map((x) => x.split('|').first), ['three', 'one', 'two']);
  });

  // Status 211 — a text the server refused for good goes again on "Retry".
  test('retry puts a failed text back on the queue and sends it', () async {
    await actions().sendText('chat', 'важно');
    final wire = store.rows.single.wireId!;
    for (var i = 0; i < MessageActions.kMaxTextRefusals; i++) {
      await actions().onAck(wire, ok: false);
    }
    expect(await settings.get('pending_actions'), isNot(contains(wire)), reason: 'given up');
    sender.sent.clear();
    store.calls.clear();
    await actions().retrySend('chat', wireId: wire, text: 'важно');
    expect(store.calls, contains('status $wire ${MsgStatus.sending}'));
    expect(sender.sent.map((x) => x.split('|').first), ['важно']);
    await actions().onAck(wire, ok: true);
    expect(store.calls.last, 'status $wire ${MsgStatus.sent}');
  });

  // Status 211 (tech-debt 2.59) — a photo whose ack never came goes again
  // when the connection is back: same wire id, no new upload.
  test('a stored media message without its ack is sent again', () async {
    const media = '{"kind":"photo","blob":"b1"}';
    await actions().trackStoredOutgoing('chat', w, mediaJson: media);
    expect(await settings.get('pending_actions'), contains(w));
    await actions().onReconnected();
    expect(sender.resent, ['$w|$media']);
    await actions().onAck(w, ok: true);
    expect(await settings.get('pending_actions'), isNot(contains(w)));
    // "Retry" on one that failed: back on the queue, out at once.
    await actions().retrySend('chat', wireId: w, text: '', mediaJson: media);
    expect(sender.resent, ['$w|$media', '$w|$media']);
  });

  // Status 211 — "too many at once" isn't a refusal: no "!", no try lost.
  test('a busy server (429) leaves the message sending', () async {
    await actions().sendText('chat', 'hi');
    final wire = store.rows.single.wireId!;
    store.calls.clear();
    await actions().onAck(wire, ok: false, busy: true);
    expect(store.calls.where((x) => x.startsWith('status')), isEmpty);
    expect(await settings.get('pending_actions'), contains(wire));
  });

  test('edits carry formatting both ways; an older app\'s edit has none', () async {
    expect(
      await actions().edit('chat', w, '  new text ', entities: const [TextEntity(EntityType.italic, 2, 3)]),
      isTrue,
    );
    expect(store.lastEditEntities, '[{"t":"italic","o":0,"l":3}]', reason: 'trimmed with the text');
    expect(sender.actions.single['entities'], [
      {'t': 'italic', 'o': 0, 'l': 3},
    ]);
    await actions().onIncomingAction(
      'chat',
      'edit',
      jsonEncode({
        'target': w,
        'text': 'hi',
        'entities': [
          {'t': 'bold', 'o': 0, 'l': 2},
        ],
      }),
      'peer1',
    );
    expect(store.lastEditEntities, '[{"t":"bold","o":0,"l":2}]');
    await actions().onIncomingAction('chat', 'edit', jsonEncode({'target': w, 'text': '*hi*'}), 'peer1');
    expect(store.lastEditEntities, isNull);
  });

  test('nothing is sent when storage refuses (not my message)', () async {
    store.accept = false;
    expect(await actions().edit('chat', w, 'x'), isFalse);
    expect(await actions().deleteForEveryone('chat', w), isFalse);
    await actions().react('chat', w, '👍');
    expect(sender.actions, isEmpty);
  });

  test('receipts: delivery always, read only with the setting on', () async {
    store.pending = [w];
    await actions().sendDeliveryReceipts('chat');
    await actions().sendReadReceipts('chat');
    expect(sender.actions, [
      {
        't': 'receipt',
        'read': false,
        'ids': [w],
      },
      {
        't': 'receipt',
        'read': true,
        'ids': [w],
      },
    ]);
    // Status 211 — kept pending until the server acks them.
    expect(store.calls, isEmpty);
    await actions().onAck(sender.actionWires[1], ok: true);
    await actions().onAck(sender.actionWires[0], ok: false);
    expect(store.calls, ['receipted $w 2'], reason: 'a refused receipt stays pending');

    await c.read(readReceiptsProvider.notifier).save(false);
    await actions().sendReadReceipts('chat');
    expect(sender.actions.length, 2, reason: 'read receipts off');
  });

  // Status 213 — each person's receipt is kept with its time ("Message info").
  test('an incoming receipt records who and when', () async {
    await actions().onIncomingAction('chat', 'receipt', jsonEncode({'read': false, 'ids': [w]}), 'mama');
    await actions().onIncomingAction('chat', 'receipt', jsonEncode({'read': true, 'ids': [w]}), 'mama');
    final r = (await store.receiptsFor(w)).single;
    expect(r.peer, 'mama');
    expect(r.deliveredAt, isNotNull);
    expect(r.readAt, isNotNull);
  });

  // Status 211 — a delivery receipt that didn't get through goes again when
  // the connection is back, for every chat (the sender's ✓ became ✓✓ only
  // if another message came).
  test('the connection back: pending delivery receipts go out again', () async {
    final t = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        chatsProvider.overrideWith((ref) async => [ChatPreview(id: 'chat', name: 'Mama', preview: '', time: '')]),
      ],
    );
    addTearDown(t.dispose);
    store.pending = [w];
    final a = t.read(messageActionsProvider);
    await a.sendDeliveryReceipts('chat'); // handed to a dead connection: no ack
    await a.onReconnected();
    await pumpEventQueue();
    expect(sender.actions.where((x) => x['t'] == 'receipt').length, 2);
    await a.onAck(sender.actionWires.last, ok: true);
    expect(store.calls, ['receipted $w 1']);
  });

  // Owner, 2026-10-15: "messages arrive before I accept — are they shown
  // as read?" No: a request only confirms delivery.
  test('message request: delivered goes out, read and typing do not', () async {
    final req = 'ef' * 16;
    final t = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        chatsProvider.overrideWith(
          (ref) async => [ChatPreview(id: req, name: 'Grisha', preview: '', time: '', request: true)],
        ),
      ],
    );
    addTearDown(t.dispose);
    await t.read(chatsProvider.future);
    await t.read(readReceiptsProvider.future);
    await t.read(typingIndicatorsProvider.future);
    store.pending = [w];
    final a = t.read(messageActionsProvider);
    await a.sendDeliveryReceipts(req);
    await a.sendReadReceipts(req);
    await a.typing(req, true);
    expect(sender.actions.map((x) => (x['t'], x['read'])).toList(), [('receipt', false)]);
  });

  test('typing is throttled and respects the setting', () async {
    final t0 = DateTime(2026);
    final a = actions();
    await a.typing('chat', true, now: t0);
    await a.typing('chat', true, now: t0.add(const Duration(seconds: 2)));
    await a.typing('chat', true, now: t0.add(const Duration(seconds: 5)));
    await a.typing('chat', false);
    await a.typing('chat', false);
    expect(sender.actions, [
      {'t': 'typing', 'active': true},
      {'t': 'typing', 'active': true},
      {'t': 'typing', 'active': false},
    ]);
    await c.read(typingIndicatorsProvider.notifier).save(false);
    await a.typing('other', true, now: t0);
    expect(sender.actions.length, 3);
  });

  test('incoming actions are attributed to the authenticated sender', () async {
    final a = actions();
    expect(await a.onIncomingAction('chat', 'reaction', jsonEncode({'target': w, 'emoji': '👍'}), 'peer1'), isTrue);
    expect(
      await a.onIncomingAction('chat', 'reaction', jsonEncode({'target': w, 'emoji': '👍'}), null),
      isFalse,
      reason: 'unattributable',
    );
    await a.onIncomingAction('chat', 'edit', jsonEncode({'target': w, 'text': 'new'}), 'peer1');
    await a.onIncomingAction('chat', 'delete', jsonEncode({'target': w}), null);
    await a.onIncomingAction(
      'chat',
      'receipt',
      jsonEncode({
        'read': true,
        'ids': [w],
      }),
      'peer1',
    );
    expect(await a.onIncomingAction('chat', 'edit', 'not json', 'peer1'), isFalse);
    expect(store.calls, [
      'react $w peer1 👍',
      'edit $w peer1 new',
      'delete $w ',
      'status-in chat $w ${MsgStatus.read}',
    ]);

    // Reciprocity: with my read receipts off, theirs show as delivered.
    await c.read(readReceiptsProvider.notifier).save(false);
    await a.onIncomingAction(
      'chat',
      'receipt',
      jsonEncode({
        'read': true,
        'ids': [w],
      }),
      'peer1',
    );
    expect(store.calls.last, 'status-in chat $w ${MsgStatus.delivered}');
  });

  // Owner, 2026-10-15: the person who started a chat by QR saw
  // "Chat 56844611" forever — only "Group xxxx" was replaced by a name.
  test('profile names a chat I started ("Chat <their key>")', () async {
    final peer = '56844611${'a' * 56}';
    final chat = 'cd' * 16;
    final t = ProviderContainer(
      overrides: [
        messageStoreProvider.overrideWithValue(store),
        messageSenderProvider.overrideWithValue(sender),
        settingsStoreProvider.overrideWithValue(settings),
        linkPreviewBaseUrlProvider.overrideWithValue(() => null),
        chatsProvider.overrideWith(
          (ref) async => [ChatPreview(id: chat, name: 'Chat 56844611', preview: '', time: '')],
        ),
      ],
    );
    addTearDown(t.dispose);
    await t.read(chatsProvider.future);
    await t.read(messageActionsProvider).onIncomingAction(chat, 'profile', jsonEncode({'name': ' Симулятор '}), peer);
    expect(store.renames, ['Chat 56844611→Симулятор']);
  });

  // ADR-034 — a group's name from a member; the placeholders (both
  // languages) let a just-joined chat become the group.
  test('group_name renames the group', () async {
    final a = actions();
    final chat = 'ab' * 20;
    expect(await a.onIncomingAction(chat, 'group_name', jsonEncode({'name': ' Дача '}), 'peer1'), isTrue);
    expect(store.groupNames, ['$chat=Дача (Group abababab|New group|New chat|Группа abababab|Новая группа|Новый чат)']);
    expect(
      await a.onIncomingAction(chat, 'group_name', jsonEncode({'name': 'X'}), null),
      isFalse,
      reason: 'unattributable',
    );
    expect(await a.onIncomingAction(chat, 'group_name', jsonEncode({'name': '  '}), 'peer1'), isFalse);
    expect(store.groupNames.length, 1);
  });

  test('typing indicator appears, expires, and stops on a new message', () async {
    final a = actions();
    await a.onIncomingAction('chat', 'typing', '{"active":true}', 'peer1');
    expect(c.read(typingChatsProvider).containsKey('chat'), isTrue);
    c.read(typingChatsProvider.notifier).expire(now: DateTime.now().add(const Duration(seconds: 7)));
    expect(c.read(typingChatsProvider), isEmpty, reason: 'expires without "stopped"');

    await a.onIncomingAction('chat', 'typing', '{"active":true}', 'peer1');
    store.pending = [w];
    c.read(openChatProvider.notifier).set('chat');
    await a.afterIncomingMessage('chat');
    expect(c.read(typingChatsProvider), isEmpty);
    expect(sender.actions.map((x) => x['read']), [false, true], reason: 'delivered + read (chat is open)');
  });

  group('disappearing messages', () {
    late ProviderContainer t;
    setUp(() {
      t = ProviderContainer(
        overrides: [
          messageStoreProvider.overrideWithValue(store),
          messageSenderProvider.overrideWithValue(sender),
          settingsStoreProvider.overrideWithValue(settings),
          linkPreviewBaseUrlProvider.overrideWithValue(() => null),
          chatsProvider.overrideWith(
            (ref) async => const [ChatPreview(id: 'chat', name: 'M', preview: '', time: '', disappearSecs: 3600)],
          ),
        ],
      );
      addTearDown(t.dispose);
    });

    test('messages carry the chat timer and get an expiry', () async {
      await t.read(chatsProvider.future);
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      await t.read(messageActionsProvider).sendText('chat', 'self-destruct');
      final row = store.rows.single;
      expect(sender.lastExpire, 3600);
      expect(row.expireAt, inInclusiveRange(before + 3600, before + 3602));
    });

    test('setting the timer: stored, system line, sent to the other side', () async {
      await t.read(messageActionsProvider).setTimer('chat', 86400);
      expect(store.calls.first, 'timer 86400');
      expect(store.rows.single.kind, 'system');
      expect(store.rows.single.body, 'timer:86400:me');
      expect(sender.actions.single, {'t': 'timer', 'secs': 86400});
    });

    test('their timer change applies here with a system line', () async {
      final a = t.read(messageActionsProvider);
      expect(await a.onIncomingAction('chat', 'timer', '{"secs":0}', 'peer'), isTrue);
      expect(store.calls.first, 'timer 0');
      expect(store.rows.single.body, 'timer:0:peer');
    });

    test('expireNow sweeps and refreshes affected chats', () async {
      store.expired = ['chat'];
      await t.read(messageActionsProvider).expireNow();
      expect(store.calls, ['expire']);
    });

    test('timer labels and system lines in both languages', () {
      final en = lookupAppL10n(const Locale('en'));
      final ru = lookupAppL10n(const Locale('ru'));
      expect(timerChoiceLabel(en, 86400), '1 day');
      expect(timerChoiceLabel(en, 172800), '2 days');
      expect(timerChoiceLabel(ru, 172800), '2 дня');
      expect(timerChoiceLabel(ru, 5 * 86400), '5 дней');
      expect(timerChoiceLabel(ru, 2419200), '4 недели');
      expect(systemLineText(en, 'timer:86400:me'), 'You set messages to disappear after 1 day');
      expect(systemLineText(ru, 'timer:0:peer'), 'Исчезающие сообщения выключены');
      expect(systemLineText(en, 'legacy text'), 'legacy text');
    });
  });

  group('ADR-035 group membership', () {
    final chat = 'ab' * 16;
    final me = 'aa' * 32;
    final anya = 'a1' * 32;
    final bob = 'b0' * 32;
    late FakeGroupOps ops;
    late FakeChatStore chats;
    late ProviderContainer t;

    setUp(() {
      ops = FakeGroupOps()..adminId = me;
      chats = FakeChatStore();
      MessageActions.peerLeftJitter = () => Duration.zero;
      t = ProviderContainer(
        overrides: [
          messageStoreProvider.overrideWithValue(store),
          messageSenderProvider.overrideWithValue(sender),
          settingsStoreProvider.overrideWithValue(settings),
          chatStoreProvider.overrideWithValue(chats),
          groupOpsProvider.overrideWithValue(ops),
          chatsProvider.overrideWith(
            (ref) async => [ChatPreview(id: chat, name: 'Дача', group: true, preview: '', time: '')],
          ),
        ],
      );
      addTearDown(t.dispose);
    });

    test('the admin removes someone: one Commit, the others told, a line here', () async {
      await t.read(chatsProvider.future);
      await t.read(messageActionsProvider).removeMembers(chat, [bob]);
      expect(ops.calls, ['remove $bob']);
      expect(sender.actions.single, {
        't': 'removed',
        'who': [bob],
      });
      expect(store.rows.single.body, 'member-removed:me:${shortKey(bob)}');
    });

    test('rename: sent to everyone, renamed here, a line', () async {
      await t.read(chatsProvider.future);
      final a = t.read(messageActionsProvider);
      await a.renameGroup(chat, '  Дача 2 ');
      expect(sender.actions.single, {'t': 'group_name', 'name': 'Дача 2'});
      expect(store.renames, ['→Дача 2']);
      expect(store.rows.single.body, 'group-renamed:me:Дача 2');
      await a.renameGroup(chat, 'Дача');
      expect(sender.actions.length, 1, reason: 'same name: nothing to do');
    });

    test('leaving: the others told, off the server, the chat gone here', () async {
      await t.read(messageActionsProvider).leaveGroup(chat);
      expect(sender.actions.single, {'t': 'leave'});
      expect(ops.calls, ['leave-server']);
      expect(chats.calls, ['delete $chat']);
    });

    test('leaving fails offline and keeps the chat (so it can be retried)', () async {
      ops.fail = true;
      await expectLater(t.read(messageActionsProvider).leaveGroup(chat), throwsStateError);
      expect(chats.calls, isEmpty);
    });

    test('a rename counts only from whoever manages the group', () async {
      store.firstName = false;
      await t.read(chatsProvider.future);
      final a = t.read(messageActionsProvider);
      ops.adminId = anya;
      expect(await a.onIncomingAction(chat, 'group_name', jsonEncode({'name': 'Взлом'}), bob), isFalse);
      expect(store.renames, isEmpty);
      expect(await a.onIncomingAction(chat, 'group_name', jsonEncode({'name': 'Дом'}), anya), isTrue);
      expect(store.renames, ['→Дом']);
      expect(store.rows.single.body, 'group-renamed:by:${shortKey(anya)}:Дом');
    });

    test('nobody is added or removed quietly: the Commit names who did it (mls-identity:3)', () async {
      final a = t.read(messageActionsProvider);
      final dave = 'd0' * 32;
      await a.onGroupCommit(
        chat,
        jsonEncode({
          'by': bob,
          'added': [dave],
          'removed': [anya],
        }),
      );
      expect(store.rows.map((r) => r.body), [
        'member-added:by:${shortKey(bob)}:${shortKey(dave)}',
        'member-removed:by:${shortKey(bob)}:${shortKey(anya)}',
      ]);
      // A claimed "removed" line adds nothing: the Commit already said it.
      final who = jsonEncode({
        'who': [anya],
      });
      expect(await a.onIncomingAction(chat, 'removed', who, bob), isFalse);
      expect(store.rows.length, 2);
    });

    test('someone left: their removal Commit adds no second line', () async {
      final a = t.read(messageActionsProvider);
      expect(await a.onIncomingAction(chat, 'leave', '{}', bob), isTrue);
      await a.onGroupCommit(
        chat,
        jsonEncode({
          'by': anya,
          'added': [],
          'removed': [bob],
        }),
      );
      expect(store.rows.map((r) => r.body), ['member-left:${shortKey(bob)}']);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });

    test('someone leaves: a line, then one of us commits their removal', () async {
      expect(await t.read(messageActionsProvider).onIncomingAction(chat, 'leave', '{}', bob), isTrue);
      expect(store.rows.single.body, 'member-left:${shortKey(bob)}');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(ops.calls, ['remove $bob']);
    });

    test('a Commit that removed me: one line, and off the server', () async {
      final a = t.read(messageActionsProvider);
      await a.onGroupCommit(chat);
      expect(store.rows, isEmpty, reason: 'still a member');
      ops.active = false;
      await a.onGroupCommit(chat);
      expect(store.rows.single.body, 'you-removed');
      expect(ops.calls, ['leave-server']);
    });

    test('the admin manages; anyone does without an admin; nobody once removed', () {
      expect(GroupRole(active: true, admin: me).canManage(me), isTrue);
      expect(GroupRole(active: true, admin: anya).canManage(me), isFalse);
      expect(const GroupRole(active: true).canManage(me), isTrue);
      expect(GroupRole(active: false, admin: me).canManage(me), isFalse);
    });

    test('membership lines in both languages', () {
      final en = lookupAppL10n(const Locale('en'));
      final ru = lookupAppL10n(const Locale('ru'));
      expect(systemLineText(en, 'you-removed'), 'You were removed from this group.');
      expect(systemLineText(ru, 'member-left:Аня'), 'Аня вышел(а) из группы.');
      expect(systemLineText(en, 'member-removed:me:Bob'), 'You removed Bob.');
      expect(systemLineText(ru, 'member-removed:by:Аня:Боб, Вика'), 'Аня удалил(а): Боб, Вика.');
      expect(systemLineText(ru, 'member-added:by:Аня:Дима'), 'Аня добавил(а): Дима.');
      expect(systemLineText(en, 'member-added:by:Anya:Dima'), 'Anya added Dima.');
      expect(systemLineText(en, 'group-renamed:me:Home'), 'You renamed the group to “Home”.');
      expect(systemLineText(ru, 'group-renamed:by:Аня:Дом'), 'Аня переименовал(а) группу в «Дом».');
    });
  });
}

/// ADR-035 — records membership calls; [active] / [adminId] answer role queries.
class FakeGroupOps implements GroupOps {
  final calls = <String>[];
  bool active = true;
  String? adminId;
  bool fail = false;

  @override
  Future<void> removeMembers(String chatId, List<String> who) async {
    if (fail) throw StateError('offline');
    calls.add('remove ${who.join(',')}');
  }

  @override
  Future<void> leaveServer(String chatId) async {
    if (fail) throw StateError('offline');
    calls.add('leave-server');
  }

  @override
  Future<bool> isActive(String chatId) async => active;

  @override
  Future<String?> admin(String chatId) async => adminId;
}
