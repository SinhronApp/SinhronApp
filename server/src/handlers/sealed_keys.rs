// Sealed-sender delivery keys — ADR-023 (spec §6.5).
//
//   PUT /v1/sealed-keys   a device publishes this and next week's HPKE
//                         public keys (action proof, domain
//                         PUT_SEALED_KEYS_DOMAIN; body = week_be4 || pk
//                         for each key, in order).
//   GET /v1/sealed-keys?identities=<hex>,<hex>
//                         a sender fetches the current keys of the people
//                         it is about to write to (public keys only).
//   POST /v1/sealed       tech-debt 2.2 — "unidentified access": the same
//                         envelopes, sent with NO authentication (a fresh
//                         HTTP request, not the sender's WS). Each delivery
//                         carries the recipient's 16-byte access key; the
//                         server checks SHA-256(access key) against what
//                         the recipient published (PUT, `access_hash_hex`)
//                         — so only people they gave it to (inside MLS)
//                         can reach them this way. The server learns
//                         neither the group nor the sender's account.
//
// The server stores public keys and their owner; envelopes sealed to
// them are opaque (see ws::handle_sealed_submit).

use axum::{
    extract::{DefaultBodyLimit, Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use serde::{Deserialize, Serialize};
use base64::{prelude::BASE64_STANDARD, Engine};
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use tracing::{error, info};

use super::proof::{self, PUT_SEALED_KEYS_DOMAIN};
use crate::AppState;

pub const WEEK_SECS: i64 = 7 * 24 * 3600;
const MAX_KEYS_PER_PUT: usize = 4;
const MAX_IDENTITIES_PER_GET: usize = 100;
/// Deliveries in one unauthenticated submit (a group message = one per member).
pub const MAX_ANON_DELIVERIES: usize = 100;
pub const ACCESS_KEY_LEN: usize = 16;
/// GRP-8 — one envelope on the unauthenticated route (a real one is a few
/// KB; the largest the app makes is ~160 KiB) and the bytes of envelopes
/// one person may have waiting from it: 4 MiB each, 600 a minute, kept a
/// year, filled the disk with nobody to name. Past either the delivery is
/// refused and the sender's app uses the signed-in route.
pub const MAX_ANON_ENVELOPE_BYTES: usize = 256 * 1024;
pub const MAX_ANON_QUEUE_BYTES: i64 = 64 * 1024 * 1024;
/// PREV-3 — unauthenticated submits per client IP (each costs up to a few
/// hundred queries); one message is one request.
/// GRP-4 — delivery keys kept per person and week (each new public key was
/// a new row, and the unauthenticated GET returned them all), and PUTs per
/// person (the app publishes on start and once a week). One key per week
/// and key generation; a generation is a cut-off device or a restore, and
/// the app republishes generation 0 with the newest — 32 is far past any
/// honest week, and the newest always stay.
const MAX_KEYS_PER_WEEK: i64 = 32;
static PUT_PER_USER: crate::rate_limit::StaticLimiter = crate::rate_limit::StaticLimiter::new("SINHRON_RATE_SEALED_KEYS", 120, 3_600);
static ANON_PER_IP: crate::rate_limit::StaticLimiter = crate::rate_limit::StaticLimiter::new("SINHRON_RATE_SEALED_IP", 600, 60);

pub fn current_week(now_unix: i64) -> i32 {
    (now_unix / WEEK_SECS) as i32
}

pub fn key_id_of(public: &[u8]) -> Vec<u8> {
    Sha256::digest(public)[..16].to_vec()
}

#[derive(Debug, Deserialize, Serialize)]
pub struct SealedKeyIn {
    pub week: i32,
    pub public_hex: String,
    /// ADR-082 — the owner's signature of this key (64 bytes; older apps
    /// send none). Checked by senders, not here.
    #[serde(default)]
    pub sig_hex: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct PutRequest {
    pub identity_pubkey_hex: String,
    pub keys: Vec<SealedKeyIn>,
    /// SHA-256 of the person's access key (tech-debt 2.2); signed after
    /// the keys when present.
    #[serde(default)]
    pub access_hash_hex: Option<String>,
    /// Version of that access key (rotation); signed after the hash.
    #[serde(default)]
    pub access_version: i32,
    /// ADR-082 — the signing device's certificate (a linked device).
    #[serde(default)]
    pub cert_hex: Option<String>,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct PutResponse {
    pub stored: usize,
    /// The person's current access-key version on the server — a device
    /// behind it adopts it (another of their devices rotated the key).
    pub access_version: i32,
}

pub async fn put(State(state): State<AppState>, Json(req): Json<PutRequest>) -> Result<Json<PutResponse>, SealedKeysError> {
    let pool = state.pool.ok_or(SealedKeysError::NoDb)?;
    let identity = hex::decode(&req.identity_pubkey_hex).map_err(|e| SealedKeysError::BadRequest(format!("identity: {e}")))?;
    if req.keys.is_empty() || req.keys.len() > MAX_KEYS_PER_PUT {
        return Err(SealedKeysError::BadRequest(format!("1..={MAX_KEYS_PER_PUT} keys")));
    }
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let week_now = current_week(now);
    let mut keys = Vec::with_capacity(req.keys.len());
    let mut signed = Vec::with_capacity(req.keys.len() * 36);
    for k in &req.keys {
        let public = hex::decode(&k.public_hex).map_err(|e| SealedKeysError::BadRequest(format!("public_hex: {e}")))?;
        if public.len() != 32 {
            return Err(SealedKeysError::BadRequest("public key must be 32 bytes".into()));
        }
        // Only keys a sender could pick now or soon — no stockpiling.
        if k.week < week_now - 1 || k.week > week_now + 2 {
            return Err(SealedKeysError::BadRequest(format!("week {} out of range", k.week)));
        }
        signed.extend_from_slice(&k.week.to_be_bytes());
        signed.extend_from_slice(&public);
        let sig = k.sig_hex.as_deref().map(hex::decode).transpose().map_err(|e| SealedKeysError::BadRequest(format!("sig_hex: {e}")))?;
        if sig.as_ref().is_some_and(|s| s.len() != 64) {
            return Err(SealedKeysError::BadRequest("sig must be 64 bytes".into()));
        }
        keys.push((k.week, public, sig));
    }
    let cert = req.cert_hex.as_deref().map(hex::decode).transpose().map_err(|e| SealedKeysError::BadRequest(format!("cert_hex: {e}")))?;
    if cert.as_ref().is_some_and(|c| c.len() > 256) {
        return Err(SealedKeysError::BadRequest("cert too long".into()));
    }
    let access_hash = match &req.access_hash_hex {
        Some(h) => {
            let b = hex::decode(h).map_err(|e| SealedKeysError::BadRequest(format!("access_hash_hex: {e}")))?;
            if b.len() != 32 {
                return Err(SealedKeysError::BadRequest("access hash must be 32 bytes".into()));
            }
            signed.extend_from_slice(&b);
            signed.extend_from_slice(&req.access_version.to_be_bytes());
            Some(b)
        }
        None => None,
    };
    let sig = hex::decode(&req.proof_hex).map_err(|e| SealedKeysError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(PUT_SEALED_KEYS_DOMAIN, &identity, &signed, req.proof_ts, &sig, now)
        .map_err(|e| SealedKeysError::Unauthorized(e.to_string()))?;

    // ADR-027 — or one of the person's active linked devices.
    let user = crate::accounts::resolve_signer(&pool, &identity).await.map_err(SealedKeysError::db)?;
    let Some((user_pk, _)) = user else {
        return Err(SealedKeysError::Unauthorized("unknown identity".into()));
    };
    if PUT_PER_USER.check(&user_pk.to_string()).is_err() {
        return Err(SealedKeysError::TooMany);
    }
    // Only a newer (or the same) version replaces the hash — an older
    // device can't undo a rotation. GRP-5 — and not one far ahead: at the
    // maximum no rotation was possible ever after.
    if let Some(h) = &access_hash {
        sqlx::query(
            "UPDATE users SET access_hash = $2, access_version = $3 \
             WHERE user_pk = $1 AND access_version <= $3 AND $3::bigint <= access_version::bigint + $4",
        )
            .bind(user_pk)
            .bind(h)
            .bind(req.access_version)
            .bind(super::access_keys::MAX_VERSION_STEP)
            .execute(&pool)
            .await
            .map_err(SealedKeysError::db)?;
    }
    let (access_version,): (i32,) = sqlx::query_as("SELECT access_version FROM users WHERE user_pk = $1")
        .bind(user_pk)
        .fetch_one(&pool)
        .await
        .map_err(SealedKeysError::db)?;
    let mut stored = 0;
    // ADR-084 — a key published again counts as the newest (GET lists the
    // newest first): after a device is disconnected my devices publish keys
    // of a new generation, and a device that hasn't heard yet may still
    // publish the old ones — whoever published last wins, not the first.
    // ADR-082 — a signed PUT adds the signature to a key stored without one;
    // a PUT without one never wipes it.
    for (week, public, sig) in keys {
        let r = sqlx::query(
            "INSERT INTO sealed_keys (key_id, user_pk, public_key, week, sig, cert) VALUES ($1, $2, $3, $4, $5, $6) \
             ON CONFLICT (key_id) DO UPDATE SET created_at = NOW(), \
             sig = COALESCE(EXCLUDED.sig, sealed_keys.sig), cert = COALESCE(EXCLUDED.cert, sealed_keys.cert) \
             WHERE sealed_keys.user_pk = EXCLUDED.user_pk",
        )
        .bind(key_id_of(&public))
        .bind(user_pk)
        .bind(&public)
        .bind(week)
        .bind(&sig)
        .bind(sig.as_ref().and(cert.as_ref()))
        .execute(&pool)
        .await
        .map_err(SealedKeysError::db)?;
        stored += r.rows_affected() as usize;
    }
    // GRP-4 — only the newest few of each week stay.
    sqlx::query(
        "DELETE FROM sealed_keys WHERE key_id IN (SELECT key_id FROM ( \
            SELECT key_id, row_number() OVER (PARTITION BY week ORDER BY created_at DESC) AS n \
            FROM sealed_keys WHERE user_pk = $1) t WHERE n > $2)",
    )
    .bind(user_pk)
    .bind(MAX_KEYS_PER_WEEK)
    .execute(&pool)
    .await
    .map_err(SealedKeysError::db)?;
    info!(identity = %crate::short_key(&req.identity_pubkey_hex), stored, "sealed keys published");
    Ok(Json(PutResponse { stored, access_version }))
}

#[derive(Debug, Deserialize)]
pub struct GetQuery {
    pub identities: String,
}

#[derive(Debug, Serialize)]
pub struct SealedKeyOut {
    pub identity_pubkey_hex: String,
    pub week: i32,
    pub public_hex: String,
    /// ADR-082 — absent for keys an older app published.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sig_hex: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cert_hex: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct GetResponse {
    pub keys: Vec<SealedKeyOut>,
}

pub async fn get(State(state): State<AppState>, Query(q): Query<GetQuery>) -> Result<Json<GetResponse>, SealedKeysError> {
    let pool = state.pool.ok_or(SealedKeysError::NoDb)?;
    let mut ids = Vec::new();
    for h in q.identities.split(',').filter(|s| !s.is_empty()) {
        let b = hex::decode(h).map_err(|e| SealedKeysError::BadRequest(format!("identity: {e}")))?;
        if b.len() != 32 {
            return Err(SealedKeysError::BadRequest("identity must be 32 bytes".into()));
        }
        ids.push(b);
    }
    if ids.is_empty() || ids.len() > MAX_IDENTITIES_PER_GET {
        return Err(SealedKeysError::BadRequest(format!("1..={MAX_IDENTITIES_PER_GET} identities")));
    }
    let week = current_week(OffsetDateTime::now_utc().unix_timestamp());
    type Row = (Vec<u8>, i32, Vec<u8>, Option<Vec<u8>>, Option<Vec<u8>>);
    let rows: Vec<Row> = sqlx::query_as(
        "SELECT u.identity_pubkey, k.week, k.public_key, k.sig, k.cert FROM sealed_keys k \
         JOIN users u ON u.user_pk = k.user_pk \
         WHERE u.identity_pubkey = ANY($1) AND k.week BETWEEN $2 AND $3 \
         ORDER BY u.identity_pubkey, k.week, k.created_at DESC",
    )
    .bind(&ids)
    .bind(week - 1)
    .bind(week + 1)
    .fetch_all(&pool)
    .await
    .map_err(SealedKeysError::db)?;
    Ok(Json(GetResponse {
        keys: rows
            .into_iter()
            .map(|(id, week, pk, sig, cert)| SealedKeyOut {
                identity_pubkey_hex: hex::encode(id),
                week,
                public_hex: hex::encode(pk),
                sig_hex: sig.map(hex::encode),
                cert_hex: cert.map(hex::encode),
            })
            .collect(),
    }))
}

#[derive(Debug, Deserialize)]
pub struct AnonDelivery {
    pub key_id_hex: String,
    pub envelope_b64: String,
    pub access_key_hex: String,
    /// The chat's disappearing timer (0 = keep) — tech-debt 2.5.
    #[serde(default)]
    pub ttl_secs: u32,
    /// A real message: wakes an offline phone (overnight item 8).
    #[serde(default)]
    pub urgent: bool,
    /// ADR-056 — the sealed notification preview (base64), urgent only.
    #[serde(default)]
    pub push_preview_b64: Option<String>,
    /// Tech-debt 2.53 — drop if not delivered within this many seconds
    /// (0 = keep): "online" heartbeats and "typing".
    #[serde(default)]
    pub drop_after_secs: u32,
}

#[derive(Debug, Deserialize)]
pub struct AnonSubmit {
    pub message_id: String,
    pub deliveries: Vec<AnonDelivery>,
}

#[derive(Debug, Serialize)]
pub struct AnonSubmitResponse {
    pub accepted: usize,
    /// Unknown key, or no / wrong access key — the sender falls back to
    /// the authenticated route for these.
    pub refused: usize,
}

/// `POST /v1/sealed` as routed: [anonymous_submit] behind the per-IP limit
/// (PREV-3). The address is only counted, never stored or logged.
pub async fn anonymous_submit_http(
    state: State<AppState>,
    headers: HeaderMap,
    req: Json<AnonSubmit>,
) -> Result<Json<AnonSubmitResponse>, SealedKeysError> {
    if crate::admin::client_rate_key(&headers).is_some_and(|ip| ANON_PER_IP.check(&ip).is_err()) {
        return Err(SealedKeysError::TooMany);
    }
    anonymous_submit(state, req).await
}

/// Tech-debt 2.2 — `POST /v1/sealed`, no authentication. Rate-limited per
/// recipient key (the sender is unknown by design).
pub async fn anonymous_submit(
    State(state): State<AppState>,
    Json(req): Json<AnonSubmit>,
) -> Result<Json<AnonSubmitResponse>, SealedKeysError> {
    let pool = state.pool.clone().ok_or(SealedKeysError::NoDb)?;
    let message_id = uuid::Uuid::parse_str(&req.message_id).map_err(|_| SealedKeysError::BadRequest("message_id must be UUID".into()))?;
    if req.deliveries.is_empty() || req.deliveries.len() > MAX_ANON_DELIVERIES {
        return Err(SealedKeysError::BadRequest(format!("1..={MAX_ANON_DELIVERIES} deliveries")));
    }
    let now = OffsetDateTime::now_utc();
    let (mut accepted, mut refused) = (0usize, 0usize);
    let mut wake: Vec<crate::push::Wake> = Vec::new();
    let mut wake_live: Vec<crate::push::Wake> = Vec::new();
    for d in &req.deliveries {
        let (Ok(key_id), Ok(envelope), Ok(access)) = (
            hex::decode(&d.key_id_hex),
            BASE64_STANDARD.decode(&d.envelope_b64),
            hex::decode(&d.access_key_hex),
        ) else {
            refused += 1;
            continue;
        };
        if access.len() != ACCESS_KEY_LEN || envelope.len() > MAX_ANON_ENVELOPE_BYTES {
            refused += 1;
            continue;
        }
        let owner: Option<(uuid::Uuid,)> = sqlx::query_as("SELECT user_pk FROM sealed_keys WHERE key_id = $1")
            .bind(&key_id)
            .fetch_optional(&pool)
            .await
            .map_err(SealedKeysError::db)?;
        let Some((recipient,)) = owner else {
            refused += 1;
            continue;
        };
        // ADR-071 — the recipient's own key for this sender, or (ADR-026)
        // their shared one. A revoked key: "accepted", dropped, no push.
        let verdict = super::access_keys::anonymous_verdict(&pool, recipient, &access).await.map_err(SealedKeysError::db)?;
        // Only a delivery with a key the recipient gave out counts: junk
        // naming their key used up their contacts' limit
        // (docs/security-review-2026-11.md, server-http:4). A revoked key
        // counts like a working one, each sender's key in its own bucket, and
        // the full queue (GRP-8) answers both alike — the limits don't tell a
        // blocked sender apart (audit 2026-11b, keys-block-oracle).
        if verdict != super::access_keys::AnonVerdict::Refuse
            && (state.rate.check_ws_submit(&format!("anon:{}:{}", d.key_id_hex, hex::encode(Sha256::digest(&access)))).is_err()
                || anon_queue_bytes(&pool, recipient).await? >= MAX_ANON_QUEUE_BYTES)
        {
            refused += 1;
            continue;
        }
        match verdict {
            super::access_keys::AnonVerdict::Deliver => {}
            super::access_keys::AnonVerdict::DropSilently => {
                accepted += 1;
                continue;
            }
            super::access_keys::AnonVerdict::Refuse => {
                refused += 1;
                continue;
            }
        }
        match crate::ws::deliver_sealed(
            &pool,
            &state.sessions,
            message_id,
            &key_id,
            &envelope,
            d.ttl_secs,
            d.urgent,
            d.drop_after_secs,
            now,
        )
            .await
            .map_err(|e| {
                error!(error = %e, "anonymous sealed delivery failed");
                SealedKeysError::Db
            })? {
            crate::ws::SealedOutcome::UnknownKey => refused += 1,
            crate::ws::SealedOutcome::Delivered { recipient, live } => {
                accepted += 1;
                if d.urgent {
                    let preview = d.push_preview_b64.as_deref().and_then(|p| BASE64_STANDARD.decode(p).ok()).unwrap_or_default();
                    // Status 167 — a connected Android phone gets its Google push too.
                    crate::push::add_wake(if live { &mut wake_live } else { &mut wake }, recipient, &preview);
                }
            }
            crate::ws::SealedOutcome::Duplicate => accepted += 1, // a retry counts as accepted
        }
    }
    crate::push::spawn_notify(pool.clone(), state.push.clone(), wake);
    crate::push::spawn_notify_android_live(pool.clone(), state.push.clone(), wake_live);
    crate::metrics::MESSAGES_SUBMITTED_TOTAL.inc();
    info!(accepted, refused, "anonymous sealed message routed");
    Ok(Json(AnonSubmitResponse { accepted, refused }))
}

/// Bytes of sealed envelopes waiting for [recipient] (not yet received).
async fn anon_queue_bytes(pool: &sqlx::PgPool, recipient: uuid::Uuid) -> Result<i64, SealedKeysError> {
    let (bytes,): (i64,) = sqlx::query_as(
        "SELECT COALESCE(SUM(octet_length(envelope)), 0)::bigint FROM message_deliveries \
         WHERE recipient_user_pk = $1 AND envelope IS NOT NULL AND received_at IS NULL",
    )
    .bind(recipient)
    .fetch_one(pool)
    .await
    .map_err(SealedKeysError::db)?;
    Ok(bytes)
}

/// Envelopes are small (one MLS message each), but a group message has
/// one per member.
pub fn anonymous_body_limit() -> DefaultBodyLimit {
    DefaultBodyLimit::max(4 * 1024 * 1024)
}

#[derive(Debug, thiserror::Error)]
pub enum SealedKeysError {
    #[error("database unavailable")]
    NoDb,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("too many requests")]
    TooMany,
    #[error("internal error")]
    Db,
}

impl SealedKeysError {
    fn db(e: sqlx::Error) -> Self {
        error!(error = %e, "sealed keys db error");
        Self::Db
    }
}

impl IntoResponse for SealedKeysError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::NoDb => StatusCode::SERVICE_UNAVAILABLE,
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            Self::TooMany => StatusCode::TOO_MANY_REQUESTS,
            Self::Db => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, Json(serde_json::json!({ "error": self.to_string() }))).into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn state(pool: sqlx::PgPool) -> AppState {
        AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    fn signed_put(sk: &SigningKey, keys: &[(i32, [u8; 32])], ts: i64) -> PutRequest {
        signed_put_with(sk, keys, None, ts)
    }

    fn signed_put_versioned(sk: &SigningKey, keys: &[(i32, [u8; 32])], hash: [u8; 32], version: i32, ts: i64) -> PutRequest {
        let mut body = Vec::new();
        for (w, pk) in keys {
            body.extend_from_slice(&w.to_be_bytes());
            body.extend_from_slice(pk);
        }
        body.extend_from_slice(&hash);
        body.extend_from_slice(&version.to_be_bytes());
        let mut msg = PUT_SEALED_KEYS_DOMAIN.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&Sha256::digest(&body));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        PutRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            keys: keys.iter().map(|(w, pk)| SealedKeyIn { week: *w, public_hex: hex::encode(pk), sig_hex: None }).collect(),
            access_hash_hex: Some(hex::encode(hash)),
            access_version: version,
            cert_hex: None,
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes()),
        }
    }

    fn signed_put_with(sk: &SigningKey, keys: &[(i32, [u8; 32])], access_hash: Option<[u8; 32]>, ts: i64) -> PutRequest {
        let mut body = Vec::new();
        for (w, pk) in keys {
            body.extend_from_slice(&w.to_be_bytes());
            body.extend_from_slice(pk);
        }
        if let Some(h) = access_hash {
            body.extend_from_slice(&h);
            body.extend_from_slice(&0i32.to_be_bytes());
        }
        let mut msg = PUT_SEALED_KEYS_DOMAIN.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&Sha256::digest(&body));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        PutRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            keys: keys.iter().map(|(w, pk)| SealedKeyIn { week: *w, public_hex: hex::encode(pk), sig_hex: None }).collect(),
            access_hash_hex: access_hash.map(hex::encode),
            access_version: 0,
            cert_hex: None,
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes()),
        }
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn publish_and_fetch_delivery_keys(pool: sqlx::PgPool) {
        let sk = SigningKey::from_bytes(&[5u8; 32]);
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let w = current_week(now);
        let keys = [(w, [1u8; 32]), (w + 1, [2u8; 32])];

        let ok = put(State(state(pool.clone())), Json(signed_put(&sk, &keys, now))).await.unwrap();
        assert_eq!(ok.0.stored, 2);
        // Re-publishing is harmless (the keys only become the newest).
        assert_eq!(put(State(state(pool.clone())), Json(signed_put(&sk, &keys, now))).await.unwrap().0.stored, 2);

        // A forged proof (signed by someone else) is refused.
        let mut forged = signed_put(&SigningKey::from_bytes(&[6u8; 32]), &keys, now);
        forged.identity_pubkey_hex = hex::encode(sk.verifying_key().to_bytes());
        assert!(matches!(put(State(state(pool.clone())), Json(forged)).await, Err(SealedKeysError::Unauthorized(_))));
        // Stockpiling far-future weeks is refused.
        let far = signed_put(&sk, &[(w + 10, [3u8; 32])], now);
        assert!(matches!(put(State(state(pool.clone())), Json(far)).await, Err(SealedKeysError::BadRequest(_))));

        let got = get(State(state(pool)), Query(GetQuery { identities: hex::encode(sk.verifying_key().to_bytes()) }))
            .await
            .unwrap();
        assert_eq!(got.0.keys.len(), 2);
        assert_eq!(got.0.keys[0].public_hex, hex::encode([1u8; 32]));
    }

    /// ADR-082 (audit mls-identity:4) — the owner's signature on each key
    /// (and a linked device's certificate) round-trips to senders; an older
    /// app's PUT without one still works, and doesn't wipe one stored.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn delivery_key_signatures_round_trip_and_old_apps_still_publish(pool: sqlx::PgPool) {
        let old: PutRequest = serde_json::from_str(
            r#"{"identity_pubkey_hex":"00","keys":[{"week":1,"public_hex":"00"}],"proof_ts":1,"proof_hex":"00"}"#,
        )
        .unwrap();
        assert!(old.cert_hex.is_none() && old.keys[0].sig_hex.is_none(), "an older app's body parses");
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        let id = hex::encode(sk.verifying_key().to_bytes());
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let keys = [(current_week(now), [1u8; 32]), (current_week(now) + 1, [2u8; 32])];
        let fetch = || async { get(State(state(pool.clone())), Query(GetQuery { identities: id.clone() })).await.unwrap().0.keys };
        let signed = |sig: u8| {
            let mut r = signed_put(&sk, &keys, now);
            r.keys.iter_mut().for_each(|k| k.sig_hex = Some(hex::encode([sig; 64])));
            r.cert_hex = Some(hex::encode([9u8; 132]));
            r
        };

        assert_eq!(put(State(state(pool.clone())), Json(signed_put(&sk, &keys, now))).await.unwrap().0.stored, 2);
        assert!(fetch().await.iter().all(|k| k.sig_hex.is_none() && k.cert_hex.is_none()), "old app: no signature");
        // The updated app signs the keys already there.
        assert_eq!(put(State(state(pool.clone())), Json(signed(3))).await.unwrap().0.stored, 2);
        assert_eq!(put(State(state(pool.clone())), Json(signed(3))).await.unwrap().0.stored, 2, "a re-publish refreshes (ADR-084)");
        assert_eq!(put(State(state(pool.clone())), Json(signed_put(&sk, &keys, now))).await.unwrap().0.stored, 2, "and never wipes the signature");
        let got = fetch().await;
        assert_eq!(got.len(), 2);
        assert!(got.iter().all(|k| k.sig_hex == Some(hex::encode([3u8; 64])) && k.cert_hex == Some(hex::encode([9u8; 132]))));
        let json = serde_json::to_value(GetResponse { keys: got }).unwrap();
        assert!(json["keys"][0]["sig_hex"].is_string());
        let mut bad = signed(3);
        bad.keys[0].sig_hex = Some("00".into());
        assert!(matches!(put(State(state(pool)), Json(bad)).await, Err(SealedKeysError::BadRequest(_))));
    }

    /// ADR-084 (status 238) — after a device is disconnected my devices publish
    /// a new key for this week: senders get it first, not the old one the
    /// disconnected device can still compute; a device that publishes the
    /// old one again makes it the first again (the last publisher wins).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn the_newest_published_delivery_key_is_listed_first(pool: sqlx::PgPool) {
        let sk = SigningKey::from_bytes(&[7u8; 32]);
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let w = current_week(now);
        let id = hex::encode(sk.verifying_key().to_bytes());
        for (pk, want) in [([1u8; 32], [1u8; 32]), ([2u8; 32], [2u8; 32]), ([1u8; 32], [1u8; 32])] {
            put(State(state(pool.clone())), Json(signed_put(&sk, &[(w, pk)], now))).await.unwrap();
            let got = get(State(state(pool.clone())), Query(GetQuery { identities: id.clone() })).await.unwrap();
            assert_eq!(got.0.keys[0].public_hex, hex::encode(want), "the last one published comes first");
        }
    }

    /// Tech-debt 2.2 — unauthenticated delivery needs the recipient's
    /// access key; the access hash is part of the signed publish.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn anonymous_delivery_needs_the_recipients_access_key(pool: sqlx::PgPool) {
        let bob = SigningKey::from_bytes(&[41u8; 32]);
        let carol = SigningKey::from_bytes(&[42u8; 32]);
        let mut users = Vec::new();
        for sk in [&bob, &carol] {
            let u = uuid::Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(u)
                .bind(sk.verifying_key().to_bytes().to_vec())
                .execute(&pool)
                .await
                .unwrap();
            users.push(u);
        }
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let w = current_week(now);
        let access = [7u8; ACCESS_KEY_LEN];
        let access_hash: [u8; 32] = Sha256::digest(access).into();
        // A tampered access hash (signature over another one) is refused.
        let mut forged = signed_put_with(&bob, &[(w, [1u8; 32])], Some([0u8; 32]), now);
        forged.access_hash_hex = Some(hex::encode(access_hash));
        assert!(matches!(put(State(state(pool.clone())), Json(forged)).await, Err(SealedKeysError::Unauthorized(_))));
        // Bob publishes keys + his access hash; Carol only keys.
        let _ = put(State(state(pool.clone())), Json(signed_put_with(&bob, &[(w, [1u8; 32])], Some(access_hash), now))).await.unwrap();
        let _ = put(State(state(pool.clone())), Json(signed_put(&carol, &[(w, [2u8; 32])], now))).await.unwrap();

        let delivery = |pk: [u8; 32], key: &[u8]| AnonDelivery {
            key_id_hex: hex::encode(key_id_of(&pk)),
            envelope_b64: BASE64_STANDARD.encode(b"sealed"),
            access_key_hex: hex::encode(key),
            ttl_secs: 0,
            urgent: false,
            push_preview_b64: None,
            drop_after_secs: 0,
        };
        let submit = |ds: Vec<AnonDelivery>| AnonSubmit { message_id: uuid::Uuid::now_v7().to_string(), deliveries: ds };

        let r = anonymous_submit(State(state(pool.clone())), Json(submit(vec![delivery([1u8; 32], &access)]))).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (1, 0));
        let r = anonymous_submit(State(state(pool.clone())), Json(submit(vec![delivery([1u8; 32], &[8u8; 16])]))).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (0, 1), "wrong access key");
        let r = anonymous_submit(State(state(pool.clone())), Json(submit(vec![delivery([2u8; 32], &access)]))).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (0, 1), "Carol published no access hash");

        // Rotation: Bob publishes version 1 → the old key stops working;
        // a device still on version 0 can't roll it back and learns v1.
        let new_access = [9u8; ACCESS_KEY_LEN];
        let new_hash: [u8; 32] = Sha256::digest(new_access).into();
        let v1 = signed_put_versioned(&bob, &[(w, [1u8; 32])], new_hash, 1, now);
        assert_eq!(put(State(state(pool.clone())), Json(v1)).await.unwrap().0.access_version, 1);
        let r = anonymous_submit(State(state(pool.clone())), Json(submit(vec![delivery([1u8; 32], &access)]))).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (0, 1), "the rotated-out key is refused");
        let r = anonymous_submit(State(state(pool.clone())), Json(submit(vec![delivery([1u8; 32], &new_access)]))).await.unwrap();
        assert_eq!((r.0.accepted, r.0.refused), (1, 0));
        let old = signed_put_with(&bob, &[(w, [1u8; 32])], Some(access_hash), now);
        assert_eq!(put(State(state(pool.clone())), Json(old)).await.unwrap().0.access_version, 1, "older version ignored");

        // What was stored names neither the sender nor the group.
        let rows: Vec<(uuid::Uuid, Option<Vec<u8>>)> =
            sqlx::query_as("SELECT recipient_user_pk, envelope FROM message_deliveries").fetch_all(&pool).await.unwrap();
        assert_eq!(rows.len(), 2, "the first send and the one after rotation");
        assert!(rows.iter().all(|r| r.0 == users[0]));
        assert_eq!(rows[0].1.as_deref(), Some(&b"sealed"[..]));
        let (msgs,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages").fetch_one(&pool).await.unwrap();
        assert_eq!(msgs, 0);
    }

    /// PREV-3 — the unauthenticated route counts requests per client IP.
    #[tokio::test]
    async fn anonymous_submits_are_limited_per_client_ip() {
        let st = AppState {
            pool: None,
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        };
        let from = |ip: &'static str| {
            let mut h = HeaderMap::new();
            h.insert("x-forwarded-for", ip.parse().unwrap());
            h
        };
        let req = || Json(AnonSubmit { message_id: String::new(), deliveries: Vec::new() });
        for _ in 0..600 {
            let r = anonymous_submit_http(State(st.clone()), from("198.51.100.201"), req()).await;
            assert!(matches!(r, Err(SealedKeysError::NoDb)));
        }
        let r = anonymous_submit_http(State(st.clone()), from("198.51.100.201"), req()).await;
        assert!(matches!(r, Err(SealedKeysError::TooMany)), "the 601st in a minute");
        let r = anonymous_submit_http(State(st), from("198.51.100.202"), req()).await;
        assert!(matches!(r, Err(SealedKeysError::NoDb)), "another address is not affected");
    }

    /// GRP-8 — an oversized envelope is refused, and so is anything more
    /// once the recipient's queue of unreceived envelopes is full.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn anonymous_delivery_caps_the_envelope_and_the_recipients_queue(pool: sqlx::PgPool) {
        let bob = SigningKey::from_bytes(&[43u8; 32]);
        let bob_pk = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(bob_pk)
            .bind(bob.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let access = [7u8; ACCESS_KEY_LEN];
        let hash: [u8; 32] = Sha256::digest(access).into();
        let _ = put(State(state(pool.clone())), Json(signed_put_with(&bob, &[(current_week(now), [1u8; 32])], Some(hash), now))).await.unwrap();
        let send = |len: usize| {
            let pool = pool.clone();
            async move {
                let d = AnonDelivery {
                    key_id_hex: hex::encode(key_id_of(&[1u8; 32])),
                    envelope_b64: BASE64_STANDARD.encode(vec![1u8; len]),
                    access_key_hex: hex::encode(access),
                    ttl_secs: 0,
                    urgent: false,
                    push_preview_b64: None,
                    drop_after_secs: 0,
                };
                let r = anonymous_submit(State(state(pool)), Json(AnonSubmit { message_id: uuid::Uuid::now_v7().to_string(), deliveries: vec![d] }))
                    .await
                    .unwrap();
                (r.0.accepted, r.0.refused)
            }
        };
        assert_eq!(send(MAX_ANON_ENVELOPE_BYTES).await, (1, 0), "the largest allowed");
        assert_eq!(send(MAX_ANON_ENVELOPE_BYTES + 1).await, (0, 1), "one byte more");
        let (rows,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries").fetch_one(&pool).await.unwrap();
        assert_eq!(rows, 1);

        // 64 MiB waiting for Bob: nothing more over this route…
        sqlx::query(
            "INSERT INTO message_deliveries (recipient_user_pk, message_id, envelope) \
             SELECT $1, gen_random_uuid(), decode(repeat('00', 1048576), 'hex') FROM generate_series(1, 64)",
        )
        .bind(bob_pk)
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(send(10).await, (0, 1), "the queue is full");
        // …until his phone has received them.
        sqlx::query("UPDATE message_deliveries SET received_at = NOW()").execute(&pool).await.unwrap();
        assert_eq!(send(10).await, (1, 0));
    }

    /// Audit 2026-11b keys-block-oracle — the limits answer a blocked key
    /// like a working one, and a blocked sender doesn't use up anyone
    /// else's limit. (A limiter of 3 that never refills: no clock involved.)
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn blocked_and_active_keys_answer_the_same(pool: sqlx::PgPool) {
        let bob = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey, access_per_contact) VALUES ($1, $2, TRUE)")
            .bind(bob)
            .bind(vec![0x51u8; 32])
            .execute(&pool)
            .await
            .unwrap();
        let pk = [1u8; 32];
        sqlx::query("INSERT INTO sealed_keys (key_id, user_pk, public_key, week) VALUES ($1, $2, $3, 1)")
            .bind(key_id_of(&pk))
            .bind(bob)
            .bind(pk.to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let (active, blocked) = ([7u8; ACCESS_KEY_LEN], [8u8; ACCESS_KEY_LEN]);
        for (k, revoked) in [(active, false), (blocked, true)] {
            sqlx::query("INSERT INTO access_keys (user_pk, key_hash, revoked) VALUES ($1, $2, $3)")
                .bind(bob)
                .bind(Sha256::digest(k).to_vec())
                .bind(revoked)
                .execute(&pool)
                .await
                .unwrap();
        }
        let mut st = state(pool.clone());
        st.rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateDefaults {
            ws_submit: crate::rate_limit::RateConfig { capacity: 3, refill_per_sec: 0.0 },
            ..crate::rate_limit::RateConfig::defaults()
        });
        let send = |key: [u8; ACCESS_KEY_LEN]| {
            let st = st.clone();
            async move {
                let deliveries = (0..5)
                    .map(|_| AnonDelivery {
                        key_id_hex: hex::encode(key_id_of(&pk)),
                        envelope_b64: BASE64_STANDARD.encode(b"x"),
                        access_key_hex: hex::encode(key),
                        ttl_secs: 0,
                        urgent: false,
                        push_preview_b64: None,
                        drop_after_secs: 0,
                    })
                    .collect();
                let r = anonymous_submit(State(st), Json(AnonSubmit { message_id: uuid::Uuid::now_v7().to_string(), deliveries })).await.unwrap();
                (r.0.accepted, r.0.refused)
            }
        };
        // The blocked sender first: the same answer, and the other's limit is untouched.
        assert_eq!(send(blocked).await, (3, 2), "a blocked key");
        assert_eq!(send(active).await, (3, 2), "a working key");
        let (rows,): (i64,) = sqlx::query_as("SELECT count(*) FROM message_deliveries").fetch_one(&pool).await.unwrap();
        assert_eq!(rows, 1, "one message id from the working key; nothing from the blocked one");
    }

    /// GRP-4 — a person keeps the 32 newest delivery keys of a week, however
    /// many they publish, and can't publish without end. A week of cutting
    /// off three devices and a restore (5 generations) keeps every key.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn delivery_keys_are_capped_per_person_and_week(pool: sqlx::PgPool) {
        let sk = SigningKey::from_bytes(&[8u8; 32]);
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let w = current_week(now);
        let count = || async {
            let (n,): (i64,) = sqlx::query_as("SELECT count(*) FROM sealed_keys").fetch_one(&pool).await.unwrap();
            n
        };
        for i in 0..9u8 {
            let keys: Vec<(i32, [u8; 32])> = (0..4u8).map(|j| (w, [i * 4 + j + 1; 32])).collect();
            let _ = put(State(state(pool.clone())), Json(signed_put(&sk, &keys, now))).await.unwrap();
            if i == 4 {
                assert_eq!(count().await, 20, "five generations in a week all stay");
            }
        }
        let _ = put(State(state(pool.clone())), Json(signed_put(&sk, &[(w + 1, [99u8; 32])], now))).await.unwrap();
        let got = get(State(state(pool.clone())), Query(GetQuery { identities: hex::encode(sk.verifying_key().to_bytes()) }))
            .await
            .unwrap()
            .0
            .keys;
        assert_eq!(got.len(), 33, "32 of this week + next week's");
        assert_eq!(got[0].public_hex, hex::encode([36u8; 32]), "the newest stay");
        assert_eq!(got[32].public_hex, hex::encode([99u8; 32]));

        let mut refused = 0;
        for _ in 0..120 {
            match put(State(state(pool.clone())), Json(signed_put(&sk, &[(w, [1u8; 32])], now))).await {
                Err(SealedKeysError::TooMany) => refused += 1,
                r => drop(r.unwrap()),
            }
        }
        assert_eq!(refused, 10, "120 an hour, 10 used above");
    }

    /// GRP-5 — the access-key version can't be published out of a
    /// rotation's reach (it went to the maximum, for good).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn the_access_version_cannot_jump_to_the_maximum(pool: sqlx::PgPool) {
        let sk = SigningKey::from_bytes(&[9u8; 32]);
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let keys = [(current_week(now), [1u8; 32])];
        let v = |version: i32| {
            let (pool, req) = (pool.clone(), signed_put_versioned(&sk, &keys, [version as u8; 32], version, now));
            async move { put(State(state(pool)), Json(req)).await.unwrap().0.access_version }
        };
        assert_eq!(v(i32::MAX).await, 0, "ignored");
        assert_eq!(v(1).await, 1, "a rotation still works");
        assert_eq!(v(101).await, 101);
        assert_eq!(v(202).await, 101, "more than 100 ahead");
    }
}
