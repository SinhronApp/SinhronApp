-- ADR-040 addendum — UnifiedPush bodies are encrypted to the phone (Web Push,
-- RFC 8291): its P-256 public key (65 bytes, uncompressed) and 16-byte auth
-- secret come with the endpoint. NULL for APNs tokens.
ALTER TABLE apns_tokens ADD COLUMN IF NOT EXISTS webpush_p256dh BYTEA;
ALTER TABLE apns_tokens ADD COLUMN IF NOT EXISTS webpush_auth BYTEA;
ALTER TABLE apns_tokens DROP CONSTRAINT IF EXISTS apns_tokens_webpush_keys;
ALTER TABLE apns_tokens ADD CONSTRAINT apns_tokens_webpush_keys CHECK (
    (webpush_p256dh IS NULL AND webpush_auth IS NULL)
    OR (length(webpush_p256dh) = 65 AND length(webpush_auth) = 16)
);
