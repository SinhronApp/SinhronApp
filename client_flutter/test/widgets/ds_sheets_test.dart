// Every sheet looks the same (owner, 2026-11-03): a rounded card over a
// blur — at the bottom of a phone with a grabber, a centred card of at
// most ~480 on an iPad.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/forward_sheet.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';
import 'package:sinhron/widgets/ds_action_sheet.dart';
import 'package:sinhron/widgets/ds_name_sheet.dart';
import 'package:sinhron/widgets/ds_picker_sheet.dart';

const phone = Size(390, 844);
const ipad = Size(1024, 1366);

late BuildContext ctx;

Future<void> pump(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    Localizations(
      locale: const Locale('en'),
      delegates: AppL10n.localizationsDelegates,
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: size),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder(
                pageBuilder: (c, _, _) {
                  ctx = c;
                  return const SizedBox.expand();
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('action sheet: on a phone at the bottom with a grabber; Cancel closes', (t) async {
    await pump(t, phone);
    final picked = showDsActionSheet<int>(ctx, title: 'Delete it?', actions: [const DsSheetAction('Delete', 1, destructive: true)]);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-grabber')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-popup')), findsNothing);
    expect(t.getRect(find.byKey(const ValueKey('sheet-cancel'))).bottom, greaterThan(phone.height - 80));
    await t.tap(find.byKey(const ValueKey('sheet-cancel')));
    await t.pumpAndSettle();
    expect(await picked, isNull);
  });

  testWidgets('action sheet, picker, forward and name sheets: centred cards on an iPad', (t) async {
    await pump(t, ipad);
    void centred(String what) {
      final r = t.getRect(find.byKey(const ValueKey('sheet-popup')));
      expect(r.width, lessThanOrEqualTo(480), reason: what);
      expect(r.center.dx, closeTo(ipad.width / 2, 1), reason: what);
      expect(r.center.dy, closeTo(ipad.height / 2, 1), reason: what);
      expect(find.byKey(const ValueKey('sheet-grabber')), findsNothing, reason: '$what: no grabber on a popup');
    }

    final action = showDsActionSheet<int>(ctx, actions: [const DsSheetAction('Mute', 1)]);
    await t.pumpAndSettle();
    centred('action sheet');
    await t.tap(find.byKey(const ValueKey('sheet-action-Mute')));
    await t.pumpAndSettle();
    expect(await action, 1);

    final pick = showDsPickerSheet(context: ctx, title: 'Last seen', options: const ['Everyone', 'Nobody'], current: 'Everyone');
    await t.pumpAndSettle();
    centred('picker');
    await t.tap(find.text('Nobody'));
    await t.pumpAndSettle();
    expect(await pick, 'Nobody');

    final fwd = showForwardSheet(ctx, const [ChatPreview(id: 'b', name: 'Boris', preview: '', time: '')]);
    await t.pumpAndSettle();
    centred('forward');
    await t.tap(find.byKey(const ValueKey('forward-b')));
    await t.pumpAndSettle();
    expect((await fwd)?.id, 'b');

    final name = showNameSheet(ctx, current: 'Vera');
    await t.pumpAndSettle();
    final card = find.descendant(of: find.byKey(const ValueKey('name-sheet')), matching: find.byType(DecoratedBox)).first;
    expect(t.getSize(card).width, lessThanOrEqualTo(480));
    await t.tapAt(const Offset(20, 20)); // outside: closes
    await t.pumpAndSettle();
    expect(await name, isNull);
  });
}
