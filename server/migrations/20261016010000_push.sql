-- Overnight item 8 — push notifications (APNs).
--
-- urgent: the sender marked this delivery as a real message (not a receipt,
-- "typing" or presence) — only those wake an offline phone and count in
-- its badge. The server can't tell them apart itself (sealed, ADR-023).
ALTER TABLE message_deliveries ADD COLUMN IF NOT EXISTS urgent BOOLEAN NOT NULL DEFAULT false;
CREATE INDEX IF NOT EXISTS message_deliveries_badge
    ON message_deliveries (recipient_user_pk) WHERE received_at IS NULL AND urgent;

-- One APNs token per device and kind ('alert' — messages; 'voip' — calls,
-- PushKit). `sandbox`: the token belongs to Apple's development
-- environment (builds installed from Xcode) rather than production
-- (TestFlight, App Store). Goes with the device.
CREATE TABLE IF NOT EXISTS apns_tokens (
    device_pk  BYTEA       NOT NULL REFERENCES devices(device_pk) ON DELETE CASCADE,
    kind       TEXT        NOT NULL,
    token      TEXT        NOT NULL,
    sandbox    BOOLEAN     NOT NULL DEFAULT false,
    -- The phone's language for the notification text ("New message" /
    -- "Новое сообщение") — the server picks the words, the app has none.
    lang       TEXT        NOT NULL DEFAULT 'en',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (device_pk, kind),
    CONSTRAINT apns_tokens_kind CHECK (kind IN ('alert', 'voip')),
    CONSTRAINT apns_tokens_token CHECK (token ~ '^[0-9a-f]{32,200}$'),
    CONSTRAINT apns_tokens_lang CHECK (lang ~ '^[a-z]{2}$')
);
-- A token moves with a reinstall to whoever registers it last.
CREATE UNIQUE INDEX IF NOT EXISTS apns_tokens_token_uq ON apns_tokens (token, kind);
