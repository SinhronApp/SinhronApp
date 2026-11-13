// Blur budget (audit jank-01/02/04): blur only under the tab bar on
// iPhone / iPad. Sheets, the message menu, notices and plain bars: none.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/features/chat_view/message_menu.dart';
import 'package:sinhron/widgets/app_notice_host.dart';
import 'package:sinhron/widgets/ds_action_sheet.dart';
import 'package:sinhron/widgets/ds_blur_bar.dart';
import 'package:sinhron/widgets/ds_icon.dart';
import 'package:sinhron/widgets/ds_tab_bar.dart';

void main() {
  setUp(() => DsHaptics.enabled = false);

  Widget app(Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(390, 800)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
      ),
    ),
  );

  final blur = find.byType(BackdropFilter);

  testWidgets('an action sheet has no blur, opening or open', (t) async {
    await t.pumpWidget(app(const SizedBox.expand()));
    final ctx = t.element(find.byType(SizedBox).first);
    showDsActionSheet<int>(ctx, title: 'Title', actions: const [DsSheetAction('One', 1)]);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('sheet-backdrop')), findsOneWidget);
    expect(blur, findsNothing, reason: 'mid-transition');
    await t.pumpAndSettle();
    expect(find.text('One'), findsOneWidget);
    expect(blur, findsNothing);
  });

  testWidgets('the message menu has no blur, opening or open', (t) async {
    await t.pumpWidget(app(const SizedBox.expand()));
    final ctx = t.element(find.byType(SizedBox).first);
    showMessageMenu(
      ctx,
      origin: const Rect.fromLTWH(100, 300, 200, 40),
      bubble: const SizedBox(width: 200, height: 40),
      alignRight: true,
      items: const [MessageMenuItem('copy', 'Copy')],
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('menu-backdrop')), findsOneWidget);
    expect(blur, findsNothing, reason: 'mid-transition');
    await t.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(blur, findsNothing);
  });

  testWidgets('a notice has no blur', (t) async {
    addTearDown(() => appNotice.value = '');
    await t.pumpWidget(app(const AppNoticeHost()));
    showDone('Key copied');
    await t.pump();
    expect(find.text('Key copied'), findsOneWidget);
    expect(blur, findsNothing);
    await t.pump(noticeDuration(NoticeTone.done));
    await t.pumpAndSettle();
  });

  group('tab bar', () {
    const bar = DsTabBar(
      active: DsTabId.chats,
      items: [DsTabItem(id: DsTabId.chats, label: 'Chats', icon: DsIconShape.search)],
    );

    testWidgets('iPhone / iPad: exactly one blur', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await t.pumpWidget(app(const Align(alignment: Alignment.bottomCenter, child: bar)));
      expect(blur, findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Android: solid, no blur', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await t.pumpWidget(app(const Align(alignment: Alignment.bottomCenter, child: bar)));
      expect(blur, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('iPhone with high contrast: solid', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await t.pumpWidget(
        app(const MediaQuery(data: MediaQueryData(size: Size(390, 800), highContrast: true), child: bar)),
      );
      expect(blur, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('a plain DsBlurBar (chat header, composer) is solid on every platform', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(app(const Align(child: DsBlurBar(child: SizedBox(width: 100, height: 44)))));
    expect(blur, findsNothing);
    final box = t.widget<DecoratedBox>(find.descendant(of: find.byType(DsBlurBar), matching: find.byType(DecoratedBox)));
    expect((box.decoration as BoxDecoration).color, DsTokens.light.bg);
    debugDefaultTargetPlatformOverride = null;
  });
}
