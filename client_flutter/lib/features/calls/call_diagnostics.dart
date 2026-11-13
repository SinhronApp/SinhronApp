// Call diagnostics — the owner's friend, 2026-10-16: "a small button in the
// call: I record my screen, tap it, and it shows that my mic works, that the
// connection is up, what bytes go and come — then we'd know where it breaks
// instead of guessing".
//
// Twice a second the panel reads WebRTC's own statistics from both LiveKit
// connections (sending: publisher, receiving: subscriber) and shows: my mic
// level, the other side's level, bytes and rate each way, packet loss,
// jitter, round trip, the codec, and the path the call took — direct (UDP /
// TCP) or through our relay (TURN over UDP / TCP / TLS 443, ADR-042). No IP
// addresses: screen recordings get shared.
//
// `CallStatsSnapshot.parse` is pure (reports as maps) — tested without a call.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';

/// One reading of the call's statistics.
@immutable
class CallStatsSnapshot {
  const CallStatsSnapshot({
    required this.at,
    this.micLevel,
    this.peerLevel,
    this.sentBytes,
    this.recvBytes,
    this.sendKbps,
    this.recvKbps,
    this.lossPercent,
    this.jitterMs,
    this.rttMs,
    this.codec,
    this.videoCodec,
    this.path,
    this.videoOut,
    this.videoIn,
    this.audioPacketsIn,
    this.audioPacketsPerSec,
  });

  final DateTime at;

  /// 0..1 — my microphone, as WebRTC hears it (before sending).
  final double? micLevel;

  /// 0..1 — the other side's sound arriving here.
  final double? peerLevel;
  final int? sentBytes;
  final int? recvBytes;
  final double? sendKbps;
  final double? recvKbps;

  /// Incoming packets lost, % of all expected.
  final double? lossPercent;
  final double? jitterMs;

  /// Round trip to the server (ICE pair), ms.
  final double? rttMs;
  final String? codec;

  /// The camera's codec being sent (h265 / h264 / vp8 — ADR-045).
  final String? videoCodec;

  /// e.g. "direct · udp", "relay · tls" — the path the call's media took.
  final String? path;

  /// ADR-046 — my best layer being sent and the best picture arriving,
  /// e.g. "1920×1080 · 30 fps" (null when no video flows).
  final String? videoOut;
  final String? videoIn;

  /// The other side's voice packets received so far, and per second now —
  /// 0/s with a subscribed track = their sound isn't reaching me.
  final int? audioPacketsIn;
  final double? audioPacketsPerSec;

  static num? _num(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);

  /// From WebRTC stats reports (each a map with `type`, `id` and its values);
  /// [prev] gives the rates.
  static CallStatsSnapshot parse({
    required List<Map<String, Object?>> publisher,
    required List<Map<String, Object?>> subscriber,
    required DateTime at,
    CallStatsSnapshot? prev,
  }) {
    double? micLevel;
    int? sent;
    String? codecId;
    String? videoCodecId;
    Map<String, Object?>? bestOut;
    Map<String, Object?>? bestIn;
    bool taller(Map<String, Object?> r, Map<String, Object?>? than) =>
        (_num(r['frameHeight']) ?? 0) > (than == null ? 0 : (_num(than['frameHeight']) ?? 0));
    for (final r in publisher) {
      final type = r['type'];
      if (type == 'media-source' && r['kind'] == 'audio') micLevel = _num(r['audioLevel'])?.toDouble();
      if (type == 'outbound-rtp') {
        sent = (sent ?? 0) + (_num(r['bytesSent'])?.toInt() ?? 0);
        if (r['kind'] == 'audio' || r['mediaType'] == 'audio') codecId ??= r['codecId'] as String?;
        if (r['kind'] == 'video' || r['mediaType'] == 'video') {
          videoCodecId ??= r['codecId'] as String?;
          if (taller(r, bestOut)) bestOut = r;
        }
      }
    }
    double? peerLevel;
    int? recv;
    var lost = 0, got = 0;
    double? jitter;
    for (final r in subscriber) {
      if (r['type'] != 'inbound-rtp') continue;
      recv = (recv ?? 0) + (_num(r['bytesReceived'])?.toInt() ?? 0);
      if ((r['kind'] == 'video' || r['mediaType'] == 'video') && taller(r, bestIn)) bestIn = r;
      if (r['kind'] == 'audio' || r['mediaType'] == 'audio') {
        final level = _num(r['audioLevel'])?.toDouble();
        if (level != null && (peerLevel == null || level > peerLevel)) peerLevel = level;
        lost += _num(r['packetsLost'])?.toInt() ?? 0;
        got += _num(r['packetsReceived'])?.toInt() ?? 0;
        final j = _num(r['jitter'])?.toDouble();
        if (j != null) jitter = j * 1000;
      }
    }
    String? codecName(String? id) {
      if (id == null) return null;
      final c = publisher.where((r) => r['type'] == 'codec' && r['id'] == id).firstOrNull;
      return (c?['mimeType'] as String?)?.split('/').last.toLowerCase();
    }

    String? size(Map<String, Object?>? r) {
      if (r == null) return null;
      final w = _num(r['frameWidth'])?.toInt(), h = _num(r['frameHeight'])?.toInt();
      if (w == null || h == null || h == 0) return null;
      final fps = _num(r['framesPerSecond'])?.round();
      return fps == null ? '$w×$h' : '$w×$h · $fps fps';
    }

    final codec = codecName(codecId);
    final videoCodec = codecName(videoCodecId);
    // The path: the selected (or nominated, succeeded) candidate pair of the
    // sending connection, and its local candidate.
    double? rtt;
    String? path;
    Map<String, Object?>? pair;
    for (final r in publisher) {
      if (r['type'] != 'candidate-pair') continue;
      final selected = r['selected'] == true || r['selected'] == 'true';
      final nominated = (r['nominated'] == true || r['nominated'] == 'true') && r['state'] == 'succeeded';
      if (selected || (pair == null && nominated)) pair = r;
    }
    if (pair != null) {
      final rt = _num(pair['currentRoundTripTime'])?.toDouble();
      if (rt != null) rtt = rt * 1000;
      final local = publisher.where((r) => r['id'] == pair!['localCandidateId']).firstOrNull;
      if (local != null) {
        final type = local['candidateType'] as String?;
        final relay = type == 'relay';
        final proto = relay ? (local['relayProtocol'] ?? local['protocol']) : local['protocol'];
        path = '${relay ? 'relay' : 'direct'} · ${proto ?? '?'}';
      }
    }
    double? rate(int? now, int? before) {
      if (prev == null || now == null || before == null) return null;
      final secs = at.difference(prev.at).inMilliseconds / 1000;
      if (secs <= 0) return null;
      return (now - before) * 8 / 1000 / secs;
    }

    return CallStatsSnapshot(
      at: at,
      micLevel: micLevel,
      peerLevel: peerLevel,
      sentBytes: sent,
      recvBytes: recv,
      sendKbps: rate(sent, prev?.sentBytes),
      recvKbps: rate(recv, prev?.recvBytes),
      lossPercent: lost + got > 0 ? lost * 100 / (lost + got) : null,
      jitterMs: jitter,
      rttMs: rtt,
      codec: codec,
      videoCodec: videoCodec,
      path: path,
      videoOut: size(bestOut),
      videoIn: size(bestIn),
      audioPacketsIn: got + lost > 0 || subscriber.any((r) => r['type'] == 'inbound-rtp') ? got : null,
      audioPacketsPerSec: () {
        final before = prev?.audioPacketsIn;
        if (prev == null || before == null) return null;
        final secs = at.difference(prev.at).inMilliseconds / 1000;
        return secs <= 0 ? null : (got - before) / secs;
      }(),
    );
  }
}

String _bytes(int? b) {
  if (b == null) return '—';
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(2)} MB';
}

String _kbps(double? k) => k == null ? '—' : '${k.toStringAsFixed(0)} kbit/s';

/// The panel's text, one fact per line (also what a test reads).
List<String> diagnosticsLines(
  CallStatsSnapshot s, {
  required String room,
  required String plan,
  required int people,
  String setup = '',
  int? peerAudioTracks,
  String? audioSession,
}) => [
  'room: $room · $people in call',
  // Where the time went from the answer to hearing each other (CallTimeline).
  if (setup.isNotEmpty) 'setup: $setup',
  'path: ${s.path ?? '—'}${plan == 'reserve' ? ' (reserve 443)' : ''}',
  'mic: ${s.micLevel == null ? '—' : (s.micLevel! * 100).round()}%  ·  peer: ${s.peerLevel == null ? '—' : (s.peerLevel! * 100).round()}%',
  '↑ ${_bytes(s.sentBytes)} · ${_kbps(s.sendKbps)}',
  '↓ ${_bytes(s.recvBytes)} · ${_kbps(s.recvKbps)}',
  'loss: ${s.lossPercent == null ? '—' : '${s.lossPercent!.toStringAsFixed(1)}%'}'
      '  ·  jitter: ${s.jitterMs == null ? '—' : '${s.jitterMs!.round()} ms'}'
      '  ·  rtt: ${s.rttMs == null ? '—' : '${s.rttMs!.round()} ms'}',
  'codec: ${s.codec ?? '—'}${s.videoCodec == null ? '' : ' · video ${s.videoCodec}'}',
  if (s.videoOut != null || s.videoIn != null) 'video ↑ ${s.videoOut ?? '—'}  ·  ↓ ${s.videoIn ?? '—'}',
  // Which side of a silent call is silent (owner, 2026-10-18): their track
  // here and its packets flowing; my phone's audio session.
  if (peerAudioTracks != null)
    'peer audio: ${peerAudioTracks == 0 ? 'no track' : '$peerAudioTracks track${peerAudioTracks == 1 ? '' : 's'}'}'
        ' · ${s.audioPacketsIn ?? 0} pkts'
        '${s.audioPacketsPerSec == null ? '' : ' (${s.audioPacketsPerSec!.round()}/s)'}',
  if (audioSession != null) 'session: $audioSession',
];

/// The iPhone's audio session (`dev.sinhron/audio` → `audioState`) in one
/// line: "playAndRecord · VoiceChat · active · webrtc on (CallKit) ·
/// MicrophoneBuiltIn → Receiver". Off a call's play-and-record the mic
/// records nothing; "webrtc off (CallKit)" — waiting for CallKit's
/// activation.
String audioSessionLine(Map<String, Object?> m) {
  final manual = m['manual'] == true;
  final webrtc = m['enabled'] == true || !manual ? 'webrtc on' : 'webrtc off';
  return [
    m['category'] ?? '?',
    m['mode'] ?? '?',
    m['active'] == true ? 'active' : 'inactive',
    if (m['interrupted'] == true) 'INTERRUPTED',
    '$webrtc${manual ? ' (CallKit)' : ''}',
    if (m['input'] == false) 'NO MIC',
    '${m['in'] ?? '?'} → ${m['out'] ?? '?'}',
  ].join(' · ');
}

/// The overlay: reads the room's statistics twice a second.
class CallDiagnosticsPanel extends StatefulWidget {
  const CallDiagnosticsPanel({super.key, required this.room, required this.plan, this.setup, this.audioSession});

  final lk.Room room;

  /// `direct` / `reserve` — the path the app asked for (ADR-042).
  final String plan;

  /// The call's setup marks ("prep 0 ms · room 410 ms · …").
  final String Function()? setup;

  /// iPhone: the audio session's state (null elsewhere).
  final Future<Map<String, Object?>?> Function()? audioSession;

  @override
  State<CallDiagnosticsPanel> createState() => _CallDiagnosticsPanelState();
}

class _CallDiagnosticsPanelState extends State<CallDiagnosticsPanel> {
  CallStatsSnapshot _s = CallStatsSnapshot(at: DateTime.now());
  String? _session;
  Timer? _timer;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _read());
    _read();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static Future<List<Map<String, Object?>>> _reports(Future<List<dynamic>>? f) async {
    if (f == null) return const [];
    try {
      final list = await f;
      return [
        for (final r in list)
          <String, Object?>{...(r.values as Map).cast<String, Object?>(), 'type': r.type as String, 'id': r.id as String},
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _read() async {
    if (_busy) return;
    _busy = true;
    try {
      // Through the tracks' own senders / receivers (public API): each one's
      // stats include its transport — the candidate pair, so the path too.
      final room = widget.room;
      final pub = <Map<String, Object?>>[
        for (final p in room.localParticipant?.trackPublications.values ?? const <lk.LocalTrackPublication>[])
          ...await _reports(p.track?.sender?.getStats()),
      ];
      final sub = <Map<String, Object?>>[
        for (final rp in room.remoteParticipants.values)
          for (final p in rp.trackPublications.values) ...await _reports(p.track?.receiver?.getStats()),
      ];
      final session = await widget.audioSession?.call();
      if (!mounted) return;
      setState(() {
        _s = CallStatsSnapshot.parse(publisher: pub, subscriber: sub, at: DateTime.now(), prev: _s);
        _session = session == null ? null : audioSessionLine(session);
      });
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = diagnosticsLines(
      _s,
      room: widget.room.connectionState.name,
      plan: widget.plan,
      people: widget.room.remoteParticipants.length + 1,
      setup: widget.setup?.call() ?? '',
      peerAudioTracks: [
        for (final p in widget.room.remoteParticipants.values) ...p.audioTrackPublications.where((t) => t.subscribed),
      ].length,
      audioSession: _session,
    );
    return Container(
      key: const ValueKey('call-diagnostics'),
      padding: const EdgeInsets.all(DsSpace.x3),
      decoration: BoxDecoration(color: DsPalette.black40, borderRadius: BorderRadius.circular(DsSpace.x3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Level(label: 'mic', value: _s.micLevel),
          const SizedBox(height: DsSpace.x1),
          _Level(label: 'peer', value: _s.peerLevel),
          const SizedBox(height: DsSpace.x2),
          for (final l in lines)
            Text(l, style: DsTextArt.t13w500Monov2.copyWith(color: DsPalette.white, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Level extends StatelessWidget {
  const _Level({required this.label, required this.value});
  final String label;
  final double? value;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 40,
        child: Text(label, style: DsTextArt.t13w500Monov2.copyWith(color: DsPalette.white, fontSize: 12)),
      ),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DsSpace.x1),
          child: Container(
            height: 6,
            color: DsPalette.white20,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: ((value ?? 0) * 3).clamp(0.0, 1.0),
              child: Container(color: DsPalette.green),
            ),
          ),
        ),
      ),
    ],
  );
}
