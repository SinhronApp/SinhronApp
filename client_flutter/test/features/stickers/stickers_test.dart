// ADR-049 — stickers and a richer emoji panel (owner, 2026-10-18: "stickers
// and emoji, really good ones, and adding packs"). Formats, imports from
// files, the built-in packs, emoji search and skin tones.

import 'dart:convert';
import 'dart:io' show gzip, zlib;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:sinhron/features/chat_view/emoji_data.dart';
import 'package:sinhron/features/chat_view/emoji_names.dart';
import 'package:sinhron/features/chat_view/emoji_panel.dart';
import 'package:sinhron/features/stickers/sticker_codec.dart';
import 'package:sinhron/features/stickers/sticker_import.dart';
import 'package:sinhron/features/stickers/sticker_panel.dart';
import 'package:sinhron/features/stickers/sticker_store.dart';
import 'package:sinhron/features/stickers/sticker_view.dart';

final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2]);
final webp = Uint8List.fromList([...'RIFF'.codeUnits, 9, 0, 0, 0, ...'WEBPVP8 '.codeUnits]);
final webm = Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3, 1]);
final lottieJson = utf8.encode('{"v":"5.5.7","fr":30,"ip":0,"op":30,"w":64,"h":64,"layers":[]}');

/// A 1-bit palette PNG of [w]×[h] (one black row of data — only the
/// header counts).
Uint8List pngHeader(int w, int h) {
  List<int> chunk(String type, List<int> data) {
    final td = [...type.codeUnits, ...data];
    final n = ByteData(4)..setUint32(0, data.length);
    final c = ByteData(4)..setUint32(0, getCrc32(td));
    return [...n.buffer.asUint8List(), ...td, ...c.buffer.asUint8List()];
  }

  final ihdr = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 1)
    ..setUint8(9, 3);
  return Uint8List.fromList([
    ...png.sublist(0, 8),
    ...chunk('IHDR', ihdr.buffer.asUint8List()),
    ...chunk('PLTE', [0, 0, 0]),
    ...chunk('IDAT', zlib.encode(Uint8List(1 + (w + 7) ~/ 8))),
    ...chunk('IEND', []),
  ]);
}

void main() {
  // Owner, 2026-10-19: photo-like Telegram stickers stayed "Not sent" — the
  // thumbnail was over 32 KB even at 96 px and Rust refused the send.
  test('a video sticker is sent with the pack\'s still, not an emoji drawn big', () {
    final still = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 1]);
    expect(stickerSendPicture('webm', still), same(still));
    expect(stickerSendPicture('webm', Uint8List(0)), isNull, reason: 'no still kept → the emoji, as before');
    expect(stickerSendPicture('webm', null), isNull);
    expect(stickerSendPicture('tgs', still), isNull, reason: 'Lottie draws its own frame');
    expect(stickerSendPicture('webp', still), isNull, reason: 'a picture is its own still');
  });

  group('sticker thumbnail always fits 32 KB', () {
    Future<Uint8List> Function(int) sized(Map<int, int> bytesAt, List<int> asked) => (px) async {
      asked.add(px);
      return Uint8List(bytesAt[px] ?? 0);
    };

    test('the largest size that fits', () async {
      final asked = <int>[];
      final t = await fitStickerThumb(sized({160: 50000, 120: 40000, 96: 33000, 72: 20000, 48: 9000}, asked));
      expect(t.length, 20000);
      expect(asked, [160, 120, 96, 72]);
    });

    test('a small sticker keeps its 160 px thumbnail', () async {
      final asked = <int>[];
      expect((await fitStickerThumb(sized({160: 12000}, asked))).length, 12000);
      expect(asked, [160]);
    });

    test('nothing fits → no thumbnail, the sticker still goes', () async {
      final t = await fitStickerThumb(sized({for (final px in kStickerThumbSizes) px: 40000}, []));
      expect(t, isEmpty);
    });

    test('a renderer that throws → no thumbnail, not a failed send', () async {
      expect(await fitStickerThumb((_) async => throw const FormatException('bad')), isEmpty);
    });
  });

  TestWidgetsFlutterBinding.ensureInitialized();

  test('formats are told by their bytes; a plain Lottie JSON becomes a .tgs', () {
    expect(stickerFormatOfBytes(png), 'png');
    expect(stickerFormatOfBytes(webp), 'webp');
    expect(stickerFormatOfBytes(webm), 'webm');
    expect(stickerFormatOfBytes(gzip.encode(lottieJson)), 'tgs');
    expect(stickerFormatOfBytes(lottieJson), isNull);
    expect(looksLikeLottieJson(lottieJson), isTrue);
    expect(looksLikeLottieJson(utf8.encode('{"name":"not lottie"}')), isFalse);
    expect(stickerFormatOfBytes(gzipLottie(lottieJson)), 'tgs');
    expect(stickerFormatAnimated('tgs') && stickerFormatAnimated('webm'), isTrue);
    expect(stickerFormatAnimated('webp'), isFalse);
  });

  test('a .tgs that would unpack to too much is refused (gzip bomb)', () async {
    final bomb = gzip.encode(Uint8List(2 * 1024 * 1024));
    expect(bomb.length, lessThan(64 * 1024));
    expect(() => gunzipLimited(bomb, limit: 1024 * 1024), throwsFormatException);
    expect(gunzipLimited(gzip.encode(lottieJson)), lottieJson);
    expect(await decodeTgs(png), isNull, reason: 'not gzip: not a .tgs');
  });

  test('importing files: zips opened, junk skipped, emoji from file names, a preview each', () async {
    final zip = ZipEncoder().encodeBytes(
      Archive()
        ..add(ArchiveFile.bytes('cats/happy_😺.webp', webp))
        ..add(ArchiveFile.bytes('cats/anim_🎉.json', lottieJson))
        ..add(ArchiveFile.bytes('__MACOSX/._happy.webp', webp))
        ..add(ArchiveFile.bytes('cats/readme.txt', utf8.encode('hi'))),
    );
    final files = [
      ImportedFile('Котики_и_друзья.zip', Uint8List.fromList(zip)),
      ImportedFile('wave👋🏽.png', png),
      ImportedFile('clip.webm', webm),
      ImportedFile('notes.pdf', Uint8List.fromList(utf8.encode('%PDF'))),
    ];
    final previews = <String>[];
    final r = await stickersFromFiles(
      files,
      preview: (d, f, e) async {
        previews.add(f);
        return png;
      },
    );
    expect([for (final s in r.stickers) s.format], ['webp', 'tgs', 'png', 'webm']);
    expect([for (final s in r.stickers) s.emoji], ['😺', '🎉', '👋🏽', '']);
    expect(r.stickers.map((s) => s.id).toSet(), hasLength(4), reason: 'unique ids');
    expect(r.skipped, 2, reason: 'readme.txt and the pdf');
    expect(previews, hasLength(4));
    expect(packTitleFor(files, 'Мои стикеры'), 'Котики и друзья');
    expect(packTitleFor([ImportedFile('a.png', png)], 'Мои стикеры'), 'Мои стикеры');
    // Too big is skipped, not cut.
    final big = Uint8List(kMaxStickerBytes + 1)..setAll(0, png);
    expect((await stickersFromFiles([ImportedFile('big.png', big)], preview: (_, _, _) async => png)).skipped, 1);
  });

  // security-review-2026-11 critic:8.
  test('a zip that lies about its size is never inflated past one sticker', () {
    final zip = Uint8List.fromList(ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.bytes('cat.webp', Uint8List(16 << 20)))));
    final b = ByteData.sublistView(zip);
    b.setUint32(22, 10, Endian.little); // local header: "10 bytes"
    for (var i = zip.length - 22; i >= 0; i--) {
      if (b.getUint32(i, Endian.little) == 0x02014b50) b.setUint32(i + 24, 10, Endian.little); // central directory
    }
    final out = expandArchives([ImportedFile('bomb.zip', zip)]);
    expect(out.where((f) => f.bytes.length > kMaxStickerBytes), isEmpty);
  });

  // security-review-2026-11 app-surface:4 — 31 KB that decodes to ~1 GB.
  testWidgets('a png sticker that says 16000x16000 is never decoded: its emoji instead', (t) async {
    final bomb = pngHeader(16000, 16000);
    expect(await t.runAsync(() => stickerPictureOk(bomb)), isFalse);
    expect(await t.runAsync(() => stickerPictureOk(pngHeader(512, 512))), isTrue);
    await t.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StickerView(cacheKey: 'bomb', format: 'png', load: () async => bomb, emoji: 'B'),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(seconds: 3));
    }
    expect(find.byType(Image), findsNothing);
    expect(find.text('B'), findsOneWidget);
  });

  test('recents, filtering by emoji, the animated emoji for a lone emoji', () {
    expect(withRecentSticker('', 'p/a'), 'p/a');
    expect(withRecentSticker('p/a p/b', 'p/b'), 'p/b p/a');
    var r = '';
    for (var i = 0; i < 30; i++) {
      r = withRecentSticker(r, 'p/$i');
    }
    expect(r.split(' '), hasLength(kRecentStickersMax));
    const pack = StickerPackView(
      id: 'sinhron.noto_faces',
      titles: {'en': 'Feelings'},
      builtin: true,
      stickers: [
        Sticker(packId: 'sinhron.noto_faces', id: 'a', emoji: '😂', format: 'tgs', asset: 'x'),
        Sticker(packId: 'sinhron.noto_faces', id: 'b', emoji: '❤️', format: 'tgs', asset: 'y'),
      ],
    );
    expect(stickersForEmoji([pack], '😂').single.id, 'a');
    expect(stickersForEmoji([pack], '❤').single.id, 'b', reason: 'with or without the variation selector');
    expect(animatedEmojiFor([pack], ' ❤ ')!.id, 'b');
    expect(animatedEmojiFor([pack], '🐱'), isNull);
    expect(pack.title('ru'), 'Feelings', reason: 'falls back to English');
  });

  test('emoji search knows English and Russian names', () {
    expect(searchEmoji('cat'), contains('🐱'));
    expect(searchEmoji('кот'), contains('🐱'));
    expect(searchEmoji('сердце'), contains('❤️'));
    expect(searchEmoji('thumbs up'), contains('👍'));
    expect(searchEmoji('   '), isEmpty);
    expect(searchEmoji('zzzzqqq'), isEmpty);
    // Every emoji in the panel has a name.
    for (final c in EmojiCategory.values) {
      for (final e in emojiOf(c)) {
        expect(kEmojiNames[e], isNotEmpty, reason: e);
      }
    }
  });

  test('skin tones: applied by Unicode rules, remembered per emoji', () {
    expect(kSkinToneEmoji, containsAll(['👍', '👋', '✌️']));
    expect(kSkinToneEmoji, isNot(contains('😀')));
    expect(withSkinTone('👍', kSkinTones[2]), '👍🏽');
    expect(withSkinTone('✌️', kSkinTones[4]), '✌🏿', reason: 'the variation selector goes');
    var s = withEmojiTone('', '👍', '👍🏽');
    s = withEmojiTone(s, '👋', '👋🏻');
    expect(parseEmojiTones(s), {'👍': '👍🏽', '👋': '👋🏻'});
    s = withEmojiTone(s, '👍', '👍');
    expect(parseEmojiTones(s), {'👋': '👋🏻'}, reason: 'back to the default tone');
  });

  test('built-in packs: every file is there, in its format, with a licence', () async {
    final packs = await loadBuiltinPacks();
    expect(packs.map((p) => p.id), ['sinhron.noto_faces', 'sinhron.noto_gestures', 'sinhron.fluent_3d']);
    var n = 0;
    for (final p in packs) {
      expect(p.builtin, isTrue);
      expect(p.license, isNotEmpty, reason: p.id);
      expect(p.author, isNotEmpty, reason: p.id);
      expect(p.title('ru'), isNot(p.title('en')));
      for (final s in p.stickers) {
        final bytes = await s.bytes();
        expect(stickerFormatOfBytes(bytes), s.format, reason: s.asset);
        expect(bytes.length, lessThan(kMaxStickerBytes), reason: s.asset);
        expect(s.emoji, isNotEmpty, reason: s.asset);
        n++;
      }
    }
    expect(n, 108);
    expect(await rootBundle.loadString('assets/stickers/NOTICE.md'), contains('CC BY 4.0'));
  });

  test('a built-in Lottie sticker parses and moves', () async {
    final packs = await loadBuiltinPacks();
    final s = packs.first.stickers.first;
    final c = await LottieComposition.fromBytes(await s.bytes(), decoder: LottieComposition.decodeGZip);
    expect(c.duration, greaterThan(Duration.zero));
    // Parsed once, then from the cache.
    final cache = LottieCompositions(capacity: 2);
    var loads = 0;
    Future<Uint8List> load() async {
      loads++;
      return s.bytes();
    }

    await cache.get('a', load);
    await cache.get('a', load);
    await cache.get('b', load);
    await cache.get('c', load);
    expect(loads, 3);
    expect(cache.peek('a'), isNull, reason: 'the oldest went');
    expect(cache.peek('c'), isNotNull);
  });
}
