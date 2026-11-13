// Ringback (owner, 2026-10-19: "a tone while I'm calling someone — a nice,
// beautiful one, not the standard"). A soft three-note bell — A4, C#5, E5,
// each with a gentle overtone and a long decay — then a pause; repeats while
// the other side rings. Synthesised in memory (no audio assets), played into
// the call's own audio session (no session change: the call owns the audio),
// stopped the moment they answer, decline or the call ends.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

// StreamAudioSource is experimental in just_audio 0.10.6 — as in
// voice_player.dart.
// ignore_for_file: experimental_member_use

/// One loop: three bell notes, then quiet — 3 s in all.
const kRingbackNotes = [440.0, 554.37, 659.25];
const kRingbackNoteMs = 260;
const kRingbackLoopMs = 3000;

/// 16-bit mono PCM WAV of one loop of the ringback.
Uint8List synthRingback({int rate = 22050, double volume = 0.45}) {
  final n = rate * kRingbackLoopMs ~/ 1000;
  final data = ByteData(44 + n * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 2, Endian.little);
  final step = rate * kRingbackNoteMs ~/ 1000;
  for (var i = 0; i < n; i++) {
    var v = 0.0;
    for (var k = 0; k < kRingbackNotes.length; k++) {
      final start = k * step;
      if (i < start) continue;
      final t = (i - start) / rate;
      // A bell: quick attack, long exponential decay, a soft octave
      // overtone that fades faster — warm, not a beep.
      final env = math.min(1.0, t * 80) * math.exp(-t * 2.6);
      final f = kRingbackNotes[k];
      v += env * (math.sin(2 * math.pi * f * t) + 0.28 * math.exp(-t * 4) * math.sin(4 * math.pi * f * t));
    }
    final s = (v / kRingbackNotes.length * volume * 2).clamp(-1.0, 1.0);
    data.setInt16(44 + i * 2, (s * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

class _Bytes extends StreamAudioSource {
  _Bytes(this._b);
  final Uint8List _b;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final s = start ?? 0, e = end ?? _b.length;
    return StreamAudioResponse(
      sourceLength: _b.length,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(_b.sublist(s, e)),
      contentType: 'audio/wav',
    );
  }
}

/// Plays the ringback while [start]ed; [stop] silences it at once.
abstract class Ringback {
  Future<void> start();
  Future<void> stop();
}

class JustAudioRingback implements Ringback {
  AudioPlayer? _player;
  static final Uint8List _loop = synthRingback();
  bool _on = false;
  Timer? _tick;

  @override
  Future<void> start() async {
    if (_on || !(Platform.isIOS || Platform.isAndroid)) return;
    _on = true;
    // Status 223 — armed first: a first load that fails while the call's
    // audio comes up (CallKit, LiveKit) is retried on the next loop.
    _tick = Timer.periodic(const Duration(milliseconds: kRingbackLoopMs), (_) => _again());
    try {
      final p = _player ??= AudioPlayer(handleAudioSessionActivation: false);
      await p.setAudioSource(_Bytes(_loop));
      if (!_on) return;
      unawaited(p.play());
      // Status 212 (owner: "the tone plays a second, then silence") — the
      // call's audio session comes up right after the tone starts (the room
      // joined ahead, CallKit) and pauses the player, which may still say
      // it's playing. Each loop starts afresh, so the tone never stays off.
    } catch (_) {
      // A ringback is a nicety — the call goes on without it.
    }
  }

  Future<void> _again() async {
    final p = _player;
    if (!_on || p == null) return;
    try {
      await p.pause();
      if (p.processingState != ProcessingState.ready) await p.setAudioSource(_Bytes(_loop));
      await p.seek(Duration.zero);
      if (_on) unawaited(p.play());
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _on = false;
    _tick?.cancel();
    _tick = null;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _on = false;
    _tick?.cancel();
    await _player?.dispose();
    _player = null;
  }
}

final ringbackProvider = Provider<Ringback>((ref) {
  final r = JustAudioRingback();
  ref.onDispose(r.dispose);
  return r;
});
