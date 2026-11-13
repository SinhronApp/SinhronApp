// Voice recording — ADR-017 stage 4.
//
// `record` writes AAC to a file while recording (it has no in-memory
// AAC mode). The file lives in the app's temp dir only for the length
// of the recording: on stop it's read into RAM and deleted at once; on
// cancel it's deleted. Encryption happens in Rust before any upload.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'waveform.dart';

/// Hard cap — longer recordings are stopped and sent as is.
const Duration kMaxVoiceDuration = Duration(minutes: 15);

class RecordedVoice {
  const RecordedVoice({
    required this.bytes,
    required this.durationMs,
    required this.waveform,
  });

  final Uint8List bytes;
  final int durationMs;
  final Uint8List waveform;
}

class VoiceRecorder {
  VoiceRecorder({AudioRecorder? recorder}) : _rec = recorder ?? AudioRecorder();

  final AudioRecorder _rec;

  /// Asked once — every millisecond before the mic opens is felt.
  static Directory? _tmp;
  final List<double> _samples = [];
  final Stopwatch _clock = Stopwatch();
  StreamSubscription<Amplitude>? _amp;
  String? _path;

  bool get isRecording => _path != null;
  Duration get elapsed => _clock.elapsed;

  /// Latest levels for a live meter (0..255), newest last.
  List<int> recentLevels(int n) {
    final from = _samples.length > n ? _samples.length - n : 0;
    return [for (final db in _samples.sublist(from)) dbToLevel(db)];
  }

  /// Starts recording; false if the microphone permission is denied.
  Future<bool> start() async {
    if (isRecording) return true;
    if (!await _rec.hasPermission()) return false;
    final dir = _tmp ??= await getTemporaryDirectory();
    final path = '${dir.path}/voice-${DateTime.now().microsecondsSinceEpoch}.m4a';
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        // Speech: mono 48 kbps ≈ 6 KB/s → 15 min ≈ 5.4 MB.
        bitRate: 48000,
        sampleRate: 44100,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
      path: path,
    );
    _path = path;
    _samples.clear();
    _clock
      ..reset()
      ..start();
    _amp = _rec
        .onAmplitudeChanged(const Duration(milliseconds: 100))
        .listen((a) => _samples.add(a.current));
    return true;
  }

  /// Stops, reads the audio into RAM and deletes the temp file.
  Future<RecordedVoice?> stop() async {
    if (!isRecording) return null;
    final durationMs = _clock.elapsedMilliseconds;
    _clock.stop();
    await _amp?.cancel();
    _amp = null;
    final path = await _rec.stop() ?? _path!;
    _path = null;
    final file = File(path);
    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return RecordedVoice(
        bytes: bytes,
        durationMs: durationMs,
        waveform: downsampleWaveform(_samples),
      );
    } finally {
      await _deleteQuietly(file);
    }
  }

  /// Discards the recording and its temp file.
  Future<void> cancel() async {
    if (!isRecording) return;
    _clock.stop();
    await _amp?.cancel();
    _amp = null;
    final path = _path!;
    _path = null;
    await _rec.cancel();
    await _deleteQuietly(File(path));
  }

  Future<void> dispose() async {
    await cancel();
    await _rec.dispose();
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
