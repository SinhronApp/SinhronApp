// ADR-077 — the server's service notices, for its administrators.
//
//     POST /v1/admin/notices   { identity_pubkey_hex, after_id, proof_ts, proof_hex }
//         Signed (ADMIN_NOTICES_DOMAIN, body = after_id in decimal) by the
//         identity key or a linked device of a person listed in
//         SINHRON_ADMIN_IDENTITIES. 200 { notices: [{ id, kind, text, ts }] }
//         — those after `after_id`, oldest first, at most the last
//         [MAX_NOTICES]. 403 for anyone else: the app then shows nothing
//         (and asks again at its next start).
//
// The notices themselves are written by crate::admin.

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::error;

use super::proof::{self, ADMIN_NOTICES_DOMAIN};
use crate::AppState;

/// Most notices in one answer (the newest ones).
pub const MAX_NOTICES: i64 = 500;

#[derive(Debug, Deserialize)]
pub struct NoticesRequest {
    pub identity_pubkey_hex: String,
    #[serde(default)]
    pub after_id: i64,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Notice {
    pub id: i64,
    pub kind: String,
    pub text: String,
    /// Unix seconds.
    pub ts: i64,
}

#[derive(Debug, Serialize)]
pub struct NoticesResponse {
    pub notices: Vec<Notice>,
}

#[derive(Debug, thiserror::Error)]
pub enum AdminError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("not an administrator")]
    Forbidden,
    #[error("no db configured")]
    NoDb,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
}

impl IntoResponse for AdminError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            AdminError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            AdminError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            AdminError::Forbidden => (StatusCode::FORBIDDEN, "not an administrator".to_string()),
            AdminError::NoDb => (StatusCode::SERVICE_UNAVAILABLE, "no database configured".to_string()),
            AdminError::Db(e) => {
                error!(error = %e, "db error in admin handler");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

/// `POST /v1/admin/notices` — see the module comment.
pub async fn notices(
    State(state): State<AppState>,
    Json(req): Json<NoticesRequest>,
) -> Result<Json<NoticesResponse>, AdminError> {
    let pool = state.pool.ok_or(AdminError::NoDb)?;
    let signer =
        hex::decode(&req.identity_pubkey_hex).map_err(|e| AdminError::BadRequest(format!("identity: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| AdminError::BadRequest(format!("proof_hex: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(ADMIN_NOTICES_DOMAIN, &signer, req.after_id.to_string().as_bytes(), req.proof_ts, &sig, now)
        .map_err(|e| AdminError::Unauthorized(e.to_string()))?;
    let cfg = crate::admin::config();
    if !cfg.enabled() {
        return Err(AdminError::Forbidden);
    }
    // A linked device reads for its person.
    let Some((_, person)) = crate::accounts::resolve_signer(&pool, &signer).await? else {
        return Err(AdminError::Forbidden);
    };
    if !cfg.is_admin(&person) {
        return Err(AdminError::Forbidden);
    }
    let rows: Vec<(i64, String, String, OffsetDateTime)> = sqlx::query_as(
        "SELECT id, kind, body, created_at FROM (\
           SELECT id, kind, body, created_at FROM admin_notices WHERE id > $1 ORDER BY id DESC LIMIT $2\
         ) t ORDER BY id",
    )
    .bind(req.after_id)
    .bind(MAX_NOTICES)
    .fetch_all(&pool)
    .await?;
    Ok(Json(NoticesResponse {
        notices: rows
            .into_iter()
            .map(|(id, kind, text, at)| Notice { id, kind, text, ts: at.unix_timestamp() })
            .collect(),
    }))
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

    fn req(sk: &SigningKey, after_id: i64) -> NoticesRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = ADMIN_NOTICES_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(after_id.to_string().as_bytes()));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        NoticesRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            after_id,
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    async fn register(pool: &sqlx::PgPool, sk: &SigningKey) {
        let pk = sk.verifying_key().to_bytes().to_vec();
        let user = uuid::Uuid::new_v4();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(user)
            .bind(&pk)
            .execute(pool)
            .await
            .unwrap();
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL — run with `cargo test -- --include-ignored`"]
    async fn only_administrators_read_notices(pool: sqlx::PgPool) {
        let admin = SigningKey::from_bytes(&[0x91; 32]);
        let other = SigningKey::from_bytes(&[0x92; 32]);
        register(&pool, &admin).await;
        register(&pool, &other).await;
        crate::admin::add_admin_for_test(&admin.verifying_key().to_bytes());
        let first = crate::admin::post(&pool, "ok", "hello").await.unwrap();
        crate::admin::post(&pool, "alert", "🔥 busy").await.unwrap();

        let st = || State(state(pool.clone()));
        let Json(all) = notices(st(), Json(req(&admin, 0))).await.unwrap();
        let texts: Vec<&str> = all.notices.iter().map(|n| n.text.as_str()).collect();
        assert_eq!(texts, vec!["hello", "🔥 busy"]);
        assert_eq!(all.notices[1].kind, "alert");
        let Json(newer) = notices(st(), Json(req(&admin, first))).await.unwrap();
        assert_eq!(newer.notices.len(), 1);

        assert!(matches!(notices(st(), Json(req(&other, 0))).await, Err(AdminError::Forbidden)));
        // A signature over another after_id doesn't pass.
        let mut forged = req(&admin, 5);
        forged.after_id = 0;
        assert!(matches!(notices(st(), Json(forged)).await, Err(AdminError::Unauthorized(_))));
    }
}
