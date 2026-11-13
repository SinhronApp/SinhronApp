// ADR-041 — calls on poor internet and weak phones: preset, codec, link
// notice and the audio-only fallback.

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:sinhron/features/calls/call_quality.dart';

void main() {
  group('device class', () {
    test('iPhone 11 and newer (iPhone12,x+), iPad from iPad13 → high; older and unknown → standard', () {
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'iPhone12,1'), CallDeviceClass.high); // 11
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'iPhone17,3'), CallDeviceClass.high); // 16
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'iPhone11,8'), CallDeviceClass.standard); // XR
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'iPhone10,3'), CallDeviceClass.standard); // X
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'iPad13,1'), CallDeviceClass.high);
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'iPad11,6'), CallDeviceClass.standard);
      expect(classifyCallDevice(isAndroid: false, iosMachine: 'arm64'), CallDeviceClass.standard); // Simulator
      expect(classifyCallDevice(isAndroid: false, ramMb: 2048, cores: 2), CallDeviceClass.standard);
    });

    test('Android: ≤ 4 GB RAM, the low-RAM flag, ≤ 4 cores or Android < 9 → low', () {
      // A 4 GB phone reports ~3.7 GB of totalMem.
      expect(classifyCallDevice(isAndroid: true, ramMb: 3700, cores: 8, sdkInt: 33), CallDeviceClass.low);
      expect(classifyCallDevice(isAndroid: true, ramMb: kLowEndRamMb, cores: 8, sdkInt: 33), CallDeviceClass.low);
      expect(
        classifyCallDevice(isAndroid: true, ramMb: 8000, cores: 8, isLowRamDevice: true, sdkInt: 33),
        CallDeviceClass.low,
      );
      expect(classifyCallDevice(isAndroid: true, ramMb: 8000, cores: 4, sdkInt: 33), CallDeviceClass.low);
      expect(classifyCallDevice(isAndroid: true, ramMb: 8000, cores: 8, sdkInt: 27), CallDeviceClass.low);
    });

    test('Android: a 6 GB, 8-core phone on a recent OS is standard', () {
      expect(classifyCallDevice(isAndroid: true, ramMb: 5600, cores: 8, sdkInt: 34), CallDeviceClass.standard);
    });

    test('Android: ≥ 8 GB, ≥ 8 cores and Android 11+ → high; any one missing → standard', () {
      // An 8 GB phone reports ~7.4 GB of totalMem.
      expect(classifyCallDevice(isAndroid: true, ramMb: 7400, cores: 8, sdkInt: 34), CallDeviceClass.high);
      expect(classifyCallDevice(isAndroid: true, ramMb: 7400, cores: 6, sdkInt: 34), CallDeviceClass.standard);
      expect(classifyCallDevice(isAndroid: true, ramMb: 7400, cores: 8, sdkInt: 29), CallDeviceClass.standard);
      expect(classifyCallDevice(isAndroid: true, ramMb: 7400, cores: 8), CallDeviceClass.standard);
    });

    test('unknown values (device info failed) do not count against the phone', () {
      expect(classifyCallDevice(isAndroid: true), CallDeviceClass.standard);
      expect(classifyCallDevice(isAndroid: true, ramMb: 0, cores: 0, sdkInt: 0), CallDeviceClass.standard);
    });
  });

  group('video preset', () {
    test('high: 1080p, 30 fps, 2.5 Mbps top, 180p + 540p layers', () {
      final p = callVideoPreset(CallDeviceClass.high);
      expect(p.capture.dimensions.height, 1080);
      expect(p.capture.encoding!.maxBitrate, 2500000);
      expect(p.capture.encoding!.maxFramerate, 30);
      expect(p.maxFps, 30);
      expect(p.simulcastLayers.map((l) => l.dimensions.height), [180, 540]);
    });

    test('standard: 720p, 30 fps, 1.5 Mbps top, 180p + 360p layers', () {
      final p = callVideoPreset(CallDeviceClass.standard);
      expect(p.capture.dimensions.height, 720);
      expect(p.capture.encoding!.maxBitrate, 1500000);
      expect(p.capture.encoding!.maxFramerate, 30);
      expect(p.maxFps, 30);
      expect(p.simulcastLayers.map((l) => l.dimensions.height), [180, 360]);
    });

    test('low: 360p, 15 fps, 350 kbps top, one 180p layer', () {
      final p = callVideoPreset(CallDeviceClass.low);
      expect(p.capture.dimensions.height, 360);
      expect(p.capture.encoding!.maxBitrate, 350000);
      expect(p.maxFps, 15);
      expect(p.simulcastLayers.map((l) => l.dimensions.height), [180]);
    });

    test('every layer is lighter than the top one', () {
      for (final c in CallDeviceClass.values) {
        final p = callVideoPreset(c);
        for (final l in p.simulcastLayers) {
          expect(l.encoding!.maxBitrate, lessThan(p.capture.encoding!.maxBitrate));
          expect(l.dimensions.height, lessThan(p.capture.dimensions.height));
        }
      }
    });
  });

  group('video ceiling (ADR-046)', () {
    test('device, link and heat: the lowest of the three wins', () {
      VideoCeiling? c(CallDeviceClass d, CallLinkQuality q, [int heat = 0]) =>
          videoCeilingFor(device: d, link: q, thermal: heat);
      const hi = CallDeviceClass.high, std = CallDeviceClass.standard;
      expect(c(hi, CallLinkQuality.excellent), VideoCeiling.p1080);
      expect(c(hi, CallLinkQuality.good), VideoCeiling.p720);
      expect(c(hi, CallLinkQuality.unknown), VideoCeiling.p720, reason: 'not measured yet: start at 720p');
      expect(c(hi, CallLinkQuality.poor), VideoCeiling.p540);
      expect(c(hi, CallLinkQuality.lost), VideoCeiling.p540);
      expect(c(std, CallLinkQuality.excellent), VideoCeiling.p720, reason: 'an ordinary phone tops out at 720p');
      expect(c(hi, CallLinkQuality.excellent, 1), VideoCeiling.p1080, reason: 'fair heat is fine');
      expect(c(hi, CallLinkQuality.excellent, 2), VideoCeiling.p720);
      expect(c(hi, CallLinkQuality.excellent, 3), VideoCeiling.p540);
      expect(c(std, CallLinkQuality.good, 3), VideoCeiling.p540);
      expect(c(CallDeviceClass.low, CallLinkQuality.excellent), isNull, reason: 'weak phones stay at 360p');
    });

    test('the top layer: scale from the capture, bitrate and frame rate per height', () {
      expect(topLayerFor(VideoCeiling.p1080, 1080), (scaleDownBy: 1.0, maxBitrate: 2500000, maxFramerate: 30));
      expect(topLayerFor(VideoCeiling.p720, 1080), (scaleDownBy: 1.5, maxBitrate: 1500000, maxFramerate: 30));
      expect(topLayerFor(VideoCeiling.p540, 1080), (scaleDownBy: 2.0, maxBitrate: 800000, maxFramerate: 24));
      expect(topLayerFor(VideoCeiling.p720, 720), (scaleDownBy: 1.0, maxBitrate: 1500000, maxFramerate: 30));
      // A 720p capture can't go above 720p.
      expect(topLayerFor(VideoCeiling.p1080, 720), (scaleDownBy: 1.0, maxBitrate: 1500000, maxFramerate: 30));
      expect(topLayerFor(VideoCeiling.p540, 720).scaleDownBy, closeTo(1.333, 0.001));
    });

    test('down at once, up only after the better target holds for 10 s', () {
      final c = VideoCeilingController();
      final t0 = DateTime(2026, 10, 18, 12);
      expect(c.update(VideoCeiling.p720, t0), VideoCeiling.p720, reason: 'first value applies at once');
      expect(c.update(VideoCeiling.p1080, t0.add(const Duration(seconds: 1))), isNull);
      expect(c.update(VideoCeiling.p1080, t0.add(const Duration(seconds: 6))), isNull);
      expect(c.update(VideoCeiling.p1080, t0.add(const Duration(seconds: 11))), VideoCeiling.p1080);
      expect(c.current, VideoCeiling.p1080);
      expect(c.update(VideoCeiling.p540, t0.add(const Duration(seconds: 12))), VideoCeiling.p540, reason: 'down: now');
      // A flicker up and back resets the wait.
      expect(c.update(VideoCeiling.p720, t0.add(const Duration(seconds: 13))), isNull);
      expect(c.update(VideoCeiling.p540, t0.add(const Duration(seconds: 14))), isNull);
      expect(c.update(VideoCeiling.p720, t0.add(const Duration(seconds: 20))), isNull);
      expect(c.update(VideoCeiling.p720, t0.add(const Duration(seconds: 29))), isNull);
      expect(c.update(VideoCeiling.p720, t0.add(const Duration(seconds: 30))), VideoCeiling.p720);
      expect(c.update(null, t0.add(const Duration(seconds: 31))), isNull);
    });
  });

  group('codec', () {
    test('H.264 when the encoder list has it, VP8 otherwise', () {
      expect(chooseVideoCodec(encoderMimeTypes: ['video/VP8', 'video/H264', 'video/VP9']), 'h264');
      expect(chooseVideoCodec(encoderMimeTypes: ['video/VP8', 'video/VP9', 'video/AV1']), 'vp8');
      expect(chooseVideoCodec(encoderMimeTypes: const []), 'vp8');
    });

    test('the kill switch brings VP8 back everywhere', () {
      expect(chooseVideoCodec(encoderMimeTypes: ['video/H264'], preferH264: false), 'vp8');
    });

    test('publish options: simulcast on, backup codec OFF (it would bypass SFrame)', () {
      final o = callVideoPublishOptions(callVideoPreset(CallDeviceClass.standard), 'h264');
      expect(o.videoCodec, 'h264');
      expect(o.simulcast, isTrue);
      expect(o.backupVideoCodec.enabled, isFalse);
      expect(o.videoEncoding!.maxBitrate, 1500000);
      expect(o.videoSimulcastLayers, hasLength(2));
    });

    test('voice: Opus speech bitrate with DTX and RED', () {
      expect(kCallAudioPublishOptions.dtx, isTrue);
      expect(kCallAudioPublishOptions.red, isTrue);
      expect(kCallAudioPublishOptions.encoding!.maxBitrate, 32000, reason: "starts at 32 kbps, then follows the link");
    });
  });

  group('link quality', () {
    test('LiveKit grades map one to one', () {
      expect(callLinkQualityFrom(lk.ConnectionQuality.excellent), CallLinkQuality.excellent);
      expect(callLinkQualityFrom(lk.ConnectionQuality.good), CallLinkQuality.good);
      expect(callLinkQualityFrom(lk.ConnectionQuality.poor), CallLinkQuality.poor);
      expect(callLinkQualityFrom(lk.ConnectionQuality.lost), CallLinkQuality.lost);
      expect(callLinkQualityFrom(lk.ConnectionQuality.unknown), CallLinkQuality.unknown);
    });

    test('bars and "bad"', () {
      expect(CallLinkQuality.values.map((q) => q.bars), [3, 3, 2, 1, 0]);
      expect(CallLinkQuality.values.where((q) => q.isBad), [CallLinkQuality.poor, CallLinkQuality.lost]);
    });

    test('notice: audio-only switch first, then my link, then theirs', () {
      expect(callNoticeFor(mine: CallLinkQuality.good, peerBad: false, autoAudioOnly: false), CallNotice.none);
      expect(callNoticeFor(mine: CallLinkQuality.poor, peerBad: true, autoAudioOnly: false), CallNotice.weakMine);
      expect(callNoticeFor(mine: CallLinkQuality.excellent, peerBad: true, autoAudioOnly: false), CallNotice.weakPeer);
      expect(callNoticeFor(mine: CallLinkQuality.poor, peerBad: true, autoAudioOnly: true), CallNotice.autoAudioOnly);
    });
  });

  group('audio-only fallback', () {
    final t0 = DateTime(2026, 10, 16, 12);
    DateTime at(int s) => t0.add(Duration(seconds: s));

    test('poor for 8 s with the camera on → switch', () {
      final f = AudioOnlyFallback();
      f.report(CallLinkQuality.poor, at(0));
      expect(f.due(now: at(7), cameraOn: true), isFalse);
      expect(f.due(now: at(8), cameraOn: true), isTrue);
    });

    test('never with the camera already off', () {
      final f = AudioOnlyFallback();
      f.report(CallLinkQuality.lost, at(0));
      expect(f.due(now: at(60), cameraOn: false), isFalse);
    });

    test('a short dip does not switch; the clock restarts after recovery', () {
      final f = AudioOnlyFallback();
      f.report(CallLinkQuality.poor, at(0));
      f.report(CallLinkQuality.good, at(5));
      expect(f.due(now: at(9), cameraOn: true), isFalse);
      f.report(CallLinkQuality.poor, at(10));
      expect(f.due(now: at(17), cameraOn: true), isFalse);
      expect(f.due(now: at(18), cameraOn: true), isTrue);
    });

    test('poor → lost is one bad stretch', () {
      final f = AudioOnlyFallback();
      f.report(CallLinkQuality.poor, at(0));
      f.report(CallLinkQuality.lost, at(4));
      expect(f.badSince, at(0));
      expect(f.due(now: at(8), cameraOn: true), isTrue);
    });

    test('after a switch the next one needs a fresh bad stretch', () {
      final f = AudioOnlyFallback();
      f.report(CallLinkQuality.poor, at(0));
      expect(f.due(now: at(8), cameraOn: true), isTrue);
      f.fired();
      expect(f.due(now: at(9), cameraOn: true), isFalse);
    });

    test('the person turned the camera back on: 30 s before stepping in again', () {
      final f = AudioOnlyFallback();
      f.report(CallLinkQuality.poor, at(0));
      f.fired();
      f.report(CallLinkQuality.poor, at(10));
      f.userTurnedCameraOn(at(20));
      expect(f.holdNow, const Duration(seconds: 30));
      expect(f.due(now: at(49), cameraOn: true), isFalse);
      expect(f.due(now: at(50), cameraOn: true), isTrue);
    });
  });
}
