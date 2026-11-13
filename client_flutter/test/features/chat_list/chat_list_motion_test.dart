// Chat list motion (owner, 2026-10-18): rows rise in when the list opens,
// a chat pinned to the top glides there, the others glide down — and with
// Reduce Motion nothing moves at all.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';
import 'package:sinhron/widgets/ds_motion.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

const a = 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
const b = 'b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2';
const c = 'c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3';

ChatPreview chat(String id, String name, {bool pinned = false}) =>
    ChatPreview(id: id, name: name, preview: 'hi', time: '', pinned: pinned);

class Harness {
  var chats = [chat(a, 'Anna'), chat(b, 'Boris'), chat(c, 'Clara')];
  late final container = ProviderContainer(
    overrides: [
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      chatsProvider.overrideWith((ref) async => chats),
    ],
  );

  Future<void> pump(WidgetTester t, {bool reduceMotion = false}) async {
    addTearDown(container.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduceMotion),
            child: const Directionality(textDirection: TextDirection.ltr, child: ChatListScreen()),
          ),
        ),
      ),
    );
  }

  /// New chats arrive (the provider reloads); one frame — the reorder frame.
  Future<void> reorder(WidgetTester t, List<ChatPreview> next) async {
    chats = next;
    container.invalidate(chatsProvider);
    // The reload lands a few microtask hops later; stop at the frame that
    // shows it.
    for (var i = 0; i < 10 && !identical(container.read(chatsProvider).value, next); i++) {
      await t.pump();
    }
  }
}

double y(WidgetTester t, String id) => t.getTopLeft(find.byKey(ValueKey('chat-$id'))).dy;

/// The entrance fades of the chat rows.
List<double> rowFades(WidgetTester t) => [
  for (final id in [a, b, c])
    t
        .widget<FadeTransition>(
          find.descendant(
            of: find.ancestor(of: find.byKey(ValueKey('chat-$id')), matching: find.byType(DsAppear)),
            matching: find.byType(FadeTransition),
          ).first,
        )
        .opacity
        .value,
];

void main() {
  testWidgets('rows rise in; a pinned chat glides to the top, the others glide down', (t) async {
    final h = Harness();
    await h.pump(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 40));
    expect(rowFades(t).first, lessThan(1), reason: 'rows are fading in');
    await t.pumpAndSettle();
    expect(rowFades(t), [1, 1, 1]);
    final (ya, yc) = (y(t, a), y(t, c));
    expect(ya, lessThan(yc));

    await h.reorder(t, [chat(c, 'Clara', pinned: true), chat(a, 'Anna'), chat(b, 'Boris')]);
    expect((y(t, a), y(t, c)), (ya, yc), reason: 'the reorder frame still paints the old places');
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(y(t, c), inExclusiveRange(ya, yc), reason: 'Clara on her way up');
    await t.pumpAndSettle();
    expect(y(t, c), ya, reason: 'Clara on top');
    expect(y(t, a), greaterThan(ya));
  });

  testWidgets('Reduce Motion: rows are just there, a reorder just happens', (t) async {
    final h = Harness();
    await h.pump(t, reduceMotion: true);
    await t.pump();
    await t.pump();
    expect(rowFades(t), [1, 1, 1], reason: 'no entrance');
    final ya = y(t, a);

    await h.reorder(t, [chat(c, 'Clara', pinned: true), chat(a, 'Anna'), chat(b, 'Boris')]);
    expect(y(t, c), ya, reason: 'already on top in the same frame');
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'no animation running');
  });
}
