-- ADR-082 (audit mls-identity:4) — the owner's signature on each published
-- delivery key, and the device certificate when a linked device signed it.
-- The server only stores and returns them; senders check them, so a key
-- the server swaps in gets no notification preview. NULL = an older app.
ALTER TABLE sealed_keys ADD COLUMN IF NOT EXISTS sig BYTEA;
ALTER TABLE sealed_keys ADD COLUMN IF NOT EXISTS cert BYTEA;
