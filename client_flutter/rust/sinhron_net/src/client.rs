// WS client — channel-based API + auto-reconnect.
//
// Architecture (post-B2):
//
//     ┌─────────────────────────────────────────────────────────────┐
//     │  WsClient (handle) ──── outbound_tx ┐                        │
//     │            ▲                        │                        │
//     │            └── inbound_rx ── events ┤                        │
//     └──────────────────────────────────────┼───────────────────────┘
//                                            │
//          spawned `run_loop` task           ▼
//          ┌──────────────────────────────────────────────┐
//          │  loop {                                       │
//          │    handshake() — connect + Hello/Auth/Ack     │
//          │    spawn writer(sink, outbound_rx)            │
//          │    spawn reader(stream, inbound_tx)           │
//          │    join either → exponential backoff → retry  │
//          │  } until shutdown signal                      │
//          └──────────────────────────────────────────────┘
//
// What the caller sees: a single struct with `send(frame).await` and
// `recv().await -> Event`. Reconnect is automatic — events emit
// `Connected` / `Disconnected` so the UI can show network state. The
// Resume cursor is tracked across reconnects so missed messages get
// replayed automatically.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use ed25519_dalek::{Signer, SigningKey};
use futures_util::{SinkExt, StreamExt};
use prost::Message as ProstMessage;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch, Mutex, Notify};
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::header::SEC_WEBSOCKET_PROTOCOL;
use tokio_tungstenite::tungstenite::protocol::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use tracing::{debug, info, warn};

use crate::proto::{
    resume::StreamCursor, ws_frame::Body, Auth, Heartbeat, Resume, WsFrame,
};

/// WebSocket subprotocol negotiated against the server.
pub const SUBPROTOCOL: &str = "sinhron.v1";
/// Domain-separation prefix for the WS auth signature (must match
/// server's `WS_AUTH_DOMAIN`).
pub const WS_AUTH_DOMAIN: &[u8] = b"sinhron-ws-auth-v1:";
/// ADR-086 — the prefix that binds a signature to one server's name
/// (mirror of the server's `proof::SERVER_HOST_DOMAIN`).
pub const SERVER_HOST_DOMAIN: &[u8] = b"sinhron-server-host-v1:";

/// ADR-086 — the server name a signature is bound to: the host of the
/// URL the app was set up with, lowercased, without the port. Never the
/// address a DNS fallback dialed (ADR-072): the URL keeps the name.
pub fn url_host(url: &str) -> String {
    url.parse::<tokio_tungstenite::tungstenite::http::Uri>()
        .ok()
        .and_then(|u| u.host().map(str::to_ascii_lowercase))
        .unwrap_or_default()
}

/// ADR-086 — what is really signed for the server named `host`:
/// `SERVER_HOST_DOMAIN || host || 0x00 || msg` (WS login, every action
/// proof, registration). A server takes only its own names, so another
/// server can't pass the signature on to it.
pub fn bind_to_host(host: &str, msg: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(SERVER_HOST_DOMAIN.len() + host.len() + 1 + msg.len());
    m.extend_from_slice(SERVER_HOST_DOMAIN);
    m.extend_from_slice(host.as_bytes());
    m.push(0);
    m.extend_from_slice(msg);
    m
}

/// The WS login's signed bytes for `url`'s server (ADR-086).
fn ws_auth_message(url: &str, challenge: &[u8]) -> Vec<u8> {
    let mut msg = WS_AUTH_DOMAIN.to_vec();
    msg.extend_from_slice(challenge);
    bind_to_host(&url_host(url), &msg)
}
/// Per-phase handshake timeout.
const HANDSHAKE_TIMEOUT_SECS: u64 = 10;
/// CN-20: only a session that lived this long resets the reconnect back-off.
/// A server that accepts the login and drops at once is backed off like a
/// failed connect.
const STABLE_SESSION: Duration = Duration::from_secs(30);
/// Default [`Keepalive::connect_timeout`].
const CONNECT_TIMEOUT_SECS: u64 = 20;
/// Initial reconnect delay. Doubles each failure until [`RECONNECT_MAX_SECS`].
const RECONNECT_INITIAL_MS: u64 = 500;
const RECONNECT_MAX_SECS: u64 = 60;
/// Bounded outbound buffer — backpressure on caller if server is slow.
const OUTBOUND_BUFFER: usize = 256;

/// Connection timings. Protocol constants (proto §Heartbeat: client
/// ticks every 20 s; the server closes a session silent for 45 s, the
/// client drops one whose server is silent for 45 s — 2026-10-16, was
/// 30 / 75: a connection that went dead right after login, as from Russia
/// without VPN, kept swallowing pushes for over a minute), not
/// operator settings — they live in the phone app, where there is no
/// env to tune (tech-debt 2.10). Tests use short ones via
/// [`WsClient::start_with_keepalive`].
///
/// Battery 2026-10-18 — an Android phone with "always connected" (ADR-040)
/// keeps this connection all day, and every heartbeat wakes the mobile
/// radio (~10 s of high power each). In the background
/// ([`WsClient::set_background`]) the client asks the server for
/// [`Keepalive::background_heartbeat`] instead and uses it once the server
/// agrees (`Heartbeat.next_within_secs` in its reply; an older server
/// says 0 and the client stays at [`Keepalive::heartbeat`]).
#[derive(Debug, Clone, Copy)]
pub struct Keepalive {
    /// How often the client sends a Heartbeat frame.
    pub heartbeat: Duration,
    /// The gap in the background. 120 s: under the shortest idle timeouts
    /// commonly reported for mobile carrier NATs and home routers
    /// (~5 min) with room for a late timer on a sleeping phone; the
    /// server allows up to 300 s, Caddy's socket read timeout is 10 min.
    pub background_heartbeat: Duration,
    /// No frame at all from the server for this long → the connection
    /// is dead (half-open TCP after a network switch, a sleeping NAT):
    /// drop it and reconnect instead of waiting for the OS.
    pub server_silence: Duration,
    /// A heartbeat with no frame at all back for this long → the
    /// connection is dead. With the long background gap the silence rule
    /// above would need a whole gap more to notice.
    pub reply_timeout: Duration,
    /// First reconnect delay; doubles up to [`Keepalive::reconnect_max`].
    pub reconnect_initial: Duration,
    pub reconnect_max: Duration,
    /// TCP connect + TLS + WebSocket upgrade, together. Owner, 2026-10-20:
    /// with a VPN on, a friend's phone said "Connecting…" forever — a
    /// stalled TLS exchange never returned, so the client never failed and
    /// never retried.
    pub connect_timeout: Duration,
}

impl Default for Keepalive {
    fn default() -> Self {
        Self {
            heartbeat: Duration::from_secs(20),
            background_heartbeat: Duration::from_secs(120),
            server_silence: Duration::from_secs(45),
            reply_timeout: Duration::from_secs(30),
            reconnect_initial: Duration::from_millis(RECONNECT_INITIAL_MS),
            reconnect_max: Duration::from_secs(RECONNECT_MAX_SECS),
            connect_timeout: Duration::from_secs(CONNECT_TIMEOUT_SECS),
        }
    }
}

#[derive(Clone)]
pub struct WsClientConfig {
    /// Full URL, e.g. `wss://cabin.sinhron.app/v1/sync`.
    pub url: String,
    /// 32-byte Ed25519 identity seed (BIP-39 derived).
    pub identity_seed: [u8; 32],
    /// Optional TLS pinning (WU B3 — spec §6.1). When `Some`, the WS
    /// handshake trusts ONLY the bundled operator CA; any other valid
    /// chain (incl. webpki) is rejected. `None` falls back to the
    /// default tokio-tungstenite rustls connector — fine for dev
    /// (`ws://localhost`) and acceptable in early-prod.
    pub tls: Option<crate::tls::TlsPinning>,
    /// The last delivery sequence the app has CONSUMED, shared across
    /// clients (bug 2026-10-16: a connection that died without anyone
    /// noticing swallowed pushes the server then counted as received; the
    /// next client — a fresh one after the background, cursor 0 — never
    /// asked for them again). When set, every (re)connect resumes from it.
    pub resume_cursor: Option<Arc<std::sync::atomic::AtomicU64>>,
}

// Manual Debug — `TlsPinning` doesn't derive Debug (rustls types
// aren't all Debug-friendly).
impl std::fmt::Debug for WsClientConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WsClientConfig")
            .field("url", &self.url)
            .field(
                "identity_seed",
                &"[redacted; 32 bytes]",
            )
            .field("tls_pinning", &self.tls.is_some())
            .finish()
    }
}

/// Event emitted from the WS task to the caller. The caller polls these
/// via [`WsClient::recv`] — typically by feeding them to a Riverpod
/// notifier or analogous state holder.
#[derive(Debug, Clone)]
pub enum Event {
    /// Successfully (re)connected + authenticated.
    Connected,
    /// Socket dropped — the run loop will attempt to reconnect with
    /// exponential backoff. Caller may surface "Reconnecting…" in the UI.
    Disconnected { reason: String },
    /// Incoming protobuf frame from the server.
    Frame(WsFrame),
}

/// What the app tells the running connection: is it in the background
/// (long heartbeat gap), and how many times the phone's network changed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct Mode {
    background: bool,
    network: u64,
}

/// Handle on the running WS client. Cheap to clone — the underlying
/// channels are reference-counted.
#[derive(Clone)]
pub struct WsClient {
    outbound_tx: mpsc::Sender<WsFrame>,
    mode: Arc<watch::Sender<Mode>>,
    inbound_rx: Arc<Mutex<mpsc::Receiver<Event>>>,
    shutdown: Arc<Notify>,
    /// Set by [`WsClient::shutdown`]; checked before every reconnect.
    stopped: Arc<AtomicBool>,
    /// Cached identity pubkey for the configured seed.
    identity_pubkey: [u8; 32],
}

impl WsClient {
    /// Start the WS client. Returns immediately — the background task
    /// drives connection asynchronously. First [`Event::Connected`]
    /// fires when the handshake completes.
    pub fn start(config: WsClientConfig) -> Self {
        Self::start_with_keepalive(config, Keepalive::default())
    }

    /// [`WsClient::start`] with custom connection timings (tests).
    pub fn start_with_keepalive(config: WsClientConfig, keepalive: Keepalive) -> Self {
        let sk = SigningKey::from_bytes(&config.identity_seed);
        let identity_pubkey = sk.verifying_key().to_bytes();
        // ADR-072 — a wss host is ours: checked address, DoH fallback.
        crate::dns::global().add_our_host(&config.url);

        let (outbound_tx, outbound_rx) = mpsc::channel::<WsFrame>(OUTBOUND_BUFFER);
        let (inbound_tx, inbound_rx) = mpsc::channel::<Event>(OUTBOUND_BUFFER);
        let shutdown = Arc::new(Notify::new());
        let stopped = Arc::new(AtomicBool::new(false));
        let (mode, mode_rx) = watch::channel(Mode::default());

        let task_shutdown = shutdown.clone();
        let task_stopped = stopped.clone();
        let task_config = config.clone();
        tokio::spawn(async move {
            run_loop(task_config, keepalive, sk, outbound_rx, inbound_tx, mode_rx, task_shutdown, task_stopped).await;
        });

        Self {
            outbound_tx,
            mode: Arc::new(mode),
            inbound_rx: Arc::new(Mutex::new(inbound_rx)),
            shutdown,
            stopped,
            identity_pubkey,
        }
    }

    /// Queue a frame for sending. Awaits if the outbound buffer is full
    /// (backpressure). Returns an error only if the client has been
    /// shut down.
    pub async fn send(&self, frame: WsFrame) -> Result<(), SendError> {
        self.outbound_tx
            .send(frame)
            .await
            .map_err(|_| SendError::ClientShutDown)
    }

    /// Wait for the next event. None when the client task has stopped
    /// (typically because [`WsClient::shutdown`] was called).
    pub async fn recv(&self) -> Option<Event> {
        let mut rx = self.inbound_rx.lock().await;
        rx.recv().await
    }

    /// Identity pubkey for the configured seed. Constant for the
    /// lifetime of this client.
    pub fn identity_pubkey(&self) -> &[u8; 32] {
        &self.identity_pubkey
    }

    /// The app went to the background (`true`: the long heartbeat gap) or
    /// came back / a call started (`false`: the short one, and a heartbeat
    /// now so a link that died meanwhile is noticed at once).
    pub fn set_background(&self, on: bool) {
        self.mode.send_if_modified(|m| {
            let changed = m.background != on;
            m.background = on;
            changed
        });
    }

    /// The phone switched networks (Wi-Fi ↔ mobile, a new cell): the old
    /// socket is bound to the network that went away, so drop it and
    /// connect again now — also cuts a reconnect back-off short.
    pub fn network_changed(&self) {
        self.mode.send_modify(|m| m.network += 1);
    }

    /// Signal the run loop to stop. Drops the underlying socket on the
    /// next event-loop tick.
    pub fn shutdown(&self) {
        // The flag is what actually stops the loop: the Notify permit is
        // consumed by whichever await sees it first (the live session),
        // and the reconnect loop used to carry on regardless — every
        // "restart" left a zombie connection authenticated as the same
        // identity (found by `start_shutdown_cycles_do_not_leak`).
        self.stopped.store(true, Ordering::SeqCst);
        self.shutdown.notify_one();
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SendError {
    #[error("client has been shut down")]
    ClientShutDown,
}

#[derive(Debug, thiserror::Error)]
pub enum ConnectError {
    #[error("bad URL: {0}")]
    BadUrl(String),
    #[error("transport failed: {0}")]
    TransportFailed(String),
    #[error("protocol violation: {0}")]
    Protocol(String),
    #[error("server did not send Hello within timeout")]
    HelloTimeout,
    #[error("server did not Ack auth within timeout")]
    AckTimeout,
    #[error("no connection to the server within {0} ms (TCP / TLS / upgrade)")]
    ConnectTimeout(u128),
    #[error("auth rejected (code {code}): {message}")]
    AuthRejected { code: i32, message: String },
    #[error("encode failed: {0}")]
    Encode(String),
}

// ─────────────────────────────────────────────────────────────────────
// Background task — connect + reconnect loop
// ─────────────────────────────────────────────────────────────────────

async fn run_loop(
    config: WsClientConfig,
    keepalive: Keepalive,
    sk: SigningKey,
    mut outbound_rx: mpsc::Receiver<WsFrame>,
    inbound_tx: mpsc::Sender<Event>,
    mut mode_rx: watch::Receiver<Mode>,
    shutdown: Arc<Notify>,
    stopped: Arc<AtomicBool>,
) {
    let mut backoff = keepalive.reconnect_initial;
    // Resume cursor — incremented as we receive Push frames; sent in a
    // Resume frame after each successful (re)connect so missed messages
    // are replayed.
    let mut last_acked_seq: u64 = 0;

    loop {
        // Shutdown short-circuit BEFORE attempting a (re)connect.
        if stopped.load(Ordering::SeqCst) {
            debug!("ws shutdown requested — exiting run_loop");
            return;
        }

        // What the app consumed wins over what this client merely read off a
        // socket (frames still queued when the client was dropped).
        if let Some(c) = &config.resume_cursor {
            last_acked_seq = c.load(Ordering::SeqCst);
        }
        let network = mode_rx.borrow_and_update().network;
        // Shutdown wins over a connect that's stuck.
        let mut session_started = None;
        let connect_result = tokio::select! {
            _ = shutdown.notified() => return,
            r = handshake(&config, &sk, keepalive.connect_timeout) => r,
        };
        match connect_result {
            Ok(socket) => {
                session_started = Some(tokio::time::Instant::now());
                let _ = inbound_tx.send(Event::Connected).await;

                // Send Resume after every (re)connect — replays anything
                // missed since last_acked_seq.
                if last_acked_seq > 0 {
                    let resume = WsFrame {
                        frame_id: String::new(),
                        body: Some(Body::Resume(Resume {
                            cursors: vec![StreamCursor {
                                stream_id: "main".to_string(),
                                last_acked_seq,
                            }],
                        })),
                    };
                    // Push directly onto the socket via the same path
                    // the writer task uses — we don't have it yet, so
                    // we just queue into outbound_rx via a side channel
                    // by piping the resume frame back through... actually
                    // simpler: drive the session inline here so Resume
                    // is the first thing sent post-handshake.
                    let (sink, stream) = socket.split();
                    let driver_outcome = run_session(
                        sink,
                        stream,
                        &mut outbound_rx,
                        &inbound_tx,
                        Some(resume),
                        &mut last_acked_seq,
                        &shutdown,
                        &keepalive,
                        &mut mode_rx,
                        network,
                    )
                    .await;
                    let _ = inbound_tx
                        .send(Event::Disconnected {
                            reason: driver_outcome,
                        })
                        .await;
                } else {
                    let (sink, stream) = socket.split();
                    let driver_outcome = run_session(
                        sink,
                        stream,
                        &mut outbound_rx,
                        &inbound_tx,
                        None,
                        &mut last_acked_seq,
                        &shutdown,
                        &keepalive,
                        &mut mode_rx,
                        network,
                    )
                    .await;
                    let _ = inbound_tx
                        .send(Event::Disconnected {
                            reason: driver_outcome,
                        })
                        .await;
                }
            }
            Err(e) => {
                warn!(error = %e, backoff_ms = backoff.as_millis() as u64, "ws connect failed — backing off");
                let _ = inbound_tx
                    .send(Event::Disconnected {
                        reason: e.to_string(),
                    })
                    .await;
            }
        }

        if stopped.load(Ordering::SeqCst) {
            debug!("ws shutdown requested — exiting run_loop");
            return;
        }

        if session_started.is_some_and(|t| t.elapsed() >= STABLE_SESSION) {
            backoff = keepalive.reconnect_initial;
        }

        // A new network: connect on it now, no back-off.
        if mode_rx.borrow().network != network {
            backoff = keepalive.reconnect_initial;
            continue;
        }

        // Sleep with shutdown-cancellation; a network change wakes it.
        tokio::select! {
            _ = shutdown.notified() => return,
            _ = tokio::time::sleep(backoff + jitter(backoff)) => {}
            _ = network_changed(&mut mode_rx, network) => {
                backoff = keepalive.reconnect_initial;
                continue;
            }
        }
        backoff = (backoff * 2).min(keepalive.reconnect_max);
    }
}

/// CN-20: up to a quarter of [backoff] on top, so phones dropped together
/// do not come back together. The clock's nanoseconds are random enough.
fn jitter(backoff: Duration) -> Duration {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    backoff.mul_f64(f64::from(nanos) / 4e9)
}

/// Resolves once the network counter moves past [since]; never if the
/// handle is gone.
async fn network_changed(mode_rx: &mut watch::Receiver<Mode>, since: u64) {
    loop {
        if mode_rx.changed().await.is_err() {
            return std::future::pending().await;
        }
        if mode_rx.borrow_and_update().network != since {
            return;
        }
    }
}

/// The heartbeat gap for this session: the background one only once the
/// server has accepted it ([granted], from its Heartbeat reply).
fn heartbeat_gap(keepalive: &Keepalive, background: bool, granted: Duration) -> Duration {
    if background {
        keepalive.background_heartbeat.min(granted).max(keepalive.heartbeat)
    } else {
        keepalive.heartbeat
    }
}

type WsSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

async fn handshake(
    config: &WsClientConfig,
    sk: &SigningKey,
    connect_timeout: Duration,
) -> Result<WsSocket, ConnectError> {
    // ── Build the upgrade request with subprotocol header ────────
    let mut req = config
        .url
        .as_str()
        .into_client_request()
        .map_err(|e| ConnectError::BadUrl(e.to_string()))?;
    req.headers_mut().insert(
        SEC_WEBSOCKET_PROTOCOL,
        SUBPROTOCOL.parse().expect("static subprotocol header value"),
    );

    // WU B3 — when an operator CA is pinned, route the upgrade through
    // `connect_async_tls_with_config` with `Connector::Rustls` carrying
    // our constrained `ClientConfig`. Otherwise fall through to the
    // default `connect_async` which uses tokio-tungstenite's stock
    // webpki-roots connector.
    let connector = config.tls.as_ref().map(|pin| tokio_tungstenite::Connector::Rustls(pin.client_config()));
    let connect = async {
    Ok::<_, ConnectError>(if let Some(proxy) = crate::proxy::socks_proxy() {
        // SOCKS5 tunnel first (the proxy resolves the host — remote DNS),
        // then the same TLS + WS upgrade over it. After the SOCKS
        // handshake the stream is a plain TCP tunnel to the server.
        let uri = req.uri().clone();
        let host = uri.host().ok_or_else(|| ConnectError::BadUrl("no host".into()))?.to_string();
        let port = uri.port_u16().unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
        let tcp = tokio_socks::tcp::Socks5Stream::connect(proxy.as_str(), (host.as_str(), port))
            .await
            .map_err(|e| ConnectError::TransportFailed(format!("socks proxy: {e}")))?
            .into_inner();
        tokio_tungstenite::client_async_tls_with_config(req, tcp, None, connector)
            .await
            .map_err(|e| ConnectError::TransportFailed(e.to_string()))?
    } else if req.uri().scheme_str() == Some("wss") {
        // ADR-072 — the address from our resolver (the system answer if it
        // passes the check, else DoH / a remembered one); TLS still checks
        // the certificate for the URL's host name.
        connect_wss(&config.url, connector, crate::dns::global()).await?
    } else {
        match connector {
        Some(connector) => tokio_tungstenite::connect_async_tls_with_config(
            req,
            None,  // default WebSocketConfig (max frame / message size)
            false, // disable_nagle — leave default (Nagle ON)
            Some(connector),
        )
        .await
        .map_err(|e| ConnectError::TransportFailed(e.to_string()))?,
        None => tokio_tungstenite::connect_async(req)
            .await
            .map_err(|e| ConnectError::TransportFailed(e.to_string()))?,
        }
    })
    };
    let (mut socket, response) =
        timeout(connect_timeout, connect).await.map_err(|_| ConnectError::ConnectTimeout(connect_timeout.as_millis()))??;
    debug!(status = %response.status(), "ws upgrade ok");

    // ── Phase 1: receive Hello, capture challenge ────────────────
    let hello =
        timeout(Duration::from_secs(HANDSHAKE_TIMEOUT_SECS), recv_frame(&mut socket))
            .await
            .map_err(|_| ConnectError::HelloTimeout)?
            .map_err(ConnectError::TransportFailed)?;

    let challenge = match hello.body {
        Some(Body::Hello(h)) => {
            // Risk #4 / CRIT-1.4 — record server-clock observation.
            // `h.server_time` is the server's `now_utc().unix_timestamp()`
            // at the moment it queued the Hello frame. `clock_drift::record`
            // pairs it with a fresh `Instant::now()` internally so all
            // subsequent action-proof signatures advance monotonically
            // from this anchor regardless of wall-clock changes.
            crate::clock_drift::record(h.server_time);
            h.challenge_nonce
        }
        other => {
            return Err(ConnectError::Protocol(format!(
                "first frame must be Hello, got {:?}",
                other.as_ref().map(std::mem::discriminant)
            )));
        }
    };
    if challenge.len() != 32 {
        return Err(ConnectError::Protocol(format!(
            "Hello.challenge_nonce must be 32 bytes, got {}",
            challenge.len()
        )));
    }

    // ── Phase 2: sign challenge + send Auth ──────────────────────
    let identity_pubkey = sk.verifying_key().to_bytes();
    let sig = sk.sign(&ws_auth_message(&config.url, &challenge)).to_bytes().to_vec();

    let auth = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Auth(Auth {
            identity_pubkey: identity_pubkey.to_vec(),
            signature: sig,
        })),
    };
    // CN-21: a server that stops reading must not hang the login.
    timeout(Duration::from_secs(HANDSHAKE_TIMEOUT_SECS), send_frame(&mut socket, &auth))
        .await
        .map_err(|_| ConnectError::TransportFailed("auth send timed out".to_string()))??;

    // ── Phase 3: expect "authenticated" Ack ──────────────────────
    let ack =
        timeout(Duration::from_secs(HANDSHAKE_TIMEOUT_SECS), recv_frame(&mut socket))
            .await
            .map_err(|_| ConnectError::AckTimeout)?
            .map_err(ConnectError::TransportFailed)?;

    match ack.body {
        Some(Body::Ack(a)) if a.error_code == 0 => {
            info!(identity = %hex::encode(identity_pubkey), "ws authenticated");
            Ok(socket)
        }
        Some(Body::Ack(a)) => Err(ConnectError::AuthRejected {
            code: a.error_code,
            message: a.error_message,
        }),
        other => Err(ConnectError::Protocol(format!(
            "expected Ack, got {:?}",
            other.as_ref().map(std::mem::discriminant)
        ))),
    }
}

fn ws_request(url: &str) -> Result<tokio_tungstenite::tungstenite::handshake::client::Request, ConnectError> {
    let mut req = url.into_client_request().map_err(|e| ConnectError::BadUrl(e.to_string()))?;
    req.headers_mut().insert(
        SEC_WEBSOCKET_PROTOCOL,
        SUBPROTOCOL.parse().expect("static subprotocol header value"),
    );
    Ok(req)
}

/// TCP to the resolver's addresses in turn (checked ones first), then TLS
/// with SNI + the certificate check for the URL's host and the WebSocket
/// upgrade. An address whose TLS fails is dropped from the resolver's
/// memory; a wrong certificate is never accepted.
pub async fn connect_wss(
    url: &str,
    connector: Option<tokio_tungstenite::Connector>,
    dns: &Arc<crate::dns::Resolver>,
) -> Result<(WsSocket, tokio_tungstenite::tungstenite::handshake::client::Response), ConnectError> {
    let req = ws_request(url)?;
    let uri = req.uri().clone();
    let host = uri.host().ok_or_else(|| ConnectError::BadUrl("no host".into()))?.to_string();
    let port = uri.port_u16().unwrap_or(443);
    let addrs = dns
        .resolve(&host, port)
        .await
        .map_err(|e| ConnectError::TransportFailed(format!("dns: {e}")))?;
    let mut last = String::from("no address");
    for addr in addrs.into_iter().take(3) {
        let tcp = match TcpStream::connect(addr).await {
            Ok(t) => t,
            Err(e) => {
                last = format!("{addr}: {e}");
                continue;
            }
        };
        match tokio_tungstenite::client_async_tls_with_config(ws_request(url)?, tcp, None, connector.clone()).await {
            Ok(ok) => return Ok(ok),
            Err(e) => {
                if let tokio_tungstenite::tungstenite::Error::Io(io) = &e {
                    if crate::dns::is_tls_error(io) {
                        dns.note_bad(&host, addr.ip());
                    }
                }
                last = format!("{addr}: {e}");
            }
        }
    }
    Err(ConnectError::TransportFailed(last))
}

/// Run one connected session — pump frames in both directions. Returns
/// when the socket closes (cleanly or with an error); the run_loop
/// then reconnects.
/// REL-1 — "replayed N more S": the Resume page ended at S, more waits.
fn resume_more(msg: &str) -> Option<u64> {
    msg.strip_prefix("replayed ")?.split_once(" more ")?.1.parse().ok()
}

#[cfg(test)]
mod rel1_tests {
    #[test]
    fn a_cut_resume_page_is_asked_on() {
        assert_eq!(super::resume_more("replayed 1000 more 77"), Some(77));
        assert_eq!(super::resume_more("replayed 3"), None);
    }
}

async fn run_session(
    mut sink: futures_util::stream::SplitSink<WsSocket, Message>,
    mut stream: futures_util::stream::SplitStream<WsSocket>,
    outbound_rx: &mut mpsc::Receiver<WsFrame>,
    inbound_tx: &mpsc::Sender<Event>,
    initial_send: Option<WsFrame>,
    last_acked_seq: &mut u64,
    shutdown: &Arc<Notify>,
    keepalive: &Keepalive,
    mode_rx: &mut watch::Receiver<Mode>,
    network: u64,
) -> String {
    // Send the initial frame (Resume) if present.
    if let Some(f) = initial_send {
        if let Err(e) = send_frame_split(&mut sink, &f, keepalive.reply_timeout).await {
            return format!("initial frame send failed: {e}");
        }
    }

    // Tech-debt 2.10 — the client never sent a Heartbeat, so the server's
    // 75 s idle watchdog dropped every quiet session and the client
    // reconnected: a disconnect/reconnect cycle every 75 s while idle.
    //
    // Battery 2026-10-18 — in the background the gap grows to
    // `background_heartbeat` once the server accepts it; a dead link is
    // caught by `reply_timeout` after the heartbeat that got no reply.
    let mut background = mode_rx.borrow().background;
    let mut granted = Duration::ZERO; // the server's accepted gap, this session
    let mut every = heartbeat_gap(keepalive, background, granted);
    let mut last_beat = tokio::time::Instant::now();
    let mut next_beat = last_beat + every;
    let mut heartbeat_seq: u64 = 0;
    let mut last_rx = tokio::time::Instant::now();
    // When the oldest heartbeat still without any frame back went out.
    let mut awaiting: Option<tokio::time::Instant> = None;
    let mut mode_alive = true;
    let mut beat_now = false;

    loop {
        if beat_now {
            beat_now = false;
            next_beat = tokio::time::Instant::now();
        }
        let reply_deadline = awaiting.map(|t| t + keepalive.reply_timeout);
        let long_gap = every > keepalive.heartbeat;
        tokio::select! {
            _ = shutdown.notified() => {
                return "shutdown requested".to_string();
            }

            _ = tokio::time::sleep_until(next_beat) => {
                if !long_gap && last_rx.elapsed() >= keepalive.server_silence {
                    return format!("server silent for {}s", keepalive.server_silence.as_secs());
                }
                heartbeat_seq += 1;
                let ask = if background { keepalive.background_heartbeat.as_secs() as u32 } else { 0 };
                let hb = WsFrame {
                    frame_id: String::new(),
                    body: Some(Body::Heartbeat(Heartbeat { sequence: heartbeat_seq, next_within_secs: ask })),
                };
                if let Err(e) = send_frame_split(&mut sink, &hb, keepalive.reply_timeout).await {
                    return format!("heartbeat send failed: {e}");
                }
                last_beat = tokio::time::Instant::now();
                awaiting.get_or_insert(last_beat);
                next_beat = last_beat + every;
            }

            _ = tokio::time::sleep_until(reply_deadline.unwrap_or(next_beat)), if reply_deadline.is_some() => {
                return format!("no reply to heartbeat for {}s", keepalive.reply_timeout.as_secs());
            }

            changed = mode_rx.changed(), if mode_alive => {
                if changed.is_err() {
                    mode_alive = false; // the handle is gone; keep the mode we have
                    continue;
                }
                let mode = *mode_rx.borrow_and_update();
                if mode.network != network {
                    return "network changed".to_string();
                }
                if mode.background != background {
                    // The server's watchdog follows our last heartbeat, so
                    // start from the short gap and ask again right away.
                    background = mode.background;
                    granted = Duration::ZERO;
                    every = heartbeat_gap(keepalive, background, granted);
                    beat_now = true;
                    // The silence rule counts from here: the long gap
                    // just ended, the heartbeat now gets its reply time.
                    last_rx = tokio::time::Instant::now();
                }
            }

            // Outbound: caller queued a frame → write to sink
            outgoing = outbound_rx.recv() => {
                let Some(frame) = outgoing else {
                    return "outbound channel closed".to_string();
                };
                if let Err(e) = send_frame_split(&mut sink, &frame, keepalive.reply_timeout).await {
                    return format!("send failed: {e}");
                }
            }

            // Inbound: server sent a frame → decode, update cursor, dispatch
            incoming = stream.next() => {
                let msg = match incoming {
                    None => return "ws closed by peer".to_string(),
                    Some(Err(e)) => return format!("ws recv error: {e}"),
                    Some(Ok(m)) => m,
                };
                last_rx = tokio::time::Instant::now();
                awaiting = None;
                match msg {
                    Message::Binary(bytes) => {
                        match WsFrame::decode(bytes.as_ref()) {
                            // The server's heartbeat echo only proves the
                            // link is alive — nothing for the caller. It
                            // says which gap the server accepted.
                            Ok(WsFrame { body: Some(Body::Heartbeat(h)), .. }) => {
                                if background {
                                    granted = Duration::from_secs(u64::from(h.next_within_secs));
                                    let gap = heartbeat_gap(keepalive, background, granted);
                                    if gap != every {
                                        every = gap;
                                        next_beat = last_beat + every;
                                    }
                                }
                            }
                            Ok(frame) => {
                                // REL-1 — a Resume page was cut (1000 rows / 16 MiB): ask
                                // for the rest now, from where the page ended, not from
                                // the cursor a live push may already have moved past it.
                                if let Some(Body::Ack(ref a)) = frame.body {
                                    if let Some(from) = resume_more(&a.error_message) {
                                        let next = WsFrame {
                                            frame_id: String::new(),
                                            body: Some(Body::Resume(Resume {
                                                cursors: vec![StreamCursor { stream_id: "main".to_string(), last_acked_seq: from }],
                                            })),
                                        };
                                        if let Err(e) = send_frame_split(&mut sink, &next, keepalive.reply_timeout).await {
                                            return format!("resume page send failed: {e}");
                                        }
                                    }
                                }
                                // Track Push sequence for Resume.
                                if let Some(Body::Push(ref p)) = frame.body {
                                    if p.sequence > *last_acked_seq {
                                        *last_acked_seq = p.sequence;
                                    }
                                }
                                if inbound_tx.send(Event::Frame(frame)).await.is_err() {
                                    return "inbound channel closed".to_string();
                                }
                            }
                            Err(e) => return format!("frame decode: {e}"),
                        }
                    }
                    Message::Text(_) => return "text frame on binary subprotocol".to_string(),
                    Message::Ping(_) | Message::Pong(_) => {}
                    Message::Close(_) => return "ws closed by peer".to_string(),
                    Message::Frame(_) => {}
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Wire helpers (joined + split variants — frb-friendly)
// ─────────────────────────────────────────────────────────────────────

async fn send_frame(socket: &mut WsSocket, frame: &WsFrame) -> Result<(), ConnectError> {
    let mut buf = Vec::with_capacity(frame.encoded_len());
    frame
        .encode(&mut buf)
        .map_err(|e| ConnectError::Encode(e.to_string()))?;
    socket
        .send(Message::Binary(Bytes::from(buf)))
        .await
        .map_err(|e| ConnectError::TransportFailed(e.to_string()))
}

async fn send_frame_split(
    sink: &mut futures_util::stream::SplitSink<WsSocket, Message>,
    frame: &WsFrame,
    limit: Duration,
) -> Result<(), String> {
    let mut buf = Vec::with_capacity(frame.encoded_len());
    frame.encode(&mut buf).map_err(|e| e.to_string())?;
    // CN-21: a server that stops reading must not freeze the session —
    // the caller ends it on any error, so the half-written sink is dropped.
    timeout(limit, sink.send(Message::Binary(Bytes::from(buf))))
        .await
        .map_err(|_| format!("write stalled for {}s", limit.as_secs()))?
        .map_err(|e| e.to_string())
}

async fn recv_frame(socket: &mut WsSocket) -> Result<WsFrame, String> {
    loop {
        let msg = socket
            .next()
            .await
            .ok_or_else(|| "ws closed".to_string())?
            .map_err(|e| format!("ws recv: {e}"))?;
        match msg {
            Message::Binary(bytes) => {
                return WsFrame::decode(bytes.as_ref())
                    .map_err(|e| format!("frame decode: {e}"))
            }
            Message::Text(_) => return Err("text frame on binary subprotocol".to_string()),
            Message::Ping(_) | Message::Pong(_) => continue,
            Message::Close(_) => return Err("ws closed by peer".to_string()),
            Message::Frame(_) => continue,
        }
    }
}
