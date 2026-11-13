import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/compose/compose_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

void main() {
  testWidgets('New chat shows "online" only from real presence — never by default', (t) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 1000)),
          child: Localizations(
            locale: const Locale('en'),
            delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: ComposeScreen(
                onCancel: () {},
                contacts: [
                  ComposeContact(chatId: 'c1', name: 'Milena', key: 'b4067c14${'0' * 56}'),
                  ComposeContact(
                    chatId: 'c2',
                    name: 'Sashka',
                    key: '598115fd${'0' * 56}',
                    status: 'online',
                    online: true,
                  ),
                  ComposeContact(chatId: 'c3', name: 'MacBook', key: '56844611${'0' * 56}', status: 'last seen 5 minutes ago'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('b406 7c14'), findsOneWidget, reason: 'nothing known: just the key');
    expect(find.text('5981 15fd · online'), findsOneWidget);
    expect(find.text('5684 4611 · last seen 5 minutes ago'), findsOneWidget);
    expect(find.textContaining('online'), findsOneWidget);
  });
}
