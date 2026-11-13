// ADR-025 end-to-end: one person on two devices, through a real server
// (SINHRON_E2E_HTTP, default http://127.0.0.1:8080).
//
//   1. Alice's phone (primary) and laptop (linked: own device key +
//      identity-signed certificate) and Bob bootstrap; the laptop
//      registers itself via POST /v1/devices.
//   2. The phone makes a chat with Bob (all of Bob's devices invited).
//   3. Device sync on the phone: the laptop is missing → one KeyPackage
//      for just that device → pending Commit → server orders it (Ack 0)
//      → Welcome to ourselves → the laptop joins.
//   4. Bob writes → both of Alice's devices decrypt it.
//   5. The laptop writes → Bob and Alice's phone get it (as Alice's own
//      message); the laptop drops its own echo.
//   6. The phone revokes the laptop (server + MLS remove) → Bob's next
//      message no longer opens on the laptop.
//
// Usage: cargo run --example multidevice_e2e

use std::time::Duration;

use rand_core::{OsRng, RngCore};
use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{SealedDelivery, SealedSubmit, Submit, Welcome, WsFrame};
use sinhron_sync::envelope::{decode_message, encode_history, Decoded, HistoryItem};
use sinhron_net::{Event, WsClient, WsClientConfig};
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

/// Next frame `pick` accepts; others are skipped (and logged).
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

/// A Welcome for `to` — addressed to `devices` of theirs (empty: any).
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

/// Decrypt the next Push for `group` on this device.
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
    println!("→ multidevice_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut laptop_seed = [0u8; 32];
    OsRng.fill_bytes(&mut laptop_seed);

    let mut phone = SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: None })?;
    let mut laptop =
        SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: Some(laptop_seed) })?;
    let mut bob = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: None })?;
    anyhow::ensure!(phone.identity_pubkey_hex() == laptop.identity_pubkey_hex(), "one person");
    anyhow::ensure!(phone.device_public_key() != laptop.device_public_key(), "two device keys");

    // 1. Bootstrap (the laptop registers its certificate).
    phone.bootstrap_with_server(&http).await?;
    laptop.bootstrap_with_server(&http).await?;
    bob.bootstrap_with_server(&http).await?;
    let alice_hex = phone.identity_pubkey_hex();
    let alice = hex::decode(&alice_hex)?;
    let alice_arr: [u8; 32] = alice.clone().try_into().map_err(|_| anyhow::anyhow!("identity len"))?;
    let devices = http.list_devices(&alice_hex).await?;
    anyhow::ensure!(
        devices.iter().any(|d| d.device_pk_hex == hex::encode(laptop.device_public_key())),
        "laptop listed among Alice's devices"
    );
    println!("✓ Alice has {} devices on the server", devices.len());

    let phone_ws = connect(&phone, "phone").await?;
    let laptop_ws = connect(&laptop, "laptop").await?;
    let bob_ws = connect(&bob, "bob").await?;

    // 2. Chat with Bob.
    let group = phone.create_group()?;
    let invite = phone.fetch_kp_and_invite(&http, &group, &bob.identity_pubkey_hex()).await?;
    phone_ws.send(welcome(&hex::decode(bob.identity_pubkey_hex())?, &group, &invite.welcome_bytes, vec![])).await?;
    let w = wait_for(&bob_ws, "bob", |b| match b {
        Body::Welcome(w) => Some(w.welcome_bytes),
        _ => None,
    })
    .await?;
    bob.join_via_welcome(&w)?;
    println!("✓ Bob joined");

    // 3. Device sync on the phone.
    let laptop_pk = laptop.device_public_key();
    let in_group = phone.group_device_keys(&group, &alice_arr)?;
    anyhow::ensure!(!in_group.contains(&laptop_pk), "laptop not in the chat yet");
    let kps = http.fetch_device_keypackages(phone.login_seed_bytes(), &alice_hex, &[laptop_pk.clone()]).await?;
    anyhow::ensure!(kps.len() == 1 && kps[0].0 == laptop_pk, "exactly the laptop's KeyPackage");
    let pending = phone.invite_devices_pending(&group, &[kps[0].1.clone()])?;
    let (cid, frame) = submit(&group, pending.commit_bytes.clone(), Some(pending.epoch));
    phone_ws.send(frame).await?;
    anyhow::ensure!(ack(&phone_ws, "phone", &cid).await? == 0, "server ordered the commit");
    phone.confirm_commit(&group)?;
    let my_device = phone.device_public_key();
    http.announce_group(phone.login_seed_bytes(), &group, phone.group_epoch(&group)?, &[my_device.clone(), laptop_pk.clone()]).await?;
    // Addressed to the laptop only (ADR-025): the phone doesn't get it back,
    // and it isn't left queued on the server.
    phone_ws.send(welcome(&alice, &group, pending.welcome_bytes.as_deref().unwrap_or_default(), vec![laptop_pk.clone()])).await?;
    let (m, _) = next_message(&bob_ws, &mut bob, "bob", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::Commit { .. }), "Bob applies the add, got {m:?}");
    // With several devices the server keeps Welcomes queued (it can't tell
    // which device one is for): skip any not addressed to this device.
    loop {
        let w = wait_for(&laptop_ws, "laptop", |b| match b {
            Body::Welcome(w) => Some(w.welcome_bytes),
            _ => None,
        })
        .await?;
        match laptop.join_via_welcome(&w) {
            Ok(g) if g == group => break,
            Ok(_) => continue,
            Err(e) => println!("laptop · Welcome not for this device ({e})"),
        }
    }
    anyhow::ensure!(laptop.group_epoch(&group)? == bob.group_epoch(&group)?, "same epoch everywhere");
    anyhow::ensure!(bob.group_member_identities(&group)?.len() == 2, "still two people");
    println!("✓ laptop joined via device sync");

    // 3b. History for the new device: an MLS message in the chat, sealed
    // ONLY to Alice's own delivery key (shared by her devices).
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let week = sinhron_sync::sealed::week_of(now);
    let my_key = phone
        .delivery_keys_to_publish(now)?
        .into_iter()
        .find(|k| k.week == week)
        .ok_or_else(|| anyhow::anyhow!("no delivery key"))?;
    let keys: Vec<(u32, Vec<u8>)> = phone.delivery_keys_to_publish(now)?.into_iter().map(|k| (k.week, k.public)).collect();
    http.publish_sealed_keys(phone.identity_seed_bytes(), &keys, None, None).await?;
    let item = HistoryItem {
        wire_id: uuid::Uuid::now_v7().to_string(),
        ts: 1,
        kind: "text".into(),
        text: "an old message".into(),
        media_json: String::new(),
        sender: bob.identity_pubkey_hex(),
        ..Default::default()
    };
    let ct = phone.encrypt(&group, &encode_history(vec![item.clone()], "Bob", false, false))?;
    let sealed = phone.seal_for(&group, &ct, &[my_key.public.clone()])?;
    let hid = uuid::Uuid::now_v7().to_string();
    phone_ws
        .send(WsFrame {
            frame_id: hid.clone(),
            body: Some(Body::SealedSubmit(SealedSubmit {
                message_id: hid,
                deliveries: sealed.into_iter().map(|(k, e)| SealedDelivery { key_id: k.to_vec(), envelope: e, ttl_secs: 0, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 }).collect(),
                access_keys: Vec::new(),
            })),
        })
        .await?;
    let p = wait_for(&laptop_ws, "laptop", |b| match b {
        Body::Push(p) if !p.sealed_key_id.is_empty() => Some(p),
        _ => None,
    })
    .await?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let (gid, m, sender) = laptop.open_sealed(&p.sealed_key_id, &p.ciphertext, now)?;
    anyhow::ensure!(gid == group && sender.as_deref() == Some(alice.as_slice()), "history from Alice for this chat");
    let IncomingMessage::App(b) = m else { anyhow::bail!("expected the history message") };
    anyhow::ensure!(decode_message(&b)?.decoded == Decoded::History { items: vec![item], chat_name: "Bob".into(), is_group: false, saved: false });
    println!("✓ the laptop got the chat's history (sealed to Alice's own key only)");

    // 4. Bob → both of Alice's devices.
    let ct = bob.encrypt(&group, b"hi Alice")?;
    let (id, f) = submit(&group, ct, None);
    bob_ws.send(f).await?;
    anyhow::ensure!(ack(&bob_ws, "bob", &id).await? == 0);
    for (ws, c, who) in [(&phone_ws, &mut phone, "phone"), (&laptop_ws, &mut laptop, "laptop")] {
        let (m, sender) = next_message(ws, c, who, &group).await?;
        anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"hi Alice"), "{who} got {m:?}");
        anyhow::ensure!(sender.as_deref() == Some(hex::decode(bob.identity_pubkey_hex())?.as_slice()), "{who}: from Bob");
    }
    println!("✓ Bob's message reached the phone and the laptop");

    // 4b. The phone writes after the history message Bob never saw: MLS
    // skips that generation — Bob still decrypts.
    let ct = phone.encrypt(&group, b"after history")?;
    let (_, f) = submit(&group, ct, None);
    phone_ws.send(f).await?;
    let (m, _) = next_message(&bob_ws, &mut bob, "bob", &group).await?;
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"after history"), "bob got {m:?}");
    let (m, _) = next_message(&laptop_ws, &mut laptop, "laptop", &group).await?;
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"after history"), "laptop got {m:?}");
    let (m, _) = next_message(&phone_ws, &mut phone, "phone", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::OwnCommitEcho), "the phone drops its own echo, got {m:?}");
    println!("✓ Bob unaffected by the history message");

    // 5. Laptop → Bob + Alice's phone; the laptop ignores its echo.
    let ct = laptop.encrypt(&group, b"from my laptop")?;
    let (id, f) = submit(&group, ct, None);
    laptop_ws.send(f).await?;
    let (m, sender) = next_message(&bob_ws, &mut bob, "bob", &group).await?;
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"from my laptop"), "bob got {m:?}");
    anyhow::ensure!(sender.as_deref() == Some(alice.as_slice()), "Bob sees Alice, not a device");
    let (m, sender) = next_message(&phone_ws, &mut phone, "phone", &group).await?;
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"from my laptop"), "phone got {m:?}");
    anyhow::ensure!(sender.as_deref() == Some(alice.as_slice()), "the phone sees it as Alice's own");
    let (m, _) = next_message(&laptop_ws, &mut laptop, "laptop", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::OwnCommitEcho), "laptop drops its echo, got {m:?}");
    let _ = id;
    println!("✓ the laptop's message reached Bob and Alice's phone");

    // 6. Revoke the laptop.
    http.revoke_device(phone.identity_seed_bytes(), &laptop_pk).await?;
    let pending = phone.remove_device_pending(&group, &laptop_pk)?;
    let (cid, frame) = submit(&group, pending.commit_bytes.clone(), Some(pending.epoch));
    phone_ws.send(frame).await?;
    anyhow::ensure!(ack(&phone_ws, "phone", &cid).await? == 0, "removal ordered");
    phone.confirm_commit(&group)?;
    let (m, _) = next_message(&bob_ws, &mut bob, "bob", &group).await?;
    anyhow::ensure!(matches!(m, IncomingMessage::Commit { .. }), "Bob applies the removal, got {m:?}");
    anyhow::ensure!(!http.list_devices(&alice_hex).await?.iter().any(|d| d.device_pk_hex == hex::encode(&laptop_pk)));
    let ct = bob.encrypt(&group, b"after revoke")?;
    let (id, f) = submit(&group, ct, None);
    bob_ws.send(f).await?;
    anyhow::ensure!(ack(&bob_ws, "bob", &id).await? == 0);
    let (m, _) = next_message(&phone_ws, &mut phone, "phone", &group).await?;
    anyhow::ensure!(matches!(&m, IncomingMessage::App(b) if b == b"after revoke"), "phone got {m:?}");
    // The laptop's socket is still Alice's (same identity), so the server
    // may hand it the frame — but it can no longer open it.
    let g = group.clone();
    if let Ok(Ok(p)) = timeout(
        Duration::from_secs(3),
        wait_for(&laptop_ws, "laptop", |b| match b {
            Body::Push(p) if p.group_id == g => Some(p),
            _ => None,
        }),
    )
    .await
    {
        let r = laptop.decrypt_with_sender(&group, &p.ciphertext);
        anyhow::ensure!(!matches!(r, Ok((IncomingMessage::App(_), _))), "revoked laptop must not read new messages");
    }
    println!("✓ revoked laptop can't read new messages");

    for ws in [phone_ws, laptop_ws, bob_ws] {
        ws.shutdown();
    }
    println!("\n🎯 multidevice_e2e · one person, two devices, real server ✓");
    Ok(())
}
