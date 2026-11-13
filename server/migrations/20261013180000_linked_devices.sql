-- ADR-025 — several devices per person (spec §6.7).
--
-- A linked device registers with a *device certificate*: the identity key
-- signs the device's own Ed25519 key ("SDC1" || identity_pub || device_pub
-- || sig, 132 bytes). The primary device (device_pk = identity key) has no
-- certificate. Revoking a device keeps its row (messages and media refer
-- to it) but drops its KeyPackages and group memberships.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS certificate BYTEA;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS devices_user_active ON devices (user_pk) WHERE revoked_at IS NULL;
