// Smoothness (jank-09): "typing" or presence for ONE chat rebuilds only that
// chat's row — not every visible row (heartbeats come every 25 s per contact).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart' show typingChatsProvider;
import 'package:sinhron/core/providers/presence.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/widgets/ds_motion.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

const ids = ['a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2', 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3'];
const peers = ['aa', 'bb', 'cc'];

/// The row widgets now on screen; a row whose widget object is the same as
/// before was not rebuilt by the list.
List<Widget> rows(WidgetTester t) => [for (final id in ids) t.widget(find.byKey(ValueKey('chat-$id')))];

int rebuilt(List<Widget> before, List<Widget> after) => [
  for (var i = 0; i < before.length; i++)
    if (!identical(before[i], after[i])) i,
].length;

void main() {
  setUp(DsAppear.resetRowsPlayed);

  testWidgets('typing / presence for one chat rebuilds only its row', (t) async {
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        chatsProvider.overrideWith(
          (ref) async => [
            for (var i = 0; i < 3; i++) ChatPreview(id: ids[i], name: 'Chat $i', preview: 'hi', time: '', peerId: peers[i]),
          ],
        ),
      ],
    );
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: MediaQueryData(size: Size(390, 844)),
            child: Directionality(textDirection: TextDirection.ltr, child: ChatListScreen()),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // Typing in the second chat.
    var before = rows(t);
    container.read(typingChatsProvider.notifier).set(ids[1], true);
    await t.pump();
    var after = rows(t);
    debugPrint('typing on: rows rebuilt ${rebuilt(before, after)} of 3');
    expect(rebuilt(before, after), 1);
    expect(identical(before[1], after[1]), isFalse);
    expect(find.text('typing…'), findsOneWidget);

    // The first chat's contact comes online.
    final now = DateTime.now();
    before = after;
    container.read(peerPresenceProvider.notifier).apply(peers[0], online: true, hidden: false, at: now);
    await t.pump();
    after = rows(t);
    debugPrint('came online: rows rebuilt ${rebuilt(before, after)} of 3');
    expect(rebuilt(before, after), 1);
    expect(identical(before[0], after[0]), isFalse);

    // Its next heartbeat: still online, nothing to redraw.
    before = after;
    container.read(peerPresenceProvider.notifier).apply(peers[0], online: true, hidden: false, at: now, now: now);
    await t.pump();
    after = rows(t);
    debugPrint('heartbeat: rows rebuilt ${rebuilt(before, after)} of 3');
    expect(rebuilt(before, after), 0);

    container.read(typingChatsProvider.notifier).set(ids[1], false);
    await t.pumpWidget(const SizedBox());
    container.dispose();
  });
}
