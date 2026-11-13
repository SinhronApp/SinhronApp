// Connection keepalive + reconnect storms (tech-debt 2.8 / 2.10), against
// an in-process fake server that speaks the real handshake: Hello →
// Auth → Ack, then optionally echoes Heartbeats or closes the socket.
// Battery 2026-10-18: the background heartbeat gap and network changes.

use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use prost::Message as _;
use sinhron_net::proto::{ws_frame::Body, Ack, Heartbeat, Hello, WsFrame};
use sinhron_net::{Event, Keepalive, WsClient, WsClientConfig};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::Message;

/// The leak checks count every file descriptor of this test process, so
/// the tests here run one at a time — another test's sockets made them
/// fail at random (2026-10-22).
static SERIAL: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[derive(Default)]
struct Server {
    connections: AtomicUsize,
    heartbeats: AtomicU64,
    /// Echo client heartbeats (a healthy server does).
    echo: AtomicBool,
    /// Close each session right after authenticating it.
    drop_after_auth: AtomicBool,
    /// Cursor of the last Resume the client sent (0 = none).
    resumed_from: AtomicU64,
    resumes: AtomicUsize,
    /// Accept the heartbeat gap a client asks for (a server from
    /// 2026-10-18 on); off = an older server, its replies say 0.
    grant: AtomicBool,
    /// `next_within_secs` of every heartbeat, in order.
    asked: Mutex<Vec<u32>>,
    /// The last Auth: (key, signature).
    auth: Mutex<Option<(Vec<u8>, Vec<u8>)>>,
}

fn encode(frame: &WsFrame) -> Message {
    let mut buf = Vec::new();
    frame.encode(&mut buf).unwrap();
    Message::Binary(buf.into())
}

async fn start_server(server: Arc<Server>) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { return };
            let server = server.clone();
            tokio::spawn(async move {
                let callback = |_req: &Request, mut resp: Response| {
                    resp.headers_mut().insert("Sec-WebSocket-Protocol", HeaderValue::from_static("sinhron.v1"));
                    Ok(resp)
                };
                let Ok(mut ws) = tokio_tungstenite::accept_hdr_async(tcp, callback).await else { return };
                server.connections.fetch_add(1, Ordering::SeqCst);
                let hello = WsFrame {
                    frame_id: String::new(),
                    body: Some(Body::Hello(Hello { server_version: "fake".into(), server_time: 0, challenge_nonce: vec![7; 32] })),
                };
                if ws.send(encode(&hello)).await.is_err() {
                    return;
                }
                // Auth — kept, not verified here; the real server does that.
                let Some(Ok(Message::Binary(auth))) = ws.next().await else { return };
                if let Ok(WsFrame { body: Some(Body::Auth(a)), .. }) = WsFrame::decode(auth.as_ref()) {
                    *server.auth.lock().unwrap() = Some((a.identity_pubkey, a.signature));
                }
                let ack = WsFrame {
                    frame_id: String::new(),
                    body: Some(Body::Ack(Ack { acked_frame_id: String::new(), error_code: 0, error_message: String::new() })),
                };
                if ws.send(encode(&ack)).await.is_err() {
                    return;
                }
                if server.drop_after_auth.load(Ordering::SeqCst) {
                    let _ = ws.close(None).await;
                    return;
                }
                while let Some(Ok(msg)) = ws.next().await {
                    if let Message::Binary(bytes) = msg {
                        if let Ok(WsFrame { body: Some(Body::Resume(r)), .. }) = WsFrame::decode(bytes.as_ref()) {
                            server.resumes.fetch_add(1, Ordering::SeqCst);
                            let c = r.cursors.first().map(|c| c.last_acked_seq).unwrap_or(0);
                            server.resumed_from.store(c, Ordering::SeqCst);
                            continue;
                        }
                        if let Ok(WsFrame { body: Some(Body::Heartbeat(h)), .. }) = WsFrame::decode(bytes.as_ref()) {
                            server.heartbeats.fetch_add(1, Ordering::SeqCst);
                            server.asked.lock().unwrap().push(h.next_within_secs);
                            if server.echo.load(Ordering::SeqCst) {
                                let granted = if server.grant.load(Ordering::SeqCst) { h.next_within_secs } else { 0 };
                                let echo = WsFrame {
                                    frame_id: String::new(),
                                    body: Some(Body::Heartbeat(Heartbeat { sequence: 0, next_within_secs: granted })),
                                };
                                if ws.send(encode(&echo)).await.is_err() {
                                    return;
                                }
                            }
                        }
                    }
                }
            });
        }
    });
    format!("ws://{addr}/v1/sync")
}

fn config(url: &str) -> WsClientConfig {
    WsClientConfig { url: url.to_string(), identity_seed: [42; 32], tls: None, resume_cursor: None }
}

fn fast() -> Keepalive {
    Keepalive {
        heartbeat: Duration::from_millis(100),
        // Whole seconds on the wire (`next_within_secs`).
        background_heartbeat: Duration::from_secs(1),
        server_silence: Duration::from_millis(450),
        reply_timeout: Duration::from_millis(250),
        reconnect_initial: Duration::from_millis(5),
        reconnect_max: Duration::from_millis(20),
        connect_timeout: Duration::from_millis(300),
    }
}

/// Collect events for [dur] (the client keeps running).
async fn events_for(client: &WsClient, dur: Duration) -> Vec<Event> {
    let mut out = Vec::new();
    let deadline = tokio::time::Instant::now() + dur;
    while let Ok(Some(ev)) = tokio::time::timeout_at(deadline, client.recv()).await {
        out.push(ev);
    }
    out
}

fn open_fds() -> usize {
    std::fs::read_dir("/dev/fd").map(|d| d.count()).unwrap_or(0)
}

#[tokio::test]
async fn heartbeats_keep_a_quiet_session_alive() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let client = WsClient::start_with_keepalive(config(&url), fast());

    let events = events_for(&client, Duration::from_millis(1_200)).await;
    client.shutdown();

    assert!(matches!(events.first(), Some(Event::Connected)));
    assert!(
        !events.iter().any(|e| matches!(e, Event::Disconnected { .. })),
        "a quiet but healthy session must not drop: {events:?}"
    );
    assert!(!events.iter().any(|e| matches!(e, Event::Frame(_))), "heartbeat echoes are not surfaced");
    assert_eq!(server.connections.load(Ordering::SeqCst), 1);
    assert!(server.heartbeats.load(Ordering::SeqCst) >= 8, "client heartbeats every 100 ms");
}

#[tokio::test]
async fn a_silent_server_is_detected_and_the_client_reconnects() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default()); // no echo: half-open link
    let url = start_server(server.clone()).await;
    let client = WsClient::start_with_keepalive(config(&url), fast());

    let events = events_for(&client, Duration::from_millis(1_500)).await;
    client.shutdown();

    let silent = events
        .iter()
        .filter(|e| {
            matches!(e, Event::Disconnected { reason } if reason.contains("server silent") || reason.contains("no reply"))
        })
        .count();
    assert!(silent >= 1, "silence must be noticed: {events:?}");
    assert!(server.connections.load(Ordering::SeqCst) >= 2, "and the client reconnects");
}

/// Tech-debt 2.8 — a server that drops every session right after auth:
/// the client must keep reconnecting without leaking sockets or tasks.
#[tokio::test]
async fn reconnect_storm_does_not_leak() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.drop_after_auth.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let before = open_fds();

    let client = WsClient::start_with_keepalive(config(&url), fast());
    let mut connected = 0;
    while connected < 100 {
        match tokio::time::timeout(Duration::from_secs(5), client.recv()).await {
            Ok(Some(Event::Connected)) => connected += 1,
            Ok(Some(_)) => {}
            other => panic!("storm stalled after {connected} reconnects: {other:?}"),
        }
    }
    client.shutdown();
    tokio::time::sleep(Duration::from_millis(200)).await;

    assert!(server.connections.load(Ordering::SeqCst) >= 100);
    let after = open_fds();
    assert!(after <= before + 8, "file descriptors leaked: {before} → {after}");
}

/// 100 independent clients started and shut down back to back.
#[tokio::test]
async fn start_shutdown_cycles_do_not_leak() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let before = open_fds();
    for i in 0..100 {
        let client = WsClient::start_with_keepalive(config(&url), fast());
        match tokio::time::timeout(Duration::from_secs(5), client.recv()).await {
            Ok(Some(Event::Connected)) => {}
            other => panic!("cycle {i}: {other:?}"),
        }
        client.shutdown();
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    let after = open_fds();
    assert!(after <= before + 8, "file descriptors leaked: {before} → {after}");
}

/// Bug 2026-10-16 — a fresh client (the app back from the background, or
/// restarted) resumes from what the app had consumed, so what a dead
/// connection swallowed is sent again. Without a cursor: no Resume.
#[tokio::test]
async fn a_fresh_client_resumes_from_the_shared_cursor() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;

    let plain = WsClient::start_with_keepalive(config(&url), fast());
    events_for(&plain, Duration::from_millis(300)).await;
    plain.shutdown();
    assert_eq!(server.resumes.load(Ordering::SeqCst), 0, "nothing consumed yet → no Resume");

    let cursor = Arc::new(AtomicU64::new(42));
    let resumed = WsClient::start_with_keepalive(
        WsClientConfig { resume_cursor: Some(cursor.clone()), ..config(&url) },
        fast(),
    );
    events_for(&resumed, Duration::from_millis(300)).await;
    assert_eq!(server.resumes.load(Ordering::SeqCst), 1);
    assert_eq!(server.resumed_from.load(Ordering::SeqCst), 42);
    resumed.shutdown();
}

async fn connected(client: &WsClient) {
    loop {
        match tokio::time::timeout(Duration::from_secs(5), client.recv()).await {
            Ok(Some(Event::Connected)) => return,
            Ok(Some(_)) => {}
            other => panic!("never connected: {other:?}"),
        }
    }
}

fn beats(server: &Server) -> u64 {
    server.heartbeats.load(Ordering::SeqCst)
}

/// Battery 2026-10-18 — in the background the client asks for the long
/// gap, uses it once the server agrees, and drops back to the short one
/// (with a heartbeat at once) when the app comes back.
#[tokio::test]
async fn the_background_gap_is_used_once_the_server_agrees() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    server.grant.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let client = WsClient::start_with_keepalive(config(&url), fast());
    connected(&client).await;
    tokio::time::sleep(Duration::from_millis(350)).await;
    assert!(beats(&server) >= 2, "foreground: every 100 ms");
    assert!(server.asked.lock().unwrap().iter().all(|&a| a == 0), "the foreground asks for nothing");

    client.set_background(true);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let at_switch = beats(&server);
    assert_eq!(server.asked.lock().unwrap().last(), Some(&1), "asks for its gap right away");
    let events = events_for(&client, Duration::from_millis(2_300)).await;
    let in_background = beats(&server) - at_switch;
    assert!((1..=3).contains(&in_background), "about one heartbeat a second, not 23: {in_background}");
    assert!(!events.iter().any(|e| matches!(e, Event::Disconnected { .. })), "the long gap is no disconnect: {events:?}");

    client.set_background(false);
    tokio::time::sleep(Duration::from_millis(50)).await;
    let back = beats(&server);
    assert!(back > at_switch + in_background, "a heartbeat at once on coming back");
    assert_eq!(server.asked.lock().unwrap().last(), Some(&0));
    tokio::time::sleep(Duration::from_millis(550)).await;
    assert!(beats(&server) - back >= 4, "and every 100 ms again");
    assert_eq!(server.connections.load(Ordering::SeqCst), 1);
    client.shutdown();
}

/// A server from before 2026-10-18 replies 0: the client keeps the short
/// gap in the background too (the server would drop it at 45 s otherwise).
#[tokio::test]
async fn an_older_server_keeps_the_short_gap() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let client = WsClient::start_with_keepalive(config(&url), fast());
    connected(&client).await;
    client.set_background(true);
    tokio::time::sleep(Duration::from_millis(50)).await;
    let at_switch = beats(&server);
    tokio::time::sleep(Duration::from_millis(1_000)).await;
    assert!(beats(&server) - at_switch >= 7, "still every 100 ms");
    assert!(server.asked.lock().unwrap().iter().any(|&a| a == 1), "it did ask");
    client.shutdown();
}

/// With the long gap a dead link is caught by the reply timeout after a
/// heartbeat, not a whole gap later.
#[tokio::test]
async fn a_dead_link_in_the_background_is_caught_after_one_heartbeat() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    server.grant.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let client = WsClient::start_with_keepalive(config(&url), fast());
    connected(&client).await;
    client.set_background(true);
    tokio::time::sleep(Duration::from_millis(200)).await; // granted
    server.echo.store(false, Ordering::SeqCst); // half-open from here
    let started = tokio::time::Instant::now();
    let reason = loop {
        match tokio::time::timeout(Duration::from_secs(3), client.recv()).await {
            Ok(Some(Event::Disconnected { reason })) => break reason,
            Ok(Some(_)) => {}
            other => panic!("dead link not noticed: {other:?}"),
        }
    };
    assert!(reason.contains("no reply"), "{reason}");
    // Next heartbeat ≤ 1 s, then 250 ms for its reply.
    assert!(started.elapsed() < Duration::from_millis(1_600), "took {:?}", started.elapsed());
    connected(&client).await;
    client.shutdown();
}

/// Wi-Fi ↔ mobile: the socket on the old network is dropped and a new one
/// opened at once.
#[tokio::test]
async fn a_network_change_reconnects_at_once() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.echo.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let mut keepalive = fast();
    keepalive.reconnect_initial = Duration::from_secs(5); // no back-off is what's tested
    let client = WsClient::start_with_keepalive(config(&url), keepalive);
    connected(&client).await;

    client.network_changed();
    let started = tokio::time::Instant::now();
    match tokio::time::timeout(Duration::from_secs(2), client.recv()).await {
        Ok(Some(Event::Disconnected { reason })) => assert!(reason.contains("network changed"), "{reason}"),
        other => panic!("{other:?}"),
    }
    connected(&client).await;
    assert!(started.elapsed() < Duration::from_secs(1), "took {:?}", started.elapsed());
    assert_eq!(server.connections.load(Ordering::SeqCst), 2);
    client.shutdown();
}

/// Offline and waiting out a back-off: a new network cuts the wait short.
#[tokio::test]
async fn a_network_change_cuts_the_backoff_short() {
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    server.drop_after_auth.store(true, Ordering::SeqCst);
    let url = start_server(server.clone()).await;
    let mut keepalive = fast();
    keepalive.reconnect_initial = Duration::from_secs(10);
    keepalive.reconnect_max = Duration::from_secs(10);
    let client = WsClient::start_with_keepalive(config(&url), keepalive);
    connected(&client).await;
    match tokio::time::timeout(Duration::from_secs(2), client.recv()).await {
        Ok(Some(Event::Disconnected { .. })) => {}
        other => panic!("{other:?}"),
    }
    tokio::time::sleep(Duration::from_millis(100)).await; // in the 10 s back-off now
    let started = tokio::time::Instant::now();
    client.network_changed();
    connected(&client).await;
    assert!(started.elapsed() < Duration::from_secs(1), "took {:?}", started.elapsed());
    client.shutdown();
}

/// Owner, 2026-10-20: behind a VPN a phone said "Connecting…" forever. A
/// server that takes the TCP connection and then says nothing (a stalled
/// TLS / upgrade) must end in Disconnected and another try, not a hang.
#[tokio::test]
async fn a_connect_that_stalls_times_out_and_is_retried() {
    let _serial = SERIAL.lock().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let accepted = Arc::new(AtomicUsize::new(0));
    let seen = accepted.clone();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((tcp, _)) = listener.accept().await {
            seen.fetch_add(1, Ordering::SeqCst);
            held.push(tcp); // open, silent
        }
    });
    let client = WsClient::start_with_keepalive(config(&format!("ws://{addr}/v1/sync")), fast());
    let events = events_for(&client, Duration::from_millis(1_200)).await;
    client.shutdown();
    assert!(
        events.iter().any(|e| matches!(e, Event::Disconnected { reason } if reason.contains("no connection to the server"))),
        "a stalled connect must fail: {events:?}"
    );
    assert!(accepted.load(Ordering::SeqCst) >= 2, "and be tried again");
}

/// ADR-086 (mls-identity:5) — the login names the server by the name in
/// the app's URL, not by the address it dialed (as with a DNS fallback,
/// ADR-072), so a login a hostile server took can't be used on another.
#[tokio::test]
async fn the_login_names_the_server_by_its_url_name_not_the_dialed_address() {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    let _serial = SERIAL.lock().await;
    let server = Arc::new(Server::default());
    let url = start_server(server.clone()).await.replace("127.0.0.1", "LocalHost");
    let client = WsClient::start_with_keepalive(config(&url), fast());
    connected(&client).await;
    client.shutdown();

    let (pk, sig) = server.auth.lock().unwrap().clone().expect("an Auth came");
    let vk = VerifyingKey::from_bytes(&pk.try_into().unwrap()).unwrap();
    let sig = Signature::from_slice(&sig).unwrap();
    let mut login = sinhron_net::WS_AUTH_DOMAIN.to_vec();
    login.extend_from_slice(&[7; 32]);
    assert!(vk.verify(&sinhron_net::bind_to_host("localhost", &login), &sig).is_ok(), "bound to the URL's name");
    assert!(vk.verify(&sinhron_net::bind_to_host("127.0.0.1", &login), &sig).is_err(), "not to the address");
    assert!(vk.verify(&login, &sig).is_err(), "never unbound");
}
