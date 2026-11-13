// When an incoming message was written — for its place in the chat.
//
// Owner, 2026-10-16: "my new message shows above his older one". A message
// was placed by when it reached the server; from a slow link (a friend in
// Russia: sends that hung for minutes) it landed after replies written
// later. Every message id is a UUIDv7 made on the sender's phone at send
// time, so the time is already in it — no protocol change. Bounded by the
// server: never later than it arrived there (a sender can't pin a message
// to the bottom). Audit critic:7 (docs/security-review-2026-11.md): the id
// is the sender's word — up to 7 days back let a modified app slip a
// message in above replies already written. Now only 15 minutes back (a
// slow link); older (a wrong clock, a send queued offline — the outbox
// keeps its id) → when it arrived, as before 2026-10-16.

import 'dart:math' as math;

import 'server_clock.dart';

const _maxEarlier = 15 * 60;

/// Unix seconds to sort an incoming message by.
int incomingMessageTs(String messageId, int deliveredAtUnix) {
  // The arrival time is the server's word (audit 2026-11b T06): an impossible
  // one broke the chat, a future one pinned the message to the bottom.
  // "Now" is the later of this phone's clock and the server-corrected one: a
  // phone whose own clock is days behind still places honest messages right.
  final nowMs = math.max(DateTime.now().millisecondsSinceEpoch, serverNowMs());
  deliveredAtUnix = deliveredAtUnix.clamp(0, nowMs ~/ 1000 + 86400);
  final sent = uuidV7Seconds(messageId);
  if (sent == null) return deliveredAtUnix;
  if (sent > deliveredAtUnix) return deliveredAtUnix;
  if (sent < deliveredAtUnix - _maxEarlier) return deliveredAtUnix;
  return sent;
}

/// The creation time (unix seconds) inside a UUIDv7, or null for any other id.
int? uuidV7Seconds(String id) {
  final hex = id.replaceAll('-', '');
  if (hex.length != 32 || hex[12] != '7') return null;
  final ms = int.tryParse(hex.substring(0, 12), radix: 16);
  return ms == null ? null : ms ~/ 1000;
}
