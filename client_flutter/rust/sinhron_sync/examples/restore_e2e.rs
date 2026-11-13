// ADR-074 end-to-end: Bob lost his phone and signed in on a new one with
// his 24 words — his contacts add the new phone back into their chats.
// Through a real server (SINHRON_E2E_HTTP, default http://127.0.0.1:8080).
//
//   1. Alice and Bob's old phone bootstrap; Alice makes a chat with Bob.
//   2. The old phone goes silent. Bob's new phone (a linked device made
//      from the words: its own device key + certificate) bootstraps and
//      registers; it was never in Alice's chat.
//   3. Alice's device sync for other people: Bob's devices on the server →
//      the new one is missing → one KeyPackage for just that device →
//      checked to be Bob's → pending Commit → server orders it → announce →
//      a Welcome to Bob addressed to the new phone.
//   4. The new phone joins and sees it was added back by someone else (not
//      a new request).
//   5. Alice ↔ the new phone, both ways; the new phone writes as Bob.
//
// Usage: cargo run --example restore_e2e

use std::time::Duration;

use rand_core::{OsRng, RngCore};
use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::time::timeout;

const ALICE_PHRASE: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
const BOB_PHRASE: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";

fn http_url() -> String {
    std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string())
}
fn ws_url() -> String {
    format!("{}/v1/sync", http_url().replacen("http", "ws", 1))
}
fn unix() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

async fn connect(client: &SyncClient, who: &str) -> anyhow::Result<WsClient> {
    let ws = WsClient::start(WsClientConfig { url: ws_url(), identity_seed: client.login_seed_bytes(), tls: None, resume_cursor: None });
    match timeout(Duration::from_secs(10), ws.recv()).await? {
        Some(Event::Connected) => println!("{who} ✓ ws connected"),
        other => anyhow::bail!("{who}: expected Connected, got {other:?}"),
    }
    Ok(ws)
}

async fn wait_for<T>(ws: &WsClient, who: &str, mut pick: impl FnMut(Body) -> Option<T>) -> anyhow::Result<T> {
    loop {
        match timeout(Duration::from_secs(15), ws.recv()).await? {
            Some(Event::Frame(WsFrame { body: Some(b), .. })) => {
                let name = format!("{:?}", std::mem::discriminant(&b));
                if let Some(t) = pick(b) {
                    return Ok(t);
                }
                println!("{who} · skipped frame {name}");
            }
            Some(Event::Frame(_)) | Some(Event::Connected) => {}
            Some(Event::Disconnected { reason }) => anyhow::bail!("{who} disconnected: {reason}"),
            None => anyhow::bail!("{who}: ws closed"),
        }
    }
}

async fn ack(ws: &WsClient, who: &str, frame_id: &str) -> anyhow::Result<i32> {
    let id = frame_id.to_string();
    wait_for(ws, who, |b| match b {
        Body::Ack(a) if a.acked_frame_id == id => Some(a.error_code),
        _ => None,
    })
    .await
}

fn submit(group: &[u8], ciphertext: Vec<u8>, commit_epoch: Option<u64>) -> (String, WsFrame) {
    let id = uuid::Uuid::now_v7().to_string();
    let frame = WsFrame {
        frame_id: id.clone(),
        body: Some(Body::Submit(Submit {
            group_id: group.to_vec(),
            ciphertext,
            message_id: id.clone(),
            sealed_sender: false,
            is_commit: commit_epoch.is_some(),
            commit_epoch: commit_epoch.unwrap_or(0),
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        })),
    };
    (id, frame)
}

fn welcome(to: &[u8], group: &[u8], bytes: &[u8], devices: Vec<Vec<u8>>) -> WsFrame {
    WsFrame {
        frame_id: format!("welcome-{}", uuid::Uuid::now_v7()),
        body: Some(Body::Welcome(Welcome {
            recipient_identity_pubkey: to.to_vec(),
            group_id: group.to_vec(),
            welcome_bytes: bytes.to_vec(),
            sent_at: unix(),
            recipient_device_pks: devices,
        })),
    }
}

async fn next_message(
    ws: &WsClient,
    client: &mut SyncClient,
    who: &str,
    group: &[u8],
) -> anyhow::Result<(IncomingMessage, Option<Vec<u8>>)> {
    let g = group.to_vec();
    let p = wait_for(ws, who, |b| match b {
        Body::Push(p) if p.group_id == g => Some(p),
        _ => None,
    })
    .await?;
    Ok(client.decrypt_with_sender(group, &p.ciphertext)?)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("→ restore_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut alice = SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: None })?;
    let mut bob_old = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: None })?;
    alice.bootstrap_with_server(&http).await?;
    bob_old.bootstrap_with_server(&http).await?;
    let bob_hex = bob_old.identity_pubkey_hex();
    let bob: [u8; 32] = hex::decode(&bob_hex)?.try_into().map_err(|_| anyhow::anyhow!("identity len"))?;

    // 1. Alice's chat with Bob.
    let alice_ws = connect(&alice, "alice").await?;
    let old_ws = connect(&bob_old, "bob (old phone)").await?;
    let group = alice.create_group()?;
    let invite = alice.fetch_kp_and_invite(&http, &group, &bob_hex).await?;
    alice_ws.send(welcome(&bob, &group, &invite.welcome_bytes, vec![])).await?;
    let w = wait_for(&old_ws, "bob (old phone)", |b| match b {
        Body::Welcome(w) => Some(w.welcome_bytes),
        _ => None,
    })
    .await?;
    bob_old.join_via_welcome(&w)?;
    println!("✓ Alice and Bob have a chat");

    // 2. The old phone is gone; Bob signs in on a new one with his words.
    drop(old_ws);
    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    let mut bob_new = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: Some(seed) })?;
    bob_new.bootstrap_with_server(&http).await?;
    let new_pk = bob_new.device_public_key();
    let new_ws = connect(&bob_new, "bob (new phone)").await?;
    anyhow::ensure!(!alice.group_device_keys(&group, &bob)?.contains(&new_pk), "the new phone isn't in the chat");

    // 3. Alice's device sync for other people.
    let listed = http.list_devices(&bob_hex).await?;
    let present = alice.group_device_keys(&group, &bob)?;
    let missing: Vec<Vec<u8>> =
        listed.iter().filter_map(|d| hex::decode(&d.device_pk_hex).ok()).filter(|k| !present.contains(k)).collect();
    anyhow::ensure!(missing == vec![new_pk.clone()], "the server lists Bob's new phone as missing");
    let kps = http.fetch_device_keypackages(alice.login_seed_bytes(), &bob_hex, &missing).await?;
    let packages: Vec<([u8; 32], Vec<u8>)> = kps.into_iter().map(|(_, kp)| (bob, kp)).collect();
    let (pending, added) = alice.invite_devices_of_pending(&group, &packages)?;
    anyhow::ensure!(added == vec![(bob, new_pk.clone())], "exactly Bob's new phone, checked to be his");
    let (cid, frame) = submit(&group, pending.commit_bytes.clone(), Some(pending.epoch));
    alice_ws.send(frame).await?;
    anyhow::ensure!(ack(&alice_ws, "alice", &cid).await? == 0, "server ordered the commit");
    alice.confirm_commit(&group)?;
    let alice_device = alice.device_public_key();
    http.announce_group(alice.login_seed_bytes(), &group, alice.group_epoch(&group)?, &[alice_device.clone(), new_pk.clone()]).await?;
    alice_ws.send(welcome(&bob, &group, pending.welcome_bytes.as_deref().unwrap_or_default(), vec![new_pk.clone()])).await?;
    println!("✓ Alice added Bob's new phone");

    // 4. The new phone joins — added back, not a request.
    loop {
        let w = wait_for(&new_ws, "bob (new phone)", |b| match b {
            Body::Welcome(w) => Some(w.welcome_bytes),
            _ => None,
        })
        .await?;
        match bob_new.join_via_welcome(&w) {
            Ok(g) if g == group => break,
            Ok(_) => continue,
            Err(e) => println!("bob (new phone) · Welcome not for this device ({e})"),
        }
    }
    anyhow::ensure!(bob_new.added_back_by_someone_else(&group)?, "added back by Alice: Bob's chat, not a request");
    anyhow::ensure!(bob_new.group_epoch(&group)? == alice.group_epoch(&group)?, "same epoch");
    println!("✓ the new phone is in the chat (added back)");

    // 5. Both ways.
    let ct = alice.encrypt(&group, b"welcome back, Bob")?;
    let (id, f) = submit(&group, ct, None);
    alice_ws.send(f).await?;
    anyhow::ensure!(ack(&alice_ws, "alice", &id).await? == 0);
    let (m, sender) = next_message(&new_ws, &mut bob_new, "bob (new phone)", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::App(ref b) if b == b"welcome back, Bob"), "got {m:?}");
    anyhow::ensure!(sender.as_deref() == Some(hex::decode(alice.identity_pubkey_hex())?.as_slice()));
    println!("✓ Alice → the new phone");

    let ct = bob_new.encrypt(&group, b"thanks, I'm back")?;
    let (id, f) = submit(&group, ct, None);
    new_ws.send(f).await?;
    anyhow::ensure!(ack(&new_ws, "bob (new phone)", &id).await? == 0);
    let (m, sender) = next_message(&alice_ws, &mut alice, "alice", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::App(ref b) if b == b"thanks, I'm back"), "got {m:?}");
    anyhow::ensure!(sender.as_deref() == Some(bob.as_slice()), "the new phone writes as Bob");
    println!("✓ the new phone → Alice, as Bob");

    println!("✓ restore_e2e passed");
    Ok(())
}
