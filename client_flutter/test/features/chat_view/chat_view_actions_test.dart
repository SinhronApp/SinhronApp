import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/widgets/ds_blur_bar.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/mentions.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/saved_messages.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_info/chat_info_screen.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/chat_view/rich_composer.dart';
import 'package:sinhron/core/rich_text.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/message_actions_test.dart' show FakeGroupOps, FakeMessageStore, FakeSender;
import '../../core/people_test.dart' show FakePeopleStore;
import '../../core/saved_messages_test.dart' show FakeSavedBackend, kSavedId;
import '../../core/settings_providers_test.dart' show MemoryStore;

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const w1 = '00000000-0000-4000-8000-000000000001';
const w2 = '00000000-0000-4000-8000-000000000002';
const w3 = '00000000-0000-4000-8000-000000000003';
const w4 = '00000000-0000-4000-8000-000000000004';
const w5 = '00000000-0000-4000-8000-000000000005';

/// An hour ago — inside the 24 h edit / delete-for-everyone window.
final base = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;

core.StoredMessageSummary row(
  String id,
  String wire,
  int ts,
  String body, {
  bool mine = false,
  int status = 1,
  String? reply,
  String? reactions,
  bool deleted = false,
  int? edited,
  String kind = 'text',
  int? expireAt,
  String? entities,
}) =>
    core.StoredMessageSummary(
      id: id,
      chatId: chatId,
      tsUnix: base + ts,
      body: body,
      kind: kind,
      isMine: mine,
      wireId: wire,
      expireAt: expireAt,
      status: status,
      replyJson: reply,
      reactionsJson: reactions,
      deleted: deleted,
      editedTs: edited,
      entitiesJson: entities,
    );

final rows = [
  row('m1', w1, 1, 'Hello there', reactions: '{"👍":["peer"]}'),
  row('m2', w2, 2, 'Mine, read', mine: true, status: 3, edited: 5),
  row('m3', w3, 3, 'Old news', deleted: true),
  row('m4', w4, 4, 'Second unread', reply: '{"id":"$w1","snippet":"Hello there","kind":"text"}'),
  row('m5', w5, 5, 'Mine, sending', mine: true, status: 0, expireAt: 1900000000),
  row('s1', 'sys', 6, 'Messages now disappear after 1 day', kind: 'system'),
];

final kMe = 'ee' * 32;
final kAnya = 'a1' * 32;
final kBoris = 'b0' * 32;

class Harness {
  Harness({
    String? pinned,
    int unread = 0,
    List<core.StoredMessageSummary>? history,
    bool request = false,
    bool group = false,
    bool member = true,
    bool blocked = false,
    String? savedId,
    int disappear = 0,
  }) {
    groups.active = member;
    final shown = history ?? rows;
    container = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      savedMessagesBackendProvider.overrideWithValue(FakeSavedBackend(id: savedId)),
      messageStoreProvider.overrideWithValue(store),
      messageSenderProvider.overrideWithValue(sender),
      chatStoreProvider.overrideWithValue(chats),
      groupOpsProvider.overrideWithValue(groups),
      hapticsProvider.overrideWithValue(Haptics(() => false)),
      linkPreviewBaseUrlProvider.overrideWithValue(() => null),
      peopleStoreProvider.overrideWithValue(
        people
          ..names_.addAll({kAnya: 'Аня', kBoris: 'Борис'})
          ..blocked_.addAll([if (blocked) kAnya]),
      ),
      chatMembersLoaderProvider.overrideWithValue((_) async => [kMe, kAnya, kBoris]),
      myIdentityProvider.overrideWithValue(() => kMe),
      videoPickerProvider.overrideWithValue((camera, max) async {
        videoPicks.add((camera, max));
        return null; // cancelled
      }),
      messagePageFetcherProvider.overrideWithValue(
        (String id, {int? beforeTs, String? beforeId, required int limit}) async => beforeId == null ? shown : const [],
      ),
      chatsProvider.overrideWith(
        (ref) async => [
          ChatPreview(
            id: chatId,
            name: 'Maria',
            group: group,
            preview: '',
            time: '',
            unread: unread,
            pinnedMsg: pinned,
            request: request && !chats.calls.contains('request $chatId false'),
            peerId: group ? null : kAnya,
            disappearSecs: disappear,
          ),
          const ChatPreview(id: 'b1b2c3d4e5f60718293a4b5c6d7e8f9012345678', name: 'Boris', preview: '', time: ''),
          if (savedId != null && savedId != chatId)
            ChatPreview(id: savedId, name: 'Saved Messages', preview: '', time: '', saved: true),
        ],
      ),
    ]);
  }

  final store = FakeMessageStore();
  final sender = FakeSender();
  final people = FakePeopleStore();
  final chats = FakeChatStore();
  final groups = FakeGroupOps();
  final videoPicks = <(bool, Duration)>[];
  late final ProviderContainer container;

  /// [screen] — something else than this chat (it gets the same fakes).
  Future<void> pump(WidgetTester t, {Widget? screen}) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(container.dispose);
    await container.read(chatsProvider.future);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder(
                pageBuilder: (_, _, _) => screen ?? const ChatViewScreen(chatId: chatId, contactName: 'Maria'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }
}

Finder text(String s) => find.textContaining(s, findRichText: true);

/// The message text itself (not a one-line quote of it).
Finder bubble(String s) => find.byWidgetPredicate(
      (w) => w is RichText && w.maxLines == null && w.text.toPlainText().contains(s),
    );

Future<void> longPress(WidgetTester t, String s) async {
  await t.longPress(bubble(s));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('statuses, quote, reactions, edited, tombstone, unread divider', (t) async {
    final h = Harness(unread: 2);
    await h.pump(t);
    expect(find.byKey(const ValueKey('status-3')), findsOneWidget, reason: 'read ✓✓');
    expect(find.byKey(const ValueKey('status-0')), findsOneWidget, reason: 'sending');
    expect(text('edited'), findsOneWidget);
    expect(find.byKey(const ValueKey('tombstone')), findsOneWidget);
    expect(text('Old news'), findsNothing, reason: 'deleted text is gone');
    expect(find.byKey(const ValueKey('reply-quote')), findsOneWidget);
    expect(find.byKey(const ValueKey('reaction-👍')), findsOneWidget);
    expect(find.byKey(const ValueKey('unread-divider')), findsOneWidget);
  });

  testWidgets('long-press menu: react, then reply sends the quote', (t) async {
    final h = Harness();
    await h.pump(t);

    await longPress(t, 'Hello there');
    expect(find.byKey(const ValueKey('menu-reply')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-edit')), findsNothing, reason: 'not my message');
    await t.tap(find.byKey(const ValueKey('react-🔥')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'react $w1 me 🔥');

    await longPress(t, 'Hello there');
    await t.tap(find.byKey(const ValueKey('menu-reply')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
    expect(text('Reply to Maria'), findsOneWidget);

    await t.enterText(find.byType(EditableText), 'Answer');
    await t.pump(); // the mic button turns into "send" on the next frame
    await t.tap(find.byKey(const ValueKey('composer-send-or-mic')));
    await t.pumpAndSettle();
    expect(h.sender.sent.single, startsWith('Answer|{"id":"$w1"'));
    expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
  });

  testWidgets('double tap hearts; tapping a reaction chip takes it', (t) async {
    final h = Harness();
    await h.pump(t);
    await t.tap(bubble('Hello there'));
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(bubble('Hello there'));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'react $w1 me ❤️');
    await t.tap(find.byKey(const ValueKey('reaction-👍')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'react $w1 me 👍');
  });

  testWidgets('swipe left on a bubble starts a reply', (t) async {
    final h = Harness();
    await h.pump(t);
    await t.drag(bubble('Hello there'), const Offset(-120, 0));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('reply-bar')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('composer-mode-cancel')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('reply-bar')), findsNothing);
  });

  testWidgets('edit my message: composer takes the text, send edits', (t) async {
    final h = Harness();
    await h.pump(t);
    await longPress(t, 'Mine, read');
    await t.tap(find.byKey(const ValueKey('menu-edit')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('edit-bar')), findsOneWidget);
    expect(find.text('Mine, read'), findsWidgets, reason: 'text loaded into the composer');
    await t.enterText(find.byType(EditableText), 'Mine, fixed');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('composer-send-or-mic')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'edit $w2 me Mine, fixed');
    expect(h.sender.actions.last, {'t': 'edit', 'target': w2, 'text': 'Mine, fixed', 'entities': []});
  });

  // ADR-070 — formatting end to end on the chat screen.
  testWidgets('typing **bold** in the composer sends clean text with its formatting', (t) async {
    final h = Harness();
    await h.pump(t);
    final c = t.widget<EditableText>(find.byType(EditableText)).controller as RichTextController;
    c.selection = const TextSelection.collapsed(offset: 0);
    for (final ch in '**Жирный** привет'.split('')) {
      final sel = c.selection;
      c.value = TextEditingValue(
        text: c.text.replaceRange(sel.start, sel.end, ch),
        selection: TextSelection.collapsed(offset: sel.start + 1),
      );
    }
    await t.pump();
    expect(c.text, 'Жирный привет', reason: 'the markers turned into formatting as typed');
    await t.tap(find.byKey(const ValueKey('composer-send-or-mic')));
    await t.pumpAndSettle();
    expect(h.sender.sent.single, startsWith('Жирный привет|'));
    expect(h.sender.lastEntities, '[{"t":"bold","o":0,"l":6}]');
    expect(h.store.rows.single.entitiesJson, '[{"t":"bold","o":0,"l":6}]');
  });

  testWidgets('a formatted message: bold in the bubble, edit keeps it, copy is plain, forward keeps it', (t) async {
    final h = Harness(history: [
      row('f1', w1, 1, 'Bold and plain', mine: true, status: 3, entities: '[{"t":"bold","o":0,"l":4}]'),
    ]);
    await h.pump(t);
    final spans = <TextSpan>[];
    bubble('Bold and plain').evaluate().map((e) => (e.widget as RichText).text).forEach((s) => s.visitChildren((c) {
          if (c is TextSpan && c.text != null) spans.add(c);
          return true;
        }));
    expect(spans.firstWhere((s) => s.text == 'Bold').style!.fontWeight, FontWeight.w700);
    expect(spans.firstWhere((s) => s.text == ' and plain').style!.fontWeight, isNull);

    // Copy: plain words on the clipboard, the formatting remembered here.
    final clip = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await longPress(t, 'Bold and plain');
    await t.tap(find.byKey(const ValueKey('menu-copy')));
    await t.pumpAndSettle();
    expect(clip, ['Bold and plain']);
    expect(RichClipboard.match('Bold and plain')!.entities, const [TextEntity(EntityType.bold, 0, 4)]);
    RichClipboard.clear();

    // Edit: the composer shows it formatted; the edit goes out formatted.
    await longPress(t, 'Bold and plain');
    await t.tap(find.byKey(const ValueKey('menu-edit')));
    await t.pumpAndSettle();
    final c = t.widget<EditableText>(find.byType(EditableText)).controller as RichTextController;
    expect(c.formatted, FormattedText('Bold and plain', const [TextEntity(EntityType.bold, 0, 4)]));
    c.selection = TextSelection.collapsed(offset: c.text.length);
    c.value = TextEditingValue(text: '${c.text}!', selection: TextSelection.collapsed(offset: c.text.length + 1));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('composer-send-or-mic')));
    await t.pumpAndSettle();
    expect(h.sender.actions.last['entities'], [
      {'t': 'bold', 'o': 0, 'l': 4},
    ]);
    expect(h.store.lastEditEntities, '[{"t":"bold","o":0,"l":4}]');

    // Forward (to Saved messages here): the copy keeps the formatting.
    await longPress(t, 'Bold and plain');
    await t.tap(find.byKey(const ValueKey('menu-forward')));
    await t.pumpAndSettle();
    await t.tap(find.text('Boris').last);
    await t.pumpAndSettle();
    expect(h.sender.lastEntities, '[{"t":"bold","o":0,"l":4}]');
  });

  testWidgets('an older app\'s message: its *stars* render bold, the quote of it is plain', (t) async {
    final h = Harness(history: [row('o1', w1, 1, 'see *this* now')]);
    await h.pump(t);
    expect(bubble('see this now'), findsOneWidget, reason: 'markers read, not shown');
    await longPress(t, 'see this now');
    await t.tap(find.byKey(const ValueKey('menu-reply')));
    await t.pumpAndSettle();
    await t.enterText(find.byType(EditableText), 'ok');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('composer-send-or-mic')));
    await t.pumpAndSettle();
    expect(h.sender.sent.single, contains('"snippet":"see this now"'));
  });

  // Owner, 2026-10-18 — after blocking, writing and calling them still worked.
  // ADR-055 — owner, 2026-10-18: "why are there no saved messages?"
  testWidgets('"Save" in the menu copies the message into Saved messages in one tap', (t) async {
    final h = Harness(savedId: kSavedId);
    await h.pump(t);
    await longPress(t, 'Hello there');
    await t.tap(find.byKey(const ValueKey('menu-save')));
    await t.pumpAndSettle();
    expect(h.store.rows.last.chatId, kSavedId);
    expect(h.store.rows.last.body, 'Hello there');
    expect(h.sender.sent.last, startsWith('Hello there|'));
  });

  testWidgets('Saved messages: no calls, no receipts, no typing, no "Save" item', (t) async {
    final h = Harness(savedId: chatId);
    h.store.pending = [w4];
    await h.pump(t);
    expect(find.bySemanticsLabel('Call'), findsNothing);
    expect(find.byKey(const ValueKey('composer-attach')), findsOneWidget, reason: 'anything can be sent there');
    await t.enterText(find.byType(EditableText), 'note to self');
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(h.sender.actions, isEmpty, reason: 'no read receipts or typing to myself');
    await longPress(t, 'Hello there');
    expect(find.byKey(const ValueKey('menu-forward')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-save')), findsNothing, reason: 'already here');
  });

  testWidgets('a chat with someone I blocked: no composer, no call buttons, an Unblock bar', (t) async {
    final h = Harness(blocked: true);
    await h.pump(t);
    expect(find.byKey(const ValueKey('blocked-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('composer-attach')), findsNothing);
    expect(find.bySemanticsLabel('Call'), findsNothing);
    await t.tap(find.byKey(const ValueKey('blocked-unblock')));
    await t.pumpAndSettle();
    expect(h.people.blocked_, isEmpty);
    expect(find.byKey(const ValueKey('blocked-bar')), findsNothing);
    expect(find.byKey(const ValueKey('composer-attach')), findsOneWidget);
  });

  // Owner, 2026-10-18 — "like WhatsApp / Telegram / Signal".
  testWidgets('a lone emoji is big without a bubble; the list runs under the glass header and composer', (t) async {
    final h = Harness(history: [row('e', w2, -60, '🤣'), row('t', w3, -30, 'Text')]);
    await h.pump(t);
    expect(find.byKey(const ValueKey('jumbo-emoji')), findsOneWidget);
    expect(find.byType(DsBlurBar), findsNWidgets(2), reason: 'header and bottom bar are glass');
    final list = t.widget<ListView>(find.byType(ListView).first);
    final pad = list.padding! as EdgeInsets;
    final header = t.getSize(find.byKey(const ValueKey('chat-header')));
    expect(pad.top, greaterThan(header.height), reason: 'messages start below the header, scroll under it');
    expect(pad.bottom, greaterThan(30), reason: 'and above the composer');
  });

  // Owner, 2026-10-18 — a message with a clock can be called back.
  testWidgets('a waiting message of mine: "Cancel sending" removes it and calls a delete after it', (t) async {
    final h = Harness(
      history: [
        row('wait', w2, -60, 'Still waiting', mine: true, status: 0),
        row('done', '$w2-sent', -30, 'Already sent', mine: true, status: 1),
      ],
    );
    await h.pump(t);
    await longPress(t, 'Already sent');
    expect(find.byKey(const ValueKey('menu-cancel-send')), findsNothing, reason: 'sent is sent');
    // A corner of the backdrop: the (taller) menu covers its middle.
    await t.tapAt(t.getTopLeft(find.byKey(const ValueKey('menu-backdrop'))) + const Offset(8, 120));
    await t.pumpAndSettle();

    await longPress(t, 'Still waiting');
    await t.tap(find.byKey(const ValueKey('menu-cancel-send')));
    await t.pumpAndSettle();
    expect(h.store.calls, contains('local wait'));
    expect(h.sender.cancelled, [w2]);
    expect(h.sender.actions.last, {'t': 'delete', 'target': w2}, reason: 'in case it did reach the server');
  });

  // Status 213 — "Info" on my message: sent, delivered, read with times.
  testWidgets('message info: when it was sent, delivered and read', (t) async {
    final h = Harness();
    await h.store.recordReceipts(chatId, [w2], 'peer', read: true, ts: base + 60);
    await h.pump(t);
    await longPress(t, 'Mine, read');
    await t.tap(find.byKey(const ValueKey('menu-info')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-info')), findsOneWidget);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Delivered'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('—'), findsNothing, reason: 'both times are known');
  });

  // Status 211 — a message that didn't go: red "Not sent · Tap to retry"
  // under it; a tap (or "Retry" in its menu) sends it again, same wire id.
  testWidgets('a failed message of mine says so and goes again on a tap', (t) async {
    final h = Harness(history: [row('bad', w2, -60, 'Important', mine: true, status: -1)]);
    await h.pump(t);
    final retry = find.byKey(const ValueKey('retry-$w2'));
    expect(retry, findsOneWidget);
    await t.tap(retry);
    await t.pumpAndSettle();
    expect(h.sender.sent.map((x) => x.split('|').first), ['Important']);
    expect(h.store.calls, contains('status $w2 ${MsgStatus.sending}'));
  });

  testWidgets('attach: in the keyboard\'s place under the composer, + turns ×, the field brings the keyboard back', (t) async {
    final h = Harness();
    await h.pump(t);
    final plus = find.byKey(const ValueKey('composer-attach'));
    final turn = find.descendant(of: plus, matching: find.byType(AnimatedRotation));
    expect(t.widget<AnimatedRotation>(turn).turns, 0);

    await t.tap(find.byType(EditableText));
    await t.pump();
    await t.tap(plus);
    await t.pumpAndSettle();
    final panel = find.byKey(const ValueKey('attach-panel'));
    expect(panel, findsOneWidget);
    expect(t.getTopLeft(panel).dy, greaterThanOrEqualTo(t.getBottomLeft(plus).dy), reason: 'below the composer');
    expect(t.widget<AnimatedRotation>(turn).turns, 0.125, reason: '+ is ×');
    final field = t.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isFalse, reason: 'the keyboard goes; the panel takes its place');

    await t.tap(find.byType(EditableText));
    await t.pumpAndSettle();
    expect(panel, findsNothing, reason: 'typing again closes it');

    await t.tap(plus);
    await t.pumpAndSettle();
    await t.tap(plus);
    await t.pumpAndSettle();
    expect(panel, findsNothing, reason: '× closes it');
    expect(t.widget<AnimatedRotation>(turn).turns, 0);
  });

  testWidgets('video: record with the camera (3 min cap) or choose from the library', (t) async {
    final h = Harness();
    await h.pump(t);
    await t.tap(find.byKey(const ValueKey('composer-attach')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('attach-video')));
    await t.pumpAndSettle();
    await t.tap(find.text('Record video'));
    await t.pumpAndSettle();
    expect(h.videoPicks.single, (true, const Duration(minutes: 3)));

    await t.tap(find.byKey(const ValueKey('composer-attach')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('attach-video')));
    await t.pumpAndSettle();
    await t.tap(find.text('Choose from library'));
    await t.pumpAndSettle();
    expect(h.videoPicks.last, (false, const Duration(minutes: 10)));
    expect(h.sender.sent, isEmpty, reason: 'cancelled picks send nothing');
  });

  testWidgets('after 24 h my message can no longer be edited or deleted for everyone', (t) async {
    final h = Harness(history: [row('old', w2, -2 * 86400, 'Old mine', mine: true, status: 3)]);
    await h.pump(t);
    await longPress(t, 'Old mine');
    expect(find.byKey(const ValueKey('menu-edit')), findsNothing);
    await t.tap(find.byKey(const ValueKey('menu-delete')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-action-Delete for everyone')), findsNothing);
    expect(find.byKey(const ValueKey('sheet-action-Delete for me')), findsOneWidget);
  });

  testWidgets('delete: for everyone only for my messages; for me otherwise', (t) async {
    final h = Harness();
    await h.pump(t);
    await longPress(t, 'Mine, read');
    await t.tap(find.byKey(const ValueKey('menu-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete for everyone')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'delete $w2 me');

    await longPress(t, 'Hello there');
    await t.tap(find.byKey(const ValueKey('menu-delete')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-action-Delete for everyone')), findsNothing);
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete for me')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'local m1');
  });

  testWidgets('selection mode: select, add, cancel', (t) async {
    final h = Harness();
    await h.pump(t);
    await longPress(t, 'Hello there');
    await t.tap(find.byKey(const ValueKey('menu-select')));
    await t.pumpAndSettle();
    expect(text('1 selected'), findsOneWidget);
    // In selection mode the whole row takes the tap.
    await t.tap(bubble('Second unread'), warnIfMissed: false);
    await t.pumpAndSettle();
    expect(text('2 selected'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.checkmark_alt), findsNWidgets(2), reason: 'a check icon, not a ✓ character');
    expect(find.text('✓'), findsNothing);
    await t.tap(find.byKey(const ValueKey('selection-delete')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete for me')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'local m1,m4');
    expect(text('selected'), findsNothing);
  });

  testWidgets('a long message: the bubble scrolls in a box, the whole menu stays on screen', (t) async {
    final long = ['A long letter', for (var i = 1; i < 34; i++) 'line $i of the letter'].join('\n');
    final h = Harness(history: [row('l1', w1, 1, long)]);
    await h.pump(t);

    await t.longPress(bubble('A long letter'));
    await t.pumpAndSettle();
    final box = find.byKey(const ValueKey('menu-bubble-scroll'));
    expect(box, findsOneWidget, reason: 'too tall to fit with the menu: it scrolls');
    for (final id in ['reply', 'copy', 'select-text', 'forward', 'pin', 'select', 'report', 'delete']) {
      final item = find.byKey(ValueKey('menu-$id'));
      expect(item.hitTestable(), findsOneWidget, reason: '$id is reachable');
      final r = t.getRect(item);
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.bottom, lessThanOrEqualTo(844));
    }
    final menuTop = t.getRect(find.byKey(const ValueKey('menu-reply'))).top;
    expect(t.getRect(box).bottom, lessThanOrEqualTo(menuTop), reason: 'the bubble does not run under the menu');

    final position = t.state<ScrollableState>(find.descendant(of: box, matching: find.byType(Scrollable))).position;
    await t.drag(box, const Offset(0, -400));
    await t.pumpAndSettle();
    expect(position.pixels, greaterThan(0), reason: 'the rest of the message can be read');
    expect(find.byKey(const ValueKey('menu-delete')).hitTestable(), findsOneWidget, reason: 'the menu is still open');
  });

  testWidgets('"Select text" opens the words to select from; Copy all copies them', (t) async {
    final h = Harness(history: [
      row('f1', w1, 1, 'Bold and plain', entities: '[{"t":"bold","o":0,"l":4}]'),
    ]);
    await h.pump(t);
    final clip = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await longPress(t, 'Bold and plain');
    await t.tap(find.byKey(const ValueKey('menu-select-text')));
    await t.pumpAndSettle();
    final sheet = find.byKey(const ValueKey('select-text-sheet'));
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.byType(SelectableRegion)), findsOneWidget);
    final words = find.descendant(of: sheet, matching: bubble('Bold and plain'));
    expect(words, findsOneWidget);
    final spans = <TextSpan>[];
    t.widget<RichText>(words).text.visitChildren((c) {
      if (c is TextSpan && c.text != null) spans.add(c);
      return true;
    });
    expect(spans.firstWhere((s) => s.text == 'Bold').style!.fontWeight, FontWeight.w700, reason: 'formatting kept');

    await t.tap(find.byKey(const ValueKey('select-text-copy-all')));
    await t.pumpAndSettle();
    expect(clip, ['Bold and plain']);
    expect(sheet, findsNothing);
    RichClipboard.clear();

    await longPress(t, 'Bold and plain');
    await t.tap(find.byKey(const ValueKey('menu-select-text')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('select-text-close')));
    await t.pumpAndSettle();
    expect(sheet, findsNothing);
  });

  testWidgets('pinned bar shows the message and unpins', (t) async {
    final h = Harness(pinned: w1);
    await h.pump(t);
    expect(find.byKey(const ValueKey('pinned-bar')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('unpin')));
    await t.pumpAndSettle();
    expect(h.store.calls.last, 'pin null');
  });

  testWidgets('typing indicator in the header and the list', (t) async {
    final h = Harness();
    await h.pump(t);
    h.container.read(typingChatsProvider.notifier).set(chatId, true);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('typing…'), findsOneWidget);
    h.container.read(typingChatsProvider.notifier).set(chatId, false);
    await t.pumpAndSettle();
    expect(find.text('typing…'), findsNothing);
  });

  testWidgets('opening the chat sends read receipts; typing goes out while composing', (t) async {
    final h = Harness();
    h.store.pending = [w4];
    await h.pump(t);
    expect(h.sender.actions.first, {'t': 'receipt', 'read': true, 'ids': [w4]});
    await t.enterText(find.byType(EditableText), 'hi');
    // The typing switch is read from settings first (async).
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(h.sender.actions.last, {'t': 'typing', 'active': true});
    expect(h.sender.badWireIds, isEmpty, reason: 'every action gets a v7 wire id');
    expect(h.container.read(openChatProvider), chatId);
  });

  testWidgets('@mentions: real members in the picker, a token on the wire, names in bubbles', (t) async {
    final h = Harness(group: true, history: [row('m9', w1, 1, 'привет ${mentionOf(kMe)} и ${mentionOf(kBoris)}')]);
    await h.pump(t);
    expect(text('@вы'), findsNothing);
    expect(text('@You'), findsOneWidget, reason: 'me, in the reader\'s language');
    expect(text('@Борис'), findsOneWidget);

    await t.enterText(find.byType(EditableText), '@А');
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('mention-$kAnya')), findsOneWidget);
    expect(find.byKey(ValueKey('mention-$kBoris')), findsNothing, reason: 'filtered by the query');
    expect(find.byKey(ValueKey('mention-$kMe')), findsNothing, reason: 'not myself');
    await t.tap(find.byKey(ValueKey('mention-$kAnya')));
    await t.pumpAndSettle();
    expect(find.text('@Аня '), findsWidgets);
    await t.enterText(find.byType(EditableText), '@Аня как дела?');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('composer-send-or-mic')));
    await t.pumpAndSettle();
    expect(h.sender.sent.last, startsWith('${mentionOf(kAnya)} как дела?'));
  });

  // ADR-035 — a group that removed me stays readable, without a composer.
  testWidgets('removed from a group: history stays, no composer, delete offered', (t) async {
    final h = Harness(group: true, member: false);
    await h.pump(t);
    expect(find.byKey(const ValueKey('not-member-bar')), findsOneWidget);
    expect(find.byType(EditableText), findsNothing);
    expect(find.text('Hello there'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('not-member-delete')));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete chat').last); // asks first
    await t.pumpAndSettle();
    expect(h.chats.calls, contains('delete $chatId'));
  });

  testWidgets('message request: no read receipts, typing or name until accepted', (t) async {
    final h = Harness(request: true);
    h.store.pending = [w4];
    await h.pump(t);
    expect(find.byKey(const ValueKey('request-bar')), findsOneWidget);
    expect(find.text('Message request'), findsOneWidget);
    expect(find.byType(EditableText), findsNothing, reason: 'no composer until accepted');
    expect(h.sender.actions.where((a) => a['read'] == true), isEmpty, reason: 'no read receipts to a stranger');

    await t.tap(find.byKey(const ValueKey('request-accept')));
    await t.pumpAndSettle();
    expect(h.chats.calls, contains('request $chatId false'));
    expect(find.byKey(const ValueKey('request-bar')), findsNothing);
    expect(find.byType(EditableText), findsOneWidget);
    expect(h.sender.actions.last, {'t': 'receipt', 'read': true, 'ids': [w4]});
  });

  testWidgets('message request: delete asks first, then drops the chat', (t) async {
    final h = Harness(request: true);
    await h.pump(t);
    await t.tap(find.byKey(const ValueKey('request-delete')));
    await t.pumpAndSettle();
    expect(h.chats.calls, isNot(contains('delete $chatId')), reason: 'asks first (2026-10-16 UI audit)');
    await t.tap(find.text('Delete chat').last);
    await t.pumpAndSettle();
    expect(h.chats.calls, contains('delete $chatId'));
  });

  testWidgets('disappearing: system line, ⏱ on the message, timer in the header', (t) async {
    final h = Harness(disappear: 86400);
    await h.pump(t);
    expect(find.byKey(const ValueKey('system-line')), findsOneWidget);
    expect(find.text('Messages now disappear after 1 day'), findsOneWidget);
    expect(find.byKey(const ValueKey('meta-expiring')), findsOneWidget);
    expect(t.widget(find.byKey(const ValueKey('meta-expiring'))), isA<Icon>(), reason: 'an icon, not ⏱');
    expect(find.byKey(const ValueKey('header-timer')), findsOneWidget);
    expect(find.textContaining('⏱'), findsNothing);
  });
}
