// Push tokens — overnight item 8 (alert) / item 9 (VoIP).
//
//     PUT /v1/push-token   (token: APNs hex, or — Android, ADR-040 — an
//                           allowlisted UnifiedPush `https://` endpoint, or
//                           — Android, ADR-057 — `fcm:` + a Google token)
//     { device_pk_hex, kind: "alert" | "voip", token_hex, sandbox, lang,
//       p256dh?, auth?, call_hint_key_hex?, proof_ts, proof_hex }
//
// Signed by the device's own key (the key it logs in with — the identity
// key on the first device) over `kind ‖ 0 ‖ token ‖ sandbox ‖ lang`, then
// `‖ 0 ‖ p256dh ‖ 0 ‖ auth` when the keys are there, `‖ 1 ‖ call_hint_key_hex`
// when that is (ADR-056: a PushKit token's 32-byte key — call pushes carry
// HMAC(key, call ‖ chat) so the phone names the caller before it connects;
// the key is the phone's own, so Apple can't match hints across phones).
// ADR-057: an `fcm:` token must come with `call_hint_key_hex` for either
// kind — there it is the phone's own 32-byte key FCM bodies are sealed to
// (Google sees only the sealed blob; `fcm.rs`).
// An endpoint must come
// with the phone's Web Push keys (base64url: 65-byte P-256 public key,
// 16-byte auth secret) — its pushes are encrypted to them (RFC 8291). `lang`
// (two letters) picks the notification's words. An empty
// token removes the device's token of that kind (notifications switched
// off). A token another device had registered moves to this one (the app
// was reinstalled for another account). 204.
//
//     GET /v1/push/info    (public, no login)
//     { "unifiedpush_hosts": ["push.example.org"],
//       "fcm": { project_id, app_id, api_key, sender_id } | null }
//
// Which push server the Android app should tell people to add in the ntfy
// app (it defaults to ntfy.sh, whose endpoints this server refuses). Empty
// list: UnifiedPush off on this server. The hosts are already public — they
// are the operator's DNS names. `fcm` (ADR-057): this server's Firebase
// project, for the app to register with Google push — only when the server
// can send FCM. Not secret: every Firebase app ships these ids in its APK.

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use serde::Deserialize;
use time::OffsetDateTime;
use tracing::{error, info};

use super::proof::{self, PUSH_TOKEN_DOMAIN};
use crate::AppState;

/// LIMIT-2 — PUTs per device: 600 an hour. The app sends both tokens (alert
/// and VoIP) on every connect, so a bad link must not run it dry.
static PUT_PER_DEVICE: crate::rate_limit::StaticLimiter = crate::rate_limit::StaticLimiter::new("SINHRON_RATE_PUSH_TOKEN", 600, 3_600);

#[derive(Debug, Deserialize)]
pub struct PushTokenRequest {
    pub device_pk_hex: String,
    pub kind: String,
    pub token_hex: String,
    #[serde(default)]
    pub sandbox: bool,
    #[serde(default = "default_lang")]
    pub lang: String,
    /// UnifiedPush only: the phone's Web Push keys, base64url.
    #[serde(default)]
    pub p256dh: Option<String>,
    #[serde(default)]
    pub auth: Option<String>,
    /// ADR-056 — VoIP (APNs) tokens: the call hint key; ADR-057 — FCM
    /// tokens (both kinds): the key pushes are sealed to. 32 bytes, hex.
    #[serde(default)]
    pub call_hint_key_hex: Option<String>,
    pub proof_ts: i64,
    pub proof_hex: String,
}

fn default_lang() -> String {
    "en".to_string()
}

/// What the signature covers.
pub fn token_body(
    kind: &str,
    token_hex: &str,
    sandbox: bool,
    lang: &str,
    keys: Option<(&str, &str)>,
    call_hint_key_hex: Option<&str>,
) -> Vec<u8> {
    let mut b = kind.as_bytes().to_vec();
    b.push(0);
    b.extend_from_slice(token_hex.as_bytes());
    b.push(sandbox as u8);
    b.extend_from_slice(lang.as_bytes());
    if let Some((p256dh, auth)) = keys {
        b.push(0);
        b.extend_from_slice(p256dh.as_bytes());
        b.push(0);
        b.extend_from_slice(auth.as_bytes());
    }
    if let Some(h) = call_hint_key_hex {
        b.push(1);
        b.extend_from_slice(h.as_bytes());
    }
    b
}

/// Base64url (padding optional) of exactly [len] bytes.
fn b64url(s: &str, len: usize) -> Option<Vec<u8>> {
    use base64::Engine;
    let v = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s.trim_end_matches('=')).ok()?;
    (v.len() == len).then_some(v)
}

#[derive(Debug, thiserror::Error)]
pub enum PushTokenError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("too many requests")]
    RateLimited,
    #[error("no db configured")]
    NoDb,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
}

impl IntoResponse for PushTokenError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            PushTokenError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            PushTokenError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            PushTokenError::RateLimited => (StatusCode::TOO_MANY_REQUESTS, "too many push-token updates".to_string()),
            PushTokenError::NoDb => (StatusCode::SERVICE_UNAVAILABLE, "no database configured".to_string()),
            PushTokenError::Db(e) => {
                error!(error = %e, "db error in push-token handler");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

pub async fn info() -> Json<serde_json::Value> {
    // Read once: a public endpoint must not re-read (or re-log) the files.
    static FCM: once_cell::sync::Lazy<Option<crate::fcm::ClientConfig>> =
        once_cell::sync::Lazy::new(crate::fcm::FcmConfig::client_from_env);
    info_with(&crate::unifiedpush::UnifiedPushConfig::from_env(), FCM.as_ref())
}

/// [info] with the allowlist and Firebase ids given (tests set them).
pub fn info_with(
    unifiedpush: &crate::unifiedpush::UnifiedPushConfig,
    fcm: Option<&crate::fcm::ClientConfig>,
) -> Json<serde_json::Value> {
    Json(serde_json::json!({ "unifiedpush_hosts": unifiedpush.hosts, "fcm": fcm }))
}

pub async fn put(State(state): State<AppState>, Json(req): Json<PushTokenRequest>) -> Result<StatusCode, PushTokenError> {
    put_with(state, req, &crate::unifiedpush::UnifiedPushConfig::from_env()).await
}

/// [put] with the operator's UnifiedPush allowlist given (tests set one).
pub async fn put_with(
    state: AppState,
    req: PushTokenRequest,
    unifiedpush: &crate::unifiedpush::UnifiedPushConfig,
) -> Result<StatusCode, PushTokenError> {
    let pool = state.pool.clone().ok_or(PushTokenError::NoDb)?;
    if !matches!(req.kind.as_str(), "alert" | "voip") {
        return Err(PushTokenError::BadRequest("kind must be alert or voip".into()));
    }
    // ADR-040 — an Android phone's UnifiedPush endpoint instead of an APNs
    // token: only `https://` on the operator's allowlisted hosts.
    let endpoint = crate::unifiedpush::is_endpoint(&req.token_hex);
    let fcm = crate::fcm::is_token(&req.token_hex);
    let token = if endpoint || fcm { req.token_hex.clone() } else { req.token_hex.to_ascii_lowercase() };
    let keys = match (req.p256dh.as_deref(), req.auth.as_deref()) {
        (Some(p), Some(a)) => Some((p, a)),
        (None, None) => None,
        _ => return Err(PushTokenError::BadRequest("p256dh and auth go together".into())),
    };
    let mut webpush: Option<(Vec<u8>, Vec<u8>)> = None;
    if endpoint {
        if !unifiedpush.allows(&token) {
            return Err(PushTokenError::BadRequest("UnifiedPush endpoint not allowed on this server".into()));
        }
        let (p, a) = keys.ok_or_else(|| PushTokenError::BadRequest("an endpoint needs p256dh and auth".into()))?;
        let (Some(p), Some(a)) = (b64url(p, 65), b64url(a, 16)) else {
            return Err(PushTokenError::BadRequest("p256dh / auth: bad base64url or length".into()));
        };
        if p256::PublicKey::from_sec1_bytes(&p).is_err() {
            return Err(PushTokenError::BadRequest("p256dh is not a P-256 point".into()));
        }
        webpush = Some((p, a));
    } else if keys.is_some() {
        return Err(PushTokenError::BadRequest("p256dh / auth only with an endpoint".into()));
    } else if fcm {
        if !crate::fcm::valid_token(&token) {
            return Err(PushTokenError::BadRequest("fcm token: 20..400 of [A-Za-z0-9_:-]".into()));
        }
    } else if !token.is_empty()
        && (token.len() < 32 || token.len() > 200 || !token.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err(PushTokenError::BadRequest("token must be 32..200 hex or an https endpoint".into()));
    }
    let call_hint_key = match req.call_hint_key_hex.as_deref() {
        None if fcm => return Err(PushTokenError::BadRequest("an fcm token needs call_hint_key_hex (its key)".into())),
        None => None,
        Some(h) => match hex::decode(h) {
            Ok(k) if k.len() == 32 && ((req.kind == "voip" && !endpoint) || fcm) => Some(k),
            _ => return Err(PushTokenError::BadRequest("call_hint_key_hex: 32 bytes hex, VoIP or fcm tokens only".into())),
        },
    };
    if req.lang.len() != 2 || !req.lang.bytes().all(|b| b.is_ascii_lowercase()) {
        return Err(PushTokenError::BadRequest("lang must be two lowercase letters".into()));
    }
    let device = hex::decode(&req.device_pk_hex).map_err(|e| PushTokenError::BadRequest(format!("device: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| PushTokenError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        PUSH_TOKEN_DOMAIN,
        &device,
        &token_body(&req.kind, &req.token_hex, req.sandbox, &req.lang, keys, req.call_hint_key_hex.as_deref()),
        req.proof_ts,
        &sig,
        OffsetDateTime::now_utc().unix_timestamp(),
    )
    .map_err(|e| PushTokenError::Unauthorized(e.to_string()))?;
    let active: Option<(i32,)> = sqlx::query_as("SELECT 1 FROM devices WHERE device_pk = $1 AND revoked_at IS NULL")
        .bind(&device)
        .fetch_optional(&pool)
        .await?;
    if active.is_none() {
        return Err(PushTokenError::Unauthorized("unknown or revoked device".into()));
    }
    // LIMIT-2 — each request is a write transaction and there was no limit.
    // Keyed by the parsed key, not the request's spelling ("AB…" and "ab…"
    // are one device).
    if PUT_PER_DEVICE.check(&hex::encode(&device)).is_err() {
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["push_token"]).inc();
        return Err(PushTokenError::RateLimited);
    }
    let mut tx = pool.begin().await?;
    // server-http:14 / critic:6 — the token moves only within my account (a
    // reinstall, a new phone) or off a revoked device. Whoever knew another
    // person's token took it away from their phone by registering it: no
    // more pushes, no ringing calls. Another account keeps its own row.
    sqlx::query(
        "DELETE FROM apns_tokens WHERE kind = $2 AND (device_pk = $1 OR (token = $3 AND device_pk IN ( \
             SELECT device_pk FROM devices \
             WHERE revoked_at IS NOT NULL OR user_pk = (SELECT user_pk FROM devices WHERE device_pk = $1))))",
    )
        .bind(&device)
        .bind(&req.kind)
        .bind(&token)
        .execute(&mut *tx)
        .await?;
    if !token.is_empty() {
        let (p256dh, auth) = webpush.unzip();
        sqlx::query(
            "INSERT INTO apns_tokens (device_pk, kind, token, sandbox, lang, webpush_p256dh, webpush_auth, call_hint_key) \
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
        )
        .bind(&device)
        .bind(&req.kind)
        .bind(&token)
        .bind(req.sandbox)
        .bind(&req.lang)
        .bind(p256dh)
        .bind(auth)
        .bind(call_hint_key)
        .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    info!(kind = %req.kind, registered = !token.is_empty(), sandbox = req.sandbox, "push token updated");
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use sha2::{Digest, Sha256};

    fn state(pool: sqlx::PgPool) -> AppState {
        AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    #[test]
    fn info_names_the_allowed_push_hosts() {
        let cfg = crate::unifiedpush::UnifiedPushConfig::from_value(Some(" Push.Example.org., ntfy.example.net"));
        assert_eq!(
            info_with(&cfg, None).0,
            serde_json::json!({ "unifiedpush_hosts": ["push.example.org", "ntfy.example.net"], "fcm": null })
        );
        let off = crate::unifiedpush::UnifiedPushConfig::from_value(None);
        assert_eq!(info_with(&off, None).0, serde_json::json!({ "unifiedpush_hosts": [], "fcm": null }));
        // ADR-057 — the Firebase ids the app registers with.
        let fcm = crate::fcm::ClientConfig {
            project_id: "p".into(),
            app_id: "1:2:android:3".into(),
            api_key: "AIza".into(),
            sender_id: "2".into(),
        };
        assert_eq!(
            info_with(&off, Some(&fcm)).0["fcm"],
            serde_json::json!({ "project_id": "p", "app_id": "1:2:android:3", "api_key": "AIza", "sender_id": "2" })
        );
    }

    fn req(sk: &SigningKey, kind: &str, token: &str, sandbox: bool) -> PushTokenRequest {
        req_keys(sk, kind, token, sandbox, None)
    }

    fn req_keys(sk: &SigningKey, kind: &str, token: &str, sandbox: bool, keys: Option<(&str, &str)>) -> PushTokenRequest {
        req_full(sk, kind, token, sandbox, keys, None)
    }

    fn req_full(
        sk: &SigningKey,
        kind: &str,
        token: &str,
        sandbox: bool,
        keys: Option<(&str, &str)>,
        hint: Option<&str>,
    ) -> PushTokenRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = PUSH_TOKEN_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(token_body(kind, token, sandbox, "ru", keys, hint)));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        PushTokenRequest {
            device_pk_hex: hex::encode(sk.verifying_key().to_bytes()),
            kind: kind.into(),
            token_hex: token.into(),
            sandbox,
            lang: "ru".into(),
            p256dh: keys.map(|k| k.0.to_string()),
            auth: keys.map(|k| k.1.to_string()),
            call_hint_key_hex: hint.map(str::to_string),
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    /// LIMIT-2 — the route had no request limit: one device could keep
    /// write transactions going without end.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_device_cannot_rewrite_its_token_without_end(pool: sqlx::PgPool) {
        // Keys no other test uses: the limiter is one per process.
        let (a, b) = (SigningKey::from_bytes(&[0xD7u8; 32]), SigningKey::from_bytes(&[0xD8u8; 32]));
        for sk in [&a, &b] {
            let u = uuid::Uuid::now_v7();
            let pk = sk.verifying_key().to_bytes().to_vec();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
        }
        let st = state(pool);
        let tok = "ab".repeat(32);
        let again = || req(&a, "alert", &tok, true);
        // Both tokens on each of a hundred reconnects in an hour go through.
        for _ in 0..200 {
            assert_eq!(put(State(st.clone()), Json(again())).await.unwrap(), StatusCode::NO_CONTENT);
        }
        // The rest of the hour's 600, without the database.
        let key = hex::encode(a.verifying_key().to_bytes());
        for _ in 200..600 {
            assert!(PUT_PER_DEVICE.check(&key).is_ok());
        }
        let refused = put(State(st.clone()), Json(again())).await.unwrap_err();
        assert_eq!(refused.into_response().status(), StatusCode::TOO_MANY_REQUESTS);
        // The same key spelled in capitals is the same device.
        let mut caps = again();
        caps.device_pk_hex = caps.device_pk_hex.to_uppercase();
        let refused = put(State(st.clone()), Json(caps)).await.unwrap_err();
        assert_eq!(refused.into_response().status(), StatusCode::TOO_MANY_REQUESTS);
        // Another device, and my own KeyPackage uploads and calls, are not held back.
        assert_eq!(put(State(st.clone()), Json(req(&b, "alert", &"cd".repeat(32), true))).await.unwrap(), StatusCode::NO_CONTENT);
        assert!(st.rate.check_kp_upload(&again().device_pk_hex).is_ok());
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_device_registers_moves_and_removes_its_token(pool: sqlx::PgPool) {
        let a = SigningKey::from_bytes(&[71u8; 32]);
        let b = SigningKey::from_bytes(&[72u8; 32]);
        for sk in [&a, &b] {
            let u = uuid::Uuid::now_v7();
            let pk = sk.verifying_key().to_bytes().to_vec();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
        }
        let tok = "ab".repeat(32);
        let rows = || {
            let pool = pool.clone();
            async move {
                let r: Vec<(Vec<u8>, String, String, bool)> =
                    sqlx::query_as("SELECT device_pk, kind, token, sandbox FROM apns_tokens ORDER BY kind").fetch_all(&pool).await.unwrap();
                r
            }
        };
        let st = || State(state(pool.clone()));
        assert_eq!(put(st(), Json(req(&a, "alert", &tok, true))).await.unwrap(), StatusCode::NO_CONTENT);
        assert_eq!(put(st(), Json(req(&a, "voip", &"cd".repeat(32), true))).await.unwrap(), StatusCode::NO_CONTENT);
        assert_eq!(rows().await.len(), 2);
        // Someone else's signature over my device: refused.
        let mut forged = req(&b, "alert", &tok, false);
        forged.device_pk_hex = hex::encode(a.verifying_key().to_bytes());
        assert!(matches!(put(st(), Json(forged)).await, Err(PushTokenError::Unauthorized(_))));
        // server-http:14 — another person registering my token doesn't take
        // it off my phone (both rows stay).
        put(st(), Json(req(&b, "alert", &tok, false))).await.unwrap();
        let r = rows().await;
        assert_eq!(r.len(), 3);
        assert!(r.iter().any(|(d, k, t, _)| *d == a.verifying_key().to_bytes().to_vec() && k == "alert" && *t == tok), "mine stays");
        // A reinstall in my own account (a new device key): the token moves there.
        let a2 = SigningKey::from_bytes(&[73u8; 32]);
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) SELECT $1, user_pk, $1 FROM devices WHERE device_pk = $2")
            .bind(a2.verifying_key().to_bytes().to_vec())
            .bind(a.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        put(st(), Json(req(&a2, "alert", &tok, false))).await.unwrap();
        let r = rows().await;
        assert_eq!(r.len(), 3);
        assert!(!r.iter().any(|(d, k, _, _)| *d == a.verifying_key().to_bytes().to_vec() && k == "alert"), "moved off my old device");
        put(st(), Json(req(&b, "alert", "", false))).await.unwrap();
        // Empty token: notifications off.
        put(st(), Json(req(&a, "voip", "", true))).await.unwrap();
        assert_eq!(rows().await.len(), 1);
        // Garbage.
        assert!(matches!(put(st(), Json(req(&a, "sms", &tok, true))).await, Err(PushTokenError::BadRequest(_))));
        assert!(matches!(put(st(), Json(req(&a, "alert", "zz", true))).await, Err(PushTokenError::BadRequest(_))));
        // ADR-040 — an endpoint only where the operator allowed UnifiedPush
        // (not configured in tests).
        assert!(matches!(
            put(st(), Json(req(&a, "alert", "https://push.example.org/up1", false))).await,
            Err(PushTokenError::BadRequest(_))
        ));
    }

    // Tech-debt 2.36 — an Android phone's UnifiedPush endpoint with its Web
    // Push keys (RFC 8291), end to end through the handler and the table.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn an_android_endpoint_registers_with_its_keys(pool: sqlx::PgPool) {
        use base64::Engine;
        let e = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let a = SigningKey::from_bytes(&[73u8; 32]);
        let u = uuid::Uuid::now_v7();
        let pk = a.verifying_key().to_bytes().to_vec();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
        let cfg = crate::unifiedpush::UnifiedPushConfig::from_value(Some("push.example.org"));
        let point = p256::SecretKey::from_slice(&[9u8; 32]).unwrap().public_key().to_sec1_bytes();
        let p256dh = e.encode(&point);
        let auth = e.encode([5u8; 16]);
        let put_ = |r: PushTokenRequest| put_with(state(pool.clone()), r, &cfg);
        // The endpoint keeps its case (ntfy topics are case-sensitive).
        let endpoint = "https://push.example.org/UpAbC123?up=1";
        assert_eq!(
            put_(req_keys(&a, "alert", endpoint, false, Some((&p256dh, &auth)))).await.unwrap(),
            StatusCode::NO_CONTENT
        );
        let row: (String, Option<Vec<u8>>, Option<Vec<u8>>) =
            sqlx::query_as("SELECT token, webpush_p256dh, webpush_auth FROM apns_tokens WHERE device_pk = $1")
                .bind(&pk)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(row, (endpoint.to_string(), Some(point.to_vec()), Some(vec![5u8; 16])));
        // Without keys, with a key that isn't a P-256 point, on a host the
        // operator didn't allow, or keys with an APNs token: refused.
        let bad = |r| async { matches!(put_(r).await, Err(PushTokenError::BadRequest(_))) };
        assert!(bad(req(&a, "alert", endpoint, false)).await, "no keys");
        assert!(bad(req_keys(&a, "alert", endpoint, false, Some((&e.encode([4u8; 65]), &auth)))).await, "not a point");
        assert!(
            bad(req_keys(&a, "alert", "https://evil.example.com/up1", false, Some((&p256dh, &auth)))).await,
            "host not allowed"
        );
        assert!(bad(req_keys(&a, "alert", &"ab".repeat(32), false, Some((&p256dh, &auth)))).await, "keys with an APNs token");
        // A refused request didn't touch the stored endpoint.
        let n: (i64,) = sqlx::query_as("SELECT count(*) FROM apns_tokens").fetch_one(&pool).await.unwrap();
        assert_eq!(n.0, 1);
    }

    /// ADR-056 — a PushKit token with the phone's call hint key: stored
    /// with it, signed (a changed key breaks the proof), VoIP only.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_voip_token_registers_its_call_hint_key(pool: sqlx::PgPool) {
        let a = SigningKey::from_bytes(&[74u8; 32]);
        let u = uuid::Uuid::now_v7();
        let pk = a.verifying_key().to_bytes().to_vec();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
        let st = || State(state(pool.clone()));
        let key = "07".repeat(32);
        let tok = "cd".repeat(32);
        put(st(), Json(req_full(&a, "voip", &tok, false, None, Some(&key)))).await.unwrap();
        let targets = crate::push::voip_targets(&pool, &[u]).await.unwrap();
        assert_eq!(targets[0].call_hint_key, Some(vec![7u8; 32]));
        let mut swapped = req_full(&a, "voip", &tok, false, None, Some(&key));
        swapped.call_hint_key_hex = Some("08".repeat(32));
        assert!(matches!(put(st(), Json(swapped)).await, Err(PushTokenError::Unauthorized(_))));
        let bad = |r| async { matches!(put(st(), Json(r)).await, Err(PushTokenError::BadRequest(_))) };
        assert!(bad(req_full(&a, "alert", &"ab".repeat(32), false, None, Some(&key))).await, "alert tokens have none");
        assert!(bad(req_full(&a, "voip", &tok, false, None, Some("0707"))).await, "32 bytes");
        // Re-registering without a key (an older app) clears it.
        put(st(), Json(req(&a, "voip", &tok, false))).await.unwrap();
        assert_eq!(crate::push::voip_targets(&pool, &[u]).await.unwrap()[0].call_hint_key, None);
    }

    /// ADR-057 — an Android phone's Google token, one for messages and
    /// calls, each with the phone's key (signed); the push to it is sealed
    /// to that key.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn an_fcm_token_registers_with_its_key_for_both_kinds(pool: sqlx::PgPool) {
        let a = SigningKey::from_bytes(&[75u8; 32]);
        let u = uuid::Uuid::now_v7();
        let pk = a.verifying_key().to_bytes().to_vec();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
        let st = || State(state(pool.clone()));
        let key = "0a".repeat(32);
        // Google's tokens are mixed case: kept as they are.
        let tok = format!("fcm:cAbC-_1:APA91b{}", "Xy".repeat(70));
        for kind in ["alert", "voip"] {
            put(st(), Json(req_full(&a, kind, &tok, false, None, Some(&key)))).await.unwrap();
        }
        let rows: Vec<(String, String, Option<Vec<u8>>)> =
            sqlx::query_as("SELECT kind, token, call_hint_key FROM apns_tokens ORDER BY kind").fetch_all(&pool).await.unwrap();
        assert_eq!(rows, vec![("alert".into(), tok.clone(), Some(vec![10u8; 32])), ("voip".into(), tok.clone(), Some(vec![10u8; 32]))]);
        let bad = |r| async { matches!(put(st(), Json(r)).await, Err(PushTokenError::BadRequest(_))) };
        assert!(bad(req(&a, "alert", &tok, false)).await, "no key");
        assert!(bad(req_full(&a, "alert", "fcm:a b", false, None, Some(&key))).await, "not a token");
        // The push for a message reaches the token with its key.
        let push = crate::push::tests::RecordingPush::default();
        assert_eq!(crate::push::notify_offline(&pool, &push, &[(u, None)]).await.unwrap(), 1);
        assert_eq!(push.0.lock().unwrap()[0].0, tok);
        let targets = crate::push::voip_targets(&pool, &[u]).await.unwrap();
        assert_eq!(targets[0].call_hint_key, Some(vec![10u8; 32]));
    }

    #[test]
    fn keys_are_signed_and_checked() {
        // The signature covers the keys: swapping them breaks it.
        assert_ne!(
            token_body("alert", "https://p/u", false, "ru", Some(("a", "b")), None),
            token_body("alert", "https://p/u", false, "ru", Some(("x", "b")), None)
        );
        assert_eq!(token_body("alert", "ab", false, "ru", None, None), b"alert\0ab\0ru".to_vec());
        assert_eq!(token_body("voip", "ab", false, "ru", None, Some("0f")), b"voip\0ab\0ru\x010f".to_vec());
        use base64::Engine;
        let e = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        assert_eq!(b64url(&e.encode([7u8; 16]), 16), Some(vec![7u8; 16]));
        assert_eq!(b64url(&format!("{}==", e.encode([7u8; 16])), 16), Some(vec![7u8; 16]));
        assert_eq!(b64url(&e.encode([7u8; 15]), 16), None);
        assert_eq!(b64url("+/+/", 3), None, "standard alphabet refused");
    }
}
