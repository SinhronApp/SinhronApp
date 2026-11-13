// Making a sticker pack from files the person has — ADR-049.
//
// Accepts .tgs (Telegram's gzipped Lottie), a plain Lottie .json (gzipped
// here into a .tgs), .webp, .png, .webm, and .zip archives of those. Each
// sticker gets a small PNG preview for the panel; its emoji comes from an
// emoji in the file name ("cat_😺.webp"), if any. Nothing is fetched from
// anywhere: importing a file someone already has is theirs to do — the app
// never scrapes or bulk-downloads other services' packs.

import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../src/rust/api/stickers.dart' as core;
import 'sticker_codec.dart';

/// Bounds the Rust core enforces too (`sticker.rs`).
const kMaxPackStickers = 200;
const kMaxStickerBytes = 1024 * 1024;
const kMaxPreviewBytes = 64 * 1024;

class ImportedFile {
  const ImportedFile(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

class ImportResult {
  const ImportResult(this.stickers, this.skipped);
  final List<core.StickerData> stickers;

  /// Files that weren't stickers (wrong type, too big, past the limit).
  final int skipped;
}

final _emojiInName = RegExp(r'(\p{Extended_Pictographic}|\p{Regional_Indicator})[\u{FE0F}\u{200D}\p{Extended_Pictographic}\u{1F3FB}-\u{1F3FF}]*', unicode: true);

/// The first emoji in a file name, or ''.
String emojiInFileName(String name) => _emojiInName.firstMatch(name)?.group(0) ?? '';

/// Every file in [files], zips opened (one level), junk skipped.
List<ImportedFile> expandArchives(List<ImportedFile> files) {
  final out = <ImportedFile>[];
  for (final f in files) {
    final isZip = f.bytes.length > 4 && f.bytes[0] == 0x50 && f.bytes[1] == 0x4b;
    if (!isZip) {
      out.add(f);
      continue;
    }
    try {
      // The directory read by hand: ZipDecoder inflates an entry marked as
      // a symlink in full, with no cap (security-audit-2026-11b M05).
      final dir = ZipDirectory()..read(InputMemoryStream(f.bytes));
      for (final h in dir.fileHeaders) {
        final e = h.file!;
        final name = e.filename.split('/').last;
        if (name.isEmpty || name.startsWith('.') || e.filename.contains('__MACOSX/')) continue;
        // The size in the zip header is the sender's word: a few KB can
        // inflate to gigabytes. Inflated here with a cap; other methods
        // (bzip2…) skipped (security-review-2026-11 critic:8).
        final data = e.getStream(decompress: false).toUint8List();
        if (data.length > kMaxStickerBytes * 4) continue;
        try {
          out.add(switch (e.compressionMethod) {
            CompressionType.none => ImportedFile(name, data),
            CompressionType.deflate => ImportedFile(name, gunzipLimited(data, limit: kMaxStickerBytes, raw: true)),
            _ => throw const FormatException('zip method'),
          });
        } catch (_) {}
      }
    } catch (_) {
      // Not a readable zip — counted as skipped below.
      out.add(f);
    }
  }
  return out;
}

/// Stickers from [files], each with a preview. [preview] makes the PNG
/// (swapped in tests).
Future<ImportResult> stickersFromFiles(
  List<ImportedFile> files, {
  Future<Uint8List> Function(Uint8List data, String format, String emoji)? preview,
}) async {
  final make = preview ?? (d, f, e) => stickerStillPng(d, f, emoji: e, px: 128);
  final out = <core.StickerData>[];
  var skipped = 0;
  for (final f in expandArchives(files)) {
    var data = f.bytes;
    if (looksLikeLottieJson(data)) data = gzipLottie(data);
    final format = stickerFormatOfBytes(data);
    if (format == null || data.length > kMaxStickerBytes || out.length >= kMaxPackStickers) {
      skipped++;
      continue;
    }
    final emoji = emojiInFileName(f.name);
    var still = Uint8List(0);
    try {
      still = await make(data, format, emoji);
      if (still.length > kMaxPreviewBytes) still = Uint8List(0);
    } catch (_) {
      // A file the renderer can't open isn't a sticker.
      if (format == 'tgs') {
        skipped++;
        continue;
      }
    }
    out.add(core.StickerData(id: 's${out.length + 1}', emoji: emoji, format: format, data: data, preview: still));
  }
  return ImportResult(out, skipped);
}

/// A pack title from the picked files: the zip's name, else [fallback].
String packTitleFor(List<ImportedFile> files, String fallback) {
  for (final f in files) {
    if (f.name.toLowerCase().endsWith('.zip')) {
      final t = f.name.substring(0, f.name.length - 4).replaceAll(RegExp(r'[_\-]+'), ' ').trim();
      if (t.isNotEmpty) return t.length > 64 ? t.substring(0, 64) : t;
    }
  }
  return fallback;
}
