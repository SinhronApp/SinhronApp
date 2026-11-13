// New chat → "Paste address" opens a sheet (owner, 2026-10-20: the inline
// field pushed the whole list down).

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/compose/compose_screen.dart';
import 'package:sinhron/features/compose/paste_key_sheet.dart';
import 'package:sinhron/l10n/l10n.dart';

void main() {
  final key = 'ab' * 32;

  test('a bare address (spaces fine) or a contact link gives the key; anything else nothing', () {
    expect(pastedKey(key), key);
    expect(pastedKey(' ${key.substring(0, 32)} ${key.substring(32)} '), key);
    expect(pastedKey('sinhron-contact:$key@chat.example.com?n=Anya'), key);
    expect(pastedKey(key.substring(1)), isNull);
    expect(pastedKey('hello'), isNull);
  });

  testWidgets('the sheet takes the address and starts the chat; the list never moves', (t) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final started = <String>[];
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
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (_, _, _) =>
                      ComposeScreen(contacts: const [], onInviteByIdentity: (hex) async => started.add(hex)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final footer = find.textContaining('Contacts');
    final before = footer.evaluate().isEmpty ? null : t.getTopLeft(footer.first);

    await t.tap(find.text('Paste address'));
    await t.pumpAndSettle();
    expect(find.text('Start encrypted chat'), findsOneWidget);
    if (before != null) expect(t.getTopLeft(footer.first), before, reason: 'nothing under it slid down');

    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('paste-key-field')), matching: find.byType(EditableText)),
      key.substring(0, 10),
    );
    await t.pump();
    expect(find.text('10 of 64 characters'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('paste-key-start')));
    await t.pumpAndSettle();
    expect(started, isEmpty, reason: 'not a whole address yet');

    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('paste-key-field')), matching: find.byType(EditableText)),
      key,
    );
    await t.pump();
    expect(find.text('Address looks right'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('paste-key-start')));
    await t.pumpAndSettle();
    expect(started, [key]);
    expect(find.text('Start encrypted chat'), findsNothing, reason: 'the sheet closed');
  });
}
