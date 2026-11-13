import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_view/encrypted_photo.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_messages.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/chat_view_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../../core/chat_actions_test.dart' show FakeChatStore;
import '../../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../../core/settings_providers_test.dart' show MemoryStore;

const chatId = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

class FakeLoader implements MediaLoader {
  final fetched = <String>[];
  @override
  Future<core.MediaInfo> info(String mediaJson) async => core.MediaInfo(
        kind: mediaJson.contains('video') ? 'video' : 'photo',
        mimeType: mediaJson.contains('video') ? 'video/mp4' : 'image/jpeg',
        fileName: '',
        blurhash: '',
        width: 1280,
        height: 720,
        durationMs: mediaJson.contains('video') ? 83000 : 0,
        waveform: Uint8List(0),
        caption: '',
        sizeBytes: BigInt.from(3 * 1024 * 1024),
        hasThumbnail: mediaJson.contains('poster'),
        round: false,
      );
  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => Uint8List(0);
  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async {
    fetched.add(mediaJson);
    throw StateError('not in tests');
  }
}

class FakeLinkLoader implements LinkPreviewLoader {
  @override
  Future<core.LinkPreviewInfo> info(String json) async => const core.LinkPreviewInfo(
        url: 'https://example.org/post',
        domain: 'example.org',
        title: 'A great article',
        description: 'Worth reading',
        hasImage: false,
      );
  @override
  Future<Uint8List> image(String json) async => Uint8List(0);
}

String photoJson(int n, {String album = 'al1'}) => '{"v":1,"kind":"photo","n":$n,"album_id":"$album"}';

core.StoredMessageSummary row(String id, int ts, String kind, {String body = '', String? media, bool mine = false}) =>
    core.StoredMessageSummary(
      id: id,
      chatId: chatId,
      tsUnix: 1760000000 + ts,
      body: body,
      kind: kind,
      isMine: mine,
      mediaJson: media,
      wireId: '00000000-0000-4000-8000-00000000000$ts',
      status: 1,
      deleted: false,
    );

Future<ProviderContainer> pumpChat(WidgetTester t, List<core.StoredMessageSummary> rows) async {
  t.view.physicalSize = const Size(390, 844);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final c = ProviderContainer(overrides: [
    settingsStoreProvider.overrideWithValue(MemoryStore()),
    messageStoreProvider.overrideWithValue(FakeMessageStore()),
    messageSenderProvider.overrideWithValue(FakeSender()),
    chatStoreProvider.overrideWithValue(FakeChatStore()),
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    mediaLoaderProvider.overrideWithValue(FakeLoader()),
    linkPreviewLoaderProvider.overrideWithValue(FakeLinkLoader()),
    messagePageFetcherProvider.overrideWithValue(
      (String id, {int? beforeTs, String? beforeId, required int limit}) async => beforeId == null ? rows : const [],
    ),
    chatsProvider.overrideWith((ref) async => [const ChatPreview(id: chatId, name: 'Maria', preview: '', time: '')]),
  ]);
  addTearDown(c.dispose);
  await c.read(chatsProvider.future);
  await t.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
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
  return c;
}

void main() {
  testWidgets('an album is one grid bubble; a tile opens the gallery at it', (t) async {
    await pumpChat(t, [
      row('p1', 1, 'photo', media: photoJson(1), body: 'Trip'),
      row('p2', 2, 'photo', media: photoJson(2)),
      row('p3', 3, 'photo', media: photoJson(3)),
      row('p4', 4, 'photo', media: photoJson(4, album: 'other')),
    ]);
    expect(find.byKey(const ValueKey('album-tile-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('album-tile-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('album-tile-3')), findsNothing, reason: 'another album is its own bubble');

    await t.tap(find.byKey(const ValueKey('album-tile-1')));
    await t.pumpAndSettle();
    expect(find.text('2 of 4'), findsOneWidget, reason: 'gallery over every photo of the chat');

    // Swipe to the next photo.
    await t.fling(find.byKey(const ValueKey('gallery-pages')), const Offset(-300, 0), 1500);
    await t.pumpAndSettle();
    expect(find.text('3 of 4'), findsOneWidget);

    // Drag down far enough → closes.
    await t.drag(find.byKey(const ValueKey('gallery-pages')), const Offset(0, 300));
    await t.pumpAndSettle();
    expect(find.text('3 of 4'), findsNothing);
  });

  // Owner, 2026-11-03: a round video message is not a video — swiping
  // through the chat's photos never lands on one.
  testWidgets('the gallery opened from a photo skips round video messages', (t) async {
    await pumpChat(t, [
      row('p1', 1, 'photo', media: photoJson(1)),
      row('p2', 2, 'photo', media: photoJson(2)),
      row('n1', 3, 'video', media: '{"v":1,"kind":"video","round":true}'),
    ]);
    expect(find.byKey(const ValueKey('video-note-bubble')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('album-tile-0')));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget, reason: 'two photos, the round video left out');
    await t.tap(find.byKey(const ValueKey('gallery-close')));
    await t.pumpAndSettle();
  });

  // Status 213 (owner: "compare how photos are sent — Telegram, iMessage")
  // — a photo alone is the bubble: full width, time on the picture; with a
  // caption the time stays under the words.
  testWidgets('a photo alone: wide, the time on the picture; with a caption: under the caption', (t) async {
    await pumpChat(t, [
      row('p1', 1, 'photo', media: photoJson(1, album: ''), mine: true),
      row('p2', 2, 'photo', media: photoJson(2, album: ''), body: 'Море'),
    ]);
    expect(find.byKey(const ValueKey('media-time-pill')), findsOneWidget, reason: 'only on the bare photo');
    expect(find.text('Море'), findsOneWidget);
    final photo = t.getSize(find.byType(EncryptedPhoto).first);
    expect(photo.width, kPhotoBubbleWidth, reason: 'wider than the old 244');
  });

  testWidgets('a small drag down springs back instead of closing', (t) async {
    await pumpChat(t, [
      row('p1', 1, 'photo', media: photoJson(1)),
      row('p2', 2, 'photo', media: photoJson(2)),
    ]);
    await t.tap(find.byKey(const ValueKey('album-tile-0')));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);
    await t.drag(find.byKey(const ValueKey('gallery-pages')), const Offset(0, 40));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget, reason: 'still open');
    await t.tap(find.byKey(const ValueKey('gallery-close')));
    await t.pumpAndSettle();
    expect(find.text('1 of 2'), findsNothing);
  });

  testWidgets('link preview card renders under the text and opens the link sheet', (t) async {
    await pumpChat(t, [
      row('t1', 1, 'text', body: 'read https://example.org/post', media: '{"v":1,"type":"link"}'),
    ]);
    expect(find.byKey(const ValueKey('link-preview')), findsOneWidget);
    expect(find.text('A great article'), findsOneWidget);
    expect(find.text('example.org'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('link-preview')));
    // At once: the double-tap heart does not hold a single tap back.
    await t.pump();
    expect(find.byKey(const ValueKey('sheet-action-Open link')), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-action-Open link')), findsOneWidget);
  });

  testWidgets('video bubble shows duration and size', (t) async {
    await pumpChat(t, [row('v1', 1, 'video', media: '{"v":1,"kind":"video"}')]);
    expect(find.byKey(const ValueKey('video-bubble')), findsOneWidget);
    expect(find.textContaining('1:23'), findsOneWidget);
    expect(find.textContaining('3.0 MB'), findsOneWidget);
    expect(find.byType(EncryptedThumbnail), findsNothing, reason: 'older video: no poster');
  });

  testWidgets('a video with a poster frame shows it in the bubble', (t) async {
    await pumpChat(t, [row('v2', 1, 'video', media: '{"v":1,"kind":"video","poster":1}')]);
    expect(find.byKey(const ValueKey('video-bubble')), findsOneWidget);
    expect(find.byType(EncryptedThumbnail), findsOneWidget);
    expect(find.textContaining('1:23'), findsOneWidget, reason: 'duration still over the poster');
  });
}
