-- ADR-071 — one access key per contact; block = revoke that key.
--
-- A person gives each chat partner their own 16-byte access key (inside
-- MLS) and publishes only SHA-256 of each here. The server can't tell
-- whose key a hash is. Unauthenticated deliveries (POST /v1/sealed) to a
-- person in this mode need one of their active keys; a revoked key is
-- accepted and silently dropped (no push). Deliveries without a key
-- (authenticated WS, plain Submit) still arrive but never push.
--
--   version     the person's access_version the key belongs to (a newer
--               version drops older active keys; revoked ones stay)
--   revoked     the person blocked whoever holds this key
--   decided_ms  when the latest block / unblock was decided (the device's
--               clock, ADR-064): a later decision wins, so a device that
--               hasn't heard of a block can't undo it
CREATE TABLE IF NOT EXISTS access_keys (
    user_pk    UUID    NOT NULL REFERENCES users(user_pk) ON DELETE CASCADE,
    key_hash   BYTEA   NOT NULL,
    version    INTEGER NOT NULL DEFAULT 0,
    revoked    BOOLEAN NOT NULL DEFAULT FALSE,
    decided_ms BIGINT  NOT NULL DEFAULT 0,
    PRIMARY KEY (user_pk, key_hash)
);

-- Set by the person's first PUT /v1/access-keys: from then on their old
-- shared key (users.access_hash, ADR-026) is no longer accepted.
ALTER TABLE users ADD COLUMN IF NOT EXISTS access_per_contact BOOLEAN NOT NULL DEFAULT FALSE;
