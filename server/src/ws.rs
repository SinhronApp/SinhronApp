// WebSocket sync endpoint — spec §7.3 / WU A5+A6.
//
// Per-connection FSM:
//
//   1. Upgrade accepted (subprotocol `sinhron.v1` required) — generate
//      32-byte CSPRNG challenge
//   2. Server → [Hello] with that challenge + version + server_time
//   3. Client → [Auth] within AUTH_TIMEOUT_SECS with identity_pubkey +
//      Ed25519_sign(privkey, b"sinhron-server-host-v1:" || host || 0x00 ||
//                            b"sinhron-ws-auth-v1:" || challenge)
//      — host is this server's name as the app dialed it (ADR-086,
//      proof::verify_ws_auth)
//   4. Server verifies signature + checks identity is in `users` table
//      → registers a SessionRegistry slot for the user_pk
//   5. Steady-state, with two concurrent tasks:
//        • [recv] reads frames from socket → routes:
//            – Heartbeat  → server echoes own Heartbeat
//            – Submit     → persist to messages + fanout Push to group
//                           members' connected sessions (WU A6)
//            – Resume     → ACK 501 (WU A7)
//            – Presence/Typing/Receipt → ACK 501 (Phase 3)
//        • [send] drains the registry's mpsc into the socket sink
//   6. SessionGuard dropped on disconnect → automatic cleanup
//
// Idle watchdog: 45s without an inbound frame closes the connection (heartbeat 20s;
// a frozen iOS app stops sending, so the server soon counts it offline and pushes).
// A client may ask for a longer gap in its Heartbeat (`next_within_secs` — an
// Android phone in the background, battery 2026-10-18): that session's watchdog
// becomes the gap plus slack, see [`session_idle_secs`].

use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use bytes::Bytes;

use crate::handlers::access_keys::CallVerdict as AccessCall;
use futures_util::stream::SplitStream;
use futures_util::{SinkExt, StreamExt};
use prost::Message as ProstMessage;
use rand::RngCore;
use sqlx::PgPool;
use time::OffsetDateTime;
use tokio::sync::mpsc;
use tokio::time::{timeout, Instant};
use tracing::{debug, error, info, warn};
use uuid::Uuid;

use crate::call_session::{CallKind, CallSession, CallSessionRegistry, StartCallOutcome};
use crate::proto::{
    resume::StreamCursor, ws_frame::Body, Ack, Auth, CallAccept, CallEnd, CallInvite, CallRing,
    Hello, Heartbeat, Push, Resume, SealedSubmit, Submit, Welcome, WsFrame,
};
use crate::AppState;

const SUBPROTOCOL: &str = "sinhron.v1";
const AUTH_TIMEOUT_SECS: u64 = 10;
/// Default idle watchdog. Clients heartbeat well inside it.
const DEFAULT_IDLE_TIMEOUT_SECS: u64 = 45;

/// Tech-debt 2.10 — `SINHRON_WS_IDLE_TIMEOUT_SECS` overrides the idle
/// watchdog (read once). Values below 15 s are raised to 15 so a typo
/// can't disconnect every client between heartbeats; empty/unparsable
/// = default.
fn idle_timeout_secs() -> u64 {
    static V: std::sync::OnceLock<u64> = std::sync::OnceLock::new();
    *V.get_or_init(|| parse_idle_timeout(std::env::var("SINHRON_WS_IDLE_TIMEOUT_SECS").ok().as_deref()))
}

fn parse_idle_timeout(v: Option<&str>) -> u64 {
    v.and_then(|s| s.trim().parse::<u64>().ok())
        .map(|n| n.max(15))
        .unwrap_or(DEFAULT_IDLE_TIMEOUT_SECS)
}

/// The longest heartbeat gap a client may ask for. Keeps a dead
/// background session from counting as online (no push) for long, and
/// stays under Caddy's `/v1/sync` read timeout (Caddyfile).
const MAX_HEARTBEAT_GAP_SECS: u32 = 300;

/// The gap the server accepts for a requested one (0 = the default).
fn granted_heartbeat_gap(requested: u32) -> u32 {
    requested.min(MAX_HEARTBEAT_GAP_SECS)
}

/// Idle watchdog for a session whose client said "next heartbeat within
/// [requested] s": the gap plus half of it (at least 25 s — a phone's timer
/// fires late when the CPU sleeps), never below the [default] watchdog.
fn session_idle_secs(requested: u32, default: u64) -> u64 {
    let gap = u64::from(granted_heartbeat_gap(requested));
    if gap == 0 {
        return default;
    }
    default.max(gap + (gap / 2).max(25))
}

/// WS-11 — new connections per client address (IPv6: per /64). Nothing
/// limited them: one stranger could hold thousands of sockets in the 10 s
/// before login, and one account could log in in a loop, each login reading
/// its queue from the database. A family behind one router (a dozen
/// devices all reconnecting, with retries, after a server restart) is far
/// below it — this is not the place to risk the connection.
static CONNECT_LIMIT: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_WS_CONNECT", 600, window(60));

/// A limiter's window: in tests so long that a bucket never refills while a
/// test counts its tokens (a slow machine made such tests fail at random).
const fn window(secs: u64) -> u64 {
    if cfg!(test) {
        1_000_000_000
    } else {
        secs
    }
}

pub async fn ws_upgrade(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    if crate::admin::client_rate_key(&headers).is_some_and(|ip| CONNECT_LIMIT.check(&ip).is_err()) {
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["ws_connect"]).inc();
        return (StatusCode::TOO_MANY_REQUESTS, "too many connections").into_response();
    }
    if state.pool.is_none() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "ws unavailable: no database configured",
        )
            .into_response();
    }
    // A frame was allowed up to axum's 64 MiB: a few of them and a reader
    // that never reads ran the server out of memory (security review
    // 2026-11-02). Real frames are tens of KB; the largest — a batch of
    // history for a new device (50 items) — stays under 4 MiB.
    upgrade
        .protocols([SUBPROTOCOL])
        .max_message_size(MAX_WS_MESSAGE_BYTES)
        .max_frame_size(MAX_WS_MESSAGE_BYTES)
        .on_upgrade(move |socket| handle_socket(state, socket, crate::admin::client_ip(&headers)))
}

/// ADR-075, ADR-027 — did its person disconnect the device that logs in
/// with [key]? (A key with no device row is not a disconnected device.)
async fn device_revoked(pool: &PgPool, key: &[u8], user_pk: Uuid) -> sqlx::Result<bool> {
    let row: Option<(bool,)> = sqlx::query_as("SELECT revoked_at IS NOT NULL FROM devices WHERE device_pk = $1 AND user_pk = $2")
        .bind(key)
        .bind(user_pk)
        .fetch_optional(pool)
        .await?;
    Ok(row == Some((true,)))
}

async fn handle_socket(state: AppState, mut socket: WebSocket, ip: Option<std::net::IpAddr>) {
    let chosen = socket.protocol().map(|h| h.to_str().unwrap_or("").to_string());
    if chosen.as_deref() != Some(SUBPROTOCOL) {
        warn!(chosen = ?chosen, "ws closed: subprotocol mismatch");
        let _ = socket.close().await;
        return;
    }

    // ── Send Hello ────────────────────────────────────────────────────
    let mut challenge = [0u8; 32];
    rand::rng().fill_bytes(&mut challenge);

    let hello = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Hello(Hello {
            server_version: env!("CARGO_PKG_VERSION").to_string(),
            server_time: OffsetDateTime::now_utc().unix_timestamp(),
            challenge_nonce: challenge.to_vec(),
        })),
    };
    if let Err(e) = send_frame_inline(&mut socket, &hello).await {
        warn!(error = %e, "failed to send Hello");
        let _ = socket.close().await;
        return;
    }

    // ── Auth ─────────────────────────────────────────────────────────
    let auth_result = timeout(
        Duration::from_secs(AUTH_TIMEOUT_SECS),
        verify_auth_with_challenge(&mut socket, &challenge),
    )
    .await;
    let identity_pubkey = match auth_result {
        Err(_) => {
            warn!("ws closed: auth timeout");
            let _ = send_ack_inline(&mut socket, "", 408, "auth timeout").await;
            let _ = socket.close().await;
            return;
        }
        Ok(Err(reason)) => {
            warn!(reason = %reason, "ws closed: auth failed");
            let _ = send_ack_inline(&mut socket, "", 401, &reason).await;
            let _ = socket.close().await;
            return;
        }
        Ok(Ok(a)) => a.identity_pubkey,
    };

    let pool = state.pool.expect("ws_upgrade checked pool was Some");
    // ADR-027 — the identity key, or an active linked device's own key
    // (a revoked device can't log in any more).
    let resolved = match crate::accounts::resolve_signer(&pool, &identity_pubkey).await {
        Ok(r) => r,
        Err(e) => {
            error!(error = %e, "ws auth: db error");
            let _ = send_ack_inline(&mut socket, "", 500, "internal error").await;
            let _ = socket.close().await;
            return;
        }
    };
    let registered: Option<(Uuid,)> = resolved.as_ref().map(|(u, _)| (*u,));

    // ADR-075 — the first device (its key is the identity key) cut off by its
    // person from a new phone doesn't come back in: no messages, no calls.
    // (Whoever extracts the account key itself from it could still sign up
    // a new device — the account key is the account; threat model.)
    if let Some((user_pk,)) = registered {
        match device_revoked(&pool, &identity_pubkey, user_pk).await {
            Ok(false) => {}
            Ok(true) => {
                warn!(%user_pk, "ws closed: this device was disconnected by its owner");
                let _ = send_ack_inline(&mut socket, "", 403, "device disconnected").await;
                let _ = socket.close().await;
                return;
            }
            // WS-30 — a database error used to read as "not disconnected".
            Err(e) => {
                error!(error = %e, "ws auth: db error");
                let _ = send_ack_inline(&mut socket, "", 500, "internal error").await;
                let _ = socket.close().await;
                return;
            }
        }
    }

    // ADR-025 — "last seen" of the device that logged in (the signer key is
    // the device key; the first device's is the identity key). Device sync
    // skips devices silent for a long time (an abandoned install).
    let _ = sqlx::query("UPDATE devices SET last_seen_at = NOW() WHERE device_pk = $1")
        .bind(&identity_pubkey)
        .execute(&pool)
        .await;

    let Some((user_pk,)) = registered else {
        // A linked device its person removed hears so — it shows "this
        // device is signed out" instead of "Connecting…" forever (owner,
        // 2026-11-01). Its own key only; says nothing about anyone else.
        if linked_device_removed(&pool, &identity_pubkey).await {
            warn!("ws closed: this linked device was disconnected by its owner");
            let _ = send_ack_inline(&mut socket, "", 403, "device disconnected").await;
            let _ = socket.close().await;
            return;
        }
        warn!(
            identity = %crate::short_key(&hex::encode(&identity_pubkey)),
            "ws closed: identity not registered"
        );
        let _ = send_ack_inline(&mut socket, "", 403, "identity not registered").await;
        let _ = socket.close().await;
        return;
    };

    info!("ws session authenticated");
    // ADR-077 — the account's last IP, quoted when someone complains about
    // it (in memory only; nothing kept when there are no administrators).
    if let Some((_, person)) = &resolved {
        crate::admin::note_ip(person, ip);
    }
    let _ = send_ack_inline(&mut socket, "", 0, "authenticated").await;

    // ── Steady-state — split socket + spawn send/recv pair ───────────
    //
    // The recv task reads + routes inbound frames. The send task drains
    // an mpsc fed by the SessionRegistry's fanout calls. Both tasks
    // share the same SessionGuard lifetime: when either ends, the
    // guard drops and the registry unregisters the connection.
    let (tx_out, rx_out) = mpsc::unbounded_channel::<Bytes>();
    // ADR-025 — remember which device this connection is (its login key).
    let guard = state.sessions.register_device(user_pk, Some(identity_pubkey.clone()), tx_out);
    // WS-19 — a device disconnected by its person between the check above
    // and this registration was missed by both: the check had passed, and
    // the one-time drop of its connections found none yet. Look again now
    // that the connection is in the registry.
    let revoked = device_revoked(&pool, &identity_pubkey, user_pk).await;
    if !matches!(revoked, Ok(false)) {
        drop(guard);
        warn!(%user_pk, db_error = revoked.is_err(), "ws closed: this device was disconnected during login");
        let (code, why) = if revoked.is_err() { (500, "internal error") } else { (403, "device disconnected") };
        let _ = send_ack_inline(&mut socket, "", code, why).await;
        let _ = socket.close().await;
        return;
    }

    // Risk #10 — drain any Welcomes that piled up while this user was
    // offline. Best-effort: a failure here is logged but doesn't tear
    // down the session (the welcomes stay in the queue for the next
    // reconnect). Must happen AFTER session register so the fanout
    // route to this connection exists.
    if let Err(e) = flush_pending_welcomes(&pool, &state.sessions, user_pk, Some(&identity_pubkey)).await {
        warn!(error = %e, %user_pk, "failed to flush pending welcomes on auth");
    }
    // Bug 2026-10-16 (owner: "my friend stopped getting my messages") —
    // what arrived while this person had no connection. Only Resume used to
    // replay it, and the app sends Resume only after it got something on
    // the same connection — a fresh one (every launch, every return from
    // the background since the push fix) never did: 111 of 443 deliveries
    // on the server had never reached an app. After the Welcomes, so a new
    // chat exists before its first messages.
    if let Err(e) = deliver_backlog(&pool, &state.sessions, user_pk).await {
        warn!(error = %e, %user_pk, "failed to deliver backlog on auth");
    }
    // Overnight item 9 — a call still ringing for this person (they were
    // woken by PushKit, or just came online): send its invite now.
    replay_ringing_invites(&state.sessions, &state.calls, user_pk, Some(&identity_pubkey));
    // 2026-10-26 — a call this person already answered on another device:
    // this one (woken by a push, still ringing) stops.
    for call_id in state.calls.answered_elsewhere(user_pk, &identity_pubkey) {
        let frame = WsFrame {
            frame_id: String::new(),
            body: Some(Body::CallEnd(CallEnd { call_id: call_id.to_string(), reason: "answered_elsewhere".to_string() })),
        };
        if let Ok(bytes) = encode_frame(&frame) {
            state.sessions.fanout_devices(user_pk, std::slice::from_ref(&identity_pubkey), bytes);
        }
    }

    let (sink, stream) = socket.split();
    let mut send_task = tokio::spawn(run_send_task(sink, rx_out, guard.queued()));
    let recv_loop = run_recv_loop(
        guard.conn_id(),
        stream,
        pool.clone(),
        state.sessions.clone(),
        state.push.clone(),
        state.rate.clone(),
        state.calls.clone(),
        user_pk,
        identity_pubkey.clone(),
    );
    tokio::pin!(recv_loop);
    // The session also ends when its send side does — e.g. the device was
    // revoked and its queue dropped (ADR-027).
    let recv_outcome = tokio::select! {
        r = &mut recv_loop => r,
        _ = &mut send_task => Ok(()),
    };

    if let Err(e) = recv_outcome {
        debug!(error = %e, "ws recv loop ended");
    }
    // Dropping the guard unregisters; dropping the channel sender (it
    // lived inside the registry's stored SessionSender, gone now) signals
    // the send_task to exit.
    drop(guard);
    if !send_task.is_finished() {
        let _ = send_task.await;
    }
    info!("ws session closed");
    // Status 182 (owner, 2026-10-19: "a call rings only the second time") —
    // an iPhone going to the background keeps its socket a few seconds: an
    // invite sent down it was "delivered", no push went, the app was
    // already frozen, nothing rang. The last connection gone while a call
    // still rings for this person → their phone gets the push now.
    if !state.sessions.is_online(user_pk) {
        push_ringing_after_disconnect(&pool, &state.push, &state.calls, user_pk).await;
    }
}

// ─────────────────────────────────────────────────────────────────────
// Send / recv task halves
// ─────────────────────────────────────────────────────────────────────

/// One frame not written in this long — the device stopped reading.
const SEND_STALL_SECS: u64 = 120;

async fn run_send_task(
    mut sink: impl futures_util::Sink<Message> + Unpin,
    mut rx_out: mpsc::UnboundedReceiver<Bytes>,
    queued: std::sync::Arc<std::sync::atomic::AtomicUsize>,
) {
    while let Some(bytes) = rx_out.recv().await {
        let len = bytes.len();
        if !matches!(timeout(Duration::from_secs(SEND_STALL_SECS), sink.send(Message::Binary(bytes))).await, Ok(Ok(()))) {
            debug!("ws sink closed or stalled — send task exiting");
            return;
        }
        // server-ws:3 — over the cap the registry stopped queueing for us:
        // close, the app reconnects and gets the rest as the backlog.
        // WS-02 — but first write out what was queued before that: those
        // messages are already marked as received (and Welcomes deleted);
        // closing after one frame lost up to 32 MiB of them for good.
        let waiting = queued.fetch_sub(len, std::sync::atomic::Ordering::Relaxed).saturating_sub(len);
        if waiting > crate::session::MAX_QUEUED_BYTES && rx_out.is_empty() {
            warn!("ws send queue over its cap — closing the connection");
            return;
        }
    }
}

/// Default stream id used for per-user reconciliation. Spec §7.3 leaves
/// the stream namespace server-defined; we model "all messages addressed
/// to user X" as one stream. Future work may split by group_id or device.
const MAIN_STREAM_ID: &str = "main";

#[allow(clippy::too_many_arguments)]
async fn run_recv_loop(
    conn: Uuid,
    mut stream: SplitStream<WebSocket>,
    pool: PgPool,
    sessions: crate::session::SessionRegistry,
    push: std::sync::Arc<dyn crate::push::PushClient>,
    rate: crate::rate_limit::RateLimiter,
    calls: crate::call_session::CallSessionRegistry,
    self_user_pk: Uuid,
    self_device: Vec<u8>,
) -> anyhow::Result<()> {
    let mut last_seen = Instant::now();
    // Stretched by a Heartbeat that asks for a longer gap, back to the
    // default by one that doesn't.
    let mut idle = idle_timeout_secs();
    loop {
        let remaining = Duration::from_secs(idle)
            .saturating_sub(last_seen.elapsed());
        if remaining.is_zero() {
            warn!("ws idle watchdog fired ({idle}s)");
            return Ok(());
        }
        let recv = timeout(remaining, stream.next()).await;
        let msg = match recv {
            Err(_) => {
                warn!("ws idle watchdog fired ({idle}s)");
                return Ok(());
            }
            Ok(None) => return Ok(()),
            Ok(Some(Ok(m))) => m,
            Ok(Some(Err(e))) => return Err(anyhow::anyhow!("ws recv error: {e}")),
        };
        last_seen = Instant::now();

        match msg {
            Message::Binary(bytes) => {
                let frame = match decode_frame(bytes.as_ref()) {
                    Ok(f) => f,
                    Err(e) => {
                        warn!(error = %e, "malformed frame — closing");
                        return Ok(());
                    }
                };
                if let Some(Body::Heartbeat(h)) = &frame.body {
                    idle = session_idle_secs(h.next_within_secs, idle_timeout_secs());
                }
                if let Err(e) = REPLY_TO
                    .scope(conn, route_frame(&pool, &sessions, &push, &rate, &calls, self_user_pk, &self_device, frame))
                    .await
                {
                    warn!(error = %e, "frame routing failed");
                }
            }
            Message::Text(_) => {
                warn!("text frame on binary subprotocol — closing");
                return Ok(());
            }
            Message::Ping(_) | Message::Pong(_) => { /* WS layer */ }
            Message::Close(_) => return Ok(()),
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Frame router
// ─────────────────────────────────────────────────────────────────────

tokio::task_local! {
    /// server-ws:9 — the connection whose frame is being handled: its acks
    /// and the heartbeat reply go back to it alone. They went to every
    /// connection of the person — a background phone took a sibling's
    /// heartbeat gap for its own, and each frame was copied to every queue.
    static REPLY_TO: Uuid;
}

#[allow(clippy::too_many_arguments)]
async fn route_frame(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    push: &std::sync::Arc<dyn crate::push::PushClient>,
    rate: &crate::rate_limit::RateLimiter,
    calls: &crate::call_session::CallSessionRegistry,
    self_user_pk: Uuid,
    self_device: &[u8],
    frame: WsFrame,
) -> anyhow::Result<()> {
    let frame_id = frame.frame_id.clone();
    match frame.body {
        Some(Body::Heartbeat(h)) => {
            // Server-side heartbeat reply lets the client detect server
            // liveness too. Pushed via session registry so we don't
            // need to hold the sink directly. It carries the gap we
            // accepted — the client only waits that long if we say so.
            let reply = WsFrame {
                frame_id: String::new(),
                body: Some(Body::Heartbeat(Heartbeat {
                    sequence: 0,
                    next_within_secs: granted_heartbeat_gap(h.next_within_secs),
                })),
            };
            push_to_user(sessions, self_user_pk, &reply);
            Ok(())
        }
        Some(Body::Submit(s)) => {
            handle_submit(pool, sessions, push, rate, self_user_pk, self_device, &frame_id, s).await
        }
        Some(Body::SealedSubmit(s)) => {
            handle_sealed_submit(pool, sessions, push, rate, self_user_pk, &frame_id, s).await
        }
        Some(Body::Resume(r)) => {
            // Each Resume replays up to 1000 stored messages: in a loop it
            // filled the server's memory (security review 2026-11-02).
            if let Err(d) = RESUME_LIMIT.check(&self_user_pk.to_string()) {
                push_ack(sessions, self_user_pk, &frame_id, 429, &format!("too many resumes; retry in {}s", d.as_secs()));
                return Ok(());
            }
            handle_resume(pool, sessions, self_user_pk, &frame_id, r).await
        }
        Some(Body::Welcome(w)) => {
            // Welcomes went to anyone, without limit, and are kept a year.
            if let Err(d) = WELCOME_LIMIT.check(&self_user_pk.to_string()) {
                push_ack(sessions, self_user_pk, &frame_id, 429, &format!("too many invitations; retry in {}s", d.as_secs()));
                return Ok(());
            }
            handle_welcome(pool, sessions, self_user_pk, &frame_id, w).await
        }
        Some(Body::Presence(_)) | Some(Body::Typing(_)) | Some(Body::Receipt(_)) => {
            push_ack(sessions, self_user_pk, &frame_id, 501, "not implemented");
            Ok(())
        }
        // CB2 — caller→server: invite the peer to a call.
        Some(Body::CallInvite(i)) => {
            if let Err(d) = CALL_INVITE_LIMIT.check(&self_user_pk.to_string()) {
                push_ack(sessions, self_user_pk, &frame_id, 429, &format!("too many calls; retry in {}s", d.as_secs()));
                return Ok(());
            }
            handle_call_invite(pool, sessions, push, calls, self_user_pk, &frame_id, i).await
        }
        // CB4 — accept (callee picks up / declines).
        Some(Body::CallAccept(a)) => {
            handle_call_accept(sessions, calls, self_user_pk, Some(self_device), &frame_id, a).await
        }
        // CB4 — end (either side hangs up).
        Some(Body::CallEnd(e)) => {
            handle_call_end(sessions, calls, self_user_pk, &frame_id, e).await
        }
        // CallRing is server→client only — clients sending it = bug.
        Some(Body::CallRing(_)) => {
            push_ack(sessions, self_user_pk, &frame_id, 400, "CallRing is server-only");
            Ok(())
        }
        Some(Body::Auth(_)) | Some(Body::Hello(_)) | Some(Body::Ack(_)) | Some(Body::Push(_)) => {
            push_ack(sessions, self_user_pk, &frame_id, 400, "frame not allowed mid-session");
            Ok(())
        }
        None => {
            push_ack(sessions, self_user_pk, &frame_id, 400, "empty frame body");
            Ok(())
        }
    }
}

/// WS-10 — Commits per account. They all wait for one lock ([COMMIT_ORDER]):
/// at the Submit limit (600 a minute) one account held up the changes in
/// every chat. A person re-adding a returned phone into all their chats
/// sends tens in a burst.
static COMMIT_LIMIT: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_WS_COMMIT", 120, window(60));

/// ADR-092 — Commits are taken and fanned out one at a time.
static COMMIT_ORDER: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// ADR-092 — the plain head of an MLS message (RFC 9420 §6): `(group id,
/// epoch)` when it is a Commit, `None` for anything else (an application
/// message, a proposal, bytes that aren't MLS). Read leniently: anything a
/// phone would read as a Commit is one here.
fn mls_commit_head(b: &[u8]) -> Option<(&[u8], u64)> {
    // A variable-length vector: 2-bit width (1, 2 or 4 bytes), then the bytes.
    fn bytes<'a>(b: &'a [u8], at: &mut usize) -> Option<&'a [u8]> {
        let width = [1usize, 2, 4].get(usize::from(*b.get(*at)? >> 6)).copied()?;
        let len = b.get(*at..*at + width)?.iter().fold(0usize, |v, x| (v << 8) | usize::from(*x)) & ((1 << (8 * width - 2)) - 1);
        let out = b.get(*at + width..*at + width + len)?;
        *at += width + len;
        Some(out)
    }
    let wire = u16::from_be_bytes(b.get(2..4)?.try_into().ok()?);
    let mut at = 4;
    let group = bytes(b, &mut at)?;
    let epoch = u64::from_be_bytes(b.get(at..at + 8)?.try_into().ok()?);
    at += 8;
    let content_type = match wire {
        // PrivateMessage: the content type follows the epoch.
        2 => *b.get(at)?,
        // PublicMessage: the sender (type, and a u32 index for a member or
        // an external sender), the authenticated data, then the content type.
        1 => {
            at += match *b.get(at)? {
                1 | 2 => 5,
                3 | 4 => 1,
                _ => return None,
            };
            bytes(b, &mut at)?;
            *b.get(at)?
        }
        _ => return None,
    };
    (content_type == 3).then_some((group, epoch))
}

// ─────────────────────────────────────────────────────────────────────
// Submit handler — persist + fanout
// ─────────────────────────────────────────────────────────────────────

async fn handle_submit(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    push: &std::sync::Arc<dyn crate::push::PushClient>,
    rate: &crate::rate_limit::RateLimiter,
    sender_user_pk: Uuid,
    sender_device: &[u8],
    frame_id: &str,
    s: Submit,
) -> anyhow::Result<()> {
    // T1.5 — rate-limit by user_pk (post-Auth identity). A single
    // authenticated session can't burst more than the configured cap
    // (default 600/min = 10/s). Keyed by user_pk (not source IP) so a
    // device can't multiply its budget across reconnects, and so two
    // devices of the same identity share the budget per spec §6.5.
    let sender_key = sender_user_pk.to_string();
    if let Err(retry_after) = rate.check_ws_submit(&sender_key) {
        let msg = format!("rate limited; retry after {}s", retry_after.as_secs());
        push_ack(sessions, sender_user_pk, frame_id, 429, &msg);
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["ws_submit"])
            .inc();
        return Ok(());
    }

    // ── Validate inputs ──────────────────────────────────────────────
    if s.group_id.is_empty() {
        push_ack(sessions, sender_user_pk, frame_id, 400, "empty group_id");
        return Ok(());
    }
    if s.ciphertext.is_empty() {
        push_ack(sessions, sender_user_pk, frame_id, 400, "empty ciphertext");
        return Ok(());
    }
    if !bulk_allowed(sender_user_pk, s.ciphertext.len()) {
        push_ack(sessions, sender_user_pk, frame_id, 429, "rate limited: too many large messages");
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["ws_bulk"]).inc();
        return Ok(());
    }
    let message_id = match Uuid::parse_str(&s.message_id) {
        Ok(u) => u,
        Err(_) => {
            push_ack(sessions, sender_user_pk, frame_id, 400, "message_id must be UUID");
            return Ok(());
        }
    };

    // T1.4 — sealed-sender base. When the client opts in via
    // `s.sealed_sender`, the server promises:
    //   • never write sender_user_pk / sender_device_pk to disk
    //   • never include sender hint in Push frames
    //   • mask sender_user_pk in info! / warn! logs
    // Full §6.5 wraps the MLS frame in an HPKE envelope keyed by
    // recipient delivery_key (deferred). The flag here is the
    // foundation; once HPKE wrapping arrives, the same flag still
    // governs server-side anonymization.
    let sealed = s.sealed_sender;

    // ── Authorize: sender must be a member of the target group ──────
    // ADR-025 — through ANY of the person's active devices (the WS
    // session is per identity, not per device). How many of them are in
    // the group decides whether the sender's own user is a recipient.
    let (own_devices_in_group,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM group_members gm \
         JOIN devices d ON d.device_pk = gm.device_pk \
         WHERE gm.group_id = $1 AND d.user_pk = $2 AND d.revoked_at IS NULL",
    )
    .bind(&s.group_id)
    .bind(sender_user_pk)
    .fetch_one(pool)
    .await?;
    if own_devices_in_group == 0 {
        // ADR-075 — the person's device here was cut off (a lost phone): a
        // new device of theirs may rejoin by an external commit. Only a
        // Commit — nothing else gets through — and the members check it
        // names a person who still has a leaf in the chat.
        let (was_here,): (bool,) = sqlx::query_as(
            "SELECT EXISTS (SELECT 1 FROM group_former_devices f JOIN devices d ON d.device_pk = f.device_pk \
             WHERE f.group_id = $1 AND d.user_pk = $2)",
        )
        .bind(&s.group_id)
        .bind(sender_user_pk)
        .fetch_one(pool)
        .await?;
        if !(was_here && s.is_commit) {
            push_ack(sessions, sender_user_pk, frame_id, 403, "not a group member");
            return Ok(());
        }
        info!(group = %crate::short_key(&hex::encode(&s.group_id)), "a cut-off device's person rejoins by external commit");
    }

    // ADR-092 — a Commit says so, and only a Commit: the flag and the epoch
    // come from the message's own header (an unflagged Commit would move
    // the members on behind the server's back).
    let head = mls_commit_head(&s.ciphertext);
    if s.is_commit != head.is_some() {
        push_ack(sessions, sender_user_pk, frame_id, 400, "is_commit must match the message");
        return Ok(());
    }
    // One Commit at a time, fanned out before the next is looked at: every
    // member then gets a chat's Commits in the order the server took them.
    if s.is_commit && COMMIT_LIMIT.check(&sender_key).is_err() {
        push_ack(sessions, sender_user_pk, frame_id, 429, "rate limited: too many Commits");
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["ws_commit"]).inc();
        return Ok(());
    }
    let order = match s.is_commit {
        true => Some(COMMIT_ORDER.lock().await),
        false => None,
    };

    // ── Persist message + per-recipient delivery rows (transactional) ──
    //
    // The transaction guarantees we never have a `messages` row without
    // its corresponding `message_deliveries` entries (or vice versa). On
    // crash mid-fanout, replay starts cleanly from either both-or-neither.
    let now = OffsetDateTime::now_utc();
    let mut tx = pool.begin().await?;

    // ── Tech-debt 2.3 / ADR-022, ADR-092 — order Commits per group ─────
    // The server can't read a Commit, so it can't tell a garbage one from a
    // good one. It used to take the first Commit of an epoch and refuse the
    // rest: a member's garbage Commit froze the chat (every honest phone
    // refused it and then got 409 — server-ws:2 variant B). Now each phone
    // takes the first Commit of its epoch that it can apply (they all get
    // the same Commits in the same order), and the server takes a Commit
    // for epoch E only from a device that has seen, and not taken, every
    // Commit it holds for E after the one that brought the device to E
    // (`parent_commit_id`, `refused_commit_ids`). So two good Commits for
    // one epoch never both go out, and a garbage one only waits for the
    // next honest Commit. One per device and epoch (a flood stays small).
    // No epoch is too far: nobody takes a jump.
    if let Some((group, epoch)) = head {
        let epoch = match i64::try_from(epoch) {
            Ok(e) if e < i64::MAX => e,
            _ => {
                push_ack(sessions, sender_user_pk, frame_id, 400, "commit_epoch too large");
                return Ok(());
            }
        };
        if group != s.group_id.as_slice() || epoch as u64 != s.commit_epoch {
            push_ack(sessions, sender_user_pk, frame_id, 400, "commit_epoch or group is not the Commit's own");
            return Ok(());
        }
        let known: Option<(i32,)> = sqlx::query_as("SELECT 1 FROM mls_groups WHERE group_id = $1 FOR UPDATE")
            .bind(&s.group_id)
            .fetch_optional(&mut *tx)
            .await?;
        // A group never registered with the server: nothing to order
        // against — accept as before.
        if known.is_some() {
            let parent = Uuid::parse_str(&s.parent_commit_id).ok();
            let (after,): (i64,) = sqlx::query_as(
                "SELECT COALESCE((SELECT n FROM group_commits WHERE group_id = $1 AND message_id = $2), 0)",
            )
            .bind(&s.group_id)
            .bind(parent)
            .fetch_one(&mut *tx)
            .await?;
            let held: Vec<(i64, Uuid, Vec<u8>)> =
                sqlx::query_as("SELECT n, message_id, device_pk FROM group_commits WHERE group_id = $1 AND epoch = $2")
                    .bind(&s.group_id)
                    .bind(epoch)
                    .fetch_all(&mut *tx)
                    .await?;
            let refused: std::collections::HashSet<Uuid> =
                s.refused_commit_ids.iter().filter_map(|id| Uuid::parse_str(id).ok()).collect();
            // A lost Ack: the same device sends the same Commit again. It
            // was taken and went out — say so again, change nothing (the
            // app would otherwise drop a Commit everyone else applied).
            // The same id from another device, or with other bytes: refused.
            if let Some((_, _, device)) = held.iter().find(|(_, id, _)| *id == message_id) {
                let same: Option<(bool,)> =
                    sqlx::query_as("SELECT ciphertext = $3 FROM messages WHERE message_id = $1 AND group_id = $2 LIMIT 1")
                        .bind(message_id)
                        .bind(&s.group_id)
                        .bind(&s.ciphertext)
                        .fetch_optional(&mut *tx)
                        .await?;
                tx.rollback().await?;
                match device.as_slice() == sender_device && same != Some((false,)) {
                    true => push_ack(sessions, sender_user_pk, frame_id, 0, "ok"),
                    false => push_ack(sessions, sender_user_pk, frame_id, 400, "message_id already used"),
                }
                return Ok(());
            }
            let unseen = held.iter().filter(|(n, id, _)| *n > after && !refused.contains(id)).count();
            let again = held.iter().any(|(_, _, device)| device.as_slice() == sender_device);
            if unseen > 0 || again {
                tx.rollback().await?;
                let msg = format!("stale commit: epoch {epoch} has {unseen} Commit(s) this device hasn't seen");
                push_ack(sessions, sender_user_pk, frame_id, 409, &msg);
                info!(group = %crate::short_key(&hex::encode(&s.group_id)), epoch, unseen, again, "commit lost the race — 409");
                return Ok(());
            }
            sqlx::query(
                "INSERT INTO group_commits (group_id, epoch, message_id, device_pk) VALUES ($1, $2, $3, $4) \
                 ON CONFLICT DO NOTHING",
            )
            .bind(&s.group_id)
            .bind(epoch)
            .bind(message_id)
            .bind(sender_device)
            .execute(&mut *tx)
            .await?;
            sqlx::query("UPDATE mls_groups SET current_epoch = $2 + 1 WHERE group_id = $1")
                .bind(&s.group_id)
                .bind(epoch)
                .execute(&mut *tx)
                .await?;
        }
    }

    // sender_device_pk stays NULL: nothing reads it, and it named the
    // person's oldest device, not the sender (critic:11). The MLS message
    // inside the ciphertext carries the sender's leaf for the recipients.
    sqlx::query(
        "INSERT INTO messages \
         (message_id, group_id, sender_device_pk, ciphertext, ts) \
         VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (ts, message_id) DO NOTHING",
    )
    .bind(message_id)
    .bind(&s.group_id)
    .bind(None::<Vec<u8>>)
    .bind(&s.ciphertext)
    .bind(now)
    .execute(&mut *tx)
    .await?;

    // Resolve recipients = all users in this group EXCEPT the sender —
    // unless the sender has other devices in it (ADR-025): then the
    // sender's user gets the delivery too, and the device that sent it
    // drops its own echo (`IncomingMessage::OwnCommitEcho`).
    let recipient_user_pks: Vec<Uuid> = sqlx::query_as(
        "SELECT DISTINCT d.user_pk \
         FROM group_members gm \
         JOIN devices d ON d.device_pk = gm.device_pk \
         WHERE gm.group_id = $1 AND d.revoked_at IS NULL AND (d.user_pk <> $2 OR $3)",
    )
    .bind(&s.group_id)
    .bind(sender_user_pk)
    .bind(own_devices_in_group > 1)
    .fetch_all(&mut *tx)
    .await?
    .into_iter()
    .map(|r: (Uuid,)| r.0)
    .collect();

    // ADR-071, ADR-087 (amended) — someone who hands out per-contact keys
    // is pushed as usual when the sender holds their key (not revoked):
    // a plain Submit is what the app sends when a member has no fresh
    // delivery key — a phone asleep for weeks, exactly the one to wake.
    // Only a revoked key (blocked): no push, outside the badge. No key (a
    // stranger, a key not yet received): a content-free request push.
    // My own devices: always.
    let verdicts = crate::handlers::access_keys::verdicts_on(&mut tx, &recipient_user_pks, &s.access_keys).await?;
    let verdict = |u: &Uuid| verdicts.get(u).copied().unwrap_or(AccessCall::Ring);
    let mut quiet: std::collections::HashSet<Uuid> =
        recipient_user_pks.iter().filter(|u| verdict(u) != AccessCall::Ring).copied().collect();
    quiet.remove(&sender_user_pk);
    let requests: Vec<Uuid> = quiet.iter().filter(|u| verdict(u) == AccessCall::AppOnly).copied().collect();

    // Allocate per-recipient seq via the BIGSERIAL column. RETURNING
    // gives us the seq so the Push carries the correct value.
    let mut delivery_seqs: Vec<(Uuid, i64)> = Vec::with_capacity(recipient_user_pks.len());
    for rid in &recipient_user_pks {
        let row: Option<(i64,)> = sqlx::query_as(
            "INSERT INTO message_deliveries (recipient_user_pk, message_id, urgent) \
             VALUES ($1, $2, $3) \
             ON CONFLICT (recipient_user_pk, message_id) DO NOTHING \
             RETURNING seq",
        )
        .bind(rid)
        .bind(message_id)
        .bind(s.urgent && !quiet.contains(rid))
        .fetch_optional(&mut *tx)
        .await?;
        if let Some((seq,)) = row {
            delivery_seqs.push((*rid, seq));
        }
        // ON CONFLICT → no new seq (duplicate). Sender retry of same
        // message_id is silently de-duped.
    }

    // WS-05 — a Commit whose message_id was already used (for an ordinary
    // message, a sealed envelope) reached nobody, or not everybody, yet was
    // written into the epoch's order: no honest phone could name it as
    // refused, and every later Commit got 409 — the chat frozen for good.
    // A Commit is taken only when every recipient gets it.
    if s.is_commit && delivery_seqs.len() != recipient_user_pks.len() {
        tx.rollback().await?;
        push_ack(sessions, sender_user_pk, frame_id, 400, "message_id already used");
        return Ok(());
    }

    // A retry (same message_id, new `ts`) delivered nothing new: drop the
    // ciphertext copy it just stored. `messages` is partitioned by ts, so
    // it can't carry a unique index on message_id alone; the deliveries
    // index is the arbiter (a racing original blocks this tx on it until
    // it commits). Found by `concurrent_submits_deliver_each_message_exactly_once`.
    // WS-06 — likewise a message to nobody (a chat with no other member):
    // nobody will ever ask for it, it only took disk for a year.
    if delivery_seqs.is_empty() {
        sqlx::query("DELETE FROM messages WHERE ts = $1 AND message_id = $2")
            .bind(now)
            .bind(message_id)
            .execute(&mut *tx)
            .await?;
    }

    tx.commit().await?;

    // No sender, no chat, no size in the log — only counts.
    info!(
        message_id = %message_id,
        recipients = recipient_user_pks.len(),
        sealed = sealed,
        "message persisted"
    );

    // T2.4 — count successful Submit
    crate::metrics::MESSAGES_SUBMITTED_TOTAL.inc();

    // ── Push fanout — best-effort, per-recipient seq embedded ────────
    let mut delivered = 0usize;
    let mut offline_recipients: Vec<Uuid> = Vec::new();
    let mut live_recipients: Vec<Uuid> = Vec::new();
    for (rid, seq) in &delivery_seqs {
        let push_frame = WsFrame {
            frame_id: String::new(),
            body: Some(Body::Push(Push {
                group_id: s.group_id.clone(),
                ciphertext: s.ciphertext.clone(),
                message_id: s.message_id.clone(),
                delivered_at: now.unix_timestamp(),
                sequence: *seq as u64,
                sealed_key_id: Vec::new(),
            })),
        };
        let bytes = encode_frame(&push_frame)?;
        let count = sessions.fanout(std::slice::from_ref(rid), bytes);
        delivered += count;
        if count == 0 {
            offline_recipients.push(*rid);
        } else {
            live_recipients.push(*rid);
            mark_received(pool, *rid, &[*seq]).await?;
        }
    }
    info!(
        message_id = %message_id,
        recipients = recipient_user_pks.len(),
        delivered = delivered,
        offline = offline_recipients.len(),
        "fanout"
    );
    drop(order);

    // T2.4 — count delivered Push frames (not enqueued; only actually
    // sent to live sessions). offline_recipients count is captured
    // separately via retention/push-stub metrics.
    crate::metrics::MESSAGES_FANOUT_TOTAL.inc_by(delivered as u64);

    // ── Push notification for offline recipients (overnight item 8) ──
    //
    // Only a delivery the sender marked urgent (a real message, not a
    // receipt or "typing") wakes a phone; the push says "New message" and
    // the badge — no content, no group (tech-debt 2.7).
    if s.urgent {
        let (mut req_wake, mut req_live): (Vec<crate::push::Wake>, Vec<crate::push::Wake>) = (Vec::new(), Vec::new());
        for u in &requests {
            if rate.check_request_push(&sender_user_pk.to_string(), &u.to_string()) {
                if live_recipients.contains(u) { &mut req_live } else { &mut req_wake }.push((*u, None));
            }
        }
        crate::push::spawn_request(pool.clone(), push.clone(), req_wake, req_live);
        offline_recipients.retain(|u| !quiet.contains(u));
        live_recipients.retain(|u| !quiet.contains(u));
        let wake = offline_recipients.into_iter().map(|u| (u, None)).collect();
        crate::push::spawn_notify(pool.clone(), push.clone(), wake);
        // Status 167 — connected Android phones get their Google push too.
        let live = live_recipients.into_iter().map(|u| (u, None)).collect();
        crate::push::spawn_notify_android_live(pool.clone(), push.clone(), live);
    }

    push_ack(sessions, sender_user_pk, frame_id, 0, "submitted");
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────
// Sealed delivery — ADR-023 (spec §6.5)
// ─────────────────────────────────────────────────────────────────────
//
// Each envelope is addressed to a delivery key (key_id). The server maps
// key_id → recipient, stores the envelope on that recipient's delivery
// row (no `messages` row, no group id anywhere) and pushes it. It can't
// check group membership — it doesn't know the group — so the guards
// are the per-sender rate limit and the recipient's MLS processing,
// which drops anything not from a member.

/// Envelopes per SealedSubmit (a group of up to ~1000 devices, spec §6.3).
const MAX_SEALED_DELIVERIES: usize = 1000;

async fn handle_sealed_submit(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    push: &std::sync::Arc<dyn crate::push::PushClient>,
    rate: &crate::rate_limit::RateLimiter,
    sender_user_pk: Uuid,
    frame_id: &str,
    s: SealedSubmit,
) -> anyhow::Result<()> {
    if let Err(retry_after) = rate.check_ws_submit(&sender_user_pk.to_string()) {
        push_ack(sessions, sender_user_pk, frame_id, 429, &format!("rate limited; retry after {}s", retry_after.as_secs()));
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["ws_submit"]).inc();
        return Ok(());
    }
    let Ok(message_id) = Uuid::parse_str(&s.message_id) else {
        push_ack(sessions, sender_user_pk, frame_id, 400, "message_id must be UUID");
        return Ok(());
    };
    if s.deliveries.is_empty() || s.deliveries.len() > MAX_SEALED_DELIVERIES {
        push_ack(sessions, sender_user_pk, frame_id, 400, "1..=1000 deliveries");
        return Ok(());
    }
    // GRP-8, WS-04 — `POST /v1/sealed` caps an envelope; this route went
    // around it. No cap on the recipient's queue here: the app does not
    // fall back on a refusal, and a skipped delivery inside an accepted
    // frame would be a message silently lost for one member.
    if s.deliveries.iter().any(|d| d.envelope.len() > MAX_SEALED_ENVELOPE_BYTES) {
        push_ack(sessions, sender_user_pk, frame_id, 413, "sealed envelope too large");
        return Ok(());
    }
    if !bulk_allowed(sender_user_pk, s.deliveries.iter().map(|d| d.envelope.len()).sum()) {
        push_ack(sessions, sender_user_pk, frame_id, 429, "rate limited: too many large messages");
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["ws_bulk"]).inc();
        return Ok(());
    }
    let now = OffsetDateTime::now_utc();
    let mut accepted = 0usize;
    let mut unknown = 0usize;
    // Status 211 — the ack tells the truth: "ok" only if it reached someone
    // besides me (a ✓ on a message nobody got was a lie). [to_others]:
    // deliveries meant for another account; [others_ok]: of those, stored.
    let (mut to_others, mut others_ok, mut limited) = (0usize, 0usize, 0usize);
    let mut wake: Vec<crate::push::Wake> = Vec::new();
    let mut wake_live: Vec<crate::push::Wake> = Vec::new();
    // ADR-071 (amended) — message requests: a content-free push; the phone
    // decides (its block list, the sender in the sealed preview).
    let (mut req_wake, mut req_live): (Vec<crate::push::Wake>, Vec<crate::push::Wake>) = (Vec::new(), Vec::new());
    // ADR-087 (amended) — per recipient: does the sender hold their key?
    let mut verdicts: std::collections::HashMap<Uuid, AccessCall> = std::collections::HashMap::new();
    for d in &s.deliveries {
        if d.key_id.len() != 16 || d.envelope.is_empty() {
            unknown += 1;
            continue;
        }
        // ADR-071 — this route carries no access key (it would tie the key
        // to the signed-in sender). To someone who hands out per-contact
        // keys it's a message request: delivered, never pushed, limited.
        let owner: Option<(Uuid, bool)> = sqlx::query_as(
            "SELECT k.user_pk, u.access_per_contact FROM sealed_keys k JOIN users u ON u.user_pk = k.user_pk \
             WHERE k.key_id = $1",
        )
        .bind(&d.key_id)
        .fetch_optional(pool)
        .await?;
        let other = owner.is_none_or(|(recipient, _)| recipient != sender_user_pk);
        if other {
            to_others += 1;
        }
        // ADR-087 (amended) — with their key (not revoked): pushed as usual,
        // whichever route (the anonymous one failed, a group's other member
        // had no key); only a revoked one (blocked): arrives, no push; none:
        // a message request.
        let (request, blocked) = match owner {
            Some((recipient, true)) if recipient != sender_user_pk => {
                let v = match verdicts.get(&recipient) {
                    Some(v) => *v,
                    None => {
                        let v = crate::handlers::access_keys::call_verdicts(pool, &[recipient], &s.access_keys)
                            .await?
                            .get(&recipient)
                            .copied()
                            .unwrap_or(AccessCall::AppOnly);
                        verdicts.insert(recipient, v);
                        v
                    }
                };
                if v != AccessCall::Ring && rate.check_request(&format!("{sender_user_pk}>{recipient}")).is_err() {
                    crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["request"]).inc();
                    unknown += 1;
                    limited += 1;
                    continue;
                }
                (v == AccessCall::AppOnly, v == AccessCall::Swallow)
            }
            _ => (false, false),
        };
        let urgent = d.urgent && !request && !blocked;
        match deliver_sealed(pool, sessions, message_id, &d.key_id, &d.envelope, d.ttl_secs, urgent, d.drop_after_secs, now)
            .await?
        {
            SealedOutcome::Delivered { recipient, live } => {
                accepted += 1;
                others_ok += other as usize;
                if urgent {
                    crate::push::add_wake(if live { &mut wake_live } else { &mut wake }, recipient, &d.push_preview);
                } else if request
                    && d.urgent
                    && rate.check_request_push(&sender_user_pk.to_string(), &recipient.to_string())
                {
                    crate::push::add_wake(if live { &mut req_live } else { &mut req_wake }, recipient, &d.push_preview);
                }
            }
            SealedOutcome::Duplicate => others_ok += other as usize, // a retry
            SealedOutcome::UnknownKey => unknown += 1,
        }
    }
    crate::push::spawn_notify(pool.clone(), push.clone(), wake);
    crate::push::spawn_notify_android_live(pool.clone(), push.clone(), wake_live);
    crate::push::spawn_request(pool.clone(), push.clone(), req_wake, req_live);
    crate::metrics::MESSAGES_SUBMITTED_TOTAL.inc();
    // No group id, no sender, no recipients in the log — only counts.
    info!(message_id = %message_id, accepted, unknown, "sealed message routed");
    let (code, what) = match () {
        _ if to_others == 0 || others_ok > 0 => (0, "sealed"),
        _ if limited > 0 => (429, "rate limited"),
        _ => (404, "no recipient has this key"),
    };
    push_ack(sessions, sender_user_pk, frame_id, code, &format!("{what}: {accepted} delivered, {unknown} unknown keys"));
    Ok(())
}

pub(crate) enum SealedOutcome {
    /// Stored for [recipient]; [live] = pushed to an open connection too.
    Delivered { recipient: Uuid, live: bool },
    /// A retry — this recipient already has this message.
    Duplicate,
    UnknownKey,
}

/// One sealed envelope → its key's owner: stored on their delivery row
/// (no group, no sender) and pushed to their live sessions. Shared by the
/// WS `SealedSubmit` and the unauthenticated `POST /v1/sealed`.
/// [drop_after_secs] (tech-debt 2.53, 0 = keep): the row expires that long
/// after it is written, delivered or not — Resume never replays it after.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn deliver_sealed(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    message_id: Uuid,
    key_id: &[u8],
    envelope: &[u8],
    ttl_secs: u32,
    urgent: bool,
    drop_after_secs: u32,
    now: OffsetDateTime,
) -> anyhow::Result<SealedOutcome> {
    if key_id.len() != 16 || envelope.is_empty() {
        return Ok(SealedOutcome::UnknownKey);
    }
    let owner: Option<(Uuid,)> = sqlx::query_as("SELECT user_pk FROM sealed_keys WHERE key_id = $1")
        .bind(key_id)
        .fetch_optional(pool)
        .await?;
    let Some((recipient,)) = owner else {
        return Ok(SealedOutcome::UnknownKey);
    };
    let row: Option<(i64,)> = sqlx::query_as(
        "INSERT INTO message_deliveries (recipient_user_pk, message_id, envelope, sealed_key_id, ttl_secs, urgent, expires_at) \
         VALUES ($1, $2, $3, $4, NULLIF($5::double precision, 0)::integer, $6, \
                 CASE WHEN $7::double precision > 0 THEN NOW() + make_interval(secs => $7::double precision) END) \
         ON CONFLICT (recipient_user_pk, message_id) DO NOTHING \
         RETURNING seq",
    )
    .bind(recipient)
    .bind(message_id)
    .bind(envelope)
    .bind(key_id)
    // Tech-debt 2.5 — the chat's timer (capped like the per-chat one).
    .bind(ttl_secs.min(crate::handlers::groups::MAX_RETENTION_SECS as u32) as f64)
    .bind(urgent)
    // Tech-debt 2.53 — counted from now, not from receipt.
    .bind(drop_after_secs.min(crate::handlers::groups::MAX_RETENTION_SECS as u32) as f64)
    .fetch_optional(pool)
    .await?;
    let Some((seq,)) = row else { return Ok(SealedOutcome::Duplicate) };
    let frame = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Push(Push {
            group_id: Vec::new(),
            ciphertext: envelope.to_vec(),
            message_id: message_id.to_string(),
            delivered_at: now.unix_timestamp(),
            sequence: seq as u64,
            sealed_key_id: key_id.to_vec(),
        })),
    };
    let delivered = sessions.fanout(std::slice::from_ref(&recipient), encode_frame(&frame)?);
    crate::metrics::MESSAGES_FANOUT_TOTAL.inc_by(delivered as u64);
    if delivered > 0 {
        mark_received(pool, recipient, &[seq]).await?;
    }
    Ok(SealedOutcome::Delivered { recipient, live: delivered > 0 })
}

/// The recipient has these deliveries now (pushed live or replayed): the
/// disappearing timers start here — ADR-020 counts from receipt. A
/// drop-after expiry set at write time (tech-debt 2.53) stays if sooner.
pub(crate) async fn mark_received(pool: &PgPool, recipient: Uuid, seqs: &[i64]) -> anyhow::Result<()> {
    if seqs.is_empty() {
        return Ok(());
    }
    // LEAST skips NULL; a repeat (replay) never moves the expiry later.
    sqlx::query(
        "UPDATE message_deliveries SET received_at = COALESCE(received_at, NOW()), \
                expires_at = CASE WHEN ttl_secs > 0 \
                    THEN LEAST(expires_at, NOW() + make_interval(secs => ttl_secs::double precision)) \
                    ELSE expires_at END \
         WHERE recipient_user_pk = $1 AND seq = ANY($2)",
    )
    .bind(recipient)
    .bind(seqs)
    .execute(pool)
    .await?;
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────
// Welcome forwarding — WU C4
// ─────────────────────────────────────────────────────────────────────
//
// Inbound client→server Welcome: server looks up the recipient's
// connected sessions by identity_pubkey and forwards the frame as-is.
// If the recipient is offline, the Welcome is persisted to
// `pending_welcomes` (TTL 7d via retention worker) and delivered on
// the recipient's next successful Auth — see [`flush_pending_welcomes`].
// Risk #10 fix.

/// Largest WebSocket message accepted (see `ws_upgrade`).
const MAX_WS_MESSAGE_BYTES: usize = 4 * 1024 * 1024;

/// Devices one Welcome may name (they are one person's).
const MAX_WELCOME_DEVICES: usize = 64;

/// Largest Welcome (real ones are tens of KB) and most bytes of Welcomes
/// waiting for one person: 4 MiB each, 600 an hour, kept a year, filled
/// the disk (docs/security-review-2026-11.md, server-ws:6).
///
/// WS-08 — the queue must fit, with room to spare, into one connection's
/// [crate::session::MAX_QUEUED_BYTES] (32 MiB): at 64 MiB a login poured it
/// all into the connection, which was then closed as stalled — every time.
const MAX_WELCOME_BYTES: usize = 1024 * 1024;
const MAX_PENDING_WELCOME_BYTES: usize = 8 * 1024 * 1024;
/// WS-21 — the one success answer to a Welcome.
const WELCOME_ACCEPTED: &str = "welcome accepted";
/// WS-07 — a real group id is 16–32 bytes; megabytes in this field went
/// past the Welcome quota onto the disk.
const MAX_GROUP_ID_BYTES: usize = 255;

/// WS-04, WS-06 — bytes one account may store per hour through Submit and
/// SealedSubmit. The only limits were 4 MiB a frame and 600 frames a minute:
/// 2.4 GB a minute onto the disk, kept a year. Ordinary messages (up to
/// [BULK_FREE_BYTES]) are free; a larger frame pays one token per
/// [BULK_CHUNK_BYTES] — 2000 an hour is ~500 MiB (history for a new device
/// goes in 256 KiB batches).
static BULK_LIMIT: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_WS_BULK", 2000, window(3600));
const BULK_FREE_BYTES: usize = 64 * 1024;
const BULK_CHUNK_BYTES: usize = 256 * 1024;

/// May [user] store a frame of [bytes] now ([BULK_LIMIT])?
fn bulk_allowed(user: Uuid, bytes: usize) -> bool {
    if bytes <= BULK_FREE_BYTES {
        return true;
    }
    let key = user.to_string();
    let need = bytes.div_ceil(BULK_CHUNK_BYTES);
    let got = (0..need).take_while(|_| BULK_LIMIT.check(&key).is_ok()).count();
    // A refused frame gives back what it took: a retry every few seconds
    // would otherwise eat the refill and a large frame never get through.
    if got < need {
        (0..got).for_each(|_| BULK_LIMIT.refund(&key));
    }
    got == need
}

/// One sealed envelope over the WebSocket. Larger than on the route without
/// login (256 KiB): a batch of data for the person's own devices is 256 KiB
/// before it is sealed.
const MAX_SEALED_ENVELOPE_BYTES: usize = 1024 * 1024;

/// Resumes per user (one per reconnect is normal).
static RESUME_LIMIT: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_WS_RESUME", 30, 60);

/// Welcomes (invitations into a chat) per sender. A new phone coming back
/// is re-added by its contacts into every chat — hundreds, not thousands.
static WELCOME_LIMIT: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_WS_WELCOME", 600, 3_600);

/// Calls started per caller: invite + hang up in a loop rang someone's
/// phone without end (docs/security-review-2026-11.md, server-ws:4).
/// 20 at once, then one every three minutes.
static CALL_INVITE_LIMIT: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_WS_CALL_INVITE", 20, 3_600);

/// Largest first frame (the Auth, ~110 bytes): a 4 MiB frame of empty
/// list items decoded into ~260 MiB before anyone logged in (server-ws:1).
const MAX_AUTH_FRAME_BYTES: usize = 4 * 1024;

/// TTL for queued Welcomes — as long as messages are kept
/// (`SINHRON_MESSAGE_RETENTION_DAYS`, a year by default). It was 7 days:
/// a phone away longer lost the invitation, and with it every message of
/// that chat, kept for longer, became unreadable. The server knows "X
/// invited Y to group Z" until Y connects (threat model). After expiry
/// the retention worker drops it.
fn pending_welcome_ttl_days() -> i64 {
    crate::retention::retention_days()
}

async fn handle_welcome(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    sender_user_pk: Uuid,
    frame_id: &str,
    mut w: Welcome,
) -> anyhow::Result<()> {
    // One person's devices — not a list of millions (WS-39: it was sorted
    // first and counted after).
    if w.recipient_device_pks.len() > MAX_WELCOME_DEVICES {
        push_ack(sessions, sender_user_pk, frame_id, 400, "too many recipient devices");
        return Ok(());
    }
    // A device listed 64 times got 64 stored copies (server-ws:6).
    w.recipient_device_pks.sort();
    w.recipient_device_pks.dedup();
    if w.welcome_bytes.len() > MAX_WELCOME_BYTES {
        push_ack(sessions, sender_user_pk, frame_id, 413, "welcome too large");
        return Ok(());
    }
    if w.recipient_identity_pubkey.len() != 32 {
        push_ack(
            sessions,
            sender_user_pk,
            frame_id,
            400,
            "recipient_identity_pubkey must be 32 bytes",
        );
        return Ok(());
    }
    if w.welcome_bytes.is_empty() {
        push_ack(sessions, sender_user_pk, frame_id, 400, "empty welcome_bytes");
        return Ok(());
    }
    if w.group_id.len() > MAX_GROUP_ID_BYTES {
        push_ack(sessions, sender_user_pk, frame_id, 400, "group_id too long");
        return Ok(());
    }

    // Lookup recipient by identity pubkey.
    let recipient: Option<(Uuid,)> = sqlx::query_as(
        "SELECT user_pk FROM users WHERE identity_pubkey = $1",
    )
    .bind(&w.recipient_identity_pubkey)
    .fetch_optional(pool)
    .await?;
    let Some((recipient_user_pk,)) = recipient else {
        push_ack(sessions, sender_user_pk, frame_id, 404, "recipient not registered");
        return Ok(());
    };
    // ADR-025 — a person with several devices may Welcome their own new
    // device (device sync); a person with one device has nobody to welcome.
    let recipient_devices = active_device_count(pool, recipient_user_pk).await?;
    if recipient_user_pk == sender_user_pk && recipient_devices < 2 {
        push_ack(
            sessions,
            sender_user_pk,
            frame_id,
            400,
            "cannot Welcome yourself",
        );
        return Ok(());
    }

    // WS-08 — an unaddressed Welcome to a person with several devices used
    // to stay queued for a year and be sent again on every login. The server
    // now addresses it to each of their devices itself: every copy is
    // delivered once and deleted.
    if w.recipient_device_pks.is_empty() && recipient_devices >= 2 {
        w.recipient_device_pks =
            sqlx::query_as("SELECT device_pk FROM devices WHERE user_pk = $1 AND revoked_at IS NULL ORDER BY device_pk LIMIT $2")
                .bind(recipient_user_pk)
                .bind(MAX_WELCOME_DEVICES as i64)
                .fetch_all(pool)
                .await?
                .into_iter()
                .map(|r: (Vec<u8>,)| r.0)
                .collect();
    }

    // ADR-025 — addressed to specific devices of the recipient: only those
    // get it; a device that's offline gets it queued for itself, and the
    // queued copy goes as soon as it has it.
    if !w.recipient_device_pks.is_empty() {
        let forward = WsFrame { frame_id: frame_id.to_string(), body: Some(Body::Welcome(w.clone())) };
        let got = sessions.fanout_devices(recipient_user_pk, &w.recipient_device_pks, encode_frame(&forward)?);
        let expires_at = OffsetDateTime::now_utc() + time::Duration::days(pending_welcome_ttl_days());
        let mut queued = 0usize;
        for d in w.recipient_device_pks.iter().filter(|d| !got.contains(d)) {
            let theirs: Option<(i32,)> =
                sqlx::query_as("SELECT 1 FROM devices WHERE device_pk = $1 AND user_pk = $2 AND revoked_at IS NULL")
                    .bind(d)
                    .bind(recipient_user_pk)
                    .fetch_optional(pool)
                    .await?;
            if theirs.is_none() {
                continue;
            }
            sqlx::query(
                "INSERT INTO pending_welcomes (recipient_user_pk, group_id, welcome_bytes, expires_at, recipient_device_pk) \
                 VALUES ($1, $2, $3, $4, $5)",
            )
            .bind(recipient_user_pk)
            .bind(&w.group_id)
            .bind(&w.welcome_bytes)
            .bind(expires_at)
            .bind(d)
            .execute(pool)
            .await?;
            queued += 1;
        }
        trim_pending_welcomes(pool, recipient_user_pk).await?;
        debug!(delivered = got.len(), queued, "welcome to devices");
        // WS-21 — one answer whether the person is online or not, and
        // whichever device is: the ack told any account both.
        push_ack(sessions, sender_user_pk, frame_id, 0, WELCOME_ACCEPTED);
        return Ok(());
    }

    // Forward verbatim — preserve original frame_id so the recipient's
    // client can correlate if it cares.
    let forward = WsFrame {
        frame_id: frame_id.to_string(),
        body: Some(Body::Welcome(w.clone())),
    };
    let bytes = encode_frame(&forward)?;
    let delivered = sessions.fanout(&[recipient_user_pk], bytes);
    info!(
        recipient = %crate::short_key(&hex::encode(&w.recipient_identity_pubkey)),
        delivered,
        group = %crate::short_key(&hex::encode(&w.group_id)),
        "welcome forwarded"
    );
    // ADR-025 — the server can't tell which of the recipient's devices a
    // Welcome is for (it's encrypted to KeyPackages), so with several
    // devices it stays queued until TTL even after a live delivery: each
    // device takes the ones addressed to it and ignores the rest.
    if delivered > 0 && recipient_devices < 2 {
        push_ack(sessions, sender_user_pk, frame_id, 0, WELCOME_ACCEPTED);
    } else {
        // Risk #10 — recipient offline. Persist the Welcome and ack OK
        // (not 503). On recipient's next Auth, `flush_pending_welcomes`
        // drains the queue. Expires after pending_welcome_ttl_days().
        let expires_at = OffsetDateTime::now_utc()
            + time::Duration::days(pending_welcome_ttl_days());
        let insert_res = sqlx::query(
            "INSERT INTO pending_welcomes \
                (recipient_user_pk, group_id, welcome_bytes, expires_at) \
             VALUES ($1, $2, $3, $4)",
        )
        .bind(recipient_user_pk)
        .bind(&w.group_id)
        .bind(&w.welcome_bytes)
        .bind(expires_at)
        .execute(pool)
        .await;
        match insert_res {
            Ok(_) => {
                trim_pending_welcomes(pool, recipient_user_pk).await?;
                info!(
                    recipient_user_pk = %crate::short_key(&recipient_user_pk.to_string()),
                    group = %crate::short_key(&hex::encode(&w.group_id)),
                    "welcome queued for offline recipient"
                );
                push_ack(sessions, sender_user_pk, frame_id, 0, WELCOME_ACCEPTED);
            }
            Err(e) => {
                warn!(error = %e, "failed to persist pending welcome");
                push_ack(
                    sessions,
                    sender_user_pk,
                    frame_id,
                    503,
                    "queue insert failed",
                );
            }
        }
    }
    Ok(())
}

/// Past [MAX_PENDING_WELCOME_BYTES] for one person the oldest queued
/// Welcomes go: a full queue refusing new ones would let a stranger stop
/// anyone being invited for a year.
async fn trim_pending_welcomes(pool: &PgPool, recipient: Uuid) -> anyhow::Result<()> {
    sqlx::query(
        "DELETE FROM pending_welcomes WHERE id IN (SELECT id FROM ( \
            SELECT id, SUM(octet_length(welcome_bytes) + octet_length(group_id)) OVER (ORDER BY id DESC) AS total \
            FROM pending_welcomes WHERE recipient_user_pk = $1) t WHERE total > $2)",
    )
    .bind(recipient)
    .bind(MAX_PENDING_WELCOME_BYTES as i64)
    .execute(pool)
    .await?;
    Ok(())
}

/// Drain queued Welcomes for the just-authenticated user. Called once
/// per WS connection right after the Auth handshake succeeds. Pushes
/// each Welcome to the session as a server-originated `WsFrame.Welcome`,
/// then deletes the row. Failures during fanout leave the row in place
/// so the next reconnect retries.
///
/// Risk #10 flush half — receive path that closes the loop opened by
/// `handle_welcome` queueing for an offline recipient.
pub(crate) async fn flush_pending_welcomes(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    user_pk: Uuid,
    device: Option<&[u8]>,
) -> anyhow::Result<()> {
    // This user's queued Welcomes — those for any of their devices, and
    // (ADR-025) those addressed to the device that just logged in.
    let rows: Vec<(i64, Vec<u8>, Vec<u8>, Option<Vec<u8>>)> = sqlx::query_as(
        // WS-09 — never more than the queue's cap into memory, whatever
        // the table holds (older rows, written under a larger cap): the
        // newest that fit, like `trim_pending_welcomes` keeps.
        "SELECT id, group_id, welcome_bytes, recipient_device_pk FROM ( \
            SELECT id, group_id, welcome_bytes, recipient_device_pk, enqueued_at, \
                   SUM(octet_length(welcome_bytes) + octet_length(group_id)) OVER (ORDER BY id DESC) AS total \
            FROM pending_welcomes \
            WHERE recipient_user_pk = $1 AND expires_at > NOW() \
              AND (recipient_device_pk IS NULL OR recipient_device_pk = $2)) t \
         WHERE total <= $3 \
         ORDER BY enqueued_at ASC, id ASC",
    )
    .bind(user_pk)
    .bind(device)
    .bind(MAX_PENDING_WELCOME_BYTES as i64)
    .fetch_all(pool)
    .await?;

    if rows.is_empty() {
        return Ok(());
    }

    let now_ts = OffsetDateTime::now_utc().unix_timestamp();
    let mut delivered_any = Vec::with_capacity(rows.len());
    let mut delivered_mine = Vec::new();
    for (id, group_id, welcome_bytes, for_device) in rows {
        let frame = WsFrame {
            frame_id: format!("queued-welcome-{id}"),
            body: Some(Body::Welcome(Welcome {
                // recipient_identity_pubkey isn't strictly needed at
                // this point (the recipient IS already authenticated
                // on this session), but the schema field is non-empty —
                // we set it to an empty vec; client SDK accepts.
                recipient_identity_pubkey: Vec::new(),
                group_id,
                welcome_bytes,
                sent_at: now_ts,
                recipient_device_pks: for_device.iter().cloned().collect(),
            })),
        };
        let bytes = match encode_frame(&frame) {
            Ok(b) => b,
            Err(e) => {
                warn!(error = %e, id, "failed to encode pending welcome");
                continue;
            }
        };
        match for_device {
            // Addressed to this device: once it has it, it's gone.
            Some(d) => {
                if !sessions.fanout_devices(user_pk, &[d], bytes).is_empty() {
                    delivered_mine.push(id);
                }
            }
            // WS-08 — to the device that just logged in, not once more to
            // every other connection of the person.
            None => {
                let got = match device {
                    Some(d) => !sessions.fanout_devices(user_pk, &[d.to_vec()], bytes).is_empty(),
                    None => sessions.fanout(&[user_pk], bytes) > 0,
                };
                if got {
                    delivered_any.push(id);
                }
            }
        }
    }

    // Unaddressed ones: with several devices another one may still need
    // them; they expire instead (see handle_welcome).
    if !delivered_any.is_empty() && active_device_count(pool, user_pk).await? < 2 {
        delivered_mine.extend(delivered_any);
    }
    if !delivered_mine.is_empty() {
        let n = delivered_mine.len();
        sqlx::query("DELETE FROM pending_welcomes WHERE id = ANY($1)")
            .bind(&delivered_mine)
            .execute(pool)
            .await?;
        info!(count = n, "flushed pending welcomes");
    }
    Ok(())
}

/// ADR-025 — how many active (not revoked) devices a person has.
async fn active_device_count(pool: &PgPool, user_pk: Uuid) -> anyhow::Result<i64> {
    let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices WHERE user_pk = $1 AND revoked_at IS NULL")
        .bind(user_pk)
        .fetch_one(pool)
        .await?;
    Ok(n)
}

// ─────────────────────────────────────────────────────────────────────
// Call signaling — WU CB2 + CB4 (1:1 calls per spec §10)
// ─────────────────────────────────────────────────────────────────────
//
// Three frame types arrive on this server's WS:
//
//   CallInvite (client → server): caller asks to start a call. Server
//   verifies group membership + 1:1ness + that no other call is active
//   for this group. On success it registers a CallSession, forwards
//   CallInvite verbatim to the callee, and sends CallRing back to the
//   caller (signals "we got it; ringing on the other side").
//
//   CallAccept (client → server): callee picks up (or declines). Server
//   authorizes (only the callee may Accept), updates session state,
//   forwards Accept to the caller.
//
//   CallEnd (client → server): either side hangs up. Forward to the
//   opposite party; session moves to Ended (grace 5s) before eviction.
//
// CallRing is server-emitted only — never accepted from clients.
//
// Authorization model:
//   - 1:1 calls: the other member is the callee.
//   - Group calls (tech-debt 4.9, 2026-10-13): every other member is
//     invited (≤ MAX_CALL_PARTIES); anyone invited may join while it
//     rings or runs; leaving doesn't end it for the rest until one
//     person is left. Media is still one LiveKit room with the group's
//     SFrame key (MLS exporter), so it scales without server changes.
//   - Caller must be a member of the group_id.
//   - Only invitees can CallAccept. Any party can CallEnd.
//
// Server does NOT see media — only signaling. LiveKit (the SFU) handles
// SRTP transport; SFrame keys come from MLS exporter, also invisible
// here. See `docs/plan-calls.md` for the broader architecture.

const CALL_KIND_AUDIO_TAG: &str = "audio";
/// Largest group that may start a call (LiveKit room + SFrame KID
/// sender-index space of 64 leave headroom).
const MAX_CALL_PARTIES: usize = 32;
const CALL_KIND_VIDEO_TAG: &str = "video";

async fn handle_call_invite(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    push: &std::sync::Arc<dyn crate::push::PushClient>,
    calls: &CallSessionRegistry,
    caller_user_pk: Uuid,
    frame_id: &str,
    inv: CallInvite,
) -> anyhow::Result<()> {
    // ── Validate inputs ──────────────────────────────────────────────
    let Ok(call_id) = Uuid::parse_str(&inv.call_id) else {
        push_ack(sessions, caller_user_pk, frame_id, 400, "call_id must be UUID");
        return Ok(());
    };
    if inv.group_id.is_empty() {
        push_ack(sessions, caller_user_pk, frame_id, 400, "empty group_id");
        return Ok(());
    }
    // proto3 enum decodes as i32; map to our internal type. Default (0)
    // = KIND_UNKNOWN — reject.
    let kind = match inv.kind {
        1 => CallKind::Audio,
        2 => CallKind::Video,
        _ => {
            push_ack(sessions, caller_user_pk, frame_id, 400, "kind must be AUDIO or VIDEO");
            return Ok(());
        }
    };
    let kind_tag = match kind {
        CallKind::Audio => CALL_KIND_AUDIO_TAG,
        CallKind::Video => CALL_KIND_VIDEO_TAG,
    };
    // ADR-090 (calls:5) — the caller signs its invite; the phones check it
    // (the server only passes it on). Without it the server alone could ring
    // anyone as anyone.
    if !(crate::push::MIN_CALL_PROOF..=crate::push::MAX_CALL_PROOF).contains(&inv.caller_proof.len()) {
        push_ack(sessions, caller_user_pk, frame_id, 400, "the invite must be signed by its caller");
        return Ok(());
    }

    // ── Verify group exists + collect distinct member user_pk's ──────
    //
    // We need every device's user_pk because group_members keys by
    // device, but call participation is at the user level (a user with
    // two paired phones is still one party in the call).
    let members: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT DISTINCT d.user_pk \
         FROM group_members gm \
         JOIN devices d ON d.device_pk = gm.device_pk \
         WHERE gm.group_id = $1 AND d.revoked_at IS NULL",
    )
    .bind(&inv.group_id)
    .fetch_all(pool)
    .await?;

    if members.is_empty() {
        push_ack(sessions, caller_user_pk, frame_id, 404, "group not found");
        return Ok(());
    }

    if members.len() < 2 {
        push_ack(sessions, caller_user_pk, frame_id, 412, "nobody else in this group");
        return Ok(());
    }
    if members.len() > MAX_CALL_PARTIES {
        push_ack(sessions, caller_user_pk, frame_id, 412, "group too large for a call");
        return Ok(());
    }
    if !members.iter().any(|(u,)| *u == caller_user_pk) {
        push_ack(sessions, caller_user_pk, frame_id, 403, "not a group member");
        return Ok(());
    }
    let invitees: Vec<Uuid> = members.iter().map(|(u,)| *u).filter(|u| *u != caller_user_pk).collect();
    let invited = invitees.len();
    // ADR-071 — who wants this caller's key: someone who revoked it
    // (blocked the caller) isn't invited at all; someone the caller holds
    // no key for gets the invite in their open app, without a push.
    let verdicts = crate::handlers::access_keys::call_verdicts(pool, &invitees, &inv.access_keys).await?;
    let verdict = |u: &Uuid| verdicts.get(u).copied().unwrap_or(AccessCall::Ring);
    let swallowed = invitees.iter().filter(|u| verdict(u) == AccessCall::Swallow).count();
    let invitees: Vec<Uuid> = invitees.into_iter().filter(|u| verdict(u) != AccessCall::Swallow).collect();
    let quiet: Vec<Uuid> = invitees.iter().filter(|u| verdict(u) == AccessCall::AppOnly).copied().collect();

    // ── Cap TTL and synthesize canonical livekit_room ─────────────────
    let ttl_secs = inv
        .ttl_secs
        .clamp(0, crate::call_session::RINGING_TIMEOUT_MAX_SECS as i64);
    let livekit_room = format!("sinhron-call-{}", call_id);

    // ── Register CallSession (rejects busy / duplicate) ──────────────
    //
    // CallSession.last_activity is std::time::Instant (monotonic, no
    // async runtime tie-in). ws.rs already imports tokio::time::Instant
    // for its timeout/last_seen plumbing, so we explicitly construct a
    // std Instant here to avoid the collision.
    // Tech-debt 2.27 — who calls, for the callee's block list.
    let caller_identity: Vec<u8> = sqlx::query_scalar("SELECT identity_pubkey FROM users WHERE user_pk = $1")
        .bind(caller_user_pk)
        .fetch_optional(pool)
        .await?
        .unwrap_or_default();
    let session = CallSession {
        call_id,
        group_id: inv.group_id.clone(),
        caller_user_pk,
        caller_identity: caller_identity.clone(),
        caller_proof: inv.caller_proof.clone(),
        invitees: invitees.clone(),
        joined: Vec::new(),
        gone: Vec::new(),
        woken: Vec::new(),
        quiet: quiet.clone(),
        kind,
        livekit_room: livekit_room.clone(),
        status: crate::call_session::CallStatus::Ringing,
        created_at_unix: OffsetDateTime::now_utc().unix_timestamp(),
        last_activity: std::time::Instant::now(),
    };
    let mut started = calls.start_call(session.clone());
    // server-ws:5 — a call everyone left without a CallEnd kept the group
    // "busy" until a restart. Nobody in its LiveKit room and nothing heard
    // for a minute: end it, tell its people, start this one.
    if started == StartCallOutcome::GroupBusy && crate::handlers::call::group_room_is_empty(&inv.group_id).await {
        if let Some(dead) = calls.end_stale(&inv.group_id, Duration::from_secs(60)) {
            let end = CallEnd { call_id: dead.call_id.to_string(), reason: "ended".to_string() };
            sessions.fanout(&dead.reachable(), encode_frame(&WsFrame { frame_id: String::new(), body: Some(Body::CallEnd(end)) })?);
            started = calls.start_call(session);
        }
    }
    match started {
        StartCallOutcome::Started => {}
        StartCallOutcome::GroupBusy => {
            push_ack(sessions, caller_user_pk, frame_id, 409, "another call is active for this group");
            return Ok(());
        }
        StartCallOutcome::DuplicateCallId => {
            push_ack(sessions, caller_user_pk, frame_id, 409, "call_id already in use");
            return Ok(());
        }
    }

    // ── Forward CallInvite to the callee (rewrite ttl + livekit_room) ──
    let forward = WsFrame {
        frame_id: frame_id.to_string(),
        body: Some(Body::CallInvite(CallInvite {
            call_id: inv.call_id.clone(),
            group_id: inv.group_id.clone(),
            kind: inv.kind,
            livekit_room: livekit_room.clone(),
            ttl_secs,
            caller_identity: caller_identity.clone(),
            access_keys: Vec::new(),
            sends_access_keys: false,
            caller_proof: inv.caller_proof.clone(),
        })),
    };
    let bytes = encode_frame(&forward)?;
    let mut delivered = 0usize;
    let mut offline: Vec<Uuid> = Vec::new();
    let mut online: Vec<Uuid> = Vec::new();
    for u in &invitees {
        let n = sessions.fanout(std::slice::from_ref(u), bytes.clone());
        if verdict(u) == AccessCall::AppOnly {
            // No push: the open app only. The caller isn't told it got there
            // (calls:10 — someone I blocked learnt "online right now" from
            // it, and that they are blocked): it looks like a swallowed one.
            continue;
        }
        delivered += n;
        if n == 0 {
            offline.push(*u);
        } else {
            online.push(*u);
        }
    }
    // Overnight item 9 — wake offline invitees' phones (PushKit): the call
    // rings on the lock screen; the app connects and gets this invite
    // replayed (`replay_ringing_invites`). No group, no caller in the push.
    // Status 167 — and the connected ones' Android phones through Google:
    // a swiped-away app can leave a socket up that nothing reads.
    let mut voip = crate::push::voip_targets(pool, &offline).await.unwrap_or_else(|e| {
        warn!(error = %e, "voip token lookup failed");
        Vec::new()
    });
    // 2026-10-26 — and their other devices that aren't connected (a locked
    // iPhone while the iPad is open).
    let connected = sessions.online_devices(&online);
    voip.extend(crate::push::call_targets_for_connected(pool, &online, &connected).await.unwrap_or_else(|e| {
        warn!(error = %e, "call token lookup for connected callees failed");
        Vec::new()
    }));
    // Status 182 — who must not be pushed again on disconnect: those pushed
    // now (offline) and those never to be pushed (no key).
    calls.mark_woken(&call_id, invitees.iter().filter(|u| offline.contains(u) || verdict(u) == AccessCall::AppOnly).copied());
    let woken = voip.len();
    crate::push::spawn_call(
        pool.clone(),
        push.clone(),
        voip,
        inv.call_id.clone(),
        kind == CallKind::Video,
        inv.group_id.clone(),
        caller_identity.clone(),
        inv.caller_proof.clone(),
    );

    // ── Send CallRing back to caller — "we delivered it" signal ──────
    let ring = WsFrame {
        frame_id: String::new(),
        body: Some(Body::CallRing(CallRing {
            call_id: inv.call_id.clone(),
            delivered: delivered > 0,
        })),
    };
    if let Ok(ring_bytes) = encode_frame(&ring) {
        sessions.fanout(&[caller_user_pk], ring_bytes);
    }

    info!(
        call_id = %inv.call_id,
        kind = %kind_tag,
        caller = %crate::short_key(&caller_user_pk.to_string()),
        // Everyone in the group, swallowed ones too (ADR-071: the log
        // mustn't tell a block apart from an unanswered phone).
        invitees = invited,
        delivered,
        "call invite forwarded",
    );

    crate::metrics::CALLS_TOTAL
        .with_label_values(&[kind_tag])
        .inc();

    // Swallowed (ADR-071): the caller hears ringing until the timeout,
    // exactly as if the phone just wasn't picked up.
    if delivered > 0 || woken > 0 || swallowed > 0 || !quiet.is_empty() {
        push_ack(sessions, caller_user_pk, frame_id, 0, "ringing");
    } else {
        // Nobody online and no phone to wake: the caller hears "offline"
        // at once instead of ringing into the void.
        push_ack(sessions, caller_user_pk, frame_id, 503, "callee offline");
        // Tear down the session — no "ringing forever".
        let _ = calls.end(call_id, caller_user_pk);
    }

    Ok(())
}

/// Invites of calls still ringing for [user] (they haven't answered or
/// declined) — to a connection that just logged in.
async fn push_ringing_after_disconnect(
    pool: &PgPool,
    push: &std::sync::Arc<dyn crate::push::PushClient>,
    calls: &CallSessionRegistry,
    user: Uuid,
) {
    for c in calls.take_unwoken(user) {
        let targets = match crate::push::voip_targets(pool, &[user]).await {
            Ok(t) => t,
            Err(e) => {
                warn!(error = %e, "voip token lookup failed");
                continue;
            }
        };
        info!(phones = targets.len(), "call push after disconnect");
        crate::push::spawn_call(
            pool.clone(),
            push.clone(),
            targets,
            c.call_id.to_string(),
            c.kind == CallKind::Video,
            c.group_id.clone(),
            c.caller_identity.clone(),
            c.caller_proof.clone(),
        );
    }
}

/// Status 223 — to the connection that just came ([device]), not to all of
/// the person's devices: one already ringing for the call took the second
/// copy as a new call and answered "busy", ending it for the caller.
fn replay_ringing_invites(
    sessions: &crate::session::SessionRegistry,
    calls: &CallSessionRegistry,
    user: Uuid,
    device: Option<&[u8]>,
) {
    let now = OffsetDateTime::now_utc().unix_timestamp();
    for c in calls.ringing_for(user) {
        let left = (crate::call_session::RINGING_TIMEOUT_SECS as i64 - (now - c.created_at_unix)).max(1);
        let frame = WsFrame {
            frame_id: String::new(),
            body: Some(Body::CallInvite(CallInvite {
                call_id: c.call_id.to_string(),
                group_id: c.group_id.clone(),
                kind: match c.kind {
                    CallKind::Audio => 1,
                    CallKind::Video => 2,
                },
                livekit_room: c.livekit_room.clone(),
                ttl_secs: left,
                caller_identity: c.caller_identity.clone(),
                access_keys: Vec::new(),
                sends_access_keys: false,
                caller_proof: c.caller_proof.clone(),
            })),
        };
        if let Ok(bytes) = encode_frame(&frame) {
            // Status 213 — their phone woke and connected: it rings now, and
            // the caller's screen can say so.
            let reached = match device {
                Some(d) => !sessions.fanout_devices(user, &[d.to_vec()], bytes).is_empty(),
                None => sessions.fanout(&[user], bytes) > 0,
            };
            if reached && !c.quiet.contains(&user) {
                let ring = WsFrame {
                    frame_id: String::new(),
                    body: Some(Body::CallRing(CallRing { call_id: c.call_id.to_string(), delivered: true })),
                };
                if let Ok(ring) = encode_frame(&ring) {
                    sessions.fanout(&[c.caller_user_pk], ring);
                }
            }
        }
    }
}

async fn handle_call_accept(
    sessions: &crate::session::SessionRegistry,
    calls: &CallSessionRegistry,
    actor_user_pk: Uuid,
    actor_device: Option<&[u8]>,
    frame_id: &str,
    accept: CallAccept,
) -> anyhow::Result<()> {
    let Ok(call_id) = Uuid::parse_str(&accept.call_id) else {
        push_ack(sessions, actor_user_pk, frame_id, 400, "call_id must be UUID");
        return Ok(());
    };

    // Unknown call → 404 before touching the registry.
    let Some(_existing) = calls.get(&call_id) else {
        push_ack(sessions, actor_user_pk, frame_id, 404, "call not found");
        return Ok(());
    };

    if accept.accept {
        // Callee picks up. Only the callee may flip Ringing → Active.
        match calls.accept(call_id, actor_user_pk) {
            crate::call_session::CallUpdateOutcome::Updated => {}
            crate::call_session::CallUpdateOutcome::Unauthorized => {
                push_ack(sessions, actor_user_pk, frame_id, 403, "only callee may accept");
                return Ok(());
            }
            crate::call_session::CallUpdateOutcome::InvalidTransition => {
                push_ack(sessions, actor_user_pk, frame_id, 409, "cannot accept in current state");
                return Ok(());
            }
            crate::call_session::CallUpdateOutcome::Unknown => {
                push_ack(sessions, actor_user_pk, frame_id, 404, "call not found");
                return Ok(());
            }
        }

        // Tell everyone already in the call (the caller, earlier joiners)
        // so the caller's UI goes Ringing → Connected; in a group call the
        // others just learn someone joined.
        let forward = WsFrame {
            frame_id: frame_id.to_string(),
            body: Some(Body::CallAccept(CallAccept {
                call_id: accept.call_id.clone(),
                accept: true,
            })),
        };
        if let Ok(bytes) = encode_frame(&forward) {
            let others: Vec<Uuid> = calls
                .get(&call_id)
                .map(|c| c.present().into_iter().filter(|u| *u != actor_user_pk).collect())
                .unwrap_or_default();
            sessions.fanout(&others, bytes);
        }

        // Noted first: a device connecting in between learns it on connect.
        if let Some(d) = actor_device {
            calls.note_answered_on(call_id, actor_user_pk, d);
        }
        stop_ringing_elsewhere(sessions, actor_user_pk, actor_device, &accept.call_id, "answered_elsewhere");
        info!(
            call_id = %accept.call_id,
            callee = %crate::short_key(&actor_user_pk.to_string()),
            "call accepted",
        );
        push_ack(sessions, actor_user_pk, frame_id, 0, "accepted");
    } else {
        // Decline. 1:1 (or the last invitee of a group): the caller is
        // told "rejected". A group call keeps ringing for the others.
        let notify = match calls.leave(call_id, actor_user_pk) {
            crate::call_session::LeaveOutcome::Left { notify, .. } => notify,
            crate::call_session::LeaveOutcome::Unauthorized => {
                push_ack(sessions, actor_user_pk, frame_id, 403, "not a party to this call");
                return Ok(());
            }
            crate::call_session::LeaveOutcome::Unknown => {
                push_ack(sessions, actor_user_pk, frame_id, 404, "call not found");
                return Ok(());
            }
        };
        let forward = WsFrame {
            frame_id: frame_id.to_string(),
            body: Some(Body::CallEnd(CallEnd {
                call_id: accept.call_id.clone(),
                reason: "rejected".to_string(),
            })),
        };
        if let Ok(bytes) = encode_frame(&forward) {
            sessions.fanout(&notify, bytes);
        }
        stop_ringing_elsewhere(sessions, actor_user_pk, actor_device, &accept.call_id, "declined_elsewhere");
        info!(
            call_id = %accept.call_id,
            callee = %crate::short_key(&actor_user_pk.to_string()),
            "call declined",
        );
        push_ack(sessions, actor_user_pk, frame_id, 0, "declined");
    }

    Ok(())
}

/// 2026-10-26 — the callee answered (or declined) on one device: the
/// person's other devices stop ringing. A CallEnd with [reason] goes to
/// every other connection of theirs (older apps just end the ring).
fn stop_ringing_elsewhere(
    sessions: &crate::session::SessionRegistry,
    user_pk: Uuid,
    actor_device: Option<&[u8]>,
    call_id: &str,
    reason: &str,
) {
    let Some(device) = actor_device else { return };
    let frame = WsFrame {
        frame_id: String::new(),
        body: Some(Body::CallEnd(CallEnd { call_id: call_id.to_string(), reason: reason.to_string() })),
    };
    if let Ok(bytes) = encode_frame(&frame) {
        sessions.fanout_user_except_device(user_pk, device, bytes);
    }
}

/// CB5 — periodic watchdog. Calls `gc_expired()` ~once per second to:
///   1. Evict Ringing sessions older than `RINGING_TIMEOUT_SECS` and
///      broadcast `CallEnd { reason: "no_answer" }` to both parties.
///   2. Evict Ended sessions past the grace window (silent — both
///      parties already know).
///   3. Update the `sinhron_calls_active` gauge for /metrics.
///
/// The watchdog also publishes the CallEnd notifications so the
/// caller's UI flips from "Ringing..." to "No answer" without the
/// client itself running a timer. Spec §10 implies server-driven
/// timeout for predictability across mixed clock environments.
///
/// Returns the JoinHandle so the test suite / shutdown logic can
/// abort it if needed. In production we spawn-and-forget.
pub fn spawn_call_watchdog(
    calls: CallSessionRegistry,
    sessions: crate::session::SessionRegistry,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(Duration::from_secs(1));
        // First tick fires immediately — skip it so we don't run the
        // sweep before any session was ever inserted.
        ticker.tick().await;

        loop {
            ticker.tick().await;

            let expired = calls.gc_expired();
            crate::metrics::CALLS_ACTIVE.set(calls.count_active() as i64);

            if expired.is_empty() {
                continue;
            }

            for session in expired {
                let frame = WsFrame {
                    frame_id: String::new(),
                    body: Some(Body::CallEnd(CallEnd {
                        call_id: session.call_id.to_string(),
                        reason: "no_answer".to_string(),
                    })),
                };
                let bytes = match encode_frame(&frame) {
                    Ok(b) => b,
                    Err(e) => {
                        warn!(
                            call_id = %session.call_id,
                            error = %e,
                            "watchdog: failed to encode CallEnd"
                        );
                        continue;
                    }
                };
                let dlv = sessions.fanout(&session.reachable(), bytes);
                info!(
                    call_id = %session.call_id,
                    delivered = dlv,
                    "watchdog: ringing timeout → CallEnd no_answer",
                );
            }
        }
    })
}

async fn handle_call_end(
    sessions: &crate::session::SessionRegistry,
    calls: &CallSessionRegistry,
    actor_user_pk: Uuid,
    frame_id: &str,
    end: CallEnd,
) -> anyhow::Result<()> {
    let Ok(call_id) = Uuid::parse_str(&end.call_id) else {
        push_ack(sessions, actor_user_pk, frame_id, 400, "call_id must be UUID");
        return Ok(());
    };

    // Already gone (past the GRACE_SECS window) → idempotent ack.
    let Some(_existing) = calls.get(&call_id) else {
        // Already gone — could be a late retransmit. Idempotent ack.
        push_ack(sessions, actor_user_pk, frame_id, 0, "call already ended");
        return Ok(());
    };

    let notify = match calls.leave(call_id, actor_user_pk) {
        crate::call_session::LeaveOutcome::Left { notify, .. } => notify,
        crate::call_session::LeaveOutcome::Unauthorized => {
            push_ack(sessions, actor_user_pk, frame_id, 403, "not a party to this call");
            return Ok(());
        }
        crate::call_session::LeaveOutcome::Unknown => {
            push_ack(sessions, actor_user_pk, frame_id, 0, "call already ended");
            return Ok(());
        }
    };

    // Forward CallEnd to whoever the registry says (the other party of
    // a 1:1 call; in a group, nobody while it goes on, everyone left
    // when it's over). Bounded reason length so a misbehaving client
    // can't pump arbitrary data through the signaling channel.
    // On a character boundary: a letter across byte 64 panicked (server-ws:7).
    let mut reason = end.reason.clone();
    let mut cut = reason.len().min(64);
    while !reason.is_char_boundary(cut) {
        cut -= 1;
    }
    reason.truncate(cut);
    // The server's own words about a person's other devices: from a client
    // they kept the other side's call (and mic) on, or hid a missed call
    // (audit 2026-11b #23).
    if reason == "answered_elsewhere" || reason == "declined_elsewhere" {
        reason = "hangup".to_string();
    }

    let forward = WsFrame {
        frame_id: frame_id.to_string(),
        body: Some(Body::CallEnd(CallEnd {
            call_id: end.call_id.clone(),
            reason: reason.clone(),
        })),
    };
    if let Ok(bytes) = encode_frame(&forward) {
        sessions.fanout(&notify, bytes);
    }

    info!(
        call_id = %end.call_id,
        actor = %crate::short_key(&actor_user_pk.to_string()),
        reason = %reason,
        "call ended",
    );
    push_ack(sessions, actor_user_pk, frame_id, 0, "ended");
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────
// Resume handler — replay missed messages since cursor
// ─────────────────────────────────────────────────────────────────────

async fn handle_resume(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    self_user_pk: Uuid,
    frame_id: &str,
    r: Resume,
) -> anyhow::Result<()> {
    // For now we honor only `MAIN_STREAM_ID`. Extra cursors are ignored
    // with a debug log so future expansion is non-breaking.
    let cursor = r
        .cursors
        .iter()
        .find(|c: &&StreamCursor| c.stream_id == MAIN_STREAM_ID)
        .map(|c| c.last_acked_seq as i64)
        .unwrap_or(0);

    // SELECT all deliveries newer than cursor for this user, JOIN onto
    // messages for the actual ciphertext. ORDER BY seq ASC so the client
    // receives them in insertion order (in-MLS-group ordering invariant
    // per spec §7.3 line 366).
    // ADR-023: a sealed delivery carries its own envelope and has no
    // `messages` row — LEFT JOIN, prefer the envelope, empty group id.
    let rows: Vec<DeliveryRow> = sqlx::query_as(
        "SELECT seq, message_id, group_id, body, ts, key FROM ( \
         SELECT md.seq, md.message_id, COALESCE(m.group_id, ''::bytea) AS group_id, \
                COALESCE(md.envelope, m.ciphertext) AS body, COALESCE(m.ts, md.delivered_at) AS ts, \
                COALESCE(md.sealed_key_id, ''::bytea) AS key, \
                SUM(octet_length(COALESCE(md.envelope, m.ciphertext))) OVER (ORDER BY md.seq) AS total \
         FROM message_deliveries md \
         LEFT JOIN messages m ON m.message_id = md.message_id AND md.envelope IS NULL \
         WHERE md.recipient_user_pk = $1 AND md.seq > $2 \
           AND (md.expires_at IS NULL OR md.expires_at > NOW()) \
           AND (md.envelope IS NOT NULL OR m.message_id IS NOT NULL) \
         ORDER BY md.seq ASC \
         LIMIT 1000) page \
         WHERE total - octet_length(body) < $3 ORDER BY seq ASC",
    )
    .bind(self_user_pk)
    .bind(cursor)
    .bind(MAX_REPLAY_BYTES)
    .fetch_all(pool)
    .await?;

    info!(
        cursor = cursor,
        replayed = rows.len(),
        "resume replay"
    );

    // REL-1 — the page stops at 1000 rows / [MAX_REPLAY_BYTES]. A live push
    // then moves a second device's cursor past the rest, which no later
    // Resume asks for (the first device already marked it received): it was
    // lost on that device. Say where the page ended; the client asks on.
    let last = rows.last().map(|r| r.0);
    let sent = push_rows(pool, sessions, self_user_pk, rows).await?;
    let more = match last {
        Some(last) => sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM message_deliveries WHERE recipient_user_pk = $1 AND seq > $2 \
               AND (expires_at IS NULL OR expires_at > NOW()))",
        )
        .bind(self_user_pk)
        .bind(last)
        .fetch_one(pool)
        .await?
        .then_some(last),
        None => None,
    };
    let msg = match more {
        Some(last) => format!("replayed {sent} more {last}"),
        None => format!("replayed {sent}"),
    };
    push_ack(sessions, self_user_pk, frame_id, 0, &msg);
    Ok(())
}

/// REL-1 — the seq a Resume page ended at, when more is waiting.
pub fn resume_more(msg: &str) -> Option<u64> {
    msg.strip_prefix("replayed ")?.split_once(" more ")?.1.parse().ok()
}

#[cfg(test)]
mod rel1_tests {
    #[test]
    fn a_cut_page_says_where_it_ended() {
        assert_eq!(super::resume_more("replayed 1000 more 4242"), Some(4242));
        assert_eq!(super::resume_more("replayed 12"), None);
    }
}

/// WS-03 — most bytes one login or Resume reads from the queue (the last
/// row may go over by its own size, at most 4 MiB). It was 1000 rows of any
/// size — up to ~4 GB into memory per request. The rest comes with the next
/// Resume or login. With the Welcome queue (8 MiB) it stays under one
/// connection's cap (32 MiB), so a login never stalls its own connection.
const MAX_REPLAY_BYTES: i64 = 16 * 1024 * 1024;

/// One delivery row: seq, message id, group id, ciphertext, time, sealed key.
type DeliveryRow = (i64, Uuid, Vec<u8>, Vec<u8>, OffsetDateTime, Vec<u8>);

/// On every login: push what hasn't reached this person yet (nothing was
/// connected when it came) — oldest first, like Resume. Returns how many.
pub(crate) async fn deliver_backlog(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    user_pk: Uuid,
) -> anyhow::Result<usize> {
    let rows: Vec<DeliveryRow> = sqlx::query_as(
        "SELECT seq, message_id, group_id, body, ts, key FROM ( \
         SELECT md.seq, md.message_id, COALESCE(m.group_id, ''::bytea) AS group_id, \
                COALESCE(md.envelope, m.ciphertext) AS body, COALESCE(m.ts, md.delivered_at) AS ts, \
                COALESCE(md.sealed_key_id, ''::bytea) AS key, \
                SUM(octet_length(COALESCE(md.envelope, m.ciphertext))) OVER (ORDER BY md.seq) AS total \
         FROM message_deliveries md \
         LEFT JOIN messages m ON m.message_id = md.message_id AND md.envelope IS NULL \
         WHERE md.recipient_user_pk = $1 AND md.received_at IS NULL \
           AND (md.expires_at IS NULL OR md.expires_at > NOW()) \
           AND (md.envelope IS NOT NULL OR m.message_id IS NOT NULL) \
         ORDER BY md.seq ASC \
         LIMIT 1000) page \
         WHERE total - octet_length(body) < $2 ORDER BY seq ASC",
    )
    .bind(user_pk)
    .bind(MAX_REPLAY_BYTES)
    .fetch_all(pool)
    .await?;
    if rows.is_empty() {
        return Ok(0);
    }
    let n = rows.len();
    let sent = push_rows(pool, sessions, user_pk, rows).await?;
    info!(waiting = n, sent, "backlog delivered on login");
    Ok(sent)
}

/// Push delivery rows to [user]'s live connections; the ones that went out
/// count as received (ADR-020 timers start). Returns the number of frames.
async fn push_rows(
    pool: &PgPool,
    sessions: &crate::session::SessionRegistry,
    user: Uuid,
    rows: Vec<DeliveryRow>,
) -> anyhow::Result<usize> {
    let mut sent = 0usize;
    let mut replayed = Vec::new();
    for (seq, message_id, group_id, ciphertext, ts, sealed_key_id) in rows {
        let push = WsFrame {
            frame_id: String::new(),
            body: Some(Body::Push(Push {
                group_id,
                ciphertext,
                message_id: message_id.to_string(),
                delivered_at: ts.unix_timestamp(),
                sequence: seq as u64,
                sealed_key_id,
            })),
        };
        let bytes = encode_frame(&push)?;
        let n = sessions.fanout(&[user], bytes);
        if n > 0 {
            replayed.push(seq);
        }
        sent += n;
    }
    mark_received(pool, user, &replayed).await?;
    Ok(sent)
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

fn encode_frame(frame: &WsFrame) -> anyhow::Result<Bytes> {
    let mut buf = Vec::with_capacity(frame.encoded_len());
    frame.encode(&mut buf)?;
    Ok(Bytes::from(buf))
}

/// An ack or heartbeat reply: to the connection that sent the frame
/// ([REPLY_TO]); outside a connection (tests), to all of [user_pk]'s.
fn push_to_user(
    sessions: &crate::session::SessionRegistry,
    user_pk: Uuid,
    frame: &WsFrame,
) {
    if let Ok(bytes) = encode_frame(frame) {
        match REPLY_TO.try_with(|c| *c) {
            Ok(conn) => {
                sessions.send_to(user_pk, conn, bytes);
            }
            Err(_) => {
                sessions.fanout(&[user_pk], bytes);
            }
        }
    }
}

fn push_ack(
    sessions: &crate::session::SessionRegistry,
    user_pk: Uuid,
    acked_frame_id: &str,
    error_code: i32,
    error_message: &str,
) {
    let ack = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Ack(Ack {
            acked_frame_id: acked_frame_id.to_string(),
            error_code,
            error_message: error_message.to_string(),
        })),
    };
    push_to_user(sessions, user_pk, &ack);
}

// ─────────────────────────────────────────────────────────────────────
// Auth-phase helpers (run on the joined socket, before splitting)
// ─────────────────────────────────────────────────────────────────────

async fn verify_auth_with_challenge(
    socket: &mut WebSocket,
    challenge: &[u8; 32],
) -> Result<Auth, String> {
    let frame = next_frame_inline(socket).await?;
    let auth = match frame.body {
        Some(Body::Auth(a)) => a,
        Some(_) => return Err("first frame must be Auth".to_string()),
        None => return Err("frame has no body".to_string()),
    };

    if auth.identity_pubkey.len() != 32 {
        return Err(format!(
            "identity_pubkey must be 32 bytes, got {}",
            auth.identity_pubkey.len()
        ));
    }
    if auth.signature.len() != 64 {
        return Err(format!(
            "signature must be 64 bytes, got {}",
            auth.signature.len()
        ));
    }

    crate::handlers::proof::verify_ws_auth(&auth.identity_pubkey, &auth.signature, challenge)
        .map_err(|e| e.to_string())?;
    Ok(auth)
}

async fn send_frame_inline(socket: &mut WebSocket, frame: &WsFrame) -> anyhow::Result<()> {
    let bytes = encode_frame(frame)?;
    socket
        .send(Message::Binary(bytes))
        .await
        .map_err(|e| anyhow::anyhow!("ws send failed: {e}"))
}

async fn send_ack_inline(
    socket: &mut WebSocket,
    acked_frame_id: &str,
    error_code: i32,
    error_message: &str,
) -> anyhow::Result<()> {
    let ack = WsFrame {
        frame_id: String::new(),
        body: Some(Body::Ack(Ack {
            acked_frame_id: acked_frame_id.to_string(),
            error_code,
            error_message: error_message.to_string(),
        })),
    };
    send_frame_inline(socket, &ack).await
}

/// The first frame, sized before it is decoded ([MAX_AUTH_FRAME_BYTES]).
fn decode_auth_frame(bytes: &[u8]) -> Result<WsFrame, String> {
    if bytes.len() > MAX_AUTH_FRAME_BYTES {
        return Err(format!("first frame over {MAX_AUTH_FRAME_BYTES} bytes"));
    }
    WsFrame::decode(bytes).map_err(|e| format!("frame decode error: {e}"))
}

/// WS-50 — most fields the body of one frame may have. The largest honest
/// list is 1000 sealed deliveries.
const MAX_FRAME_FIELDS: usize = 4096;

/// The app's frame ids are a UUID with a short prefix.
const MAX_FRAME_ID_BYTES: usize = 128;

/// A frame after login. WS-50 — 4 MiB of empty list items (two bytes each)
/// decoded into ~180 MiB of heap before any check ran; several connections
/// at once and the server was out of memory. The fields of the frame's body
/// are counted on the wire first, without allocating.
fn decode_frame(bytes: &[u8]) -> Result<WsFrame, prost::DecodeError> {
    use prost::encoding::{decode_key, decode_varint, skip_field, DecodeContext, WireType};
    let mut top = bytes;
    while !top.is_empty() {
        let (tag, wire) = decode_key(&mut top)?;
        if wire != WireType::LengthDelimited {
            skip_field(wire, tag, &mut top, DecodeContext::default())?;
            continue;
        }
        let len = decode_varint(&mut top)? as usize;
        if len > top.len() {
            break; // truncated: the real decode says so
        }
        let (mut body, rest) = top.split_at(len);
        top = rest;
        // frame_id (a short string) is walked too; garbage there is an
        // error for the real decode to report, not for this count.
        let mut fields = 0usize;
        while !body.is_empty() {
            let Ok((tag, wire)) = decode_key(&mut body) else { break };
            if skip_field(wire, tag, &mut body, DecodeContext::default()).is_err() {
                break;
            }
            fields += 1;
            if fields > MAX_FRAME_FIELDS {
                return Err(prost::DecodeError::new("too many fields in one frame"));
            }
        }
    }
    let frame = WsFrame::decode(bytes)?;
    // WS-49 — the sender's frame_id is passed on to other people (Welcome,
    // call frames): megabytes rode in it past every size check.
    if frame.frame_id.len() > MAX_FRAME_ID_BYTES {
        return Err(prost::DecodeError::new("frame_id too long"));
    }
    Ok(frame)
}

/// WS-01 — a loop, not recursion: ~20 000 empty Ping frames before login
/// overflowed the worker's stack and killed the whole server. A few control
/// frames are harmless; a stream of them instead of Auth closes the socket.
const MAX_CONTROL_FRAMES_BEFORE_AUTH: usize = 16;

async fn next_frame_inline(socket: &mut WebSocket) -> Result<WsFrame, String> {
    for _ in 0..=MAX_CONTROL_FRAMES_BEFORE_AUTH {
        let msg = socket
            .next()
            .await
            .ok_or_else(|| "client disconnected".to_string())?
            .map_err(|e| format!("ws recv error: {e}"))?;
        match msg {
            Message::Binary(bytes) => return decode_auth_frame(bytes.as_ref()),
            Message::Text(_) => return Err("text frame on binary protocol".to_string()),
            Message::Ping(_) | Message::Pong(_) => continue,
            Message::Close(_) => return Err("client closed connection".to_string()),
        }
    }
    Err("too many control frames before Auth".to_string())
}

#[cfg(test)]
mod two_device_call_tests {
    use super::*;
    use crate::call_session::{CallKind, CallSession, CallStatus};

    fn labels(r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>) -> Vec<String> {
        std::iter::from_fn(|| r.try_recv().ok())
            .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                Body::CallAccept(_) => Some("accept".to_string()),
                Body::CallEnd(e) => Some(format!("end:{}", e.reason)),
                Body::Ack(a) => Some(format!("ack:{}", a.error_code)),
                Body::Heartbeat(_) => Some("heartbeat".to_string()),
                _ => None,
            })
            .collect()
    }

    fn ringing(calls: &CallSessionRegistry, caller: Uuid, callee: Uuid) -> String {
        let call_id = Uuid::now_v7();
        calls.start_call(CallSession {
            call_id,
            group_id: b"two-devices".to_vec(),
            caller_user_pk: caller,
            caller_identity: Vec::new(),
            caller_proof: Vec::new(),
            invitees: vec![callee],
            joined: Vec::new(),
            gone: Vec::new(),
            woken: Vec::new(),
            quiet: Vec::new(),
            kind: CallKind::Audio,
            livekit_room: "sinhron-call-test".to_string(),
            status: CallStatus::Ringing,
            created_at_unix: 1_700_000_000,
            last_activity: std::time::Instant::now(),
        });
        call_id.to_string()
    }

    // Owner, 2026-10-26 — answered on one device, the other kept ringing
    // for 45 s and then showed a missed call.
    #[tokio::test]
    async fn answering_on_one_device_stops_the_others() {
        let sessions = crate::session::SessionRegistry::new();
        let calls = CallSessionRegistry::new();
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        let (iphone, ipad) = (vec![0xA1u8; 32], vec![0xA2u8; 32]);
        let (ctx, mut caller) = tokio::sync::mpsc::unbounded_channel();
        let (ptx, mut phone) = tokio::sync::mpsc::unbounded_channel();
        let (ttx, mut tablet) = tokio::sync::mpsc::unbounded_channel();
        let g = (
            sessions.register_device(alice, Some(vec![0xC0u8; 32]), ctx),
            sessions.register_device(bob, Some(iphone.clone()), ptx),
            sessions.register_device(bob, Some(ipad.clone()), ttx),
        );
        assert_eq!(sessions.online_devices(&[bob]).len(), 2);

        let call = ringing(&calls, alice, bob);
        let accept = handle_call_accept(&sessions, &calls, bob, Some(&iphone), "a", CallAccept { call_id: call.clone(), accept: true });
        REPLY_TO.scope(g.1.conn_id(), accept).await.unwrap();
        assert_eq!(labels(&mut caller), vec!["accept"]);
        assert_eq!(labels(&mut tablet), vec!["end:answered_elsewhere"], "the iPad stops ringing (and gets no ack: server-ws:9)");
        assert_eq!(labels(&mut phone), vec!["ack:0"], "the iPhone that answered is not told to stop");
        let call_uuid = Uuid::parse_str(&call).unwrap();
        assert_eq!(calls.answered_elsewhere(bob, &[0xA3u8; 32]), vec![call_uuid], "a third device woken later is told");
        assert!(calls.answered_elsewhere(bob, &iphone).is_empty(), "never the device that answered (it may reconnect)");

        let calls = CallSessionRegistry::new(); // the first call is still on
        let call = ringing(&calls, alice, bob);
        let decline = handle_call_accept(&sessions, &calls, bob, Some(&ipad), "d", CallAccept { call_id: call, accept: false });
        REPLY_TO.scope(g.2.conn_id(), decline).await.unwrap();
        assert_eq!(labels(&mut caller), vec!["end:rejected"]);
        assert_eq!(labels(&mut phone), vec!["end:declined_elsewhere"]);
        assert_eq!(labels(&mut tablet), vec!["ack:0"]);
    }

    // Status 223 — a device connecting while my call rings gets the invite;
    // the one already ringing doesn't get a second copy (it took it as a
    // new call and answered "busy", which ended the call for the caller).
    #[tokio::test]
    async fn a_device_that_connects_gets_the_ringing_invite_alone() {
        let sessions = crate::session::SessionRegistry::new();
        let calls = CallSessionRegistry::new();
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        let (iphone, ipad) = (vec![0xA1u8; 32], vec![0xA2u8; 32]);
        let (ptx, mut phone) = tokio::sync::mpsc::unbounded_channel();
        let (ttx, mut tablet) = tokio::sync::mpsc::unbounded_channel();
        let _g = (
            sessions.register_device(bob, Some(iphone), ptx),
            sessions.register_device(bob, Some(ipad.clone()), ttx),
        );
        let _call = ringing(&calls, alice, bob);
        replay_ringing_invites(&sessions, &calls, bob, Some(&ipad));
        let invites = |r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>| {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter(|b| matches!(WsFrame::decode(b.as_ref()).ok().and_then(|f| f.body), Some(Body::CallInvite(_))))
                .count()
        };
        assert_eq!(invites(&mut tablet), 1, "the iPad that just connected rings");
        assert_eq!(invites(&mut phone), 0, "the iPhone already ringing gets no second copy");
    }

    // server-ws:7 — a reason with a letter across byte 64 panicked the
    // handler; now it is cut before that letter and still forwarded.
    #[tokio::test]
    async fn a_hang_up_reason_cut_inside_a_letter_does_not_panic() {
        let sessions = crate::session::SessionRegistry::new();
        let calls = CallSessionRegistry::new();
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        let (ptx, mut phone) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register_device(bob, Some(vec![0xA1u8; 32]), ptx);
        let call_id = ringing(&calls, alice, bob);
        let reason = format!("{}é", "a".repeat(63));
        handle_call_end(&sessions, &calls, alice, "e", CallEnd { call_id, reason }).await.unwrap();
        assert_eq!(labels(&mut phone), vec![format!("end:{}", "a".repeat(63))]);
    }

    // Audit 2026-11b #23 — "answered_elsewhere" is the server's word; from
    // the other side it is an ordinary hang-up.
    #[tokio::test]
    async fn a_client_cannot_hang_up_with_the_servers_own_reasons() {
        for word in ["answered_elsewhere", "declined_elsewhere"] {
            let sessions = crate::session::SessionRegistry::new();
            let calls = CallSessionRegistry::new();
            let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
            let (ptx, mut phone) = tokio::sync::mpsc::unbounded_channel();
            let _g = sessions.register_device(bob, Some(vec![0xA1u8; 32]), ptx);
            let call_id = ringing(&calls, alice, bob);
            handle_call_end(&sessions, &calls, alice, "e", CallEnd { call_id, reason: word.to_string() }).await.unwrap();
            assert_eq!(labels(&mut phone), vec!["end:hangup"]);
        }
    }

    // server-ws:1 — the first frame is sized before it is decoded: 4 MiB
    // of empty list items became ~260 MiB before anyone logged in.
    #[test]
    fn a_big_first_frame_is_refused_before_decoding() {
        assert!(decode_auth_frame(&vec![0x12u8; 4 * 1024 * 1024]).unwrap_err().contains("first frame over"));
        let auth = WsFrame {
            frame_id: String::new(),
            body: Some(Body::Auth(Auth { identity_pubkey: vec![1u8; 32], signature: vec![2u8; 64] })),
        };
        assert!(matches!(decode_auth_frame(&encode_frame(&auth).unwrap()).unwrap().body, Some(Body::Auth(_))));
    }

    // server-ws:9 — my iPad's heartbeat reply and its acks reached my
    // iPhone too (a background phone took the iPad's 20 s gap for its own).
    #[tokio::test]
    async fn acks_and_heartbeats_go_back_only_to_the_connection_that_sent_them() {
        let sessions = crate::session::SessionRegistry::new();
        let pool = sqlx::postgres::PgPoolOptions::new().connect_lazy("postgres://x@127.0.0.1:1/x").unwrap();
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let calls = CallSessionRegistry::new();
        let me = Uuid::now_v7();
        let (ptx, mut phone) = tokio::sync::mpsc::unbounded_channel();
        let (ttx, mut tablet) = tokio::sync::mpsc::unbounded_channel();
        let _phone = sessions.register_device(me, Some(vec![0xA1u8; 32]), ptx);
        let tab = sessions.register_device(me, Some(vec![0xA2u8; 32]), ttx);
        let heartbeat = WsFrame { frame_id: String::new(), body: Some(Body::Heartbeat(Heartbeat { sequence: 1, next_within_secs: 0 })) };
        let empty = WsFrame { frame_id: "e".into(), body: None };
        for frame in [heartbeat, empty] {
            REPLY_TO.scope(tab.conn_id(), route_frame(&pool, &sessions, &push, &rate, &calls, me, &[0xA2u8; 32], frame)).await.unwrap();
        }
        assert_eq!(labels(&mut tablet), vec!["heartbeat", "ack:400"]);
        assert_eq!(labels(&mut phone), Vec::<String>::new(), "the other device hears nothing");
    }

    // server-ws:4 — invite + hang up in a loop rang a phone without end;
    // past 20 invites the caller gets 429 and nothing more is sent.
    #[tokio::test]
    async fn a_caller_inviting_in_a_loop_is_stopped() {
        let sessions = crate::session::SessionRegistry::new();
        let pool = sqlx::postgres::PgPoolOptions::new().connect_lazy("postgres://x@127.0.0.1:1/x").unwrap();
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let calls = CallSessionRegistry::new();
        let alice = Uuid::now_v7();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register_device(alice, Some(vec![0xC0u8; 32]), tx);
        for _ in 0..25 {
            // A bad call id answers 400 without the database — enough to count.
            let inv = CallInvite { call_id: "x".into(), group_id: vec![1], kind: 1, livekit_room: String::new(), ttl_secs: 30, caller_identity: Vec::new(), access_keys: Vec::new(), sends_access_keys: true, caller_proof: vec![1; crate::push::MIN_CALL_PROOF] };
            let frame = WsFrame { frame_id: "i".into(), body: Some(Body::CallInvite(inv)) };
            route_frame(&pool, &sessions, &push, &rate, &calls, alice, &[0xC0u8; 32], frame).await.unwrap();
        }
        let acks = labels(&mut rx);
        assert_eq!(acks.iter().filter(|a| *a == "ack:400").count(), 20);
        assert_eq!(acks.iter().filter(|a| *a == "ack:429").count(), 5);
    }
}

/// A linked device whose person removed it ("Devices" → Disconnect) — the
/// login tells it so (owner, 2026-11-01). Unknown keys stay "not registered".
async fn linked_device_removed(pool: &PgPool, device_pk: &[u8]) -> bool {
    let removed: Option<(bool,)> = sqlx::query_as("SELECT revoked_at IS NOT NULL FROM devices WHERE device_pk = $1")
        .bind(device_pk)
        .fetch_optional(pool)
        .await
        .unwrap_or(None);
    removed == Some((true,))
}

#[cfg(test)]
mod tests {
    fn test_push() -> std::sync::Arc<dyn crate::push::PushClient> {
        std::sync::Arc::new(crate::push::LoggingPush)
    }

    /// ADR-092 — the head of an MLS PrivateMessage Commit for [group] at
    /// [epoch] (all the server reads), then [tag] as its (garbage) body.
    pub(crate) fn fake_commit(group: &[u8], epoch: u64, tag: u8) -> Vec<u8> {
        let mut b = vec![0, 1, 0, 2, group.len() as u8];
        b.extend_from_slice(group);
        b.extend_from_slice(&epoch.to_be_bytes());
        b.extend_from_slice(&[3, 0, tag]);
        b
    }

    /// ADR-090 — a caller proof of the right size (the server only passes
    /// it on; the phones check it).
    const TEST_PROOF: [u8; crate::push::MIN_CALL_PROOF] = [1; crate::push::MIN_CALL_PROOF];

    use super::*;
    use crate::proto::SealedDelivery;

    #[test]
    fn a_requested_heartbeat_gap_stretches_the_session_watchdog() {
        // No request (every client before 2026-10-18, and the foreground).
        assert_eq!(session_idle_secs(0, 45), 45);
        assert_eq!(granted_heartbeat_gap(0), 0);
        // Asking for less than the default never shortens it.
        assert_eq!(session_idle_secs(20, 45), 45);
        // The Android background gap: 120 s + 60 s slack.
        assert_eq!(granted_heartbeat_gap(120), 120);
        assert_eq!(session_idle_secs(120, 45), 180);
        // Small gaps get at least 25 s of slack.
        assert_eq!(session_idle_secs(40, 45), 65);
        // Capped: a client can't stay "online" for an hour while dead.
        assert_eq!(granted_heartbeat_gap(3600), MAX_HEARTBEAT_GAP_SECS);
        assert_eq!(session_idle_secs(3600, 45), 450);
        // An operator's longer default still wins.
        assert_eq!(session_idle_secs(120, 600), 600);
    }

    #[test]
    fn idle_timeout_env_parsing() {
        assert_eq!(parse_idle_timeout(None), DEFAULT_IDLE_TIMEOUT_SECS);
        assert_eq!(parse_idle_timeout(Some("")), DEFAULT_IDLE_TIMEOUT_SECS);
        assert_eq!(parse_idle_timeout(Some("garbage")), DEFAULT_IDLE_TIMEOUT_SECS);
        assert_eq!(parse_idle_timeout(Some("120")), 120);
        assert_eq!(parse_idle_timeout(Some("3")), 15, "a typo can't drop every client between heartbeats");
    }

    /// WS-47 — a person whose only device in the chat was disconnected is
    /// not a participant of its calls: they were still invited (rung).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_disconnected_device_is_not_rung(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"call-revoked".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..3u8 {
            let u = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[0x50 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)").bind(&[0x60 + i; 32][..]).bind(u).bind(&b"c"[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x60 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(u);
        }
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE user_pk = $1").bind(users[2]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let calls = CallSessionRegistry::new();
        let mut rx = Vec::new();
        let mut guards = Vec::new();
        for u in &users {
            let (tx, r) = tokio::sync::mpsc::unbounded_channel();
            guards.push(sessions.register(*u, tx));
            rx.push(r);
        }
        let invites = |r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>| {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter(|b| matches!(WsFrame::decode(b.as_ref()).ok().and_then(|f| f.body), Some(Body::CallInvite(_))))
                .count()
        };
        let inv = CallInvite { call_id: Uuid::now_v7().to_string(), group_id: group.clone(), kind: 1, livekit_room: String::new(), ttl_secs: 30, caller_identity: vec![9u8; 32], access_keys: Vec::new(), sends_access_keys: false, caller_proof: TEST_PROOF.to_vec() };
        handle_call_invite(&pool, &sessions, &test_push(), &calls, users[0], "i", inv).await.unwrap();
        assert_eq!(invites(&mut rx[1]), 1, "Bob is rung");
        assert_eq!(invites(&mut rx[2]), 0, "the person whose device was disconnected is not");
    }

    /// Tech-debt 4.9 — a group call: everyone else is invited, people
    /// join one by one (those already in hear about it), the caller can
    /// leave without ending it, and it ends when one person is left.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn group_call_signaling(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"team-call".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..3u8 {
            let u = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[0x50 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)").bind(&[0x60 + i; 32][..]).bind(u).bind(&b"c"[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x60 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(u);
        }
        let (alice, bob, carol) = (users[0], users[1], users[2]);
        let sessions = crate::session::SessionRegistry::new();
        let calls = CallSessionRegistry::new();
        let mut rx = Vec::new();
        let mut guards = Vec::new();
        for u in &users {
            let (tx, r) = tokio::sync::mpsc::unbounded_channel();
            guards.push(sessions.register(*u, tx));
            rx.push(r);
        }
        // Drain one inbox into short labels ("invite", "ring", "accept", "end:<reason>", "ack:<code>").
        let drain = |r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>| -> Vec<String> {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                    // Tech-debt 2.27 — the invite names the real caller (a
                    // forged one from the caller is overwritten).
                    Body::CallInvite(i) if i.caller_identity.len() == 32 && i.caller_identity != [9u8; 32] => {
                        Some("invite".to_string())
                    }
                    Body::CallInvite(_) => Some("invite:wrong-caller".to_string()),
                    Body::CallRing(_) => Some("ring".to_string()),
                    Body::CallAccept(_) => Some("accept".to_string()),
                    Body::CallEnd(e) => Some(format!("end:{}", e.reason)),
                    Body::Ack(a) => Some(format!("ack:{}", a.error_code)),
                    _ => None,
                })
                .collect()
        };
        let call_id = Uuid::now_v7().to_string();
        let inv = CallInvite { call_id: call_id.clone(), group_id: group.clone(), kind: 1, livekit_room: String::new(), ttl_secs: 30, caller_identity: vec![9u8; 32], access_keys: Vec::new(), sends_access_keys: false, caller_proof: TEST_PROOF.to_vec() };
        handle_call_invite(&pool, &sessions, &test_push(), &calls, alice, "i", inv).await.unwrap();
        assert_eq!(drain(&mut rx[0]), vec!["ring", "ack:0"]);
        assert_eq!(drain(&mut rx[1]), vec!["invite"]);
        assert_eq!(drain(&mut rx[2]), vec!["invite"]);

        let acc = || CallAccept { call_id: call_id.clone(), accept: true };
        handle_call_accept(&sessions, &calls, bob, None, "a1", acc()).await.unwrap();
        assert_eq!(drain(&mut rx[0]), vec!["accept"], "the caller learns someone joined");
        handle_call_accept(&sessions, &calls, carol, None, "a2", acc()).await.unwrap();
        assert_eq!(drain(&mut rx[0]), vec!["accept"]);
        assert_eq!(drain(&mut rx[1]), vec!["ack:0", "accept"], "an earlier joiner hears about the new one");

        let end = |r: &str| CallEnd { call_id: call_id.clone(), reason: r.to_string() };
        handle_call_end(&sessions, &calls, alice, "e1", end("hangup")).await.unwrap();
        assert_eq!(drain(&mut rx[1]), Vec::<String>::new(), "the caller leaving doesn't end it for the others");
        assert_eq!(drain(&mut rx[2]), vec!["ack:0"]);
        handle_call_end(&sessions, &calls, bob, "e2", end("hangup")).await.unwrap();
        assert_eq!(drain(&mut rx[2]), vec!["end:hangup"], "the last one left is told it's over");
        drop(guards);
    }

    /// server-ws:5 — both ends of a call dropped without a CallEnd: every
    /// later call in the group got 409 "busy" until the server restarted.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_call_everyone_left_silently_does_not_keep_the_group_busy(pool: sqlx::PgPool) {
        use crate::call_session::CallStatus;
        use prost::Message as _;
        let group = b"ghost-call".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(alice, 0x71u8), (bob, 0x72u8)] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[id; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[id; 32][..]).bind(u).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[id; 32][..]).execute(&pool).await.unwrap();
        }
        let calls = CallSessionRegistry::new();
        let ghost = Uuid::now_v7();
        let idle = std::time::Instant::now() - Duration::from_secs(120);
        calls.start_call(CallSession { call_id: ghost, group_id: group.clone(), caller_user_pk: alice, caller_identity: vec![], caller_proof: vec![], invitees: vec![bob], joined: vec![bob], gone: vec![], woken: vec![], quiet: vec![], kind: CallKind::Audio, livekit_room: String::new(), status: CallStatus::Active, created_at_unix: 0, last_activity: idle });
        // LiveKit: no such room (404 to everything).
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, axum::Router::new()).await });
        let _env = crate::handlers::call::tests::ENV_LOCK.lock().unwrap();
        std::env::set_var("LIVEKIT_KEYS", "test-key: test-secret-that-is-at-least-32-chars");
        std::env::set_var("LIVEKIT_API_URL", &url);
        let sessions = crate::session::SessionRegistry::new();
        let (tx_a, mut rx_a) = tokio::sync::mpsc::unbounded_channel();
        let (tx_b, mut rx_b) = tokio::sync::mpsc::unbounded_channel();
        let _guards = (sessions.register(alice, tx_a), sessions.register(bob, tx_b));
        let inv = CallInvite { call_id: Uuid::now_v7().to_string(), group_id: group.clone(), kind: 1, livekit_room: String::new(), ttl_secs: 30, caller_identity: vec![], access_keys: vec![], sends_access_keys: false, caller_proof: TEST_PROOF.to_vec() };
        handle_call_invite(&pool, &sessions, &test_push(), &calls, bob, "i", inv).await.unwrap();
        std::env::remove_var("LIVEKIT_KEYS");
        std::env::remove_var("LIVEKIT_API_URL");
        let labels = |r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>| -> Vec<String> {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                    Body::CallEnd(e) if e.call_id == ghost.to_string() => Some("ghost-ended".to_string()),
                    Body::CallInvite(_) => Some("invite".to_string()),
                    Body::Ack(a) => Some(format!("ack:{}", a.error_code)),
                    _ => None,
                })
                .collect()
        };
        assert_eq!(labels(&mut rx_b), vec!["ghost-ended", "ack:0"], "the new call rings instead of 409");
        assert_eq!(labels(&mut rx_a), vec!["ghost-ended", "invite"]);
    }

    /// Overnight item 9 — calling someone whose app is closed: their phone
    /// gets a PushKit push (call id only), the call keeps ringing instead of
    /// "callee offline", and the invite reaches them when they connect.
    /// Nobody to wake → "callee offline" as before.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_closed_app_is_woken_and_gets_the_invite_on_connect(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"voip-call".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..2u8 {
            let u = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[0x90 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)").bind(&[0xa0 + i; 32][..]).bind(u).bind(&b"c"[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0xa0 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(u);
        }
        let (alice, bob) = (users[0], users[1]);
        let sessions = crate::session::SessionRegistry::new();
        let calls = CallSessionRegistry::new();
        let rec = std::sync::Arc::new(crate::push::tests::RecordingPush::default());
        let push: std::sync::Arc<dyn crate::push::PushClient> = rec.clone();
        let (atx, mut arx) = tokio::sync::mpsc::unbounded_channel();
        let _ga = sessions.register(alice, atx);
        let acks = |r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>| -> Vec<(i32, String)> {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                    Body::Ack(a) => Some((a.error_code, a.error_message)),
                    _ => None,
                })
                .collect()
        };
        let invite = |id: &str| CallInvite { call_id: id.to_string(), group_id: group.clone(), kind: 2, livekit_room: String::new(), ttl_secs: 30, caller_identity: Vec::new(), access_keys: Vec::new(), sends_access_keys: false, caller_proof: TEST_PROOF.to_vec() };

        // calls:5 — an invite its caller didn't sign doesn't go anywhere
        // (the phones would show it with no name and not ring anyway).
        let unsigned = CallInvite { caller_proof: Vec::new(), ..invite(&Uuid::now_v7().to_string()) };
        handle_call_invite(&pool, &sessions, &push, &calls, alice, "i0", unsigned).await.unwrap();
        assert_eq!(acks(&mut arx), vec![(400, "the invite must be signed by its caller".to_string())]);

        // Bob closed the app and has no VoIP token: offline.
        let first = Uuid::now_v7().to_string();
        handle_call_invite(&pool, &sessions, &push, &calls, alice, "i1", invite(&first)).await.unwrap();
        assert_eq!(acks(&mut arx), vec![(503, "callee offline".to_string())]);

        // With a VoIP token: it rings, and his phone is woken.
        // ADR-056 — with the phone's call hint key.
        sqlx::query("INSERT INTO apns_tokens (device_pk, kind, token, sandbox, call_hint_key) VALUES ($1, 'voip', $2, true, $3)")
            .bind(&[0xa1u8; 32][..])
            .bind("cd".repeat(32))
            .bind(&[7u8; 32][..])
            .execute(&pool)
            .await
            .unwrap();
        let second = Uuid::now_v7().to_string();
        handle_call_invite(&pool, &sessions, &push, &calls, alice, "i2", invite(&second)).await.unwrap();
        assert_eq!(acks(&mut arx), vec![(0, "ringing".to_string())]);
        for _ in 0..50 {
            if !rec.0.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        let mut got = rec.0.lock().unwrap().clone();
        // ADR-090 — the caller's signature, sealed to the phone's key.
        let sealed = match &mut got[0].2 {
            crate::push::PushMessage::IncomingCall { proof, .. } => proof.take(),
            _ => None,
        };
        assert_eq!(crate::push::open_call_proof(&[7u8; 32], &sealed.unwrap()), Some(TEST_PROOF.to_vec()));
        assert_eq!(
            got,
            vec![("cd".repeat(32), true, crate::push::PushMessage::IncomingCall {
                call_id: second.clone(),
                video: true,
                hint: crate::push::call_hint(&[7u8; 32], &second, &group),
                caller: Some(hex::encode([0x90u8; 32])),
                proof: None,
            })]
        );

        // Woken, the app connects: the invite is waiting for it.
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let _gb = sessions.register(bob, btx);
        replay_ringing_invites(&sessions, &calls, bob, None);
        let invites: Vec<CallInvite> = std::iter::from_fn(|| brx.try_recv().ok())
            .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                Body::CallInvite(i) => Some(i),
                _ => None,
            })
            .collect();
        assert_eq!(invites.len(), 1);
        assert_eq!(invites[0].call_id, second);
        assert_eq!(invites[0].kind, 2);
        assert!(invites[0].ttl_secs > 0 && invites[0].ttl_secs <= 30);
        // Status 213 — Alice's screen learns it rings now ("Ringing…").
        let rings: Vec<CallRing> = std::iter::from_fn(|| arx.try_recv().ok())
            .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                Body::CallRing(r) => Some(r),
                _ => None,
            })
            .collect();
        assert_eq!(rings.last().map(|r| (r.call_id.clone(), r.delivered)), Some((second.clone(), true)));
        // Once he declines, nothing more is replayed.
        handle_call_accept(&sessions, &calls, bob, None, "d", CallAccept { call_id: second.clone(), accept: false }).await.unwrap();
        assert!(calls.ringing_for(bob).is_empty());
    }

    /// ADR-071 — Bob hands out per-contact keys and blocks Alice: nothing
    /// from her wakes his phone over any route (anonymous with her revoked
    /// key, signed-in WS, plain Submit, a call), while she sees the same
    /// answers as before; a stranger's message arrives without a push.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_blocked_person_cannot_wake_me(pool: sqlx::PgPool) {
        use crate::handlers::{access_keys, sealed_keys};
        use axum::{extract::State, Json};
        use ed25519_dalek::{Signer, SigningKey};
        use prost::Message as _;
        use sha2::{Digest, Sha256};
        let bob_sk = SigningKey::from_bytes(&[0x33u8; 32]);
        let group = b"alice-bob".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let (alice, bob, carol) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let ids = [(alice, [0x31u8; 32].to_vec()), (bob, bob_sk.verifying_key().to_bytes().to_vec()), (carol, [0x35u8; 32].to_vec())];
        for (u, id) in &ids {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(id).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(id).bind(u).execute(&pool).await.unwrap();
        }
        for (_, id) in &ids[..2] {
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(id).execute(&pool).await.unwrap();
        }
        let bob_dev = &ids[1].1;
        for (kind, token) in [("alert", "be".repeat(32)), ("voip", "cd".repeat(32))] {
            sqlx::query("INSERT INTO apns_tokens (device_pk, kind, token, sandbox) VALUES ($1, $2, $3, false)")
                .bind(bob_dev).bind(kind).bind(token).execute(&pool).await.unwrap();
        }
        let bob_pub = [0x78u8; 32];
        let bob_key = sealed_keys::key_id_of(&bob_pub);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(&bob_key).bind(bob).bind(&bob_pub[..]).execute(&pool).await.unwrap();

        let rec = std::sync::Arc::new(crate::push::tests::RecordingPush::default());
        let push: std::sync::Arc<dyn crate::push::PushClient> = rec.clone();
        let state = crate::AppState {
            pool: Some(pool.clone()),
            sessions: crate::session::SessionRegistry::new(),
            push: push.clone(),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: CallSessionRegistry::new(),
        };
        let (sessions, rate, calls) = (&state.sessions, &state.rate, &state.calls);
        // What went out since the last look: "msg" / "req" / "call".
        let pushed = || async {
            for _ in 0..25 {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            std::mem::take(&mut *rec.0.lock().unwrap())
                .into_iter()
                .map(|(_, _, m)| match m {
                    crate::push::PushMessage::NewMessage { .. } => "msg",
                    crate::push::PushMessage::Request { .. } => "req",
                    crate::push::PushMessage::IncomingCall { .. } => "call",
                })
                .collect::<Vec<_>>()
        };
        let stored = || async {
            let (n,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE recipient_user_pk = $1")
                .bind(bob).fetch_one(&pool).await.unwrap();
            n
        };
        // Bob's key for Alice, published and handed to her (inside MLS).
        let alice_key = [0x0au8; 16];
        let hash: [u8; 32] = Sha256::digest(alice_key).into();
        let bob_put = |decisions: Vec<access_keys::Decision>| {
            let ts = OffsetDateTime::now_utc().unix_timestamp();
            let dec: Vec<(Vec<u8>, bool, i64)> =
                decisions.iter().map(|d| (hex::decode(&d.hash_hex).unwrap(), d.revoked, d.at_ms)).collect();
            let mut msg = crate::handlers::proof::PUT_ACCESS_KEYS_DOMAIN.to_vec();
            msg.push(b':');
            msg.extend_from_slice(&Sha256::digest(access_keys::signed_body(0, &[hash.to_vec()], &dec)));
            msg.push(b':');
            msg.extend_from_slice(&ts.to_be_bytes());
            access_keys::PutRequest {
                identity_pubkey_hex: hex::encode(bob_sk.verifying_key().to_bytes()),
                access_version: 0,
                add_hex: vec![hex::encode(hash)],
                decisions,
                proof_ts: ts,
                proof_hex: hex::encode(bob_sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes()),
            }
        };
        let decide = |revoked: bool, at_ms: i64| vec![access_keys::Decision { hash_hex: hex::encode(hash), revoked, at_ms }];
        let _ = access_keys::put(State(state.clone()), Json(bob_put(Vec::new()))).await.unwrap();
        let anon = || sealed_keys::AnonSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![sealed_keys::AnonDelivery {
                key_id_hex: hex::encode(&bob_key),
                envelope_b64: base64::Engine::encode(&base64::prelude::BASE64_STANDARD, b"sealed"),
                access_key_hex: hex::encode(alice_key),
                ttl_secs: 0,
                urgent: true,
                push_preview_b64: None,
                drop_after_secs: 0,
            }],
        };
        let ws_sealed_with = |access_keys: Vec<Vec<u8>>| SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![SealedDelivery { key_id: bob_key.clone(), envelope: b"x".to_vec(), ttl_secs: 0, urgent: true, push_preview: Vec::new(), drop_after_secs: 0 }],
            access_keys,
        };
        let ws_sealed = || ws_sealed_with(Vec::new());
        let plain_with = |access_keys: Vec<Vec<u8>>| Submit {
            group_id: group.clone(),
            ciphertext: b"mls".to_vec(),
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit: false,
            commit_epoch: 0,
            urgent: true,
            access_keys,
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };

        // Unblocked: her anonymous message wakes him.
        let r = sealed_keys::anonymous_submit(State(state.clone()), Json(anon())).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (1, 0));
        assert_eq!(pushed().await, ["msg"]);
        assert_eq!(stored().await, 1);

        // A stranger over the signed-in route: delivered, no badge, and
        // (amended) only a content-free request push — the phone decides.
        handle_sealed_submit(&pool, sessions, &push, rate, carol, "c1", ws_sealed()).await.unwrap();
        assert_eq!(pushed().await, ["req"], "a request push, not a message push");
        assert_eq!(stored().await, 2, "it arrives");
        handle_sealed_submit(&pool, sessions, &push, rate, carol, "c1b", ws_sealed()).await.unwrap();
        assert_eq!(pushed().await, Vec::<&str>::new(), "one request push per sender per 10 minutes");
        let (urgent,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE recipient_user_pk = $1 AND urgent")
            .bind(bob).fetch_one(&pool).await.unwrap();
        assert_eq!(urgent, 1, "only Alice's counts in the badge");

        // Bob blocks Alice.
        let _ = access_keys::put(State(state.clone()), Json(bob_put(decide(true, 1_000)))).await.unwrap();
        let r = sealed_keys::anonymous_submit(State(state.clone()), Json(anon())).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (1, 0), "she sees the same answer");
        assert_eq!(pushed().await, Vec::<&str>::new());
        assert_eq!(stored().await, 3, "and nothing is kept");
        // Her fallbacks: signed-in sealed, plain Submit, with the key she
        // holds (now revoked) — arrive (his app drops them), never push.
        handle_sealed_submit(&pool, sessions, &push, rate, alice, "a1", ws_sealed_with(vec![alice_key.to_vec()])).await.unwrap();
        handle_submit(&pool, sessions, &push, rate, alice, &[], "a2", plain_with(vec![alice_key.to_vec()])).await.unwrap();
        assert_eq!(stored().await, 5, "both arrived");
        assert_eq!(pushed().await, Vec::<&str>::new(), "a blocked contact still can't wake me");
        // A changed app that leaves her key out is a stranger to the server:
        // at most a content-free request push, which his phone drops (she is
        // blocked there).
        handle_submit(&pool, sessions, &push, rate, alice, &[], "a3", plain_with(Vec::new())).await.unwrap();
        assert_eq!(pushed().await, ["req"]);

        // Her call: swallowed — his open app doesn't see it, no push, she
        // hears ringing; nothing waits for him when he connects.
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let gb = sessions.register(bob, btx);
        let (atx, mut arx) = tokio::sync::mpsc::unbounded_channel();
        let _ga = sessions.register(alice, atx);
        let invite = |keys: Vec<Vec<u8>>| CallInvite {
            call_id: Uuid::now_v7().to_string(),
            group_id: group.clone(),
            kind: 1,
            livekit_room: String::new(),
            ttl_secs: 30,
            caller_identity: Vec::new(),
            access_keys: keys,
            sends_access_keys: true,
            caller_proof: TEST_PROOF.to_vec(),
        };
        let frames = |r: &mut tokio::sync::mpsc::UnboundedReceiver<bytes::Bytes>| -> Vec<String> {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                    Body::Ack(a) => Some(format!("ack:{}:{}", a.error_code, a.error_message)),
                    Body::CallInvite(_) => Some("invite".into()),
                    Body::CallRing(r) => Some(if r.delivered { "ring:delivered".into() } else { "ring".into() }),
                    _ => None,
                })
                .collect()
        };
        let blocked_call = invite(vec![alice_key.to_vec()]);
        handle_call_invite(&pool, sessions, &push, calls, alice, "i1", blocked_call.clone()).await.unwrap();
        assert_eq!(frames(&mut arx), vec!["ring", "ack:0:ringing"]);
        assert_eq!(frames(&mut brx), Vec::<String>::new());
        assert!(calls.ringing_for(bob).is_empty());
        drop(gb);
        assert_eq!(pushed().await, Vec::<&str>::new());
        let _ = calls.end(Uuid::parse_str(&blocked_call.call_id).unwrap(), alice);
        // A new app without a key (a stranger): only his open app.
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let gb = sessions.register(bob, btx);
        let keyless = invite(Vec::new());
        handle_call_invite(&pool, sessions, &push, calls, alice, "i2", keyless.clone()).await.unwrap();
        assert_eq!(frames(&mut brx), vec!["invite"]);
        assert_eq!(pushed().await, Vec::<&str>::new());
        // calls:10 — and the caller can't tell: the same as a swallowed call,
        // whether his app is open or not (it said "delivered" / "offline").
        assert_eq!(frames(&mut arx), vec!["ring", "ack:0:ringing"], "his app is open");
        let _ = calls.end(Uuid::parse_str(&keyless.call_id).unwrap(), alice);
        drop(gb);
        let keyless = invite(Vec::new());
        handle_call_invite(&pool, sessions, &push, calls, alice, "i2b", keyless.clone()).await.unwrap();
        assert_eq!(frames(&mut arx), vec!["ring", "ack:0:ringing"], "his app is closed");
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let gb = sessions.register(bob, btx);
        replay_ringing_invites(sessions, calls, bob, None);
        assert_eq!(frames(&mut brx), vec!["invite"]);
        assert_eq!(frames(&mut arx), Vec::<String>::new(), "nor when he connects");
        let _ = calls.end(Uuid::parse_str(&keyless.call_id).unwrap(), alice);
        drop(gb);

        // Unblocked later: her key works again — message and call ring.
        let _ = access_keys::put(State(state.clone()), Json(bob_put(decide(false, 2_000)))).await.unwrap();
        let r = sealed_keys::anonymous_submit(State(state.clone()), Json(anon())).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (1, 0));
        assert_eq!(pushed().await, ["msg"]);
        handle_call_invite(&pool, sessions, &push, calls, alice, "i3", invite(vec![alice_key.to_vec()])).await.unwrap();
        assert_eq!(pushed().await, ["call"], "his phone rings (PushKit)");
    }

    /// ADR-087 (amended) — Bob hands out per-contact keys and hasn't blocked
    /// Alice: her message wakes his phone with an ordinary push whichever
    /// route it takes — anonymous with his key, the signed-in sealed route
    /// (the anonymous one failed), or plain Submit (his delivery key is
    /// stale: his phone slept for weeks). Removing the transition switch
    /// (status 240) had left the last two without a push.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_message_from_a_contact_i_have_not_blocked_always_wakes_my_phone(pool: sqlx::PgPool) {
        use crate::handlers::sealed_keys;
        use sha2::{Digest, Sha256};
        let group = b"alice-bob-2".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(alice, [0x61u8; 32]), (bob, [0x62u8; 32])] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey, access_per_contact) VALUES ($1, $2, TRUE)").bind(u).bind(&id[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id[..]).bind(u).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&id[..]).execute(&pool).await.unwrap();
        }
        sqlx::query("INSERT INTO apns_tokens (device_pk, kind, token, sandbox) VALUES ($1, 'alert', $2, false)")
            .bind(&[0x62u8; 32][..]).bind("bf".repeat(32)).execute(&pool).await.unwrap();
        let bob_pub = [0x79u8; 32];
        let bob_key = sealed_keys::key_id_of(&bob_pub);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(&bob_key).bind(bob).bind(&bob_pub[..]).execute(&pool).await.unwrap();
        // The key Bob gave Alice (published by his app, handed to her in MLS).
        let alice_key = [0x0bu8; 16];
        sqlx::query("INSERT INTO access_keys (user_pk, key_hash, revoked) VALUES ($1, $2, FALSE)")
            .bind(bob).bind(Sha256::digest(alice_key).to_vec()).execute(&pool).await.unwrap();

        let rec = std::sync::Arc::new(crate::push::tests::RecordingPush::default());
        let push: std::sync::Arc<dyn crate::push::PushClient> = rec.clone();
        let state = crate::AppState {
            pool: Some(pool.clone()),
            sessions: crate::session::SessionRegistry::new(),
            push: push.clone(),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: CallSessionRegistry::new(),
        };
        let pushed = || async {
            for _ in 0..25 {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
            std::mem::take(&mut *rec.0.lock().unwrap())
                .into_iter()
                .map(|(_, _, m)| match m {
                    crate::push::PushMessage::NewMessage { .. } => "msg",
                    crate::push::PushMessage::Request { .. } => "req",
                    crate::push::PushMessage::IncomingCall { .. } => "call",
                })
                .collect::<Vec<_>>()
        };
        let mine = vec![alice_key.to_vec(), vec![0x0cu8; 16]]; // and someone else's key for another member
        for i in 0..3 {
            // (a) anonymous, with his key
            let anon = sealed_keys::AnonSubmit {
                message_id: Uuid::now_v7().to_string(),
                deliveries: vec![sealed_keys::AnonDelivery {
                    key_id_hex: hex::encode(&bob_key),
                    envelope_b64: base64::Engine::encode(&base64::prelude::BASE64_STANDARD, b"sealed"),
                    access_key_hex: hex::encode(alice_key),
                    ttl_secs: 0,
                    urgent: true,
                    push_preview_b64: None,
                    drop_after_secs: 0,
                }],
            };
            let r = sealed_keys::anonymous_submit(axum::extract::State(state.clone()), axum::Json(anon)).await.unwrap();
            assert_eq!((r.0.accepted, r.0.refused), (1, 0));
            assert_eq!(pushed().await, ["msg"], "anonymous route, message {i}");
            // (b) signed-in sealed
            let sealed = SealedSubmit {
                message_id: Uuid::now_v7().to_string(),
                deliveries: vec![SealedDelivery { key_id: bob_key.clone(), envelope: b"x".to_vec(), ttl_secs: 0, urgent: true, push_preview: vec![7u8; 64], drop_after_secs: 0 }],
                access_keys: mine.clone(),
            };
            handle_sealed_submit(&pool, &state.sessions, &push, &state.rate, alice, "s", sealed).await.unwrap();
            assert_eq!(pushed().await, ["msg"], "signed-in sealed route, message {i}");
            // (c) plain Submit in their chat
            let plain = Submit {
                group_id: group.clone(),
                ciphertext: b"mls".to_vec(),
                message_id: Uuid::now_v7().to_string(),
                sealed_sender: false,
                is_commit: false,
                commit_epoch: 0,
                urgent: true,
                access_keys: mine.clone(),
                refused_commit_ids: Vec::new(),
                parent_commit_id: String::new(),
            };
            handle_submit(&pool, &state.sessions, &push, &state.rate, alice, &[], "p", plain).await.unwrap();
            assert_eq!(pushed().await, ["msg"], "plain Submit route, message {i}");
        }
        let (badge,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE recipient_user_pk = $1 AND urgent")
            .bind(bob).fetch_one(&pool).await.unwrap();
        assert_eq!(badge, 9, "every one counts in his badge");
    }

    /// Overnight item 8 — an urgent sealed message to someone with no open
    /// connection wakes their phone once; a receipt (not urgent) doesn't;
    /// someone online gets it over the connection, no push.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn only_urgent_messages_to_offline_people_push(pool: sqlx::PgPool) {
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(alice, [0x51u8; 32]), (bob, [0x52u8; 32])] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&id[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id[..]).bind(u).execute(&pool).await.unwrap();
        }
        sqlx::query("INSERT INTO apns_tokens (device_pk, kind, token, sandbox) VALUES ($1, 'alert', $2, false)")
            .bind(&[0x52u8; 32][..])
            .bind("be".repeat(32))
            .execute(&pool)
            .await
            .unwrap();
        let bob_pk = [0x78u8; 32];
        let bob_key = crate::handlers::sealed_keys::key_id_of(&bob_pk);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(&bob_key).bind(bob).bind(&bob_pk[..]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let rec = std::sync::Arc::new(crate::push::tests::RecordingPush::default());
        let push: std::sync::Arc<dyn crate::push::PushClient> = rec.clone();
        let send = |urgent: bool| SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            // ADR-056 — the sender's sealed preview rides along to the push.
            deliveries: vec![SealedDelivery { key_id: bob_key.clone(), envelope: b"x".to_vec(), ttl_secs: 0, urgent, push_preview: vec![9u8; 689], drop_after_secs: 0 }],
            access_keys: Vec::new(),
        };
        let pushed = || rec.0.lock().unwrap().len();
        let settle = || async {
            for _ in 0..50 {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        };
        handle_sealed_submit(&pool, &sessions, &push, &rate, alice, "r", send(false)).await.unwrap();
        settle().await;
        assert_eq!(pushed(), 0, "a receipt doesn't wake anyone");
        handle_sealed_submit(&pool, &sessions, &push, &rate, alice, "m", send(true)).await.unwrap();
        settle().await;
        assert_eq!(pushed(), 1, "a message to an offline phone does");
        assert_eq!(rec.0.lock().unwrap()[0].2, crate::push::PushMessage::NewMessage { unread: 1, preview: Some(vec![9u8; 689]) });
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(bob, tx);
        handle_sealed_submit(&pool, &sessions, &push, &rate, alice, "m2", send(true)).await.unwrap();
        settle().await;
        assert_eq!(pushed(), 1, "online: delivered over the connection, no push");
    }

    /// ADR-023 — a sealed envelope reaches the key's owner with no group
    /// id; the server keeps no `messages` row; an unknown key is counted
    /// and skipped; a retry isn't delivered twice; Resume replays it.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn sealed_envelopes_route_by_key_without_the_group(pool: sqlx::PgPool) {
        use prost::Message as _;
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(alice, [0x41u8; 32]), (bob, [0x42u8; 32])] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(u).bind(&id[..]).execute(&pool).await.unwrap();
        }
        let bob_pk = [0x77u8; 32];
        let bob_key = crate::handlers::sealed_keys::key_id_of(&bob_pk);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(&bob_key).bind(bob).bind(&bob_pk[..]).execute(&pool).await.unwrap();

        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let (atx, mut arx) = tokio::sync::mpsc::unbounded_channel();
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let _ga = sessions.register(alice, atx);
        let _gb = sessions.register(bob, btx);
        let msg_id = Uuid::now_v7().to_string();
        let submit = || SealedSubmit {
            message_id: msg_id.clone(),
            deliveries: vec![
                SealedDelivery { key_id: bob_key.clone(), envelope: b"opaque-envelope".to_vec(), ttl_secs: 0, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 },
                SealedDelivery { key_id: vec![0u8; 16], envelope: b"nobody".to_vec(), ttl_secs: 0, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 },
            ],
            access_keys: Vec::new(),
        };
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s1", submit()).await.unwrap();
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s2", submit()).await.unwrap(); // retry

        let decode = |b: Vec<u8>| WsFrame::decode(b.as_slice()).unwrap().body;
        let acks: Vec<String> = std::iter::from_fn(|| arx.try_recv().ok())
            .filter_map(|b| match decode(b.to_vec()) { Some(Body::Ack(a)) => Some(a.error_message), _ => None })
            .collect();
        assert_eq!(acks, vec!["sealed: 1 delivered, 1 unknown keys", "sealed: 0 delivered, 1 unknown keys"]);
        let pushes: Vec<Push> = std::iter::from_fn(|| brx.try_recv().ok())
            .filter_map(|b| match decode(b.to_vec()) { Some(Body::Push(p)) => Some(p), _ => None })
            .collect();
        assert_eq!(pushes.len(), 1, "delivered once despite the retry");
        assert!(pushes[0].group_id.is_empty(), "no group id leaves the server");
        assert_eq!(pushes[0].sealed_key_id, bob_key);
        assert_eq!(pushes[0].ciphertext, b"opaque-envelope");
        let (stored,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages").fetch_one(&pool).await.unwrap();
        assert_eq!(stored, 0, "nothing stored per group");

        // Status 211 — nothing reached anyone: the ack says so (no false ✓).
        let lost = SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![SealedDelivery { key_id: vec![1u8; 16], envelope: b"nobody".to_vec(), ttl_secs: 0, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 }],
            access_keys: Vec::new(),
        };
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s0", lost).await.unwrap();
        let codes: Vec<i32> = std::iter::from_fn(|| arx.try_recv().ok())
            .filter_map(|b| match decode(b.to_vec()) { Some(Body::Ack(a)) => Some(a.error_code), _ => None })
            .collect();
        assert_eq!(codes, vec![404]);

        // Bob reconnects from scratch: Resume replays the envelope.
        handle_resume(&pool, &sessions, bob, "r", Resume { cursors: vec![] }).await.unwrap();
        let replay: Vec<Push> = std::iter::from_fn(|| brx.try_recv().ok())
            .filter_map(|b| match decode(b.to_vec()) { Some(Body::Push(p)) => Some(p), _ => None })
            .collect();
        assert_eq!(replay.len(), 1);
        assert_eq!(replay[0].ciphertext, b"opaque-envelope");
        assert_eq!(replay[0].sealed_key_id, bob_key);

        // Tech-debt 2.5 — a sealed message from a chat with a timer: once
        // it runs out, Resume no longer replays it and the sweep drops it.
        let timed = SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![SealedDelivery { key_id: bob_key.clone(), envelope: b"short-lived".to_vec(), ttl_secs: 60, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 }],
            access_keys: Vec::new(),
        };
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s3", timed).await.unwrap();
        let (with_expiry,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE expires_at IS NOT NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(with_expiry, 1);
        sqlx::query("UPDATE message_deliveries SET expires_at = NOW() - interval '1 second' WHERE expires_at IS NOT NULL")
            .execute(&pool)
            .await
            .unwrap();
        while brx.try_recv().is_ok() {}
        handle_resume(&pool, &sessions, bob, "r2", Resume { cursors: vec![] }).await.unwrap();
        let replay: Vec<Push> = std::iter::from_fn(|| brx.try_recv().ok())
            .filter_map(|b| match decode(b.to_vec()) { Some(Body::Push(p)) => Some(p), _ => None })
            .collect();
        assert_eq!(replay.len(), 1, "only the untimed one");
        crate::retention::sweep(&pool, 30).await.unwrap();
        let (left,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries").fetch_one(&pool).await.unwrap();
        assert_eq!(left, 1, "the expired delivery is gone");
        // Bob offline: the timer doesn't start until it reaches him. (The
        // sweep above dropped his week-1 test key — put it back.)
        drop(_gb);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1) ON CONFLICT DO NOTHING")
            .bind(&bob_key).bind(bob).bind(&bob_pk[..]).execute(&pool).await.unwrap();
        let later = SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![SealedDelivery { key_id: bob_key.clone(), envelope: b"while away".to_vec(), ttl_secs: 60, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 }],
            access_keys: Vec::new(),
        };
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s4", later).await.unwrap();

        let (exp,): (Option<OffsetDateTime>,) =
            sqlx::query_as("SELECT expires_at FROM message_deliveries WHERE envelope = $1").bind(&b"while away"[..]).fetch_one(&pool).await.unwrap();
        assert!(exp.is_none(), "not received yet → no countdown");
        let (btx2, _brx2) = tokio::sync::mpsc::unbounded_channel();
        let _gb2 = sessions.register(bob, btx2);
        handle_resume(&pool, &sessions, bob, "r3", Resume { cursors: vec![] }).await.unwrap();
        let (exp, got): (Option<OffsetDateTime>, Option<OffsetDateTime>) = sqlx::query_as(
            "SELECT expires_at, received_at FROM message_deliveries WHERE envelope = $1",
        )
        .bind(&b"while away"[..])
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(got.is_some() && exp.is_some(), "received on Resume → countdown starts");
    }

    /// Bug 2026-10-16 — a message that came while Bob had no connection
    /// reaches him when he logs in, without any Resume from the app (a
    /// fresh connection never sends one); once, not again on the next login.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn what_came_while_offline_arrives_on_login(pool: sqlx::PgPool) {
        use prost::Message as _;
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(alice, [0x51u8; 32]), (bob, [0x52u8; 32])] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(u).bind(&id[..]).execute(&pool).await.unwrap();
        }
        let bob_pk = [0x78u8; 32];
        let bob_key = crate::handlers::sealed_keys::key_id_of(&bob_pk);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(&bob_key).bind(bob).bind(&bob_pk[..]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let (atx, _arx) = tokio::sync::mpsc::unbounded_channel();
        let _ga = sessions.register(alice, atx);
        // Bob is away: two messages wait.
        for text in [&b"first while away"[..], &b"second while away"[..]] {
            let submit = SealedSubmit {
                message_id: Uuid::now_v7().to_string(),
                deliveries: vec![SealedDelivery { key_id: bob_key.clone(), envelope: text.to_vec(), ttl_secs: 0, urgent: true, push_preview: Vec::new(), drop_after_secs: 0 }],
                access_keys: Vec::new(),
            };
            handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s", submit).await.unwrap();
        }
        let waiting = || {
            let pool = pool.clone();
            async move {
                let (n,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE received_at IS NULL")
                    .fetch_one(&pool)
                    .await
                    .unwrap();
                n
            }
        };
        assert_eq!(waiting().await, 2);
        // Bob logs in: both arrive, oldest first, with no Resume.
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let _gb = sessions.register(bob, btx);
        assert_eq!(deliver_backlog(&pool, &sessions, bob).await.unwrap(), 2);
        let got: Vec<Vec<u8>> = std::iter::from_fn(|| brx.try_recv().ok())
            .filter_map(|b| match WsFrame::decode(b.as_ref()).unwrap().body {
                Some(Body::Push(p)) => Some(p.ciphertext),
                _ => None,
            })
            .collect();
        assert_eq!(got, vec![b"first while away".to_vec(), b"second while away".to_vec()]);
        assert_eq!(waiting().await, 0, "marked received");
        // The next login doesn't send them again.
        assert_eq!(deliver_backlog(&pool, &sessions, bob).await.unwrap(), 0);
        assert!(brx.try_recv().is_err());
    }

    /// Tech-debt 2.53 — "online" heartbeats to a contact who is away: each
    /// expires `drop_after_secs` after it is stored, so Bob doesn't get an
    /// hour of them on login; a real message still waits. With a chat
    /// timer too, whichever runs out first wins.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn heartbeats_to_an_offline_contact_are_dropped(pool: sqlx::PgPool) {
        use prost::Message as _;
        let (alice, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(alice, [0x61u8; 32]), (bob, [0x62u8; 32])] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(u).bind(&id[..]).execute(&pool).await.unwrap();
        }
        let bob_pk = [0x79u8; 32];
        let bob_key = crate::handlers::sealed_keys::key_id_of(&bob_pk);
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(&bob_key).bind(bob).bind(&bob_pk[..]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let send = |text: &'static [u8], ttl_secs: u32, drop_after_secs: u32| SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![SealedDelivery {
                key_id: bob_key.clone(),
                envelope: text.to_vec(),
                ttl_secs,
                urgent: false,
                push_preview: Vec::new(),
                drop_after_secs,
            }],
            access_keys: Vec::new(),
        };
        let expiry_in = |text: &'static [u8]| {
            let pool = pool.clone();
            async move {
                let (secs,): (Option<f64>,) = sqlx::query_as(
                    "SELECT EXTRACT(EPOCH FROM expires_at - NOW())::double precision FROM message_deliveries WHERE envelope = $1",
                )
                .bind(text)
                .fetch_one(&pool)
                .await
                .unwrap();
                secs
            }
        };
        // Bob is away.
        for (text, ttl, drop) in [(&b"online 1"[..], 0, 120), (&b"online 2"[..], 0, 120), (&b"hello"[..], 0, 0), (&b"timed"[..], 60, 120)] {
            handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s", send(text, ttl, drop)).await.unwrap();
        }
        let e = expiry_in(b"online 1").await.expect("expiry set at write time, not at receipt");
        assert!((110.0..=120.0).contains(&e), "{e}");
        assert_eq!(expiry_in(b"hello").await, None, "a real message waits");
        // A huge value is capped like a chat timer.
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s", send(b"capped", 0, u32::MAX)).await.unwrap();
        let e = expiry_in(b"capped").await.unwrap();
        assert!(e <= crate::handlers::groups::MAX_RETENTION_SECS as f64, "{e}");
        sqlx::query("DELETE FROM message_deliveries WHERE envelope = $1").bind(&b"capped"[..]).execute(&pool).await.unwrap();

        // Two minutes pass for the heartbeats only.
        sqlx::query("UPDATE message_deliveries SET expires_at = NOW() - interval '1 second' WHERE envelope IN ($1, $2)")
            .bind(&b"online 1"[..]).bind(&b"online 2"[..]).execute(&pool).await.unwrap();
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let _gb = sessions.register(bob, btx);
        assert_eq!(deliver_backlog(&pool, &sessions, bob).await.unwrap(), 2);
        let got: Vec<Vec<u8>> = std::iter::from_fn(|| brx.try_recv().ok())
            .filter_map(|b| match WsFrame::decode(b.as_ref()).unwrap().body {
                Some(Body::Push(p)) => Some(p.ciphertext),
                _ => None,
            })
            .collect();
        assert_eq!(got, vec![b"hello".to_vec(), b"timed".to_vec()], "no stale heartbeats");
        // The chat's 60 s timer from receipt beats the 120 s from writing.
        let e = expiry_in(b"timed").await.unwrap();
        assert!((50.0..=60.0).contains(&e), "{e}");
        crate::retention::sweep(&pool, 30).await.unwrap();
        let (left,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE envelope IN ($1, $2)")
            .bind(&b"online 1"[..]).bind(&b"online 2"[..]).fetch_one(&pool).await.unwrap();
        assert_eq!(left, 0, "the sweep removes them");

        // Bob online: the heartbeat is pushed live; its row still goes after
        // 120 s (a chat timer, if longer, doesn't stretch it).
        while brx.try_recv().is_ok() {}
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1) ON CONFLICT DO NOTHING")
            .bind(&bob_key).bind(bob).bind(&bob_pk[..]).execute(&pool).await.unwrap();
        handle_sealed_submit(&pool, &sessions, &test_push(), &rate, alice, "s", send(b"online 3", 3600, 120)).await.unwrap();
        assert!(brx.try_recv().is_ok(), "pushed live");
        let e = expiry_in(b"online 3").await.unwrap();
        assert!((110.0..=120.0).contains(&e), "{e}");
    }

    /// ADR-025 — a person with two devices in a group: their own message
    /// is delivered back to them (for the other device); with one device
    /// it is not. A Welcome to oneself is allowed and stays queued.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn second_device_gets_own_messages_and_welcomes(pool: sqlx::PgPool) {
        let group = b"two-devices".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let alice = Uuid::now_v7();
        let bob = Uuid::now_v7();
        for (u, id) in [(alice, 0x41u8), (bob, 0x42u8)] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(u).bind(&[id; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)")
                .bind(&[id; 32][..]).bind(u).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
                .bind(&group).bind(&[id; 32][..]).execute(&pool).await.unwrap();
        }
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(alice, tx);
        let msg = || Submit {
            group_id: group.clone(),
            ciphertext: b"hi".to_vec(),
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        let own_rows = || async {
            let (n,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries WHERE recipient_user_pk = $1")
                .bind(alice).fetch_one(&pool).await.unwrap();
            n
        };
        handle_submit(&pool, &sessions, &test_push(), &rate, alice, &[], "1", msg()).await.unwrap();
        assert_eq!(own_rows().await, 0, "one device: no echo");

        // Alice's laptop joins the group.
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential, certificate) VALUES ($1, $2, $1, $3)")
            .bind(&[0x4Au8; 32][..]).bind(alice).bind(&[0u8; 132][..]).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
            .bind(&group).bind(&[0x4Au8; 32][..]).execute(&pool).await.unwrap();
        handle_submit(&pool, &sessions, &test_push(), &rate, alice, &[], "2", msg()).await.unwrap();
        assert_eq!(own_rows().await, 1, "two devices: delivered to Alice's other device too");
        // critic:11 — the server stored the oldest device as the sender.
        let (named,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages WHERE sender_device_pk IS NOT NULL").fetch_one(&pool).await.unwrap();
        assert_eq!(named, 0, "no sender device kept for a message");

        // The phone welcomes the laptop without naming it: accepted, and
        // the server queues one copy for each of Alice's devices (WS-08).
        let w = Welcome { recipient_identity_pubkey: vec![0x41; 32], group_id: group.clone(), welcome_bytes: b"w".to_vec(), sent_at: 0, recipient_device_pks: vec![] };
        handle_welcome(&pool, &sessions, alice, "w", w).await.unwrap();
        flush_pending_welcomes(&pool, &sessions, alice, None).await.unwrap();
        let (queued,): (i64,) = sqlx::query_as("SELECT count(*) FROM pending_welcomes").fetch_one(&pool).await.unwrap();
        assert_eq!(queued, 2);

        // Addressed to the laptop (offline): queued for it alone; the
        // phone's next login doesn't get it; the laptop's does, and then
        // it's gone (no 7-day copy).
        sqlx::query("DELETE FROM pending_welcomes").execute(&pool).await.unwrap();
        let laptop = vec![0x4Au8; 32];
        let w = Welcome {
            recipient_identity_pubkey: vec![0x41; 32],
            group_id: group.clone(),
            welcome_bytes: b"for the laptop".to_vec(),
            sent_at: 0,
            recipient_device_pks: vec![laptop.clone()],
        };
        handle_welcome(&pool, &sessions, alice, "w2", w).await.unwrap();
        let count = || async {
            let (n,): (i64,) = sqlx::query_as("SELECT count(*) FROM pending_welcomes WHERE recipient_device_pk IS NOT NULL")
                .fetch_one(&pool)
                .await
                .unwrap();
            n
        };
        assert_eq!(count().await, 1);
        let (ptx, mut prx) = tokio::sync::mpsc::unbounded_channel();
        let _phone = sessions.register_device(alice, Some(vec![0x41u8; 32]), ptx);
        flush_pending_welcomes(&pool, &sessions, alice, Some(&[0x41u8; 32])).await.unwrap();
        assert!(prx.try_recv().is_err(), "not for the phone");
        assert_eq!(count().await, 1);
        let (ltx, mut lrx) = tokio::sync::mpsc::unbounded_channel();
        let _laptop = sessions.register_device(alice, Some(laptop.clone()), ltx);
        flush_pending_welcomes(&pool, &sessions, alice, Some(&laptop)).await.unwrap();
        assert!(lrx.try_recv().is_ok(), "the laptop gets it");
        assert_eq!(count().await, 0, "and then it's gone");
    }

    // server-ws:6 — Welcomes filled the disk: 4 MiB each, one device named
    // 64 times = 64 copies, no limit per person. Now 1 MiB each, one copy
    // per device, and an offline person keeps the newest 8 MiB (WS-08).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn welcomes_cannot_fill_the_disk(pool: sqlx::PgPool) {
        let (mallory, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(mallory, 0x61u8), (bob, 0x62u8)] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[id; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[id; 32][..]).bind(u).execute(&pool).await.unwrap();
        }
        let sessions = crate::session::SessionRegistry::new();
        let w = |bytes: Vec<u8>, devices: Vec<Vec<u8>>| Welcome { recipient_identity_pubkey: vec![0x62; 32], group_id: b"g".to_vec(), welcome_bytes: bytes, sent_at: 0, recipient_device_pks: devices };
        let rows = || async {
            let (n, total): (i64, Option<i64>) = sqlx::query_as("SELECT count(*), SUM(octet_length(welcome_bytes))::bigint FROM pending_welcomes")
                .fetch_one(&pool)
                .await
                .unwrap();
            (n, total.unwrap_or(0))
        };
        handle_welcome(&pool, &sessions, mallory, "big", w(vec![1; MAX_WELCOME_BYTES + 1], vec![])).await.unwrap();
        assert_eq!(rows().await.0, 0, "over 1 MiB: refused");
        handle_welcome(&pool, &sessions, mallory, "x64", w(vec![1; 1000], vec![vec![0x62; 32]; 64])).await.unwrap();
        assert_eq!(rows().await.0, 1, "one copy for the one device");
        for i in 0..66u8 {
            handle_welcome(&pool, &sessions, mallory, "fill", w(vec![i; MAX_WELCOME_BYTES], vec![])).await.unwrap();
        }
        let (n, total) = rows().await;
        assert!(total as usize <= MAX_PENDING_WELCOME_BYTES && n == 7, "{n} rows, {total} bytes");
        let (newest,): (Vec<u8>,) = sqlx::query_as("SELECT welcome_bytes FROM pending_welcomes ORDER BY id DESC LIMIT 1").fetch_one(&pool).await.unwrap();
        assert_eq!(newest[0], 65, "the newest is kept");
    }

    /// Tech-debt 2.3 / ADR-022 — two members race a Commit in the same
    /// epoch: exactly one is stored and acknowledged (0), the other gets
    /// 409 and leaves no trace; the next epoch's Commit is accepted.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn concurrent_commits_one_wins_the_other_gets_409(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"commit-race".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..2u8 {
            let user_pk = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(user_pk).bind(&[0x30 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
                .bind(&[0xE0 + i; 32][..]).bind(user_pk).bind(&b"cred"[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
                .bind(&group).bind(&[0xE0 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(user_pk);
        }
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let mut inboxes = Vec::new();
        let mut guards = Vec::new();
        for u in &users {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            guards.push(sessions.register(*u, tx));
            inboxes.push(rx);
        }
        let commit = |epoch: u64, tag: u8| Submit {
            group_id: group.clone(),
            ciphertext: fake_commit(&group, epoch, tag),
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit: true,
            commit_epoch: epoch,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        let push = test_push();
        let (a, b) = tokio::join!(
            handle_submit(&pool, &sessions, &push, &rate, users[0], &[], "a", commit(0, 1)),
            handle_submit(&pool, &sessions, &push, &rate, users[1], &[], "b", commit(0, 2)),
        );
        a.unwrap();
        b.unwrap();

        // Each sender's Ack code (Push frames to the other are skipped).
        let mut codes = Vec::new();
        for rx in inboxes.iter_mut() {
            while let Ok(bytes) = rx.try_recv() {
                if let Ok(WsFrame { body: Some(Body::Ack(ack)), .. }) = WsFrame::decode(bytes.as_ref()) {
                    codes.push(ack.error_code);
                }
            }
        }
        codes.sort();
        assert_eq!(codes, vec![0, 409], "one winner, one 409");
        let (stored,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages").fetch_one(&pool).await.unwrap();
        assert_eq!(stored, 1, "the losing Commit is not stored");
        let (epoch,): (i64,) = sqlx::query_as("SELECT current_epoch FROM mls_groups WHERE group_id = $1")
            .bind(&group).fetch_one(&pool).await.unwrap();
        assert_eq!(epoch, 1);

        // The loser retries in the next epoch → accepted.
        handle_submit(&pool, &sessions, &test_push(), &rate, users[1], &[], "b2", commit(1, 3)).await.unwrap();
        let (epoch,): (i64,) = sqlx::query_as("SELECT current_epoch FROM mls_groups WHERE group_id = $1")
            .bind(&group).fetch_one(&pool).await.unwrap();
        assert_eq!(epoch, 2);

        // A Commit for a far-future epoch freezes nothing (security review
        // 2026-11-02: `<=` let epoch 2^60 lock the group; ADR-092: nobody
        // takes it, and an honest Commit for epoch 2 still goes through).
        handle_submit(&pool, &sessions, &test_push(), &rate, users[0], &[], "evil", commit(1 << 60, 4)).await.unwrap();
        handle_submit(&pool, &sessions, &test_push(), &rate, users[1], &[], "b3", commit(2, 6)).await.unwrap();
        let (epoch,): (i64,) = sqlx::query_as("SELECT current_epoch FROM mls_groups WHERE group_id = $1")
            .bind(&group).fetch_one(&pool).await.unwrap();
        assert_eq!(epoch, 3, "the honest Commit still goes through");
        drop(guards);
    }

    /// server-ws:2 — a chat the server hadn't ordered yet (epoch 0) caught up
    /// on its first Commit to anything ≤ 100: a member sent epoch 100, the
    /// chat jumped to 101 and every honest Commit got 409 for good. And
    /// epoch 2^63 wrapped to a negative number. Now (ADR-092) a jump only
    /// goes out to phones that won't take it, the honest Commit for the
    /// chat's epoch still goes through, and the winner's device is kept.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_member_can_not_jump_a_new_chat_to_epoch_101_and_freeze_it(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"fresh-chat".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..2u8 {
            let user_pk = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user_pk).bind(&[0x50 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[0x50 + i; 32][..]).bind(user_pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x50 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(user_pk);
        }
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let (tx, mut mallory_rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(users[0], tx);
        let commit = |epoch: u64| Submit {
            group_id: group.clone(),
            ciphertext: fake_commit(&group, epoch, 1),
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit: true,
            commit_epoch: epoch,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        let epoch = || async {
            sqlx::query_as::<_, (i64,)>("SELECT current_epoch FROM mls_groups WHERE group_id = $1")
                .bind(&group)
                .fetch_one(&pool)
                .await
                .unwrap()
        };
        let mallory_dev = [0x50u8; 32];
        handle_submit(&pool, &sessions, &test_push(), &rate, users[0], &mallory_dev, "jump", commit(100)).await.unwrap();
        handle_submit(&pool, &sessions, &test_push(), &rate, users[0], &mallory_dev, "wrap", commit(1 << 63)).await.unwrap();
        let mut codes = Vec::new();
        while let Ok(bytes) = mallory_rx.try_recv() {
            if let Ok(WsFrame { body: Some(Body::Ack(a)), .. }) = WsFrame::decode(bytes.as_ref()) {
                codes.push(a.error_code);
            }
        }
        assert_eq!(codes, vec![0, 400], "a jump is fanned out (nobody takes it); 2^63 is no epoch");
        assert_eq!(epoch().await, (101,));
        let bob_dev = [0x51u8; 32];
        handle_submit(&pool, &sessions, &test_push(), &rate, users[1], &bob_dev, "honest", commit(0)).await.unwrap();
        assert_eq!(epoch().await, (1,), "the honest Commit goes through");
    }

    /// ADR-092 (server-ws:2 variant B) — Mallory, a member with a modified
    /// app, sends a garbage Commit at the chat's epoch. The server took it as
    /// the epoch's Commit; Alice's and Bob's phones refuse it, so they stay
    /// at the epoch, and every Commit of theirs got 409 — frozen for good.
    /// Now a Commit from a device that saw the garbage one and didn't take
    /// it goes through (and makes its device the epoch's author, card
    /// included); one that hasn't seen it still waits, so two good Commits
    /// for one epoch never both go out; Mallory gets one Commit per epoch.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_members_garbage_commit_does_not_freeze_the_chat(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"garbage-commit".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id, current_epoch) VALUES ($1, 5)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..3u8 {
            let user_pk = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user_pk).bind(&[0x70 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[0x70 + i; 32][..]).bind(user_pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x70 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(user_pk);
        }
        let (alice, bob, mallory) = (users[0], users[1], users[2]);
        let (alice_dev, bob_dev, mallory_dev) = ([0x70u8; 32], [0x71u8; 32], [0x72u8; 32]);
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let mut inboxes = Vec::new();
        let mut guards = Vec::new();
        for u in &users {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            guards.push(sessions.register(*u, tx));
            inboxes.push(rx);
        }
        let commit = |epoch: u64, id: Uuid, parent: Option<Uuid>, refused: &[Uuid]| Submit {
            group_id: group.clone(),
            ciphertext: fake_commit(&group, epoch, 9),
            message_id: id.to_string(),
            sealed_sender: false,
            is_commit: true,
            commit_epoch: epoch,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: refused.iter().map(Uuid::to_string).collect(),
            parent_commit_id: parent.map(|p| p.to_string()).unwrap_or_default(),
        };
        let mut acks = std::collections::HashMap::new();
        let mut drain = |inboxes: &mut Vec<tokio::sync::mpsc::UnboundedReceiver<Bytes>>| {
            let mut pushed = Vec::new();
            for rx in inboxes.iter_mut() {
                while let Ok(bytes) = rx.try_recv() {
                    match WsFrame::decode(bytes.as_ref()) {
                        Ok(WsFrame { body: Some(Body::Ack(a)), .. }) => {
                            acks.insert(a.acked_frame_id, a.error_code);
                        }
                        Ok(WsFrame { body: Some(Body::Push(p)), .. }) => pushed.push(p.message_id),
                        _ => {}
                    }
                }
            }
            pushed
        };
        let state = || async {
            sqlx::query_as::<_, (i64,)>("SELECT current_epoch FROM mls_groups WHERE group_id = $1")
                .bind(&group)
                .fetch_one(&pool)
                .await
                .unwrap()
        };
        let push = test_push();
        let garbage = Uuid::now_v7();
        handle_submit(&pool, &sessions, &push, &rate, mallory, &mallory_dev, "garbage", commit(5, garbage, None, &[])).await.unwrap();
        assert!(drain(&mut inboxes).contains(&garbage.to_string()), "it goes out (the server can't read it)");
        assert_eq!(state().await, (6,));

        // Bob hasn't seen it yet: his Commit waits, as before.
        handle_submit(&pool, &sessions, &push, &rate, bob, &bob_dev, "bob-early", commit(5, Uuid::now_v7(), None, &[])).await.unwrap();
        // Alice's phone saw it and refused it: her Commit for epoch 5 goes through.
        let fix = Uuid::now_v7();
        handle_submit(&pool, &sessions, &push, &rate, alice, &alice_dev, "alice", commit(5, fix, None, &[garbage])).await.unwrap();
        assert!(drain(&mut inboxes).contains(&fix.to_string()));
        assert_eq!(state().await, (6,), "Alice's Commit for the same epoch goes through");
        // Bob refused the garbage too, but hasn't seen Alice's: no second good Commit.
        handle_submit(&pool, &sessions, &push, &rate, bob, &bob_dev, "bob-late", commit(5, Uuid::now_v7(), None, &[garbage])).await.unwrap();
        // Mallory gets one Commit per epoch.
        handle_submit(&pool, &sessions, &push, &rate, mallory, &mallory_dev, "again", commit(5, Uuid::now_v7(), None, &[fix])).await.unwrap();
        // Bob took Alice's Commit: the chat moves on.
        let next = Uuid::now_v7();
        handle_submit(&pool, &sessions, &push, &rate, bob, &bob_dev, "bob-next", commit(6, next, Some(fix), &[])).await.unwrap();
        drain(&mut inboxes);
        assert_eq!(
            ["garbage", "bob-early", "alice", "bob-late", "again", "bob-next"].map(|f| acks.get(f).copied()),
            [Some(0), Some(409), Some(0), Some(409), Some(409), Some(0)]
        );
        assert_eq!(state().await, (7,));
        drop(guards);
    }

    /// ADR-092 — the server orders only what says it is a Commit, so a
    /// Commit must say so (the flag) and its epoch is its own header's: an
    /// unflagged Commit would move the members on behind the server's back.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_commit_must_say_it_is_one(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"flagged".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let user_pk = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user_pk).bind(&[0x7Au8; 32][..]).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[0x7Au8; 32][..]).bind(user_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x7Au8; 32][..]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(user_pk, tx);
        let frame = |ciphertext: Vec<u8>, is_commit: bool, commit_epoch: u64| Submit {
            group_id: group.clone(),
            ciphertext,
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit,
            commit_epoch,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        let dev = [0x7Au8; 32];
        let push = test_push();
        handle_submit(&pool, &sessions, &push, &rate, user_pk, &dev, "unflagged", frame(fake_commit(&group, 0, 1), false, 0)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, user_pk, &dev, "not-a-commit", frame(vec![0, 1, 0, 2, 0], true, 0)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, user_pk, &dev, "other-epoch", frame(fake_commit(&group, 3, 1), true, 0)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, user_pk, &dev, "other-chat", frame(fake_commit(b"elsewhere", 0, 1), true, 0)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, user_pk, &dev, "message", frame(vec![0, 1, 0, 2, 0], false, 0)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, user_pk, &dev, "commit", frame(fake_commit(&group, 0, 1), true, 0)).await.unwrap();
        let mut acks = std::collections::HashMap::new();
        while let Ok(bytes) = rx.try_recv() {
            if let Ok(WsFrame { body: Some(Body::Ack(a)), .. }) = WsFrame::decode(bytes.as_ref()) {
                acks.insert(a.acked_frame_id, a.error_code);
            }
        }
        assert_eq!(
            ["unflagged", "not-a-commit", "other-epoch", "other-chat", "message", "commit"].map(|f| acks.get(f).copied()),
            [Some(400), Some(400), Some(400), Some(400), Some(0), Some(0)]
        );
    }

    /// ADR-092 — the head is read as a phone reads it: a PublicMessage
    /// Commit (an external join by the card) counts too, a proposal or an
    /// application message doesn't, and a cut-short frame is no Commit.
    #[test]
    fn mls_commit_head_reads_private_and_public_commits() {
        assert_eq!(mls_commit_head(&fake_commit(b"g", 7, 0)), Some((&b"g"[..], 7)));
        let mut public = vec![0, 1, 0, 1, 0x40, 1, b'g'];
        public.extend_from_slice(&9u64.to_be_bytes());
        public.extend_from_slice(&[4, 0, 3]);
        assert_eq!(mls_commit_head(&public), Some((&b"g"[..], 9)), "external commit, 2-byte length");
        let mut member = vec![0, 1, 0, 1, 1, b'g'];
        member.extend_from_slice(&1u64.to_be_bytes());
        member.extend_from_slice(&[1, 0, 0, 0, 2, 1, 0xAA, 3]);
        assert_eq!(mls_commit_head(&member), Some((&b"g"[..], 1)), "member sender, authenticated data");
        let mut app = fake_commit(b"g", 7, 0);
        app[5 + 1 + 8] = 1;
        assert_eq!(mls_commit_head(&app), None);
        assert_eq!(mls_commit_head(&fake_commit(b"g", 7, 0)[..10]), None);
        assert_eq!(mls_commit_head(b"hello"), None);
    }

    /// ADR-075 — Bob's phone in the chat was cut off (lost): his new device
    /// may send a Commit (its external join) — nothing else — and a
    /// stranger may not even do that.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_cut_off_devices_person_rejoins_by_commit_only(pool: sqlx::PgPool) {
        use prost::Message as _;
        let group = b"rejoin".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..3u8 {
            let user_pk = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(user_pk).bind(&[0x50 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
                .bind(&[0xA0 + i; 32][..]).bind(user_pk).bind(&b"cred"[..]).execute(&pool).await.unwrap();
            users.push(user_pk);
        }
        let (alice, bob, carol) = (users[0], users[1], users[2]);
        // Alice is in; Bob's old phone was, and was revoked; Carol never.
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
            .bind(&group).bind(&[0xA0u8; 32][..]).execute(&pool).await.unwrap();
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE device_pk = $1").bind(&[0xA1u8; 32][..]).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
            .bind(&[0xB1u8; 32][..]).bind(bob).bind(&b"cred"[..]).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO group_former_devices (group_id, device_pk) VALUES ($1, $2)")
            .bind(&group).bind(&[0xA1u8; 32][..]).execute(&pool).await.unwrap();

        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let mut inboxes = Vec::new();
        let mut guards = Vec::new();
        for u in &users {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            guards.push(sessions.register(*u, tx));
            inboxes.push(rx);
        }
        let frame = |is_commit: bool| Submit {
            group_id: group.clone(),
            ciphertext: if is_commit { fake_commit(&group, 0, 7) } else { vec![7] },
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit,
            commit_epoch: 0,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        let push = test_push();
        handle_submit(&pool, &sessions, &push, &rate, bob, &[], "msg", frame(false)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, carol, &[], "stranger", frame(true)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, bob, &[], "join", frame(true)).await.unwrap();
        let mut acks = std::collections::HashMap::new();
        let mut alice_got = 0;
        for (i, rx) in inboxes.iter_mut().enumerate() {
            while let Ok(bytes) = rx.try_recv() {
                match WsFrame::decode(bytes.as_ref()) {
                    Ok(WsFrame { body: Some(Body::Ack(a)), .. }) => {
                        acks.insert(a.acked_frame_id, a.error_code);
                    }
                    Ok(WsFrame { body: Some(Body::Push(_)), .. }) if i == 0 => alice_got += 1,
                    _ => {}
                }
            }
        }
        assert_eq!(acks.get("msg"), Some(&403), "a message from the cut-off person: no");
        assert_eq!(acks.get("stranger"), Some(&403), "a stranger's commit: no");
        assert_eq!(acks.get("join"), Some(&0), "the cut-off person's commit (external join): yes");
        assert_eq!(alice_got, 1, "Alice gets the join commit");
        drop(guards);
    }

    /// Tech-debt 2.9 — many senders submitting into one group at once
    /// (plus at-least-once retries of the same message_id): every message
    /// reaches every other member exactly once, and each recipient's
    /// sequence numbers are unique.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn concurrent_submits_deliver_each_message_exactly_once(pool: sqlx::PgPool) {
        let group = b"busy-group".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)")
            .bind(&group)
            .execute(&pool)
            .await
            .unwrap();
        let mut users = Vec::new();
        for i in 0..4u8 {
            let user_pk = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(user_pk)
                .bind(&[0x10 + i; 32][..])
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
                .bind(&[0xD0 + i; 32][..])
                .bind(user_pk)
                .bind(&b"cred"[..])
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
                .bind(&group)
                .bind(&[0xD0 + i; 32][..])
                .execute(&pool)
                .await
                .unwrap();
            users.push(user_pk);
        }

        let sessions = crate::session::SessionRegistry::new();
        let mut defaults = crate::rate_limit::RateConfig::defaults();
        defaults.ws_submit = crate::rate_limit::RateConfig::per_window(10_000, 60);
        let rate = crate::rate_limit::RateLimiter::new(defaults);

        // 4 senders × 25 messages, every message submitted twice
        // (a client retry racing its original).
        let mut ids = Vec::new();
        let mut jobs = Vec::new();
        for (s, sender) in users.iter().enumerate() {
            for m in 0..25 {
                let id = Uuid::now_v7();
                ids.push((*sender, id));
                for attempt in 0..2 {
                    let submit = Submit {
                        group_id: group.clone(),
                        ciphertext: vec![s as u8, m as u8, attempt],
                        message_id: id.to_string(),
                        is_commit: false,
                        commit_epoch: 0,
                        urgent: false,
                        sealed_sender: false,
                        access_keys: Vec::new(),
                        refused_commit_ids: Vec::new(),
                        parent_commit_id: String::new(),
                    };
                    let (pool, sessions, rate, sender) = (pool.clone(), sessions.clone(), rate.clone(), *sender);
                    jobs.push(tokio::spawn(async move {
                        handle_submit(&pool, &sessions, &test_push(), &rate, sender, &[], "f", submit).await
                    }));
                }
            }
        }
        for j in jobs {
            j.await.unwrap().unwrap();
        }

        for recipient in &users {
            let rows: Vec<(i64, Uuid)> = sqlx::query_as(
                "SELECT seq, message_id FROM message_deliveries WHERE recipient_user_pk = $1 ORDER BY seq",
            )
            .bind(recipient)
            .fetch_all(&pool)
            .await
            .unwrap();
            let expected: std::collections::BTreeSet<Uuid> =
                ids.iter().filter(|(s, _)| s != recipient).map(|(_, id)| *id).collect();
            let got: std::collections::BTreeSet<Uuid> = rows.iter().map(|r| r.1).collect();
            assert_eq!(rows.len(), 75, "3 other senders × 25 messages, retries de-duplicated");
            assert_eq!(got, expected, "every message from the others, none of one's own");
            let seqs: std::collections::BTreeSet<i64> = rows.iter().map(|r| r.0).collect();
            assert_eq!(seqs.len(), rows.len(), "sequence numbers are unique per recipient");
        }
        let (stored,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages").fetch_one(&pool).await.unwrap();
        assert_eq!(stored, 100, "a retry must not leave a second copy of the ciphertext");
        let (orphans,): (i64,) = sqlx::query_as(
            "SELECT count(*) FROM message_deliveries md WHERE NOT EXISTS \
             (SELECT 1 FROM messages m WHERE m.message_id = md.message_id)",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(orphans, 0, "every delivery still points at its ciphertext");
    }

    /// A removed linked device hears "device disconnected"; an unknown key
    /// and a working device don't (owner, 2026-11-01).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_removed_linked_device_is_told_so(pool: sqlx::PgPool) {
        let user_pk = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(user_pk).bind(&[0x61u8; 32][..]).execute(&pool).await.unwrap();
        for pk in [0xC1u8, 0xC2] {
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
                .bind(&[pk; 32][..]).bind(user_pk).bind(&b"cred"[..]).execute(&pool).await.unwrap();
        }
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE device_pk = $1").bind(&[0xC1u8; 32][..]).execute(&pool).await.unwrap();
        assert!(linked_device_removed(&pool, &[0xC1u8; 32]).await);
        assert!(!linked_device_removed(&pool, &[0xC2u8; 32]).await);
        assert!(!linked_device_removed(&pool, &[0xEEu8; 32]).await);
    }
}

/// ADR-083 — a member removed from a chat leaves its server roster too
/// (security review 2026-11, critic:5, critic:3 server part).
#[cfg(test)]
mod roster_removal_tests {
    use super::*;
    use crate::handlers::groups::{self, GroupError};
    use axum::extract::{Json, Path};
    use ed25519_dalek::{Signer, SigningKey};
    use sha2::{Digest, Sha256};

    fn signed(sk: &SigningKey, domain: &[u8], body: &[u8]) -> (String, i64, String) {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = domain.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(body));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        (hex::encode(sk.verifying_key().to_bytes()), ts, hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()))
    }

    fn removal(by: &SigningKey, group: &[u8], who: &[&SigningKey]) -> groups::RemoveRequest {
        let people: Vec<Vec<u8>> = who.iter().map(|p| p.verifying_key().to_bytes().to_vec()).collect();
        let (signer, ts, sig) = signed(by, b"sinhron-group-remove-v1:", &groups::remove_body(group, &people));
        groups::RemoveRequest {
            identity_pubkey_hex: signer,
            member_identities_hex: people.iter().map(hex::encode).collect(),
            proof_ts: ts,
            proof_hex: sig,
        }
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_removed_member_is_off_the_roster_and_gets_no_fanout(pool: sqlx::PgPool) {
        let group = b"family".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let keys: Vec<SigningKey> = (0..4u8).map(|i| SigningKey::from_bytes(&[0x90 + i; 32])).collect();
        let mut users = Vec::new();
        for (i, sk) in keys.iter().enumerate() {
            let (u, pk) = (Uuid::now_v7(), sk.verifying_key().to_bytes().to_vec());
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
            if i < 3 {
                sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
                    .bind(&group).bind(&pk).execute(&pool).await.unwrap();
            }
            users.push(u);
        }
        let (alice, bob, mallory) = (&keys[0], &keys[1], &keys[3]);
        // Bob also has an old phone here that he cut off (ADR-075).
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential, revoked_at) VALUES ($1, $2, $1, NOW())")
            .bind(&[0x9Fu8; 32][..]).bind(users[1]).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO group_former_devices (group_id, device_pk) VALUES ($1, $2)")
            .bind(&group).bind(&[0x9Fu8; 32][..]).execute(&pool).await.unwrap();

        let sessions = crate::session::SessionRegistry::new();
        let state = || AppState {
            pool: Some(pool.clone()),
            sessions: sessions.clone(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        };
        let path = || Path(hex::encode(&group));
        // Not a member: can't take anyone out.
        assert!(matches!(
            groups::remove(State(state()), path(), Json(removal(mallory, &group, &[bob]))).await,
            Err(GroupError::Forbidden(_))
        ));
        // Alice's Commit removed Bob; her app tells the server.
        assert_eq!(groups::remove(State(state()), path(), Json(removal(alice, &group, &[bob]))).await.unwrap(), StatusCode::NO_CONTENT);
        let (rows,): (i64,) = sqlx::query_as(
            "SELECT (SELECT count(*) FROM group_members gm JOIN devices d ON d.device_pk = gm.device_pk WHERE gm.group_id = $1 AND d.user_pk = $2) \
                  + (SELECT count(*) FROM group_former_devices f JOIN devices d ON d.device_pk = f.device_pk WHERE f.group_id = $1 AND d.user_pk = $2)",
        )
        .bind(&group).bind(users[1]).fetch_one(&pool).await.unwrap();
        assert_eq!(rows, 0, "Bob is off the roster, his cut-off phone too");

        // Alice writes: Carol gets it, Bob doesn't. Bob can't post, fetch the
        // card or put himself back.
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let mut inboxes = Vec::new();
        let mut guards = Vec::new();
        for u in &users[..3] {
            let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
            guards.push(sessions.register(*u, tx));
            inboxes.push(rx);
        }
        let frame = |is_commit: bool| Submit {
            group_id: group.clone(),
            ciphertext: if is_commit { crate::ws::tests::fake_commit(&group, 0, 7) } else { vec![7] },
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit,
            commit_epoch: 0,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        handle_submit(&pool, &sessions, &push, &rate, users[0], &[], "a1", frame(false)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, users[1], &[], "b1", frame(false)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, users[1], &[], "b2", frame(true)).await.unwrap();
        let mut pushes = [0; 3];
        let mut acks = std::collections::HashMap::new();
        for (i, rx) in inboxes.iter_mut().enumerate() {
            while let Ok(bytes) = rx.try_recv() {
                match WsFrame::decode(bytes.as_ref()) {
                    Ok(WsFrame { body: Some(Body::Ack(a)), .. }) => {
                        acks.insert(a.acked_frame_id, a.error_code);
                    }
                    Ok(WsFrame { body: Some(Body::Push(_)), .. }) => pushes[i] += 1,
                    _ => {}
                }
            }
        }
        assert_eq!(pushes, [0, 0, 1], "only Carol gets Alice's message");
        assert_eq!((acks.get("a1"), acks.get("b1"), acks.get("b2")), (Some(&0), Some(&403), Some(&403)));
        let (pk, ts, sig) = signed(bob, b"sinhron-group-card-get-v1:", &group);
        let card = groups::GetCardRequest { device_pk_hex: pk, proof_ts: ts, proof_hex: sig };
        assert!(matches!(groups::get_card(State(state()), path(), Json(card)).await, Err(GroupError::Forbidden(_))));
        let bob_pk = bob.verifying_key().to_bytes().to_vec();
        let (pk, ts, sig) = signed(bob, b"sinhron-group-announce-v1:", &groups::announce_body(&group, 0, std::slice::from_ref(&bob_pk)));
        let back = groups::CreateGroupRequest {
            group_id_hex: hex::encode(&group),
            creator_device_pk_hex: pk,
            member_device_pks_hex: vec![hex::encode(&bob_pk)],
            epoch: 0,
            proof_ts: Some(ts),
            proof_hex: Some(sig),
        };
        assert!(matches!(groups::create(State(state()), Json(back)).await, Err(GroupError::Forbidden(_))));
        drop(guards);
    }
}

/// Attacks from the 2026-11-11 audit (docs/security-audit-2026-11b/04-server-ws):
/// each test states the right behaviour and failed before its fix.
#[cfg(test)]
mod audit_tests {
    use super::tests::fake_commit;
    use super::*;

    fn acks(r: &mut tokio::sync::mpsc::UnboundedReceiver<Bytes>) -> Vec<(String, i32)> {
        std::iter::from_fn(|| r.try_recv().ok())
            .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                Body::Ack(a) => Some((a.acked_frame_id, a.error_code)),
                _ => None,
            })
            .collect()
    }

    /// The real server on a local port, without a database behind it.
    async fn serve() -> std::net::SocketAddr {
        let pool = sqlx::postgres::PgPoolOptions::new().connect_lazy("postgres://nobody@127.0.0.1:1/none").unwrap();
        let state = crate::AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: CallSessionRegistry::new(),
        };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, crate::build_app(state)).await });
        addr
    }

    /// A client's connection to [serve]'s server, as if from [ip] behind Caddy.
    async fn connect(
        addr: std::net::SocketAddr,
        ip: Option<&str>,
    ) -> Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, tokio_tungstenite::tungstenite::Error> {
        use tokio_tungstenite::tungstenite::client::IntoClientRequest;
        let mut req = format!("ws://{addr}/v1/sync").into_client_request().unwrap();
        req.headers_mut().insert("sec-websocket-protocol", "sinhron.v1".parse().unwrap());
        if let Some(ip) = ip {
            req.headers_mut().insert("x-forwarded-for", ip.parse().unwrap());
        }
        tokio_tungstenite::connect_async(req).await.map(|(ws, _)| ws)
    }

    /// WS-01 — a stranger sends empty Pings instead of Auth: the recursion
    /// in `next_frame_inline` overflowed the stack and aborted the process
    /// (this test killed the whole test run).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn pings_before_login_do_not_kill_the_server() {
        let addr = serve().await;
        let mut ws = connect(addr, None).await.unwrap();
        let _hello = ws.next().await;
        for _ in 0..200_000u32 {
            if ws.feed(tokio_tungstenite::tungstenite::Message::Ping(Bytes::new())).await.is_err() {
                break;
            }
        }
        let _ = ws.flush().await;
        // The server hung up on the flood instead of reading it to the end.
        let closed = timeout(Duration::from_secs(60), async { while let Some(Ok(_)) = ws.next().await {} }).await;
        assert!(closed.is_ok(), "the flooding connection is closed");
        let mut ws2 = connect(addr, None).await.expect("the server is still up");
        assert!(ws2.next().await.is_some());
    }

    async fn two_people(pool: &sqlx::PgPool) -> (Uuid, Uuid) {
        let (mallory, bob) = (Uuid::now_v7(), Uuid::now_v7());
        for (u, id) in [(mallory, 0x61u8), (bob, 0x62u8)] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[id; 32][..]).execute(pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[id; 32][..]).bind(u).execute(pool).await.unwrap();
        }
        (mallory, bob)
    }

    /// WS-07 — the Welcome quota counted `welcome_bytes` only; megabytes in
    /// `group_id` lay next to it in the same row (314 MB against a 64 MB cap).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_welcome_cannot_carry_megabytes_in_its_group_id(pool: sqlx::PgPool) {
        let (mallory, _bob) = two_people(&pool).await;
        let sessions = crate::session::SessionRegistry::new();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(mallory, tx);
        let welcome = |group_id: Vec<u8>| Welcome { recipient_identity_pubkey: vec![0x62; 32], group_id, welcome_bytes: vec![1], sent_at: 0, recipient_device_pks: vec![] };
        handle_welcome(&pool, &sessions, mallory, "fat", welcome(vec![7; 3 * 1024 * 1024])).await.unwrap();
        assert_eq!(acks(&mut rx), vec![("fat".to_string(), 400)]);
        // What fits the field is still counted against the queue's cap.
        for i in 0..12u8 {
            let w = Welcome { welcome_bytes: vec![i; MAX_WELCOME_BYTES - 200], ..welcome(vec![i; 255]) };
            handle_welcome(&pool, &sessions, mallory, "w", w).await.unwrap();
        }
        let (total, rows): (i64, i64) =
            sqlx::query_as("SELECT COALESCE(SUM(octet_length(group_id) + octet_length(welcome_bytes)), 0)::bigint, COUNT(*) FROM pending_welcomes")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert!(total as usize <= MAX_PENDING_WELCOME_BYTES, "{total} bytes queued for one person");
        assert_eq!(rows, 7, "the group ids count: 8 such Welcomes are over 8 MiB");
    }

    /// WS-08 — a person with two devices; anyone queues them 40 Welcomes of
    /// 1 MiB. Every login poured all of them into the connection, it went
    /// over its 32 MiB cap and was closed; the rows stayed — for a year.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn queued_welcomes_do_not_lock_a_person_out(pool: sqlx::PgPool) {
        let (mallory, bob) = two_people(&pool).await;
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[0x63u8; 32][..]).bind(bob).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        for i in 0..40u8 {
            let w = Welcome { recipient_identity_pubkey: vec![0x62; 32], group_id: b"g".to_vec(), welcome_bytes: vec![i; MAX_WELCOME_BYTES], sent_at: 0, recipient_device_pks: vec![] };
            handle_welcome(&pool, &sessions, mallory, "w", w).await.unwrap();
        }
        // A queue left from before the fix (64 MiB cap, nobody's device).
        for _ in 0..40 {
            sqlx::query("INSERT INTO pending_welcomes (recipient_user_pk, group_id, welcome_bytes, expires_at) VALUES ($1, 'g', $2, NOW() + interval '1 day')")
                .bind(bob)
                .bind(vec![9u8; MAX_WELCOME_BYTES])
                .execute(&pool)
                .await
                .unwrap();
        }
        let (other_tx, mut other_rx) = tokio::sync::mpsc::unbounded_channel();
        let _other = sessions.register_device(bob, Some(vec![0x63; 32]), other_tx);
        while other_rx.try_recv().is_ok() {}
        for login in 0..3 {
            let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
            let guard = sessions.register_device(bob, Some(vec![0x62; 32]), tx);
            flush_pending_welcomes(&pool, &sessions, bob, Some(&[0x62; 32])).await.unwrap();
            let queued = guard.queued().load(std::sync::atomic::Ordering::Relaxed);
            assert!(queued <= MAX_PENDING_WELCOME_BYTES + 4096, "login {login}: {queued} bytes queued");
            if login == 0 {
                assert!(rx.try_recv().is_ok(), "the device does get its Welcomes");
            }
        }
        assert!(other_rx.try_recv().is_err(), "a login does not replay the queue to the person's other device");
    }

    /// WS-05 — a member sends an ordinary message with id X, then a Commit
    /// with the same X. The Commit was written into the epoch's order but
    /// delivered to nobody: every honest Commit after it got 409, forever
    /// (a way around ADR-092 / PR #87).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_commit_nobody_received_does_not_freeze_the_chat(pool: sqlx::PgPool) {
        let group = b"hidden-commit".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id, current_epoch) VALUES ($1, 5)").bind(&group).execute(&pool).await.unwrap();
        let mut users = Vec::new();
        for i in 0..3u8 {
            let u = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&[0x70 + i; 32][..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&[0x70 + i; 32][..]).bind(u).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x70 + i; 32][..]).execute(&pool).await.unwrap();
            users.push(u);
        }
        let (alice, mallory) = (users[0], users[2]);
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let (atx, mut arx) = tokio::sync::mpsc::unbounded_channel();
        let (mtx, mut mrx) = tokio::sync::mpsc::unbounded_channel();
        let _g = (sessions.register(alice, atx), sessions.register(mallory, mtx));
        let submit = |id: Uuid, commit: bool| Submit {
            group_id: group.clone(),
            ciphertext: if commit { fake_commit(&group, 5, 9) } else { vec![0, 1, 0, 2, 0] },
            message_id: id.to_string(),
            sealed_sender: false,
            is_commit: commit,
            commit_epoch: if commit { 5 } else { 0 },
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        let x = Uuid::now_v7();
        handle_submit(&pool, &sessions, &push, &rate, mallory, &[0x72; 32], "msg", submit(x, false)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, mallory, &[0x72; 32], "hidden", submit(x, true)).await.unwrap();
        assert_eq!(acks(&mut mrx), vec![("msg".to_string(), 0), ("hidden".to_string(), 400)], "the hidden Commit is refused");
        let (held, epoch): (i64, i64) =
            sqlx::query_as("SELECT (SELECT COUNT(*) FROM group_commits), (SELECT current_epoch FROM mls_groups WHERE group_id = $1)")
                .bind(&group)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!((held, epoch), (0, 5), "nothing written into the epoch's order");
        // Alice got one Push (the ordinary message); her honest Commit for
        // the same epoch goes through.
        assert_eq!(std::iter::from_fn(|| arx.try_recv().ok()).count(), 1);
        handle_submit(&pool, &sessions, &push, &rate, alice, &[0x70; 32], "alice", submit(Uuid::now_v7(), true)).await.unwrap();
        assert_eq!(acks(&mut arx), vec![("alice".to_string(), 0)], "an honest Commit goes through (was: 409 forever)");
    }

    /// WS-04, WS-06 — one account wrote 4 MiB frames 600 times a minute
    /// (Submit or sealed envelopes), kept a year: the disk full in minutes.
    /// Large frames now draw on an hourly byte budget; ordinary messages
    /// don't, and a message to nobody is not kept.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn large_messages_have_an_hourly_budget(pool: sqlx::PgPool) {
        let (mallory, bob) = two_people(&pool).await;
        let group = b"bulk".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id, current_epoch) VALUES ($1, 0)").bind(&group).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x61u8; 32][..]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(mallory, tx);
        let submit = |bytes: usize| Submit {
            group_id: group.clone(),
            ciphertext: vec![0; bytes],
            message_id: Uuid::now_v7().to_string(),
            sealed_sender: false,
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        // Alone in the chat: accepted, nothing kept.
        handle_submit(&pool, &sessions, &push, &rate, mallory, &[0x61; 32], "alone", submit(100)).await.unwrap();
        let (kept,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM messages").fetch_one(&pool).await.unwrap();
        assert_eq!((acks(&mut rx), kept), (vec![("alone".to_string(), 0)], 0), "a message to nobody is not stored");

        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[0x62u8; 32][..]).execute(&pool).await.unwrap();
        // 4 MiB frames: 16 tokens each, 2000 an hour — the 126th is refused.
        let mut codes = Vec::new();
        for _ in 0..130 {
            handle_submit(&pool, &sessions, &push, &rate, mallory, &[0x61; 32], "big", submit(MAX_WS_MESSAGE_BYTES - 1024)).await.unwrap();
            codes.extend(acks(&mut rx).into_iter().map(|a| a.1));
            sqlx::query("DELETE FROM messages").execute(&pool).await.unwrap();
        }
        assert_eq!(codes.iter().filter(|c| **c == 0).count(), 125, "~500 MiB an hour, then 429");
        assert!(codes[125..].iter().all(|c| *c == 429));
        // The same budget for sealed envelopes; ordinary messages still go.
        let sealed = SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![crate::proto::SealedDelivery { key_id: vec![1; 16], envelope: vec![0; 1024 * 1024], ttl_secs: 0, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 }],
            access_keys: Vec::new(),
        };
        handle_sealed_submit(&pool, &sessions, &push, &rate, mallory, "sealed", sealed).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, mallory, &[0x61; 32], "small", submit(BULK_FREE_BYTES)).await.unwrap();
        assert_eq!(acks(&mut rx), vec![("sealed".to_string(), 429), ("small".to_string(), 0)]);
        // The refused frames gave their tokens back: none is left, and the
        // five refusals above did not push the account into debt.
        assert!(!bulk_allowed(mallory, BULK_FREE_BYTES + 1));
        let _ = bob;
    }

    /// WS-03 — a login or a Resume read up to 1000 queued rows of any size
    /// (4 MiB each) into memory at once. Now a page of ~16 MiB; the rest
    /// comes with the next one, nothing is lost.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_big_backlog_comes_in_pages(pool: sqlx::PgPool) {
        let (_mallory, bob) = two_people(&pool).await;
        for _ in 0..10 {
            sqlx::query("INSERT INTO message_deliveries (recipient_user_pk, message_id, envelope, sealed_key_id) VALUES ($1, $2, $3, $4)")
                .bind(bob)
                .bind(Uuid::now_v7())
                .bind(vec![7u8; 3 * 1024 * 1024])
                .bind(&[1u8; 16][..])
                .execute(&pool)
                .await
                .unwrap();
        }
        let sessions = crate::session::SessionRegistry::new();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let guard = sessions.register(bob, tx);
        let mut seqs = Vec::new();
        let mut drain = |guard: &crate::session::SessionGuard| {
            let got: Vec<u64> = std::iter::from_fn(|| rx.try_recv().ok())
                .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                    Body::Push(p) => Some(p.sequence),
                    _ => None,
                })
                .collect();
            guard.queued().store(0, std::sync::atomic::Ordering::Relaxed);
            got
        };
        assert_eq!(deliver_backlog(&pool, &sessions, bob).await.unwrap(), 6, "a login: 16 MiB of 3 MiB rows");
        seqs.extend(drain(&guard));
        // Resume from where the app got to: the next page, then the last.
        for (frame, expect) in [("r1", 4usize), ("r2", 0)] {
            let cursors = vec![StreamCursor { stream_id: MAIN_STREAM_ID.to_string(), last_acked_seq: *seqs.last().unwrap() }];
            handle_resume(&pool, &sessions, bob, frame, Resume { cursors }).await.unwrap();
            let page = drain(&guard);
            assert_eq!(page.len(), expect, "{frame}");
            seqs.extend(page);
        }
        assert_eq!(seqs.len(), 10);
        assert!(seqs.windows(2).all(|w| w[0] < w[1]), "in order, each once");
        assert_eq!(deliver_backlog(&pool, &sessions, bob).await.unwrap(), 0, "all marked received");
    }

    /// WS-11 — nothing limited new connections: thousands of sockets held
    /// before login, or one account logging in in a loop. Now a limit
    /// per client address (600 a minute).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn connections_from_one_address_are_limited() {
        let addr = serve().await;
        let mut refused = 0;
        for _ in 0..605 {
            match connect(addr, Some("6.6.6.6, 198.51.100.7")).await {
                Ok(ws) => drop(ws),
                Err(tokio_tungstenite::tungstenite::Error::Http(r)) if r.status() == 429 => refused += 1,
                Err(e) => panic!("{e}"),
            }
        }
        assert_eq!(refused, 5, "600 a minute, then 429");
        assert!(connect(addr, Some("198.51.100.8")).await.is_ok(), "another address is not affected");
    }

    /// WS-02 — a connection over its 32 MiB cap was closed after ONE more
    /// frame; the rest of its queue — messages already marked as received,
    /// Welcomes already deleted — was dropped for good.
    #[tokio::test]
    async fn a_stalled_connection_is_closed_only_after_its_queue_went_out() {
        let sessions = crate::session::SessionRegistry::new();
        let user = Uuid::now_v7();
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let guard = sessions.register(user, tx);
        let frame = Bytes::from(vec![0u8; 4 * 1024 * 1024]);
        let queued = (0..10).filter(|_| sessions.fanout(&[user], frame.clone()) == 1).count();
        assert_eq!(queued, 8, "32 MiB fit, then the connection is marked stalled");
        let written = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let sink = Box::pin(futures_util::sink::unfold(written.clone(), |n, _m: Message| async move {
            n.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            Ok::<_, std::convert::Infallible>(n)
        }));
        // Ends by itself (the registry still holds the sender): it closes.
        timeout(Duration::from_secs(60), run_send_task(sink, rx, guard.queued())).await.expect("the send task closes the connection");
        assert_eq!(written.load(std::sync::atomic::Ordering::Relaxed), 8, "everything queued was written first");
    }

    /// WS-10 — every Commit on the server waits for one lock, and one
    /// account could send 600 a minute. WS-21 — the Welcome ack said whether
    /// the person is online. WS-39 — a device list was sorted before counted.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn commits_are_limited_and_a_welcome_ack_says_nothing(pool: sqlx::PgPool) {
        let (mallory, bob) = two_people(&pool).await;
        let group = b"commit-flood".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id, current_epoch) VALUES ($1, 5)").bind(&group).execute(&pool).await.unwrap();
        for id in [0x61u8, 0x62] {
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[id; 32][..]).execute(&pool).await.unwrap();
        }
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(mallory, tx);
        for _ in 0..125 {
            let commit = Submit {
                group_id: group.clone(),
                ciphertext: fake_commit(&group, 5, 9),
                message_id: Uuid::now_v7().to_string(),
                sealed_sender: false,
                is_commit: true,
                commit_epoch: 5,
                urgent: false,
                access_keys: Vec::new(),
                refused_commit_ids: Vec::new(),
                parent_commit_id: String::new(),
            };
            handle_submit(&pool, &sessions, &push, &rate, mallory, &[0x61; 32], "c", commit).await.unwrap();
        }
        let codes: Vec<i32> = acks(&mut rx).into_iter().map(|a| a.1).collect();
        // The first is taken; the rest are the same device's second Commit
        // for the epoch — 409.
        assert_eq!((codes[0], codes[1], codes[119]), (0, 409, 409));
        assert!(codes[120..].iter().all(|c| *c == 429), "120 a minute, then 429: {:?}", &codes[118..]);

        // Welcome: the same answer to an offline person and an online one.
        let welcome = |devices: Vec<Vec<u8>>| Welcome { recipient_identity_pubkey: vec![0x62; 32], group_id: group.clone(), welcome_bytes: vec![1], sent_at: 0, recipient_device_pks: devices };
        let texts = |r: &mut tokio::sync::mpsc::UnboundedReceiver<Bytes>| -> Vec<(i32, String)> {
            std::iter::from_fn(|| r.try_recv().ok())
                .filter_map(|b| match WsFrame::decode(b.as_ref()).ok()?.body? {
                    Body::Ack(a) => Some((a.error_code, a.error_message)),
                    _ => None,
                })
                .collect()
        };
        handle_welcome(&pool, &sessions, mallory, "off", welcome(vec![])).await.unwrap();
        handle_welcome(&pool, &sessions, mallory, "off-dev", welcome(vec![vec![0x62; 32]])).await.unwrap();
        let (btx, _brx) = tokio::sync::mpsc::unbounded_channel();
        let _b = sessions.register_device(bob, Some(vec![0x62; 32]), btx);
        handle_welcome(&pool, &sessions, mallory, "on", welcome(vec![])).await.unwrap();
        handle_welcome(&pool, &sessions, mallory, "on-dev", welcome(vec![vec![0x62; 32]])).await.unwrap();
        let answers = texts(&mut rx);
        assert_eq!(answers.len(), 4);
        assert!(answers.iter().all(|a| *a == answers[0] && a.0 == 0), "{answers:?}");
        // 65 times the same device: refused before any sorting.
        handle_welcome(&pool, &sessions, mallory, "many", welcome(vec![vec![0x62; 32]; 65])).await.unwrap();
        assert_eq!(texts(&mut rx)[0].0, 400);
    }

    /// WS-30 — the "was this device disconnected?" check at login read a
    /// database error as "no" and let the device in. WS-19 — the same check
    /// now also runs after the connection is registered.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_disconnected_device_check_does_not_pass_on_a_database_error(pool: sqlx::PgPool) {
        let (_mallory, bob) = two_people(&pool).await;
        assert!(!device_revoked(&pool, &[0x62; 32], bob).await.unwrap());
        assert!(!device_revoked(&pool, &[0x99; 32], bob).await.unwrap(), "no such device");
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE user_pk = $1").bind(bob).execute(&pool).await.unwrap();
        assert!(device_revoked(&pool, &[0x62; 32], bob).await.unwrap());
        let broken = sqlx::postgres::PgPoolOptions::new()
            .acquire_timeout(Duration::from_millis(300))
            .connect_lazy("postgres://nobody@127.0.0.1:1/none")
            .unwrap();
        assert!(device_revoked(&broken, &[0x62; 32], bob).await.is_err(), "an error is an error, not 'still connected'");
    }

    /// A lost Ack — the same device sends the same Commit again (same id,
    /// same bytes): the same answer as the first time, nothing sent twice.
    /// The id from another device, or with other bytes, is refused.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_repeated_commit_gets_the_same_answer(pool: sqlx::PgPool) {
        let (alice, bob) = two_people(&pool).await;
        let group = b"commit-retry".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id, current_epoch) VALUES ($1, 5)").bind(&group).execute(&pool).await.unwrap();
        for id in [0x61u8, 0x62] {
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(&[id; 32][..]).execute(&pool).await.unwrap();
        }
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let (atx, mut arx) = tokio::sync::mpsc::unbounded_channel();
        let (btx, mut brx) = tokio::sync::mpsc::unbounded_channel();
        let _g = (sessions.register(alice, atx), sessions.register(bob, btx));
        let id = Uuid::now_v7();
        let commit = |tag: u8| Submit {
            group_id: group.clone(),
            ciphertext: fake_commit(&group, 5, tag),
            message_id: id.to_string(),
            sealed_sender: false,
            is_commit: true,
            commit_epoch: 5,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        };
        handle_submit(&pool, &sessions, &push, &rate, alice, &[0x61; 32], "first", commit(9)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, alice, &[0x61; 32], "again", commit(9)).await.unwrap();
        assert_eq!(acks(&mut arx), vec![("first".to_string(), 0), ("again".to_string(), 0)]);
        assert_eq!(std::iter::from_fn(|| brx.try_recv().ok()).count(), 1, "Bob got the Commit once");
        let (held, epoch): (i64, i64) =
            sqlx::query_as("SELECT (SELECT COUNT(*) FROM group_commits), (SELECT current_epoch FROM mls_groups WHERE group_id = $1)")
                .bind(&group)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!((held, epoch), (1, 6));
        // The chat moves on (Bob's Commit for epoch 6); Alice, who never got
        // her Ack, repeats her Commit for epoch 5: still "taken", not 409.
        let next = Submit { ciphertext: fake_commit(&group, 6, 7), message_id: Uuid::now_v7().to_string(), commit_epoch: 6, ..commit(9) };
        handle_submit(&pool, &sessions, &push, &rate, bob, &[0x62; 32], "next", next).await.unwrap();
        assert_eq!(acks(&mut brx), vec![("next".to_string(), 0)]);
        handle_submit(&pool, &sessions, &push, &rate, alice, &[0x61; 32], "late", commit(9)).await.unwrap();
        assert_eq!(acks(&mut arx), vec![("late".to_string(), 0)], "a repeat after the chat moved on");
        while brx.try_recv().is_ok() {}
        // Other bytes under the same id; the same id from another device.
        handle_submit(&pool, &sessions, &push, &rate, alice, &[0x61; 32], "other-bytes", commit(8)).await.unwrap();
        handle_submit(&pool, &sessions, &push, &rate, bob, &[0x62; 32], "other-device", commit(9)).await.unwrap();
        assert_eq!(acks(&mut arx), vec![("other-bytes".to_string(), 400)]);
        assert_eq!(acks(&mut brx), vec![("other-device".to_string(), 400)]);
    }

    /// WS-50 — a frame after login made of 2 million empty list items fits
    /// the 4 MiB limit and decoded into ~180 MiB of heap before any check.
    #[test]
    fn a_frame_after_login_does_not_decode_into_hundreds_of_megabytes() {
        use prost::Message as _;
        let frame = |n: usize| {
            WsFrame {
                frame_id: "f".to_string(),
                body: Some(Body::SealedSubmit(SealedSubmit { deliveries: vec![Default::default(); n], ..Default::default() })),
            }
            .encode_to_vec()
        };
        let bloat = frame(2_000_000);
        assert!(bloat.len() <= MAX_WS_MESSAGE_BYTES);
        assert!(decode_frame(&bloat).is_err(), "refused before it is decoded");
        // The same shape in another list.
        let cursors = WsFrame { frame_id: String::new(), body: Some(Body::Resume(Resume { cursors: vec![Default::default(); 100_000] })) }.encode_to_vec();
        assert!(decode_frame(&cursors).is_err());
        // The largest honest frames pass: 1000 deliveries, a 4 MiB message.
        let Some(Body::SealedSubmit(s)) = decode_frame(&frame(1000)).unwrap().body else { panic!() };
        assert_eq!(s.deliveries.len(), 1000);
        let big = WsFrame {
            frame_id: Uuid::now_v7().to_string(),
            body: Some(Body::Submit(Submit { ciphertext: vec![0x12; MAX_WS_MESSAGE_BYTES - 1024], group_id: vec![1; 32], ..Default::default() })),
        }
        .encode_to_vec();
        assert!(matches!(decode_frame(&big).unwrap().body, Some(Body::Submit(_))));
        assert!(decode_frame(&[0xFF; 64]).is_err(), "garbage is still an error");
        // WS-49 — a frame_id is a short label, not a megabyte for other people.
        let id = |n: usize| WsFrame { frame_id: "w".repeat(n), body: Some(Body::Welcome(Welcome::default())) }.encode_to_vec();
        assert!(decode_frame(&id(MAX_FRAME_ID_BYTES)).is_ok() && decode_frame(&id(MAX_FRAME_ID_BYTES + 1)).is_err());
    }

    /// GRP-8, WS-04 — `POST /v1/sealed` got a cap on the envelope; a
    /// signed-in SealedSubmit went around it (4 MiB each).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_sealed_envelope_over_the_websocket_has_a_cap(pool: sqlx::PgPool) {
        let (mallory, bob) = two_people(&pool).await;
        let key = vec![0x5Au8; 16];
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)").bind(&key).bind(bob).bind(&[1u8; 32][..]).execute(&pool).await.unwrap();
        let sessions = crate::session::SessionRegistry::new();
        let rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults());
        let push: std::sync::Arc<dyn crate::push::PushClient> = std::sync::Arc::new(crate::push::LoggingPush);
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let _g = sessions.register(mallory, tx);
        let sealed = |bytes: usize| SealedSubmit {
            message_id: Uuid::now_v7().to_string(),
            deliveries: vec![crate::proto::SealedDelivery { key_id: key.clone(), envelope: vec![0; bytes], ttl_secs: 0, urgent: false, push_preview: Vec::new(), drop_after_secs: 0 }],
            access_keys: Vec::new(),
        };
        handle_sealed_submit(&pool, &sessions, &push, &rate, mallory, "big", sealed(MAX_SEALED_ENVELOPE_BYTES + 1)).await.unwrap();
        handle_sealed_submit(&pool, &sessions, &push, &rate, mallory, "ok", sealed(MAX_SEALED_ENVELOPE_BYTES)).await.unwrap();
        assert_eq!(acks(&mut rx), vec![("big".to_string(), 413), ("ok".to_string(), 0)]);
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM message_deliveries WHERE recipient_user_pk = $1").bind(bob).fetch_one(&pool).await.unwrap();
        assert_eq!(n, 1, "only the one that fits is stored");
    }

    /// REL-1 — a second device whose queue is larger than one page (16 MiB)
    /// got the first page only; the next live message moved its cursor past
    /// the rest, which then never came. The Ack now says "more <seq>" and
    /// the app asks on: following it delivers everything, in order, once.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn following_the_acks_a_resume_delivers_the_whole_queue_in_order(pool: sqlx::PgPool) {
        let (_mallory, bob) = two_people(&pool).await;
        // 40 MiB, already marked received by Bob's first device.
        for _ in 0..13 {
            sqlx::query("INSERT INTO message_deliveries (recipient_user_pk, message_id, envelope, sealed_key_id, received_at) VALUES ($1, $2, $3, $4, NOW())")
                .bind(bob)
                .bind(Uuid::now_v7())
                .bind(vec![7u8; 3 * 1024 * 1024 + 100 * 1024])
                .bind(&[1u8; 16][..])
                .execute(&pool)
                .await
                .unwrap();
        }
        let sessions = crate::session::SessionRegistry::new();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let guard = sessions.register(bob, tx);
        let (mut seqs, mut from, mut rounds) = (Vec::new(), 0u64, 0);
        loop {
            rounds += 1;
            let cursors = vec![StreamCursor { stream_id: MAIN_STREAM_ID.to_string(), last_acked_seq: from }];
            handle_resume(&pool, &sessions, bob, "r", Resume { cursors }).await.unwrap();
            let mut more = None;
            // What the app's socket reads, in order: the page, then its Ack.
            while let Ok(b) = rx.try_recv() {
                match WsFrame::decode(b.as_ref()).unwrap().body.unwrap() {
                    Body::Push(p) => {
                        assert!(more.is_none(), "the Ack comes after its page");
                        seqs.push(p.sequence);
                    }
                    Body::Ack(a) => more = Some(resume_more(&a.error_message)),
                    _ => {}
                }
            }
            let queued = guard.queued().swap(0, std::sync::atomic::Ordering::Relaxed);
            assert!(queued <= crate::session::MAX_QUEUED_BYTES, "one page at a time fits the connection: {queued}");
            match more.expect("every Resume is answered") {
                Some(next) => {
                    assert_eq!(Some(&next), seqs.last(), "the next page starts where this one ended");
                    from = next;
                }
                None => break,
            }
            assert!(rounds < 10, "it ends");
        }
        assert_eq!((seqs.len(), rounds), (13, 3), "40 MiB in three pages");
        assert!(seqs.windows(2).all(|w| w[0] < w[1]), "in order, each once");
    }
}
