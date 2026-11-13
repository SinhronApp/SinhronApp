// Regression test for CN-20 (security audit 2026-11b): a login alone does not
// reset the reconnect back-off. A server that accepts the login and hangs up
// at once used to get a full login every reconnect_initial, forever.
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use prost::Message as _;
use sinhron_net::proto::{ws_frame::Body, Ack, Hello, WsFrame};
use sinhron_net::{Event, Keepalive, WsClient, WsClientConfig};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::Message;

fn encode(frame: &WsFrame) -> Message {
    let mut buf = Vec::new();
    frame.encode(&mut buf).unwrap();
    Message::Binary(buf.into())
}

fn ack(msg: String) -> WsFrame {
    WsFrame { frame_id: String::new(), body: Some(Body::Ack(Ack { acked_frame_id: String::new(), error_code: 0, error_message: msg })) }
}

/// Fake 127.0.0.1 server: Hello -> Auth -> Ack(0), then `after` runs with the socket.
async fn start_server<F, Fut>(conns: Arc<AtomicUsize>, after: F) -> String
where
    F: Fn(tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) -> Fut + Send + Sync + Clone + 'static,
    Fut: std::future::Future<Output = ()> + Send + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { return };
            let conns = conns.clone();
            let after = after.clone();
            tokio::spawn(async move {
                let cb = |_r: &Request, mut resp: Response| {
                    resp.headers_mut().insert("Sec-WebSocket-Protocol", HeaderValue::from_static("sinhron.v1"));
                    Ok(resp)
                };
                let Ok(mut ws) = tokio_tungstenite::accept_hdr_async(tcp, cb).await else { return };
                conns.fetch_add(1, Ordering::SeqCst);
                let hello = WsFrame { frame_id: String::new(), body: Some(Body::Hello(Hello { server_version: "fake".into(), server_time: 0, challenge_nonce: vec![7; 32] })) };
                if ws.send(encode(&hello)).await.is_err() { return; }
                let Some(Ok(Message::Binary(_auth))) = ws.next().await else { return };
                if ws.send(encode(&ack(String::new()))).await.is_err() { return; }
                after(ws).await;
            });
        }
    });
    format!("ws://{addr}/v1/sync")
}

fn config(url: &str) -> WsClientConfig {
    WsClientConfig { url: url.to_string(), identity_seed: [42; 32], tls: None, resume_cursor: None }
}

#[tokio::test]
async fn a_server_that_drops_after_login_is_backed_off() {
    let conns = Arc::new(AtomicUsize::new(0));
    let url = start_server(conns.clone(), |mut ws| async move {
        let _ = ws.close(None).await; // accept the login, hang up immediately
    })
    .await;
    let ka = Keepalive {
        reconnect_initial: Duration::from_millis(100),
        reconnect_max: Duration::from_secs(5),
        ..Keepalive::default()
    };
    let client = WsClient::start_with_keepalive(config(&url), ka);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let mut connected = 0;
    while let Ok(Some(ev)) = tokio::time::timeout_at(deadline, client.recv()).await {
        if matches!(ev, Event::Connected) { connected += 1; }
    }
    client.shutdown();
    let n = conns.load(Ordering::SeqCst);
    println!("logins in 3 s: server saw {n}, client reported Connected {connected} times");
    // Doubling from 100 ms: 100+200+400+800+1600 ms -> about 5 logins in 3 s
    // (it was 25+ with the reset on every login).
    assert!((2..=7).contains(&n), "expected exponential back-off, got {n} logins in 3 s");
}
