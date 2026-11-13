// Canonical end-to-end smoke: two SyncClients in one process, live over
// the real server protocol (HTTP + WebSocket). Validates that Alice can
// send Bob an MLS-encrypted message and Bob decrypts it back to the
// exact plaintext — the goal-completion criterion of spec §12.
//
// Without a physical-device test, this is the strongest validation we
// have that the full Sinhron stack is correct end-to-end:
//   • Identity registration over HTTP
//   • KeyPackage publish + fetch over HTTP
//   • WS auth handshake (Ed25519 challenge-response)
//   • MLS group creation + Welcome forwarding via WS frame
//   • MLS Add proposal → Welcome → join_via_welcome
//   • MLS encrypt → WS Submit → server fanout → WS Push → MLS decrypt
//
// Preconditions:
//   • `sinhron-server` running on http://localhost:8080 + ws://localhost:8080/v1/sync
//   • Empty (or doesn't-collide) sinhron_dev Postgres database
//
// Usage:
//   cargo run --example full_e2e

use std::time::Duration;

use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::sync::{mpsc, oneshot};
use tokio::time::timeout;

const ALICE_PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon art";
const BOB_PHRASE: &str = "legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth title";
const WS_URL: &str = "ws://localhost:8080/v1/sync";
const HTTP_URL: &str = "http://localhost:8080";
const PLAINTEXT: &[u8] = b"hello sinhron, this is real MLS over the wire";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("→ full_e2e starting · ws={WS_URL} http={HTTP_URL}");

    // Coordination channels:
    //   • alice waits for bob's identity_pubkey before inviting
    //   • bob signals done when the App message is decrypted
    let (bob_id_tx, bob_id_rx) = oneshot::channel::<String>();
    let (alice_done_tx, alice_done_rx) = oneshot::channel::<()>();

    let alice = tokio::spawn(async move {
        alice_task(bob_id_rx, alice_done_tx).await
    });
    let bob = tokio::spawn(async move {
        bob_task(bob_id_tx, alice_done_rx).await
    });

    // Bound the whole thing — if either task hangs, exit non-zero.
    let (alice_result, bob_result) = tokio::try_join!(
        async { Ok::<_, anyhow::Error>(timeout(Duration::from_secs(45), alice).await??) },
        async { Ok::<_, anyhow::Error>(timeout(Duration::from_secs(45), bob).await??) },
    )?;

    let plaintext_round_trip = alice_result?;
    let bob_decrypted = bob_result?;
    assert_eq!(
        plaintext_round_trip, bob_decrypted,
        "alice's plaintext must equal bob's decrypted"
    );
    println!("\n🎯 full_e2e end-to-end · MLS plaintext round-trip ✓");
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────
// Alice — group creator + sender
// ─────────────────────────────────────────────────────────────────────

async fn alice_task(
    bob_id_rx: oneshot::Receiver<String>,
    done_tx: oneshot::Sender<()>,
) -> anyhow::Result<Vec<u8>> {
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: ALICE_PHRASE.to_string(),
        db_path: None, // ephemeral — single-process e2e proof,
        device_seed: None,
    })?;
    let http = HttpApi::new(HTTP_URL.to_string());

    println!("alice → bootstrap_with_server");
    let boot = client.bootstrap_with_server(&http).await?;
    println!(
        "alice ✓ user_pk={} identity={}",
        boot.user_pk, boot.identity_pubkey_hex
    );

    // Derive seed for WS auth from the same phrase — sinhron_net's
    // WsClientConfig takes the raw 32-byte seed (not the phrase).
    let id =
        sinhron_crypto::identity::derive_identity(ALICE_PHRASE).map_err(|e| anyhow::anyhow!("{e}"))?;
    let ws = WsClient::start(WsClientConfig {
        url: WS_URL.to_string(),
        identity_seed: id.ed25519_secret,
        tls: None, // ws://localhost in this smoke
        resume_cursor: None,
    });

    // Wait for Connected event.
    expect_connected(&ws, "alice").await?;

    // Wait for Bob to publish his identity_pubkey so we can fetch his KP.
    let bob_identity_hex = bob_id_rx.await?;
    println!("alice ← bob_identity = {bob_identity_hex}");

    // MLS group create + invite Bob (HTTP fetch his KP + MLS Add).
    let group_id = client.create_group()?;
    println!("alice ✓ group_id = {}", hex::encode(&group_id));

    let outcome = client
        .fetch_kp_and_invite(&http, &group_id, &bob_identity_hex)
        .await?;
    println!(
        "alice ✓ invite outcome · commit={}B welcome={}B",
        outcome.commit_bytes.len(),
        outcome.welcome_bytes.len()
    );

    // Send the Welcome to Bob via the WS server.
    let welcome_frame = WsFrame {
        frame_id: "alice-welcome".to_string(),
        body: Some(Body::Welcome(Welcome {
            recipient_identity_pubkey: hex::decode(&bob_identity_hex)?,
            group_id: group_id.clone(),
            welcome_bytes: outcome.welcome_bytes.clone(),
            sent_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0),
            recipient_device_pks: vec![],
        })),
    };
    ws.send(welcome_frame).await?;
    println!("alice → Welcome dispatched via WS");

    // Brief pause so the server forwards and Bob processes the Welcome
    // before we send the encrypted app message.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Encrypt the app message via MLS and Submit via WS.
    let ciphertext = client.encrypt(&group_id, PLAINTEXT)?;
    let submit_frame = WsFrame {
        frame_id: "alice-submit-1".to_string(),
        body: Some(Body::Submit(Submit {
            group_id: group_id.clone(),
            ciphertext: ciphertext.clone(),
            message_id: uuid::Uuid::now_v7().to_string(),
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            sealed_sender: false, // T1.4 — non-sealed path still tested,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        })),
    };
    ws.send(submit_frame).await?;
    println!("alice → Submit dispatched · ciphertext_len={}", ciphertext.len());

    // Wait until Bob signals it's decrypted the message.
    done_tx.send(()).ok(); // signal Bob may shut down too
    ws.shutdown();
    Ok(PLAINTEXT.to_vec())
}

// ─────────────────────────────────────────────────────────────────────
// Bob — group joiner + receiver
// ─────────────────────────────────────────────────────────────────────

async fn bob_task(
    bob_id_tx: oneshot::Sender<String>,
    alice_done_rx: oneshot::Receiver<()>,
) -> anyhow::Result<Vec<u8>> {
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: BOB_PHRASE.to_string(),
        db_path: None, // ephemeral — single-process e2e proof,
        device_seed: None,
    })?;
    let http = HttpApi::new(HTTP_URL.to_string());

    println!("bob → bootstrap_with_server");
    let boot = client.bootstrap_with_server(&http).await?;
    println!(
        "bob ✓ user_pk={} identity={}",
        boot.user_pk, boot.identity_pubkey_hex
    );

    let id =
        sinhron_crypto::identity::derive_identity(BOB_PHRASE).map_err(|e| anyhow::anyhow!("{e}"))?;
    let ws = WsClient::start(WsClientConfig {
        url: WS_URL.to_string(),
        identity_seed: id.ed25519_secret,
        tls: None, // ws://localhost in this smoke
        resume_cursor: None,
    });
    expect_connected(&ws, "bob").await?;

    // Now signal alice with our identity so she can fetch the KP.
    bob_id_tx
        .send(client.identity_pubkey_hex())
        .map_err(|_| anyhow::anyhow!("alice dropped the bob_id channel"))?;

    let mut joined_group: Option<Vec<u8>> = None;
    let plaintext = loop {
        let event = timeout(Duration::from_secs(30), ws.recv())
            .await?
            .ok_or_else(|| anyhow::anyhow!("bob ws closed unexpectedly"))?;
        match event {
            Event::Connected => {} // already handled
            Event::Disconnected { reason } => {
                anyhow::bail!("bob disconnected: {reason}");
            }
            Event::Frame(f) => match f.body {
                Some(Body::Welcome(w)) => {
                    println!(
                        "bob ← Welcome group={} welcome_len={}",
                        hex::encode(&w.group_id),
                        w.welcome_bytes.len()
                    );
                    let gid = client.join_via_welcome(&w.welcome_bytes)?;
                    println!("bob ✓ joined group {}", hex::encode(&gid));
                    joined_group = Some(gid);
                }
                Some(Body::Push(p)) => {
                    let group = joined_group.as_ref().ok_or_else(|| {
                        anyhow::anyhow!("bob received Push without first joining a group")
                    })?;
                    println!(
                        "bob ← Push group={} ciphertext_len={}",
                        hex::encode(&p.group_id),
                        p.ciphertext.len()
                    );
                    let decoded = client.decrypt(group, &p.ciphertext)?;
                    match decoded {
                        IncomingMessage::App(bytes) => {
                            println!("bob ✓ decrypted plaintext: {:?}", String::from_utf8_lossy(&bytes));
                            break bytes;
                        }
                        other => {
                            println!("bob ← non-App {other:?}, continuing");
                        }
                    }
                }
                Some(Body::Ack(a)) => {
                    println!(
                        "bob ← Ack frame={} code={} msg={}",
                        a.acked_frame_id, a.error_code, a.error_message
                    );
                }
                other => {
                    println!("bob ← unhandled frame {:?}", other.as_ref().map(std::mem::discriminant));
                }
            },
        }
    };

    let _ = alice_done_rx.await; // hold until alice signals
    ws.shutdown();
    Ok(plaintext)
}

// ─────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────

async fn expect_connected(ws: &WsClient, who: &str) -> anyhow::Result<()> {
    let event = timeout(Duration::from_secs(10), ws.recv())
        .await?
        .ok_or_else(|| anyhow::anyhow!("{who}: ws closed before Connected"))?;
    match event {
        Event::Connected => {
            println!("{who} ✓ ws connected");
            Ok(())
        }
        Event::Disconnected { reason } => {
            anyhow::bail!("{who}: disconnected before connected — {reason}");
        }
        Event::Frame(_) => {
            anyhow::bail!("{who}: received a frame before Connected event");
        }
    }
}

// `mpsc` is imported for potential future use (multi-message tests).
#[allow(dead_code)]
fn _force_use(_: mpsc::Receiver<()>) {}
