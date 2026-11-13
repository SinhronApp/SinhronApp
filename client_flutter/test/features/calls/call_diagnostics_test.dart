// The friend's idea, 2026-10-16: a call diagnostics panel. The parsing of
// WebRTC stats into what the panel shows, on sample reports.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/call_diagnostics.dart';

List<Map<String, Object?>> pub(int bytesSent) => [
  {'type': 'media-source', 'id': 'ms', 'kind': 'audio', 'audioLevel': 0.2},
  {'type': 'outbound-rtp', 'id': 'o', 'kind': 'audio', 'bytesSent': bytesSent, 'codecId': 'c'},
  {'type': 'codec', 'id': 'c', 'mimeType': 'audio/opus'},
  {'type': 'candidate-pair', 'id': 'p0', 'state': 'failed', 'localCandidateId': 'l0'},
  {'type': 'candidate-pair', 'id': 'p1', 'selected': true, 'state': 'succeeded', 'localCandidateId': 'l1', 'currentRoundTripTime': 0.085},
  {'type': 'local-candidate', 'id': 'l0', 'candidateType': 'host', 'protocol': 'udp'},
  {'type': 'local-candidate', 'id': 'l1', 'candidateType': 'relay', 'protocol': 'udp', 'relayProtocol': 'tls'},
];

List<Map<String, Object?>> sub(int bytes) => [
  {'type': 'inbound-rtp', 'id': 'i', 'kind': 'audio', 'bytesReceived': bytes, 'packetsLost': 5, 'packetsReceived': 95, 'jitter': 0.012, 'audioLevel': 0.4},
];

void main() {
  test('mic and peer levels, the relay path over TLS, loss, jitter, rtt, codec', () {
    final t0 = DateTime(2026, 10, 16, 12);
    final a = CallStatsSnapshot.parse(publisher: pub(10000), subscriber: sub(20000), at: t0);
    expect(a.micLevel, 0.2);
    expect(a.peerLevel, 0.4);
    expect(a.path, 'relay · tls');
    expect(a.rttMs, closeTo(85, 0.01));
    expect(a.lossPercent, closeTo(5, 0.01));
    expect(a.jitterMs, closeTo(12, 0.01));
    expect(a.codec, 'opus');
    expect(a.sendKbps, isNull, reason: 'no rate before a second reading');

    final b = CallStatsSnapshot.parse(
      publisher: pub(10000 + 3000),
      subscriber: sub(20000 + 6000),
      at: t0.add(const Duration(seconds: 1)),
      prev: a,
    );
    expect(b.sendKbps, closeTo(24, 0.01));
    expect(b.recvKbps, closeTo(48, 0.01));

    final lines = diagnosticsLines(b, room: 'connected', plan: 'reserve', people: 2);
    expect(lines, contains('path: relay · tls (reserve 443)'));
    expect(lines.first, 'room: connected · 2 in call');
    expect(lines.any((l) => l.startsWith('mic: 20%')), isTrue);
  });

  test('a direct path, and nothing known yet', () {
    final d = CallStatsSnapshot.parse(
      publisher: [
        {'type': 'candidate-pair', 'id': 'p', 'nominated': true, 'state': 'succeeded', 'localCandidateId': 'l'},
        {'type': 'local-candidate', 'id': 'l', 'candidateType': 'srflx', 'protocol': 'udp'},
      ],
      subscriber: const [],
      at: DateTime(2026),
    );
    expect(d.path, 'direct · udp');
    final empty = CallStatsSnapshot.parse(publisher: const [], subscriber: const [], at: DateTime(2026));
    expect(diagnosticsLines(empty, room: 'connecting', plan: 'direct', people: 1)[1], 'path: —');
  });

  test('ADR-046: the best layer sent and the best picture received, with frame rate', () {
    final a = CallStatsSnapshot.parse(
      publisher: [
        ...pub(1000),
        {'type': 'outbound-rtp', 'id': 'vq', 'kind': 'video', 'rid': 'q', 'frameWidth': 320, 'frameHeight': 180, 'framesPerSecond': 15},
        {'type': 'outbound-rtp', 'id': 'vf', 'kind': 'video', 'rid': 'f', 'frameWidth': 1920, 'frameHeight': 1080, 'framesPerSecond': 30},
        {'type': 'outbound-rtp', 'id': 'vh', 'kind': 'video', 'rid': 'h', 'frameWidth': 960, 'frameHeight': 540, 'framesPerSecond': 24},
      ],
      subscriber: [
        ...sub(1000),
        {'type': 'inbound-rtp', 'id': 'iv', 'kind': 'video', 'frameWidth': 1280, 'frameHeight': 720},
      ],
      at: DateTime(2026, 10, 18),
    );
    expect(a.videoOut, '1920×1080 · 30 fps');
    expect(a.videoIn, '1280×720');
    expect(
      diagnosticsLines(a, room: 'r', plan: 'direct', people: 2),
      contains('video ↑ 1920×1080 · 30 fps  ·  ↓ 1280×720'),
    );
    final audioOnly = CallStatsSnapshot.parse(publisher: pub(1), subscriber: sub(1), at: DateTime(2026, 10, 18));
    expect(audioOnly.videoOut, isNull);
    expect(diagnosticsLines(audioOnly, room: 'r', plan: 'direct', people: 2).where((l) => l.startsWith('video')), isEmpty);
  });
}
