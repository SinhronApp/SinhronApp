// Audit 2026-11b (12) — a LiveKit server must not get a second, unencrypted
// "backup codec" copy of my camera: livekit_client 2.7.0 opens one on a
// single SubscribedQualityUpdate whenever dynacast is on (it never reads
// `BackupVideoCodec.enabled` there, and that sender gets no SFrame
// cryptor). Dynacast is off, and a codec that would turn it back on
// (VP9 / AV1, forced by the server) ends the call.
// The real livekit_client path runs here over a fake peer connection.


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:livekit_client/src/core/engine.dart' as lk_engine;
import 'package:livekit_client/src/e2ee/e2ee_manager.dart' as lk_e2ee;
import 'package:livekit_client/src/core/transport.dart' as lk_transport;
import 'package:livekit_client/src/internal/events.dart' as lk_internal;
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as pb;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as pb_rtc;
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/livekit_engine.dart';

class _NativeKeys extends rtc.KeyProvider {
  @override
  String get id => 'fake';
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Track implements rtc.MediaStreamTrack {
  @override
  String? get id => 'camera-track';
  @override
  String? get kind => 'video';
  @override
  bool get enabled => true;
  @override
  Map<String, dynamic> getSettings() => const {};
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Stream implements rtc.MediaStream {
  @override
  String get id => 'stream';
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Sender implements rtc.RTCRtpSender {
  @override
  String get senderId => 'backup-sender';
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Transceiver implements rtc.RTCRtpTransceiver {
  @override
  rtc.RTCRtpSender get sender => _Sender();
  @override
  Future<void> setCodecPreferences(List<rtc.RTCRtpCodecCapability> codecs) async {}
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

/// The publisher peer connection: remembers every sender it is asked for.
class _Pc implements rtc.RTCPeerConnection {
  final added = <rtc.MediaStreamTrack?>[];

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async {
    added.add(track);
    return _Transceiver();
  }

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('one SubscribedQualityUpdate from the server opens no second sender', () async {
    final media = (deviceClass: CallDeviceClass.standard, preset: callVideoPreset(CallDeviceClass.standard), codec: 'h264');
    final keys = CallKeyProvider(
      _NativeKeys(),
      rtc.KeyProviderOptions(sharedKey: false, ratchetSalt: Uint8List(0), ratchetWindowSize: 0),
    );
    final options = callRoomOptions(lk.E2EEOptions(keyProvider: keys), media);
    expect(options.defaultVideoPublishOptions.backupVideoCodec.enabled, isFalse, reason: 'Sinhron turns backup off');

    // Every call into the native WebRTC plugin, by name.
    final native = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        native.add(call.method);
        return switch (call.method) {
          'getRtpReceiverCapabilities' => {
            'codecs': [
              {'mimeType': 'video/VP8', 'clockRate': 90000, 'sdpFmtpLine': ''},
            ],
            'headerExtensions': <Object>[],
            'fecMechanisms': <Object>[],
          },
          'createDataPacketCryptor' => {'dataCryptorId': 'dc'},
          _ => null,
        };
      },
    );

    final pc = _Pc();
    final engine = lk_engine.Engine(connectOptions: const lk.ConnectOptions(), roomOptions: options);
    engine.publisher = await lk_transport.Transport.create(
      (cfg, [constraints = const {}]) async => pc,
      connectOptions: const lk.ConnectOptions(),
    );
    final room = lk.Room(engine: engine);
    // LiveKit's E2EE manager, set up as Room.connect does it.
    final e2ee = lk_e2ee.E2EEManager(keys, dcEncryptionEnabled: true);
    await e2ee.setup(room);
    engine.setE2eeManager(e2ee);

    // The join: gives the room its local participant.
    engine.events.emit(lk_internal.EngineJoinResponseEvent(
      response: pb_rtc.JoinResponse(participant: pb.ParticipantInfo(sid: 'PA_me', identity: 'me')),
    ));
    await pumpEventQueue();
    final me = room.localParticipant!;

    // My camera, published the way Sinhron publishes it (h264, backup off).
    final camera = lk.LocalVideoTrack(lk.TrackSource.camera, _Stream(), _Track(), const lk.CameraCaptureOptions())
      ..codec = 'h264';
    final pub = lk.LocalTrackPublication<lk.LocalVideoTrack>(
      participant: me,
      info: pb.TrackInfo(sid: 'TR_cam', type: pb.TrackType.VIDEO, source: pb.TrackSource.CAMERA, encryption: pb.Encryption_Type.GCM),
      track: camera,
    )..backupVideoCodec = callVideoPublishOptions(media.preset, 'h264').backupVideoCodec;
    me.addTrackPublication(pub);
    expect(pub.backupVideoCodec!.enabled, isFalse);
    expect(pc.added, isEmpty);

    // The hostile server: "a subscriber needs VP8 of TR_cam".
    engine.signalClient.events.emit(lk_internal.SignalSubscribedQualityUpdatedEvent(
      trackSid: 'TR_cam',
      subscribedQualities: const [],
      subscribedCodecs: [
        pb_rtc.SubscribedCodec(
          codec: 'vp8',
          qualities: [pb_rtc.SubscribedQuality(quality: pb.VideoQuality.HIGH, enabled: true)],
        ),
      ],
    ));
    await pumpEventQueue();
    // ...and it answers the AddTrackRequest for the new sender (no `encryption` in it).
    engine.signalClient.events.emit(lk_internal.SignalLocalTrackPublishedEvent(cid: 'backup-sender', track: pb.TrackInfo()));
    await pumpEventQueue();

    expect(pc.added, isEmpty, reason: 'no second sender for my camera');
    expect(camera.simulcastCodecs, isEmpty);
  });

  test('dynacast is off; a codec that makes LiveKit turn it back on is refused', () {
    final media = (deviceClass: CallDeviceClass.standard, preset: callVideoPreset(CallDeviceClass.standard), codec: 'h264');
    final keys = CallKeyProvider(
      _NativeKeys(),
      rtc.KeyProviderOptions(sharedKey: false, ratchetSalt: Uint8List(0), ratchetWindowSize: 0),
    );
    expect(callRoomOptions(lk.E2EEOptions(keyProvider: keys), media).dynacast, isFalse);
    // local.dart:302 — publishing VP9 / AV1 (the server's choice through
    // `enabled_publish_codecs`) sets dynacast to true again.
    for (final codec in ['vp9', 'VP9', 'av1']) {
      expect(callTrackEncrypted(lk.EncryptionType.kGcm, codec: codec), isFalse, reason: codec);
    }
    for (final codec in ['vp8', 'h264', 'h265', '']) {
      expect(callTrackEncrypted(lk.EncryptionType.kGcm, codec: codec), isTrue, reason: codec);
    }
  });
}
