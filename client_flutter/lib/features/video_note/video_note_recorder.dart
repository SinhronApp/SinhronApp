// Round video messages ("кружки") — ADR-048. Recording side.
//
// The front camera records a short clip (≤ [kMaxVideoNoteDuration]) into
// the app's temp dir; the chat crops it to a [kVideoNoteSide]-px square
// (`video_note_tools.dart`), reads it into RAM and deletes every
// plaintext file before Rust encrypts and uploads it — as for any video.
//
// [VideoNoteRecorder] is the seam: widget tests swap in a fake (no
// camera plugin under `flutter test`), the app uses [CameraVideoNoteRecorder].

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show DeviceOrientation;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/permissions.dart';

/// Hard cap — the recording stops and is sent at this length (Telegram's).
const Duration kMaxVideoNoteDuration = Duration(seconds: 60);

/// Shorter holds are accidental — not sent.
const Duration kMinVideoNoteDuration = Duration(seconds: 1);

/// Side of the square clip that goes out, in pixels.
const int kVideoNoteSide = 480;

/// A finished recording: a plaintext file in the temp dir (the caller
/// deletes it) and how long it is.
class RecordedVideoNote {
  const RecordedVideoNote({required this.path, required this.durationMs});
  final String path;
  final int durationMs;
}

enum VideoNoteStart {
  started,

  /// Camera or microphone permission refused.
  denied,

  /// No camera, or it failed to open.
  unavailable,
}

abstract class VideoNoteRecorder {
  /// Opens the front camera and starts recording.
  Future<VideoNoteStart> start();

  bool get isRecording;
  Duration get elapsed;

  /// There is a second camera to switch to.
  bool get canSwitchCamera;

  /// Front ⇄ back, without stopping the recording.
  Future<void> switchCamera();

  /// The live picture, filling (cover) whatever box it gets — the
  /// overlay clips it to a circle.
  Widget preview();

  /// Stops; null if nothing usable was recorded.
  Future<RecordedVideoNote?> stop();

  /// Stops and deletes the recording.
  Future<void> cancel();

  /// Releases the camera (cancels a recording still running).
  Future<void> dispose();
}

typedef VideoNoteRecorderFactory = VideoNoteRecorder Function();

final videoNoteRecorderProvider = Provider<VideoNoteRecorderFactory>((ref) => CameraVideoNoteRecorder.new);

/// The `camera` plugin: 480p from the front camera, ~1 Mbit/s H.264
/// (hardware) + AAC. The capture orientation is locked to the one the
/// phone has when recording starts, so turning it mid-way doesn't turn
/// the picture.
class CameraVideoNoteRecorder implements VideoNoteRecorder {
  CameraVideoNoteRecorder({CallPermissionsService permissions = const CallPermissionsService()})
    : _permissions = permissions;

  final CallPermissionsService _permissions;
  final Stopwatch _clock = Stopwatch();

  /// The phone's cameras don't change while the app runs: listed once
  /// (on switching the mic to video), not on every hold.
  static List<CameraDescription>? _known;

  /// Lists the cameras ahead of the hold — opens none of them.
  static Future<void> warmUp() async {
    try {
      _known ??= await availableCameras();
    } catch (_) {
      // No camera plugin (tests, desktop) — the hold finds out.
    }
  }
  CameraController? _camera;
  List<CameraDescription> _cameras = const [];
  bool _recording = false;
  bool _switching = false;

  @override
  bool get isRecording => _recording;

  @override
  Duration get elapsed => _clock.elapsed;

  @override
  bool get canSwitchCamera => _cameras.length > 1;

  @override
  Future<VideoNoteStart> start() async {
    if (_recording) return VideoNoteStart.started;
    if (await _permissions.requestMicAndCamera() != CallPermission.granted) return VideoNoteStart.denied;
    try {
      _cameras = _known ??= await availableCameras();
      if (_cameras.isEmpty) return VideoNoteStart.unavailable;
      final front = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );
      final camera = CameraController(
        front,
        ResolutionPreset.medium,
        enableAudio: true,
        videoBitrate: 1000000,
        audioBitrate: 64000,
      );
      _camera = camera;
      await camera.initialize();
      await camera.lockCaptureOrientation(camera.value.deviceOrientation);
      await camera.prepareForVideoRecording();
      await camera.startVideoRecording();
      _recording = true;
      _clock
        ..reset()
        ..start();
      return VideoNoteStart.started;
    } on CameraException catch (e) {
      await _release();
      return e.code.contains('Access') || e.code.contains('ermission')
          ? VideoNoteStart.denied
          : VideoNoteStart.unavailable;
    } catch (_) {
      await _release();
      return VideoNoteStart.unavailable;
    }
  }

  @override
  Future<void> switchCamera() async {
    final camera = _camera;
    if (camera == null || !canSwitchCamera || _switching) return;
    _switching = true;
    try {
      final now = camera.description;
      final next = _cameras.firstWhere(
        (c) => c.lensDirection != now.lensDirection,
        orElse: () => _cameras[(_cameras.indexOf(now) + 1) % _cameras.length],
      );
      await camera.setDescription(next);
    } catch (_) {
      // Keep recording on the camera we have.
    } finally {
      _switching = false;
    }
  }

  @override
  Widget preview() {
    final camera = _camera;
    if (camera == null) return const SizedBox.expand();
    return ValueListenableBuilder<CameraValue>(
      valueListenable: camera,
      builder: (context, v, _) {
        if (!v.isInitialized || v.previewSize == null) return const SizedBox.expand();
        final o = v.recordingOrientation ?? v.lockedCaptureOrientation ?? v.deviceOrientation;
        final landscape = o == DeviceOrientation.landscapeLeft || o == DeviceOrientation.landscapeRight;
        final aspect = landscape ? v.aspectRatio : 1 / v.aspectRatio;
        return ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(width: 100 * aspect, height: 100, child: _rotated(camera.buildPreview(), o)),
          ),
        );
      },
    );
  }

  /// Android hands the texture over unrotated (as the plugin's own
  /// `CameraPreview` does it); iOS rotates it natively.
  static Widget _rotated(Widget texture, DeviceOrientation o) {
    if (!Platform.isAndroid) return texture;
    const turns = {
      DeviceOrientation.portraitUp: 0,
      DeviceOrientation.landscapeRight: 1,
      DeviceOrientation.portraitDown: 2,
      DeviceOrientation.landscapeLeft: 3,
    };
    return RotatedBox(quarterTurns: turns[o] ?? 0, child: texture);
  }

  @override
  Future<RecordedVideoNote?> stop() async {
    final camera = _camera;
    if (camera == null || !_recording) return null;
    final durationMs = _clock.elapsedMilliseconds;
    _clock.stop();
    _recording = false;
    try {
      final file = await camera.stopVideoRecording();
      return RecordedVideoNote(path: file.path, durationMs: durationMs);
    } catch (_) {
      return null;
    } finally {
      await _release();
    }
  }

  @override
  Future<void> cancel() async {
    final camera = _camera;
    if (camera == null) return;
    _clock.stop();
    if (_recording) {
      _recording = false;
      try {
        final file = await camera.stopVideoRecording();
        await File(file.path).delete();
      } catch (_) {}
    }
    await _release();
  }

  @override
  Future<void> dispose() => cancel();

  Future<void> _release() async {
    final camera = _camera;
    _camera = null;
    try {
      await camera?.dispose();
    } catch (_) {}
  }
}
