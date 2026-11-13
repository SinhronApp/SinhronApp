// ADR-043 (short links) — `https://<this server>/i/<id>#<key>`.
//
//   POST /v1/invites        {"id", "blob_b64"} — the app leaves its signed
//                           invite link, sealed under the key in the short
//                           link's #fragment. No account (an invite isn't
//                           tied to one); first write wins (409 after);
//                           kept a year. Per client IP: 30 an hour.
//   GET  /v1/invites/{id}   {"blob_b64"} — the opening phone fetches it;
//                           404 when gone. Per client IP: 120 an hour.
//   GET  /i/{id}            the install page, as /join (join.rs).
//
// The blob is opaque here: the server can't tell who invites or their
// name — only that an invite was made and when, and who fetched it. Nothing
// logs the id next to an IP.

use axum::{
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use base64::{prelude::BASE64_STANDARD, Engine};
use serde::{Deserialize, Serialize};
use tracing::{error, info};

use crate::rate_limit::StaticLimiter;
use crate::AppState;

pub const MAX_BLOB: usize = 4096;
const ID_LEN: usize = 10;
const TTL_DAYS: i32 = 365;
/// WEB-2 — at most this many live invites on the whole server (≤ ~400 MB),
/// however many addresses ask. Past it the app shares the long link.
const MAX_LIVE: i64 = 100_000;

static CREATE_PER_IP: StaticLimiter = StaticLimiter::new("SINHRON_RATE_INVITE_CREATE_IP", 30, 3_600);
static FETCH_PER_IP: StaticLimiter = StaticLimiter::new("SINHRON_RATE_INVITE_FETCH_IP", 120, 3_600);

#[derive(Debug, Deserialize)]
pub struct CreateRequest {
    pub id: String,
    pub blob_b64: String,
}

#[derive(Debug, Serialize)]
pub struct GetResponse {
    pub blob_b64: String,
}

fn check_id(id: &str) -> Result<(), InviteError> {
    if id.len() == ID_LEN && id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        Ok(())
    } else {
        Err(InviteError::BadRequest("id must be 10 letters or digits".into()))
    }
}

fn limit(limiter: &StaticLimiter, label: &str, headers: &HeaderMap) -> Result<(), InviteError> {
    if let Some(ip) = crate::admin::client_rate_key(headers) {
        if limiter.check(&ip).is_err() {
            crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&[label]).inc();
            return Err(InviteError::RateLimited);
        }
    }
    Ok(())
}

pub async fn create(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateRequest>,
) -> Result<StatusCode, InviteError> {
    let pool = state.pool.ok_or(InviteError::NoDb)?;
    // WEB-3 — refused requests count too.
    limit(&CREATE_PER_IP, "invite_create_ip", &headers)?;
    check_id(&req.id)?;
    let blob = BASE64_STANDARD.decode(&req.blob_b64).map_err(|e| InviteError::BadRequest(format!("blob: {e}")))?;
    if blob.is_empty() {
        return Err(InviteError::BadRequest("empty blob".into()));
    }
    if blob.len() > MAX_BLOB {
        return Err(InviteError::TooBig);
    }
    let (live,): (i64,) = sqlx::query_as("SELECT count(*) FROM short_invites WHERE expires_at > NOW()")
        .fetch_one(&pool)
        .await
        .map_err(InviteError::db)?;
    if live >= MAX_LIVE {
        error!("short invites are full");
        return Err(InviteError::Full);
    }
    let inserted = sqlx::query(
        "INSERT INTO short_invites (id, blob, expires_at) VALUES ($1, $2, NOW() + make_interval(days => $3)) \
         ON CONFLICT (id) DO NOTHING",
    )
    .bind(&req.id)
    .bind(&blob)
    .bind(TTL_DAYS)
    .execute(&pool)
    .await
    .map_err(InviteError::db)?;
    if inserted.rows_affected() == 0 {
        return Err(InviteError::Conflict);
    }
    info!("short invite stored");
    Ok(StatusCode::CREATED)
}

pub async fn get(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<GetResponse>, InviteError> {
    let pool = state.pool.ok_or(InviteError::NoDb)?;
    check_id(&id).map_err(|_| InviteError::NotFound)?;
    limit(&FETCH_PER_IP, "invite_fetch_ip", &headers)?;
    let row: Option<(Vec<u8>,)> = sqlx::query_as("SELECT blob FROM short_invites WHERE id = $1 AND expires_at > NOW()")
        .bind(&id)
        .fetch_optional(&pool)
        .await
        .map_err(InviteError::db)?;
    match row {
        Some((blob,)) => Ok(Json(GetResponse { blob_b64: BASE64_STANDARD.encode(blob) })),
        None => Err(InviteError::NotFound),
    }
}

#[derive(Debug, thiserror::Error)]
pub enum InviteError {
    #[error("database unavailable")]
    NoDb,
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("blob too big (at most {MAX_BLOB} bytes)")]
    TooBig,
    #[error("no such invite")]
    NotFound,
    #[error("id taken")]
    Conflict,
    #[error("rate limited")]
    RateLimited,
    #[error("short links are full")]
    Full,
    #[error("internal error")]
    Db,
}

impl InviteError {
    fn db(e: sqlx::Error) -> Self {
        error!(error = %e, "short invite db error");
        Self::Db
    }
}

impl IntoResponse for InviteError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::NoDb | Self::Full => StatusCode::SERVICE_UNAVAILABLE,
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::TooBig => StatusCode::PAYLOAD_TOO_LARGE,
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

    fn state(pool: sqlx::PgPool) -> AppState {
        AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    fn req(id: &str, blob: &[u8]) -> Json<CreateRequest> {
        Json(CreateRequest { id: id.into(), blob_b64: BASE64_STANDARD.encode(blob) })
    }

    fn status<T>(r: Result<T, InviteError>) -> StatusCode {
        match r {
            Ok(_) => StatusCode::OK,
            Err(e) => e.into_response().status(),
        }
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn an_invite_is_stored_once_and_fetched_until_it_expires(pool: sqlx::PgPool) {
        let s = || State(state(pool.clone()));
        let h = HeaderMap::new;
        assert_eq!(create(s(), h(), req("Ab3dEf7hJk", b"sealed")).await.unwrap(), StatusCode::CREATED);
        assert_eq!(status(create(s(), h(), req("Ab3dEf7hJk", b"other")).await), StatusCode::CONFLICT);
        assert_eq!(status(create(s(), h(), req("short", b"x")).await), StatusCode::BAD_REQUEST);
        assert_eq!(status(create(s(), h(), req("Ab3dEf7h!k", b"x")).await), StatusCode::BAD_REQUEST);
        assert_eq!(status(create(s(), h(), req("Zz3dEf7hJk", b"")).await), StatusCode::BAD_REQUEST);
        assert_eq!(status(create(s(), h(), req("Zz3dEf7hJk", &[0; MAX_BLOB + 1])).await), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(create(s(), h(), req("Zz3dEf7hJk", &[0; MAX_BLOB])).await.unwrap(), StatusCode::CREATED);

        let got = get(s(), h(), Path("Ab3dEf7hJk".into())).await.unwrap();
        assert_eq!(BASE64_STANDARD.decode(&got.0.blob_b64).unwrap(), b"sealed", "the first write won");
        assert_eq!(status(get(s(), h(), Path("Nope000000".into())).await), StatusCode::NOT_FOUND);
        assert_eq!(status(get(s(), h(), Path("../../etc".into())).await), StatusCode::NOT_FOUND);

        // Kept a year; past that it reads as gone, and the retention sweep empties it.
        let (days,): (f64,) = sqlx::query_as(
            "SELECT EXTRACT(EPOCH FROM expires_at - created_at)::float8 / 86400 FROM short_invites WHERE id = 'Ab3dEf7hJk'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!((days - 365.0).abs() < 0.01, "{days}");
        sqlx::query("UPDATE short_invites SET expires_at = NOW() - interval '1 second' WHERE id = 'Ab3dEf7hJk'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(status(get(s(), h(), Path("Ab3dEf7hJk".into())).await), StatusCode::NOT_FOUND);
        crate::retention::sweep(&pool, 30).await.unwrap();
        // WEB-4 — the blob goes, the id stays taken: an old link can't be re-pointed.
        let (kept,): (i32,) =
            sqlx::query_as("SELECT octet_length(blob) FROM short_invites WHERE id = 'Ab3dEf7hJk'").fetch_one(&pool).await.unwrap();
        assert_eq!(kept, 0, "the blob went, the id stays taken");
        assert_eq!(status(create(s(), h(), req("Ab3dEf7hJk", b"evil")).await), StatusCode::CONFLICT);
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn creating_is_limited_per_client_ip(pool: sqlx::PgPool) {
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "198.51.100.77".parse().unwrap());
        let mut last = StatusCode::CREATED;
        for i in 0..31 {
            last = status(create(State(state(pool.clone())), h.clone(), req(&format!("Rate{i:06}"), b"x")).await);
        }
        assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
    }

    /// WEB-2 — no account and a fresh address per request must not fill the disk.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn the_whole_server_keeps_a_bounded_number_of_invites(pool: sqlx::PgPool) {
        sqlx::query(
            "INSERT INTO short_invites (id, blob, expires_at) \
             SELECT lpad(i::text, 10, '0'), 'x', NOW() + interval '1 day' FROM generate_series(1, $1) i",
        )
        .bind(MAX_LIVE - 1)
        .execute(&pool)
        .await
        .unwrap();
        let s = || State(state(pool.clone()));
        assert_eq!(create(s(), HeaderMap::new(), req("LastOne000", b"x")).await.unwrap(), StatusCode::CREATED);
        assert_eq!(status(create(s(), HeaderMap::new(), req("OneTooMany", b"x")).await), StatusCode::SERVICE_UNAVAILABLE);
        // Expired ones don't count.
        sqlx::query("UPDATE short_invites SET expires_at = NOW() - interval '1 second' WHERE id = 'LastOne000'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(create(s(), HeaderMap::new(), req("OneTooMany", b"x")).await.unwrap(), StatusCode::CREATED);
    }

    /// WEB-3 — a body far past any invite is refused before it's read and parsed.
    #[tokio::test]
    async fn an_oversized_body_is_refused_unparsed() {
        use tower::ServiceExt;
        let post = |blob_len: usize| {
            let st = AppState {
                pool: None,
                sessions: crate::session::SessionRegistry::new(),
                push: std::sync::Arc::new(crate::push::LoggingPush),
                rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
                calls: crate::call_session::CallSessionRegistry::new(),
            };
            let body = serde_json::json!({ "id": "Ab3dEf7hJk", "blob_b64": BASE64_STANDARD.encode(vec![0u8; blob_len]) });
            let req = axum::http::Request::post("/v1/invites")
                .header("content-type", "application/json")
                .body(axum::body::Body::from(body.to_string()))
                .unwrap();
            async move { crate::build_app(st).oneshot(req).await.unwrap().status() }
        };
        assert_eq!(post(100 * 1024).await, StatusCode::PAYLOAD_TOO_LARGE);
        // The biggest real invite still reaches the handler (no database here).
        assert_eq!(post(MAX_BLOB).await, StatusCode::SERVICE_UNAVAILABLE);
    }

    /// server-http:9 — a new IPv6 address from the same /64 was a new client.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn new_addresses_in_one_ipv6_64_share_the_limit(pool: sqlx::PgPool) {
        let mut last = StatusCode::CREATED;
        for i in 0..31 {
            let mut h = HeaderMap::new();
            h.insert("x-forwarded-for", format!("2001:db8:77:1:{i:x}::9").parse().unwrap());
            last = status(create(State(state(pool.clone())), h, req(&format!("Six{i:07}"), b"x")).await);
        }
        assert_eq!(last, StatusCode::TOO_MANY_REQUESTS);
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "::ffff:198.51.100.78".parse().unwrap());
        assert_eq!(crate::admin::client_rate_key(&h).as_deref(), Some("198.51.100.78"), "IPv4 stays per address");
    }
}
