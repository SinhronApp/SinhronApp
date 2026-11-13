// Tech-debt 2.24 — video poster frame and compression before sending.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/video_tools.dart';

class FakeVideoTools implements VideoTools {
  FakeVideoTools(this.dir, {this.compressWorks = true});
  final Directory dir;
  final bool compressWorks;
  final calls = <String>[];

  @override
  Future<String?> compress(String path) async {
    calls.add('compress');
    if (!compressWorks) return null;
    final out = File('${dir.path}/small.mp4')..writeAsBytesSync(List.filled(1000, 7));
    return out.path;
  }

  @override
  Future<Uint8List?> posterFrame(String path) async {
    calls.add('poster ${path.split('/').last}');
    return Uint8List.fromList([0xFF, 0xD8]);
  }

  @override
  Future<void> cleanup() async => calls.add('cleanup');
}

/// Compression that makes the file bigger.
class _BiggerTools extends FakeVideoTools {
  _BiggerTools(super.dir);
  @override
  Future<String?> compress(String path) async =>
      (File('${dir.path}/bigger.mp4')..writeAsBytesSync(Uint8List(kCompressVideoAbove + 100))).path;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('video_tools_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  File clip(String name, int size) => File('${dir.path}/$name')..writeAsBytesSync(Uint8List(size));

  test('a small clip goes as is, with a poster; the temp file is gone after', () async {
    final f = clip('a.mov', 1000);
    final tools = FakeVideoTools(dir);
    final v = await prepareVideoForSending(tools, f.path);
    expect(v.bytes.length, 1000);
    expect(v.mimeType, 'video/quicktime');
    expect(v.compressed, isFalse);
    expect(v.poster, isNotNull);
    expect(tools.calls, ['poster a.mov', 'cleanup'], reason: 'no compression under the threshold');
    expect(f.existsSync(), isFalse, reason: 'no plaintext left on disk');
  });

  test('a large clip is compressed; both files are deleted', () async {
    final f = clip('big.mov', kCompressVideoAbove + 1);
    final tools = FakeVideoTools(dir);
    final v = await prepareVideoForSending(tools, f.path);
    expect(v.compressed, isTrue);
    expect(v.bytes.length, 1000);
    expect(v.mimeType, 'video/mp4');
    expect(tools.calls, ['compress', 'poster small.mp4', 'cleanup']);
    expect(f.existsSync(), isFalse);
    expect(File('${dir.path}/small.mp4').existsSync(), isFalse);
  });

  test('if compression fails, the original is sent', () async {
    final f = clip('big.mp4', kCompressVideoAbove + 1);
    final v = await prepareVideoForSending(FakeVideoTools(dir, compressWorks: false), f.path);
    expect(v.compressed, isFalse);
    expect(v.bytes.length, kCompressVideoAbove + 1);
    expect(f.existsSync(), isFalse);
  });

  test('a compressed copy that is not smaller is dropped; MIME follows the file', () async {
    final f = clip('low.webm', kCompressVideoAbove + 1);
    final v = await prepareVideoForSending(_BiggerTools(dir), f.path);
    expect(v.compressed, isFalse);
    expect(v.bytes.length, kCompressVideoAbove + 1, reason: 'the original goes');
    expect(v.mimeType, 'video/webm');
    expect(File('${dir.path}/bigger.mp4').existsSync(), isFalse, reason: 'dropped copy deleted');
    expect(f.existsSync(), isFalse);
  });

  test('too large even after compression: refused before reading, files deleted', () async {
    final f = clip('huge.mov', 1);
    // Sparse file over the limit without writing 95 MB.
    f.openSync(mode: FileMode.write)
      ..setPositionSync(kMaxVideoBytes + 1)
      ..writeByteSync(0)
      ..closeSync();
    await expectLater(prepareVideoForSending(FakeVideoTools(dir, compressWorks: false), f.path), throwsA(isA<VideoTooLarge>()));
    expect(f.existsSync(), isFalse);
  });

  test('without the plugin (tests, desktop): no poster, no compression, no crash', () async {
    final f = clip('c.mp4', 10);
    final tools = PluginVideoTools();
    expect(await tools.posterFrame(f.path), isNull);
    expect(await tools.compress(f.path), isNull);
    await tools.cleanup();
  });
}
