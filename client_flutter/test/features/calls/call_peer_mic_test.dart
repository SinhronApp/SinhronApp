// Owner, 2026-10-19: "on the call screen there's no sign that the other
// side muted". LiveKit tells the room when someone mutes (signalling, so
// also with SFrame); a 1:1 call shows a crossed mic on their photo and
// "Микрофон выключен", in the video view and in the call bar; group tiles
// show it on each name tag.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/features/calls/call_video.dart';
import 'package:sinhron/features/calls/live_call_bar.dart';
import 'package:sinhron/l10n/l10n.dart';

void main() {
  Widget host(Widget child, {Size size = const Size(390, 844)}) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: Localizations(
      locale: const Locale('ru'),
      delegates: AppL10n.localizationsDelegates,
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      ),
    ),
  );

  test('1:1: off when their mic is muted or not sent; a group or an empty room: never', () {
    expect(peerMicOffFrom([true], group: false), isTrue);
    expect(peerMicOffFrom([null], group: false), isTrue, reason: 'no mic track at all');
    expect(peerMicOffFrom([false], group: false), isFalse);
    expect(peerMicOffFrom([], group: false), isFalse, reason: 'nobody there yet');
    expect(peerMicOffFrom([true, true], group: true), isFalse, reason: 'tiles show each one');
  });

  testWidgets('audio call: a crossed mic on their photo and "Микрофон выключен" instead of the voice bars', (t) async {
    Widget screen(bool off) => host(
      CallScreen(contactName: 'Мама', initialState: CallState.active, voiceLevel: ValueNotifier(0.4), peerMicOff: off),
    );
    await t.pumpWidget(screen(false));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('peer-mic-off')), findsNothing);
    expect(find.text('Микрофон выключен'), findsNothing);

    await t.pumpWidget(screen(true));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('peer-mic-off')), findsOneWidget);
    expect(find.text('Микрофон выключен'), findsOneWidget);
    // The badge sits on the photo's lower right.
    final photo = t.getRect(find.byType(CallPeerAvatar));
    final badge = t.getRect(find.byKey(const ValueKey('peer-mic-off')));
    expect(photo.contains(badge.center), isTrue);
    expect(badge.center.dx, greaterThan(photo.center.dx));
    expect(badge.center.dy, greaterThan(photo.center.dy));
  });

  testWidgets('video call: a "Микрофон выключен" pill over their camera', (t) async {
    await t.pumpWidget(
      host(
        const CallScreen(
          contactName: 'Мама',
          initialState: CallState.active,
          initialMedia: CallMedia.video,
          peerMicOff: true,
          remoteVideo: SizedBox.expand(),
          remoteVideoOn: true,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('call-peer-mic-off')), findsOneWidget);
    expect(find.text('Микрофон выключен'), findsOneWidget);
  });

  testWidgets('a lone tile (their camera off) puts the crossed mic on the photo; several tiles on the name tag', (t) async {
    await t.pumpWidget(host(const SizedBox(width: 390, height: 600, child: CallTile(name: 'Мама', micOff: true))));
    expect(find.byKey(const ValueKey('peer-mic-off')), findsOneWidget);
    expect(find.text('Мама'), findsNothing, reason: 'alone on screen: no name tag at the bottom edge');

    await t.pumpWidget(host(const SizedBox(width: 180, height: 240, child: CallTile(name: 'Мама', micOff: true, compact: true))));
    expect(find.byKey(const ValueKey('tile-mic-off')), findsOneWidget);
    expect(find.byKey(const ValueKey('peer-mic-off')), findsNothing);
    expect(find.text('Мама'), findsOneWidget);
  });

  testWidgets('the call bar: a crossed mic instead of the dot while they are muted', (t) async {
    final semantics = t.ensureSemantics();
    final now = DateTime.now();
    ActiveCallState call({required bool off, DateTime? audio}) => ActiveCallState(
      phase: CallPhase.connected,
      callId: 'c',
      connectedAt: now,
      audioAt: audio,
      peerMicOff: off,
    );
    await t.pumpWidget(host(LiveCallBar(call: call(off: true, audio: now), onTap: () {})));
    expect(find.byKey(const ValueKey('call-bar-mic-off')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Микрофон выключен')), findsWidgets, reason: 'VoiceOver hears it');
    await t.pumpWidget(host(LiveCallBar(call: call(off: false, audio: now), onTap: () {})));
    expect(find.byKey(const ValueKey('call-bar-mic-off')), findsNothing);
    // Still connecting: not yet (their mic may simply not be up).
    await t.pumpWidget(host(LiveCallBar(call: call(off: true), onTap: () {})));
    expect(find.byKey(const ValueKey('call-bar-mic-off')), findsNothing);
    semantics.dispose();
  });
}
