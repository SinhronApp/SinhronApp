// Tech-debt 2.21 — drag to reorder pinned chats and folders.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/chat_list/reorder_screen.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

void main() {
  testWidgets('dragging a row by its handle saves the new order', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final saved = <List<String>>[];
    await t.pumpWidget(
      ProviderScope(
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Localizations(
              locale: const Locale('en'),
              delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) => ReorderScreen(
                    title: 'Pinned chats',
                    items: const [ReorderItem('a', 'Anna'), ReorderItem('b', 'Boris'), ReorderItem('c', 'Chloe')],
                    onReorder: (ids) async => saved.add(ids),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Hold a row and drag it to change the order.'), findsOneWidget);

    // Anna's handle, dragged below Boris (rows are 56 px).
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('reorder-handle-0'))));
    await t.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(0, 9));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();
    expect(saved, [
      ['b', 'a', 'c'],
    ]);
    expect(t.getTopLeft(find.text('Boris')).dy, lessThan(t.getTopLeft(find.text('Anna')).dy));

    // Long-press anywhere on a row works too: Chloe to the top.
    final g2 = await t.startGesture(t.getCenter(find.text('Chloe')));
    await t.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 16; i++) {
      await g2.moveBy(const Offset(0, -9));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g2.up();
    await t.pumpAndSettle();
    expect(saved.last, ['c', 'b', 'a']);
  });
}
