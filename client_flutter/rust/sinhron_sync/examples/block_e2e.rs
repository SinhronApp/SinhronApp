// ADR-071 end-to-end — block = revoke that person's access key, through a
// real server (SINHRON_E2E_HTTP, default http://127.0.0.1:8080).
//
//   1. Bob publishes per-contact key hashes (PUT /v1/access-keys) and
//      gives Alice her own key inside MLS.
//   2. Alice → Bob without authentication with that key: delivered. Bob's
//      old shared key (ADR-026) no longer works.
//   3. Bob blocks Alice (a revoke decision). Her next message gets the
//      same "accepted" answer — and never reaches Bob. Her call: she hears
//      ringing, Bob's app sees nothing.
//   4. Her fallback over the signed-in WS reaches Bob's open app (it drops
//      it; the server sends no push — `ws::tests::a_blocked_person_cannot_wake_me`).
//   5. A stale device's older unblock can't lift the block; Bob's later
//      unblock does — her key works again.
//
// Usage: cargo run --example block_e2e

use std::time::Duration;

use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{CallInvite, SealedDelivery, SealedSubmit, Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::envelope::{decode_message, encode_access, Decoded};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::time::timeout;

const ALICE_PHRASE: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
const BOB_PHRASE: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";

fn http_url() -> String {
    std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string())
}
fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}
fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as i64
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

async fn wait_for<T>(ws: &WsClient, secs: u64, mut pick: impl FnMut(Body) -> Option<T>) -> anyhow::Result<Option<T>> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(secs);
    loop {
        let left = deadline.saturating_duration_since(tokio::time::Instant::now());
        match timeout(left, ws.recv()).await {
            Err(_) => return Ok(None),
            Ok(Some(Event::Frame(WsFrame { body: Some(b), .. }))) => {
                if let Some(t) = pick(b) {
                    return Ok(Some(t));
                }
            }
            Ok(Some(Event::Disconnected { reason })) => anyhow::bail!("disconnected: {reason}"),
            Ok(None) => anyhow::bail!("ws closed"),
            _ => {}
        }
    }
}

type Anon = (String, Vec<([u8; 16], Vec<u8>, Vec<u8>)>);

/// Alice's message to Bob, sealed, with [key] as the access key.
fn seal(alice: &mut SyncClient, group: &[u8], bob_pk: &[u8], text: &[u8], key: &[u8]) -> anyhow::Result<Anon> {
    let ct = alice.encrypt(group, text)?;
    let sealed = alice.seal_for(group, &ct, &[bob_pk.to_vec()])?;
    Ok((uuid::Uuid::now_v7().to_string(), sealed.into_iter().map(|(k, e)| (k, e, key.to_vec())).collect()))
}

fn sealed_push(b: Body) -> Option<sinhron_net::proto::Push> {
    match b {
        Body::Push(p) if !p.sealed_key_id.is_empty() => Some(p),
        _ => None,
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("→ block_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut alice = SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: None })?;
    let mut bob = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: None })?;
    alice.bootstrap_with_server(&http).await?;
    bob.bootstrap_with_server(&http).await?;
    for c in [&alice, &bob] {
        let keys: Vec<(u32, Vec<u8>)> = c.delivery_keys_to_publish(now())?.into_iter().map(|k| (k.week, k.public)).collect();
        http.publish_sealed_keys(c.identity_seed_bytes(), &keys, Some((c.access_hash(), c.access_version())), None).await?;
    }
    let alice_ws = connect(&alice).await?;
    let bob_ws = connect(&bob).await?;
    let alice_id = hex::decode(alice.identity_pubkey_hex())?;

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
    let w = wait_for(&bob_ws, 15, |b| match b {
        Body::Welcome(w) => Some(w.welcome_bytes),
        _ => None,
    })
    .await?
    .ok_or_else(|| anyhow::anyhow!("no Welcome"))?;
    bob.join_via_welcome(&w)?;

    // 1. Bob: the hash of Alice's key (and his own) to the server first,
    //    then the key to Alice inside MLS.
    let bob_id = hex::decode(bob.identity_pubkey_hex())?;
    let v = http
        .publish_access_keys(bob.identity_seed_bytes(), 0, &[bob.access_hash_for(&alice_id), bob.access_hash_for(&bob_id)], &[])
        .await?;
    anyhow::ensure!(v == 0);
    let id = uuid::Uuid::now_v7().to_string();
    bob_ws
        .send(WsFrame {
            frame_id: id.clone(),
            body: Some(Body::Submit(Submit {
                group_id: group.clone(),
                ciphertext: bob.encrypt(&group, &encode_access(&bob.access_key_for(&alice_id)))?,
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
    let p = wait_for(&alice_ws, 15, |b| match b {
        Body::Push(p) if p.group_id == g => Some(p),
        _ => None,
    })
    .await?
    .ok_or_else(|| anyhow::anyhow!("no access message"))?;
    let (m, _) = alice.decrypt_with_sender(&group, &p.ciphertext)?;
    let IncomingMessage::App(bytes) = m else { anyhow::bail!("expected the access message") };
    let Decoded::Access { key: her_key } = decode_message(&bytes)?.decoded else { anyhow::bail!("not an access key") };
    anyhow::ensure!(her_key == bob.access_key_for(&alice_id).to_vec() && her_key != bob.access_key().to_vec());
    println!("✓ Alice has the key Bob made for her alone");

    // 2. Alice → Bob without authentication.
    let week = sinhron_sync::sealed::week_of(now());
    let (_, _, bob_pk, _) = http
        .fetch_sealed_keys(&[bob.identity_pubkey_hex()])
        .await?
        .into_iter()
        .find(|(_, w, ..)| *w == week)
        .ok_or_else(|| anyhow::anyhow!("no key for this week"))?;
    let (mid, items) = seal(&mut alice, &group, &bob_pk, b"hello Bob", &her_key)?;
    anyhow::ensure!(http.submit_sealed_anonymous(&mid, &items, 0, &[true], &[], 0).await? == (1, 0));
    let p = wait_for(&bob_ws, 10, sealed_push).await?.ok_or_else(|| anyhow::anyhow!("Bob got nothing"))?;
    let (_, m, sender) = bob.open_sealed(&p.sealed_key_id, &p.ciphertext, now())?;
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"hello Bob") && sender.as_deref() == Some(alice_id.as_slice()));
    let (mid, items) = seal(&mut alice, &group, &bob_pk, b"with the old shared key", &bob.access_key())?;
    anyhow::ensure!(http.submit_sealed_anonymous(&mid, &items, 0, &[true], &[], 0).await? == (0, 1), "shared key refused");
    println!("✓ delivered with her key; the old shared key is refused");

    // 3. Bob blocks Alice.
    let blocked_at = now_ms();
    http.publish_access_keys(bob.identity_seed_bytes(), 0, &[], &[(bob.access_hash_for(&alice_id), true, blocked_at)]).await?;
    let (mid, items) = seal(&mut alice, &group, &bob_pk, b"are you there?", &her_key)?;
    anyhow::ensure!(
        http.submit_sealed_anonymous(&mid, &items, 0, &[true], &[], 0).await? == (1, 0),
        "she sees the same answer as before"
    );
    anyhow::ensure!(wait_for(&bob_ws, 3, sealed_push).await?.is_none(), "nothing reached Bob");
    println!("✓ blocked: her message is 'accepted' and silently dropped");

    let call_id = uuid::Uuid::now_v7().to_string();
    alice_ws
        .send(WsFrame {
            frame_id: "call".into(),
            body: Some(Body::CallInvite(CallInvite {
                call_id: call_id.clone(),
                group_id: group.clone(),
                kind: 1,
                livekit_room: String::new(),
                ttl_secs: 30,
                caller_identity: Vec::new(),
                access_keys: vec![her_key.clone()],
                sends_access_keys: true,
                caller_proof: alice.call_invite_proof(&call_id, &group, false, now()),
            })),
        })
        .await?;
    let ack = wait_for(&alice_ws, 10, |b| match b {
        Body::Ack(a) if a.acked_frame_id == "call" => Some((a.error_code, a.error_message)),
        _ => None,
    })
    .await?;
    anyhow::ensure!(ack == Some((0, "ringing".to_string())), "she hears ringing: {ack:?}");
    let seen = wait_for(&bob_ws, 3, |b| matches!(b, Body::CallInvite(_)).then_some(())).await?;
    anyhow::ensure!(seen.is_none(), "Bob's app saw no call");
    alice_ws
        .send(WsFrame {
            frame_id: "end".into(),
            body: Some(Body::CallEnd(sinhron_net::proto::CallEnd { call_id, reason: "hangup".into() })),
        })
        .await?;
    println!("✓ blocked: her call rings for her, never for Bob");

    // 4. Her fallback over the signed-in WS (no key on that route).
    let ct = alice.encrypt(&group, b"over the websocket")?;
    let sealed = alice.seal_for(&group, &ct, std::slice::from_ref(&bob_pk))?;
    let mid = uuid::Uuid::now_v7().to_string();
    alice_ws
        .send(WsFrame {
            frame_id: mid.clone(),
            body: Some(Body::SealedSubmit(SealedSubmit {
                message_id: mid,
                deliveries: sealed
                    .into_iter()
                    .map(|(k, e)| SealedDelivery { key_id: k.to_vec(), envelope: e, ttl_secs: 0, urgent: true, push_preview: vec![], drop_after_secs: 0 })
                    .collect(),
                    access_keys: Vec::new(),
            })),
        })
        .await?;
    let p = wait_for(&bob_ws, 10, sealed_push).await?.ok_or_else(|| anyhow::anyhow!("request not delivered"))?;
    let (_, _, sender) = bob.open_sealed(&p.sealed_key_id, &p.ciphertext, now())?;
    anyhow::ensure!(sender.as_deref() == Some(alice_id.as_slice()));
    println!("✓ her WS fallback reaches Bob's open app as a request (his app drops it; no push)");

    // 5. A stale device's older unblock can't lift it; a later one does.
    http.publish_access_keys(
        bob.identity_seed_bytes(),
        0,
        &[bob.access_hash_for(&alice_id)],
        &[(bob.access_hash_for(&alice_id), false, blocked_at - 60_000)],
    )
    .await?;
    let (mid, items) = seal(&mut alice, &group, &bob_pk, b"still blocked?", &her_key)?;
    anyhow::ensure!(http.submit_sealed_anonymous(&mid, &items, 0, &[], &[], 0).await? == (1, 0));
    anyhow::ensure!(wait_for(&bob_ws, 3, sealed_push).await?.is_none(), "an older unblock changes nothing");
    http.publish_access_keys(bob.identity_seed_bytes(), 0, &[], &[(bob.access_hash_for(&alice_id), false, now_ms())]).await?;
    let (mid, items) = seal(&mut alice, &group, &bob_pk, b"friends again", &her_key)?;
    anyhow::ensure!(http.submit_sealed_anonymous(&mid, &items, 0, &[true], &[], 0).await? == (1, 0));
    let p = wait_for(&bob_ws, 10, sealed_push).await?.ok_or_else(|| anyhow::anyhow!("not delivered after unblock"))?;
    let (_, m, _) = bob.open_sealed(&p.sealed_key_id, &p.ciphertext, now())?;
    // MLS may report the skipped generations; what matters is the text.
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"friends again"), "got {m:?}");
    println!("✓ unblocked: her key works again");

    alice_ws.shutdown();
    bob_ws.shutdown();
    println!("\n🎯 block_e2e · blocked = nothing reaches me ✓");
    Ok(())
}
