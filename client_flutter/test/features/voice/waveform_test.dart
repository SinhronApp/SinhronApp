import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/voice/waveform.dart';

void main() {
  test('dB maps linearly to 0..255 and clamps', () {
    expect(dbToLevel(0), 255);
    expect(dbToLevel(-50), 0);
    expect(dbToLevel(-25), 128);
    expect(dbToLevel(-160), 0);
    expect(dbToLevel(6), 255);
    expect(dbToLevel(double.nan), 0);
  });

  test('downsample keeps the peak per bucket and the exact length', () {
    final samples = List<double>.filled(640, -50)..[100] = 0;
    final w = downsampleWaveform(samples);
    expect(w.length, kWaveformPoints);
    expect(w[10], 255, reason: 'sample 100 falls in bucket 10');
    expect(w.where((v) => v != 0).length, 1);
  });

  test('fewer samples than points still fills every point', () {
    final w = downsampleWaveform([-50, 0, -25], points: 6);
    expect(w, [0, 0, 255, 255, 128, 128]);
  });

  test('empty recording gives a flat line', () {
    expect(downsampleWaveform(const []).every((v) => v == 0), isTrue);
  });

  test('duration label', () {
    expect(formatVoiceDuration(7000), '0:07');
    expect(formatVoiceDuration(83400), '1:23');
    expect(formatVoiceDuration(725000), '12:05');
  });
}
