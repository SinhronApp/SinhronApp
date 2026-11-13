// PostgreSQL connection + migration runner.
//
// WU A2 — initial schema lands here. `sqlx::migrate!` reads everything
// under `migrations/` at compile time and embeds it in the binary, so
// `docker run sinhron-server` is a single-binary deploy (no separate
// `sqlx-cli` step needed in production).

use std::time::Duration;

use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
use sqlx::PgPool;
use tracing::{info, warn};

/// Default pool size — matches typical Axum/tokio worker-thread count.
/// Override via `SINHRON_PG_MAX_CONNS` env var when tuning for load.
const DEFAULT_PG_MAX_CONNS: u32 = 16;

/// Default acquire timeout — how long a handler waits for a free
/// connection before giving up with 503. Short by design: we'd rather
/// fail fast and let the client retry than queue indefinitely under
/// load. Override via `SINHRON_PG_ACQUIRE_TIMEOUT_SECS`.
const DEFAULT_PG_ACQUIRE_TIMEOUT_SECS: u64 = 5;

/// Construct a PgPool from a Postgres connection URL. The URL is the
/// canonical libpq form: `postgres://user:pass@host:port/db?sslmode=...`.
///
/// Risk #9 — connection pool sizing is tunable via env:
///
///   * `SINHRON_PG_MAX_CONNS`           (default 16)
///   * `SINHRON_PG_ACQUIRE_TIMEOUT_SECS` (default 5)
///
/// Sizing guidance:
///   • 1-10 concurrent users → default 16 is plenty
///   • 100 concurrent users  → bump to 32-64; watch Postgres `max_connections`
///   • 1000+ concurrent users → consider pgbouncer in front + per-app
///     pool of ~32. Pgbouncer is also the right answer if you run
///     multiple server replicas (each with its own pool).
pub async fn connect_pool(database_url: &str) -> anyhow::Result<PgPool> {
    let opts: PgConnectOptions = database_url
        .parse()
        .map_err(|e| anyhow::anyhow!("invalid SINHRON_DB_URL: {e}"))?;

    let max_conns = std::env::var("SINHRON_PG_MAX_CONNS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_PG_MAX_CONNS);
    let acquire_timeout = std::env::var("SINHRON_PG_ACQUIRE_TIMEOUT_SECS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_PG_ACQUIRE_TIMEOUT_SECS);

    let pool = PgPoolOptions::new()
        .max_connections(max_conns)
        .acquire_timeout(Duration::from_secs(acquire_timeout))
        // Lazy connect — server starts even if Postgres is briefly
        // unreachable. /_readyz reports the connection state honestly so
        // operators / k8s see "not ready yet" instead of crash-loop.
        .connect_lazy_with(opts);

    info!(
        max_conns,
        acquire_timeout_secs = acquire_timeout,
        "postgres pool created (lazy connect)"
    );
    Ok(pool)
}

/// Apply all pending migrations under `migrations/`. Idempotent — runs
/// only the unapplied ones. The migration runner uses an advisory lock
/// internally so concurrent server instances don't race.
pub async fn run_migrations(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::migrate!("./migrations")
        .run(pool)
        .await
        .map_err(|e| anyhow::anyhow!("migration failed: {e}"))?;
    info!("migrations applied");
    Ok(())
}

/// `/_readyz` probe — issues `SELECT 1` against the pool. k8s-style:
/// 200 OK means "happy to take traffic", 503 means "give me a moment".
/// Distinct from `/_healthz` which only proves the process is alive.
pub async fn ping(pool: &PgPool) -> anyhow::Result<()> {
    sqlx::query("SELECT 1")
        .execute(pool)
        .await
        .map(|_| ())
        .map_err(|e| {
            warn!(error = %e, "readyz ping failed");
            anyhow::anyhow!("postgres unreachable: {e}")
        })
}
