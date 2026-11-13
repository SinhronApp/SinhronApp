import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:livekit_client/livekit_client.dart' show MediaDevice;
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/live_call_screen.dart' show callEndedLabel;
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/features/calls/call_quality.dart';

void main() {
  Widget host(Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(390, 844)),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    ),
  );

  // Owner, 2026-10-15: the caller saw Accept / Decline on their own phone;
  // Accept on the callee's phone only flipped the picture.
  testWidgets('outgoing: Calling… and hang-up only', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.outgoing)));
    expect(find.text('Calling…'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-accept')), findsNothing);
    expect(find.byKey(const ValueKey('call-decline')), findsOneWidget);
    expect(find.textContaining('@maria'), findsNothing, reason: 'no demo handle');
  });

  testWidgets('incoming: Accept answers the call; the screen follows the call', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var accepted = 0;
    Widget screen(CallState s) => host(CallScreen(contactName: 'Вера', initialState: s, onAccept: () => accepted++));
    await t.pumpWidget(screen(CallState.incoming));
    await t.tap(find.byKey(const ValueKey('call-accept')));
    await t.pump();
    expect(accepted, 1);
    expect(find.byKey(const ValueKey('call-accept')), findsOneWidget, reason: 'waits for the call to connect');

    await t.pumpWidget(screen(CallState.active));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300)); // the views cross-fade
    expect(find.byKey(const ValueKey('call-accept')), findsNothing);
    expect(find.text('00:00'), findsOneWidget, reason: 'connected: the timer runs');
  });

  // Owner, 2026-10-15: two mic buttons, the camera button did nothing, the
  // name jumped while ringing, video depended on who pressed what.
  testWidgets('video controls: one mic, camera really toggles, flip only with camera on', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final asked = <bool>[];
    var cameraWorks = true;
    await t.pumpWidget(
      host(
        CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          onToggleCamera: (on) async {
            asked.add(on);
            return cameraWorks;
          },
        ),
      ),
    );
    // Audio call: "Video" asks for the camera and switches the view.
    await t.tap(find.byKey(const ValueKey('call-video')));
    await t.pump();
    expect(asked, [true]);
    expect(find.byKey(const ValueKey('call-mute')), findsOneWidget, reason: 'one mic button');
    expect(find.byKey(const ValueKey('call-flip')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('call-camera')));
    await t.pump();
    expect(asked, [true, false]);
    expect(find.byKey(const ValueKey('call-flip')), findsNothing);

    // No camera (Simulator): stays on audio.
    cameraWorks = false;
    await t.tap(find.byKey(const ValueKey('call-video')));
    await t.pump();
    expect(find.byKey(const ValueKey('call-camera')), findsNothing, reason: 'still the audio view');
  });

  testWidgets('their video shows even with my camera off', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          onToggleCamera: (_) async => true,
          remoteVideoOn: true,
          remoteVideo: const SizedBox(key: ValueKey('remote')),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('remote')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-flip')), findsNothing, reason: 'my camera is off');
  });

  testWidgets('ringing: the name does not move with the rings', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.incoming)));
    final y0 = t.getTopLeft(find.text('Вера')).dy;
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 230));
      expect(t.getTopLeft(find.text('Вера')).dy, y0);
    }
  });

  // Owner, 2026-10-15: the speaker icon didn't always show the truth.
  testWidgets('speaker icon follows the call, not a local guess', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final taps = <bool>[];
    Widget screen(bool on) =>
        host(CallScreen(contactName: 'Вера', initialState: CallState.active, speakerOn: on, onToggleSpeaker: taps.add));
    // A video call starts on the loudspeaker.
    await t.pumpWidget(screen(true));
    final speaker = find.byKey(const ValueKey('call-speaker'));
    expect(speaker, findsOneWidget);
    Color bgOf() =>
        (t.widget<Container>(find.descendant(of: speaker, matching: find.byType(Container)).first).decoration!
                as BoxDecoration)
            .color!;
    final onColor = bgOf();
    // Headphones plugged in: the call says the speaker is off.
    await t.pumpWidget(screen(false));
    await t.pump();
    expect(bgOf(), isNot(onColor));
    // A rebuild with the same state doesn't undo my tap.
    await t.tap(speaker);
    await t.pump();
    expect(taps, [true]);
    await t.pumpWidget(screen(false));
    await t.pump();
    expect(bgOf(), onColor, reason: 'my tap stands until the call reports otherwise');
  });

  test('headphones and Bluetooth count as an external output', () {
    expect(hasExternalAudioOutput(const [MediaDevice('1', 'iPhone Speaker', 'audiooutput', null)]), isFalse);
    expect(hasExternalAudioOutput(const [MediaDevice('2', 'AirPods Pro', 'audiooutput', null)]), isTrue);
    expect(hasExternalAudioOutput(const [MediaDevice('3', 'Headphones', 'audiooutput', null)]), isTrue);
    expect(
      hasExternalAudioOutput(const [MediaDevice('4', 'Bluetooth', 'audioinput', null)]),
      isFalse,
      reason: 'mic only',
    );
  });

  // Overnight item 5 — say why a call that never connected ended.
  testWidgets('ended: the reason instead of "Call ended · 00:00"', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(const CallScreen(contactName: 'Вера', initialState: CallState.ended, endedLabel: 'No answer')),
    );
    expect(find.text('No answer'), findsOneWidget);
    expect(find.textContaining('Call ended'), findsNothing);
  });

  // Status 213 — my call reached their phone: "Ringing…", as in WhatsApp.
  testWidgets('outgoing: "Calling…" until their phone has it, then "Ringing…"', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.outgoing)));
    expect(find.text('Calling…'), findsOneWidget);
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.outgoing, peerRinging: true)));
    await t.pump(const Duration(seconds: 1));
    expect(find.text('Ringing…'), findsOneWidget);
  });

  // Status 212 (owner: "it says connecting, then the screen goes, then it's
  // back") — "Call ended" holds to the close; a rejoin keeps the video.
  testWidgets('ended stays ended; a rejoin keeps the video layout', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.ended)));
    // The call went idle (mapped to "outgoing") just before the screen closes.
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.outgoing)));
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('Calling'), findsNothing);

    Widget video({required bool room, bool hold = false}) => host(
      CallScreen(
        key: const ValueKey('second-call'), // a fresh screen, not the ended one
        contactName: 'Ира',
        initialState: CallState.active,
        onToggleCamera: (_) async => true,
        remoteVideoOn: room,
        holdLayout: hold,
        remoteVideo: room ? const SizedBox(key: ValueKey('remote')) : null,
      ),
    );
    await t.pumpWidget(video(room: true));
    await t.pump(const Duration(seconds: 1));
    final videoKey = find.byKey(const ValueKey('video'));
    expect(videoKey, findsOneWidget);
    await t.pumpWidget(video(room: false, hold: true)); // the room is rejoining
    await t.pump(const Duration(seconds: 1));
    expect(videoKey, findsOneWidget, reason: 'no flip to the audio screen and back');
  });

  // Status 223 (owner: "as in WhatsApp — mute or turn the speaker on before
  // it connects"; "the iPad on its side looks broken").
  testWidgets('calling: mute and speaker before it connects; an iPad on its side keeps it centred', (t) async {
    t.view.physicalSize = const Size(1180, 820); // iPad, landscape
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final muted = <bool>[], speaker = <bool>[];
    await t.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1180, 820)),
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: CallScreen(
              contactName: 'Вова',
              initialState: CallState.outgoing,
              onToggleMute: muted.add,
              onToggleSpeaker: speaker.add,
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('call-outgoing-mute')));
    await t.tap(find.byKey(const ValueKey('call-outgoing-speaker')));
    await t.pump();
    expect(muted, [true]);
    expect(speaker, [true]);
    final name = t.getCenter(find.text('Вова'));
    final hangUp = t.getCenter(find.byKey(const ValueKey('call-decline')));
    expect((name.dx - hangUp.dx).abs(), lessThan(40), reason: 'one column, centred — not photo left, button right');
    expect(hangUp.dy, greaterThan(name.dy));
  });

  test('ended labels: no answer, busy, declined, missed; nothing once it connected', () {
    final en = lookupAppL10n(const Locale('en'));
    final ru = lookupAppL10n(const Locale('ru'));
    ActiveCallState ended(String reason, {bool caller = true, DateTime? at}) =>
        ActiveCallState(phase: CallPhase.ended, endReason: reason, isCaller: caller, connectedAt: at);
    expect(callEndedLabel(en, ended('no_answer')), 'No answer');
    expect(callEndedLabel(ru, ended('busy')), 'Занято');
    expect(callEndedLabel(ru, ended('rejected')), 'Звонок отклонён');
    expect(callEndedLabel(ru, ended('no_answer', caller: false)), 'Пропущенный звонок');
    expect(callEndedLabel(en, ended('hangup')), isNull);
    expect(callEndedLabel(en, ended('busy', at: DateTime(2026))), isNull);
    // Answered, but neither path came up (a VPN): said so, not "Call ended".
    expect(callEndedLabel(ru, ended('livekit_failure', at: DateTime(2026))), 'Не удалось соединить звонок');
  });

  // ADR-041 — link quality on screen and the automatic audio-only switch.
  testWidgets('link: bars by the timer only in a live call; the notice under it', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(const CallScreen(contactName: 'Вера', initialState: CallState.active)));
    expect(find.byKey(const ValueKey('call-signal')), findsNothing, reason: 'demo: no bars');
    expect(find.byKey(const ValueKey('call-notice')), findsNothing);

    await t.pumpWidget(
      host(
        const CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          linkQuality: CallLinkQuality.poor,
          notice: CallNotice.weakMine,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('call-signal')), findsOneWidget);
    expect(find.text('Weak connection'), findsOneWidget);
  });

  testWidgets('poor link: the call turns my camera off → the screen follows and says why', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final asked = <bool>[];
    Widget screen({required bool camera, CallNotice notice = CallNotice.none}) => host(
      CallScreen(
        contactName: 'Вера',
        initialState: CallState.active,
        initialMedia: CallMedia.video,
        onToggleCamera: (on) async {
          asked.add(on);
          return true;
        },
        cameraOn: camera,
        linkQuality: CallLinkQuality.poor,
        notice: notice,
      ),
    );
    await t.pumpWidget(screen(camera: true, notice: CallNotice.weakMine));
    expect(find.byKey(const ValueKey('call-flip')), findsOneWidget, reason: 'video view, camera on');
    expect(find.byKey(const ValueKey('call-notice')), findsOneWidget, reason: 'the line shows in the video view too');

    await t.pumpWidget(screen(camera: false, notice: CallNotice.autoAudioOnly));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300)); // the views cross-fade
    expect(find.byKey(const ValueKey('call-flip')), findsNothing);
    expect(find.byKey(const ValueKey('call-video')), findsOneWidget, reason: 'audio view: Video turns it back on');
    expect(find.text('Weak connection — camera off to keep the voice'), findsOneWidget);
    expect(asked, isEmpty, reason: 'the call did it; the screen does not ask again');

    await t.tap(find.byKey(const ValueKey('call-video')));
    await t.pump();
    expect(asked, [true]);
  });

  test('link notices are translated', () {
    final ru = lookupAppL10n(const Locale('ru'));
    expect(ru.callWeakLink, 'Слабая связь');
    expect(ru.callWeakLinkPeer, 'Слабая связь у собеседника');
    expect(ru.callAutoAudioOnly, contains('камера выключена'));
  });

  // Owner, 2026-10-16: after "hang up" the other side still saw me for
  // seconds, and "Call ended" was a strip at the left with black beside it.
  testWidgets('hang up ends the call at once; "Call ended" fills the screen', (t) async {
    var closed = 0;
    await t.pumpWidget(
      host(
        CallScreen(
          contactName: 'MacBook',
          initialState: CallState.active,
          onClose: () => closed++,
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('call-hangup')));
    await t.pump();
    expect(closed, 1, reason: 'no 1.6 s wait before the call is told to end');
    await t.pump(const Duration(milliseconds: 200));
    final label = find.byKey(const ValueKey('call-ended-label'));
    expect(label, findsOneWidget);
    final box = t.getSize(find.ancestor(of: label, matching: find.byType(Container)).last);
    expect(box.width, t.getSize(find.byType(CallScreen)).width, reason: 'the whole screen, not the width of its text');
  });

  // Owner, 2026-10-18: "to get to the chat during a call I had to hang up".
  testWidgets('minimise: on my ringing call and a live one, not on an incoming call', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var minimised = 0;
    Widget screen(CallState s, {CallMedia media = CallMedia.audio}) =>
        host(CallScreen(contactName: 'Вера', initialState: s, initialMedia: media, onMinimize: () => minimised++));
    await t.pumpWidget(screen(CallState.incoming));
    expect(find.byKey(const ValueKey('call-minimize')), findsNothing, reason: 'answer or decline first');
    await t.pumpWidget(screen(CallState.outgoing));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('call-minimize')), findsOneWidget);
    await t.pumpWidget(screen(CallState.active));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('call-minimize')));
    expect(minimised, 1);
    await t.pumpWidget(const SizedBox()); // a fresh screen
    await t.pumpWidget(screen(CallState.active, media: CallMedia.video));
    expect(find.byKey(const ValueKey('call-minimize')), findsOneWidget, reason: 'the video view too');
  });

  testWidgets('answered, no sound yet: "Connecting…" instead of the timer; then the timer and the voice bars', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final level = ValueNotifier<double>(0);
    Widget screen(bool connecting) => host(
      CallScreen(contactName: 'Вера', initialState: CallState.active, connecting: connecting, voiceLevel: level),
    );
    await t.pumpWidget(screen(true));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('call-connecting')), findsOneWidget);
    expect(find.text('00:00'), findsNothing);
    expect(find.byKey(const ValueKey('call-voice-bars')), findsNothing, reason: 'no voice to show yet');

    await t.pumpWidget(screen(false));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('call-connecting')), findsNothing);
    expect(find.text('00:00'), findsOneWidget);
    expect(find.byKey(const ValueKey('call-voice-bars')), findsOneWidget);
  });

  // Owner, 2026-10-18: "the noise-suppression button right above hang-up is
  // a bad place".
  testWidgets('mic mode sits with the sound controls, hang-up stands alone', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          micModeLabel: 'Mic: Voice Isolation',
          onMicMode: () {},
        ),
      ),
    );
    final pill = t.getRect(find.byKey(const ValueKey('call-mic-mode')));
    final speaker = t.getRect(find.byKey(const ValueKey('call-speaker')));
    final hangUp = t.getRect(find.byKey(const ValueKey('call-hangup')));
    expect(pill.bottom, lessThan(speaker.top), reason: 'above the row of sound buttons');
    expect(hangUp.top - pill.bottom, greaterThan(speaker.height), reason: 'a whole row between it and hang-up');
    expect(speaker.bottom, lessThan(hangUp.top), reason: 'hang-up alone on its own row');
  });

  // Owner, 2026-10-19: six buttons left "Перевернуть" unreadable on an
  // iPhone SE — with my picture on screen, flip sits on it.
  testWidgets('flip the camera on my own picture; the bar keeps five buttons at most', (t) async {
    t.view.physicalSize = const Size(375, 667);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var flips = 0;
    await t.pumpWidget(
      host(
        CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          initialMedia: CallMedia.video,
          cameraOn: true,
          selfVideo: const SizedBox.expand(key: ValueKey('me')),
          onSwitchCamera: () => flips++,
          onPickAudioRoute: () {},
          onShareScreen: () {},
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    final me = t.getRect(find.byKey(const ValueKey('me')));
    final flip = t.getRect(find.byKey(const ValueKey('call-flip')));
    expect(me.contains(flip.center), isTrue);
    await t.tap(find.byKey(const ValueKey('call-flip')));
    expect(flips, 1);
    for (final k in ['call-mute', 'call-camera', 'call-audio-route', 'call-share-screen', 'call-hangup']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
  });

  // Owner, 2026-10-19: "turning video on mid-call there's no speaker
  // button — only in an audio call".
  testWidgets('a video call has the speaker button too (no headset around)', (t) async {
    t.view.physicalSize = const Size(375, 667);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final asked = <bool>[];
    await t.pumpWidget(
      host(
        CallScreen(
          contactName: 'Вера',
          initialState: CallState.active,
          initialMedia: CallMedia.video,
          cameraOn: true,
          selfVideo: const SizedBox.expand(key: ValueKey('me')),
          speakerOn: true,
          onToggleSpeaker: asked.add,
          onShareScreen: () {},
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    final speaker = find.byKey(const ValueKey('call-video-speaker'));
    expect(speaker, findsOneWidget);
    expect(find.byKey(const ValueKey('call-audio-route')), findsNothing, reason: 'no headset: a plain toggle');
    await t.tap(speaker);
    await t.pump();
    expect(asked, [false], reason: 'video starts on the speaker; a tap moves it to the earpiece');
    await t.tap(speaker);
    await t.pump();
    expect(asked, [false, true]);
  });

}
