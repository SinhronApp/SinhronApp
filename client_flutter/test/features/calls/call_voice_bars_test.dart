// Owner, 2026-10-18: "bars that jump to the tone, like an equalizer — not
// resource-hungry and not tiring".

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/call_voice_bars.dart';

void main() {
  test('silence: a low resting line; a voice lifts them, the middle most', () {
    final quiet = CallVoiceBars.heightsFor(0, 1.0);
    expect(quiet.toSet().length, 1, reason: 'all at rest');
    expect(quiet.first, lessThan(0.2));
    final loud = CallVoiceBars.heightsFor(0.5, 0, sway: false);
    expect(loud[2], greaterThan(loud[0]));
    expect(loud[2], greaterThan(quiet[2] * 3));
    expect(loud.every((h) => h <= 1), isTrue);
  });

  test('they sway a little with time, never past full height', () {
    final a = CallVoiceBars.heightsFor(1, 0.0);
    final b = CallVoiceBars.heightsFor(1, 0.4);
    expect(a, isNot(equals(b)));
    for (var s = 0.0; s < 3; s += 0.1) {
      expect(CallVoiceBars.heightsFor(1, s).every((h) => h >= 0 && h <= 1), isTrue);
    }
  });

  Widget host(ValueListenable<double> level, {bool reduce = false}) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Directionality(textDirection: TextDirection.ltr, child: Center(child: CallVoiceBars(level: level))),
  );

  double middle(WidgetTester t) {
    final boxes = find.descendant(of: find.byKey(const ValueKey('call-voice-bars')), matching: find.byType(Container));
    return t.getSize(boxes.at(2)).height;
  }

  testWidgets('moves only while there is sound; silence stops drawing', (t) async {
    final level = ValueNotifier<double>(0);
    await t.pumpWidget(host(level));
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'silent from the start: no ticker');
    final rest = middle(t);

    level.value = 0.6;
    await t.pump();
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 40));
    }
    expect(middle(t), greaterThan(rest * 2));

    level.value = 0;
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 40));
    }
    expect(middle(t), closeTo(rest, 0.5));
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'settled → the ticker stopped');
  });

  testWidgets('Reduce Motion: no ticker, the bars just step with the level', (t) async {
    final level = ValueNotifier<double>(0);
    await t.pumpWidget(host(level, reduce: true));
    final rest = middle(t);
    level.value = 0.6;
    await t.pump();
    expect(middle(t), greaterThan(rest * 2));
    expect(t.binding.hasScheduledFrame, isFalse);
  });
}
