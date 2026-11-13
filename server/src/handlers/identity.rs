// Identity registration endpoint — WU A3.
//
// Wire contract:
//
//     POST /v1/identity
//     Content-Type: application/json
//     {
//       "identity_pubkey_hex": "64 hex chars",   // 32-byte Ed25519 pubkey
//       "registration_proof_hex": "128 hex chars" // 64-byte signature
//     }
//
//     201 Created  → new user persisted
//     200 OK       → already registered (idempotent — returns existing user_pk)
//     400 Bad Request → malformed body / hex / lengths
//     401 Unauthorized → signature verification failed
//     403 Forbidden → the operator blocked this key (ACCT-2)
//     500 Internal  → DB error
//
// Response body (both 200 and 201):
//
//     { "user_pk": "uuid-v7", "registered_at": "rfc3339", "already_existed": bool }

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::{debug, error, info};
use uuid::Uuid;

use super::proof;
use crate::rate_limit::StaticLimiter;
use crate::AppState;

/// New accounts per client IP. The per-key limit below is no limit for
/// someone making a fresh key each time (security review 2026-11-02);
/// a family setting up several phones at home stays well under it.
static REGISTER_PER_IP: StaticLimiter = StaticLimiter::new("SINHRON_RATE_REGISTER_IP", 20, 3_600);

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub identity_pubkey_hex: String,
    pub registration_proof_hex: String,
    /// Optional: register a primary device atomically in the same
    /// transaction. Sinhron's design has device-credential keys that
    /// are distinct from the identity key (spec §6.5). Multi-device
    /// onboarding adds additional devices via `POST /v1/devices` later.
    #[serde(default)]
    pub primary_device: Option<PrimaryDevice>,
}

#[derive(Debug, Deserialize)]
pub struct PrimaryDevice {
    /// 32-byte device_pk (the device's own Ed25519 verifying key).
    pub device_pk_hex: String,
    /// MLS BasicCredential bytes. For now we store the device pubkey
    /// itself (32 bytes); when full MLS credentials land we'll accept
    /// arbitrary length per RFC 9420.
    pub device_credential_hex: String,
}

#[derive(Debug, Serialize)]
pub struct RegisterResponse {
    /// UUIDv7 — time-ordered, suitable as a sort key. Server-generated
    /// on first registration; preserved across idempotent retries.
    pub user_pk: Uuid,
    /// Server-side registration timestamp (RFC 3339).
    #[serde(with = "time::serde::rfc3339")]
    pub registered_at: OffsetDateTime,
    /// `true` when this is a no-op replay (row already existed);
    /// `false` for the first registration that actually created the row.
    pub already_existed: bool,
    /// Confirmed device_pk if a primary_device was registered. `None`
    /// when the request omitted primary_device.
    pub primary_device_pk_hex: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum RegisterError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    /// The operator blocked this key (`scripts/reports.sh ban`).
    #[error("account blocked")]
    Banned,
    #[error("no db configured")]
    NoDb,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
    /// T1.5 — rate-limit tripped. The client should back off for at
    /// least `retry_after_secs` seconds before retrying.
    #[error("rate limited; retry after {retry_after_secs}s")]
    RateLimited { retry_after_secs: u64 },
}

impl IntoResponse for RegisterError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            RegisterError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            RegisterError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            RegisterError::Banned => (StatusCode::FORBIDDEN, "account blocked".to_string()),
            RegisterError::NoDb => (
                StatusCode::SERVICE_UNAVAILABLE,
                "no database configured".to_string(),
            ),
            RegisterError::Db(e) => {
                error!(error = %e, "db error in register handler");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
            RegisterError::RateLimited { retry_after_secs } => {
                // 429 + Retry-After header. Standard pattern.
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

pub async fn register(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<RegisterRequest>,
) -> Result<(StatusCode, Json<RegisterResponse>), RegisterError> {
    let pool = state.pool.ok_or(RegisterError::NoDb)?;

    if let Some(ip) = crate::admin::client_rate_key(&headers) {
        if let Err(retry_after) = REGISTER_PER_IP.check(&ip) {
            crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["register_ip"]).inc();
            return Err(RegisterError::RateLimited { retry_after_secs: retry_after.as_secs() });
        }
    }

    // ── Parse + validate ─────────────────────────────────────────────
    let pubkey = hex::decode(&req.identity_pubkey_hex)
        .map_err(|e| RegisterError::BadRequest(format!("identity_pubkey_hex: {e}")))?;
    let proof_bytes = hex::decode(&req.registration_proof_hex)
        .map_err(|e| RegisterError::BadRequest(format!("registration_proof_hex: {e}")))?;

    // ── Verify the self-signed proof ─────────────────────────────────
    proof::verify_registration_proof(&pubkey, &proof_bytes)
        .map_err(|e| match e {
            proof::ProofError::PubkeyLen(_) | proof::ProofError::SignatureLen(_) => {
                RegisterError::BadRequest(e.to_string())
            }
            proof::ProofError::PubkeyInvalid(_) | proof::ProofError::SignatureMismatch => {
                RegisterError::Unauthorized(e.to_string())
            }
            // Registration proof has no timestamp — this arm shouldn't
            // fire, but pattern-matching exhaustiveness demands it.
            proof::ProofError::StaleTimestamp { .. } => {
                RegisterError::Unauthorized(e.to_string())
            }
        })?;

    // T1.5 — rate-limit by the pubkey being registered (defaults: 5/hour).
    // After the proof: junk requests naming someone's key used it up
    // (docs/security-review-2026-11.md, server-http:4).
    if let Err(retry_after) = state.rate.check_register(&req.identity_pubkey_hex) {
        info!(
            ident_prefix = %crate::short_key(&req.identity_pubkey_hex),
            retry_after_secs = retry_after.as_secs(),
            "rate-limited registration",
        );
        // T2.4 — count rate-limit hits per action for ops dashboards.
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["register"])
            .inc();
        return Err(RegisterError::RateLimited {
            retry_after_secs: retry_after.as_secs(),
        });
    }

    // ── Parse + validate optional primary device ─────────────────────
    // The first device is the identity key itself — every app sends
    // exactly that. The proof is the same bytes forever, so whoever had it
    // could hang their own key on someone's account as one of its devices
    // (docs/security-review-2026-11.md, server-http:2). Linked devices
    // come through POST /v1/devices with a certificate.
    let primary_device_bytes = if let Some(d) = req.primary_device.as_ref() {
        let pk = hex::decode(&d.device_pk_hex)
            .map_err(|e| RegisterError::BadRequest(format!("device_pk_hex: {e}")))?;
        let cred = hex::decode(&d.device_credential_hex)
            .map_err(|e| RegisterError::BadRequest(format!("device_credential_hex: {e}")))?;
        if pk != pubkey || cred != pubkey {
            return Err(RegisterError::BadRequest(
                "primary device must be the identity key".to_string(),
            ));
        }
        Some((pk, cred))
    } else {
        None
    };

    // ── Idempotent insert (users + optional devices, transactional) ──
    //
    // The `users.identity_pubkey` UNIQUE constraint guarantees only one
    // row per pubkey. We use INSERT ... ON CONFLICT DO NOTHING + RETURNING
    // and then a follow-up SELECT for the conflict case so the handler
    // returns the same user_pk on replays. The device upsert sits in the
    // same transaction so a partial register (user but no device, or
    // vice versa) cannot leak through.
    let new_user_pk = Uuid::now_v7();
    let mut tx = pool.begin().await?;

    let inserted: Option<(Uuid, OffsetDateTime)> = sqlx::query_as(
        "INSERT INTO users (user_pk, identity_pubkey, registered_at) \
         VALUES ($1, $2, NOW()) \
         ON CONFLICT (identity_pubkey) DO NOTHING \
         RETURNING user_pk, registered_at",
    )
    .bind(new_user_pk)
    .bind(&pubkey)
    .fetch_optional(&mut *tx)
    .await?;

    let (user_pk, registered_at, already_existed) = match inserted {
        Some((pk, ts)) => (pk, ts, false),
        None => {
            let existing: (Uuid, OffsetDateTime, String) = sqlx::query_as(
                "SELECT user_pk, registered_at, status FROM users WHERE identity_pubkey = $1",
            )
            .bind(&pubkey)
            .fetch_one(&mut *tx)
            .await?;
            // ACCT-2 — a ban leaves this row behind: the app registers on
            // every launch, and the same key used to come back at once.
            if existing.2 != "active" {
                return Err(RegisterError::Banned);
            }
            (existing.0, existing.1, true)
        }
    };

    // Upsert primary device if provided. Idempotent (UNIQUE on device_pk
    // → DO NOTHING). Re-registering the same identity with the same
    // device_pk is a no-op; with a DIFFERENT device_pk it adds an
    // additional device row (legitimate multi-device path).
    let confirmed_device_pk_hex = if let Some((dpk, cred)) = primary_device_bytes {
        sqlx::query(
            "INSERT INTO devices (device_pk, user_pk, credential, registered_at) \
             VALUES ($1, $2, $3, NOW()) \
             ON CONFLICT (device_pk) DO NOTHING",
        )
        .bind(&dpk)
        .bind(user_pk)
        .bind(&cred)
        .execute(&mut *tx)
        .await?;
        Some(hex::encode(&dpk))
    } else {
        None
    };

    tx.commit().await?;

    if already_existed {
        debug!(user_pk = %user_pk, "register: already exists");
    } else {
        info!("register: new user");
    }

    let status = if already_existed {
        StatusCode::OK
    } else {
        StatusCode::CREATED
    };
    Ok((
        status,
        Json(RegisterResponse {
            user_pk,
            registered_at,
            already_existed,
            primary_device_pk_hex: confirmed_device_pk_hex,
        }),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn req(sk: &SigningKey, device: &[u8]) -> RegisterRequest {
        let pk = sk.verifying_key().to_bytes();
        let mut m = proof::REGISTRATION_DOMAIN.to_vec();
        m.extend_from_slice(&pk);
        RegisterRequest {
            identity_pubkey_hex: hex::encode(pk),
            registration_proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
            primary_device: Some(PrimaryDevice { device_pk_hex: hex::encode(device), device_credential_hex: hex::encode(device) }),
        }
    }

    // server-http:2 — the registration proof never changes: whoever had it
    // hung their own key on the account as a device. Now only the identity
    // key itself is the first device (what every app sends).
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_replayed_proof_cannot_add_someone_elses_device(pool: sqlx::PgPool) {
        let mut st = crate::tests::no_db_state();
        st.pool = Some(pool.clone());
        let alice = SigningKey::from_bytes(&[0x21u8; 32]);
        let mallory = [0x66u8; 32];
        let ok = register(State(st.clone()), HeaderMap::new(), Json(req(&alice, &alice.verifying_key().to_bytes()))).await;
        assert_eq!(ok.unwrap().0, StatusCode::CREATED);
        let ghost = register(State(st), HeaderMap::new(), Json(req(&alice, &mallory))).await;
        assert!(matches!(ghost, Err(RegisterError::BadRequest(_))));
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices").fetch_one(&pool).await.unwrap();
        assert_eq!(n, 1, "only Alice's own key");
    }

    /// FUZZ-ENV-1 — the weak keys 00…00 and 01 00…00 "signed" anything with a
    /// fixed signature; the server took them as accounts. Registration asks
    /// for a strict signature by the key itself, so they stay out — and an
    /// ordinary key registers, registers again and signs as before.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_weak_key_is_not_registered_and_an_ordinary_one_still_is(pool: sqlx::PgPool) {
        let mut st = crate::tests::no_db_state();
        st.pool = Some(pool.clone());
        let mut one = [0u8; 32];
        one[0] = 1;
        let mut base_s1 = [0x66u8; 64]; // R = the base point, s = 1
        base_s1[0] = 0x58;
        base_s1[32..].fill(0);
        base_s1[32] = 1;
        for key in [[0u8; 32], one] {
            let mut key_s0 = [0u8; 64]; // R = the key, s = 0
            key_s0[..32].copy_from_slice(&key);
            for sig in [key_s0, base_s1] {
                let r = RegisterRequest {
                    identity_pubkey_hex: hex::encode(key),
                    registration_proof_hex: hex::encode(sig),
                    primary_device: Some(PrimaryDevice { device_pk_hex: hex::encode(key), device_credential_hex: hex::encode(key) }),
                };
                let res = register(State(st.clone()), HeaderMap::new(), Json(r)).await;
                assert!(matches!(res, Err(RegisterError::Unauthorized(_))), "{}", hex::encode(key));
            }
        }
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users").fetch_one(&pool).await.unwrap();
        assert_eq!(n, 0, "no weak key became an account");

        let alice = SigningKey::from_bytes(&[0x23u8; 32]);
        let pk = alice.verifying_key().to_bytes();
        let again = || register(State(st.clone()), HeaderMap::new(), Json(req(&alice, &pk)));
        assert_eq!(again().await.unwrap().0, StatusCode::CREATED);
        assert_eq!(again().await.unwrap().0, StatusCode::OK, "the app's next launch");
        assert!(crate::accounts::resolve_signer(&pool, &pk).await.unwrap().is_some());
        // Her login and a signed request, as the app makes them.
        let challenge = [7u8; 32];
        let mut m = proof::WS_AUTH_DOMAIN.to_vec();
        m.extend_from_slice(&challenge);
        let login = alice.sign(&proof::for_localhost(&m)).to_bytes();
        assert!(proof::verify_ws_auth(&pk, &login, &challenge).is_ok());
        let mut m = proof::DEVICE_ADD_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&<sha2::Sha256 as sha2::Digest>::digest(b"body"));
        m.push(b':');
        m.extend_from_slice(&1000i64.to_be_bytes());
        let sig = alice.sign(&proof::for_localhost(&m)).to_bytes();
        assert!(proof::verify_action_proof(proof::DEVICE_ADD_DOMAIN, &pk, b"body", 1000, &sig, 1000).is_ok());
    }

    /// ACCT-2 — a banned key registered again on the app's next launch.
    /// The SQL here is what `scripts/reports.sh ban` runs.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_banned_key_stays_out(pool: sqlx::PgPool) {
        let mut st = crate::tests::no_db_state();
        st.pool = Some(pool.clone());
        let mallory = SigningKey::from_bytes(&[0x22u8; 32]);
        let pk = mallory.verifying_key().to_bytes();
        let again = || register(State(st.clone()), HeaderMap::new(), Json(req(&mallory, &pk)));
        assert_eq!(again().await.unwrap().0, StatusCode::CREATED);
        assert!(crate::accounts::resolve_signer(&pool, &pk).await.unwrap().is_some());

        let key = hex::encode(pk);
        sqlx::query("DELETE FROM users WHERE identity_pubkey = decode($1, 'hex')").bind(&key).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey, status) VALUES (gen_random_uuid(), decode($1, 'hex'), 'banned')")
            .bind(&key)
            .execute(&pool)
            .await
            .unwrap();

        assert!(matches!(again().await, Err(RegisterError::Banned)));
        let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM devices").fetch_one(&pool).await.unwrap();
        assert_eq!(n, 0, "no device comes back");
        // No login, no signed request (WS and every handler ask this).
        assert_eq!(crate::accounts::resolve_signer(&pool, &pk).await.unwrap(), None);
        // "Delete account" doesn't lift the ban.
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = proof::ACCOUNT_DELETE_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&<sha2::Sha256 as sha2::Digest>::digest(pk));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        let del = crate::handlers::account::DeleteRequest {
            identity_pubkey_hex: key,
            proof_ts: ts,
            proof_hex: hex::encode(mallory.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        };
        let gone = crate::handlers::account::delete(State(st.clone()), Json(del)).await;
        assert!(matches!(gone, Err(crate::handlers::account::AccountError::NotFound)));
        assert!(matches!(again().await, Err(RegisterError::Banned)));
    }
}
