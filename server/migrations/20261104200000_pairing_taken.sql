-- storage-devices:13 follow-up (status 245, ADR-091): a taken pairing
-- keeps a marker for 10 more minutes instead of vanishing. The bundle is
-- wiped (empty ciphertext); any later PUT or GET for that id gets 409
-- "already used", so the old phone learns that someone else answered.
ALTER TABLE pairing_mailbox ADD COLUMN IF NOT EXISTS taken BOOLEAN NOT NULL DEFAULT FALSE;
