// Server clock drift correction — Risk #4 + CRIT-1.4 monotonic upgrade.
//
// Every action-proof signature embeds a `timestamp_secs` field and the
// server rejects anything outside ±60s of its own clock
// (`ACTION_CLOCK_SKEW_SECS` in `server/src/handlers/proof.rs`). If the
// device's clock is wrong (user set it manually, NTP failure, dying
// battery RTC on old iPhones, traveler crossing time zones with bad
// auto-update), **every** signed request fails with "stale timestamp"
// and the app is stuck.
//
// Approach
// ────────
// On the first observation of authoritative server time (WS Hello, HTTP
// Date header) we capture a **boot point**:
//
//     boot = (server_unix_at_observation, Instant::now())
//
// All later [`corrected_now_secs`] calls compute:
//
//     corrected_now = boot.server + (Instant::now() - boot.instant)
//
// Because [`std::time::Instant`] is guaranteed monotonic, the corrected
// time **never moves backward** within a process — even if the user
// manually rewinds the device's wall-clock between proofs.
//
// This is the CRIT-1.4 upgrade over the original Risk #4 fix, which
// stored a single drift offset and added it to `SystemTime::now()` —
// that variant was vulnerable to wall-clock rollback giving an attacker
// a window where they could replay proofs at a stale timestamp.
//
// Observation update policy
// ─────────────────────────
// Each `record()` call replaces the boot point with the latest
// observation. This tracks legitimate server-side time corrections
// (e.g. server NTP step) — at the cost of a one-time monotonicity
// dip if a buggy / stale Date header arrives. We accept this because:
//
//   1. The HTTP Date header is required to be the current server
//      time per RFC 7231 §7.1.1.2 (caches notwithstanding — but a
//      misbehaving cache returning an old Date would be a separate
//      bug worth surfacing anyway).
//   2. The server's ±60s skew window means even a coarse new
//      observation can't push proofs out of validity by more than
//      that window's worth of "moved backward".
//   3. Monotonicity WITHIN a continuous run of proofs (between
//      observations) is guaranteed by Instant.
//
// Thread-safety: single `Mutex<Option<BootPoint>>`. Loads are cheap
// (uncontended lock), and writes happen at most once per WS reconnect
// or per HTTP response — well below any rate where contention matters.

use std::sync::Mutex;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Captured zero point from which monotonic time advances.
#[derive(Debug, Clone, Copy)]
struct BootPoint {
    /// Unix seconds (UTC) the server reported at the moment we set this point.
    server_secs: i64,
    /// Local monotonic [`Instant`] at the moment we captured `server_secs`.
    /// Subsequent `corrected_now_secs` calls advance from here using
    /// `instant.elapsed()`.
    instant: Instant,
}

/// `None` until first observation. After that, holds the latest
/// observation paired with the local `Instant` it landed at. `Mutex::new`
/// is `const` since Rust 1.63 — safe in a `static`.
static BOOT_POINT: Mutex<Option<BootPoint>> = Mutex::new(None);

/// Record an observation: the server thinks the current unix time is
/// `server_unix`. Captures `Instant::now()` internally so subsequent
/// reads can advance monotonically from this anchor.
///
/// Safe to call from any thread / from sync or async context.
pub fn record(server_unix: i64) {
    // Years 2020..2100 only: an impossible server time must not become the
    // app's clock (audit 2026-11b T06).
    if !(1_577_836_800..4_102_444_800).contains(&server_unix) {
        return;
    }
    let now = Instant::now();
    if let Ok(mut guard) = BOOT_POINT.lock() {
        *guard = Some(BootPoint {
            server_secs: server_unix,
            instant: now,
        });
    }
    // Lock poisoning means a previous holder panicked — we leak the
    // observation in that case. Falling back to wall-clock is safer
    // than panicking from a sync hot path.
}

/// Current best-known unix timestamp from the server's perspective.
///
/// Returns `boot.server + (Instant::now() - boot.instant)` once we have
/// an observation, advancing monotonically regardless of wall-clock
/// changes. Falls back to raw `SystemTime::now()` before the first
/// observation — the first signed request may then fail with stale
/// timestamp, and the server response's Date header will install a
/// boot point so the immediate retry succeeds.
/// [`corrected_now_secs`] in milliseconds — for message ids and times
/// (owner, 2026-10-16: an iPhone set to automatic time still ran behind, and
/// messages sorted by it landed above newer ones).
pub fn corrected_now_ms() -> i64 {
    if let Ok(guard) = BOOT_POINT.lock() {
        if let Some(bp) = *guard {
            let elapsed = bp.instant.elapsed().as_millis() as i64;
            return bp.server_secs.saturating_mul(1000).saturating_add(elapsed);
        }
    }
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn corrected_now_secs() -> i64 {
    if let Ok(guard) = BOOT_POINT.lock() {
        if let Some(bp) = *guard {
            // `as_secs` is u64, but elapsed is bounded by process
            // lifetime (~years at most) so the i64 cast is safe.
            let elapsed = bp.instant.elapsed().as_secs() as i64;
            return bp.server_secs.saturating_add(elapsed);
        }
    }
    local_now_secs()
}

/// Raw wall-clock unix time — exposed for diagnostics (compare with
/// [`corrected_now_secs`] in the UI to see drift magnitude) and as the
/// pre-observation fallback.
pub fn local_now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Current drift (`corrected - local`) in seconds. `0` if never observed.
pub fn current_drift_secs() -> i64 {
    let corrected = corrected_now_secs();
    let local = local_now_secs();
    corrected.saturating_sub(local)
}

/// `true` if we have observed at least one server timestamp this process.
pub fn has_observation() -> bool {
    BOOT_POINT
        .lock()
        .map(|g| g.is_some())
        .unwrap_or(false)
}

/// Test-only — wipe the boot point so tests start from a clean state.
/// Public-but-#[cfg(test)] keeps it out of the FFI surface.
#[cfg(test)]
pub fn reset_for_test() {
    if let Ok(mut guard) = BOOT_POINT.lock() {
        *guard = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;
    use std::thread::sleep;
    use std::time::Duration;

    // Tests share a single static. Serialize them through a process-local
    // mutex so we can assert exact behavior instead of "approximately".
    static TEST_SERIAL: StdMutex<()> = StdMutex::new(());

    /// Audit 2026-11b T06: a server Hello with an impossible time must not
    /// become the app's clock (Dart's DateTime throws on it — sending breaks).
    #[test]
    fn t06_impossible_server_time_is_ignored() {
        let _guard = TEST_SERIAL.lock().unwrap();
        reset_for_test();
        record(i64::MAX);
        assert!(corrected_now_ms() < 4_102_444_800_000, "clock = {}", corrected_now_ms());
        record(-1);
        assert!(corrected_now_ms() > 1_577_836_800_000, "clock = {}", corrected_now_ms());
    }

    #[test]
    fn record_then_corrected_returns_close_to_recorded() {
        let _guard = TEST_SERIAL.lock().unwrap();
        reset_for_test();
        let server_t = 1_700_000_000_i64;
        record(server_t);
        let got = corrected_now_secs();
        // Should be within 1 second of recorded value immediately after.
        assert!(
            (got - server_t).abs() <= 1,
            "corrected_now={got} not close to server_t={server_t}",
        );
    }

    #[test]
    fn corrected_advances_monotonically() {
        let _guard = TEST_SERIAL.lock().unwrap();
        reset_for_test();
        record(1_700_000_000);
        let a = corrected_now_secs();
        sleep(Duration::from_millis(1100));
        let b = corrected_now_secs();
        assert!(b >= a + 1, "monotonic: expected b >= a+1, got a={a} b={b}");
    }

    /// CRIT-1.4 — the original Risk #4 implementation was vulnerable to
    /// wall-clock rollback. The monotonic variant must not regress
    /// `corrected_now` even if `SystemTime::now()` moves backward,
    /// because we no longer consult it once a boot point is set.
    ///
    /// We can't actually rewind the OS clock from a unit test, but we
    /// can prove the property structurally: after `record(server_t)`,
    /// two reads taken back-to-back must satisfy `b >= a` regardless
    /// of `SystemTime`. Strong evidence the value derives only from
    /// `Instant`, which the platform guarantees monotonic.
    #[test]
    fn back_to_back_reads_are_monotone() {
        let _guard = TEST_SERIAL.lock().unwrap();
        reset_for_test();
        record(1_700_000_000);
        let mut last = corrected_now_secs();
        for _ in 0..1000 {
            let next = corrected_now_secs();
            assert!(next >= last, "regression: {next} < {last}");
            last = next;
        }
    }

    #[test]
    fn local_now_is_close_to_system_clock() {
        let _guard = TEST_SERIAL.lock().unwrap();
        let a = local_now_secs();
        let b = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        assert!((a - b).abs() <= 1, "local_now drifts from system time");
    }

    #[test]
    fn has_observation_flips_on_first_record() {
        let _guard = TEST_SERIAL.lock().unwrap();
        reset_for_test();
        assert!(!has_observation(), "fresh state should be unobserved");
        record(1_700_000_000);
        assert!(has_observation());
    }

    #[test]
    fn corrected_falls_back_to_local_when_unobserved() {
        let _guard = TEST_SERIAL.lock().unwrap();
        reset_for_test();
        let a = corrected_now_secs();
        let b = local_now_secs();
        assert!(
            (a - b).abs() <= 1,
            "pre-observation fallback should equal local time",
        );
    }
}
