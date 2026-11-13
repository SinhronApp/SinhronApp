// KeyPackage upload + consume — WU A4.
//
// Wire contracts:
//
//   POST /v1/keypackages
//     {
//       "device_pk_hex": "64 hex",            // 32-byte device pubkey
//       "kp_bytes_b64": "base64",             // RFC 9420 TLS-encoded KeyPackage
//       "upload_proof_ts": 1716405123,        // unix seconds
//       "upload_proof_hex": "128 hex"         // Ed25519 sig over canonical msg
//     }
//     → 201 with { keypackage_id, expires_at } on success
//     → 401 if signature / device mismatch
//     → 404 if device not registered
//     → 400 on malformed inputs
//
//   GET /v1/keypackages/consume?identity_pubkey_hex=...&count=N
//       &signer_pk_hex=...&proof_ts=...&proof_hex=...
//     → 200 with [{ device_pk_hex, keypackage_id, kp_bytes_b64 }, ...]
//     Consumes one KeyPackage per device of the target identity. Uses
//     FOR UPDATE SKIP LOCKED so concurrent consumers don't race.
//     Signed (KP_CONSUME_DOMAIN, body = the target identity key) by a
//     registered, active device — 401 otherwise (server-http:5).
//     → 404 if identity unknown
//     → 200 with [] if pool exhausted
//
//   GET /v1/keypackages/available?identities=<hex>,<hex>…   (tech-debt 2.34)
//     → 200 { "missing": [hex, …] } — who of them has no KeyPackage on any
//     active device (or isn't registered). Consumes nothing: a group is
//     created only when everyone can be added, so nobody's KeyPackages are
//     used up for a group that then fails. At most MAX_AVAILABLE_QUERY.

use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use base64::{prelude::BASE64_STANDARD, Engine};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::{debug, error, info};
use uuid::Uuid;

use super::proof::{self, KP_CONSUME_DOMAIN, UPLOAD_KP_DOMAIN};
use crate::rate_limit::StaticLimiter;
use crate::AppState;

/// Anyone could empty a person's pool, and nobody could add them to a chat
/// or link their new phone (security review 2026-11-02). Taking is signed
/// by a registered device now (server-http:5) and limited per person taken
/// from, per caller account and per caller IP.
static CONSUME_PER_TARGET: StaticLimiter = StaticLimiter::new("SINHRON_RATE_KP_CONSUME_TARGET", 60, 3_600);
static CONSUME_PER_IP: StaticLimiter = StaticLimiter::new("SINHRON_RATE_KP_CONSUME_IP", 240, 3_600);
static CONSUME_PER_CALLER: StaticLimiter = StaticLimiter::new("SINHRON_RATE_KP_CONSUME_CALLER", 240, 3_600);
/// DEV-4 — one account took a person's whole stock (~20 a device, one from
/// every device per request) in 20 requests. An account takes from one
/// other person this often; own devices (device sync, one per chat) are
/// not counted.
static CONSUME_PER_PAIR: StaticLimiter = StaticLimiter::new("SINHRON_RATE_KP_CONSUME_PAIR", 40, 3_600);

// ─────────────────────────────────────────────────────────────────────
// Upload
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct UploadRequest {
    pub device_pk_hex: String,
    pub kp_bytes_b64: String,
    pub upload_proof_ts: i64,
    pub upload_proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct UploadResponse {
    pub keypackage_id: Uuid,
    #[serde(with = "time::serde::rfc3339")]
    pub expires_at: OffsetDateTime,
}

/// TTL for fresh KeyPackages per spec §7.6 (30 days OR until consume).
const KP_TTL_DAYS: i64 = 30;

/// Largest KeyPackage stored (a real one is a few hundred bytes).
const MAX_KP_BYTES: usize = 16 * 1024;
/// Unused KeyPackages kept per device: the app keeps ~20 and adds one per
/// launch, so even 30 days of many launches fit.
const MAX_WAITING_KPS: i64 = 1_000;

pub async fn upload(
    State(state): State<AppState>,
    Json(req): Json<UploadRequest>,
) -> Result<(StatusCode, Json<UploadResponse>), KpError> {
    let pool = state.pool.ok_or(KpError::NoDb)?;

    // ── Parse + validate request ─────────────────────────────────────
    let device_pk = hex::decode(&req.device_pk_hex)
        .map_err(|e| KpError::BadRequest(format!("device_pk_hex: {e}")))?;
    if device_pk.len() != 32 {
        return Err(KpError::BadRequest(format!(
            "device_pk must be 32 bytes, got {}",
            device_pk.len()
        )));
    }
    let kp_bytes = BASE64_STANDARD
        .decode(&req.kp_bytes_b64)
        .map_err(|e| KpError::BadRequest(format!("kp_bytes_b64: {e}")))?;
    // server-http:6 — a real KeyPackage is well under 1 KB; up to 1.5 MB
    // each, unlimited, was a way to fill the disk.
    if kp_bytes.is_empty() || kp_bytes.len() > MAX_KP_BYTES {
        return Err(KpError::BadRequest(format!("kp_bytes must be 1..={MAX_KP_BYTES} bytes")));
    }
    let proof_sig = hex::decode(&req.upload_proof_hex)
        .map_err(|e| KpError::BadRequest(format!("upload_proof_hex: {e}")))?;

    // ── Look up the device — also fetches the credential we'll verify against ──
    let device_row: Option<(Vec<u8>,)> = sqlx::query_as(
        "SELECT credential FROM devices WHERE device_pk = $1 AND revoked_at IS NULL",
    )
    .bind(&device_pk)
    .fetch_optional(&pool)
    .await?;
    let credential = match device_row {
        Some(r) => r.0,
        None => return Err(KpError::NotFound("device not registered".to_string())),
    };

    // For now, device credential bytes ARE the device's Ed25519 pubkey
    // (32 bytes). When we adopt full MLS BasicCredential serialization
    // (TLS-encoded per RFC 9420), this becomes a parser call.
    if credential.len() != 32 {
        return Err(KpError::Db(sqlx::Error::Protocol(
            "stored device credential is not 32 bytes — schema invariant broken".into(),
        )));
    }

    // ── Verify timestamped action proof ──────────────────────────────
    let now_secs = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(
        UPLOAD_KP_DOMAIN,
        &credential,
        &kp_bytes,
        req.upload_proof_ts,
        &proof_sig,
        now_secs,
    )
    .map_err(map_proof_err)?;

    // T1.5 — rate-limit by device_pk_hex. Same device can't burn more
    // than the configured cap per window (default 100/hour). After the
    // proof: unsigned requests naming someone's device used up its bucket
    // and it could not refill (docs/security-review-2026-11.md, server-http:4).
    if let Err(retry_after) = state.rate.check_kp_upload(&req.device_pk_hex) {
        info!(
            device_prefix = %crate::short_key(&req.device_pk_hex),
            retry_after_secs = retry_after.as_secs(),
            "rate-limited kp upload",
        );
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["kp_upload"])
            .inc();
        return Err(KpError::RateLimited {
            retry_after_secs: retry_after.as_secs(),
        });
    }

    let (waiting,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM keypackages WHERE device_pk = $1 AND consumed_at IS NULL AND expires_at > NOW()",
    )
    .bind(&device_pk)
    .fetch_one(&pool)
    .await?;
    if waiting >= MAX_WAITING_KPS {
        return Err(KpError::RateLimited { retry_after_secs: 3_600 });
    }

    // ── Insert ────────────────────────────────────────────────────────
    let kp_id = Uuid::now_v7();
    let expires_at = OffsetDateTime::now_utc() + time::Duration::days(KP_TTL_DAYS);

    sqlx::query(
        "INSERT INTO keypackages \
         (keypackage_id, device_pk, kp_bytes, uploaded_at, expires_at) \
         VALUES ($1, $2, $3, NOW(), $4)",
    )
    .bind(kp_id)
    .bind(&device_pk)
    .bind(&kp_bytes)
    .bind(expires_at)
    .execute(&pool)
    .await?;

    let _ = sqlx::query("UPDATE devices SET last_seen_at = NOW() WHERE device_pk = $1")
        .bind(&device_pk)
        .execute(&pool)
        .await;
    info!(keypackage_id = %kp_id, device_pk = %crate::short_key(&req.device_pk_hex), "kp uploaded");
    Ok((
        StatusCode::CREATED,
        Json(UploadResponse {
            keypackage_id: kp_id,
            expires_at,
        }),
    ))
}

// ─────────────────────────────────────────────────────────────────────
// Consume
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ConsumeQuery {
    /// Identity to fetch KeyPackages for — hex-encoded 32-byte
    /// ed25519 identity pubkey.
    pub identity_pubkey_hex: String,
    /// How many KeyPackages to consume. Capped at MAX_CONSUME_BATCH so
    /// a single request can't drain the pool.
    #[serde(default = "default_consume_count")]
    pub count: u32,
    /// ADR-025 — one KeyPackage from EACH active device of the person
    /// (inviting someone adds all their devices). `count` is ignored.
    #[serde(default)]
    pub per_device: bool,
    /// With `per_device`: only these devices (comma-separated hex) —
    /// device sync adds just the missing ones.
    #[serde(default)]
    pub devices: Option<String>,
    /// server-http:5 — who takes them: the identity key or an active
    /// linked device's key, and its action proof over the target identity.
    #[serde(default)]
    pub signer_pk_hex: String,
    #[serde(default)]
    pub proof_ts: i64,
    #[serde(default)]
    pub proof_hex: String,
}

fn default_consume_count() -> u32 {
    1
}

/// Every app asks for one (`count=1`, or `per_device`); ten emptied a
/// person's whole stock in two requests (server-http:5).
const MAX_CONSUME_BATCH: u32 = 1;

/// A consume of [identity]'s KeyPackages signed by [signer] (tests).
#[cfg(test)]
pub(crate) fn signed_consume(signer: &ed25519_dalek::SigningKey, identity: &[u8], count: u32, per_device: bool, devices: Option<String>) -> ConsumeQuery {
    use ed25519_dalek::Signer;
    use sha2::{Digest, Sha256};
    let ts = OffsetDateTime::now_utc().unix_timestamp();
    let mut m = KP_CONSUME_DOMAIN.to_vec();
    m.push(b':');
    m.extend_from_slice(&Sha256::digest(identity));
    m.push(b':');
    m.extend_from_slice(&ts.to_be_bytes());
    ConsumeQuery {
        identity_pubkey_hex: hex::encode(identity),
        count,
        per_device,
        devices,
        signer_pk_hex: hex::encode(signer.verifying_key().to_bytes()),
        proof_ts: ts,
        proof_hex: hex::encode(signer.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
    }
}

#[derive(Debug, Serialize)]
pub struct ConsumeItem {
    pub keypackage_id: Uuid,
    pub device_pk_hex: String,
    pub kp_bytes_b64: String,
}

pub async fn consume(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<ConsumeQuery>,
) -> Result<Json<Vec<ConsumeItem>>, KpError> {
    let pool = state.pool.ok_or(KpError::NoDb)?;

    let identity_pubkey = hex::decode(&q.identity_pubkey_hex)
        .map_err(|e| KpError::BadRequest(format!("identity_pubkey_hex: {e}")))?;
    if identity_pubkey.len() != 32 {
        return Err(KpError::BadRequest(format!(
            "identity_pubkey must be 32 bytes, got {}",
            identity_pubkey.len()
        )));
    }
    let limited = |r: Result<(), std::time::Duration>| r.map_err(|d| KpError::RateLimited { retry_after_secs: d.as_secs() });
    if let Some(ip) = crate::admin::client_rate_key(&headers) {
        limited(CONSUME_PER_IP.check(&ip))?;
    }
    // server-http:5 — a stranger with no account drained anyone's pool.
    let signer = hex::decode(&q.signer_pk_hex).map_err(|e| KpError::BadRequest(format!("signer_pk_hex: {e}")))?;
    let sig = hex::decode(&q.proof_hex).map_err(|e| KpError::BadRequest(format!("proof_hex: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(KP_CONSUME_DOMAIN, &signer, &identity_pubkey, q.proof_ts, &sig, now)
        .map_err(|e| KpError::Unauthorized(e.to_string()))?;
    let Some((caller, _)) = crate::accounts::resolve_signer(&pool, &signer).await? else {
        return Err(KpError::Unauthorized("not an active device".into()));
    };
    limited(CONSUME_PER_CALLER.check(&caller.to_string()))?;
    let mut only: Vec<Vec<u8>> = Vec::new();
    for h in q.devices.as_deref().unwrap_or("").split(',').filter(|h| !h.is_empty()) {
        only.push(hex::decode(h).map_err(|e| KpError::BadRequest(format!("devices: {e}")))?);
    }
    // The person's bucket pays only for KeyPackages handed out: 404s,
    // empty answers and bad requests used it up, and nobody could add them
    // to a chat for an hour (docs/security-review-2026-11.md, server-http:5).
    let target = hex::encode(&identity_pubkey);
    limited(CONSUME_PER_TARGET.check(&target))?;
    let count = q.count.clamp(1, MAX_CONSUME_BATCH) as i64;

    // Verify the identity exists. Returns 404 to distinguish "unknown
    // user" from "user exists but pool empty" (which returns [] with 200).
    let user_pk: Option<(Uuid,)> =
        sqlx::query_as("SELECT user_pk FROM users WHERE identity_pubkey = $1")
            .bind(&identity_pubkey)
            .fetch_optional(&pool)
            .await?;
    let Some((user_pk,)) = user_pk else {
        CONSUME_PER_TARGET.refund(&target);
        return Err(KpError::NotFound("identity not registered".to_string()));
    };
    // DEV-4 — paid, like the person's bucket, only for KeyPackages handed out.
    let pair = (user_pk != caller).then(|| format!("{caller}>{target}"));
    if let Some(pair) = &pair {
        if let Err(e) = limited(CONSUME_PER_PAIR.check(pair)) {
            CONSUME_PER_TARGET.refund(&target);
            return Err(e);
        }
    }

    // ── Atomic consume ────────────────────────────────────────────────
    //
    // We need:
    //   1. SELECT up to `count` rows from keypackages WHERE:
    //        device_pk → device whose user_pk matches the queried identity
    //        AND consumed_at IS NULL
    //        AND expires_at > NOW()
    //      ordered by uploaded_at ASC (FIFO — oldest first).
    //   2. UPDATE those rows to set consumed_at = NOW().
    //   3. Return the kp_bytes.
    //
    // Done as a single CTE with FOR UPDATE SKIP LOCKED so concurrent
    // consumers don't grab the same rows.
    let picked = if q.per_device {
        // One per active device; LATERAL so each pick can lock its row.
        "SELECT k.keypackage_id
            FROM devices d
            JOIN users u ON u.user_pk = d.user_pk
            CROSS JOIN LATERAL (
                SELECT kp.keypackage_id FROM keypackages kp
                WHERE kp.device_pk = d.device_pk
                  AND kp.consumed_at IS NULL
                  AND kp.expires_at > NOW()
                ORDER BY kp.uploaded_at ASC
                LIMIT 1
                FOR UPDATE SKIP LOCKED
            ) k
            WHERE u.identity_pubkey = $1 AND d.revoked_at IS NULL AND $2 > 0
              AND (cardinality($3::bytea[]) = 0 OR d.device_pk = ANY($3))"
    } else {
        "SELECT kp.keypackage_id
            FROM keypackages kp
            JOIN devices d ON d.device_pk = kp.device_pk
            JOIN users u   ON u.user_pk   = d.user_pk
            WHERE u.identity_pubkey = $1
              AND d.revoked_at IS NULL
              AND kp.consumed_at IS NULL
              AND kp.expires_at > NOW()
            ORDER BY kp.uploaded_at ASC
            LIMIT $2
            FOR UPDATE OF kp SKIP LOCKED"
    };
    let sql = format!(
        "WITH picked AS ({picked})
        UPDATE keypackages SET consumed_at = NOW()
        FROM picked
        WHERE keypackages.keypackage_id = picked.keypackage_id
        RETURNING keypackages.keypackage_id,
                  keypackages.device_pk,
                  keypackages.kp_bytes"
    );
    let mut query = sqlx::query_as::<_, (Uuid, Vec<u8>, Vec<u8>)>(&sql).bind(&identity_pubkey).bind(count);
    if q.per_device {
        query = query.bind(&only);
    }
    let rows = query.fetch_all(&pool).await?;
    if rows.is_empty() {
        CONSUME_PER_TARGET.refund(&target);
        if let Some(pair) = &pair {
            CONSUME_PER_PAIR.refund(pair);
        }
    }

    let items: Vec<ConsumeItem> = rows
        .into_iter()
        .map(|(id, dpk, kpb)| ConsumeItem {
            keypackage_id: id,
            device_pk_hex: hex::encode(&dpk),
            kp_bytes_b64: BASE64_STANDARD.encode(&kpb),
        })
        .collect();

    debug!(
        identity = %crate::short_key(&q.identity_pubkey_hex),
        consumed = items.len(),
        "kp consume"
    );
    Ok(Json(items))
}

#[derive(Debug, Deserialize)]
pub struct AvailableQuery {
    /// Comma-separated identity keys (hex).
    pub identities: String,
}

#[derive(Debug, Serialize)]
pub struct AvailableReply {
    pub missing: Vec<String>,
}

const MAX_AVAILABLE_QUERY: usize = 50;

pub async fn available(
    State(state): State<AppState>,
    Query(q): Query<AvailableQuery>,
) -> Result<Json<AvailableReply>, KpError> {
    let pool = state.pool.ok_or(KpError::NoDb)?;
    let mut wanted: Vec<String> = Vec::new();
    for h in q.identities.split(',').map(|h| h.trim().to_ascii_lowercase()).filter(|h| !h.is_empty()) {
        let b = hex::decode(&h).map_err(|e| KpError::BadRequest(format!("identities: {e}")))?;
        if b.len() != 32 {
            return Err(KpError::BadRequest("identities: 32-byte keys".into()));
        }
        if !wanted.contains(&h) {
            wanted.push(h);
        }
    }
    if wanted.is_empty() || wanted.len() > MAX_AVAILABLE_QUERY {
        return Err(KpError::BadRequest(format!("identities: 1..{MAX_AVAILABLE_QUERY}")));
    }
    let keys: Vec<Vec<u8>> = wanted.iter().map(|h| hex::decode(h).unwrap_or_default()).collect();
    let have: Vec<(Vec<u8>,)> = sqlx::query_as(
        "SELECT u.identity_pubkey FROM users u
          WHERE u.identity_pubkey = ANY($1)
            AND EXISTS (SELECT 1 FROM devices d JOIN keypackages kp ON kp.device_pk = d.device_pk
                         WHERE d.user_pk = u.user_pk AND d.revoked_at IS NULL
                           AND kp.consumed_at IS NULL AND kp.expires_at > NOW())",
    )
    .bind(&keys)
    .fetch_all(&pool)
    .await?;
    let have: Vec<String> = have.into_iter().map(|(k,)| hex::encode(k)).collect();
    Ok(Json(AvailableReply { missing: wanted.into_iter().filter(|h| !have.contains(h)).collect() }))
}

#[cfg(test)]
mod available_tests {
    use super::*;

    fn state(pool: sqlx::PgPool) -> AppState {
        AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    // Tech-debt 2.34 — who can't be added is known before anyone's
    // KeyPackages are used up.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn says_who_has_no_keypackage_and_consumes_nothing(pool: sqlx::PgPool) {
        let with = [1u8; 32];
        let without = [2u8; 32];
        let revoked = [3u8; 32];
        for (id, dev, kp, revoke) in [(with, [11u8; 32], true, false), (without, [12u8; 32], false, false), (revoked, [13u8; 32], true, true)] {
            let u = uuid::Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&id[..]).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential, revoked_at) VALUES ($1, $2, $1, CASE WHEN $3 THEN NOW() END)")
                .bind(&dev[..])
                .bind(u)
                .bind(revoke)
                .execute(&pool)
                .await
                .unwrap();
            if kp {
                sqlx::query("INSERT INTO keypackages (keypackage_id, device_pk, kp_bytes, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 day')")
                    .bind(uuid::Uuid::now_v7())
                    .bind(&dev[..])
                    .bind(vec![9u8; 8])
                    .execute(&pool)
                    .await
                    .unwrap();
            }
        }
        let unknown = [4u8; 32];
        let ids = [with, without, revoked, unknown].iter().map(hex::encode).collect::<Vec<_>>().join(",");
        let Json(r) = available(State(state(pool.clone())), Query(AvailableQuery { identities: ids })).await.unwrap();
        assert_eq!(r.missing, vec![hex::encode(without), hex::encode(revoked), hex::encode(unknown)]);
        let left: (i64,) = sqlx::query_as("SELECT count(*) FROM keypackages WHERE consumed_at IS NULL").fetch_one(&pool).await.unwrap();
        assert_eq!(left.0, 2, "nothing consumed");
        assert!(matches!(
            available(State(state(pool)), Query(AvailableQuery { identities: "zz".into() })).await,
            Err(KpError::BadRequest(_))
        ));
    }

    fn upload_req(sk: &ed25519_dalek::SigningKey, kp: &[u8]) -> UploadRequest {
        use ed25519_dalek::Signer;
        use sha2::{Digest, Sha256};
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = UPLOAD_KP_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(kp));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        UploadRequest {
            device_pk_hex: hex::encode(sk.verifying_key().to_bytes()),
            kp_bytes_b64: BASE64_STANDARD.encode(kp),
            upload_proof_ts: ts,
            upload_proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    async fn person(pool: &sqlx::PgPool, pk: &[u8]) {
        let u = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(pk).execute(pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(pk).bind(u).execute(pool).await.unwrap();
    }

    // server-http:4 — a stranger's 150 unsigned uploads naming my device no
    // longer use up my bucket: my own upload still goes through.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn junk_uploads_in_my_name_do_not_lock_out_my_refill(pool: sqlx::PgPool) {
        let me = ed25519_dalek::SigningKey::from_bytes(&[0x51u8; 32]);
        person(&pool, &me.verifying_key().to_bytes()).await;
        let st = state(pool.clone());
        for _ in 0..150 {
            let mut junk = upload_req(&me, b"kp");
            junk.upload_proof_hex = hex::encode([0u8; 64]);
            assert!(matches!(upload(State(st.clone()), Json(junk)).await, Err(KpError::Unauthorized(_))));
        }
        let (status, _) = upload(State(st), Json(upload_req(&me, b"kp"))).await.expect("my own upload");
        assert_eq!(status, StatusCode::CREATED);
    }

    // server-http:6 — KeyPackages as disk filler: a 20 KB one is refused,
    // and so is the 1001st unused one of a device; a real one is stored.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn keypackages_cannot_fill_the_disk(pool: sqlx::PgPool) {
        let me = ed25519_dalek::SigningKey::from_bytes(&[0x53u8; 32]);
        let pk = me.verifying_key().to_bytes();
        person(&pool, &pk).await;
        let st = state(pool.clone());
        assert!(matches!(upload(State(st.clone()), Json(upload_req(&me, &[1u8; 20_000]))).await, Err(KpError::BadRequest(_))));
        assert!(upload(State(st.clone()), Json(upload_req(&me, &[1u8; 500]))).await.is_ok());
        sqlx::query(
            "INSERT INTO keypackages (keypackage_id, device_pk, kp_bytes, expires_at) \
             SELECT gen_random_uuid(), $1, '\\x01', NOW() + interval '1 day' FROM generate_series(1, 999)",
        )
        .bind(&pk[..])
        .execute(&pool)
        .await
        .unwrap();
        assert!(matches!(upload(State(st), Json(upload_req(&me, &[1u8; 500]))).await, Err(KpError::RateLimited { .. })));
    }

    // server-http:5 — count=10 hands out one; empty answers and bad
    // requests don't use up the person's limit (60 an hour), so a real
    // consume still works after 120 of them.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn empty_answers_do_not_lock_a_person_out_and_one_at_a_time(pool: sqlx::PgPool) {
        let victim = [0x52u8; 32];
        person(&pool, &victim).await;
        let caller = ed25519_dalek::SigningKey::from_bytes(&[0x54u8; 32]);
        person(&pool, &caller.verifying_key().to_bytes()).await;
        let q = |count: u32, per_device: bool, devices: Option<&str>| Query(signed_consume(&caller, &victim, count, per_device, devices.map(String::from)));
        let st = state(pool.clone());
        for _ in 0..40 {
            assert!(consume(State(st.clone()), HeaderMap::new(), q(10, false, None)).await.unwrap().0.is_empty());
            assert!(consume(State(st.clone()), HeaderMap::new(), q(1, true, Some(&hex::encode([9u8; 32])))).await.unwrap().0.is_empty());
            assert!(matches!(consume(State(st.clone()), HeaderMap::new(), q(1, true, Some("zz"))).await, Err(KpError::BadRequest(_))));
        }
        for _ in 0..3 {
            sqlx::query("INSERT INTO keypackages (keypackage_id, device_pk, kp_bytes, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 day')")
                .bind(uuid::Uuid::now_v7())
                .bind(&victim[..])
                .bind(vec![9u8; 8])
                .execute(&pool)
                .await
                .unwrap();
        }
        let Json(got) = consume(State(st), HeaderMap::new(), q(10, false, None)).await.expect("not locked out");
        assert_eq!(got.len(), 1, "one per request");
    }

    // server-http:5 — someone with no account (or a revoked device) took a
    // person's KeyPackages unsigned; now only a registered device may.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_stranger_without_a_device_can_not_take_my_keypackages(pool: sqlx::PgPool) {
        let victim = [0x55u8; 32];
        person(&pool, &victim).await;
        sqlx::query("INSERT INTO keypackages (keypackage_id, device_pk, kp_bytes, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 day')")
            .bind(uuid::Uuid::now_v7())
            .bind(&victim[..])
            .bind(vec![9u8; 8])
            .execute(&pool)
            .await
            .unwrap();
        let st = state(pool.clone());
        let take = |q: ConsumeQuery| consume(State(st.clone()), HeaderMap::new(), Query(q));
        let stranger = ed25519_dalek::SigningKey::from_bytes(&[0x56u8; 32]);
        let mut unsigned = signed_consume(&stranger, &victim, 1, true, None);
        (unsigned.signer_pk_hex, unsigned.proof_hex, unsigned.proof_ts) = (String::new(), String::new(), 0);
        assert!(matches!(take(unsigned).await, Err(KpError::Unauthorized(_))), "unsigned, as old apps did");
        assert!(matches!(take(signed_consume(&stranger, &victim, 1, true, None)).await, Err(KpError::Unauthorized(_))), "no account");
        let caller = ed25519_dalek::SigningKey::from_bytes(&[0x57u8; 32]);
        person(&pool, &caller.verifying_key().to_bytes()).await;
        let mut forged = signed_consume(&caller, &victim, 1, true, None);
        forged.identity_pubkey_hex = hex::encode(caller.verifying_key().to_bytes());
        assert!(matches!(take(forged).await, Err(KpError::Unauthorized(_))), "a proof for another person");
        let left: (i64,) = sqlx::query_as("SELECT count(*) FROM keypackages WHERE consumed_at IS NULL").fetch_one(&pool).await.unwrap();
        assert_eq!(left.0, 1, "nothing taken");
        assert_eq!(take(signed_consume(&caller, &victim, 1, true, None)).await.unwrap().0.len(), 1, "a registered device may");
    }

    // DEV-4 — one registered stranger emptied a person's stock of 20 in 20
    // requests; now 40 an hour from one account, the rest stays. The
    // person's own devices are not limited (device sync, one per chat).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn one_account_can_not_empty_a_persons_stock(pool: sqlx::PgPool) {
        let victim = ed25519_dalek::SigningKey::from_bytes(&[0x58u8; 32]);
        let victim_pk = victim.verifying_key().to_bytes();
        person(&pool, &victim_pk).await;
        sqlx::query(
            "INSERT INTO keypackages (keypackage_id, device_pk, kp_bytes, expires_at) \
             SELECT gen_random_uuid(), $1, '\\x01', NOW() + interval '1 day' FROM generate_series(1, 60)",
        )
        .bind(&victim_pk[..])
        .execute(&pool)
        .await
        .unwrap();
        let stranger = ed25519_dalek::SigningKey::from_bytes(&[0x59u8; 32]);
        person(&pool, &stranger.verifying_key().to_bytes()).await;
        let st = state(pool.clone());
        let take = |who: &ed25519_dalek::SigningKey| consume(State(st.clone()), HeaderMap::new(), Query(signed_consume(who, &victim_pk, 1, true, None)));
        // A relative's new phone: three devices of one account each add it
        // to six shared chats, one request per chat — none is refused.
        for _ in 0..18 {
            assert_eq!(take(&stranger).await.unwrap().0.len(), 1, "3 devices x 6 chats");
        }
        let mut got = 18;
        for _ in 18..50 {
            match take(&stranger).await {
                Ok(Json(items)) => got += items.len(),
                Err(e) => assert!(matches!(e, KpError::RateLimited { .. })),
            }
        }
        assert_eq!(got, 40, "forty an hour from one account");
        for _ in 0..12 {
            assert_eq!(take(&victim).await.unwrap().0.len(), 1, "own devices are not limited");
        }
        let left: (i64,) = sqlx::query_as("SELECT count(*) FROM keypackages WHERE consumed_at IS NULL").fetch_one(&pool).await.unwrap();
        assert_eq!(left.0, 8);
        // The refused requests did not use up the person's own bucket (60).
        let friend = ed25519_dalek::SigningKey::from_bytes(&[0x5au8; 32]);
        person(&pool, &friend.verifying_key().to_bytes()).await;
        assert_eq!(take(&friend).await.unwrap().0.len(), 1, "someone else still can");
    }
}

// ─────────────────────────────────────────────────────────────────────
// Error envelope (shared between upload + consume)
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, thiserror::Error)]
pub enum KpError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("no db configured")]
    NoDb,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    /// T1.5 — rate-limit tripped. Client should back off `retry_after_secs`
    /// before retrying. Default policy: 100 uploads / hour per device_pk.
    #[error("rate limited; retry after {retry_after_secs}s")]
    RateLimited { retry_after_secs: u64 },
}

impl IntoResponse for KpError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            KpError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            KpError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            KpError::NotFound(m) => (StatusCode::NOT_FOUND, m.clone()),
            KpError::NoDb => (
                StatusCode::SERVICE_UNAVAILABLE,
                "no database configured".to_string(),
            ),
            KpError::Db(e) => {
                error!(error = %e, "db error in keypackages handler");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
            KpError::RateLimited { retry_after_secs } => {
                use axum::http::header;
                let mut resp = (
                    StatusCode::TOO_MANY_REQUESTS,
                    Json(serde_json::json!({
                        "error": "rate limited",
                        "retry_after_secs": retry_after_secs,
                    })),
                )
                    .into_response();
                resp.headers_mut().insert(
                    header::RETRY_AFTER,
                    retry_after_secs.to_string().parse().expect("ascii digits parse"),
                );
                return resp;
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

fn map_proof_err(e: proof::ProofError) -> KpError {
    match e {
        proof::ProofError::PubkeyLen(_) | proof::ProofError::SignatureLen(_) => {
            KpError::BadRequest(e.to_string())
        }
        proof::ProofError::StaleTimestamp { .. }
        | proof::ProofError::SignatureMismatch
        | proof::ProofError::PubkeyInvalid(_) => KpError::Unauthorized(e.to_string()),
    }
}
