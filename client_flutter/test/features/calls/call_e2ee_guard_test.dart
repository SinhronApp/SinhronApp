// Security review 2026-11 (docs/security-review-2026-11.md, calls:1–3) —
// a hostile LiveKit server must not get a call into the clear: a track it
// marks "not encrypted" ends the call; it can't slip frames in through the
// known "unencrypted frame" trailer; data messages are encrypted too.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_path.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/call_timeline.dart';
import 'package:sinhron/features/calls/live_call_screen.dart' show callEndedLabel;
import 'package:sinhron/features/calls/livekit_engine.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import 'active_call_provider_test.dart' show FakeNetService;

/// Remembers what the native key provider was asked to do.
class _NativeKeys extends rtc.KeyProvider {
  final trailers = <Uint8List>[];
  @override
  String get id => 'fake';
  @override
  Future<void> setSifTrailer({required Uint8List trailer}) async => trailers.add(trailer);
  @override
  Future<bool> setKey({required String participantId, required int index, required Uint8List key}) async => true;
  @override
  Future<Uint8List> ratchetKey({required String participantId, required int index}) async => Uint8List(0);
  @override
  Future<Uint8List> exportKey({required String participantId, required int index}) async => Uint8List(0);
  @override
  Future<void> dispose() async {}
}

final _media = (deviceClass: CallDeviceClass.standard, preset: callVideoPreset(CallDeviceClass.standard), codec: 'vp8');

CallKeyProvider _keys(_NativeKeys native) => CallKeyProvider(
  native,
  rtc.KeyProviderOptions(
    sharedKey: false,
    ratchetSalt: Uint8List.fromList(lk.defaultRatchetSalt.codeUnits),
    ratchetWindowSize: 0,
    uncryptedMagicBytes: Uint8List.fromList(callUncryptedMagicBytes().codeUnits),
  ),
);

/// Joins for real nowhere; keeps the engine's "room gone" callback.
class _Engine extends CallEngine {
  void Function(String reason)? onDisconnected;

  @override
  Future<CallPrep> prepare({required String httpBaseUrl, required String groupIdHex, required String kind}) async =>
      CallPrep(
        groupIdHex: groupIdHex,
        kind: kind,
        token: core.LivekitTokenInfo(
          token: 't',
          livekitUrl: 'wss://lk.example',
          room: 'r',
          expiresAtUnix: 0,
          ttlSecs: 3600,
          videoCodecs: const [],
        ),
        turn: const core.TurnCredsInfo(username: 'u', credential: 'c', urls: [], ttlSecs: 0),
        media: _media,
      );

  @override
  Future<LiveKitSession> connect({
    required CallPrep prep,
    void Function()? onReconnecting,
    void Function()? onReconnected,
    void Function(String reason)? onDisconnected,
    CallPath path = CallPath.direct,
    bool micMuted = false,
    bool camera = true,
    CallTimeline? timeline,
    bool? speaker,
  }) {
    this.onDisconnected = onDisconnected;
    return Completer<LiveKitSession>().future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('calls:1 — a track the server marks unencrypted is refused', () {
    test('server says NONE: refused (mine, received, announced)', () {
      expect(callTrackEncrypted(lk.EncryptionType.kNone, codec: 'vp8'), isFalse);
      expect(callTrackEncrypted(lk.EncryptionType.kNone, mimeType: 'audio/opus'), isFalse);
      expect(callTrackEncrypted(lk.EncryptionType.kNone), isFalse);
      expect(callTrackEncrypted(lk.EncryptionType.kCustom, mimeType: 'video/vp8'), isFalse);
    });

    test('server forces AV1 (LiveKit puts no cryptor on it) or a broken type: refused', () {
      expect(callTrackEncrypted(lk.EncryptionType.kGcm, codec: 'AV1'), isFalse);
      expect(callTrackEncrypted(lk.EncryptionType.kGcm, mimeType: 'video/AV1'), isFalse);
      expect(callTrackEncrypted(lk.EncryptionType.kGcm, mimeType: 'video'), isFalse);
    });

    test('an honest call (this and older versions all publish GCM): accepted', () {
      for (final codec in ['vp8', 'h264', 'h265', '']) {
        expect(callTrackEncrypted(lk.EncryptionType.kGcm, codec: codec), isTrue, reason: codec);
      }
      for (final mime in ['audio/opus', 'audio/red', 'video/VP8', 'video/H264', 'video/H265']) {
        expect(callTrackEncrypted(lk.EncryptionType.kGcm, mimeType: mime), isTrue, reason: mime);
      }
      expect(callTrackEncrypted(lk.EncryptionType.kGcm), isTrue);
    });

    test('the engine reporting it ends the call as "not encrypted", not "the other side left"', () async {
      final engine = _Engine();
      late FakeNetService net;
      final c = ProviderContainer(
        overrides: [
          netServiceProvider.overrideWith((ref) => net = FakeNetService(ref)),
          callEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(c.dispose);
      c.read(activeCallProvider);
      const id = '01900000-0000-7000-8000-0000000000e1';
      net.pushEvent(
        core.NetEvent(
          kind: 'call_invite',
          callInvite: core.NetCallInvite(
            callId: id,
            groupIdHex: 'g1',
            kind: 'audio',
            livekitRoom: 'sinhron-call-$id',
            ttlSecs: 30,
            callerIdentityHex: 'ca' * 32, // ADR-090: a signed invite
          ),
        ),
      );
      await pumpEventQueue();
      c.read(activeCallProvider.notifier).debugAnswered();
      await pumpEventQueue();
      expect(c.read(activeCallProvider).phase, CallPhase.connected);
      expect(engine.onDisconnected, isNotNull, reason: 'joining the room');

      engine.onDisconnected!(kCallNotEncrypted);
      await pumpEventQueue();
      final s = c.read(activeCallProvider);
      expect(s.phase, CallPhase.ended);
      expect(s.endReason, kCallNotEncrypted);
      expect(callEndedLabel(lookupAppL10n(const Locale('ru')), s), 'Звонок прерван: сервер пытался отключить шифрование');
    });
  });

  group('calls:2 — the server cannot inject unencrypted frames', () {
    test('the trailer is not the public LK-ROCKS, 32 random bytes, new each call', () {
      final a = callUncryptedMagicBytes();
      final b = callUncryptedMagicBytes();
      expect(a, isNot(lk.defaultMagicBytes));
      expect(a.codeUnits, hasLength(32));
      expect(a.codeUnits.every((u) => u < 256), isTrue, reason: 'bytes, as LiveKit passes them on');
      expect(a, isNot(b));
    });

    test('a trailer the server sends (JoinResponse.sif_trailer) is ignored', () async {
      final native = _NativeKeys();
      final keys = _keys(native);
      final mine = List.of(keys.options.uncryptedMagicBytes!);
      await keys.setSifTrailer(Uint8List.fromList(utf8.encode('LK-ROCKS')));
      expect(native.trailers, isEmpty);
      expect(keys.options.uncryptedMagicBytes, mine);
    });
  });

  test('calls:3 — data messages (the codec agreement) are encrypted too', () {
    final opts = callRoomOptions(lk.E2EEOptions(keyProvider: _keys(_NativeKeys())), _media);
    // livekit_client 2.7.0 encrypts data only when `encryption` is set
    // (room.dart: dcEncryptionEnabled: roomOptions.encryption != null).
    expect(opts.encryption, isNotNull);
    expect(opts.encryption!.encryptionType, lk.EncryptionType.kGcm);
  });
}
