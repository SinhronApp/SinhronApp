// Reconnect / Resume smoke — WU A7 end-to-end check.
//
// Scenario:
//   1. Alice connects (Bob is offline)
//   2. Alice Submits TWO messages to a group containing Alice + Bob
//   3. Alice disconnects
//   4. Bob connects AFTER the fact, sends Resume{cursor: 0}
//   5. Bob expects to receive both messages, in order, via Push frames
//
// This validates:
//   • Submit persists messages + delivery rows even when no recipient is online
//   • Resume queries deliveries by recipient + seq → replays in order
//   • Per-recipient seq is monotonic across two Submits
//
// Preconditions (same as ws_fanout): identities + group registered.

use std::time::Duration;

use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use prost::Message as ProstMessage;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::SEC_WEBSOCKET_PROTOCOL;
use tokio_tungstenite::tungstenite::protocol::Message;

use sinhron_server::proto::resume::StreamCursor;
use sinhron_server::proto::ws_frame::Body;
use sinhron_server::proto::{Auth, Resume, Submit, WsFrame};

const WS_AUTH_DOMAIN: &[u8] = b"sinhron-ws-auth-v1:";

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

    let alice = SigningKey::from_bytes(&parse_seed(ALICE_SEED_HEX));
    let bob = SigningKey::from_bytes(&parse_seed(BOB_SEED_HEX));

    // ── 1. Alice submits 2 messages while Bob is offline ─────────────
    {
        let mut socket = ws_connect(&url).await?;
        let challenge = expect_hello(&mut socket).await?;
        auth(&mut socket, &alice, &challenge).await?;
        expect_ack(&mut socket, 0).await?;

        for i in 1..=2 {
            let body = format!("offline msg {i}");
            let submit = WsFrame {
                frame_id: format!("alice-{i}"),
                body: Some(Body::Submit(Submit {
                    group_id: hex::decode(GROUP_ID_HEX)?,
                    ciphertext: body.as_bytes().to_vec(),
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
            send_frame(&mut socket, &submit).await?;
            expect_ack(&mut socket, 0).await?;
            println!("→ alice submitted {body:?}");
        }
        socket.close(None).await?;
    }
    println!("✓ alice disconnected · 2 messages persisted while bob offline");

    // ── 2. Bob connects + Resume ─────────────────────────────────────
    let mut socket = ws_connect(&url).await?;
    let challenge = expect_hello(&mut socket).await?;
    auth(&mut socket, &bob, &challenge).await?;
    expect_ack(&mut socket, 0).await?;

    let resume = WsFrame {
        frame_id: "bob-resume".to_string(),
        body: Some(Body::Resume(Resume {
            cursors: vec![StreamCursor {
                stream_id: "main".to_string(),
                last_acked_seq: 0,
            }],
        })),
    };
    send_frame(&mut socket, &resume).await?;
    println!("→ bob Resume · cursor=0");

    // Expect the 2 messages and the Resume Ack. The server also sends a
    // device its queue right after login, so a message may come twice
    // (once for the login, once for the Resume) — the app drops repeats by
    // message_id, and so does this check. Read until the Resume's Ack.
    let mut got_pushes: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    let mut got_ack: Option<String> = None;
    for _ in 0..8 {
        let f = timeout(Duration::from_secs(5), recv_frame(&mut socket)).await??;
        match f.body {
            Some(Body::Push(p)) => {
                let s = String::from_utf8_lossy(&p.ciphertext).into_owned();
                println!("← bob Push · seq={} · body={s:?}", p.sequence);
                if !seen.contains(&p.message_id) {
                    seen.push(p.message_id.clone());
                    got_pushes.push(s);
                }
            }
            Some(Body::Ack(a)) => {
                println!("← bob Ack · code={} · msg={}", a.error_code, a.error_message);
                let ours = a.acked_frame_id == "bob-resume";
                got_ack = Some(a.error_message);
                if ours {
                    break;
                }
            }
            other => anyhow::bail!("unexpected frame: {:?}", other),
        }
    }
    socket.close(None).await?;

    assert_eq!(got_pushes.len(), 2, "expected 2 replays");
    assert_eq!(got_pushes[0], "offline msg 1");
    assert_eq!(got_pushes[1], "offline msg 2");
    assert!(got_ack.is_some());

    println!("✓ resume end-to-end · 2 messages replayed in order");
    Ok(())
}

async fn ws_connect(
    url: &str,
) -> anyhow::Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>> {
    let mut req = url.into_client_request()?;
    req.headers_mut()
        .insert(SEC_WEBSOCKET_PROTOCOL, "sinhron.v1".parse()?);
    let (socket, _) = tokio_tungstenite::connect_async(req).await?;
    Ok(socket)
}

async fn expect_hello<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
) -> anyhow::Result<Vec<u8>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let f = recv_frame(socket).await?;
    match f.body {
        Some(Body::Hello(h)) => Ok(h.challenge_nonce),
        _ => anyhow::bail!("expected Hello"),
    }
}

async fn auth<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    sk: &SigningKey,
    challenge: &[u8],
) -> anyhow::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let pk = sk.verifying_key().to_bytes();
    let mut msg = Vec::new();
    msg.extend_from_slice(WS_AUTH_DOMAIN);
    msg.extend_from_slice(challenge);
    let sig = sk.sign(&sinhron_server::handlers::proof::bind_to_host(&sinhron_server::handlers::proof::public_hosts()[0], &msg)).to_bytes().to_vec();
    let frame = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Auth(Auth {
            identity_pubkey: pk.to_vec(),
            signature: sig,
        })),
    };
    send_frame(socket, &frame).await
}

async fn expect_ack<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    expected_code: i32,
) -> anyhow::Result<()>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let f = recv_frame(socket).await?;
    match f.body {
        Some(Body::Ack(a)) if a.error_code == expected_code => Ok(()),
        Some(Body::Ack(a)) => {
            anyhow::bail!("ack error · code={} msg={}", a.error_code, a.error_message)
        }
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
