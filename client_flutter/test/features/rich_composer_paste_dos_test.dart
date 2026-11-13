// Audit 2026-11b T13: a 64 KiB text must not freeze the UI isolate.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_view/rich_composer.dart';

void main() {
  test('T13: pasting 64 KiB of Markdown-looking text does not freeze', () {
    for (final paste in ['# x${' ' * 65536}y', '`a`' * 21845]) {
      final c = RichTextController();
      final sw = Stopwatch()..start();
      c.value = TextEditingValue(text: paste, selection: TextSelection.collapsed(offset: paste.length));
      expect(sw.elapsedMilliseconds, lessThan(300), reason: paste.substring(0, 3));
      expect(c.text.length, paste.length, reason: 'kept as typed');
    }
  });
}
