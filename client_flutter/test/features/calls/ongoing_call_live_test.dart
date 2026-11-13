// Owner, 2026-10-18 — "the call ended, it still says Join": a phone that
// slept missed the CallEnd. Before offering Join the chat asks the server
// (LiveKit's count) and forgets a call nobody is in.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';

void main() {
  final t0 = DateTime(2026, 10, 18, 17);
  OngoingCall call(String id) =>
      OngoingCall(callId: id, groupIdHex: 'g', kind: CallKind.audio, livekitRoom: 'r', since: t0);

  ProviderContainer host(bool? Function() answer, List<String> asked) {
    final c = ProviderContainer(
      overrides: [
        callLiveCheckProvider.overrideWithValue((g) async {
          asked.add(g);
          return answer();
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a call nobody is in is forgotten; "don\'t know" keeps it', () async {
    bool? live = true;
    final asked = <String>[];
    final c = host(() => live, asked);
    final n = c.read(ongoingGroupCallsProvider.notifier)..put(call('c1'));

    await n.verify('g', now: t0.add(const Duration(seconds: 5)));
    expect(asked, isEmpty, reason: 'its first seconds: the caller may not be in the room yet');

    await n.verify('g', now: t0.add(const Duration(seconds: 30)));
    expect(n.inChat('g', now: t0.add(const Duration(seconds: 30))), isNotNull, reason: 'still on');

    await n.verify('g', now: t0.add(const Duration(seconds: 35)));
    expect(asked.length, 1, reason: 'not asked again right away');

    live = null; // older server / offline
    await n.verify('g', now: t0.add(const Duration(seconds: 60)));
    expect(n.inChat('g', now: t0.add(const Duration(seconds: 60))), isNotNull);

    live = false;
    await n.verify('g', now: t0.add(const Duration(seconds: 90)));
    expect(n.inChat('g', now: t0.add(const Duration(seconds: 90))), isNull, reason: 'ended while I slept');
  });
}
