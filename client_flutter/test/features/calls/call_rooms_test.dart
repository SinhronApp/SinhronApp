// Status 184 (owner, 2026-10-19: "the call isn't on screen, but I still hear
// the voice; the mic says it's on after the call ended") — no call room may
// stay open once its call is over.

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:sinhron/features/calls/livekit_engine.dart';

class _Room implements lk.Room {
  int disconnects = 0;
  int disposes = 0;

  @override
  lk.LocalParticipant? get localParticipant => null;

  @override
  Future<void> disconnect() async => disconnects++;

  @override
  Future<bool> dispose() async {
    disposes++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(openCallRooms.clear);

  test('an orphan room is left and disposed; the call\'s own stays', () async {
    final orphan = _Room(), mine = _Room();
    openCallRooms
      ..add(orphan)
      ..add(mine);
    expect(await closeOrphanCallRooms(keep: mine), 1);
    expect(orphan.disconnects, 1);
    expect(orphan.disposes, 1);
    expect(mine.disconnects, 0);
    expect(openCallRooms, {mine});
  });

  test('with no call on, every room goes', () async {
    final a = _Room(), b = _Room();
    openCallRooms
      ..add(a)
      ..add(b);
    expect(await closeOrphanCallRooms(), 2);
    expect(openCallRooms, isEmpty);
    expect(await closeOrphanCallRooms(), 0, reason: 'nothing left to close');
  });

  test('closing a room takes it off the list even if leaving fails', () async {
    final r = _Room();
    openCallRooms.add(r);
    await closeCallRoom(r);
    await closeCallRoom(r); // twice: harmless
    expect(openCallRooms, isEmpty);
    expect(r.disconnects, 2);
  });
}
