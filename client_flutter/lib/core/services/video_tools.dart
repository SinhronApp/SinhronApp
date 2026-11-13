// Video before sending — tech-debt 2.24.
//
// • Poster frame: a still from the clip (platform decoder via the
//   `video_compress` plugin), re-encoded by Rust into the encrypted
//   thumbnail + BlurHash (`net_send_video`), so the bubble shows a picture
//   before anything is downloaded.
// • Compression: clips over [kCompressVideoAbove] are re-encoded to 720p
//   (H.264) on the device before encryption — smaller uploads, and long
//   recordings fit under the 95 MB limit.
//
// Plaintext on disk: the picker's temp file and the compressed copy live
// only while the clip is read into memory; both are deleted right after,
// along with the plugin's cache.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_compress/video_compress.dart';

/// Clips larger than this are compressed before sending.
const int kCompressVideoAbove = 16 * 1024 * 1024;

/// Largest clip we read into memory to send (= `kMaxMediaBytes`).
const int kMaxVideoBytes = 95 * 1024 * 1024;

/// The clip is over [kMaxVideoBytes] even after compression.
class VideoTooLarge implements Exception {
  const VideoTooLarge();
}

/// MIME type from the file extension (the plugin's output is always .mp4).
String videoMimeOf(String path) => switch (path.toLowerCase().split('.').last) {
  'mov' || 'qt' => 'video/quicktime',
  'm4v' => 'video/x-m4v',
  '3gp' => 'video/3gpp',
  'webm' => 'video/webm',
  'mkv' => 'video/x-matroska',
  _ => 'video/mp4',
};

/// Platform video helpers (faked in tests).
abstract class VideoTools {
  /// A JPEG still from the clip, or null.
  Future<Uint8List?> posterFrame(String path);

  /// Path of a smaller copy, or null to send the original.
  Future<String?> compress(String path);

  /// Drop the plugin's temp files.
  Future<void> cleanup();
}

class PluginVideoTools implements VideoTools {
  @override
  Future<Uint8List?> posterFrame(String path) async {
    try {
      // The iOS plugin never answers when it can't grab a frame — time out.
      return await VideoCompress.getByteThumbnail(path, quality: 80, position: -1)
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null; // no poster — the bubble falls back to a dark frame
    }
  }

  @override
  Future<String?> compress(String path) async {
    try {
      final out = await VideoCompress.compressVideo(
        path,
        quality: VideoQuality.Res1280x720Quality,
        includeAudio: true,
      ).timeout(
        const Duration(minutes: 5),
        onTimeout: () async {
          await VideoCompress.cancelCompression();
          return null;
        },
      );
      return out?.path;
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null; // send the original
    }
  }

  @override
  Future<void> cleanup() async {
    try {
      await VideoCompress.deleteAllCache();
    } catch (_) {}
  }
}

final videoToolsProvider = Provider<VideoTools>((ref) => PluginVideoTools());

/// What actually goes out: the bytes (original or compressed), its MIME
/// type and an optional poster frame.
class PreparedVideo {
  const PreparedVideo({required this.bytes, required this.mimeType, this.poster, this.compressed = false});
  final Uint8List bytes;
  final String mimeType;
  final Uint8List? poster;
  final bool compressed;
}

/// Preparations running now — the plugin's cache is only wiped when the
/// last one ends (it holds the others' half-written output).
int _activePreparations = 0;

/// Compress if large, grab a poster, read into memory, then delete every
/// plaintext file involved ([path] included). Throws [VideoTooLarge] when
/// even the smaller file is over [kMaxVideoBytes] — checked before reading.
Future<PreparedVideo> prepareVideoForSending(VideoTools tools, String path) async {
  final original = File(path);
  String? smaller;
  _activePreparations++;
  try {
    final originalSize = await original.length();
    if (originalSize > kCompressVideoAbove) {
      smaller = await tools.compress(path);
      // A compressed copy that isn't smaller (low-bitrate source) is no use.
      if (smaller != null && await File(smaller).length() >= originalSize) {
        try {
          await File(smaller).delete();
        } catch (_) {}
        smaller = null;
      }
    }
    final use = smaller ?? path;
    if (await File(use).length() > kMaxVideoBytes) throw const VideoTooLarge();
    final poster = await tools.posterFrame(use);
    final bytes = await File(use).readAsBytes();
    return PreparedVideo(bytes: bytes, mimeType: videoMimeOf(use), poster: poster, compressed: smaller != null);
  } finally {
    for (final p in [path, ?smaller]) {
      try {
        await File(p).delete();
      } catch (_) {}
    }
    if (--_activePreparations == 0) await tools.cleanup();
  }
}
