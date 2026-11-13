// Round video messages — ADR-048. From the camera's file to the bytes
// that go out.
//
// The platform crops the centre square, scales it to [kVideoNoteSide] px
// and paints everything outside the inscribed circle black, with its
// hardware H.264 encoder (iOS AVAssetExportSession, Android Media3
// Transformer, channel `dev.sinhron/media` → `squareVideo`). So the file
// holds exactly what the recorder saw in the circle — nothing at the edges.
//
// Privacy (owner, 2026-10-19): when that crop fails it is tried once more,
// then the clip is NOT sent ([VideoNoteCropFailed]) — the uncropped camera
// frame never leaves the phone. (Until 0.6.0 the original went out and the
// receiver only drew it as a circle; the gallery showed it whole.)

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/video_tools.dart';
import 'video_note_recorder.dart';

abstract class VideoNoteTools {
  /// Path of a [side]×[side] copy of [path] with black outside the
  /// inscribed circle, or null.
  Future<String?> square(String path, int side);
}

class PlatformVideoNoteTools implements VideoNoteTools {
  static const _channel = MethodChannel('dev.sinhron/media');

  @override
  Future<String?> square(String path, int side) async {
    try {
      return await _channel
          .invokeMethod<String>('squareVideo', {'path': path, 'side': side})
          .timeout(const Duration(minutes: 1), onTimeout: () => null);
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }
}

final videoNoteToolsProvider = Provider<VideoNoteTools>((ref) => PlatformVideoNoteTools());

/// A round clip ready to send.
class PreparedVideoNote {
  const PreparedVideoNote({required this.video, required this.width, required this.height});
  final PreparedVideo video;

  /// Always [kVideoNoteSide] — the square the circle sits in.
  final int width;
  final int height;
}

/// The platform couldn't cut the clip down to the circle — nothing is
/// sent (the chat says so; the camera file is already deleted).
class VideoNoteCropFailed implements Exception {
  const VideoNoteCropFailed();
}

/// Tries at the circle crop before giving up.
const int kVideoNoteCropAttempts = 2;

/// Circle crop, poster frame, read into memory — and every plaintext file
/// deleted, the camera's original included. Throws [VideoNoteCropFailed]
/// when the platform can't crop it: the uncropped original is never sent.
Future<PreparedVideoNote> prepareVideoNote(VideoNoteTools crop, VideoTools tools, String path) async {
  String? square;
  try {
    for (var i = 0; i < kVideoNoteCropAttempts && square == null; i++) {
      try {
        final s = await crop.square(path, kVideoNoteSide);
        if (s != null && s != path && await File(s).exists()) square = s;
      } catch (_) {}
    }
    if (square == null) throw const VideoNoteCropFailed();
    try {
      await File(path).delete();
    } catch (_) {}
    // Deletes the file it reads.
    final video = await prepareVideoForSending(tools, square);
    return PreparedVideoNote(video: video, width: kVideoNoteSide, height: kVideoNoteSide);
  } finally {
    for (final p in [path, ?square]) {
      try {
        if (await File(p).exists()) await File(p).delete();
      } catch (_) {}
    }
  }
}
