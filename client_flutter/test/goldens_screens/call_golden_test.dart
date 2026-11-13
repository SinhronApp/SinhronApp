// The call screens as images (owner, 2026-10-18: "make the call screen
// nicer"): talking with the voice bars, "Connecting…", my call ringing
// with "⌄", and the call bar over the app. Re-record with
// `flutter test --update-goldens test/goldens_screens/call_golden_test.dart`
// and look at them. The animations that loop (dots, rings) are frozen at a
// fixed moment, not settled.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/palette.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/features/calls/live_call_bar.dart';
import 'package:sinhron/l10n/l10n.dart';

import '../test_harness.dart';

void main() {
  setUpAll(loadAppFonts);

  Widget app(Widget child, {Size size = const Size(390, 844), EdgeInsets padding = const EdgeInsets.only(top: 47, bottom: 34)}) => Localizations(
    locale: const Locale('ru'),
    delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
    child: MediaQuery(
      data: MediaQueryData(size: size, padding: padding, viewPadding: padding),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: DefaultTextStyle(
            style: DsText.callout.copyWith(color: DsTokens.light.text),
            child: RepaintBoundary(key: const ValueKey('shot'), child: child),
          ),
        ),
      ),
    ),
  );

  Future<void> shoot(
    WidgetTester t,
    String name,
    Widget child, {
    Size size = const Size(390, 844),
    EdgeInsets padding = const EdgeInsets.only(top: 47, bottom: 34),
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(child, size: size, padding: padding));
    for (var i = 0; i < 18; i++) {
      await t.pump(const Duration(milliseconds: 40)); // frame by frame, like a phone
    }
    await expectLater(find.byKey(const ValueKey('shot')), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('talking, the other side speaking', (t) async {
    final level = ValueNotifier<double>(0.5);
    await shoot(
      t,
      'call_active_ru',
      CallScreen(
        contactName: 'Мария Чен',
        initialState: CallState.active,
        onMinimize: () {},
        voiceLevel: level,
        linkQuality: CallLinkQuality.good,
        micModeLabel: 'Микрофон: изоляция голоса',
        onMicMode: () {},
      ),
    );
  });

  testWidgets('answered, connecting', (t) async {
    await shoot(
      t,
      'call_connecting_ru',
      CallScreen(
        contactName: 'Мария Чен',
        initialState: CallState.active,
        onMinimize: () {},
        connecting: true,
        voiceLevel: ValueNotifier<double>(0),
      ),
    );
  });

  testWidgets('my call ringing', (t) async {
    await shoot(t, 'call_outgoing_ru', CallScreen(contactName: 'Мария Чен', initialState: CallState.outgoing, onMinimize: () {}));
  });

  testWidgets('the call bar over the app', (t) async {
    final now = DateTime.now();
    await shoot(
      t,
      'call_bar_ru',
      Column(
        children: [
          LiveCallBar(
            call: ActiveCallState(
              phase: CallPhase.connected,
              callId: 'c',
              connectedAt: now.subtract(const Duration(minutes: 2, seconds: 14)),
              audioAt: now.subtract(const Duration(minutes: 2, seconds: 14)),
            ),
            onTap: () {},
          ),
          const Expanded(child: ColoredBox(color: DsPalette.white)),
        ],
      ),
    );
  });

  // Owner, 2026-10-19: the screen ran off an iPhone; "Share screen" floated
  // over the name; no sign the other side muted. Every button, the smallest
  // iPhone; sideways; a video call with six buttons.
  CallScreen everything({CallMedia media = CallMedia.audio}) => CallScreen(
    contactName: 'Константин Константинопольский',
    initialState: CallState.active,
    initialMedia: media,
    onMinimize: () {},
    voiceLevel: ValueNotifier<double>(0.4),
    linkQuality: CallLinkQuality.good,
    peerMicOff: true,
    muted: true,
    micModeLabel: 'Микрофон: изоляция голоса',
    onMicMode: () {},
    onPickAudioRoute: () {},
    audioRouteLabel: 'Galaxy Buds2 Pro',
    audioRouteExternal: true,
    onShareScreen: () {},
    cameraOn: media == CallMedia.video,
    onSwitchCamera: () {},
    remoteVideoOn: media == CallMedia.video,
    selfVideo: media == CallMedia.video ? const ColoredBox(color: DsPalette.art2D2640) : null,
  );

  testWidgets('every button on an iPhone SE, their mic off', (t) async {
    await shoot(t, 'call_active_se_ru', everything(), size: const Size(375, 667), padding: const EdgeInsets.only(top: 20));
  });

  testWidgets('sideways', (t) async {
    await shoot(
      t,
      'call_active_landscape_ru',
      everything(),
      size: const Size(844, 390),
      padding: const EdgeInsets.only(left: 47, right: 47, bottom: 21),
    );
  });

  testWidgets('video, six buttons on an iPhone SE', (t) async {
    await shoot(
      t,
      'call_video_se_ru',
      everything(media: CallMedia.video),
      size: const Size(375, 667),
      padding: const EdgeInsets.only(top: 20),
    );
  });

  testWidgets('ended: the real length', (t) async {
    await shoot(
      t,
      'call_ended_ru',
      CallScreen(
        contactName: 'Мама',
        initialState: CallState.ended,
        connectedAt: DateTime(2026, 10, 19, 0, 30),
        endedAt: DateTime(2026, 10, 19, 0, 32, 37),
      ),
    );
  });
}
