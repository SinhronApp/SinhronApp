// Now, by the server's clock (owner, 2026-10-16: "my iPhone's time runs
// behind although it's set to automatic — there must be protection").
//
// The Rust core learns the offset from the server (its Hello / HTTP Date —
// `sinhron_net::clock_drift`) and keeps it monotonic; message ids (UUIDv7)
// and the times of my messages come from it, so a phone with a wrong clock
// doesn't put its messages in the past or the future for anyone.

import '../src/rust/api/simple.dart' as core;

/// Milliseconds since the epoch by the server's clock; the phone's own clock
/// when the core isn't loaded (tests) or hasn't heard the server yet.
int serverNowMs() {
  try {
    return core.clockNowMs();
  } catch (_) {
    return DateTime.now().millisecondsSinceEpoch;
  }
}

DateTime serverNow() => DateTime.fromMillisecondsSinceEpoch(serverNowMs());
