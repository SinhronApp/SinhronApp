// The small motion blocks (lib/widgets/ds_motion.dart): each one moves
// with motion on and does nothing at all under Reduce Motion.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/motion.dart';
import 'package:sinhron/widgets/ds_motion.dart';

Widget host(Widget child, {bool reduceMotion = false}) => MediaQuery(
  data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduceMotion),
  child: Directionality(textDirection: TextDirection.ltr, child: child),
);

const box = SizedBox(key: ValueKey('box'), width: 40, height: 40);

/// Fade layers between [of] and the box.
Iterable<FadeTransition> fades(WidgetTester t, Type of) => t.widgetList<FadeTransition>(
  find.descendant(of: find.byType(of), matching: find.byType(FadeTransition)),
);

void main() {
  testWidgets('DsAppear fades and rises in, then leaves the child bare', (t) async {
    await t.pumpWidget(host(const Center(child: DsAppear(child: box))));
    expect(fades(t, DsAppear).single.opacity.value, 0);
    final start = t.getTopLeft(find.byKey(const ValueKey('box'))).dy;
    await t.pump(const Duration(milliseconds: 100));
    final mid = fades(t, DsAppear).single.opacity.value;
    expect(mid, inExclusiveRange(0, 1));
    await t.pumpAndSettle();
    expect(fades(t, DsAppear).single.opacity.value, 1, reason: 'fully there at rest');
    expect(t.getTopLeft(find.byKey(const ValueKey('box'))).dy, lessThan(start), reason: 'it rose');
  });

  testWidgets('DsAppear: rows arrive together (no stagger), within DsMotion.base', (t) async {
    await t.pumpWidget(host(const Column(children: [DsAppear(index: 0, child: box), DsAppear(index: 7, child: box)])));
    await t.pump(const Duration(milliseconds: 60));
    final list = t.widgetList<FadeTransition>(find.byType(FadeTransition)).toList();
    expect(list[0].opacity.value, inExclusiveRange(0, 1));
    expect(list[1].opacity.value, list[0].opacity.value, reason: 'no row waits for another');
    await t.pump(DsMotion.base);
    expect(t.widgetList<FadeTransition>(find.byType(FadeTransition)).map((f) => f.opacity.value), [1, 1]);
  });

  testWidgets('list rows play once per app launch', (t) async {
    DsAppear.resetRowsPlayed();
    addTearDown(DsAppear.resetRowsPlayed);
    Widget list(String k) => host(DsAppearScope(key: ValueKey(k), child: Column(children: dsStaggered(const [box]))));
    await t.pumpWidget(list('first'));
    expect(fades(t, DsAppear).single.opacity.value, 0, reason: 'the first list fades in');
    await t.pumpAndSettle();
    await t.pumpWidget(list('again'));
    expect(fades(t, DsAppear).single.opacity.value, 1, reason: 'a later list is simply there');
  });

  testWidgets('DsPopIn springs in', (t) async {
    await t.pumpWidget(host(const Center(child: DsPopIn(child: box))));
    double scale() => t.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value;
    expect(scale(), closeTo(0.6, 0.001));
    await t.pump(const Duration(milliseconds: 80));
    expect(scale(), inExclusiveRange(0.6, 1.2));
    await t.pumpAndSettle();
    expect(scale(), 1);
  });

  testWidgets('DsFadeSwitcher crossfades a new child', (t) async {
    Widget sw(String s) => host(DsFadeSwitcher(rise: 6, child: Text(s, key: ValueKey(s))));
    await t.pumpWidget(sw('a'));
    await t.pumpWidget(sw('b'));
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('a'), findsOneWidget, reason: 'the old one fades out');
    expect(find.text('b'), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.text('a'), findsNothing);
  });

  group('Reduce Motion: nothing moves', () {
    testWidgets('DsAppear', (t) async {
      await t.pumpWidget(host(const Center(child: DsAppear(index: 5, child: box)), reduceMotion: true));
      expect(t.widget<FadeTransition>(find.byType(FadeTransition)).opacity.value, 1);
      expect(t.getTopLeft(find.byKey(const ValueKey('box'))), const Offset(380, 280), reason: 'already in place');
    });

    testWidgets('DsPopIn', (t) async {
      await t.pumpWidget(host(const Center(child: DsPopIn(child: box)), reduceMotion: true));
      expect(t.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value, 1);
    });

    testWidgets('DsFadeSwitcher swaps at once', (t) async {
      Widget sw(String s) => host(DsFadeSwitcher(child: Text(s, key: ValueKey(s))), reduceMotion: true);
      await t.pumpWidget(sw('a'));
      await t.pumpWidget(sw('b'));
      await t.pump();
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsOneWidget);
    });
  });

  group('DsReorderSlide', () {
    Widget list(List<String> ids, {bool reduceMotion = false}) => host(
      ListView.builder(
        itemCount: ids.length,
        findChildIndexCallback: (key) {
          final i = ids.indexOf((key as ValueKey<String>).value);
          return i < 0 ? null : i;
        },
        itemBuilder: (_, i) => DsReorderSlide(
          key: ValueKey(ids[i]),
          child: SizedBox(height: 50, child: Text(ids[i])),
        ),
      ),
      reduceMotion: reduceMotion,
    );

    double y(WidgetTester t, String id) => t.getTopLeft(find.text(id)).dy;

    testWidgets('a row pinned to the top glides there; the others glide down', (t) async {
      await t.pumpWidget(list(['a', 'b', 'c']));
      expect((y(t, 'a'), y(t, 'c')), (0, 100));

      await t.pumpWidget(list(['c', 'a', 'b']));
      // The frame that reorders still paints every row where it was.
      expect((y(t, 'a'), y(t, 'c')), (0, 100));
      await t.pump(); // the glide's first frame
      await t.pump(const Duration(milliseconds: 120));
      expect(y(t, 'a'), inExclusiveRange(0, 50));
      expect(y(t, 'c'), inExclusiveRange(0, 100));
      await t.pumpAndSettle();
      expect((y(t, 'c'), y(t, 'a'), y(t, 'b')), (0, 50, 100));
    });

    testWidgets('a tap mid-glide lands on the row that is moving there', (t) async {
      final taps = <String>[];
      Widget tappable(List<String> ids) => host(
        ListView.builder(
          itemCount: ids.length,
          findChildIndexCallback: (key) => ids.indexOf((key as ValueKey<String>).value),
          itemBuilder: (_, i) => DsReorderSlide(
            key: ValueKey(ids[i]),
            child: GestureDetector(
              onTap: () => taps.add(ids[i]),
              child: SizedBox(height: 50, child: Text(ids[i])),
            ),
          ),
        ),
      );
      await t.pumpWidget(tappable(['a', 'b']));
      await t.pumpWidget(tappable(['b', 'a']));
      await t.pump();
      await t.pump(const Duration(milliseconds: 60));
      await t.tapAt(const Offset(10, 10));
      expect(taps, ['b'], reason: 'b is gliding up into the top slot');
      await t.pumpAndSettle();
    });

    testWidgets('scrolling does not move rows', (t) async {
      await t.pumpWidget(list([for (var i = 0; i < 40; i++) 'r$i']));
      final g = await t.startGesture(const Offset(100, 400));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, -30));
        await t.pump(const Duration(milliseconds: 16));
        // Painted exactly where the scroll put it, every frame.
        final top = y(t, 'r10');
        expect(top, closeTo(10 * 50 - (t.state<ScrollableState>(find.byType(Scrollable)).position.pixels), 0.01));
      }
      await g.up();
      await t.pumpAndSettle();
    });

    testWidgets('Reduce Motion: rows jump straight to their new place', (t) async {
      await t.pumpWidget(list(['a', 'b', 'c'], reduceMotion: true));
      await t.pumpWidget(list(['c', 'a', 'b'], reduceMotion: true));
      expect((y(t, 'c'), y(t, 'a'), y(t, 'b')), (0, 50, 100));
    });
  });
}
