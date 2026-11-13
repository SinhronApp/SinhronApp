-- Disappearing timers count from delivery, not from sending (ADR-020:
-- "the clock starts when it reaches the phone").
--
-- received_at — when the server pushed the delivery to one of the
-- recipient's live sessions (or replayed it on Resume). The sealed TTL
-- (ttl_secs) turns into expires_at only then; a chat's stored ciphertexts
-- go once every recipient has received them and the timer has passed
-- since. Someone offline longer than the timer still gets the message
-- (until the server's global retention).
ALTER TABLE message_deliveries ADD COLUMN IF NOT EXISTS received_at TIMESTAMPTZ;
ALTER TABLE message_deliveries ADD COLUMN IF NOT EXISTS ttl_secs INTEGER;
CREATE INDEX IF NOT EXISTS message_deliveries_message ON message_deliveries (message_id);
