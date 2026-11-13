// Bootstrap smoke — drives `SyncClient::bootstrap_with_server` against
// a running operator server. Validates the wire format of the HTTP API
// against the server's expectations.
//
// Preconditions: server running on http://localhost:8080, postgres up.
//
// Usage:
//   cargo run --example bootstrap_smoke

use sinhron_sync::{HttpApi, SyncClient, SyncClientConfig};

const PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon art";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let base_url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "http://localhost:8080".to_string());

    println!("→ create SyncClient from phrase");
    // `mut` because bootstrap_with_server now takes &mut self
    // (Risk #3 fix — drops `unsafe impl Sync`).
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: PHRASE.to_string(),
        db_path: None, // in-memory: smoke test is single-process,
        device_seed: None,
    })?;
    println!("✓ identity_pubkey = {}", client.identity_pubkey_hex());

    let http = HttpApi::new(base_url);

    println!("→ bootstrap_with_server (register + publish KP)");
    let outcome = client.bootstrap_with_server(&http).await?;
    println!(
        "✓ first bootstrap: user_pk={} already_existed={} kp_id={}",
        outcome.user_pk, outcome.already_existed, outcome.keypackage_id
    );
    assert!(!outcome.already_existed, "expected first call to create new row");

    println!("→ bootstrap_with_server AGAIN (idempotent replay)");
    let outcome2 = client.bootstrap_with_server(&http).await?;
    println!(
        "✓ second bootstrap: user_pk={} already_existed={} kp_id={}",
        outcome2.user_pk, outcome2.already_existed, outcome2.keypackage_id
    );
    assert!(outcome2.already_existed, "expected replay to report existing");
    assert_eq!(outcome.user_pk, outcome2.user_pk, "user_pk must be stable");

    println!("→ consume one KP for this identity");
    let kps = http
        .fetch_device_keypackages(client.login_seed_bytes(), &client.identity_pubkey_hex(), &[])
        .await?;
    println!("✓ kp consumed · {} bytes", kps[0].1.len());

    println!("\n🎯 bootstrap_with_server end-to-end ✓");
    Ok(())
}
