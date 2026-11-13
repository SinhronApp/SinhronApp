// ADR-045 — the video codec of a call, FaceTime-style (owner, 2026-10-16:
// "the best possible video even on a bad link").
//
// H.265 (HEVC) gives about 40 % more picture than H.264 for the same bits,
// and almost every phone encodes it in hardware (iPhone since the A10,
// most Android since ~2017) — no heat, no battery. But a phone can only
// send it when everyone in the call can decode it, and LiveKit's "backup
// codec" (a second, H.264 copy for those who can't) goes out unencrypted
// in livekit_client 2.7.0 — not an option (E2EE first). AV1 is out for
// the same reason (no frame encryption for AV1 at all in 2.7.0).
//
// So the phones agree:
//   1. Every phone in the room tells the others what it decodes (a small
//      LiveKit data message on topic `sinhron.codecs`, again on each join).
//      A peer that says nothing (an older app) decodes H.264 / VP8 only.
//   2. A phone sends H.265 when the server takes it (the call token lists
//      the server's codecs; older servers list none), this phone encodes it
//      in hardware, and every other phone decodes it; else H.264 (hardware
//      everywhere), else VP8. It starts on H.264 / VP8 and moves up once
//      the others have spoken — a camera re-publish, about half a second.
//   3. A phone that receives video it can't decode (bytes arrive, no frame
//      comes out for a few seconds) says `codec_bad` — the sender drops
//      that codec for this call. Belt and braces for a decoder that claims
//      more than it can.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

const kCodecTopic = 'sinhron.codecs';

/// What a peer that never said decodes: every app before ADR-045.
const kLegacyDecoders = {'h264', 'vp8'};

/// Best first.
const _preference = ['h265', 'h264', 'vp8'];

/// `video/H265` → `h265`.
String codecNameOf(String mime) {
  final m = mime.toLowerCase();
  final i = m.indexOf('/');
  return i < 0 ? m : m.substring(i + 1);
}

/// The codec to send with.
///  - [server]: what the server takes (empty from older servers);
///  - [hardware]: what this phone encodes in hardware;
///  - [encodable]: what this phone's WebRTC can encode at all;
///  - [peers]: each other participant's decoders (null = said nothing);
///  - [bad]: codecs a peer couldn't decode in this call.
String pickVideoCodec({
  required List<String> server,
  required Set<String> hardware,
  required Set<String> encodable,
  required Iterable<Set<String>?> peers,
  Set<String> bad = const {},
}) {
  bool everyoneTakes(String c) => peers.every((p) => (p ?? kLegacyDecoders).contains(c));
  for (final c in _preference) {
    if (bad.contains(c) || !everyoneTakes(c)) continue;
    switch (c) {
      case 'h265':
        if (!server.contains('h265') || !hardware.contains('h265') || !encodable.contains('h265')) continue;
      case 'h264':
        if (!encodable.contains('h264')) continue;
    }
    return c;
  }
  return 'vp8';
}

/// Decoding stuck: bytes kept coming for [window] and no frame came out.
@visibleForTesting
class DecodeWatch {
  DecodeWatch({this.window = const Duration(seconds: 6)});
  final Duration window;
  DateTime? _since;
  int _bytes = 0;

  /// One stats reading of an incoming video track. True once it's stuck.
  bool stuck({required int bytesReceived, required int framesDecoded, required DateTime now}) {
    if (framesDecoded > 0 || bytesReceived <= _bytes) {
      if (framesDecoded > 0) _since = null;
      _bytes = bytesReceived;
      return false;
    }
    _bytes = bytesReceived;
    _since ??= now;
    return now.difference(_since!) >= window;
  }
}

/// What this phone can do — from the OS (hardware) and WebRTC (all).
class CodecAbilities {
  const CodecAbilities({required this.hardware, required this.encodable, required this.decodable});
  final Set<String> hardware;
  final Set<String> encodable;
  final Set<String> decodable;

  static const _channel = MethodChannel('dev.sinhron/media');

  static Future<CodecAbilities> probe() async {
    Future<Set<String>> caps(Future<rtc.RTCRtpCapabilities> f) async {
      try {
        final c = await f;
        return {for (final x in c.codecs ?? const <rtc.RTCRtpCodecCapability>[]) codecNameOf(x.mimeType)};
      } catch (_) {
        return const {};
      }
    }

    var hardware = <String>{};
    try {
      hardware = {...?await _channel.invokeListMethod<String>('hardwareVideoEncoders')};
    } on MissingPluginException {
      // Tests / desktop: no hardware list — H.264 / VP8 as before.
    } on PlatformException {
      // ditto
    }
    if (hardware.isEmpty && defaultTargetPlatform == TargetPlatform.iOS) hardware = {'h264'};
    return CodecAbilities(
      hardware: hardware,
      encodable: await caps(rtc.getRtpSenderCapabilities('video')),
      decodable: await caps(rtc.getRtpReceiverCapabilities('video')),
    );
  }
}

/// Runs for one call room: tells the others what this phone decodes,
/// listens to theirs, asks for a better codec when everyone agrees, and
/// reports a codec it can't decode.
class CodecNegotiator {
  CodecNegotiator({
    required this.room,
    required this.server,
    required this.abilities,
    required this.currentCodec,
    required this.onWant,
  });

  final lk.Room room;
  final List<String> server;
  final CodecAbilities abilities;

  /// The camera's codec now (null: camera off).
  final String? Function() currentCodec;

  /// Re-publish the camera with this codec.
  final Future<void> Function(String codec) onWant;

  final _peers = <String, Set<String>>{};
  final _joinedAt = <String, DateTime>{};
  late final DateTime _startedAt;
  final _bad = <String>{};

  /// A newcomer gets this long to say what it decodes before it counts as
  /// an older app (no back-and-forth re-publish on every join).
  static const grace = Duration(seconds: 3);
  final _watches = <String, DecodeWatch>{};
  final _reported = <String>{};
  lk.EventsListener<lk.RoomEvent>? _listener;
  Timer? _tick;
  bool _switching = false;

  /// For the diagnostics panel.
  Map<String, Set<String>> get peers => Map.unmodifiable(_peers);
  Set<String> get bad => Set.unmodifiable(_bad);

  void start() {
    _startedAt = DateTime.now();
    _listener = room.createListener()
      ..on<lk.DataReceivedEvent>(_onData)
      ..on<lk.ParticipantConnectedEvent>((e) {
        _joinedAt[e.participant.identity] = DateTime.now();
        unawaited(_announce());
      })
      ..on<lk.ParticipantDisconnectedEvent>((e) {
        _peers.remove(e.participant.identity);
        unawaited(evaluate());
      });
    unawaited(_announce());
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_watchDecoding());
      unawaited(evaluate());
    });
  }

  Future<void> dispose() async {
    _tick?.cancel();
    await _listener?.dispose();
  }

  Future<void> _send(Map<String, Object?> m) async {
    try {
      await room.localParticipant?.publishData(utf8.encode(jsonEncode(m)), reliable: true, topic: kCodecTopic);
    } catch (_) {
      // Not connected (yet / any more) — the next join announces again.
    }
  }

  Future<void> _announce() => _send({'t': 'codecs', 'v': 1, 'dec': abilities.decodable.toList()});

  void _onData(lk.DataReceivedEvent e) {
    if (e.topic != kCodecTopic || e.participant == null) return;
    try {
      final m = jsonDecode(utf8.decode(e.data)) as Map<String, Object?>;
      switch (m['t']) {
        case 'codecs':
          _peers[e.participant!.identity] = {for (final c in (m['dec'] as List? ?? const [])) '$c'.toLowerCase()};
          unawaited(evaluate());
        case 'codec_bad':
          final c = '${m['codec']}'.toLowerCase();
          if (_bad.add(c)) unawaited(evaluate());
      }
    } catch (_) {
      // Not ours / garbled — ignored.
    }
  }

  /// Everyone heard from (or quiet long enough to count as an older app):
  /// switch to the best codec they all take.
  Future<void> evaluate() async {
    final current = currentCodec();
    if (current == null || _switching) return;
    final remotes = room.remoteParticipants.values.toList();
    if (remotes.isEmpty) return; // alone: keep what we have until someone comes
    final now = DateTime.now();
    final waiting = remotes.any(
      (p) => !_peers.containsKey(p.identity) && now.difference(_joinedAt[p.identity] ?? _startedAt) < grace,
    );
    if (waiting) return;
    final want = pickVideoCodec(
      server: server,
      hardware: abilities.hardware,
      encodable: abilities.encodable,
      peers: [for (final p in remotes) _peers[p.identity]],
      bad: _bad,
    );
    if (want == current) return;
    _switching = true;
    try {
      // ignore: avoid_print
      print('[livekit] video codec $current → $want');
      await onWant(want);
    } finally {
      _switching = false;
    }
  }

  /// Incoming video that doesn't decode → tell its sender.
  Future<void> _watchDecoding() async {
    final now = DateTime.now();
    for (final p in room.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        final receiver = pub.track?.receiver;
        if (receiver == null) continue;
        try {
          for (final r in await receiver.getStats()) {
            if (r.type != 'inbound-rtp') continue;
            final v = r.values;
            final codec = codecNameOf(pub.mimeType);
            final key = '${p.identity}/${pub.sid}/$codec';
            final watch = _watches.putIfAbsent(key, DecodeWatch.new);
            final stuck = watch.stuck(
              bytesReceived: (v['bytesReceived'] as num?)?.toInt() ?? 0,
              framesDecoded: (v['framesDecoded'] as num?)?.toInt() ?? 0,
              now: now,
            );
            if (stuck && _reported.add(key)) {
              // ignore: avoid_print
              print('[livekit] $codec from ${p.identity} doesn\'t decode — asking for another');
              await _send({'t': 'codec_bad', 'codec': codec});
            }
          }
        } catch (_) {
          // Stats unavailable for a moment.
        }
      }
    }
  }
}
