-- ADR-040 — Android push without Google: a device's "token" may be its
-- UnifiedPush endpoint (an https URL on the operator's ntfy) instead of an
-- APNs hex token. Same table, same kinds (alert = messages, voip = calls).
ALTER TABLE apns_tokens DROP CONSTRAINT IF EXISTS apns_tokens_token;
ALTER TABLE apns_tokens ADD CONSTRAINT apns_tokens_token
    CHECK (token ~ '^[0-9a-f]{32,200}$' OR (token ~ '^https://' AND length(token) <= 512));
