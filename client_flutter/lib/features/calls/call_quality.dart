// ADR-041 — calls on poor internet and weak phones.
//
// Pure decisions, no plugins: which camera preset and codec to publish
// with, how the link quality reads on screen, and when a call that keeps
// a poor link drops my camera so the voice survives. The LiveKit engine
// and the call provider feed them real values; tests feed them numbers.

import 'package:livekit_client/livekit_client.dart' as lk;

/// What this phone can afford to encode (ADR-046): `high` sends up to
/// 1080p, `standard` up to 720p, `low` 360p.
enum CallDeviceClass { high, standard, low }

/// iPhone: `high` from the iPhone 11 (model id `iPhone12,x`, A13 — 1080p
/// H.265 in hardware with room to spare), iPad from `iPad13,x` (A14 / M1);
/// older ones and unknown ids (the Simulator) are `standard` — every
/// supported iPhone encodes 720p in hardware.
///
/// Android: "low" when the OS says so (`isLowRamDevice`), ≤ 4 GB RAM
/// (`totalMem` of a 4 GB phone reads ~3.6–3.9 GB, a 6 GB one ~5.5 GB),
/// ≤ 4 cores, or Android < 9 (old hardware); `high` with ≥ 8 GB (reads
/// ~7.2–7.6 GB), ≥ 8 cores and Android 11+ — this year's and last
/// year's mid-range and flagships. Unknown values don't count either way.
CallDeviceClass classifyCallDevice({
  required bool isAndroid,
  int? ramMb,
  int? cores,
  bool isLowRamDevice = false,
  int? sdkInt,
  String? iosMachine,
}) {
  if (!isAndroid) return _appleClass(iosMachine);
  if (isLowRamDevice) return CallDeviceClass.low;
  if (ramMb != null && ramMb > 0 && ramMb <= kLowEndRamMb) return CallDeviceClass.low;
  if (cores != null && cores > 0 && cores <= 4) return CallDeviceClass.low;
  if (sdkInt != null && sdkInt > 0 && sdkInt < 28) return CallDeviceClass.low;
  final strong =
      ramMb != null && ramMb >= kHighEndRamMb && cores != null && cores >= 8 && sdkInt != null && sdkInt >= 30;
  return strong ? CallDeviceClass.high : CallDeviceClass.standard;
}

CallDeviceClass _appleClass(String? machine) {
  final m = RegExp(r'^(iPhone|iPad)(\d+),').firstMatch(machine ?? '');
  if (m == null) return CallDeviceClass.standard;
  final gen = int.parse(m.group(2)!);
  final high = m.group(1) == 'iPhone' ? gen >= 12 : gen >= 13;
  return high ? CallDeviceClass.high : CallDeviceClass.standard;
}

/// `totalMem` at or below this is a "4 GB or less" phone.
const kLowEndRamMb = 4608;

/// `totalMem` at or above this is an "8 GB or more" phone.
const kHighEndRamMb = 6900;

/// Camera capture + publish settings for one device class.
class CallVideoPreset {
  const CallVideoPreset({required this.capture, required this.simulcastLayers, required this.maxFps});

  /// Capture size and the top simulcast layer's bitrate / frame rate.
  final lk.VideoParameters capture;

  /// The lower layers (LiveKit picks 1–2 of them by capture size).
  final List<lk.VideoParameters> simulcastLayers;

  final double maxFps;
}

/// ADR-046 — capture and the top simulcast layer: 1080p / 30 fps /
/// 2.5 Mbps on strong phones, 720p / 30 fps / 1.5 Mbps on ordinary ones,
/// 360p / 15 fps / 350 kbps on weak Android (was 540p / 24 fps / 700 kbps
/// for everyone but the weak). The top layer is a ceiling, not a promise:
/// [videoCeilingFor] lowers it on the fly with the link and the heat, and
/// the lower layers keep simulcast — a viewer on a bad link gets 540p /
/// 360p / 180p instead of nothing. A 360p capture makes LiveKit send two
/// layers, not three — one encoder fewer on a phone with no CPU to spare.
CallVideoPreset callVideoPreset(CallDeviceClass c) => switch (c) {
  CallDeviceClass.high => const CallVideoPreset(
    capture: lk.VideoParameters(
      dimensions: lk.VideoDimensionsPresets.h1080_169,
      encoding: lk.VideoEncoding(maxBitrate: 2500 * 1000, maxFramerate: 30),
    ),
    simulcastLayers: [
      lk.VideoParameters(
        dimensions: lk.VideoDimensionsPresets.h180_169,
        encoding: lk.VideoEncoding(maxBitrate: 160 * 1000, maxFramerate: 15),
      ),
      lk.VideoParameters(
        dimensions: lk.VideoDimensionsPresets.h540_169,
        encoding: lk.VideoEncoding(maxBitrate: 800 * 1000, maxFramerate: 24),
      ),
    ],
    maxFps: 30,
  ),
  CallDeviceClass.standard => const CallVideoPreset(
    capture: lk.VideoParameters(
      dimensions: lk.VideoDimensionsPresets.h720_169,
      encoding: lk.VideoEncoding(maxBitrate: 1500 * 1000, maxFramerate: 30),
    ),
    simulcastLayers: [
      lk.VideoParameters(
        dimensions: lk.VideoDimensionsPresets.h180_169,
        encoding: lk.VideoEncoding(maxBitrate: 150 * 1000, maxFramerate: 15),
      ),
      lk.VideoParameters(
        dimensions: lk.VideoDimensionsPresets.h360_169,
        encoding: lk.VideoEncoding(maxBitrate: 450 * 1000, maxFramerate: 24),
      ),
    ],
    maxFps: 30,
  ),
  CallDeviceClass.low => const CallVideoPreset(
    capture: lk.VideoParameters(
      dimensions: lk.VideoDimensionsPresets.h360_169,
      encoding: lk.VideoEncoding(maxBitrate: 350 * 1000, maxFramerate: 15),
    ),
    simulcastLayers: [
      lk.VideoParameters(
        dimensions: lk.VideoDimensionsPresets.h180_169,
        encoding: lk.VideoEncoding(maxBitrate: 100 * 1000, maxFramerate: 12),
      ),
    ],
    maxFps: 15,
  ),
};

// ─── ADR-046 — the top layer follows the link and the heat ─────────────

/// How high my best picture goes right now. Ordered low → high.
enum VideoCeiling { p540, p720, p1080 }

extension VideoCeilingX on VideoCeiling {
  int get height => switch (this) {
    VideoCeiling.p540 => 540,
    VideoCeiling.p720 => 720,
    VideoCeiling.p1080 => 1080,
  };

  VideoCeiling min(VideoCeiling o) => index <= o.index ? this : o;
}

/// The phone's heat, on iOS's scale (Android's thermal status mapped onto
/// it): 0 nominal, 1 fair, 2 serious, 3 critical.
typedef ThermalLevel = int;

/// The ceiling for my top layer: what the phone can encode (1080p strong,
/// 720p ordinary), what my link carries (excellent → 1080p, good or not
/// measured yet → 720p, poor / lost → 540p) and how hot the phone is
/// (serious → 720p, critical → 540p — FaceTime steps down the same way).
/// Null for a weak phone: its 360p top layer is already the floor.
VideoCeiling? videoCeilingFor({
  required CallDeviceClass device,
  required CallLinkQuality link,
  ThermalLevel thermal = 0,
}) {
  if (device == CallDeviceClass.low) return null;
  final byDevice = device == CallDeviceClass.high ? VideoCeiling.p1080 : VideoCeiling.p720;
  final byLink = switch (link) {
    CallLinkQuality.excellent => VideoCeiling.p1080,
    CallLinkQuality.good || CallLinkQuality.unknown => VideoCeiling.p720,
    CallLinkQuality.poor || CallLinkQuality.lost => VideoCeiling.p540,
  };
  final byHeat = thermal >= 3
      ? VideoCeiling.p540
      : thermal == 2
      ? VideoCeiling.p720
      : VideoCeiling.p1080;
  return byDevice.min(byLink).min(byHeat);
}

/// The top encoding for [ceiling] when the camera captures [captureHeight]
/// lines: scale-down factor, bitrate, frame rate. The scale is relative to
/// the capture, so the same ceiling works for a 1080p and a 720p capture.
({double scaleDownBy, int maxBitrate, int maxFramerate}) topLayerFor(VideoCeiling ceiling, int captureHeight) {
  final h = ceiling.height < captureHeight ? ceiling.height : captureHeight;
  final (bitrate, fps) = switch (h) {
    >= 1080 => (2500 * 1000, 30),
    >= 720 => (1500 * 1000, 30),
    _ => (800 * 1000, 24),
  };
  return (scaleDownBy: captureHeight / h, maxBitrate: bitrate, maxFramerate: fps);
}

/// Steps the ceiling down at once and up only after the better target has
/// held for [upHold] — a link flickering between "good" and "excellent"
/// must not flip the picture back and forth every few seconds.
class VideoCeilingController {
  VideoCeilingController({this.upHold = const Duration(seconds: 10)});

  final Duration upHold;
  VideoCeiling? _current;
  VideoCeiling? _pending;
  DateTime? _pendingSince;

  VideoCeiling? get current => _current;

  /// A new target. Returns the ceiling to apply now, or null if nothing
  /// changes yet.
  VideoCeiling? update(VideoCeiling? target, DateTime now) {
    if (target == null) return null;
    final cur = _current;
    if (cur == null || target.index < cur.index) {
      _pending = null;
      _pendingSince = null;
      return _current = target;
    }
    if (target == cur) {
      _pending = null;
      _pendingSince = null;
      return null;
    }
    if (_pending != target) {
      _pending = target;
      _pendingSince = now;
      return null;
    }
    if (now.difference(_pendingSince!) < upHold) return null;
    _pending = null;
    _pendingSince = null;
    return _current = target;
  }
}

/// Kill switch for H.264. If real phones show black video with it, set to
/// false: every device goes back to VP8 (the old behaviour).
const kCallPreferH264 = true;

/// H.264 when this phone's WebRTC encoder list has it — on Android that
/// list holds H.264 only with a hardware encoder (there is no software
/// one), on iOS it is VideoToolbox. Otherwise VP8.
String chooseVideoCodec({required List<String> encoderMimeTypes, bool preferH264 = kCallPreferH264}) {
  final h264 = encoderMimeTypes.any((m) => m.toLowerCase() == 'video/h264');
  return preferH264 && h264 ? 'h264' : 'vp8';
}

/// Publish options for my camera. The backup codec is OFF on purpose:
/// livekit_client 2.7.0 attaches the SFrame cryptor only to a track's
/// primary sender, so a backup-codec copy (sent when the SFU asks for it)
/// would leave the phone unencrypted. E2EE beats compatibility here.
/// The flag alone only stops offering one; what stops the server from
/// asking for it anyway is dynacast being off ([callRoomOptions]).
lk.VideoPublishOptions callVideoPublishOptions(CallVideoPreset p, String codec) => lk.VideoPublishOptions(
  videoCodec: codec,
  videoEncoding: p.capture.encoding,
  simulcast: true,
  videoSimulcastLayers: p.simulcastLayers,
  backupVideoCodec: const lk.BackupVideoCodec(enabled: false),
);

/// Voice: Opus starting at 32 kbps (then following the link —
/// [callAudioBitrateFor]), DTX (silence costs ~nothing) and RED (each
/// packet carries the previous one, so a lost packet is not a lost
/// syllable). Opus's own FEC is on in WebRTC by default.
const kCallAudioPublishOptions = lk.AudioPublishOptions(
  encoding: lk.AudioEncoding(maxBitrate: kCallAudioBitrateStart),
  dtx: true,
  red: true,
);

const kCallAudioBitrateStart = 32000;

/// Owner, 2026-10-16: "the best possible sound even on bad internet". The
/// voice's ceiling by my link: rich, full-band voice when the link allows
/// (40 kbps — near studio for speech), lean when it doesn't (Opus stays
/// intelligible down to ~12 kbps; FEC + RED cover the losses; video is
/// what gives way first).
int callAudioBitrateFor(CallLinkQuality q) => switch (q) {
  CallLinkQuality.excellent => 40000,
  CallLinkQuality.good => 32000,
  CallLinkQuality.unknown => kCallAudioBitrateStart,
  CallLinkQuality.poor => 20000,
  CallLinkQuality.lost => 14000,
};

/// LiveKit's per-participant link grade, as the call screen shows it.
enum CallLinkQuality { unknown, excellent, good, poor, lost }

CallLinkQuality callLinkQualityFrom(lk.ConnectionQuality q) => switch (q) {
  lk.ConnectionQuality.excellent => CallLinkQuality.excellent,
  lk.ConnectionQuality.good => CallLinkQuality.good,
  lk.ConnectionQuality.poor => CallLinkQuality.poor,
  lk.ConnectionQuality.lost => CallLinkQuality.lost,
  lk.ConnectionQuality.unknown => CallLinkQuality.unknown,
};

extension CallLinkQualityX on CallLinkQuality {
  bool get isBad => this == CallLinkQuality.poor || this == CallLinkQuality.lost;

  /// Signal bars, 0–3 (unknown shows 3 dimmed — nothing measured yet).
  int get bars => switch (this) {
    CallLinkQuality.excellent || CallLinkQuality.unknown => 3,
    CallLinkQuality.good => 2,
    CallLinkQuality.poor => 1,
    CallLinkQuality.lost => 0,
  };
}

/// The one line the call screen shows about the link, if any.
enum CallNotice { none, weakMine, weakPeer, autoAudioOnly, switchingPath, keepsDropping }

CallNotice callNoticeFor({
  required CallLinkQuality mine,
  required bool peerBad,
  required bool autoAudioOnly,
  bool switchingPath = false,
  bool keepsDropping = false,
}) {
  // ADR-042 — rejoining through the reserve path: say so, it takes seconds.
  if (switchingPath) return CallNotice.switchingPath;
  // Tech-debt 2.38 — even the reserve path keeps dropping: something on the
  // phone (a VPN by rules) is in the way; say what helps.
  if (keepsDropping) return CallNotice.keepsDropping;
  if (autoAudioOnly) return CallNotice.autoAudioOnly;
  if (mine.isBad) return CallNotice.weakMine;
  if (peerBad) return CallNotice.weakPeer;
  return CallNotice.none;
}

/// My link stays poor → my camera goes off so the voice survives.
///
/// LiveKit reports quality only when it changes, so the caller arms a timer
/// for [holdNow] after a bad report and asks [due] when it fires. Fires
/// after [hold] of continuous poor/lost; once the person turns the camera
/// back on themselves it waits [holdAfterOverride] instead — they chose
/// video, we only step in again when it clearly isn't working.
class AudioOnlyFallback {
  AudioOnlyFallback({this.hold = const Duration(seconds: 8), this.holdAfterOverride = const Duration(seconds: 30)});

  final Duration hold;
  final Duration holdAfterOverride;
  DateTime? _badSince;
  bool _overridden = false;

  Duration get holdNow => _overridden ? holdAfterOverride : hold;

  /// Bad since when (null = the link is fine). For tests and logs.
  DateTime? get badSince => _badSince;

  /// A new quality report for MY link.
  void report(CallLinkQuality q, DateTime now) {
    if (q.isBad) {
      _badSince ??= now;
    } else {
      _badSince = null;
    }
  }

  /// Time to switch my camera off.
  bool due({required DateTime now, required bool cameraOn}) {
    final since = _badSince;
    return cameraOn && since != null && now.difference(since) >= holdNow;
  }

  /// The camera was switched off by us: the next switch needs a fresh
  /// stretch of bad link.
  void fired() => _badSince = null;

  /// The person turned the camera on again.
  void userTurnedCameraOn(DateTime now) {
    _overridden = true;
    if (_badSince != null) _badSince = now;
  }
}
