// Voice playback from decrypted bytes in RAM — ADR-017 stage 4.
//
// just_audio's StreamAudioSource serves the bytes to the native player
// through its in-process proxy on 127.0.0.1 — the decrypted audio never
// touches disk. (iOS: needs NSAllowsLocalNetworking in Info.plist.)
// One message plays at a time; starting another stops the first.

import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../calls/active_call_provider.dart' show activeCallProvider, callOwnsAudio;

// StreamAudioSource is marked experimental in just_audio 0.10.6, but it
// is the only way to play from RAM without a plaintext temp file.
// Re-check on every just_audio bump (pinned exactly in pubspec).
// ignore_for_file: experimental_member_use

class _BytesSource extends StreamAudioSource {
  _BytesSource(this._bytes);
  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final s = start ?? 0;
    final e = end ?? _bytes.length;
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(_bytes.sublist(s, e)),
      contentType: 'audio/mp4',
    );
  }
}

/// A voice message to play next: its key and how to get its bytes.
typedef VoiceTrack = (String key, Future<Uint8List> Function() load);

/// Playback speeds, Telegram-style.
const kVoiceSpeeds = [1.0, 1.5, 2.0];

class VoicePlayback {
  const VoicePlayback({
    this.key,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.speed = 1.0,
  });

  /// Which message is loaded (its media JSON), null when idle.
  final String? key;
  final bool playing;
  final bool loading;
  final Duration position;
  final Duration duration;

  /// Applies to every message until changed (UI backlog §3 item 28).
  final double speed;

  double get progress =>
      duration.inMilliseconds == 0 ? 0 : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
}

class VoicePlayerNotifier extends Notifier<VoicePlayback> {
  AudioPlayer? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  double _speed = 1.0;

  /// What plays after the current message finishes (consecutive voice
  /// messages autoplay).
  List<VoiceTrack> _next = const [];

  /// 1× → 1.5× → 2× → 1×.
  Future<void> cycleSpeed() async {
    final i = kVoiceSpeeds.indexOf(_speed);
    _speed = kVoiceSpeeds[(i + 1) % kVoiceSpeeds.length];
    state = _copy();
    await _player?.setSpeed(_speed);
  }

  @override
  VoicePlayback build() {
    ref.onDispose(_release);
    return const VoicePlayback();
  }

  /// Jump to [fraction] (0..1) of [key] — a tap or a drag on the waveform.
  /// The active message seeks in place (paused stays paused, the speed and
  /// the autoplay queue stay); another message starts playing from there.
  Future<void> seek(
    String key,
    double fraction,
    Future<Uint8List> Function() load, {
    List<VoiceTrack> next = const [],
  }) async {
    final f = fraction.clamp(0.0, 1.0);
    final p = _player;
    if (state.key == key && state.loading) return;
    if (state.key == key && p != null) {
      final to = state.duration * f;
      state = _copy(position: to);
      await p.seek(to);
      return;
    }
    await toggle(key, load, next: next, from: f);
  }

  /// Play/pause [key]; [load] returns the decrypted audio when needed.
  /// [next] plays automatically afterwards, in order. A fresh start begins
  /// at [from] (0..1 of the length).
  Future<void> toggle(
    String key,
    Future<Uint8List> Function() load, {
    List<VoiceTrack> next = const [],
    double from = 0,
  }) async {
    final p = _player;
    if (state.key == key && p != null) {
      if (p.playing) {
        await p.pause();
      } else {
        await p.play();
      }
      return;
    }
    await _release();
    _next = next;
    state = VoicePlayback(key: key, loading: true, speed: _speed);
    try {
      final session = await AudioSession.instance;
      // During a call the session is the call's (play-and-record): a voice
      // message plays inside it, never switching it to playback (that took
      // the microphone from the call — ADR-063).
      final inCall = callOwnsAudio(ref.read(activeCallProvider));
      if (!inCall) await session.configure(const AudioSessionConfiguration.speech());
      // Owner, 2026-10-16: in headphones "every other time" there was no
      // sound. After a call (WebRTC's play-and-record session) or an in-app
      // sound (ambient) the session could stay someone else's — take it
      // explicitly before playing, so the sound goes where the system routes
      // it now (AirPods, wired, speaker).
      if (!inCall) await session.setActive(true);
      // Headphones pulled out: pause, don't blast it from the speaker.
      _subs.add(
        session.becomingNoisyEventStream.listen((_) {
          if (_player?.playing ?? false) unawaited(_player!.pause());
        }),
      );
      final bytes = await load();
      final player = AudioPlayer();
      _player = player;
      _subs.add(
        player.positionStream.listen((pos) {
          if (state.key == key) state = _copy(position: pos);
        }),
      );
      _subs.add(
        player.playerStateStream.listen((ps) {
          if (state.key != key) return;
          if (ps.processingState == ProcessingState.completed) {
            player.pause();
            player.seek(Duration.zero);
            state = _copy(playing: false, position: Duration.zero);
            final queue = _next;
            if (queue.isNotEmpty) {
              final (k, l) = queue.first;
              unawaited(toggle(k, l, next: queue.sublist(1)).catchError((Object _) {}));
            }
          } else {
            state = _copy(playing: ps.playing);
          }
        }),
      );
      final duration = await player.setAudioSource(_BytesSource(bytes));
      await player.setSpeed(_speed);
      final length = duration ?? Duration.zero;
      final start = from > 0 ? length * from : Duration.zero;
      if (start > Duration.zero) await player.seek(start);
      state = _copy(loading: false, duration: length, position: start);
      unawaited(player.play());
    } catch (_) {
      await _release();
      state = const VoicePlayback();
      rethrow;
    }
  }

  Future<void> stop() async {
    _next = const [];
    await _release();
    state = VoicePlayback(speed: _speed);
  }

  VoicePlayback _copy({bool? playing, bool? loading, Duration? position, Duration? duration}) => VoicePlayback(
    key: state.key,
    playing: playing ?? state.playing,
    loading: loading ?? state.loading,
    position: position ?? state.position,
    duration: duration ?? state.duration,
    speed: _speed,
  );

  Future<void> _release() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final p = _player;
    _player = null;
    await p?.dispose();
  }
}

final voicePlayerProvider = NotifierProvider<VoicePlayerNotifier, VoicePlayback>(VoicePlayerNotifier.new);
