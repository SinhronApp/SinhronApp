// Chat gallery: paging, strip, chrome, zoom gestures, actions, video.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/media_cache.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/media_viewer/chat_gallery.dart';
import 'package:sinhron/features/media_viewer/gallery_pages.dart';
import 'package:sinhron/features/media_viewer/gallery_video.dart';
import 'package:sinhron/features/media_viewer/photo_gallery_screen.dart';
import 'package:sinhron/features/video_note/video_note_circle.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'fake_video_platform.dart';

class FakeLoader implements MediaLoader {
  @override
  Future<core.MediaInfo> info(String mediaJson) async {
    final video = mediaJson.contains('video');
    return core.MediaInfo(
      kind: video ? 'video' : 'photo',
      mimeType: video ? 'video/mp4' : 'image/jpeg',
      fileName: '',
      blurhash: '',
      width: 1280,
      height: 720,
      durationMs: video ? 10000 : 0,
      waveform: Uint8List(0),
      caption: '',
      sizeBytes: BigInt.from(1024 * 1024),
      round: false,
      hasThumbnail: false,
    );
  }

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => Uint8List(0);

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async {
    if (mediaJson.contains('video') && !thumbnail) return Uint8List(16);
    throw StateError('not in tests');
  }
}

GalleryItem item(int n, {bool video = false}) => GalleryItem(
  mediaJson: '{"n":$n${video ? ',"video":1' : ''}}',
  heroTag: 'photo-$n',
  sender: 'Maria',
  date: 'Today · 14:0$n',
  caption: n == 1 ? 'Sunset' : '',
  isVideo: video,
  rowId: 'r$n',
  wireId: 'w$n',
);

/// A round video message (ADR-048). The fake player says 1280×720 — like
/// an old clip that went out uncropped.
GalleryItem roundItem(int n) => GalleryItem(
  mediaJson: '{"n":$n,"video":1,"round":true}',
  heroTag: 'photo-$n',
  sender: 'Maria',
  date: 'Today · 14:0$n',
  isVideo: true,
  round: true,
  rowId: 'r$n',
  wireId: 'w$n',
);

late FakeVideoPlatform video;

Future<void> pumpGallery(
  WidgetTester t,
  List<GalleryItem> items,
  int index, {
  GalleryActions actions = const GalleryActions(),
  Future<List<GalleryItem>>? allItems,
  MediaCache? cache,
}) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        mediaLoaderProvider.overrideWithValue(FakeLoader()),
        mediaCacheProvider.overrideWithValue(cache ?? MediaCache()),
        galleryVideoOpenerProvider.overrideWithValue(
          (bytes, mime) async =>
              GalleryVideoHandle(VideoPlayerController.networkUrl(Uri.parse('http://127.0.0.1/v')), () async {}),
        ),
      ],
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder(
              pageBuilder: (ctx, _, _) => Center(
                child: GestureDetector(
                  key: const ValueKey('open'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => openPhotoGallery(ctx, items, index, actions: actions, allItems: allItems),
                  child: const SizedBox(width: 100, height: 100),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.byKey(const ValueKey('open')));
  await t.pumpAndSettle();
}

double chromeOpacity(WidgetTester t) => t
    .widget<AnimatedOpacity>(
      find.ancestor(of: find.byKey(const ValueKey('gallery-counter')), matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

Future<void> doubleTapAt(WidgetTester t, Offset p) async {
  await t.tapAt(p);
  await t.pump(const Duration(milliseconds: 60));
  await t.tapAt(p);
  await t.pumpAndSettle();
}

/// A tap waits out the double-tap window (zoom) before it counts.
Future<void> singleTapAt(WidgetTester t, Offset p) async {
  await t.tapAt(p);
  await t.pump(const Duration(milliseconds: 350));
  await t.pumpAndSettle();
}

Future<void> close(WidgetTester t) async {
  await t.tap(find.byKey(const ValueKey('gallery-close')));
  await t.pumpAndSettle();
  expect(find.byKey(const ValueKey('gallery-pages')), findsNothing);
}

void main() {
  setUp(() {
    video = FakeVideoPlatform();
    VideoPlayerPlatform.instance = video;
  });

  testWidgets('pages through every item: counter, sender · date, strip, keys', (t) async {
    final items = [for (var n = 1; n <= 5; n++) item(n, video: n == 4)];
    await pumpGallery(t, items, 2);
    expect(find.text('3 of 5'), findsOneWidget);
    expect(find.text('Maria · Today · 14:03'), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-strip')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('gallery-strip-photo-1')));
    await t.pumpAndSettle();
    expect(find.text('1 of 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-caption')), findsOneWidget, reason: 'its caption');

    await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(-300, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('2 of 5'), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-caption')), findsNothing);

    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pumpAndSettle();
    expect(find.text('3 of 5'), findsOneWidget, reason: 'iPad keyboard');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-pages')), findsNothing);
  });

  testWidgets('one tap hides the chrome, another brings it back', (t) async {
    await pumpGallery(t, [item(1), item(2)], 0);
    expect(chromeOpacity(t), 1);
    await singleTapAt(t, const Offset(195, 400));
    expect(chromeOpacity(t), 0);
    await singleTapAt(t, const Offset(195, 400));
    expect(chromeOpacity(t), 1);
  });

  testWidgets('double tap zooms into the point and locks paging; again → back', (t) async {
    await pumpGallery(t, [item(1), item(2)], 0);
    final zoom = t.state<ZoomableViewState>(find.byType(ZoomableView));
    await doubleTapAt(t, const Offset(100, 300));
    expect(zoom.scale, greaterThanOrEqualTo(2.5));
    expect(chromeOpacity(t), 1, reason: 'a double tap is not a tap');

    // Zoomed: a swipe pans the photo, it doesn't turn the page.
    await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(-300, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
    // …and a drag down doesn't close it.
    await t.drag(find.byKey(const ValueKey('gallery-pages')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);

    await doubleTapAt(t, const Offset(195, 400));
    expect(zoom.scale, 1);
    await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(-300, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
  });

  testWidgets('pinch rubber-bands past 1× and the max, then settles', (t) async {
    await pumpGallery(t, [item(1)], 0);
    final zoom = t.state<ZoomableViewState>(find.byType(ZoomableView));
    const c = Offset(195, 422);

    Future<void> pinch(double spanFrom, double step, int steps, void Function() during) async {
      final a = await t.startGesture(c - Offset(spanFrom / 2, 0), pointer: 1);
      final b = await t.startGesture(c + Offset(spanFrom / 2, 0), pointer: 2);
      for (var i = 0; i < steps; i++) {
        await a.moveBy(Offset(-step, 0));
        await b.moveBy(Offset(step, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      during();
      await a.up();
      await b.up();
      await t.pumpAndSettle();
    }

    // Pinch in below 1×: it shrinks a little (resisting), then springs back.
    await pinch(200, -6, 15, () => expect(zoom.scale, inExclusiveRange(0.5, 0.99)));
    expect(zoom.scale, 1);

    // Spread far past 5×: it goes a bit past, then settles at 5×.
    await pinch(60, 12, 40, () => expect(zoom.scale, greaterThan(5)));
    expect(zoom.scale, closeTo(5, 0.001));
  });

  testWidgets('drag down: small springs back, far closes', (t) async {
    await pumpGallery(t, [item(1), item(2)], 0);
    await t.drag(find.byKey(const ValueKey('gallery-pages')), const Offset(0, 40));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
    await t.drag(find.byKey(const ValueKey('gallery-pages')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsNothing);
  });

  testWidgets('share is anchored at its button (iPad popover); save says so', (t) async {
    Rect? origin;
    var saved = 0;
    await pumpGallery(
      t,
      [item(1), item(2)],
      0,
      actions: GalleryActions(
        share: (it, o) async {
          origin = o;
          return true;
        },
        save: (it) async {
          saved++;
          return true;
        },
      ),
    );
    await t.tap(find.byKey(const ValueKey('gallery-share')));
    await t.pumpAndSettle();
    final button = t.getRect(find.byKey(const ValueKey('gallery-share')));
    expect(origin, isNotNull);
    expect(origin!.overlaps(button), isTrue);

    await t.tap(find.byKey(const ValueKey('gallery-save')));
    await t.pump();
    expect(saved, 1);
    expect(find.text('Saved to Photos'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Saved to Photos'), findsNothing);
  });

  testWidgets('no forward / show in chat / delete buttons without actions', (t) async {
    await pumpGallery(t, [item(1)], 0);
    expect(find.byKey(const ValueKey('gallery-share')), findsOneWidget);
    expect(find.byKey(const ValueKey('gallery-forward')), findsNothing);
    expect(find.byKey(const ValueKey('gallery-show-in-chat')), findsNothing);
    expect(find.byKey(const ValueKey('gallery-delete')), findsNothing);
    expect(find.byKey(const ValueKey('gallery-strip')), findsNothing, reason: 'one item: no strip');
    expect(find.text('Maria'), findsOneWidget, reason: 'one item: sender instead of "1 of 1"');
  });

  testWidgets('forward: "Forwarded" when sent, nothing when cancelled', (t) async {
    bool? answer;
    final sent = <String>[];
    await pumpGallery(
      t,
      [item(1), item(2)],
      1,
      actions: GalleryActions(
        forward: (it) async {
          sent.add(it.mediaJson);
          return answer;
        },
      ),
    );
    await t.tap(find.byKey(const ValueKey('gallery-forward')));
    await t.pump();
    expect(find.byKey(const ValueKey('gallery-notice')), findsNothing, reason: 'picked nothing');
    answer = true;
    await t.tap(find.byKey(const ValueKey('gallery-forward')));
    await t.pump();
    expect(find.text('Forwarded'), findsOneWidget);
    expect(sent, [item(2).mediaJson, item(2).mediaJson]);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('show in chat closes the gallery and hands over the item', (t) async {
    GalleryItem? shown;
    await pumpGallery(t, [item(1), item(2)], 1, actions: GalleryActions(showInChat: (it) => shown = it));
    await t.tap(find.byKey(const ValueKey('gallery-show-in-chat')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-pages')), findsNothing);
    expect(shown?.wireId, 'w2');
  });

  testWidgets('delete drops the item and shows the next; the last one closes', (t) async {
    final asked = <String>[];
    await pumpGallery(
      t,
      [item(1), item(2), item(3)],
      1,
      actions: GalleryActions(
        delete: (it) async {
          asked.add(it.rowId!);
          return true;
        },
      ),
    );
    await t.tap(find.byKey(const ValueKey('gallery-delete')));
    await t.pumpAndSettle();
    expect(find.text('2 of 2'), findsOneWidget);
    expect(find.text('Maria · Today · 14:03'), findsOneWidget, reason: 'the next one slid in');

    await t.tap(find.byKey(const ValueKey('gallery-delete')));
    await t.pumpAndSettle();
    expect(find.text('Maria'), findsOneWidget, reason: 'only photo 1 is left');
    await t.tap(find.byKey(const ValueKey('gallery-delete')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-pages')), findsNothing);
    expect(asked, ['r2', 'r3', 'r1']);
  });

  testWidgets('the full list merges in after opening, the same photo on screen', (t) async {
    final full = Completer<List<GalleryItem>>();
    await pumpGallery(t, [item(3), item(4)], 0, allItems: full.future);
    expect(find.text('1 of 2'), findsOneWidget);
    full.complete([for (var n = 1; n <= 5; n++) item(n)]);
    await t.pumpAndSettle();
    expect(find.text('3 of 5'), findsOneWidget);
    expect(find.text('Maria · Today · 14:03'), findsOneWidget);
    await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(300, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('2 of 5'), findsOneWidget, reason: 'older ones are reachable');
  });

  testWidgets('first frame paints the cached thumbnail, never "Decrypting…"', (t) async {
    final cache = MediaCache();
    cache.put(mediaCacheKey(item(1).mediaJson, thumbnail: true), _png);
    final items = [item(1)];
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          mediaLoaderProvider.overrideWithValue(FakeLoader()),
          mediaCacheProvider.overrideWithValue(cache),
        ],
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              observers: [HeroController()],
              onGenerateRoute: (_) => PageRouteBuilder(
                pageBuilder: (ctx, _, _) => Center(
                  child: GestureDetector(
                    key: const ValueKey('open'),
                  behavior: HitTestBehavior.opaque,
                    onTap: () => openPhotoGallery(ctx, items, 0),
                    child: const SizedBox(
                      width: 120,
                      height: 90,
                      child: Hero(tag: 'photo-1', child: ColoredBox(color: Color.fromRGBO(1, 2, 3, 1))),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open')));
    await t.pump(const Duration(milliseconds: 200)); // thumbnail precache (times out in fake time)
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(
      find.byWidgetPredicate((w) => w.runtimeType.toString() == '_MorphShuttle'),
      findsOneWidget,
      reason: 'the bubble grows into the viewer',
    );
    expect(find.text('Decrypting…'), findsNothing);
    // Landed: the page's very first frame has the thumbnail.
    await t.pump(const Duration(milliseconds: 320));
    expect(find.byKey(const ValueKey('gallery-thumb')), findsOneWidget);
    expect(find.text('Decrypting…'), findsNothing);
    await t.pumpAndSettle();
    expect(find.text('Photo unavailable'), findsNothing, reason: 'the thumbnail stays while the full one fails');
  });

  group('video', () {
    testWidgets('plays with controls; pause, sound, scrub, loop; chrome hides while playing', (t) async {
      await pumpGallery(t, [item(1), item(2, video: true)], 1);
      await t.pumpAndSettle();
      expect(video.calls, containsAllInOrder(['create', 'play']));
      expect(video.looping, isTrue, reason: '10 s clip loops');
      expect(find.byKey(const ValueKey('gallery-video-controls')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('gallery-video-play')));
      await t.pump();
      expect(video.calls.last, 'pause');
      await t.tap(find.byKey(const ValueKey('gallery-video-play')));
      await t.pump();
      expect(video.calls.last, 'play');

      await t.tap(find.byKey(const ValueKey('gallery-video-mute')));
      await t.pump();
      expect(video.volume, 0);

      final bar = t.getRect(find.byKey(const ValueKey('gallery-video-scrubber')));
      await t.dragFrom(bar.centerLeft + const Offset(4, 0), Offset(bar.width / 2, 0));
      await t.pump();
      expect(video.calls, contains('seek'));
      expect(video.position.inMilliseconds, inInclusiveRange(4000, 6000));
      expect(video.calls.last, 'play', reason: 'scrubbing resumes playback');

      // Left alone while playing: the chrome goes, the video keeps playing.
      await t.pump(const Duration(seconds: 3));
      await t.pumpAndSettle();
      expect(chromeOpacity(t), 0);
      expect(video.calls.last, 'play');

      // Swipe to the photo: paused, no video controls.
      await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(300, 0), 1500);
      await t.pumpAndSettle();
      expect(find.text('1 of 2'), findsOneWidget);
      expect(video.calls.last, 'pause');
      expect(find.byKey(const ValueKey('gallery-video-controls')), findsNothing);

      await singleTapAt(t, const Offset(195, 400));
      await close(t);
      // The player is freed off the frame (after its controls let go).
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pumpAndSettle();
      expect(video.calls, contains('dispose'), reason: 'the player and its RAM copy are let go');
    });

    testWidgets('a round video is a circle — page, picture, strip — with no share or save (ADR-048)', (t) async {
      var shared = 0, saved = 0;
      await pumpGallery(
        t,
        [item(1), roundItem(2)],
        1,
        actions: GalleryActions(
          share: (it, o) async => ++shared > 0,
          save: (it) async => ++saved > 0,
          forward: (it) async => true,
        ),
      );
      await t.pumpAndSettle();
      expect(video.calls, containsAllInOrder(['create', 'play']));

      // The page: a square box with the circle in it, not a 16:9 player.
      final box = t.getSize(find.byKey(const ValueKey('gallery-round')));
      expect(box.width, box.height);
      expect(box.width, lessThan(390));
      final picture = find.byKey(const ValueKey('gallery-round-video'));
      expect(picture, findsOneWidget);
      // Every frame of it is drawn inside a circle — nothing at the edges.
      final players = find.byType(VideoPlayer);
      expect(players, findsOneWidget);
      expect(find.ancestor(of: players, matching: find.byType(ClipOval)), findsOneWidget);
      expect(find.ancestor(of: players, matching: find.byType(AspectRatio)), findsOneWidget,
          reason: 'only the circle\'s own 1:1 box, never the clip\'s 16:9');
      expect(t.widget<AspectRatio>(find.ancestor(of: players, matching: find.byType(AspectRatio))).aspectRatio, 1);
      final fitted = t.widget<FittedBox>(find.descendant(of: picture, matching: find.byType(FittedBox)));
      expect(fitted.fit, BoxFit.cover);
      // The strip shows it round too.
      expect(
        find.descendant(of: find.byKey(const ValueKey('gallery-strip-photo-2')), matching: find.byType(VideoNoteCircle)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('gallery-strip-photo-1')), matching: find.byType(VideoNoteCircle)),
        findsNothing,
      );

      // No share / save: the file may hold more than the circle.
      expect(find.byKey(const ValueKey('gallery-share')), findsNothing);
      expect(find.byKey(const ValueKey('gallery-save')), findsNothing);
      expect(find.byKey(const ValueKey('gallery-forward')), findsOneWidget, reason: 'forwarding keeps it round');
      expect(shared + saved, 0);

      // Swipe to the photo: share and save are back.
      await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(300, 0), 1500);
      await t.pumpAndSettle();
      expect(find.text('1 of 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('gallery-share')), findsOneWidget);
      expect(find.byKey(const ValueKey('gallery-save')), findsOneWidget);
      await close(t);
    });

    test('share / save refuse a round video outright', () async {
      expect(await shareGalleryItem(FakeLoader(), roundItem(2), Rect.zero), isFalse);
      expect(await saveGalleryItem(FakeLoader(), roundItem(2)), isFalse);
    });

    testWidgets('a long video does not loop', (t) async {
      video = FakeVideoPlatform(duration: const Duration(minutes: 3));
      VideoPlayerPlatform.instance = video;
      await pumpGallery(t, [item(2, video: true)], 0);
      await t.pumpAndSettle();
      expect(video.looping, isFalse);
      await close(t);
    });
  });

  test('galleryItemsOf: photos and videos only, oldest first, albums in order', () {
    core.StoredMessageSummary r(String id, int ts, String kind, {bool deleted = false, String? media = '{}'}) =>
        core.StoredMessageSummary(
          id: id,
          chatId: 'c',
          tsUnix: 1760000000 + ts,
          body: id == 'b' ? 'hi' : '',
          kind: kind,
          isMine: id == 'b',
          mediaJson: media == null ? null : '{"id":"$id"}',
          wireId: 'w$id',
          status: 1,
          deleted: deleted,
        );
    final rows = [
      r('d', 5, 'photo'),
      r('a', 1, 'photo'),
      r('b', 2, 'video'),
      r('c', 2, 'photo'), // same second as b (album): stored order kept
      r('t', 3, 'text'),
      r('x', 4, 'photo', deleted: true),
      r('v', 4, 'voice'),
      r('n', 4, 'photo', media: null),
    ];
    final items = galleryItemsOf(rows, senderOf: (row) => row.isMine ? 'You' : 'Maria', heroPrefix: 'shared-');
    expect([for (final i in items) i.rowId], ['a', 'b', 'c', 'd']);
    expect(items[1].isVideo, isTrue);
    expect(items[1].sender, 'You');
    expect(items[1].caption, 'hi');
    expect(items[0].heroTag, 'shared-a');
    expect(items[0].wireId, 'wa');
  });

  test('galleryItemsOf skips round videos (ADR-048); with videoNotes it keeps and marks them', () {
    core.StoredMessageSummary r(String id, String kind, String media) => core.StoredMessageSummary(
      id: id,
      chatId: 'c',
      tsUnix: 1760000000 + id.codeUnitAt(0),
      body: '',
      kind: kind,
      isMine: false,
      mediaJson: media,
      status: 1,
      deleted: false,
    );
    final rows = [
      r('a', 'video', '{"kind":"video","round":true}'),
      r('b', 'video', '{"kind":"video"}'),
      r('c', 'photo', '{"kind":"photo"}'),
    ];
    // Swiping through the chat's pictures: a round video isn't one of them.
    final swipe = galleryItemsOf(rows, senderOf: (_) => 'Maria');
    expect([for (final i in swipe) i.rowId], ['b', 'c']);
    expect(swipe.any((i) => i.round), isFalse);
    final items = galleryItemsOf(rows, senderOf: (_) => 'Maria', videoNotes: true);
    expect([for (final i in items) i.round], [true, false, false]);
  });

  testWidgets('a round video flies in as a circle, not its whole frame', (t) async {
    final cache = MediaCache();
    final round = roundItem(2);
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          mediaLoaderProvider.overrideWithValue(FakeLoader()),
          mediaCacheProvider.overrideWithValue(cache),
          galleryVideoOpenerProvider.overrideWithValue(
            (bytes, mime) async =>
                GalleryVideoHandle(VideoPlayerController.networkUrl(Uri.parse('http://127.0.0.1/v')), () async {}),
          ),
        ],
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Navigator(
              observers: [HeroController()],
              onGenerateRoute: (_) => PageRouteBuilder(
                pageBuilder: (ctx, _, _) => Center(
                  child: GestureDetector(
                    key: const ValueKey('open'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => openPhotoGallery(ctx, [round], 0),
                    child: const SizedBox(
                      width: 120,
                      height: 120,
                      child: Hero(tag: 'photo-2', child: ColoredBox(color: Color.fromRGBO(1, 2, 3, 1))),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open')));
    await t.pump(const Duration(milliseconds: 200));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const ValueKey('gallery-round-shuttle')), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_MorphShuttle'), findsNothing);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('gallery-round')), findsOneWidget);
    await close(t);
  });

  test('fitRect: contain and cover, centred', () {
    const box = Size(400, 800);
    expect(fitRect(box, 2, cover: false), const Rect.fromLTWH(0, 300, 400, 200));
    expect(fitRect(box, 2, cover: true), const Rect.fromLTWH(-600, 0, 1600, 800));
    expect(fitRect(box, 0.5, cover: false), const Rect.fromLTWH(0, 0, 400, 800));
  });
}

// 1×1 transparent PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);
