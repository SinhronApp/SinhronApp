// Tech-debt 2.20 — a burst of incoming messages re-reads the chat list a
// few times, not once per message.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';

void main() {
  test('first change refreshes at once; a burst folds into one re-read', () async {
    var reads = 0;
    final c = ProviderContainer(
      overrides: [
        chatsProvider.overrideWith((ref) async {
          reads++;
          return const <ChatPreview>[];
        }),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(chatsProvider, (_, _) {});
    addTearDown(sub.close);
    await c.read(chatsProvider.future);
    expect(reads, 1);

    final r = c.read(chatsRefresherProvider);
    r.schedule();
    await c.read(chatsProvider.future);
    expect(reads, 2, reason: 'a single message shows up immediately');

    for (var i = 0; i < 200; i++) {
      r.schedule(); // the first starts a read; the rest arrive while it's in flight
    }
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await c.read(chatsProvider.future);
    expect(reads, 4, reason: '200 messages → the read they started + one re-read, not 200');

    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(reads, 4, reason: 'quiet afterwards');
  });
}
