// Rewinding a voice message (owner, 2026-10-18): a tap on the waveform
// plays from that point, a drag scrubs (the time follows the finger, the
// seek lands on release), the autoplay queue and the speed chip survive.

import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/chat_view/encrypted_media_bubbles.dart';
import 'package:sinhron/features/voice/voice_player.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

const _lengthMs = 80000;

class _Loader implements MediaLoader {
  @override
  Future<core.MediaInfo> info(String mediaJson) async => core.MediaInfo(
    kind: 'voice',
    mimeType: 'audio/mp4',
    fileName: '',
    blurhash: '',
    width: 0,
    height: 0,
    durationMs: _lengthMs,
    waveform: Uint8List.fromList(List.generate(64, (i) => i * 4)),
    caption: '',
    sizeBytes: BigInt.from(1000),
    hasThumbnail: false,
    round: false,
  );

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => Uint8List(0);

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async => Uint8List.fromList([1, 2, 3]);
}

/// Records seeks; plays "from there" without just_audio.
class _FakePlayer extends VoicePlayerNotifier {
  final seeks = <(String, double)>[];
  List<String> queue = const [];

  @override
  VoicePlayback build() => const VoicePlayback();

  @override
  Future<void> seek(
    String key,
    double fraction,
    Future<Uint8List> Function() load, {
    List<VoiceTrack> next = const [],
  }) async {
    seeks.add((key, fraction));
    queue = [for (final (k, _) in next) k];
    state = VoicePlayback(
      key: key,
      playing: true,
      position: const Duration(milliseconds: _lengthMs) * fraction,
      duration: const Duration(milliseconds: _lengthMs),
      speed: state.speed,
    );
  }

  @override
  Future<void> cycleSpeed() async => state = VoicePlayback(
    key: state.key,
    playing: state.playing,
    position: state.position,
    duration: state.duration,
    speed: state.speed == 1 ? 1.5 : 1,
  );
}

Future<_FakePlayer> _pump(WidgetTester t) async {
  final player = _FakePlayer();
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        mediaLoaderProvider.overrideWithValue(_Loader()),
        voicePlayerProvider.overrideWith(() => player),
      ],
      child: const DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: EncryptedVoice(mediaJson: '{voice}', color: Color(0xFF000000), following: ['{voice2}']),
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
  return player;
}

final _wave = find.byKey(const ValueKey('voice-waveform'));

/// A point [f] of the way along the waveform.
Offset _at(WidgetTester t, double f) {
  final r = t.getRect(_wave);
  return Offset(r.left + r.width * f, r.center.dy);
}

void main() {
  testWidgets('a tap on the waveform plays from that point, the queue comes along', (t) async {
    final player = await _pump(t);
    expect(find.text('1:20'), findsOneWidget, reason: 'the length before playing');

    await t.tapAt(_at(t, 0.25));
    await t.pumpAndSettle();
    expect(player.seeks.single.$1, '{voice}');
    expect(player.seeks.single.$2, closeTo(0.25, 0.01));
    expect(player.queue, ['{voice2}'], reason: 'the next voice messages still autoplay');
    expect(find.text('0:20'), findsOneWidget, reason: 'the time shows the new position');
  });

  testWidgets('a drag scrubs: the time follows the finger, the seek lands on release', (t) async {
    final player = await _pump(t);
    final g = await t.startGesture(_at(t, 0.1));
    await g.moveTo(_at(t, 0.3));
    await t.pump();
    await g.moveTo(_at(t, 0.75));
    await t.pump();
    expect(player.seeks, isEmpty, reason: 'no seek per frame');
    expect(find.text('1:00'), findsOneWidget, reason: '75 % of 1:20 while the finger is down');

    await g.up();
    await t.pumpAndSettle();
    expect(player.seeks.single.$2, closeTo(0.75, 0.01));
    expect(find.text('1:00'), findsOneWidget);
  });

  testWidgets('dragging past the ends stops at 0 and at the length', (t) async {
    final player = await _pump(t);
    final g = await t.startGesture(_at(t, 0.5));
    await g.moveTo(_at(t, 0.2));
    await t.pump();
    await g.moveTo(_at(t, -0.5));
    await t.pump();
    expect(find.text('0:00'), findsOneWidget);
    await g.up();
    await t.pumpAndSettle();
    expect(player.seeks.single.$2, 0.0);

    final g2 = await t.startGesture(_at(t, 0.5));
    await g2.moveTo(_at(t, 0.8));
    await g2.moveTo(_at(t, 1.6));
    await g2.up();
    await t.pumpAndSettle();
    expect(player.seeks.last.$2, 1.0);
  });

  testWidgets('the speed chip stays and still cycles after a seek', (t) async {
    final player = await _pump(t);
    await t.tapAt(_at(t, 0.5));
    await t.pumpAndSettle();
    expect(find.text('1×'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('voice-speed')));
    await t.pumpAndSettle();
    expect(find.text('1.5×'), findsOneWidget);
    expect(player.seeks, hasLength(1), reason: 'the chip is not a seek');
  });

  testWidgets('the waveform is a slider for VoiceOver', (t) async {
    final handle = t.ensureSemantics();
    final player = await _pump(t);
    final node = t.getSemantics(_wave);
    expect(node.label, contains('Playback position'));
    expect(node.value, '0:00 / 1:20');
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await t.pumpAndSettle();
    expect(player.seeks.single.$2, closeTo(0.1, 0.001));
    handle.dispose();
  });
}
