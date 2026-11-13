-- ADR-023 — sealed sender (spec §6.5).
--
-- sealed_keys: each device's weekly HPKE public keys. A sender wraps
-- {group_id, mls_message} for every recipient key; the server stores the
-- envelope per recipient and never learns the group. (Not the same as
-- devices.delivery_key, which is the push-notification routing token.)
CREATE TABLE IF NOT EXISTS sealed_keys (
    key_id      BYTEA       NOT NULL PRIMARY KEY,   -- sha256(public_key)[..16]
    user_pk     UUID        NOT NULL REFERENCES users(user_pk) ON DELETE CASCADE,
    public_key  BYTEA       NOT NULL,
    week        INTEGER     NOT NULL,               -- unix_secs / 604800
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT sealed_keys_key_id_len CHECK (octet_length(key_id) = 16),
    CONSTRAINT sealed_keys_public_len CHECK (octet_length(public_key) = 32)
);
CREATE INDEX IF NOT EXISTS sealed_keys_user_week ON sealed_keys (user_pk, week);

-- A sealed delivery has no row in `messages` (that table is per group):
-- the recipient's own envelope lives on the delivery itself.
ALTER TABLE message_deliveries ADD COLUMN IF NOT EXISTS envelope BYTEA;
ALTER TABLE message_deliveries ADD COLUMN IF NOT EXISTS sealed_key_id BYTEA;
