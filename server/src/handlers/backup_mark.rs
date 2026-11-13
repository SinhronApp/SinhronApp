// ADR-090 (docs/security-review-2026-11.md, storage-devices:14) — the chat
// backup in the person's iCloud / Google Drive could be rolled back unseen:
// whoever controls the cloud put an older root (and its files) back, and a
// new phone restored it as "the newest" — later messages gone, people
// blocked since unblocked. The server now keeps, per account and cloud, when
// the newest backup of its devices was made; before a restore the phone asks
// and warns when the cloud has nothing that new. A rollback then needs the
// cloud and this server together.
//
//   POST /v1/backup-mark
//   { "device_pk_hex", "cloud": one of CLOUDS, "created_ts",
//     "proof_ts", "proof_hex" }
//   — action proof by an active device of the account (BACKUP_MARK_DOMAIN,
//   body = cloud || be8(created_ts)). `created_ts` > 0: a backup made then
//   is in the cloud (the newest one is kept); 0: just ask.
//   → { "created_ts": the newest known, 0 = none }

use axum::{extract::State, response::Json};
use serde::{Deserialize, Serialize};
use time::OffsetDateTime;
use uuid::Uuid;

use super::groups::GroupError;
use super::proof::{self, BACKUP_MARK_DOMAIN};
use crate::AppState;

/// DEV-5 — the clouds the app names ("icloud", "googledrive", "folder";
/// "drive" as first documented): any made-up word was a new row, without end.
const CLOUDS: [&str; 4] = ["icloud", "googledrive", "drive", "folder"];
/// DEV-5 — marks per person (the app sends one per backup or restore).
static MARK_PER_USER: crate::rate_limit::StaticLimiter = crate::rate_limit::StaticLimiter::new("SINHRON_RATE_BACKUP_MARK", 600, 3_600);

#[derive(Debug, Deserialize)]
pub struct MarkRequest {
    pub device_pk_hex: String,
    pub cloud: String,
    #[serde(default)]
    pub created_ts: i64,
    pub proof_ts: i64,
    pub proof_hex: String,
}

#[derive(Debug, Serialize)]
pub struct MarkResponse {
    pub created_ts: i64,
}

/// What a mark request signs: cloud || be8(created_ts).
pub fn mark_body(cloud: &str, created_ts: i64) -> Vec<u8> {
    let mut b = cloud.as_bytes().to_vec();
    b.extend_from_slice(&created_ts.to_be_bytes());
    b
}

pub async fn mark(State(state): State<AppState>, Json(req): Json<MarkRequest>) -> Result<Json<MarkResponse>, GroupError> {
    let pool = state.pool.ok_or(GroupError::NoDb)?;
    let now = OffsetDateTime::now_utc().unix_timestamp();
    let ok_cloud = CLOUDS.contains(&req.cloud.as_str());
    // A day ahead at most: a phone's clock is off a little, not by years.
    if !ok_cloud || !(0..=now + 86_400).contains(&req.created_ts) {
        return Err(GroupError::BadRequest("cloud: a known one; created_ts: 0..now".into()));
    }
    let device = hex::decode(&req.device_pk_hex).map_err(|e| GroupError::BadRequest(format!("device_pk_hex: {e}")))?;
    let sig = hex::decode(&req.proof_hex).map_err(|e| GroupError::BadRequest(format!("proof_hex: {e}")))?;
    proof::verify_action_proof(BACKUP_MARK_DOMAIN, &device, &mark_body(&req.cloud, req.created_ts), req.proof_ts, &sig, now)
        .map_err(|e| GroupError::Unauthorized(e.to_string()))?;
    let user: Option<(Uuid,)> = sqlx::query_as("SELECT user_pk FROM devices WHERE device_pk = $1 AND revoked_at IS NULL")
        .bind(&device)
        .fetch_optional(&pool)
        .await?;
    let Some((user,)) = user else {
        return Err(GroupError::Forbidden("not an active device".into()));
    };
    if MARK_PER_USER.check(&user.to_string()).is_err() {
        return Err(GroupError::RateLimited);
    }
    if req.created_ts > 0 {
        sqlx::query(
            "INSERT INTO backup_marks (user_pk, cloud, created_ts) VALUES ($1, $2, $3) \
             ON CONFLICT (user_pk, cloud) DO UPDATE SET created_ts = GREATEST(backup_marks.created_ts, EXCLUDED.created_ts), updated_at = NOW()",
        )
        .bind(user)
        .bind(&req.cloud)
        .bind(req.created_ts)
        .execute(&pool)
        .await?;
    }
    let got: Option<(i64,)> = sqlx::query_as("SELECT created_ts FROM backup_marks WHERE user_pk = $1 AND cloud = $2")
        .bind(user)
        .bind(&req.cloud)
        .fetch_optional(&pool)
        .await?;
    Ok(Json(MarkResponse { created_ts: got.map_or(0, |(t,)| t) }))
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

    fn req(sk: &SigningKey, cloud: &str, created_ts: i64) -> MarkRequest {
        let ts = OffsetDateTime::now_utc().unix_timestamp();
        let mut m = BACKUP_MARK_DOMAIN.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(mark_body(cloud, created_ts)));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        MarkRequest {
            device_pk_hex: hex::encode(sk.verifying_key().to_bytes()),
            cloud: cloud.into(),
            created_ts,
            proof_ts: ts,
            proof_hex: hex::encode(sk.sign(&crate::handlers::proof::for_localhost(&m)).to_bytes()),
        }
    }

    /// storage-devices:14 — the newest backup's time stays with the server,
    /// whatever the cloud holds later: an older one never lowers it, another
    /// cloud and another account have their own, a stranger reads nothing.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn the_server_remembers_the_newest_backup_so_an_older_one_shows(pool: sqlx::PgPool) {
        let mut people = Vec::new();
        for seed in [41u8, 42] {
            let sk = SigningKey::from_bytes(&[seed; 32]);
            let pk = sk.verifying_key().to_bytes().to_vec();
            let u = Uuid::now_v7();
            sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(u).bind(&pk).execute(&pool).await.unwrap();
            sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)").bind(&pk).bind(u).execute(&pool).await.unwrap();
            people.push(sk);
        }
        let (me, other) = (&people[0], &people[1]);
        let post = |r| mark(State(state(pool.clone())), Json(r));
        let at = |r: Result<Json<MarkResponse>, GroupError>| r.unwrap().0.created_ts;
        assert_eq!(at(post(req(me, "icloud", 0)).await), 0, "no backup yet");
        assert_eq!(at(post(req(me, "icloud", 1_793_000_000)).await), 1_793_000_000);
        assert_eq!(at(post(req(me, "icloud", 1_792_000_000)).await), 1_793_000_000, "an older one doesn't lower it");
        assert_eq!(at(post(req(me, "icloud", 0)).await), 1_793_000_000);
        assert_eq!(at(post(req(me, "drive", 0)).await), 0, "each cloud its own");
        assert_eq!(at(post(req(other, "icloud", 0)).await), 0, "each account its own");
        let stranger = SigningKey::from_bytes(&[43u8; 32]);
        assert!(matches!(post(req(&stranger, "icloud", 0)).await, Err(GroupError::Forbidden(_))));
        let mut forged = req(other, "icloud", 1_793_100_000);
        forged.device_pk_hex = hex::encode(me.verifying_key().to_bytes());
        assert!(matches!(post(forged).await, Err(GroupError::Unauthorized(_))), "not in my name");
        assert!(matches!(post(req(me, "../x", 0)).await, Err(GroupError::BadRequest(_))));
        assert!(matches!(post(req(me, "icloud", i64::MAX)).await, Err(GroupError::BadRequest(_))), "from the future");

        // DEV-5 — a made-up cloud name is no new row; the app's names are known.
        assert!(matches!(post(req(me, "abcdefgh", 1_793_000_000)).await, Err(GroupError::BadRequest(_))));
        for cloud in ["googledrive", "folder"] {
            assert_eq!(at(post(req(me, cloud, 1_793_000_000)).await), 1_793_000_000);
        }
        let (rows,): (i64,) = sqlx::query_as("SELECT count(*) FROM backup_marks").fetch_one(&pool).await.unwrap();
        assert_eq!(rows, 3);
        // …and marks are limited per person.
        let mut refused = 0;
        for _ in 0..600 {
            match post(req(me, "icloud", 0)).await {
                Err(GroupError::RateLimited) => refused += 1,
                r => drop(r.unwrap()),
            }
        }
        assert!((6..=8).contains(&refused), "600 an hour, 7 used above: {refused}");
        assert_eq!(at(post(req(other, "icloud", 0)).await), 0, "another person is not affected");
    }
}
