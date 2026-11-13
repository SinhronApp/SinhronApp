-- ADR-056 — names in notifications without the server knowing them.
-- A PushKit token may come with the phone's own 32-byte key; call pushes
-- then carry HMAC(key, call id ‖ group id) instead of nothing, and the
-- phone finds which of its chats is calling. Message previews are sealed
-- by the sender and only passed through — nothing is stored for them.
ALTER TABLE apns_tokens ADD COLUMN IF NOT EXISTS call_hint_key BYTEA;
ALTER TABLE apns_tokens DROP CONSTRAINT IF EXISTS apns_tokens_call_hint_key;
ALTER TABLE apns_tokens ADD CONSTRAINT apns_tokens_call_hint_key
    CHECK (call_hint_key IS NULL OR (kind = 'voip' AND length(call_hint_key) = 32));
