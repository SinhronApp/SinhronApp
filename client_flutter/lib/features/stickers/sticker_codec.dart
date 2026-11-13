// Sticker files in RAM — ADR-049: what format a file is, Lottie
// compositions parsed once, and still PNGs (panel previews, the picture
// older apps show for an animated sticker).
//
// Formats: png / webp (still), tgs (gzip-compressed Lottie JSON —
// Telegram's open format; a plain Lottie .json is gzipped on import),
// webm (VP9 video; plays on Android, a still picture elsewhere).

import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibDecoder, gzip;
import 'dart:math' show max;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/painting.dart';
import 'package:lottie/lottie.dart';

/// The format of a sticker file from its first bytes, or null (the Rust
/// core checks the same way — `sticker::format_of`).
String? stickerFormatOfBytes(List<int> b) {
  bool at(int i, List<int> m) {
    if (b.length < i + m.length) return false;
    for (var k = 0; k < m.length; k++) {
      if (b[i + k] != m[k]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return 'png';
  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
  if (at(0, const [0x1f, 0x8b])) return 'tgs';
  if (at(0, const [0x1a, 0x45, 0xdf, 0xa3])) return 'webm';
  return null;
}

bool stickerFormatAnimated(String format) => format == 'tgs' || format == 'webm';

/// A plain Lottie JSON file (`{"v":"5.5.7",…,"layers":[…]}`) — gzipped on
/// import so it becomes a `.tgs`.
bool looksLikeLottieJson(List<int> b) {
  if (b.isEmpty || b.first != 0x7b) return false;
  final head = String.fromCharCodes(b.take(2048));
  return head.contains('"v"') && (head.contains('"layers"') || head.contains('"fr"'));
}

Uint8List gzipLottie(List<int> json) => Uint8List.fromList(gzip.encode(json));

/// Most a .tgs may unpack to. A sticker from someone else could be a
/// "gzip bomb" (1 MB that inflates to gigabytes); real ones are ≤ 1 MB.
const kMaxLottieJsonBytes = 16 * 1024 * 1024;

/// Unpack a .tgs (or, [raw], a zip entry's deflate data), refusing more
/// than [limit] bytes.
Uint8List gunzipLimited(List<int> tgs, {int limit = kMaxLottieJsonBytes, bool raw = false}) {
  final out = BytesBuilder(copy: false);
  final inflate = ZLibDecoder(gzip: !raw, raw: raw).startChunkedConversion(
    _CappedSink((chunk) {
      out.add(chunk);
      if (out.length > limit) throw const FormatException('sticker animation too large');
    }),
  );
  inflate
    ..add(tgs)
    ..close();
  return out.takeBytes();
}

class _CappedSink implements Sink<List<int>> {
  _CappedSink(this._onChunk);
  final void Function(List<int>) _onChunk;
  @override
  void add(List<int> data) => _onChunk(data);
  @override
  void close() {}
}

/// Lottie decoder for stickers: a .tgs unpacked with [gunzipLimited].
Future<LottieComposition?> decodeTgs(List<int> bytes) async {
  if (bytes.length < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b) return null;
  final json = gunzipLimited(bytes);
  if (_maxRepeaterCopies(jsonDecode(utf8.decode(json))) > kMaxRepeaterCopies) return null;
  return LottieComposition.parseJsonBytes(json);
}

/// The renderer loops a repeater's `copies` times on every frame, with no
/// limit of its own: a sticker asking for more than this is refused.
const kMaxRepeaterCopies = 512; // keyframe times sit next to the values

/// The largest number any repeater (`"ty":"rp"`) in [v] names as copies.
num _maxRepeaterCopies(Object? v, {bool inCopies = false}) {
  if (v is num) return inCopies ? v : 0;
  num best = 0;
  if (v is List) {
    for (final e in v) {
      best = max(best, _maxRepeaterCopies(e, inCopies: inCopies));
    }
  } else if (v is Map) {
    for (final e in v.entries) {
      final copies = inCopies || (v['ty'] == 'rp' && e.key == 'c');
      best = max(best, _maxRepeaterCopies(e.value, inCopies: copies));
    }
  }
  return best;
}

/// Parsed Lottie animations by sticker key — parsing is the slow part, so
/// each one happens once; the oldest go when there are many.
class LottieCompositions {
  LottieCompositions({this.capacity = 96});
  final int capacity;
  final _done = <String, LottieComposition>{}; // insertion-ordered
  final _loading = <String, Future<LottieComposition>>{};

  LottieComposition? peek(String key) => _done[key];

  Future<LottieComposition> get(String key, Future<Uint8List> Function() bytes) {
    final hit = _done.remove(key);
    if (hit != null) {
      _done[key] = hit; // most recent last
      return SynchronousFuture(hit);
    }
    return _loading[key] ??= () async {
      try {
        final data = await bytes();
        final c = await LottieComposition.fromBytes(data, decoder: decodeTgs);
        _done[key] = c;
        while (_done.length > capacity) {
          _done.remove(_done.keys.first);
        }
        return c;
      } finally {
        unawaited(_loading.remove(key));
      }
    }();
  }
}

/// One shared cache for the app.
final lottieCompositions = LottieCompositions();

/// A frame of [c] at [progress] as a [px]×[px] PNG (transparent around).
Future<Uint8List> lottieStillPng(LottieComposition c, {int px = 256, double progress = 0}) async {
  final drawable = LottieDrawable(c)..setProgress(progress);
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  drawable.draw(canvas, ui.Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()), fit: BoxFit.contain);
  return _png(rec.endRecording(), px, px);
}

/// Longest side a png / webp sticker may have (Telegram's are 512). A
/// 31 KB PNG can say 16000×16000 — ~1 GB once decoded (security-review-2026-11 app-surface:4).
const kMaxStickerSide = 2048;

/// Is [b] a picture of at most [kMaxStickerSide] a side? Read from its
/// header, nothing decoded. Not a picture → false.
Future<bool> stickerPictureOk(Uint8List b) async {
  try {
    final buf = await ui.ImmutableBuffer.fromUint8List(b);
    final d = await ui.ImageDescriptor.encoded(buf);
    final ok = d.width <= kMaxStickerSide && d.height <= kMaxStickerSide;
    d.dispose();
    buf.dispose();
    return ok;
  } catch (_) {
    return false;
  }
}

/// A still picture (png / webp bytes) scaled to fit [px]×[px], as PNG.
Future<Uint8List> imageStillPng(Uint8List bytes, {int px = 128}) async {
  if (!await stickerPictureOk(bytes)) throw const FormatException('sticker picture too big');
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = (await codec.getNextFrame()).image;
  codec.dispose();
  final w = frame.width.toDouble(), h = frame.height.toDouble();
  final scale = px / (w > h ? w : h);
  final ow = (w * scale).round().clamp(1, px), oh = (h * scale).round().clamp(1, px);
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawImageRect(
    frame,
    ui.Rect.fromLTWH(0, 0, w, h),
    ui.Rect.fromLTWH(0, 0, ow.toDouble(), oh.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  frame.dispose();
  return _png(rec.endRecording(), ow, oh);
}

/// [emoji] drawn big on a transparent [px]×[px] square — the picture of a
/// sticker this phone can't decode (a webm on iPhone).
Future<Uint8List> emojiStillPng(String emoji, {int px = 128}) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  final tp = TextPainter(
    text: TextSpan(text: emoji.isEmpty ? '🙂' : emoji, style: TextStyle(fontSize: px * 0.78)),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, ui.Offset((px - tp.width) / 2, (px - tp.height) / 2));
  tp.dispose();
  return _png(rec.endRecording(), px, px);
}

Future<Uint8List> _png(ui.Picture picture, int w, int h) async {
  final img = await picture.toImage(w, h);
  picture.dispose();
  try {
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    img.dispose();
  }
}

/// Still PNG of any sticker file, fitting [px]: a Lottie frame, the picture
/// itself scaled, or [emoji] for a video.
Future<Uint8List> stickerStillPng(Uint8List data, String format, {required String emoji, int px = 128}) async {
  switch (format) {
    case 'tgs':
      final c = await LottieComposition.fromBytes(data, decoder: decodeTgs);
      return lottieStillPng(c, px: px);
    case 'png' || 'webp':
      return imageStillPng(data, px: px);
    default:
      return emojiStillPng(emoji, px: px);
  }
}

/// The encrypted-thumbnail limit (Rust `media::MAX_THUMBNAIL_BYTES`).
const kMaxStickerThumbBytes = 32 * 1024;

/// Thumbnail sizes tried in turn, largest first.
const kStickerThumbSizes = [160, 120, 96, 72, 48];

/// Owner, 2026-10-19: Telegram stickers that are photos ("memes") came out
/// over 32 KB even at 96 px, Rust refused the thumbnail and the sticker
/// stayed "Not sent". The largest of [kStickerThumbSizes] that fits; none
/// fits (or rendering fails) → empty: the sticker goes without one.
Future<Uint8List> fitStickerThumb(Future<Uint8List> Function(int px) render, {int max = kMaxStickerThumbBytes}) async {
  for (final px in kStickerThumbSizes) {
    try {
      final t = await render(px);
      if (t.isNotEmpty && t.length <= max) return t;
    } catch (_) {
      return Uint8List(0);
    }
  }
  return Uint8List(0);
}

/// Owner, 2026-10-19: a Telegram video sticker went out as a big "👥" — the
/// iPhone can't open webm, so its still was the emoji. The pack keeps
/// Telegram's own still (the PNG [preview]): that picture goes instead.
/// Null → draw the still from the sticker itself.
Uint8List? stickerSendPicture(String format, Uint8List? preview) =>
    format == 'webm' && preview != null && preview.isNotEmpty ? preview : null;
