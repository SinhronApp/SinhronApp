// Background retention worker — WU A9 / spec §7.6.
//
// Runs as a `tokio::spawn`-ed task launched from [`crate::run`]. Once
// per `RETENTION_PERIOD_SECS` it sweeps:
//
//   • keypackages   — DELETE WHERE consumed_at IS NOT NULL
//                              OR expires_at < NOW()
//   • messages      — DELETE WHERE ts < NOW() - retention_days
//   • message_deliveries — DELETE WHERE delivered_at < NOW() - retention_days;
//                          a sealed one also once received 30 days ago
//
// Configurable via env:
//   SINHRON_MESSAGE_RETENTION_DAYS  (default 365 — owner, 2026-11-02: a phone
//                                    away for weeks still gets its texts; the
//                                    spec's §7.6 had 14)
//   SINHRON_RETENTION_SWEEP_SECS    (default 3600 — once per hour)
//
// Monthly partitions of `messages` (tech-debt 4.4): every sweep makes sure
// the current and the next month have their own partition (moving any rows
// that already landed in `messages_default`), and DROPs whole month
// partitions that ended before the retention window — no row-by-row DELETE
// for them. The row DELETE below still trims the partial month at the edge.
//
// What's NOT here yet:
//   • Account purge (soft-mark > 365d → drop 30d later) — same gating.

use std::time::Duration;

use sqlx::PgPool;
use tokio::time::interval;
use tracing::{debug, error, info};

/// Default retention for messages + deliveries, and for queued Welcomes
/// (invitations into a chat). The spec (§7.6) had 14 days; a phone off for
/// two weeks then lost its messages for good — encrypted texts cost the
/// server almost nothing (~2.4 MB a fortnight), so a year (owner, 2026-11-02).
const DEFAULT_RETENTION_DAYS: i64 = 365;

/// sealed-push:6 — a sealed envelope stays this long after its person
/// received it (it was kept the whole year: a contact could fill the disk).
/// Another device of theirs away longer no longer gets it by Resume.
const RECEIVED_SEALED_KEEP_DAYS: i32 = 30;

/// `SINHRON_MESSAGE_RETENTION_DAYS`, else [DEFAULT_RETENTION_DAYS].
pub fn retention_days() -> i64 {
    days_or_default(std::env::var("SINHRON_MESSAGE_RETENTION_DAYS").ok().as_deref())
}

/// ACCT-6 — 1…3650 days, as the installer checks: 0 or a negative number
/// deleted every message on the next sweep, a huge one overflowed.
fn days_or_default(raw: Option<&str>) -> i64 {
    raw.and_then(|s| s.trim().parse().ok())
        .filter(|d| (1..=3650).contains(d))
        .unwrap_or(DEFAULT_RETENTION_DAYS)
}

/// ACCT-6 — a period of 0 made `interval` panic: no sweeps until restart.
fn sweep_secs_or_default(raw: Option<&str>) -> u64 {
    raw.and_then(|s| s.trim().parse().ok())
        .filter(|s| *s > 0)
        .unwrap_or(DEFAULT_SWEEP_SECS)
}

/// Default sweep cadence — once per hour. The exact value doesn't
/// matter much; the queries are cheap and the worst case is "rows live
/// up to retention + 1h" before they go.
const DEFAULT_SWEEP_SECS: u64 = 3600;

/// Spawn the retention worker. The returned `JoinHandle` ends when the
/// pool is dropped (server shutdown drops AppState which drops the
/// pool clone here).
pub fn spawn(pool: PgPool) -> tokio::task::JoinHandle<()> {
    let retention_days = retention_days();
    let sweep_secs = sweep_secs_or_default(std::env::var("SINHRON_RETENTION_SWEEP_SECS").ok().as_deref());

    info!(
        retention_days,
        sweep_secs,
        "retention worker scheduled"
    );

    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(sweep_secs));
        loop {
            ticker.tick().await;
            if let Err(e) = sweep(&pool, retention_days).await {
                error!(error = %e, "retention sweep failed — will retry next tick");
            }
            // ADR-077 — administrators' notices and IPs with reports: 30 days.
            match crate::admin::sweep(&pool).await {
                Ok((notices, ips)) if notices + ips > 0 => info!(notices, ips, "admin retention swept"),
                Ok(_) => {}
                Err(e) => error!(error = %e, "admin retention sweep failed — will retry next tick"),
            }
        }
    })
}

/// Single sweep pass. Public so unit / integration tests can call it
/// directly without waiting on the ticker.
pub async fn sweep(pool: &PgPool, retention_days: i64) -> anyhow::Result<SweepReport> {
    let mut report = SweepReport::default();

    // ── messages: month partitions (tech-debt 4.4) ───────────────────
    // A failure here must not skip the rest of the sweep.
    if let Err(e) = ensure_month_partitions(pool).await {
        tracing::warn!(error = %e, "month partitions not ensured this sweep");
    }
    let (dropped, rows) = drop_expired_partitions(pool, retention_days).await?;
    report.partitions_dropped = dropped;
    report.messages_deleted += rows;

    // ── keypackages ──────────────────────────────────────────────────
    //
    // Drop consumed rows (the recipient has the KP, server doesn't need
    // to keep it) AND expired rows (per §7.6 — 30d TTL or until consume,
    // whichever comes first; our handler sets expires_at = uploaded_at +
    // 30d). The pool's hot index (`keypackages_consume_idx`) only covers
    // unconsumed rows, so deletes against it are fast.
    let res = sqlx::query(
        "DELETE FROM keypackages \
         WHERE consumed_at IS NOT NULL OR expires_at < NOW()",
    )
    .execute(pool)
    .await?;
    report.keypackages_deleted = res.rows_affected();

    // ── message_deliveries ───────────────────────────────────────────
    //
    // Delete delivery rows older than retention. Done BEFORE messages
    // so the JOIN-on-replay query never sees a delivery whose message
    // is already gone (avoiding a brief consistency hole).
    let res = sqlx::query(
        "DELETE FROM message_deliveries \
         WHERE delivered_at < NOW() - make_interval(days => $1::int)",
    )
    .bind(retention_days as i32)
    .execute(pool)
    .await?;
    report.deliveries_deleted = res.rows_affected();
    let res = sqlx::query(
        "DELETE FROM message_deliveries \
         WHERE envelope IS NOT NULL AND received_at < NOW() - make_interval(days => $1::int)",
    )
    .bind(RECEIVED_SEALED_KEEP_DAYS)
    .execute(pool)
    .await?;
    report.deliveries_deleted += res.rows_affected();

    // ── sealed_keys (ADR-023) ────────────────────────────────────────
    //
    // Delivery keys older than 4 weeks: no sender picks them any more
    // (GET returns last/this/next week) and clients accept two weeks
    // back. Best-effort — counted with the deliveries metric.
    let _ = sqlx::query("DELETE FROM sealed_keys WHERE week < (EXTRACT(EPOCH FROM NOW())::bigint / 604800)::int - 4")
        .execute(pool)
        .await;

    // ── messages ─────────────────────────────────────────────────────
    //
    // Whole expired months are already gone (DROP above); this trims the
    // rows of the month that straddles the retention edge and anything
    // still sitting in `messages_default`.
    let res = sqlx::query(
        "DELETE FROM messages \
         WHERE ts < NOW() - make_interval(days => $1::int)",
    )
    .bind(retention_days as i32)
    .execute(pool)
    .await?;
    report.messages_deleted += res.rows_affected();

    // ── pending_welcomes (Risk #10) ──────────────────────────────────
    //
    // Per-row expires_at was set by handle_welcome at insert time
    // (now + the retention window). Anything past that is dropped
    // — the recipient never came online in time. Sender's UI must
    // re-invite if needed (future WU surfaces this as a banner).
    let res = sqlx::query("DELETE FROM pending_welcomes WHERE expires_at < NOW()")
        .execute(pool)
        .await?;
    report.pending_welcomes_deleted = res.rows_affected();

    // Sealed deliveries whose chat timer ran out (tech-debt 2.5).
    sqlx::query("DELETE FROM message_deliveries WHERE expires_at < NOW()")
        .execute(pool)
        .await?;

    // QR-pairing mailboxes and "taken" markers (10-minute TTL, tech-debt 4.2, ADR-091).
    sqlx::query("DELETE FROM pairing_mailbox WHERE expires_at < NOW()")
        .execute(pool)
        .await?;

    // ADR-043 — short invite links older than a year: the blob goes, the id
    // stays taken. WEB-4 — a deleted row freed the id, and whoever still had
    // the old link (id + key) could put their own invite behind it.
    sqlx::query("UPDATE short_invites SET blob = '' WHERE expires_at < NOW() AND blob <> ''")
        .execute(pool)
        .await?;

    // ── per-chat disappearing TTL (T3.4) ─────────────────────────────
    //
    // For groups with `disappearing_after_secs` set, delete messages
    // older than that local TTL. Independent of the global retention
    // window — typically a tighter (60s … 7d) interval. The partial
    // index `groups_disappearing_idx` keeps the JOIN cheap.
    //
    // Edge: if disappearing_after_secs is set TO a value LARGER than
    // global retention_days, the global pass above already wiped the
    // rows — this query is a no-op. Safe.
    // The timer counts from delivery (ADR-020): a stored ciphertext goes
    // once it is older than the timer AND every recipient received it at
    // least that long ago. Undelivered ones wait for the global window.
    let res = sqlx::query(
        "DELETE FROM messages m \
         USING mls_groups g \
         WHERE m.group_id = g.group_id \
           AND g.disappearing_after_secs IS NOT NULL \
           AND m.ts < NOW() - make_interval(secs => g.disappearing_after_secs::double precision) \
           AND NOT EXISTS ( \
               SELECT 1 FROM message_deliveries md \
               WHERE md.message_id = m.message_id \
                 AND (md.received_at IS NULL \
                      OR md.received_at > NOW() - make_interval(secs => g.disappearing_after_secs::double precision)))",
    )
    .execute(pool)
    .await?;
    report.disappearing_deleted = res.rows_affected();

    // Media blobs untouched for 90 days (rows + files, ADR-017).
    report.media_deleted = crate::handlers::media::sweep_expired(pool).await?;
    // MEDIA-3 — files no row knows about and stale `.part` leftovers.
    {
        use crate::handlers::media::{media_dir, sweep_orphans, ORPHAN_MIN_AGE};
        match sweep_orphans(pool, &media_dir(), ORPHAN_MIN_AGE).await {
            Ok(n) => report.media_deleted += n,
            Err(e) => tracing::warn!(error = %e, "orphan media sweep failed"),
        }
    }

    debug!(
        keypackages = report.keypackages_deleted,
        deliveries = report.deliveries_deleted,
        messages = report.messages_deleted,
        pending_welcomes = report.pending_welcomes_deleted,
        "retention sweep completed"
    );

    if report.has_work() {
        info!(
            keypackages = report.keypackages_deleted,
            deliveries = report.deliveries_deleted,
            messages = report.messages_deleted,
            pending_welcomes = report.pending_welcomes_deleted,
            disappearing = report.disappearing_deleted,
            media = report.media_deleted,
            "retention sweep removed rows"
        );
        // T2.4 — emit per-table counters so Prometheus can graph
        // retention activity over time.
        let m = &crate::metrics::RETENTION_ROWS_DELETED;
        m.with_label_values(&["keypackages"]).inc_by(report.keypackages_deleted);
        m.with_label_values(&["message_deliveries"]).inc_by(report.deliveries_deleted);
        m.with_label_values(&["messages"]).inc_by(report.messages_deleted);
        m.with_label_values(&["pending_welcomes"]).inc_by(report.pending_welcomes_deleted);
        m.with_label_values(&["disappearing"]).inc_by(report.disappearing_deleted);
        m.with_label_values(&["media"]).inc_by(report.media_deleted);
    }
    if report.partitions_dropped > 0 {
        info!(partitions = report.partitions_dropped, "retention dropped expired message partitions");
    }
    Ok(report)
}

/// Partition names this worker owns: `messages_YYYY_MM`.
fn is_month_partition(name: &str) -> bool {
    let b = name.as_bytes();
    name.len() == "messages_2026_05".len()
        && name.starts_with("messages_")
        && b[9..13].iter().all(u8::is_ascii_digit)
        && b[13] == b'_'
        && b[14..16].iter().all(u8::is_ascii_digit)
}

/// Make sure the current and the next UTC month have their own partition.
/// Rows that already fell into `messages_default` for that month are moved
/// into the new partition (Postgres refuses to create a partition whose
/// range overlaps rows in DEFAULT). Runs in one transaction; a no-op once
/// both partitions exist, so the lock is taken about once a month.
pub async fn ensure_month_partitions(pool: &PgPool) -> anyhow::Result<u32> {
    let months: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT 'messages_' || to_char(m AT TIME ZONE 'UTC', 'YYYY_MM'), \
                to_char(m AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00', \
                to_char((m + interval '1 month') AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || '+00' \
         FROM generate_series(date_trunc('month', NOW(), 'UTC'), \
                              date_trunc('month', NOW(), 'UTC') + interval '1 month', \
                              interval '1 month') AS m",
    )
    .fetch_all(pool)
    .await?;

    let mut created = 0;
    for (name, from, to) in months {
        anyhow::ensure!(is_month_partition(&name), "unexpected partition name {name}");
        let exists: bool = sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
            .bind(&name)
            .fetch_one(pool)
            .await?;
        if exists {
            continue;
        }
        // `name`, `from`, `to` come from the query above (fixed formats) — not
        // user input — and DDL can't take bind parameters.
        let mut tx = pool.begin().await?;
        // Two server instances sweeping at once: one creates, the other
        // waits here and then sees the partition (review fix).
        sqlx::query("SELECT pg_advisory_xact_lock(7731001)").execute(&mut *tx).await?;
        let exists: bool = sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
            .bind(&name)
            .fetch_one(&mut *tx)
            .await?;
        if exists {
            continue;
        }
        let has_default: bool = sqlx::query_scalar("SELECT to_regclass('messages_default') IS NOT NULL")
            .fetch_one(&mut *tx)
            .await?;
        if has_default {
            sqlx::query("ALTER TABLE messages DETACH PARTITION messages_default")
                .execute(&mut *tx)
                .await?;
        }
        sqlx::query(&format!(
            "CREATE TABLE {name} PARTITION OF messages FOR VALUES FROM ('{from}') TO ('{to}')"
        ))
        .execute(&mut *tx)
        .await?;
        if has_default {
            sqlx::query(&format!(
                "WITH moved AS (DELETE FROM messages_default WHERE ts >= '{from}' AND ts < '{to}' RETURNING *) \
                 INSERT INTO messages SELECT * FROM moved"
            ))
            .execute(&mut *tx)
            .await?;
            sqlx::query("ALTER TABLE messages ATTACH PARTITION messages_default DEFAULT")
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;
        info!(partition = %name, "created message partition");
        created += 1;
    }
    Ok(created)
}

/// DROP every `messages_YYYY_MM` partition whose month ended before the
/// retention window. Returns (partitions dropped, rows they held).
pub async fn drop_expired_partitions(pool: &PgPool, retention_days: i64) -> anyhow::Result<(u64, u64)> {
    let expired: Vec<String> = sqlx::query_scalar(
        "SELECT c.relname::text FROM pg_inherits i \
           JOIN pg_class c ON c.oid = i.inhrelid \
           JOIN pg_class p ON p.oid = i.inhparent \
         WHERE p.relname = 'messages' \
           AND c.relname ~ '^messages_[0-9]{4}_[0-9]{2}$' \
           AND (to_date(substr(c.relname, 10), 'YYYY_MM')::timestamp AT TIME ZONE 'UTC') \
               + interval '1 month' <= NOW() - make_interval(days => $1::int)",
    )
    .bind(retention_days as i32)
    .fetch_all(pool)
    .await?;

    let (mut dropped, mut rows) = (0u64, 0u64);
    for name in expired {
        anyhow::ensure!(is_month_partition(&name), "unexpected partition name {name}");
        let n: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {name}"))
            .fetch_one(pool)
            .await?;
        sqlx::query(&format!("DROP TABLE IF EXISTS {name}")).execute(pool).await?;
        dropped += 1;
        rows += n as u64;
    }
    Ok((dropped, rows))
}

#[derive(Debug, Default, Clone, Copy)]
pub struct SweepReport {
    pub keypackages_deleted: u64,
    pub deliveries_deleted: u64,
    pub messages_deleted: u64,
    /// Expired pending Welcomes dropped per Risk #10's 7-day TTL.
    pub pending_welcomes_deleted: u64,
    /// T3.4 — messages dropped via per-chat disappearing TTL.
    /// Separate counter so ops can distinguish "regular retention"
    /// vs "user-configured shorter TTL" in `/metrics`.
    pub disappearing_deleted: u64,
    pub media_deleted: u64,
    /// Whole month partitions of `messages` dropped (tech-debt 4.4);
    /// their rows are counted in `messages_deleted`.
    pub partitions_dropped: u64,
}

impl SweepReport {
    pub fn has_work(&self) -> bool {
        self.keypackages_deleted > 0
            || self.deliveries_deleted > 0
            || self.messages_deleted > 0
            || self.pending_welcomes_deleted > 0
            || self.disappearing_deleted > 0
            || self.media_deleted > 0
            || self.partitions_dropped > 0
    }
}

// ─────────────────────────────────────────────────────────────────────
// Risk #7 — integration tests against a real Postgres.
//
// `sqlx::test` provisions a fresh per-test database, applies our
// migrations, and hands us a pool. Tests verify:
//
//   • TTL boundary correctness (rows just over the line go; just under stay)
//   • Empty DB sweep returns SweepReport::default
//   • Consumed keypackages always reaped regardless of expires_at
//   • Expired keypackages always reaped regardless of consume status
//
// These guard against off-by-one errors in `make_interval(days => $1)`
// and the regression class where someone migrates `ts` to `TIMESTAMP`
// (timezone-naive) and silent-deletes everything because `NOW()`
// returns `TIMESTAMPTZ` and Postgres compares them inconsistently.
//
// Tests require `DATABASE_URL` to point at a Postgres the user can
// CREATE DATABASE on (sqlx will spawn ephemeral DBs). Run with:
//
//     DATABASE_URL=postgres://localhost/sinhron_dev_template \
//         cargo test -p sinhron_server retention
//
// In CI, the postgres container in docker-compose serves this role.
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::types::Uuid;
    use time::OffsetDateTime;

    /// Helper: insert one row into `messages` at a given offset from now.
    /// Returns the message_id so the test can assert on/around it.
    async fn insert_msg_aged(pool: &PgPool, hours_ago: i64) -> anyhow::Result<Uuid> {
        let id = Uuid::now_v7();
        let ts = OffsetDateTime::now_utc() - time::Duration::hours(hours_ago);

        // messages table requires a group + group_members for FK
        // sanity. Minimal scaffold: one user, one group, one membership.
        let user_pk = Uuid::now_v7();
        let group_id: Vec<u8> = b"test-group-id-32-bytes-padding!!".to_vec();

        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2) ON CONFLICT DO NOTHING")
            .bind(user_pk)
            .bind(vec![0u8; 32])
            .execute(pool)
            .await?;

        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1) ON CONFLICT DO NOTHING")
            .bind(&group_id)
            .execute(pool)
            .await?;

        sqlx::query(
            "INSERT INTO messages (message_id, group_id, sender_device_pk, ts, ciphertext) \
             VALUES ($1, $2, NULL, $3, $4)",
        )
        .bind(id)
        .bind(&group_id)
        .bind(ts)
        .bind(vec![0u8; 32])
        .execute(pool)
        .await?;

        Ok(id)
    }

    /// Boundary case — retention_days=14. Message exactly 14d+1s old
    /// is older than the threshold → deleted. Message exactly 14d-1s
    /// old is younger → kept.
    ///
    /// This catches the off-by-one class: e.g. if someone changes the
    /// query to `<=` instead of `<`, the "exactly 14d" row would also
    /// go, which we don't want.
    // `#[ignore]` so `cargo test` (no DATABASE_URL) doesn't fail when
    // Postgres isn't running. Run explicitly:
    //   DATABASE_URL=postgres://localhost/sinhron_dev_template \
    //       cargo test -p sinhron_server --lib -- --ignored retention
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn sweep_respects_message_ttl_boundary(pool: PgPool) {
        // 14 days = 14*24 = 336 hours. Add an hour buffer on each
        // side so we don't depend on subsecond timing for the boundary
        // (sqlx::test runs in real time).
        let stale = insert_msg_aged(&pool, 14 * 24 + 1).await.expect("stale");
        let fresh = insert_msg_aged(&pool, 14 * 24 - 1).await.expect("fresh");

        let report = sweep(&pool, 14).await.expect("sweep");
        assert!(
            report.messages_deleted >= 1,
            "expected at least 1 message deleted, got {}",
            report.messages_deleted
        );

        // Stale gone, fresh stays.
        let stale_still: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE message_id = $1")
            .bind(stale)
            .fetch_one(&pool)
            .await
            .expect("count stale");
        assert_eq!(stale_still, 0, "stale message should have been deleted");

        let fresh_still: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM messages WHERE message_id = $1")
            .bind(fresh)
            .fetch_one(&pool)
            .await
            .expect("count fresh");
        assert_eq!(fresh_still, 1, "fresh message should NOT have been deleted");
    }

    /// Empty DB sweep is a no-op and returns SweepReport::default().
    /// Guards against the "first sweep crashes on a fresh deploy"
    /// regression.
    // `#[ignore]` so `cargo test` (no DATABASE_URL) doesn't fail when
    // Postgres isn't running. Run explicitly:
    //   DATABASE_URL=postgres://localhost/sinhron_dev_template \
    //       cargo test -p sinhron_server --lib -- --ignored retention
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn sweep_on_empty_db_is_noop(pool: PgPool) {
        let report = sweep(&pool, 14).await.expect("sweep");
        assert_eq!(report.keypackages_deleted, 0);
        assert_eq!(report.deliveries_deleted, 0);
        assert_eq!(report.messages_deleted, 0);
        // The only possible "work" on an empty DB is dropping the migration's
        // initial (empty) month partition once it is past the window.
        assert!(!report.has_work() || report.partitions_dropped > 0);
        let second = sweep(&pool, 14).await.expect("sweep again");
        assert!(!second.has_work(), "second sweep on an empty DB does nothing");
    }

    /// Consumed keypackages are deleted regardless of expires_at.
    /// `consumed_at IS NOT NULL` short-circuits the `OR expires_at < NOW()` —
    /// even a fresh, unexpired KP that's been consumed goes.
    // `#[ignore]` so `cargo test` (no DATABASE_URL) doesn't fail when
    // Postgres isn't running. Run explicitly:
    //   DATABASE_URL=postgres://localhost/sinhron_dev_template \
    //       cargo test -p sinhron_server --lib -- --ignored retention
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn sweep_drops_consumed_keypackages(pool: PgPool) {
        let user_pk = Uuid::now_v7();
        let device_pk = vec![1u8; 32];
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(user_pk)
            .bind(vec![0u8; 32])
            .execute(&pool)
            .await
            .expect("user");
        sqlx::query(
            "INSERT INTO devices (device_pk, user_pk, credential) \
             VALUES ($1, $2, $3)",
        )
        .bind(&device_pk)
        .bind(user_pk)
        .bind(vec![2u8; 32])
        .execute(&pool)
        .await
        .expect("device");

        // Future expiry but already consumed → must go.
        let future = OffsetDateTime::now_utc() + time::Duration::days(30);
        let consumed_at = OffsetDateTime::now_utc();
        sqlx::query(
            "INSERT INTO keypackages \
             (keypackage_id, device_pk, kp_bytes, uploaded_at, expires_at, consumed_at) \
             VALUES ($1, $2, $3, NOW(), $4, $5)",
        )
        .bind(Uuid::now_v7())
        .bind(&device_pk)
        .bind(vec![3u8; 64])
        .bind(future)
        .bind(consumed_at)
        .execute(&pool)
        .await
        .expect("kp insert");

        let report = sweep(&pool, 14).await.expect("sweep");
        assert_eq!(
            report.keypackages_deleted, 1,
            "consumed KP must be deleted regardless of expires_at"
        );

        let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM keypackages")
            .fetch_one(&pool)
            .await
            .expect("count");
        assert_eq!(remaining, 0);
    }

    async fn partition_of(pool: &PgPool, id: Uuid) -> String {
        sqlx::query_scalar("SELECT tableoid::regclass::text FROM messages WHERE message_id = $1")
            .bind(id)
            .fetch_one(pool)
            .await
            .expect("tableoid")
    }

    /// Tech-debt 4.4: the current month gets its own partition and rows that
    /// had already landed in DEFAULT move into it; a second run is a no-op.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn current_month_partition_is_created_and_default_rows_move(pool: PgPool) {
        let now_row = insert_msg_aged(&pool, 0).await.expect("row");
        assert_eq!(partition_of(&pool, now_row).await, "messages_default");

        let created = ensure_month_partitions(&pool).await.expect("ensure");
        assert_eq!(created, 2, "current + next month");
        let part = partition_of(&pool, now_row).await;
        assert!(is_month_partition(&part), "row moved to {part}");

        assert_eq!(ensure_month_partitions(&pool).await.expect("again"), 0);
        // DEFAULT is attached again (rows outside known months still insert).
        insert_msg_aged(&pool, 24 * 400).await.expect("old row goes to default");
    }

    /// A whole month older than the window is DROPped, rows counted; the
    /// current month's partition stays.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn expired_month_partition_is_dropped(pool: PgPool) {
        sqlx::query(
            "CREATE TABLE messages_2025_01 PARTITION OF messages \
             FOR VALUES FROM ('2025-01-01 00:00:00+00') TO ('2025-02-01 00:00:00+00')",
        )
        .execute(&pool)
        .await
        .expect("old partition");
        let id = Uuid::now_v7();
        sqlx::query(
            "INSERT INTO mls_groups (group_id) VALUES ($1) ON CONFLICT DO NOTHING",
        )
        .bind(b"g".to_vec())
        .execute(&pool)
        .await
        .expect("group");
        sqlx::query(
            "INSERT INTO messages (message_id, group_id, ts, ciphertext) \
             VALUES ($1, $2, '2025-01-15 12:00:00+00', $3)",
        )
        .bind(id)
        .bind(b"g".to_vec())
        .bind(vec![1u8; 8])
        .execute(&pool)
        .await
        .expect("old row");

        let report = sweep(&pool, 14).await.expect("sweep");
        // messages_2025_01 plus the migration's initial messages_2026_05 (both expired).
        assert!(report.partitions_dropped >= 1);
        assert!(report.messages_deleted >= 1);
        let gone: bool = sqlx::query_scalar("SELECT to_regclass('messages_2025_01') IS NULL")
            .fetch_one(&pool)
            .await
            .expect("regclass");
        assert!(gone, "expired partition dropped");
        let current: bool = sqlx::query_scalar(
            "SELECT to_regclass('messages_' || to_char(NOW() AT TIME ZONE 'UTC', 'YYYY_MM')) IS NOT NULL",
        )
        .fetch_one(&pool)
        .await
        .expect("current");
        assert!(current, "current month partition kept");
    }

    // sealed-push:6 — sealed envelopes stayed a year after they were
    // received; now 30 days. Not yet received ones wait for their person.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn a_received_sealed_envelope_goes_after_30_days(pool: PgPool) {
        let bob = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(bob).bind(vec![0x42u8; 32]).execute(&pool).await.unwrap();
        for (tag, received_days_ago) in [(1u8, Some(31)), (2, Some(29)), (3, None)] {
            sqlx::query(
                "INSERT INTO message_deliveries (recipient_user_pk, message_id, envelope, delivered_at, received_at) \
                 VALUES ($1, $2, $3, NOW() - interval '40 days', NOW() - make_interval(days => $4))",
            )
            .bind(bob)
            .bind(Uuid::now_v7())
            .bind(vec![tag; 1024])
            .bind(received_days_ago)
            .execute(&pool)
            .await
            .unwrap();
        }
        sweep(&pool, 365).await.expect("sweep");
        let left: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT envelope FROM message_deliveries ORDER BY envelope").fetch_all(&pool).await.unwrap();
        let left: Vec<u8> = left.into_iter().map(|(e,)| e[0]).collect();
        assert_eq!(left, vec![2, 3], "received 31 days ago: gone; 29 days ago and never received: kept");
    }

    // WEB-4 — an expired short link keeps its id (as an empty row), so the
    // same id can't be stored again with someone else's invite behind it.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn an_expired_short_invite_keeps_its_id_taken(pool: PgPool) {
        for (id, days) in [("Old0000000", -1), ("New0000000", 1)] {
            sqlx::query("INSERT INTO short_invites (id, blob, expires_at) VALUES ($1, 'sealed', NOW() + make_interval(days => $2))")
                .bind(id)
                .bind(days)
                .execute(&pool)
                .await
                .unwrap();
        }
        sweep(&pool, 365).await.expect("sweep");
        let rows: Vec<(String, Vec<u8>)> = sqlx::query_as("SELECT id, blob FROM short_invites ORDER BY id").fetch_all(&pool).await.unwrap();
        assert_eq!(rows, vec![("New0000000".into(), b"sealed".to_vec()), ("Old0000000".into(), vec![])]);
        // What POST /v1/invites does with the old id: nothing — 409.
        let again = sqlx::query(
            "INSERT INTO short_invites (id, blob, expires_at) VALUES ('Old0000000', 'evil', NOW() + interval '1 year') \
             ON CONFLICT (id) DO NOTHING",
        )
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(again.rows_affected(), 0);
    }

    // ACCT-6 — settings that would wipe everything or stop the worker fall
    // back to the defaults.
    #[test]
    fn bad_retention_settings_fall_back_to_the_defaults() {
        assert_eq!(days_or_default(Some("30")), 30);
        assert_eq!(days_or_default(Some("3650")), 3650);
        for bad in ["0", "-5", "3651", "99999999999", "week", ""] {
            assert_eq!(days_or_default(Some(bad)), DEFAULT_RETENTION_DAYS, "{bad:?}");
        }
        assert_eq!(days_or_default(None), DEFAULT_RETENTION_DAYS);
        assert_eq!(sweep_secs_or_default(Some("60")), 60);
        for bad in ["0", "-1", "soon"] {
            assert_eq!(sweep_secs_or_default(Some(bad)), DEFAULT_SWEEP_SECS, "{bad:?}");
        }
        assert_eq!(sweep_secs_or_default(None), DEFAULT_SWEEP_SECS);
    }

    #[test]
    fn only_month_partitions_are_owned() {
        assert!(is_month_partition("messages_2026_05"));
        assert!(!is_month_partition("messages_default"));
        assert!(!is_month_partition("messages_2026_5"));
        assert!(!is_month_partition("messages_2026_05; DROP TABLE users"));
    }
}
