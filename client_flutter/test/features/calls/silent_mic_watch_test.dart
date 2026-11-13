// Owner, 2026-10-20: the iPad answered, sent 0 bytes for the whole call and
// nothing tried again. The watch asks for a repair once the mic's counter
// stays flat for 3 s — audio first, then the track — a few times at most.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/call_diagnostics.dart';
import 'package:sinhron/features/calls/silent_mic_watch.dart';

void main() {
  test('a mic that sends is left alone', () {
    final w = SilentMicWatch();
    for (var b = 100; b < 2000; b += 100) {
      expect(w.sample(b), MicRepair.none);
    }
  });

  test('0 bytes for 3 s: restart audio, then the track; at most 3 tries', () {
    final w = SilentMicWatch();
    final got = [for (var i = 0; i < 12; i++) w.sample(0)];
    expect(got.where((r) => r != MicRepair.none).toList(), [
      MicRepair.recoverAudio,
      MicRepair.restartTrack,
      MicRepair.restartTrack,
    ]);
    expect(got[2], MicRepair.recoverAudio, reason: 'after the third flat second');
    expect(w.tries, 3);
  });

  test('a counter that stops growing mid-call counts too; unreadable stats do nothing', () {
    final w = SilentMicWatch();
    expect(w.sample(500), MicRepair.none);
    expect(w.sample(null), MicRepair.none);
    expect(w.sample(500), MicRepair.none);
    expect(w.sample(500), MicRepair.none);
    expect(w.sample(500), MicRepair.recoverAudio);
    expect(w.sample(900), MicRepair.none, reason: 'sending again');
  });

  test('the session line says when iOS interrupted the audio', () {
    expect(
      audioSessionLine({
        'category': 'PlayAndRecord',
        'mode': 'VoiceChat',
        'active': false,
        'interrupted': true,
        'manual': true,
        'enabled': true,
      }),
      startsWith('PlayAndRecord · VoiceChat · inactive · INTERRUPTED · webrtc on (CallKit)'),
    );
  });
}
