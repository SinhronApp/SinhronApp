// Chat rosters on the server: who gets a chat's messages (fan-out), its
// card and its call room. The server can't read MLS, so the apps tell it.
//
// ADR-083 (security review 2026-11, server-http:1) — POST /v1/groups is
// signed by the device that announces (GROUP_ANNOUNCE_DOMAIN, body =
// group_id || be8(epoch) || each member device key). Into a chat that exists only a
// device of a person already in its roster adds devices — or a person whose
// device there was cut off re-announces just their new device (ADR-075). A
// new chat: the signer is one of its devices. An unsigned announce is
// refused (401; the transition switch went 2026-11-04, owner: all apps update
// together).
//
// Wire contract:
//
//   POST /v1/groups
//   {
//     "group_id_hex": "2-256 hex chars",        // opaque MLS group id
//     "creator_device_pk_hex": "64 hex chars",  // who created it
//     "member_device_pks_hex": ["64 hex", ...], // devices to add
//     "epoch": 1,                               // ADR-090, its MLS epoch now
//     "proof_ts", "proof_hex"                   // ADR-083, by the creator
//   }
//   → 201 with { group_id_hex, member_count }; 401 bad or missing proof,
//     403 not this device's chat
//
//   POST /v1/groups/{group_id_hex}/remove   (ADR-083)
//   { "identity_pubkey_hex", "member_identities_hex": [...], "proof_ts", "proof_hex" }
//   — a member's app, after its Commit removed these people, takes all
//   their devices out of the roster (and out of the chat's call room).
//   Body = group_id || each identity key (GROUP_REMOVE_DOMAIN).
//
//   PUT  /v1/groups/{group_id_hex}/card   (ADR-075)
//   { "device_pk_hex", "epoch", "card_b64", "proof_ts", "proof_hex" }
//   — a member's device leaves the chat's current MLS GroupInfo (public:
//   the tree's keys and devices, the epoch's external key). Signed by that
//   device's key (GROUP_CARD_PUT_DOMAIN, body = group_id || be8(epoch) ||
//   card); the device must be in the group; another epoch than the one
//   the server has ordered is refused (409). ADR-093 — each device keeps
//   its own card (server-http:10: nobody's card replaces another's).
//   POST /v1/groups/{group_id_hex}/card   (ADR-075)
//   { "device_pk_hex", "proof_ts", "proof_hex" }
//   → { cards: [{ epoch, card_b64, identity_hex }] }
//   — fetched by an active device of a person who has a device in the
//   group, or had one there that was cut off: their new phone joins by an
//   external commit. Signed by that device (GROUP_CARD_GET_DOMAIN, body =
//   group_id). ADR-093 — the card of each of the chat's active devices,
//   newest epoch first, each with its person: the phone picks the one its
//   own person or most people left. 404 when there is none.
//
//   PUT /v1/groups/{group_id_hex}/retention   (tech-debt 2.5)
//   { "identity_pubkey_hex", "after_secs" (0 = off), "proof_ts", "proof_hex" }
//   — a member sets how long the server keeps the chat's stored
//   ciphertexts (`mls_groups.disappearing_after_secs`, swept by
//   `retention.rs`). Action proof by the identity key, domain
//   GROUP_RETENTION_DOMAIN, body = group_id || be8(after_secs).

use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Json, Response},
};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use tracing::{error, info};

use super::proof::{
    self, GROUP_ANNOUNCE_DOMAIN, GROUP_CARD_GET_DOMAIN, GROUP_CARD_PUT_DOMAIN, GROUP_LEAVE_DOMAIN, GROUP_REMOVE_DOMAIN,
    GROUP_RETENTION_DOMAIN,
};
use crate::rate_limit::StaticLimiter;
use crate::AppState;

/// GRP-3 — announces, card uploads and card fetches of one device, each
/// counted apart: 600 an hour (a restored phone enters a few hundred chats
/// at once).
static PER_DEVICE: StaticLimiter = StaticLimiter::new("SINHRON_RATE_GROUPS", 600, 3_600);

/// GRP-3 — most chats one device may have created. Nothing sweeps
/// `mls_groups`, and every chat holds a card of up to 256 KB per device.
pub const MAX_CHATS_PER_DEVICE: i64 = 1000;

/// GRP-3 — most cards one fetch returns (the phone weighs the two newest
/// epochs); the whole roster's used to come back at once.
pub const MAX_CARDS_PER_FETCH: i64 = 32;

/// GRP-3 — called once the signature is checked, so the key is a real one.
fn limit(route: &str, device: &[u8]) -> Result<(), GroupError> {
    PER_DEVICE.check(&format!("{route}:{}", hex::encode(device))).map_err(|_| {
        crate::metrics::RATE_LIMIT_HITS_TOTAL.with_label_values(&[route]).inc();
        GroupError::RateLimited
    })
}

/// Longest server-side chat timer (the client offers up to a week).
pub const MAX_RETENTION_SECS: i64 = 30 * 24 * 3600;

/// Most devices in one announced roster: a big family chat (32 people,
/// each with a phone and a few linked devices) fits several times over.
pub const MAX_GROUP_DEVICES: usize = 512;

#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub group_id_hex: String,
    pub creator_device_pk_hex: String,
    pub member_device_pks_hex: Vec<String>,
    /// ADR-090 — the chat's MLS epoch on the announcing device: where the
    /// server starts ordering a new chat's Commits (ignored for one it has).
    pub epoch: i64,
    /// ADR-083 — action proof by the creator device. Absent: an older app.
    #[serde(default)]
    pub proof_ts: Option<i64>,
    #[serde(default)]
    pub proof_hex: Option<String>,
}

/// ADR-083 — what an announce signs: group_id || be8(epoch) (ADR-090) ||
/// each member device key.
pub fn announce_body(group_id: &[u8], epoch: i64, members: &[Vec<u8>]) -> Vec<u8> {
    let mut b = group_id.to_vec();
    b.extend_from_slice(&epoch.to_be_bytes());
    members.iter().for_each(|m| b.extend_from_slice(m));
    b
}

#[derive(Debug, Serialize)]
pub struct CreateGroupResponse {
    pub group_id_hex: String,
    pub member_count: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum GroupError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("rate limited")]
    RateLimited,
    #[error("no db configured")]
    NoDb,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
}

impl IntoResponse for GroupError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            GroupError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            GroupError::NotFound(m) => (StatusCode::NOT_FOUND, m.clone()),
            GroupError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            GroupError::Forbidden(m) => (StatusCode::FORBIDDEN, m.clone()),
            GroupError::Conflict(m) => (StatusCode::CONFLICT, m.clone()),
            GroupError::RateLimited => (StatusCode::TOO_MANY_REQUESTS, "rate limited".to_string()),
            GroupError::NoDb => (
                StatusCode::SERVICE_UNAVAILABLE,
                "no database configured".to_string(),
            ),
            GroupError::Db(e) => {
                error!(error = %e, "db error in groups handler");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

pub async fn create(
    State(state): State<AppState>,
    Json(req): Json<CreateGroupRequest>,
) -> Result<(StatusCode, Json<CreateGroupResponse>), GroupError> {
    let pool = state.pool.ok_or(GroupError::NoDb)?;

    let group_id = hex::decode(&req.group_id_hex)
        .map_err(|e| GroupError::BadRequest(format!("group_id_hex: {e}")))?;
    if group_id.is_empty() || group_id.len() > 128 {
        return Err(GroupError::BadRequest(format!(
            "group_id must be 1..=128 bytes, got {}",
            group_id.len()
        )));
    }

    let creator = hex::decode(&req.creator_device_pk_hex)
        .map_err(|e| GroupError::BadRequest(format!("creator_device_pk_hex: {e}")))?;
    if creator.len() != 32 {
        return Err(GroupError::BadRequest(format!(
            "creator_device_pk must be 32 bytes, got {}",
            creator.len()
        )));
    }

    // 31 000 copies of one device were 62 000 queries holding a database
    // connection for seconds; 16 such requests stopped the server
    // (docs/security-review-2026-11.md, server-http:3). Capped, and one
    // query each below.
    if req.member_device_pks_hex.len() > MAX_GROUP_DEVICES {
        return Err(GroupError::BadRequest(format!("at most {MAX_GROUP_DEVICES} devices")));
    }
    let mut members: Vec<Vec<u8>> = Vec::with_capacity(req.member_device_pks_hex.len());
    for (i, h) in req.member_device_pks_hex.iter().enumerate() {
        let bytes = hex::decode(h)
            .map_err(|e| GroupError::BadRequest(format!("member[{i}]: {e}")))?;
        if bytes.len() != 32 {
            return Err(GroupError::BadRequest(format!(
                "member[{i}] must be 32 bytes, got {}",
                bytes.len()
            )));
        }
        members.push(bytes);
    }
    if members.is_empty() || req.epoch < 0 {
        return Err(GroupError::BadRequest(
            "at least one member and an epoch ≥ 0 required".to_string(),
        ));
    }
    // ADR-083 — anyone who knew a chat's id put their device into it
    // (security review 2026-11, server-http:1).
    match (req.proof_ts, req.proof_hex.as_deref()) {
        (Some(ts), Some(h)) => {
            let sig = hex::decode(h).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
            let now = OffsetDateTime::now_utc().unix_timestamp();
            proof::verify_action_proof(GROUP_ANNOUNCE_DOMAIN, &creator, &announce_body(&group_id, req.epoch, &members), ts, &sig, now)
                .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
        }
        _ => return Err(GroupError::Unauthorized("the announce must be signed by its device".into())),
    }
    limit("group_announce", &creator)?;

    let mut tx = pool.begin().await?;

    // Sanity: every device referenced must be registered. Otherwise the
    // FK on group_members would surface as a cryptic Postgres error.
    let mut all = members.clone();
    all.push(creator.clone());
    let known: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT device_pk FROM devices WHERE device_pk = ANY($1)")
        .bind(&all)
        .fetch_all(&mut *tx)
        .await?;
    if let Some(d) = all.iter().find(|d| !known.iter().any(|(k,)| k == *d)) {
        return Err(GroupError::NotFound(format!("device {} not registered", hex::encode(d))));
    }

    // ADR-083 — a chat that exists: the creator's person is in its roster,
    // or had a device there that was cut off and adds only this one
    // (ADR-075). A new chat: the creator is one of its devices.
    let (exists, in_roster, was_here, active, created): (bool, bool, bool, bool, i64) = sqlx::query_as(
        "SELECT EXISTS (SELECT 1 FROM mls_groups WHERE group_id = $1), \
           EXISTS (SELECT 1 FROM group_members gm JOIN devices d ON d.device_pk = gm.device_pk \
                   JOIN devices me ON me.user_pk = d.user_pk \
                   WHERE gm.group_id = $1 AND me.device_pk = $2 AND d.revoked_at IS NULL), \
           EXISTS (SELECT 1 FROM group_former_devices f JOIN devices d ON d.device_pk = f.device_pk \
                   JOIN devices me ON me.user_pk = d.user_pk WHERE f.group_id = $1 AND me.device_pk = $2), \
           EXISTS (SELECT 1 FROM devices WHERE device_pk = $2 AND revoked_at IS NULL), \
           (SELECT count(*) FROM mls_groups WHERE created_by_device_pk = $2)",
    )
    .bind(&group_id)
    .bind(&creator)
    .fetch_one(&mut *tx)
    .await?;
    let allowed = if exists {
        in_roster || (was_here && members.iter().all(|m| *m == creator))
    } else {
        members.contains(&creator)
    };
    if !active || !allowed {
        return Err(GroupError::Forbidden("not this device's chat".into()));
    }
    // GRP-3 — one account made chats (and a 256 KB card in each) without end.
    if !exists && created >= MAX_CHATS_PER_DEVICE {
        return Err(GroupError::Forbidden("too many chats made by this device".into()));
    }

    // Upsert mls_groups row. Idempotent — re-POSTing same group is a no-op.
    // ADR-090 — a new chat starts at the creator's epoch (1 after its first
    // Add, merged without a Submit; 0 for "Saved messages").
    sqlx::query(
        "INSERT INTO mls_groups \
         (group_id, created_by_device_pk, created_at, current_epoch) \
         VALUES ($1, $2, NOW(), $3) \
         ON CONFLICT (group_id) DO NOTHING",
    )
    .bind(&group_id)
    .bind(&creator)
    .bind(req.epoch)
    .execute(&mut *tx)
    .await?;

    // Upsert each member. epoch = 0 (initial roster).
    sqlx::query(
        "INSERT INTO group_members (group_id, device_pk, joined_at_epoch) \
         SELECT $1, d, 0 FROM UNNEST($2::bytea[]) AS d \
         ON CONFLICT (group_id, device_pk) DO NOTHING",
    )
    .bind(&group_id)
    .bind(&members)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    info!(
        group = %crate::short_key(&req.group_id_hex),
        member_count = members.len(),
        "group announced"
    );
    Ok((
        StatusCode::CREATED,
        Json(CreateGroupResponse {
            group_id_hex: req.group_id_hex,
            member_count: members.len(),
        }),
    ))
}

#[derive(Debug, Deserialize)]
pub struct RetentionRequest {
    pub identity_pubkey_hex: String,
    /// Seconds; 0 turns the server-side timer off.
    pub after_secs: i64,
    pub proof_ts: i64,
    pub proof_hex: String,
}

/// Signed body of a retention change: `group_id || be8(after_secs)`.
pub fn retention_body(group_id: &[u8], after_secs: i64) -> Vec<u8> {
    let mut b = group_id.to_vec();
    b.extend_from_slice(&after_secs.to_be_bytes());
    b
}

/// Tech-debt 2.5 — a member sets the chat's server-side timer.
pub async fn set_retention(
    State(state): State<AppState>,
    Path(group_id_hex): Path<String>,
    Json(req): Json<RetentionRequest>,
) -> Result<StatusCode, GroupError> {
    let pool = state.pool.ok_or(GroupError::NoDb)?;
    let group_id = hex::decode(&group_id_hex).map_err(|e| GroupError::BadRequest(format!("group_id: {e}")))?;
    let identity = hex::decode(&req.identity_pubkey_hex).map_err(|e| GroupError::BadRequest(format!("identity: {e}")))?;
    if !(0..=MAX_RETENTION_SECS).contains(&req.after_secs) {
        return Err(GroupError::BadRequest(format!("after_secs must be 0..={MAX_RETENTION_SECS}")));
    }
    let sig = hex::decode(&req.proof_hex).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        GROUP_RETENTION_DOMAIN,
        &identity,
        &retention_body(&group_id, req.after_secs),
        req.proof_ts,
        &sig,
        OffsetDateTime::now_utc().unix_timestamp(),
    )
    .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
    // ADR-027 — signed by the identity key or an active linked device.
    let Some((_, identity)) = crate::accounts::resolve_signer(&pool, &identity).await? else {
        return Err(GroupError::Unauthorized("unknown signer".into()));
    };

    let member: Option<(i32,)> = sqlx::query_as(
        "SELECT 1 FROM group_members gm \
         JOIN devices d ON d.device_pk = gm.device_pk \
         JOIN users u ON u.user_pk = d.user_pk \
         WHERE gm.group_id = $1 AND u.identity_pubkey = $2 AND d.revoked_at IS NULL LIMIT 1",
    )
    .bind(&group_id)
    .bind(&identity)
    .fetch_optional(&pool)
    .await?;
    if member.is_none() {
        return Err(GroupError::Forbidden("not a member of this group".into()));
    }
    sqlx::query("UPDATE mls_groups SET disappearing_after_secs = $2 WHERE group_id = $1")
        .bind(&group_id)
        .bind((req.after_secs > 0).then_some(req.after_secs))
        .execute(&pool)
        .await?;
    info!(group = %crate::short_key(&group_id_hex), after_secs = req.after_secs, "chat retention set");
    Ok(StatusCode::NO_CONTENT)
}

/// ADR-075 — the largest card the server keeps (a GroupInfo with the tree:
/// ~0.6 KB per leaf; 256 KB is a few hundred devices).
pub const MAX_CARD_BYTES: usize = 256 * 1024;

#[derive(Debug, Deserialize)]
pub struct PutCardRequest {
    pub device_pk_hex: String,
    pub epoch: i64,
    pub card_b64: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

/// ADR-075 — what a card upload signs: group_id || be8(epoch) || card.
pub fn card_body(group_id: &[u8], epoch: i64, card: &[u8]) -> Vec<u8> {
    let mut b = Vec::with_capacity(group_id.len() + 8 + card.len());
    b.extend_from_slice(group_id);
    b.extend_from_slice(&epoch.to_be_bytes());
    b.extend_from_slice(card);
    b
}

/// ADR-075 — `PUT /v1/groups/{group_id_hex}/card`.
pub async fn put_card(
    State(state): State<AppState>,
    Path(group_id_hex): Path<String>,
    Json(req): Json<PutCardRequest>,
) -> Result<StatusCode, GroupError> {
    use base64::Engine;
    let pool = state.pool.ok_or(GroupError::NoDb)?;
    let group_id = hex::decode(&group_id_hex).map_err(|e| GroupError::BadRequest(format!("group_id: {e}")))?;
    let device = hex::decode(&req.device_pk_hex).map_err(|e| GroupError::BadRequest(format!("device_pk: {e}")))?;
    let card = base64::engine::general_purpose::STANDARD
        .decode(&req.card_b64)
        .map_err(|e| GroupError::BadRequest(format!("card_b64: {e}")))?;
    if card.is_empty() || card.len() > MAX_CARD_BYTES || req.epoch < 0 {
        return Err(GroupError::BadRequest(format!("card must be 1..={MAX_CARD_BYTES} bytes, epoch ≥ 0")));
    }
    let sig = hex::decode(&req.proof_hex).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        GROUP_CARD_PUT_DOMAIN,
        &device,
        &card_body(&group_id, req.epoch, &card),
        req.proof_ts,
        &sig,
        OffsetDateTime::now_utc().unix_timestamp(),
    )
    .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
    limit("group_card_put", &device)?;
    let member: Option<(i64,)> = sqlx::query_as(
        "SELECT g.current_epoch FROM group_members gm \
         JOIN devices d ON d.device_pk = gm.device_pk \
         JOIN mls_groups g ON g.group_id = gm.group_id \
         WHERE gm.group_id = $1 AND gm.device_pk = $2 AND d.revoked_at IS NULL",
    )
    .bind(&group_id)
    .bind(&device)
    .fetch_optional(&pool)
    .await?;
    let Some((current,)) = member else {
        return Err(GroupError::Forbidden("this device is not in the group".into()));
    };
    // Only the group's own epoch: a card from the future (epoch 2^62) used to
    // lock every later card out (security review 2026-11-02).
    if req.epoch != current {
        return Err(GroupError::Conflict(format!("card for epoch {}, group is at {current}", req.epoch)));
    }
    // ADR-093 (server-http:10) — one card per chat let a member's garbage
    // card stand for the epoch. Each device keeps its own; a new phone reads
    // them all and trusts the one its person or most people left.
    sqlx::query(
        "INSERT INTO group_cards (group_id, device_pk, epoch, card) VALUES ($1, $2, $3, $4) \
         ON CONFLICT (group_id, device_pk) DO UPDATE SET epoch = EXCLUDED.epoch, card = EXCLUDED.card, updated_at = NOW()",
    )
    .bind(&group_id)
    .bind(&device)
    .bind(req.epoch)
    .bind(&card)
    .execute(&pool)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Debug, Deserialize)]
pub struct GetCardRequest {
    pub device_pk_hex: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct CardResponse {
    pub cards: Vec<CardEntry>,
}

/// ADR-093 — one device's card, with the identity key of its person.
#[derive(Debug, Serialize)]
pub struct CardEntry {
    pub epoch: i64,
    pub card_b64: String,
    pub identity_hex: String,
}

/// ADR-075 — `POST /v1/groups/{group_id_hex}/card`.
pub async fn get_card(
    State(state): State<AppState>,
    Path(group_id_hex): Path<String>,
    Json(req): Json<GetCardRequest>,
) -> Result<Json<CardResponse>, GroupError> {
    use base64::Engine;
    let pool = state.pool.ok_or(GroupError::NoDb)?;
    let group_id = hex::decode(&group_id_hex).map_err(|e| GroupError::BadRequest(format!("group_id: {e}")))?;
    let device = hex::decode(&req.device_pk_hex).map_err(|e| GroupError::BadRequest(format!("device_pk: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        GROUP_CARD_GET_DOMAIN,
        &device,
        &group_id,
        req.proof_ts,
        &sig,
        OffsetDateTime::now_utc().unix_timestamp(),
    )
    .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
    limit("group_card_get", &device)?;
    // The fetching device is active, and its person is in the group — or
    // was, through a device they cut off.
    let allowed: Option<(uuid::Uuid,)> = sqlx::query_as(
        "SELECT me.user_pk FROM devices me WHERE me.device_pk = $2 AND me.revoked_at IS NULL AND ( \
           EXISTS (SELECT 1 FROM group_members gm JOIN devices d ON d.device_pk = gm.device_pk \
                   WHERE gm.group_id = $1 AND d.user_pk = me.user_pk AND d.revoked_at IS NULL) \
        OR EXISTS (SELECT 1 FROM group_former_devices f JOIN devices d ON d.device_pk = f.device_pk \
                   WHERE f.group_id = $1 AND d.user_pk = me.user_pk))",
    )
    .bind(&group_id)
    .bind(&device)
    .fetch_optional(&pool)
    .await?;
    let Some((me,)) = allowed else {
        return Err(GroupError::Forbidden("not this person's chat".into()));
    };
    // ADR-093 — each active device's card, newest epoch first; the phone
    // weighs them (it counts only the two newest epochs). GRP-3 — at most
    // MAX_CARDS_PER_FETCH (a 249-byte request used to bring megabytes back),
    // the fetching person's own first within an epoch.
    let rows: Vec<(i64, Vec<u8>, Vec<u8>)> = sqlx::query_as(
        "SELECT c.epoch, c.card, u.identity_pubkey FROM group_cards c \
         JOIN group_members gm ON gm.group_id = c.group_id AND gm.device_pk = c.device_pk \
         JOIN devices d ON d.device_pk = c.device_pk AND d.revoked_at IS NULL \
         JOIN users u ON u.user_pk = d.user_pk \
         WHERE c.group_id = $1 ORDER BY c.epoch DESC, (d.user_pk = $2) DESC, c.updated_at LIMIT $3",
    )
    .bind(&group_id)
    .bind(me)
    .bind(MAX_CARDS_PER_FETCH)
    .fetch_all(&pool)
    .await?;
    if rows.is_empty() {
        return Err(GroupError::NotFound("no card for this group yet".into()));
    }
    let cards = rows
        .into_iter()
        .map(|(epoch, card, identity)| CardEntry {
            epoch,
            card_b64: base64::engine::general_purpose::STANDARD.encode(card),
            identity_hex: hex::encode(identity),
        })
        .collect();
    Ok(Json(CardResponse { cards }))
}

/// ADR-035 — body of `POST /v1/groups/{id}/leave`.
#[derive(Debug, serde::Deserialize)]
pub struct LeaveRequest {
    pub identity_pubkey_hex: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

/// ADR-035 — `POST /v1/groups/{group_id_hex}/leave`: the signer's devices
/// stop receiving this group's messages (they left, or the group removed
/// them in MLS and their app noticed). Only yourself — nobody can take
/// someone else out of the fan-out. Idempotent: 204 also when already out.
/// GRP-10 — like `/remove`, it also closes the way back in by the card for
/// their cut-off phones and takes their devices out of the chat's call.
pub async fn leave(
    State(state): State<AppState>,
    Path(group_id_hex): Path<String>,
    Json(req): Json<LeaveRequest>,
) -> Result<StatusCode, GroupError> {
    let pool = state.pool.ok_or(GroupError::NoDb)?;
    let group_id = hex::decode(&group_id_hex).map_err(|e| GroupError::BadRequest(format!("group_id: {e}")))?;
    let signer = hex::decode(&req.identity_pubkey_hex).map_err(|e| GroupError::BadRequest(format!("identity: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        GROUP_LEAVE_DOMAIN,
        &signer,
        &group_id,
        req.proof_ts,
        &sig,
        OffsetDateTime::now_utc().unix_timestamp(),
    )
    .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
    let Some((_, identity)) = crate::accounts::resolve_signer(&pool, &signer).await? else {
        return Err(GroupError::Unauthorized("unknown signer".into()));
    };
    let gone: Vec<(Vec<u8>,)> = sqlx::query_as(
        "DELETE FROM group_members gm USING devices d, users u \
         WHERE gm.group_id = $1 AND gm.device_pk = d.device_pk AND d.user_pk = u.user_pk \
         AND u.identity_pubkey = $2 RETURNING gm.device_pk",
    )
    .bind(&group_id)
    .bind(&identity)
    .fetch_all(&pool)
    .await?;
    sqlx::query(
        "DELETE FROM group_former_devices f USING devices d, users u \
         WHERE f.group_id = $1 AND f.device_pk = d.device_pk AND d.user_pk = u.user_pk \
         AND u.identity_pubkey = $2",
    )
    .bind(&group_id)
    .bind(&identity)
    .execute(&pool)
    .await?;
    info!(group = %crate::short_key(&group_id_hex), devices = gone.len(), "left group");
    super::call::evict_from_calls(vec![group_id], gone.into_iter().map(|(d,)| d).collect());
    Ok(StatusCode::NO_CONTENT)
}

/// ADR-083 — body of `POST /v1/groups/{id}/remove`.
#[derive(Debug, Deserialize)]
pub struct RemoveRequest {
    pub identity_pubkey_hex: String,
    pub member_identities_hex: Vec<String>,
    pub proof_ts: i64,
    pub proof_hex: String,
}

/// ADR-083 — what a removal signs: group_id || each identity key.
pub fn remove_body(group_id: &[u8], people: &[Vec<u8>]) -> Vec<u8> {
    let mut b = group_id.to_vec();
    people.iter().for_each(|m| b.extend_from_slice(m));
    b
}

/// ADR-083 — `POST /v1/groups/{group_id_hex}/remove`: a member whose
/// Commit removed these people takes their devices out of the roster, so
/// they stop getting the chat's Commits, card, invites and call room
/// (security review 2026-11, critic:5). The server can't check the Commit:
/// any member could already remove anyone in MLS. Idempotent.
pub async fn remove(
    State(state): State<AppState>,
    Path(group_id_hex): Path<String>,
    Json(req): Json<RemoveRequest>,
) -> Result<StatusCode, GroupError> {
    let pool = state.pool.ok_or(GroupError::NoDb)?;
    let group_id = hex::decode(&group_id_hex).map_err(|e| GroupError::BadRequest(format!("group_id: {e}")))?;
    let signer = hex::decode(&req.identity_pubkey_hex).map_err(|e| GroupError::BadRequest(format!("identity: {e}")))?;
    if req.member_identities_hex.is_empty() || req.member_identities_hex.len() > MAX_GROUP_DEVICES {
        return Err(GroupError::BadRequest(format!("1..={MAX_GROUP_DEVICES} people")));
    }
    let people = req
        .member_identities_hex
        .iter()
        .map(|h| hex::decode(h).ok().filter(|b| b.len() == 32))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| GroupError::BadRequest("member_identities_hex: 64 hex each".into()))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    proof::verify_action_proof(GROUP_REMOVE_DOMAIN, &signer, &remove_body(&group_id, &people), req.proof_ts, &sig, now)
        .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
    let Some((signer_user, _)) = crate::accounts::resolve_signer(&pool, &signer).await? else {
        return Err(GroupError::Unauthorized("unknown signer".into()));
    };
    let mut tx = pool.begin().await?;
    let (member,): (bool,) = sqlx::query_as(
        "SELECT EXISTS (SELECT 1 FROM group_members gm JOIN devices d ON d.device_pk = gm.device_pk \
         WHERE gm.group_id = $1 AND d.user_pk = $2 AND d.revoked_at IS NULL)",
    )
    .bind(&group_id)
    .bind(signer_user)
    .fetch_one(&mut *tx)
    .await?;
    if !member {
        return Err(GroupError::Forbidden("not a member of this group".into()));
    }
    let gone: Vec<(Vec<u8>,)> = sqlx::query_as(
        "DELETE FROM group_members gm USING devices d, users u \
         WHERE gm.group_id = $1 AND gm.device_pk = d.device_pk AND d.user_pk = u.user_pk \
         AND u.identity_pubkey = ANY($2) RETURNING gm.device_pk",
    )
    .bind(&group_id)
    .bind(&people)
    .fetch_all(&mut *tx)
    .await?;
    // Their cut-off phones no longer open the way back in by the card.
    sqlx::query(
        "DELETE FROM group_former_devices f USING devices d, users u \
         WHERE f.group_id = $1 AND f.device_pk = d.device_pk AND d.user_pk = u.user_pk \
         AND u.identity_pubkey = ANY($2)",
    )
    .bind(&group_id)
    .bind(&people)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    let devices: Vec<Vec<u8>> = gone.into_iter().map(|(d,)| d).collect();
    info!(group = %crate::short_key(&group_id_hex), devices = devices.len(), "removed from group");
    super::call::evict_from_calls(vec![group_id], devices);
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod leave_tests {
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

    fn req(sk: &SigningKey, group: &[u8]) -> LeaveRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = GROUP_LEAVE_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(group));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        LeaveRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn only_you_take_yourself_out_of_a_group(pool: sqlx::PgPool) {
        let group = b"leave-group".to_vec();
        let alice = SigningKey::from_bytes(&[41u8; 32]);
        let bob = SigningKey::from_bytes(&[42u8; 32]);
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        for sk in [&alice, &bob] {
            let u = uuid::Uuid::now_v7();
            let pk = sk.verifying_key().to_bytes().to_vec();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
                .bind(&group)
                .bind(&pk)
                .execute(&pool)
                .await
                .unwrap();
        }
        let count = |pk: Vec<u8>| {
            let pool = pool.clone();
            let group = group.clone();
            async move {
                let (n,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM group_members WHERE group_id = $1 AND device_pk = $2")
                    .bind(&group)
                    .bind(pk)
                    .fetch_one(&pool)
                    .await
                    .unwrap();
                n
            }
        };
        // GRP-10 — each has a cut-off old phone that was in the chat.
        for (sk, old) in [(&alice, [43u8; 32]), (&bob, [44u8; 32])] {
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential, revoked_at) SELECT $1, user_pk, $1, NOW() FROM devices WHERE device_pk = $2")
                .bind(&old[..])
                .bind(sk.verifying_key().to_bytes().to_vec())
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO group_former_devices (group_id, device_pk) VALUES ($1, $2)").bind(&group).bind(&old[..]).execute(&pool).await.unwrap();
        }
        let path = || Path(hex::encode(&group));
        // Bob can't take Alice out (a forged request fails the signature).
        let mut forged = req(&bob, &group);
        forged.identity_pubkey_hex = hex::encode(alice.verifying_key().to_bytes());
        assert!(matches!(leave(State(state(pool.clone())), path(), Json(forged)).await, Err(GroupError::Unauthorized(_))));
        assert_eq!(count(alice.verifying_key().to_bytes().to_vec()).await, 1);
        // Alice leaves; Bob stays; leaving twice is fine.
        assert_eq!(leave(State(state(pool.clone())), path(), Json(req(&alice, &group))).await.unwrap(), StatusCode::NO_CONTENT);
        assert_eq!(count(alice.verifying_key().to_bytes().to_vec()).await, 0);
        assert_eq!(count(bob.verifying_key().to_bytes().to_vec()).await, 1);
        // Her cut-off phone no longer opens the way back in; Bob's still does.
        let former: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT device_pk FROM group_former_devices WHERE group_id = $1").bind(&group).fetch_all(&pool).await.unwrap();
        assert_eq!(former, vec![(vec![44u8; 32],)]);
        assert_eq!(leave(State(state(pool.clone())), path(), Json(req(&alice, &group))).await.unwrap(), StatusCode::NO_CONTENT);
    }
}

#[cfg(test)]
mod retention_tests {
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

    fn req(sk: &SigningKey, group: &[u8], secs: i64) -> RetentionRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = GROUP_RETENTION_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(retention_body(group, secs)));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        RetentionRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            after_secs: secs,
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn members_set_the_server_side_timer_and_the_sweep_uses_it(pool: sqlx::PgPool) {
        let group = b"timer-group".to_vec();
        let alice = SigningKey::from_bytes(&[31u8; 32]);
        let mallory = SigningKey::from_bytes(&[32u8; 32]);
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        for sk in [&alice, &mallory] {
            let u = uuid::Uuid::now_v7();
            let pk = sk.verifying_key().to_bytes().to_vec();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
        }
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
            .bind(&group)
            .bind(alice.verifying_key().to_bytes().to_vec())
            .execute(&pool)
            .await
            .unwrap();
        let path = || Path(hex::encode(&group));
        let secs = || async {
            let (v,): (Option<i64>,) = sqlx::query_as("SELECT disappearing_after_secs FROM mls_groups WHERE group_id = $1")
                .bind(&group)
                .fetch_one(&pool)
                .await
                .unwrap();
            v
        };

        // A non-member can't; a bad signature can't; out of range can't.
        assert!(matches!(set_retention(State(state(pool.clone())), path(), Json(req(&mallory, &group, 60))).await, Err(GroupError::Forbidden(_))));
        let mut forged = req(&mallory, &group, 60);
        forged.identity_pubkey_hex = hex::encode(alice.verifying_key().to_bytes());
        assert!(matches!(set_retention(State(state(pool.clone())), path(), Json(forged)).await, Err(GroupError::Unauthorized(_))));
        assert!(matches!(
            set_retention(State(state(pool.clone())), path(), Json(req(&alice, &group, MAX_RETENTION_SECS + 1))).await,
            Err(GroupError::BadRequest(_))
        ));
        assert_eq!(secs().await, None);

        set_retention(State(state(pool.clone())), path(), Json(req(&alice, &group, 3600))).await.unwrap();
        assert_eq!(secs().await, Some(3600));

        // The sweep deletes the chat's stored ciphertexts older than that.
        let alice_pk = alice.verifying_key().to_bytes().to_vec();
        for (age_secs, id) in [(7200i64, 1u8), (60, 2)] {
            sqlx::query(
                "INSERT INTO messages (message_id, group_id, sender_device_pk, ciphertext, ts) \
                 VALUES ($1, $2, $3, $4, NOW() - make_interval(secs => $5::double precision))",
            )
            .bind(uuid::Uuid::now_v7())
            .bind(&group)
            .bind(&alice_pk)
            .bind(vec![id])
            .bind(age_secs as f64)
            .execute(&pool)
            .await
            .unwrap();
        }
        // An hour-old message that one recipient hasn't received yet stays:
        // the timer counts from delivery (ADR-020).
        let pending = uuid::Uuid::now_v7();
        sqlx::query(
            "INSERT INTO messages (message_id, group_id, sender_device_pk, ciphertext, ts) \
             VALUES ($1, $2, $3, $4, NOW() - interval '2 hours')",
        )
        .bind(pending)
        .bind(&group)
        .bind(&alice_pk)
        .bind(vec![3u8])
        .execute(&pool)
        .await
        .unwrap();
        let (mallory_user,): (uuid::Uuid,) = sqlx::query_as("SELECT user_pk FROM users WHERE identity_pubkey = $1")
            .bind(mallory.verifying_key().to_bytes().to_vec())
            .fetch_one(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO message_deliveries (recipient_user_pk, message_id) VALUES ($1, $2)")
            .bind(mallory_user)
            .bind(pending)
            .execute(&pool)
            .await
            .unwrap();
        crate::retention::sweep(&pool, 30).await.unwrap();
        let (left,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages WHERE group_id = $1").bind(&group).fetch_one(&pool).await.unwrap();
        assert_eq!(left, 2, "the delivered hour-old message is gone; the minute-old and the undelivered stay");
        // Received two hours ago → its timer has run out too.
        sqlx::query("UPDATE message_deliveries SET received_at = NOW() - interval '2 hours' WHERE message_id = $1")
            .bind(pending)
            .execute(&pool)
            .await
            .unwrap();
        crate::retention::sweep(&pool, 30).await.unwrap();
        let (left,): (i64,) = sqlx::query_as("SELECT count(*) FROM messages WHERE group_id = $1").bind(&group).fetch_one(&pool).await.unwrap();
        assert_eq!(left, 1);

        // 0 turns it off.
        set_retention(State(state(pool.clone())), path(), Json(req(&alice, &group, 0))).await.unwrap();
        assert_eq!(secs().await, None);
    }
}

/// ADR-083 — who may put devices into a chat's roster (security review
/// 2026-11, server-http:1; old P0 #4).
#[cfg(test)]
mod announce_tests {
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

    /// A person with one device (its key is the identity key, as on a first phone).
    async fn person(pool: &sqlx::PgPool, seed: u8) -> SigningKey {
        let sk = SigningKey::from_bytes(&[seed; 32]);
        let pk = sk.verifying_key().to_bytes().to_vec();
        let u = uuid::Uuid::now_v7();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(pool).await.unwrap();
        sk
    }

    fn pk(sk: &SigningKey) -> Vec<u8> {
        sk.verifying_key().to_bytes().to_vec()
    }

    /// An announce by [signer] naming [creator], signed unless [signed] is false.
    fn announce(signer: &SigningKey, creator: &SigningKey, group: &[u8], members: &[&SigningKey], signed: bool) -> CreateGroupRequest {
        let members: Vec<Vec<u8>> = members.iter().map(|m| pk(m)).collect();
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = b"sinhron-group-announce-v1:".to_vec();
        m.push(b':');
        let body = announce_body(group, 1, &members);
        m.extend_from_slice(&Sha256::digest(&body));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        let mut j = serde_json::json!({
            "group_id_hex": hex::encode(group),
            "creator_device_pk_hex": hex::encode(pk(creator)),
            "member_device_pks_hex": members.iter().map(hex::encode).collect::<Vec<_>>(),
            "epoch": 1,
        });
        if signed {
            j["proof_ts"] = ts.into();
            j["proof_hex"] = hex::encode(signer.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()).into();
        }
        serde_json::from_value(j).unwrap()
    }

    async fn roster(pool: &sqlx::PgPool, group: &[u8]) -> Vec<Vec<u8>> {
        let rows: Vec<(Vec<u8>,)> = sqlx::query_as("SELECT device_pk FROM group_members WHERE group_id = $1 ORDER BY device_pk")
            .bind(group)
            .fetch_all(pool)
            .await
            .unwrap();
        let mut v: Vec<Vec<u8>> = rows.into_iter().map(|(d,)| d).collect();
        v.sort();
        v
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_stranger_can_not_put_their_device_into_someones_chat(pool: sqlx::PgPool) {
        let (alice, bob, mallory) = (person(&pool, 61).await, person(&pool, 62).await, person(&pool, 63).await);
        let group = b"alice-and-bob".to_vec();
        let post = |r| create(State(state(pool.clone())), Json(r));

        assert_eq!(post(announce(&alice, &alice, &group, &[&alice, &bob], true)).await.unwrap().0, StatusCode::CREATED);
        // Mallory knows the chat's id: signed by her own device — not her chat.
        assert!(matches!(post(announce(&mallory, &mallory, &group, &[&mallory], true)).await, Err(GroupError::Forbidden(_))));
        // In Alice's name: the signature doesn't match; unsigned: refused.
        assert!(matches!(post(announce(&mallory, &alice, &group, &[&mallory], true)).await, Err(GroupError::Unauthorized(_))));
        assert!(matches!(post(announce(&mallory, &mallory, &group, &[&mallory], false)).await, Err(GroupError::Unauthorized(_))));
        // A new chat must have its creator in it — no junk chats of others.
        assert!(matches!(post(announce(&mallory, &mallory, b"junk", &[&alice], true)).await, Err(GroupError::Forbidden(_))));
        let mut want = vec![pk(&alice), pk(&bob)];
        want.sort();
        assert_eq!(roster(&pool, &group).await, want, "Mallory is not in Alice's chat");

        // Bob's phone was cut off; his new one re-enters with only itself
        // (ADR-075) — but can't bring anyone else along.
        let bob_new = SigningKey::from_bytes(&[64u8; 32]);
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) SELECT $1, user_pk, $1 FROM devices WHERE device_pk = $2")
            .bind(pk(&bob_new))
            .bind(pk(&bob))
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_former_devices (group_id, device_pk) VALUES ($1, $2)").bind(&group).bind(pk(&bob)).execute(&pool).await.unwrap();
        sqlx::query("DELETE FROM group_members WHERE device_pk = $1").bind(pk(&bob)).execute(&pool).await.unwrap();
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE device_pk = $1").bind(pk(&bob)).execute(&pool).await.unwrap();
        assert!(matches!(post(announce(&bob_new, &bob_new, &group, &[&bob_new, &mallory], true)).await, Err(GroupError::Forbidden(_))));
        assert!(matches!(post(announce(&bob, &bob, &group, &[&bob], true)).await, Err(GroupError::Forbidden(_))), "the cut-off phone itself: no");
        assert_eq!(post(announce(&bob_new, &bob_new, &group, &[&bob_new], true)).await.unwrap().0, StatusCode::CREATED);
        // A member adds a new person.
        let carol = person(&pool, 65).await;
        assert_eq!(post(announce(&alice, &alice, &group, &[&alice, &carol], true)).await.unwrap().0, StatusCode::CREATED);
        let mut want = vec![pk(&alice), pk(&bob_new), pk(&carol)];
        want.sort();
        assert_eq!(roster(&pool, &group).await, want);
    }

    // server-http:3 — one registered device repeated thousands of times
    // tied up a database connection for seconds; a real roster still works.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn a_roster_of_thousands_is_refused_before_the_database(pool: sqlx::PgPool) {
        let (a, b, c) = (person(&pool, 0x70).await, person(&pool, 0x71).await, person(&pool, 0x72).await);
        let group = hex::decode("a1b2c3d4").unwrap();
        let post = |r| create(State(state(pool.clone())), Json(r));
        let flood = vec![&b; 5_000];
        assert!(matches!(post(announce(&a, &a, &group, &flood, true)).await, Err(GroupError::BadRequest(_))));
        let stranger = SigningKey::from_bytes(&[0x7F; 32]);
        assert!(matches!(post(announce(&a, &a, &group, &[&a, &stranger], true)).await, Err(GroupError::NotFound(_))));
        assert_eq!(post(announce(&a, &a, &group, &[&a, &b, &c, &b], true)).await.unwrap().0, StatusCode::CREATED);
        assert_eq!(roster(&pool, &group).await.len(), 3, "every device once, the repeated one too");
    }

    /// server-http:10 — any device in the roster replaced the card of the
    /// current epoch; then (ADR-090) the epoch's author's card stood, and the
    /// author may be the member who sent garbage. ADR-093 — every device
    /// keeps its own card; a fetch gets the card of each active device still
    /// in the chat, newest epoch first, each with its person.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn every_member_keeps_its_own_card_and_nobody_replaces_another(pool: sqlx::PgPool) {
        use base64::Engine;
        let (alice, bob, mallory) = (person(&pool, 81).await, person(&pool, 83).await, person(&pool, 82).await);
        let group = b"card-chat".to_vec();
        let post = |r| create(State(state(pool.clone())), Json(r));
        assert_eq!(
            post(announce(&alice, &alice, &group, &[&alice, &bob, &mallory], true)).await.unwrap().0,
            StatusCode::CREATED
        );
        let put = |sk: &SigningKey, epoch: i64, card: &[u8]| {
            let ts = OffsetDateTime::now_utc().unix_timestamp();
            let mut m = GROUP_CARD_PUT_DOMAIN.to_vec();
            m.push(b':');
            m.extend_from_slice(&Sha256::digest(card_body(&group, epoch, card)));
            m.push(b':');
            m.extend_from_slice(&ts.to_be_bytes());
            let req = PutCardRequest {
                device_pk_hex: hex::encode(pk(sk)),
                epoch,
                card_b64: base64::engine::general_purpose::STANDARD.encode(card),
                proof_ts: ts,
                proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
            };
            put_card(State(state(pool.clone())), Path(hex::encode(&group)), Json(req))
        };
        let fetch = |sk: &SigningKey| {
            let ts = OffsetDateTime::now_utc().unix_timestamp();
            let mut m = GROUP_CARD_GET_DOMAIN.to_vec();
            m.push(b':');
            m.extend_from_slice(&Sha256::digest(&group));
            m.push(b':');
            m.extend_from_slice(&ts.to_be_bytes());
            let req = GetCardRequest {
                device_pk_hex: hex::encode(pk(sk)),
                proof_ts: ts,
                proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
            };
            get_card(State(state(pool.clone())), Path(hex::encode(&group)), Json(req))
        };
        let cards = |r: Json<CardResponse>| {
            let mut v: Vec<(i64, Vec<u8>, String)> = r
                .0
                .cards
                .into_iter()
                .map(|c| (c.epoch, base64::engine::general_purpose::STANDARD.decode(c.card_b64).unwrap(), c.identity_hex))
                .collect();
            v.sort();
            v
        };
        assert!(matches!(fetch(&alice).await, Err(GroupError::NotFound(_))));
        // Mallory is first and sends garbage again and again: Alice's and
        // Bob's cards stand next to it, each with its person.
        assert_eq!(put(&mallory, 1, b"garbage").await.unwrap(), StatusCode::NO_CONTENT);
        assert_eq!(put(&alice, 1, b"honest").await.unwrap(), StatusCode::NO_CONTENT);
        assert_eq!(put(&bob, 1, b"honest").await.unwrap(), StatusCode::NO_CONTENT);
        assert_eq!(put(&mallory, 1, b"garbage again").await.unwrap(), StatusCode::NO_CONTENT);
        let mut want = vec![
            (1, b"garbage again".to_vec(), hex::encode(pk(&mallory))),
            (1, b"honest".to_vec(), hex::encode(pk(&alice))),
            (1, b"honest".to_vec(), hex::encode(pk(&bob))),
        ];
        want.sort();
        assert_eq!(cards(fetch(&bob).await.unwrap()), want);
        // Ahead of the chat or behind it: refused (no "0 catches up to 100").
        assert!(matches!(put(&mallory, 2, b"future").await, Err(GroupError::Conflict(_))));
        assert!(matches!(put(&mallory, 0, b"past").await, Err(GroupError::Conflict(_))));
        // The chat moved on: Alice's card is the new epoch's, the others stay.
        sqlx::query("UPDATE mls_groups SET current_epoch = 2 WHERE group_id = $1").bind(&group).execute(&pool).await.unwrap();
        assert_eq!(put(&alice, 2, b"epoch 2").await.unwrap(), StatusCode::NO_CONTENT);
        let got = fetch(&bob).await.unwrap().0.cards;
        assert_eq!((got.len(), got[0].epoch, got[0].identity_hex.clone()), (3, 2, hex::encode(pk(&alice))), "newest first");
        // Alice's device is cut off: her card no longer goes out.
        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE device_pk = $1").bind(pk(&alice)).execute(&pool).await.unwrap();
        let left = cards(fetch(&bob).await.unwrap());
        assert!(left.len() == 2 && left.iter().all(|c| c.0 == 1 && c.2 != hex::encode(pk(&alice))), "{left:?}");
    }

    /// 2026-11-04 (owner: "remove all legacy") — the transition switch is
    /// gone: an unsigned announce is refused even from a member.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn an_unsigned_announce_is_refused_even_from_a_member(pool: sqlx::PgPool) {
        let (alice, bob, carol) = (person(&pool, 71).await, person(&pool, 72).await, person(&pool, 73).await);
        let group = b"old-apps".to_vec();
        let post = |r| create(State(state(pool.clone())), Json(r));
        assert_eq!(post(announce(&alice, &alice, &group, &[&alice, &bob], true)).await.unwrap().0, StatusCode::CREATED);
        assert!(matches!(post(announce(&bob, &bob, &group, &[&bob, &carol], false)).await, Err(GroupError::Unauthorized(_))));
        assert_eq!(roster(&pool, &group).await.len(), 2);
    }
}
