-- ADR-037 — deleting an account and reporting abuse (App Store 5.1.1(v), 1.2).
--
-- 1. A deleted account's devices go; media it uploaded stays for the people
--    who received it (their messages still reference it) — the uploader
--    column becomes NULL instead of blocking the delete.
ALTER TABLE media ALTER COLUMN uploaded_by_device DROP NOT NULL;
ALTER TABLE media DROP CONSTRAINT IF EXISTS media_uploaded_by_device_fkey;
ALTER TABLE media ADD CONSTRAINT media_uploaded_by_device_fkey
    FOREIGN KEY (uploaded_by_device) REFERENCES devices(device_pk) ON DELETE SET NULL;

-- 2. Reports for the operator. The reporter chose to share what is in
--    `message_text` (decrypted on their phone); the server never could.
--    Kept identity keys, not user rows: a report outlives a deleted account.
CREATE TABLE IF NOT EXISTS abuse_reports (
    id                 BIGSERIAL   PRIMARY KEY,
    reporter_identity  BYTEA       NOT NULL,
    reported_identity  BYTEA       NOT NULL,
    reason             TEXT        NOT NULL,
    message_text       TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    reviewed_at        TIMESTAMPTZ,
    CONSTRAINT abuse_reports_keys CHECK (octet_length(reporter_identity) = 32 AND octet_length(reported_identity) = 32),
    CONSTRAINT abuse_reports_reason CHECK (reason IN ('spam', 'abuse', 'illegal', 'other')),
    CONSTRAINT abuse_reports_text_len CHECK (message_text IS NULL OR length(message_text) <= 4000)
);
CREATE INDEX IF NOT EXISTS abuse_reports_open ON abuse_reports (created_at) WHERE reviewed_at IS NULL;
CREATE INDEX IF NOT EXISTS abuse_reports_reporter ON abuse_reports (reporter_identity, created_at);
