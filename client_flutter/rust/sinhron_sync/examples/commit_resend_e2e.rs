// ADR-101 end-to-end, through a real server (SINHRON_E2E_HTTP, default
// http://127.0.0.1:8080): what happens to a Commit whose Ack never reached
// the phone. Every person here has ONE device in the chat, so nobody gets a
// copy of their own Commit back — the answer to the repeat is all there is.
//
//   B. Lost Ack: Bob's Commit is taken, the Ack is "lost" (ignored here).
//      Alice moves on and writes; Bob can't open that yet and keeps it.
//      Bob sends the very same Commit again → Ack 0, nothing goes out
//      twice → Bob applies his Commit, opens what he kept.
//   D. The same, but the chat went one more epoch on before the repeat.
//   C. Lost race: Alice and Bob commit at one epoch, Alice first. Bob's
//      answer (409) is "lost"; the repeat is 409 again → he drops his,
//      takes Alice's, the chat is whole.
//   W. A Commit that adds Carol, its Ack lost: repeat → Ack 0, then the
//      Welcome; Carol reads and writes.
//
// Not in CI (needs a server). Run:
//   cd server && SINHRON_LISTEN=127.0.0.1:8080 SINHRON_DB_URL=$DATABASE_URL cargo run
//   cd client_flutter/rust && cargo run -p sinhron_sync --example commit_resend_e2e

use std::collections::VecDeque;
use std::time::Duration;

use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{Push, Submit, Welcome, WsFrame};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};
use tokio::time::timeout;

fn http_url() -> String {
    std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string())
}

struct Peer {
    name: &'static str,
    client: SyncClient,
    ws: WsClient,
    pushes: VecDeque<Push>,
    welcomes: VecDeque<Vec<u8>>,
}

impl Peer {
    async fn new(name: &'static str, http: &HttpApi) -> anyhow::Result<Self> {
        let phrase = sinhron_crypto::generate_phrase();
        let mut client = SyncClient::new(SyncClientConfig { phrase, db_path: None, device_seed: None })?;
        client.bootstrap_with_server(http).await?;
        let url = format!("{}/v1/sync", http_url().replacen("http", "ws", 1));
        let ws = WsClient::start(WsClientConfig { url, identity_seed: client.login_seed_bytes(), tls: None, resume_cursor: None });
        match timeout(Duration::from_secs(10), ws.recv()).await? {
            Some(Event::Connected) => {}
            other => anyhow::bail!("{name}: expected Connected, got {other:?}"),
        }
        Ok(Self { name, client, ws, pushes: VecDeque::new(), welcomes: VecDeque::new() })
    }

    fn id(&self) -> String {
        self.client.identity_pubkey_hex()
    }

    /// Read frames until `want` says stop; pushes and welcomes are kept.
    async fn pump(&mut self, want_ack: Option<&str>, wait: Duration) -> anyhow::Result<Option<i32>> {
        loop {
            let ev = match timeout(wait, self.ws.recv()).await {
                Ok(ev) => ev,
                Err(_) => return Ok(None),
            };
            match ev {
                Some(Event::Frame(WsFrame { body: Some(Body::Ack(a)), .. })) if Some(a.acked_frame_id.as_str()) == want_ack => {
                    return Ok(Some(a.error_code));
                }
                Some(Event::Frame(WsFrame { body: Some(Body::Push(p)), .. })) => {
                    self.pushes.push_back(p);
                    if want_ack == Some("first push") {
                        return Ok(None);
                    }
                }
                Some(Event::Frame(WsFrame { body: Some(Body::Welcome(w)), .. })) => {
                    self.welcomes.push_back(w.welcome_bytes);
                    if want_ack == Some("first welcome") {
                        return Ok(None);
                    }
                }
                Some(Event::Frame(_)) | Some(Event::Connected) => {}
                Some(Event::Disconnected { reason }) => anyhow::bail!("{} disconnected: {reason}", self.name),
                None => anyhow::bail!("{}: ws closed", self.name),
            }
        }
    }

    /// Send a Submit and return the server's code for it.
    async fn send(&mut self, group: &[u8], bytes: &[u8], commit_epoch: Option<u64>, message_id: &str) -> anyhow::Result<i32> {
        let frame_id = uuid::Uuid::now_v7().to_string();
        let frame = WsFrame {
            frame_id: frame_id.clone(),
            body: Some(Body::Submit(Submit {
                group_id: group.to_vec(),
                ciphertext: bytes.to_vec(),
                message_id: message_id.to_string(),
                sealed_sender: false,
                is_commit: commit_epoch.is_some(),
                commit_epoch: commit_epoch.unwrap_or(0),
                urgent: false,
                access_keys: Vec::new(),
                refused_commit_ids: Vec::new(),
                parent_commit_id: String::new(),
            })),
        };
        self.ws.send(frame).await?;
        self.pump(Some(&frame_id), Duration::from_secs(15)).await?.ok_or_else(|| anyhow::anyhow!("{}: no ack", self.name))
    }

    async fn say(&mut self, group: &[u8], text: &[u8]) -> anyhow::Result<()> {
        let ct = self.client.encrypt(group, text)?;
        let code = self.send(group, &ct, None, &uuid::Uuid::now_v7().to_string()).await?;
        anyhow::ensure!(code == 0, "{}: message refused ({code})", self.name);
        Ok(())
    }

    /// The next pushed frame of this chat, not opened.
    async fn next_push(&mut self, group: &[u8]) -> anyhow::Result<Push> {
        loop {
            if let Some(at) = self.pushes.iter().position(|p| p.group_id == group) {
                return Ok(self.pushes.remove(at).unwrap());
            }
            self.pump(Some("first push"), Duration::from_secs(10)).await?;
            anyhow::ensure!(self.pushes.iter().any(|p| p.group_id == group), "{}: nothing came", self.name);
        }
    }

    async fn open_next(&mut self, group: &[u8]) -> anyhow::Result<IncomingMessage> {
        let p = self.next_push(group).await?;
        Ok(self.client.decrypt(group, &p.ciphertext)?)
    }

    /// Nothing more comes for this chat (2 s).
    async fn quiet(&mut self, group: &[u8]) -> anyhow::Result<bool> {
        self.pump(None, Duration::from_secs(2)).await?;
        Ok(!self.pushes.iter().any(|p| p.group_id == group))
    }
}

fn is_text(m: &IncomingMessage, text: &[u8]) -> bool {
    matches!(m, IncomingMessage::App(b) if b == text)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    println!("→ commit_resend_e2e · http={}", http_url());
    let http = HttpApi::new(http_url());
    let mut alice = Peer::new("alice", &http).await?;
    let mut bob = Peer::new("bob", &http).await?;
    let mut carol = Peer::new("carol", &http).await?;

    let group = alice.client.create_group()?;
    let invite = alice.client.fetch_kp_and_invite(&http, &group, &bob.id()).await?;
    let to = hex::decode(bob.id())?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs() as i64;
    let welcome = |to: &[u8], bytes: &[u8]| WsFrame {
        frame_id: format!("welcome-{}", uuid::Uuid::now_v7()),
        body: Some(Body::Welcome(Welcome { recipient_identity_pubkey: to.to_vec(), group_id: group.clone(), welcome_bytes: bytes.to_vec(), sent_at: now, recipient_device_pks: vec![] })),
    };
    alice.ws.send(welcome(&to, &invite.welcome_bytes)).await?;
    bob.pump(Some("first welcome"), Duration::from_secs(10)).await?;
    let w = bob.welcomes.pop_front().ok_or_else(|| anyhow::anyhow!("bob: no welcome"))?;
    bob.client.join_via_welcome(&w)?;
    alice.say(&group, b"hello").await?;
    anyhow::ensure!(is_text(&bob.open_next(&group).await?, b"hello"));
    println!("✓ Alice and Bob have a chat (one device each)");

    // B. Lost Ack.
    let e = bob.client.group_epoch(&group)?;
    let p = bob.client.self_update_pending(&group)?;
    let m = uuid::Uuid::now_v7().to_string();
    let first = bob.send(&group, &p.commit_bytes, Some(p.epoch), &m).await?;
    anyhow::ensure!(first == 0, "the server took Bob's Commit ({first})");
    // ... but Bob never learns: the Ack is lost. Alice moves on and writes.
    anyhow::ensure!(matches!(alice.open_next(&group).await?, IncomingMessage::Commit { .. }));
    alice.say(&group, b"are you there?").await?;
    let kept = bob.next_push(&group).await?;
    let early = bob.client.decrypt(&group, &kept.ciphertext);
    println!("  Bob, his Commit still pending, gets Alice's message of the next epoch: {early:?}");
    anyhow::ensure!(matches!(early, Ok(IncomingMessage::StaleEpoch { .. })), "the app keeps such a frame (StaleEpoch while a Commit is pending)");
    anyhow::ensure!(bob.quiet(&group).await?, "one device: no copy of his own Commit comes back");
    // N1 — a second change while the first waits is not made (it would take
    // the first one's place, and the repeat's Ack 0 would apply the wrong one).
    anyhow::ensure!(bob.client.self_update_pending(&group).is_err(), "N1: no second Commit while one waits");
    let again = bob.send(&group, &p.commit_bytes, Some(p.epoch), &m).await?;
    anyhow::ensure!(again == 0, "B: the same Commit again must be Ack 0, got {again}");
    anyhow::ensure!(bob.client.confirm_commit(&group)? == e + 1);
    anyhow::ensure!(is_text(&bob.client.decrypt(&group, &kept.ciphertext)?, b"are you there?"), "the kept message opens now");
    bob.say(&group, b"yes").await?;
    let got = alice.open_next(&group).await?;
    anyhow::ensure!(is_text(&got, b"yes"), "B: Alice's next frame is Bob's message, not his Commit a second time: {got:?}");
    println!("✓ B: lost Ack → same Commit again → Ack 0, nothing sent twice, one epoch ({})", e + 1);

    // D. Lost Ack, and the chat goes one more epoch on before the repeat.
    let e = bob.client.group_epoch(&group)?;
    let p = bob.client.self_update_pending(&group)?;
    let m = uuid::Uuid::now_v7().to_string();
    anyhow::ensure!(bob.send(&group, &p.commit_bytes, Some(p.epoch), &m).await? == 0);
    anyhow::ensure!(matches!(alice.open_next(&group).await?, IncomingMessage::Commit { .. }));
    let pa = alice.client.self_update_pending(&group)?;
    let ma = uuid::Uuid::now_v7().to_string();
    anyhow::ensure!(alice.send(&group, &pa.commit_bytes, Some(pa.epoch), &ma).await? == 0, "Alice's Commit on top of Bob's");
    alice.client.confirm_commit(&group)?;
    let kept = bob.next_push(&group).await?;
    let early = bob.client.decrypt(&group, &kept.ciphertext);
    println!("  Bob, his Commit still pending, gets Alice's Commit made on top of it: {early:?}");
    anyhow::ensure!(matches!(early, Ok(IncomingMessage::StaleEpoch { .. })), "kept by the app, not lost");
    let again = bob.send(&group, &p.commit_bytes, Some(p.epoch), &m).await?;
    anyhow::ensure!(again == 0, "D: the repeat after the chat moved on must be Ack 0, got {again}");
    anyhow::ensure!(bob.client.confirm_commit(&group)? == e + 1);
    anyhow::ensure!(matches!(bob.client.decrypt(&group, &kept.ciphertext)?, IncomingMessage::Commit { .. }), "the kept Commit applies now");
    anyhow::ensure!(bob.client.group_epoch(&group)? == alice.client.group_epoch(&group)?);
    alice.say(&group, b"d1").await?;
    anyhow::ensure!(is_text(&bob.open_next(&group).await?, b"d1"));
    bob.say(&group, b"d2").await?;
    anyhow::ensure!(is_text(&alice.open_next(&group).await?, b"d2"));
    println!("✓ D: repeat after the chat went an epoch further → Ack 0, both at epoch {}", e + 2);

    // C. Lost race.
    let pa = alice.client.self_update_pending(&group)?;
    let pb = bob.client.self_update_pending(&group)?;
    anyhow::ensure!(alice.send(&group, &pa.commit_bytes, Some(pa.epoch), &uuid::Uuid::now_v7().to_string()).await? == 0);
    alice.client.confirm_commit(&group)?;
    let mb = uuid::Uuid::now_v7().to_string();
    let first = bob.send(&group, &pb.commit_bytes, Some(pb.epoch), &mb).await?;
    anyhow::ensure!(first == 409, "Bob lost the race ({first})");
    // ... the 409 is lost too. The repeat:
    let again = bob.send(&group, &pb.commit_bytes, Some(pb.epoch), &mb).await?;
    anyhow::ensure!(again == 409, "C: the repeat of a Commit that lost must be 409 again, got {again}");
    bob.client.discard_commit(&group)?;
    anyhow::ensure!(matches!(bob.open_next(&group).await?, IncomingMessage::Commit { .. }), "Bob takes Alice's Commit");
    anyhow::ensure!(bob.client.group_epoch(&group)? == alice.client.group_epoch(&group)?);
    anyhow::ensure!(alice.quiet(&group).await?, "Bob's Commit went to nobody");
    alice.say(&group, b"c1").await?;
    anyhow::ensure!(is_text(&bob.open_next(&group).await?, b"c1"));
    bob.say(&group, b"c2").await?;
    anyhow::ensure!(is_text(&alice.open_next(&group).await?, b"c2"));
    println!("✓ C: lost race → repeat is 409 → dropped, the winner's Commit taken, chat whole");

    // W. A Commit that adds Carol; its Ack lost; the Welcome goes after the repeat.
    let e = alice.client.group_epoch(&group)?;
    let kps = alice.client.fetch_people_keypackages(&http, &[carol.id()]).await?;
    let p = alice.client.invite_devices_pending(&group, &kps.1)?;
    let adds = alice.client.pending_adds(&group)?;
    anyhow::ensure!(adds.len() == 1 && hex::encode(adds[0].0) == carol.id(), "who to welcome is known while pending");
    let m = uuid::Uuid::now_v7().to_string();
    anyhow::ensure!(alice.send(&group, &p.commit_bytes, Some(p.epoch), &m).await? == 0);
    anyhow::ensure!(matches!(bob.open_next(&group).await?, IncomingMessage::Commit { .. }));
    let again = alice.send(&group, &p.commit_bytes, Some(p.epoch), &m).await?;
    anyhow::ensure!(again == 0, "W: repeat must be Ack 0, got {again}");
    anyhow::ensure!(alice.client.confirm_commit(&group)? == e + 1);
    let mut members = vec![alice.client.device_public_key()];
    members.extend(adds.iter().map(|(_, d)| d.clone()));
    http.announce_group(alice.client.login_seed_bytes(), &group, e + 1, &members).await?;
    alice.ws.send(welcome(&hex::decode(carol.id())?, p.welcome_bytes.as_ref().ok_or_else(|| anyhow::anyhow!("no welcome"))?)).await?;
    carol.pump(Some("first welcome"), Duration::from_secs(10)).await?;
    let w = carol.welcomes.pop_front().ok_or_else(|| anyhow::anyhow!("carol: no welcome"))?;
    carol.client.join_via_welcome(&w)?;
    carol.say(&group, b"hi all").await?;
    anyhow::ensure!(is_text(&alice.open_next(&group).await?, b"hi all"));
    anyhow::ensure!(is_text(&bob.open_next(&group).await?, b"hi all"));
    bob.say(&group, b"welcome").await?;
    anyhow::ensure!(is_text(&carol.open_next(&group).await?, b"welcome"));
    println!("✓ W: adding Carol with a lost Ack → repeat Ack 0 → Welcome → she reads and writes");

    println!("✓ commit_resend_e2e passed");
    Ok(())
}
