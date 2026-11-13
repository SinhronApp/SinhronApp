// A live call where my mic sends nothing (owner, 2026-10-20: the iPad
// answered, heard nothing and sent 0 bytes — "session inactive" under
// CallKit: the system never switched the call's audio on, and nothing
// tried again). Every second while the call is live: if the mic's sender
// hasn't sent a byte more for [stall], first ask iOS to switch the audio
// on again (`recoverAudio`), then restart the mic track; a few tries at
// most. A muted mic still sends (silence frames), so a flat counter means
// no audio is being recorded at all.

import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
import 'package:livekit_client/livekit_client.dart' as lk;

enum MicRepair { none, recoverAudio, restartTrack }

/// The decision, apart from timers and the platform (tested on its own).
class SilentMicWatch {
  SilentMicWatch({this.stall = 3, this.maxTries = 3});

  /// Flat samples (one a second) before a repair.
  final int stall;
  final int maxTries;

  int? _last;
  int _flat = 0;
  int _tries = 0;

  int get tries => _tries;

  /// [bytesSent] — the mic sender's counter now (null: not readable).
  MicRepair sample(int? bytesSent) {
    if (bytesSent == null || _tries >= maxTries) return MicRepair.none;
    final grew = _last == null || bytesSent > _last!;
    _last = bytesSent;
    if (grew && bytesSent > 0) {
      _flat = 0;
      return MicRepair.none;
    }
    if (++_flat < stall) return MicRepair.none;
    _flat = 0;
    _tries++;
    return _tries == 1 ? MicRepair.recoverAudio : MicRepair.restartTrack;
  }
}

/// Bytes the mic's sender has sent (all outbound audio RTP), or null.
Future<int?> micBytesSent(lk.Room room) async {
  int? sent;
  for (final p in room.localParticipant?.audioTrackPublications ?? const <lk.LocalTrackPublication>[]) {
    try {
      final stats = await p.track?.sender?.getStats();
      for (final r in stats ?? const []) {
        if (r.type != 'outbound-rtp') continue;
        final v = (r.values as Map)['bytesSent'];
        if (v is num) sent = (sent ?? 0) + v.toInt();
      }
    } catch (_) {}
  }
  return sent;
}

/// iPhone / iPad: switch the call's audio session on again and restart
/// WebRTC's audio (`CallAudio.recover` in CallKitBridge.swift).
Future<bool> recoverIosAudio() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return false;
  try {
    return await const MethodChannel('dev.sinhron/audio').invokeMethod<bool>('recoverAudio') ?? false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Runs [SilentMicWatch] on [room] once a second while [live] says so.
class SilentMicGuard {
  SilentMicGuard(this.room, {required this.live, this.onRepair});

  final lk.Room room;
  final bool Function() live;

  /// Told what was tried (for the setup line / logs).
  final void Function(MicRepair)? onRepair;

  final _watch = SilentMicWatch();
  Timer? _timer;
  bool _busy = false;

  @visibleForTesting
  SilentMicWatch get watch => _watch;

  void start() => _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_busy || !live()) return;
    _busy = true;
    try {
      final repair = _watch.sample(await micBytesSent(room));
      if (repair == MicRepair.none) return;
      // ignore: avoid_print
      print('[livekit] my mic sent nothing for ${_watch.stall} s — ${repair.name} (try ${_watch.tries})');
      onRepair?.call(repair);
      if (repair == MicRepair.recoverAudio) {
        await recoverIosAudio();
      } else {
        for (final p in room.localParticipant?.audioTrackPublications ?? const <lk.LocalTrackPublication>[]) {
          final t = p.track;
          if (t is lk.LocalAudioTrack) await t.restartTrack();
        }
        await recoverIosAudio();
      }
      if (_watch.tries >= _watch.maxTries) stop();
    } catch (e) {
      // ignore: avoid_print
      print('[livekit] mic repair failed: $e');
    } finally {
      _busy = false;
    }
  }
}
