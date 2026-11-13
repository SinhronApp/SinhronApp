import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:sinhron/features/stickers/sticker_codec.dart';

/// Audit 2026-11b M04: a tiny .tgs whose repeater asks for millions of
/// copies must not be handed to the renderer (it loops `copies` times per
/// frame on the UI thread).
void main() {
  test('a tgs with a huge repeater is refused or draws fast', () async {
    const k0 = '{"a":0,"k":[0,0]}';
    const tr = '"p":$k0,"a":$k0,"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0}';
    const json = '{"v":"5.5.2","fr":30,"ip":0,"op":30,"w":100,"h":100,"layers":[{"ty":4,"ind":1,"ip":0,"op":30,"st":0,'
        '"ks":{},"shapes":[{"ty":"gr","it":['
        '{"ty":"rc","p":{"a":0,"k":[50,50]},"s":{"a":0,"k":[10,10]},"r":{"a":0,"k":0}},'
        '{"ty":"fl","c":{"a":0,"k":[1,0,0,1]},"o":{"a":0,"k":100}},'
        '{"ty":"rp","c":{"a":0,"k":2000000},"o":{"a":0,"k":0},"tr":{$tr,"so":{"a":0,"k":100},"eo":{"a":0,"k":100}}},'
        '{"ty":"tr",$tr,"o":{"a":0,"k":100}}]}]}]}';
    final tgs = gzip.encode(utf8.encode(json));
    expect(tgs.length, lessThan(1024));
    final sw = Stopwatch()..start();
    try {
      final c = await decodeTgs(tgs);
      final rec = ui.PictureRecorder();
      LottieDrawable(c!).draw(ui.Canvas(rec), const ui.Rect.fromLTWH(0, 0, 100, 100));
      rec.endRecording();
    } catch (_) {
      // Refused — fine.
    }
    // ignore: avoid_print
    print('one frame took ${sw.elapsedMilliseconds} ms (tgs ${tgs.length} bytes)');
    expect(sw.elapsedMilliseconds, lessThan(500));
  });
}
