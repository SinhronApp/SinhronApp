// jank-06: a burst of "chat changed" bumps (catch-up after coming back
// online) must not re-read the open chat once per message.
// Measured: 10 bumps while a read is in flight — before 10 reads, after 2.
//
// jank-05 (slice): a repeated "typing" ping while somebody already types
// (here or in another chat) must not rebuild the open chat's bubbles.
// Measured: bubbles rebuilt per ping — before 5 of 5, after 0 of 5.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import 'chat_view_actions_test.dart' show Harness, chatId, kAnya, kBoris;

core.StoredMessageSummary _msg(int n) => core.StoredMessageSummary(
      id: 'm$n',
      chatId: 'c1',
      tsUnix: 1700000000 + n,
      body: 'msg $n',
      kind: 'text',
      isMine: false,
      status: 1,
      deleted: false,
    );

void main() {
  test('burst of chat revisions: reads 10 -> 2, last message shown', () async {
    final stored = <core.StoredMessageSummary>[_msg(0)];
    var reads = 0;
    Completer<void>? gate;
    final container = ProviderContainer(overrides: [
      messagePageFetcherProvider.overrideWithValue(
        (chatId, {beforeTs, beforeId, required limit}) async {
          reads++;
          final snapshot = [...stored];
          await gate?.future;
          return snapshot;
        },
      ),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(chatMessagesProvider('c1'), (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(reads, 1);
    expect(container.read(chatMessagesProvider('c1')).messages.length, 1);

    // Reads are slow from here on; 10 messages land one after another.
    reads = 0;
    gate = Completer<void>();
    for (var n = 1; n <= 10; n++) {
      stored.add(_msg(n));
      container.read(chatRevisionProvider('c1').notifier).bump();
      await pumpEventQueue(times: 2);
    }
    gate.complete();
    await pumpEventQueue();

    // ignore: avoid_print
    print('jank-06 burst of 10: reads = $reads');
    expect(reads, lessThanOrEqualTo(2));
    final s = container.read(chatMessagesProvider('c1'));
    expect(s.messages.length, 11);
    expect(s.messages.last.id, 'm10');
    expect(s.loading, false);
  });

  testWidgets('repeated typing ping: bubbles rebuilt 5 of 5 -> 0 of 5', (t) async {
    final h = Harness();
    await h.pump(t);
    await t.pumpAndSettle();
    const ids = ['m1', 'm2', 'm3', 'm4', 'm5'];
    List<Widget> bubbles() => [for (final id in ids) t.widget(find.byKey(ValueKey<String>('m:$id')))];
    int rebuilt(List<Widget> a, List<Widget> b) => [
      for (var i = 0; i < a.length; i++)
        if (!identical(a[i], b[i])) i,
    ].length;

    final typing = h.container.read(typingPeopleProvider.notifier);
    typing.set(chatId, kAnya, true);
    await t.pump();

    // The same person keeps typing: the next ping changes nothing on screen.
    var before = bubbles();
    typing.set(chatId, kAnya, true);
    await t.pump();
    var after = bubbles();
    debugPrint('jank-05 typing ping, same chat: bubbles rebuilt ${rebuilt(before, after)} of 5');
    expect(rebuilt(before, after), 0);

    // Somebody types in another chat meanwhile.
    before = after;
    typing.set('b1b2c3d4e5f60718293a4b5c6d7e8f9012345678', kBoris, true);
    await t.pump();
    after = bubbles();
    debugPrint('jank-05 typing ping, other chat: bubbles rebuilt ${rebuilt(before, after)} of 5');
    expect(rebuilt(before, after), 0);

    // Not stale: a second person starting to type here still shows.
    before = after;
    typing.set(chatId, kBoris, true);
    await t.pump();
    expect(rebuilt(before, bubbles()), 5);

    // Let the typing sweep timer run out.
    await t.pump(TypingChats.ttl + const Duration(seconds: 1));
    await t.pump(TypingChats.ttl + const Duration(seconds: 1));
  });
}
