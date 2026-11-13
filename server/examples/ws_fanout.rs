// Two-client fanout smoke — proves Alice → server → Bob via WS Push.
//
// Preconditions (set up via curl before running this):
//   1. POST /v1/identity for Alice (seed = ALICE_SEED, with primary_device)
//   2. POST /v1/identity for Bob   (seed = BOB_SEED,   with primary_device)
//   3. POST /v1/groups linking Alice + Bob into one group
//
// Then `cargo run --example ws_fanout`:
//   • Task B (Bob): connects WS → auth → expects a Push within 10s,
//                   prints contents, exits 0
//   • Task A (Alice): waits ~1s → connects WS → auth → Submit a fake
//                     encrypted blob → expects Ack code=0, exits 0
//
// Exits 0 iff Bob received Alice's message.

use std::time::Duration;

use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use prost::Message as ProstMessage;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::SEC_WEBSOCKET_PROTOCOL;
use tokio_tungstenite::tungstenite::protocol::Message;

use sinhron_server::proto::ws_frame::Body;
use sinhron_server::proto::{Auth, Submit, WsFrame};

const WS_AUTH_DOMAIN: &[u8] = b"sinhron-ws-auth-v1:";

// Exactly 64 hex chars = 32 bytes each.
const ALICE_SEED_HEX: &str =
    "4242424242424242424242424242424242424242424242424242424242424242";
const BOB_SEED_HEX: &str =
    "1717171717171717171717171717171717171717171717171717171717171717";
const GROUP_ID_HEX: &str = "deadbeef";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "ws://localhost:8080/v1/sync".to_string());

    let alice_seed = parse_seed(ALICE_SEED_HEX);
    let bob_seed = parse_seed(BOB_SEED_HEX);

    let url_b = url.clone();
    let bob = tokio::spawn(async move { bob_task(&url_b, bob_seed).await });

    // Small delay so Bob is registered in SessionRegistry before Alice
    // sends. In production, a "join" RTT or push-and-buffer would replace
    // this — for the smoke we just sleep.
    tokio::time::sleep(Duration::from_millis(500)).await;

    let alice = tokio::spawn(async move { alice_task(&url, alice_seed).await });

    let alice_result = alice.await??;
    let bob_result = timeout(Duration::from_secs(8), bob).await???;

    println!("alice: {alice_result}");
    println!("bob:   {bob_result}");
    println!("✓ fanout end-to-end");
    Ok(())
}

async fn alice_task(url: &str, seed: [u8; 32]) -> anyhow::Result<String> {
    let sk = SigningKey::from_bytes(&seed);
    let pk = sk.verifying_key().to_bytes();

    let mut socket = ws_connect(url).await?;

    // Hello
    let hello = recv_frame(&mut socket).await?;
    let challenge = match hello.body {
        Some(Body::Hello(h)) => h.challenge_nonce,
        _ => anyhow::bail!("alice: expected Hello"),
    };

    // Auth
    auth(&mut socket, &sk, &pk, &challenge).await?;
    expect_ack(&mut socket, 0).await?;

    // Submit
    let message_id = uuid::Uuid::now_v7().to_string();
    let submit = WsFrame {
        frame_id: "alice-submit-1".to_string(),
        body: Some(Body::Submit(Submit {
            group_id: hex::decode(GROUP_ID_HEX)?,
            ciphertext: b"hello from alice".to_vec(),
            message_id: message_id.clone(),
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            sealed_sender: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        })),
    };
    send_frame(&mut socket, &submit).await?;

    expect_ack(&mut socket, 0).await?;
    socket.close(None).await?;
    Ok(format!("Submit ok · message_id={message_id}"))
}

async fn bob_task(url: &str, seed: [u8; 32]) -> anyhow::Result<String> {
    let sk = SigningKey::from_bytes(&seed);
    let pk = sk.verifying_key().to_bytes();

    let mut socket = ws_connect(url).await?;

    let hello = recv_frame(&mut socket).await?;
    let challenge = match hello.body {
        Some(Body::Hello(h)) => h.challenge_nonce,
        _ => anyhow::bail!("bob: expected Hello"),
    };
    auth(&mut socket, &sk, &pk, &challenge).await?;
    expect_ack(&mut socket, 0).await?; // auth ack

    // Wait for a Push frame within 5 seconds.
    loop {
        let frame = timeout(Duration::from_secs(5), recv_frame(&mut socket)).await??;
        match frame.body {
            Some(Body::Push(p)) => {
                let body_str = String::from_utf8_lossy(&p.ciphertext).into_owned();
                socket.close(None).await?;
                return Ok(format!(
                    "got Push · message_id={} · body={body_str:?}",
                    p.message_id
                ));
            }
            Some(other) => {
                // Could be a Heartbeat echo or stray Ack; ignore and keep waiting.
                eprintln!("bob: ignoring non-Push frame {:?}", std::mem::discriminant(&other));
            }
            None => {}
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Wire helpers
// ─────────────────────────────────────────────────────────────────────

async fn ws_connect(
    url: &str,
) -> anyhow::Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>> {
    let mut req = url.into_client_request()?;
    req.headers_mut()
        .insert(SEC_WEBSOCKET_PROTOCOL, "sinhron.v1".parse()?);
    let (socket, _resp) = tokio_tungstenite::connect_async(req).await?;
    Ok(socket)
}

async fn auth<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    sk: &SigningKey,
    pk: &[u8; 32],
    challenge: &[u8],
) -> anyhow::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut msg = Vec::new();
    msg.extend_from_slice(WS_AUTH_DOMAIN);
    msg.extend_from_slice(challenge);
    let sig = sk.sign(&sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg)).to_bytes().to_vec();
    let auth = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Auth(Auth {
            identity_pubkey: pk.to_vec(),
            signature: sig,
        })),
    };
    send_frame(socket, &auth).await
}

async fn expect_ack<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    expected_code: i32,
) -> anyhow::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let frame = recv_frame(socket).await?;
    match frame.body {
        Some(Body::Ack(a)) if a.error_code == expected_code => Ok(()),
        Some(Body::Ack(a)) => anyhow::bail!(
            "ack error: code={} msg={}",
            a.error_code,
            a.error_message
        ),
        other => anyhow::bail!("expected Ack, got {:?}", other),
    }
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

fn parse_seed(hex_str: &str) -> [u8; 32] {
    let bytes = hex::decode(hex_str.trim()).expect("seed must be hex");
    bytes.try_into().expect("seed must be 32 bytes")
}
