-- ADR-057 — Google push (FCM) for Android: a device's token may be
-- `fcm:` + Google's registration token (mixed case, [A-Za-z0-9_:-]); its
-- `call_hint_key` is then the phone's own key FCM bodies are sealed to.
ALTER TABLE apns_tokens DROP CONSTRAINT IF EXISTS apns_tokens_token;
ALTER TABLE apns_tokens ADD CONSTRAINT apns_tokens_token
    CHECK (token ~ '^[0-9a-f]{32,200}$'
        OR (token ~ '^https://' AND length(token) <= 512)
        OR (token ~ '^fcm:[A-Za-z0-9_:-]{20,}$' AND length(token) <= 404));
-- ADR-056 kept the key to VoIP tokens; an FCM token has it for both kinds.
ALTER TABLE apns_tokens DROP CONSTRAINT IF EXISTS apns_tokens_call_hint_key;
ALTER TABLE apns_tokens ADD CONSTRAINT apns_tokens_call_hint_key
    CHECK (call_hint_key IS NULL OR (length(call_hint_key) = 32 AND (kind = 'voip' OR token LIKE 'fcm:%')));
