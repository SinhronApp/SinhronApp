// Owner, 2026-10-18: "calls with mum's iPhone often have no sound (video
// works), or it comes only after a long time". On iPhone the audio session
// decides whether the mic records at all: LiveKit's default switched it to
// `playback` (no mic) while only the other side's track was there with the
// speaker preferred — which LiveKit starts as true; in-app sounds switched
// it to `ambient`. CallKit's activation now starts WebRTC's audio (native).

import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:livekit_client/src/support/native_audio.dart';
// ignore: implementation_imports
import 'package:livekit_client/src/track/audio_management.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_diagnostics.dart';
import 'package:sinhron/features/calls/livekit_engine.dart';

void main() {
  test('a call keeps play-and-record whatever is published yet — never playback (no mic)', () {
    for (final s in [AudioTrackState.remoteOnly, AudioTrackState.localOnly, AudioTrackState.localAndRemote]) {
      for (final speaker in [true, false]) {
        final c = callAudioConfigFor(s, speaker: speaker);
        expect(c.appleAudioCategory, AppleAudioCategory.playAndRecord, reason: '$s speaker=$speaker');
        expect(c.appleAudioMode, speaker ? AppleAudioMode.videoChat : AppleAudioMode.voiceChat);
      }
    }
    expect(callAudioConfigFor(AudioTrackState.none, speaker: true).appleAudioCategory, AppleAudioCategory.soloAmbient);
  });

  test('an audio call joins on the earpiece even though LiveKit starts "prefer speaker"', () async {
    useCallAudioConfig(speaker: false);
    expect((await onConfigureNativeAudio(AudioTrackState.remoteOnly)).appleAudioMode, AppleAudioMode.voiceChat);
    useCallAudioConfig(speaker: true);
    expect((await onConfigureNativeAudio(AudioTrackState.remoteOnly)).appleAudioMode, AppleAudioMode.videoChat);
    releaseJoinSpeaker(); // the speaker button (LiveKit's own choice) decides from here
  });

  test('in-app sounds and voice messages leave the audio session alone during a call', () {
    expect(callOwnsAudio(const ActiveCallState.idle()), isFalse);
    for (final p in [CallPhase.incomingRinging, CallPhase.outgoingRinging, CallPhase.connected, CallPhase.ended]) {
      expect(callOwnsAudio(ActiveCallState(phase: p)), isTrue, reason: '$p');
    }
  });

  group('diagnostics: which side is silent', () {
    final t0 = DateTime(2026, 10, 18, 20);
    List<Map<String, Object?>> inbound(int packets) => [
      {'type': 'inbound-rtp', 'id': 'a', 'kind': 'audio', 'packetsReceived': packets, 'packetsLost': 0, 'bytesReceived': packets * 80},
    ];

    test('their packets and the rate', () {
      final a = CallStatsSnapshot.parse(publisher: const [], subscriber: inbound(100), at: t0);
      final b = CallStatsSnapshot.parse(publisher: const [], subscriber: inbound(150), at: t0.add(const Duration(seconds: 1)), prev: a);
      expect(b.audioPacketsIn, 150);
      expect(b.audioPacketsPerSec, 50);
      final lines = diagnosticsLines(b, room: 'connected', plan: 'direct', people: 2, peerAudioTracks: 1);
      expect(lines, contains('peer audio: 1 track · 150 pkts (50/s)'));
      expect(
        diagnosticsLines(CallStatsSnapshot(at: t0), room: 'c', plan: 'direct', people: 2, peerAudioTracks: 0),
        contains('peer audio: no track · 0 pkts'),
      );
    });

    test('the iPhone audio session in one line', () {
      expect(
        audioSessionLine({
          'category': 'PlayAndRecord',
          'mode': 'VoiceChat',
          'active': true,
          'manual': true,
          'enabled': true,
          'input': true,
          'in': 'MicrophoneBuiltIn',
          'out': 'Receiver',
        }),
        'PlayAndRecord · VoiceChat · active · webrtc on (CallKit) · MicrophoneBuiltIn → Receiver',
      );
      expect(
        audioSessionLine({'category': 'Ambient', 'mode': 'Default', 'active': false, 'manual': true, 'enabled': false, 'input': false}),
        'Ambient · Default · inactive · webrtc off (CallKit) · NO MIC · ? → ?',
      );
      final lines = diagnosticsLines(CallStatsSnapshot(at: t0), room: 'c', plan: 'direct', people: 2, audioSession: 'X');
      expect(lines, contains('session: X'));
    });
  });
}
