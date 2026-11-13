// sinhron_sync — MLS-encrypted messaging over the Sinhron WS protocol.
//
// Architecture:
//
//     Dart UI ──────────► sinhron_core (FFI) ─────► sinhron_sync ───┐
//                                                                    │
//      ┌─────────────── sinhron_crypto (MLS engine, ID derivation)   │
//      │                                                              │
//      ├─── SyncClient ─── sinhron_net (WS transport)                 │
//      │                                                              │
//      └─── sinhron_storage (persistent MLS group state)              │
//                                                                    │
//                                                  Server ◄──────────┘
//
// What this crate owns:
//   • `SyncClient` — the user-facing handle. Constructs an MLS identity
//     from the BIP-39 phrase, drives MlsGroup creation / join /
//     send-message / receive-message flows.
//   • The MLS provider — an `OpenMlsRustCrypto` instance (in-memory for
//     v1; backed by sinhron_storage in a later WU).
//   • Coordination with sinhron_net — encrypts outgoing app messages
//     into MLS frames before sending, decrypts incoming Push frames
//     before handing plaintext back to the caller.
//
// What's still stubbed:
//   • Conflict resolution per spec §9.3 — landing in WU C5.
//   • Welcome delivery (today rides over WS Welcome frames; multi-device
//     pairing is §6.5).
//
// What landed in WU C6:
//   • Persistent MLS state via `SinhronProvider` (rust-crypto for
//     signing/HPKE/RNG + `openmls_sqlite_storage` for state). Group
//     ratchets survive process restart.

pub mod identity;
pub mod group;
pub mod client;
pub mod http_api;
pub mod provider;
pub mod media;
pub mod envelope;
pub mod photo;
pub mod link_preview;
pub mod sticker;
pub mod telegram_stickers;
pub mod sealed;
pub mod push_preview;
pub mod call_invite;
pub mod pairing;
pub mod invite;
pub mod transfer;
pub mod backup;
pub mod commit_order;
pub mod card_choice;

/// Tests that open the process-wide storage DB take this first (the DB
/// is one per process; parallel tests would trample each other).
#[cfg(test)]
pub(crate) fn test_db_lock() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    LOCK.lock().unwrap_or_else(|e| e.into_inner())
}

pub use client::{InvitedPerson, SyncClient, SyncClientConfig, SyncError};
pub use group::{GroupHandle, IncomingMessage};
pub use http_api::{HttpApi, HttpError};
pub use provider::{JsonCodec, ProviderError, SinhronProvider};
