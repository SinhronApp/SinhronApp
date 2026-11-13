import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/ui_sounds.dart';

void main() {
  test('synthesised blips are valid, quiet 16-bit mono WAV', () {
    final wav = synthBlip([880, 1320], msPerTone: 60, volume: 0.18, rate: 22050);
    final d = ByteData.sublistView(wav);
    String tag(int o) => String.fromCharCodes(wav.sublist(o, o + 4));
    expect(tag(0), 'RIFF');
    expect(tag(8), 'WAVE');
    expect(tag(36), 'data');
    expect(d.getUint16(22, Endian.little), 1, reason: 'mono');
    expect(d.getUint16(34, Endian.little), 16, reason: '16-bit');
    final samples = d.getUint32(40, Endian.little) ~/ 2;
    expect(samples, 22050 * 60 ~/ 1000 * 2);
    var peak = 0;
    for (var i = 0; i < samples; i++) {
      peak = d.getInt16(44 + i * 2, Endian.little).abs() > peak ? d.getInt16(44 + i * 2, Endian.little).abs() : peak;
    }
    expect(peak, lessThanOrEqualTo((0.18 * 32767).round()), reason: 'quiet');
    expect(peak, greaterThan(1000), reason: 'audible');
    expect(d.getInt16(44, Endian.little), 0, reason: 'starts silent (no click)');
  });
}
