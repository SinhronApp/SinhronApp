// ADR-075 end-to-end: Bob loses his first phone (the one with the account
// key) and signs in on a new one with his 24 words — while Alice is
// offline. Through a real server (SINHRON_E2E_HTTP, default
// http://127.0.0.1:8080).
//
//   1. Alice and Bob's first phone make a chat; Alice leaves its card.
//   2. Alice goes offline. Bob's new phone (a device from the words)
//      registers.
//   3. The new phone fetches the chat's cards and joins by the one Bob's
//      first phone left (ADR-100: only a card signed by a device of his) —
//      an external commit, Alice is still away. Then it cuts the old phone
//      off with the words (signed by the account key); that one can't log
//      in any more. (Cut off first, the server no longer gives its card:
//      the new phone then waits for a member to add it, ADR-074.)
//   4. Alice comes back: she applies the join; her phone checks Bob's signed
//      revocation and takes the old phone's leaf out.
//   5. Alice ↔ the new phone, both ways; the old phone is out of the chat.
//
// Usage: cargo run --example rejoin_e2e

use std::time::Duration;

use rand_core::{OsRng, RngCore};
use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::time::timeout;

const ALICE_PHRASE: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";
const BOB_PHRASE: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";

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

fn welcome(to: &[u8], group: &[u8], bytes: &[u8]) -> WsFrame {
    WsFrame {
        frame_id: format!("welcome-{}", uuid::Uuid::now_v7()),
        body: Some(Body::Welcome(Welcome {
            recipient_identity_pubkey: to.to_vec(),
            group_id: group.to_vec(),
            welcome_bytes: bytes.to_vec(),
            sent_at: unix(),
            recipient_device_pks: vec![],
        })),
    }
}

async fn next_message(ws: &WsClient, client: &mut SyncClient, who: &str, group: &[u8]) -> anyhow::Result<(IncomingMessage, Option<Vec<u8>>)> {
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
    println!("→ rejoin_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut alice = SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: None })?;
    let mut bob_old = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: None })?;
    alice.bootstrap_with_server(&http).await?;
    bob_old.bootstrap_with_server(&http).await?;
    let bob_hex = bob_old.identity_pubkey_hex();
    let bob: [u8; 32] = hex::decode(&bob_hex)?.try_into().map_err(|_| anyhow::anyhow!("identity len"))?;
    let old_pk = bob_old.device_public_key();

    // 1. The chat; Alice leaves its card.
    let alice_ws = connect(&alice, "alice").await?;
    let old_ws = connect(&bob_old, "bob (first phone)").await?;
    let group = alice.create_group()?;
    let invite = alice.fetch_kp_and_invite(&http, &group, &bob_hex).await?;
    alice_ws.send(welcome(&bob, &group, &invite.welcome_bytes)).await?;
    let w = wait_for(&old_ws, "bob (first phone)", |b| match b {
        Body::Welcome(w) => Some(w.welcome_bytes),
        _ => None,
    })
    .await?;
    bob_old.join_via_welcome(&w)?;
    let (epoch, card) = alice.group_card(&group)?;
    http.put_group_card(alice.login_seed_bytes(), &group, epoch, &card).await?;
    // ADR-100 — Bob's phone leaves its own card: the only kind his new
    // phone will take (signed by a device of his).
    let (epoch, card) = bob_old.group_card(&group)?;
    http.put_group_card(bob_old.login_seed_bytes(), &group, epoch, &card).await?;
    println!("✓ Alice and Bob have a chat; its card is on the server (epoch {epoch})");

    // 2. Alice offline; the first phone lost. Bob's new phone, his words.
    drop(alice_ws);
    drop(old_ws);
    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    let mut bob_new = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: Some(seed) })?;
    bob_new.bootstrap_with_server(&http).await?;

    // 3. The new phone joins by the card — nobody else online.
    let new_ws = connect(&bob_new, "bob (new phone)").await?;
    let me: [u8; 32] = hex::decode(bob_new.identity_pubkey_hex())?.try_into().map_err(|_| anyhow::anyhow!("identity"))?;
    let cards = http.get_group_cards(bob_new.login_seed_bytes(), &group).await?;
    let mine: Vec<_> = cards.into_iter().filter(|c| c.identity == me).collect();
    let card = sinhron_sync::card_choice::cards_to_try(&mine, &me).into_iter().next().ok_or_else(|| anyhow::anyhow!("no card of my own device"))?;
    let (gid, pending) = bob_new.join_by_card(&group, &card)?;
    anyhow::ensure!(gid == group, "the card is this chat's");
    let (cid, frame) = submit(&group, pending.commit_bytes.clone(), Some(pending.epoch));
    new_ws.send(frame).await?;
    anyhow::ensure!(ack(&new_ws, "bob (new phone)", &cid).await? == 0, "the server ordered the join");
    let new_pk = bob_new.device_public_key();
    http.announce_group(bob_new.login_seed_bytes(), &group, bob_new.group_epoch(&group)?, &[new_pk.clone()]).await?;
    println!("✓ the new phone joined by the chat's card while Alice was away");

    // Now the lost phone is cut off with the words.
    let identity_secret = sinhron_crypto::identity::derive_identity(BOB_PHRASE)?.ed25519_secret;
    http.revoke_device(identity_secret, &old_pk).await?;
    println!("✓ the first phone cut off with the words");
    let old_try = WsClient::start(WsClientConfig { url: ws_url(), identity_seed: bob_old.login_seed_bytes(), tls: None, resume_cursor: None });
    match timeout(Duration::from_secs(10), old_try.recv()).await? {
        Some(Event::Connected) => anyhow::bail!("the cut-off first phone logged in"),
        other => println!("✓ the cut-off first phone can't log in ({other:?})"),
    }
    drop(old_try);

    // 4. Alice is back: the join was waiting for her; then she checks Bob's
    //    signed revocation and takes the old phone out.
    let alice_ws = connect(&alice, "alice").await?;
    let (m, _) = next_message(&alice_ws, &mut alice, "alice", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::Commit { .. }), "Alice applies Bob's join, got {m:?}");
    anyhow::ensure!(alice.group_device_keys(&group, &bob)?.contains(&new_pk), "Bob's new phone is in Alice's chat");
    let listed = http.list_devices_with_revoked(&bob_hex).await?;
    let lost = listed.iter().find(|d| d.revoked).ok_or_else(|| anyhow::anyhow!("the revoked phone is listed"))?;
    anyhow::ensure!(lost.device_pk_hex == hex::encode(&old_pk));
    anyhow::ensure!(
        sinhron_sync::http_api::revocation_is_signed(http.host(), &bob, &old_pk, lost.revoke_proof_ts, &lost.revoke_proof_hex),
        "Bob's account key signed it"
    );
    anyhow::ensure!(!sinhron_sync::http_api::revocation_is_signed(http.host(), &bob, &new_pk, lost.revoke_proof_ts, &lost.revoke_proof_hex), "for that device only");
    let gone = alice.remove_devices_pending(&group, &[old_pk.clone()])?;
    let (rid, frame) = submit(&group, gone.commit_bytes.clone(), Some(gone.epoch));
    alice_ws.send(frame).await?;
    anyhow::ensure!(ack(&alice_ws, "alice", &rid).await? == 0);
    alice.confirm_commit(&group)?;
    let (m, _) = next_message(&new_ws, &mut bob_new, "bob (new phone)", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::Commit { .. }), "the new phone applies the removal, got {m:?}");
    anyhow::ensure!(alice.group_device_keys(&group, &bob)? == vec![new_pk.clone()], "only the new phone is Bob's here");
    println!("✓ Alice's phone took the cut-off phone out (checked Bob's signature)");

    // 5. Both ways.
    let ct = alice.encrypt(&group, b"hi Bob, new phone?")?;
    let (id, f) = submit(&group, ct, None);
    alice_ws.send(f).await?;
    anyhow::ensure!(ack(&alice_ws, "alice", &id).await? == 0);
    let (m, _) = next_message(&new_ws, &mut bob_new, "bob (new phone)", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::App(ref b) if b == b"hi Bob, new phone?"), "got {m:?}");
    let ct = bob_new.encrypt(&group, b"yes, the old one is gone")?;
    let (id, f) = submit(&group, ct, None);
    new_ws.send(f).await?;
    anyhow::ensure!(ack(&new_ws, "bob (new phone)", &id).await? == 0);
    let (m, sender) = next_message(&alice_ws, &mut alice, "alice", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::App(ref b) if b == b"yes, the old one is gone"), "got {m:?}");
    anyhow::ensure!(sender.as_deref() == Some(bob.as_slice()));
    println!("✓ Alice ↔ the new phone");

    println!("✓ rejoin_e2e passed");
    Ok(())
}
