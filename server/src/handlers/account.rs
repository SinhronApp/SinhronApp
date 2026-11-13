// ADR-037 — deleting an account and reporting abuse.
//
//     POST /v1/account/delete   { identity_pubkey_hex, proof_ts, proof_hex }
//         Signed by the identity key itself (not a linked device) over the
//         identity key. Removes the person: devices, KeyPackages, group
//         memberships, queued deliveries, push tokens, sealed keys, state
//         backup, pending Welcomes. Media they uploaded stays for the people
//         who received it. Live connections end at once. 204; 404 when the
//         account doesn't exist (already deleted).
//
//     POST /v1/reports          { identity_pubkey_hex, reported_identity_hex,
//                                 reason, message_text?, proof_ts, proof_hex }
//         A report for the operator (App Store 1.2). The reporter's app sends
//         the reported message's text only because the reporter chose to
//         share it — the server never sees message content otherwise. Rate
//         limited per reporter (REPORTS_PER_DAY). 202. ADR-077 — with
//         administrators configured, the reporter's IP (this request) and
//         the reported account's last IP (in memory, from its last login)
//         are kept with it for 30 days, and the administrators are told.
//
// Operators review reports with SQL (`docs/onboarding.md`, "Жалобы") or in
// the app's "Server" chat (ADR-077).

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Json, Response},
};
use serde::Deserialize;
use time::OffsetDateTime;
use tracing::{error, info, warn};
use uuid::Uuid;

use super::proof::{self, ACCOUNT_DELETE_DOMAIN, REPORT_DOMAIN};
use crate::AppState;

/// How many reports one person may send in 24 hours.
pub const REPORTS_PER_DAY: i64 = 50;

/// Longest message text kept with a report (characters).
pub const REPORT_TEXT_MAX: usize = 4000;
/// Reports from one address (IPv6: its /64) a day — throwaway accounts
/// flooded the administrators' "Server" chat (server-http:16).
static REPORT_PER_IP: crate::rate_limit::StaticLimiter =
    crate::rate_limit::StaticLimiter::new("SINHRON_RATE_REPORT_IP", 10, 86_400);

#[derive(Debug, Deserialize)]
pub struct DeleteRequest {
    pub identity_pubkey_hex: String,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Deserialize)]
pub struct ReportRequest {
    pub identity_pubkey_hex: String,
    pub reported_identity_hex: String,
    pub reason: String,
    #[serde(default)]
    pub message_text: Option<String>,
    pub proof_ts: i64,
    pub proof_hex: String,
}

/// What a report's signature covers: who is reported, why, and the text.
pub fn report_body(reported: &[u8], reason: &str, text: Option<&str>) -> Vec<u8> {
    let mut b = reported.to_vec();
    b.extend_from_slice(reason.as_bytes());
    b.push(0);
    if let Some(t) = text {
        b.extend_from_slice(t.as_bytes());
    }
    b
}

#[derive(Debug, thiserror::Error)]
pub enum AccountError {
    #[error("bad request: {0}")]
    BadRequest(String),
    #[error("unauthorized: {0}")]
    Unauthorized(String),
    #[error("not found")]
    NotFound,
    #[error("too many reports")]
    TooMany,
    #[error("no db configured")]
    NoDb,
    #[error("database error: {0}")]
    Db(#[from] sqlx::Error),
}

impl IntoResponse for AccountError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            AccountError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            AccountError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, m.clone()),
            AccountError::NotFound => (StatusCode::NOT_FOUND, "no such account".to_string()),
            AccountError::TooMany => (StatusCode::TOO_MANY_REQUESTS, "too many reports today".to_string()),
            AccountError::NoDb => (StatusCode::SERVICE_UNAVAILABLE, "no database configured".to_string()),
            AccountError::Db(e) => {
                error!(error = %e, "db error in account handler");
                (StatusCode::INTERNAL_SERVER_ERROR, "internal error".to_string())
            }
        };
        (status, Json(serde_json::json!({ "error": msg }))).into_response()
    }
}

fn now() -> i64 {
    OffsetDateTime::now_utc().unix_timestamp()
}

/// `POST /v1/account/delete` — see the module comment.
pub async fn delete(State(state): State<AppState>, Json(req): Json<DeleteRequest>) -> Result<StatusCode, AccountError> {
    let pool = state.pool.ok_or(AccountError::NoDb)?;
    let identity =
        hex::decode(&req.identity_pubkey_hex).map_err(|e| AccountError::BadRequest(format!("identity: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| AccountError::BadRequest(format!("proof_hex: {e}")))?;
    // The identity key itself: a linked device can't delete the account.
    proof::verify_action_proof(ACCOUNT_DELETE_DOMAIN, &identity, &identity, req.proof_ts, &sig, now())
        .map_err(|e| AccountError::Unauthorized(e.to_string()))?;

    let mut tx = pool.begin().await?;
    // Only an active account: deleting the row a ban left would lift the ban (ACCT-2).
    let users: Vec<(Uuid,)> =
        sqlx::query_as("SELECT user_pk FROM users WHERE identity_pubkey = $1 AND status = 'active' FOR UPDATE")
            .bind(&identity)
            .fetch_all(&mut *tx)
            .await?;
    if users.is_empty() {
        return Err(AccountError::NotFound);
    }
    let ids: Vec<Uuid> = users.into_iter().map(|(u,)| u).collect();
    // No foreign keys on these two: delete by hand.
    sqlx::query("DELETE FROM message_deliveries WHERE recipient_user_pk = ANY($1)")
        .bind(&ids)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "DELETE FROM push_subscriptions WHERE delivery_key IN \
         (SELECT delivery_key FROM devices WHERE user_pk = ANY($1) AND delivery_key IS NOT NULL)",
    )
    .bind(&ids)
    .execute(&mut *tx)
    .await?;
    // The Commit order log (ADR-092) named the device — for the first one
    // that is the identity key — next to chat and epoch for good (ACCT-1).
    // The rows stay, the order needs them; the key goes.
    sqlx::query(
        "UPDATE group_commits SET device_pk = '' WHERE device_pk IN (SELECT device_pk FROM devices WHERE user_pk = ANY($1))",
    )
    .bind(&ids)
    .execute(&mut *tx)
    .await?;
    // Cascades: devices → KeyPackages, group memberships; sealed keys,
    // state backup, pending Welcomes. Media keeps a NULL uploader.
    sqlx::query("DELETE FROM users WHERE user_pk = ANY($1)").bind(&ids).execute(&mut *tx).await?;
    tx.commit().await?;
    for u in &ids {
        state.sessions.drop_user(*u);
    }
    info!(identity = %crate::short_key(&req.identity_pubkey_hex), "account deleted");
    Ok(StatusCode::NO_CONTENT)
}

/// `POST /v1/reports` — see the module comment.
pub async fn report(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<ReportRequest>,
) -> Result<StatusCode, AccountError> {
    let pool = state.pool.ok_or(AccountError::NoDb)?;
    let signer =
        hex::decode(&req.identity_pubkey_hex).map_err(|e| AccountError::BadRequest(format!("identity: {e}")))?;
    let reported = hex::decode(&req.reported_identity_hex)
        .map_err(|e| AccountError::BadRequest(format!("reported: {e}")))?;
    if reported.len() != 32 {
        return Err(AccountError::BadRequest("reported identity must be 32 bytes".into()));
    }
    if !matches!(req.reason.as_str(), "spam" | "abuse" | "illegal" | "other") {
        return Err(AccountError::BadRequest("unknown reason".into()));
    }
    let text = req.message_text.as_deref().map(str::trim).filter(|t| !t.is_empty());
    if text.is_some_and(|t| t.chars().count() > REPORT_TEXT_MAX) {
        return Err(AccountError::BadRequest("message text too long".into()));
    }
    // PostgreSQL text can't hold NUL: say 400 here instead of a 500 at the INSERT.
    if text.is_some_and(|t| t.contains('\0')) {
        return Err(AccountError::BadRequest("message text has a NUL".into()));
    }
    let sig = hex::decode(&req.proof_hex).map_err(|e| AccountError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(
        REPORT_DOMAIN,
        &signer,
        &report_body(&reported, &req.reason, req.message_text.as_deref()),
        req.proof_ts,
        &sig,
        now(),
    )
    .map_err(|e| AccountError::Unauthorized(e.to_string()))?;
    // A linked device reports for its person.
    let Some((_, reporter)) = crate::accounts::resolve_signer(&pool, &signer).await? else {
        return Err(AccountError::Unauthorized("unknown signer".into()));
    };
    if reporter == reported {
        return Err(AccountError::BadRequest("can't report yourself".into()));
    }
    // About a real account, from one older than a day: accounts made to
    // report buried real reports and stored anyone's IP (server-http:16).
    let (target, aged): (bool, bool) = sqlx::query_as(
        "SELECT EXISTS (SELECT 1 FROM users WHERE identity_pubkey = $1), \
         EXISTS (SELECT 1 FROM users WHERE identity_pubkey = $2 AND registered_at < NOW() - INTERVAL '1 day')",
    )
    .bind(&reported)
    .bind(&reporter)
    .fetch_one(&pool)
    .await?;
    if !target {
        return Err(AccountError::NotFound);
    }
    if !aged {
        return Err(AccountError::Unauthorized("account too new to report".into()));
    }
    let (today,): (i64,) = sqlx::query_as(
        "SELECT COUNT(*) FROM abuse_reports WHERE reporter_identity = $1 AND created_at > NOW() - INTERVAL '1 day'",
    )
    .bind(&reporter)
    .fetch_one(&pool)
    .await?;
    if today >= REPORTS_PER_DAY {
        warn!("report rate limit hit");
        return Err(AccountError::TooMany);
    }
    // Last of the checks: refused reports (no such account, too new) spent
    // the address's ten, and nobody behind it could report for a day (ACCT-4).
    if crate::admin::client_rate_key(&headers).is_some_and(|ip| REPORT_PER_IP.check(&ip).is_err()) {
        return Err(AccountError::TooMany);
    }
    // ADR-077 — IPs only when someone is there to read them.
    let admins = crate::admin::config().enabled();
    let ip = |ip: Option<std::net::IpAddr>| ip.filter(|_| admins).map(|ip| ip.to_string());
    sqlx::query(
        "INSERT INTO abuse_reports (reporter_identity, reported_identity, reason, message_text, reporter_ip, reported_ip) \
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(&reporter)
    .bind(&reported)
    .bind(&req.reason)
    .bind(text)
    .bind(ip(crate::admin::client_ip(&headers)))
    .bind(ip(crate::admin::last_ip(&reported)))
    .execute(&pool)
    .await?;
    if admins {
        crate::admin::report_filed();
    }
    info!(reason = %req.reason, "abuse report filed");
    Ok(StatusCode::ACCEPTED)
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

    fn sign(sk: &SigningKey, domain: &[u8], body: &[u8]) -> (i64, String) {
        let ts = now();
        let mut m = domain.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(body));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        (ts, hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()))
    }

    fn delete_req(sk: &SigningKey) -> DeleteRequest {
        let pk = sk.verifying_key().to_bytes();
        let (proof_ts, proof_hex) = sign(sk, ACCOUNT_DELETE_DOMAIN, &pk);
        DeleteRequest { identity_pubkey_hex: hex::encode(pk), proof_ts, proof_hex }
    }

    fn report_req(sk: &SigningKey, reported: &[u8], reason: &str, text: Option<&str>) -> ReportRequest {
        let (proof_ts, proof_hex) = sign(sk, REPORT_DOMAIN, &report_body(reported, reason, text));
        ReportRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            reported_identity_hex: hex::encode(reported),
            reason: reason.into(),
            message_text: text.map(str::to_string),
            proof_ts,
            proof_hex,
        }
    }

    async fn add_person(pool: &sqlx::PgPool, sk: &SigningKey, group: &[u8]) -> Uuid {
        let u = Uuid::now_v7();
        let pk = sk.verifying_key().to_bytes().to_vec();
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey, registered_at) VALUES ($1, $2, NOW() - INTERVAL '2 days')")
            .bind(u)
            .bind(&pk)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)")
            .bind(&pk)
            .bind(u)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO group_members (group_id, device_pk, joined_at_epoch) VALUES ($1, $2, 0)")
            .bind(group)
            .bind(&pk)
            .execute(pool)
            .await
            .unwrap();
        u
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn deleting_an_account_removes_the_person_and_keeps_what_others_received(pool: sqlx::PgPool) {
        let group = b"del-group".to_vec();
        let alice = SigningKey::from_bytes(&[51u8; 32]);
        let bob = SigningKey::from_bytes(&[52u8; 32]);
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        let a = add_person(&pool, &alice, &group).await;
        add_person(&pool, &bob, &group).await;
        let a_pk = alice.verifying_key().to_bytes().to_vec();
        // A photo Alice sent, a delivery queued for her.
        sqlx::query("INSERT INTO media (sha256, size_bytes, uploaded_by_device) VALUES ($1, 1, $2)")
            .bind(vec![7u8; 32])
            .bind(&a_pk)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO message_deliveries (recipient_user_pk, message_id) VALUES ($1, $2)")
            .bind(a)
            .bind(Uuid::now_v7())
            .execute(&pool)
            .await
            .unwrap();

        // Commits she made in the chat (ACCT-1).
        for epoch in 0..3i64 {
            sqlx::query("INSERT INTO group_commits (group_id, epoch, message_id, device_pk) VALUES ($1, $2, $3, $4)")
                .bind(&group)
                .bind(epoch)
                .bind(Uuid::now_v7())
                .bind(&a_pk)
                .execute(&pool)
                .await
                .unwrap();
        }

        // Bob can't delete Alice.
        let mut forged = delete_req(&bob);
        forged.identity_pubkey_hex = hex::encode(&a_pk);
        assert!(matches!(delete(State(state(pool.clone())), Json(forged)).await, Err(AccountError::Unauthorized(_))));

        assert_eq!(delete(State(state(pool.clone())), Json(delete_req(&alice))).await.unwrap(), StatusCode::NO_CONTENT);
        let n = |sql: &'static str| {
            let pool = pool.clone();
            async move {
                let (n,): (i64,) = sqlx::query_as(sql).fetch_one(&pool).await.unwrap();
                n
            }
        };
        assert_eq!(n("SELECT COUNT(*) FROM users").await, 1, "Bob stays");
        assert_eq!(n("SELECT COUNT(*) FROM devices").await, 1);
        assert_eq!(n("SELECT COUNT(*) FROM group_members").await, 1);
        assert_eq!(n("SELECT COUNT(*) FROM message_deliveries").await, 0);
        assert_eq!(n("SELECT COUNT(*) FROM media WHERE uploaded_by_device IS NULL").await, 1, "Bob keeps the photo");
        // ACCT-1 — the Commit order stays, her key in it doesn't.
        let named: (i64, i64) = sqlx::query_as("SELECT COUNT(*), COUNT(*) FILTER (WHERE device_pk = $1) FROM group_commits")
            .bind(&a_pk)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(named, (3, 0));
        // Again: nothing to delete.
        assert!(matches!(delete(State(state(pool.clone())), Json(delete_req(&alice))).await, Err(AccountError::NotFound)));
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn reports_are_signed_kept_for_the_operator_and_limited(pool: sqlx::PgPool) {
        let group = b"rep-group".to_vec();
        let alice = SigningKey::from_bytes(&[61u8; 32]);
        let bob = SigningKey::from_bytes(&[62u8; 32]);
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        add_person(&pool, &alice, &group).await;
        add_person(&pool, &bob, &group).await;
        let b_pk = bob.verifying_key().to_bytes();
        let st = || State(state(pool.clone()));

        let ok = report_req(&alice, &b_pk, "abuse", Some("you will regret this"));
        assert_eq!(report(st(), HeaderMap::new(), Json(ok)).await.unwrap(), StatusCode::ACCEPTED);
        let (reason, text): (String, Option<String>) =
            sqlx::query_as("SELECT reason, message_text FROM abuse_reports").fetch_one(&pool).await.unwrap();
        assert_eq!((reason.as_str(), text.as_deref()), ("abuse", Some("you will regret this")));

        // The text is signed: changing it breaks the proof.
        let mut tampered = report_req(&alice, &b_pk, "spam", Some("buy"));
        tampered.message_text = Some("something else".into());
        assert!(matches!(report(st(), HeaderMap::new(), Json(tampered)).await, Err(AccountError::Unauthorized(_))));
        // Unknown reason, yourself.
        assert!(matches!(report(st(), HeaderMap::new(), Json(report_req(&alice, &b_pk, "meh", None))).await, Err(AccountError::BadRequest(_))));
        let a_pk = alice.verifying_key().to_bytes();
        assert!(matches!(report(st(), HeaderMap::new(), Json(report_req(&alice, &a_pk, "spam", None))).await, Err(AccountError::BadRequest(_))));
        // Rate limit.
        for _ in 1..REPORTS_PER_DAY {
            report(st(), HeaderMap::new(), Json(report_req(&alice, &b_pk, "spam", None))).await.unwrap();
        }
        assert!(matches!(report(st(), HeaderMap::new(), Json(report_req(&alice, &b_pk, "spam", None))).await, Err(AccountError::TooMany)));
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn with_administrators_a_report_keeps_both_ips(pool: sqlx::PgPool) {
        let group = b"rep-ip-group".to_vec();
        let alice = SigningKey::from_bytes(&[63u8; 32]);
        let bob = SigningKey::from_bytes(&[64u8; 32]);
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        add_person(&pool, &alice, &group).await;
        add_person(&pool, &bob, &group).await;
        crate::admin::add_admin_for_test(&[0x65; 32]);
        let b_pk = bob.verifying_key().to_bytes();
        // Bob last logged in from here (WS auth notes it).
        crate::admin::note_ip(&b_pk, Some("198.51.100.7".parse().unwrap()));
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", "203.0.113.5".parse().unwrap());
        report(State(state(pool.clone())), headers, Json(report_req(&alice, &b_pk, "spam", None))).await.unwrap();
        let row: (Option<String>, Option<String>, bool) =
            sqlx::query_as("SELECT reporter_ip, reported_ip, admin_notified_at IS NULL FROM abuse_reports")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(row, (Some("203.0.113.5".into()), Some("198.51.100.7".into()), true));
    }

    /// server-http:16 — accounts made a minute ago filed reports by the
    /// hundred about anyone: real reports were buried, anyone's IP stored.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn throwaway_accounts_cannot_flood_reports(pool: sqlx::PgPool) {
        let group = b"rep-flood".to_vec();
        let (alice, bob, fresh) = (SigningKey::from_bytes(&[66u8; 32]), SigningKey::from_bytes(&[67u8; 32]), SigningKey::from_bytes(&[68u8; 32]));
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        for sk in [&alice, &bob, &fresh] {
            add_person(&pool, sk, &group).await;
        }
        sqlx::query("UPDATE users SET registered_at = NOW() WHERE identity_pubkey = $1")
            .bind(&fresh.verifying_key().to_bytes()[..])
            .execute(&pool)
            .await
            .unwrap();
        let b_pk = bob.verifying_key().to_bytes();
        let st = || State(state(pool.clone()));
        let spam = |sk: &SigningKey, about: &[u8]| Json(report_req(sk, about, "spam", None));
        assert!(matches!(report(st(), HeaderMap::new(), spam(&fresh, &b_pk)).await, Err(AccountError::Unauthorized(_))));
        assert!(matches!(report(st(), HeaderMap::new(), spam(&alice, &[69u8; 32])).await, Err(AccountError::NotFound)));
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "192.0.2.66".parse().unwrap());
        for _ in 0..10 {
            report(st(), h.clone(), spam(&alice, &b_pk)).await.unwrap();
        }
        assert!(matches!(report(st(), h, spam(&alice, &b_pk)).await, Err(AccountError::TooMany)), "10 a day from one address");
    }

    /// ACCT-4 — ten refused reports from an address used up its day: nobody
    /// behind the same address (home, office, mobile NAT) could report.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn refused_reports_do_not_spend_the_address_limit(pool: sqlx::PgPool) {
        let group = b"rep-refused".to_vec();
        let (mum, bob, fresh) = (SigningKey::from_bytes(&[70u8; 32]), SigningKey::from_bytes(&[71u8; 32]), SigningKey::from_bytes(&[72u8; 32]));
        sqlx::query("INSERT INTO mls_groups (group_id) VALUES ($1)").bind(&group).execute(&pool).await.unwrap();
        for sk in [&mum, &bob, &fresh] {
            add_person(&pool, sk, &group).await;
        }
        sqlx::query("UPDATE users SET registered_at = NOW() WHERE identity_pubkey = $1")
            .bind(&fresh.verifying_key().to_bytes()[..])
            .execute(&pool)
            .await
            .unwrap();
        let b_pk = bob.verifying_key().to_bytes();
        let st = || State(state(pool.clone()));
        let mut h = HeaderMap::new();
        h.insert("x-forwarded-for", "192.0.2.74".parse().unwrap());
        for i in 0..12u8 {
            let nobody = report(st(), h.clone(), Json(report_req(&mum, &[100 + i; 32], "spam", None))).await;
            assert!(matches!(nobody, Err(AccountError::NotFound)));
            let too_new = report(st(), h.clone(), Json(report_req(&fresh, &b_pk, "spam", None))).await;
            assert!(matches!(too_new, Err(AccountError::Unauthorized(_))));
        }
        // A NUL in the quoted text is a bad request, not a server error.
        let nul = report(st(), h.clone(), Json(report_req(&mum, &b_pk, "abuse", Some("a\0b")))).await;
        assert!(matches!(nul, Err(AccountError::BadRequest(_))));
        let real = report(st(), h, Json(report_req(&mum, &b_pk, "abuse", None))).await;
        assert_eq!(real.unwrap(), StatusCode::ACCEPTED);
    }
}
