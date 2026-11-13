-- server-http:14 / critic:6 (docs/security-review-2026-11.md) — a push token
-- no longer moves to whoever registers it last: another account keeps its own
-- row (registering a known token took it off the victim's phone). Within one
-- account it still moves (handlers/push_tokens.rs).
DROP INDEX IF EXISTS apns_tokens_token_uq;
