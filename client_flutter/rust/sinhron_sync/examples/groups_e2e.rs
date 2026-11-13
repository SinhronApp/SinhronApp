// ADR-034 end-to-end: a group of several people, through a real server
// (SINHRON_E2E_HTTP, default http://127.0.0.1:8080).
//
//   1. Alice, Bob and Carol (fresh phrases each run) bootstrap and connect.
//   2. Alice makes a group with Bob and Carol in ONE Commit
//      (`fetch_kps_and_invite_people`: every device's KeyPackage, one
//      announce) and sends each of them the one Welcome, addressed to
//      their devices; then the group's name (`GroupName` envelope).
//   3. Bob and Carol join and read the name; everyone writes once and the
//      other two read it, with the right sender.
//   4. Carol adds Dave later: a pending Commit the server orders (Ack 0)
//      reaches Alice and Bob, who apply it; Dave joins from his Welcome;
//      everyone (four people) reads everyone.
//
// Usage: cargo run --example groups_e2e

use std::time::Duration;

use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::envelope::{decode_message, encode_group_name, encode_text, Decoded};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::time::timeout;

fn http_url() -> String {
    std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string())
}
fn ws_url() -> String {
    format!("{}/v1/sync", http_url().replacen("http", "ws", 1))
}
fn unix() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

struct Member {
    name: &'static str,
    client: SyncClient,
    ws: WsClient,
}

impl Member {
    async fn new(name: &'static str, http: &HttpApi) -> anyhow::Result<Self> {
        // Fresh people each run: KeyPackages a previous run left on the
        // server belong to keys that no longer exist.
        let phrase = sinhron_crypto::generate_phrase();
        let mut client = SyncClient::new(SyncClientConfig { phrase, db_path: None, device_seed: None })?;
        client.bootstrap_with_server(http).await?;
        let ws = WsClient::start(WsClientConfig { url: ws_url(), identity_seed: client.login_seed_bytes(), tls: None, resume_cursor: None });
        match timeout(Duration::from_secs(10), ws.recv()).await? {
            Some(Event::Connected) => println!("{name} ✓ ws connected"),
            other => anyhow::bail!("{name}: expected Connected, got {other:?}"),
        }
        Ok(Self { name, client, ws })
    }

    fn id(&self) -> String {
        self.client.identity_pubkey_hex()
    }

    /// Next frame `pick` accepts; others are skipped (and logged).
    async fn wait_for<T>(&self, mut pick: impl FnMut(Body) -> Option<T>) -> anyhow::Result<T> {
        loop {
            match timeout(Duration::from_secs(15), self.ws.recv()).await? {
                Some(Event::Frame(WsFrame { body: Some(b), .. })) => {
                    let name = format!("{:?}", std::mem::discriminant(&b));
                    if let Some(t) = pick(b) {
                        return Ok(t);
                    }
                    println!("{} · skipped frame {name}", self.name);
                }
                Some(Event::Frame(_)) | Some(Event::Connected) => {}
                Some(Event::Disconnected { reason }) => anyhow::bail!("{} disconnected: {reason}", self.name),
                None => anyhow::bail!("{}: ws closed", self.name),
            }
        }
    }

    /// Submit to the group; `commit_epoch` marks an ordered Commit. Returns the Ack code.
    async fn submit(&self, group: &[u8], ciphertext: Vec<u8>, commit_epoch: Option<u64>) -> anyhow::Result<i32> {
        let id = uuid::Uuid::now_v7().to_string();
        self.ws
            .send(WsFrame {
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
            })
            .await?;
        self.wait_for(|b| match b {
            Body::Ack(a) if a.acked_frame_id == id => Some(a.error_code),
            _ => None,
        })
        .await
    }

    async fn send_welcome(&self, to: &str, group: &[u8], bytes: &[u8], devices: Vec<Vec<u8>>) -> anyhow::Result<()> {
        self.ws
            .send(WsFrame {
                frame_id: format!("welcome-{}", uuid::Uuid::now_v7()),
                body: Some(Body::Welcome(Welcome {
                    recipient_identity_pubkey: hex::decode(to)?,
                    group_id: group.to_vec(),
                    welcome_bytes: bytes.to_vec(),
                    sent_at: unix(),
                    recipient_device_pks: devices,
                })),
            })
            .await?;
        Ok(())
    }

    async fn join(&mut self, group: &[u8]) -> anyhow::Result<()> {
        let g = group.to_vec();
        let w = self
            .wait_for(|b| match b {
                Body::Welcome(w) if w.group_id == g => Some(w),
                _ => None,
            })
            .await?;
        anyhow::ensure!(self.client.join_via_welcome(&w.welcome_bytes)? == group, "{}: joined another group", self.name);
        println!("{} ✓ joined", self.name);
        Ok(())
    }

    /// Decrypt the next Push for `group`.
    async fn next(&mut self, group: &[u8]) -> anyhow::Result<(IncomingMessage, Option<String>)> {
        let g = group.to_vec();
        let p = self
            .wait_for(|b| match b {
                Body::Push(p) if p.group_id == g => Some(p),
                _ => None,
            })
            .await?;
        let (m, sender) = self.client.decrypt_with_sender(group, &p.ciphertext)?;
        Ok((m, sender.map(hex::encode)))
    }
}

/// Every member writes once; every other member reads it from them.
async fn round(group: &[u8], members: &mut [Member]) -> anyhow::Result<()> {
    for i in 0..members.len() {
        let text = format!("hello from {}", members[i].name);
        let ct = members[i].client.encrypt(group, &encode_text(&text))?;
        anyhow::ensure!(members[i].submit(group, ct, None).await? == 0, "{} send refused", members[i].name);
        let from = members[i].id();
        for j in 0..members.len() {
            if i == j {
                continue;
            }
            let (m, sender) = members[j].next(group).await?;
            let IncomingMessage::App(bytes) = m else { anyhow::bail!("{}: not an app message: {m:?}", members[j].name) };
            let decoded = decode_message(&bytes)?.decoded;
            anyhow::ensure!(decoded == Decoded::Text(text.clone()), "{} read {decoded:?}", members[j].name);
            anyhow::ensure!(sender.as_deref() == Some(from.as_str()), "{}: wrong sender", members[j].name);
        }
        println!("✓ {} → everyone", members[i].name);
    }
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("→ groups_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut alice = Member::new("alice", &http).await?;
    let mut bob = Member::new("bob", &http).await?;
    let mut carol = Member::new("carol", &http).await?;

    // 2. One Commit for Bob and Carol; one Welcome, a copy for each.
    let group = alice.client.create_group()?;
    let (outcome, people) = alice.client.fetch_kps_and_invite_people(&http, &group, &[bob.id(), carol.id()]).await?;
    anyhow::ensure!(people.len() == 2, "both people invited");
    for p in &people {
        alice.send_welcome(&p.identity_hex, &group, &outcome.welcome_bytes, p.devices.clone()).await?;
    }
    bob.join(&group).await?;
    carol.join(&group).await?;
    for m in [&mut alice, &mut bob, &mut carol] {
        anyhow::ensure!(m.client.group_member_identities(&group)?.len() == 3, "{} sees three people", m.name);
    }

    // The group's name reaches both.
    let ct = alice.client.encrypt(&group, &encode_group_name("Дача"))?;
    anyhow::ensure!(alice.submit(&group, ct, None).await? == 0, "name refused");
    for m in [&mut bob, &mut carol] {
        let (msg, _) = m.next(&group).await?;
        let IncomingMessage::App(bytes) = msg else { anyhow::bail!("{}: name not an app message", m.name) };
        anyhow::ensure!(decode_message(&bytes)?.decoded == Decoded::GroupName { name: "Дача".into() }, "{}: name", m.name);
        println!("{} ✓ group is called «Дача»", m.name);
    }

    // 3. Everyone reads everyone.
    let mut members = vec![alice, bob, carol];
    round(&group, &mut members).await?;

    // 4. Alice (the admin) adds Dave: an ordered Commit that Bob and Carol apply.
    let mut dave = Member::new("dave", &http).await?;
    let (people, kps) = members[0].client.fetch_people_keypackages(&http, &[dave.id()]).await?;
    let pending = members[0].client.invite_devices_pending(&group, &kps)?;
    anyhow::ensure!(members[0].submit(&group, pending.commit_bytes.clone(), Some(pending.epoch)).await? == 0, "commit refused");
    members[0].client.confirm_commit(&group)?;
    let alice_device = members[0].client.device_public_key();
    let mut devices = vec![alice_device.clone()];
    devices.extend(people[0].devices.iter().cloned());
    http.announce_group(members[0].client.login_seed_bytes(), &group, members[0].client.group_epoch(&group)?, &devices).await?;
    members[0]
        .send_welcome(&people[0].identity_hex, &group, pending.welcome_bytes.as_ref().unwrap(), people[0].devices.clone())
        .await?;
    for m in members.iter_mut().skip(1) {
        let (msg, _) = m.next(&group).await?;
        anyhow::ensure!(matches!(msg, IncomingMessage::Commit { .. }), "{}: expected the Commit, got {msg:?}", m.name);
        println!("{} ✓ applied Alice's Commit (Dave added)", m.name);
    }
    dave.join(&group).await?;
    members.push(dave);
    round(&group, &mut members).await?;

    for m in &members {
        m.ws.shutdown();
    }
    println!("\n🎯 groups_e2e · 3-person group in one Commit, name, a 4th added later — everyone reads everyone ✓");
    Ok(())
}
