// In-app sounds — UI backlog §4 item 38. Quiet "sent" / "received"
// blips, synthesised in memory (no audio assets), switchable in
// Settings. They follow the iPhone's silent switch (ambient session),
// never interrupt a playing voice message, and only exist on phones.

import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../features/calls/active_call_provider.dart' show activeCallProvider, callOwnsAudio;
import '../features/voice/voice_player.dart';
import 'providers/settings_providers.dart';

// StreamAudioSource is experimental in just_audio 0.10.6 — same note
// as voice_player.dart.
// ignore_for_file: experimental_member_use

enum UiSound { sent, received }

/// 16-bit mono PCM WAV of short sine tones with a soft envelope.
Uint8List synthBlip(List<double> freqs, {int msPerTone = 60, double volume = 0.18, int rate = 22050}) {
  final perTone = rate * msPerTone ~/ 1000;
  final n = perTone * freqs.length;
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
  for (var t = 0; t < freqs.length; t++) {
    for (var i = 0; i < perTone; i++) {
      final x = i / perTone;
      // Quick attack, smooth decay — no clicks.
      final env = math.min(1.0, x * 12) * math.pow(1 - x, 2);
      final v = math.sin(2 * math.pi * freqs[t] * i / rate) * env * volume;
      data.setInt16(44 + (t * perTone + i) * 2, (v * 32767).round(), Endian.little);
    }
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

class UiSounds {
  UiSounds(this._ref);
  final Ref _ref;
  AudioPlayer? _player;

  static final _clips = {
    UiSound.sent: synthBlip([880, 1320]),
    UiSound.received: synthBlip([990, 660], msPerTone: 70),
  };

  Future<void> play(UiSound s) async {
    if (!(Platform.isIOS || Platform.isAndroid)) return;
    if (!(_ref.read(uiSoundsEnabledProvider).value ?? true)) return;
    if (_ref.read(voicePlayerProvider).playing) return;
    // Never during a call (owner, 2026-10-18: calls with no sound): the
    // blip switches the phone's audio session to "ambient", which takes the
    // microphone from the call — a message arriving in the chat left open
    // under the call screen silenced it.
    if (callOwnsAudio(_ref.read(activeCallProvider))) return;
    try {
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.ambient,
          avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.mixWithOthers,
        ),
      );
      final p = _player ??= AudioPlayer();
      await p.setAudioSource(_Bytes(_clips[s]!));
      await p.play();
    } catch (_) {
      // Sounds are a nicety — never surface errors.
    }
  }
}

/// Settings → "In-app sounds" (on by default).
final uiSoundsEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('ui_sounds', true));

final uiSoundsProvider = Provider<UiSounds>((ref) {
  final s = UiSounds(ref);
  ref.onDispose(() => s._player?.dispose());
  return s;
});
