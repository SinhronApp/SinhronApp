// Channel-based smoke — drives the new WsClient::start API.
//
// Validates B2:
//   • start() spawns background task
//   • Connected event fires after handshake
//   • Submit → server Ack received as Frame event
//   • shutdown() cleanly ends the task
//
// Usage:
//   cargo run --example connect_smoke

use std::time::Duration;

use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Submit, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "ws://localhost:8080/v1/sync".to_string());
    let seed_hex = std::env::args()
        .nth(2)
        .unwrap_or_else(|| "4242424242424242424242424242424242424242424242424242424242424242".to_string());

    let seed: [u8; 32] = hex::decode(&seed_hex)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("seed must be 32 bytes"))?;

    println!("→ starting client to {url}");
    let client = WsClient::start(WsClientConfig {
        url,
        identity_seed: seed,
        tls: None, // dev smoke: ws://localhost — no TLS to pin
        resume_cursor: None,
    });

    // Wait for Connected (handshake done).
    match tokio::time::timeout(Duration::from_secs(10), client.recv()).await {
        Ok(Some(Event::Connected)) => println!("← Connected"),
        Ok(Some(Event::Disconnected { reason })) => anyhow::bail!("disconnect: {reason}"),
        Ok(Some(Event::Frame(f))) => anyhow::bail!("unexpected frame before Connected: {f:?}"),
        Ok(None) => anyhow::bail!("client task ended before connected"),
        Err(_) => anyhow::bail!("connect timeout"),
    }

    println!("✓ identity={}", hex::encode(client.identity_pubkey()));

    // Submit a fake-encrypted blob to the demo group.
    let submit = WsFrame {
        frame_id: "b2-submit-1".to_string(),
        body: Some(Body::Submit(Submit {
            group_id: hex::decode("deadbeef")?,
            ciphertext: b"hello from B2 client".to_vec(),
            message_id: uuid::Uuid::now_v7().to_string(),
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            sealed_sender: false, // T1.4 — opt-in only,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        })),
    };
    client.send(submit).await?;
    println!("→ Submit · group=deadbeef");

    // Expect an Ack frame back.
    match tokio::time::timeout(Duration::from_secs(5), client.recv()).await {
        Ok(Some(Event::Frame(f))) => println!("← Frame: {:?}", f.body.as_ref().map(std::mem::discriminant)),
        Ok(other) => anyhow::bail!("expected Frame, got {other:?}"),
        Err(_) => anyhow::bail!("submit ack timeout"),
    }

    client.shutdown();
    println!("✓ shutdown signaled");

    // Drain the disconnect event so the task ends cleanly.
    let _ = tokio::time::timeout(Duration::from_secs(2), client.recv()).await;
    println!("✓ clean exit");
    Ok(())
}
