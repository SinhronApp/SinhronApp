// Ringback (owner, 2026-10-19): a soft bell while my call rings over there.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/ringback.dart';

void main() {
  test('it plays only while my call rings at the other end', () {
    const ringing = ActiveCallState(phase: CallPhase.outgoingRinging, callId: 'c', isCaller: true);
    expect(ringbackWanted(ringing), isTrue);
    expect(ringbackWanted(ringing.copyWith(phase: CallPhase.connected)), isFalse, reason: 'answered');
    expect(ringbackWanted(ringing.copyWith(phase: CallPhase.ended)), isFalse, reason: 'declined / over');
    expect(ringbackWanted(const ActiveCallState.idle()), isFalse);
    expect(
      ringbackWanted(const ActiveCallState(phase: CallPhase.incomingRinging, callId: 'c')),
      isFalse,
      reason: 'a call ringing for me rings its own way',
    );
  });

  test('one loop: a 3 s mono 16-bit WAV, bell notes first, quiet at the end', () {
    final w = synthRingback(rate: 8000);
    final d = ByteData.sublistView(w);
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 12)), 'WAVE');
    expect(d.getUint16(22, Endian.little), 1, reason: 'mono');
    final samples = (w.length - 44) ~/ 2;
    expect(samples, 8000 * kRingbackLoopMs ~/ 1000);
    int peak(int from, int to) {
      var m = 0;
      for (var i = from; i < to; i++) {
        final v = d.getInt16(44 + i * 2, Endian.little).abs();
        if (v > m) m = v;
      }
      return m;
    }

    expect(peak(0, 2000), greaterThan(3000), reason: 'the notes are heard');
    expect(peak(samples - 800, samples), lessThan(peak(0, 2000) ~/ 10), reason: 'the pause before the next loop');
  });

  test('off phones (tests, desktop) it does nothing and never throws', () async {
    final r = JustAudioRingback();
    await r.start();
    await r.stop();
    await r.dispose();
  });
}
