// Calls — WU CA3 + CA4.
//
// Endpoints:
//
//   POST /v1/call/token   → mint LiveKit JWT for a room
//     Body:
//       {
//         "identity_pubkey_hex": "64 hex",        // signer's ed25519 pubkey
//         "group_id_hex": "...",                  // target MLS group
//         "kind": "audio" | "video",
//         "request_ts": 1716405123,
//         "request_proof_hex": "128 hex"          // action proof
//       }
//     Response:
//       {
//         "token": "<JWT>",
//         "livekit_url": "wss://your-host/livekit",
//         "room": "sinhron-call-<call_id>",
//         "expires_at_unix": 1716405723,
//         "ttl_secs": 600
//       }
//
//   GET /v1/call/turn?identity_pubkey_hex=...&ts=...&proof_hex=...
//     → TURN credentials for ICE (RFC 5766 REST-API)
//     Response:
//       {
//         "urls": ["turn:host:3478?transport=udp", ...],
//         "username": "<expiry>:<per-person-per-day tag>",
//         "credential": "<base64 hmac-sha1>",
//         "ttl_secs": 86400
//       }
//
// Spec §10.2 — token issuance via sinhron-server; clients NEVER see
// LIVEKIT_API_SECRET or TURN_SHARED_SECRET.
//
// Security:
//   • Action-proof required (same Ed25519 mechanism as KP upload). Binds
//     request to identity + timestamp + body.
//   • Rate-limited per signing key, accounts only: the kp_upload policy
//     (100 an hour) for token, live and turn together.
//   • Token mint requires the caller to be a member of the target MLS
//     group (group_members → devices → users). Non-members get 403 — they
//     must not join the SFU room, see who is in it, or disrupt the call.
//   • TURN credentials TTL-bounded (default 24h, `TURN_TTL_SECS`). coturn
//     re-checks the credential on every allocation refresh, so the TTL
//     must outlive the longest call — there is no mid-call re-mint.
//   • TURN username carries no identity (random nonce) — coturn logs
//     usernames, and they must not reveal who is calling.

use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use base64::{prelude::BASE64_STANDARD, Engine};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use sha2::Sha256;
use time::OffsetDateTime;
use tracing::{info, warn};

use super::proof::{self, CALL_TOKEN_DOMAIN, CALL_TURN_DOMAIN};
use crate::AppState;

// ─────────────────────────────────────────────────────────────────────
// /v1/call/token — LiveKit JWT mint
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub identity_pubkey_hex: String,
    pub group_id_hex: String,
    /// "audio" or "video" — informs LiveKit room metadata. We don't
    /// gate publish permissions by kind (both allow audio+video tracks);
    /// it's metadata for the recipient to know what's expected.
    pub kind: String,
    pub request_ts: i64,
    pub request_proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct TokenResponse {
    pub token: String,
    pub livekit_url: String,
    pub room: String,
    pub expires_at_unix: i64,
    pub ttl_secs: i64,
    /// The video codecs this server's LiveKit takes, best first — the app
    /// picks among them (H.265 where the phone encodes it in hardware).
    /// Older servers send none: the app stays on H.264 / VP8.
    pub video_codecs: Vec<String>,
}

/// What `server/livekit.yaml` enables for video (a test keeps the two in
/// step). AV1 is not here: livekit_client 2.7.0 leaves AV1 tracks
/// unencrypted (E2EE first).
pub const CALL_VIDEO_CODECS: &[&str] = &["h265", "h264", "vp8"];

#[derive(Debug, thiserror::Error)]
pub enum CallError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("server misconfigured: {0}")]
    Misconfigured(String),
    #[error("rate limited; retry after {retry_after_secs}s")]
    RateLimited { retry_after_secs: u64 },
}

impl IntoResponse for CallError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            CallError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            CallError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            CallError::Forbidden(m) => (StatusCode::FORBIDDEN, m.clone()),
            CallError::Misconfigured(m) => {
                warn!(error = %m, "call endpoint misconfigured");
                (
                    StatusCode::SERVICE_UNAVAILABLE,
                    "call infrastructure not configured".to_string(),
                )
            }
            CallError::RateLimited { retry_after_secs } => {
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
                    retry_after_secs
                        .to_string()
                        .parse()
                        .expect("ascii digits parse"),
                );
                return resp;
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

/// JWT TTL for LiveKit join tokens: only for joining — LiveKit renews the
/// token of everyone connected (every few minutes, 10 min each), so a long
/// call outlives it. A token kept back after its owner left the chat opens
/// the room for 10 minutes, not an hour (security review 2026-11, calls:4).
const TOKEN_TTL_SECS: i64 = 600;

pub async fn mint_token(
    State(state): State<AppState>,
    Json(req): Json<TokenRequest>,
) -> Result<(StatusCode, Json<TokenResponse>), CallError> {
    // ── Validate inputs ──────────────────────────────────────────────
    let pubkey = hex::decode(&req.identity_pubkey_hex)
        .map_err(|e| CallError::BadRequest(format!("identity_pubkey_hex: {e}")))?;
    if pubkey.len() != 32 {
        return Err(CallError::BadRequest(format!(
            "identity_pubkey must be 32 bytes, got {}",
            pubkey.len(),
        )));
    }
    if req.group_id_hex.is_empty() || req.group_id_hex.len() > 256 {
        return Err(CallError::BadRequest("group_id_hex length".to_string()));
    }
    let kind = match req.kind.as_str() {
        "audio" | "video" => req.kind.clone(),
        _ => return Err(CallError::BadRequest("kind must be 'audio' or 'video'".to_string())),
    };
    let proof_sig = hex::decode(&req.request_proof_hex)
        .map_err(|e| CallError::BadRequest(format!("request_proof_hex: {e}")))?;

    // ── Verify action proof — body is "<group_id_hex>:<kind>" ───────
    let body = format!("{}:{}", req.group_id_hex, kind);
    let now_secs = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(
        CALL_TOKEN_DOMAIN,
        &pubkey,
        body.as_bytes(),
        req.request_ts,
        &proof_sig,
        now_secs,
    )
    .map_err(map_proof_err)?;

    // ── Caller must be a member of the group ─────────────────────────
    let group_id = hex::decode(&req.group_id_hex)
        .map_err(|e| CallError::BadRequest(format!("group_id_hex: {e}")))?;
    let pool = state
        .pool
        .as_ref()
        .ok_or_else(|| CallError::Misconfigured("no database".to_string()))?;
    // ADR-027 — a linked device signs with its own key; the call is the
    // person's (LiveKit identity = identity key, as SFrame keys expect).
    let identity_pk = match crate::accounts::resolve_signer(pool, &pubkey).await {
        Ok(Some((_, id))) => id,
        Ok(None) => return Err(CallError::Forbidden("unknown signer".to_string())),
        Err(e) => {
            warn!(error = %e, "call token signer lookup failed");
            return Err(CallError::Misconfigured("membership check unavailable".to_string()));
        }
    };
    // ── Rate-limit ───────────────────────────────────────────────────
    // The kp_upload bucket policy, per key — after the proof: junk
    // requests in someone's name used up their bucket (server-http:4);
    // and after the account check: every freshly made key got a bucket
    // in the map KeyPackage uploads and pairing share (LIMIT-3).
    if let Err(retry_after) = state.rate.check_kp_upload(&req.identity_pubkey_hex) {
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["call_token"])
            .inc();
        return Err(CallError::RateLimited {
            retry_after_secs: retry_after.as_secs(),
        });
    }
    let member = is_group_member(pool, &group_id, &identity_pk).await.map_err(|e| {
        warn!(error = %e, "call token membership query failed");
        CallError::Misconfigured("membership check unavailable".to_string())
    })?;
    if !member {
        return Err(CallError::Forbidden("not a member of this group".to_string()));
    }

    // ── Read LiveKit config from env ─────────────────────────────────
    let (api_key, api_secret) = livekit_keys_from_env().map_err(CallError::Misconfigured)?;
    let livekit_url = std::env::var("LIVEKIT_URL")
        .unwrap_or_else(|_| "ws://localhost:7880".to_string());

    // ── Compose room name + claims ───────────────────────────────────
    let room = format!("sinhron-call-{}", &req.group_id_hex);
    // ADR-025 — the participant is the *device* that asked (its own key; the
    // identity key on the first device): two devices of one person can be
    // in a call at once, each with its own SFrame key (its MLS leaf).
    let identity = hex::encode(&pubkey);
    let exp = now_secs + TOKEN_TTL_SECS;

    let claims = serde_json::json!({
        "iss": api_key,
        "sub": identity,
        "nbf": now_secs,
        "exp": exp,
        "video": {
            "room": room,
            "roomJoin": true,
            "canPublish": true,
            "canSubscribe": true,
            "canPublishData": true,
        },
        "metadata": req.group_id_hex,
    });
    let token = mint_hs256_jwt(&claims, &api_secret)
        .map_err(|e| CallError::Misconfigured(format!("jwt mint: {e}")))?;

    info!(
        identity = %&identity[..12],
        group = %crate::short_key(&req.group_id_hex),
        kind = %kind,
        "minted LiveKit token",
    );

    Ok((
        StatusCode::OK,
        Json(TokenResponse {
            token,
            livekit_url,
            room,
            expires_at_unix: exp,
            ttl_secs: TOKEN_TTL_SECS,
            video_codecs: CALL_VIDEO_CODECS.iter().map(|c| c.to_string()).collect(),
        }),
    ))
}

// ─────────────────────────────────────────────────────────────────────
// /v1/call/live — is anyone in this group's call right now?
// ─────────────────────────────────────────────────────────────────────
//
// Owner, 2026-10-18: "the call ended — it still says Join". A CallEnd
// reaches only the devices online at that moment; a phone that was asleep
// keeps "Call in progress · Join" for hours. Before offering Join the app
// asks here, and LiveKit (the truth: who is in the room) answers. Same
// guard as the token: an action proof over "<group_id_hex>:live" and
// membership of the group.

#[derive(Debug, Deserialize)]
pub struct LiveRequest {
    pub identity_pubkey_hex: String,
    pub group_id_hex: String,
    pub request_ts: i64,
    pub request_proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct LiveResponse {
    pub live: bool,
    pub participants: u32,
}

pub async fn call_live(
    State(state): State<AppState>,
    Json(req): Json<LiveRequest>,
) -> Result<(StatusCode, Json<LiveResponse>), CallError> {
    let pubkey = hex::decode(&req.identity_pubkey_hex)
        .map_err(|e| CallError::BadRequest(format!("identity_pubkey_hex: {e}")))?;
    if pubkey.len() != 32 {
        return Err(CallError::BadRequest("identity_pubkey must be 32 bytes".to_string()));
    }
    if req.group_id_hex.is_empty() || req.group_id_hex.len() > 256 {
        return Err(CallError::BadRequest("group_id_hex length".to_string()));
    }
    let proof_sig = hex::decode(&req.request_proof_hex)
        .map_err(|e| CallError::BadRequest(format!("request_proof_hex: {e}")))?;
    let body = format!("{}:live", req.group_id_hex);
    let now_secs = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(CALL_TOKEN_DOMAIN, &pubkey, body.as_bytes(), req.request_ts, &proof_sig, now_secs)
        .map_err(map_proof_err)?;
    let group_id = hex::decode(&req.group_id_hex)
        .map_err(|e| CallError::BadRequest(format!("group_id_hex: {e}")))?;
    let pool = state
        .pool
        .as_ref()
        .ok_or_else(|| CallError::Misconfigured("no database".to_string()))?;
    let identity_pk = match crate::accounts::resolve_signer(pool, &pubkey).await {
        Ok(Some((_, id))) => id,
        Ok(None) => return Err(CallError::Forbidden("unknown signer".to_string())),
        Err(e) => {
            warn!(error = %e, "call live signer lookup failed");
            return Err(CallError::Misconfigured("membership check unavailable".to_string()));
        }
    };
    // Only an account has a bucket (LIMIT-3).
    if let Err(retry_after) = state.rate.check_kp_upload(&req.identity_pubkey_hex) {
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["call_live"])
            .inc();
        return Err(CallError::RateLimited {
            retry_after_secs: retry_after.as_secs(),
        });
    }
    let member = is_group_member(pool, &group_id, &identity_pk).await.map_err(|e| {
        warn!(error = %e, "call live membership query failed");
        CallError::Misconfigured("membership check unavailable".to_string())
    })?;
    if !member {
        return Err(CallError::Forbidden("not a member of this group".to_string()));
    }

    let (api_key, api_secret) = livekit_keys_from_env().map_err(CallError::Misconfigured)?;
    let api_url = std::env::var("LIVEKIT_API_URL").unwrap_or_else(|_| "http://livekit:7880".to_string());
    let room = format!("sinhron-call-{}", &req.group_id_hex);
    let n = room_participants(&api_url, &api_key, &api_secret, &room, now_secs)
        .await
        .map_err(|e| {
            warn!(error = %e, "LiveKit ListParticipants failed");
            CallError::Misconfigured("call state unavailable".to_string())
        })?;
    Ok((StatusCode::OK, Json(LiveResponse { live: n > 0, participants: n })))
}

/// Is nobody in this group's LiveKit call room? `false` when unsure
/// (LiveKit not configured or not answering).
pub(crate) async fn group_room_is_empty(group_id: &[u8]) -> bool {
    let Ok((key, secret)) = livekit_keys_from_env() else { return false };
    let api_url = std::env::var("LIVEKIT_API_URL").unwrap_or_else(|_| "http://livekit:7880".to_string());
    let room = format!("sinhron-call-{}", hex::encode(group_id)); // as the app names it (mint_token)
    let now = OffsetDateTime::now_utc().unix_timestamp();
    room_participants(&api_url, &key, &secret, &room, now).await == Ok(0)
}

/// How many are in LiveKit room [room] (0 when it doesn't exist). Twirp
/// `RoomService/ListParticipants` with a one-minute `roomAdmin` token.
async fn room_participants(
    api_url: &str,
    api_key: &str,
    api_secret: &str,
    room: &str,
    now_secs: i64,
) -> Result<u32, String> {
    let token = room_admin_token(api_key, api_secret, room, now_secs)?;
    let url = format!("{}/twirp/livekit.RoomService/ListParticipants", api_url.trim_end_matches('/'));
    let resp = reqwest::Client::new()
        .post(url)
        .bearer_auth(token)
        .timeout(std::time::Duration::from_secs(5))
        .json(&serde_json::json!({ "room": room }))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(0); // no such room: nobody's in a call
    }
    if !resp.status().is_success() {
        return Err(format!("LiveKit answered {}", resp.status()));
    }
    let v: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(participant_count(&v))
}

/// A one-minute `roomAdmin` token for LiveKit's RoomService on [room].
fn room_admin_token(api_key: &str, api_secret: &str, room: &str, now_secs: i64) -> Result<String, String> {
    let claims = serde_json::json!({
        "iss": api_key,
        "nbf": now_secs,
        "exp": now_secs + 60,
        "video": { "room": room, "roomAdmin": true },
    });
    mint_hs256_jwt(&claims, api_secret)
}

/// ADR-083 — take [devices] out of these groups' call rooms now: they
/// were removed from the chat or cut off, and LiveKit would keep renewing
/// their token while they stay connected (security review 2026-11,
/// calls:4). In the background; quiet when LiveKit isn't set up or the
/// device isn't in the room (participant identity = device key, as minted).
pub(crate) fn evict_from_calls(groups: Vec<Vec<u8>>, devices: Vec<Vec<u8>>) {
    let Ok((key, secret)) = livekit_keys_from_env() else { return };
    if groups.is_empty() || devices.is_empty() {
        return;
    }
    let api_url = std::env::var("LIVEKIT_API_URL").unwrap_or_else(|_| "http://livekit:7880".to_string());
    tokio::spawn(async move {
        let n = remove_participants(&api_url, &key, &secret, &groups, &devices).await;
        if n > 0 {
            info!(n, "removed devices taken out of a call");
        }
    });
}

/// Twirp `RoomService/RemoveParticipant` for each device in each room; how
/// many LiveKit took out (a device not in the room answers 404).
async fn remove_participants(api_url: &str, key: &str, secret: &str, groups: &[Vec<u8>], devices: &[Vec<u8>]) -> u32 {
    let url = format!("{}/twirp/livekit.RoomService/RemoveParticipant", api_url.trim_end_matches('/'));
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let mut n = 0;
    for g in groups {
        let room = format!("sinhron-call-{}", hex::encode(g)); // as mint_token names it
        let Ok(token) = room_admin_token(key, secret, &room, now) else { return n };
        for d in devices {
            let sent = reqwest::Client::new()
                .post(&url)
                .bearer_auth(&token)
                .timeout(std::time::Duration::from_secs(5))
                .json(&serde_json::json!({ "room": room, "identity": hex::encode(d) }))
                .send()
                .await;
            n += sent.is_ok_and(|r| r.status().is_success()) as u32;
        }
    }
    n
}

/// `{"participants":[…]}` → how many; a missing list is an empty room.
fn participant_count(v: &serde_json::Value) -> u32 {
    v.get("participants").and_then(|p| p.as_array()).map_or(0, |a| a.len() as u32)
}

// ─────────────────────────────────────────────────────────────────────
// /v1/call/turn — coturn REST-API credential mint (RFC 5766)
// ─────────────────────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct TurnQuery {
    pub identity_pubkey_hex: String,
    pub request_ts: i64,
    pub request_proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct TurnResponse {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
    pub ttl_secs: i64,
}

/// Default TURN credential lifetime. 24h so a credential minted at call
/// start survives coturn's allocation refreshes for any realistic call.
const TURN_TTL_SECS_DEFAULT: i64 = 86_400;

pub async fn mint_turn_creds(
    State(state): State<AppState>,
    Query(q): Query<TurnQuery>,
) -> Result<Json<TurnResponse>, CallError> {
    let pubkey = hex::decode(&q.identity_pubkey_hex)
        .map_err(|e| CallError::BadRequest(format!("identity_pubkey_hex: {e}")))?;
    if pubkey.len() != 32 {
        return Err(CallError::BadRequest(format!(
            "identity_pubkey must be 32 bytes, got {}",
            pubkey.len(),
        )));
    }
    let proof_sig = hex::decode(&q.request_proof_hex)
        .map_err(|e| CallError::BadRequest(format!("request_proof_hex: {e}")))?;

    // Action proof body is just the identity itself — TURN creds don't
    // bind to a specific group, they're a general-purpose ICE relay.
    let now_secs = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(
        CALL_TURN_DOMAIN,
        &pubkey,
        q.identity_pubkey_hex.as_bytes(),
        q.request_ts,
        &proof_sig,
        now_secs,
    )
    .map_err(map_proof_err)?;
    // Only someone with an account here: any freshly made key used to get
    // a day of relaying through the operator's coturn (security review
    // 2026-11-02). No database (tests, a dev run) — nothing to check.
    let mut person = pubkey.clone();
    if let Some(pool) = &state.pool {
        let known = crate::accounts::resolve_signer(pool, &pubkey)
            .await
            .map_err(|_| CallError::Misconfigured("account check unavailable".to_string()))?;
        let Some((_, identity)) = known else {
            return Err(CallError::Forbidden("not a registered account".to_string()));
        };
        person = identity;
    }
    // Rate-limit: reuse kp_upload bucket per identity, after the proof
    // and the account check (LIMIT-3: only an account has a bucket).
    if let Err(retry_after) = state.rate.check_kp_upload(&q.identity_pubkey_hex) {
        crate::metrics::RATE_LIMIT_HITS_TOTAL
            .with_label_values(&["call_turn"])
            .inc();
        return Err(CallError::RateLimited {
            retry_after_secs: retry_after.as_secs(),
        });
    }

    let shared_secret = std::env::var("TURN_SHARED_SECRET")
        .map_err(|_| CallError::Misconfigured("TURN_SHARED_SECRET not set".to_string()))?;
    let urls_raw = std::env::var("TURN_URLS").unwrap_or_else(|_| String::new());
    let urls = parse_turn_urls(&urls_raw);
    if urls.is_empty() {
        return Err(CallError::Misconfigured("TURN_URLS empty".to_string()));
    }
    // ADR-041 — without `turns:` (TLS on 443, ADR-016) phones on networks
    // that block UDP and odd ports (some carriers, corporate/hotel Wi-Fi)
    // can't call at all. Say so once in the log, not on every call.
    if !has_tls_fallback(&urls) {
        static WARNED: std::sync::Once = std::sync::Once::new();
        WARNED.call_once(|| {
            warn!("TURN_URLS has no turns: entry — calls fail on networks that only allow HTTPS (443)");
        });
    }
    let ttl_secs = std::env::var("TURN_TTL_SECS")
        .ok()
        .and_then(|s| s.parse::<i64>().ok())
        .filter(|&v| v > 0 && v <= 86_400)
        .unwrap_or(TURN_TTL_SECS_DEFAULT);

    // Username format per coturn REST-API convention:
    // "<expiry_unix>:<anything>" — expiry first so coturn can parse the
    // TTL without state. The suffix is a per-person-per-day tag, NOT the
    // identity: coturn logs usernames, and a log of who relayed when is
    // exactly the social-graph metadata the threat model tries to keep
    // away from a compromised or compelled operator.
    let (username, expiry) = turn_username(&person, now_secs, ttl_secs);
    let credential = hmac_sha1_base64(shared_secret.as_bytes(), username.as_bytes());

    Ok(Json(TurnResponse {
        urls,
        username,
        credential,
        ttl_secs: expiry - now_secs,
    }))
}

/// One TURN username per person per UTC day, and its expiry. coturn counts
/// `user-quota` by the whole username, so the expiry is counted from the
/// end of the day, not from "now": with the second of the mint in it every
/// mint was a new name with its own quota, and one account took every
/// relay slot (LIMIT-1). The credential lives `ttl_secs` to `ttl_secs` + 24 h.
fn turn_username(person: &[u8], now_secs: i64, ttl_secs: i64) -> (String, i64) {
    let day = now_secs.div_euclid(86_400);
    let expiry = (day + 1) * 86_400 + ttl_secs;
    (format!("{}:{}", expiry, person_tag(person, day)), expiry)
}

// ─────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────

/// True iff any device of the user with `identity_pubkey` is in
/// `group_members` for `group_id`. Same join as `ws::handle_call_invite`.
pub(crate) async fn is_group_member(
    pool: &sqlx::PgPool,
    group_id: &[u8],
    identity_pubkey: &[u8],
) -> Result<bool, sqlx::Error> {
    let (member,): (bool,) = sqlx::query_as(
        "SELECT EXISTS ( \
             SELECT 1 FROM group_members gm \
             JOIN devices d ON d.device_pk = gm.device_pk \
             JOIN users u ON u.user_pk = d.user_pk \
             WHERE gm.group_id = $1 AND u.identity_pubkey = $2)",
    )
    .bind(group_id)
    .bind(identity_pubkey)
    .fetch_one(pool)
    .await?;
    Ok(member)
}

/// `TURN_URLS` (comma-separated) → the list handed to clients: trimmed,
/// empty and duplicate entries dropped, and anything that isn't a
/// `turn:` / `turns:` / `stun:` URL dropped with a warning (a typo there
/// would otherwise reach every phone as a broken ICE server). Order kept:
/// the installer writes UDP, TCP, then TLS on 443 (ADR-016/041).
fn parse_turn_urls(raw: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for url in raw.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        let lower = url.to_ascii_lowercase();
        if !(lower.starts_with("turn:") || lower.starts_with("turns:") || lower.starts_with("stun:")) {
            warn!(url = %url, "TURN_URLS entry ignored: not a turn:/turns:/stun: URL");
            continue;
        }
        if !out.iter().any(|u| u == url) {
            out.push(url.to_string());
        }
    }
    out
}

/// TURN over TLS is offered — the path that works where only HTTPS does.
fn has_tls_fallback(urls: &[String]) -> bool {
    urls.iter().any(|u| u.to_ascii_lowercase().starts_with("turns:"))
}

/// The TURN username's suffix: the same for one person (all their devices)
/// for a day, so coturn's `user-quota` counts per person — a random one per
/// mint let one free account hold every relay slot (deploy-deps:3). Keyed
/// by a secret made at start: unlinkable to the person in coturn's logs.
fn person_tag(identity: &[u8], day: i64) -> String {
    static KEY: once_cell::sync::Lazy<[u8; 32]> = once_cell::sync::Lazy::new(rand::random);
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(&KEY[..]).expect("hmac init");
    mac.update(identity);
    mac.update(&day.to_be_bytes());
    hex::encode(&mac.finalize().into_bytes()[..16])
}

fn map_proof_err(e: proof::ProofError) -> CallError {
    match e {
        proof::ProofError::PubkeyLen(_) | proof::ProofError::SignatureLen(_) => {
            CallError::BadRequest(e.to_string())
        }
        proof::ProofError::PubkeyInvalid(_)
        | proof::ProofError::SignatureMismatch
        | proof::ProofError::StaleTimestamp { .. } => CallError::Unauthorized(e.to_string()),
    }
}

/// Parse `LIVEKIT_KEYS` env (format: `"<key>: <secret>"`) into a pair.
/// Multiple keys not supported — server picks the first. LiveKit itself
/// accepts multi-key for rotation, but our minting side just needs ONE
/// to sign with; clients use whichever is current.
fn livekit_keys_from_env() -> Result<(String, String), String> {
    let raw = std::env::var("LIVEKIT_KEYS")
        .map_err(|_| "LIVEKIT_KEYS not set".to_string())?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("LIVEKIT_KEYS empty".to_string());
    }
    // Format: "key: secret" (space-after-colon as the LiveKit docs spec).
    let mut parts = trimmed.splitn(2, ':');
    let key = parts
        .next()
        .ok_or_else(|| "missing key".to_string())?
        .trim()
        .to_string();
    let secret = parts
        .next()
        .ok_or_else(|| "missing secret".to_string())?
        .trim()
        .to_string();
    if key.is_empty() || secret.is_empty() {
        return Err("LIVEKIT_KEYS malformed".to_string());
    }
    if secret.len() < 32 {
        return Err("LIVEKIT_KEYS secret < 32 chars; refuse weak key".to_string());
    }
    Ok((key, secret))
}

/// Placeholders from `.env.example` / docs/deploy-guide.md §3 — public in the repo.
const PUBLIC_SECRETS: &[&str] = &["devsecret", "devturnsecret", "GENERATE_", "dev_only", "change-me"];

/// Security review 2026-11 (deploy-deps:6) — a real deploy (LiveKit at
/// `wss://`, not `*.localhost`) refuses to start with a secret copied from
/// the repo: with it anyone could use LiveKit's admin API, mint TURN
/// credentials or log in to the database. Local dev (ws://, localhost) is
/// left alone.
pub fn refuse_public_secrets() -> Result<(), String> {
    let url = std::env::var("LIVEKIT_URL").unwrap_or_default();
    let Some(host) = url.strip_prefix("wss://") else { return Ok(()) };
    let host = host.split([':', '/']).next().unwrap_or_default();
    if host == "localhost" || host.ends_with(".localhost") {
        return Ok(());
    }
    for var in ["LIVEKIT_KEYS", "TURN_SHARED_SECRET", "SINHRON_DB_URL", "SINHRON_DB_MIGRATE_URL"] {
        let value = std::env::var(var).unwrap_or_default();
        if PUBLIC_SECRETS.iter().any(|p| value.contains(p)) {
            return Err(format!(
                "{var} holds a placeholder from the repo — set a random secret in server/.env \
                 (install.sh makes them; for the database see docs/deploy-guide.md §3)"
            ));
        }
    }
    Ok(())
}

/// Build a `HS256`-signed JWT. Manual implementation (no `jsonwebtoken`
/// dep) keeps the crate footprint minimal — LiveKit only ever consumes
/// HS256, so a 30-line impl is enough.
fn mint_hs256_jwt(claims: &serde_json::Value, secret: &str) -> Result<String, String> {
    let header = serde_json::json!({"alg": "HS256", "typ": "JWT"});
    let header_b64 = URL_SAFE_NO_PAD.encode(serde_json::to_string(&header).unwrap());
    let claims_b64 = URL_SAFE_NO_PAD
        .encode(serde_json::to_string(claims).map_err(|e| e.to_string())?);
    let signing_input = format!("{header_b64}.{claims_b64}");

    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(secret.as_bytes())
        .map_err(|e| format!("hmac init: {e}"))?;
    mac.update(signing_input.as_bytes());
    let sig = mac.finalize().into_bytes();
    let sig_b64 = URL_SAFE_NO_PAD.encode(sig);

    Ok(format!("{signing_input}.{sig_b64}"))
}

/// HMAC-SHA1 → base64-encoded credential per coturn REST-API convention.
/// Note: this is `base64::STANDARD`, NOT url-safe — coturn parses the
/// `+/=` set as documented in its docs.
fn hmac_sha1_base64(secret: &[u8], data: &[u8]) -> String {
    let mut mac = <Hmac<Sha1> as Mac>::new_from_slice(secret).expect("hmac-sha1 init");
    mac.update(data);
    BASE64_STANDARD.encode(mac.finalize().into_bytes())
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
pub(crate) mod tests {

    #[test]
    fn live_counts_participants_and_reads_an_empty_room_as_none() {
        assert_eq!(super::participant_count(&serde_json::json!({"participants": [{"identity": "a"}, {"identity": "b"}]})), 2);
        assert_eq!(super::participant_count(&serde_json::json!({"participants": []})), 0);
        assert_eq!(super::participant_count(&serde_json::json!({})), 0, "LiveKit omits an empty list");
    }

    /// The codecs the app is told about are the ones LiveKit is set to
    /// take (and AV1 stays out — it would go unencrypted).
    #[test]
    fn advertised_video_codecs_match_livekit_yaml() {
        let yaml = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/livekit.yaml")).unwrap();
        for c in CALL_VIDEO_CODECS {
            assert!(yaml.contains(&format!("mime: video/{c}")), "livekit.yaml must enable video/{c}");
        }
        assert!(!yaml.contains("mime: video/av1"), "AV1 would reach the SFU unencrypted");
        assert!(!CALL_VIDEO_CODECS.contains(&"av1"));
    }
    use super::*;
    use std::sync::Mutex as StdMutex;

    // Env-mutating tests must serialize — cargo test runs in parallel.
    pub(crate) static ENV_LOCK: StdMutex<()> = StdMutex::new(());

    #[test]
    fn jwt_mint_roundtrip_decodes_claims() {
        let claims = serde_json::json!({
            "iss": "key",
            "sub": "user1",
            "video": { "room": "r" },
        });
        let token = mint_hs256_jwt(&claims, "test_secret_at_least_32_chars_long!!").unwrap();

        // JWT has three dot-separated parts.
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3, "expected header.payload.sig");

        // Decode payload back.
        let payload_bytes = URL_SAFE_NO_PAD.decode(parts[1]).unwrap();
        let decoded: serde_json::Value = serde_json::from_slice(&payload_bytes).unwrap();
        assert_eq!(decoded["iss"], "key");
        assert_eq!(decoded["video"]["room"], "r");
    }

    #[test]
    fn hmac_sha1_base64_deterministic() {
        let a = hmac_sha1_base64(b"secret", b"user:1716405123");
        let b = hmac_sha1_base64(b"secret", b"user:1716405123");
        assert_eq!(a, b);
        assert!(!a.is_empty());

        let c = hmac_sha1_base64(b"different_secret", b"user:1716405123");
        assert_ne!(a, c, "different secret must produce different cred");
    }

    #[test]
    fn livekit_keys_parses_canonical_format() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var(
            "LIVEKIT_KEYS",
            "devkey: devsecret_at_least_32_chars_for_unit_test_!!!",
        );
        let (k, s) = livekit_keys_from_env().unwrap();
        assert_eq!(k, "devkey");
        assert!(s.starts_with("devsecret"));
        std::env::remove_var("LIVEKIT_KEYS");
    }

    /// deploy-deps:6 — every secret `.env.example` and the deploy guide ship
    /// keeps a real deploy from starting; localhost / ws:// dev still starts.
    #[test]
    fn real_deploy_refuses_secrets_copied_from_the_repo() {
        let _g = ENV_LOCK.lock().unwrap();
        let read = |p: &str| std::fs::read_to_string(format!("{}/{p}", env!("CARGO_MANIFEST_DIR"))).unwrap();
        let (example, guide) = (read(".env.example"), read("../docs/deploy-guide.md"));
        let value = |text: &str, key: &str| -> String {
            let line = text.lines().find(|l| l.starts_with(&format!("{key}="))).unwrap();
            line[key.len() + 1..].split("  #").next().unwrap().trim().to_string()
        };
        let vars = ["LIVEKIT_KEYS", "TURN_SHARED_SECRET", "SINHRON_DB_URL", "SINHRON_DB_MIGRATE_URL", "LIVEKIT_URL"];
        let db = |pw: &str| format!("postgres://sinhron:{pw}@postgres:5432/sinhron");
        let random = ("API0123456789abcdef: 5f2c8e1d9a7b3c4e6f8a0b1c2d3e4f5a6b7c8d9e0f1a2b3c", "9c1e5a7b3d2f4e6a8b0c1d2e3f4a5b6c");
        let mut public = vec![];
        for text in [&example, &guide] {
            public.push(("LIVEKIT_KEYS", value(text, "LIVEKIT_KEYS")));
            public.push(("TURN_SHARED_SECRET", value(text, "TURN_SHARED_SECRET")));
            public.push(("SINHRON_DB_URL", db(&value(text, "SINHRON_DB_PASSWORD"))));
        }
        public.push(("SINHRON_DB_URL", db("dev_only"))); // docker-compose.yml's default
        public.push(("SINHRON_DB_MIGRATE_URL", db("dev_only")));
        let set = |url: &str, var: &str, bad: &str| {
            std::env::set_var("LIVEKIT_URL", url);
            std::env::set_var("LIVEKIT_KEYS", random.0);
            std::env::set_var("TURN_SHARED_SECRET", random.1);
            std::env::set_var("SINHRON_DB_URL", db(random.1));
            std::env::set_var("SINHRON_DB_MIGRATE_URL", db(random.1));
            std::env::set_var(var, bad);
        };
        for (var, bad) in &public {
            set("wss://livekit.example.com", var, bad);
            assert!(refuse_public_secrets().is_err(), "{var}={bad} was accepted");
            for dev in ["wss://livekit.localhost", "ws://192.168.1.109:7880"] {
                set(dev, var, bad);
                assert!(refuse_public_secrets().is_ok(), "{dev}: dev must still start");
            }
        }
        set("wss://livekit.example.com", "LIVEKIT_URL", "wss://livekit.example.com");
        assert!(refuse_public_secrets().is_ok(), "random secrets must start");
        for v in vars {
            std::env::remove_var(v);
        }
    }

    #[test]
    fn livekit_keys_rejects_short_secret() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("LIVEKIT_KEYS", "k: too_short");
        let result = livekit_keys_from_env();
        assert!(result.is_err());
        std::env::remove_var("LIVEKIT_KEYS");
    }

    #[test]
    fn livekit_keys_rejects_missing_secret() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("LIVEKIT_KEYS", "onlykey");
        let result = livekit_keys_from_env();
        assert!(result.is_err());
        std::env::remove_var("LIVEKIT_KEYS");
    }

    // ── ADR-041 — the TURN list clients get ──────────────────────────

    /// The installer's list (install.sh): UDP, TCP, TLS on 443.
    const INSTALLER_TURN_URLS: &str = "turn:chat.example.com:3478?transport=udp,\
        turn:chat.example.com:3478?transport=tcp,turns:turn.chat.example.com:443?transport=tcp";

    #[test]
    fn turn_urls_keep_order_and_the_443_fallback() {
        let urls = parse_turn_urls(INSTALLER_TURN_URLS);
        assert_eq!(
            urls,
            vec![
                "turn:chat.example.com:3478?transport=udp",
                "turn:chat.example.com:3478?transport=tcp",
                "turns:turn.chat.example.com:443?transport=tcp",
            ]
        );
        assert!(has_tls_fallback(&urls));
    }

    #[test]
    fn turn_urls_drop_blanks_duplicates_and_junk() {
        let urls = parse_turn_urls(" turn:a:3478 , ,turn:a:3478,https://a/,TURNS:b:443?transport=tcp,stun:a:3478,");
        assert_eq!(urls, vec!["turn:a:3478", "TURNS:b:443?transport=tcp", "stun:a:3478"]);
        assert!(has_tls_fallback(&urls), "scheme check ignores case");
        assert!(!has_tls_fallback(&parse_turn_urls("turn:a:3478?transport=udp")));
        assert!(parse_turn_urls(" , ").is_empty());
    }

    /// The handler never awaits (no DB) — run it in place, so the env lock
    /// isn't held across an await.
    fn block_on<F: std::future::Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().build().unwrap().block_on(f)
    }

    fn turn_query(seed: u8, ts: i64) -> TurnQuery {
        use ed25519_dalek::{Signer, SigningKey};
        use sha2::Digest;
        let sk = SigningKey::from_bytes(&[seed; 32]);
        let pk_hex = hex::encode(sk.verifying_key().to_bytes());
        let mut msg = CALL_TURN_DOMAIN.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&Sha256::digest(pk_hex.as_bytes()));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        TurnQuery {
            identity_pubkey_hex: pk_hex,
            request_ts: ts,
            request_proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes()),
        }
    }

    #[test]
    fn turn_response_carries_all_transports_and_valid_credentials() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("TURN_SHARED_SECRET", "turn-test-secret");
        std::env::set_var("TURN_URLS", INSTALLER_TURN_URLS);
        std::env::set_var("TURN_TTL_SECS", "3600");
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let res = block_on(mint_turn_creds(State(crate::tests::no_db_state()), Query(turn_query(5, now))));
        std::env::remove_var("TURN_SHARED_SECRET");
        std::env::remove_var("TURN_URLS");
        std::env::remove_var("TURN_TTL_SECS");
        let Json(r) = res.expect("mint");

        assert_eq!(r.urls.len(), 3);
        assert!(r.urls.iter().any(|u| u.starts_with("turn:") && u.ends_with("transport=udp")));
        assert!(r.urls.iter().any(|u| u.starts_with("turn:") && u.ends_with("transport=tcp")));
        assert!(r.urls.iter().any(|u| u.starts_with("turns:") && u.contains(":443")));
        assert!((3_600..=3_600 + 86_400).contains(&r.ttl_secs), "LIMIT-1: counted from the end of the day");
        // coturn REST-API: "<expiry>:<nonce>", credential = b64(HMAC-SHA1).
        let (expiry, nonce) = r.username.split_once(':').unwrap();
        let expiry: i64 = expiry.parse().unwrap();
        assert!((expiry - (now + r.ttl_secs)).abs() <= 2);
        assert_eq!(nonce.len(), 32);
        assert_eq!(r.credential, hmac_sha1_base64(b"turn-test-secret", r.username.as_bytes()));
    }

    #[test]
    fn turn_without_urls_is_misconfigured() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("TURN_SHARED_SECRET", "turn-test-secret");
        std::env::set_var("TURN_URLS", " , https://not-turn/ ");
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let res = block_on(mint_turn_creds(State(crate::tests::no_db_state()), Query(turn_query(6, now))));
        std::env::remove_var("TURN_SHARED_SECRET");
        std::env::remove_var("TURN_URLS");
        assert!(matches!(res, Err(CallError::Misconfigured(_))));
    }

    // server-http:4 — 150 requests naming my key with a junk proof are all
    // refused and no longer use up my bucket: my own request still works.
    #[test]
    fn junk_requests_in_my_name_do_not_lock_me_out_of_calls() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("TURN_SHARED_SECRET", "turn-test-secret");
        std::env::set_var("TURN_URLS", INSTALLER_TURN_URLS);
        let st = crate::tests::no_db_state();
        let now = OffsetDateTime::now_utc().unix_timestamp();
        for _ in 0..150 {
            let mut junk = turn_query(8, now);
            junk.request_proof_hex = hex::encode([0u8; 64]);
            assert!(matches!(block_on(mint_turn_creds(State(st.clone()), Query(junk))), Err(CallError::Unauthorized(_))));
        }
        let res = block_on(mint_turn_creds(State(st), Query(turn_query(8, now))));
        std::env::remove_var("TURN_SHARED_SECRET");
        std::env::remove_var("TURN_URLS");
        assert!(res.is_ok(), "my own request still goes through");
    }

    /// deploy-deps:3 — a fresh random username per mint: coturn could not
    /// cap one person, and one free account took every relay slot.
    #[test]
    fn one_persons_turn_names_share_one_quota_and_do_not_name_them() {
        let _g = ENV_LOCK.lock().unwrap();
        std::env::set_var("TURN_SHARED_SECRET", "turn-test-secret");
        std::env::set_var("TURN_URLS", INSTALLER_TURN_URLS);
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let tag = |seed: u8| {
            let res = block_on(mint_turn_creds(State(crate::tests::no_db_state()), Query(turn_query(seed, now))));
            res.unwrap().0.username.split_once(':').unwrap().1.to_string()
        };
        let (a1, a2, b) = (tag(5), tag(5), tag(6));
        std::env::remove_var("TURN_SHARED_SECRET");
        std::env::remove_var("TURN_URLS");
        assert_eq!(a1, a2, "one person, one coturn quota");
        assert_ne!(a1, b);
        assert!(!turn_query(5, now).identity_pubkey_hex.contains(&a1), "not the key");
        assert!(include_str!("../../turnserver.conf").contains("\nuser-quota="), "coturn caps each name");
    }

    /// LIMIT-1 — the username began with the second of the mint, so every
    /// mint was a new name for coturn and `user-quota` capped nothing.
    #[test]
    fn turn_username_is_the_same_all_day() {
        let day = 20_000 * 86_400;
        let (first, expiry) = turn_username(&[5; 32], day, 3_600);
        for now in [day + 1, day + 40_000, day + 86_399] {
            assert_eq!(turn_username(&[5; 32], now, 3_600).0, first, "one name, one coturn quota");
            assert!(expiry - now >= 3_600, "valid at least the configured time");
            assert!(expiry - now <= 3_600 + 86_400);
        }
        assert_eq!(first.split_once(':').unwrap().0, expiry.to_string(), "coturn reads the expiry first");
        assert_ne!(turn_username(&[5; 32], day + 86_400, 3_600).0, first, "a new name the next day");
        assert_ne!(turn_username(&[6; 32], day, 3_600).0, first, "another person, another name");
    }

    /// TURN credentials only for an account on this server: a new key
    /// nobody registered gets nothing (security review 2026-11-02).
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn turn_is_refused_to_unregistered_keys(pool: sqlx::PgPool) {
        let mut st = crate::tests::no_db_state();
        st.pool = Some(pool.clone());
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let q = turn_query(7, now);
        let pk = hex::decode(&q.identity_pubkey_hex).unwrap();
        let env = |on: bool| {
            if on {
                std::env::set_var("TURN_SHARED_SECRET", "turn-test-secret");
                std::env::set_var("TURN_URLS", INSTALLER_TURN_URLS);
            } else {
                std::env::remove_var("TURN_SHARED_SECRET");
                std::env::remove_var("TURN_URLS");
            }
        };
        {
            let _g = ENV_LOCK.lock().unwrap();
            env(true);
            let res = mint_turn_creds(State(st.clone()), Query(turn_query(7, now))).await;
            env(false);
            assert!(matches!(res, Err(CallError::Forbidden(_))), "unknown key refused");
        }
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(&pk)
            .execute(&pool)
            .await
            .unwrap();
        let _g = ENV_LOCK.lock().unwrap();
        env(true);
        let res = mint_turn_creds(State(st), Query(turn_query(7, now))).await;
        env(false);
        assert!(res.is_ok(), "a registered account gets credentials");
    }

    /// LIMIT-3 — the bucket was taken before the account check: every
    /// freshly made key left one in the map KeyPackage uploads share.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn only_an_account_has_a_call_bucket(pool: sqlx::PgPool) {
        use ed25519_dalek::{Signer, SigningKey};
        use sha2::Digest;
        let one = crate::rate_limit::RateConfig { capacity: 1, refill_per_sec: 0.0 };
        let mut st = crate::tests::no_db_state();
        st.pool = Some(pool.clone());
        st.rate = crate::rate_limit::RateLimiter::new(crate::rate_limit::RateDefaults {
            register: one,
            kp_upload: one,
            ws_submit: one,
            media_upload: one,
        });
        let now = OffsetDateTime::now_utc().unix_timestamp();
        let sk = SigningKey::from_bytes(&[9; 32]);
        let pk_hex = hex::encode(sk.verifying_key().to_bytes());
        let proof = |body: &str| {
            let mut msg = CALL_TOKEN_DOMAIN.to_vec();
            msg.push(b':');
            msg.extend_from_slice(&Sha256::digest(body.as_bytes()));
            msg.push(b':');
            msg.extend_from_slice(&now.to_be_bytes());
            hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&msg)).to_bytes())
        };
        // A key nobody registered: refused every time, never "rate limited"
        // (one token in the bucket — it had been used up by the first try).
        for _ in 0..3 {
            let token = TokenRequest {
                identity_pubkey_hex: pk_hex.clone(),
                group_id_hex: "aa".into(),
                kind: "audio".into(),
                request_ts: now,
                request_proof_hex: proof("aa:audio"),
            };
            assert!(matches!(mint_token(State(st.clone()), Json(token)).await, Err(CallError::Forbidden(_))));
            let live = LiveRequest {
                identity_pubkey_hex: pk_hex.clone(),
                group_id_hex: "aa".into(),
                request_ts: now,
                request_proof_hex: proof("aa:live"),
            };
            assert!(matches!(call_live(State(st.clone()), Json(live)).await, Err(CallError::Forbidden(_))));
            let turn = mint_turn_creds(State(st.clone()), Query(turn_query(9, now))).await;
            assert!(matches!(turn, Err(CallError::Forbidden(_))));
        }
        // With an account the limit is there as before.
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
            .bind(uuid::Uuid::now_v7())
            .bind(sk.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let _ = mint_turn_creds(State(st.clone()), Query(turn_query(9, now))).await;
        let again = mint_turn_creds(State(st), Query(turn_query(9, now))).await;
        assert!(matches!(again, Err(CallError::RateLimited { .. })));
    }

    /// Membership gate for /v1/call/token. Members of the group pass,
    /// a registered user outside it and an unknown key are refused.
    #[ignore = "requires DATABASE_URL"]
    #[sqlx::test(migrations = "./migrations")]
    async fn is_group_member_only_true_for_members(pool: sqlx::PgPool) {
        let alice_pk = [0xA1u8; 32];
        let mallory_pk = [0x66u8; 32];
        let group = b"group-1".to_vec();
        for (user_pk, identity, device) in [
            (uuid::Uuid::now_v7(), alice_pk, [0xD1u8; 32]),
            (uuid::Uuid::now_v7(), mallory_pk, [0xD6u8; 32]),
        ] {
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)")
                .bind(user_pk)
                .bind(&identity[..])
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $3)")
                .bind(&device[..])
                .bind(user_pk)
                .bind(&b"cred"[..])
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)")
            .bind(&group)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
            .bind(&group)
            .bind(&[0xD1u8; 32][..])
            .execute(&pool)
            .await
            .unwrap();

        assert!(is_group_member(&pool, &group, &alice_pk).await.unwrap());
        assert!(!is_group_member(&pool, &group, &mallory_pk).await.unwrap());
        assert!(!is_group_member(&pool, &group, &[0x00u8; 32]).await.unwrap());
        assert!(!is_group_member(&pool, b"other-group", &alice_pk).await.unwrap());
    }

    /// calls:4 — a removed member is taken out of the chat's call room (the
    /// room LiveKit names after the chat, the participant its device key);
    /// a kept-back token opens the room for 10 minutes, not an hour.
    #[tokio::test]
    async fn a_removed_member_is_taken_out_of_the_call_room() {
        use axum::{extract::Json as AxJson, http::HeaderMap, routing::post};
        let seen = std::sync::Arc::new(StdMutex::new(Vec::new()));
        let s = seen.clone();
        let app = axum::Router::new().route(
            "/twirp/livekit.RoomService/RemoveParticipant",
            post(move |h: HeaderMap, AxJson(v): AxJson<serde_json::Value>| async move {
                assert!(h.get("authorization").is_some_and(|a| a.to_str().unwrap().starts_with("Bearer ")));
                let found = v["identity"] == hex::encode([0xB0u8; 32]);
                s.lock().unwrap().push(v);
                if found { StatusCode::OK } else { StatusCode::NOT_FOUND }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let n = remove_participants(&url, "k", &"s".repeat(32), &[b"chat".to_vec()], &[vec![0xB0; 32], vec![0xB1; 32]]).await;
        assert_eq!(n, 1, "the one in the room");
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0], serde_json::json!({ "room": format!("sinhron-call-{}", hex::encode(b"chat")), "identity": hex::encode([0xB0u8; 32]) }));
        assert_eq!(seen.len(), 2);
        assert!(TOKEN_TTL_SECS <= 600);
    }
}
