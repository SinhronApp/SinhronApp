// ADR-045 — the call's video codec, FaceTime-style: H.265 where everyone
// can, H.264 / VP8 otherwise, and away from a codec a phone can't decode.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/call_codecs.dart';
import 'package:sinhron/features/calls/call_diagnostics.dart';

const _server = ['h265', 'h264', 'vp8'];
const _iphone = {'h264', 'h265'};
const _all = {'h264', 'h265', 'vp8', 'av1'};

void main() {
  test('iPhone ↔ iPhone: H.265, the FaceTime codec', () {
    expect(
      pickVideoCodec(server: _server, hardware: _iphone, encodable: _all, peers: [_all]),
      'h265',
    );
  });

  test('an older app, an older server, or a peer without H.265: H.264', () {
    expect(pickVideoCodec(server: _server, hardware: _iphone, encodable: _all, peers: [null]), 'h264',
        reason: 'said nothing = an app before ADR-045');
    expect(pickVideoCodec(server: const [], hardware: _iphone, encodable: _all, peers: [_all]), 'h264',
        reason: 'the server didn\'t say it takes H.265');
    expect(pickVideoCodec(server: _server, hardware: _iphone, encodable: _all, peers: [_all, {'h264', 'vp8'}]),
        'h264', reason: 'a group: everyone must decode it');
    expect(pickVideoCodec(server: _server, hardware: {'h264'}, encodable: _all, peers: [_all]), 'h264',
        reason: 'no hardware H.265 here: not on a software encoder');
  });

  test('a codec someone couldn\'t decode is dropped; VP8 is the floor; AV1 never', () {
    expect(pickVideoCodec(server: _server, hardware: _iphone, encodable: _all, peers: [_all], bad: {'h265'}), 'h264');
    expect(pickVideoCodec(server: _server, hardware: const {}, encodable: {'vp8'}, peers: [_all]), 'vp8');
    expect(pickVideoCodec(server: [..._server, 'av1'], hardware: {'av1', 'h264'}, encodable: _all, peers: [_all]), 'h264',
        reason: 'AV1 would go unencrypted in livekit_client 2.7.0');
  });

  test('mime names', () {
    expect(codecNameOf('video/H265'), 'h265');
    expect(codecNameOf('video/VP8'), 'vp8');
    expect(codecNameOf('H264'), 'h264');
  });

  test('video that arrives but never decodes is noticed after the window, frames reset it', () {
    final w = DecodeWatch(window: const Duration(seconds: 6));
    final t0 = DateTime(2026, 10, 16, 20);
    expect(w.stuck(bytesReceived: 1000, framesDecoded: 0, now: t0), isFalse);
    expect(w.stuck(bytesReceived: 5000, framesDecoded: 0, now: t0.add(const Duration(seconds: 3))), isFalse);
    expect(w.stuck(bytesReceived: 9000, framesDecoded: 0, now: t0.add(const Duration(seconds: 7))), isTrue);
    final ok = DecodeWatch();
    expect(ok.stuck(bytesReceived: 1000, framesDecoded: 0, now: t0), isFalse);
    expect(ok.stuck(bytesReceived: 5000, framesDecoded: 30, now: t0.add(const Duration(seconds: 10))), isFalse);
    expect(ok.stuck(bytesReceived: 5000, framesDecoded: 30, now: t0.add(const Duration(seconds: 20))), isFalse,
        reason: 'no new bytes — nothing to decode');
  });

  test('diagnostics show the camera codec next to the voice one', () {
    final s = CallStatsSnapshot.parse(
      publisher: const [
        {'type': 'outbound-rtp', 'id': 'a', 'kind': 'audio', 'bytesSent': 10, 'codecId': 'ca'},
        {'type': 'outbound-rtp', 'id': 'v', 'kind': 'video', 'bytesSent': 10, 'codecId': 'cv'},
        {'type': 'codec', 'id': 'ca', 'mimeType': 'audio/opus'},
        {'type': 'codec', 'id': 'cv', 'mimeType': 'video/H265'},
      ],
      subscriber: const [],
      at: DateTime(2026),
    );
    expect(s.videoCodec, 'h265');
    expect(diagnosticsLines(s, room: 'connected', plan: 'direct', people: 2).last, 'codec: opus · video h265');
  });
}
