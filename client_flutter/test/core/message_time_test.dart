// Owner, 2026-10-16: a message from a slow link landed below replies
// written after it. Incoming messages sort by when they were written (the
// sender's UUIDv7), bounded by when the server got them.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/message_time.dart';
import 'package:sinhron/features/chat_list/chat_data.dart' show formatMessageTime;

String v7(int unixMs) {
  final h = unixMs.toRadixString(16).padLeft(12, '0');
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-7abc-8def-0123456789ab';
}

void main() {
  const arrived = 1760600000; // when the server got it

  test('a message written before it arrived keeps its own time', () {
    expect(incomingMessageTs(v7((arrived - 300) * 1000), arrived), arrived - 300);
  });

  test('a sender clock ahead of the server can\'t pin it to the bottom', () {
    expect(incomingMessageTs(v7((arrived + 3600) * 1000), arrived), arrived);
  });

  test('critic:7 — a message backdated by days can\'t slip in above replies: it lands when it arrived', () {
    expect(incomingMessageTs(v7((arrived - 6 * 86400) * 1000), arrived), arrived);
    expect(incomingMessageTs(v7((arrived - 30 * 86400) * 1000), arrived), arrived);
  });

  test('a slow link keeps its time up to 15 minutes back; a send queued for an hour → its arrival', () {
    expect(incomingMessageTs(v7((arrived - 15 * 60) * 1000), arrived), arrived - 15 * 60);
    expect(incomingMessageTs(v7((arrived - 3600) * 1000), arrived), arrived);
  });

  test('an id that is not a UUIDv7 → the server time', () {
    expect(incomingMessageTs('01900000-0000-4000-8000-000000000000', arrived), arrived);
    expect(incomingMessageTs('remote-xyz', arrived), arrived);
    expect(uuidV7Seconds(v7(1760600000123)), 1760600000);
  });

  // Audit 2026-11b T06: delivered_at is the server's word, taken as is.
  test('T06 — an impossible server time can\'t break the chat: the time still formats', () {
    final ts = incomingMessageTs('x', 9000000000000);
    expect(() => formatMessageTime(ts), returnsNormally);
    expect(incomingMessageTs('x', -5), 0);
  });

  test('T06 — a server time from the future can\'t pin a message to the bottom for more than a day', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(incomingMessageTs('x', now + 30 * 86400), lessThanOrEqualTo(now + 86400 + 5));
  });
}
