// Regression test for CN-21 (security audit 2026-11b): a socket write has a
// time limit. A server that keeps TCP open but stops reading used to freeze
// the session inside the write — no watchdog, no shutdown.
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
async fn stalled_write_ends_the_session_and_shutdown_works() {
    let conns = Arc::new(AtomicUsize::new(0));
    let url = start_server(conns.clone(), |ws| async move {
        // Keep the socket open, never read, never write.
        tokio::time::sleep(Duration::from_secs(30)).await;
        drop(ws);
    })
    .await;
    let ka = Keepalive {
        heartbeat: Duration::from_millis(100),
        background_heartbeat: Duration::from_secs(1),
        server_silence: Duration::from_millis(450),
        reply_timeout: Duration::from_millis(250),
        reconnect_initial: Duration::from_millis(50),
        reconnect_max: Duration::from_millis(200),
        connect_timeout: Duration::from_millis(500),
    };
    let client = WsClient::start_with_keepalive(config(&url), ka);
    assert!(matches!(client.recv().await, Some(Event::Connected)));
    // 48 x 1 MiB frames — far more than the loopback socket buffers hold.
    for _ in 0..48 {
        client.send(ack("B".repeat(1 << 20))).await.unwrap();
    }
    // The stuck write is given up after reply_timeout and the session ends.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    let reason = loop {
        match tokio::time::timeout_at(deadline, client.recv()).await {
            Ok(Some(Event::Disconnected { reason })) => break reason,
            Ok(Some(_)) => {}
            other => panic!("no Disconnected within 3 s of a stalled write: {other:?}"),
        }
    };
    println!("disconnected: {reason}");

    // shutdown() stops the run loop even if it is in a stalled write again.
    client.shutdown();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        match tokio::time::timeout_at(deadline, client.recv()).await {
            Ok(None) => break,
            Ok(Some(_)) => {}
            Err(_) => panic!("run loop still alive 3 s after shutdown()"),
        }
    }
}
