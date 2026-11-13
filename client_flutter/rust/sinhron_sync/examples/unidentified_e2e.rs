// Tech-debt 2.2 end-to-end — sealed sender without the sender's
// connection, through a real server (SINHRON_E2E_HTTP, default
// http://127.0.0.1:8080).
//
//   1. Alice and Bob publish delivery keys + the hash of their access key.
//   2. Bob gives Alice his access key inside MLS (an `Access` message).
//   3. Alice seals a message for Bob and posts it to POST /v1/sealed with
//      NO authentication — a plain HTTP request carrying Bob's key.
//   4. Bob gets a Push with no group, opens it: right group, plaintext and
//      Alice as the sender (MLS still authenticates her to Bob).
//   5. A wrong access key is refused.
//
// Usage: cargo run --example unidentified_e2e

use std::time::Duration;

use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::envelope::{decode_message, encode_access, Decoded};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::time::timeout;

const ALICE_PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon art";
const BOB_PHRASE: &str = "legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth title";

fn http_url() -> String {
    std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string())
}
fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

async fn connect(c: &SyncClient) -> anyhow::Result<WsClient> {
    let ws = WsClient::start(WsClientConfig {
        url: format!("{}/v1/sync", http_url().replacen("http", "ws", 1)),
        identity_seed: c.login_seed_bytes(),
        tls: None,
        resume_cursor: None,
    });
    match timeout(Duration::from_secs(10), ws.recv()).await? {
        Some(Event::Connected) => Ok(ws),
        other => anyhow::bail!("expected Connected, got {other:?}"),
    }
}

async fn wait_for<T>(ws: &WsClient, mut pick: impl FnMut(Body) -> Option<T>) -> anyhow::Result<T> {
    loop {
        match timeout(Duration::from_secs(15), ws.recv()).await? {
            Some(Event::Frame(WsFrame { body: Some(b), .. })) => {
                if let Some(t) = pick(b) {
                    return Ok(t);
                }
            }
            Some(Event::Disconnected { reason }) => anyhow::bail!("disconnected: {reason}"),
            None => anyhow::bail!("ws closed"),
            _ => {}
        }
    }
}

async fn publish(http: &HttpApi, c: &SyncClient) -> anyhow::Result<()> {
    let keys: Vec<(u32, Vec<u8>)> = c.delivery_keys_to_publish(now())?.into_iter().map(|k| (k.week, k.public)).collect();
    http.publish_sealed_keys(c.identity_seed_bytes(), &keys, Some((c.access_hash(), c.access_version())), None).await?;
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("→ unidentified_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut alice = SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: None })?;
    let mut bob = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: None })?;
    alice.bootstrap_with_server(&http).await?;
    bob.bootstrap_with_server(&http).await?;
    publish(&http, &alice).await?;
    publish(&http, &bob).await?;
    let alice_ws = connect(&alice).await?;
    let bob_ws = connect(&bob).await?;

    // A chat.
    let group = alice.create_group()?;
    let invite = alice.fetch_kp_and_invite(&http, &group, &bob.identity_pubkey_hex()).await?;
    alice_ws
        .send(WsFrame {
            frame_id: "w".into(),
            body: Some(Body::Welcome(Welcome {
                recipient_identity_pubkey: hex::decode(bob.identity_pubkey_hex())?,
                group_id: group.clone(),
                welcome_bytes: invite.welcome_bytes,
                sent_at: now() as i64,
                recipient_device_pks: vec![],
            })),
        })
        .await?;
    let w = wait_for(&bob_ws, |b| match b {
        Body::Welcome(w) => Some(w.welcome_bytes),
        _ => None,
    })
    .await?;
    bob.join_via_welcome(&w)?;

    // Bob → Alice: his access key, inside MLS (the ordinary route).
    let id = uuid::Uuid::now_v7().to_string();
    bob_ws
        .send(WsFrame {
            frame_id: id.clone(),
            body: Some(Body::Submit(Submit {
                group_id: group.clone(),
                ciphertext: bob.encrypt(&group, &encode_access(&bob.access_key()))?,
                message_id: id,
                sealed_sender: false,
                is_commit: false,
                commit_epoch: 0,
                urgent: false,
                access_keys: Vec::new(),
                refused_commit_ids: Vec::new(),
                parent_commit_id: String::new(),
            })),
        })
        .await?;
    let g = group.clone();
    let p = wait_for(&alice_ws, |b| match b {
        Body::Push(p) if p.group_id == g => Some(p),
        _ => None,
    })
    .await?;
    let (m, _) = alice.decrypt_with_sender(&group, &p.ciphertext)?;
    let IncomingMessage::App(bytes) = m else { anyhow::bail!("expected the access message") };
    let Decoded::Access { key: bob_access } = decode_message(&bytes)?.decoded else { anyhow::bail!("not an access key") };
    anyhow::ensure!(bob_access == bob.access_key().to_vec());
    println!("✓ Alice has Bob's access key (sent inside MLS)");

    // Alice → Bob, no authentication.
    let week = sinhron_sync::sealed::week_of(now());
    let (_, _, bob_pk, signed) = http
        .fetch_sealed_keys(&[bob.identity_pubkey_hex()])
        .await?
        .into_iter()
        .find(|(_, w, ..)| *w == week)
        .ok_or_else(|| anyhow::anyhow!("no key for this week"))?;
    anyhow::ensure!(signed, "Bob's delivery key carries his signature (ADR-082)");
    let ct = alice.encrypt(&group, b"nobody knows who sent this")?;
    let sealed = alice.seal_for(&group, &ct, &[bob_pk])?;
    let items: Vec<([u8; 16], Vec<u8>, Vec<u8>)> = sealed.iter().map(|(k, e)| (*k, e.clone(), bob_access.clone())).collect();
    let mid = uuid::Uuid::now_v7().to_string();

    let wrong: Vec<_> = items.iter().map(|(k, e, _)| (*k, e.clone(), vec![0u8; 16])).collect();
    anyhow::ensure!(http.submit_sealed_anonymous(&mid, &wrong, 0, &[], &[], 0).await? == (0, 1), "a wrong access key is refused");
    anyhow::ensure!(http.submit_sealed_anonymous(&mid, &items, 0, &[], &[], 0).await? == (1, 0), "Bob's access key is accepted");
    println!("✓ posted to /v1/sealed without authentication");

    // Rotation (tech-debt 2.2): Bob resets his key → the old one Alice
    // holds is refused at once; the new one (shared again) works.
    bob.set_access_version(1);
    let keys: Vec<(u32, Vec<u8>)> = bob.delivery_keys_to_publish(now())?.into_iter().map(|k| (k.week, k.public)).collect();
    anyhow::ensure!(http.publish_sealed_keys(bob.identity_seed_bytes(), &keys, Some((bob.access_hash(), 1)), None).await? == 1);
    let again = uuid::Uuid::now_v7().to_string();
    anyhow::ensure!(http.submit_sealed_anonymous(&again, &items, 0, &[], &[], 0).await? == (0, 1), "the rotated-out key is refused");
    let fresh: Vec<_> = items.iter().map(|(k, e, _)| (*k, e.clone(), bob.access_key().to_vec())).collect();
    anyhow::ensure!(http.submit_sealed_anonymous(&again, &fresh, 0, &[], &[], 0).await? == (1, 0), "the new key works");
    println!("✓ access key rotated: old refused, new accepted");

    let p = wait_for(&bob_ws, |b| match b {
        Body::Push(p) if !p.sealed_key_id.is_empty() => Some(p),
        _ => None,
    })
    .await?;
    anyhow::ensure!(p.group_id.is_empty(), "no group on the wire");
    let (gid, m, sender) = bob.open_sealed(&p.sealed_key_id, &p.ciphertext, now())?;
    anyhow::ensure!(gid == group);
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"nobody knows who sent this"), "got {m:?}");
    anyhow::ensure!(sender.as_deref() == Some(hex::decode(alice.identity_pubkey_hex())?.as_slice()), "Bob still knows it's Alice");
    println!("✓ Bob opened it: right chat, right text, from Alice");

    alice_ws.shutdown();
    bob_ws.shutdown();
    println!("\n🎯 unidentified_e2e · sealed sender without the sender's connection ✓");
    Ok(())
}
