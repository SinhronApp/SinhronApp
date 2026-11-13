// Per-contact access keys — ADR-071 (extends ADR-026).
//
//   PUT /v1/access-keys   a person publishes SHA-256 of the access key they
//                         give each chat partner (`add`), and their blocks /
//                         unblocks of those keys (`decisions`). Signed by the
//                         identity key (domain PUT_ACCESS_KEYS_DOMAIN).
//
// The server never learns whose key a hash is: the keys travel inside MLS.
// The first PUT turns on "per-contact" mode for the person; from then on:
//
//   POST /v1/sealed    active key → delivered (push if urgent); revoked key
//                      → accepted and dropped silently (no push, nothing
//                      stored, same answer); unknown or the old shared key
//                      → refused (the sender falls back to the WS route).
//   WS SealedSubmit /  no key on this route (it would link the key to the
//   Submit             signed-in sender, and a revocation would then show
//                      whom they blocked): delivered, never pushed, rate-
//                      limited per sender → recipient ("request").
//   CallInvite         carries the caller's keys: active → rings; revoked
//                      → swallowed; none → the open app only, no push.
//
// Someone who never published keeps the ADR-026 behaviour (one shared key).

use std::collections::{HashMap, HashSet};

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use subtle::ConstantTimeEq;
use time::OffsetDateTime;
use tracing::{error, info};
use uuid::Uuid;

use super::proof::{self, PUT_ACCESS_KEYS_DOMAIN};
use super::sealed_keys::ACCESS_KEY_LEN;
use crate::AppState;

/// Hashes in one PUT (adds + decisions each).
const MAX_PER_PUT: usize = 1000;
/// Keys one person may hold on the server: this many in use (contacts +
/// spares) and this many blocked, counted apart (GRP-5: junk blocks, which
/// never go, used up the room for new contacts' keys).
const MAX_KEYS_PER_USER: i64 = 5000;
/// GRP-5 — how far ahead of the stored one a published version may be (a
/// rotation is +1): a device set it to the maximum and no rotation was
/// possible ever after.
pub const MAX_VERSION_STEP: i64 = 100;
/// GRP-5 — a decision counts as made a day from now at the latest: a block
/// dated to the end of time could never be lifted.
const MAX_DECISION_AHEAD_MS: i64 = 86_400_000;
/// GRP-7 — PUTs per person (the app sends a few when chats or blocks change).
static PUT_PER_USER: crate::rate_limit::StaticLimiter = crate::rate_limit::StaticLimiter::new("SINHRON_RATE_ACCESS_KEYS", 600, 3_600);

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct Decision {
    pub hash_hex: String,
    /// true = blocked (key revoked), false = unblocked.
    pub revoked: bool,
    /// When it was decided (ms since the epoch, the device's clock).
    pub at_ms: i64,
}

#[derive(Debug, Deserialize)]
pub struct PutRequest {
    pub identity_pubkey_hex: String,
    /// The person's access-key version these hashes belong to.
    pub access_version: i32,
    /// Hashes of keys being handed out. Never re-activates a revoked one.
    #[serde(default)]
    pub add_hex: Vec<String>,
    #[serde(default)]
    pub decisions: Vec<Decision>,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct PutResponse {
    /// The person's current version — a device behind it adopts it and
    /// publishes again (another of their devices rotated the keys).
    pub access_version: i32,
    /// Rows newly stored or changed by this request.
    pub changed: usize,
}

/// What a PUT signs: version, then each add (tag 1 ‖ hash), then each
/// decision (tag 2 = revoke / 3 = unblock ‖ hash ‖ at_ms).
pub fn signed_body(version: i32, adds: &[Vec<u8>], decisions: &[(Vec<u8>, bool, i64)]) -> Vec<u8> {
    let mut b = Vec::with_capacity(4 + adds.len() * 33 + decisions.len() * 41);
    b.extend_from_slice(&version.to_be_bytes());
    for h in adds {
        b.push(1);
        b.extend_from_slice(h);
    }
    for (h, revoked, at) in decisions {
        b.push(if *revoked { 2 } else { 3 });
        b.extend_from_slice(h);
        b.extend_from_slice(&at.to_be_bytes());
    }
    b
}

fn hash32(h: &str) -> Result<Vec<u8>, AccessKeysError> {
    let b = hex::decode(h).map_err(|e| AccessKeysError::BadRequest(format!("hash: {e}")))?;
    if b.len() != 32 {
        return Err(AccessKeysError::BadRequest("hash must be 32 bytes".into()));
    }
    Ok(b)
}

pub async fn put(State(state): State<AppState>, Json(req): Json<PutRequest>) -> Result<Json<PutResponse>, AccessKeysError> {
    let pool = state.pool.ok_or(AccessKeysError::NoDb)?;
    let identity = hex::decode(&req.identity_pubkey_hex).map_err(|e| AccessKeysError::BadRequest(format!("identity: {e}")))?;
    if req.add_hex.len() > MAX_PER_PUT || req.decisions.len() > MAX_PER_PUT {
        return Err(AccessKeysError::BadRequest(format!("at most {MAX_PER_PUT} adds and {MAX_PER_PUT} decisions")));
    }
    if req.access_version < 0 {
        return Err(AccessKeysError::BadRequest("negative version".into()));
    }
    let adds: Vec<Vec<u8>> = req.add_hex.iter().map(|h| hash32(h)).collect::<Result<_, _>>()?;
    let decisions: Vec<(Vec<u8>, bool, i64)> =
        req.decisions.iter().map(|d| Ok((hash32(&d.hash_hex)?, d.revoked, d.at_ms.max(0)))).collect::<Result<_, _>>()?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let sig = hex::decode(&req.proof_hex).map_err(|e| AccessKeysError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        PUT_ACCESS_KEYS_DOMAIN,
        &identity,
        &signed_body(req.access_version, &adds, &decisions),
        req.proof_ts,
        &sig,
        now,
    )
    .map_err(|e| AccessKeysError::Unauthorized(e.to_string()))?;
    // ADR-027 — or one of the person's active linked devices.
    let Some((user_pk, _)) = crate::accounts::resolve_signer(&pool, &identity).await.map_err(AccessKeysError::db)? else {
        return Err(AccessKeysError::Unauthorized("unknown identity".into()));
    };
    if PUT_PER_USER.check(&user_pk.to_string()).is_err() {
        return Err(AccessKeysError::TooMany);
    }

    let mut tx = pool.begin().await.map_err(AccessKeysError::db)?;
    // Per-contact mode from now on; a newer version replaces the old one.
    let current: Option<(i32,)> = sqlx::query_as(
        "UPDATE users SET access_per_contact = TRUE, access_version = GREATEST(access_version, $2) \
         WHERE user_pk = $1 AND $2::bigint <= access_version::bigint + $3 RETURNING access_version",
    )
    .bind(user_pk)
    .bind(req.access_version)
    .bind(MAX_VERSION_STEP)
    .fetch_optional(&mut *tx)
    .await
    .map_err(AccessKeysError::db)?;
    let Some((current,)) = current else {
        return Err(AccessKeysError::BadRequest("version too far ahead".into()));
    };
    if req.access_version < current {
        // A device behind a rotation: it adopts `current` and comes back.
        tx.commit().await.map_err(AccessKeysError::db)?;
        return Ok(Json(PutResponse { access_version: current, changed: 0 }));
    }
    // Keys of older versions stop working — except revoked ones, which
    // keep dropping what the blocked person still sends with them.
    sqlx::query("DELETE FROM access_keys WHERE user_pk = $1 AND version < $2 AND NOT revoked")
        .bind(user_pk)
        .bind(current)
        .execute(&mut *tx)
        .await
        .map_err(AccessKeysError::db)?;
    // GRP-7 — one statement each, not one per hash (up to 2000 round trips
    // inside this transaction held the pool).
    // A revoked key stays revoked: only an unblock decision lifts it.
    let added = sqlx::query(
        "INSERT INTO access_keys (user_pk, key_hash, version) SELECT $1, h, $3 FROM UNNEST($2::bytea[]) AS t(h) \
         ON CONFLICT (user_pk, key_hash) DO NOTHING",
    )
    .bind(user_pk)
    .bind(&adds)
    .bind(current)
    .execute(&mut *tx)
    .await
    .map_err(AccessKeysError::db)?;
    // The later decision wins (equal times: the block) — in the request
    // (a hash named twice) and against what is stored.
    let hashes: Vec<Vec<u8>> = decisions.iter().map(|d| d.0.clone()).collect();
    let flags: Vec<bool> = decisions.iter().map(|d| d.1).collect();
    let latest = now.saturating_mul(1000).saturating_add(MAX_DECISION_AHEAD_MS);
    let times: Vec<i64> = decisions.iter().map(|d| d.2.min(latest)).collect();
    let decided = sqlx::query(
        "INSERT INTO access_keys (user_pk, key_hash, version, revoked, decided_ms) \
         SELECT DISTINCT ON (h) $1, h, $3, r, at FROM UNNEST($2::bytea[], $4::bool[], $5::bigint[]) AS t(h, r, at) \
         ORDER BY h, at DESC, r DESC \
         ON CONFLICT (user_pk, key_hash) DO UPDATE SET revoked = excluded.revoked, decided_ms = excluded.decided_ms, \
             version = GREATEST(access_keys.version, excluded.version) \
         WHERE access_keys.decided_ms < excluded.decided_ms \
            OR (access_keys.decided_ms = excluded.decided_ms AND excluded.revoked AND NOT access_keys.revoked)",
    )
    .bind(user_pk)
    .bind(&hashes)
    .bind(current)
    .bind(&flags)
    .bind(&times)
    .execute(&mut *tx)
    .await
    .map_err(AccessKeysError::db)?;
    // The quota, counted on what is stored after this request (NEW-3): the
    // app sends every decision again each time, and counting those on top
    // of their own rows refused the whole PUT once the quota was near.
    // Past it nothing is kept — the transaction is dropped.
    let (held, blocked): (i64, i64) =
        sqlx::query_as("SELECT count(*) FILTER (WHERE NOT revoked), count(*) FILTER (WHERE revoked) FROM access_keys WHERE user_pk = $1")
            .bind(user_pk)
            .fetch_one(&mut *tx)
            .await
            .map_err(AccessKeysError::db)?;
    if held > MAX_KEYS_PER_USER || blocked > MAX_KEYS_PER_USER {
        return Err(AccessKeysError::BadRequest(format!("at most {MAX_KEYS_PER_USER} keys per person")));
    }
    let changed = (added.rows_affected() + decided.rows_affected()) as usize;
    tx.commit().await.map_err(AccessKeysError::db)?;
    // Counts only — never which hashes.
    info!(adds = adds.len(), decisions = decisions.len(), changed, "access keys published");
    Ok(Json(PutResponse { access_version: current, changed }))
}

/// What happens to an unauthenticated delivery to a person.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnonVerdict {
    /// A key they handed out and didn't revoke (or, ADR-026, their shared key).
    Deliver,
    /// A key they revoked: answer "accepted", store nothing, push nothing.
    DropSilently,
    /// No such key: refused, the sender may try the signed-in route.
    Refuse,
}

/// The verdict for [access_key] sent to [recipient].
pub async fn anonymous_verdict(pool: &PgPool, recipient: Uuid, access_key: &[u8]) -> sqlx::Result<AnonVerdict> {
    if access_key.len() != ACCESS_KEY_LEN {
        return Ok(AnonVerdict::Refuse);
    }
    let hash = Sha256::digest(access_key);
    let user: Option<(bool, Option<Vec<u8>>)> =
        sqlx::query_as("SELECT access_per_contact, access_hash FROM users WHERE user_pk = $1")
            .bind(recipient)
            .fetch_optional(pool)
            .await?;
    let Some((per_contact, shared)) = user else { return Ok(AnonVerdict::Refuse) };
    if !per_contact {
        // ADR-026 — one shared key.
        let ok = shared.is_some_and(|h| bool::from(h.as_slice().ct_eq(hash.as_slice())));
        return Ok(if ok { AnonVerdict::Deliver } else { AnonVerdict::Refuse });
    }
    let row: Option<(bool,)> = sqlx::query_as("SELECT revoked FROM access_keys WHERE user_pk = $1 AND key_hash = $2")
        .bind(recipient)
        .bind(hash.as_slice())
        .fetch_optional(pool)
        .await?;
    Ok(match row {
        Some((false,)) => AnonVerdict::Deliver,
        Some((true,)) => AnonVerdict::DropSilently,
        // My old shared key no longer delivers once I hand out per-contact
        // keys (the status-181 transition switch went 2026-11-04): someone
        // I blocked who kept it can't wake me with it (sealed-push:4).
        None => AnonVerdict::Refuse,
    })
}

/// Which of [users] are in per-contact mode: deliveries to them that
/// carry no key (WS, plain Submit) arrive but never push.
pub async fn per_contact_users<'e>(ex: impl sqlx::PgExecutor<'e>, users: &[Uuid]) -> sqlx::Result<HashSet<Uuid>> {
    if users.is_empty() {
        return Ok(HashSet::new());
    }
    let rows: Vec<(Uuid,)> = sqlx::query_as("SELECT user_pk FROM users WHERE user_pk = ANY($1) AND access_per_contact")
        .bind(users)
        .fetch_all(ex)
        .await?;
    Ok(rows.into_iter().map(|(u,)| u).collect())
}

/// What a call invite does for one invitee.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallVerdict {
    /// Rings: the open app and a push (as before ADR-071).
    Ring,
    /// The open app only, no push (no key: a stranger, an old app).
    AppOnly,
    /// The caller holds only a key the invitee revoked: nothing at all.
    Swallow,
}

/// Per invitee: does the caller hold a key they handed out? [keys] are
/// the caller's access keys to the people in the call (any order). The
/// stock server keeps no record of which key matched. (Every app since
/// 0.7.0 sends its keys; the switch for older ones went 2026-10-26.)
pub async fn call_verdicts(
    pool: &PgPool,
    invitees: &[Uuid],
    keys: &[Vec<u8>],
) -> sqlx::Result<HashMap<Uuid, CallVerdict>> {
    verdicts_on(&mut *pool.acquire().await?, invitees, keys).await
}

/// [call_verdicts] on one connection (a Submit's open transaction — a
/// second connection per message ran the pool dry under load). ADR-087
/// (amended): messages over the signed-in routes use the same verdicts.
pub async fn verdicts_on(
    conn: &mut sqlx::PgConnection,
    invitees: &[Uuid],
    keys: &[Vec<u8>],
) -> sqlx::Result<HashMap<Uuid, CallVerdict>> {
    let per_contact = per_contact_users(&mut *conn, invitees).await?;
    let hashes: Vec<Vec<u8>> = keys
        .iter()
        .filter(|k| k.len() == ACCESS_KEY_LEN)
        .take(64)
        .map(|k| Sha256::digest(k).to_vec())
        .collect();
    let rows: Vec<(Uuid, bool)> = if hashes.is_empty() || per_contact.is_empty() {
        Vec::new()
    } else {
        let strict: Vec<Uuid> = per_contact.iter().copied().collect();
        sqlx::query_as("SELECT user_pk, revoked FROM access_keys WHERE user_pk = ANY($1) AND key_hash = ANY($2)")
            .bind(&strict)
            .bind(&hashes)
            .fetch_all(&mut *conn)
            .await?
    };
    Ok(invitees
        .iter()
        .map(|u| {
            let v = if !per_contact.contains(u) {
                CallVerdict::Ring
            } else if rows.iter().any(|(r, revoked)| r == u && !revoked) {
                CallVerdict::Ring
            } else if rows.iter().any(|(r, _)| r == u) {
                CallVerdict::Swallow
            } else {
                CallVerdict::AppOnly
            };
            (*u, v)
        })
        .collect())
}

#[derive(Debug, thiserror::Error)]
pub enum AccessKeysError {
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

impl AccessKeysError {
    fn db(e: sqlx::Error) -> Self {
        error!(error = %e, "access keys db error");
        Self::Db
    }
}

impl IntoResponse for AccessKeysError {
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

    pub(crate) fn state(pool: PgPool) -> AppState {
        AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    fn signed(sk: &SigningKey, version: i32, adds: &[[u8; 32]], decisions: &[([u8; 32], bool, i64)]) -> PutRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let adds_v: Vec<Vec<u8>> = adds.iter().map(|h| h.to_vec()).collect();
        let dec_v: Vec<(Vec<u8>, bool, i64)> = decisions.iter().map(|(h, r, a)| (h.to_vec(), *r, *a)).collect();
        let mut msg = PUT_ACCESS_KEYS_DOMAIN.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&Sha256::digest(signed_body(version, &adds_v, &dec_v)));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        PutRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            access_version: version,
            add_hex: adds.iter().map(hex::encode).collect(),
            decisions: decisions
                .iter()
                .map(|(h, r, a)| Decision { hash_hex: hex::encode(h), revoked: *r, at_ms: *a })
                .collect(),
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes()),
        }
    }

    fn h(key: &[u8; 16]) -> [u8; 32] {
        Sha256::digest(key).into()
    }

    async fn user(pool: &PgPool, sk: &SigningKey) -> Uuid {
        let u = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(u)
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(pool)
            .await
            .unwrap();
        u
    }

    /// ADR-071 — adds, a block, a stale device that can't undo it, an
    /// unblock, and rotation (old active keys go, revoked ones stay).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn per_contact_keys_block_unblock_and_rotate(pool: PgPool) {
        let bob = SigningKey::from_bytes(&[61u8; 32]);
        let bob_pk = user(&pool, &bob).await;
        let (alice_k, carol_k) = ([1u8; 16], [2u8; 16]);
        let v = |k: [u8; 16]| {
            let pool = pool.clone();
            async move { anonymous_verdict(&pool, bob_pk, &k).await.unwrap() }
        };
        // Before any PUT: ADR-026 mode, no shared key → refused.
        assert_eq!(v(alice_k).await, AnonVerdict::Refuse);

        // A forged signature is refused.
        let mut forged = signed(&SigningKey::from_bytes(&[62u8; 32]), 0, &[h(&alice_k)], &[]);
        forged.identity_pubkey_hex = hex::encode(bob.verifying_key().to_bytes());
        assert!(matches!(put(State(state(pool.clone())), Json(forged)).await, Err(AccessKeysError::Unauthorized(_))));

        let r = put(State(state(pool.clone())), Json(signed(&bob, 0, &[h(&alice_k), h(&carol_k)], &[]))).await.unwrap();
        assert_eq!((r.0.access_version, r.0.changed), (0, 2));
        assert_eq!(v(alice_k).await, AnonVerdict::Deliver);
        assert_eq!(v([9u8; 16]).await, AnonVerdict::Refuse, "unknown key");

        // Bob blocks Carol at t=1000.
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[], &[(h(&carol_k), true, 1000)]))).await.unwrap();
        assert_eq!(v(carol_k).await, AnonVerdict::DropSilently);
        // Re-adding (another device sharing keys) doesn't lift it, nor does
        // an older unblock from a device that hasn't heard of the block.
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[h(&carol_k)], &[(h(&carol_k), false, 900)]))).await.unwrap();
        assert_eq!(v(carol_k).await, AnonVerdict::DropSilently);
        // A later unblock does.
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[], &[(h(&carol_k), false, 2000)]))).await.unwrap();
        assert_eq!(v(carol_k).await, AnonVerdict::Deliver);
        // …and an older block after it doesn't.
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[], &[(h(&carol_k), true, 1500)]))).await.unwrap();
        assert_eq!(v(carol_k).await, AnonVerdict::Deliver);
        // A block of a key never added still counts (a decision can come first).
        let dave_k = [4u8; 16];
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[], &[(h(&dave_k), true, 3000)]))).await.unwrap();
        assert_eq!(v(dave_k).await, AnonVerdict::DropSilently);

        // Rotation to version 1: Alice's old key stops, Dave's stays revoked.
        let r = put(State(state(pool.clone())), Json(signed(&bob, 1, &[h(&[5u8; 16])], &[]))).await.unwrap();
        assert_eq!(r.0.access_version, 1);
        assert_eq!(v(alice_k).await, AnonVerdict::Refuse);
        assert_eq!(v(dave_k).await, AnonVerdict::DropSilently);
        assert_eq!(v([5u8; 16]).await, AnonVerdict::Deliver);
        // A device still on version 0 changes nothing and learns 1.
        let r = put(State(state(pool.clone())), Json(signed(&bob, 0, &[h(&alice_k)], &[]))).await.unwrap();
        assert_eq!((r.0.access_version, r.0.changed), (1, 0));
        assert_eq!(v(alice_k).await, AnonVerdict::Refuse);

        // The old shared key (ADR-026) is no longer accepted.
        sqlx::query("UPDATE users SET access_hash = $2 WHERE user_pk = $1")
            .bind(bob_pk)
            .bind(h(&[7u8; 16]).to_vec())
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(v([7u8; 16]).await, AnonVerdict::Refuse);
        // Nothing on the server names a contact: hashes and flags only.
        let (cols,): (i64,) = sqlx::query_as(
            "SELECT count(*) FROM information_schema.columns WHERE table_name = 'access_keys'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(cols, 5);
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn call_verdicts_per_invitee(pool: PgPool) {
        let bob = SigningKey::from_bytes(&[71u8; 32]);
        let carol = SigningKey::from_bytes(&[72u8; 32]);
        let dan = SigningKey::from_bytes(&[73u8; 32]);
        let (bob_pk, carol_pk, dan_pk) = (user(&pool, &bob).await, user(&pool, &carol).await, user(&pool, &dan).await);
        // Bob gave the caller [1;16] and later revoked it; Carol gave [2;16];
        // Dan never published (0.6.0).
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[h(&[1u8; 16])], &[(h(&[1u8; 16]), true, 10)]))).await.unwrap();
        let _ = put(State(state(pool.clone())), Json(signed(&carol, 0, &[h(&[2u8; 16])], &[]))).await.unwrap();
        let all = [bob_pk, carol_pk, dan_pk];
        let v = call_verdicts(&pool, &all, &[[1u8; 16].to_vec(), [2u8; 16].to_vec()]).await.unwrap();
        assert_eq!(v[&bob_pk], CallVerdict::Swallow);
        assert_eq!(v[&carol_pk], CallVerdict::Ring);
        assert_eq!(v[&dan_pk], CallVerdict::Ring, "old mode: as before");
        // No keys (a stranger, an old app): the open app only.
        let v = call_verdicts(&pool, &all, &[]).await.unwrap();
        assert_eq!((v[&bob_pk], v[&carol_pk], v[&dan_pk]), (CallVerdict::AppOnly, CallVerdict::AppOnly, CallVerdict::Ring));
        let v = call_verdicts(&pool, &[bob_pk], &[[1u8; 16].to_vec()]).await.unwrap();
        assert_eq!(v[&bob_pk], CallVerdict::Swallow);
        // Another person's key for Bob is no proof for Carol.
        let v = call_verdicts(&pool, &[carol_pk], &[[1u8; 16].to_vec()]).await.unwrap();
        assert_eq!(v[&carol_pk], CallVerdict::AppOnly);
    }
    /// sealed-push:4 — someone I blocked who kept my old shared key (from
    /// before per-contact keys) no longer gets through with it.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_blocked_contact_with_my_old_shared_key_does_not_get_through(pool: PgPool) {
        let bob = SigningKey::from_bytes(&[63u8; 32]);
        let bob_pk = user(&pool, &bob).await;
        let h = |k: &[u8]| Sha256::digest(k);
        sqlx::query("UPDATE users SET access_per_contact = TRUE, access_hash = $2 WHERE user_pk = $1")
            .bind(bob_pk)
            .bind(h(&[7u8; 16]).to_vec())
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO access_keys (user_pk, key_hash, revoked) VALUES ($1, $2, TRUE)")
            .bind(bob_pk)
            .bind(h(&[9u8; 16]).to_vec())
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(anonymous_verdict(&pool, bob_pk, &[7u8; 16]).await.unwrap(), AnonVerdict::Refuse, "the old shared key");
        assert_eq!(anonymous_verdict(&pool, bob_pk, &[9u8; 16]).await.unwrap(), AnonVerdict::DropSilently, "blocked stays blocked");
        assert_eq!(anonymous_verdict(&pool, bob_pk, &[8u8; 16]).await.unwrap(), AnonVerdict::Refuse, "an unknown key is still refused");
    }

    /// GRP-7 — the largest PUT is two statements (it was 2000), a hash
    /// decided twice in one request keeps the later decision, and PUTs
    /// are limited per person.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_full_put_keeps_its_meaning_and_puts_are_limited(pool: PgPool) {
        let bob = SigningKey::from_bytes(&[64u8; 32]);
        let bob_pk = user(&pool, &bob).await;
        let n = |i: usize, tag: u8| -> [u8; 32] {
            let mut b = [tag; 32];
            b[..8].copy_from_slice(&(i as u64).to_be_bytes());
            b
        };
        let adds: Vec<[u8; 32]> = (0..MAX_PER_PUT).map(|i| n(i, 1)).collect();
        let mut decisions: Vec<([u8; 32], bool, i64)> = (0..MAX_PER_PUT - 2).map(|i| (n(i, 2), true, 5)).collect();
        // The same hash twice: unblocked at 7 after a block at 6, in any order.
        decisions.push((n(0, 3), false, 7));
        decisions.push((n(0, 3), true, 6));
        let r = put(State(state(pool.clone())), Json(signed(&bob, 0, &adds, &decisions))).await.unwrap();
        assert_eq!(r.0.changed, 2 * MAX_PER_PUT - 1);
        let (rows, revoked): (i64, i64) =
            sqlx::query_as("SELECT count(*), count(*) FILTER (WHERE revoked) FROM access_keys WHERE user_pk = $1")
                .bind(bob_pk)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!((rows, revoked), (2 * MAX_PER_PUT as i64 - 1, MAX_PER_PUT as i64 - 2));
        let (rev, at): (bool, i64) = sqlx::query_as("SELECT revoked, decided_ms FROM access_keys WHERE key_hash = $1")
            .bind(n(0, 3).to_vec())
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!((rev, at), (false, 7), "the later decision of the two");
        // Re-adding a revoked key in the same batch doesn't lift the block.
        let r = put(State(state(pool.clone())), Json(signed(&bob, 0, &[n(1, 2)], &[]))).await.unwrap();
        assert_eq!(r.0.changed, 0);

        let mut refused = 0;
        for _ in 0..600 {
            match put(State(state(pool.clone())), Json(signed(&bob, 0, &[], &[]))).await {
                Err(AccessKeysError::TooMany) => refused += 1,
                r => drop(r.unwrap()),
            }
        }
        assert!((1..=2).contains(&refused), "600 an hour, 2 used above: {refused}");
    }

    /// GRP-5 — what a device does before it is disconnected can be undone:
    /// a block "from the end of time" is lifted by a later unblock, the
    /// version can't be put out of a rotation's reach, and junk blocks
    /// don't use up the room for new keys.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_devices_decisions_can_be_undone_later(pool: PgPool) {
        let bob = SigningKey::from_bytes(&[65u8; 32]);
        let bob_pk = user(&pool, &bob).await;
        let alice_k = [1u8; 16];
        let now_ms = OffsetDateTime::now_utc().unix_timestamp() * 1000;
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[h(&alice_k)], &[(h(&alice_k), true, i64::MAX)]))).await.unwrap();
        assert_eq!(anonymous_verdict(&pool, bob_pk, &alice_k).await.unwrap(), AnonVerdict::DropSilently);
        let (at,): (i64,) = sqlx::query_as("SELECT decided_ms FROM access_keys WHERE user_pk = $1").bind(bob_pk).fetch_one(&pool).await.unwrap();
        assert!(at <= now_ms + MAX_DECISION_AHEAD_MS + 60_000, "stored as decided a day ahead at most: {at}");
        // Two days pass (the stored time moves back instead of the clock forward).
        sqlx::query("UPDATE access_keys SET decided_ms = decided_ms - $1").bind(2 * MAX_DECISION_AHEAD_MS).execute(&pool).await.unwrap();
        let _ = put(State(state(pool.clone())), Json(signed(&bob, 0, &[], &[(h(&alice_k), false, now_ms)]))).await.unwrap();
        assert_eq!(anonymous_verdict(&pool, bob_pk, &alice_k).await.unwrap(), AnonVerdict::Deliver, "unblocked two days later");

        // The version: not to the maximum…
        let far = put(State(state(pool.clone())), Json(signed(&bob, i32::MAX, &[], &[]))).await;
        assert!(matches!(far, Err(AccessKeysError::BadRequest(_))));
        let far = put(State(state(pool.clone())), Json(signed(&bob, MAX_VERSION_STEP as i32 + 1, &[], &[]))).await;
        assert!(matches!(far, Err(AccessKeysError::BadRequest(_))));
        // …so a rotation (+1) still works.
        let r = put(State(state(pool.clone())), Json(signed(&bob, 1, &[h(&[2u8; 16])], &[]))).await.unwrap();
        assert_eq!((r.0.access_version, r.0.changed), (1, 1));

        // 5000 blocks nobody can lift: a new contact still gets a key.
        sqlx::query(
            "INSERT INTO access_keys (user_pk, key_hash, version, revoked, decided_ms) \
             SELECT $1, sha256(i::text::bytea), 1, TRUE, 1 FROM generate_series(1, 5000) AS i",
        )
        .bind(bob_pk)
        .execute(&pool)
        .await
        .unwrap();
        let r = put(State(state(pool.clone())), Json(signed(&bob, 1, &[h(&[3u8; 16])], &[]))).await.unwrap();
        assert_eq!(r.0.changed, 1);
        assert_eq!(anonymous_verdict(&pool, bob_pk, &[3u8; 16]).await.unwrap(), AnonVerdict::Deliver);
        // NEW-3 — the app sends the blocks it already has again with every
        // PUT: a stored one is not counted twice, the request goes through.
        let old: [u8; 32] = <sha2::Sha256 as sha2::Digest>::digest(b"1").into();
        let r = put(State(state(pool.clone())), Json(signed(&bob, 1, &[h(&[5u8; 16])], &[(old, true, now_ms)]))).await.unwrap();
        assert_eq!(r.0.changed, 2, "the new key, and the old block's newer time");
        // (No room for one more block, though.)
        let full = put(State(state(pool.clone())), Json(signed(&bob, 1, &[], &[(h(&[4u8; 16]), true, now_ms)]))).await;
        assert!(matches!(full, Err(AccessKeysError::BadRequest(_))));
    }
}
