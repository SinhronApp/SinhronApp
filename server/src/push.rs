// Push notifications — overnight item 8.
//
// When a message reaches someone with no live connection, their phones get
// an APNs push: a localized "New message" and the badge. Never the message,
// never the chat in a form the server or Apple can read (tech-debt 2.7, spec
// §13.x). ADR-056: the sender may add a preview sealed to the recipient's
// delivery key; it rides along unread and the phone's Notification Service
// Extension shows the name and text from it. A call push carries an HMAC of
// call + chat under a key the phone registered with its PushKit token —
// CallKit names the caller at once, nobody else can tell the chat.
//
// Which deliveries wake a phone is the sender's call: the app marks a
// delivery `urgent` for a real message (text, photo, voice, file…), not for
// receipts, "typing", presence or reactions — the server can't tell them
// apart (sealed, ADR-023).
//
// Tokens live in `apns_tokens` (device, kind alert / voip, sandbox?) —
// `PUT /v1/push-token` (handlers/push_tokens.rs): APNs hex, a UnifiedPush
// `https://` endpoint (ADR-040) or, ADR-057, `fcm:` + a Google token with
// the phone's own 32-byte key (`fcm.rs` — Google sees only a sealed blob).
// Nothing configured (no `APNS_*`, no ntfy hosts, no FCM files) →
// `LoggingPush`: nothing leaves the server.

use std::sync::Arc;

use async_trait::async_trait;
use sqlx::PgPool;
use tracing::{debug, info, warn};
use uuid::Uuid;

use crate::apns::{Apns, ApnsResult};
use crate::unifiedpush::{UnifiedPush, UnifiedPushConfig};

/// One phone's push token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushTarget {
    pub device_pk: Vec<u8>,
    pub token: String,
    pub sandbox: bool,
    /// The phone's language for the notification text.
    pub lang: String,
    /// UnifiedPush only: the phone's Web Push keys (P-256 public key, auth
    /// secret) — the body is encrypted to them (RFC 8291).
    pub webpush: Option<(Vec<u8>, Vec<u8>)>,
    /// The phone's own 32-byte key: ADR-056 call hints (APNs VoIP tokens),
    /// ADR-057 the key FCM bodies are sealed to (both kinds).
    pub call_hint_key: Option<Vec<u8>>,
}

/// What the push says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushMessage {
    /// "New message" + this badge; ADR-056 — the sender's sealed preview
    /// of the message that woke the phone, if it sent one.
    NewMessage { unread: u32, preview: Option<Vec<u8>> },
    /// ADR-071 (amended) — a message request (a delivery without an access
    /// key) for someone with per-contact keys: no text, no count, no
    /// sound from the server. The phone decides — with its own block list
    /// and the sender in the sealed preview — whether to show one quiet
    /// "New message request" or nothing. iPhone: a background push (never
    /// shown by iOS itself); Android: `{"t":"req"}` wakes the app.
    Request { preview: Option<Vec<u8>> },
    /// Overnight item 9 — a VoIP push: the phone reports this call to
    /// CallKit at once. Only the call id and audio / video: no group, no
    /// caller (the app learns them from the invite after connecting).
    /// ADR-056 — `hint`: [call_hint] under that phone's key.
    /// ADR-071 (amended) — `caller`: the caller's identity key (hex) for
    /// Android, inside its encrypted push only (Google / ntfy see
    /// ciphertext): the phone doesn't ring for someone it blocked. Never
    /// in the iPhone's VoIP push (Apple would read it).
    /// ADR-090 (calls:5) — `proof`: the caller's signature on the invite,
    /// sealed to that phone's key ([seal_call_proof]); the iPhone names the
    /// call only when it checks out.
    IncomingCall { call_id: String, video: bool, hint: Option<String>, caller: Option<String>, proof: Option<String> },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PushOutcome {
    Sent,
    /// Delivered after switching APNs environment — store the right one.
    SentOtherEnvironment,
    /// Dead token — remove it.
    Gone,
    Failed,
}

#[async_trait]
pub trait PushClient: Send + Sync {
    async fn send(&self, target: &PushTarget, msg: &PushMessage) -> PushOutcome;
}

/// Push off: logs that a push would go (no token, no user).
pub struct LoggingPush;

#[async_trait]
impl PushClient for LoggingPush {
    async fn send(&self, _target: &PushTarget, msg: &PushMessage) -> PushOutcome {
        debug!(?msg, "push off — would notify");
        PushOutcome::Sent
    }
}

/// Real delivery: APNs tokens go to Apple, `https://` endpoints to
/// UnifiedPush (Android, ADR-040), `fcm:` tokens to Google (Android,
/// ADR-057). Any may be off.
pub struct RealPush {
    pub apns: Option<Apns>,
    pub up: Option<UnifiedPush>,
    pub fcm: Option<crate::fcm::Fcm>,
}

#[async_trait]
impl PushClient for RealPush {
    async fn send(&self, target: &PushTarget, msg: &PushMessage) -> PushOutcome {
        let result = if crate::fcm::is_token(&target.token) {
            // Off on this server now (files removed): keep the token — the
            // app still has it and FCM may come back.
            let Some(fcm) = &self.fcm else { return PushOutcome::Failed };
            let Some(key) = &target.call_hint_key else { return PushOutcome::Gone };
            let now = time::OffsetDateTime::now_utc().unix_timestamp();
            let mut body = match msg {
                PushMessage::NewMessage { unread, .. } => crate::unifiedpush::message_body(*unread),
                PushMessage::Request { .. } => crate::unifiedpush::request_body(),
                PushMessage::IncomingCall { call_id, video, caller, .. } => {
                    crate::unifiedpush::call_body(call_id, *video, caller.as_deref())
                }
            };
            // The phone ignores a call that comes late (one TTL for both).
            body["ts"] = now.into();
            match crate::fcm::seal(key, &body) {
                Some(sealed) => fcm.send(&target.token, &sealed).await,
                None => ApnsResult::Gone,
            }
        } else if crate::unifiedpush::is_endpoint(&target.token) {
            let Some(up) = &self.up else { return PushOutcome::Gone };
            // No keys (an endpoint from before encryption): drop it — the
            // app registers again, with keys, on its next start.
            let Some((p256dh, auth)) = &target.webpush else { return PushOutcome::Gone };
            let (body, call) = match msg {
                // Android shows its own notifications (ADR-040); previews and
                // hints are for the iPhone's extension.
                PushMessage::NewMessage { unread, .. } => (crate::unifiedpush::message_body(*unread), false),
                PushMessage::Request { .. } => (crate::unifiedpush::request_body(), false),
                PushMessage::IncomingCall { call_id, video, caller, .. } => {
                    (crate::unifiedpush::call_body(call_id, *video, caller.as_deref()), true)
                }
            };
            match crate::webpush::encrypt(p256dh, auth, body.to_string().as_bytes()) {
                Ok(sealed) => up.send(&target.token, sealed, call).await,
                Err(_) => ApnsResult::Gone,
            }
        } else {
            let Some(apns) = &self.apns else { return PushOutcome::Failed };
            let (body, collapse, kind) = match msg {
                // One "New message" per phone, replaced by the next — no count
                // of messages on the lock screen either. With a preview each
                // message is its own notification (the extension groups them
                // by chat on the phone).
                PushMessage::NewMessage { unread, preview } => (
                    crate::apns::alert_body(*unread, &target.lang, preview.as_deref()),
                    if preview.is_some() { None } else { Some("sinhron-new") },
                    crate::apns::ApnsKind::Alert,
                ),
                // Without a preview the phone can't tell who wrote — and so
                // can't rule out someone blocked: nothing to send.
                PushMessage::Request { preview: None } => return PushOutcome::Sent,
                PushMessage::Request { preview: Some(p) } => {
                    (crate::apns::request_body(p), None, crate::apns::ApnsKind::Background)
                }
                PushMessage::IncomingCall { call_id, video, hint, proof, .. } => {
                    (crate::apns::call_body(call_id, *video, hint.as_deref(), proof.as_deref()), None, crate::apns::ApnsKind::Voip)
                }
            };
            match apns.send(&target.token, target.sandbox, kind, &body, collapse).await {
                ApnsResult::WrongEnvironment => {
                    return match apns.send(&target.token, !target.sandbox, kind, &body, collapse).await {
                        ApnsResult::Sent => PushOutcome::SentOtherEnvironment,
                        ApnsResult::Failed(..) => PushOutcome::Failed,
                        ApnsResult::Gone | ApnsResult::WrongEnvironment => PushOutcome::Gone,
                    };
                }
                r => r,
            }
        };
        match result {
            ApnsResult::Sent => PushOutcome::Sent,
            ApnsResult::Gone | ApnsResult::WrongEnvironment => PushOutcome::Gone,
            ApnsResult::Failed(..) => PushOutcome::Failed,
        }
    }
}

/// A token row: device, token, sandbox, lang, Web Push keys, the phone's
/// key (FCM), user.
type PushRow = (Vec<u8>, String, bool, String, Option<Vec<u8>>, Option<Vec<u8>>, Option<Vec<u8>>, Uuid);

/// The configured client: APNs when `APNS_*` is set and the key loads,
/// UnifiedPush when `SINHRON_UNIFIEDPUSH_HOSTS` is set, FCM when both
/// Firebase files are there (`fcm.rs`); none → logging only.
pub fn from_env() -> Arc<dyn PushClient> {
    let apns = match crate::apns::ApnsConfig::from_env() {
        Some(cfg) => Apns::new(cfg).inspect_err(|e| warn!(error = %e, "APNs configured but unusable")).ok(),
        None => {
            info!("APNS_* not set — iOS push notifications off");
            None
        }
    };
    let up_cfg = UnifiedPushConfig::from_env();
    let up = if up_cfg.enabled() { UnifiedPush::new(up_cfg).ok() } else { None };
    let fcm = crate::fcm::FcmConfig::from_env()
        .and_then(|cfg| crate::fcm::Fcm::new(cfg).inspect_err(|e| warn!(error = %e, "FCM configured but unusable")).ok());
    if apns.is_none() && up.is_none() && fcm.is_none() {
        return Arc::new(LoggingPush);
    }
    Arc::new(RealPush { apns, up, fcm })
}

/// ADR-056 — largest preview passed on (the app's are 689 bytes); a bigger
/// one is dropped, the push still goes.
pub const MAX_PREVIEW: usize = 1024;

/// Someone to wake, with the sealed preview of the message that woke them.
pub type Wake = (Uuid, Option<Vec<u8>>);

/// Add [user] to [wake] once (the first preview wins).
pub fn add_wake(wake: &mut Vec<Wake>, user: Uuid, preview: &[u8]) {
    if wake.iter().any(|(u, _)| *u == user) {
        return;
    }
    let preview = (!preview.is_empty() && preview.len() <= MAX_PREVIEW).then(|| preview.to_vec());
    wake.push((user, preview));
}

/// ADR-056 — what a call push says about the chat: HMAC-SHA256(phone's
/// key, "sinhron-call-hint-v1" ‖ call id ‖ group id), 16 bytes, hex. A
/// different value every call, so Apple can't link calls of one chat; the
/// phone tries its chats to find the one that matches.
pub fn call_hint(key: &[u8], call_id: &str, group_id: &[u8]) -> Option<String> {
    use hmac::{Hmac, Mac};
    let mut mac = Hmac::<sha2::Sha256>::new_from_slice(key).ok()?;
    mac.update(b"sinhron-call-hint-v1");
    mac.update(call_id.as_bytes());
    mac.update(group_id);
    Some(hex::encode(&mac.finalize().into_bytes()[..16]))
}

/// ADR-090 (calls:5) — the caller's [proof] for one phone's VoIP push:
/// base64(nonce ‖ AES-256-GCM(phone's key, u8 len ‖ proof ‖ zeros to
/// [MAX_CALL_PROOF] + 1), aad `sinhron-call-proof-v1`). Every one the same
/// size, and Apple can't read who calls (the credential names the person).
pub fn seal_call_proof(key: &[u8], proof: &[u8]) -> Option<String> {
    use aes_gcm::aead::{Aead, KeyInit, Payload};
    use base64::Engine;
    if proof.is_empty() || proof.len() > MAX_CALL_PROOF {
        return None;
    }
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(key).ok()?;
    let mut plain = vec![proof.len() as u8];
    plain.extend_from_slice(proof);
    plain.resize(1 + MAX_CALL_PROOF, 0);
    let nonce: [u8; 12] = rand::random();
    let mut out = nonce.to_vec();
    out.extend(cipher.encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &plain, aad: CALL_PROOF_AAD }).ok()?);
    Some(base64::engine::general_purpose::STANDARD.encode(out))
}

/// What the phone does with [seal_call_proof] (`CallProof.caller` in
/// `ios/Shared/PushShared.swift`) — for tests.
#[cfg(test)]
pub fn open_call_proof(key: &[u8], sealed: &str) -> Option<Vec<u8>> {
    use aes_gcm::aead::{Aead, KeyInit, Payload};
    use base64::Engine;
    let b = base64::engine::general_purpose::STANDARD.decode(sealed).ok()?;
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(key).ok()?;
    let plain = cipher.decrypt(aes_gcm::Nonce::from_slice(b.get(..12)?), Payload { msg: &b[12..], aad: CALL_PROOF_AAD }).ok()?;
    plain.get(1..1 + *plain.first()? as usize).map(<[u8]>::to_vec)
}

/// ADR-090 — the longest caller proof: ts + signature + device certificate.
pub const MAX_CALL_PROOF: usize = 8 + 64 + 132;
/// ADR-090 — the shortest: ts + signature + identity key.
pub const MIN_CALL_PROOF: usize = 8 + 64 + 32;
const CALL_PROOF_AAD: &[u8] = b"sinhron-call-proof-v1";

/// Wake [wake] (they had no live connection when an urgent delivery
/// arrived): every active phone with an alert token gets "New message" and
/// the count of urgent deliveries it hasn't received yet. Dead tokens go.
pub async fn notify_offline(pool: &PgPool, push: &dyn PushClient, wake: &[Wake]) -> anyhow::Result<usize> {
    notify(pool, push, wake, false, false).await
}

/// ADR-071 (amended) — [wake] got a message request (no access key): a
/// [PushMessage::Request] to each phone — [only_fcm] for connected people
/// (status 167). The phone decides whether anything shows.
pub async fn notify_request(pool: &PgPool, push: &dyn PushClient, wake: &[Wake], only_fcm: bool) -> anyhow::Result<usize> {
    notify(pool, push, wake, only_fcm, true).await
}

/// Status 167 — [wake] had a live connection, but an Android phone can
/// hold one the app no longer reads (Sinhron swiped away, the "always
/// connected" socket still up): the message never shows. Its Google push
/// (`fcm:` tokens only) goes anyway; the app drops a "new message" push
/// while it is on screen.
pub async fn notify_android_live(pool: &PgPool, push: &dyn PushClient, wake: &[Wake]) -> anyhow::Result<usize> {
    notify(pool, push, wake, true, false).await
}

async fn notify(pool: &PgPool, push: &dyn PushClient, wake: &[Wake], only_fcm: bool, request: bool) -> anyhow::Result<usize> {
    if wake.is_empty() {
        return Ok(0);
    }
    let users: Vec<Uuid> = wake.iter().map(|(u, _)| *u).collect();
    let rows: Vec<PushRow> = sqlx::query_as(
        "SELECT t.device_pk, t.token, t.sandbox, t.lang, t.webpush_p256dh, t.webpush_auth, t.call_hint_key, d.user_pk FROM apns_tokens t \
         JOIN devices d ON d.device_pk = t.device_pk \
         WHERE d.user_pk = ANY($1) AND d.revoked_at IS NULL AND t.kind = 'alert' AND (NOT $2 OR t.token LIKE 'fcm:%')",
    )
    .bind(&users)
    .bind(only_fcm)
    .fetch_all(pool)
    .await?;
    let (mut sent, mut gone, mut failed) = (0usize, 0usize, 0usize);
    for (device_pk, token, sandbox, lang, p256dh, auth, call_hint_key, user) in rows {
        let target = PushTarget { device_pk, token, sandbox, lang, webpush: p256dh.zip(auth), call_hint_key };
        let preview = wake.iter().find(|(u, _)| *u == user).and_then(|(_, p)| p.clone());
        let msg = if request {
            PushMessage::Request { preview }
        } else {
            let (unread,): (i64,) = sqlx::query_as(
                "SELECT COUNT(*) FROM message_deliveries WHERE recipient_user_pk = $1 AND received_at IS NULL AND urgent",
            )
            .bind(user)
            .fetch_one(pool)
            .await?;
            PushMessage::NewMessage { unread: unread.clamp(0, u32::MAX as i64) as u32, preview }
        };
        let outcome = push.send(&target, &msg).await;
        record(pool, &target, &outcome).await?;
        match outcome {
            PushOutcome::Sent | PushOutcome::SentOtherEnvironment => sent += 1,
            PushOutcome::Gone => gone += 1,
            PushOutcome::Failed => failed += 1,
        }
    }
    crate::metrics::PUSH_SENT_TOTAL.inc_by(sent as u64);
    // Counts only — no user, no token (diagnosing "the push didn't come").
    info!(people = users.len(), sent, gone, failed, android_live = only_fcm, request, "message push");
    Ok(sent)
}

/// Keep the token table right after a push: a dead token goes, a token
/// that turned out to be of the other APNs environment is flipped.
async fn record(pool: &PgPool, target: &PushTarget, outcome: &PushOutcome) -> anyhow::Result<()> {
    match outcome {
        PushOutcome::Gone => {
            sqlx::query("DELETE FROM apns_tokens WHERE device_pk = $1 AND token = $2")
                .bind(&target.device_pk)
                .bind(&target.token)
                .execute(pool)
                .await?;
        }
        PushOutcome::SentOtherEnvironment => {
            sqlx::query("UPDATE apns_tokens SET sandbox = NOT sandbox WHERE device_pk = $1 AND token = $2")
                .bind(&target.device_pk)
                .bind(&target.token)
                .execute(pool)
                .await?;
        }
        PushOutcome::Sent | PushOutcome::Failed => {}
    }
    Ok(())
}

/// Status 167 — the Google (`fcm:`) call tokens of [users] who are
/// connected: an Android phone can hold a socket the app no longer reads,
/// and a call sent down it never rings. The app rings once per call id.
pub async fn fcm_call_targets(pool: &PgPool, users: &[Uuid]) -> anyhow::Result<Vec<PushTarget>> {
    Ok(voip_targets(pool, users).await?.into_iter().filter(|t| crate::fcm::is_token(&t.token)).collect())
}

/// Callees with the app open on some device: their Google call tokens
/// (status 167) and the VoIP tokens of their devices **not** connected now
/// — a locked iPhone rings while the iPad is open (2026-10-26).
pub async fn call_targets_for_connected(pool: &PgPool, users: &[Uuid], connected: &[Vec<u8>]) -> anyhow::Result<Vec<PushTarget>> {
    Ok(voip_targets(pool, users)
        .await?
        .into_iter()
        .filter(|t| crate::fcm::is_token(&t.token) || !connected.contains(&t.device_pk))
        .collect())
}

/// Overnight item 9 — VoIP tokens of [users]' active devices.
pub async fn voip_targets(pool: &PgPool, users: &[Uuid]) -> anyhow::Result<Vec<PushTarget>> {
    if users.is_empty() {
        return Ok(Vec::new());
    }
    type VoipRow = (Vec<u8>, String, bool, String, Option<Vec<u8>>, Option<Vec<u8>>, Option<Vec<u8>>);
    let rows: Vec<VoipRow> = sqlx::query_as(
        "SELECT t.device_pk, t.token, t.sandbox, t.lang, t.webpush_p256dh, t.webpush_auth, t.call_hint_key FROM apns_tokens t \
         JOIN devices d ON d.device_pk = t.device_pk \
         WHERE d.user_pk = ANY($1) AND d.revoked_at IS NULL AND t.kind = 'voip'",
    )
    .bind(users)
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|(device_pk, token, sandbox, lang, p256dh, auth, call_hint_key)| PushTarget {
            device_pk,
            token,
            sandbox,
            lang,
            webpush: p256dh.zip(auth),
            call_hint_key,
        })
        .collect())
}

/// Ring [targets] through PushKit in the background; dead tokens go.
/// [group_id] only goes into each phone's hint (ADR-056), never as is.
pub fn spawn_call(
    pool: PgPool,
    push: Arc<dyn PushClient>,
    targets: Vec<PushTarget>,
    call_id: String,
    video: bool,
    group_id: Vec<u8>,
    caller_identity: Vec<u8>,
    caller_proof: Vec<u8>,
) {
    if targets.is_empty() {
        return;
    }
    tokio::spawn(async move {
        let n = targets.len();
        let mut sent = 0;
        for t in targets {
            let hint = t.call_hint_key.as_deref().and_then(|k| call_hint(k, &call_id, &group_id));
            let caller = (!caller_identity.is_empty()).then(|| hex::encode(&caller_identity));
            let proof = t.call_hint_key.as_deref().and_then(|k| seal_call_proof(k, &caller_proof));
            let msg = PushMessage::IncomingCall { call_id: call_id.clone(), video, hint, caller, proof };
            let outcome = push.send(&t, &msg).await;
            let _ = record(&pool, &t, &outcome).await;
            if matches!(outcome, PushOutcome::Sent | PushOutcome::SentOtherEnvironment) {
                sent += 1;
                crate::metrics::PUSH_SENT_TOTAL.inc();
            }
        }
        info!(phones = n, sent, "call push");
    });
}

/// [notify_offline] in the background — the sender's WS handler doesn't
/// wait for Apple.
pub fn spawn_notify(pool: PgPool, push: Arc<dyn PushClient>, wake: Vec<Wake>) {
    if wake.is_empty() {
        return;
    }
    tokio::spawn(async move {
        if let Err(e) = notify_offline(&pool, push.as_ref(), &wake).await {
            warn!(error = %e, "push failed");
        }
    });
}

/// [notify_request] in the background: [wake] offline, [live] connected
/// (Google push only).
pub fn spawn_request(pool: PgPool, push: Arc<dyn PushClient>, wake: Vec<Wake>, live: Vec<Wake>) {
    if wake.is_empty() && live.is_empty() {
        return;
    }
    tokio::spawn(async move {
        for (w, only_fcm) in [(wake, false), (live, true)] {
            if let Err(e) = notify_request(&pool, push.as_ref(), &w, only_fcm).await {
                warn!(error = %e, "request push failed");
            }
        }
    });
}

/// [notify_android_live] in the background.
pub fn spawn_notify_android_live(pool: PgPool, push: Arc<dyn PushClient>, wake: Vec<Wake>) {
    if wake.is_empty() {
        return;
    }
    tokio::spawn(async move {
        if let Err(e) = notify_android_live(&pool, push.as_ref(), &wake).await {
            warn!(error = %e, "push failed");
        }
    });
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::sync::Mutex;

    /// Records what would be sent; answers Gone for tokens starting "dead".
    #[derive(Default)]
    pub struct RecordingPush(pub Mutex<Vec<(String, bool, PushMessage)>>);

    #[async_trait]
    impl PushClient for RecordingPush {
        async fn send(&self, target: &PushTarget, msg: &PushMessage) -> PushOutcome {
            self.0.lock().unwrap().push((target.token.clone(), target.sandbox, msg.clone()));
            if target.token.starts_with("dead") { PushOutcome::Gone } else { PushOutcome::Sent }
        }
    }

    /// Bug 2026-10-16 — an Xcode build's sandbox token sent to production
    /// (or the reverse) gets BadDeviceToken: the other environment is tried
    /// and the push still arrives.
    #[tokio::test]
    async fn a_token_of_the_other_environment_still_gets_its_push() {
        use axum::{Router, http::StatusCode, routing::post};
        async fn serve(status: StatusCode, body: &'static str) -> String {
            let app = Router::new().route("/3/device/{token}", post(move || async move { (status, body) }));
            let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = l.local_addr().unwrap();
            tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
            format!("http://{addr}")
        }
        let prod = serve(StatusCode::BAD_REQUEST, r#"{"reason":"BadDeviceToken"}"#).await;
        let sandbox = serve(StatusCode::OK, "").await;
        let key = p256::ecdsa::SigningKey::from_slice(&[5u8; 32]).unwrap();
        let cfg = crate::apns::ApnsConfig { key_path: String::new(), key_id: "K".into(), team_id: "T".into(), topic: "t".into() };
        let push = RealPush { apns: Some(Apns::with_key(cfg, key, (prod, sandbox))), up: None, fcm: None };
        let target = PushTarget {
            device_pk: vec![1],
            token: "ab".repeat(32),
            sandbox: false,
            lang: "ru".into(),
            webpush: None,
            call_hint_key: None,
        };
        let msg = PushMessage::NewMessage { unread: 1, preview: None };
        assert_eq!(push.send(&target, &msg).await, PushOutcome::SentOtherEnvironment);
        let sandbox_target = PushTarget { sandbox: true, ..target };
        assert_eq!(push.send(&sandbox_target, &msg).await, PushOutcome::Sent);
    }

    /// ADR-090 (calls:5) — the caller's proof opens with the phone's key only,
    /// every sealed proof is one size (Apple can't tell a linked device from
    /// a first one), and a proof the caller didn't send (too long) isn't sealed.
    #[test]
    fn the_callers_proof_reaches_only_that_phone() {
        let short = [1u8; MIN_CALL_PROOF];
        let long = [2u8; MAX_CALL_PROOF];
        let a = seal_call_proof(&[7u8; 32], &short).unwrap();
        let b = seal_call_proof(&[7u8; 32], &long).unwrap();
        assert_eq!(a.len(), b.len());
        assert_eq!(open_call_proof(&[7u8; 32], &a), Some(short.to_vec()));
        assert_eq!(open_call_proof(&[7u8; 32], &b), Some(long.to_vec()));
        assert_eq!(open_call_proof(&[8u8; 32], &a), None, "another phone's key");
        assert_eq!(seal_call_proof(&[7u8; 32], &[0u8; MAX_CALL_PROOF + 1]), None);
        assert_eq!(seal_call_proof(&[7u8; 32], &[]), None);
    }

    /// ADR-056 — the same value the phone computes
    /// (`ios/SharedTests/main.swift`); another call, another value.
    #[test]
    fn call_hint_matches_the_phone() {
        let key = [7u8; 32];
        let h = call_hint(&key, "call-1", &[0xab; 16]).unwrap();
        assert_eq!(h, "d01a62f01da1971496ea8b436e0aba67");
        assert_ne!(call_hint(&key, "call-2", &[0xab; 16]).unwrap(), h);
        assert_ne!(call_hint(&[8u8; 32], "call-1", &[0xab; 16]).unwrap(), h);
    }

    #[test]
    fn one_wake_per_person_and_oversized_previews_are_dropped() {
        let (a, b) = (Uuid::now_v7(), Uuid::now_v7());
        let mut wake = Vec::new();
        add_wake(&mut wake, a, &[1, 2]);
        add_wake(&mut wake, a, &[3]);
        add_wake(&mut wake, b, &vec![0u8; MAX_PREVIEW + 1]);
        add_wake(&mut wake, Uuid::now_v7(), &[]);
        assert_eq!(wake[0], (a, Some(vec![1, 2])));
        assert_eq!(wake[1], (b, None));
        assert_eq!(wake[2].1, None);
        assert_eq!(wake.len(), 3);
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn offline_people_get_new_message_with_their_badge_and_dead_tokens_go(pool: sqlx::PgPool) {
        let u = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(vec![1u8; 32]).execute(&pool).await.unwrap();
        let (live, dead) = ("aa11".repeat(16), format!("dead{}", "22".repeat(30)));
        for (pk, token, sandbox) in [(vec![1u8; 32], live.clone(), true), (vec![2u8; 32], dead.clone(), false)] {
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO apns_tokens (device_pk, kind, token, sandbox) VALUES ($1, 'alert', $2, $3)")
                .bind(&pk)
                .bind(&token)
                .bind(sandbox)
                .execute(&pool)
                .await
                .unwrap();
        }
        // Two urgent deliveries waiting, one receipt (not urgent), one already received.
        for (urgent, received) in [(true, false), (true, false), (false, false), (true, true)] {
            sqlx::query(
                "INSERT INTO message_deliveries (recipient_user_pk, message_id, urgent, received_at) \
                 VALUES ($1, $2, $3, CASE WHEN $4 THEN NOW() END)",
            )
            .bind(u)
            .bind(Uuid::now_v7())
            .bind(urgent)
            .bind(received)
            .execute(&pool)
            .await
            .unwrap();
        }
        let push = RecordingPush::default();
        assert_eq!(notify_offline(&pool, &push, &[(u, Some(vec![7u8; 689]))]).await.unwrap(), 1);
        let mut got = push.0.lock().unwrap().clone();
        got.sort_by(|a, b| a.0.cmp(&b.0));
        assert_eq!(
            got,
            vec![
                (live, true, PushMessage::NewMessage { unread: 2, preview: Some(vec![7u8; 689]) }),
                (dead, false, PushMessage::NewMessage { unread: 2, preview: Some(vec![7u8; 689]) }),
            ]
        );
        let (left,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM apns_tokens").fetch_one(&pool).await.unwrap();
        assert_eq!(left, 1, "the dead token is forgotten");
    }
    /// Status 167 — Sinhron swiped away on Android left a socket up that
    /// nothing read: messages and calls sent down it never showed. A
    /// connected person's Google (`fcm:`) tokens get the push anyway; their
    /// iPhone (APNs) and ntfy tokens don't — those apps read their socket.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn connected_android_phones_still_get_their_google_push(pool: sqlx::PgPool) {
        let u = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(vec![1u8; 32]).execute(&pool).await.unwrap();
        let fcm = format!("fcm:{}", "a".repeat(40));
        let apns = "bb22".repeat(16);
        for (pk, token, kind) in [
            (vec![1u8; 32], fcm.clone(), "alert"),
            (vec![1u8; 32], fcm.clone(), "voip"),
            (vec![2u8; 32], apns.clone(), "alert"),
            (vec![2u8; 32], apns.clone(), "voip"),
        ] {
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1) ON CONFLICT DO NOTHING")
                .bind(&pk)
                .bind(u)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO apns_tokens (device_pk, kind, token, sandbox, call_hint_key) VALUES ($1, $2, $3, false, $4)")
                .bind(&pk)
                .bind(kind)
                .bind(&token)
                .bind(token.starts_with("fcm:").then(|| vec![9u8; 32]))
                .execute(&pool)
                .await
                .unwrap();
        }
        let push = RecordingPush::default();
        assert_eq!(notify_android_live(&pool, &push, &[(u, None)]).await.unwrap(), 1);
        let got: Vec<String> = push.0.lock().unwrap().iter().map(|(t, _, _)| t.clone()).collect();
        assert_eq!(got, vec![fcm.clone()], "only the Google token of a connected person");
        let calls: Vec<String> = fcm_call_targets(&pool, &[u]).await.unwrap().into_iter().map(|t| t.token).collect();
        assert_eq!(calls, vec![fcm.clone()], "a call rings a connected person's Android phone through Google, not the iPhone");

        // 2026-10-26 — the iPhone (device 2) isn't connected (the person's
        // other device is): its VoIP token rings it; once it is connected, not.
        let mut targets: Vec<String> =
            call_targets_for_connected(&pool, &[u], &[vec![1u8; 32]]).await.unwrap().into_iter().map(|t| t.token).collect();
        targets.sort();
        let mut want = vec![fcm.clone(), apns.clone()];
        want.sort();
        assert_eq!(targets, want, "a locked iPhone rings while another device is open");
        let targets: Vec<String> = call_targets_for_connected(&pool, &[u], &[vec![1u8; 32], vec![2u8; 32]])
            .await
            .unwrap()
            .into_iter()
            .map(|t| t.token)
            .collect();
        assert_eq!(targets, vec![fcm], "the connected iPhone gets the call on its socket");
    }
}
