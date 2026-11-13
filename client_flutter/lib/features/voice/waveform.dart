// Voice-message waveform helpers — ADR-017 stage 4, spec §11.2.
//
// While recording we sample input level in dBFS (record's
// onAmplitudeChanged, ~10/s). The envelope carries ≤256 bytes, one per
// point, 0-255; we send [kWaveformPoints].

import 'dart:math' as math;
import 'dart:typed_data';

const int kWaveformPoints = 64;

/// Below this the mic is effectively silent; 0 dBFS is full scale.
const double kSilenceDb = -50;

/// dBFS → 0..255 (linear in dB between [kSilenceDb] and 0).
int dbToLevel(double db) {
  if (db.isNaN) return 0;
  final t = ((db - kSilenceDb) / -kSilenceDb).clamp(0.0, 1.0);
  return (t * 255).round();
}

/// Reduce raw dBFS samples to exactly [points] levels (peak per bucket,
/// so short syllables stay visible). Empty input → flat line.
Uint8List downsampleWaveform(List<double> dbfs, {int points = kWaveformPoints}) {
  final out = Uint8List(points);
  if (dbfs.isEmpty) return out;
  for (var i = 0; i < points; i++) {
    final start = (i * dbfs.length / points).floor();
    final end = math.max(start + 1, ((i + 1) * dbfs.length / points).floor());
    var peak = 0;
    for (var j = start; j < end && j < dbfs.length; j++) {
      peak = math.max(peak, dbToLevel(dbfs[j]));
    }
    out[i] = peak;
  }
  return out;
}

/// "0:07", "1:23", "12:05".
String formatVoiceDuration(int ms) {
  final total = (ms / 1000).round();
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
