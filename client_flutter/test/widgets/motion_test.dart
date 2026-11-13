import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/motion.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/widgets/ds_action_sheet.dart';
import 'package:sinhron/widgets/ds_count_badge.dart';
import 'package:sinhron/widgets/ds_page_route.dart';
import 'package:sinhron/widgets/ds_pressable.dart';

Widget app(Widget child, {bool reduceMotion = false}) => DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
        ),
      ),
    );

double scaleOf(WidgetTester t) => t.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

void main() {
  test('spring curve settles at 1 and overshoots on the way', () {
    final c = DsMotion.springy;
    expect(c.transform(0), 0);
    expect(c.transform(1), 1);
    final peak = [for (var i = 1; i < 100; i++) c.transform(i / 100)].reduce((a, b) => a > b ? a : b);
    expect(peak, greaterThan(1.0), reason: 'bouncy spring overshoots');
  });

  testWidgets('pressable shrinks while held, springs back, then taps', (t) async {
    var taps = 0;
    await t.pumpWidget(app(Center(child: DsPressable(onTap: () => taps++, child: const SizedBox(width: 80, height: 40)))));
    final g = await t.startGesture(t.getCenter(find.byType(DsPressable)));
    await t.pump();
    expect(scaleOf(t), lessThan(1));
    await g.up();
    await t.pumpAndSettle();
    expect(scaleOf(t), 1);
    expect(taps, 1);
  });

  testWidgets('Reduce Motion: no shrink on press', (t) async {
    await t.pumpWidget(app(
      Center(child: DsPressable(onTap: () {}, child: const SizedBox(width: 80, height: 40))),
      reduceMotion: true,
    ));
    final g = await t.startGesture(t.getCenter(find.byType(DsPressable)));
    await t.pump();
    expect(scaleOf(t), 1);
    await g.up();
  });

  testWidgets('animated count shows the new number and caps at 99+', (t) async {
    // No Navigator here: its first route would keep the first child.
    Widget count(int n) => Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: DsAnimatedCount(count: n, style: const TextStyle(fontSize: 12))),
        );
    await t.pumpWidget(count(3));
    expect(find.text('3'), findsOneWidget);
    await t.pumpWidget(count(4));
    await t.pumpAndSettle();
    expect(find.text('4'), findsOneWidget);
    expect(find.text('3'), findsNothing);
    await t.pumpWidget(count(150));
    await t.pumpAndSettle();
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('page route crossfades under Reduce Motion', (t) async {
    late BuildContext ctx;
    await t.pumpWidget(app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    }), reduceMotion: true));
    Navigator.of(ctx).push(DsPageRoute<void>(builder: (_) => const Text('next')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(
      find.ancestor(of: find.text('next'), matching: find.byType(FadeTransition)),
      findsWidgets,
    );
    await t.pumpAndSettle();
    expect(find.text('next'), findsOneWidget);
  });

  testWidgets('action sheet: drag down to dismiss, small drag springs back', (t) async {
    late BuildContext ctx;
    String? picked = 'unset';
    await t.pumpWidget(app(Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    Future<void> open() async {
      showDsActionSheet<String>(ctx, actions: const [DsSheetAction('Archive', 'a')]).then((v) => picked = v);
      await t.pumpAndSettle();
    }

    await open();
    await t.drag(find.byKey(const ValueKey('sheet-action-Archive')), const Offset(0, 40));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-action-Archive')), findsOneWidget, reason: 'springs back');
    await t.drag(find.byKey(const ValueKey('sheet-action-Archive')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-action-Archive')), findsNothing);
    expect(picked, isNull, reason: 'dismissed without a choice');
  });
}
