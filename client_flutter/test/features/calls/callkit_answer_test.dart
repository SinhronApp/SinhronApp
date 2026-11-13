// Owner, 2026-10-16: answering with the app's own Accept button left the
// iPhone's "Accept call" banner on screen — the app never told CallKit.
// Now `answer` reaches the native side (CallKit answer action on iOS, the
// incoming-call notification dropped on Android).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/callkit_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    CallKitBridge.debugNative = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.sinhron/callkit'),
      (call) async {
        calls.add(call);
        return true;
      },
    );
  });

  tearDown(() {
    CallKitBridge.debugNative = null;
    CallKitBridge.debugAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.sinhron/callkit'),
      null,
    );
  });

  test('answering in the app tells the system call UI', () async {
    await CallKitBridge().answer('c1');
    expect(calls.single.method, 'answerCall');
    expect(calls.single.arguments, {'call_id': 'c1'});
  });

  test('off a phone nothing is sent', () async {
    CallKitBridge.debugNative = false;
    await CallKitBridge().answer('c1');
    expect(calls, isEmpty);
  });

  // Owner, 2026-10-18: "the camera must not close when the call is minimised".
  // Android: the call's foreground service needs the camera type for that —
  // announced again when an audio call turns video.
  test('Android: the connected call is announced with its camera', () async {
    CallKitBridge.debugAndroid = true;
    await CallKitBridge().callConnected(callId: 'c1', peerName: 'Вера', video: true);
    expect(calls.single.method, 'startCall');
    expect(calls.single.arguments, {'call_id': 'c1', 'peer_name': 'Вера', 'video': true});
  });

  test('the keep-alive takes the camera for a video call or a camera turned on', () {
    expect(callKeepsCamera(const ActiveCallState(kind: CallKind.video)), isTrue);
    expect(callKeepsCamera(const ActiveCallState(kind: CallKind.audio)), isFalse);
    expect(callKeepsCamera(const ActiveCallState(kind: CallKind.audio, cameraOn: true)), isTrue);
  });
}
