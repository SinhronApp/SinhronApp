// Owner, 2026-10-19 (iPhone screenshot of an audio call): the call screen
// ran off the edges — "Share screen" floated on the right edge over the
// name, a name tag sat at the very bottom like a stray label, and the
// labels were English in the Russian app. Every call screen at an iPhone SE,
// an ordinary and a large phone, upright and sideways, in Russian and in
// English, with every button there can be: no overflow, nothing off the
// screen, no button over another, no English in the Russian app.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/features/calls/call_screen_share.dart';
import 'package:sinhron/l10n/l10n.dart';

/// A phone: its size, and the notch / home bar it keeps clear.
typedef Phone = ({String name, Size size, EdgeInsets padding});

const List<Phone> phones = [
  (name: 'SE', size: Size(375, 667), padding: EdgeInsets.only(top: 20)),
  (name: '15', size: Size(390, 844), padding: EdgeInsets.only(top: 47, bottom: 34)),
  (name: 'Pro Max', size: Size(430, 932), padding: EdgeInsets.only(top: 59, bottom: 34)),
  (name: 'SE sideways', size: Size(667, 375), padding: EdgeInsets.zero),
  (name: '15 sideways', size: Size(844, 390), padding: EdgeInsets.only(left: 47, right: 47, bottom: 21)),
  (name: 'Pro Max sideways', size: Size(932, 430), padding: EdgeInsets.only(left: 59, right: 59, bottom: 21)),
];

/// The buttons a screen may show — none may sit on another.
const buttonKeys = [
  'call-decline',
  'call-accept',
  'call-audio-mute',
  'call-mute',
  'call-video',
  'call-speaker',
  'call-camera',
  'call-flip',
  'call-audio-route',
  'call-share-screen',
  'call-hangup',
  'call-mic-mode',
  'call-minimize',
];

/// Labels the owner saw in English on the Russian call screen.
const english = ['Encrypted', 'Unmute', 'Mute', 'Video', 'End', 'Share screen', 'Speaker', 'Flip', 'Back to call', 'Rotate'];

void main() {
  Widget host(Phone phone, String lang, Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: Localizations(
      locale: Locale(lang),
      delegates: AppL10n.localizationsDelegates,
      child: MediaQuery(
        data: MediaQueryData(size: phone.size, padding: phone.padding, viewPadding: phone.padding),
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      ),
    ),
  );

  final ten = ValueNotifier<double>(0.3);
  final screens = <String, Widget>{
    'incoming': const CallScreen(contactName: 'Константин Константинопольский', initialState: CallState.incoming),
    'outgoing': CallScreen(contactName: 'Мама', initialState: CallState.outgoing, onMinimize: () {}),
    // Every button an audio call can have: mic mode, a headset's long name,
    // screen sharing; a notice and their mic off.
    'audio, all buttons': CallScreen(
      contactName: 'Константин Константинопольский',
      initialState: CallState.active,
      onMinimize: () {},
      voiceLevel: ten,
      linkQuality: CallLinkQuality.poor,
      notice: CallNotice.weakPeer,
      peerMicOff: true,
      muted: true,
      micModeLabel: 'Микрофон: изоляция голоса',
      onMicMode: () {},
      onPickAudioRoute: () {},
      audioRouteLabel: 'Galaxy Buds2 Pro',
      audioRouteExternal: true,
      onShareScreen: () {},
    ),
    // Six buttons in the bar: mic, camera, flip, sound, screen, end.
    'video, all buttons': CallScreen(
      contactName: 'Мама',
      initialState: CallState.active,
      initialMedia: CallMedia.video,
      onMinimize: () {},
      remoteVideoOn: true,
      remoteVideo: const SizedBox.expand(),
      selfVideo: const SizedBox.expand(),
      cameraOn: true,
      muted: true,
      linkQuality: CallLinkQuality.good,
      notice: CallNotice.weakMine,
      peerMicOff: true,
      onSwitchCamera: () {},
      onPickAudioRoute: () {},
      audioRouteLabel: 'AirPods Pro',
      audioRouteExternal: true,
      onShareScreen: () {},
      sharingScreen: true,
    ),
    'ended': CallScreen(
      contactName: 'Мама',
      initialState: CallState.ended,
      connectedAt: DateTime(2026, 10, 19, 0, 30),
      endedAt: DateTime(2026, 10, 19, 0, 32, 37),
    ),
    'their screen': ScreenShareViewer(
      name: 'Константин Константинопольский',
      video: const SizedBox(width: 300, height: 600),
      onClose: () {},
      onHangUp: () {},
      lockOrientation: false,
    ),
  };

  for (final phone in phones) {
    for (final lang in ['ru', 'en']) {
      for (final entry in screens.entries) {
        testWidgets('${entry.key} · ${phone.name} · $lang', (t) async {
          t.view.physicalSize = phone.size;
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          await t.pumpWidget(host(phone, lang, entry.value));
          await t.pump(const Duration(milliseconds: 400));
          await t.pump(const Duration(milliseconds: 400));
          expect(t.takeException(), isNull, reason: 'no overflow');

          final screen = Offset.zero & phone.size;
          bool inside(Rect r) => r.left >= screen.left - 0.5 && r.top >= screen.top - 0.5 && r.right <= screen.right + 0.5 && r.bottom <= screen.bottom + 0.5;

          // Every piece of text on the screen.
          for (final e in find.byType(RichText).evaluate()) {
            final box = e.renderObject! as RenderBox;
            if (!box.hasSize || box.size.isEmpty) continue;
            // Where it really is (a FittedBox may scale it down).
            final r = MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
            expect(inside(r), isTrue, reason: '"${(e.widget as RichText).text.toPlainText()}" at $r is off the screen');
          }

          // The buttons: on the screen, clear of the notch sides, none over another.
          final rects = <String, Rect>{};
          for (final k in buttonKeys) {
            final f = find.byKey(ValueKey(k));
            if (f.evaluate().isEmpty) continue;
            final r = t.getRect(f.first);
            expect(inside(r), isTrue, reason: '$k at $r is off the screen');
            expect(r.left, greaterThanOrEqualTo(phone.padding.left - 0.5), reason: '$k under the notch');
            expect(r.right, lessThanOrEqualTo(phone.size.width - phone.padding.right + 0.5), reason: '$k under the notch');
            expect(r.bottom, lessThanOrEqualTo(phone.size.height - phone.padding.bottom + 0.5), reason: '$k under the home bar');
            rects[k] = r;
          }
          final keys = rects.keys.toList();
          for (var i = 0; i < keys.length; i++) {
            for (var j = i + 1; j < keys.length; j++) {
              final overlap = rects[keys[i]]!.intersect(rects[keys[j]]!);
              expect(
                overlap.width > 0.5 && overlap.height > 0.5,
                isFalse,
                reason: '${keys[i]} ${rects[keys[i]]} and ${keys[j]} ${rects[keys[j]]} overlap',
              );
            }
          }

          if (lang == 'ru') {
            for (final word in english) {
              expect(find.text(word), findsNothing, reason: '"$word" in the Russian app');
            }
          }
        });
      }
    }
  }

  // The Russian words the owner should see where he saw English.
  testWidgets('Russian on the call screen and over a shared screen', (t) async {
    const phone = (name: '15', size: Size(390, 844), padding: EdgeInsets.only(top: 47, bottom: 34));
    t.view.physicalSize = phone.size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(phone, 'ru', screens['video, all buttons']!));
    await t.pump(const Duration(milliseconds: 400));
    for (final word in ['Зашифровано', 'Вкл. звук', 'Видео', 'Завершить', 'Остановить']) {
      expect(find.text(word), findsOneWidget, reason: word);
    }
    await t.pumpWidget(host(phone, 'ru', screens['their screen']!));
    await t.pump();
    for (final word in ['К звонку', 'Повернуть', 'Завершить']) {
      expect(find.text(word), findsOneWidget, reason: word);
    }
  });

  // Without the app's Localizations (an overlay, a test, a preview) the
  // text follows the app's language, not English.
  testWidgets('no Localizations above: the app\'s language, not English', (t) async {
    final was = currentLanguage;
    currentLanguage = 'ru';
    addTearDown(() => currentLanguage = was);
    late String text;
    await t.pumpWidget(
      Builder(
        builder: (context) {
          text = context.l10n.callEnd;
          return const SizedBox();
        },
      ),
    );
    expect(text, 'Завершить');
  });

  // Words on these screens come from l10n (ru + en), never typed in.
  test('no hard-coded words on the call screens', () {
    final typedIn = RegExp(r"(Text\(\s*|label:\s*|title:\s*)'[^'$]*[A-Za-zА-Яа-я]{2}");
    for (final f in ['call_screen', 'call_screen_share', 'live_call_screen', 'live_call_bar', 'call_video']) {
      final src = File('lib/features/calls/$f.dart').readAsStringSync();
      expect(typedIn.allMatches(src).map((m) => m[0]), isEmpty, reason: f);
    }
  });
}
