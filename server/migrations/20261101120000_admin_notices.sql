-- ADR-077 — the server's administrator(s).
--
-- 1. Service notices the server writes for its administrators (load
--    alerts and "back to normal", new reports). The server is their
--    author — there is nothing to hide from it; only administrators can
--    read them (signed request, identity listed in
--    SINHRON_ADMIN_IDENTITIES). Kept 30 days.
CREATE TABLE IF NOT EXISTS admin_notices (
    id          BIGSERIAL   PRIMARY KEY,
    kind        TEXT        NOT NULL,
    body        TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT admin_notices_kind CHECK (kind IN ('alert', 'ok', 'report')),
    CONSTRAINT admin_notices_body_len CHECK (length(body) <= 8000)
);
CREATE INDEX IF NOT EXISTS admin_notices_created ON admin_notices (created_at);

-- 2. A report keeps the reporter's IP (from the request) and the reported
--    account's last IP (known only in memory, from its last login) — both
--    wiped after 30 days; the report itself stays. `admin_notified_at`:
--    when the administrators were told (reports filed before this
--    migration count as told).
ALTER TABLE abuse_reports
    ADD COLUMN IF NOT EXISTS reporter_ip TEXT,
    ADD COLUMN IF NOT EXISTS reported_ip TEXT,
    ADD COLUMN IF NOT EXISTS admin_notified_at TIMESTAMPTZ;
UPDATE abuse_reports SET admin_notified_at = NOW() WHERE admin_notified_at IS NULL;
CREATE INDEX IF NOT EXISTS abuse_reports_admin_pending ON abuse_reports (id) WHERE admin_notified_at IS NULL;
