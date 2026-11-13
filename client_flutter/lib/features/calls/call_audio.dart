// Where the call's sound goes — owner, 2026-10-16: "headphones, speakers,
// microphones — switch normally, in real time".
//
// The speaker button: with only the phone's own earpiece and loudspeaker
// it toggles between them as before. With headphones / Bluetooth / a car
// around it shows where the sound is now ("AirPods") and opens a choice:
//   iPhone  — the system's own route menu (AVRoutePickerView, the same as in
//             the Phone app), `dev.sinhron/audio` in CallKitBridge.swift;
//             the route and its changes come from AVAudioSession.
//   Android — our sheet listing flutter_webrtc's outputs (AudioSwitch:
//             `earpiece` / `speaker` / `wired-headset` / `bluetooth`);
//             choosing one calls `Helper.selectAudioOutput`.
// The microphone follows the output: a Bluetooth headset or wired headset
// brings its own mic, the phone's speaker / earpiece use the phone's.
//
// Real time: a headset that connects mid-call takes the sound (iPhone does
// it by itself; on Android the app selects it — AudioSwitch would keep an
// earlier manual choice); one that goes away hands the sound back, and the
// button follows both.

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, defaultTargetPlatform, TargetPlatform, listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc show Helper;
import 'package:livekit_client/livekit_client.dart' as lk show Hardware;

import '../../l10n/l10n.dart';
import 'active_call_provider.dart';

enum AudioOutputKind { earpiece, speaker, wired, bluetooth, car, airplay, usb, other }

extension AudioOutputKindX on AudioOutputKind {
  /// Not the phone's own earpiece or loudspeaker.
  bool get external => this != AudioOutputKind.earpiece && this != AudioOutputKind.speaker;
}

/// `speaker`, `wired-headset`… (Android ids, iOS kinds from the bridge).
AudioOutputKind audioOutputKindOf(String s) => switch (s) {
  'earpiece' => AudioOutputKind.earpiece,
  'speaker' => AudioOutputKind.speaker,
  'wired' || 'wired-headset' => AudioOutputKind.wired,
  'bluetooth' => AudioOutputKind.bluetooth,
  'car' => AudioOutputKind.car,
  'airplay' => AudioOutputKind.airplay,
  'usb' => AudioOutputKind.usb,
  _ => AudioOutputKind.other,
};

@immutable
class AudioOutput {
  const AudioOutput(this.kind, {this.name = '', this.id = ''});
  final AudioOutputKind kind;

  /// From the OS: "AirPods Pro", "Galaxy Buds"… (may be empty).
  final String name;

  /// Android: what `selectAudioOutput` takes.
  final String id;

  @override
  bool operator ==(Object other) => other is AudioOutput && other.kind == kind && other.name == name && other.id == id;
  @override
  int get hashCode => Object.hash(kind, name, id);
  @override
  String toString() => 'AudioOutput($kind, $name)';
}

/// Android: where the sound goes (flutter_webrtc doesn't say which output
/// AudioSwitch picked) — my choice while it's there; otherwise AudioSwitch's
/// own order: Bluetooth, wired, then loudspeaker or earpiece as the speaker
/// button says.
AudioOutput? androidActiveOutput(List<AudioOutput> outputs, {required bool speakerOn, AudioOutputKind? chosen}) {
  AudioOutput? of(AudioOutputKind k) => outputs.where((o) => o.kind == k).firstOrNull;
  if (chosen != null && of(chosen) != null) return of(chosen);
  return of(AudioOutputKind.bluetooth) ??
      of(AudioOutputKind.wired) ??
      (speakerOn
          ? of(AudioOutputKind.speaker) ?? of(AudioOutputKind.earpiece)
          : of(AudioOutputKind.earpiece) ?? of(AudioOutputKind.speaker)) ??
      outputs.firstOrNull;
}

/// A headset / Bluetooth device that wasn't there before — the sound moves
/// to it, as in a phone call.
AudioOutput? newlyConnectedOutput(List<AudioOutput> before, List<AudioOutput> now) =>
    now.where((o) => o.kind.external && !before.any((b) => b.kind == o.kind)).firstOrNull;

/// The phone's audio routes. Faked in tests.
abstract class CallAudioPlatform {
  /// iPhone: the system route menu does the choosing.
  bool get systemPicker;

  /// Android: the outputs to choose from (empty on iPhone).
  Future<List<AudioOutput>> outputs();

  /// iPhone: the route now and whether a headset / Bluetooth is around.
  /// Null on Android (worked out by [androidActiveOutput]).
  Future<({AudioOutput output, bool external})?> current();

  /// Something plugged / unplugged / switched.
  Stream<void> get changes;

  Future<void> showSystemPicker();

  /// Android: send the sound to [o].
  Future<void> select(AudioOutput o);

  /// iPhone (iOS 15+): the mic mode now — `standard`, `voiceIsolation`,
  /// `wideSpectrum`; null where there's no such choice.
  Future<String?> micMode();

  /// iPhone: the system's mic-mode menu (Voice Isolation lives there).
  Future<void> showMicModes();
}

/// iPhone: the audio session now — category, mode, active, WebRTC's audio
/// switch under CallKit, route (`AudioRouteBridge` → `CallAudio.state`) —
/// for the call diagnostics. Null elsewhere.
Future<Map<String, Object?>?> iosAudioSessionState() async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return null;
  try {
    return await const MethodChannel('dev.sinhron/audio').invokeMapMethod<String, Object?>('audioState');
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

class NativeCallAudioPlatform implements CallAudioPlatform {
  NativeCallAudioPlatform() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'routeChanged') _routeChanges.add(null);
      return null;
    });
  }

  static const _channel = MethodChannel('dev.sinhron/audio');
  final _routeChanges = StreamController<void>.broadcast();

  static bool get _ios => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  bool get systemPicker => _ios;

  @override
  Future<List<AudioOutput>> outputs() async {
    if (_ios) return const [];
    try {
      final list = await lk.Hardware.instance.audioOutputs();
      return [for (final d in list) AudioOutput(audioOutputKindOf(d.deviceId), name: d.label, id: d.deviceId)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<({AudioOutput output, bool external})?> current() async {
    if (!_ios) return null;
    try {
      final m = await _channel.invokeMapMethod<String, Object?>('currentRoute');
      if (m == null) return null;
      return (
        output: AudioOutput(audioOutputKindOf(m['kind'] as String? ?? ''), name: m['name'] as String? ?? ''),
        external: m['external'] == true,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Stream<void> get changes => _ios ? _routeChanges.stream : lk.Hardware.instance.onDeviceChange.stream.map((_) {});

  @override
  Future<void> showSystemPicker() async {
    try {
      await _channel.invokeMethod<bool>('showRoutePicker');
    } on MissingPluginException {
      // not on this platform
    } on PlatformException {
      // no window to show it in
    }
  }

  @override
  Future<void> select(AudioOutput o) => rtc.Helper.selectAudioOutput(o.id);

  @override
  Future<String?> micMode() async {
    if (!_ios) return null;
    try {
      return await _channel.invokeMethod<String>('micMode');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> showMicModes() async {
    try {
      await _channel.invokeMethod<bool>('showMicModes');
    } on MissingPluginException {
      // not on this platform
    } on PlatformException {
      // older iOS
    }
  }
}

final callAudioPlatformProvider = Provider<CallAudioPlatform>((ref) => NativeCallAudioPlatform());

/// What the speaker button shows.
@immutable
class CallAudioState {
  const CallAudioState({this.current, this.outputs = const [], this.external = false, this.micMode});

  /// iPhone: `standard` / `voiceIsolation` / `wideSpectrum` (null: no choice
  /// here — Android, older iOS).
  final String? micMode;

  /// Where the sound goes now (null: not known yet).
  final AudioOutput? current;

  /// Android: what the sheet offers.
  final List<AudioOutput> outputs;

  /// A headset / Bluetooth / car is around: the button opens a choice.
  final bool external;

  @override
  bool operator ==(Object other) =>
      other is CallAudioState &&
      other.current == current &&
      other.external == external &&
      other.micMode == micMode &&
      listEquals(other.outputs, outputs);
  @override
  int get hashCode => Object.hash(current, external, micMode, Object.hashAll(outputs));
}

/// Watched by the call screen while a call is on.
class CallAudio extends Notifier<CallAudioState> {
  StreamSubscription<void>? _sub;
  AudioOutputKind? _chosen;
  List<AudioOutput> _seen = const [];
  bool _first = true;

  CallAudioPlatform get _platform => ref.read(callAudioPlatformProvider);

  @override
  CallAudioState build() {
    _sub = _platform.changes.listen((_) => refresh());
    ref.onDispose(() => _sub?.cancel());
    // The speaker button flipped (or a video call started on the speaker).
    ref.listen(activeCallProvider.select((c) => c.speakerOn), (_, _) => refresh());
    Future.microtask(refresh);
    return const CallAudioState();
  }

  Future<void> refresh() async {
    final platform = _platform;
    final now = await platform.current();
    if (now != null) {
      final mode = await platform.micMode();
      if (!ref.mounted) return;
      state = CallAudioState(current: now.output, external: now.external || now.output.kind.external, micMode: mode);
      return;
    }
    final outputs = await platform.outputs();
    if (!ref.mounted) return;
    final arrived = _first ? null : newlyConnectedOutput(_seen, outputs);
    _first = false;
    _seen = outputs;
    if (arrived != null) {
      _chosen = arrived.kind;
      await platform.select(arrived);
      if (!ref.mounted) return;
    }
    final current = androidActiveOutput(
      outputs,
      speakerOn: ref.read(activeCallProvider).speakerOn,
      chosen: _chosen,
    );
    state = CallAudioState(current: current, outputs: outputs, external: outputs.any((o) => o.kind.external));
  }

  /// iPhone: open the mic-mode menu, then pick up what was chosen (the
  /// menu is the system's; it reports nothing back, so look a few times).
  Future<void> chooseMicMode() async {
    await _platform.showMicModes();
    for (final wait in const [1500, 3000, 6000]) {
      await Future<void>.delayed(Duration(milliseconds: wait));
      if (!ref.mounted) return;
      await refresh();
    }
  }

  /// Android sheet: send the sound to [o]. Loudspeaker / earpiece go through
  /// the call's speaker switch too (LiveKit keeps that preference).
  Future<void> choose(AudioOutput o) async {
    _chosen = o.kind;
    final call = ref.read(activeCallProvider.notifier);
    if (o.kind == AudioOutputKind.speaker) {
      await call.setSpeakerOn(true);
    } else if (o.kind == AudioOutputKind.earpiece) {
      await call.setSpeakerOn(false);
    }
    await _platform.select(o);
    await refresh();
  }
}

final callAudioProvider = NotifierProvider.autoDispose<CallAudio, CallAudioState>(CallAudio.new);

/// The button's / sheet's name for an output: the device's own name for
/// Bluetooth / AirPlay ("AirPods Pro"), a word for the rest.
String audioOutputLabel(AppL10n l, AudioOutput o) => switch (o.kind) {
  AudioOutputKind.earpiece => l.callAudioPhone,
  AudioOutputKind.speaker => l.callSpeaker,
  AudioOutputKind.wired => l.callAudioHeadphones,
  AudioOutputKind.bluetooth => o.name.trim().isEmpty ? 'Bluetooth' : o.name.trim(),
  AudioOutputKind.car => o.name.trim().isEmpty ? l.callAudioCar : o.name.trim(),
  AudioOutputKind.airplay => o.name.trim().isEmpty ? 'AirPlay' : o.name.trim(),
  AudioOutputKind.usb => o.name.trim().isEmpty ? 'USB' : o.name.trim(),
  AudioOutputKind.other => o.name.trim().isEmpty ? l.callAudioOther : o.name.trim(),
};

/// "Mic: Voice Isolation" — the pill under the call controls.
String micModeLabel(AppL10n l, String mode) => l.callMicMode(switch (mode) {
  'voiceIsolation' => l.callMicVoiceIsolation,
  'wideSpectrum' => l.callMicWideSpectrum,
  _ => l.callMicStandard,
});
