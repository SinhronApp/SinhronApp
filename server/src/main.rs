// Sinhron operator server — binary entry point.
//
// All routing / handlers / WS / DB live in the library crate
// (`src/lib.rs`); main is just a tokio bootstrap so integration tests
// and the `ws_client` example can pull in the internals via
// `sinhron_server::*`.
//
// `sinhron-server --healthcheck` probes a running server's `/_healthz`
// and exits 0/1 — the Docker healthcheck (the slim image has no wget).

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    if std::env::args().nth(1).as_deref() == Some("--healthcheck") {
        std::process::exit(sinhron_server::healthcheck::run_cli().await);
    }
    sinhron_server::run().await
}
