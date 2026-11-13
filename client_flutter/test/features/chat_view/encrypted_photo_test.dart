import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/chat_view/encrypted_photo.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

// 1×1 transparent PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeLoader implements MediaLoader {
  _FakeLoader({this.failFetch = false});
  final bool failFetch;
  final fetched = <String>[];

  @override
  Future<core.MediaInfo> info(String mediaJson) async => core.MediaInfo(
        kind: 'photo',
        mimeType: 'image/jpeg',
        fileName: '',
        blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
        width: 1280,
        height: 960,
        durationMs: 0,
        waveform: Uint8List(0),
        caption: '',
        sizeBytes: BigInt.from(300000),
        hasThumbnail: true,
        round: false,
      );

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => _png;

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async {
    fetched.add('${thumbnail ? 'thumb' : 'full'}:$mediaJson');
    if (failFetch) throw StateError('server down');
    return _png;
  }
}

Widget _host(MediaLoader loader, Widget child) => ProviderScope(
      overrides: [mediaLoaderProvider.overrideWithValue(loader)],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: child),
      ),
    );

void main() {
  test('bubble height follows aspect ratio within bounds', () {
    expect(photoBubbleHeight(1280, 960), closeTo(210, 1));
    expect(photoBubbleHeight(4000, 500), 140); // panorama clamped
    expect(photoBubbleHeight(500, 4000), 380); // tall screenshot clamped
    expect(photoBubbleHeight(0, 0), 180);
    expect(photoBubbleHeight(1280, 960, width: 230), closeTo(172, 1)); // a small phone
  });

  testWidgets('shows blurhash then thumbnail; tap opens with the media json',
      (tester) async {
    final loader = _FakeLoader();
    String? opened;
    await tester.pumpWidget(_host(
      loader,
      EncryptedPhoto(mediaJson: '{"m":1}', onTap: () => opened = '{"m":1}'),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('photo-thumb')), findsOneWidget);
    // Status 213 — then the photo itself: the bubble isn't blurred.
    expect(loader.fetched.first, 'thumb:{"m":1}', reason: 'the thumbnail first');
    expect(find.byKey(const ValueKey('photo-full')), findsOneWidget);
    final box = tester.getSize(find.byType(EncryptedPhoto));
    expect(box.width, kPhotoBubbleWidth);
    expect(box.height, closeTo(210, 1));

    await tester.tap(find.byType(EncryptedPhoto));
    expect(opened, '{"m":1}');
  });

  testWidgets('download failure shows a message and disables tap',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(
      _FakeLoader(failFetch: true),
      EncryptedPhoto(mediaJson: '{}', onTap: () => taps++),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Photo unavailable'), findsOneWidget);
    await tester.tap(find.byType(EncryptedPhoto));
    expect(taps, 0);
  });
}
