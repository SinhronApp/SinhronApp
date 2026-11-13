// Who is behind a signing key — ADR-027 (identity key on the first
// device only).
//
// Devices paired by QR never get the identity key: they sign account-level
// requests (WS login, sealed keys, calls, media, revocation, chat timer)
// with their own device key, and send that key where the identity key
// used to go. The server accepts it only while it is an active linked
// device of the person — certificate on record, not revoked — so revoking
// a device really locks it out.

use sqlx::PgPool;
use uuid::Uuid;

/// `(user_pk, identity_pubkey)` for a signing key: the identity key
/// itself, or an active linked device's key. `None` = nobody (unknown key,
/// a revoked device, or an account the operator blocked — ACCT-2).
pub async fn resolve_signer(pool: &PgPool, pk: &[u8]) -> sqlx::Result<Option<(Uuid, Vec<u8>)>> {
    let user: Option<(Uuid,)> = sqlx::query_as("SELECT user_pk FROM users WHERE identity_pubkey = $1 AND status = 'active'")
        .bind(pk)
        .fetch_optional(pool)
        .await?;
    if let Some((u,)) = user {
        return Ok(Some((u, pk.to_vec())));
    }
    sqlx::query_as(
        "SELECT u.user_pk, u.identity_pubkey FROM devices d \
         JOIN users u ON u.user_pk = d.user_pk \
         WHERE d.device_pk = $1 AND d.revoked_at IS NULL AND d.certificate IS NOT NULL AND u.status = 'active'",
    )
    .bind(pk)
    .fetch_optional(pool)
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL"]
    async fn linked_device_keys_speak_for_the_person_until_revoked(pool: PgPool) {
        let user = Uuid::now_v7();
        let identity = vec![0x61u8; 32];
        let laptop = vec![0x62u8; 32];
        let legacy = vec![0x63u8; 32];
        sqlx::query("INSERT INTO users (user_pk, identity_pubkey) VALUES ($1, $2)").bind(user).bind(&identity).execute(&pool).await.unwrap();
        // A linked device (certificate on record) and a row without one.
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential, certificate) VALUES ($1, $2, $1, $3)")
            .bind(&laptop).bind(user).bind(vec![0u8; 132]).execute(&pool).await.unwrap();
        sqlx::query("INSERT INTO devices (device_pk, user_pk, credential) VALUES ($1, $2, $1)")
            .bind(&legacy).bind(user).execute(&pool).await.unwrap();

        assert_eq!(resolve_signer(&pool, &identity).await.unwrap(), Some((user, identity.clone())));
        assert_eq!(resolve_signer(&pool, &laptop).await.unwrap(), Some((user, identity.clone())), "the laptop speaks for its person");
        assert_eq!(resolve_signer(&pool, &legacy).await.unwrap(), None, "no certificate, no say");
        assert_eq!(resolve_signer(&pool, &[0x64u8; 32]).await.unwrap(), None, "a stranger");

        sqlx::query("UPDATE devices SET revoked_at = NOW() WHERE device_pk = $1").bind(&laptop).execute(&pool).await.unwrap();
        assert_eq!(resolve_signer(&pool, &laptop).await.unwrap(), None, "revoked: locked out");
    }
}
