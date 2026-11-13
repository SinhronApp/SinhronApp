// Audit 2026-11b (11) — the server stays silent on a publish: LiveKit has
// already put my live mic on the connection (the server picked that
// order) and never gives it an SFrame cryptor. After the failed publish
// the app stops that track and ends the call (`callPublishFailed`).
// The real livekit_client path runs here over a fake peer connection.


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore_for_file: implementation_imports, invalid_use_of_internal_member
import 'package:livekit_client/src/core/engine.dart' as lk_engine;
import 'package:livekit_client/src/e2ee/e2ee_manager.dart' as lk_e2ee;
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
  _Track([this.id = 'mic-track', this.kind = 'audio']);
  int stops = 0;
  @override
  final String? id;
  @override
  final String? kind;
  @override
  bool get enabled => true;
  @override
  bool? get muted => false;
  @override
  Future<void> stop() async => stops++;
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
  _Sender(this.track);
  @override
  final rtc.MediaStreamTrack? track;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Transceiver implements rtc.RTCRtpTransceiver {
  _Transceiver(this.sender);
  @override
  final rtc.RTCRtpSender sender;
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _Pc implements rtc.RTCPeerConnection {
  final sent = <rtc.RTCRtpSender>[];

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async {
    sent.add(_Sender(track));
    return _Transceiver(sent.last);
  }

  @override
  Future<List<rtc.RTCRtpSender>> getSenders() async => sent;

  @override
  Future<rtc.RTCSessionDescription> createOffer([Map<String, dynamic>? constraints]) async =>
      rtc.RTCSessionDescription('v=0\r\n', 'offer');

  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription description) async {}

  @override
  Future<rtc.RTCSignalingState?> getSignalingState() async => rtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the server never answers AddTrack: the mic left on the connection is stopped and the call ends', () async {
    final native = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        native.add(call.method);
        return call.method == 'createDataPacketCryptor' ? {'dataCryptorId': 'dc'} : null;
      },
    );

    final media = (deviceClass: CallDeviceClass.standard, preset: callVideoPreset(CallDeviceClass.standard), codec: 'h264');
    final keys = CallKeyProvider(
      _NativeKeys(),
      rtc.KeyProviderOptions(sharedKey: false, ratchetSalt: Uint8List(0), ratchetWindowSize: 0),
    );
    final publisher = _Pc(), subscriber = _Pc();
    var made = 0;
    final engine = lk_engine.Engine(
      // LiveKit's publish timeout is 10 s; the test does not wait that long.
      connectOptions: const lk.ConnectOptions(
        timeouts: lk.Timeouts(
          connection: Duration(seconds: 10),
          debounce: Duration(milliseconds: 20),
          publish: Duration(milliseconds: 200),
          subscribe: Duration(seconds: 10),
          peerConnection: Duration(seconds: 10),
          iceRestart: Duration(seconds: 10),
        ),
      ),
      roomOptions: callRoomOptions(lk.E2EEOptions(keyProvider: keys), media),
      peerConnectionCreate: (cfg, [constraints = const {}]) async => made++ == 0 ? publisher : subscriber,
    );
    final room = lk.Room(engine: engine);
    final e2ee = lk_e2ee.E2EEManager(keys, dcEncryptionEnabled: true);
    await e2ee.setup(room);
    engine.setE2eeManager(e2ee);

    openCallRooms.add(room);
    callPublishGrace = const Duration(milliseconds: 50);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        null,
      );
      openCallRooms.remove(room);
      callPublishGrace = const Duration(seconds: 12);
    });
    final refused = <String>[];
    callRefusers[room] = (what, reason) => refused.add(reason);

    // Nothing on the connection (no camera, a refused mic): the call goes on.
    await callPublishFailed(room);
    expect(refused, isEmpty);

    // The server's JoinResponse: it chooses the "publish in parallel" branch.
    engine.signalClient.events.emit(lk_internal.SignalJoinResponseEvent(
      response: pb_rtc.JoinResponse(
        participant: pb.ParticipantInfo(sid: 'PA_me', identity: 'me'),
        subscriberPrimary: true,
        fastPublish: true,
        enabledPublishCodecs: [pb.Codec(mime: 'audio/opus'), pb.Codec(mime: 'video/h264')],
      ),
    ));
    await pumpEventQueue();
    final me = room.localParticipant!;
    expect(engine.enabledPublishCodecs, isNotEmpty);

    // A camera / screen track the server did not confirm (also a lost reply
    // on a bad network): stopped, the call goes on with sound only.
    final cam = _Track('cam-track', 'video');
    publisher.sent.add(_Sender(cam));
    await callPublishFailed(room);
    expect(cam.stops, 1, reason: 'the camera is stopped');
    expect(refused, isEmpty, reason: 'and the call goes on');
    publisher.sent.clear();

    // An honest publish still on its way when another one fails (queued
    // behind it, or published again after a reconnect): by the second look
    // it is a publication (here: gone from the list) — left alone.
    final onItsWay = _Track('queued-mic', 'audio');
    publisher.sent.add(_Sender(onItsWay));
    final check = callPublishFailed(room);
    await pumpEventQueue();
    publisher.sent.clear();
    await check;
    expect(onItsWay.stops, 0, reason: 'not stopped');
    expect(refused, isEmpty, reason: 'and the call goes on');

    // Audit 2026-11b (61) — the same after a reconnect, where LiveKit
    // publishes again by itself and no publish call of the app fails.
    checkPublishesAfterReconnect(room);
    final again = _Track('mic-after-reconnect', 'audio');
    // An honest reconnect: everything on the connection is a publication.
    room.events.emit(const lk.RoomReconnectedEvent());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(refused, isEmpty, reason: 'an honest reconnect ends nothing');

    // Sinhron: `room.localParticipant?.publishAudioTrack(mic)` (livekit_engine.dart:565).
    final micTrack = _Track();
    final mic = lk.LocalAudioTrack(lk.TrackSource.microphone, _Stream(), micTrack, const lk.AudioCaptureOptions());
    await expectLater(me.publishAudioTrack(mic), throwsA(isA<lk.TrackPublishException>())); // the server stays silent
    expect(publisher.sent.map((s) => s.track?.id), ['mic-track'], reason: 'the live mic is on the connection');
    expect(native.where((m) => m.toLowerCase().contains('framecryptor')), isEmpty, reason: 'with no frame cryptor');

    // Sinhron, in the catch around every publish:
    await callPublishFailed(room);
    expect(micTrack.stops, 1, reason: 'the mic is stopped');
    // The call ends as "couldn't connect" — not as "not encrypted".
    expect(refused, [kCallMediaFailed]);
    // The stopped tracks are not taken for new ones later.
    await callPublishFailed(room);
    expect(micTrack.stops, 1);
    expect(refused, hasLength(1));

    // The server is silent on the publish after a reconnect: stopped too.
    publisher.sent.add(_Sender(again));
    room.events.emit(const lk.RoomReconnectedEvent());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(again.stops, 1, reason: 'the mic left bare by the reconnect is stopped');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
