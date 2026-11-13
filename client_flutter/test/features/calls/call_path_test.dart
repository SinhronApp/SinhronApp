// ADR-042 — the reserve path for calls (TURN over TLS on 443): which URLs,
// when a call starts on it, and when a dropping call moves to it.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/call_path.dart';
import 'package:sinhron/features/calls/call_quality.dart';

void main() {
  final t0 = DateTime(2026, 10, 16, 12);

  test('the reserve is the TLS TURN only', () {
    expect(
      reserveTurnUrls([
        'turn:chat.example:3478?transport=udp',
        'turn:chat.example:3478?transport=tcp',
        'turns:turn.chat.example:443?transport=tcp',
      ]),
      ['turns:turn.chat.example:443?transport=tcp'],
    );
    expect(reserveTurnUrls(['turn:x:3478']), isEmpty);
  });

  test('a call starts on the reserve when asked, or when it was needed in the last day', () {
    expect(initialCallPath(alwaysReserve: false, now: t0), CallPath.direct);
    expect(initialCallPath(alwaysReserve: true, now: t0), CallPath.reserve);
    expect(
      initialCallPath(alwaysReserve: false, reserveNeededAt: t0.subtract(const Duration(hours: 3)), now: t0),
      CallPath.reserve,
    );
    expect(
      initialCallPath(alwaysReserve: false, reserveNeededAt: t0.subtract(const Duration(hours: 25)), now: t0),
      CallPath.direct,
    );
  });

  test('two drops within 30 s move the call; two far apart do not', () {
    final c = PathChurn();
    expect(c.dropped(t0), isFalse);
    c.recovered();
    expect(c.dropped(t0.add(const Duration(seconds: 12))), isTrue);
    final d = PathChurn();
    expect(d.dropped(t0), isFalse);
    d.recovered();
    expect(d.dropped(t0.add(const Duration(seconds: 40))), isFalse);
  });

  test('one drop that lasts 8 s moves the call; recovering in time does not', () {
    final c = PathChurn();
    c.dropped(t0);
    expect(c.stalled(t0.add(const Duration(seconds: 5))), isFalse);
    expect(c.stalled(t0.add(const Duration(seconds: 8))), isTrue);
    c.recovered();
    expect(c.stalled(t0.add(const Duration(seconds: 20))), isFalse);
  });

  test('the switch is said on the call screen before anything else', () {
    expect(
      callNoticeFor(mine: CallLinkQuality.poor, peerBad: true, autoAudioOnly: true, switchingPath: true),
      CallNotice.switchingPath,
    );
    expect(callNoticeFor(mine: CallLinkQuality.good, peerBad: false, autoAudioOnly: false), CallNotice.none);
    // Tech-debt 2.38 — the reserve drops too: what helps comes before the
    // weak-link lines.
    expect(
      callNoticeFor(mine: CallLinkQuality.poor, peerBad: true, autoAudioOnly: true, keepsDropping: true),
      CallNotice.keepsDropping,
    );
  });
}
