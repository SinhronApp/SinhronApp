-- Tech-debt 2.5 (residual) — the chat timer for sealed deliveries.
--
-- A sealed envelope names no chat, so the per-chat timer
-- (mls_groups.disappearing_after_secs) can't reach it; the sender attaches
-- the timer to each delivery instead and the retention sweep deletes the
-- delivery when it runs out. Resume never replays an expired one.
ALTER TABLE message_deliveries ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ;
CREATE INDEX IF NOT EXISTS message_deliveries_expires ON message_deliveries (expires_at) WHERE expires_at IS NOT NULL;
