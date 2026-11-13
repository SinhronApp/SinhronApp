// Owner, 2026-11-03 (comparing with Telegram): Media / Files / Voice /
// Links; round video messages live with the voice messages.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/shared_media/shared_media_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

class _Loader implements MediaLoader {
  @override
  Future<core.MediaInfo> info(String mediaJson) async => core.MediaInfo(
    kind: 'video',
    mimeType: 'video/mp4',
    fileName: '',
    blurhash: '',
    width: 0,
    height: 0,
    durationMs: 14000,
    waveform: Uint8List(0),
    caption: '',
    sizeBytes: BigInt.from(1024),
    hasThumbnail: false,
    round: mediaJson.contains('round'),
  );

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => Uint8List(0);

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async => throw StateError('not in tests');
}

core.StoredMessageSummary _row(String id, String kind, int ts, String media, {bool mine = false}) =>
    core.StoredMessageSummary(
      id: id,
      chatId: 'c',
      tsUnix: 1762000000 + ts,
      body: '',
      kind: kind,
      isMine: mine,
      mediaJson: media,
      status: 1,
      deleted: false,
    );

void main() {
  testWidgets('tabs: Media · Files · Voice · Links with counts; a round video is in Voice', (t) async {
    final rows = [
      _row('p1', 'photo', 1, '{"kind":"photo"}'),
      _row('v1', 'video', 2, '{"kind":"video"}'),
      _row('n1', 'video', 3, '{"kind":"video","round":true}', mine: true),
      _row('a1', 'voice', 4, '{"kind":"voice"}'),
      _row('d1', 'document', 5, '{"kind":"document"}'),
    ];
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          mediaLoaderProvider.overrideWithValue(_Loader()),
          messagesProvider('c').overrideWith((ref) async => rows),
        ],
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: const MediaQuery(
            data: MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: SharedMediaScreen(chatId: 'c', contactName: 'Maria'),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    String chip(String name) => [
      for (final w in t.widgetList<Text>(
        find.descendant(of: find.byKey(ValueKey('shared-tab-$name')), matching: find.byType(Text)),
      ))
        w.data,
    ].join(' ');
    expect(chip('media'), 'Media 2', reason: 'the photo and the plain video');
    expect(chip('files'), 'Files 1');
    expect(chip('voice'), 'Voice 2', reason: 'the voice message and the round video');
    expect(chip('links'), 'Links 0');
    expect(find.text('All'), findsNothing, reason: 'no jumbled "All" tab');

    // Media opens first: the photo and the video, no round video.
    expect(find.byKey(const ValueKey('shared-tile-p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-tile-v1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-tile-n1')), findsNothing);
    expect(find.text('0:14'), findsOneWidget, reason: "the video's length on its tile");

    await t.tap(find.byKey(const ValueKey('shared-tab-voice')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-note-n1')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-voice-a1')), findsOneWidget);
    expect(find.text('You'), findsOneWidget, reason: 'my round video: "You"');
    expect(find.text('Maria'), findsNWidgets(2), reason: 'the header and her voice message');
    expect(find.text('Video message · 0:14'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('shared-tab-links')));
    await t.pumpAndSettle();
    expect(find.text('No links yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-empty')), findsOneWidget);
  });
}
