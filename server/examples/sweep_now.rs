// Run one retention sweep on demand. Useful for integration smoke +
// future admin-CLI tooling. NOT a production endpoint — the running
// server already sweeps periodically; this just gives an out-of-band
// way to trigger one in test scenarios.
//
// Usage:
//   SINHRON_DB_URL=... cargo run --example sweep_now [retention_days]

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let retention_days: i64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(14);

    let url = std::env::var("SINHRON_DB_URL")
        .map_err(|_| anyhow::anyhow!("SINHRON_DB_URL must be set"))?;
    let pool = sinhron_server::db::connect_pool(&url).await?;
    let report = sinhron_server::retention::sweep(&pool, retention_days).await?;
    println!(
        "sweep · retention_days={retention_days} · keypackages={} · deliveries={} · messages={}",
        report.keypackages_deleted, report.deliveries_deleted, report.messages_deleted
    );
    Ok(())
}
