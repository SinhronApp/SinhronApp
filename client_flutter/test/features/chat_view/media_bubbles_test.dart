import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/chat_view/encrypted_media_bubbles.dart';
import 'package:sinhron/features/shared_media/real_shared_media.dart';
import 'package:sinhron/features/video_note/video_note_circle.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

core.MediaInfo _info(String kind) => core.MediaInfo(
      kind: kind,
      mimeType: kind == 'document' ? 'application/pdf' : 'audio/mp4',
      fileName: kind == 'document' ? 'contract.pdf' : '',
      blurhash: '',
      width: 0,
      height: 0,
      durationMs: kind == 'voice' ? 83400 : 0,
      waveform: Uint8List.fromList(List.generate(64, (i) => i * 4)),
      caption: '',
      sizeBytes: BigInt.from((2.4 * 1024 * 1024).round()),
      hasThumbnail: false,
      round: false,
    );

class _Loader implements MediaLoader {
  _Loader({this.fail = false});
  final bool fail;
  final fetched = <String>[];

  @override
  Future<core.MediaInfo> info(String mediaJson) async =>
      _info(mediaJson.contains('voice') ? 'voice' : mediaJson.contains('doc') ? 'document' : 'photo');

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => Uint8List(0);

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async {
    fetched.add(mediaJson);
    if (fail) throw StateError('down');
    return Uint8List.fromList([1, 2, 3]);
  }
}

Widget _host(MediaLoader loader, Widget child, {List overrides = const []}) => ProviderScope(
      overrides: [mediaLoaderProvider.overrideWithValue(loader), ...overrides],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      ),
    );

core.StoredMessageSummary _row(String id, String kind, int ts, {String? media}) =>
    core.StoredMessageSummary(
      id: id,
      chatId: 'c',
      tsUnix: ts,
      body: '',
      kind: kind,
      isMine: false,
      senderLabel: null,
      mediaJson: media,
      status: 0,
      deleted: false,
    );

void main() {
  testWidgets('document bubble shows name, size, type; tap shares decrypted bytes', (t) async {
    final loader = _Loader();
    final shared = <String>[];
    await t.pumpWidget(_host(
      loader,
      Center(
        child: EncryptedDocument(
          mediaJson: '{doc}',
          color: const Color(0xFF000000),
          share: (bytes, {required fileName, required mimeType, origin}) async {
            shared.add('$fileName|$mimeType|${bytes.length}|${origin != null && !origin.isEmpty}');
          },
        ),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('contract.pdf'), findsOneWidget);
    expect(find.text('2.4 MB · PDF'), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('document-open')));
    await t.pumpAndSettle();
    // On iPad the share sheet is a popover that needs an anchor — without
    // one it never opened (owner, 2026-10-18).
    expect(shared, ['contract.pdf|application/pdf|3|true']);
  });

  testWidgets('document open failure offers retry', (t) async {
    await t.pumpWidget(_host(
      _Loader(fail: true),
      Center(
        child: EncryptedDocument(
          mediaJson: '{doc}',
          color: const Color(0xFF000000),
          share: (bytes, {required fileName, required mimeType, origin}) async {},
        ),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('document-open')));
    await t.pumpAndSettle();
    expect(find.text('Could not open — tap to retry'), findsOneWidget);
  });

  testWidgets('voice bubble shows total duration before playing', (t) async {
    await t.pumpWidget(_host(
      _Loader(),
      const Center(child: EncryptedVoice(mediaJson: '{voice}', color: Color(0xFF000000))),
    ));
    await t.pumpAndSettle();
    expect(find.text('1:23'), findsOneWidget);
    expect(find.byKey(const ValueKey('voice-play')), findsOneWidget);
  });

  test('mediaRowsOf keeps only real media of the kind, newest first', () {
    final rows = [
      _row('1', 'photo', 10, media: '{p1}'),
      _row('2', 'text', 20),
      _row('3', 'photo', 30, media: '{p3}'),
      _row('4', 'photo', 40), // legacy mock row without media JSON
      _row('5', 'document', 50, media: '{doc}'),
    ];
    expect(mediaRowsOf(rows, {'photo'}).map((r) => r.id), ['3', '1']);
    expect(mediaRowsOf(rows, {'document'}).map((r) => r.id), ['5']);
  });

  testWidgets('shared media: media grid, file rows, calm empty states', (t) async {
    final rows = [
      _row('1', 'photo', 10, media: '{p1}'),
      _row('2', 'photo', 20, media: '{p2}'),
      _row('3', 'document', 30, media: '{doc}'),
    ];
    Future<void> pump(SharedSection s) => t.pumpWidget(_host(
          _Loader(),
          RealSharedMedia(chatId: 'c', section: s),
          overrides: [messagesProvider('c').overrideWith((ref) async => rows)],
        ));

    await pump(SharedSection.media);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-photo-grid')), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-month-January 1970')), findsOneWidget, reason: 'a month heading');

    await pump(SharedSection.files);
    await t.pumpAndSettle();
    expect(find.text('contract.pdf'), findsOneWidget);
    expect(find.byKey(const ValueKey('document-type-icon')), findsOneWidget, reason: 'a tile by type');
    expect(find.textContaining('2.4 MB · '), findsOneWidget, reason: 'size · date');

    await pump(SharedSection.voice);
    await t.pumpAndSettle();
    expect(find.text('No voice messages yet'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('shared-empty')), matching: find.byType(Icon)), findsOneWidget);
  });

  testWidgets('shared media: a round video is in Voice as a circle, not in Media (ADR-048)', (t) async {
    final rows = [
      _row('1', 'video', 10, media: '{"kind":"video","round":true}'),
      _row('2', 'video', 20, media: '{"kind":"video"}'),
      _row('3', 'voice', 30, media: '{voice}'),
    ];
    Future<void> pump(SharedSection s) => t.pumpWidget(_host(
          _Loader(),
          RealSharedMedia(chatId: 'c', section: s, contactName: 'Maria'),
          overrides: [messagesProvider('c').overrideWith((ref) async => rows)],
        ));

    await pump(SharedSection.media);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('shared-tile-2')), findsOneWidget, reason: 'the plain video');
    expect(find.byKey(const ValueKey('shared-video-2')), findsOneWidget, reason: 'its length badge');
    expect(
      find.descendant(of: find.byKey(const ValueKey('shared-video-2')), matching: find.byType(Icon)),
      findsOneWidget,
      reason: 'a play icon, not a ▶ character',
    );
    expect(find.byKey(const ValueKey('shared-tile-1')), findsNothing, reason: 'no round video among photos');
    expect(find.byType(VideoNoteCircle), findsNothing);

    await pump(SharedSection.voice);
    await t.pumpAndSettle();
    final round = find.byKey(const ValueKey('shared-round-1'));
    expect(round, findsOneWidget);
    expect(find.descendant(of: round, matching: find.byType(ClipOval)), findsOneWidget);
    expect(find.byKey(const ValueKey('shared-voice-3')), findsOneWidget);
    expect(find.text('Maria'), findsNWidgets(2), reason: 'who sent each');
    expect(find.textContaining('Video message'), findsOneWidget);
    // Newest first: the voice message (ts 30) above the round video (ts 10).
    expect(
      t.getTopLeft(find.byKey(const ValueKey('shared-voice-3'))).dy,
      lessThan(t.getTopLeft(find.byKey(const ValueKey('shared-note-1'))).dy),
    );
  });
}
