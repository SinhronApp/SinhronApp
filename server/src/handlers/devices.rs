// Linked devices — ADR-025 (spec §6.7).
//
//   POST   /v1/devices               a new device registers itself with its
//                                    device certificate (identity-signed) and
//                                    an action proof made with ITS OWN key
//                                    (domain DEVICE_ADD_DOMAIN, body = cert).
//   GET    /v1/devices?identity_pubkey_hex=[&revoked=1]
//                                    the person's active devices (public keys
//                                    only — the same thing KeyPackage consume
//                                    already reveals). ADR-075 — `revoked=1`
//                                    adds the revoked ones with the identity
//                                    key's signature over the revocation, so
//                                    other people's phones can check it.
//   DELETE /v1/devices/{device_pk}   revoke: action proof by the identity key
//                                    (DEVICE_REVOKE_DOMAIN, body = device_pk).
//                                    Drops the device's KeyPackages and group
//                                    rows (kept as group_former_devices: its
//                                    person may rejoin by external commit,
//                                    ADR-075); MLS removal is a Commit by the
//                                    person's other device or, with the
//                                    proof, by anyone in the chat.
//
// The primary device (device_pk = identity key, inserted by POST
// /v1/identity) has no certificate. Any device may be revoked — the
// primary too, when that phone is lost — except the person's last one.

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::{error, info};
use uuid::Uuid;

use super::proof::{self, DEVICE_ADD_DOMAIN, DEVICE_CERT_DOMAIN, DEVICE_REVOKE_DOMAIN};
#[cfg(test)]
use super::proof::{GROUP_CARD_GET_DOMAIN, GROUP_CARD_PUT_DOMAIN};
use crate::AppState;

const CERT_MAGIC: &[u8; 4] = b"SDC1";
pub const CERT_LEN: usize = 4 + 32 + 32 + 64;
/// Linked devices per person (the primary one not counted).
pub const MAX_LINKED_DEVICES: i64 = 8;
/// DEV-2 — link + revoke in a circle made devices without end (rows kept
/// for good, all handed to anyone who asks). Linked in the last 30 days,
/// revoked ones too; and the most a list returns.
const MAX_LINKED_PER_MONTH: i64 = 32;
const MAX_LISTED_DEVICES: i64 = 64;

/// Check a device certificate → `(identity_pub, device_pub)`.
pub fn verify_certificate(cert: &[u8]) -> Result<([u8; 32], [u8; 32]), DevicesError> {
    if cert.len() != CERT_LEN || &cert[..4] != CERT_MAGIC {
        return Err(DevicesError::BadRequest("malformed device certificate".into()));
    }
    let identity: [u8; 32] = cert[4..36].try_into().expect("len checked");
    let device: [u8; 32] = cert[36..68].try_into().expect("len checked");
    let sig: [u8; 64] = cert[68..].try_into().expect("len checked");
    let vk = VerifyingKey::from_bytes(&identity)
        .map_err(|_| DevicesError::BadRequest("bad identity key in certificate".into()))?;
    let mut msg = DEVICE_CERT_DOMAIN.to_vec();
    msg.extend_from_slice(&device);
    // PROOF-3 — strict, as in proof.rs.
    vk.verify_strict(&msg, &Signature::from_bytes(&sig))
        .map_err(|_| DevicesError::Unauthorized("certificate not signed by that identity".into()))?;
    if device == identity {
        return Err(DevicesError::BadRequest("device key equals identity key".into()));
    }
    Ok((identity, device))
}

#[derive(Debug, Deserialize)]
pub struct AddRequest {
    pub certificate_hex: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct DeviceOut {
    pub device_pk_hex: String,
    /// Empty for the primary device.
    pub certificate_hex: String,
    pub registered_at: i64,
    /// Last WS login / KeyPackage upload (unix seconds); `registered_at`
    /// when never seen since.
    pub last_seen_at: i64,
    /// ADR-075 — only with `revoked=1`: cut off, and the identity key's
    /// signature over it (DEVICE_REVOKE_DOMAIN action proof, body =
    /// device_pk) with its timestamp.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub revoked: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub revoke_proof_hex: String,
    #[serde(skip_serializing_if = "is_zero")]
    pub revoke_proof_ts: i64,
}

fn is_zero(v: &i64) -> bool {
    *v == 0
}

pub async fn add(State(state): State<AppState>, Json(req): Json<AddRequest>) -> Result<(StatusCode, Json<DeviceOut>), DevicesError> {
    let pool = state.pool.ok_or(DevicesError::NoDb)?;
    let cert = hex::decode(&req.certificate_hex).map_err(|e| DevicesError::BadRequest(format!("certificate_hex: {e}")))?;
    let (identity, device) = verify_certificate(&cert)?;
    // The device proves it holds its own key (and that this is fresh).
    let sig = hex::decode(&req.proof_hex).map_err(|e| DevicesError::BadRequest(format!("proof_hex: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(DEVICE_ADD_DOMAIN, &device, &cert, req.proof_ts, &sig, now)
        .map_err(|e| DevicesError::Unauthorized(e.to_string()))?;

    let mut tx = pool.begin().await.map_err(DevicesError::db)?;
    // DEV-3 — the row lock: requests at once each counted under the limit and
    // all got in; now the person's links go one at a time.
    let user: Option<(Uuid,)> = sqlx::query_as("SELECT user_pk FROM users WHERE identity_pubkey = $1 AND status = 'active' FOR NO KEY UPDATE")
        .bind(&identity[..])
        .fetch_optional(&mut *tx)
        .await
        .map_err(DevicesError::db)?;
    let Some((user_pk,)) = user else {
        return Err(DevicesError::NotFound("identity not registered".into()));
    };
    let existing: Option<(Uuid, Option<OffsetDateTime>, OffsetDateTime)> =
        sqlx::query_as("SELECT user_pk, revoked_at, registered_at FROM devices WHERE device_pk = $1")
            .bind(&device[..])
            .fetch_optional(&mut *tx)
            .await
            .map_err(DevicesError::db)?;
    let registered_at = match existing {
        // Re-registering is idempotent; a revoked key stays revoked.
        Some((owner, None, at)) if owner == user_pk => at,
        Some(_) => return Err(DevicesError::Conflict("device key already used".into())),
        None => {
            let (count, month): (i64, i64) = sqlx::query_as(
                "SELECT COUNT(*) FILTER (WHERE revoked_at IS NULL), \
                        COUNT(*) FILTER (WHERE registered_at > NOW() - interval '30 days') \
                 FROM devices WHERE user_pk = $1 AND certificate IS NOT NULL",
            )
            .bind(user_pk)
            .fetch_one(&mut *tx)
            .await
            .map_err(DevicesError::db)?;
            if count >= MAX_LINKED_DEVICES {
                return Err(DevicesError::Conflict(format!("at most {MAX_LINKED_DEVICES} linked devices")));
            }
            if month >= MAX_LINKED_PER_MONTH {
                return Err(DevicesError::Conflict("too many devices linked this month".into()));
            }
            let (at,): (OffsetDateTime,) = sqlx::query_as(
                "INSERT INTO devices (device_pk, user_pk, credential, certificate) VALUES ($1, $2, $1, $3) \
                 RETURNING registered_at",
            )
            .bind(&device[..])
            .bind(user_pk)
            .bind(&cert)
            .fetch_one(&mut *tx)
            .await
            .map_err(DevicesError::db)?;
            at
        }
    };
    tx.commit().await.map_err(DevicesError::db)?;
    info!(identity = %crate::short_key(&hex::encode(identity)), "linked device registered");
    Ok((
        StatusCode::CREATED,
        Json(DeviceOut {
            device_pk_hex: hex::encode(device),
            certificate_hex: req.certificate_hex,
            registered_at: registered_at.unix_timestamp(),
            last_seen_at: registered_at.unix_timestamp(),
            revoked: false,
            revoke_proof_hex: String::new(),
            revoke_proof_ts: 0,
        }),
    ))
}

#[derive(Debug, Deserialize)]
pub struct ListQuery {
    pub identity_pubkey_hex: String,
    /// ADR-075 — `1`: revoked devices too, with their proofs.
    #[serde(default)]
    pub revoked: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ListResponse {
    pub devices: Vec<DeviceOut>,
}

pub async fn list(State(state): State<AppState>, Query(q): Query<ListQuery>) -> Result<Json<ListResponse>, DevicesError> {
    let pool = state.pool.ok_or(DevicesError::NoDb)?;
    let identity = hex::decode(&q.identity_pubkey_hex).map_err(|e| DevicesError::BadRequest(format!("identity: {e}")))?;
    let with_revoked = q.revoked.as_deref() == Some("1");
    #[allow(clippy::type_complexity)]
    let rows: Vec<(Vec<u8>, Option<Vec<u8>>, OffsetDateTime, OffsetDateTime, bool, Option<Vec<u8>>, Option<i64>)> = sqlx::query_as(
        // DEV-2 — at most MAX_LISTED_DEVICES: the active ones, then the
        // latest revoked.
        "SELECT * FROM (SELECT d.device_pk, d.certificate, d.registered_at, COALESCE(d.last_seen_at, d.registered_at), \
                d.revoked_at IS NOT NULL, d.revoke_proof, d.revoke_proof_ts FROM devices d \
         JOIN users u ON u.user_pk = d.user_pk \
         WHERE u.identity_pubkey = $1 AND (d.revoked_at IS NULL OR ($2 AND d.revoke_proof IS NOT NULL)) \
         ORDER BY d.revoked_at DESC NULLS FIRST LIMIT $3) t ORDER BY 3, 1",
    )
    .bind(&identity)
    .bind(with_revoked)
    .bind(MAX_LISTED_DEVICES)
    .fetch_all(&pool)
    .await
    .map_err(DevicesError::db)?;
    Ok(Json(ListResponse {
        devices: rows
            .into_iter()
            .map(|(pk, cert, at, seen, revoked, proof, proof_ts)| DeviceOut {
                device_pk_hex: hex::encode(pk),
                certificate_hex: cert.map(hex::encode).unwrap_or_default(),
                registered_at: at.unix_timestamp(),
                // server-http:7 — anyone with the address polled this to the
                // second (when the phone opened, when a push woke it; ADR-031
                // hides "last seen"). The day is all the apps need (never
                // before the link time, which is exact anyway).
                last_seen_at: (seen.unix_timestamp().div_euclid(86_400) * 86_400).max(at.unix_timestamp()),
                revoked,
                revoke_proof_hex: if revoked { proof.map(hex::encode).unwrap_or_default() } else { String::new() },
                revoke_proof_ts: if revoked { proof_ts.unwrap_or(0) } else { 0 },
            })
            .collect(),
    }))
}

#[derive(Debug, Deserialize)]
pub struct RevokeRequest {
    pub identity_pubkey_hex: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

pub async fn revoke(
    State(state): State<AppState>,
    Path(device_pk_hex): Path<String>,
    Json(req): Json<RevokeRequest>,
) -> Result<StatusCode, DevicesError> {
    let pool = state.pool.ok_or(DevicesError::NoDb)?;
    let device = hex::decode(&device_pk_hex).map_err(|e| DevicesError::BadRequest(format!("device_pk: {e}")))?;
    let identity = hex::decode(&req.identity_pubkey_hex).map_err(|e| DevicesError::BadRequest(format!("identity: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| DevicesError::BadRequest(format!("proof_hex: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(DEVICE_REVOKE_DOMAIN, &identity, &device, req.proof_ts, &sig, now)
        .map_err(|e| DevicesError::Unauthorized(e.to_string()))?;

    let mut tx = pool.begin().await.map_err(DevicesError::db)?;
    // Lock the person's active devices so two revocations can't race
    // each other down to zero.
    let active: Vec<(Vec<u8>,)> = sqlx::query_as(
        "SELECT d.device_pk FROM devices d JOIN users u ON u.user_pk = d.user_pk \
         WHERE u.identity_pubkey = $1 AND d.revoked_at IS NULL FOR UPDATE OF d",
    )
    .bind(&identity)
    .fetch_all(&mut *tx)
    .await
    .map_err(DevicesError::db)?;
    if !active.iter().any(|(pk,)| *pk == device) {
        return Err(DevicesError::NotFound("no such device".into()));
    }
    if active.len() < 2 {
        return Err(DevicesError::Conflict("can't revoke the last device".into()));
    }
    // ADR-075 — the signature stays with the device: other people's phones
    // check it before they take its leaf out of a chat.
    sqlx::query("UPDATE devices SET revoked_at = NOW(), revoke_proof = $2, revoke_proof_ts = $3 WHERE device_pk = $1")
        .bind(&device)
        .bind(&sig)
        .bind(req.proof_ts)
        .execute(&mut *tx)
        .await
        .map_err(DevicesError::db)?;
    // ADR-075 — its chats: the person may rejoin them by external commit.
    sqlx::query(
        "INSERT INTO group_former_devices (group_id, device_pk) \
         SELECT group_id, device_pk FROM group_members WHERE device_pk = $1 ON CONFLICT DO NOTHING",
    )
    .bind(&device)
    .execute(&mut *tx)
    .await
    .map_err(DevicesError::db)?;
    sqlx::query("DELETE FROM keypackages WHERE device_pk = $1 AND consumed_at IS NULL")
        .bind(&device)
        .execute(&mut *tx)
        .await
        .map_err(DevicesError::db)?;
    let groups: Vec<(Vec<u8>,)> = sqlx::query_as("DELETE FROM group_members WHERE device_pk = $1 RETURNING group_id")
        .bind(&device)
        .fetch_all(&mut *tx)
        .await
        .map_err(DevicesError::db)?;
    let (owner,): (Uuid,) = sqlx::query_as("SELECT user_pk FROM devices WHERE device_pk = $1")
        .bind(&device)
        .fetch_one(&mut *tx)
        .await
        .map_err(DevicesError::db)?;
    tx.commit().await.map_err(DevicesError::db)?;
    // Its live connections end now, not at its next reconnect.
    state.sessions.drop_device(owner, &device);
    // And its calls (security review 2026-11, calls:4).
    super::call::evict_from_calls(groups.into_iter().map(|(g,)| g).collect(), vec![device.clone()]);
    info!(identity = %crate::short_key(&req.identity_pubkey_hex), "linked device revoked");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, thiserror::Error)]
pub enum DevicesError {
    #[error("database unavailable")]
    NoDb,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("internal error")]
    Db,
}

impl DevicesError {
    fn db(e: sqlx::Error) -> Self {
        error!(error = %e, "devices db error");
        Self::Db
    }
}

impl IntoResponse for DevicesError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::NoDb => StatusCode::SERVICE_UNAVAILABLE,
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            Self::NotFound(_) => StatusCode::NOT_FOUND,
            Self::Conflict(_) => StatusCode::CONFLICT,
            Self::Db => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, Json(serde_json::json!({ "error": self.to_string() }))).into_response()
    }
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

    fn cert(identity: &SigningKey, device: &SigningKey) -> Vec<u8> {
        let dpk = device.verifying_key().to_bytes();
        let mut m = DEVICE_CERT_DOMAIN.to_vec();
        m.extend_from_slice(&dpk);
        let mut c = CERT_MAGIC.to_vec();
        c.extend_from_slice(&identity.verifying_key().to_bytes());
        c.extend_from_slice(&dpk);
        c.extend_from_slice(&identity.sign(&m).to_bytes());
        c
    }

    fn action(domain: &[u8], sk: &SigningKey, body: &[u8], ts: i64) -> String {
        let mut m = domain.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(body));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes())
    }

    fn add_req(identity: &SigningKey, device: &SigningKey, ts: i64) -> AddRequest {
        let c = cert(identity, device);
        AddRequest { proof_hex: action(DEVICE_ADD_DOMAIN, device, &c, ts), certificate_hex: hex::encode(c), proof_ts: ts }
    }

    #[test]
    fn certificate_checks() {
        let id = SigningKey::from_bytes(&[1u8; 32]);
        let dev = SigningKey::from_bytes(&[2u8; 32]);
        let c = cert(&id, &dev);
        assert_eq!(c.len(), CERT_LEN);
        let (i, d) = verify_certificate(&c).unwrap();
        assert_eq!(i, id.verifying_key().to_bytes());
        assert_eq!(d, dev.verifying_key().to_bytes());
        // Someone else's signature over the device key is refused.
        let mut forged = cert(&SigningKey::from_bytes(&[3u8; 32]), &dev);
        forged[4..36].copy_from_slice(&id.verifying_key().to_bytes());
        assert!(matches!(verify_certificate(&forged), Err(DevicesError::Unauthorized(_))));
        assert!(matches!(verify_certificate(&c[..100]), Err(DevicesError::BadRequest(_))));
        // PROOF-3 — the identity point as "identity": (R = base point, S = 1)
        // used to certify any device.
        let mut weak = CERT_MAGIC.to_vec();
        weak.extend_from_slice(&[1u8; 1]);
        weak.extend_from_slice(&[0u8; 31]);
        weak.extend_from_slice(&dev.verifying_key().to_bytes());
        weak.push(0x58);
        weak.extend_from_slice(&[0x66u8; 31]);
        weak.push(1);
        weak.extend_from_slice(&[0u8; 31]);
        assert!(matches!(verify_certificate(&weak), Err(DevicesError::Unauthorized(_))));
    }

    /// FUZZ-ENV-1 — neither weak identity key (00…00, 01 00…00) certifies a
    /// device with the fixed signature (R = the key, s = 0).
    #[test]
    fn a_weak_identity_key_certifies_nothing() {
        let mut one = [0u8; 32];
        one[0] = 1;
        for key in [[0u8; 32], one] {
            for i in 2..66u8 {
                let mut cert = CERT_MAGIC.to_vec();
                cert.extend_from_slice(&key);
                cert.extend_from_slice(&[i; 32]);
                cert.extend_from_slice(&key); // R
                cert.extend_from_slice(&[0u8; 32]); // s
                assert!(verify_certificate(&cert).is_err());
            }
        }
    }

    // ACCT-2 — a banned key is a `users` row with status 'banned': it links no device.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_banned_key_links_no_device(pool: sqlx::PgPool) {
        let id = SigningKey::from_bytes(&[41u8; 32]);
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey, status) VALUES ($1, $2, 'banned')")
            .bind(Uuid::now_v7())
            .bind(id.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let laptop = SigningKey::from_bytes(&[42u8; 32]);
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let res = add(State(state(pool.clone())), Json(add_req(&id, &laptop, now))).await;
        assert!(matches!(res, Err(DevicesError::NotFound(_))));
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices").fetch_one(&pool).await.unwrap();
        assert_eq!(n, 0);
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn link_list_and_revoke(pool: sqlx::PgPool) {
        let id = SigningKey::from_bytes(&[11u8; 32]);
        let id_pk = id.verifying_key().to_bytes().to_vec();
        let user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id_pk).bind(user).execute(&pool).await.unwrap();
        let laptop = SigningKey::from_bytes(&[12u8; 32]);
        let now = OffsetDateTime::now_utc().unix_timestamp();

        let (code, out) = add(State(state(pool.clone())), Json(add_req(&id, &laptop, now))).await.unwrap();
        assert_eq!(code, StatusCode::CREATED);
        assert_eq!(out.0.device_pk_hex, hex::encode(laptop.verifying_key().to_bytes()));
        // Idempotent.
        assert!(add(State(state(pool.clone())), Json(add_req(&id, &laptop, now))).await.is_ok());
        // A proof by someone other than the device is refused.
        let mut stolen = add_req(&id, &laptop, now);
        stolen.proof_hex = action(DEVICE_ADD_DOMAIN, &SigningKey::from_bytes(&[13u8; 32]), &hex::decode(&stolen.certificate_hex).unwrap(), now);
        assert!(matches!(add(State(state(pool.clone())), Json(stolen)).await, Err(DevicesError::Unauthorized(_))));

        let q = || Query(ListQuery { identity_pubkey_hex: hex::encode(&id_pk), revoked: None });
        let listed = list(State(state(pool.clone())), q()).await.unwrap();
        assert_eq!(listed.0.devices.len(), 2);
        assert!(listed.0.devices.iter().any(|d| d.certificate_hex.is_empty()), "primary has no cert");
        assert!(listed.0.devices.iter().all(|d| d.last_seen_at >= d.registered_at), "last seen ≥ registered");

        let lpk = laptop.verifying_key().to_bytes().to_vec();
        let revoke_req = |signer: &SigningKey| RevokeRequest {
            identity_pubkey_hex: hex::encode(&id_pk),
            proof_ts: now,
            proof_hex: action(DEVICE_REVOKE_DOMAIN, signer, &lpk, now),
        };
        // The laptop can't revoke itself with its own key — only the identity can.
        assert!(matches!(
            revoke(State(state(pool.clone())), Path(hex::encode(&lpk)), Json(revoke_req(&laptop))).await,
            Err(DevicesError::Unauthorized(_))
        ));
        // The laptop is online: revoking ends its live connection at once.
        let st = state(pool.clone());
        let (ltx, mut lrx) = tokio::sync::mpsc::unbounded_channel();
        let _laptop_session = st.sessions.register_device(user, Some(lpk.clone()), ltx);
        assert_eq!(
            revoke(State(st.clone()), Path(hex::encode(&lpk)), Json(revoke_req(&id))).await.unwrap(),
            StatusCode::NO_CONTENT
        );
        assert!(lrx.recv().await.is_none(), "its send queue is closed → the session ends");
        assert_eq!(list(State(state(pool.clone())), q()).await.unwrap().0.devices.len(), 1);
        // A revoked key can't come back.
        assert!(matches!(add(State(state(pool.clone())), Json(add_req(&id, &laptop, now))).await, Err(DevicesError::Conflict(_))));
        // The last device can't be revoked …
        let primary = || RevokeRequest { identity_pubkey_hex: hex::encode(&id_pk), proof_ts: now, proof_hex: action(DEVICE_REVOKE_DOMAIN, &id, &id_pk, now) };
        assert!(matches!(
            revoke(State(state(pool.clone())), Path(hex::encode(&id_pk)), Json(primary())).await,
            Err(DevicesError::Conflict(_))
        ));
        // … but a lost primary can, once another device exists.
        let tablet = SigningKey::from_bytes(&[14u8; 32]);
        let _ = add(State(state(pool.clone())), Json(add_req(&id, &tablet, now))).await.unwrap();
        assert_eq!(
            revoke(State(state(pool.clone())), Path(hex::encode(&id_pk)), Json(primary())).await.unwrap(),
            StatusCode::NO_CONTENT
        );
        let left = list(State(state(pool)), q()).await.unwrap().0.devices;
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].device_pk_hex, hex::encode(tablet.verifying_key().to_bytes()));
    }

    /// ADR-075 — a lost phone cut off from a new one: listed with the
    /// identity key's signature (anyone can check it), its chats remembered
    /// for the person's rejoin; the card of a chat goes to the person's new
    /// device, never to a stranger; a stale card is refused.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_lost_phone_is_cut_off_with_a_proof_and_its_person_gets_the_card(pool: sqlx::PgPool) {
        use crate::handlers::groups::{card_body, get_card, put_card, GetCardRequest, GroupError, PutCardRequest};
        use base64::Engine;
        let id = SigningKey::from_bytes(&[31u8; 32]);
        let id_pk = id.verifying_key().to_bytes().to_vec();
        let user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id_pk).bind(user).execute(&pool).await.unwrap();
        // Alice, in the chat with Bob's (lost) first phone.
        let alice = SigningKey::from_bytes(&[32u8; 32]);
        let alice_pk = alice.verifying_key().to_bytes().to_vec();
        let alice_user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(alice_user).bind(&alice_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&alice_pk).bind(alice_user).execute(&pool).await.unwrap();
        let group = b"bob-and-alice".to_vec();
        sqlx::query("INSERT INTO mls_groups (group_id, current_epoch) VALUES ($1, 5)").bind(&group).execute(&pool).await.unwrap();
        for d in [&id_pk, &alice_pk] {
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)").bind(&group).bind(d).execute(&pool).await.unwrap();
        }
        let now = OffsetDateTime::now_utc().unix_timestamp();
        // Bob signs in on a new phone, and cuts the old one off with his words.
        let new_phone = SigningKey::from_bytes(&[33u8; 32]);
        let new_pk = new_phone.verifying_key().to_bytes().to_vec();
        let _ = add(State(state(pool.clone())), Json(add_req(&id, &new_phone, now))).await.unwrap();
        let proof = action(DEVICE_REVOKE_DOMAIN, &id, &id_pk, now);
        let req = RevokeRequest { identity_pubkey_hex: hex::encode(&id_pk), proof_ts: now, proof_hex: proof.clone() };
        assert_eq!(revoke(State(state(pool.clone())), Path(hex::encode(&id_pk)), Json(req)).await.unwrap(), StatusCode::NO_CONTENT);

        let q = |revoked: Option<&str>| Query(ListQuery { identity_pubkey_hex: hex::encode(&id_pk), revoked: revoked.map(String::from) });
        assert_eq!(list(State(state(pool.clone())), q(None)).await.unwrap().0.devices.len(), 1, "as before: active only");
        let all = list(State(state(pool.clone())), q(Some("1"))).await.unwrap().0.devices;
        let lost = all.iter().find(|d| d.revoked).expect("the revoked one is listed");
        assert_eq!(lost.device_pk_hex, hex::encode(&id_pk));
        let sig = hex::decode(&lost.revoke_proof_hex).unwrap();
        assert!(proof::verify_action_proof(DEVICE_REVOKE_DOMAIN, &id_pk, &id_pk, lost.revoke_proof_ts, &sig, now).is_ok(), "anyone can check it");
        let json = serde_json::to_value(&all.iter().find(|d| !d.revoked).unwrap()).unwrap();
        assert!(json.get("revoked").is_none() && json.get("revoke_proof_hex").is_none(), "nothing extra for active devices");
        let (former,): (i64,) = sqlx::query_as("SELECT count(*) FROM group_former_devices WHERE group_id = $1 AND device_pk = $2")
            .bind(&group).bind(&id_pk).fetch_one(&pool).await.unwrap();
        assert_eq!(former, 1, "the chat is remembered for Bob's rejoin");

        // Cards: Alice (in the chat) leaves one; Bob's new phone fetches it.
        let card = b"group info bytes".to_vec();
        let put = |signer: &SigningKey, epoch: i64| PutCardRequest {
            device_pk_hex: hex::encode(signer.verifying_key().to_bytes()),
            epoch,
            card_b64: base64::engine::general_purpose::STANDARD.encode(&card),
            proof_ts: now,
            proof_hex: action(GROUP_CARD_PUT_DOMAIN, signer, &card_body(&group, epoch, &card), now),
        };
        let get = |signer: &SigningKey| GetCardRequest {
            device_pk_hex: hex::encode(signer.verifying_key().to_bytes()),
            proof_ts: now,
            proof_hex: action(GROUP_CARD_GET_DOMAIN, signer, &group, now),
        };
        let gid = || Path(hex::encode(&group));
        assert!(matches!(get_card(State(state(pool.clone())), gid(), Json(get(&new_phone))).await, Err(GroupError::NotFound(_))));
        assert!(matches!(put_card(State(state(pool.clone())), gid(), Json(put(&new_phone, 5))).await, Err(GroupError::Forbidden(_))), "not in the chat yet");
        assert!(matches!(put_card(State(state(pool.clone())), gid(), Json(put(&alice, 4))).await, Err(GroupError::Conflict(_))), "stale");
        let mut forged = put(&alice, 5);
        forged.epoch = 6;
        assert!(matches!(put_card(State(state(pool.clone())), gid(), Json(forged)).await, Err(GroupError::Unauthorized(_))));
        assert_eq!(put_card(State(state(pool.clone())), gid(), Json(put(&alice, 5))).await.unwrap(), StatusCode::NO_CONTENT);
        let got = get_card(State(state(pool.clone())), gid(), Json(get(&new_phone))).await.unwrap().0;
        assert_eq!(got.cards.len(), 1);
        assert_eq!((got.cards[0].epoch, base64::engine::general_purpose::STANDARD.decode(&got.cards[0].card_b64).unwrap()), (5, card.clone()));
        let stranger = SigningKey::from_bytes(&[34u8; 32]);
        assert!(matches!(get_card(State(state(pool.clone())), gid(), Json(get(&stranger))).await, Err(GroupError::Forbidden(_))));
        // A card from the future (ahead of the server's epoch) is refused —
        // epoch 2^62 used to lock every later card out (security review
        // 2026-11-02); after two Commits the newer card replaces it, and an
        // older one never does.
        assert!(matches!(put_card(State(state(pool.clone())), gid(), Json(put(&alice, 7))).await, Err(GroupError::Conflict(_))));
        sqlx::query("UPDATE mls_groups SET current_epoch = 7 WHERE group_id = $1").bind(&group).execute(&pool).await.unwrap();
        assert!(put_card(State(state(pool.clone())), gid(), Json(put(&alice, 7))).await.is_ok());
        assert!(matches!(put_card(State(state(pool.clone())), gid(), Json(put(&alice, 6))).await, Err(GroupError::Conflict(_))));
        assert_eq!(get_card(State(state(pool)), gid(), Json(get(&new_phone))).await.unwrap().0.cards[0].epoch, 7);
    }

    // server-http:7 — a stranger with my address read when my phone last
    // connected, to the second; now only the day.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_stranger_sees_only_the_day_my_phone_was_last_seen(pool: sqlx::PgPool) {
        let id = SigningKey::from_bytes(&[23u8; 32]);
        let id_pk = id.verifying_key().to_bytes().to_vec();
        let user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
        sqlx::query(
            "INSERT INTO devices (device_pk, user_pk, credential, registered_at, last_seen_at) \
             VALUES ($1, $2, $1, '2026-11-01 08:00:05+00', '2026-11-04 03:17:42+00')",
        )
        .bind(&id_pk)
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
        let q = Query(ListQuery { identity_pubkey_hex: hex::encode(&id_pk), revoked: None });
        let d = &list(State(state(pool)), q).await.unwrap().0.devices[0];
        assert_eq!(d.last_seen_at, 1_793_750_400, "2026-11-04 00:00 UTC, not 03:17:42");
        assert_eq!(d.registered_at, 1_793_520_005, "the link time stays exact (the apps order devices by it)");
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn keypackages_one_per_device(pool: sqlx::PgPool) {
        use crate::handlers::keypackages::{consume, signed_consume};
        use axum::http::HeaderMap;
        let id = SigningKey::from_bytes(&[21u8; 32]);
        let id_pk = id.verifying_key().to_bytes().to_vec();
        let user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id_pk).bind(user).execute(&pool).await.unwrap();
        let laptop = SigningKey::from_bytes(&[22u8; 32]);
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let _ = add(State(state(pool.clone())), Json(add_req(&id, &laptop, now))).await.unwrap();
        let lpk = laptop.verifying_key().to_bytes().to_vec();
        for (dev, n) in [(&id_pk, 2), (&lpk, 2)] {
            for i in 0..n {
                sqlx::query("INSERT INTO keypackages (keypackage_id, device_pk, kp_bytes, expires_at) VALUES ($1, $2, $3, NOW() + interval '1 day')")
                    .bind(Uuid::now_v7()).bind(dev).bind(vec![dev[0], i]).execute(&pool).await.unwrap();
            }
        }
        let q = |devices: Option<String>| Query(signed_consume(&id, &id_pk, 1, true, devices));
        let got = consume(State(state(pool.clone())), HeaderMap::new(), q(None)).await.unwrap().0;
        let mut devs: Vec<_> = got.iter().map(|i| i.device_pk_hex.clone()).collect();
        devs.sort();
        let mut want = vec![hex::encode(&id_pk), hex::encode(&lpk)];
        want.sort();
        assert_eq!(devs, want, "one KeyPackage from each device");
        // Only the laptop.
        let got = consume(State(state(pool.clone())), HeaderMap::new(), q(Some(hex::encode(&lpk)))).await.unwrap().0;
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].device_pk_hex, hex::encode(&lpk));
        // A revoked device contributes nothing.
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE device_pk = $1").bind(&lpk).execute(&pool).await.unwrap();
        let got = consume(State(state(pool)), HeaderMap::new(), q(None)).await.unwrap().0;
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].device_pk_hex, hex::encode(&id_pk));
    }

    /// DEV-2 — link + revoke in a circle: 32 a month, and a list of at most
    /// 64 (the active ones always in it) however many were ever revoked.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn devices_can_not_be_made_without_end(pool: sqlx::PgPool) {
        let id = SigningKey::from_bytes(&[61u8; 32]);
        let id_pk = id.verifying_key().to_bytes().to_vec();
        let user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id_pk).bind(user).execute(&pool).await.unwrap();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let dev = |n: u8| SigningKey::from_bytes(&[n, 62, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        for n in 0..MAX_LINKED_PER_MONTH as u8 {
            let d = dev(n);
            let dpk = d.verifying_key().to_bytes().to_vec();
            add(State(state(pool.clone())), Json(add_req(&id, &d, now))).await.unwrap();
            let req = RevokeRequest { identity_pubkey_hex: hex::encode(&id_pk), proof_ts: now, proof_hex: action(DEVICE_REVOKE_DOMAIN, &id, &dpk, now) };
            revoke(State(state(pool.clone())), Path(hex::encode(&dpk)), Json(req)).await.unwrap();
        }
        assert!(matches!(add(State(state(pool.clone())), Json(add_req(&id, &dev(200), now))).await, Err(DevicesError::Conflict(_))));
        // A month later linking works again.
        sqlx::query("UPDATE devices SET registered_at = NOW() - interval '31 days' WHERE certificate IS NOT NULL").execute(&pool).await.unwrap();
        add(State(state(pool.clone())), Json(add_req(&id, &dev(200), now))).await.unwrap();
        // Years of it: the list stays short, the active devices are in it.
        sqlx::query(
            "INSERT INTO devices (device_pk, user_pk, credential, certificate, registered_at, revoked_at, revoke_proof, revoke_proof_ts) \
             SELECT sha256(g::text::bytea), $1, '\\x00', '\\x00', NOW() - interval '90 days', NOW() - interval '80 days', '\\x00', 1 \
             FROM generate_series(1, 300) g",
        )
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
        let q = Query(ListQuery { identity_pubkey_hex: hex::encode(&id_pk), revoked: Some("1".into()) });
        let listed = list(State(state(pool)), q).await.unwrap().0.devices;
        assert_eq!(listed.len() as i64, MAX_LISTED_DEVICES);
        let active: Vec<&DeviceOut> = listed.iter().filter(|d| !d.revoked).collect();
        assert_eq!(active.len(), 2, "the primary and the linked one");
        assert_eq!(listed.iter().filter(|d| d.revoke_proof_ts == now).count(), 32, "the latest revoked before the old ones");
        assert!(listed.windows(2).all(|w| w[0].registered_at <= w[1].registered_at), "ordered as before");
    }

    /// DEV-3 — 16 links at once: no more than 8 get in.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn links_at_once_do_not_pass_the_limit(pool: sqlx::PgPool) {
        let now = OffsetDateTime::now_utc().unix_timestamp();
        for person in 0..4u8 {
            let id = SigningKey::from_bytes(&[70 + person; 32]);
            let id_pk = id.verifying_key().to_bytes().to_vec();
            let user = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id_pk).bind(user).execute(&pool).await.unwrap();
            let tasks: Vec<_> = (0..16u8)
                .map(|n| {
                    let mut seed = [80 + person; 32];
                    seed[0] = n;
                    let req = add_req(&id, &SigningKey::from_bytes(&seed), now);
                    tokio::spawn(add(State(state(pool.clone())), Json(req)))
                })
                .collect();
            let mut ok = 0;
            for t in tasks {
                match t.await.unwrap() {
                    Ok(_) => ok += 1,
                    Err(e) => assert!(matches!(e, DevicesError::Conflict(_))),
                }
            }
            assert_eq!(ok, MAX_LINKED_DEVICES);
            let (linked,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices WHERE user_pk = $1 AND certificate IS NOT NULL")
                .bind(user)
                .fetch_one(&pool)
                .await
                .unwrap();
            assert_eq!(linked, MAX_LINKED_DEVICES);
        }
    }

    /// PREV-8 — the clean-up migration revokes a certificate-less "device"
    /// that is not the identity key, and nothing else.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn ghost_devices_are_revoked_and_honest_ones_stay(pool: sqlx::PgPool) {
        let id = SigningKey::from_bytes(&[91u8; 32]);
        let id_pk = id.verifying_key().to_bytes().to_vec();
        let user = Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&id_pk).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&id_pk).bind(user).execute(&pool).await.unwrap();
        let laptop = SigningKey::from_bytes(&[92u8; 32]);
        let now = OffsetDateTime::now_utc().unix_timestamp();
        add(State(state(pool.clone())), Json(add_req(&id, &laptop, now))).await.unwrap();
        let ghost = vec![93u8; 32];
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&ghost).bind(user).execute(&pool).await.unwrap();
        sqlx::query(include_str!("../../migrations/20261112200500_revoke_ghost_devices.sql")).execute(&pool).await.unwrap();
        let active: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT device_pk FROM devices WHERE revoked_at IS NULL ORDER BY registered_at").fetch_all(&pool).await.unwrap();
        assert_eq!(active, vec![(id_pk,), (laptop.verifying_key().to_bytes().to_vec(),)]);
    }
}
