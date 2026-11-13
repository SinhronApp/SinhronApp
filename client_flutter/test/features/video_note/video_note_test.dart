// ADR-048 — round video messages ("кружки") end to end in the chat:
// tap switches the mic to a camera, hold records (fake camera), slide to
// cancel / up to lock, 60 s cap, square crop + poster + temp files gone,
// the send goes out as a round video; the round bubble autoplays muted
// and plays with sound on a tap (fake player).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/pending_media.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/core/services/video_tools.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/features/video_note/video_note_bubble.dart';
import 'package:sinhron/features/video_note/video_note_recorder.dart';
import 'package:sinhron/features/video_note/video_note_tools.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../../core/settings_providers_test.dart' show MemoryStore;
import '../../core/video_tools_test.dart' show FakeVideoTools;

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
const roundJson = '{"v":1,"kind":"video","round":true,"n":1}';
const plainVideoJson = '{"v":1,"kind":"video","n":2}';

class FakeRecorder implements VideoNoteRecorder {
  FakeRecorder(this.dir, {this.result = VideoNoteStart.started});
  final Directory dir;
  final VideoNoteStart result;
  Duration clock = Duration.zero;
  bool recording = false;
  bool cancelled = false;
  bool disposed = false;
  int switches = 0;
  String? recordedPath;

  /// Set: the camera "opens" only when it completes.
  Completer<void>? gate;

  @override
  Future<VideoNoteStart> start() async {
    await gate?.future;
    if (result == VideoNoteStart.started) recording = true;
    return result;
  }

  @override
  bool get isRecording => recording;
  @override
  Duration get elapsed => clock;
  @override
  bool get canSwitchCamera => true;
  @override
  Future<void> switchCamera() async => switches++;
  @override
  Widget preview() => const ColoredBox(key: ValueKey('fake-preview'), color: Color(0xFF000000));

  @override
  Future<RecordedVideoNote?> stop() async {
    recording = false;
    final f = File('${dir.path}/camera-${DateTime.now().microsecondsSinceEpoch}.mov')
      ..writeAsBytesSync(List.filled(4000, 1));
    recordedPath = f.path;
    return RecordedVideoNote(path: f.path, durationMs: clock.inMilliseconds);
  }

  @override
  Future<void> cancel() async {
    if (recording) cancelled = true;
    recording = false;
  }

  @override
  Future<void> dispose() async {
    await cancel();
    disposed = true;
  }
}

class FakeCrop implements VideoNoteTools {
  FakeCrop(this.dir, {this.failFirst = 0});
  final Directory dir;
  final calls = <(String, int)>[];
  String? out;

  /// This many calls fail (null) before one works.
  int failFirst;

  @override
  Future<String?> square(String path, int side) async {
    calls.add((path, side));
    if (calls.length <= failFirst) return null;
    out = (File('${dir.path}/square.mp4')..writeAsBytesSync(List.filled(1500, 2))).path;
    return out;
  }
}

class OnlineNet extends NetService {
  OnlineNet(super.ref);
  @override
  String? get httpBaseUrl => 'http://srv';
}

class FakeLoader implements MediaLoader {
  final fetched = <String>[];
  @override
  Future<core.MediaInfo> info(String mediaJson) async => core.MediaInfo(
    kind: 'video',
    mimeType: 'video/mp4',
    fileName: '',
    blurhash: '',
    width: 480,
    height: 480,
    durationMs: 12000,
    waveform: Uint8List(0),
    caption: '',
    sizeBytes: BigInt.from(900 * 1024),
    hasThumbnail: false,
    round: isVideoNoteJson(mediaJson),
  );
  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => Uint8List(0);
  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async {
    fetched.add('${thumbnail ? 't' : 'f'}:$mediaJson');
    return Uint8List.fromList([1, 2, 3]);
  }
}

class FakeInlineVideo extends ChangeNotifier implements InlineVideo {
  static final made = <FakeInlineVideo>[];
  FakeInlineVideo() {
    made.add(this);
  }
  bool opened = false;
  bool disposed = false;
  @override
  bool playing = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration duration = const Duration(seconds: 12);
  double volume = 1;
  bool looping = false;

  @override
  Future<void> open(Uint8List bytes, String mimeType) async => opened = true;
  @override
  Future<void> play() async {
    playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    playing = false;
    notifyListeners();
  }

  @override
  Future<void> seekTo(Duration p) async {
    position = p;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async => volume = v;
  @override
  Future<void> setLooping(bool l) async => looping = l;
  @override
  Widget view() => const ColoredBox(key: ValueKey('fake-video'), color: Color(0xFF222222));
  @override
  Future<void> dispose() async {
    disposed = true;
    super.dispose();
  }

  /// Played to the end (not looping).
  void finish() {
    position = duration;
    playing = false;
    notifyListeners();
  }
}

core.StoredMessageSummary row(String id, int ts, String kind, {String? media, bool mine = false}) =>
    core.StoredMessageSummary(
      id: id,
      chatId: chatId,
      tsUnix: 1760000000 + ts,
      body: '',
      kind: kind,
      isMine: mine,
      mediaJson: media,
      wireId: '00000000-0000-4000-8000-00000000000$ts',
      status: 1,
      deleted: false,
    );

class H {
  H(this.dir, {VideoNoteStart start = VideoNoteStart.started, List<core.StoredMessageSummary> rows = const []}) {
    recorder = FakeRecorder(dir, result: start);
    crop = FakeCrop(dir);
    tools = FakeVideoTools(dir);
    container = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      messageStoreProvider.overrideWithValue(FakeMessageStore()),
      messageSenderProvider.overrideWithValue(FakeSender()),
      chatStoreProvider.overrideWithValue(FakeChatStore()),
      hapticsProvider.overrideWithValue(Haptics(() => false)),
      mediaLoaderProvider.overrideWithValue(loader),
      netServiceProvider.overrideWith(OnlineNet.new),
      videoNoteRecorderProvider.overrideWithValue(() {
        made++;
        return recorder;
      }),
      videoNoteToolsProvider.overrideWithValue(crop),
      videoToolsProvider.overrideWithValue(tools),
      inlineVideoProvider.overrideWithValue(FakeInlineVideo.new),
      messagePageFetcherProvider.overrideWithValue(
        (String id, {int? beforeTs, String? beforeId, required int limit}) async => beforeId == null ? rows : const [],
      ),
      chatsProvider.overrideWith((ref) async => [const ChatPreview(id: chatId, name: 'Maria', preview: '', time: '')]),
    ]);
  }

  final Directory dir;
  late final FakeRecorder recorder;
  late final FakeCrop crop;
  late final FakeVideoTools tools;
  final loader = FakeLoader();
  int made = 0;
  late final ProviderContainer container;

  Future<void> pump(WidgetTester t, {bool reduceMotion = false}) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    addTearDown(container.dispose);
    await container.read(chatsProvider.future);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: const Size(390, 844), disableAnimations: reduceMotion),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              onGenerateRoute: (_) => PageRouteBuilder(
                pageBuilder: (_, _, _) => const ChatViewScreen(chatId: chatId, contactName: 'Maria'),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.pumpAndSettle();
  }
}

final mic = find.byKey(const ValueKey('composer-send-or-mic'));
final overlay = find.byKey(const ValueKey('video-note-overlay'));

/// Lets real file I/O (crop, read, delete) finish, then settles.
Future<void> settleIo(WidgetTester t) async {
  for (var i = 0; i < 30; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await t.pump(const Duration(milliseconds: 50));
  }
  await t.pumpAndSettle();
}

/// The mic button shows the camera glyph.
bool inVideoMode() => find.descendant(of: mic, matching: find.byKey(const ValueKey('video'))).evaluate().isNotEmpty;

/// The mode is remembered while the app runs (across tests too).
Future<void> switchToVideo(WidgetTester t) async {
  if (inVideoMode()) return;
  await t.tap(mic);
  await t.pump();
}

Future<TestGesture> holdMic(WidgetTester t) async {
  final g = await t.startGesture(t.getCenter(mic));
  await t.pump(const Duration(milliseconds: 600)); // long press
  await t.pump();
  await t.pump();
  return g;
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('video_note_test');
    FakeInlineVideo.made.clear();
    heardVideoNotes.clear();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a tap switches the mic to a camera and back, with a hint', (t) async {
    final h = H(dir);
    await h.pump(t);
    if (inVideoMode()) {
      await t.tap(mic);
      await t.pump(const Duration(seconds: 3));
    }
    final sem = t.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('Hold to record a voice message')), findsWidgets);

    await t.tap(mic);
    await t.pump();
    expect(find.byKey(const ValueKey('mic-hint')), findsOneWidget);
    expect(find.text('Hold to record a video message, tap for voice'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Hold to record a video message')), findsWidgets);
    expect(h.made, 0, reason: 'a tap records nothing');

    await t.pump(const Duration(seconds: 3));
    expect(find.byKey(const ValueKey('mic-hint')), findsNothing, reason: 'the hint goes away');

    await t.tap(mic);
    await t.pump();
    expect(find.text('Hold to record a voice message, tap for video'), findsOneWidget);
    await t.pump(const Duration(seconds: 3));
    sem.dispose();
  });

  testWidgets('hold records a circle; a second finger flips the camera; release sends a round video', (t) async {
    final h = H(dir);
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);

    expect(overlay, findsOneWidget);
    expect(find.byKey(const ValueKey('fake-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-note-record-ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-note-recording-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-hold-hint')), findsOneWidget);

    // Flip with another finger: the hold goes on.
    await t.tapAt(t.getCenter(find.byKey(const ValueKey('video-note-flip'))));
    await t.pump();
    expect(h.recorder.switches, 1);
    expect(overlay, findsOneWidget, reason: 'the second finger lifting does not end the recording');

    h.recorder.clock = const Duration(seconds: 5);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('0:05'), findsOneWidget);

    await g.up();
    await t.pump();
    expect(overlay, findsNothing);
    await settleIo(t);

    expect(h.crop.calls.single.$2, kVideoNoteSide, reason: 'cropped to a 480 px square');
    expect(File(h.recorder.recordedPath!).existsSync(), isFalse, reason: 'the camera file is deleted');
    expect(File(h.crop.out!).existsSync(), isFalse, reason: 'the square copy is deleted');
    expect(h.tools.calls, contains('poster square.mp4'), reason: 'poster from the square clip');

    final pending = h.container.read(pendingMediaProvider);
    expect(pending.single.kind, 'video', reason: 'old apps see a normal video');
    expect(pending.single.label, kVideoNoteLabel);
    // No Rust under `flutter test`: the upload fails and offers a retry.
    expect(find.textContaining('video message'), findsOneWidget);
  });

  testWidgets('slide left cancels — nothing is sent', (t) async {
    final h = H(dir);
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);
    h.recorder.clock = const Duration(seconds: 3);
    await g.moveBy(const Offset(-150, 0));
    await t.pump();
    expect(overlay, findsNothing);
    expect(h.recorder.cancelled, isTrue);
    await g.up();
    await settleIo(t);
    expect(h.crop.calls, isEmpty);
    expect(h.container.read(pendingMediaProvider), isEmpty);
  });

  testWidgets('slide up locks: hands free, then Send', (t) async {
    final h = H(dir);
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);
    await g.moveBy(const Offset(0, -100));
    await t.pump();
    await g.up();
    await t.pump();
    expect(overlay, findsOneWidget, reason: 'locked — still recording after the finger is up');
    expect(find.byKey(const ValueKey('recording-send')), findsOneWidget);
    h.recorder.clock = const Duration(seconds: 4);
    await t.tap(find.byKey(const ValueKey('recording-send')));
    await t.pump();
    await settleIo(t);
    expect(h.container.read(pendingMediaProvider).single.label, kVideoNoteLabel);
  });

  // Owner, 2026-10-18: "you press — nothing moves, recording starts
  // seconds later".
  testWidgets('the circle and the bar show at once, while the camera still opens', (t) async {
    final h = H(dir);
    h.recorder.gate = Completer<void>();
    await h.pump(t);
    await switchToVideo(t);
    final g = await t.startGesture(t.getCenter(mic));
    await t.pump(const Duration(milliseconds: 100));
    expect(overlay, findsNothing, reason: 'not a hold yet — could still be a tap');
    await t.pump(kMicHoldDelay);
    await t.pump();
    expect(overlay, findsOneWidget);
    expect(find.byKey(const ValueKey('video-note-starting')), findsOneWidget, reason: 'the camera is opening');
    expect(find.byKey(const ValueKey('video-note-recording-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('recording-held-button')), findsOneWidget);
    expect(find.text('0:00'), findsWidgets);

    h.recorder.gate!.complete();
    await t.pump();
    await t.pump();
    expect(find.byKey(const ValueKey('video-note-starting')), findsNothing);
    h.recorder.clock = const Duration(seconds: 3);
    await g.up();
    await settleIo(t);
    expect(h.container.read(pendingMediaProvider).single.label, kVideoNoteLabel);
  });

  testWidgets('let go while the camera is still opening: it all goes away, nothing is sent', (t) async {
    final h = H(dir);
    h.recorder.gate = Completer<void>();
    await h.pump(t);
    await switchToVideo(t);
    final g = await t.startGesture(t.getCenter(mic));
    await t.pump(kMicHoldDelay + const Duration(milliseconds: 50));
    await t.pump();
    expect(overlay, findsOneWidget);
    await g.up();
    await t.pump();
    expect(overlay, findsNothing);
    expect(find.byKey(const ValueKey('video-note-recording-bar')), findsNothing);
    expect(mic, findsOneWidget, reason: 'the composer is back');

    h.recorder.gate!.complete();
    await settleIo(t);
    expect(h.recorder.disposed, isTrue, reason: 'the camera is released once it has opened');
    expect(h.container.read(pendingMediaProvider), isEmpty);
  });

  testWidgets('a hold under a second is dropped', (t) async {
    final h = H(dir);
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);
    h.recorder.clock = const Duration(milliseconds: 400);
    await g.up();
    await settleIo(t);
    expect(h.crop.calls, isEmpty);
    expect(File(h.recorder.recordedPath!).existsSync(), isFalse, reason: 'the short clip is deleted');
    expect(h.container.read(pendingMediaProvider), isEmpty);
  });

  testWidgets('at 60 s it stops and sends by itself', (t) async {
    final h = H(dir);
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);
    h.recorder.clock = kMaxVideoNoteDuration;
    await t.pump(const Duration(milliseconds: 300));
    expect(overlay, findsNothing);
    await settleIo(t);
    expect(h.container.read(pendingMediaProvider).single.label, kVideoNoteLabel);
    await g.up();
    await t.pump();
  });

  testWidgets('camera or microphone refused: says so, records nothing', (t) async {
    final h = H(dir, start: VideoNoteStart.denied);
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);
    await g.up();
    await t.pump();
    expect(overlay, findsNothing);
    expect(find.text('Allow the camera and microphone in Settings to record video messages'), findsOneWidget);
    expect(h.recorder.disposed, isTrue, reason: 'the camera is released');
  });

  testWidgets('round bubble: muted loop on screen, tap plays with sound and grows, ends back muted', (t) async {
    final h = H(dir, rows: [row('v1', 1, 'video', media: roundJson), row('v2', 2, 'video', media: plainVideoJson)]);
    await h.pump(t);
    expect(find.byKey(const ValueKey('video-note-bubble')), findsOneWidget);
    expect(find.byKey(const ValueKey('video-bubble')), findsOneWidget, reason: 'a normal video keeps its bubble');

    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    final v = FakeInlineVideo.made.single;
    expect(v.opened && v.playing, isTrue, reason: 'autoplays once on screen');
    expect((v.volume, v.looping), (0.0, true), reason: 'muted, looping');
    expect(h.loader.fetched, contains('f:$roundJson'));
    Size size() => t.getSize(find.byKey(const ValueKey('video-note-bubble')));
    expect(size(), const Size(kVideoNoteBubble, kVideoNoteBubble));
    // Muted: a speaker-off icon after the length, not a 🔇 character.
    expect(find.byKey(const ValueKey('video-note-muted')), findsOneWidget);
    expect(find.textContaining('🔇'), findsNothing);
    expect(find.text('▶'), findsNothing);

    await t.tap(find.byKey(const ValueKey('video-note-bubble')));
    await t.pumpAndSettle();
    expect((v.volume, v.looping, v.playing), (1.0, false, true), reason: 'from the start, with sound');
    expect(size(), const Size(kVideoNoteBubbleExpanded, kVideoNoteBubbleExpanded));
    expect(find.byKey(const ValueKey('video-note-ring')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('video-note-bubble')));
    await t.pumpAndSettle();
    expect(v.playing, isFalse, reason: 'a second tap pauses');
    expect(
      find.descendant(of: find.byKey(const ValueKey('video-note-bubble')), matching: find.byIcon(CupertinoIcons.play_fill)),
      findsOneWidget,
      reason: 'a play icon over the paused circle',
    );
    await t.tap(find.byKey(const ValueKey('video-note-bubble')));
    await t.pumpAndSettle();
    expect(v.playing, isTrue);

    v.finish();
    await t.pumpAndSettle();
    expect((v.volume, v.looping, v.playing), (0.0, true, true), reason: 'back to the muted loop');
    expect(size(), const Size(kVideoNoteBubble, kVideoNoteBubble));
    expect(find.byKey(const ValueKey('video-note-ring')), findsNothing);
    expect(find.byKey(const ValueKey('video-note-muted')), findsNothing, reason: 'heard with sound: no muted mark');
  });

  testWidgets('drag around the ring rewinds; a drag mid-picture does not', (t) async {
    final h = H(dir, rows: [row('v1', 1, 'video', media: roundJson)]);
    await h.pump(t);
    final bubble = find.byKey(const ValueKey('video-note-bubble'));
    await t.tap(bubble);
    await t.pumpAndSettle();
    final v = FakeInlineVideo.made.single;
    expect(v.playing, isTrue);
    expect(find.byKey(const ValueKey('video-note-scrubber')), findsOneWidget);

    final c = t.getCenter(bubble);
    const r = kVideoNoteBubbleExpanded / 2 - 10;
    Offset ring(double f) => c + Offset(r * math.sin(f * 2 * math.pi), -r * math.cos(f * 2 * math.pi));

    // 3 o'clock → 6 o'clock along the ring: half of the 12 s clip.
    final g = await t.startGesture(ring(0.25));
    for (var f = 0.27; f <= 0.5; f += 0.02) {
      await g.moveTo(ring(f));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.moveTo(ring(0.5));
    await t.pump();
    expect(v.playing, isFalse, reason: 'paused under the finger');
    expect(find.text('0:06'), findsOneWidget, reason: 'the time left follows the finger');
    await g.up();
    await t.pumpAndSettle();
    expect(v.position.inMilliseconds, closeTo(6000, 120));
    expect(v.playing, isTrue, reason: 'plays on from there');

    // Past 12 o'clock it stops at the end instead of wrapping to the start.
    final g2 = await t.startGesture(ring(0.9));
    for (final f in [0.93, 0.97, 0.02, 0.06]) {
      await g2.moveTo(ring(f));
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(find.text('0:00'), findsOneWidget, reason: 'held at the end');
    await g2.up();
    await t.pumpAndSettle();

    // From the middle of the picture: not a scrub.
    final before = v.position;
    await t.dragFrom(c, const Offset(60, 60));
    await t.pumpAndSettle();
    expect(v.position, before);
  });

  test('ring fraction: 12 o\'clock is 0, clockwise', () {
    const box = Size(200, 200);
    expect(videoNoteRingFraction(const Offset(100, 0), box), closeTo(0, 1e-9));
    expect(videoNoteRingFraction(const Offset(200, 100), box), closeTo(0.25, 1e-9));
    expect(videoNoteRingFraction(const Offset(100, 200), box), closeTo(0.5, 1e-9));
    expect(videoNoteRingFraction(const Offset(0, 100), box), closeTo(0.75, 1e-9));
  });

  testWidgets('reduce motion: no autoplay; a tap still plays', (t) async {
    final h = H(dir, rows: [row('v1', 1, 'video', media: roundJson)]);
    await h.pump(t, reduceMotion: true);
    await t.pump(const Duration(seconds: 1));
    expect(FakeInlineVideo.made, isEmpty);
    await t.tap(find.byKey(const ValueKey('video-note-bubble')));
    await t.pumpAndSettle();
    expect(FakeInlineVideo.made.single.volume, 1.0);
  });

  testWidgets('the bubble draws the clip only inside the circle', (t) async {
    final h = H(dir, rows: [row('1', 1, 'video', media: roundJson)]);
    await h.pump(t);
    await t.pump(const Duration(milliseconds: 400));
    await t.pumpAndSettle();
    final playing = find.byKey(const ValueKey('video-note-playing'));
    expect(playing, findsOneWidget);
    expect(find.ancestor(of: playing, matching: find.byType(VideoNoteCircle)), findsOneWidget);
    expect(find.ancestor(of: playing, matching: find.byType(ClipOval)), findsOneWidget);
  });

  test('round JSON is recognised; a plain video is not', () {
    expect(isVideoNoteJson(roundJson), isTrue);
    expect(isVideoNoteJson(plainVideoJson), isFalse);
    expect(isVideoNoteJson(null), isFalse);
  });

  test('the circle crop fails twice: nothing goes out — never the uncropped original (privacy)', () async {
    final orig = File('${dir.path}/camera.mov')..writeAsBytesSync(List.filled(800, 3));
    final crop = FakeCrop(dir, failFirst: 99);
    final tools = FakeVideoTools(dir);
    await expectLater(prepareVideoNote(crop, tools, orig.path), throwsA(isA<VideoNoteCropFailed>()));
    expect(crop.calls.length, kVideoNoteCropAttempts, reason: 'tried again before giving up');
    expect(tools.calls, isEmpty, reason: 'the original is never read, compressed or postered');
    expect(orig.existsSync(), isFalse, reason: 'the camera file is still deleted');
  });

  test('the crop throws: refused the same way', () async {
    final orig = File('${dir.path}/camera.mov')..writeAsBytesSync(List.filled(800, 3));
    await expectLater(
      prepareVideoNote(_ThrowingCrop(), FakeVideoTools(dir), orig.path),
      throwsA(isA<VideoNoteCropFailed>()),
    );
    expect(orig.existsSync(), isFalse);
  });

  test('a "square" that is the camera file itself is refused', () async {
    final orig = File('${dir.path}/camera.mov')..writeAsBytesSync(List.filled(800, 3));
    final tools = FakeVideoTools(dir);
    await expectLater(prepareVideoNote(_SameFileCrop(), tools, orig.path), throwsA(isA<VideoNoteCropFailed>()));
    expect(tools.calls, isEmpty);
  });

  test('the first crop fails, the retry works: the circle goes out', () async {
    final orig = File('${dir.path}/camera.mov')..writeAsBytesSync(List.filled(800, 3));
    final crop = FakeCrop(dir, failFirst: 1);
    final p = await prepareVideoNote(crop, FakeVideoTools(dir), orig.path);
    expect(crop.calls.length, 2);
    expect(p.video.bytes.length, 1500, reason: 'the square copy, not the 800-byte original');
    expect((p.width, p.height), (kVideoNoteSide, kVideoNoteSide));
    expect(orig.existsSync(), isFalse);
    expect(File(crop.out!).existsSync(), isFalse);
  });

  testWidgets('crop fails in the chat: nothing is sent, it says why', (t) async {
    final h = H(dir);
    h.crop.failFirst = 99;
    await h.pump(t);
    await switchToVideo(t);
    final g = await holdMic(t);
    h.recorder.clock = const Duration(seconds: 4);
    await t.pump(const Duration(milliseconds: 200));
    await g.up();
    await t.pump();
    await settleIo(t);
    expect(h.crop.calls.length, kVideoNoteCropAttempts);
    expect(h.container.read(pendingMediaProvider), isEmpty, reason: 'nothing is sent');
    expect(h.tools.calls, isEmpty);
    expect(File(h.recorder.recordedPath!).existsSync(), isFalse, reason: 'the camera file is deleted');
    expect(find.textContaining("Couldn't cut the video down to the circle"), findsOneWidget);
  });
}

class _ThrowingCrop implements VideoNoteTools {
  @override
  Future<String?> square(String path, int side) async => throw StateError('encoder');
}

class _SameFileCrop implements VideoNoteTools {
  @override
  Future<String?> square(String path, int side) async => path;
}
