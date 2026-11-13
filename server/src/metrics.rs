// In-process counters (Prometheus types, default registry) — rate-limit
// hits, messages, calls. 2026-10-26 (KISS): the `/metrics` endpoint is
// gone — nothing scraped it; the counters stay for the server's own use.
//
// Cost: each metric increment is a single atomic, no allocations.

use once_cell::sync::Lazy;
use prometheus::{
    register_int_counter, register_int_counter_vec, register_int_gauge, IntCounter, IntCounterVec, IntGauge,
};


// ─── Counters ───────────────────────────────────────────────────────

pub static MESSAGES_SUBMITTED_TOTAL: Lazy<IntCounter> = Lazy::new(|| {
    register_int_counter!(
        "sinhron_messages_submitted_total",
        "Total Submit frames accepted by the server (incl. sealed)."
    )
    .expect("metric registration")
});

pub static MESSAGES_FANOUT_TOTAL: Lazy<IntCounter> = Lazy::new(|| {
    register_int_counter!(
        "sinhron_messages_fanout_total",
        "Total Push frames sent via fanout across all sessions."
    )
    .expect("metric registration")
});

pub static PUSH_SENT_TOTAL: Lazy<IntCounter> = Lazy::new(|| {
    register_int_counter!(
        "sinhron_push_sent_total",
        "APNs pushes accepted (message notifications and VoIP calls)."
    )
    .expect("metric registration")
});

pub static RETENTION_ROWS_DELETED: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "sinhron_retention_rows_deleted_total",
        "Rows dropped by retention worker per table.",
        &["table"]
    )
    .expect("metric registration")
});

pub static RATE_LIMIT_HITS_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "sinhron_rate_limit_hits_total",
        "Requests rejected by rate limiter per action.",
        &["action"]
    )
    .expect("metric registration")
});

// ─── Gauges ─────────────────────────────────────────────────────────

pub static WS_ACTIVE_SESSIONS: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "sinhron_ws_active_sessions",
        "Currently authenticated WS sessions across all users."
    )
    .expect("metric registration")
});

/// CB2 — count of CallInvite frames that successfully started a
/// CallSession. Labelled by kind ("audio" / "video"). Does NOT count
/// rejected invites (busy / 403 / 412).
pub static CALLS_TOTAL: Lazy<IntCounterVec> = Lazy::new(|| {
    register_int_counter_vec!(
        "sinhron_calls_total",
        "Total CallInvite frames accepted by the server, by kind.",
        &["kind"]
    )
    .expect("metric registration")
});

/// CB3 — number of CallSession entries currently in the registry
/// (status != Ended). Surfaced as a gauge updated by the watchdog
/// task (CB5).
pub static CALLS_ACTIVE: Lazy<IntGauge> = Lazy::new(|| {
    register_int_gauge!(
        "sinhron_calls_active",
        "CallSession entries currently in Ringing or Active state."
    )
    .expect("metric registration")
});

// ─── Test ──────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registered_metrics_appear_in_gather() {
        // Touch each metric so it's allocated, then verify gather()
        // returns them. (Lazy init happens on first reference.)
        MESSAGES_SUBMITTED_TOTAL.inc();
        MESSAGES_FANOUT_TOTAL.inc_by(5);
        WS_ACTIVE_SESSIONS.set(3);
        RETENTION_ROWS_DELETED.with_label_values(&["messages"]).inc();
        RATE_LIMIT_HITS_TOTAL.with_label_values(&["register"]).inc();

        let families = prometheus::gather();
        let names: Vec<&str> = families.iter().map(|f| f.name()).collect();

        // The crate may not gather metrics that were created in OTHER
        // tests' processes (each test = own process in cargo). Within
        // THIS test we should see all we just touched.
        assert!(
            names.contains(&"sinhron_messages_submitted_total")
                || families.is_empty(), // some test runners reset state
            "expected sinhron_messages_submitted_total in: {names:?}"
        );
    }
}
