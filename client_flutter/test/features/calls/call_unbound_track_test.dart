// Audit 2026-11b (13) — a track the server sends without tying it to a
// participant's publication gets no SFrame decryptor from livekit_client
// 2.7.0 and would still play. `silenceUnboundTracks` switches it off on
// arrival; LiveKit switches a real one on when it subscribes.
// The real livekit_client Room / Engine run here, no connection.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:livekit_client/src/core/engine.dart' as lk_engine;
import 'package:livekit_client/src/internal/events.dart' as lk_internal;
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as pb;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as pb_rtc;
import 'package:sinhron/features/calls/livekit_engine.dart';

class _Track implements rtc.MediaStreamTrack {
  _Track(this.id);
  @override
  final String id;
  @override
  String? get kind => 'audio';
  @override
  bool enabled = true;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Stream implements rtc.MediaStream {
  _Stream(this.id);
  @override
  final String id;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a track of nobody is switched off; a subscribed one is left alone and LiveKit turns it on', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => null,
    );
    final engine = lk_engine.Engine(connectOptions: const lk.ConnectOptions(), roomOptions: const lk.RoomOptions());
    final room = lk.Room(engine: engine);
    silenceUnboundTracks(room);

    // The join: me and one real participant with a published microphone.
    engine.events.emit(lk_internal.EngineJoinResponseEvent(
      response: pb_rtc.JoinResponse(
        participant: pb.ParticipantInfo(sid: 'PA_me', identity: 'me'),
        otherParticipants: [
          pb.ParticipantInfo(
            sid: 'PA_sister',
            identity: 'sister',
            tracks: [pb.TrackInfo(sid: 'TR_mic', type: pb.TrackType.AUDIO, source: pb.TrackSource.MICROPHONE)],
          ),
        ],
      ),
    ));
    await pumpEventQueue();
    final sister = room.remoteParticipants.values.single;

    // The hostile server: an audio track of a participant it never announced.
    final ghost = _Track('TR_ghost');
    engine.events.emit(lk_internal.EngineTrackAddedEvent(track: ghost, stream: _Stream('PA_ghost|s'), receiver: null));
    await pumpEventQueue();
    expect(ghost.enabled, isFalse, reason: 'no publication, no decryptor: it must not play');

    // ...and one of a real participant, but with a track id it never published.
    final extra = _Track('TR_extra');
    engine.events.emit(lk_internal.EngineTrackAddedEvent(track: extra, stream: _Stream('PA_sister|s'), receiver: null));
    await pumpEventQueue();
    expect(extra.enabled, isFalse);

    // An honest track: LiveKit ties it to the publication and starts it.
    final real = _Track('TR_mic');
    final stream = _Stream('PA_sister|s');
    // Arrived, not tied yet: off.
    engine.events.emit(lk_internal.EngineTrackAddedEvent(track: real, stream: stream, receiver: null));
    await pumpEventQueue();
    expect(real.enabled, isFalse);
    // What RemoteParticipant.addSubscribedMediaTrack does next (remote.dart:245-255).
    final track = lk.RemoteAudioTrack(lk.TrackSource.microphone, stream, real);
    await sister.trackPublications['TR_mic']!.updateTrack(track);
    await track.start();
    expect(real.enabled, isTrue, reason: 'LiveKit switches a subscribed track on');
    // The same event once it is tied (either order of the two listeners): untouched.
    engine.events.emit(lk_internal.EngineTrackAddedEvent(track: real, stream: stream, receiver: null));
    await pumpEventQueue();
    expect(real.enabled, isTrue);
  });
}
