// Owner, 2026-10-16: headphones, speakers and mics in a call must switch
// normally, in real time. Where the sound goes, and the speaker button.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_audio.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

const _ear = AudioOutput(AudioOutputKind.earpiece, name: 'Earpiece', id: 'earpiece');
const _spk = AudioOutput(AudioOutputKind.speaker, name: 'Speakerphone', id: 'speaker');
const _wired = AudioOutput(AudioOutputKind.wired, name: 'Wired headset', id: 'wired-headset');
const _buds = AudioOutput(AudioOutputKind.bluetooth, name: 'Galaxy Buds', id: 'bluetooth');

class _Android implements CallAudioPlatform {
  List<AudioOutput> list = const [_ear, _spk];
  final selected = <AudioOutput>[];
  final ctl = StreamController<void>.broadcast();

  @override
  bool get systemPicker => false;
  @override
  Future<List<AudioOutput>> outputs() async => list;
  @override
  Future<({AudioOutput output, bool external})?> current() async => null;
  @override
  Stream<void> get changes => ctl.stream;
  @override
  Future<void> showSystemPicker() async {}
  @override
  Future<void> select(AudioOutput o) async => selected.add(o);

  String? mode;
  var micMenus = 0;
  @override
  Future<String?> micMode() async => mode;
  @override
  Future<void> showMicModes() async => micMenus++;
}

class _Iphone extends _Android {
  ({AudioOutput output, bool external})? now;
  @override
  bool get systemPicker => true;
  @override
  Future<({AudioOutput output, bool external})?> current() async => now;
}

class _Call extends ActiveCallNotifier {
  final speaker = <bool>[];
  @override
  ActiveCallState build() => const ActiveCallState(phase: CallPhase.connected, callId: 'c', groupIdHex: 'ab');
  @override
  Future<void> setSpeakerOn(bool on) async {
    speaker.add(on);
    state = state.copyWith(speakerOn: on);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('Android: where the sound goes — my choice, else Bluetooth, wired, then speaker or earpiece', () {
    expect(androidActiveOutput(const [_ear, _spk], speakerOn: false), _ear);
    expect(androidActiveOutput(const [_ear, _spk], speakerOn: true), _spk);
    expect(androidActiveOutput(const [_ear, _spk, _wired, _buds], speakerOn: true), _buds);
    expect(androidActiveOutput(const [_ear, _spk, _wired], speakerOn: false), _wired);
    expect(androidActiveOutput(const [_ear, _spk, _buds], speakerOn: false, chosen: AudioOutputKind.speaker), _spk);
    expect(
      androidActiveOutput(const [_ear, _spk], speakerOn: false, chosen: AudioOutputKind.bluetooth),
      _ear,
      reason: 'the chosen headset went away',
    );
    expect(newlyConnectedOutput(const [_ear, _spk], const [_ear, _spk, _buds]), _buds);
    expect(newlyConnectedOutput(const [_ear, _spk, _buds], const [_ear, _spk]), isNull);
  });

  test('Android: a headset that connects mid-call takes the sound; the sheet sends it anywhere', () async {
    final platform = _Android();
    final call = _Call();
    final c = ProviderContainer(
      overrides: [callAudioPlatformProvider.overrideWithValue(platform), activeCallProvider.overrideWith(() => call)],
    );
    addTearDown(c.dispose);
    final sub = c.listen(callAudioProvider, (_, _) {});
    addTearDown(sub.close);
    await _settle();
    expect(c.read(callAudioProvider).current, _ear);
    expect(c.read(callAudioProvider).external, isFalse, reason: 'only the phone: the button just toggles');

    // Earlier I put it on the speaker; then the Buds connect.
    await c.read(callAudioProvider.notifier).choose(_spk);
    expect(call.speaker, [true]);
    platform.list = const [_ear, _spk, _buds];
    platform.ctl.add(null);
    await _settle();
    expect(platform.selected.last, _buds, reason: 'AudioSwitch would keep the speaker — the app moves it');
    expect(c.read(callAudioProvider).current, _buds);
    expect(c.read(callAudioProvider).external, isTrue);

    // Back to the earpiece with the Buds still on.
    await c.read(callAudioProvider.notifier).choose(_ear);
    expect(call.speaker.last, isFalse);
    expect(platform.selected.last, _ear);
    expect(c.read(callAudioProvider).current, _ear);

    // The Buds go away: no headset left, the button toggles again.
    platform.list = const [_ear, _spk];
    platform.ctl.add(null);
    await _settle();
    expect(c.read(callAudioProvider).external, isFalse);
  });

  test('iPhone: the route and its changes come from the system', () async {
    final platform = _Iphone()..now = (output: _ear, external: false);
    final c = ProviderContainer(
      overrides: [callAudioPlatformProvider.overrideWithValue(platform), activeCallProvider.overrideWith(_Call.new)],
    );
    addTearDown(c.dispose);
    final sub = c.listen(callAudioProvider, (_, _) {});
    addTearDown(sub.close);
    await _settle();
    expect(c.read(callAudioProvider).external, isFalse);
    platform.now = (output: const AudioOutput(AudioOutputKind.bluetooth, name: 'AirPods Pro'), external: true);
    platform.ctl.add(null);
    await _settle();
    expect(c.read(callAudioProvider).current?.name, 'AirPods Pro');
    expect(c.read(callAudioProvider).external, isTrue);
    expect(platform.selected, isEmpty, reason: 'iOS routes by itself');
  });

  // Owner, 2026-10-16: "the best possible sound even on bad internet".
  test('the voice ceiling follows the link', () {
    expect(callAudioBitrateFor(CallLinkQuality.excellent), 40000);
    expect(callAudioBitrateFor(CallLinkQuality.good), 32000);
    expect(callAudioBitrateFor(CallLinkQuality.unknown), kCallAudioBitrateStart);
    expect(callAudioBitrateFor(CallLinkQuality.poor), 20000);
    expect(callAudioBitrateFor(CallLinkQuality.lost), 14000);
    expect(kCallAudioPublishOptions.dtx, isTrue);
    expect(kCallAudioPublishOptions.red, isTrue);
  });

  test('iPhone: the mic mode is read, and the menu opens on request', () async {
    final platform = _Iphone()
      ..now = (output: _ear, external: false)
      ..mode = 'voiceIsolation';
    final c = ProviderContainer(
      overrides: [callAudioPlatformProvider.overrideWithValue(platform), activeCallProvider.overrideWith(_Call.new)],
    );
    addTearDown(c.dispose);
    final sub = c.listen(callAudioProvider, (_, _) {});
    addTearDown(sub.close);
    await _settle();
    expect(c.read(callAudioProvider).micMode, 'voiceIsolation');
    expect(micModeLabel(lookupAppL10n(const Locale('ru')), 'voiceIsolation'), 'Микрофон: изоляция голоса');
    unawaited(c.read(callAudioProvider.notifier).chooseMicMode());
    await _settle();
    expect(platform.micMenus, 1);
  });

  test('names on the button', () {
    final l = lookupAppL10n(const Locale('ru'));
    expect(audioOutputLabel(l, _ear), 'Телефон');
    expect(audioOutputLabel(l, _spk), 'Динамик');
    expect(audioOutputLabel(l, _wired), 'Наушники');
    expect(audioOutputLabel(l, _buds), 'Galaxy Buds');
    expect(audioOutputLabel(l, const AudioOutput(AudioOutputKind.bluetooth)), 'Bluetooth');
  });

  Widget screen(CallMedia media, VoidCallback? pick) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(390, 844)),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          initialMedia: media,
          onToggleSpeaker: (_) {},
          speakerOn: false,
          onToggleCamera: (_) async => media == CallMedia.video,
          cameraOn: media == CallMedia.video,
          onPickAudioRoute: pick,
          audioRouteLabel: pick == null ? null : 'AirPods Pro',
          audioRouteExternal: pick != null,
        ),
      ),
    ),
  );

  testWidgets('the mic-mode pill shows under the controls and opens the menu', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var taps = 0;
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: CallScreen(
              contactName: 'Мама',
              initialState: CallState.active,
              micModeLabel: 'Mic: Voice Isolation',
              onMicMode: () => taps++,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('Mic: Voice Isolation'));
    expect(taps, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('with a headset around the speaker button names it and opens the choice', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var picks = 0;
    await t.pumpWidget(screen(CallMedia.audio, () => picks++));
    expect(find.text('AirPods Pro'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('call-speaker')));
    expect(picks, 1);

    await t.pumpWidget(screen(CallMedia.audio, null));
    expect(find.text('Speaker'), findsOneWidget, reason: 'no headset: the plain toggle');

    await t.pumpWidget(screen(CallMedia.video, () => picks++));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('call-audio-route')));
    expect(picks, 2);
    await t.pumpWidget(screen(CallMedia.video, null));
    expect(find.byKey(const ValueKey('call-audio-route')), findsNothing);
    await t.pumpWidget(const SizedBox());
  });
}
