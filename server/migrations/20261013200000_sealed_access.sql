-- Tech-debt 2.2 — sealed sender without the sender's connection
-- ("unidentified access", after Signal).
--
-- Each person derives a 16-byte access key from their account secret and
-- gives it only to the people they chat with (inside MLS). The server
-- keeps its SHA-256: an envelope sent WITHOUT authentication
-- (POST /v1/sealed) is accepted for a recipient only with that person's
-- access key, so strangers can't spam them anonymously.
ALTER TABLE users ADD COLUMN IF NOT EXISTS access_hash BYTEA;
