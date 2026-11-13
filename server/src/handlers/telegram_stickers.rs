// Telegram sticker packs by link — ADR-062 (owner, 2026-10-18: "download a
// whole sticker pack by its Telegram link").
//
// A person pastes https://t.me/addstickers/<name>; the phone asks this
// server, which asks the Telegram Bot API with the operator's bot token
// (getStickerSet + getFile — the documented way; nothing is scraped), keeps
// the answer and the files for a day, and hands them over. The phone turns
// them into an ordinary own pack (encrypted on the phone, ADR-049).
//
//   POST /v1/stickers/telegram          {"name": "Ziongo777"}
//     Headers: x-sinhron-identity / x-sinhron-ts / x-sinhron-proof
//              (TG_STICKERS_DOMAIN, body = the name as sent)
//     → 200 {"name","title","kind","stickers":[{"emoji","format","width","height","thumb"}]}
//   GET /v1/stickers/telegram/{name}/{index}        the sticker file
//   GET /v1/stickers/telegram/{name}/{index}/thumb  Telegram's small still
//     Headers: same, TG_STICKER_FILE_DOMAIN, body = the path after
//              `/v1/stickers/telegram/` ("Ziongo777/3" or "Ziongo777/3/thumb")
//     → 200 application/octet-stream
//
// Errors are {"error": code} the app turns into plain words:
//   404 not_found       no pack with that name
//   503 not_configured  no bot token on this server (or Telegram refused it)
//   502 unreachable     Telegram didn't answer (blocked network, outage)
//   429 rate_limited    ours (per account) or Telegram's; Retry-After
//
// Privacy: only registered accounts may ask (the per-account limit needs
// one), but nothing links an account to a pack — the cache is keyed by the
// pack name only and the logs carry neither. Telegram sees our bot asking
// for packs, never who asked. The bot token never reaches a log: reqwest
// errors carry the request URL, so they are logged `without_url()`.
//
// Reachability (checked 2026-10-18 from the Russian VPS): api.telegram.org
// times out over IPv4 but answers over IPv6, so the client below tries IPv6
// addresses first and the container sits on the `egress6` network too
// (docker-compose.yml). SINHRON_TELEGRAM_API_URL can point at another Bot
// API endpoint (a self-hosted telegram-bot-api server abroad) when neither
// works.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use axum::{
    extract::{Path as UrlPath, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
    Extension,
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::{info, warn};

use super::proof::{self, TG_STICKERS_DOMAIN, TG_STICKER_FILE_DOMAIN};
use crate::rate_limit::{KeyedLimiter, RateConfig};
use crate::AppState;

/// How long a pack's list and files are kept (and re-used for everyone).
pub const CACHE_TTL: Duration = Duration::from_secs(24 * 3600);
/// A sticker file bigger than this isn't a sticker (Telegram's own limits
/// are 64 / 256 / 512 KB; the app takes up to 1 MB).
pub const MAX_FILE_BYTES: usize = 1024 * 1024;
/// The most stickers taken from one pack (the app's pack limit).
pub const MAX_STICKERS: usize = 200;
/// Requests to Telegram at once, for all accounts together.
const UPSTREAM_PARALLEL: usize = 4;

const H_IDENTITY: &str = "x-sinhron-identity";
const H_TS: &str = "x-sinhron-ts";
const H_PROOF: &str = "x-sinhron-proof";

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TgError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("not registered")]
    Forbidden,
    #[error("not_found")]
    NotFound,
    #[error("not_configured")]
    NotConfigured,
    #[error("unreachable")]
    Unreachable,
    #[error("rate limited; retry after {0}s")]
    RateLimited(u64),
    #[error("database not configured")]
    NoDb,
    #[error("internal: {0}")]
    Internal(String),
}

impl TgError {
    /// The machine-readable code the app maps to words.
    fn code(&self) -> &'static str {
        match self {
            TgError::BadRequest(_) => "bad_request",
            TgError::Unauthorized(_) => "unauthorized",
            TgError::Forbidden => "forbidden",
            TgError::NotFound => "not_found",
            TgError::NotConfigured => "not_configured",
            TgError::Unreachable => "unreachable",
            TgError::RateLimited(_) => "rate_limited",
            TgError::NoDb => "no_db",
            TgError::Internal(_) => "internal",
        }
    }
}

impl IntoResponse for TgError {
    fn into_response(self) -> Response {
        let status = match &self {
            TgError::BadRequest(_) => StatusCode::BAD_REQUEST,
            TgError::Unauthorized(_) => StatusCode::UNAUTHORIZED,
            TgError::Forbidden => StatusCode::FORBIDDEN,
            TgError::NotFound => StatusCode::NOT_FOUND,
            TgError::NotConfigured | TgError::NoDb => StatusCode::SERVICE_UNAVAILABLE,
            TgError::Unreachable => StatusCode::BAD_GATEWAY,
            TgError::RateLimited(_) => StatusCode::TOO_MANY_REQUESTS,
            TgError::Internal(e) => {
                warn!(error = %e, "telegram stickers internal error");
                StatusCode::INTERNAL_SERVER_ERROR
            }
        };
        let mut body = serde_json::json!({ "error": self.code() });
        if let TgError::RateLimited(secs) = &self {
            body["retry_after_secs"] = (*secs).into();
        }
        let mut resp = (status, Json(body)).into_response();
        if let TgError::RateLimited(secs) = &self {
            resp.headers_mut().insert(header::RETRY_AFTER, secs.to_string().parse().expect("ascii digits parse"));
        }
        resp
    }
}

impl From<std::io::Error> for TgError {
    fn from(e: std::io::Error) -> Self {
        TgError::Internal(e.to_string())
    }
}

impl From<sqlx::Error> for TgError {
    fn from(e: sqlx::Error) -> Self {
        TgError::Internal(e.to_string())
    }
}

/// A Telegram set name: letters, digits, underscores, 1–64. Also what keeps
/// cache paths and Bot API URLs safe.
pub fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// A bot token as @BotFather gives it: `<digits>:<letters, digits, _ ->`.
fn valid_token(t: &str) -> bool {
    match t.split_once(':') {
        Some((id, secret)) => {
            !id.is_empty()
                && id.bytes().all(|b| b.is_ascii_digit())
                && secret.len() >= 20
                && secret.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }
        None => false,
    }
}

/// One sticker as the cache keeps it (Telegram's file ids stay here).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CachedSticker {
    pub file_id: String,
    pub file_unique_id: String,
    #[serde(default)]
    pub thumb_file_id: Option<String>,
    #[serde(default)]
    pub thumb_unique_id: Option<String>,
    pub emoji: String,
    /// "tgs" | "webm" | "webp"
    pub format: String,
    pub width: u32,
    pub height: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CachedPack {
    pub name: String,
    pub title: String,
    /// "regular" | "mask" | "custom_emoji"
    pub kind: String,
    pub stickers: Vec<CachedSticker>,
}

impl CachedPack {
    /// What the phone gets: no Telegram file ids.
    fn public(&self) -> serde_json::Value {
        serde_json::json!({
            "name": self.name,
            "title": self.title,
            "kind": self.kind,
            "stickers": self.stickers.iter().map(|s| serde_json::json!({
                "emoji": s.emoji,
                "format": s.format,
                "width": s.width,
                "height": s.height,
                "thumb": s.thumb_file_id.is_some(),
            })).collect::<Vec<_>>(),
        })
    }
}

// ── Bot API shapes (only the fields used) ──

#[derive(Deserialize)]
struct BotReply<T> {
    ok: bool,
    result: Option<T>,
    #[serde(default)]
    error_code: Option<u16>,
    #[serde(default)]
    description: Option<String>,
    #[serde(default)]
    parameters: Option<BotParams>,
}

#[derive(Deserialize)]
struct BotParams {
    #[serde(default)]
    retry_after: Option<u64>,
}

#[derive(Deserialize)]
struct BotSet {
    name: String,
    title: String,
    #[serde(default)]
    sticker_type: Option<String>,
    stickers: Vec<BotSticker>,
}

#[derive(Deserialize)]
struct BotPhoto {
    file_id: String,
    file_unique_id: String,
}

#[derive(Deserialize)]
struct BotSticker {
    file_id: String,
    file_unique_id: String,
    #[serde(default)]
    width: u32,
    #[serde(default)]
    height: u32,
    #[serde(default)]
    is_animated: bool,
    #[serde(default)]
    is_video: bool,
    #[serde(default)]
    emoji: Option<String>,
    #[serde(default)]
    thumbnail: Option<BotPhoto>,
}

#[derive(Deserialize)]
struct BotFile {
    #[serde(default)]
    file_path: Option<String>,
}

fn pack_of(set: BotSet) -> CachedPack {
    CachedPack {
        name: set.name,
        title: set.title.chars().filter(|c| !c.is_control()).take(64).collect(),
        kind: set.sticker_type.unwrap_or_else(|| "regular".into()),
        stickers: set
            .stickers
            .into_iter()
            .take(MAX_STICKERS)
            .map(|s| CachedSticker {
                format: if s.is_animated { "tgs" } else if s.is_video { "webm" } else { "webp" }.into(),
                emoji: s.emoji.unwrap_or_default().chars().take(8).collect(),
                width: s.width,
                height: s.height,
                thumb_file_id: s.thumbnail.as_ref().map(|t| t.file_id.clone()),
                thumb_unique_id: s.thumbnail.map(|t| t.file_unique_id),
                file_id: s.file_id,
                file_unique_id: s.file_unique_id,
            })
            .collect(),
    }
}

/// Telegram file ids are base64url; anything else never reaches a path.
fn safe_file_name(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Resolves IPv6 addresses first: from the Russian VPS Telegram answers
/// only over IPv6 (IPv4 times out). Without IPv6 the IPv6 attempts fail at
/// once and the IPv4 ones follow.
struct Ipv6First;

impl reqwest::dns::Resolve for Ipv6First {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let host = name.as_str().to_string();
        Box::pin(async move {
            let mut addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0)).await?.collect();
            addrs.sort_by_key(|a| !a.is_ipv6());
            Ok(Box::new(addrs.into_iter()) as reqwest::dns::Addrs)
        })
    }
}

/// The Telegram side: the Bot API client, the day cache on disk, and the
/// per-account limits.
pub struct TelegramStickers {
    token: Option<String>,
    api: String,
    http: reqwest::Client,
    cache: PathBuf,
    packs_limit: KeyedLimiter,
    files_limit: KeyedLimiter,
    upstream: tokio::sync::Semaphore,
    upstream_wait: Duration,
}

impl TelegramStickers {
    pub fn new(token: Option<String>, api: String, cache: PathBuf) -> Self {
        let token = token.map(|t| t.trim().to_string()).filter(|t| {
            let ok = valid_token(t);
            if !ok && !t.is_empty() {
                warn!("telegram bot token doesn't look like one from @BotFather — Telegram packs stay off");
            }
            ok
        });
        let http = reqwest::Client::builder()
            .dns_resolver(Arc::new(Ipv6First))
            .connect_timeout(Duration::from_secs(8))
            .timeout(Duration::from_secs(30))
            // MEDIA-6 — the request URL carries the bot token: never follow
            // a redirect elsewhere, never send the URL on as a Referer.
            .redirect(reqwest::redirect::Policy::none())
            .referer(false)
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self {
            token,
            api: api.trim_end_matches('/').to_string(),
            http,
            cache,
            // A pack = 1 list + up to 400 files (stickers + stills).
            packs_limit: KeyedLimiter::from_env("SINHRON_RATE_TG_PACKS", RateConfig::per_window(30, 3_600)),
            files_limit: KeyedLimiter::from_env("SINHRON_RATE_TG_FILES", RateConfig::per_window(3_000, 3_600)),
            upstream: tokio::sync::Semaphore::new(UPSTREAM_PARALLEL),
            upstream_wait: Duration::from_secs(20),
        }
    }

    /// From env: the token from `SINHRON_TELEGRAM_BOT_TOKEN_FILE` (default
    /// /etc/sinhron/telegram/bot-token, outside git like the APNs key) or
    /// `SINHRON_TELEGRAM_BOT_TOKEN`; `SINHRON_TELEGRAM_API_URL`;
    /// `SINHRON_TELEGRAM_CACHE_DIR` (default `<media dir>/telegram-cache`).
    pub fn from_env() -> Arc<Self> {
        let env = |k: &str| std::env::var(k).ok().filter(|s| !s.trim().is_empty());
        let file = env("SINHRON_TELEGRAM_BOT_TOKEN_FILE").unwrap_or_else(|| "/etc/sinhron/telegram/bot-token".into());
        let token = std::fs::read_to_string(&file).ok().or_else(|| env("SINHRON_TELEGRAM_BOT_TOKEN"));
        let api = env("SINHRON_TELEGRAM_API_URL").unwrap_or_else(|| "https://api.telegram.org".into());
        let cache = env("SINHRON_TELEGRAM_CACHE_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| super::media::media_dir().join("telegram-cache"));
        let me = Self::new(token, api, cache);
        info!(configured = me.configured(), "telegram sticker packs");
        Arc::new(me)
    }

    pub fn configured(&self) -> bool {
        self.token.is_some()
    }

    fn pack_dir(&self, name: &str) -> PathBuf {
        self.cache.join(name.to_ascii_lowercase())
    }

    /// MEDIA-7 — a place in the queue to Telegram, waited for no longer
    /// than `upstream_wait`: one account's flood (or a dead Telegram) kept
    /// everyone else's requests hanging for hours.
    async fn upstream_slot(&self) -> Result<tokio::sync::SemaphorePermit<'_>, TgError> {
        tokio::time::timeout(self.upstream_wait, self.upstream.acquire())
            .await
            .map_err(|_| TgError::RateLimited(30))?
            .map_err(|e| TgError::Internal(e.to_string()))
    }

    async fn call<T: serde::de::DeserializeOwned>(&self, method: &str, query: &[(&str, &str)]) -> Result<T, TgError> {
        let token = self.token.as_deref().ok_or(TgError::NotConfigured)?;
        let _slot = self.upstream_slot().await?;
        let mut resp = self
            .http
            .get(format!("{}/bot{token}/{method}", self.api))
            .query(query)
            .send()
            .await
            .map_err(|e| {
                warn!(error = %e.without_url(), method, "telegram bot api unreachable");
                TgError::Unreachable
            })?;
        let status = resp.status();
        // MEDIA-8 — the reply was read whole, whatever its size; a real one
        // (a full pack's list) is far under the cap for one file.
        let mut raw = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(|e| {
            warn!(error = %e.without_url(), %status, method, "telegram bot api: reply cut off");
            TgError::Unreachable
        })? {
            raw.extend_from_slice(&chunk);
            if raw.len() > MAX_FILE_BYTES {
                warn!(%status, method, "telegram bot api: reply too large");
                return Err(TgError::Unreachable);
            }
        }
        let reply: BotReply<T> = serde_json::from_slice(&raw).map_err(|e| {
            warn!(error = %e, %status, method, "telegram bot api: not a bot api reply");
            TgError::Unreachable
        })?;
        if reply.ok {
            return reply.result.ok_or_else(|| TgError::Internal("ok without result".into()));
        }
        let desc = reply.description.unwrap_or_default();
        Err(match reply.error_code.unwrap_or(status.as_u16()) {
            400 if desc.contains("STICKERSET") || desc.contains("not found") => TgError::NotFound,
            400 if desc.contains("file") => TgError::NotFound,
            401 | 404 => {
                warn!(method, "telegram refused the bot token — check /etc/sinhron/telegram/bot-token");
                TgError::NotConfigured
            }
            429 => TgError::RateLimited(reply.parameters.and_then(|p| p.retry_after).unwrap_or(30)),
            code => {
                warn!(code, %desc, method, "telegram bot api error");
                TgError::Unreachable
            }
        })
    }

    async fn download(&self, file_id: &str) -> Result<Vec<u8>, TgError> {
        let f: BotFile = self.call("getFile", &[("file_id", file_id)]).await?;
        let path = f.file_path.ok_or(TgError::NotFound)?;
        if path.contains("..") || path.starts_with('/') {
            return Err(TgError::Internal("odd file path from telegram".into()));
        }
        let token = self.token.as_deref().ok_or(TgError::NotConfigured)?;
        let _slot = self.upstream_slot().await?;
        let mut resp = self
            .http
            .get(format!("{}/file/bot{token}/{path}", self.api))
            .send()
            .await
            .map_err(|e| {
                warn!(error = %e.without_url(), "telegram file download failed");
                TgError::Unreachable
            })?;
        if !resp.status().is_success() {
            warn!(status = %resp.status(), "telegram file download refused");
            return Err(if resp.status() == StatusCode::NOT_FOUND { TgError::NotFound } else { TgError::Unreachable });
        }
        let mut out = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(|e| {
            warn!(error = %e.without_url(), "telegram file download cut off");
            TgError::Unreachable
        })? {
            out.extend_from_slice(&chunk);
            if out.len() > MAX_FILE_BYTES {
                return Err(TgError::NotFound);
            }
        }
        Ok(out)
    }

    /// The pack's list: from the day cache, else from Telegram.
    pub async fn pack(&self, name: &str) -> Result<CachedPack, TgError> {
        if !valid_name(name) {
            return Err(TgError::BadRequest("not a telegram pack name".into()));
        }
        if !self.configured() {
            return Err(TgError::NotConfigured);
        }
        let dir = self.pack_dir(name);
        let list = dir.join("pack.json");
        if let Some(bytes) = read_fresh(&list).await {
            if let Ok(p) = serde_json::from_slice::<CachedPack>(&bytes) {
                return Ok(p);
            }
        }
        let set: BotSet = self.call("getStickerSet", &[("name", name)]).await?;
        let pack = pack_of(set);
        if pack.stickers.is_empty() {
            return Err(TgError::NotFound);
        }
        tokio::fs::create_dir_all(&dir).await?;
        write_atomic(&list, &serde_json::to_vec(&pack).map_err(|e| TgError::Internal(e.to_string()))?).await?;
        Ok(pack)
    }

    /// One sticker file (or its still, [thumb]) — cached for a day.
    pub async fn file(&self, name: &str, index: usize, thumb: bool) -> Result<Vec<u8>, TgError> {
        let pack = self.pack(name).await?;
        let s = pack.stickers.get(index).ok_or(TgError::NotFound)?;
        let (id, unique) = if thumb {
            match (&s.thumb_file_id, &s.thumb_unique_id) {
                (Some(id), Some(u)) => (id.as_str(), u.as_str()),
                _ => return Err(TgError::NotFound),
            }
        } else {
            (s.file_id.as_str(), s.file_unique_id.as_str())
        };
        if !safe_file_name(unique) {
            return Err(TgError::Internal("odd file id from telegram".into()));
        }
        let path = self.pack_dir(name).join(unique);
        if let Some(bytes) = read_fresh(&path).await {
            return Ok(bytes);
        }
        let bytes = self.download(id).await?;
        write_atomic(&path, &bytes).await?;
        Ok(bytes)
    }

    /// Delete cached packs older than a day. Returns how many went.
    pub async fn sweep(&self) -> usize {
        let mut gone = 0;
        let Ok(mut dirs) = tokio::fs::read_dir(&self.cache).await else { return 0 };
        while let Ok(Some(d)) = dirs.next_entry().await {
            let list = d.path().join("pack.json");
            if read_fresh(&list).await.is_none() && tokio::fs::remove_dir_all(d.path()).await.is_ok() {
                gone += 1;
            }
        }
        gone
    }

    /// Hourly [sweep] in the background.
    pub fn spawn_sweeper(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let me = Arc::clone(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(3600));
            loop {
                tick.tick().await;
                let n = me.sweep().await;
                if n > 0 {
                    info!(packs = n, "telegram sticker cache swept");
                }
            }
        })
    }
}

/// The file's bytes if it was written less than [CACHE_TTL] ago.
async fn read_fresh(path: &Path) -> Option<Vec<u8>> {
    let meta = tokio::fs::metadata(path).await.ok()?;
    let age = SystemTime::now().duration_since(meta.modified().ok()?).unwrap_or_default();
    if age > CACHE_TTL {
        return None;
    }
    tokio::fs::read(path).await.ok()
}

async fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), TgError> {
    let tmp = path.with_extension(format!("{}.part", uuid::Uuid::new_v4()));
    tokio::fs::write(&tmp, bytes).await?;
    if let Err(e) = tokio::fs::rename(&tmp, path).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(e.into());
    }
    Ok(())
}

// ── HTTP ──

fn header_str<'a>(headers: &'a HeaderMap, name: &str) -> Result<&'a str, TgError> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| TgError::BadRequest(format!("missing header {name}")))
}

/// Check the action proof; the account (identity key) behind it.
async fn account(state: &AppState, headers: &HeaderMap, domain: &[u8], body: &[u8]) -> Result<String, TgError> {
    let pubkey = hex::decode(header_str(headers, H_IDENTITY)?)
        .map_err(|e| TgError::BadRequest(format!("{H_IDENTITY}: {e}")))?;
    let ts: i64 = header_str(headers, H_TS)?
        .parse()
        .map_err(|_| TgError::BadRequest(format!("{H_TS} must be unix seconds")))?;
    let sig = hex::decode(header_str(headers, H_PROOF)?).map_err(|e| TgError::BadRequest(format!("{H_PROOF}: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(domain, &pubkey, body, ts, &sig, now).map_err(|e| match e {
        proof::ProofError::PubkeyLen(_) | proof::ProofError::SignatureLen(_) => TgError::BadRequest(e.to_string()),
        _ => TgError::Unauthorized(e.to_string()),
    })?;
    let pool = state.pool.as_ref().ok_or(TgError::NoDb)?;
    // ADR-027 — a linked device speaks for its person: one limit per account.
    let (_, identity) = crate::accounts::resolve_signer(pool, &pubkey).await?.ok_or(TgError::Forbidden)?;
    Ok(hex::encode(identity))
}

fn limited(r: Result<(), Duration>) -> Result<(), TgError> {
    r.map_err(|wait| {
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&["telegram_stickers"]).inc();
        TgError::RateLimited(wait.as_secs().max(1))
    })
}

#[derive(Deserialize)]
pub struct PackRequest {
    pub name: String,
}

/// POST /v1/stickers/telegram
pub async fn pack(
    State(state): State<AppState>,
    Extension(tg): Extension<Arc<TelegramStickers>>,
    headers: HeaderMap,
    Json(req): Json<PackRequest>,
) -> Result<Json<serde_json::Value>, TgError> {
    if !valid_name(&req.name) {
        return Err(TgError::BadRequest("not a telegram pack name".into()));
    }
    if !tg.configured() {
        return Err(TgError::NotConfigured);
    }
    let who = account(&state, &headers, TG_STICKERS_DOMAIN, req.name.as_bytes()).await?;
    limited(tg.packs_limit.check(&who))?;
    Ok(Json(tg.pack(&req.name).await?.public()))
}

async fn file_response(
    state: AppState,
    tg: Arc<TelegramStickers>,
    headers: HeaderMap,
    name: String,
    index: usize,
    thumb: bool,
) -> Result<Response, TgError> {
    if !valid_name(&name) {
        return Err(TgError::BadRequest("not a telegram pack name".into()));
    }
    if !tg.configured() {
        return Err(TgError::NotConfigured);
    }
    let signed = if thumb { format!("{name}/{index}/thumb") } else { format!("{name}/{index}") };
    let who = account(&state, &headers, TG_STICKER_FILE_DOMAIN, signed.as_bytes()).await?;
    limited(tg.files_limit.check(&who))?;
    let bytes = tg.file(&name, index, thumb).await?;
    Ok(([(header::CONTENT_TYPE, "application/octet-stream")], bytes).into_response())
}

/// GET /v1/stickers/telegram/{name}/{index}
pub async fn file(
    State(state): State<AppState>,
    Extension(tg): Extension<Arc<TelegramStickers>>,
    UrlPath((name, index)): UrlPath<(String, usize)>,
    headers: HeaderMap,
) -> Result<Response, TgError> {
    file_response(state, tg, headers, name, index, false).await
}

/// GET /v1/stickers/telegram/{name}/{index}/thumb
pub async fn thumb(
    State(state): State<AppState>,
    Extension(tg): Extension<Arc<TelegramStickers>>,
    UrlPath((name, index)): UrlPath<(String, usize)>,
    headers: HeaderMap,
) -> Result<Response, TgError> {
    file_response(state, tg, headers, name, index, true).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::extract::Query;
    use axum::routing::get;
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const TOKEN: &str = "123456:AAEtestTokenForMockedTelegram_x";

    /// A fake Bot API: one pack "Ziongo777" (an animated, a video and a
    /// still sticker), the right token only; counts calls.
    async fn mock_telegram(calls: Arc<AtomicUsize>) -> String {
        let set = serde_json::json!({
            "ok": true,
            "result": {
                "name": "Ziongo777", "title": "Зионго", "sticker_type": "regular",
                "stickers": [
                    {"file_id": "F0", "file_unique_id": "U0", "type": "regular", "width": 512, "height": 512,
                     "is_animated": true, "is_video": false, "emoji": "😀",
                     "thumbnail": {"file_id": "T0", "file_unique_id": "V0", "width": 128, "height": 128}},
                    {"file_id": "F1", "file_unique_id": "U1", "type": "regular", "width": 512, "height": 512,
                     "is_animated": false, "is_video": true, "emoji": "🔥"},
                    {"file_id": "F2", "file_unique_id": "U2", "type": "regular", "width": 512, "height": 512,
                     "is_animated": false, "is_video": false}
                ]
            }
        });
        let c1 = calls.clone();
        let c2 = calls.clone();
        let c3 = calls.clone();
        let app = axum::Router::new()
            .route(
                &format!("/bot{TOKEN}/getStickerSet"),
                get(move |Query(q): Query<HashMap<String, String>>| {
                    c1.fetch_add(1, Ordering::SeqCst);
                    let set = set.clone();
                    async move {
                        if q.get("name").map(|n| n.eq_ignore_ascii_case("ziongo777")) == Some(true) {
                            Json(set)
                        } else {
                            Json(serde_json::json!({"ok": false, "error_code": 400, "description": "Bad Request: STICKERSET_INVALID"}))
                        }
                    }
                }),
            )
            .route(
                &format!("/bot{TOKEN}/getFile"),
                get(move |Query(q): Query<HashMap<String, String>>| {
                    c2.fetch_add(1, Ordering::SeqCst);
                    async move {
                        let id = q.get("file_id").cloned().unwrap_or_default();
                        Json(serde_json::json!({"ok": true, "result": {"file_id": id, "file_path": format!("stickers/{id}.bin")}}))
                    }
                }),
            )
            .route(
                &format!("/file/bot{TOKEN}/stickers/{{f}}"),
                get(move |UrlPath(f): UrlPath<String>| {
                    c3.fetch_add(1, Ordering::SeqCst);
                    async move { format!("bytes of {f}").into_bytes() }
                }),
            )
            .fallback(|| async {
                (StatusCode::UNAUTHORIZED, Json(serde_json::json!({"ok": false, "error_code": 401, "description": "Unauthorized"})))
            });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        format!("http://{addr}")
    }

    fn cache_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sinhron_tg_{tag}_{}", uuid::Uuid::new_v4()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    #[test]
    fn names_and_tokens_are_checked() {
        assert!(valid_name("Ziongo777"));
        assert!(valid_name("Animals_by_some_bot"));
        assert!(!valid_name(""));
        assert!(!valid_name("../etc"));
        assert!(!valid_name("a/b"));
        assert!(!valid_name(&"a".repeat(65)));
        assert!(valid_token(TOKEN));
        assert!(!valid_token("123456"));
        assert!(!valid_token("abc:AAEtestTokenForMockedTelegram_x"));
        assert!(!valid_token("123:short"));
        assert!(!valid_token("123:AAEtestTokenForMockedTelegram/../x"));
    }

    /// ADR-062 — the pack and its files come from the Bot API once, then
    /// from the day cache; the phone never sees Telegram's file ids.
    #[tokio::test]
    async fn a_pack_and_its_files_come_once_then_from_the_cache() {
        let calls = Arc::new(AtomicUsize::new(0));
        let api = mock_telegram(calls.clone()).await;
        let tg = TelegramStickers::new(Some(format!("{TOKEN}\n")), api, cache_dir("cache"));
        assert!(tg.configured(), "a trailing newline in the token file is fine");

        let p = tg.pack("Ziongo777").await.unwrap();
        assert_eq!(p.title, "Зионго");
        let formats: Vec<_> = p.stickers.iter().map(|s| s.format.as_str()).collect();
        assert_eq!(formats, ["tgs", "webm", "webp"]);
        assert_eq!(p.stickers[0].emoji, "😀");
        let public = p.public().to_string();
        assert!(!public.contains("F0") && !public.contains("U0"), "no telegram file ids: {public}");
        assert!(public.contains("\"thumb\":true"));
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        // Same pack, other spelling → the cache.
        tg.pack("ziongo777").await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        assert_eq!(tg.file("Ziongo777", 1, false).await.unwrap(), b"bytes of F1.bin");
        assert_eq!(calls.load(Ordering::SeqCst), 3, "getFile + the download");
        assert_eq!(tg.file("Ziongo777", 1, false).await.unwrap(), b"bytes of F1.bin");
        assert_eq!(calls.load(Ordering::SeqCst), 3, "second time from the cache");
        assert_eq!(tg.file("Ziongo777", 0, true).await.unwrap(), b"bytes of T0.bin");
        assert_eq!(tg.file("Ziongo777", 1, true).await, Err(TgError::NotFound), "no still for this one");
        assert_eq!(tg.file("Ziongo777", 9, false).await, Err(TgError::NotFound));
    }

    /// MEDIA-6 — a redirect from the Bot API address is not followed: the
    /// other host got the request (and the token, in the Referer).
    #[tokio::test]
    async fn a_redirect_from_the_bot_api_is_not_followed() {
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        let elsewhere = axum::Router::new().fallback(move || {
            h.fetch_add(1, Ordering::SeqCst);
            async { Json(serde_json::json!({"ok": true, "result": {"name": "x", "title": "evil", "stickers": []}})) }
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target = format!("http://{}/x", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, elsewhere).await.unwrap() });
        let redirecting = axum::Router::new().fallback(move || {
            let target = target.clone();
            async move { (StatusCode::FOUND, [(header::LOCATION, target)]) }
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, redirecting).await.unwrap() });

        let tg = TelegramStickers::new(Some(TOKEN.into()), api, cache_dir("redirect"));
        assert_eq!(tg.pack("Ziongo777").await, Err(TgError::Unreachable));
        assert_eq!(hits.load(Ordering::SeqCst), 0, "the redirect target was never asked");
    }

    /// MEDIA-7 — every place to Telegram taken: a request waits a little
    /// and gets "try later", it doesn't hang.
    #[tokio::test]
    async fn a_full_queue_to_telegram_answers_try_later() {
        let api = mock_telegram(Arc::new(AtomicUsize::new(0))).await;
        let mut tg = TelegramStickers::new(Some(TOKEN.into()), api, cache_dir("queue"));
        tg.upstream_wait = Duration::from_millis(100);
        let all = tg.upstream.acquire_many(UPSTREAM_PARALLEL as u32).await.unwrap();
        assert_eq!(tg.pack("Ziongo777").await, Err(TgError::RateLimited(30)));
        drop(all);
        assert!(tg.pack("Ziongo777").await.is_ok());
    }

    /// MEDIA-8 — a Bot API reply larger than any real one is refused, not
    /// read into memory whole.
    #[tokio::test]
    async fn an_oversized_bot_api_reply_is_refused() {
        let huge = axum::Router::new().fallback(|| async {
            Json(serde_json::json!({"ok": true, "result": {"name": "x", "title": "t".repeat(2 * MAX_FILE_BYTES), "stickers": []}}))
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let api = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, huge).await.unwrap() });
        let tg = TelegramStickers::new(Some(TOKEN.into()), api, cache_dir("huge"));
        assert_eq!(tg.pack("Ziongo777").await, Err(TgError::Unreachable));
    }

    #[tokio::test]
    async fn plain_errors_for_missing_packs_bad_tokens_and_no_telegram() {
        let calls = Arc::new(AtomicUsize::new(0));
        let api = mock_telegram(calls).await;
        let tg = TelegramStickers::new(Some(TOKEN.into()), api.clone(), cache_dir("errors"));
        assert_eq!(tg.pack("NoSuchPack").await, Err(TgError::NotFound));
        assert!(matches!(tg.pack("../x").await, Err(TgError::BadRequest(_))));

        let wrong = TelegramStickers::new(Some("999:AAEanotherTokenTelegramRefuses_y".into()), api, cache_dir("wrong"));
        assert_eq!(wrong.pack("Ziongo777").await, Err(TgError::NotConfigured), "Telegram refused the token");

        let none = TelegramStickers::new(None, "http://127.0.0.1:9".into(), cache_dir("none"));
        assert!(!none.configured());
        assert_eq!(none.pack("Ziongo777").await, Err(TgError::NotConfigured));

        // Nothing listens there: like a blocked api.telegram.org.
        let dead = TelegramStickers::new(Some(TOKEN.into()), "http://127.0.0.1:9".into(), cache_dir("dead"));
        assert_eq!(dead.pack("Ziongo777").await, Err(TgError::Unreachable));
    }

    #[tokio::test]
    async fn the_sweep_drops_packs_older_than_a_day() {
        let calls = Arc::new(AtomicUsize::new(0));
        let api = mock_telegram(calls.clone()).await;
        let dir = cache_dir("sweep");
        let tg = TelegramStickers::new(Some(TOKEN.into()), api, dir.clone());
        tg.pack("Ziongo777").await.unwrap();
        assert_eq!(tg.sweep().await, 0, "fresh stays");
        let list = dir.join("ziongo777").join("pack.json");
        let old = SystemTime::now() - CACHE_TTL - Duration::from_secs(60);
        std::fs::File::options().write(true).open(&list).unwrap().set_modified(old).unwrap();
        assert_eq!(tg.sweep().await, 1);
        assert!(!dir.join("ziongo777").exists());
        tg.pack("Ziongo777").await.unwrap();
        assert_eq!(calls.load(Ordering::SeqCst), 2, "asked Telegram again");
    }

    // ── Through the router ──

    use axum::http::Request;
    use ed25519_dalek::{Signer, SigningKey};
    use http_body_util::BodyExt;
    use sha2::{Digest, Sha256};
    use tower::ServiceExt;

    fn signed(req: axum::http::request::Builder, sk: &SigningKey, domain: &[u8], body: &[u8]) -> axum::http::request::Builder {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut msg = domain.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&Sha256::digest(body));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        req.header(H_IDENTITY, hex::encode(sk.verifying_key().as_bytes()))
            .header(H_TS, ts.to_string())
            .header(H_PROOF, hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes()))
    }

    fn state(pool: Option<sqlx::PgPool>) -> AppState {
        AppState {
            pool,
            sessions: crate::session::SessionRegistry::new(),
            push: Arc::new(crate::push::LoggingPush),
            rate: crate::rate_limit::RateLimiter::new(RateConfig::defaults()),
            calls: crate::call_session::CallSessionRegistry::new(),
        }
    }

    async fn post_pack(app: axum::Router, sk: &SigningKey, name: &str) -> (StatusCode, serde_json::Value) {
        let body = serde_json::json!({ "name": name }).to_string();
        let req = signed(Request::builder().method("POST").uri("/v1/stickers/telegram"), sk, TG_STICKERS_DOMAIN, name.as_bytes())
            .header(header::CONTENT_TYPE, "application/json")
            .body(axum::body::Body::from(body))
            .unwrap();
        let resp = app.oneshot(req).await.unwrap();
        let status = resp.status();
        let bytes = resp.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null))
    }

    #[tokio::test]
    async fn a_server_without_a_token_says_not_configured() {
        let tg = Arc::new(TelegramStickers::new(None, "http://127.0.0.1:9".into(), cache_dir("route")));
        let app = crate::build_app_with(state(None), tg);
        let (status, body) = post_pack(app, &SigningKey::from_bytes(&[7u8; 32]), "Ziongo777").await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body["error"], "not_configured");
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn registered_accounts_get_packs_and_files_within_their_limit(pool: sqlx::PgPool) {
        let calls = Arc::new(AtomicUsize::new(0));
        let api = mock_telegram(calls).await;
        let tg = Arc::new(TelegramStickers::new(Some(TOKEN.into()), api, cache_dir("route_db")));
        let app = crate::build_app_with(state(Some(pool.clone())), tg);
        let sk = SigningKey::from_bytes(&[9u8; 32]);

        let (status, body) = post_pack(app.clone(), &sk, "Ziongo777").await;
        assert_eq!((status, body["error"].as_str()), (StatusCode::FORBIDDEN, Some("forbidden")), "not registered here");

        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().as_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let (status, body) = post_pack(app.clone(), &sk, "Ziongo777").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body["title"], "Зионго");
        assert_eq!(body["stickers"].as_array().unwrap().len(), 3);
        let (status, body) = post_pack(app.clone(), &sk, "Nope").await;
        assert_eq!((status, body["error"].as_str()), (StatusCode::NOT_FOUND, Some("not_found")));

        let path = "Ziongo777/2";
        let req = signed(Request::builder().uri(format!("/v1/stickers/telegram/{path}")), &sk, TG_STICKER_FILE_DOMAIN, path.as_bytes())
            .body(axum::body::Body::empty())
            .unwrap();
        let resp = app.clone().oneshot(req).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(resp.into_body().collect().await.unwrap().to_bytes().as_ref(), b"bytes of F2.bin");

        // A proof for another file doesn't open this one.
        let req = signed(Request::builder().uri("/v1/stickers/telegram/Ziongo777/1"), &sk, TG_STICKER_FILE_DOMAIN, path.as_bytes())
            .body(axum::body::Body::empty())
            .unwrap();
        assert_eq!(app.oneshot(req).await.unwrap().status(), StatusCode::UNAUTHORIZED);
    }
}
