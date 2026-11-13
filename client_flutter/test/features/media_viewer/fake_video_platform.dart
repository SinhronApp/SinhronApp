// A video player platform that "plays" in memory — gallery video tests.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class FakeVideoPlatform extends VideoPlayerPlatform {
  FakeVideoPlatform({this.duration = const Duration(seconds: 10)});

  final Duration duration;
  final calls = <String>[];
  final _events = <int, StreamController<VideoEvent>>{};
  var _next = 0;
  bool? looping;
  double? volume;
  Duration position = Duration.zero;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(DataSource dataSource) async {
    final id = _next++;
    final c = StreamController<VideoEvent>();
    _events[id] = c;
    calls.add('create');
    // Initialised right away, like a file already in RAM.
    scheduleMicrotask(
      () => c.add(VideoEvent(eventType: VideoEventType.initialized, duration: duration, size: const Size(1280, 720))),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async => this.looping = looping;

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setVolume(int playerId, double volume) async => this.volume = volume;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek');
    this.position = position;
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Widget buildView(int playerId) => const SizedBox.expand(key: ValueKey('fake-video-view'));

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}
