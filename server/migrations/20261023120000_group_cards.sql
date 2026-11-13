-- ADR-075 — a phone signed in again enters its chats by itself, and a
-- device cut off is cut off for everyone.
--
--   group_cards           the chat's current MLS GroupInfo ("card": public
--                         keys and devices of the chat, the external key of
--                         the epoch — no messages, no names), left by a
--                         member's device after each change. A device of a
--                         person already in the chat fetches it and joins
--                         with an external commit, even when every other
--                         member is offline.
--   group_former_devices  a revoked device's chats: its person may still
--                         rejoin them by an external commit (the revoked
--                         device's group_members rows go).
--   devices.revoke_proof  the identity key's signature over the revocation
--   devices.revoke_proof_ts  (DEVICE_REVOKE_DOMAIN, body = device_pk):
--                         listed with the device, so other people's phones
--                         can check the person — not the server — cut it
--                         off, and take its leaf out of their chats.
CREATE TABLE IF NOT EXISTS group_cards (
    group_id    BYTEA       NOT NULL PRIMARY KEY REFERENCES mls_groups(group_id) ON DELETE CASCADE,
    epoch       BIGINT      NOT NULL,
    card        BYTEA       NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS group_former_devices (
    group_id    BYTEA       NOT NULL REFERENCES mls_groups(group_id) ON DELETE CASCADE,
    device_pk   BYTEA       NOT NULL REFERENCES devices(device_pk) ON DELETE CASCADE,
    left_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_id, device_pk)
);

ALTER TABLE devices ADD COLUMN IF NOT EXISTS revoke_proof BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS revoke_proof_ts BIGINT;
