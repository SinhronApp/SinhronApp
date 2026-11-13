-- ADR-043 (short links) — `https://<host>/i/<id>#<key>`.
--
-- The app seals its signed invite link under a key that stays in the
-- link's #fragment (never sent to the server) and leaves the blob here
-- under a random id. The server can't open it: it knows only that an
-- invite was made and when, and who fetched it (IP, time) — not who
-- invites, nor the name. No account is tied to a row. Kept a year; the
-- retention worker deletes expired rows.
CREATE TABLE IF NOT EXISTS short_invites (
    id          TEXT        PRIMARY KEY,
    blob        BYTEA       NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at  TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS short_invites_expires ON short_invites (expires_at);
