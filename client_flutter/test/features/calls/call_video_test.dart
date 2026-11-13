// Group call grid — tech-debt 4.9.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/call_video.dart';

void main() {
  test('one person fills the screen, two stack, 3-4 make a 2×2, more go to 3 columns', () {
    expect(CallVideoGrid.columnsFor(1), 1);
    expect(CallVideoGrid.columnsFor(2), 1);
    expect(CallVideoGrid.columnsFor(3), 2);
    expect(CallVideoGrid.columnsFor(4), 2);
    expect(CallVideoGrid.columnsFor(5), 3);
    expect(CallVideoGrid.columnsFor(9), 3);
  });
}
