import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';

import '../../core/chat_messages_test.dart' show FakeHistory;

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

Widget host(FakeHistory h, {String? openAt}) => ProviderScope(
      overrides: [messagePageFetcherProvider.overrideWithValue(h.fetch)],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ChatViewScreen(chatId: chatId, contactName: 'Maria', openAtWireId: openAt),
          ),
        ),
      ),
    );

int builtMessages(WidgetTester t) => find
    .byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('m:'))
    .evaluate()
    .length;

void main() {
  testWidgets('5000-message chat builds only visible bubbles and opens at the newest', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final h = FakeHistory(5000);
    await t.pumpWidget(host(h));
    await t.pumpAndSettle();

    expect(find.textContaining('message 4999', findRichText: true), findsOneWidget, reason: 'opens at the newest message');
    expect(find.textContaining(RegExp(r'^message 0$'), findRichText: true), findsNothing);
    final built = builtMessages(t);
    expect(built, greaterThan(5));
    expect(built, lessThan(40), reason: 'lazy list: only what fits (+cache), not 5000');
    expect(h.calls, ['newest'], reason: 'only the newest page is read on open');
  });

  testWidgets('scrolling up loads the next older page', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final h = FakeHistory(5000);
    await t.pumpWidget(host(h));
    await t.pumpAndSettle();

    // Reversed list: dragging down scrolls toward older messages.
    for (var i = 0; i < 6 && h.calls.length < 2; i++) {
      await t.drag(find.byKey(const ValueKey('message-list')), const Offset(0, 900));
      await t.pumpAndSettle();
    }
    expect(h.calls.length, greaterThanOrEqualTo(2));
    expect(h.calls[1], 'm04950', reason: 'cursor = oldest loaded message');
    expect(builtMessages(t), lessThan(40));
  });

  testWidgets('opened from search: older pages load and the found message is shown and tinted', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final h = FakeHistory(5000);
    await t.pumpWidget(host(h, openAt: 'w4000'));
    await t.pump();
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 16)); // one frame per walk step
    }
    await t.pumpAndSettle();
    expect(h.calls.length, greaterThan(15), reason: '~20 older pages to reach message 4000');
    final hit = find.textContaining('message 4000', findRichText: true);
    expect(hit, findsOneWidget);
    final tint = t.widget<AnimatedContainer>(find.ancestor(of: hit, matching: find.byType(AnimatedContainer)).first);
    expect((tint.decoration as BoxDecoration?)?.color?.a ?? 0, greaterThan(0), reason: 'found message is tinted');
    expect(builtMessages(t), lessThan(60), reason: 'still a lazy list');
    await t.pump(const Duration(seconds: 2)); // tint fades
  });
}
