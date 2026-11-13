// HTTP handlers. Grouped by domain area as the API grows.
//
// WU A3 adds `identity::register` (POST /v1/identity). Subsequent WUs
// add `keypackages`, `messages`, `media`, `state_backups`, `push` — each
// gets its own submodule when it lands.

pub mod account;
pub mod admin;
pub mod backup_mark;
pub mod call;
pub mod devices;
pub mod groups;
pub mod identity;
pub mod invites;
pub mod keypackages;
pub mod media;
pub mod pairing;
pub mod proof;
pub mod push_tokens;
pub mod join;
pub mod access_keys;
pub mod sealed_keys;
pub mod telegram_stickers;
