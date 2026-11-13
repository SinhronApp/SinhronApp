// Encrypted media blobs — spec §6.9, §7.3 (Media), §11. ADR-017.
//
// Endpoints:
//
//   POST /v1/media
//     Headers:
//       x-sinhron-identity  64 hex   — uploader's Ed25519 identity pubkey
//       x-sinhron-ts        unix secs
//       x-sinhron-proof     128 hex  — action proof, MEDIA_UPLOAD_DOMAIN,
//                                       body = sha256 hex (below)
//       x-sinhron-sha256    64 hex   — sha256 of the request body
//     Body: the ciphertext blob (client-side AES-256-GCM), raw bytes.
//     → 201 {"sha256": "...", "size": N}   stored
//     → 200 {"sha256": "...", "size": N}   already present (dedupe)
//
//   POST /v1/media/touch                                 (ADR-064)
//     Headers: x-sinhron-identity / x-sinhron-ts / x-sinhron-proof
//              (MEDIA_TOUCH_DOMAIN, body = x-sinhron-sha256 below),
//              x-sinhron-sha256 = sha256 hex of the JSON body
//     Body: {"sha256": ["<64 hex>", …]}  (≤ 256)
//     → 200 {"missing": [...]}  the ones not stored; the rest get
//       last_referenced_at = NOW() (another 90 days). Used by a device
//       transfer: the old device learns which media the new one could
//       not open and uploads those from its local copies. Reveals nothing
//       a download of the same hashes wouldn't.
//
//   GET /v1/media/{sha256}
//     Headers: x-sinhron-identity / x-sinhron-ts / x-sinhron-proof
//              (MEDIA_GET_DOMAIN, body = the sha256 hex from the path)
//     → 200 application/octet-stream, the ciphertext
//
// The server never sees plaintext or keys: the media key travels inside
// the MLS application message. Blobs are content-addressed files under
// SINHRON_MEDIA_DIR (`<dir>/<first 2 hex>/<sha256 hex>`); Postgres keeps
// only metadata. Auth happens BEFORE the body is read, so unauthenticated
// clients can't make us spool bytes to disk.
//
// Access model: any registered identity that knows a blob's sha256 may
// fetch it. The hash is unguessable and the content is useless without
// the key from the MLS message; per-group ACLs would require the server
// to learn which blob belongs to which chat — metadata we refuse to hold.
//
// Retention: `last_referenced_at` is bumped on every upload/GET; the
// retention worker deletes blobs untouched for MEDIA_RETENTION_DAYS.

use std::path::{Path, PathBuf};

use axum::{
    body::Body,
    extract::{Path as UrlPath, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use futures_util::StreamExt;
use sha2::{Digest, Sha256};
use time::OffsetDateTime;
use tokio::io::AsyncWriteExt;
use tracing::{info, warn};

use super::proof::{self, MEDIA_GET_DOMAIN, MEDIA_TOUCH_DOMAIN, MEDIA_UPLOAD_DOMAIN};
use crate::AppState;

/// Default cap on a single blob (ciphertext). Override with
/// SINHRON_MEDIA_MAX_BYTES.
pub const DEFAULT_MAX_BYTES: u64 = 100 * 1024 * 1024;

/// New media one person may store in 24 hours — dozens of long videos.
pub const DAILY_BYTES_PER_PERSON: u64 = 4 * 1024 * 1024 * 1024;

/// MEDIA-10 — default cap on all stored media together: blobs share the
/// disk with Postgres, and a full disk stops the whole server. Roomy, so a
/// family's 90 days of photos and video never meet it by honest use; on a
/// small disk set SINHRON_MEDIA_TOTAL_BYTES lower.
pub const DEFAULT_TOTAL_BYTES: u64 = 50 * 1024 * 1024 * 1024;

/// MEDIA-5 — an upload that sends nothing for this long is dropped (its
/// `.part` with it); the server had no timeout of its own for the body.
const BODY_STALL: std::time::Duration = std::time::Duration::from_secs(60);

/// MEDIA-1 — bytes of uploads in progress, per person (keyed like the
/// daily quota). The quota reads finished rows only, so uploads started
/// together all saw the same "used" and all passed.
static IN_FLIGHT: std::sync::Mutex<std::collections::BTreeMap<Vec<u8>, u64>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

/// One upload's share of [IN_FLIGHT]; given back when the handler ends,
/// however it ends (stored, refused, connection dropped).
struct Reserved(Vec<u8>, u64);

impl Reserved {
    /// `None` = stored today + in progress already fills the daily quota.
    fn take(person: &[u8], stored_today: u64, bytes: u64) -> Option<Self> {
        let mut map = IN_FLIGHT.lock().unwrap_or_else(|e| e.into_inner());
        let in_flight = map.get(person).copied().unwrap_or(0);
        if stored_today + in_flight >= DAILY_BYTES_PER_PERSON {
            return None;
        }
        map.insert(person.to_vec(), in_flight + bytes);
        Some(Reserved(person.to_vec(), bytes))
    }
}

impl Drop for Reserved {
    fn drop(&mut self) {
        let mut map = IN_FLIGHT.lock().unwrap_or_else(|e| e.into_inner());
        let left = map.get(&self.0).copied().unwrap_or(0).saturating_sub(self.1);
        if left == 0 {
            map.remove(&self.0);
        } else {
            map.insert(self.0.clone(), left);
        }
    }
}

/// MEDIA-3 — a file the table doesn't know (or a `.part`) this old is
/// nobody's upload in progress: the retention worker removes it.
pub const ORPHAN_MIN_AGE: std::time::Duration = std::time::Duration::from_secs(24 * 3600);

/// Blobs not uploaded or fetched for this long are deleted (spec §7.6).
pub const MEDIA_RETENTION_DAYS: i32 = 90;

const H_IDENTITY: &str = "x-sinhron-identity";
const H_TS: &str = "x-sinhron-ts";
const H_PROOF: &str = "x-sinhron-proof";
const H_SHA256: &str = "x-sinhron-sha256";

/// Most hashes in one `POST /v1/media/touch`.
pub const TOUCH_MAX: usize = 256;

#[derive(Debug, thiserror::Error)]
pub enum MediaError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("not found")]
    NotFound,
    #[error("blob exceeds {0} bytes")]
    TooLarge(u64),
    #[error("rate limited; retry after {0}s")]
    RateLimited(u64),
    #[error("database not configured")]
    NoDb,
    #[error("internal: {0}")]
    Internal(String),
}

impl IntoResponse for MediaError {
    fn into_response(self) -> Response {
        let status = match &self {
            MediaError::BadRequest(_) => StatusCode::BAD_REQUEST,
            MediaError::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            MediaError::Forbidden(_) => StatusCode::FORBIDDEN,
            MediaError::NotFound => StatusCode::NOT_FOUND,
            MediaError::TooLarge(_) => StatusCode::PAYLOAD_TOO_LARGE,
            MediaError::RateLimited(secs) => {
                let mut resp = (
                    StatusCode::TOO_MANY_REQUESTS,
                    Json(serde_json::json!({
                        "error": "rate limited",
                        "retry_after_secs": secs,
                    })),
                )
                    .into_response();
                resp.headers_mut().insert(
                    header::RETRY_AFTER,
                    secs.to_string().parse().expect("ascii digits parse"),
                );
                return resp;
            }
            MediaError::NoDb => StatusCode::SERVICE_UNAVAILABLE,
            MediaError::Internal(e) => {
                warn!(error = %e, "media handler internal error");
                StatusCode::INTERNAL_SERVER_ERROR
            }
        };
        let msg = match &self {
            MediaError::Internal(_) => "internal error".to_string(),
            other => other.to_string(),
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

impl From<sqlx::Error> for MediaError {
    fn from(e: sqlx::Error) -> Self {
        MediaError::Internal(e.to_string())
    }
}

impl From<std::io::Error> for MediaError {
    fn from(e: std::io::Error) -> Self {
        MediaError::Internal(e.to_string())
    }
}

/// Root directory for blob files. Override with SINHRON_MEDIA_DIR.
pub fn media_dir() -> PathBuf {
    std::env::var("SINHRON_MEDIA_DIR")
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("media"))
}

fn env_bytes(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .filter(|&v| v > 0)
        .unwrap_or(default)
}

fn max_bytes() -> u64 {
    env_bytes("SINHRON_MEDIA_MAX_BYTES", DEFAULT_MAX_BYTES)
}

/// `<dir>/<aa>/<sha256 hex>` — two-hex fan-out keeps directories small.
pub fn blob_path(dir: &Path, sha_hex: &str) -> PathBuf {
    dir.join(&sha_hex[..2]).join(sha_hex)
}

/// Lowercase 64-hex check; also what makes `blob_path` safe against
/// path traversal (only [0-9a-f] reaches the filesystem).
fn parse_sha256_hex(s: &str) -> Result<Vec<u8>, MediaError> {
    if s.len() != 64 || !s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(MediaError::BadRequest("sha256 must be 64 lowercase hex".into()));
    }
    hex::decode(s).map_err(|e| MediaError::BadRequest(format!("sha256: {e}")))
}

fn header_str<'a>(headers: &'a HeaderMap, name: &str) -> Result<&'a str, MediaError> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| MediaError::BadRequest(format!("missing header {name}")))
}

/// Verify the action proof carried in headers. Returns the 32-byte
/// identity pubkey.
fn verify_headers(
    headers: &HeaderMap,
    domain: &[u8],
    body: &[u8],
) -> Result<Vec<u8>, MediaError> {
    let identity_hex = header_str(headers, H_IDENTITY)?;
    let pubkey = hex::decode(identity_hex)
        .map_err(|e| MediaError::BadRequest(format!("{H_IDENTITY}: {e}")))?;
    let ts: i64 = header_str(headers, H_TS)?
        .parse()
        .map_err(|_| MediaError::BadRequest(format!("{H_TS} must be unix seconds")))?;
    let sig = hex::decode(header_str(headers, H_PROOF)?)
        .map_err(|e| MediaError::BadRequest(format!("{H_PROOF}: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(domain, &pubkey, body, ts, &sig, now).map_err(|e| match e {
        proof::ProofError::PubkeyLen(_) | proof::ProofError::SignatureLen(_) => {
            MediaError::BadRequest(e.to_string())
        }
        _ => MediaError::Unauthorized(e.to_string()),
    })?;
    Ok(pubkey)
}

/// Any device of the registered user with this identity. `None` = not
/// registered on this server.
async fn device_of(pool: &sqlx::PgPool, identity: &[u8]) -> Result<Option<Vec<u8>>, MediaError> {
    // ADR-027 — the signer may be an active linked device's own key.
    let Some((_, identity)) = crate::accounts::resolve_signer(pool, identity).await? else {
        return Ok(None);
    };
    let row: Option<(Vec<u8>,)> = sqlx::query_as(
        "SELECT d.device_pk FROM devices d \
         JOIN users u ON u.user_pk = d.user_pk \
         WHERE u.identity_pubkey = $1 AND d.revoked_at IS NULL \
         ORDER BY d.registered_at LIMIT 1",
    )
    .bind(&identity)
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|(d,)| d))
}

pub async fn upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Body,
) -> Result<(StatusCode, Json<serde_json::Value>), MediaError> {
    let sha_hex = header_str(&headers, H_SHA256)?.to_string();
    let sha = parse_sha256_hex(&sha_hex)?;

    let identity = verify_headers(&headers, MEDIA_UPLOAD_DOMAIN, sha_hex.as_bytes())?;
    // After the proof: unsigned requests in someone's name used up their
    // bucket (docs/security-review-2026-11.md, server-http:4).
    if let Err(retry) = state.rate.check_media_upload(header_str(&headers, H_IDENTITY)?) {
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["media_upload"])
            .inc();
        return Err(MediaError::RateLimited(retry.as_secs()));
    }
    let pool = state.pool.as_ref().ok_or(MediaError::NoDb)?;
    let device = device_of(pool, &identity)
        .await?
        .ok_or_else(|| MediaError::Forbidden("identity not registered".into()))?;

    let max = max_bytes();
    let declared = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    if declared.is_some_and(|len| len > max) {
        return Err(MediaError::TooLarge(max));
    }

    // Dedupe: same ciphertext already stored → just touch it.
    let existing: Option<(i64,)> = sqlx::query_as(
        "UPDATE media SET last_referenced_at = NOW() WHERE sha256 = $1 RETURNING size_bytes",
    )
    .bind(&sha)
    .fetch_optional(pool)
    .await?;
    // MEDIA-4 — only if the file is really there: a row without its file
    // (a sweep racing a re-upload, a restore without the media volume)
    // said "already stored" forever; now the same upload repairs it.
    if let Some((size,)) = existing.filter(|_| blob_path(&media_dir(), &sha_hex).exists()) {
        return Ok((
            StatusCode::OK,
            Json(serde_json::json!({ "sha256": sha_hex, "size": size })),
        ));
    }
    // One free account could fill the server's disk at ~20 GB an hour
    // (docs/security-review-2026-11.md, server-http:6): what the person's
    // devices stored in the last day.
    let (used,): (i64,) = sqlx::query_as(
        "SELECT COALESCE(SUM(m.size_bytes), 0)::bigint FROM media m \
         JOIN devices d ON d.device_pk = m.uploaded_by_device \
         JOIN devices me ON me.user_pk = d.user_pk \
         WHERE me.device_pk = $1 AND m.uploaded_at > NOW() - interval '1 day'",
    )
    .bind(&device)
    .fetch_one(pool)
    .await?;
    // MEDIA-1 — together with what this person is uploading right now
    // (a body without Content-Length counts as the largest allowed).
    let _reserved =
        Reserved::take(&device, used as u64, declared.unwrap_or(max)).ok_or(MediaError::RateLimited(3_600))?;
    // MEDIA-10 — everyone's media together: new accounts each bring a fresh
    // daily quota, and the disk is shared with Postgres. Same 429 as the
    // daily quota (the app shows it); room comes back as old blobs expire.
    let (total,): (i64,) = sqlx::query_as("SELECT COALESCE(SUM(size_bytes), 0)::bigint FROM media")
        .fetch_one(pool)
        .await?;
    let cap = env_bytes("SINHRON_MEDIA_TOTAL_BYTES", DEFAULT_TOTAL_BYTES);
    if total as u64 + declared.unwrap_or(0) > cap {
        warn!(total, cap, "media storage is full — upload refused");
        return Err(MediaError::RateLimited(3_600));
    }

    // Stream to a temp file in the same directory (atomic rename after
    // the hash checks out), hashing and counting as we go.
    let dir = media_dir();
    let final_path = blob_path(&dir, &sha_hex);
    let shard = final_path.parent().expect("blob_path has a parent").to_path_buf();
    tokio::fs::create_dir_all(&shard).await?;
    let tmp_path = shard.join(format!(".{}.{}.part", sha_hex, uuid::Uuid::new_v4()));

    let written = spool(body, &tmp_path, max, BODY_STALL).await;
    let (size, digest) = match written {
        Ok(v) => v,
        Err(e) => {
            let _ = tokio::fs::remove_file(&tmp_path).await;
            return Err(e);
        }
    };
    if digest.as_slice() != sha.as_slice() {
        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(MediaError::BadRequest("body does not match x-sinhron-sha256".into()));
    }
    if size == 0 {
        let _ = tokio::fs::remove_file(&tmp_path).await;
        return Err(MediaError::BadRequest("empty body".into()));
    }
    tokio::fs::rename(&tmp_path, &final_path).await?;

    sqlx::query(
        // MEDIA-3 — the account may have been deleted while the body came in:
        // the row is still written (nobody's), so retention finds the file.
        "INSERT INTO media (sha256, size_bytes, uploaded_by_device) \
         VALUES ($1, $2, (SELECT device_pk FROM devices WHERE device_pk = $3)) \
         ON CONFLICT (sha256) DO UPDATE SET last_referenced_at = NOW()",
    )
    .bind(&sha)
    .bind(size as i64)
    .bind(&device)
    .execute(pool)
    .await?;

    info!(sha256 = %&sha_hex[..12], size, "media blob stored");
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({ "sha256": sha_hex, "size": size })),
    ))
}

/// Write `body` to `path`, enforcing `max`. Returns (size, sha256).
async fn spool(
    body: Body,
    path: &Path,
    max: u64,
    stall: std::time::Duration,
) -> Result<(u64, Vec<u8>), MediaError> {
    let mut file = tokio::fs::File::create(path).await?;
    let mut hasher = Sha256::new();
    let mut size: u64 = 0;
    let mut stream = body.into_data_stream();
    // MEDIA-5 — a silent connection doesn't hold a `.part` forever.
    while let Some(chunk) = tokio::time::timeout(stall, stream.next())
        .await
        .map_err(|_| MediaError::BadRequest("body stalled".into()))?
    {
        let chunk = chunk.map_err(|e| MediaError::BadRequest(format!("body: {e}")))?;
        size += chunk.len() as u64;
        if size > max {
            return Err(MediaError::TooLarge(max));
        }
        hasher.update(&chunk);
        file.write_all(&chunk).await?;
    }
    file.sync_all().await?;
    Ok((size, hasher.finalize().to_vec()))
}

pub async fn download(
    State(state): State<AppState>,
    UrlPath(sha_hex): UrlPath<String>,
    headers: HeaderMap,
) -> Result<Response, MediaError> {
    let sha = parse_sha256_hex(&sha_hex)?;
    let identity = verify_headers(&headers, MEDIA_GET_DOMAIN, sha_hex.as_bytes())?;
    let pool = state.pool.as_ref().ok_or(MediaError::NoDb)?;
    if device_of(pool, &identity).await?.is_none() {
        return Err(MediaError::Forbidden("identity not registered".into()));
    }

    let row: Option<(i64,)> = sqlx::query_as(
        "UPDATE media SET last_referenced_at = NOW() WHERE sha256 = $1 RETURNING size_bytes",
    )
    .bind(&sha)
    .fetch_optional(pool)
    .await?;
    let Some((size,)) = row else {
        return Err(MediaError::NotFound);
    };

    let file = match tokio::fs::File::open(blob_path(&media_dir(), &sha_hex)).await {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            warn!(sha256 = %&sha_hex[..12], "media row without file");
            return Err(MediaError::NotFound);
        }
        Err(e) => return Err(e.into()),
    };
    let stream = tokio_util::io::ReaderStream::new(file);
    Ok((
        [
            (header::CONTENT_TYPE, "application/octet-stream".to_string()),
            (header::CONTENT_LENGTH, size.to_string()),
            // Content-addressed and immutable; private because the
            // request is authenticated.
            (header::CACHE_CONTROL, "private, max-age=31536000, immutable".to_string()),
        ],
        Body::from_stream(stream),
    )
        .into_response())
}

#[derive(serde::Deserialize)]
pub struct TouchBody {
    sha256: Vec<String>,
}

/// ADR-064 — refresh the given blobs and report the ones not stored.
pub async fn touch(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<Json<serde_json::Value>, MediaError> {
    let body_sha = hex::encode(Sha256::digest(&body));
    if header_str(&headers, H_SHA256)? != body_sha {
        return Err(MediaError::BadRequest("body does not match x-sinhron-sha256".into()));
    }
    let identity = verify_headers(&headers, MEDIA_TOUCH_DOMAIN, body_sha.as_bytes())?;
    if let Err(retry) = state.rate.check_media_upload(header_str(&headers, H_IDENTITY)?) {
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["media_touch"])
            .inc();
        return Err(MediaError::RateLimited(retry.as_secs()));
    }
    let pool = state.pool.as_ref().ok_or(MediaError::NoDb)?;
    if device_of(pool, &identity).await?.is_none() {
        return Err(MediaError::Forbidden("identity not registered".into()));
    }
    let req: TouchBody =
        serde_json::from_slice(&body).map_err(|e| MediaError::BadRequest(format!("body: {e}")))?;
    if req.sha256.len() > TOUCH_MAX {
        return Err(MediaError::BadRequest(format!("at most {TOUCH_MAX} hashes")));
    }
    let shas = req
        .sha256
        .iter()
        .map(|s| parse_sha256_hex(s))
        .collect::<Result<Vec<_>, _>>()?;
    let kept: Vec<(Vec<u8>,)> = sqlx::query_as(
        "UPDATE media SET last_referenced_at = NOW() WHERE sha256 = ANY($1) RETURNING sha256",
    )
    .bind(&shas)
    .fetch_all(pool)
    .await?;
    let missing: Vec<&String> = req
        .sha256
        .iter()
        .zip(&shas)
        .filter(|(_, b)| !kept.iter().any(|(k,)| k == *b))
        .map(|(h, _)| h)
        .collect();
    Ok(Json(serde_json::json!({ "missing": missing })))
}

/// Retention: drop blobs untouched for MEDIA_RETENTION_DAYS (rows +
/// files). Returns the number of blobs removed.
pub async fn sweep_expired(pool: &sqlx::PgPool) -> anyhow::Result<u64> {
    let gone: Vec<(Vec<u8>,)> = sqlx::query_as(
        "DELETE FROM media \
         WHERE last_referenced_at < NOW() - make_interval(days => $1::int) \
         RETURNING sha256",
    )
    .bind(MEDIA_RETENTION_DAYS)
    .fetch_all(pool)
    .await?;
    let dir = media_dir();
    for (sha,) in &gone {
        let path = blob_path(&dir, &hex::encode(sha));
        if let Err(e) = tokio::fs::remove_file(&path).await {
            if e.kind() != std::io::ErrorKind::NotFound {
                warn!(error = %e, "media file delete failed");
            }
        }
    }
    Ok(gone.len() as u64)
}

/// MEDIA-3 — files under `dir` that no row knows about (a crash between
/// rename and INSERT, a failed delete in the sweep above) and leftover
/// `.part` files (process killed mid-upload) stayed forever. Only files
/// older than `min_age` go: a younger one may be an upload in progress.
/// Only `<2 hex>/` shards are walked — the Telegram cache is left alone.
pub async fn sweep_orphans(pool: &sqlx::PgPool, dir: &Path, min_age: std::time::Duration) -> anyhow::Result<u64> {
    let Ok(mut shards) = tokio::fs::read_dir(dir).await else {
        return Ok(0);
    };
    let mut removed = 0;
    while let Some(shard) = shards.next_entry().await? {
        let shard_name = shard.file_name();
        if shard_name.len() != 2 || !shard_name.as_encoded_bytes().iter().all(u8::is_ascii_hexdigit) {
            continue;
        }
        let Ok(mut files) = tokio::fs::read_dir(shard.path()).await else {
            continue;
        };
        let mut gone = Vec::new();
        let mut blobs = Vec::new();
        while let Some(file) = files.next_entry().await? {
            let name = file.file_name().to_string_lossy().into_owned();
            let age = file.metadata().await.ok().and_then(|m| m.modified().ok()).and_then(|t| t.elapsed().ok());
            if !age.is_some_and(|a| a >= min_age) {
                continue;
            }
            if name.starts_with('.') && name.ends_with(".part") {
                gone.push(file.path());
            } else if let Ok(sha) = parse_sha256_hex(&name) {
                blobs.push((sha, file.path()));
            }
        }
        if !blobs.is_empty() {
            let shas: Vec<&[u8]> = blobs.iter().map(|(sha, _)| sha.as_slice()).collect();
            let known: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT sha256 FROM media WHERE sha256 = ANY($1)")
                .bind(&shas)
                .fetch_all(pool)
                .await?;
            gone.extend(blobs.into_iter().filter(|(sha, _)| !known.iter().any(|(k,)| k == sha)).map(|(_, path)| path));
        }
        for path in gone {
            match tokio::fs::remove_file(&path).await {
                Ok(()) => removed += 1,
                Err(e) => warn!(error = %e, "orphan media file delete failed"),
            }
        }
    }
    if removed > 0 {
        info!(removed, "media files without a row removed");
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_hex_parser_rejects_traversal_and_uppercase() {
        assert!(parse_sha256_hex(&"a".repeat(64)).is_ok());
        assert!(parse_sha256_hex(&"A".repeat(64)).is_err());
        assert!(parse_sha256_hex(&format!("../{}", "a".repeat(61))).is_err());
        assert!(parse_sha256_hex(&"a".repeat(63)).is_err());
    }

    #[test]
    fn blob_path_shards_by_first_two_hex() {
        let p = blob_path(Path::new("/m"), &format!("ab{}", "0".repeat(62)));
        assert_eq!(p, PathBuf::from(format!("/m/ab/ab{}", "0".repeat(62))));
    }

    // ── End-to-end through the real router + Postgres ────────────────

    use axum::http::Request;
    use ed25519_dalek::{Signer, SigningKey};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    fn proof_headers(sk: &SigningKey, domain: &[u8], body: &[u8]) -> Vec<(&'static str, String)> {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut msg = domain.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&Sha256::digest(body));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        vec![
            (H_IDENTITY, hex::encode(sk.verifying_key().as_bytes())),
            (H_TS, ts.to_string()),
            (H_PROOF, hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes())),
        ]
    }

    /// SINHRON_MEDIA_* are process-wide: tests that upload take turns.
    static ENV: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    async fn register(pool: &sqlx::PgPool, sk: &SigningKey, device: u8) {
        let user_pk = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(user_pk)
            .bind(&sk.verifying_key().as_bytes()[..])
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
            .bind(&[device; 32][..])
            .bind(user_pk)
            .bind(&b"cred"[..])
            .execute(pool)
            .await
            .unwrap();
    }

    fn temp_media_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("sinhron-media-test-{}", uuid::Uuid::new_v4()));
        std::env::set_var("SINHRON_MEDIA_DIR", &dir);
        dir
    }

    fn state(pool: sqlx::PgPool) -> AppState {
        AppState {
            pool: Some(pool),
            sessions: crate::session::SessionRegistry::new(),
            push: std::sync::Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(crate::rate_limit::RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    async fn upload_req(
        pool: &sqlx::PgPool,
        sk: &SigningKey,
        claimed_sha_hex: &str,
        body: Vec<u8>,
        domain: &[u8],
    ) -> StatusCode {
        let mut req = Request::builder().method("POST").uri("/v1/media");
        for (k, v) in proof_headers(sk, domain, claimed_sha_hex.as_bytes()) {
            req = req.header(k, v);
        }
        let req = req
            .header(H_SHA256, claimed_sha_hex)
            .header(header::CONTENT_LENGTH, body.len())
            .body(Body::from(body))
            .unwrap();
        crate::build_app(state(pool.clone())).oneshot(req).await.unwrap().status()
    }

    async fn download_req(pool: &sqlx::PgPool, sk: &SigningKey, sha_hex: &str) -> (StatusCode, Vec<u8>) {
        let mut req = Request::builder().uri(format!("/v1/media/{sha_hex}"));
        for (k, v) in proof_headers(sk, MEDIA_GET_DOMAIN, sha_hex.as_bytes()) {
            req = req.header(k, v);
        }
        let res = crate::build_app(state(pool.clone()))
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = res.status();
        (status, res.into_body().collect().await.unwrap().to_bytes().to_vec())
    }

    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn upload_download_roundtrip_and_rejections(pool: sqlx::PgPool) {
        let _env = ENV.lock().await;
        let dir = temp_media_dir();
        std::env::set_var("SINHRON_MEDIA_MAX_BYTES", "1024");

        let alice = SigningKey::from_bytes(&[7u8; 32]);
        let stranger = SigningKey::from_bytes(&[9u8; 32]);
        let user_pk = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(user_pk)
            .bind(&alice.verifying_key().as_bytes()[..])
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
            .bind(&[1u8; 32][..])
            .bind(user_pk)
            .bind(&b"cred"[..])
            .execute(&pool)
            .await
            .unwrap();

        let blob: Vec<u8> = (0..500u32).map(|i| (i % 251) as u8).collect();
        let sha_hex = hex::encode(Sha256::digest(&blob));

        // Store, then dedupe.
        assert_eq!(upload_req(&pool, &alice, &sha_hex, blob.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::CREATED);
        assert!(blob_path(&dir, &sha_hex).exists());
        assert_eq!(upload_req(&pool, &alice, &sha_hex, blob.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::OK);

        // Fetch back byte-for-byte.
        let (status, got) = download_req(&pool, &alice, &sha_hex).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(got, blob);

        // Unregistered identity: no upload, no download.
        assert_eq!(download_req(&pool, &stranger, &sha_hex).await.0, StatusCode::FORBIDDEN);
        let other = vec![42u8; 10];
        let other_sha = hex::encode(Sha256::digest(&other));
        assert_eq!(upload_req(&pool, &stranger, &other_sha, other.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::FORBIDDEN);

        // Proof minted for another domain is rejected.
        assert_eq!(upload_req(&pool, &alice, &other_sha, other.clone(), MEDIA_GET_DOMAIN).await, StatusCode::UNAUTHORIZED);

        // Body that doesn't match the claimed hash: rejected, nothing left on disk.
        assert_eq!(upload_req(&pool, &alice, &other_sha, vec![1u8; 10], MEDIA_UPLOAD_DOMAIN).await, StatusCode::BAD_REQUEST);
        assert!(!blob_path(&dir, &other_sha).exists());
        let shard = blob_path(&dir, &other_sha).parent().unwrap().to_path_buf();
        let leftovers = std::fs::read_dir(&shard).map(|d| d.count()).unwrap_or(0);
        assert_eq!(leftovers, 0, "temp .part file must be cleaned up");

        // Over the size cap.
        let big = vec![3u8; 2000];
        let big_sha = hex::encode(Sha256::digest(&big));
        assert_eq!(upload_req(&pool, &alice, &big_sha, big, MEDIA_UPLOAD_DOMAIN).await, StatusCode::PAYLOAD_TOO_LARGE);

        // Unknown blob.
        assert_eq!(download_req(&pool, &alice, &"0".repeat(64)).await.0, StatusCode::NOT_FOUND);

        // Retention: an old blob loses its row and its file.
        sqlx::query("UPDATE media SET last_referenced_at = NOW() - INTERVAL '91 days'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(sweep_expired(&pool).await.unwrap(), 1);
        assert!(!blob_path(&dir, &sha_hex).exists());
        assert_eq!(download_req(&pool, &alice, &sha_hex).await.0, StatusCode::NOT_FOUND);

        // server-http:6 — 4 GiB stored by this person today: 429; the
        // quota counts the last 24 hours only.
        sqlx::query("INSERT INTO media (sha256, size_bytes, uploaded_by_device) VALUES ($1, $2, $3)")
            .bind(vec![0xEEu8; 32])
            .bind(DAILY_BYTES_PER_PERSON as i64)
            .bind(&[1u8; 32][..])
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(upload_req(&pool, &alice, &other_sha, other.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::TOO_MANY_REQUESTS);
        sqlx::query("UPDATE media SET uploaded_at = NOW() - interval '2 days'").execute(&pool).await.unwrap();
        assert_eq!(upload_req(&pool, &alice, &other_sha, other, MEDIA_UPLOAD_DOMAIN).await, StatusCode::CREATED);

        std::env::remove_var("SINHRON_MEDIA_MAX_BYTES");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// MEDIA-3 — the account is deleted while its upload is still coming in:
    /// the blob gets a row (nobody's) instead of a 500 and a file no sweep finds.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn an_upload_finishing_after_account_delete_still_gets_a_row(pool: sqlx::PgPool) {
        let _env = ENV.lock().await;
        let dir = temp_media_dir();
        let alice = SigningKey::from_bytes(&[7u8; 32]);
        register(&pool, &alice, 1).await;
        let blob = vec![0x33u8; 500];
        let sha = hex::encode(Sha256::digest(&blob));
        let mut req = Request::builder().method("POST").uri("/v1/media").header(H_SHA256, &sha);
        for (k, v) in proof_headers(&alice, MEDIA_UPLOAD_DOMAIN, sha.as_bytes()) {
            req = req.header(k, v);
        }
        // No clocks: the body says when the handler began to read it (the
        // signature is checked by then) and waits until the account is gone.
        let (reading_tx, reading_rx) = tokio::sync::oneshot::channel::<()>();
        let (gone_tx, gone_rx) = tokio::sync::oneshot::channel::<()>();
        let slow = futures_util::stream::once(async move {
            let _ = reading_tx.send(());
            let _ = gone_rx.await;
            Ok::<_, std::io::Error>(blob)
        });
        let app = crate::build_app(state(pool.clone()));
        let up = tokio::spawn(app.oneshot(req.body(Body::from_stream(slow)).unwrap()));
        reading_rx.await.unwrap();
        sqlx::query("DELETE FROM users").execute(&pool).await.unwrap();
        gone_tx.send(()).unwrap();
        assert_eq!(up.await.unwrap().unwrap().status(), StatusCode::CREATED);
        assert!(blob_path(&dir, &sha).exists());
        let (rows,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM media WHERE uploaded_by_device IS NULL")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(rows, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// MEDIA-3 — old files without a row and old `.part` files go; young
    /// ones (an upload in progress), known blobs and other folders stay.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn orphan_files_and_stale_parts_are_swept(pool: sqlx::PgPool) {
        let dir = std::env::temp_dir().join(format!("sinhron-media-test-{}", uuid::Uuid::new_v4()));
        let two_days_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(48 * 3600);
        let put = |rel: String, old: bool| {
            let path = dir.join(rel);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let f = std::fs::File::create(&path).unwrap();
            if old {
                f.set_modified(two_days_ago).unwrap();
            }
            path
        };
        let (known, orphan, young) = ("ab".repeat(32), format!("ab{}", "1".repeat(62)), format!("ab{}", "2".repeat(62)));
        sqlx::query("INSERT INTO media (sha256, size_bytes) VALUES ($1, 1)")
            .bind(hex::decode(&known).unwrap())
            .execute(&pool)
            .await
            .unwrap();
        let known = put(format!("ab/{known}"), true);
        let orphan = put(format!("ab/{orphan}"), true);
        let young = put(format!("ab/{young}"), false);
        let old_part = put(format!("cd/.{}.x.part", "cd".repeat(32)), true);
        let young_part = put(format!("cd/.{}.y.part", "cd".repeat(32)), false);
        let other = put("telegram-cache/pack/file".to_string(), true);
        let stray = put("ab/notes.txt".to_string(), true);

        assert_eq!(sweep_orphans(&pool, &dir, ORPHAN_MIN_AGE).await.unwrap(), 2);
        assert!(!orphan.exists() && !old_part.exists());
        for kept in [known, young, young_part, other, stray] {
            assert!(kept.exists(), "{kept:?}");
        }
        // No media folder yet (fresh server): nothing to do.
        assert_eq!(sweep_orphans(&pool, &dir.join("nope"), ORPHAN_MIN_AGE).await.unwrap(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// MEDIA-1 — uploads started together are counted against the daily
    /// quota while they are still coming in: with 1 byte of quota left,
    /// one of five passes (all five did).
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn parallel_uploads_share_the_daily_quota(pool: sqlx::PgPool) {
        let _env = ENV.lock().await;
        let dir = temp_media_dir();
        let alice = SigningKey::from_bytes(&[7u8; 32]);
        register(&pool, &alice, 1).await;
        sqlx::query("INSERT INTO media (sha256, size_bytes, uploaded_by_device) VALUES ($1, $2, $3)")
            .bind(vec![0xEEu8; 32])
            .bind(DAILY_BYTES_PER_PERSON as i64 - 1)
            .bind(&[1u8; 32][..])
            .execute(&pool)
            .await
            .unwrap();
        let mut uploads = Vec::new();
        for i in 0..5u8 {
            let blob = vec![i; 300];
            let sha = hex::encode(Sha256::digest(&blob));
            let mut req = Request::builder().method("POST").uri("/v1/media").header(H_SHA256, &sha);
            for (k, v) in proof_headers(&alice, MEDIA_UPLOAD_DOMAIN, sha.as_bytes()) {
                req = req.header(k, v);
            }
            let slow = futures_util::stream::once(async move {
                tokio::time::sleep(std::time::Duration::from_millis(700)).await;
                Ok::<_, std::io::Error>(blob)
            });
            let app = crate::build_app(state(pool.clone()));
            uploads.push(tokio::spawn(app.oneshot(req.body(Body::from_stream(slow)).unwrap())));
        }
        let mut statuses = Vec::new();
        for up in uploads {
            statuses.push(up.await.unwrap().unwrap().status());
        }
        statuses.sort();
        assert_eq!(statuses, [vec![StatusCode::CREATED], vec![StatusCode::TOO_MANY_REQUESTS; 4]].concat());
        assert!(IN_FLIGHT.lock().unwrap().is_empty(), "every reservation is given back");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// MEDIA-5 — a body that goes silent is refused and reports an error
    /// (the caller removes the `.part`), instead of waiting forever.
    #[tokio::test]
    async fn a_stalled_body_is_dropped() {
        let path = std::env::temp_dir().join(format!("sinhron-media-stall-{}.part", uuid::Uuid::new_v4()));
        let silent = futures_util::stream::once(async { Ok::<_, std::io::Error>(vec![1u8; 10]) })
            .chain(futures_util::stream::pending());
        let stall = std::time::Duration::from_millis(100);
        let got = spool(Body::from_stream(silent), &path, 1024, stall).await;
        assert!(matches!(got, Err(MediaError::BadRequest(ref m)) if m == "body stalled"), "{got:?}");
        let whole = futures_util::stream::once(async { Ok::<_, std::io::Error>(vec![1u8; 10]) });
        assert_eq!(spool(Body::from_stream(whole), &path, 1024, stall).await.unwrap().0, 10);
        let _ = std::fs::remove_file(&path);
    }

    /// MEDIA-4 — a row whose file is gone: uploading the same blob again
    /// puts the file back (it answered "already stored", download 404).
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn a_row_without_its_file_is_repaired_by_uploading_again(pool: sqlx::PgPool) {
        let _env = ENV.lock().await;
        let dir = temp_media_dir();
        let alice = SigningKey::from_bytes(&[7u8; 32]);
        register(&pool, &alice, 1).await;
        let blob = vec![0x44u8; 300];
        let sha = hex::encode(Sha256::digest(&blob));
        assert_eq!(upload_req(&pool, &alice, &sha, blob.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::CREATED);
        std::fs::remove_file(blob_path(&dir, &sha)).unwrap();
        assert_eq!(upload_req(&pool, &alice, &sha, blob.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::CREATED);
        assert_eq!(download_req(&pool, &alice, &sha).await, (StatusCode::OK, blob.clone()));
        assert_eq!(upload_req(&pool, &alice, &sha, blob, MEDIA_UPLOAD_DOMAIN).await, StatusCode::OK, "still deduped");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// MEDIA-10 — all media together has a cap; at the cap an upload gets
    /// the same 429 as the daily quota, and room returns when blobs go.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn the_server_wide_media_cap_refuses_uploads(pool: sqlx::PgPool) {
        let _env = ENV.lock().await;
        let dir = temp_media_dir();
        let alice = SigningKey::from_bytes(&[7u8; 32]);
        register(&pool, &alice, 1).await;
        // Someone else's blobs (their account is gone) fill the store.
        sqlx::query("INSERT INTO media (sha256, size_bytes) VALUES ($1, $2)")
            .bind(vec![0xEEu8; 32])
            .bind(DEFAULT_TOTAL_BYTES as i64 - 5)
            .execute(&pool)
            .await
            .unwrap();
        let blob = vec![42u8; 10];
        let sha = hex::encode(Sha256::digest(&blob));
        assert_eq!(upload_req(&pool, &alice, &sha, blob.clone(), MEDIA_UPLOAD_DOMAIN).await, StatusCode::TOO_MANY_REQUESTS);
        assert!(!blob_path(&dir, &sha).exists());
        // Exactly up to the cap is fine.
        let small = vec![42u8; 5];
        let small_sha = hex::encode(Sha256::digest(&small));
        assert_eq!(upload_req(&pool, &alice, &small_sha, small, MEDIA_UPLOAD_DOMAIN).await, StatusCode::CREATED);
        sqlx::query("DELETE FROM media WHERE sha256 = $1").bind(vec![0xEEu8; 32]).execute(&pool).await.unwrap();
        assert_eq!(upload_req(&pool, &alice, &sha, blob, MEDIA_UPLOAD_DOMAIN).await, StatusCode::CREATED);
        let _ = std::fs::remove_dir_all(&dir);
    }

    async fn touch_req(pool: &sqlx::PgPool, sk: &SigningKey, shas: &[String], domain: &[u8]) -> (StatusCode, serde_json::Value) {
        let body = serde_json::to_vec(&serde_json::json!({ "sha256": shas })).unwrap();
        let body_sha = hex::encode(Sha256::digest(&body));
        let mut req = Request::builder().method("POST").uri("/v1/media/touch");
        for (k, v) in proof_headers(sk, domain, body_sha.as_bytes()) {
            req = req.header(k, v);
        }
        let res = crate::build_app(state(pool.clone()))
            .oneshot(req.header(H_SHA256, body_sha).body(Body::from(body)).unwrap())
            .await
            .unwrap();
        let status = res.status();
        let bytes = res.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
    }

    /// ADR-064 — touch keeps stored blobs another 90 days and names the
    /// ones the server doesn't have; strangers and bad input are refused.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn touch_keeps_blobs_and_reports_missing(pool: sqlx::PgPool) {
        let alice = SigningKey::from_bytes(&[7u8; 32]);
        let stranger = SigningKey::from_bytes(&[9u8; 32]);
        let user_pk = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(user_pk)
            .bind(&alice.verifying_key().as_bytes()[..])
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
            .bind(&[1u8; 32][..])
            .bind(user_pk)
            .bind(&b"cred"[..])
            .execute(&pool)
            .await
            .unwrap();
        let have = [5u8; 32];
        sqlx::query(
            "INSERT INTO media (sha256, size_bytes, uploaded_by_device, last_referenced_at) \
             VALUES ($1, 10, $2, NOW() - INTERVAL '80 days')",
        )
        .bind(&have[..])
        .bind(&[1u8; 32][..])
        .execute(&pool)
        .await
        .unwrap();
        let have_hex = hex::encode(have);
        let gone_hex = "ab".repeat(32);

        let (status, body) = touch_req(&pool, &alice, &[have_hex.clone(), gone_hex.clone()], MEDIA_TOUCH_DOMAIN).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["missing"], serde_json::json!([gone_hex]));
        // Refreshed: the sweep no longer takes it.
        sqlx::query("UPDATE media SET last_referenced_at = last_referenced_at - INTERVAL '10 days'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(sweep_expired(&pool).await.unwrap(), 0);

        assert_eq!(touch_req(&pool, &stranger, &[have_hex.clone()], MEDIA_TOUCH_DOMAIN).await.0, StatusCode::FORBIDDEN);
        assert_eq!(touch_req(&pool, &alice, &[have_hex.clone()], MEDIA_GET_DOMAIN).await.0, StatusCode::UNAUTHORIZED);
        assert_eq!(touch_req(&pool, &alice, &["../x".to_string()], MEDIA_TOUCH_DOMAIN).await.0, StatusCode::BAD_REQUEST);
        let too_many = vec![have_hex; TOUCH_MAX + 1];
        assert_eq!(touch_req(&pool, &alice, &too_many, MEDIA_TOUCH_DOMAIN).await.0, StatusCode::BAD_REQUEST);
    }
}
