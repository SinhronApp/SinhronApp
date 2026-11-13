// WEB-1 — a server whose startup migration failed must not serve on the old
// schema (and `/_readyz` must not say "ready"): it exits, Docker restarts it.

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[test]
fn a_failed_startup_migration_stops_the_server() {
    let mut server = Command::new(env!("CARGO_BIN_EXE_sinhron-server"))
        .env("SINHRON_DB_URL", "postgres://sinhron:x@127.0.0.1:1/sinhron") // nothing listens there
        .env_remove("SINHRON_DB_MIGRATE_URL")
        .env_remove("LIVEKIT_URL")
        .env("SINHRON_PG_ACQUIRE_TIMEOUT_SECS", "1")
        .env("SINHRON_LISTEN", "127.0.0.1:0")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let started = Instant::now();
    while started.elapsed() < Duration::from_secs(15) {
        if let Some(status) = server.try_wait().unwrap() {
            assert!(!status.success(), "must exit with an error");
            return;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    server.kill().unwrap();
    panic!("the server kept serving after its migration failed");
}
