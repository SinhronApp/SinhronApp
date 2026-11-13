// sinhron_call — Phase 3 (Calls) client-side library.
//
// Two responsibilities, kept in separate modules:
//
//   • [`sframe`] — RFC 9605 §5.2 key derivation. Takes an MLS exporter
//     secret + (sender_index, kid) and produces SFrame key/salt pairs
//     ready to hand off to LiveKit via the platform's custom KeyProvider.
//
//   • [`state`] — call lifecycle FSM. Tracks the local view of a single
//     call (Idle → Inviting → Ringing → Active → Ended) and handles
//     events from the network + UI.
//
// Spec: `design_handoff_sinhron/spec/architecture.md` §10 (calls) +
// `docs/plan-calls.md` (WU-level plan).
//
// What this crate intentionally does NOT do:
//   • No WebRTC / libwebrtc bindings — media transport stays in
//     `livekit_client` (Flutter SDK). Per spec §10.6.
//   • No FFI annotations — the bridge layer lives in `sinhron_core`'s
//     `api/simple.rs`, which calls into this crate as a plain Rust dep.

pub mod sframe;
pub mod state;

pub use sframe::{
    sender_base_key, sframe_key_pair, sframe_epoch_secret, CipherSuite, Kid, SframeError,
    SframeKeyMaterial,
};
pub use state::{Call, CallEvent, CallId, CallRole, CallState, FsmError};
