// Audit jank-03: a photo / video / link card takes its final height from
// the first frame — the feed doesn't jump when the media arrives.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/services/media_loader.dart';
import 'package:sinhron/features/chat_view/encrypted_photo.dart';
import 'package:sinhron/features/chat_view/encrypted_video.dart';
import 'package:sinhron/features/chat_view/link_preview_card.dart';
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

/// `info()` answers only when the test says so.
class _SlowLoader implements MediaLoader {
  _SlowLoader(this.kind, this.width, this.height);
  final String kind;
  final int width, height;
  final gate = Completer<void>();

  @override
  Future<core.MediaInfo> info(String mediaJson) async {
    await gate.future;
    return core.MediaInfo(
      kind: kind,
      mimeType: '',
      fileName: '',
      blurhash: '',
      width: width,
      height: height,
      durationMs: 0,
      waveform: Uint8List(0),
      caption: '',
      sizeBytes: BigInt.from(300000),
      hasThumbnail: false,
      round: false,
    );
  }

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) async => _png;

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) async => _png;
}

class _SlowLinkLoader implements LinkPreviewLoader {
  final gate = Completer<Uint8List>();

  @override
  Future<core.LinkPreviewInfo> info(String json) async => const core.LinkPreviewInfo(
    url: 'https://example.org/a',
    domain: 'example.org',
    title: 'Title',
    description: 'Description',
    hasImage: true,
  );

  @override
  Future<Uint8List> image(String json) => gate.future;
}

Widget _host(List<Override> overrides, Widget child, {bool dark = false}) => ProviderScope(
  overrides: overrides,
  child: DsTheme(
    tokens: dark ? DsTokens.dark : DsTokens.light,
    isDark: dark,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: child),
    ),
  ),
);

void main() {
  testWidgets('photo: the height is final before info() answers', (tester) async {
    // 1000×1200 → 280 × 1.2 = 336 (was 180 → 336).
    final loader = _SlowLoader('photo', 1000, 1200);
    await tester.pumpWidget(
      _host([mediaLoaderProvider.overrideWithValue(loader)], const EncryptedPhoto(mediaJson: '{"width":1000,"height":1200}')),
    );
    final before = tester.getSize(find.byType(EncryptedPhoto));
    expect(before, const Size(kPhotoBubbleWidth, 336));
    loader.gate.complete();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(EncryptedPhoto)), before);
  });

  testWidgets('photo: no size in the JSON — the old 180 placeholder', (tester) async {
    final loader = _SlowLoader('photo', 1000, 1200);
    await tester.pumpWidget(_host([mediaLoaderProvider.overrideWithValue(loader)], const EncryptedPhoto(mediaJson: '{}')));
    expect(tester.getSize(find.byType(EncryptedPhoto)).height, 180);
    loader.gate.complete();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(EncryptedPhoto)).height, 336);
  });

  testWidgets('video: the height is final before info() answers (dark, iPad)', (tester) async {
    tester.view.physicalSize = const Size(1024, 1366);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Portrait 720×1280 → clamped to 380 (was 157.5 → 380).
    final loader = _SlowLoader('video', 720, 1280);
    await tester.pumpWidget(
      _host(
        [mediaLoaderProvider.overrideWithValue(loader)],
        const EncryptedVideo(mediaJson: '{"width":720,"height":1280}'),
        dark: true,
      ),
    );
    final before = tester.getSize(find.byType(EncryptedVideo));
    expect(before, const Size(kPhotoBubbleWidth, 380));
    loader.gate.complete();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(EncryptedVideo)), before);
  });

  testWidgets('link card: the picture has its place before it loads', (tester) async {
    final loader = _SlowLinkLoader();
    await tester.pumpWidget(
      _host([linkPreviewLoaderProvider.overrideWithValue(loader)], const LinkPreviewCard(json: '{}', isOut: false)),
    );
    await tester.pumpAndSettle(); // info() answered, the image hasn't.
    expect(find.byKey(const ValueKey('link-preview-image')), findsNothing);
    final before = tester.getSize(find.byType(LinkPreviewCard));
    expect(before.width, lessThanOrEqualTo(280));
    loader.gate.complete(_png);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('link-preview-image')), findsOneWidget);
    expect(tester.getSize(find.byType(LinkPreviewCard)), before);
  });

  testWidgets('link card: the place closes when the picture fails', (tester) async {
    final loader = _SlowLinkLoader();
    await tester.pumpWidget(
      _host([linkPreviewLoaderProvider.overrideWithValue(loader)], const LinkPreviewCard(json: '{}', isOut: true)),
    );
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(LinkPreviewCard)).height;
    loader.gate.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(LinkPreviewCard)).height, before - 148);
  });
}
