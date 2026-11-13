// QR pairing mailbox — tech-debt 4.2 / ADR-025.
//
//   PUT /v1/pairing/{id}   the existing device leaves the account secret,
//                          HPKE-sealed to the key in the new device's QR.
//                          Action proof by the identity key (domain
//                          PAIRING_PUT_DOMAIN, body = id || ciphertext);
//                          first write wins (409 after), 10-minute TTL.
//   GET /v1/pairing/{id}   the new device (no account yet) takes it —
//                          once: the bundle is wiped as it's returned and
//                          a "taken" marker stays 10 minutes, so a later
//                          PUT or GET gets 409 "already used" (ADR-091) —
//                          the owner's phone learns someone else answered.
//
// The id is 128 random bits shown only in the QR; the ciphertext is
// opaque to the server, which never sees the public key it's sealed to.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use base64::{prelude::BASE64_STANDARD, Engine};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::{error, info};

use super::proof::{self, PAIRING_PUT_DOMAIN};
use crate::AppState;

pub const PAIRING_TTL_SECS: i64 = 600;
pub const MAX_PAIRING_CIPHERTEXT: usize = 1024;

#[derive(Debug, Deserialize)]
pub struct PutRequest {
    pub identity_pubkey_hex: String,
    pub ciphertext_b64: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct GetResponse {
    pub ciphertext_b64: String,
}

fn pairing_id(hex_id: &str) -> Result<Vec<u8>, PairingError> {
    let id = hex::decode(hex_id).map_err(|e| PairingError::BadRequest(format!("pairing id: {e}")))?;
    if id.len() != 16 {
        return Err(PairingError::BadRequest("pairing id must be 16 bytes".into()));
    }
    Ok(id)
}

pub async fn put(
    State(state): State<AppState>,
    Path(id_hex): Path<String>,
    Json(req): Json<PutRequest>,
) -> Result<StatusCode, PairingError> {
    let pool = state.pool.ok_or(PairingError::NoDb)?;
    let id = pairing_id(&id_hex)?;
    let ct = BASE64_STANDARD
        .decode(&req.ciphertext_b64)
        .map_err(|e| PairingError::BadRequest(format!("ciphertext: {e}")))?;
    if ct.is_empty() || ct.len() > MAX_PAIRING_CIPHERTEXT {
        return Err(PairingError::BadRequest(format!("ciphertext must be 1..={MAX_PAIRING_CIPHERTEXT} bytes")));
    }
    let identity = hex::decode(&req.identity_pubkey_hex).map_err(|e| PairingError::BadRequest(format!("identity: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| PairingError::BadRequest(format!("proof_hex: {e}")))?;
    let mut body = id.clone();
    body.extend_from_slice(&ct);
    proof::verify_action_proof(PAIRING_PUT_DOMAIN, &identity, &body, req.proof_ts, &sig, OffsetDateTime::now_utc().unix_timestamp())
        .map_err(|e| PairingError::Unauthorized(e.to_string()))?;
    // After the proof (server-http:4): junk in someone's name blocked their pairing.
    if state.rate.check_kp_upload(&format!("pairing:{}", req.identity_pubkey_hex)).is_err() {
        return Err(PairingError::RateLimited);
    }
    let known = crate::accounts::resolve_signer(&pool, &identity).await.map_err(PairingError::db)?;
    if known.is_none() {
        return Err(PairingError::Unauthorized("unknown identity".into()));
    }
    let inserted = sqlx::query(
        "INSERT INTO pairing_mailbox (pairing_id, ciphertext, expires_at) \
         VALUES ($1, $2, NOW() + make_interval(secs => $3::double precision)) \
         ON CONFLICT (pairing_id) DO NOTHING",
    )
    .bind(&id)
    .bind(&ct)
    .bind(PAIRING_TTL_SECS as f64)
    .execute(&pool)
    .await
    .map_err(PairingError::db)?;
    if inserted.rows_affected() == 0 {
        return Err(PairingError::Conflict);
    }
    info!("pairing secret left for a new device");
    Ok(StatusCode::NO_CONTENT)
}

pub async fn take(State(state): State<AppState>, Path(id_hex): Path<String>) -> Result<Json<GetResponse>, PairingError> {
    let pool = state.pool.ok_or(PairingError::NoDb)?;
    let id = pairing_id(&id_hex)?;
    // Taken once: the bundle is wiped and a "taken" marker stays for the
    // TTL, so a later PUT or GET gets 409 instead of a fresh start (ADR-091).
    let row: Option<(Vec<u8>,)> = sqlx::query_as(
        "UPDATE pairing_mailbox m SET taken = TRUE, ciphertext = ''::bytea, \
                expires_at = NOW() + make_interval(secs => $2::double precision) \
         FROM (SELECT pairing_id, ciphertext FROM pairing_mailbox \
               WHERE pairing_id = $1 AND expires_at > NOW() AND NOT taken FOR UPDATE) old \
         WHERE m.pairing_id = old.pairing_id RETURNING old.ciphertext",
    )
    .bind(&id)
    .bind(PAIRING_TTL_SECS as f64)
    .fetch_optional(&pool)
    .await
    .map_err(PairingError::db)?;
    if let Some((ct,)) = row {
        return Ok(Json(GetResponse { ciphertext_b64: BASE64_STANDARD.encode(ct) }));
    }
    let taken: Option<(bool,)> =
        sqlx::query_as("SELECT taken FROM pairing_mailbox WHERE pairing_id = $1 AND expires_at > NOW() AND taken")
            .bind(&id)
            .fetch_optional(&pool)
            .await
            .map_err(PairingError::db)?;
    Err(if taken.is_some() { PairingError::Conflict } else { PairingError::NotFound })
}

#[derive(Debug, thiserror::Error)]
pub enum PairingError {
    #[error("database unavailable")]
    NoDb,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("nothing here (yet)")]
    NotFound,
    #[error("already used")]
    Conflict,
    #[error("rate limited")]
    RateLimited,
    #[error("internal error")]
    Db,
}

impl PairingError {
    fn db(e: sqlx::Error) -> Self {
        error!(error = %e, "pairing db error");
        Self::Db
    }
}

impl IntoResponse for PairingError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::NoDb => StatusCode::SERVICE_UNAVAILABLE,
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Conflict => StatusCode::CONFLICT,
            Self::RateLimited => StatusCode::TOO_MANY_REQUESTS,
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

    fn req(sk: &SigningKey, id: &[u8], ct: &[u8]) -> PutRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut body = id.to_vec();
        body.extend_from_slice(ct);
        let mut m = PAIRING_PUT_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(&body));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        PutRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            ciphertext_b64: BASE64_STANDARD.encode(ct),
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn mailbox_is_signed_write_once_read_once(pool: sqlx::PgPool) {
        let alice = SigningKey::from_bytes(&[51u8; 32]);
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(alice.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let id = [9u8; 16];
        let p = || Path(hex::encode(id));

        assert!(matches!(take(State(state(pool.clone())), p()).await, Err(PairingError::NotFound)), "nothing yet");
        // A stranger (unregistered key) can't leave anything.
        let stranger = SigningKey::from_bytes(&[52u8; 32]);
        assert!(matches!(put(State(state(pool.clone())), p(), Json(req(&stranger, &id, b"x"))).await, Err(PairingError::Unauthorized(_))));
        // A signature over other bytes doesn't count.
        let mut forged = req(&alice, &id, b"secret");
        forged.ciphertext_b64 = BASE64_STANDARD.encode(b"evil");
        assert!(matches!(put(State(state(pool.clone())), p(), Json(forged)).await, Err(PairingError::Unauthorized(_))));

        assert_eq!(put(State(state(pool.clone())), p(), Json(req(&alice, &id, b"secret"))).await.unwrap(), StatusCode::NO_CONTENT);
        assert!(matches!(put(State(state(pool.clone())), p(), Json(req(&alice, &id, b"again"))).await, Err(PairingError::Conflict)));

        let got = take(State(state(pool.clone())), p()).await.unwrap();
        assert_eq!(BASE64_STANDARD.decode(&got.0.ciphertext_b64).unwrap(), b"secret");
        assert!(matches!(take(State(state(pool)), p()).await, Err(PairingError::Conflict)), "taken once — then 409");
    }

    // storage-devices:13 follow-up — a stranger answers the QR first and the
    // new phone takes it; the owner's own answer must then get 409 (not a
    // fresh 204 into an emptied row), so the old phone can warn him.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn owner_answer_after_a_hijacked_take_gets_409(pool: sqlx::PgPool) {
        let stranger = SigningKey::from_bytes(&[53u8; 32]);
        let owner = SigningKey::from_bytes(&[54u8; 32]);
        for k in [&stranger, &owner] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(uuid::Uuid::now_v7())
                .bind(k.verifying_key().to_bytes().to_vec())
                .execute(&pool)
                .await
                .unwrap();
        }
        let id = [10u8; 16];
        let p = || Path(hex::encode(id));
        assert_eq!(put(State(state(pool.clone())), p(), Json(req(&stranger, &id, b"theirs"))).await.unwrap(), StatusCode::NO_CONTENT);
        take(State(state(pool.clone())), p()).await.unwrap();
        assert!(
            matches!(put(State(state(pool.clone())), p(), Json(req(&owner, &id, b"mine"))).await, Err(PairingError::Conflict)),
            "the owner learns the code was already used"
        );
        assert!(matches!(take(State(state(pool)), p()).await, Err(PairingError::Conflict)), "a second take is told too");
    }
}
