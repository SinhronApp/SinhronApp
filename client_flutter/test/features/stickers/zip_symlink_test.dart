// security-audit-2026-11b M05: the zip library inflates an entry marked
// as a symlink in full, inside decodeBytes — before our own size cap.
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/stickers/sticker_import.dart';

/// [zip] with its last entry marked "made on unix, a symlink".
Uint8List asSymlink(List<int> zip) {
  final b = Uint8List.fromList(zip);
  var at = -1;
  for (var i = 0; i + 4 <= b.length; i++) {
    if (b[i] == 0x50 && b[i + 1] == 0x4b && b[i + 2] == 1 && b[i + 3] == 2) at = i;
  }
  b[at + 5] = 3; // version made by: unix
  b.buffer.asByteData().setUint32(at + 38, 0xa1ff << 16, Endian.little); // external attributes
  return b;
}

void main() {
  test('a zip entry marked as a symlink is not inflated by the library', () {
    final webp = Uint8List.fromList([...'RIFF'.codeUnits, 4, 0, 0, 0, ...'WEBP'.codeUnits]);
    final zip = asSymlink(
      ZipEncoder().encodeBytes(
        Archive()
          ..add(ArchiveFile.bytes('cat.webp', webp))
          ..add(ArchiveFile.bytes('link', Uint8List(64 << 20)..fillRange(0, 64 << 20, 0xff))),
      ),
    );
    printOnFailure('zip: ${zip.length} bytes');
    // Today: the library inflates all 64 MB of "link" and reads it as text
    // (which throws), so the whole zip comes back unopened.
    final out = expandArchives([ImportedFile('pack.zip', zip)]);
    expect(out.map((f) => f.name), ['cat.webp']);
  });
}
