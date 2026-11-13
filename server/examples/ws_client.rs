// WebSocket smoke client — drives the /v1/sync endpoint end-to-end.
//
// Flow (matches the server FSM in src/ws.rs):
//   1. Connect with subprotocol "sinhron.v1"
//   2. Receive Hello — extract challenge_nonce
//   3. Send Auth (Ed25519-signed challenge)
//   4. Receive Ack (must be error_code=0 "authenticated")
//   5. Send Heartbeat — receive Heartbeat echo
//   6. Send Submit — receive Ack with error_code=501 (stub for A6)
//   7. Close
//
// Usage:
//   cargo run --example ws_client -- ws://localhost:8080/v1/sync [seed_hex]
//
// `seed_hex` is the same identity seed used by `gen_proof register` — the
// client signs the challenge with the matching identity privkey. The
// identity MUST already be registered via POST /v1/identity for the
// handshake to succeed. The login names the server (ADR-086): the first
// name in SINHRON_PUBLIC_HOSTNAME, default localhost.

use std::time::Duration;

use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use prost::Message as ProstMessage;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::SEC_WEBSOCKET_PROTOCOL;
use tokio_tungstenite::tungstenite::protocol::Message;

// Re-include the generated types from the main crate's OUT_DIR via the
// proto module — example bins share crate context with [lib]/[bin]
// targets and can `use` the crate's modules.
use sinhron_server::proto::ws_frame::Body;
use sinhron_server::proto::{Auth, Heartbeat, Submit, WsFrame};

const WS_AUTH_DOMAIN: &[u8] = b"sinhron-ws-auth-v1:";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "ws://localhost:8080/v1/sync".to_string());
    let seed_hex = std::env::args().nth(2).unwrap_or_else(|| "42".repeat(32));
    let seed_bytes = hex::decode(&seed_hex).expect("seed must be hex");
    let seed: [u8; 32] = seed_bytes.try_into().expect("seed must be 32 bytes");
    let sk = SigningKey::from_bytes(&seed);
    let pk = sk.verifying_key().to_bytes();

    // Manually craft the upgrade request so we can set Sec-WebSocket-Protocol.
    let mut req = url.as_str().into_client_request()?;
    req.headers_mut()
        .insert(SEC_WEBSOCKET_PROTOCOL, "sinhron.v1".parse()?);

    println!("→ connecting to {url}");
    let (mut socket, response) = tokio_tungstenite::connect_async(req).await?;
    println!("← connected · status={}", response.status());

    // ── 1. Receive Hello ─────────────────────────────────────────────
    let hello_frame = recv_frame(&mut socket).await?;
    let challenge = match hello_frame.body {
        Some(Body::Hello(h)) => {
            println!(
                "← Hello · server_version={} · server_time={} · challenge_len={}",
                h.server_version,
                h.server_time,
                h.challenge_nonce.len()
            );
            h.challenge_nonce
        }
        other => anyhow::bail!("expected Hello, got {:?}", other),
    };

    // ── 2. Send Auth ─────────────────────────────────────────────────
    let mut msg = Vec::with_capacity(WS_AUTH_DOMAIN.len() + challenge.len());
    msg.extend_from_slice(WS_AUTH_DOMAIN);
    msg.extend_from_slice(&challenge);
    let sig = sk.sign(&sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg)).to_bytes().to_vec();

    let auth_frame = WsFrame {
        frame_id: "auth-1".to_string(),
        body: Some(Body::Auth(Auth {
            identity_pubkey: pk.to_vec(),
            signature: sig,
        })),
    };
    send_frame(&mut socket, &auth_frame).await?;
    println!("→ Auth · pubkey={}", hex::encode(pk));

    // ── 3. Receive Ack ───────────────────────────────────────────────
    let ack_frame = recv_frame(&mut socket).await?;
    match ack_frame.body {
        Some(Body::Ack(a)) => {
            println!("← Ack · code={} · msg={}", a.error_code, a.error_message);
            if a.error_code != 0 {
                anyhow::bail!("auth failed: {}", a.error_message);
            }
        }
        other => anyhow::bail!("expected Ack, got {:?}", other),
    }

    // ── 4. Heartbeat round-trip ──────────────────────────────────────
    let hb = WsFrame {
        frame_id: "hb-1".to_string(),
        body: Some(Body::Heartbeat(Heartbeat { sequence: 1, next_within_secs: 0 })),
    };
    send_frame(&mut socket, &hb).await?;
    println!("→ Heartbeat · seq=1");

    let echo = recv_frame(&mut socket).await?;
    match echo.body {
        Some(Body::Heartbeat(h)) => println!("← Heartbeat echo · seq={}", h.sequence),
        other => anyhow::bail!("expected Heartbeat echo, got {:?}", other),
    }

    // ── 5. Submit a fake-encrypted blob to group `deadbeef` ──────────
    //
    // After WU A6 the Submit handler persists + fans out, so the
    // ciphertext + group_id need to match a registered group with the
    // sender as a member. For the canonical smoke setup (ws_fanout
    // preconditions) `deadbeef` is the demo group; this matches.
    let submit_frame = WsFrame {
        frame_id: "submit-1".to_string(),
        body: Some(Body::Submit(Submit {
            group_id: hex::decode("deadbeef")?,
            ciphertext: b"hello from ws_client".to_vec(),
            message_id: uuid::Uuid::now_v7().to_string(),
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            sealed_sender: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        })),
    };
    send_frame(&mut socket, &submit_frame).await?;
    println!("→ Submit · group=deadbeef");

    let submit_ack = recv_frame(&mut socket).await?;
    match submit_ack.body {
        Some(Body::Ack(a)) => println!(
            "← Ack · acked={} code={} msg={}",
            a.acked_frame_id, a.error_code, a.error_message
        ),
        other => anyhow::bail!("expected Ack for Submit, got {:?}", other),
    }

    socket.close(None).await?;
    println!("→ close · clean exit");
    Ok(())
}

async fn send_frame<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    frame: &WsFrame,
) -> anyhow::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut buf = Vec::with_capacity(frame.encoded_len());
    frame.encode(&mut buf)?;
    socket.send(Message::Binary(buf.into())).await?;
    Ok(())
}

async fn recv_frame<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
) -> anyhow::Result<WsFrame>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let msg = timeout(Duration::from_secs(15), socket.next())
        .await?
        .ok_or_else(|| anyhow::anyhow!("connection closed"))??;
    match msg {
        Message::Binary(b) => Ok(WsFrame::decode(b.as_ref())?),
        other => anyhow::bail!("expected binary frame, got {:?}", other),
    }
}
