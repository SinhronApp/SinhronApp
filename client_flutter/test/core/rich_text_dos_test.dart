// Audit 2026-11b T01: a 64 KiB text must not freeze the UI isolate.
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/rich_text.dart';

void main() {
  test('T01: a 64 KiB legacy-marker message is laid out quickly', () {
    for (final unit in ['`a`', '||a||', '*a* ', 'www.a ']) {
      final sw = Stopwatch()..start();
      FormattedText.legacy(unit * (65536 ~/ unit.length));
      expect(sw.elapsedMilliseconds, lessThan(300), reason: unit);
    }
  });
}
