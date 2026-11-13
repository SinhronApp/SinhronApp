-- Tech-debt 2.2 (residual) — rotating the sealed-sender access key.
-- The key is derived per version; the server keeps the newest version's
-- hash only, so a device that still publishes an older version can't roll
-- it back (it learns the current version from the reply and adopts it).
ALTER TABLE users ADD COLUMN IF NOT EXISTS access_version INTEGER NOT NULL DEFAULT 0;
