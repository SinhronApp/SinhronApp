// Phase 2 facade — surface sinhron_crypto via frb to Dart.
//
// Per spec §8.4, only `sinhron_core` knows about flutter_rust_bridge.
// Downstream crates (sinhron_crypto, sinhron_storage, …) are plain Rust
// libs; this file is where we wrap them with `#[frb]` annotations.

use base64::prelude::*;
use sinhron_call as call;
use sinhron_crypto as crypto;
use sinhron_net as net;
use sinhron_storage as storage;
use sinhron_sync as sync;
use std::sync::OnceLock;
use tokio::sync::Mutex;

// ─────────────────────────────────────────────────────────────────────
// Diagnostics
// ─────────────────────────────────────────────────────────────────────

/// Library + frb version. Called from Dart at boot to verify the
/// Rust binary is loaded and the FFI bridge works end-to-end.
#[flutter_rust_bridge::frb(sync)]
pub fn core_version() -> String {
    format!(
        "sinhron_core {} · frb {} · rustc {}",
        env!("CARGO_PKG_VERSION"),
        "2.11.1",
        "1.94.1",
    )
}

/// Demo echo retained from the integrate-template for sanity-checking
/// string round-trips. Will be removed in a later step.
#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Hello, {name}!")
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

// ─────────────────────────────────────────────────────────────────────
// BIP-39 recovery phrase
// ─────────────────────────────────────────────────────────────────────

/// Generate a fresh 24-word BIP-39 recovery phrase via OS CSPRNG.
/// English wordlist. Returns space-separated words.
#[flutter_rust_bridge::frb(sync)]
pub fn generate_recovery_phrase() -> String {
    crypto::generate_phrase()
}

/// Validate that [phrase] parses as a BIP-39 mnemonic. True only for
/// valid checksumed phrases (12/15/18/21/24 word lengths supported by
/// the BIP-39 spec). The UI requires 24 words specifically.
#[flutter_rust_bridge::frb(sync)]
pub fn validate_recovery_phrase(phrase: String) -> bool {
    crypto::validate_phrase(&phrase)
}

// ─────────────────────────────────────────────────────────────────────
// HKDF-derived identity (Phase 2 step 2)
// ─────────────────────────────────────────────────────────────────────

/// Derive the user's identity fingerprint per spec §6.2 — a 12-char hex
/// formatted "9a3e 4d12 8b71". Stable across calls for the same phrase.
/// SHA-256 of (Ed25519 public || X25519 public), both derived via HKDF
/// from the BIP-39 seed.
pub fn derive_identity_fingerprint(phrase: String) -> Result<String, String> {
    // ADR-027 — also a linked-device bundle (public keys are in it).
    let a = crypto::identity::account_view(&phrase).map_err(|e| e.to_string())?;
    Ok(crypto::identity::fingerprint_of(&a.ed25519_public, &a.x25519_public))
}

// ─────────────────────────────────────────────────────────────────────
// OpenMLS sanity surface — proof-of-link only
// ─────────────────────────────────────────────────────────────────────

/// Summary of the full Alice↔Bob MLS smoke flow.
pub struct MlsDemoResult {
    pub ciphersuite: String,
    pub epoch_after_add: u64,
    pub members: Vec<String>,
    pub alice_to_bob: String,
    pub bob_to_alice: String,
}

// ─────────────────────────────────────────────────────────────────────
// Local storage (sinhron_storage · SQLite via rusqlite)
// ─────────────────────────────────────────────────────────────────────

/// Open / create the local SQLite database at [path]. Idempotent.
/// ADR-021: a key that doesn't open the file returns an error starting
/// with `storage locked` and leaves the file alone.
/// Typically called from Dart's `main()` after `RustLib.init()` with
/// `getApplicationDocumentsDirectory()` / sinhron.db.
///
/// **T1.1 — SQLCipher**: `key_hex` is a 64-char hex string of the
/// 32-byte AES-256 key (typically `DerivedIdentity::storage_key`
/// rendered as hex). Empty string = open unencrypted (boot-time
/// default — Dart doesn't have the phrase yet). After the user enters
/// their phrase the caller invokes [`storage_rekey`] to seal the plain
/// DB into an encrypted one without data loss.
pub fn storage_init(path: String, key_hex: String) -> Result<(), String> {
    let key_bytes = if key_hex.is_empty() {
        None
    } else {
        let arr = parse_storage_key_hex(&key_hex).map_err(|e| format!("invalid key_hex: {e}"))?;
        Some(arr)
    };
    storage::open(std::path::Path::new(&path), key_bytes.as_ref())
        .map_err(|e| e.to_string())?;
    dns_cache_attach();
    Ok(())
}

/// ADR-072 — the checked server addresses (DoH fallback) live in the
/// encrypted settings table: loaded when the DB opens, written on change.
const DNS_CACHE_SETTING: &str = "net_dns_cache";

fn dns_cache_attach() {
    let dns = net::dns::global();
    if let Ok(Some(json)) = storage::setting_get(DNS_CACHE_SETTING) {
        dns.load(&json);
    }
    dns.set_persist(Some(std::sync::Arc::new(|json: String| {
        if let Err(e) = storage::setting_set(DNS_CACHE_SETTING, &json) {
            tracing::warn!(error = %e, "dns cache not saved");
        }
    })));
}

/// ADR-072 — for connections Dart makes itself (LiveKit signalling, the
/// APK update): the address to connect to INSTEAD of the system answer
/// for one of our hosts, when that answer failed the certificate check
/// (DoH / a remembered address). `None` = resolve as usual. Dart still
/// runs TLS with our host name, so the certificate is checked as before.
pub async fn net_dns_override(host: String, port: u16) -> Option<String> {
    net::dns::global().override_for(&host, port).await.map(|ip| ip.to_string())
}

/// ADR-072 — mark the host of an https/wss URL as ours (Dart: the server
/// address the person typed, before any Rust call has seen it).
#[flutter_rust_bridge::frb(sync)]
pub fn net_dns_add_our_host(url: String) {
    net::dns::global().add_our_host(&url);
}

/// CRIT-1.1 — convert the currently-open (plain) chats DB at its known
/// path into an SQLCipher-encrypted DB sealed with the phrase-derived
/// storage key. Idempotent in the success case: a subsequent call
/// won't find a plain DB to migrate (the singleton points at the
/// encrypted file). Callers should invoke this exactly once at the end
/// of onboarding, AFTER `storage_save_phrase` (so the identity row is
/// already present and survives the migration).
///
/// `key_hex` is the same 64-char hex storage key the next boot will
/// pass to `storage_init` — derived from the BIP-39 phrase via HKDF
/// (sinhron_crypto::identity::DerivedIdentity::storage_key). Wrong key
/// here = data inaccessible on next boot. Caller MUST verify the key
/// matches what they'll persist for future opens.
pub fn storage_rekey(key_hex: String) -> Result<(), String> {
    let key = parse_storage_key_hex(&key_hex).map_err(|e| format!("invalid key_hex: {e}"))?;
    storage::migrate_unencrypted_to_encrypted(&key).map_err(|e| e.to_string())
}

/// ADR-021 — the device key for [phrase]: what the app keeps in the
/// iOS Keychain instead of the phrase. Every FFI call below that takes
/// a `phrase` also accepts this key (`sinhron-device-key:v1:<seed hex>`).
pub fn device_key_from_phrase(phrase: String) -> Result<String, String> {
    crypto::identity::device_key_from_phrase(&phrase).map_err(|e| e.to_string())
}

/// ADR-021 — erase the local chats DB (user chose "start over" on the
/// unlock screen, or signed out) and open a fresh plain one at [path].
pub fn storage_erase(path: String) -> Result<(), String> {
    storage::erase_and_reopen_plain(std::path::Path::new(&path)).map_err(|e| e.to_string())?;
    forget_deliveries(); // CR-1 — after the saved cursor is gone with the database
    Ok(())
}

/// Derive the SQLCipher storage key (64-char hex) from a BIP-39 phrase
/// or a device key (ADR-021).
/// Used by Dart to compute the key that's then passed to [`storage_rekey`]
/// or [`storage_init`]. Phrase stays Rust-side after this call returns.
pub fn derive_storage_key_hex(phrase: String) -> Result<String, String> {
    // ADR-027 — a linked-device bundle has its own storage key.
    let a = crypto::identity::account_view(&phrase).map_err(|e| e.to_string())?;
    Ok(hex::encode(a.storage_key))
}

/// Decode a 64-char hex string to `[u8; 32]`. Used internally for
/// SQLCipher PRAGMA key. Rejects anything that isn't exactly 32 bytes.
fn parse_storage_key_hex(s: &str) -> Result<[u8; 32], String> {
    let bytes = hex::decode(s).map_err(|e| e.to_string())?;
    if bytes.len() != 32 {
        return Err(format!("expected 32 bytes, got {}", bytes.len()));
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

/// Save the user's identity to the local DB. Derives all keys from
/// [phrase] (HKDF + Ed25519 + X25519), stores their public parts +
/// fingerprint + phrase hash. The phrase ITSELF is never stored —
/// only the SHA-256 hash, so we can detect "same phrase signed in
/// again" without retaining the secret.
pub fn storage_save_phrase(phrase: String) -> Result<String, String> {
    // ADR-027 — a linked-device bundle works too (public keys only).
    let id = crypto::identity::account_view(&phrase).map_err(|e| e.to_string())?;
    let fp = crypto::identity::fingerprint_of(&id.ed25519_public, &id.x25519_public);
    let ed_pub = hex::encode(id.ed25519_public);
    let x_pub = hex::encode(id.x25519_public);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    storage::save_identity(&phrase, &fp, &ed_pub, &x_pub, now)
        .map_err(|e| e.to_string())?;
    Ok(fp)
}

/// Stored identity for the FFI surface.
pub struct StoredIdentitySummary {
    pub fingerprint: String,
    pub ed25519_pub_hex: String,
    pub x25519_pub_hex: String,
    pub created_at_unix: i64,
}

/// Load the most recently saved identity, or None if none exists
/// (fresh install / pre-onboarding).
pub fn storage_load_identity() -> Result<Option<StoredIdentitySummary>, String> {
    let row = storage::load_latest_identity().map_err(|e| e.to_string())?;
    Ok(row.map(|r| StoredIdentitySummary {
        fingerprint: r.fingerprint,
        ed25519_pub_hex: r.ed25519_pub_hex,
        x25519_pub_hex: r.x25519_pub_hex,
        created_at_unix: r.created_at_unix,
    }))
}

// ─────────────────────────────────────────────────────────────────────
// Chats & messages (sinhron_storage · WU 73)
// ─────────────────────────────────────────────────────────────────────

/// Materialized chat row for the FFI surface — mirrors storage::StoredChat.
pub struct StoredChatSummary {
    pub id: String,
    pub display_name: String,
    pub is_group: bool,
    pub muted: bool,
    pub pinned: bool,
    pub unread_count: i64,
    pub last_msg_preview: Option<String>,
    pub last_msg_ts_unix: i64,
    pub last_msg_kind: String,
    pub last_msg_sender_label: Option<String>,
    pub last_msg_mine: bool,
    pub created_at_unix: i64,
    pub archived: bool,
    pub pin_order: i64,
    pub draft: Option<String>,
    pub marked_unread: bool,
    /// v7 — wire id of the message pinned in this chat.
    pub pinned_msg: Option<String>,
    /// v8 — disappearing-message timer (seconds, 0 = off).
    pub disappear_secs: i64,
    /// Status of the newest message if it's mine (0..3), else 0 — list ticks.
    pub last_msg_status: i64,
    /// v11 — a message request (someone else started the chat; not accepted).
    pub request: bool,
    /// v13 — an unread message here @-mentions me.
    pub mentioned: bool,
    /// v14 — personal chats: the other person's identity key, once known.
    pub peer_id: Option<String>,
}

/// Materialized message row.
pub struct StoredMessageSummary {
    pub id: String,
    pub chat_id: String,
    pub ts_unix: i64,
    pub body: String,
    pub kind: String,
    pub is_mine: bool,
    pub sender_label: Option<String>,
    /// Media envelope JSON for photo / voice / document rows (keys
    /// inside — never leaves the encrypted DB except via `media_*`).
    pub media_json: Option<String>,
    /// v7 / ADR-019 — see `sinhron_storage::StoredMessage`.
    pub wire_id: Option<String>,
    pub status: i64,
    pub reply_json: Option<String>,
    pub edited_ts: Option<i64>,
    pub deleted: bool,
    pub reactions_json: Option<String>,
    pub sender_id: Option<String>,
    /// v8 — disappears at this unix time.
    pub expire_at: Option<i64>,
    /// v17 / ADR-070 — formatting of `body` (`[]` = plain); None = an
    /// older app's message (its `*stars*` may be markers).
    pub entities_json: Option<String>,
}

impl From<storage::StoredMessage> for StoredMessageSummary {
    fn from(r: storage::StoredMessage) -> Self {
        Self {
            id: r.id,
            chat_id: r.chat_id,
            ts_unix: r.ts_unix,
            body: r.body,
            kind: r.kind,
            is_mine: r.is_mine,
            sender_label: r.sender_label,
            media_json: r.media_json,
            wire_id: r.wire_id,
            status: r.status,
            reply_json: r.reply_json,
            edited_ts: r.edited_ts,
            deleted: r.deleted,
            reactions_json: r.reactions_json,
            sender_id: r.sender_id,
            expire_at: r.expire_at,
            entities_json: r.entities_json,
        }
    }
}

/// A new message row from Dart (ADR-019). `wire_id` is the UUID sent
/// to the server; `reply_json` the quote; `sender_id` the authenticated
/// sender of an incoming message.
pub struct NewMessageRow {
    pub id: String,
    pub chat_id: String,
    pub ts_unix: i64,
    pub body: String,
    pub kind: String,
    pub is_mine: bool,
    pub sender_label: Option<String>,
    pub media_json: Option<String>,
    pub wire_id: Option<String>,
    pub reply_json: Option<String>,
    pub sender_id: Option<String>,
    pub expire_at: Option<i64>,
    /// ADR-070 — formatting of `body` (see [`NetPush::entities_json`]);
    /// None = an older app's message.
    pub entities_json: Option<String>,
}

pub fn storage_message_insert(row: NewMessageRow) -> Result<(), String> {
    let entities = stored_entities(&row.body, row.entities_json.as_deref());
    storage::message_insert(&storage::NewMessage {
        id: &row.id,
        chat_id: &row.chat_id,
        ts_unix: row.ts_unix,
        body: &row.body,
        kind: &row.kind,
        is_mine: row.is_mine,
        sender_label: row.sender_label.as_deref(),
        media_json: row.media_json.as_deref(),
        wire_id: row.wire_id.as_deref(),
        reply_json: row.reply_json.as_deref(),
        sender_id: row.sender_id.as_deref(),
        expire_at: row.expire_at,
        entities_json: entities.as_deref(),
    })
    .map_err(|e| e.to_string())
}

/// ADR-070 — formatting JSON as it's stored: re-parsed and cleaned for
/// [text] (what's kept is what renders); a broken one stores as no
/// formatting (`[]`), None stays None (an older app's message).
fn stored_entities(text: &str, json: Option<&str>) -> Option<String> {
    let json = json?;
    let entities = sync::envelope::entities_from_json(text, json).unwrap_or_default();
    Some(sync::envelope::entities_to_json(&entities))
}

/// Backlog §6 item 51 — a chat's disappearing timer (0 = off).
pub fn storage_chat_set_disappear(chat_id: String, secs: i64) -> Result<(), String> {
    storage::chat_set_disappear(&chat_id, secs).map_err(|e| e.to_string())
}

/// Someone's own display name (tech-debt 2.22).
pub struct PeerName {
    pub peer_id: String,
    pub name: String,
}

/// Remember a peer's display name; returns whether it changed.
pub fn storage_peer_name_set(peer_id: String, name: String, ts_unix: i64) -> Result<bool, String> {
    let name = sync::envelope::clean_profile_name(&name).ok_or("empty or too long name")?;
    storage::peer_name_set(&peer_id, &name, ts_unix).map_err(|e| e.to_string())
}

/// Someone's photo (a JPEG this device re-encoded itself).
pub struct PeerAvatar {
    pub peer_id: String,
    pub jpeg: Vec<u8>,
}

/// Tech-debt 2.21 — store the photo that came in someone's `profile`.
/// Never trusted as is: decoded and re-encoded here (metadata gone,
/// ≤32 KB); an empty or undecodable image removes it. Returns whether it
/// changed.
pub fn storage_peer_avatar_set(peer_id: String, image: Vec<u8>, ts_unix: i64) -> Result<bool, String> {
    let jpeg = if image.is_empty() {
        Vec::new()
    } else {
        sync::photo::prepare_avatar(&image).unwrap_or_default()
    };
    storage::peer_avatar_set(&peer_id, &jpeg, ts_unix).map_err(|e| e.to_string())
}

pub fn storage_peer_avatars() -> Result<Vec<PeerAvatar>, String> {
    Ok(storage::peer_avatars()
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|(peer_id, jpeg)| PeerAvatar { peer_id, jpeg })
        .collect())
}

/// My own photo for the profile: re-encoded like any photo (EXIF/GPS
/// gone), ≤32 KB — that is what goes out in `profile`.
pub fn media_avatar_prepare(image: Vec<u8>) -> Result<Vec<u8>, String> {
    sync::photo::prepare(&image).map(|p| p.thumbnail).map_err(|e| e.to_string())
}

/// A personal chat's other person (learned from their `profile`).
pub fn storage_chat_set_peer(chat_id: String, peer_id: String) -> Result<(), String> {
    storage::chat_set_peer(&chat_id, &peer_id).map_err(|e| e.to_string())
}

pub fn storage_peer_names() -> Result<Vec<PeerName>, String> {
    Ok(storage::peer_names()
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|(peer_id, name)| PeerName { peer_id, name })
        .collect())
}

/// Someone's bio ("About"), from their `profile` (ADR-052).
pub struct PeerBio {
    pub peer_id: String,
    pub bio: String,
}

/// ADR-052 — store the bio that came in someone's `profile` (cleaned again
/// here); empty forgets it. Returns whether it changed.
pub fn storage_peer_bio_set(peer_id: String, bio: String, ts_unix: i64) -> Result<bool, String> {
    storage::peer_bio_set(&peer_id, &sync::envelope::clean_profile_bio(&bio), ts_unix).map_err(|e| e.to_string())
}

pub fn storage_peer_bios() -> Result<Vec<PeerBio>, String> {
    Ok(storage::peer_bios()
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|(peer_id, bio)| PeerBio { peer_id, bio })
        .collect())
}

/// One person in my contacts (ADR-052).
pub struct StoredContact {
    /// Identity key, lower-case hex.
    pub peer_id: String,
    /// The name I first knew them by ('' = none); their own name wins.
    pub name: String,
    pub favourite: bool,
    pub added_ts: i64,
}

/// ADR-052 — contacts are their own list (deleting a chat keeps them).
pub fn storage_contacts() -> Result<Vec<StoredContact>, String> {
    Ok(storage::contacts_list()
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|c| StoredContact { peer_id: c.peer_id, name: c.name, favourite: c.favourite, added_ts: c.added_ts })
        .collect())
}

/// Add someone to my contacts; returns whether they were new. [name] is
/// kept only while there is no other (cleaned like a display name).
pub fn storage_contact_add(peer_id: String, name: String, ts_unix: i64) -> Result<bool, String> {
    let name = sync::envelope::clean_profile_name(&name).unwrap_or_default();
    storage::contact_add(&peer_id, &name, ts_unix).map_err(|e| e.to_string())
}

/// Remove someone from my contacts (their chats stay).
pub fn storage_contact_remove(peer_id: String) -> Result<bool, String> {
    storage::contact_remove(&peer_id).map_err(|e| e.to_string())
}

pub fn storage_contact_set_favourite(peer_id: String, favourite: bool) -> Result<bool, String> {
    storage::contact_set_favourite(&peer_id, favourite).map_err(|e| e.to_string())
}

/// The display name we last announced in a chat.
pub fn storage_chat_profile_sent(chat_id: String) -> Result<Option<String>, String> {
    storage::chat_profile_sent(&chat_id).map_err(|e| e.to_string())
}

pub fn storage_chat_set_profile_sent(chat_id: String, name: String) -> Result<(), String> {
    storage::chat_set_profile_sent(&chat_id, &name).map_err(|e| e.to_string())
}

/// Block / unblock a person on this device (tech-debt 2.27).
pub fn storage_peer_set_blocked(peer_id: String, blocked: bool, ts_unix: i64) -> Result<(), String> {
    storage::peer_set_blocked(&peer_id, blocked, ts_unix).map_err(|e| e.to_string())
}

pub fn storage_peers_blocked() -> Result<Vec<String>, String> {
    storage::peers_blocked().map_err(|e| e.to_string())
}

/// Delete expired messages; returns the chats that changed.
pub fn storage_messages_expire(now_unix: i64) -> Result<Vec<String>, String> {
    storage::messages_expire(now_unix).map_err(|e| e.to_string())
}

/// Server acks for my messages (1 = sent, -1 = failed).
pub fn storage_messages_raise_status(wire_ids: Vec<String>, status: i64) -> Result<u32, String> {
    storage::messages_raise_status(&wire_ids, status).map(|n| n as u32).map_err(|e| e.to_string())
}

/// A peer's delivery (2) / read (3) receipt for my messages in a chat.
pub fn storage_messages_raise_status_in_chat(chat_id: String, wire_ids: Vec<String>, status: i64) -> Result<u32, String> {
    storage::messages_raise_status_in_chat(&chat_id, &wire_ids, status)
        .map(|n| n as u32)
        .map_err(|e| e.to_string())
}

fn author(peer: &Option<String>) -> storage::Author<'_> {
    match peer {
        None => storage::Author::Me,
        Some(p) => storage::Author::Peer(p),
    }
}

/// Edit by its author: `peer_sender_id` None = me, else the incoming
/// edit's authenticated sender. Returns whether anything changed.
///
/// ADR-070 — `entities_json`: the new formatting (cleaned again here);
/// None = an older app's edit.
pub fn storage_message_apply_edit(
    chat_id: String,
    wire_id: String,
    peer_sender_id: Option<String>,
    text: String,
    edited_ts: i64,
    entities_json: Option<String>,
) -> Result<bool, String> {
    let entities = stored_entities(&text, entities_json.as_deref());
    storage::message_apply_edit(&chat_id, &wire_id, author(&peer_sender_id), &text, entities.as_deref(), edited_ts)
        .map_err(|e| e.to_string())
}

/// Delete for everyone, by its author (see [`storage_message_apply_edit`]),
/// within [`storage::EDIT_WINDOW_SECS`] of sending.
pub fn storage_message_apply_delete(
    chat_id: String,
    wire_id: String,
    peer_sender_id: Option<String>,
    now_unix: i64,
) -> Result<bool, String> {
    storage::message_apply_delete(&chat_id, &wire_id, author(&peer_sender_id), now_unix).map_err(|e| e.to_string())
}

/// Delete for me (rows on this device only).
pub fn storage_messages_delete_local(chat_id: String, ids: Vec<String>) -> Result<(), String> {
    storage::messages_delete_local(&chat_id, &ids).map_err(|e| e.to_string())
}

/// `reactor` = "me" or a sender id; `emoji` None/empty removes.
pub fn storage_message_set_reaction(
    chat_id: String,
    wire_id: String,
    reactor: String,
    emoji: Option<String>,
) -> Result<bool, String> {
    storage::message_set_reaction(&chat_id, &wire_id, &reactor, emoji.as_deref()).map_err(|e| e.to_string())
}

pub fn storage_messages_pending_receipts(chat_id: String, below: i64, limit: i64) -> Result<Vec<String>, String> {
    storage::messages_pending_receipts(&chat_id, below, limit).map_err(|e| e.to_string())
}

/// Status 213 — "Message info": [peer] got (or read) these messages of mine.
pub fn storage_receipts_record(chat_id: String, wire_ids: Vec<String>, peer: String, read: bool, ts_unix: i64) -> Result<(), String> {
    storage::receipts_record(&chat_id, &wire_ids, &peer, read, ts_unix).map_err(|e| e.to_string())
}

/// One person's receipt for a message of mine (unix seconds; None = not yet).
pub struct StoredReceipt {
    pub peer: String,
    pub delivered_at: Option<i64>,
    pub read_at: Option<i64>,
}

/// Who got / read my message [wire_id].
pub fn storage_receipts_for(wire_id: String) -> Result<Vec<StoredReceipt>, String> {
    Ok(storage::receipts_for(&wire_id)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|r| StoredReceipt { peer: r.peer, delivered_at: r.delivered_at, read_at: r.read_at })
        .collect())
}

pub fn storage_messages_mark_receipted(chat_id: String, wire_ids: Vec<String>, status: i64) -> Result<(), String> {
    storage::messages_mark_receipted(&chat_id, &wire_ids, status).map_err(|e| e.to_string())
}

pub fn storage_chat_set_pinned_message(chat_id: String, wire_id: Option<String>) -> Result<(), String> {
    storage::chat_set_pinned_message(&chat_id, wire_id.as_deref()).map_err(|e| e.to_string())
}

/// Insert or replace a chat row. Used by Compose flow (new 1:1 chat),
/// the future group-create flow, and incoming-sync once net lands.
#[allow(clippy::too_many_arguments)]
pub fn storage_chat_upsert(
    id: String,
    display_name: String,
    is_group: bool,
    muted: bool,
    pinned: bool,
    unread_count: i64,
    last_msg_preview: Option<String>,
    last_msg_ts_unix: i64,
    last_msg_kind: String,
    last_msg_sender_label: Option<String>,
    last_msg_mine: bool,
    created_at_unix: i64,
) -> Result<(), String> {
    storage::chat_upsert(
        &id,
        &display_name,
        is_group,
        muted,
        pinned,
        unread_count,
        last_msg_preview.as_deref(),
        last_msg_ts_unix,
        &last_msg_kind,
        last_msg_sender_label.as_deref(),
        last_msg_mine,
        created_at_unix,
    )
    .map_err(|e| e.to_string())
}

/// Return all chats, ordered pinned-first then most-recently-active.
pub fn storage_chats_list() -> Result<Vec<StoredChatSummary>, String> {
    let rows = storage::chats_list().map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|r| StoredChatSummary {
            id: r.id,
            display_name: r.display_name,
            is_group: r.is_group,
            muted: r.muted,
            pinned: r.pinned,
            unread_count: r.unread_count,
            last_msg_preview: r.last_msg_preview,
            last_msg_ts_unix: r.last_msg_ts_unix,
            last_msg_kind: r.last_msg_kind,
            last_msg_sender_label: r.last_msg_sender_label,
            last_msg_mine: r.last_msg_mine,
            created_at_unix: r.created_at_unix,
            archived: r.archived,
            pin_order: r.pin_order,
            draft: r.draft,
            marked_unread: r.marked_unread,
            pinned_msg: r.pinned_msg,
            disappear_secs: r.disappear_secs,
            last_msg_status: r.last_msg_status,
            request: r.request,
            mentioned: r.mentioned,
            peer_id: r.peer_id,
        })
        .collect())
}

/// Mark that an unread message in this chat @-mentions me.
pub fn storage_chat_set_mentioned(id: String) -> Result<(), String> {
    storage::chat_set_mentioned(&id).map_err(|e| e.to_string())
}

/// Rename a personal chat only while it has the placeholder name [from].
pub fn storage_chat_rename_if(chat_id: String, from: String, to: String) -> Result<bool, String> {
    storage::chat_rename_if(&chat_id, &from, &to).map_err(|e| e.to_string())
}

/// ADR-034 — a group's name from a member (see `storage::chat_set_group_name`).
pub fn storage_chat_set_group_name(chat_id: String, name: String, placeholders: Vec<String>) -> Result<bool, String> {
    storage::chat_set_group_name(&chat_id, &name, &placeholders).map_err(|e| e.to_string())
}

/// Unpin [wire_id] only if it is the pinned message (compare-and-clear).
pub fn storage_chat_unpin_if(chat_id: String, wire_id: String) -> Result<bool, String> {
    storage::chat_unpin_if(&chat_id, &wire_id).map_err(|e| e.to_string())
}

/// Mark a chat as a message request, or accept it (tech-debt 2.27).
/// ADR-074 — move chat [from]'s messages into [to] and drop [from].
pub fn storage_chat_merge_into(from: String, to: String) -> Result<u32, String> {
    storage::chat_merge_into(&from, &to).map(|n| n as u32).map_err(|e| e.to_string())
}

pub fn storage_chat_set_request(id: String, request: bool) -> Result<(), String> {
    storage::chat_set_request(&id, request).map_err(|e| e.to_string())
}

pub fn storage_chat_set_muted(id: String, muted: bool) -> Result<(), String> {
    storage::chat_set_muted(&id, muted).map_err(|e| e.to_string())
}

pub fn storage_chat_set_archived(id: String, archived: bool) -> Result<(), String> {
    storage::chat_set_archived(&id, archived).map_err(|e| e.to_string())
}

pub fn storage_chat_set_pinned(id: String, pinned: bool) -> Result<(), String> {
    storage::chat_set_pinned(&id, pinned).map_err(|e| e.to_string())
}

/// New pinned order, first = top.
pub fn storage_chats_reorder_pinned(ids: Vec<String>) -> Result<(), String> {
    storage::chats_reorder_pinned(&ids).map_err(|e| e.to_string())
}

pub fn storage_chat_mark_read(id: String) -> Result<(), String> {
    storage::chat_mark_read(&id).map_err(|e| e.to_string())
}

pub fn storage_chat_mark_unread(id: String) -> Result<(), String> {
    storage::chat_mark_unread(&id).map_err(|e| e.to_string())
}

/// Save the composer draft (None / blank clears it).
pub fn storage_chat_set_draft(id: String, draft: Option<String>) -> Result<(), String> {
    storage::chat_set_draft(&id, draft.as_deref()).map_err(|e| e.to_string())
}

pub fn storage_chat_delete(id: String) -> Result<(), String> {
    storage::chat_delete(&id).map_err(|e| e.to_string())
}

/// A local message-search hit.
pub struct MessageSearchHit {
    pub message_id: String,
    pub chat_id: String,
    pub chat_name: String,
    pub ts_unix: i64,
    pub body: String,
    /// Scroll target in the chat view; None for old local-only rows.
    pub wire_id: Option<String>,
}

/// Search decrypted message text in the local encrypted DB (never the
/// server). Newest first.
pub fn storage_messages_search(query: String, limit: i64) -> Result<Vec<MessageSearchHit>, String> {
    let hits = storage::messages_search(&query, limit).map_err(|e| e.to_string())?;
    Ok(hits
        .into_iter()
        .map(|h| MessageSearchHit {
            message_id: h.message_id,
            chat_id: h.chat_id,
            chat_name: h.chat_name,
            ts_unix: h.ts_unix,
            body: h.body,
            wire_id: h.wire_id,
        })
        .collect())
}

/// Append a message AND update the parent chat's denormalized last_msg
/// columns in one transaction. Returns Err if the parent chat is missing.
pub fn storage_message_append(
    id: String,
    chat_id: String,
    ts_unix: i64,
    body: String,
    kind: String,
    is_mine: bool,
    sender_label: Option<String>,
) -> Result<(), String> {
    storage::message_append(
        &id,
        &chat_id,
        ts_unix,
        &body,
        &kind,
        is_mine,
        sender_label.as_deref(),
    )
    .map_err(|e| e.to_string())
}

/// One page of history for the lazy chat view (oldest-first): the
/// newest `limit` messages, or those strictly older than the cursor
/// (`before_ts_unix` + `before_id`, i.e. the oldest message loaded).
pub fn storage_messages_page(
    chat_id: String,
    before_ts_unix: Option<i64>,
    before_id: Option<String>,
    limit: i64,
) -> Result<Vec<StoredMessageSummary>, String> {
    let before = match (before_ts_unix, before_id.as_deref()) {
        (Some(ts), Some(id)) => Some((ts, id)),
        _ => None,
    };
    let rows = storage::messages_page(&chat_id, before, limit).map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(StoredMessageSummary::from)
        .collect())
}

/// List messages for [chat_id], oldest-first (display order in ChatView).
/// If [limit] is Some, returns only the most-recent N messages (still
/// oldest-first within that slice).
pub fn storage_messages_list(
    chat_id: String,
    limit: Option<i64>,
) -> Result<Vec<StoredMessageSummary>, String> {
    let rows = storage::messages_list_for_chat(&chat_id, limit).map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(StoredMessageSummary::from)
        .collect())
}

// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// Networking (sinhron_net · WU B4)
// ─────────────────────────────────────────────────────────────────────
//
// The Flutter side drives the WS protocol via three functions:
//   1. `net_connect(url, identity_seed)` — start the singleton WsClient
//   2. `net_send_submit(group_id, ciphertext, message_id)` — outbound
//      Submit frame (server persists + fans out per WU A6)
//   3. `net_next_event()` — poll for the next Connected / Disconnected /
//      Push event. Caller loops this in a Dart isolate; received Push
//      bodies feed `messagesProvider` via `ref.invalidate`.
//
// One client per process — matches the single-identity assumption of
// the current app. Stored behind `OnceLock<Mutex<WsClient>>` so all FFI
// callers see the same connection.

static NET_CLIENT: OnceLock<Mutex<Option<net::WsClient>>> = OnceLock::new();

pub(crate) fn net_slot() -> &'static Mutex<Option<net::WsClient>> {
    NET_CLIENT.get_or_init(|| Mutex::new(None))
}

/// Convenience: derive the Ed25519 identity seed from a BIP-39 phrase
/// and start the WS client. Phrase stays Rust-side — Dart only sees the
/// boolean success/failure. Useful at the end of onboarding, where the
/// Dart side has the phrase in memory exactly once and we want to
/// connect without round-tripping the seed bytes back through FFI.
pub async fn net_connect_from_phrase(url: String, phrase: String) -> Result<(), String> {
    // The key the SyncClient signs account requests with: the identity
    // key, or — ADR-027, a QR-paired device — its own device key (the
    // server accepts it while the device isn't revoked).
    let seed = match sync_slot().lock().await.as_ref() {
        Some(c) => c.login_seed_bytes(),
        None => {
            crypto::identity::derive_identity(&phrase).map_err(|e| e.to_string())?.ed25519_secret
        }
    };
    start_with_seed(url, seed).await
}

async fn start_with_seed(url: String, seed: [u8; 32]) -> Result<(), String> {
    let mut slot = net_slot().lock().await;
    if let Some(prev) = slot.take() {
        prev.shutdown();
    }
    // WU B3: pinning hook. If `SINHRON_PINNED_CA_PEM` is set at compile
    // time via `--cfg sinhron_pinned_ca`, the production build can
    // override this `tls: None` default with a real `TlsPinning`. For
    // dev `ws://localhost` traffic there's nothing to pin, so the
    // default is correct.
    let client = net::WsClient::start(net::WsClientConfig {
        url,
        identity_seed: seed,
        tls: pinned_tls_from_env_or_none(),
        resume_cursor: Some(resume_cursor()),
    });
    client.set_background(NET_BACKGROUND.load(std::sync::atomic::Ordering::SeqCst));
    *slot = Some(client);
    Ok(())
}

/// Battery 2026-10-18 — set by [`net_set_background`]; a client started
/// later (a reconnect from the app) picks it up.
static NET_BACKGROUND: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The app keeps its connection while not on screen (Android "always
/// connected", ADR-040): `true` = heartbeat every 120 s instead of 20 s
/// (once the server agrees) — each one wakes the mobile radio. `false` on
/// screen and during a call.
pub async fn net_set_background(background: bool) {
    NET_BACKGROUND.store(background, std::sync::atomic::Ordering::SeqCst);
    if let Some(c) = net_slot().lock().await.as_ref() {
        c.set_background(background);
    }
}

/// The phone's network changed (Android `ConnectivityManager`): reconnect
/// on the new one now instead of waiting for the old socket to time out.
pub async fn net_network_changed() {
    if let Some(c) = net_slot().lock().await.as_ref() {
        c.network_changed();
    }
}

/// Bug 2026-10-16 (owner: "my friend doesn't see my messages, I see his") —
/// the last delivery sequence this app consumed (decrypted in
/// [`net_next_event`]). Every connection resumes from it, so what a dead
/// connection swallowed (the server counted it as received) comes again.
/// One per process; kept in the settings table so a restart keeps it.
const RESUME_CURSOR_KEY: &str = "net_resume_cursor";

fn resume_cursor() -> std::sync::Arc<std::sync::atomic::AtomicU64> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static CURSOR: std::sync::OnceLock<std::sync::Arc<AtomicU64>> = std::sync::OnceLock::new();
    let c = CURSOR.get_or_init(|| std::sync::Arc::new(AtomicU64::new(0))).clone();
    // The settings table opens at boot (it may not be open on the very
    // first call): pick the saved value up as soon as it's readable.
    if c.load(Ordering::SeqCst) == 0 {
        if let Some(v) = storage::setting_get(RESUME_CURSOR_KEY).ok().flatten().and_then(|v| v.parse::<u64>().ok()) {
            c.fetch_max(v, Ordering::SeqCst);
        }
    }
    c
}

type SeenDeliveries = (std::collections::HashSet<u64>, std::collections::VecDeque<u64>);

fn seen_deliveries() -> std::sync::MutexGuard<'static, SeenDeliveries> {
    static SEEN: std::sync::OnceLock<std::sync::Mutex<SeenDeliveries>> = std::sync::OnceLock::new();
    match SEEN.get_or_init(Default::default).lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    }
}

/// CR-1 — the account on this phone is erased (sign out): the next account's
/// deliveries are numbered afresh — with the old cursor and the old "seen"
/// numbers part of its incoming messages would be dropped until a restart.
fn forget_deliveries() {
    resume_cursor().store(0, std::sync::atomic::Ordering::SeqCst);
    *seen_deliveries() = Default::default();
}

/// True the first time this run sees delivery [sequence]; false for a
/// copy (the backlog and a Resume replay can overlap). Exact, not "below
/// the cursor": a live push can overtake an older backlog row.
fn first_delivery(sequence: u64) -> bool {
    const KEEP: usize = 8192;
    let mut g = seen_deliveries();
    if !g.0.insert(sequence) {
        return false;
    }
    g.1.push_back(sequence);
    if g.1.len() > KEEP {
        if let Some(old) = g.1.pop_front() {
            g.0.remove(&old);
        }
    }
    true
}

#[cfg(test)]
mod forget_deliveries_tests {
    use super::*;

    /// CR-1 — after a sign-out the same delivery numbers are new again.
    #[test]
    fn a_new_account_starts_with_no_seen_deliveries() {
        let n = 9_000_000_000_000; // not a number another test uses
        assert!(first_delivery(n));
        assert!(!first_delivery(n), "a copy in the same account");
        resume_cursor().fetch_max(n, std::sync::atomic::Ordering::SeqCst);
        forget_deliveries();
        assert!(first_delivery(n), "the next account's delivery with that number is new");
        assert!(resume_cursor().load(std::sync::atomic::Ordering::SeqCst) < n);
    }
}

/// The app consumed the delivery with this sequence: move the cursor on
/// (never back) and keep it.
fn note_consumed(sequence: u64) {
    use std::sync::atomic::Ordering;
    let c = resume_cursor();
    if c.fetch_max(sequence, Ordering::SeqCst) < sequence {
        let _ = storage::setting_set(RESUME_CURSOR_KEY, &sequence.to_string());
    }
}

/// Build a `TlsPinning` from the `SINHRON_PINNED_CA_PEM` environment
/// variable read at FFI boot (set at build time via Cargo or at runtime
/// via Flutter `--dart-define`-passed env). Returns `None` if the var
/// is unset or empty — the WS client then uses webpki-roots. Logs the
/// outcome so a misconfigured production build is visible in app logs.
///
/// **Risk #8 — fail-closed in release builds.** If `SINHRON_PINNED_CA_PEM`
/// is set but malformed:
///   • Debug builds — log error + fall back to webpki-roots (lets local
///     testing proceed without painful UX while you debug the cert).
///   • Release builds — `panic!` immediately. Silent downgrade in
///     production is the worst-case outcome (operator thought pinning
///     was enforced, attacker with a public CA bypasses it). Loud crash
///     beats silent compromise; the next deploy fixes the cert.
fn pinned_tls_from_env_or_none() -> Option<net::TlsPinning> {
    let pem = std::env::var("SINHRON_PINNED_CA_PEM").ok()?;
    if pem.trim().is_empty() {
        return None;
    }
    match net::TlsPinning::from_pem(pem.as_bytes()) {
        Ok(pin) => {
            tracing::info!("WS: TLS pinning enabled from SINHRON_PINNED_CA_PEM");
            // ADR-072 — the address check trusts the same CA.
            net::dns::set_probe_trust(pin.client_config());
            Some(pin)
        }
        Err(e) => {
            // Risk #8 — fail-closed in release. `debug_assertions` is
            // ON in debug builds, OFF in release. Use this rather than
            // a Cargo feature so the production binary always panics
            // without needing a separate build flag.
            #[cfg(debug_assertions)]
            {
                tracing::error!(
                    error = %e,
                    "WS: SINHRON_PINNED_CA_PEM malformed — \
                     DEBUG build falls back to webpki-roots. \
                     In RELEASE this would panic."
                );
                None
            }
            #[cfg(not(debug_assertions))]
            {
                panic!(
                    "SINHRON_PINNED_CA_PEM was set but failed to parse \
                     (error: {e}). Silent downgrade to webpki-roots is \
                     refused in release builds — fix the PEM and redeploy. \
                     See Risk #8 docs/status.md."
                );
            }
        }
    }
}

/// Disconnect + drop the current WS client.
pub async fn net_shutdown() {
    let mut slot = net_slot().lock().await;
    if let Some(c) = slot.take() {
        c.shutdown();
    }
}

/// Materialized event for the Flutter side.
///
/// frb requires `freezed` for Rust enums with field-bearing variants, which
/// breaks ADR-009 (no codegen). So we expose a flat struct with a `kind`
/// discriminator string and optional payload fields. Dart switches on
/// `kind` and reads the matching field. Less type-safe than an enum, but
/// avoids the build_runner dependency.
///
/// `kind` is one of: `"connected"`, `"disconnected"`, `"push"`, `"ack"`,
/// `"welcome"`, `"call_invite"`, `"call_accept"`, `"call_end"`,
/// `"call_ring"`, `"other"`. Only the corresponding payload field is
/// populated; others are `None`.
pub struct NetEvent {
    pub kind: String,
    /// Set when `kind == "disconnected"`.
    pub disconnected_reason: Option<String>,
    /// Set when `kind == "push"`.
    pub push: Option<NetPush>,
    /// Set when `kind == "ack"`.
    pub ack: Option<NetAck>,
    /// Set when `kind == "welcome"`.
    pub welcome: Option<NetWelcome>,
    /// CD3 — set when `kind == "call_invite"`. Inbound call from a peer.
    pub call_invite: Option<NetCallInvite>,
    /// CD3 — set when `kind == "call_accept"`. The peer accepted (or
    /// declined — see `accept` field).
    pub call_accept: Option<NetCallAccept>,
    /// CD3 — set when `kind == "call_end"`. Call ended by either side
    /// or by server watchdog.
    pub call_end: Option<NetCallEnd>,
    /// CD3 — set when `kind == "call_ring"`. Server-side ack that our
    /// outgoing invite was delivered to the callee.
    pub call_ring: Option<NetCallRing>,
}

pub struct NetCallInvite {
    pub call_id: String,
    pub group_id_hex: String,
    /// `"audio"` or `"video"`.
    pub kind: String,
    pub livekit_room: String,
    pub ttl_secs: i64,
    /// Who calls (identity key, hex) — ADR-090: only when the caller signed
    /// this invite and is in the chat here; empty otherwise (the server alone
    /// could have written it — the app doesn't ring then).
    pub caller_identity_hex: String,
}

pub struct NetCallAccept {
    pub call_id: String,
    /// `true` = peer accepted; `false` would be a decline, but in our
    /// signaling pattern decline gets translated server-side to a
    /// `CallEnd { reason: "rejected" }` so this is typically true here.
    pub accept: bool,
}

pub struct NetCallEnd {
    pub call_id: String,
    /// Free-text reason from the server / opposite party. Typical
    /// values: "hangup", "no_answer", "rejected", "network_lost".
    pub reason: String,
}

pub struct NetCallRing {
    pub call_id: String,
    /// Status 213 — the callee's phone has the invite: "Ringing".
    pub delivered: bool,
}

pub struct NetPush {
    pub group_id_hex: String,
    /// Plaintext bytes when SyncClient successfully decrypted the MLS
    /// frame. When `decrypted == false` this is the raw on-wire bytes
    /// (the caller can choose to display a placeholder or try a manual
    /// decrypt path).
    pub ciphertext: Vec<u8>,
    /// True iff SyncClient produced a plaintext ApplicationMessage from
    /// the on-wire bytes.
    pub decrypted: bool,
    pub message_id: String,
    pub delivered_at_unix: i64,
    pub sequence: u64,
    /// Decoded app message (ADR-017 envelope):
    ///   "text"        — `text` holds the message
    ///   "photo" | "voice" | "document" — `media_json` set, `text` = caption
    ///   "unsupported" — envelope from a newer app version
    ///   "undecrypted" — MLS decrypt failed (legacy plaintext demo chats)
    ///   "control"     — an MLS state change (Commit, own echo, stale
    ///                   frame), not a chat message — never stored
    ///   "access" / "history" — tech-debt 2.2 / ADR-025 (see decode_push)
    ///   actions — "reaction", "edit", …, "group_name" (ADR-034): `action_json`
    ///   "invalid"     — decrypted but malformed envelope
    pub kind: String,
    pub text: String,
    pub media_json: Option<String>,
    /// ADR-019 — quote this message replies to (text / media kinds).
    pub reply_json: Option<String>,
    /// MLS-authenticated sender identity key (hex) — gates edits and
    /// deletes, identifies reactors.
    pub sender_id: Option<String>,
    /// For kind "reaction" / "edit" / "delete" / "receipt" / "typing":
    /// `{"target","emoji"}` · `{"target","text"}` · `{"target"}` ·
    /// `{"read":bool,"ids":[…]}` · `{"active":bool}` · `{"secs":n}` (timer).
    pub action_json: Option<String>,
    /// Disappearing timer carried by a text / media message (0 = none).
    pub expire_secs: u32,
    /// ADR-070 — formatting of `text` (a text message or a caption) as the
    /// app's JSON (`[{"t":"bold","o":0,"l":4},…]`, UTF-16 offsets). None:
    /// sent by an older app — its `*stars*` may be markers.
    pub entities_json: Option<String>,
}

pub struct NetAck {
    pub acked_frame_id: String,
    pub error_code: i32,
    pub error_message: String,
}

/// Incoming Welcome frame surfaced to Dart. The NetService consumes
/// this by calling `sync_join_via_welcome` with the bytes, then
/// invalidates `chatsProvider` so the new group appears in ChatList.
pub struct NetWelcome {
    /// Hex of the inviting user's identity (so UI can show "Alice invited you").
    /// Empty if the server didn't include it (current server doesn't).
    pub inviter_identity_pubkey_hex: String,
    pub group_id_hex: String,
    pub welcome_b64: String,
    pub sent_at_unix: i64,
}

// ─────────────────────────────────────────────────────────────────────
// MLS Sync (sinhron_sync · WU C2)
// ─────────────────────────────────────────────────────────────────────
//
// Singleton SyncClient lives alongside the singleton WsClient. The Dart
// side calls `sync_init_from_phrase(phrase)` once after onboarding;
// thereafter `sync_create_keypackage_b64`, `sync_create_group`, etc.
// drive group lifecycle. Outgoing chat messages are encrypted via
// `sync_encrypt(group_id, plaintext)` BEFORE being passed to
// `net_send_submit` — keeps the FFI surface composable.

static SYNC_CLIENT: OnceLock<Mutex<Option<sync::SyncClient>>> = OnceLock::new();

pub(crate) fn sync_slot() -> &'static Mutex<Option<sync::SyncClient>> {
    SYNC_CLIENT.get_or_init(|| Mutex::new(None))
}

// ─────────────────────────────────────────────────────────────────────
// Sealed sender — ADR-023 (spec §6.5)
// ─────────────────────────────────────────────────────────────────────

struct SealedState {
    base_url: String,
    /// Week our delivery keys were last published for.
    published_week: u32,
    /// Recipient identity hex → (week, delivery public key, signed by its
    /// owner — ADR-082: only then does it get a notification preview).
    keys: std::collections::HashMap<String, (u32, Vec<u8>, bool)>,
    /// Tech-debt 2.2 — people's access keys we were given (identity hex →
    /// key), cached from the local DB (`access_key:<hex>` settings).
    access: std::collections::HashMap<String, Vec<u8>>,
}

/// Tech-debt 2.2 — someone's access key: cache, else the local DB.
fn known_access_key(st: &mut SealedState, identity_hex: &str) -> Option<Vec<u8>> {
    if let Some(k) = st.access.get(identity_hex) {
        return Some(k.clone());
    }
    let k = storage::setting_get(&format!("access_key:{identity_hex}")).ok().flatten().and_then(|h| hex::decode(h).ok())?;
    if k.len() != sync::envelope::ACCESS_KEY_LEN {
        return None;
    }
    st.access.insert(identity_hex.to_string(), k.clone());
    Some(k)
}

/// Tech-debt 2.2 — a member told us their access key (inside MLS).
async fn remember_access_key(identity_hex: &str, key: &[u8]) {
    if key.len() != sync::envelope::ACCESS_KEY_LEN {
        return;
    }
    let _ = storage::setting_set(&format!("access_key:{identity_hex}"), &hex::encode(key));
    if let Some(st) = sealed_slot().lock().await.as_mut() {
        st.access.insert(identity_hex.to_string(), key.to_vec());
    }
}

/// ADR-071 — "1" once the server took our per-contact access keys: from
/// then on only those are handed out (never the old shared key, which the
/// server no longer accepts for us).
const ACCESS_PER_CONTACT_SETTING: &str = "access_per_contact";

/// ADR-071 — this server doesn't know `PUT /v1/access-keys` (older than
/// the app): keep the shared key until the app starts again.
static ACCESS_OLD_SERVER: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Hashes per `PUT /v1/access-keys` (the server takes up to 1000 of each).
const ACCESS_PUT_CHUNK: usize = 500;

fn per_contact_access() -> bool {
    storage::setting_get(ACCESS_PER_CONTACT_SETTING).ok().flatten().as_deref() == Some("1")
}

/// Someone's access key we were given (the local DB, no cache needed).
fn stored_access_key(identity_hex: &str) -> Option<Vec<u8>> {
    let k = storage::setting_get(&format!("access_key:{identity_hex}")).ok().flatten().and_then(|h| hex::decode(h).ok())?;
    (k.len() == sync::envelope::ACCESS_KEY_LEN).then_some(k)
}

/// ADR-071 — make the server's set match this device before any key is
/// handed out: the hash of the key for everyone in [groups] who isn't
/// blocked (and for me — my other devices), and every block / unblock
/// with its time (the later one wins there, so a device that hasn't heard
/// of a block can't lift it). `Ok(false)`: an older server — stay on the
/// shared key.
async fn access_reconcile(base_url: &str, groups: &[Vec<u8>]) -> Result<bool, String> {
    if ACCESS_OLD_SERVER.load(std::sync::atomic::Ordering::Relaxed) {
        return Ok(false);
    }
    let decisions = storage::access_block_decisions().map_err(|e| e.to_string())?;
    let blocked: std::collections::HashSet<String> =
        decisions.iter().filter(|d| d.1).map(|d| d.0.to_lowercase()).collect();
    for _ in 0..2 {
        let (seed, version, adds, decided) = {
            let mut slot = sync_slot().lock().await;
            let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
            let stored = storage::setting_get(ACCESS_VERSION_SETTING).ok().flatten().and_then(|v| v.parse().ok()).unwrap_or(0);
            if stored > c.access_version() {
                c.set_access_version(stored);
            }
            let mut people = std::collections::BTreeSet::from([c.identity_pubkey_hex()]);
            for g in groups {
                if let Ok(ids) = c.group_member_identities(g) {
                    people.extend(ids.iter().map(hex::encode));
                }
            }
            let adds: Vec<[u8; 32]> = people
                .iter()
                .filter(|p| !blocked.contains(*p))
                .filter_map(|p| hex::decode(p).ok())
                .map(|id| c.access_hash_for(&id))
                .collect();
            let decided: Vec<([u8; 32], bool, i64)> = decisions
                .iter()
                .filter_map(|(p, b, at)| Some((c.access_hash_for(&hex::decode(p.to_lowercase()).ok()?), *b, *at)))
                .collect();
            (c.identity_seed_bytes(), c.access_version(), adds, decided)
        };
        let api = sync::HttpApi::new(base_url.to_string());
        let mut server_version = version;
        let rounds = adds.len().max(decided.len()).div_ceil(ACCESS_PUT_CHUNK).max(1);
        for i in 0..rounds {
            let part = |len: usize| (i * ACCESS_PUT_CHUNK).min(len)..((i + 1) * ACCESS_PUT_CHUNK).min(len);
            let (a, d) = (&adds[part(adds.len())], &decided[part(decided.len())]);
            match api.publish_access_keys(seed, version, a, d).await {
                Ok(v) => server_version = server_version.max(v),
                Err(sync::HttpError::Server { status: 404, .. }) => {
                    ACCESS_OLD_SERVER.store(true, std::sync::atomic::Ordering::Relaxed);
                    return Ok(false);
                }
                Err(e) => return Err(e.to_string()),
            }
            if server_version > version {
                break;
            }
        }
        if server_version > version {
            // Another of my devices rotated the keys: adopt and publish again.
            if let Some(c) = sync_slot().lock().await.as_mut() {
                c.set_access_version(server_version);
            }
            let _ = storage::setting_set(ACCESS_VERSION_SETTING, &server_version.to_string());
            continue;
        }
        let _ = storage::setting_set(ACCESS_PER_CONTACT_SETTING, "1");
        return Ok(true);
    }
    Err("access-key version changed twice".into())
}

/// ADR-023 — [identity_hex]'s current delivery key (cache, else the server).
async fn delivery_key_of(identity_hex: &str) -> Option<Vec<u8>> {
    let mut guard = sealed_slot().lock().await;
    let st = guard.as_mut()?;
    let week = sync::sealed::week_of(now_unix());
    let fresh = |w: u32| w == week || w == week + 1;
    if let Some((w, pk, _)) = st.keys.get(identity_hex) {
        if fresh(*w) {
            return Some(pk.clone());
        }
    }
    let found = sync::HttpApi::new(st.base_url.clone()).fetch_sealed_keys(&[identity_hex.to_string()]).await.ok()?;
    // This week's key over next week's.
    // ADR-082: only a key its owner signed — an unsigned one is the server's.
    let (_, w, pk, signed) = found.into_iter().filter(|(id, w, _, s)| id == identity_hex && fresh(*w) && *s).min_by_key(|k| k.1)?;
    st.keys.insert(identity_hex.to_string(), (w, pk.clone(), signed));
    Some(pk)
}

// Events produced on this side (not by the server) for the Dart event
// loop — e.g. the "sent" Ack of a message delivered over the anonymous
// route, which has no WS Ack.
type LocalEvents = (
    tokio::sync::mpsc::UnboundedSender<NetEvent>,
    Mutex<tokio::sync::mpsc::UnboundedReceiver<NetEvent>>,
);

fn local_events() -> &'static LocalEvents {
    static Q: OnceLock<LocalEvents> = OnceLock::new();
    Q.get_or_init(|| {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        (tx, Mutex::new(rx))
    })
}

fn push_local_ack(frame_id: &str) {
    let _ = local_events().0.send(NetEvent {
        ack: Some(NetAck { acked_frame_id: frame_id.to_string(), error_code: 0, error_message: "sealed (anonymous)".into() }),
        ..empty_net_event("ack")
    });
}

static SEALED: OnceLock<Mutex<Option<SealedState>>> = OnceLock::new();

fn sealed_slot() -> &'static Mutex<Option<SealedState>> {
    SEALED.get_or_init(|| Mutex::new(None))
}

pub(crate) fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

const ACCESS_VERSION_SETTING: &str = "access_version";

/// ADR-084 — the account roots' current generation, `<gen>:<hex>` (a synced
/// setting: my other devices get it in my own-devices group, a new device in
/// its transfer, a phone restored from a backup with the rest).
const ROOTS_SETTING: &str = "account_roots";
/// This device only: the generations before it, newest first — senders may
/// still seal to their keys for a couple of weeks.
const OLD_ROOTS_SETTING: &str = "account_roots_old";
const OLD_ROOTS_KEPT: usize = 2;

pub(crate) fn roots_setting() -> String {
    storage::setting_get(ROOTS_SETTING).ok().flatten().unwrap_or_default()
}

/// Every generation this device holds, the current one first (none: the
/// phrase's own, generation 0).
pub(crate) fn account_roots() -> Vec<crypto::identity::RootsGen> {
    let mut v = crypto::identity::RootsGen::decode_list(&roots_setting());
    v.truncate(1);
    v.extend(crypto::identity::RootsGen::decode_list(&storage::setting_get(OLD_ROOTS_SETTING).ok().flatten().unwrap_or_default()));
    v
}

/// The current generation changed from [before] (here, or my other device's
/// arrived): keep [before] for what is still sealed to it, forget the cached
/// delivery keys (mine are new) and publish the new ones.
pub(crate) async fn roots_changed(before: String) {
    if roots_setting() == before {
        return;
    }
    let held = account_roots();
    let mut old = crypto::identity::RootsGen::decode_list(&before);
    old.extend(held.iter().skip(1).copied());
    old.retain(|g| held.first() != Some(g));
    old.dedup();
    old.truncate(OLD_ROOTS_KEPT);
    let old: Vec<String> = old.iter().map(crypto::identity::RootsGen::encode).collect();
    let _ = storage::setting_set(OLD_ROOTS_SETTING, &old.join(","));
    let base = sealed_slot().lock().await.as_mut().map(|st| {
        st.published_week = 0;
        st.keys.clear();
        st.base_url.clone()
    });
    if let Some(base) = base {
        if let Err(e) = sync_enable_sealed(base).await {
            tracing::warn!(error = %e, "new delivery keys not published yet");
        }
    }
}

/// ADR-084 (audit mls-identity:2) — after disconnecting one of my devices: a
/// new generation of the account's delivery root and cloud backup key, from
/// fresh random bytes the disconnected device never sees. My other devices
/// get it in my own-devices group (sent now); this device publishes the new
/// delivery keys, and the next backups use the new key. Returns the generation.
pub async fn sync_rotate_account_roots(server_base_url: String) -> Result<u32, String> {
    let before = new_account_roots()?;
    let next_gen = account_roots().first().map_or(0, |g| g.gen);
    roots_changed(before).await;
    if let Err(e) = super::transfer::device_sync_flush(server_base_url).await {
        tracing::warn!(error = %e, "new account roots not sent yet (the next sync sends them)");
    }
    Ok(next_gen)
}

/// A fresh generation of the account roots becomes the current one; returns
/// the setting as it was, for [roots_changed].
pub(crate) fn new_account_roots() -> Result<String, String> {
    let before = roots_setting();
    let next = sync::backup::new_generation(account_roots().iter().max_by_key(|g| g.gen));
    storage::setting_set(ROOTS_SETTING, &next.encode()).map_err(|e| e.to_string())?;
    Ok(before)
}

/// Publish this device's current + next week delivery keys (and the hash
/// of our access key at our version). If another of our devices rotated
/// the access key, the server says so — adopt its version.
async fn publish_sealed_keys(base_url: &str) -> Result<u32, String> {
    let now = now_unix();
    let (seed, keys, access_hash, version, cert) = {
        let mut slot = sync_slot().lock().await;
        let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let stored = storage::setting_get(ACCESS_VERSION_SETTING).ok().flatten().and_then(|v| v.parse().ok()).unwrap_or(0);
        if stored > client.access_version() {
            client.set_access_version(stored);
        }
        client.set_rotated_roots(&account_roots());
        (
            client.identity_seed_bytes(),
            client.sealed_keys_to_publish(now).map_err(|e| e.to_string())?,
            client.access_hash(),
            client.access_version(),
            client.signer_certificate(),
        )
    };
    let pairs: Vec<(u32, Vec<u8>)> = keys.iter().map(|k| (k.week, k.public.clone())).collect();
    let server_version = sync::HttpApi::new(base_url.to_string())
        .publish_sealed_keys(seed, &pairs, Some((access_hash, version)), cert.as_deref())
        .await
        .map_err(|e| e.to_string())?;
    if server_version > version {
        if let Some(c) = sync_slot().lock().await.as_mut() {
            c.set_access_version(server_version);
        }
        let _ = storage::setting_set(ACCESS_VERSION_SETTING, &server_version.to_string());
    }
    Ok(sync::sealed::week_of(now))
}

/// Tech-debt 2.2 — rotate our sealed-sender access key: a new version, its
/// hash to the server (the old key stops working at once), and the new key
/// to our chats on the next share (`sync_share_access_key`). For when a
/// chat partner shouldn't be able to reach us anonymously any more, and
/// after revoking one of our devices.
pub async fn sync_rotate_access_key(server_base_url: String) -> Result<u32, String> {
    let next = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let next = c.access_version() + 1;
        c.set_access_version(next);
        next
    };
    storage::setting_set(ACCESS_VERSION_SETTING, &next.to_string()).map_err(|e| e.to_string())?;
    publish_sealed_keys(&server_base_url).await?;
    Ok(next)
}

/// ADR-023 — publish this device's delivery keys and, from now on, send
/// messages sealed whenever every recipient has a current key (falls
/// back to an ordinary Submit otherwise). Call after bootstrap.
///
/// Status 223 (owner: "with name and text on, it still says just 'New
/// message'") — sealing (and so the notification preview) is on from the
/// first call even if publishing fails now: messages sent in the first
/// seconds after launch, or after a failed launch-time publish, went plain
/// and carried no preview for the rest of the run. Called on every
/// connection: a no-op while this week's keys are out; otherwise it
/// publishes them (a phone that only receives kept stale keys, and a group
/// with one stale member sent nobody a preview).
pub async fn sync_enable_sealed(server_base_url: String) -> Result<(), String> {
    let week = sync::sealed::week_of(now_unix());
    {
        let mut slot = sealed_slot().lock().await;
        match slot.as_ref() {
            Some(st) if st.base_url == server_base_url && st.published_week >= week => return Ok(()),
            Some(st) if st.base_url == server_base_url => {}
            _ => {
                *slot = Some(SealedState {
                    base_url: server_base_url.clone(),
                    published_week: 0,
                    keys: std::collections::HashMap::new(),
                    access: std::collections::HashMap::new(),
                })
            }
        }
    }
    let published = publish_sealed_keys(&server_base_url).await?;
    if let Some(st) = sealed_slot().lock().await.as_mut() {
        st.published_week = st.published_week.max(published);
    }
    Ok(())
}

/// How a sealed group message goes out.
struct SealedPlan {
    base_url: String,
    /// `(key_id, envelope)` per recipient.
    deliveries: Vec<([u8; 16], Vec<u8>)>,
    /// Tech-debt 2.2 — each recipient's access key (same order) where we
    /// have one: those deliveries go without authentication (ADR-071: the
    /// rest as a message request over the WS).
    access: Vec<Option<Vec<u8>>>,
    /// Tech-debt 2.5 — the chat's disappearing timer (0 = keep): the
    /// server drops these deliveries when it runs out.
    ttl_secs: u32,
    /// Overnight item 8 — per delivery: wake that phone if it's offline (a
    /// real message, and not my own copy).
    urgent: Vec<bool>,
    /// ADR-056 — per delivery: the notification preview sealed to that
    /// recipient (urgent deliveries only).
    previews: Vec<Option<Vec<u8>>>,
    /// Tech-debt 2.53 — the server drops these if not delivered within
    /// this many seconds (0 = keep): "online" heartbeats and "typing".
    drop_after_secs: u32,
}

/// The local chat's disappearing timer (chat id = group id hex).
fn chat_timer_secs(group_id: &[u8]) -> u32 {
    let id = hex::encode(group_id);
    storage::chats_list()
        .ok()
        .and_then(|cs| cs.into_iter().find(|c| c.id == id))
        .map(|c| c.disappear_secs.clamp(0, u32::MAX as i64) as u32)
        .unwrap_or(0)
}

impl SealedPlan {
    fn ws_frame(&self, message_id: &str) -> net::proto::WsFrame {
        self.ws_frame_for(message_id, |_| true)
    }

    /// The SealedSubmit for the deliveries [pick] chooses (by index).
    fn ws_frame_for(&self, message_id: &str, pick: impl Fn(usize) -> bool) -> net::proto::WsFrame {
        net::proto::WsFrame {
            frame_id: message_id.to_string(),
            body: Some(net::proto::ws_frame::Body::SealedSubmit(net::proto::SealedSubmit {
                message_id: message_id.to_string(),
                deliveries: self
                    .deliveries
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| pick(*i))
                    .map(|(i, (key_id, envelope))| net::proto::SealedDelivery {
                        key_id: key_id.to_vec(),
                        envelope: envelope.clone(),
                        ttl_secs: self.ttl_secs,
                        urgent: self.urgent.get(i).copied().unwrap_or(false),
                        push_preview: self.previews.get(i).cloned().flatten().unwrap_or_default(),
                        drop_after_secs: self.drop_after_secs,
                    })
                    .collect(),
                // ADR-087 (amended) — the keys my contacts gave me: with
                // one, this signed-in fallback wakes their phone as usual.
                access_keys: self.access.iter().flatten().cloned().collect(),
            })),
        }
    }
}

/// ADR-071 / ADR-087 (amended) — the access keys the other members of
/// [group_id] gave me (any order): sent with a call invite and with a
/// message over the signed-in routes, so a contact's phone is woken.
async fn members_access_keys(group_id: &[u8]) -> Vec<Vec<u8>> {
    let (me, members) = {
        let mut slot = sync_slot().lock().await;
        let Some(c) = slot.as_mut() else { return Vec::new() };
        (c.identity_pubkey_hex(), c.group_member_identities(group_id).unwrap_or_default())
    };
    members.iter().map(hex::encode).filter(|m| *m != me).filter_map(|m| stored_access_key(&m)).collect()
}

/// ADR-056 — what a notification about [plaintext] may say: (kind, text)
/// for a real message (text, link, photo / video / voice / file), None
/// for everything else. storage-devices:17 — a disappearing message's
/// text stays off the lock screen (the phone shows the kind's word).
fn preview_of(plaintext: &[u8]) -> Option<(String, String)> {
    use sync::envelope::Decoded as D;
    let m = sync::envelope::decode_message(plaintext).ok()?;
    let (kind, text) = match m.decoded {
        D::Text(t) => ("text".into(), t),
        D::Link { text, .. } => ("text".into(), text),
        D::Media(md) => (sync::envelope::kind_name(md.kind).to_string(), md.caption),
        _ => return None,
    };
    Some((kind, if m.expire_secs > 0 { String::new() } else { text }))
}

/// Sealed envelopes for this group message, or None to send it the
/// ordinary way (sealed not enabled, a recipient without a key, …).
/// [preview]: (kind, text) for each woken recipient's notification.
/// [drop_after_secs]: see `sync::envelope::drop_after_secs`.
async fn sealed_plan(
    group_id: &[u8],
    ciphertext: &[u8],
    urgent: bool,
    preview: Option<(String, String)>,
    drop_after_secs: u32,
) -> Option<SealedPlan> {
    let mut guard = sealed_slot().lock().await;
    let st = guard.as_mut()?;
    let now = now_unix();
    let week = sync::sealed::week_of(now);
    if st.published_week < week {
        if let Ok(w) = publish_sealed_keys(&st.base_url).await {
            st.published_week = w;
        }
    }
    let (me, members, own_devices, my_access) = {
        let mut slot = sync_slot().lock().await;
        let client = slot.as_mut()?;
        let me = client.identity_pubkey_hex();
        let me_bytes: [u8; 32] = hex::decode(&me).ok()?.try_into().ok()?;
        let own = client.group_device_keys(group_id, &me_bytes).ok()?.len();
        // ADR-071 — my own key for my other devices, once per-contact.
        let my_access = if per_contact_access() { client.access_key_for(&me_bytes) } else { client.access_key() };
        (me, client.group_member_identities(group_id).ok()?, own, my_access)
    };
    // ADR-025: our other devices share our delivery keys (derived from the
    // account secret), so one envelope to ourselves reaches them all.
    let recipients: Vec<String> =
        members.iter().map(hex::encode).filter(|h| *h != me || own_devices > 1).collect();
    if recipients.is_empty() {
        return None;
    }
    let fresh = |k: &(u32, Vec<u8>, bool)| k.0 == week || k.0 == week + 1;
    let missing: Vec<String> = recipients
        .iter()
        .filter(|r| !st.keys.get(*r).is_some_and(fresh))
        .cloned()
        .collect();
    if !missing.is_empty() {
        if let Ok(found) = sync::HttpApi::new(st.base_url.clone()).fetch_sealed_keys(&missing).await {
            for (id, w, pk, signed) in found {
                if takes_sealed_key(st.keys.get(&id).map(|k| k.0), week, w, signed) {
                    st.keys.insert(id, (w, pk, signed));
                }
            }
        }
    }
    let keys: Option<Vec<(Vec<u8>, bool)>> = recipients
        .iter()
        .map(|r| st.keys.get(r).filter(|k| fresh(k)).map(|k| (k.1.clone(), k.2)))
        .collect();
    let (pks, signed): (Vec<Vec<u8>>, Vec<bool>) = keys?.into_iter().unzip();
    let deliveries = {
        let slot = sync_slot().lock().await;
        slot.as_ref()?.seal_for(group_id, ciphertext, &pks).ok()?
    };
    let access: Vec<Option<Vec<u8>>> = recipients
        .iter()
        .map(|r| if *r == me { Some(my_access.to_vec()) } else { known_access_key(st, r) })
        .collect();
    let urgent: Vec<bool> = recipients.iter().map(|r| urgent && *r != me).collect();
    // ADR-056 — a preview only where it may wake a phone. A failure just
    // leaves "New message". ADR-082: and only to a key its owner signed —
    // the text must not go to a key the server swapped in.
    let previews = match &preview {
        Some((kind, text)) => {
            let slot = sync_slot().lock().await;
            let client = slot.as_ref()?;
            pks.iter()
                .zip(urgent.iter().zip(&signed))
                .map(|(pk, (u, s))| if *u && *s { client.push_preview_for(pk, group_id, kind, text, now).ok() } else { None })
                .collect()
        }
        None => vec![None; recipients.len()],
    };
    Some(SealedPlan {
        base_url: st.base_url.clone(),
        deliveries,
        access,
        ttl_secs: chat_timer_secs(group_id),
        urgent,
        previews,
        drop_after_secs,
    })
}

/// Initialise the SyncClient from a BIP-39 phrase. Phrase stays Rust-
/// side. Replaces any existing client.
///
/// `db_path` controls MLS-state persistence (WU C6). When set to a
/// filesystem path, group ratchets/keys survive process restarts via
/// `openmls_sqlite_storage`. When empty (`""`), the provider runs
/// in-memory — useful for ephemeral tests, **never** for production.
/// The Flutter app passes `{ApplicationDocumentsDir}/sinhron/mls-state.sqlite`.
///
/// ADR-025: `device_seed_hex` — empty on the account's first device;
/// on a linked device, its own 32-byte key seed (hex, from the Keychain).
pub async fn sync_init_from_phrase(
    phrase: String,
    db_path: String,
    device_seed_hex: String,
) -> Result<String, String> {
    let db = if db_path.is_empty() {
        None
    } else {
        Some(std::path::PathBuf::from(db_path))
    };
    let device_seed = if device_seed_hex.is_empty() {
        None
    } else {
        let b = hex::decode(&device_seed_hex).map_err(|e| e.to_string())?;
        Some(<[u8; 32]>::try_from(b.as_slice()).map_err(|_| "device seed must be 32 bytes".to_string())?)
    };
    let client = sync::SyncClient::new(sync::SyncClientConfig {
        phrase,
        db_path: db,
        device_seed,
    })
    .map_err(|e| e.to_string())?;
    let pubkey = client.identity_pubkey_hex();
    let mut slot = sync_slot().lock().await;
    *slot = Some(client);
    Ok(pubkey)
}

/// Drop the current SyncClient. Used by Sign Out — releases the open
/// SQLite handle so the caller can `File.delete()` the MLS-state file
/// (iOS in particular is touchy about deleting open files). Returns
/// `true` if there was a client to drop, `false` if already idle.
/// Idempotent — calling twice is safe.
pub async fn sync_shutdown() -> Result<bool, String> {
    let mut slot = sync_slot().lock().await;
    let had_client = slot.take().is_some();
    Ok(had_client)
}

// ─────────────────────────────────────────────────────────────────────
// State-backup FFI — T1.2 (spec §6.8.1)
// ─────────────────────────────────────────────────────────────────────

/// Create a new MLS group with this user as the only member. Returns
/// the opaque group_id (hex). Use it for subsequent send/decrypt calls.
pub async fn sync_create_group() -> Result<String, String> {
    let mut slot = sync_slot().lock().await;
    let client = slot
        .as_mut()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let group_id = client.create_group().map_err(|e| e.to_string())?;
    Ok(hex::encode(&group_id))
}

/// ADR-090 — the chat's MLS epoch here, for its announce (0 if unknown).
async fn epoch_of(group: &[u8]) -> u64 {
    sync_slot().lock().await.as_mut().and_then(|c| c.group_epoch(group).ok()).unwrap_or(0)
}

/// ADR-055 — the local setting naming this person's "Saved messages" chat
/// (its group id hex). Read from Dart with `storage_setting_get`.
pub(crate) const SAVED_CHAT_SETTING: &str = "saved_chat_id";

/// ADR-055 — create "Saved messages": an MLS group with only this device,
/// announced to the server so it accepts sends there (the server sees a
/// group with one person's devices — nothing else). Device sync then adds
/// my other devices like in any chat. Remembers it as the Saved chat and
/// returns its id; the app makes the chat row.
pub async fn sync_create_saved_group(server_base_url: String) -> Result<String, String> {
    let (group, my_device, seed) = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        (c.create_group().map_err(|e| e.to_string())?, c.device_public_key(), c.login_seed_bytes())
    };
    sync::HttpApi::new(server_base_url)
        .announce_group(seed, &group, epoch_of(&group).await, std::slice::from_ref(&my_device))
        .await
        .map_err(|e| e.to_string())?;
    let id = hex::encode(&group);
    storage::setting_set(SAVED_CHAT_SETTING, &id).map_err(|e| e.to_string())?;
    Ok(id)
}

/// A device linked within this long that never got everything from this
/// one gets it at the next device sync (2026-10-26).
const CATCH_UP_TRANSFER_SECS: i64 = 30 * 24 * 3600;

/// ADR-064 — does this device (registered at [mine]) send everything to a
/// device registered at [theirs]? Only to a newer one; unknown → yes.
fn sends_everything_to(mine: Option<i64>, theirs: Option<i64>) -> bool {
    match (mine, theirs) {
        (Some(mine), Some(theirs)) => theirs > mine,
        _ => true,
    }
}

/// Setting marking that everything was queued for device [k] from here.
pub(crate) fn transfer_sent_key(k: &[u8]) -> String {
    format!("transfer_sent:{}", hex::encode(k))
}

fn transfer_sent_to(k: &[u8]) -> bool {
    storage::setting_get(&transfer_sent_key(k)).ok().flatten().is_some()
}

/// Queue everything for my device [k] through my own-devices group.
fn queue_transfer_to(k: &[u8], group_hex: &str) -> bool {
    match sync::transfer::queue_export(&hex::encode(k), group_hex, now_unix() as i64) {
        Ok(_) => {
            let _ = storage::setting_set(&transfer_sent_key(k), &now_unix().to_string());
            true
        }
        Err(e) => {
            tracing::warn!(error = %e, "device transfer not queued");
            false
        }
    }
}

/// Saved chats this device had before (comma-separated group ids): their
/// notes were moved into the current one, and whatever still arrives in
/// them goes there too (Dart `SavedMessages.tidy`, the push handler).
pub(crate) const SAVED_FORMER_SETTING: &str = "saved_chat_former";

/// ADR-055 — the "Saved messages" marker came from my other device: make
/// [group_hex] this device's Saved chat, unless it already has one. Two
/// devices that each made their own before they met settle on the same
/// one (the smaller id); the other one is remembered as former, and the
/// app moves its notes into the chosen one (owner, 2026-10-26: two
/// "Saved Messages" rows in the list).
pub(crate) fn adopt_saved_chat(group_hex: &str) {
    let current = storage::setting_get(SAVED_CHAT_SETTING).ok().flatten().filter(|c| !c.is_empty());
    let current_exists = |c: &str| storage::chats_list().map(|cs| cs.iter().any(|x| x.id == c)).unwrap_or(false);
    let take = match current.as_deref() {
        None => true,
        Some(c) if c == group_hex => false,
        Some(c) => !current_exists(c) || group_hex < c,
    };
    if take {
        if let Some(old) = current.as_deref() {
            remember_former_saved(old);
        }
        let _ = storage::setting_set(SAVED_CHAT_SETTING, group_hex);
    } else if let Some(c) = current.as_deref() {
        if c != group_hex {
            remember_former_saved(group_hex);
        }
    }
}

fn remember_former_saved(id: &str) {
    let have = storage::setting_get(SAVED_FORMER_SETTING).ok().flatten().unwrap_or_default();
    if have.split(',').any(|x| x == id) {
        return;
    }
    let joined = if have.is_empty() { id.to_string() } else { format!("{have},{id}") };
    let _ = storage::setting_set(SAVED_FORMER_SETTING, &joined);
}

/// Result of `sync_invite_to_group` — caller broadcasts the commit to
/// existing members via WS Submit, ships the welcome out-of-band to
/// the invitee (or via WS once Welcome frame lands).
pub struct InviteOutcome {
    pub commit_b64: String,
    pub welcome_b64: String,
}

/// Full onboarding bootstrap: register identity with the operator server
/// + publish first KeyPackage. Single FFI call so Dart-side doesn't have
/// to sequence two HTTPs. Idempotent on the registration side.
///
/// Result is a JSON-ish string ("user_pk=...; already_existed=true; ...")
/// — kept as a single line to avoid an extra struct round-trip through frb.
pub async fn sync_bootstrap_with_server(server_base_url: String) -> Result<String, String> {
    // Risk #3 fix: `as_mut()` so `&mut SyncClient` is held across the
    // `.await` — Future requires only `SyncClient: Send`, not `Sync`.
    // This drops the need for `unsafe impl Sync for SinhronProvider`.
    let mut slot = sync_slot().lock().await;
    let client = slot
        .as_mut()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let http = sync::HttpApi::new(server_base_url);
    let out = client
        .bootstrap_with_server(&http)
        .await
        .map_err(|e| e.to_string())?;
    Ok(format!(
        "user_pk={} already_existed={} identity={} kp_id={}",
        out.user_pk, out.already_existed, out.identity_pubkey_hex, out.keypackage_id
    ))
}

/// Publish this device's fresh KeyPackage to the operator server's
/// `POST /v1/keypackages` endpoint. Returns the server-assigned KP id.
/// Use after `sync_init_from_phrase` + identity-registration HTTP call.
pub async fn sync_publish_keypackage(server_base_url: String) -> Result<String, String> {
    let mut slot = sync_slot().lock().await;
    let client = slot
        .as_mut()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let http = sync::HttpApi::new(server_base_url);
    client.publish_keypackage(&http).await.map_err(|e| e.to_string())
}

/// ADR-074 — publish [count] fresh KeyPackages (at most 50): every chat
/// this device is added to uses one, so a phone signed in again — that
/// its contacts are about to add back to all its chats — needs a stock,
/// not the one a launch publishes. Made under the lock, uploaded without
/// it. Returns how many the server took.
pub async fn sync_publish_keypackages(server_base_url: String, count: u32) -> Result<u32, String> {
    let (seed, kps) = {
        let slot = sync_slot().lock().await;
        let client = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
        let kps = (0..count.min(50)).map(|_| client.create_keypackage()).collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
        (client.device_seed_bytes(), kps)
    };
    let http = sync::HttpApi::new(server_base_url);
    let mut took = 0;
    for kp in kps {
        match http.publish_keypackage(seed, &kp).await {
            Ok(_) => took += 1,
            Err(e) => {
                tracing::warn!(error = %e, published = took, "KeyPackage stock cut short");
                break;
            }
        }
    }
    Ok(took)
}

/// ADR-074 — after a Welcome: did another person add this device back
/// into a chat I was already in (my lost phone's leaf is still there)?
/// Then it is my chat, not a new request.
pub async fn sync_group_added_back(group_id_hex: String) -> Result<bool, String> {
    let group = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    client.added_back_by_someone_else(&group).map_err(|e| e.to_string())
}

/// Fetch a target user's KeyPackage from the server + invite them to
/// the named group in one call. Returns the (commit_b64, welcome_b64)
/// pair — caller broadcasts commit via WS Submit, ships welcome to the
/// target out-of-band (or via a future Welcome WS frame).
pub async fn sync_fetch_kp_and_invite(
    server_base_url: String,
    group_id_hex: String,
    target_identity_pubkey_hex: String,
) -> Result<InviteOutcome, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot
        .as_mut()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let http = sync::HttpApi::new(server_base_url);
    let (outcome, devices) = client
        .fetch_kp_and_invite_devices(&http, &group_id, &target_identity_pubkey_hex)
        .await
        .map_err(|e| e.to_string())?;
    if let Ok(mut m) = invited_devices().lock() {
        m.insert((group_id_hex.clone(), target_identity_pubkey_hex.clone()), devices);
    }
    Ok(InviteOutcome {
        commit_b64: BASE64_STANDARD.encode(&outcome.commit_bytes),
        welcome_b64: BASE64_STANDARD.encode(&outcome.welcome_bytes),
    })
}

/// ADR-034 — a group of several people: fetch every member's device
/// KeyPackages, add them all in ONE Commit, announce every device to the
/// server. Returns the one Welcome; `net_send_welcome` then sends a copy
/// to each member (addressed to the devices added for them). Nobody is
/// added unless all members have KeyPackages. For a group created just
/// now, so no one else has to see the Commit.
pub async fn sync_fetch_kps_and_invite_people(
    server_base_url: String,
    group_id_hex: String,
    member_identity_hexes: Vec<String>,
) -> Result<InviteOutcome, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    let http = sync::HttpApi::new(server_base_url);
    let (outcome, people) = client
        .fetch_kps_and_invite_people(&http, &group_id, &member_identity_hexes)
        .await
        .map_err(|e| e.to_string())?;
    remember_invited(&group_id_hex, people);
    Ok(InviteOutcome {
        commit_b64: BASE64_STANDARD.encode(&outcome.commit_bytes),
        welcome_b64: BASE64_STANDARD.encode(&outcome.welcome_bytes),
    })
}

/// ADR-034 — add people to an existing group. The Commit is held pending
/// until the server orders it (ADR-022 `Submit{is_commit}`), which also
/// delivers it to every current member; then their devices are announced.
/// Returns the Welcome for the new people (`net_send_welcome` each).
/// Errors if another member's Commit won the race — try again.
pub async fn sync_add_group_members(
    server_base_url: String,
    group_id_hex: String,
    member_identity_hexes: Vec<String>,
) -> Result<InviteOutcome, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let http = sync::HttpApi::new(server_base_url);
    settle_before_change(&http, &group_id).await;
    let (pending, people, my_device, seed) = {
        let mut slot = sync_slot().lock().await;
        let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let me = client.identity_pubkey_hex();
        // Only people not in the group yet.
        let present: Vec<String> = client
            .group_member_identities(&group_id)
            .map_err(|e| e.to_string())?
            .into_iter()
            .map(hex::encode)
            .collect();
        let targets: Vec<String> = member_identity_hexes
            .into_iter()
            .map(|t| t.to_lowercase())
            .filter(|t| *t != me && !present.contains(t))
            .collect();
        let (people, kp_bytes) = client.fetch_people_keypackages(&http, &targets).await.map_err(|e| e.to_string())?;
        let pending = client.invite_devices_pending(&group_id, &kp_bytes).map_err(|e| e.to_string())?;
        (pending, people, client.device_public_key(), client.login_seed_bytes())
    };
    if !submit_pending_commit(&group_id, &pending).await? {
        return Err("the group changed at the same time — try again".to_string());
    }
    let mut members = vec![my_device.clone()];
    members.extend(people.iter().flat_map(|p| p.devices.iter().cloned()));
    http.announce_group(seed, &group_id, epoch_of(&group_id).await, &members).await.map_err(|e| e.to_string())?;
    let welcome = pending.welcome_bytes.clone().ok_or("no welcome for the new members")?;
    remember_invited(&group_id_hex, people);
    Ok(InviteOutcome {
        commit_b64: BASE64_STANDARD.encode(&pending.commit_bytes),
        welcome_b64: BASE64_STANDARD.encode(&welcome),
    })
}

/// ADR-035 — remove people (all their devices) from a group in one Commit,
/// ordered by the server like any other. My own key is skipped (leaving is
/// `sync_leave_group_server` + a `leave` action the others act on).
/// ADR-083 — then the server drops them from the chat's roster.
pub async fn sync_remove_group_members(
    server_base_url: String,
    group_id_hex: String,
    member_identity_hexes: Vec<String>,
) -> Result<(), String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    settle_before_change(&sync::HttpApi::new(server_base_url.clone()), &group_id).await;
    let (pending, ids, seed) = {
        let mut slot = sync_slot().lock().await;
        let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let me = client.identity_pubkey_hex();
        let ids: Vec<[u8; 32]> = member_identity_hexes
            .iter()
            .map(|h| h.to_lowercase())
            .filter(|h| *h != me)
            .filter_map(|h| hex::decode(&h).ok().and_then(|b| <[u8; 32]>::try_from(b.as_slice()).ok()))
            .collect();
        (client.remove_people_pending(&group_id, &ids).map_err(|e| e.to_string())?, ids, client.identity_seed_bytes())
    };
    if !submit_pending_commit(&group_id, &pending).await? {
        return Err("the group changed at the same time — try again".to_string());
    }
    // Out of MLS already; the next removal or their own app's leave retries.
    if let Err(e) = sync::HttpApi::new(server_base_url).remove_group_members(seed, &group_id, &ids).await {
        tracing::warn!(group = %group_id_hex, error = %e, "removed, but still on the server's roster");
    }
    Ok(())
}

/// ADR-035 — tell the server to stop sending me this group's messages.
pub async fn sync_leave_group_server(server_base_url: String, group_id_hex: String) -> Result<(), String> {
    let group = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    sync::HttpApi::new(server_base_url).leave_group(seed, &group).await.map_err(|e| e.to_string())
}

/// ADR-035 — am I still a member (false after a Commit removed me)?
pub async fn sync_group_is_active(group_id_hex: String) -> Result<bool, String> {
    let group = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    client.group_is_active(&group).map_err(|e| e.to_string())
}

/// ADR-088 — the group's admin as identity hex, read from the MLS state
/// all members share (the same on every phone).
pub async fn sync_group_admin(group_id_hex: String) -> Result<Option<String>, String> {
    let group = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    Ok(client.group_admin(&group).map_err(|e| e.to_string())?.map(hex::encode))
}

/// ADR-025/034 — `net_send_welcome` addresses each person's copy to the
/// devices of theirs that got a leaf.
fn remember_invited(group_id_hex: &str, people: Vec<sync::InvitedPerson>) {
    if let Ok(mut m) = invited_devices().lock() {
        for p in people {
            m.insert((group_id_hex.to_string(), p.identity_hex), p.devices);
        }
    }
}

/// Join a group from a Welcome blob (b64-encoded MLS Welcome). Returns
/// the group_id hex so the caller can wire it to its local chat row.
pub async fn sync_join_via_welcome(welcome_b64: String) -> Result<String, String> {
    let bytes = BASE64_STANDARD
        .decode(&welcome_b64)
        .map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot
        .as_mut()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let group_id = client
        .join_via_welcome(&bytes)
        .map_err(|e| e.to_string())?;
    drop(slot);
    // Tech-debt 2.34 — frames for this group that overtook its Welcome.
    // Dart handles events one at a time, so they reach it after it made
    // the chat row for this Welcome.
    replay_early_pushes(&group_id).await;
    Ok(hex::encode(&group_id))
}

/// Send a Welcome frame to a recipient via the WS server. Used right
/// after `sync_fetch_kp_and_invite` to deliver the Welcome to the new
/// member. The server forwards to recipient's connected sessions
/// (live-only delivery — recipient must be online).
pub async fn net_send_welcome(
    recipient_identity_pubkey_hex: String,
    group_id_hex: String,
    welcome_b64: String,
) -> Result<(), String> {
    // ADR-025 — the devices the last invite into this group added for this
    // person (so the Welcome goes to them only).
    let devices = invited_devices()
        .lock()
        .ok()
        .and_then(|mut m| m.remove(&(group_id_hex.clone(), recipient_identity_pubkey_hex.clone())))
        .unwrap_or_default();
    send_welcome_to(recipient_identity_pubkey_hex, group_id_hex, welcome_b64, devices).await
}

type InvitedDevices = std::sync::Mutex<std::collections::HashMap<(String, String), Vec<Vec<u8>>>>;

/// (group hex, person hex) → device keys added by the last invite.
fn invited_devices() -> &'static InvitedDevices {
    static M: OnceLock<InvitedDevices> = OnceLock::new();
    M.get_or_init(Default::default)
}

/// A Welcome frame, addressed to `devices` of the recipient (empty: any).
async fn send_welcome_to(
    recipient_identity_pubkey_hex: String,
    group_id_hex: String,
    welcome_b64: String,
    devices: Vec<Vec<u8>>,
) -> Result<(), String> {
    let recipient = hex::decode(&recipient_identity_pubkey_hex).map_err(|e| e.to_string())?;
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let welcome = BASE64_STANDARD.decode(&welcome_b64).map_err(|e| e.to_string())?;

    let slot = net_slot().lock().await;
    let client = slot.as_ref().ok_or_else(|| "net not connected".to_string())?;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let frame = net::proto::WsFrame {
        frame_id: format!("welcome-{}", uuid::Uuid::now_v7()),
        body: Some(net::proto::ws_frame::Body::Welcome(net::proto::Welcome {
            recipient_identity_pubkey: recipient,
            group_id,
            welcome_bytes: welcome,
            sent_at: now,
            recipient_device_pks: devices,
        })),
    };
    client.send(frame).await.map_err(|e| e.to_string())
}

// ─────────────────────────────────────────────────────────────────────
// Linked devices — ADR-025 (spec §6.7)
// ─────────────────────────────────────────────────────────────────────

/// Frames whose Ack a Rust flow is waiting for (frame_id → result).
/// `net_next_event` resolves them and still passes the Ack on to Dart.
fn ack_waiters() -> &'static std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<i32>>> {
    static W: OnceLock<std::sync::Mutex<std::collections::HashMap<String, tokio::sync::oneshot::Sender<i32>>>> =
        OnceLock::new();
    W.get_or_init(Default::default)
}

const COMMIT_ACK_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);

/// ADR-092 — per chat: the Commit that brought this device to its epoch and
/// the ones it saw there and did not take (`sync::commit_order`), kept in
/// settings — a phone restarted after refusing a garbage Commit must still
/// be able to say so.
const COMMIT_LOG_SETTING: &str = "commit_log";

fn commit_log() -> sync::commit_order::CommitLog {
    storage::setting_get(COMMIT_LOG_SETTING).ok().flatten().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

fn commit_log_update(change: impl FnOnce(&mut sync::commit_order::CommitLog)) {
    let mut log = commit_log();
    change(&mut log);
    if let Ok(j) = serde_json::to_string(&log) {
        let _ = storage::setting_set(COMMIT_LOG_SETTING, &j);
    }
}

/// Submit a pending Commit (ADR-022: `is_commit` + `commit_epoch`) and
/// wait for the server's verdict: Ack 0 → apply it (true); 409 → another
/// member's Commit won this epoch, drop ours (false). Anything else
/// (incl. timeout) drops ours and errors — the next sync retries.
/// Send a Commit and wait for the server's Ack: its code (0 = ordered,
/// 409 = another Commit came first), `None` when there was no answer; and
/// the Commit's message_id. It names (ADR-092) the Commit that brought us
/// to its epoch and the ones there we did not take.
async fn send_commit(group_id: &[u8], pending: &sync::group::PendingCommit) -> (Result<(), String>, Option<i32>, String) {
    send_commit_as(group_id, pending, uuid::Uuid::now_v7().to_string()).await
}

/// [`send_commit`] under a given message_id (ADR-101: the same Commit again).
async fn send_commit_as(group_id: &[u8], pending: &sync::group::PendingCommit, message_id: String) -> (Result<(), String>, Option<i32>, String) {
    if let Ok(mut sent) = sent_commits().lock() {
        sent.insert(hex::encode(group_id), (message_id.clone(), pending.commit_bytes.clone()));
    }
    let (parent, refused) = commit_log().for_commit(&hex::encode(group_id), pending.epoch);
    let frame_id = format!("commit-{message_id}");
    let (tx, rx) = tokio::sync::oneshot::channel();
    if let Ok(mut w) = ack_waiters().lock() {
        w.insert(frame_id.clone(), tx);
    }
    let sent = {
        let slot = net_slot().lock().await;
        match slot.as_ref() {
            Some(c) => c
                .send(net::proto::WsFrame {
                    frame_id: frame_id.clone(),
                    body: Some(net::proto::ws_frame::Body::Submit(net::proto::Submit {
                        group_id: group_id.to_vec(),
                        ciphertext: pending.commit_bytes.clone(),
                        message_id: message_id.clone(),
                        sealed_sender: false,
                        is_commit: true,
                        commit_epoch: pending.epoch,
                        urgent: false,
                        access_keys: Vec::new(),
                        refused_commit_ids: refused,
                        parent_commit_id: parent,
                    })),
                })
                .await
                .map_err(|e| e.to_string()),
            None => Err("net not connected".to_string()),
        }
    };
    let code = match sent {
        Ok(()) => tokio::time::timeout(COMMIT_ACK_TIMEOUT, rx).await.ok().and_then(|r| r.ok()),
        Err(_) => None,
    };
    if let Ok(mut w) = ack_waiters().lock() {
        w.remove(&frame_id);
    }
    (sent, code, message_id)
}

/// ADR-101 — the last Commit this run of the app sent in each chat
/// (group hex → message_id, bytes). When exactly these bytes come back from
/// the server, it took our Commit — whatever happened to its Ack. And only
/// such a frame is "our own Commit echoed back" (audit CM-06: a member's
/// frame that merely names our leaf is not, and is recorded as not taken).
type SentCommits = std::collections::HashMap<String, (String, Vec<u8>)>;
fn sent_commits() -> &'static std::sync::Mutex<SentCommits> {
    static S: OnceLock<std::sync::Mutex<SentCommits>> = OnceLock::new();
    S.get_or_init(Default::default)
}

/// ADR-101 — is this frame the Commit we sent in `g_hex` and still wait on
/// (this run, or before a restart — then it is in settings)?
fn is_our_sent_commit(g_hex: &str, frame: &[u8]) -> bool {
    sent_commits().lock().is_ok_and(|s| s.get(g_hex).is_some_and(|(_, bytes)| bytes == frame))
        || unanswered().get(g_hex).is_some_and(|u| u.commit == hex::encode(frame))
}

/// ADR-101 — a Commit we sent and got no answer to (per chat, in settings:
/// it must survive a restart, like the pending Commit in the MLS state).
const UNANSWERED_SETTING: &str = "commit_unanswered";

#[derive(serde::Serialize, serde::Deserialize, Clone)]
struct Unanswered {
    epoch: u64,
    commit: String,
    message_id: String,
    welcome: Option<String>,
    /// (person, device) the Commit adds — who gets the Welcome.
    adds: Vec<(String, String)>,
    /// It came back from the server and was applied; what is left is to
    /// welcome the devices it added.
    #[serde(default)]
    applied: bool,
}

/// ADR-101 — message_ids of our Commits applied when they came back from
/// the server (this run): "was it ours?" for the code that sent them.
fn echoed_commits() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static S: OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    S.get_or_init(Default::default)
}

fn was_echoed(message_id: &str) -> bool {
    echoed_commits().lock().is_ok_and(|s| s.contains(message_id))
}

fn unanswered() -> std::collections::HashMap<String, Unanswered> {
    storage::setting_get(UNANSWERED_SETTING).ok().flatten().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

fn unanswered_update(change: impl FnOnce(&mut std::collections::HashMap<String, Unanswered>)) {
    let mut all = unanswered();
    change(&mut all);
    if let Ok(j) = serde_json::to_string(&all) {
        let _ = storage::setting_set(UNANSWERED_SETTING, &j);
    }
}

/// ADR-101 — what the server's answer to the same Commit sent again means.
#[derive(Debug, PartialEq)]
enum Resend {
    /// Ack 0: the server has it (it answers a repeat of a Commit it took
    /// with 0 again, and takes one it never saw) — apply ours.
    Apply,
    /// 409: another change came first, as on a first send; 400 / 403: it
    /// will never take it. Drop ours.
    Drop,
    /// Busy (429), a server error, no answer: nothing is known — keep it.
    Wait,
}

/// Our own Commit is applied ONLY on Ack 0 (or when its bytes come back):
/// a 409 can mean someone else's change won, and applying ours then would
/// leave this device alone in an epoch of its own.
fn after_resend(code: Option<i32>) -> Resend {
    match code {
        Some(0) => Resend::Apply,
        None | Some(429) | Some(500..=599) => Resend::Wait,
        Some(_) => Resend::Drop,
    }
}

/// ADR-101 — the answer to a Commit came after we stopped waiting for it
/// (more than 20 s): act on it now, by the same rule as for a repeat. A
/// person with one device in the chat gets no copy of their Commit back,
/// so without this they would not write in the chat until the next sync.
async fn late_commit_ack(message_id: &str, code: i32) {
    let Some((g_hex, entry)) = unanswered().into_iter().find(|(_, e)| e.message_id == message_id) else { return };
    let Ok(group) = hex::decode(&g_hex) else { return };
    {
        let mut slot = sync_slot().lock().await;
        let Some(client) = slot.as_mut() else { return };
        if !client.has_pending_commit(&group).unwrap_or(false) || client.group_epoch(&group).ok() != Some(entry.epoch) {
            return;
        }
        match after_resend(Some(code)) {
            Resend::Apply => match client.confirm_commit(&group) {
                Ok(epoch) => {
                    commit_log_update(|log| log.moved(&g_hex, epoch, message_id));
                    // The Welcome and the roster go out at the next sync.
                    unanswered_update(|u| {
                        if let Some(e) = u.get_mut(&g_hex) {
                            e.applied = true;
                        }
                    });
                }
                Err(e) => {
                    tracing::warn!(group = %g_hex, error = %e, "a late Ack's Commit not applied");
                    return;
                }
            },
            Resend::Drop => {
                let _ = client.discard_commit(&group);
                unanswered_update(|u| {
                    u.remove(&g_hex);
                });
                return;
            }
            Resend::Wait => return,
        }
    }
    replay_early_pushes(&group).await;
}

/// ADR-101 — keep a frame that did not open, to try it again later?
/// `pending_here`: this chat has a Commit of ours waiting (`None` for a
/// sealed frame, which names no chat); `any_unanswered`: some chat has a
/// Commit the server did not answer.
fn hold_while_waiting(pending_here: Option<bool>, any_unanswered: bool) -> bool {
    match pending_here {
        Some(pending) => pending,
        None => any_unanswered,
    }
}

/// ADR-101 — before a change the person asked for: settle what still waits
/// in this chat, so the change is not refused for it.
async fn settle_before_change(http: &sync::HttpApi, group: &[u8]) {
    let my_device = match sync_slot().lock().await.as_ref() {
        Some(c) => c.device_public_key(),
        None => return,
    };
    settle_unanswered(http, group, &hex::encode(group), &my_device).await;
}

/// ADR-101 — settle the Commit of ours the server did not answer, before
/// this chat's device sync makes new ones. Still pending → send the very
/// same Commit again and act on the answer ([`after_resend`]). Applied (by the
/// Ack, or when it came back) → welcome the devices it added and tell the
/// server they are in. Another member's Commit won instead → nothing to do.
async fn settle_unanswered(http: &sync::HttpApi, group: &[u8], g_hex: &str, my_device: &[u8]) {
    let Some(entry) = unanswered().remove(g_hex) else { return };
    // Its first sending is still waiting for the answer: not ours to settle yet.
    if ack_waiters().lock().is_ok_and(|w| w.contains_key(&format!("commit-{}", entry.message_id))) {
        return;
    }
    let mut ours = entry.applied || was_echoed(&entry.message_id);
    // Still pending, and it is that very Commit (made at the epoch we are in)?
    let waiting = {
        let mut slot = sync_slot().lock().await;
        slot.as_mut().is_some_and(|c| c.has_pending_commit(group).unwrap_or(false) && c.group_epoch(group).ok() == Some(entry.epoch))
    };
    if waiting && !ours {
        let pending = sync::group::PendingCommit { epoch: entry.epoch, commit_bytes: hex::decode(&entry.commit).unwrap_or_default(), welcome_bytes: None };
        let (_, code, _) = send_commit_as(group, &pending, entry.message_id.clone()).await;
        let mut slot = sync_slot().lock().await;
        let Some(client) = slot.as_mut() else { return };
        match after_resend(code) {
            Resend::Apply => {
                if client.has_pending_commit(group).unwrap_or(false) {
                    match client.confirm_commit(group) {
                        Ok(epoch) => {
                            commit_log_update(|log| log.moved(g_hex, epoch, &entry.message_id));
                            ours = true;
                        }
                        Err(e) => tracing::warn!(group = %g_hex, error = %e, "the unanswered Commit not applied"),
                    }
                }
            }
            Resend::Drop => {
                let _ = client.discard_commit(group);
            }
            Resend::Wait => return,
        }
    }
    unanswered_update(|u| {
        u.remove(g_hex);
    });
    if !ours && commit_log().for_commit(g_hex, entry.epoch + 1).0 != entry.message_id {
        return; // not ours: someone else's Commit took the chat on
    }
    // What the others sent after our Commit, kept while it waited.
    replay_early_pushes(group).await;
    tracing::info!(group = %g_hex, "a Commit the server had not answered is settled");
    let seed = match sync_slot().lock().await.as_ref() {
        Some(c) => c.login_seed_bytes(),
        None => return,
    };
    let mut members = vec![my_device.to_vec()];
    members.extend(entry.adds.iter().filter_map(|(_, d)| hex::decode(d).ok()));
    if let Err(e) = http.announce_group(seed, group, epoch_of(group).await, &members).await {
        tracing::warn!(group = %g_hex, error = %e, "settled, but not announced");
    }
    let Some(welcome) = entry.welcome.and_then(|w| hex::decode(w).ok()) else { return };
    let w64 = BASE64_STANDARD.encode(welcome);
    let mut owners: Vec<&String> = entry.adds.iter().map(|(o, _)| o).collect();
    owners.sort();
    owners.dedup();
    for owner in owners {
        let devices: Vec<Vec<u8>> = entry.adds.iter().filter(|(o, _)| o == owner).filter_map(|(_, d)| hex::decode(d).ok()).collect();
        if let Err(e) = send_welcome_to(owner.clone(), g_hex.to_string(), w64.clone(), devices).await {
            tracing::warn!(group = %g_hex, error = %e, "settled, but a Welcome was not sent");
        }
    }
}

async fn submit_pending_commit(group_id: &[u8], pending: &sync::group::PendingCommit) -> Result<bool, String> {
    let ours = submit_pending_commit_inner(group_id, pending).await;
    // ADR-101 — frames of the epoch our Commit leads to that came before
    // it was applied here could not be opened then; they were kept.
    if ours == Ok(true) {
        replay_early_pushes(group_id).await;
    }
    ours
}

async fn submit_pending_commit_inner(group_id: &[u8], pending: &sync::group::PendingCommit) -> Result<bool, String> {
    // Who the Commit adds — read while it is still pending.
    let adds = match sync_slot().lock().await.as_mut() {
        Some(c) => c.pending_adds(group_id).unwrap_or_default(),
        None => Vec::new(),
    };
    // Written down BEFORE it is sent: the app may be killed while it waits
    // for the answer, and must still know its own Commit afterwards.
    let message_id = uuid::Uuid::now_v7().to_string();
    let g_hex = hex::encode(group_id);
    let entry = Unanswered {
        applied: false,
        epoch: pending.epoch,
        commit: hex::encode(&pending.commit_bytes),
        message_id: message_id.clone(),
        welcome: pending.welcome_bytes.as_ref().map(hex::encode),
        adds: adds.into_iter().map(|(who, device)| (hex::encode(who), hex::encode(device))).collect(),
    };
    unanswered_update(|u| {
        u.insert(g_hex.clone(), entry);
    });
    let (sent, code, message_id) = send_commit_as(group_id, pending, message_id).await;
    // Answered (or never sent): nothing to remember. No answer: it stays.
    if code.is_some() || sent.is_err() {
        unanswered_update(|u| {
            if u.get(&g_hex).is_some_and(|e| e.message_id == message_id) {
                u.remove(&g_hex);
            }
        });
    }
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    match code {
        // No Commit of ours is pending any more. ADR-101 — ours came back
        // from the server before its Ack and was applied then (the chat's
        // record names it): done. Otherwise another member's Commit took us
        // on and dropped ours: ours isn't the one.
        Some(0) if !client.has_pending_commit(group_id).map_err(|e| e.to_string())? => {
            Ok(was_echoed(&message_id) || commit_log().for_commit(&hex::encode(group_id), pending.epoch + 1).0 == message_id)
        }
        Some(0) => {
            let epoch = client.confirm_commit(group_id).map_err(|e| e.to_string())?;
            commit_log_update(|log| log.moved(&hex::encode(group_id), epoch, &message_id));
            Ok(true)
        }
        Some(409) => {
            client.discard_commit(group_id).map_err(|e| e.to_string())?;
            Ok(false)
        }
        // ADR-101 — sent, and no answer in 20 s: the server may have taken
        // it. Dropping it here left the device behind the chat for good.
        // It stays pending; it is applied when it comes back from the
        // server, or settled at the next device sync (`settle_unanswered`).
        None if sent.is_ok() => {
            if !was_echoed(&message_id) && !client.has_pending_commit(group_id).unwrap_or(false) {
                unanswered_update(|u| {
                    u.remove(&g_hex);
                });
                return Err("another member's change came first".to_string());
            }
            Err("no answer from the server".to_string())
        }
        other => {
            let _ = client.discard_commit(group_id);
            Err(match (sent, other) {
                (Err(e), _) => e,
                (_, Some(c)) => format!("server refused the commit ({c})"),
                _ => "no answer from the server".to_string(),
            })
        }
    }
}

/// One of the person's devices, for Settings → Devices.
pub struct LinkedDevice {
    pub device_pk_hex: String,
    /// The account's first device (its key is the identity key).
    pub is_primary: bool,
    pub is_this_device: bool,
    pub registered_at_unix: i64,
    /// Last time the server heard from it (login / KeyPackage upload).
    pub last_seen_unix: i64,
}

/// A device silent this long is left out of device sync (an abandoned
/// install — e.g. the app deleted and the account entered again — must not
/// be pulled back into chats with its stale KeyPackages). It still shows
/// in the list, to be revoked.
const STALE_DEVICE_SECS: i64 = 30 * 24 * 3600;

/// What [`sync_devices`] changed.
pub struct DeviceSyncReport {
    /// Devices added to groups (summed over groups).
    pub added: u32,
    /// Revoked devices removed from groups.
    pub removed: u32,
    /// Groups that could not be brought up to date this time.
    pub failed: Vec<String>,
    /// ADR-064 — device transfers queued for devices just added to my
    /// own-devices group (run them with `device_transfer_step`).
    pub transfers: u32,
    /// ADR-074 — other members' new devices added to our chats.
    pub peers_added: u32,
    /// ADR-075 — chats this device entered by their card.
    pub joined: u32,
    /// ADR-075 — other members' devices they cut off, taken out of chats.
    pub peers_removed: u32,
}

/// ADR-074 — another member's device joins our chats only once it has been
/// registered this long: their own devices (if any are on) add it first,
/// and fewer of us race for its KeyPackages.
const PEER_ADD_GRACE_SECS: i64 = 10 * 60;
/// ADR-074 — how long a person's device list is reused between syncs.
const PEER_DEVICES_TTL_SECS: i64 = 10 * 60;
/// ADR-074 — chats brought up to date for other people's devices per sync
/// (the rest go on next time).
const PEER_COMMITS_PER_SYNC: usize = 20;

/// ADR-074 / ADR-075 — a person's devices as the server lists them, the
/// revoked ones with their proofs (an older server: active only), kept
/// [`PEER_DEVICES_TTL_SECS`]. None when the server didn't answer.
async fn peer_devices(http: &sync::HttpApi, identity_hex: &str) -> Option<Vec<sync::http_api::DeviceInfo>> {
    type Cache = std::sync::Mutex<std::collections::HashMap<String, (i64, Vec<sync::http_api::DeviceInfo>)>>;
    static CACHE: OnceLock<Cache> = OnceLock::new();
    let cache = CACHE.get_or_init(Default::default);
    let now = now_unix() as i64;
    let cached = cache
        .lock()
        .ok()
        .and_then(|c| c.get(identity_hex).filter(|(at, _)| now - at < PEER_DEVICES_TTL_SECS).map(|(_, l)| l.clone()));
    if let Some(l) = cached {
        return Some(l);
    }
    let l = http.list_devices_with_revoked(identity_hex).await.ok()?;
    if let Ok(mut c) = cache.lock() {
        c.insert(identity_hex.to_string(), (now, l.clone()));
    }
    Some(l)
}

/// ADR-074 — a person's devices that may be added to chats (not revoked,
/// heard from in the last 30 days, registered over [`PEER_ADD_GRACE_SECS`]
/// ago), kept [`PEER_DEVICES_TTL_SECS`]. None when the server didn't say.
async fn peer_addable_devices(http: &sync::HttpApi, identity_hex: &str) -> Option<Vec<Vec<u8>>> {
    let now = now_unix() as i64;
    let listed = peer_devices(http, identity_hex).await?;
    Some(
        listed
            .iter()
            .filter(|d| !d.revoked)
            .filter(|d| now.saturating_sub(d.last_seen_at.max(d.registered_at)) <= STALE_DEVICE_SECS)
            .filter(|d| now.saturating_sub(d.registered_at) >= PEER_ADD_GRACE_SECS)
            .filter_map(|d| hex::decode(&d.device_pk_hex).ok())
            .collect(),
    )
}

/// Tech-debt 2.5 — tell the server how long to keep this chat's stored
/// ciphertexts (the disappearing timer, seconds; 0 = off). Sealed
/// deliveries name no chat, so they keep the server's global retention.
pub async fn sync_set_chat_retention(server_base_url: String, group_id_hex: String, after_secs: i64) -> Result<(), String> {
    let group = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    sync::HttpApi::new(server_base_url)
        .set_group_retention(seed, &group, after_secs)
        .await
        .map_err(|e| e.to_string())
}

/// Tech-debt 2.2 — give our access key to the members of these chats
/// (an MLS message they keep), once per group epoch: a new member gets
/// it after the next Commit. Run on connect, with device sync.
///
/// ADR-071 — with a server that knows per-contact keys: first the server's
/// set is brought up to date (`access_reconcile`), then everyone gets
/// their own key (blocked people and unaccepted message requests none) —
/// in a chat of two as an ordinary message in it, in a group sealed to
/// each member alone.
pub async fn sync_share_access_key(group_ids_hex: Vec<String>) -> Result<u32, String> {
    let groups: Vec<(String, Vec<u8>)> =
        group_ids_hex.into_iter().filter_map(|h| Some((h.clone(), hex::decode(&h).ok()?))).collect();
    let base = sealed_slot().lock().await.as_ref().map(|s| s.base_url.clone());
    let per_contact = match base {
        Some(b) => access_reconcile(&b, &groups.iter().map(|g| g.1.clone()).collect::<Vec<_>>()).await?,
        // Not connected yet: never hand out a key the server hasn't got.
        None if per_contact_access() => return Ok(0),
        None => false,
    };
    if per_contact {
        share_per_contact_keys(groups).await
    } else {
        share_shared_access_key(groups.into_iter().map(|g| g.0).collect()).await
    }
}

/// ADR-071 — each person their own key, once per (group epoch, key
/// version, who's in it and not blocked): a new member, a rotation or an
/// unblock sends again. Not in message requests until I accept them.
async fn share_per_contact_keys(groups: Vec<(String, Vec<u8>)>) -> Result<u32, String> {
    let blocked: std::collections::HashSet<String> =
        storage::peers_blocked().map_err(|e| e.to_string())?.into_iter().map(|p| p.to_lowercase()).collect();
    // A stranger's chat I haven't accepted (or one not saved yet): no key
    // — their messages stay requests that don't wake my phone.
    let accepted: std::collections::HashSet<String> =
        storage::chats_list().map_err(|e| e.to_string())?.into_iter().filter(|c| !c.request).map(|c| c.id).collect();
    let mut sent = 0;
    for (g_hex, group) in groups {
        if !accepted.contains(&g_hex) {
            continue;
        }
        let (epoch, version, others, wanted) = {
            let mut slot = sync_slot().lock().await;
            let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
            let (Ok(epoch), Ok(members)) = (c.group_epoch(&group), c.group_member_identities(&group)) else { continue };
            let me = c.identity_pubkey_hex();
            let others: Vec<String> = members.iter().map(hex::encode).filter(|m| *m != me).collect();
            let wanted: Vec<(String, [u8; sync::envelope::ACCESS_KEY_LEN])> = others
                .iter()
                .filter(|o| !blocked.contains(*o))
                .filter_map(|o| Some((o.clone(), c.access_key_for(&hex::decode(o).ok()?))))
                .collect();
            (epoch, c.access_version(), others.len(), wanted)
        };
        let mark = format!("access_sent:{g_hex}");
        let who: Vec<&str> = wanted.iter().map(|w| &w.0[..w.0.len().min(16)]).collect();
        let state = format!("{epoch}:{version}:pc:{}", who.join(","));
        if storage::setting_get(&mark).ok().flatten().as_deref() == Some(state.as_str()) {
            continue;
        }
        let mut complete = true;
        if others == 1 && wanted.len() == 1 {
            // A chat of two: everyone in it is them or me.
            net_send_encrypted(g_hex.clone(), sync::envelope::encode_access(&wanted[0].1), uuid::Uuid::now_v7().to_string())
                .await?;
        } else {
            for (who, key) in &wanted {
                match delivery_key_of(who).await {
                    Some(pk) => send_sealed_to_self(&group, &sync::envelope::encode_access(key), &pk).await?,
                    None => complete = false, // no delivery key yet: next time
                }
            }
        }
        if complete {
            let _ = storage::setting_set(&mark, &state);
            sent += 1;
        }
    }
    Ok(sent)
}

/// Tech-debt 2.2 — the old shared key (a server without ADR-071).
async fn share_shared_access_key(group_ids_hex: Vec<String>) -> Result<u32, String> {
    let mut sent = 0;
    for g_hex in group_ids_hex {
        let Ok(group) = hex::decode(&g_hex) else { continue };
        let (epoch, key, version) = {
            let mut slot = sync_slot().lock().await;
            let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
            match c.group_epoch(&group) {
                Ok(e) => (e, c.access_key(), c.access_version()),
                Err(_) => continue,
            }
        };
        // Once per (group epoch, key version): new members and rotations.
        let mark = format!("access_sent:{g_hex}");
        let state = format!("{epoch}:{version}");
        if storage::setting_get(&mark).ok().flatten().as_deref() == Some(state.as_str()) {
            continue;
        }
        net_send_encrypted(g_hex.clone(), sync::envelope::encode_access(&key), uuid::Uuid::now_v7().to_string()).await?;
        let _ = storage::setting_set(&mark, &state);
        sent += 1;
    }
    Ok(sent)
}

// ─────────────────────────────────────────────────────────────────────
// QR pairing — tech-debt 4.2 / ADR-025
// ─────────────────────────────────────────────────────────────────────

fn pairing_offer() -> &'static std::sync::Mutex<Option<sync::pairing::PairingOffer>> {
    static P: OnceLock<std::sync::Mutex<Option<sync::pairing::PairingOffer>>> = OnceLock::new();
    P.get_or_init(Default::default)
}

/// New device: start a pairing for this device's key (`device_seed_hex`,
/// the seed it will keep) — returns the QR text
/// (`sinhron-pair:2:<id>:<one-time key>:<device key>`). The one-time key
/// stays in memory only; a new call replaces it.
pub fn pairing_offer_new(device_seed_hex: String) -> Result<String, String> {
    let seed: [u8; 32] = hex::decode(&device_seed_hex)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or("device seed must be 32 bytes hex")?;
    let device_pub = sync::pairing::device_pub_of_seed(&seed);
    let offer = sync::pairing::PairingOffer::new(&sync::pairing::default_crypto(), device_pub).map_err(|e| e.to_string())?;
    let qr = offer.qr_text();
    *pairing_offer().lock().map_err(|e| e.to_string())? = Some(offer);
    Ok(qr)
}

/// New device: wait (polling every 2 s, up to `timeout_secs`) for the
/// other device to answer the QR. Returns the account secret, or None on
/// timeout. Works before any account exists on this device.
pub async fn pairing_wait(server_base_url: String, timeout_secs: u32) -> Result<Option<String>, String> {
    let id = pairing_offer()
        .lock()
        .map_err(|e| e.to_string())?
        .as_ref()
        .map(|o| o.id)
        .ok_or("no pairing in progress")?;
    let http = sync::HttpApi::new(server_base_url);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(timeout_secs as u64);
    loop {
        if let Some(sealed) = http.take_pairing(&id).await.map_err(|e| e.to_string())? {
            let guard = pairing_offer().lock().map_err(|e| e.to_string())?;
            let offer = guard.as_ref().ok_or("pairing cancelled")?;
            return offer.open(&sync::pairing::default_crypto(), &sealed).map(Some).map_err(|e| e.to_string());
        }
        if std::time::Instant::now() >= deadline {
            return Ok(None);
        }
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    }
}

/// New device: forget the pending pairing (screen closed).
pub fn pairing_cancel() {
    if let Ok(mut p) = pairing_offer().lock() {
        *p = None;
    }
}

/// Is this text a Sinhron pairing code? (Before asking for confirmation.)
pub fn pairing_is_code(text: String) -> bool {
    sync::pairing::parse_qr(&text).is_ok()
}

/// DEV-8 — the server has already disconnected the device: a device sync that
/// failed right after (the connection dropped) is not a failed disconnect.
/// The app goes on to change the account keys; the next sync removes the
/// device's leaves (it is remembered as disconnected — PAIR-1).
fn report_after_revoke(synced: Result<DeviceSyncReport, String>) -> DeviceSyncReport {
    synced.unwrap_or_else(|e| {
        tracing::warn!(error = %e, "device disconnected; the device sync after it failed (the next one retries)");
        DeviceSyncReport { added: 0, removed: 0, failed: Vec::new(), transfers: 0, peers_added: 0, joined: 0, peers_removed: 0 }
    })
}

/// PAIR-1 — pairing a key I once disconnected is my own decision: allowed again.
fn pairing_allows(device_pub: &[u8]) {
    let k = hex::encode(device_pub);
    if storage::devsync::device_revoked(&k) {
        let _ = storage::devsync::device_revoked_set(&k, false);
    }
}

/// Existing device: answer a new device's QR — sign a certificate for its
/// device key and seal a linked-device bundle (no identity key) to its
/// one-time key, left on the server signed by our identity (ADR-027).
/// Only a device holding the account key can do this ("no account key").
pub async fn pairing_send(server_base_url: String, qr_text: String) -> Result<(), String> {
    let (_, _, device_pub) = sync::pairing::parse_qr(&qr_text).map_err(|e| e.to_string())?;
    pairing_allows(&device_pub);
    let (bundle, seed) = {
        let slot = sync_slot().lock().await;
        let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
        (c.linked_bundle_for(&device_pub).map_err(|e| e.to_string())?, c.identity_seed_bytes())
    };
    let (id, sealed) =
        sync::pairing::seal_secret(&sync::pairing::default_crypto(), &qr_text, &bundle).map_err(|e| e.to_string())?;
    sync::HttpApi::new(server_base_url).put_pairing(seed, &id, &sealed).await.map_err(|e| e.to_string())
}

/// Route the app's server traffic (WS + HTTP, link previews) through a
/// SOCKS5 proxy — e.g. Tor via Orbot, `127.0.0.1:9050` — so the server
/// doesn't see the phone's IP. Empty = connect directly. Takes effect for
/// new connections (reconnect after changing it).
pub fn net_set_socks_proxy(proxy: String) {
    net::set_socks_proxy(Some(proxy));
}

/// ADR-027 — the linked-device bundle for THIS device from the phrase
/// (sign-in with the 24 words on a new device, or rebuilding a wiped
/// Keychain): only the bundle is kept; the identity key is not.
pub fn linked_bundle_from_phrase(phrase: String, device_seed_hex: String) -> Result<String, String> {
    let seed: [u8; 32] = hex::decode(&device_seed_hex)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or("device seed must be 32 bytes hex")?;
    sync::identity::linked_bundle_from_phrase(&phrase, &seed).map_err(|e| e.to_string())
}

/// ADR-027 — add a device by QR from a device that holds no account key:
/// the 24 words authorize it (used for this call only, never stored).
pub async fn pairing_send_with_phrase(server_base_url: String, qr_text: String, phrase: String) -> Result<(), String> {
    let (_, _, device_pub) = sync::pairing::parse_qr(&qr_text).map_err(|e| e.to_string())?;
    pairing_allows(&device_pub);
    let bundle = sync::identity::linked_bundle_for_device(&phrase, &device_pub).map_err(|e| e.to_string())?;
    let (id, sealed) =
        sync::pairing::seal_secret(&sync::pairing::default_crypto(), &qr_text, &bundle).map_err(|e| e.to_string())?;
    let identity = crypto::identity::derive_identity(&phrase).map_err(|e| e.to_string())?;
    sync::HttpApi::new(server_base_url)
        .put_pairing(identity.ed25519_secret, &id, &sealed)
        .await
        .map_err(|e| e.to_string())
}

/// ADR-027 — revoke a device from one that holds no account key: the 24
/// words authorize it (this call only), then device sync removes it from
/// the chats and the access key is rotated.
pub async fn devices_revoke_with_phrase(
    server_base_url: String,
    device_pk_hex: String,
    phrase: String,
    group_ids_hex: Vec<String>,
) -> Result<DeviceSyncReport, String> {
    let device = hex::decode(&device_pk_hex).map_err(|e| e.to_string())?;
    let identity = crypto::identity::derive_identity(&phrase).map_err(|e| e.to_string())?;
    sync::HttpApi::new(server_base_url.clone())
        .revoke_device(identity.ed25519_secret, &device)
        .await
        .map_err(|e| e.to_string())?;
    let _ = storage::devsync::device_revoked_set(&hex::encode(&device), true); // PAIR-1
    Ok(report_after_revoke(sync_devices(server_base_url, group_ids_hex).await))
}

/// ADR-037 — delete my account on the server. Needs the account key: this
/// device's, or — on a device paired by QR — the 24 words (used for this
/// call only). The app wipes this device after it succeeds.
pub async fn account_delete(server_base_url: String, phrase: Option<String>) -> Result<(), String> {
    let seed = match phrase {
        Some(p) => crypto::identity::derive_identity(&p).map_err(|e| e.to_string())?.ed25519_secret,
        None => {
            let slot = sync_slot().lock().await;
            let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
            if !c.has_account_key() {
                return Err("needs the 24 words on this device".to_string());
            }
            c.identity_seed_bytes()
        }
    };
    sync::HttpApi::new(server_base_url).delete_account(seed).await.map_err(|e| e.to_string())
}

/// Overnight item 8 / 9 — tell the server this device's APNs token
/// (`kind`: alert / voip; empty token = stop). `sandbox`: the token is from
/// Apple's development environment (a build installed from Xcode). `lang`:
/// the words of the notification. Android (ADR-040): the token is a
/// UnifiedPush endpoint and `p256dh` / `auth` (base64url) the phone's Web
/// Push keys — the server encrypts the pushes to them (RFC 8291).
pub async fn push_register_token(
    server_base_url: String,
    kind: String,
    token_hex: String,
    sandbox: bool,
    lang: String,
    p256dh: Option<String>,
    auth: Option<String>,
    call_hint_key_hex: Option<String>,
) -> Result<(), String> {
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.login_seed_bytes()
    };
    // An APNs token is hex (lower-cased); a UnifiedPush endpoint (ADR-040)
    // is a URL whose path is case-sensitive — kept as is.
    let token = if token_hex.starts_with("https://") { token_hex } else { token_hex.to_lowercase() };
    let keys = p256dh.as_deref().zip(auth.as_deref());
    sync::HttpApi::new(server_base_url)
        .put_push_token(seed, &kind, &token, sandbox, &lang, keys, call_hint_key_hex.as_deref())
        .await
        .map_err(|e| e.to_string())
}

/// ADR-056 — this person's private delivery keys (hex) for the iPhone's
/// Notification Service Extension, which opens message previews sealed to
/// them. The app hands them straight to the Keychain (shared with the
/// extension only) and keeps no copy; they are derived, not stored, here.
pub async fn push_preview_keys() -> Result<Vec<String>, String> {
    let mut slot = sync_slot().lock().await;
    let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    c.set_rotated_roots(&account_roots());
    Ok(c.push_preview_secrets(now_unix()).map_err(|e| e.to_string())?.iter().map(hex::encode).collect())
}

/// Now, by the server's clock (this phone's clock + the offset learned from
/// the server), in milliseconds — for message ids and message times, so a
/// phone whose clock runs behind doesn't put its messages in the past.
#[flutter_rust_bridge::frb(sync)]
pub fn clock_now_ms() -> i64 {
    net::clock_drift::corrected_now_ms()
}

/// ADR-043 — a signed invite link: whoever opens it gets this server set
/// and me as a contact. Signed with the identity key, or on a linked device
/// with its own key + certificate. Short (`https://<server>/i/<id>#<key>`)
/// when the server kept the sealed link; else the long
/// `https://<server>/join#…` (offline, an old server).
pub async fn invite_link_create(server_host: String, name: String) -> Result<String, String> {
    let long = {
        let slot = sync_slot().lock().await;
        let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
        let identity = c.has_account_key().then(|| c.identity_seed_bytes());
        let device = c.device_seed_bytes();
        let cert = c.device_certificate();
        sync::invite::make_link(identity.as_ref(), &device, cert.as_deref(), &server_host, &name, now_unix() as i64)
            .map_err(|e| e.to_string())?
    };
    Ok(sync::invite::shorten(&long).await)
}

/// ADR-043 — a short invite link (`https://<host>/i/<id>#<key>` or
/// `sinhron://i/<host>/<id>#<key>`) → the long link it stands for, fetched
/// from its server and opened; any other link comes back unchanged.
/// Err: `expired` (gone from the server), `damaged`, `offline`.
pub async fn invite_link_resolve(link: String) -> Result<String, String> {
    sync::invite::resolve(&link).await.map_err(|e| e.to_string())
}

/// What an opened invite link says (verified).
pub struct InviteLink {
    pub server_host: String,
    pub identity_hex: String,
    pub name: String,
    pub created_at: i64,
}

/// ADR-043 — open and verify an invite link. Err: not an invite / damaged /
/// changed or forged (the message says which).
pub fn invite_link_open(link: String) -> Result<InviteLink, String> {
    let inv = sync::invite::parse_link(&link).map_err(|e| match e {
        sync::invite::InviteError::NotInvite => "not_invite".to_string(),
        sync::invite::InviteError::Malformed => "damaged".to_string(),
        sync::invite::InviteError::BadSignature | sync::invite::InviteError::HostMismatch => "forged".to_string(),
    })?;
    Ok(InviteLink {
        server_host: inv.server_host,
        identity_hex: inv.identity_hex,
        name: inv.name,
        created_at: inv.created_at,
    })
}

/// ADR-037 — report someone to the server's operator. `reason`: spam /
/// abuse / illegal / other; `message_text` only if the reporter chose to
/// share the message.
pub async fn report_person(
    server_base_url: String,
    reported_identity_hex: String,
    reason: String,
    message_text: Option<String>,
) -> Result<(), String> {
    let reported: [u8; 32] = hex::decode(&reported_identity_hex)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or("reported identity must be 32 bytes hex")?;
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    sync::HttpApi::new(server_base_url)
        .report(seed, &reported, &reason, message_text.as_deref())
        .await
        .map_err(|e| e.to_string())
}

/// ADR-077 — one service notice from the server (the "Server" chat).
pub struct AdminNoticeFfi {
    pub id: i64,
    /// alert / ok / report.
    pub kind: String,
    pub text: String,
    /// Unix seconds.
    pub ts: i64,
}

/// ADR-077 — the server's service notices after `after_id`, oldest first;
/// `None` when this person isn't the server's administrator.
pub async fn admin_notices(server_base_url: String, after_id: i64) -> Result<Option<Vec<AdminNoticeFfi>>, String> {
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    let notices = sync::HttpApi::new(server_base_url)
        .admin_notices(seed, after_id)
        .await
        .map_err(|e| e.to_string())?;
    Ok(notices.map(|v| {
        v.into_iter()
            .map(|n| AdminNoticeFfi { id: n.id, kind: n.kind, text: n.text, ts: n.ts })
            .collect()
    }))
}

/// ADR-027 — does this device hold the account key (can add / revoke
/// devices)? QR-paired devices don't.
pub async fn sync_has_account_key() -> Result<bool, String> {
    let slot = sync_slot().lock().await;
    Ok(slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.has_account_key())
}

/// ADR-025 — this person's active devices.
pub async fn devices_list(server_base_url: String) -> Result<Vec<LinkedDevice>, String> {
    let (me, mine) = {
        let slot = sync_slot().lock().await;
        let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
        (c.identity_pubkey_hex(), hex::encode(c.device_public_key()))
    };
    let list = sync::HttpApi::new(server_base_url).list_devices(&me).await.map_err(|e| e.to_string())?;
    Ok(list
        .into_iter()
        .map(|d| LinkedDevice {
            is_primary: d.certificate_hex.is_empty(),
            is_this_device: d.device_pk_hex == mine,
            device_pk_hex: d.device_pk_hex,
            registered_at_unix: d.registered_at,
            last_seen_unix: d.last_seen_at.max(d.registered_at),
        })
        .collect())
}

/// ADR-025 — device sync. For each of `group_ids_hex` this device is in:
/// add the person's other active devices that are missing (one pending
/// Commit + a Welcome to ourselves) and remove leaves of revoked ones.
/// Run on resume and after creating a chat; safe to repeat.
pub async fn sync_devices(server_base_url: String, group_ids_hex: Vec<String>) -> Result<DeviceSyncReport, String> {
    let http = sync::HttpApi::new(server_base_url);
    let (me_hex, me, my_device, seed) = {
        let slot = sync_slot().lock().await;
        let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
        let me_hex = c.identity_pubkey_hex();
        let me: [u8; 32] = hex::decode(&me_hex).ok().and_then(|v| v.try_into().ok()).ok_or("bad identity")?;
        (me_hex, me, c.device_public_key(), c.login_seed_bytes())
    };
    let listed = http.list_devices(&me_hex).await.map_err(|e| e.to_string())?;
    // Revoked ones are already absent; long-silent ones aren't *added*
    // (but aren't removed either — only revocation does that).
    let now = now_unix() as i64;
    // PAIR-1 / XFER-7 — a device I disconnected is not "active" whatever the
    // server lists: never added back (no history, no transfer), its leaf removed.
    let active: Vec<Vec<u8>> =
        storage::devsync::without_revoked_devices(listed.iter().filter_map(|d| hex::decode(&d.device_pk_hex).ok()).collect());
    let addable: Vec<Vec<u8>> = storage::devsync::without_revoked_devices(
        listed
            .iter()
            .filter(|d| now.saturating_sub(d.last_seen_at.max(d.registered_at)) <= STALE_DEVICE_SECS)
            .filter_map(|d| hex::decode(&d.device_pk_hex).ok())
            .collect(),
    );
    // ADR-064 — everything goes from an older device to a newer one, never
    // back (owner, 2026-10-26: the new phone sent its empty database to
    // the old one — "Done — 0 messages moved" — and the real transfer
    // never started). Unknown dates: allowed, as before.
    let registered = |k: &[u8]| listed.iter().find(|d| hex::decode(&d.device_pk_hex).ok().as_deref() == Some(k)).map(|d| d.registered_at);
    let my_registered = registered(&my_device);
    let newer_than_me = |k: &[u8]| sends_everything_to(my_registered, registered(k));
    let saved_hex = storage::setting_get(SAVED_CHAT_SETTING).ok().flatten().filter(|s| !s.is_empty());
    let mut report = DeviceSyncReport { added: 0, removed: 0, failed: Vec::new(), transfers: 0, peers_added: 0, joined: 0, peers_removed: 0 };
    // ADR-075 — chats with no MLS state on this device (restored from a
    // backup): it may enter them by their card.
    let mut absent: Vec<(Vec<u8>, String)> = Vec::new();
    // ADR-074 — people whose new device had no KeyPackage left this run.
    let mut no_packages: Vec<[u8; 32]> = Vec::new();
    let mut peer_commits = 0usize;
    for g_hex in group_ids_hex {
        let Ok(group) = hex::decode(&g_hex) else { continue };
        settle_unanswered(&http, &group, &g_hex, &my_device).await;
        let in_group = {
            let mut slot = sync_slot().lock().await;
            let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
            match c.group_device_keys(&group, &me) {
                Ok(k) => k,
                Err(_) => {
                    absent.push((group.clone(), g_hex.clone()));
                    continue; // not an MLS group on this device
                }
            }
        };
        if !in_group.contains(&my_device) {
            continue;
        }
        let stale: Vec<Vec<u8>> = in_group.iter().filter(|k| !active.contains(k) && **k != my_device).cloned().collect();
        let missing: Vec<Vec<u8>> = addable.iter().filter(|k| !in_group.contains(k)).cloned().collect();
        let result: Result<(), String> = async {
            for key in &stale {
                let pending = {
                    let mut slot = sync_slot().lock().await;
                    slot.as_mut().ok_or("sync not initialised")?.remove_device_pending(&group, key).map_err(|e| e.to_string())?
                };
                if submit_pending_commit(&group, &pending).await? {
                    report.removed += 1;
                }
            }
            if missing.is_empty() {
                return Ok(());
            }
            let kps = match http.fetch_device_keypackages(seed, &me_hex, &missing).await {
                Ok(k) => k,
                // The new device hasn't published KeyPackages yet.
                Err(sync::HttpError::Empty(_)) => return Ok(()),
                Err(e) => return Err(e.to_string()),
            };
            // ADR-074 — each package must really be one of mine.
            let packages: Vec<([u8; 32], Vec<u8>)> = kps.into_iter().map(|(_, kp)| (me, kp)).collect();
            let (pending, added) = {
                let mut slot = sync_slot().lock().await;
                slot.as_mut().ok_or("sync not initialised")?.invite_devices_of_pending(&group, &packages).map_err(|e| e.to_string())?
            };
            let devices: Vec<Vec<u8>> = added.into_iter().map(|(_, k)| k).collect();
            if !submit_pending_commit(&group, &pending).await? {
                return Ok(()); // lost the race; the next sync retries
            }
            let mut members = vec![my_device.clone()];
            members.extend(devices.iter().cloned());
            http.announce_group(seed, &group, epoch_of(&group).await, &members).await.map_err(|e| e.to_string())?;
            if let Some(w) = &pending.welcome_bytes {
                // Addressed to the devices just added — not queued for the rest.
                send_welcome_to(me_hex.clone(), g_hex.clone(), BASE64_STANDARD.encode(w), devices.clone()).await?;
            }
            report.added += devices.len() as u32;
            // The new device can't decrypt older MLS messages — hand it
            // the chat's recent ones from our local copy.
            if let Err(e) = send_history(&group, &g_hex).await {
                tracing::warn!(group = %g_hex, error = %e, "history for the new device not sent");
            }
            // ADR-064 — joining my own-devices group: it gets everything
            // (full history, contacts, packs, settings) through a transfer.
            if saved_hex.as_deref() == Some(g_hex.as_str()) {
                for d in devices.iter().filter(|d| newer_than_me(d)) {
                    if queue_transfer_to(d, &g_hex) {
                        report.transfers += 1;
                    }
                }
            }
            Ok(())
        }
        .await;
        // ADR-064 — a newer device of mine already in my own-devices group
        // that never got everything from this one (it joined through the
        // other device's group, which this one adopted): send it now, once.
        if saved_hex.as_deref() == Some(g_hex.as_str()) {
            for d in in_group.iter().filter(|d| **d != my_device && active.contains(d) && newer_than_me(d)) {
                let recent = registered(d).is_some_and(|r| now.saturating_sub(r) <= CATCH_UP_TRANSFER_SECS);
                if recent && !transfer_sent_to(d) && queue_transfer_to(d, &g_hex) {
                    report.transfers += 1;
                }
            }
        }
        if let Err(e) = result {
            tracing::warn!(group = %g_hex, error = %e, "device sync failed for group");
            report.failed.push(g_hex.clone());
            continue;
        }
        if peer_commits >= PEER_COMMITS_PER_SYNC {
            continue;
        }
        // ADR-074 — another member's new device (they lost their phone and
        // signed in again; or linked one while their other devices are
        // off): any of us adds it. Checked to be that person's.
        let peers: Result<u32, String> = add_peer_devices(&http, &group, &g_hex, &me, &my_device, &mut no_packages).await;
        match peers {
            Ok(0) => {}
            Ok(n) => {
                peer_commits += 1;
                report.peers_added += n;
            }
            Err(e) => {
                tracing::warn!(group = %g_hex, error = %e, "adding other members' devices failed");
                report.failed.push(g_hex.clone());
            }
        }
        // ADR-075 — devices their person cut off (signed), out of the chat.
        match remove_revoked_peer_devices(&http, &group, &me).await {
            Ok(0) => {}
            Ok(n) => {
                peer_commits += 1;
                report.peers_removed += n;
            }
            Err(e) => tracing::warn!(group = %g_hex, error = %e, "removing cut-off devices failed"),
        }
        // ADR-092 — a Commit came here that we did not take (garbage, or
        // one nobody honest takes): our own empty one makes the chat's epoch,
        // and its card, an honest member's again. Lost the race: someone
        // else's did it.
        if commit_log().needs_heal(&g_hex) {
            let made = sync_slot().lock().await.as_mut().ok_or("sync not initialised")?.self_update_pending(&group);
            match made {
                Ok(pending) => {
                    if let Err(e) = submit_pending_commit(&group, &pending).await {
                        tracing::info!(group = %g_hex, error = %e, "new keys after a refused Commit not sent");
                    }
                }
                Err(e) => tracing::warn!(group = %g_hex, error = %e, "new keys after a refused Commit not made"),
            }
        }
        // ADR-075 — the chat's card, for a member's new phone.
        upload_card(&http, &group, &g_hex).await;
    }
    report.joined = join_by_cards(&http, &absent, &my_device).await;
    Ok(report)
}

/// ADR-075 — chats whose card the server has from this device, by epoch
/// (a JSON map in settings), so each card goes up once per change. ADR-093
/// renamed it: the server dropped the old one-per-chat cards, so every
/// device leaves its own once more.
const CARDS_SENT_SETTING: &str = "group_cards_sent_v2";

/// ADR-075 — leave this chat's card on the server, once per epoch. Quiet
/// on failure (an older server has no cards; a stale one gets 409).
async fn upload_card(http: &sync::HttpApi, group: &[u8], g_hex: &str) {
    let mut sent: std::collections::HashMap<String, u64> = storage::setting_get(CARDS_SENT_SETTING)
        .ok()
        .flatten()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    let made = {
        let mut slot = sync_slot().lock().await;
        let Some(c) = slot.as_mut() else { return };
        let epoch = c.group_epoch(group).ok();
        if epoch.is_none() || sent.get(g_hex).copied() == epoch {
            return;
        }
        c.group_card(group).map(|card| (card, c.login_seed_bytes()))
    };
    let Ok(((epoch, card), seed)) = made else { return };
    match http.put_group_card(seed, group, epoch, &card).await {
        Ok(()) => {
            sent.insert(g_hex.to_string(), epoch);
            if let Ok(j) = serde_json::to_string(&sent) {
                let _ = storage::setting_set(CARDS_SENT_SETTING, &j);
            }
        }
        Err(e) => tracing::debug!(group = %g_hex, error = %e, "chat card not left"),
    }
}

/// ADR-100 — my own person's cards, newest epoch first.
fn my_cards_newest_first(mut cards: Vec<sync::card_choice::CardFromServer>, me: &[u8; 32]) -> Vec<Vec<u8>> {
    cards.retain(|c| c.identity == *me);
    cards.sort_by_key(|c| std::cmp::Reverse(c.epoch));
    cards.into_iter().map(|c| c.card).collect()
}

/// ADR-075 — enter chats this device has no state for (restored from a
/// backup, the old phone gone) by their cards: external commit, ordered by
/// the server like any Commit. A chat without a card waits for its members
/// to add this device (ADR-074). Each chat is tried at most every 30 min.
async fn join_by_cards(http: &sync::HttpApi, absent: &[(Vec<u8>, String)], my_device: &[u8]) -> u32 {
    static TRIED: OnceLock<std::sync::Mutex<std::collections::HashMap<String, i64>>> = OnceLock::new();
    let tried = TRIED.get_or_init(Default::default);
    let now = now_unix() as i64;
    let (seed, me) = {
        let slot = sync_slot().lock().await;
        match slot.as_ref() {
            Some(c) => (c.login_seed_bytes(), hex::decode(c.identity_pubkey_hex()).ok().and_then(|v| <[u8; 32]>::try_from(v).ok())),
            None => return 0,
        }
    };
    let Some(me) = me else { return 0 };
    let mut joined = 0;
    for (group, g_hex) in absent {
        if let Ok(mut t) = tried.lock() {
            if t.get(g_hex).is_some_and(|at| now - at < 30 * 60) {
                continue;
            }
            t.insert(g_hex.clone(), now);
        }
        // ADR-093 — every member's card; the one my person or most people
        // left first, the next if it doesn't open here.
        let cards = match http.get_group_cards(seed, group).await {
            // ADR-100 — only my own devices' cards can open a chat here.
            // Every one of them, newest epoch first: two devices of mine
            // leave cards that say the same, and only the one the OTHER
            // device signed opens here.
            Ok(cards) => my_cards_newest_first(cards, &me),
            Err(e) => {
                tracing::debug!(group = %g_hex, error = %e, "no card for this chat");
                continue;
            }
        };
        let mut made = None;
        for card in &cards {
            let mut slot = sync_slot().lock().await;
            let Some(c) = slot.as_mut() else { return joined };
            match c.join_by_card(group, card) {
                Ok(j) => {
                    made = Some(j);
                    break;
                }
                Err(e) => tracing::info!(group = %g_hex, error = %e, "chat card not usable"),
            }
        }
        let Some((_, pending)) = made else { continue };
        let (sent, code, message_id) = send_commit(group, &pending).await;
        if sent.is_err() || code != Some(0) {
            let mut slot = sync_slot().lock().await;
            if let Some(c) = slot.as_mut() {
                c.forget_group(group);
            }
            tracing::info!(group = %g_hex, ?code, "joining by the card refused; tried again later");
            continue;
        }
        let epoch = epoch_of(group).await;
        commit_log_update(|log| log.moved(g_hex, epoch, &message_id));
        if let Err(e) = http.announce_group(seed, group, epoch, &[my_device.to_vec()]).await {
            tracing::warn!(group = %g_hex, error = %e, "joined, but not announced");
        }
        if let Ok(mut t) = tried.lock() {
            t.remove(g_hex);
        }
        tracing::info!(group = %g_hex, "entered the chat by its card");
        upload_card(http, group, g_hex).await;
        replay_early_pushes(group).await;
        joined += 1;
    }
    joined
}

/// ADR-075 — leaves of other people's devices that they cut off (the
/// revocation signed by their identity key — checked here, not taken from
/// the server), out of [group] in one Commit. Never a person's last leaf:
/// their new device may still join by the card, and the members let it in
/// only while the person is in the chat. Returns how many went.
async fn remove_revoked_peer_devices(http: &sync::HttpApi, group: &[u8], me: &[u8; 32]) -> Result<u32, String> {
    let people: Vec<[u8; 32]> = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or("sync not initialised")?;
        c.group_member_identities(group)
            .map_err(|e| e.to_string())?
            .into_iter()
            .filter_map(|p| p.try_into().ok())
            .filter(|p| p != me)
            .collect()
    };
    let mut gone: Vec<Vec<u8>> = Vec::new();
    for person in people {
        let Some(listed) = peer_devices(http, &hex::encode(person)).await else { continue };
        let cut_off: Vec<Vec<u8>> = listed
            .iter()
            .filter(|d| d.revoked && sync::http_api::revocation_is_signed(http.host(), &person, &hex::decode(&d.device_pk_hex).unwrap_or_default(), d.revoke_proof_ts, &d.revoke_proof_hex))
            .filter_map(|d| hex::decode(&d.device_pk_hex).ok())
            .collect();
        if cut_off.is_empty() {
            continue;
        }
        let present = {
            let mut slot = sync_slot().lock().await;
            slot.as_mut().ok_or("sync not initialised")?.group_device_keys(group, &person).map_err(|e| e.to_string())?
        };
        let theirs_gone: Vec<Vec<u8>> = present.iter().filter(|k| cut_off.contains(k)).cloned().collect();
        if !theirs_gone.is_empty() && theirs_gone.len() < present.len() {
            gone.extend(theirs_gone);
        }
    }
    if gone.is_empty() {
        return Ok(0);
    }
    let pending = {
        let mut slot = sync_slot().lock().await;
        slot.as_mut().ok_or("sync not initialised")?.remove_devices_pending(group, &gone).map_err(|e| e.to_string())?
    };
    if !submit_pending_commit(group, &pending).await? {
        return Ok(0);
    }
    tracing::info!(group = %hex::encode(group), devices = gone.len(), "took other people's cut-off devices out");
    Ok(gone.len() as u32)
}

/// ADR-074 — one Commit adding the other members' devices that aren't in
/// [group] yet, one Welcome to each of those people's new devices. No
/// history: it is theirs (their backup, ADR-073, or their own devices).
/// Returns how many devices were added (0 — nothing to do or lost a race).
async fn add_peer_devices(
    http: &sync::HttpApi,
    group: &[u8],
    g_hex: &str,
    me: &[u8; 32],
    my_device: &[u8],
    no_packages: &mut Vec<[u8; 32]>,
) -> Result<u32, String> {
    let people: Vec<[u8; 32]> = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or("sync not initialised")?;
        c.group_member_identities(group)
            .map_err(|e| e.to_string())?
            .into_iter()
            .filter_map(|p| p.try_into().ok())
            .filter(|p| p != me)
            .collect()
    };
    let mut packages: Vec<([u8; 32], Vec<u8>)> = Vec::new();
    for person in people {
        if no_packages.contains(&person) {
            continue;
        }
        let p_hex = hex::encode(person);
        let Some(devices) = peer_addable_devices(http, &p_hex).await else { continue };
        let present = {
            let mut slot = sync_slot().lock().await;
            slot.as_mut().ok_or("sync not initialised")?.group_device_keys(group, &person).map_err(|e| e.to_string())?
        };
        let missing: Vec<Vec<u8>> = devices.into_iter().filter(|k| !present.contains(k)).collect();
        if missing.is_empty() {
            continue;
        }
        let seed = sync_slot().lock().await.as_ref().ok_or("sync not initialised")?.login_seed_bytes();
        match http.fetch_device_keypackages(seed, &p_hex, &missing).await {
            Ok(kps) => packages.extend(kps.into_iter().map(|(_, kp)| (person, kp))),
            Err(sync::HttpError::Empty(_)) => no_packages.push(person),
            Err(e) => tracing::warn!(error = %e, "another member's KeyPackages not fetched"),
        }
    }
    if packages.is_empty() {
        return Ok(0);
    }
    let (pending, added) = {
        let mut slot = sync_slot().lock().await;
        slot.as_mut().ok_or("sync not initialised")?.invite_devices_of_pending(group, &packages).map_err(|e| e.to_string())?
    };
    if !submit_pending_commit(group, &pending).await? {
        return Ok(0); // someone else added them first, or a race: next sync
    }
    let mut members = vec![my_device.to_vec()];
    members.extend(added.iter().map(|(_, k)| k.clone()));
    let seed = sync_slot().lock().await.as_ref().ok_or("sync not initialised")?.login_seed_bytes();
    http.announce_group(seed, group, epoch_of(group).await, &members).await.map_err(|e| e.to_string())?;
    if let Some(w) = &pending.welcome_bytes {
        let w64 = BASE64_STANDARD.encode(w);
        let mut owners: Vec<[u8; 32]> = added.iter().map(|(o, _)| *o).collect();
        owners.sort();
        owners.dedup();
        for owner in owners {
            let theirs: Vec<Vec<u8>> = added.iter().filter(|(o, _)| *o == owner).map(|(_, k)| k.clone()).collect();
            send_welcome_to(hex::encode(owner), g_hex.to_string(), w64.clone(), theirs).await?;
        }
    }
    tracing::info!(group = %g_hex, devices = added.len(), "added other members' new devices");
    Ok(added.len() as u32)
}

/// Messages handed to a newly added device, per chat.
const HISTORY_FOR_NEW_DEVICE: i64 = 200;

/// ADR-025 — a chat's recent messages (from this device's local DB) to
/// our own other devices: MLS messages in the chat, sealed ONLY to our
/// own delivery key (the same on all our devices), so no one else gets
/// them. Disappearing, deleted and system rows stay behind. A device
/// that already has messages in the chat ignores them (Dart).
async fn send_history(group: &[u8], chat_id: &str) -> Result<usize, String> {
    use sync::envelope::{encode_history, HistoryItem, MAX_HISTORY_ITEMS};
    let rows = storage::messages_list_for_chat(chat_id, Some(HISTORY_FOR_NEW_DEVICE)).map_err(|e| e.to_string())?;
    let (chat_name, is_group) = storage::chats_list()
        .ok()
        .and_then(|cs| cs.into_iter().find(|c| c.id == chat_id))
        .map(|c| (c.display_name, c.is_group))
        .unwrap_or_default();
    // ADR-055 — my "Saved messages": say so, even with no notes yet.
    let saved = storage::setting_get(SAVED_CHAT_SETTING).ok().flatten().as_deref() == Some(chat_id);
    let me = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_pubkey_hex()
    };
    let my_key = own_delivery_key().await?;
    let items: Vec<HistoryItem> = rows
        .into_iter()
        .filter(|m| !m.deleted && m.expire_at.is_none())
        .filter(|m| matches!(m.kind.as_str(), "text" | "photo" | "voice" | "document" | "video" | "sticker"))
        .filter_map(|m| {
            Some(HistoryItem {
                wire_id: m.wire_id?,
                ts: m.ts_unix,
                // ADR-049 — an older app rejects a bundle with a kind it
                // doesn't know; the media JSON still marks the sticker.
                kind: if m.kind == "sticker" { "photo".into() } else { m.kind },
                // ADR-070 — the formatting goes along (rich = not an old message).
                entities: m
                    .entities_json
                    .as_deref()
                    .and_then(|j| sync::envelope::entities_from_json(&m.body, j).ok())
                    .unwrap_or_default(),
                rich: m.entities_json.is_some(),
                text: m.body,
                media_json: m.media_json.unwrap_or_default(),
                sender: if m.is_mine { me.clone() } else { m.sender_id? },
            })
        })
        .collect();
    let mut sent = 0;
    let chunks: Vec<&[HistoryItem]> =
        if items.is_empty() && saved { vec![&[] as &[HistoryItem]] } else { items.chunks(MAX_HISTORY_ITEMS).collect() };
    for chunk in chunks {
        send_sealed_to_self(group, &encode_history(chunk.to_vec(), &chat_name, is_group, saved), &my_key).await?;
        sent += chunk.len();
    }
    Ok(sent)
}

/// This week's public delivery key for my own devices (the same on all of them).
pub(crate) async fn own_delivery_key() -> Result<Vec<u8>, String> {
    let slot = sync_slot().lock().await;
    let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
    let now = now_unix();
    let week = sync::sealed::week_of(now);
    // DEV-1 — generation 0: all my devices open it, whatever generation they know.
    Ok(c.own_devices_key(week).map_err(|e| e.to_string())?.public)
}

/// ADR-025 / ADR-064 — an MLS message in [group] sealed ONLY to my own
/// delivery key [my_key]: my other devices get it, nobody else does.
/// (ADR-071 seals a member's access key to that member's key this way.)
pub(crate) async fn send_sealed_to_self(group: &[u8], plaintext: &[u8], my_key: &[u8]) -> Result<(), String> {
    let deliveries = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let ct = c.encrypt(group, plaintext).map_err(|e| e.to_string())?;
        c.seal_for(group, &ct, &[my_key.to_vec()]).map_err(|e| e.to_string())?
    };
    let message_id = uuid::Uuid::now_v7().to_string();
    let frame = SealedPlan {
        base_url: String::new(),
        deliveries,
        access: Vec::new(),
        ttl_secs: 0,
        urgent: Vec::new(),
        previews: Vec::new(),
        drop_after_secs: 0,
    }
    .ws_frame(&message_id);
    let slot = net_slot().lock().await;
    slot.as_ref().ok_or("net not connected")?.send(frame).await.map_err(|e| e.to_string())?;
    Ok(())
}

/// ADR-025 — revoke one of the person's linked devices (signed by the
/// identity key), then remove it from `group_ids_hex` via device sync.
pub async fn devices_revoke(
    server_base_url: String,
    device_pk_hex: String,
    group_ids_hex: Vec<String>,
) -> Result<DeviceSyncReport, String> {
    let device = hex::decode(&device_pk_hex).map_err(|e| e.to_string())?;
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    sync::HttpApi::new(server_base_url.clone()).revoke_device(seed, &device).await.map_err(|e| e.to_string())?;
    // PAIR-1 — remembered here and on my other devices: the server's list can't bring it back.
    let _ = storage::devsync::device_revoked_set(&hex::encode(&device), true);
    Ok(report_after_revoke(sync_devices(server_base_url, group_ids_hex).await))
}

/// Encrypt + send: replaces `net_send_submit` for E2E flows. Encrypts
/// `plaintext` for `group_id_hex` via SyncClient, then forwards the
/// MLS ciphertext to the WS server.
/// (kind, text, media_json, reply_json, action_json) of a decrypted
/// app message — see [`NetPush`].
type PushParts = (String, String, Option<String>, Option<String>, Option<String>, u32);

#[cfg(test)]
fn decode_push(b: &[u8]) -> PushParts {
    decode_push_full(b).0
}

/// [`decode_push`] plus (ADR-070) the formatting of a text message or a
/// caption as `entities_json` (None: an older app's message). An edit
/// carries its own in `action_json` (`"entities"`), history items too.
fn decode_push_full(b: &[u8]) -> (PushParts, Option<String>) {
    let Ok(m) = sync::envelope::decode_message(b) else {
        return (("invalid".into(), String::new(), None, None, None, 0), None);
    };
    let entities = match m.decoded {
        sync::envelope::Decoded::Text(_) | sync::envelope::Decoded::Link { .. } | sync::envelope::Decoded::Media(_) => {
            m.entities.as_deref().map(sync::envelope::entities_to_json)
        }
        _ => None,
    };
    (push_parts(m), entities)
}

fn push_parts(m: sync::envelope::DecodedMessage) -> PushParts {
    use serde_json::json;
    use sync::envelope::Decoded as D;
    let rich = |v: &mut serde_json::Value, e: &Option<Vec<sync::envelope::TextEntity>>| {
        if let Some(e) = e {
            v["entities"] = serde_json::from_str(&sync::envelope::entities_to_json(e)).unwrap_or_default();
        }
    };
    let reply = m.reply_to.as_ref().map(sync::envelope::reply_to_json);
    let exp = m.expire_secs;
    let action = |kind: &str, v: serde_json::Value| (kind.to_string(), String::new(), None, None, Some(v.to_string()), 0);
    match m.decoded {
        D::Text(t) => ("text".into(), t, None, reply, None, exp),
        D::Link { text, preview } => ("text".into(), text, Some(sync::envelope::link_to_json(&preview)), reply, None, exp),
        D::Media(md) => (
            sync::envelope::message_kind(&md).to_string(),
            md.caption.clone(),
            Some(sync::envelope::media_to_json(&md)),
            reply,
            None,
            exp,
        ),
        D::Reaction { target, emoji } => action("reaction", json!({"target": target, "emoji": emoji})),
        D::Edit { target, text } => {
            let mut v = json!({"target": target, "text": text});
            rich(&mut v, &m.entities);
            action("edit", v)
        }
        D::Delete { target } => action("delete", json!({"target": target})),
        D::Receipt { read, ids } => action("receipt", json!({"read": read, "ids": ids})),
        D::Typing { active } => action("typing", json!({"active": active})),
        D::Timer { secs } => action("timer", json!({"secs": secs})),
        // Tech-debt 2.22 — the sender's display name; a pin for the chat.
        D::Profile { name, avatar, bio } => {
            action("profile", json!({"name": name, "avatar": BASE64_STANDARD.encode(&avatar), "bio": bio}))
        }
        D::Pin { target, pinned } => action("pin", json!({"target": target, "pinned": pinned})),
        D::Screenshot { recording: false } => action("screenshot", json!({})),
        D::Screenshot { recording: true } => action("screenshot", json!({"recording": true})),
        D::Presence { online, hidden } => action("presence", json!({"online": online, "hidden": hidden})),
        // ADR-034 — a group's name.
        D::GroupName { name } => action("group_name", json!({"name": name})),
        D::Leave => action("leave", json!({})),
        D::MembersRemoved { identities } => {
            action("removed", json!({"who": identities.iter().map(hex::encode).collect::<Vec<_>>()}))
        }
        // Handled in Rust (`remember_access_key`); Dart drops this kind.
        D::Access { .. } => ("access".into(), String::new(), None, None, None, 0),
        // ADR-025 — Dart stores these if the chat is still empty here.
        D::History { mut items, .. } => (
            "history".into(),
            String::new(),
            None,
            None,
            Some({
                // ADR-049 — stickers travel as "photo" (older apps).
                for i in &mut items {
                    i.kind = sync::envelope::stored_kind(&i.kind, &i.media_json);
                }
                let list: Vec<serde_json::Value> = items
                    .iter()
                    .map(|i| {
                        let mut v = serde_json::to_value(i).unwrap_or_default();
                        rich(&mut v, &i.rich.then(|| i.entities.clone()));
                        v
                    })
                    .collect();
                serde_json::to_string(&list).unwrap_or_default()
            }),
            0,
        ),
        // ADR-064 — handled in Rust (`push_event`), which fills in what changed.
        D::Transfer(_) => ("transfer".into(), String::new(), None, None, None, 0),
        D::DeviceSync { .. } => ("device_sync".into(), String::new(), None, None, None, 0),
        D::Unsupported { .. } => ("unsupported".into(), String::new(), None, None, None, 0),
    }
}

/// What a cancelled send fails with (the app drops it quietly).
pub(crate) const SEND_CANCELLED: &str = "send cancelled";

/// Sends the person cancelled ("Cancel sending" — owner, 2026-10-18): the
/// message id waits here and the send stops at its next step — before the
/// upload, and before the MLS encrypt + submit, after which it may reach
/// the server.
fn cancelled_sends() -> &'static std::sync::Mutex<std::collections::HashSet<String>> {
    static C: OnceLock<std::sync::Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    C.get_or_init(Default::default)
}

/// Stop the send of [message_id] if it hasn't reached the network yet.
#[flutter_rust_bridge::frb(sync)]
pub fn net_cancel_send(message_id: String) {
    if let Ok(mut s) = cancelled_sends().lock() {
        // Ids of sends that had already finished are never taken back out.
        if s.len() >= 256 {
            s.clear();
        }
        s.insert(message_id);
    }
}

/// True (once) if [message_id] was cancelled.
pub(crate) fn take_cancelled(message_id: &str) -> bool {
    cancelled_sends().lock().map(|mut s| s.remove(message_id)).unwrap_or(false)
}

pub(crate) async fn net_send_encrypted(
    group_id_hex: String,
    plaintext: Vec<u8>,
    message_id: String,
) -> Result<(), String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    // ADR-025 — if device sync has a Commit of ours in flight for this
    // chat, wait (≤ 10 s) for the server's verdict before encrypting, so
    // the message is in the epoch everyone ends up in.
    for _ in 0..100 {
        let pending = {
            let mut slot = sync_slot().lock().await;
            slot.as_mut().map(|c| c.has_pending_commit(&group_id).unwrap_or(false)).unwrap_or(false)
        };
        if !pending {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    // The last moment a cancel can stop it.
    if take_cancelled(&message_id) {
        return Err(SEND_CANCELLED.to_string());
    }
    // Encrypt under SyncClient.
    let ciphertext = {
        let mut slot = sync_slot().lock().await;
        let client = slot
            .as_mut()
            .ok_or_else(|| "sync not initialised".to_string())?;
        client.encrypt(&group_id, &plaintext).map_err(|e| e.to_string())?
    };
    // ADR-023: sealed when every recipient has a delivery key, otherwise
    // the ordinary per-group Submit. Tech-debt 2.2: when we also hold
    // everyone's access key, the envelopes go over an unauthenticated
    // HTTP request — the server doesn't learn which account sent them.
    // Overnight item 8 — only a real message wakes offline phones.
    let urgent = sync::envelope::wakes_recipient(&plaintext);
    let preview = if urgent { preview_of(&plaintext) } else { None };
    // Tech-debt 2.53 — "online" / "typing": not worth queueing for long.
    let drop_after_secs = sync::envelope::drop_after_secs(&plaintext);
    let frame = match sealed_plan(&group_id, &ciphertext, urgent, preview, drop_after_secs).await {
        Some(plan) => {
            // ADR-071 — per recipient: with their access key, without
            // authentication; without one, a message request over the WS
            // (it never wakes their phone if they hand out per-contact keys).
            let keyed: Vec<usize> = (0..plan.deliveries.len()).filter(|i| matches!(plan.access.get(*i), Some(Some(_)))).collect();
            let mut frame = plan.ws_frame(&message_id);
            if !keyed.is_empty() {
                let items: Vec<([u8; 16], Vec<u8>, Vec<u8>)> = keyed
                    .iter()
                    .filter_map(|i| Some((plan.deliveries[*i].0, plan.deliveries[*i].1.clone(), plan.access[*i].clone()?)))
                    .collect();
                let urgent: Vec<bool> = keyed.iter().map(|i| plan.urgent.get(*i).copied().unwrap_or(false)).collect();
                let previews: Vec<Option<Vec<u8>>> = keyed.iter().map(|i| plan.previews.get(*i).cloned().flatten()).collect();
                match sync::HttpApi::new(plan.base_url.clone())
                    .submit_sealed_anonymous(&message_id, &items, plan.ttl_secs, &urgent, &previews, plan.drop_after_secs)
                    .await
                {
                    Ok((_, 0)) if keyed.len() == plan.deliveries.len() => {
                        push_local_ack(&message_id);
                        return Ok(());
                    }
                    // The rest go over the WS; its Ack marks the message sent.
                    Ok((_, 0)) => frame = plan.ws_frame_for(&message_id, |i| !keyed.contains(&i)),
                    // Someone refused (rotated key, no access hash yet) or
                    // no network: the authenticated sealed route for all;
                    // retries of accepted deliveries are absorbed.
                    Ok((_, refused)) => tracing::debug!(refused, "anonymous sealed send refused; falling back"),
                    Err(e) => tracing::debug!(error = %e, "anonymous sealed send failed; falling back"),
                }
            }
            frame
        }
        None => net::proto::WsFrame {
            // The ack echoes frame_id: using the message's wire id lets
            // the app mark that message "sent" (ADR-019).
            frame_id: message_id.clone(),
            body: Some(net::proto::ws_frame::Body::Submit(net::proto::Submit {
                // ADR-087 (amended) — a member without a fresh delivery key
                // (a phone asleep for weeks) sends us here: my contacts'
                // keys keep their phones woken.
                access_keys: if urgent { members_access_keys(&group_id).await } else { Vec::new() },
                group_id,
                ciphertext,
                message_id,
                sealed_sender: false,
                is_commit: false,
                commit_epoch: 0,
                urgent,
                refused_commit_ids: Vec::new(),
                parent_commit_id: String::new(),
            })),
        },
    };
    let net_slot_guard = net_slot().lock().await;
    let client = net_slot_guard
        .as_ref()
        .ok_or_else(|| "net not connected".to_string())?;
    client.send(frame).await.map_err(|e| e.to_string())
}

/// Upload progress per outgoing media message (wire message id) →
/// (bytes sent, bytes total). Entry exists from the start of the send
/// until it finishes (either way); total == 0 means "still preparing /
/// encrypting".
fn upload_progress() -> &'static std::sync::Mutex<std::collections::HashMap<String, (u64, u64)>> {
    static P: OnceLock<std::sync::Mutex<std::collections::HashMap<String, (u64, u64)>>> = OnceLock::new();
    P.get_or_init(Default::default)
}

/// Removes the progress entry when a send ends (success, error, panic).
pub(crate) struct ProgressGuard(String);
impl ProgressGuard {
    pub(crate) fn start(id: &str) -> Self {
        if let Ok(mut m) = upload_progress().lock() {
            m.entry(id.to_string()).or_insert((0, 0));
        }
        Self(id.to_string())
    }
}
impl Drop for ProgressGuard {
    fn drop(&mut self) {
        if let Ok(mut m) = upload_progress().lock() {
            m.remove(&self.0);
        }
    }
}

/// Upload fraction 0.0-1.0 for an in-flight media send, 0.0 while it's
/// still being prepared/encrypted, -1.0 when no send with this id is
/// running. Cheap; meant to be polled from the UI.
#[flutter_rust_bridge::frb(sync)]
pub fn media_upload_progress(message_id: String) -> f64 {
    match upload_progress().lock().ok().and_then(|m| m.get(&message_id).copied()) {
        None => -1.0,
        Some((_, 0)) => 0.0,
        Some((sent, total)) => (sent as f64 / total as f64).clamp(0.0, 1.0),
    }
}

/// Display data of a stored link preview.
pub struct LinkPreviewInfo {
    pub url: String,
    pub domain: String,
    pub title: String,
    pub description: String,
    pub has_image: bool,
}

pub fn link_preview_info(json: String) -> Result<LinkPreviewInfo, String> {
    let p = sync::envelope::link_from_json(&json).map_err(|e| e.to_string())?;
    let domain = reqwest_domain(&p.url);
    Ok(LinkPreviewInfo {
        domain,
        has_image: p.image.is_some(),
        url: p.url,
        title: p.title,
        description: p.description,
    })
}

fn reqwest_domain(url: &str) -> String {
    url.strip_prefix("https://")
        .unwrap_or(url)
        .split(['/', '?', '#'])
        .next()
        .unwrap_or("")
        .trim_start_matches("www.")
        .to_string()
}

/// Download + decrypt a link preview's image (RAM only).
pub async fn link_preview_image(server_base_url: String, json: String) -> Result<Vec<u8>, String> {
    let p = sync::envelope::link_from_json(&json).map_err(|e| e.to_string())?;
    let r = p.image.ok_or_else(|| "no image".to_string())?;
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref()
            .ok_or_else(|| "sync not initialised".to_string())?
            .identity_seed_bytes()
    };
    let http = sync::HttpApi::new(server_base_url);
    let img = sync::media::fetch(&http, seed, &r).await.map_err(|e| e.to_string())?;
    // A peer's picture: re-encoded to a small JPEG, a huge side refused from the header.
    sync::photo::prepare_avatar(&img).map_err(|e| e.to_string())
}

/// Attach a media/link JSON to an already stored message.
pub fn storage_message_set_media(id: String, media_json: String) -> Result<(), String> {
    storage::message_set_media_json(&id, &media_json).map_err(|e| e.to_string())
}

/// Persisted setting (encrypted local DB). None when never set.
pub fn storage_setting_get(key: String) -> Result<Option<String>, String> {
    storage::setting_get(&key).map_err(|e| e.to_string())
}

pub fn storage_setting_set(key: String, value: String) -> Result<(), String> {
    storage::setting_set(&key, &value).map_err(|e| e.to_string())
}

/// Display metadata of a media message (no keys).
pub struct MediaInfo {
    /// "photo" | "voice" | "document"
    pub kind: String,
    pub mime_type: String,
    pub file_name: String,
    pub blurhash: String,
    pub width: u32,
    pub height: u32,
    pub duration_ms: u32,
    /// Voice: amplitudes 0-255.
    pub waveform: Vec<u8>,
    pub caption: String,
    /// Plaintext size of the file, for "2.4 MB" labels.
    pub size_bytes: u64,
    pub has_thumbnail: bool,
    /// A round video message (ADR-048) — `kind` stays "video".
    pub round: bool,
}

/// Encrypt + upload a media file (and optional ≤32 KB thumbnail), then
/// send the envelope over MLS. Returns the media JSON to store with the
/// local message row (`storage_message_append_media`).
///
/// `kind`: "photo" | "voice" | "document". All bytes are plaintext here
/// and are encrypted in Rust before any network I/O.
#[allow(clippy::too_many_arguments)]
pub async fn net_send_media(
    server_base_url: String,
    group_id_hex: String,
    message_id: String,
    kind: String,
    data: Vec<u8>,
    thumbnail: Option<Vec<u8>>,
    mime_type: String,
    file_name: String,
    blurhash: String,
    width: u32,
    height: u32,
    duration_ms: u32,
    waveform: Vec<u8>,
    caption: String,
    reply_json: Option<String>,
    album_id: String,
    expire_secs: u32,
    caption_entities_json: Option<String>,
) -> Result<String, String> {
    send_media(
        server_base_url,
        group_id_hex,
        message_id,
        kind,
        sync::media::MediaDraft {
            kind: None,
            data,
            thumbnail,
            mime_type,
            file_name,
            blurhash,
            width,
            height,
            duration_ms,
            waveform,
            caption,
        },
        reply_json,
        album_id,
        false,
        expire_secs,
        caption_entities_json,
    )
    .await
}

/// [net_send_media] plus the round-video flag (ADR-048), which only
/// [net_send_video] sets.
#[allow(clippy::too_many_arguments)]
async fn send_media(
    server_base_url: String,
    group_id_hex: String,
    message_id: String,
    kind: String,
    draft: sync::media::MediaDraft,
    reply_json: Option<String>,
    album_id: String,
    round: bool,
    expire_secs: u32,
    caption_entities_json: Option<String>,
) -> Result<String, String> {
    let kind = sync::envelope::kind_from_name(&kind).ok_or_else(|| format!("unknown media kind {kind}"))?;
    let caption_entities = parse_entities(&draft.caption, caption_entities_json.as_deref())?;
    if round && kind != sync::envelope::MediaKind::Video {
        return Err("only a video can be round".to_string());
    }
    let reply = parse_reply(reply_json)?;
    let _progress = ProgressGuard::start(&message_id);
    if take_cancelled(&message_id) {
        return Err(SEND_CANCELLED.to_string()); // cancelled while it was being prepared
    }
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref()
            .ok_or_else(|| "sync not initialised".to_string())?
            .identity_seed_bytes()
    };
    let http = sync::HttpApi::new(server_base_url);
    let progress_id = message_id.clone();
    let on_progress = move |sent: u64, total: u64| {
        if let Ok(mut m) = upload_progress().lock() {
            m.insert(progress_id.clone(), (sent, total));
        }
    };
    let body = sync::media::upload_with_progress(
        &http,
        seed,
        sync::media::MediaDraft { kind: Some(kind), ..draft },
        &on_progress,
    )
    .await
    .map_err(|e| e.to_string())?;
    let mut body = body;
    body.album_id = album_id;
    body.round = round;
    if let Some(e) = caption_entities {
        body.caption_entities = e;
        body.caption_rich = true;
    }
    let json = sync::envelope::media_to_json(&body);
    net_send_encrypted(
        group_id_hex,
        sync::envelope::encode_media_expiring(body, reply, expire_secs),
        message_id,
    )
    .await?;
    Ok(json)
}

pub(crate) fn parse_reply(reply_json: Option<String>) -> Result<Option<sync::envelope::ReplyRef>, String> {
    reply_json
        .map(|j| sync::envelope::reply_from_json(&j).map_err(|e| e.to_string()))
        .transpose()
}

/// Send a text message (ADR-017/018/019): optional reply quote, and
/// when `preview_base_url` is set (user enabled link previews) a
/// sender-side link preview. Returns the preview JSON to store, if any.
///
/// ADR-070 — `entities_json`: the text's formatting (`[]` = none); None
/// sends it the way 0.6.0 did (the receiver may read `*stars*` as bold).
pub async fn net_send_message(
    group_id_hex: String,
    message_id: String,
    text: String,
    reply_json: Option<String>,
    preview_base_url: Option<String>,
    expire_secs: u32,
    entities_json: Option<String>,
) -> Result<Option<String>, String> {
    let reply = parse_reply(reply_json)?;
    let entities = parse_entities(&text, entities_json.as_deref())?;
    let preview = match (preview_base_url, sync::link_preview::first_https_url(&text)) {
        (Some(base), Some(url)) => {
            let seed = {
                let slot = sync_slot().lock().await;
                slot.as_ref()
                    .ok_or_else(|| "sync not initialised".to_string())?
                    .identity_seed_bytes()
            };
            sync::link_preview::build(&sync::HttpApi::new(base), seed, &url).await.ok()
        }
        _ => None,
    };
    let json = preview.as_ref().map(sync::envelope::link_to_json);
    let bytes = match entities {
        Some(e) => sync::envelope::encode_text_rich(&text, e, preview, reply, expire_secs),
        None => sync::envelope::encode_text_expiring(&text, preview, reply, expire_secs),
    };
    net_send_encrypted(group_id_hex, bytes, message_id).await?;
    Ok(json)
}

/// Status 211 (tech-debt 2.59) — send an already uploaded media message or
/// sticker again: [media_json] is what its send returned (blob, key,
/// caption), so nothing is uploaded twice; the same [message_id], so a copy
/// that did arrive is dropped by the receiver.
pub async fn net_resend_media(
    group_id_hex: String,
    message_id: String,
    media_json: String,
    reply_json: Option<String>,
    expire_secs: u32,
) -> Result<(), String> {
    let body = sync::envelope::media_from_json(&media_json).map_err(|e| e.to_string())?;
    let reply = parse_reply(reply_json)?;
    net_send_encrypted(group_id_hex, sync::envelope::encode_media_expiring(body, reply, expire_secs), message_id).await
}

/// ADR-070 — the app's `entities_json` for [text], cleaned (None = none given).
pub(crate) fn parse_entities(text: &str, json: Option<&str>) -> Result<Option<Vec<sync::envelope::TextEntity>>, String> {
    json.map(|j| sync::envelope::entities_from_json(text, j).map_err(|e| e.to_string())).transpose()
}

/// Send a message action (ADR-019) — `action_json` is one of
/// `{"t":"reaction","target","emoji"}`, `{"t":"edit","target","text"}`,
/// `{"t":"delete","target"}`, `{"t":"receipt","read":bool,"ids":[…]}`,
/// `{"t":"typing","active":bool}`. `message_id` is a fresh wire UUID.
pub async fn net_send_action(group_id_hex: String, message_id: String, action_json: String) -> Result<(), String> {
    let bytes = encode_action(&action_json)?;
    net_send_encrypted(group_id_hex, bytes, message_id).await
}

/// Envelope bytes for an action JSON; rejects anything the receiver
/// would reject.
fn encode_action(action_json: &str) -> Result<Vec<u8>, String> {
    let v: serde_json::Value = serde_json::from_str(action_json).map_err(|e| e.to_string())?;
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or_default().to_string();
    let bytes = match v.get("t").and_then(|t| t.as_str()) {
        Some("reaction") => sync::envelope::encode_reaction(&s("target"), &s("emoji")),
        // ADR-070 — `"entities": [...]` (even empty) = the formatted form.
        Some("edit") => match v.get("entities") {
            Some(e) => {
                let text = s("text");
                let entities = sync::envelope::entities_from_json(&text, &e.to_string()).map_err(|e| e.to_string())?;
                sync::envelope::encode_edit_rich(&s("target"), &text, entities)
            }
            None => sync::envelope::encode_edit(&s("target"), &s("text")),
        },
        Some("delete") => sync::envelope::encode_delete(&s("target")),
        Some("receipt") => {
            let ids: Vec<String> = v
                .get("ids")
                .and_then(|x| x.as_array())
                .map(|a| a.iter().filter_map(|i| i.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            sync::envelope::encode_receipt(v.get("read").and_then(|x| x.as_bool()).unwrap_or(false), &ids)
        }
        Some("typing") => sync::envelope::encode_typing(v.get("active").and_then(|x| x.as_bool()).unwrap_or(false)),
        Some("timer") => sync::envelope::encode_timer(v.get("secs").and_then(|x| x.as_u64()).unwrap_or(0).min(u32::MAX as u64) as u32),
        Some("profile") => {
            let avatar = match v.get("avatar").and_then(|x| x.as_str()).filter(|a| !a.is_empty()) {
                Some(b64) => BASE64_STANDARD.decode(b64).map_err(|_| "bad avatar")?,
                None => Vec::new(),
            };
            if avatar.len() > sync::media::MAX_THUMBNAIL_BYTES {
                return Err("avatar too large".into());
            }
            sync::envelope::encode_profile(
                &sync::envelope::clean_profile_name(&s("name")).ok_or("empty or too long name")?,
                &avatar,
                &s("bio"),
            )
        }
        Some("leave") => sync::envelope::encode_leave(),
        Some("removed") => {
            let ids: Vec<[u8; 32]> = v
                .get("who")
                .and_then(|x| x.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str())
                        .filter_map(|h| hex::decode(h).ok())
                        .filter_map(|b| <[u8; 32]>::try_from(b.as_slice()).ok())
                        .collect()
                })
                .unwrap_or_default();
            if ids.is_empty() {
                return Err("removed: nobody named".into());
            }
            sync::envelope::encode_members_removed(&ids)
        }
        Some("screenshot") => {
            sync::envelope::encode_screenshot(v.get("recording").and_then(|x| x.as_bool()).unwrap_or(false))
        }
        Some("presence") => sync::envelope::encode_presence(
            v.get("online").and_then(|x| x.as_bool()).unwrap_or(false),
            v.get("hidden").and_then(|x| x.as_bool()).unwrap_or(false),
        ),
        Some("pin") => sync::envelope::encode_pin(&s("target"), v.get("pinned").and_then(|x| x.as_bool()).unwrap_or(true)),
        Some("group_name") => sync::envelope::encode_group_name(
            &sync::envelope::clean_profile_name(&s("name")).ok_or("empty or too long group name")?,
        ),
        other => return Err(format!("unknown action {other:?}")),
    };
    sync::envelope::decode(&bytes).map_err(|e| e.to_string())?;
    Ok(bytes)
}

/// Send a photo: decode → apply EXIF orientation → re-encode JPEG
/// (strips EXIF/GPS) → ≤2048 px + ≤32 KB thumbnail + BlurHash →
/// encrypt + upload → MLS envelope. `data` is the picked file (JPEG or
/// PNG). Returns the media JSON for `storage_message_append_media`.
pub async fn net_send_photo(
    server_base_url: String,
    group_id_hex: String,
    message_id: String,
    data: Vec<u8>,
    caption: String,
    reply_json: Option<String>,
    album_id: String,
    expire_secs: u32,
    caption_entities_json: Option<String>,
) -> Result<String, String> {
    // "Preparing" (0 %) shows while the photo is re-encoded.
    let _progress = ProgressGuard::start(&message_id);
    let p = sync::photo::prepare(&data).map_err(|e| e.to_string())?;
    drop(data);
    net_send_media(
        server_base_url,
        group_id_hex,
        message_id,
        "photo".to_string(),
        p.jpeg,
        Some(p.thumbnail),
        "image/jpeg".to_string(),
        String::new(),
        p.blurhash,
        p.width,
        p.height,
        0,
        Vec::new(),
        caption,
        reply_json,
        album_id,
        expire_secs,
        caption_entities_json,
    )
    .await
}

/// Send a video (tech-debt 2.24). `poster_jpeg` is a frame the platform
/// grabbed (optional): re-encoded here into the encrypted thumbnail and a
/// BlurHash, so the bubble shows a picture before anything is downloaded.
/// A bad frame just means no poster. Width/height 0 → taken from the frame.
/// `round`: a round video message (ADR-048) — square, ≤60 s, no caption.
pub async fn net_send_video(
    server_base_url: String,
    group_id_hex: String,
    message_id: String,
    data: Vec<u8>,
    mime_type: String,
    duration_ms: u32,
    width: u32,
    height: u32,
    poster_jpeg: Option<Vec<u8>>,
    caption: String,
    reply_json: Option<String>,
    round: bool,
    expire_secs: u32,
    caption_entities_json: Option<String>,
) -> Result<String, String> {
    let poster = poster_jpeg.and_then(|f| sync::photo::video_poster(&f).ok());
    let (thumbnail, blurhash, w, h) = match poster {
        Some(p) => (
            Some(p.thumbnail),
            p.blurhash,
            if width == 0 { p.width } else { width },
            if height == 0 { p.height } else { height },
        ),
        None => (None, String::new(), width, height),
    };
    send_media(
        server_base_url,
        group_id_hex,
        message_id,
        "video".to_string(),
        sync::media::MediaDraft {
            kind: None,
            data,
            thumbnail,
            mime_type,
            file_name: String::new(),
            blurhash,
            width: w,
            height: h,
            duration_ms,
            waveform: Vec::new(),
            // A round video has no caption (as in Telegram).
            caption: if round { String::new() } else { caption },
        },
        reply_json,
        String::new(),
        round,
        expire_secs,
        caption_entities_json,
    )
    .await
}

/// Render a BlurHash as a tiny PNG (≤64 px) for an instant placeholder.
pub fn media_blurhash_png(blurhash: String, width: u32, height: u32) -> Result<Vec<u8>, String> {
    sync::photo::blurhash_png(&blurhash, width, height).map_err(|e| e.to_string())
}

/// Download + verify + decrypt a media blob. `thumbnail = true` fetches
/// the preview instead of the full file. Plaintext is returned to Dart
/// for in-memory use only (spec §8.6 — never write it to disk).
pub async fn media_fetch(
    server_base_url: String,
    media_json: String,
    thumbnail: bool,
) -> Result<Vec<u8>, String> {
    let body = sync::envelope::media_from_json(&media_json).map_err(|e| e.to_string())?;
    let r = if thumbnail {
        body.thumbnail.ok_or_else(|| "no thumbnail".to_string())?
    } else {
        body.file.ok_or_else(|| "no file".to_string())?
    };
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref()
            .ok_or_else(|| "sync not initialised".to_string())?
            .identity_seed_bytes()
    };
    let http = sync::HttpApi::new(server_base_url);
    sync::media::fetch(&http, seed, &r).await.map_err(|e| e.to_string())
}

/// Parse stored media JSON into display metadata.
pub fn media_info(media_json: String) -> Result<MediaInfo, String> {
    let m = sync::envelope::media_from_json(&media_json).map_err(|e| e.to_string())?;
    Ok(MediaInfo {
        kind: sync::envelope::message_kind(&m).to_string(),
        size_bytes: m.file.as_ref().map(|f| f.plain_size).unwrap_or(0),
        has_thumbnail: m.thumbnail.is_some(),
        round: m.round,
        mime_type: m.mime_type,
        file_name: m.file_name,
        blurhash: m.blurhash,
        width: m.width,
        height: m.height,
        duration_ms: m.duration_ms,
        waveform: m.waveform,
        caption: m.caption,
    })
}

/// Pull the next event from the connected client. Returns None when
/// the client has been shut down. Caller loops this from a Dart
/// isolate; each event drives Riverpod invalidation.
///
/// WU C2: Push frames are decrypted via SyncClient before being
/// surfaced — `NetPush.ciphertext` now contains the plaintext app
/// message. For non-MLS-content frames (control flows, unknown groups)
/// the raw bytes are surfaced as-is with `decrypted: false` flag.
pub async fn net_next_event() -> Option<NetEvent> {
    let slot_guard = net_slot().lock().await;
    let client_clone = slot_guard.as_ref().cloned();
    drop(slot_guard);

    let client = client_clone?;
    // Our own events (e.g. the Ack of an anonymous send) interleave with
    // the server's; `recv` on both sides is an mpsc receive (cancel-safe).
    let raw = {
        let mut local = local_events().1.lock().await;
        tokio::select! {
            biased;
            Some(ev) = local.recv() => return Some(ev),
            r = client.recv() => r?,
        }
    };
    let event = match raw {
        net::Event::Connected => empty_net_event("connected"),
        net::Event::Disconnected { reason } => NetEvent {
            disconnected_reason: Some(reason),
            ..empty_net_event("disconnected")
        },
        net::Event::Frame(f) => match f.body {
            Some(net::proto::ws_frame::Body::Push(p)) => {
                // Consumed from here on (decrypting advances MLS state; a
                // second copy couldn't be opened anyway).
                if p.sequence > 0 {
                    // Owner, 2026-10-20: after a reconnect the server's
                    // backlog and the Resume replay can both carry the same
                    // delivery; the copy failed to decrypt (a used MLS key)
                    // and showed as "<binary 574B>". Seen once → skip.
                    if !first_delivery(p.sequence) {
                        return Some(empty_net_event("duplicate"));
                    }
                    note_consumed(p.sequence);
                }
                push_event(p).await
            }
            Some(net::proto::ws_frame::Body::Ack(a)) => NetEvent {
                ack: Some({
                    // ADR-025 — a Rust flow may be waiting for this Ack.
                    if let Some(tx) = ack_waiters().lock().ok().and_then(|mut w| w.remove(&a.acked_frame_id)) {
                        let _ = tx.send(a.error_code);
                    } else if let Some(message_id) = a.acked_frame_id.strip_prefix("commit-") {
                        late_commit_ack(message_id, a.error_code).await;
                    }
                    NetAck {
                    acked_frame_id: a.acked_frame_id,
                    error_code: a.error_code,
                    error_message: a.error_message,
                    }
                }),
                ..empty_net_event("ack")
            },
            Some(net::proto::ws_frame::Body::Welcome(w)) => NetEvent {
                welcome: Some(NetWelcome {
                    inviter_identity_pubkey_hex: String::new(),
                    group_id_hex: hex::encode(&w.group_id),
                    welcome_b64: BASE64_STANDARD.encode(&w.welcome_bytes),
                    sent_at_unix: w.sent_at,
                }),
                ..empty_net_event("welcome")
            },
            // CD3 — call signaling forwarded from server.
            Some(net::proto::ws_frame::Body::CallInvite(ci)) => {
                // kind: proto3 enum decoded as i32. Reverse mapping:
                //   1 = AUDIO, 2 = VIDEO. Unknown → "unknown" string.
                let kind_str = match ci.kind {
                    1 => "audio",
                    2 => "video",
                    _ => "unknown",
                }
                .to_string();
                let caller = signed_caller(&ci).await;
                NetEvent {
                    call_invite: Some(NetCallInvite {
                        call_id: ci.call_id,
                        group_id_hex: hex::encode(&ci.group_id),
                        kind: kind_str,
                        livekit_room: ci.livekit_room,
                        ttl_secs: ci.ttl_secs,
                        caller_identity_hex: caller,
                    }),
                    ..empty_net_event("call_invite")
                }
            }
            Some(net::proto::ws_frame::Body::CallAccept(ca)) => NetEvent {
                call_accept: Some(NetCallAccept {
                    call_id: ca.call_id,
                    accept: ca.accept,
                }),
                ..empty_net_event("call_accept")
            },
            Some(net::proto::ws_frame::Body::CallEnd(ce)) => NetEvent {
                call_end: Some(NetCallEnd {
                    call_id: ce.call_id,
                    reason: ce.reason,
                }),
                ..empty_net_event("call_end")
            },
            Some(net::proto::ws_frame::Body::CallRing(cr)) => NetEvent {
                call_ring: Some(NetCallRing { call_id: cr.call_id, delivered: cr.delivered }),
                ..empty_net_event("call_ring")
            },
            _ => empty_net_event("other"),
        },
    };
    Some(event)
}

/// A frame for a group this phone hasn't joined yet — the Welcome that
/// adds it is still on the way (a push can overtake it). Before 2026-10-16
/// such frames were dropped after being counted as received, so the first
/// thing a new member got — the group's name — could be lost for good
/// (tech-debt 2.34). Held in memory, at most [EARLY_MAX] and for
/// [EARLY_TTL]; [replay_early_pushes] opens them after a join.
struct EarlyPush {
    at: std::time::Instant,
    push: net::proto::Push,
}

const EARLY_MAX: usize = 256;
const EARLY_TTL: std::time::Duration = std::time::Duration::from_secs(600);

fn early_pushes() -> &'static std::sync::Mutex<Vec<EarlyPush>> {
    static Q: OnceLock<std::sync::Mutex<Vec<EarlyPush>>> = OnceLock::new();
    Q.get_or_init(|| std::sync::Mutex::new(Vec::new()))
}

fn hold_early_push(push: net::proto::Push) {
    let Ok(mut q) = early_pushes().lock() else { return };
    let now = std::time::Instant::now();
    q.retain(|e| now.duration_since(e.at) < EARLY_TTL);
    if q.len() >= EARLY_MAX {
        q.remove(0);
    }
    q.push(EarlyPush { at: now, push });
}

/// Frames held for [group_id] (and sealed ones, whose group shows only
/// when opened), oldest first; taken out of the queue.
fn take_early_pushes(group_id: &[u8]) -> Vec<net::proto::Push> {
    let Ok(mut q) = early_pushes().lock() else { return Vec::new() };
    let now = std::time::Instant::now();
    q.retain(|e| now.duration_since(e.at) < EARLY_TTL);
    let (take, keep): (Vec<_>, Vec<_>) = std::mem::take(&mut *q)
        .into_iter()
        .partition(|e| e.push.group_id == group_id || !e.push.sealed_key_id.is_empty());
    *q = keep;
    take.into_iter().map(|e| e.push).collect()
}

/// After joining [group_id]: open the frames held for it and hand them to
/// Dart as pushes, in arrival order. Ones still for an unknown group are
/// held again.
async fn replay_early_pushes(group_id: &[u8]) {
    for p in take_early_pushes(group_id) {
        let ev = push_event(p).await;
        if ev.kind == "push" {
            let _ = local_events().0.send(ev);
        }
    }
}

/// Decrypt one pushed frame and decode it for Dart.
async fn push_event(p: net::proto::Push) -> NetEvent {
    // Attempt MLS decrypt. If SyncClient isn't initialised
    // or the frame doesn't belong to a known group, surface
    // raw bytes + decrypted=false so the caller can log.
    let mut decrypted_bytes: Option<Vec<u8>> = None;
    // MLS state change, not a chat message (a Commit, our own
    // echo, a stale frame) — Dart must not store it.
    let mut control = false;
    let mut sender_id: Option<String> = None;
    // mls-identity:3 — a Commit that let people in or took them out:
    // `{"by", "added", "removed"}` (identity hex) for the chat's line.
    let mut membership: Option<String> = None;
    // ADR-023: a sealed delivery names no group — opening the
    // envelope reveals it (decap + MLS + sender in one call).
    let mut group_id = p.group_id.clone();
    {
        let mut slot = sync_slot().lock().await;
        if let Some(client) = slot.as_mut() {
            // ADR-092 — a Commit (by its header, as the server reads it): note
            // whether we took it, for the next Commit we send.
            let commit_at = if p.sealed_key_id.is_empty() { sync::group::commit_epoch(&p.ciphertext) } else { None };
            let mut took = None;
            let mut own = false;
            let result = if p.sealed_key_id.is_empty() {
                client.decrypt_with_sender(&p.group_id, &p.ciphertext)
            } else {
                client.set_rotated_roots(&account_roots());
                client.open_sealed(&p.sealed_key_id, &p.ciphertext, now_unix()).map(|(g, m, s)| {
                    group_id = g;
                    (m, s)
                })
            };
            match result {
                Ok((sync::IncomingMessage::App(bytes), sender)) => {
                    sender_id = sender.map(hex::encode);
                    decrypted_bytes = Some(bytes);
                }
                Ok((sync::IncomingMessage::Commit { added, removed, new_epoch }, by)) => {
                    control = true;
                    took = Some(new_epoch);
                    if !added.is_empty() || !removed.is_empty() {
                        let hexes = |v: Vec<[u8; 32]>| v.into_iter().map(hex::encode).collect::<Vec<_>>();
                        let by = by.map(hex::encode).unwrap_or_default();
                        membership = Some(serde_json::json!({"by": by, "added": hexes(added), "removed": hexes(removed)}).to_string());
                    }
                }
                // ADR-101 — a Commit of ours waits for the server's answer,
                // and this frame is from another epoch: if the server took
                // ours, it is of the epoch ours leads to (the others moved
                // on) — keep it and open it once ours is applied, instead
                // of losing it.
                Ok((sync::IncomingMessage::StaleEpoch { .. }, _)) if p.sealed_key_id.is_empty() && client.has_pending_commit(&group_id).unwrap_or(false) => {
                    drop(slot);
                    hold_early_push(p);
                    return empty_net_event("held");
                }
                Ok((m, _)) => {
                    control = true;
                    // ADR-101 — the Commit we sent came back: the server
                    // took it (it only fans out what it ordered). Apply it
                    // now, Ack or no Ack — a lost Ack used to leave this
                    // device behind the chat for good.
                    own = commit_at.is_some() && matches!(m, sync::IncomingMessage::OwnCommitEcho) && is_our_sent_commit(&hex::encode(&group_id), &p.ciphertext);
                    if own && client.has_pending_commit(&group_id).unwrap_or(false) {
                        took = client.confirm_commit(&group_id).ok();
                        if took.is_some() {
                            if let Ok(mut e) = echoed_commits().lock() {
                                e.insert(p.message_id.clone());
                            }
                            // Sent before a restart: the record is in settings.
                            let g = hex::encode(&group_id);
                            if unanswered().contains_key(&g) {
                                unanswered_update(|u| {
                                    if let Some(e) = u.get_mut(&g) {
                                        e.applied = true;
                                    }
                                });
                            }
                        }
                    }
                }
                // Tech-debt 2.34 — the group's Welcome hasn't been
                // processed yet (a push can overtake it): keep the frame
                // and open it right after the join instead of dropping it.
                Err(sync::SyncError::UnknownGroup(_)) => {
                    drop(slot);
                    hold_early_push(p);
                    return empty_net_event("held");
                }
                // ADR-101 — as above for a frame that fails outright while a
                // Commit of ours waits (a sealed one names no chat: any
                // waiting Commit counts): kept, opened after it is applied.
                Err(_) if hold_while_waiting(p.sealed_key_id.is_empty().then(|| client.has_pending_commit(&group_id).unwrap_or(false)), !unanswered().is_empty()) => {
                    drop(slot);
                    hold_early_push(p);
                    return empty_net_event("held");
                }
                // Not shown to anyone (Dart drops "undecrypted"), only logged.
                Err(e) => eprintln!("[sinhron][net] push {} not decrypted: {e}", p.message_id),
            }
            if let Some(at) = commit_at {
                let g = hex::encode(&group_id);
                match (took, client.group_epoch(&group_id)) {
                    (Some(epoch), _) => commit_log_update(|log| log.moved(&g, epoch, &p.message_id)),
                    // Our own Commit echoed back is not one we refused —
                    // only one this app really sent (audit CM-06).
                    (None, Ok(mine)) if !own => commit_log_update(|log| log.refused(&g, &p.message_id, at, mine)),
                    _ => {}
                }
            }
        }
    }
    // ADR-025 — history from our own other device: name the chat
    // (it arrived here with a placeholder) before Dart stores it.
    if let (Some(b), Some(sender)) = (&decrypted_bytes, &sender_id) {
        if let Ok(sync::envelope::DecodedMessage {
            decoded: sync::envelope::Decoded::History { chat_name, is_group, saved, .. },
            ..
        }) = sync::envelope::decode_message(b)
        {
            let (mine, only_me) = {
                let mut slot = sync_slot().lock().await;
                match slot.as_mut() {
                    Some(c) => (Some(c.identity_pubkey_hex()), c.is_own_devices_group(&group_id).unwrap_or(false)),
                    None => (None, false),
                }
            };
            if mine.as_deref() == Some(sender.as_str()) {
                if !chat_name.is_empty() {
                    let _ = storage::chat_name_if_new(&hex::encode(&group_id), &chat_name, is_group);
                }
                // ADR-055 — my Saved messages, from my other device (and the
                // group really holds nobody but me).
                if saved && only_me {
                    adopt_saved_chat(&hex::encode(&group_id));
                }
            }
        }
    }
    // Tech-debt 2.2 — a member's access key: keep it (never ours).
    if let (Some(b), Some(sender)) = (&decrypted_bytes, &sender_id) {
        if let Ok(sync::envelope::DecodedMessage { decoded: sync::envelope::Decoded::Access { key }, .. }) =
            sync::envelope::decode_message(b)
        {
            let mine = sync_slot().lock().await.as_ref().map(|c| c.identity_pubkey_hex());
            if mine.as_deref() != Some(sender.as_str()) {
                remember_access_key(sender, &key).await;
            }
        }
    }
    // ADR-064 — a transfer for this device, or changes from my other one:
    // only from me, only in a group of nobody but me.
    let own_note = match (&decrypted_bytes, &sender_id) {
        (Some(b), Some(sender)) => super::transfer::on_own_message(b, sender, &group_id).await,
        _ => None,
    };
    let full = decrypted_bytes.as_deref().map(decode_push_full);
    let entities_json = full.as_ref().and_then(|(_, e)| e.clone());
    let decoded = full.map(|(parts, _)| parts);
    let decoded = match (decoded, own_note) {
        (Some((kind, ..)), note) if kind == "transfer" || kind == "device_sync" => match note {
            Some(n) => Some((kind, String::new(), None, None, Some(n), 0)),
            // Not from me / not my own group: drop it.
            None => Some(("invalid".to_string(), String::new(), None, None, None, 0)),
        },
        (d, _) => d,
    };
    let (kind, text, media_json, reply_json, action_json, expire_secs) = decoded.unwrap_or_else(|| {
        let kind = if control { "control" } else { "undecrypted" };
        (kind.to_string(), String::new(), None, None, membership, 0)
    });
    let (cipher_or_plain, decrypted) = match decrypted_bytes {
        Some(b) => (b, true),
        None => (p.ciphertext, false),
    };
    NetEvent {
        push: Some(NetPush {
            group_id_hex: hex::encode(&group_id),
            ciphertext: cipher_or_plain,
            decrypted,
            message_id: p.message_id,
            delivered_at_unix: p.delivered_at,
            sequence: p.sequence,
            kind,
            text,
            media_json,
            reply_json,
            sender_id,
            action_json,
            expire_secs,
            entities_json,
        }),
        ..empty_net_event("push")
    }
}

/// CD3 — small helper to build a NetEvent shell with all variant
/// payloads `None`. Lets the dispatch above populate just the field it
/// cares about via struct-update syntax. Cuts ~40 lines of repeated
/// `None,None,None` initializers.
fn empty_net_event(kind: &str) -> NetEvent {
    NetEvent {
        kind: kind.to_string(),
        disconnected_reason: None,
        push: None,
        ack: None,
        welcome: None,
        call_invite: None,
        call_accept: None,
        call_end: None,
        call_ring: None,
    }
}

// ─────────────────────────────────────────────────────────────────────
// Calls outgoing — CD3 (client → server signaling)
// ─────────────────────────────────────────────────────────────────────

/// Send a CallInvite frame to start an outgoing call. The caller (Dart
/// side) generates the `call_id` as a UUIDv7 string. `kind` MUST be
/// `"audio"` or `"video"`. Server validates 1:1ness + group membership;
/// async `NetEvent::call_ring` confirms delivery, `call_accept` /
/// `call_end` signals the eventual outcome.
pub async fn net_send_call_invite(
    call_id: String,
    group_id_hex: String,
    kind: String,
    ttl_secs: i64,
) -> Result<(), String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    // ADR-071 — the keys the people called gave me: without one, a phone
    // of someone with per-contact keys isn't woken (only their open app).
    let access_keys = members_access_keys(&group_id).await;
    let kind_enum = match kind.as_str() {
        "audio" => net::proto::call_invite::CallKind::Audio,
        "video" => net::proto::call_invite::CallKind::Video,
        other => return Err(format!("unknown call kind: {other}")),
    };
    // ADR-090 (calls:5) — signed by me, so the server can't ring anyone as me.
    let caller_proof = {
        let slot = sync_slot().lock().await;
        let c = slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?;
        c.call_invite_proof(&call_id, &group_id, kind == "video", server_now())
    };
    let frame = net::proto::WsFrame {
        frame_id: format!("call-invite-{}", uuid::Uuid::now_v7()),
        body: Some(net::proto::ws_frame::Body::CallInvite(
            net::proto::CallInvite {
                call_id: call_id.clone(),
                group_id,
                kind: kind_enum as i32,
                // Server canonicalizes the livekit_room name anyway —
                // we send a hint based on call_id to avoid sending empty.
                livekit_room: format!("sinhron-call-{}", call_id),
                ttl_secs,
                // The server fills in who calls.
                caller_identity: Vec::new(),
                access_keys,
                // ADR-071 (amended) — this app knows access keys: without
                // one, the callee's open app only (old apps still ring).
                sends_access_keys: true,
                caller_proof,
            },
        )),
    };
    let slot = net_slot().lock().await;
    let client = slot
        .as_ref()
        .ok_or_else(|| "net not connected".to_string())?;
    client.send(frame).await.map_err(|e| e.to_string())
}

/// The server's clock (as the signed requests use): both ends of a call
/// read the same time even when a phone's own clock is off.
fn server_now() -> u64 {
    net::clock_drift::corrected_now_secs().max(0) as u64
}

/// ADR-090 (calls:5) — the caller of [ci], if it signed this very invite
/// (fresh, this chat, this kind) and is a member of the chat here; "" for
/// anything else — an invite only the server wrote.
async fn signed_caller(ci: &net::proto::CallInvite) -> String {
    let Some(id) = sync::call_invite::verify(&ci.caller_proof, &ci.call_id, &ci.group_id, ci.kind == 2, server_now()) else {
        tracing::warn!(call = %ci.call_id, "call invite without a valid caller signature");
        return String::new();
    };
    let mut slot = sync_slot().lock().await;
    let member = slot
        .as_mut()
        .and_then(|c| c.group_member_identities(&ci.group_id).ok())
        .is_some_and(|ids| ids.iter().any(|m| m.as_slice() == id));
    if member { hex::encode(id) } else { String::new() }
}

/// Send a CallAccept frame in response to an incoming CallInvite.
/// `accept=true` = picking up; `accept=false` = declining (server
/// translates to CallEnd{reason="rejected"} for the caller).
pub async fn net_send_call_accept(call_id: String, accept: bool) -> Result<(), String> {
    let frame = net::proto::WsFrame {
        frame_id: format!("call-accept-{}", uuid::Uuid::now_v7()),
        body: Some(net::proto::ws_frame::Body::CallAccept(
            net::proto::CallAccept { call_id, accept },
        )),
    };
    let slot = net_slot().lock().await;
    let client = slot
        .as_ref()
        .ok_or_else(|| "net not connected".to_string())?;
    client.send(frame).await.map_err(|e| e.to_string())
}

/// Send a CallEnd frame. Either side may end at any time. `reason` is
/// free-text for diagnostics; common values: "hangup", "network_lost".
pub async fn net_send_call_end(call_id: String, reason: String) -> Result<(), String> {
    let frame = net::proto::WsFrame {
        frame_id: format!("call-end-{}", uuid::Uuid::now_v7()),
        body: Some(net::proto::ws_frame::Body::CallEnd(
            net::proto::CallEnd { call_id, reason },
        )),
    };
    let slot = net_slot().lock().await;
    let client = slot
        .as_ref()
        .ok_or_else(|| "net not connected".to_string())?;
    client.send(frame).await.map_err(|e| e.to_string())
}

// ─────────────────────────────────────────────────────────────────────
// Calls — Stage C FFI surface (sinhron_call + group exporter)
// ─────────────────────────────────────────────────────────────────────
//
// Phase 3 calls connect Flutter's `livekit_client` to MLS-derived SFrame
// keys. The Dart side composes:
//
//   1. Call `mls_exporter(group_id, "SFrame 1.0 Base Key", "", 32)`
//      → bytes feed `sframe_epoch_secret`.
//   2. Call `group_own_leaf_index(group_id)` + `group_epoch(group_id)`.
//   3. Call `kid_compose(0, sender_index, epoch)` → packed KID.
//   4. Call `sframe_derive_key_pair(epoch_secret, sender_index, kid,
//      cipher_suite)` → { key_hex, salt_hex }.
//   5. Pass key/salt to livekit_client's BaseKeyProvider via setKey().
//
// Re-do steps 1-5 whenever group_epoch changes (poll-on-demand; see
// CC5 deferred to D6).

/// Current MLS epoch (bumps on every Commit). Input to SFrame KID
/// composition. Used by the Flutter poll loop to detect when SFrame
/// keys need re-deriving (CC5 / D6 strategy).
pub async fn mls_group_epoch(group_id_hex: String) -> Result<u64, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot
        .as_mut()
        .ok_or_else(|| "sync not initialised".to_string())?;
    client.group_epoch(&group_id).map_err(|e| e.to_string())
}

/// Result of [`sframe_derive_key_pair`]. Hex-encoded so Dart sees plain
/// strings; AES-128 keys are 32 hex chars, AES-256 keys are 64 hex chars.
/// Salt is always 24 hex chars (12 raw bytes per AES-GCM nonce length).
pub struct SframeKeyMaterialHex {
    pub key_hex: String,
    pub salt_hex: String,
}

/// SFrame key of one call participant (tech-debt 4.1/4.9).
pub struct CallSframeKey {
    pub key_hex: String,
    pub salt_hex: String,
    pub epoch: u64,
    /// LiveKit key-ring slot for this epoch (epoch mod 16, matching the
    /// 4-bit epoch field of the KID).
    pub key_index: u32,
}

/// The current SFrame key for the participant whose identity public key
/// is `identity_hex` (LiveKit identity = that hex) — ourselves or anyone
/// else in the group. MLS SFrame derives every sender's key from the
/// shared exporter secret + their leaf index, so each member can set
/// keys for everyone in the room (LiveKit per-participant mode).
/// Errors if the identity isn't a member of the group.
pub async fn call_sframe_key_for(group_id_hex: String, identity_hex: String) -> Result<CallSframeKey, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let identity = hex::decode(&identity_hex).map_err(|e| e.to_string())?;
    let cipher = call::CipherSuite::AesGcm128Sha256;
    let (secret, leaf, epoch) = {
        let mut slot = sync_slot().lock().await;
        let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let leaf = client
            .group_member_leaf(&group_id, &identity)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "not a member of this group".to_string())?;
        let secret = client
            .group_exporter(&group_id, "SFrame 1.0 Base Key", &[], 16)
            .map_err(|e| e.to_string())?;
        (secret, leaf, client.group_epoch(&group_id).map_err(|e| e.to_string())?)
    };
    let base = call::sender_base_key(&secret, leaf, cipher).map_err(|e| e.to_string())?;
    let kp = call::sframe_key_pair(&base, call::Kid::compose(0, leaf, epoch), cipher).map_err(|e| e.to_string())?;
    Ok(CallSframeKey {
        key_hex: hex::encode(&kp.key),
        salt_hex: hex::encode(&kp.salt),
        epoch,
        key_index: (epoch % 16) as u32,
    })
}

// ─────────────────────────────────────────────────────────────────────
// CD6 — server-issued LiveKit JWT + TURN creds (FFI)
// ─────────────────────────────────────────────────────────────────────

/// LiveKit JWT response surfaced to Dart. Token is the opaque JWT;
/// Dart hands it to `livekit_client.Room.connect`.
pub struct LivekitTokenInfo {
    pub token: String,
    pub livekit_url: String,
    pub room: String,
    pub expires_at_unix: i64,
    pub ttl_secs: i64,
    /// ADR-045 — video codecs the server takes, best first (empty from
    /// older servers: H.264 / VP8 only).
    pub video_codecs: Vec<String>,
}

/// CD6 — request a LiveKit JWT for a call. Reads the identity seed from
/// the live `SyncClient` singleton (set up at onboarding via
/// `sync_init_from_phrase`). Phrase NEVER crosses FFI for calls — it
/// already produced the seed at onboarding time and stays Rust-side.
///
/// Returns the JWT + canonical room name. Requires SyncClient to be
/// initialized; errors with "sync not initialised" otherwise.
pub async fn call_request_livekit_token(
    server_base_url: String,
    group_id_hex: String,
    kind: String,
) -> Result<LivekitTokenInfo, String> {
    let slot = sync_slot().lock().await;
    let client = slot
        .as_ref()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let seed = client.identity_seed_bytes();
    drop(slot); // release the singleton lock before HTTP I/O
    let http = sync::HttpApi::new(server_base_url);
    let r = http
        .request_livekit_token(seed, &group_id_hex, &kind)
        .await
        .map_err(|e| e.to_string())?;
    // ADR-072 — the LiveKit host is ours too (Dart's override asks about it).
    net::dns::global().add_our_host(&r.livekit_url);
    Ok(LivekitTokenInfo {
        token: r.token,
        livekit_url: r.livekit_url,
        room: r.room,
        expires_at_unix: r.expires_at_unix,
        ttl_secs: r.ttl_secs,
        video_codecs: r.video_codecs,
    })
}

/// Is anyone in this group's call right now (LiveKit's count, via the
/// server)? Before the chat offers "Join" (owner, 2026-10-18). An error
/// (older server, offline) means "don't know".
pub async fn call_is_live(server_base_url: String, group_id_hex: String) -> Result<bool, String> {
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    sync::HttpApi::new(server_base_url)
        .request_call_live(seed, &group_id_hex)
        .await
        .map_err(|e| e.to_string())
}

/// TURN credential response.
pub struct TurnCredsInfo {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
    pub ttl_secs: i64,
}

// ─────────────────────────────────────────────────────────────────────
// CD9 — Call history persistence (FFI)
// ─────────────────────────────────────────────────────────────────────

/// Materialized row for Dart side. Mirrors storage::StoredCall.
pub struct StoredCallSummary {
    pub id: String,
    pub peer_chat_id: String,
    pub kind: String,
    pub status: String,
    pub is_outgoing: bool,
    pub started_at_unix: i64,
    pub ended_at_unix: Option<i64>,
    pub duration_secs: Option<i64>,
}

/// CD9 — append a call to the history table. Called once per call on
/// terminal transition. Idempotent on `id` (INSERT OR REPLACE).
#[allow(clippy::too_many_arguments)]
pub fn storage_call_append(
    id: String,
    peer_chat_id: String,
    kind: String,
    status: String,
    is_outgoing: bool,
    started_at_unix: i64,
    ended_at_unix: Option<i64>,
    duration_secs: Option<i64>,
) -> Result<(), String> {
    storage::call_append(
        &id,
        &peer_chat_id,
        &kind,
        &status,
        is_outgoing,
        started_at_unix,
        ended_at_unix,
        duration_secs,
    )
    .map_err(|e| e.to_string())
}

/// CD9 — list call history, most-recent first. Used by the Calls tab.
pub fn storage_calls_list() -> Result<Vec<StoredCallSummary>, String> {
    let rows = storage::calls_list().map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|r| StoredCallSummary {
            id: r.id,
            peer_chat_id: r.peer_chat_id,
            kind: r.kind,
            status: r.status,
            is_outgoing: r.is_outgoing,
            started_at_unix: r.started_at_unix,
            ended_at_unix: r.ended_at_unix,
            duration_secs: r.duration_secs,
        })
        .collect())
}

/// Tech-debt 2.32 — one chat's share of the local media copies.
pub struct ChatStorageUsage {
    pub chat_id: String,
    pub bytes: i64,
}

/// Tech-debt 2.32 — space messages take on this phone (Storage screen).
pub struct StorageUsageSummary {
    pub photos: i64,
    pub videos: i64,
    pub voice: i64,
    pub documents: i64,
    /// Link-preview images and other blobs (not `other`: that name clashes
    /// with `==(Object other)` in the generated Dart class).
    pub misc: i64,
    /// Copies no message references (removed on the next start).
    pub unreferenced: i64,
    /// The message database (with WAL / SHM).
    pub database: i64,
    /// Heaviest first.
    pub by_chat: Vec<ChatStorageUsage>,
}

/// Tech-debt 2.32 — how much space messages take here.
pub fn storage_usage() -> Result<StorageUsageSummary, String> {
    let u = storage::blobs::usage().map_err(|e| e.to_string())?;
    let n = |v: u64| i64::try_from(v).unwrap_or(i64::MAX);
    Ok(StorageUsageSummary {
        photos: n(u.photos),
        videos: n(u.videos),
        voice: n(u.voice),
        documents: n(u.documents),
        misc: n(u.other),
        unreferenced: n(u.unreferenced),
        database: n(u.database),
        by_chat: u.by_chat.into_iter().map(|(chat_id, b)| ChatStorageUsage { chat_id, bytes: n(b) }).collect(),
    })
}

/// Tech-debt 2.32 — delete the local media copies (older than a minute —
/// younger ones may be a send in flight). Returns the bytes freed. Files
/// load from the server again while it still has them.
pub fn storage_clear_media_copies() -> Result<i64, String> {
    storage::blobs::clear_copies(std::time::Duration::from_secs(60))
        .map(|b| i64::try_from(b).unwrap_or(i64::MAX))
        .map_err(|e| e.to_string())
}

/// Tech-debt 2.32 — "keep media copies: a month / a week": delete the
/// copies nobody opened for [days] days (a copy's age counts from its last
/// use). Run at start; returns the bytes freed. 0 days → nothing.
pub fn storage_clear_media_copies_older_than(days: u32) -> Result<i64, String> {
    if days == 0 {
        return Ok(0);
    }
    storage::blobs::clear_copies(std::time::Duration::from_secs(u64::from(days) * 86_400))
        .map(|b| i64::try_from(b).unwrap_or(i64::MAX))
        .map_err(|e| e.to_string())
}

/// CD6 — request TURN credentials. Same singleton-identity flow as
/// [`call_request_livekit_token`].
pub async fn call_request_turn_creds(
    server_base_url: String,
) -> Result<TurnCredsInfo, String> {
    let slot = sync_slot().lock().await;
    let client = slot
        .as_ref()
        .ok_or_else(|| "sync not initialised".to_string())?;
    let seed = client.identity_seed_bytes();
    drop(slot);
    let http = sync::HttpApi::new(server_base_url);
    let r = http
        .request_turn_creds(seed)
        .await
        .map_err(|e| e.to_string())?;
    Ok(TurnCredsInfo {
        urls: turn_urls_with_checked_ips(r.urls, |h| net::dns::global().override_ip(h)),
        username: r.username,
        credential: r.credential,
        ttl_secs: r.ttl_secs,
    })
}

/// ADR-072 — WebRTC resolves TURN hosts with the system resolver. When
/// that answer was proven wrong for one of our hosts, a plain `turn:` /
/// `stun:` URL also goes out with the checked address in place of the
/// name (TURN authenticates with the credential, not a certificate; the
/// media stays end-to-end encrypted). `turns:` can't: TLS needs the name
/// (SNI routing on 443), so it stays as it is.
fn turn_urls_with_checked_ips(urls: Vec<String>, checked: impl Fn(&str) -> Option<std::net::IpAddr>) -> Vec<String> {
    let mut out = Vec::with_capacity(urls.len() * 2);
    for u in urls {
        let alt = u.split_once(':').and_then(|(scheme, rest)| {
            let s = scheme.to_ascii_lowercase();
            if s != "turn" && s != "stun" {
                return None;
            }
            let end = rest.find([':', '?']).unwrap_or(rest.len());
            let ip = checked(&rest[..end])?;
            let ip = match ip {
                std::net::IpAddr::V6(v6) => format!("[{v6}]"),
                v4 => v4.to_string(),
            };
            Some(format!("{scheme}:{ip}{}", &rest[end..]))
        });
        out.push(u);
        out.extend(alt);
    }
    out
}

#[cfg(test)]
mod transfer_direction_tests {
    use super::sends_everything_to;

    // Owner, 2026-10-26 — the new phone sent its empty database to the old
    // one; everything goes from the older device to the newer only.
    #[test]
    fn everything_goes_from_older_to_newer_only() {
        assert!(sends_everything_to(Some(100), Some(200)), "old phone → new device");
        assert!(!sends_everything_to(Some(200), Some(100)), "new device → old phone: never");
        assert!(!sends_everything_to(Some(100), Some(100)));
        assert!(sends_everything_to(None, Some(100)), "unknown: as before");
        assert!(sends_everything_to(Some(100), None));
    }
}

#[cfg(test)]
mod turn_url_tests {
    use super::turn_urls_with_checked_ips;

    #[test]
    fn plain_turn_gets_the_checked_address_turns_stays() {
        let urls = vec![
            "turn:chat.example:3478?transport=udp".to_string(),
            "turn:chat.example:3478?transport=tcp".to_string(),
            "turns:turn.chat.example:443?transport=tcp".to_string(),
            "stun:other.example:3478".to_string(),
        ];
        let checked = |h: &str| (h == "chat.example" || h == "turn.chat.example").then(|| "176.124.223.138".parse().unwrap());
        assert_eq!(
            turn_urls_with_checked_ips(urls.clone(), checked),
            vec![
                "turn:chat.example:3478?transport=udp",
                "turn:176.124.223.138:3478?transport=udp",
                "turn:chat.example:3478?transport=tcp",
                "turn:176.124.223.138:3478?transport=tcp",
                "turns:turn.chat.example:443?transport=tcp",
                "stun:other.example:3478",
            ]
        );
        // System answer fine → the list is untouched.
        assert_eq!(turn_urls_with_checked_ips(urls.clone(), |_| None), urls);
    }
}

#[cfg(test)]
mod action_tests {
    use super::*;

    // Owner, 2026-10-20 — a second copy of a delivery (backlog + Resume
    // replay) is skipped instead of failing to decrypt into "<binary>".
    #[test]
    fn a_delivery_is_taken_once() {
        let seq = 9_000_000_123;
        assert!(first_delivery(seq));
        assert!(!first_delivery(seq), "the copy is skipped");
        assert!(first_delivery(seq - 1), "an older one that arrives later still counts");
    }

    const ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

    /// Overnight backlog #2 — two real MLS clients, the same path an action
    /// takes in the app minus the network: Dart JSON → `encode_action` →
    /// Alice encrypts → Bob `decrypt_with_sender` (MLS-authenticated sender)
    /// → `decode_push` → applied to Bob's storage the way Dart does it.
    #[test]
    fn two_clients_actions_end_to_end() {
        const A: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon \
                         abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon \
                         abandon abandon abandon art";
        const B: &str = "legal winner thank year wave sausage worth useful legal winner thank year \
                         wave sausage worth useful legal winner thank year wave sausage worth title";
        let cfg = |p: &str| sync::SyncClientConfig { phrase: p.split_whitespace().collect::<Vec<_>>().join(" "), db_path: None, device_seed: None };
        let mut alice = sync::SyncClient::new(cfg(A)).unwrap();
        let mut bob = sync::SyncClient::new(cfg(B)).unwrap();
        let group = alice.create_group().unwrap();
        let kp = bob.create_keypackage().unwrap();
        let welcome = alice.invite_to_group(&group, &kp).unwrap().welcome_bytes;
        assert_eq!(bob.join_via_welcome(&welcome).unwrap(), group);
        let (alice_hex, bob_hex) = (alice.identity_pubkey_hex(), bob.identity_pubkey_hex());

        // Alice → Bob: what Bob's app gets out of one envelope.
        let mut send = |plain: Vec<u8>| -> (PushParts, String) {
            let ct = alice.encrypt(&group, &plain).unwrap();
            match bob.decrypt_with_sender(&group, &ct).unwrap() {
                (sync::IncomingMessage::App(b), Some(sender)) => (decode_push(&b), hex::encode(sender)),
                other => panic!("{other:?}"),
            }
        };
        let json = |parts: &PushParts| -> serde_json::Value { serde_json::from_str(parts.4.as_deref().unwrap()).unwrap() };

        // Bob's local database.
        let path = std::env::temp_dir().join(format!("sinhron_two_clients_{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        storage::open(&path, None).unwrap();
        let chat = hex::encode(&group);
        storage::chat_upsert(&chat, "Alice", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        storage::chat_set_request(&chat, true).unwrap(); // Alice started it

        // A text: authenticated as Alice, stored with her key as the author.
        let (t, sender) = send(sync::envelope::encode_text("привет"));
        assert_eq!((t.0.as_str(), t.1.as_str(), sender.as_str()), ("text", "привет", alice_hex.as_str()));
        let wire = "0f8fad5b-d9cb-469f-a165-70867728950e";
        let now = 1_900_000_000;
        storage::message_insert(&storage::NewMessage {
            id: "remote-1",
            chat_id: &chat,
            ts_unix: now,
            body: &t.1,
            kind: "text",
            wire_id: Some(wire),
            sender_id: Some(&sender),
            ..Default::default()
        })
        .unwrap();
        let chats = storage::chats_list().unwrap();
        assert!(chats.iter().any(|c| c.id == chat && c.request), "their message doesn't accept the request");

        // Profile: the name arrives cleaned and is stored under Alice's key.
        let (p, sender) = send(encode_action(r#"{"t":"profile","name":"  Алиса\u202e  "}"#).unwrap());
        assert_eq!(p.0, "profile");
        let name = json(&p)["name"].as_str().unwrap().to_string();
        assert_eq!(name, "Алиса", "bidi override stripped");
        assert!(storage::peer_name_set(&sender, &name, now).unwrap());
        assert_eq!(storage::peer_names().unwrap(), vec![(alice_hex.clone(), "Алиса".to_string())]);

        // Photo (tech-debt 2.21): Alice's picture carries EXIF + a GPS tag.
        // Her side re-encodes it before sending; Bob re-encodes again before
        // storing — what lands is a small JPEG with no metadata.
        let mut raw = Vec::new();
        image::RgbImage::from_fn(640, 480, |x, y| image::Rgb([(x % 256) as u8, (y % 256) as u8, 90]))
            .write_to(&mut std::io::Cursor::new(&mut raw), image::ImageFormat::Jpeg)
            .unwrap();
        let mut seg = b"Exif\0\0MM\0\x2a\0\0\0\x08\0\0\0\0\0\0GPSTEST-55.7558N".to_vec();
        let mut tagged = raw[..2].to_vec();
        tagged.extend_from_slice(&[0xFF, 0xE1]);
        tagged.extend_from_slice(&((seg.len() + 2) as u16).to_be_bytes());
        tagged.append(&mut seg);
        tagged.extend_from_slice(&raw[2..]);
        let mine = media_avatar_prepare(tagged.clone()).unwrap();
        let has = |hay: &[u8], needle: &[u8]| hay.windows(needle.len()).any(|w| w == needle);
        assert!(has(&tagged, b"GPSTEST") && !has(&mine, b"GPSTEST") && !has(&mine, b"Exif"));
        assert!(mine.len() <= sync::media::MAX_THUMBNAIL_BYTES);
        let b64 = base64::engine::general_purpose::STANDARD.encode(&mine);
        let (p, sender) = send(encode_action(&format!(r#"{{"t":"profile","name":"Алиса","avatar":"{b64}"}}"#)).unwrap());
        let got = base64::engine::general_purpose::STANDARD.decode(json(&p)["avatar"].as_str().unwrap()).unwrap();
        assert_eq!(got, mine, "the photo makes the trip intact");
        assert!(storage_peer_avatar_set(sender.clone(), got, now).unwrap());
        let stored = storage::peer_avatars().unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].0, alice_hex);
        assert!(stored[0].1.starts_with(&[0xFF, 0xD8]) && !has(&stored[0].1, b"Exif"));
        // Garbage instead of a picture removes the photo rather than storing it.
        assert!(storage_peer_avatar_set(sender.clone(), b"not an image".to_vec(), now + 1).unwrap());
        assert!(storage::peer_avatars().unwrap().is_empty());
        assert!(media_avatar_prepare(b"not an image".to_vec()).is_err());

        // Edit: only the author, only inside the window (+ delivery grace).
        let (e, sender) = send(encode_action(&format!(r#"{{"t":"edit","target":"{wire}","text":"привет!"}}"#)).unwrap());
        let text = json(&e)["text"].as_str().unwrap().to_string();
        assert!(!storage::message_apply_edit(&chat, wire, storage::Author::Peer(&bob_hex), "чужая правка", None, now + 60).unwrap());
        assert!(storage::message_apply_edit(&chat, wire, storage::Author::Peer(&sender), &text, None, now + 60).unwrap());
        let late = now + storage::EDIT_WINDOW_SECS + storage::LATE_ACTION_GRACE_SECS + 1;
        assert!(!storage::message_apply_edit(&chat, wire, storage::Author::Peer(&sender), "переписать историю", None, late).unwrap());
        assert_eq!(storage::message_by_wire(&chat, wire).unwrap().unwrap().body, "привет!");

        // Pin for everyone, timer, screenshot notice.
        let (pin, _) = send(encode_action(&format!(r#"{{"t":"pin","target":"{wire}","pinned":true}}"#)).unwrap());
        assert_eq!((pin.0.as_str(), json(&pin)["target"].as_str()), ("pin", Some(wire)));
        let (timer, _) = send(sync::envelope::encode_timer(3600));
        assert_eq!((timer.0.as_str(), json(&timer)["secs"].as_u64()), ("timer", Some(3600)));
        let (shot, sender) = send(encode_action(r#"{"t":"screenshot"}"#).unwrap());
        assert_eq!((shot.0.as_str(), sender.as_str()), ("screenshot", alice_hex.as_str()));
        let (rec, _) = send(encode_action(r#"{"t":"screenshot","recording":true}"#).unwrap());
        assert_eq!((rec.0.as_str(), json(&rec)["recording"].as_bool()), ("screenshot", Some(true)));
        // ADR-034 — a group's name, cleaned on the way out.
        let (gn, _) = send(encode_action(r#"{"t":"group_name","name":"  Дача\u202e "}"#).unwrap());
        assert_eq!((gn.0.as_str(), json(&gn)["name"].as_str()), ("group_name", Some("Дача")));
        assert!(encode_action(r#"{"t":"group_name","name":"  "}"#).is_err());

        // Delete for everyone by the author; then my reply accepts the request.
        let (d, sender) = send(encode_action(&format!(r#"{{"t":"delete","target":"{wire}"}}"#)).unwrap());
        assert_eq!(d.0, "delete");
        assert!(storage::message_apply_delete(&chat, wire, storage::Author::Peer(&sender), now + 120).unwrap());
        assert!(storage::message_by_wire(&chat, wire).unwrap().unwrap().deleted);
        storage::message_append("mine-1", &chat, now + 130, "ok", "text", true, None).unwrap();
        assert!(storage::chats_list().unwrap().iter().any(|c| c.id == chat && !c.request), "my reply accepts it");
        let _ = std::fs::remove_file(&path);

        // DEV-8 — a failed device sync after the server disconnected the device
        // is not an error of "Disconnect" (the key change must still follow).
        assert_eq!(report_after_revoke(Err("connection lost".into())).removed, 0);

        // BKP-1 — a restore from the cloud ends on a generation the backup
        // didn't bring (its root isn't signed: a disconnected device may know
        // the roots in it); what it brought is kept for opening old envelopes.
        let planted = crypto::identity::RootsGen { gen: 7, secret: [0x66; 32] };
        storage::setting_set(ROOTS_SETTING, &planted.encode()).unwrap();
        assert_eq!(new_account_roots().unwrap(), planted.encode());
        let now = account_roots();
        assert_eq!(now[0].gen, 8);
        assert_ne!(now[0].secret, planted.secret);
        // DEV-2 — a planted top generation number doesn't wrap round to 0.
        assert_eq!(sync::backup::new_generation(Some(&crypto::identity::RootsGen { gen: u32::MAX, secret: [1; 32] })).gen, u32::MAX);
    }

    fn roundtrip(action: &str) -> PushParts {
        decode_push(&encode_action(action).expect("valid action"))
    }

    #[test]
    fn actions_survive_the_trip_to_dart() {
        let (kind, _, _, _, a, _) = roundtrip(&format!(r#"{{"t":"reaction","target":"{ID}","emoji":"🔥"}}"#));
        assert_eq!(kind, "reaction");
        let v: serde_json::Value = serde_json::from_str(&a.unwrap()).unwrap();
        assert_eq!((v["target"].as_str(), v["emoji"].as_str()), (Some(ID), Some("🔥")));

        let (kind, _, _, _, a, _) = roundtrip(&format!(r#"{{"t":"receipt","read":true,"ids":["{ID}"]}}"#));
        assert_eq!(kind, "receipt");
        let v: serde_json::Value = serde_json::from_str(&a.unwrap()).unwrap();
        assert_eq!(v["read"], true);
        assert_eq!(v["ids"][0], ID);

        for (t, extra) in [("edit", r#","text":"new""#), ("delete", ""), ("typing", "")] {
            let json = if t == "typing" {
                r#"{"t":"typing","active":true}"#.to_string()
            } else {
                format!(r#"{{"t":"{t}","target":"{ID}"{extra}}}"#)
            };
            assert_eq!(roundtrip(&json).0, t);
        }
        let (kind, _, _, _, a, _) = roundtrip(r#"{"t":"timer","secs":3600}"#);
        assert_eq!((kind.as_str(), a.as_deref()), ("timer", Some(r#"{"secs":3600}"#)));
        let p = decode_push(&sync::envelope::encode_text_expiring("bye", None, None, 60));
        assert_eq!((p.0.as_str(), p.5), ("text", 60));
    }

    #[test]
    fn profile_and_pin_reach_dart() {
        let (kind, _, _, _, a, _) = roundtrip(r#"{"t":"profile","name":"  Вера  "}"#);
        assert_eq!((kind.as_str(), a.as_deref()), ("profile", Some(r#"{"avatar":"","bio":"","name":"Вера"}"#)));
        let (_, _, _, _, a, _) = roundtrip(r#"{"t":"profile","name":"Вера","avatar":"AQID","bio":" Пишите\nднём "}"#);
        let v: serde_json::Value = serde_json::from_str(&a.unwrap()).unwrap();
        assert_eq!(v["avatar"], "AQID", "the photo bytes make the trip");
        assert_eq!(v["bio"], "Пишите днём", "ADR-052 — the bio too, as one clean line");
        let (kind, _, _, _, a, _) = roundtrip(&format!(r#"{{"t":"pin","target":"{ID}","pinned":false}}"#));
        assert_eq!(kind, "pin");
        let v: serde_json::Value = serde_json::from_str(&a.unwrap()).unwrap();
        assert_eq!((v["target"].as_str(), v["pinned"].as_bool()), (Some(ID), Some(false)));
        assert!(encode_action(r#"{"t":"profile","name":"   "}"#).is_err());
        assert!(encode_action(r#"{"t":"pin","target":""}"#).is_err());
        let (kind, _, _, _, a, _) = roundtrip(r#"{"t":"screenshot"}"#);
        assert_eq!((kind.as_str(), a.as_deref()), ("screenshot", Some("{}")));
        let (kind, _, _, _, a, _) = roundtrip(r#"{"t":"screenshot","recording":true}"#);
        assert_eq!((kind.as_str(), a.as_deref()), ("screenshot", Some(r#"{"recording":true}"#)));
        // ADR-031 — presence keeps both flags; hidden is never online.
        let (kind, _, _, _, a, _) = roundtrip(r#"{"t":"presence","online":true}"#);
        assert_eq!((kind.as_str(), a.as_deref()), ("presence", Some(r#"{"hidden":false,"online":true}"#)));
        let (_, _, _, _, a, _) = roundtrip(r#"{"t":"presence","online":true,"hidden":true}"#);
        assert_eq!(a.as_deref(), Some(r#"{"hidden":true,"online":false}"#));
    }

    /// ADR-101 — a frame that did not open is kept while a Commit of ours
    /// waits: in its chat, or (a sealed frame names no chat) in any.
    #[test]
    fn frames_are_kept_while_our_commit_waits() {
        assert!(hold_while_waiting(Some(true), false));
        assert!(!hold_while_waiting(Some(false), true), "another chat's waiting Commit is no reason");
        assert!(hold_while_waiting(None, true));
        assert!(!hold_while_waiting(None, false));
    }

    /// ADR-100 — all of my person's cards are tried, newest epoch first
    /// (the same content signed by this very device must not hide the one
    /// the other device signed); other people's are not.
    #[test]
    fn all_my_cards_are_tried_newest_first() {
        let card = |epoch, who: u8, tag: u8| sync::card_choice::CardFromServer { epoch, card: vec![tag], identity: [who; 32] };
        let got = my_cards_newest_first(vec![card(4, 1, 10), card(5, 2, 20), card(5, 1, 30), card(5, 1, 31)], &[1; 32]);
        assert_eq!(got, vec![vec![30], vec![31], vec![10]]);
    }

    /// ADR-101 — our own Commit, sent again after a lost Ack, is applied
    /// only on Ack 0; a 409 (someone else's change won) or a refusal drops
    /// it; with no verdict it waits.
    #[test]
    fn a_commit_sent_again_is_applied_only_on_ack_0() {
        assert_eq!(after_resend(Some(0)), Resend::Apply);
        for refused in [409, 400, 403] {
            assert_eq!(after_resend(Some(refused)), Resend::Drop, "{refused}");
        }
        for unknown in [None, Some(429), Some(500), Some(503)] {
            assert_eq!(after_resend(unknown), Resend::Wait, "{unknown:?}");
        }
    }

    #[test]
    fn bad_actions_never_leave_the_device() {
        assert!(encode_action(r#"{"t":"reaction","target":"x y","emoji":"👍"}"#).is_err());
        assert!(encode_action(r#"{"t":"edit","target":"abc","text":""}"#).is_err());
        assert!(encode_action(r#"{"t":"receipt","read":true,"ids":[]}"#).is_err());
        assert!(encode_action(r#"{"t":"launch-missiles"}"#).is_err());
        assert!(encode_action("not json").is_err());
    }

    /// ADR-070 — formatting reaches Dart beside the clean text; edits and
    /// history carry theirs in the action JSON; an older app's has none.
    #[test]
    fn formatting_reaches_dart() {
        use sync::envelope::{TextEntity, ENTITY_BOLD};
        let bold = TextEntity { kind: ENTITY_BOLD, offset: 0, length: 2, ..Default::default() };
        let ((kind, text, ..), e) =
            decode_push_full(&sync::envelope::encode_text_rich("Hi you", vec![bold.clone()], None, None, 0));
        assert_eq!((kind.as_str(), text.as_str()), ("text", "Hi you"));
        assert_eq!(e.as_deref(), Some(r#"[{"t":"bold","o":0,"l":2}]"#));
        assert_eq!(decode_push_full(&sync::envelope::encode_text("*Hi*")).1, None);

        let edit = encode_action(&format!(
            r#"{{"t":"edit","target":"{ID}","text":"Hi","entities":[{{"t":"italic","o":0,"l":2}},{{"t":"bold","o":0,"l":7}}]}}"#
        ))
        .unwrap();
        let (kind, _, _, _, a, _) = decode_push(&edit);
        assert_eq!(kind, "edit");
        let v: serde_json::Value = serde_json::from_str(&a.unwrap()).unwrap();
        assert_eq!(v["entities"], serde_json::json!([{"t": "italic", "o": 0, "l": 2}]), "the bad range is gone");
        let (_, _, _, _, a, _) = roundtrip(&format!(r#"{{"t":"edit","target":"{ID}","text":"x"}}"#));
        assert!(serde_json::from_str::<serde_json::Value>(&a.unwrap()).unwrap().get("entities").is_none());
        assert!(encode_action(&format!(r#"{{"t":"edit","target":"{ID}","text":"x","entities":"bad"}}"#)).is_err());

        let item = |rich: bool| sync::envelope::HistoryItem {
            wire_id: ID.into(),
            ts: 1,
            kind: "text".into(),
            text: "Hi".into(),
            sender: "ab".repeat(32),
            entities: if rich { vec![bold.clone()] } else { vec![] },
            rich,
            ..Default::default()
        };
        let (_, _, _, _, a, _) = decode_push(&sync::envelope::encode_history(vec![item(true), item(false)], "B", false, false));
        let v: serde_json::Value = serde_json::from_str(&a.unwrap()).unwrap();
        assert_eq!(v[0]["entities"], serde_json::json!([{"t": "bold", "o": 0, "l": 2}]));
        assert!(v[1].get("entities").is_none());
        assert!(v[0].get("rich").is_none(), "internal fields stay out of the JSON");

        assert_eq!(stored_entities("Hi", Some(r#"[{"t":"bold","o":0,"l":9}]"#)).as_deref(), Some("[]"));
        assert_eq!(stored_entities("Hi", Some("garbage")).as_deref(), Some("[]"));
        assert_eq!(stored_entities("Hi", None), None);
    }

    #[test]
    fn reply_quote_reaches_dart_with_the_text() {
        let reply = sync::envelope::ReplyRef { id: ID.into(), snippet: "earlier".into(), kind: "text".into() };
        let (kind, text, _, r, a, _) = decode_push(&sync::envelope::encode_text_full("answer", None, Some(reply)));
        assert_eq!((kind.as_str(), text.as_str(), a), ("text", "answer", None));
        assert!(r.unwrap().contains("earlier"));
        assert!(parse_reply(Some(r#"{"id":"bad id"}"#.into())).is_err());
    }
}

// ─── Safety number (backlog §6 item 49) ─────────────────────────────

/// The pair's safety number for a 1:1 chat: my identity key, the other
/// member's (from the MLS group, authenticated), and the 60-digit
/// number both sides compute alike.
pub struct SafetyInfo {
    pub my_key_hex: String,
    pub peer_key_hex: String,
    pub number: String,
}

/// Identity keys (hex) of everyone in a chat's MLS group, once each, mine
/// included (tech-debt 2.22 — the group's member list).
pub async fn sync_group_members(group_id_hex: String) -> Result<Vec<String>, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    let mut out: Vec<String> = Vec::new();
    for k in client.group_member_identities(&group_id).map_err(|e| e.to_string())? {
        let h = hex::encode(k);
        if !out.contains(&h) {
            out.push(h);
        }
    }
    Ok(out)
}

/// Safety number with one member of a group (tech-debt 2.27 — group
/// verification). The key must belong to a current member.
pub async fn sync_safety_number_with(group_id_hex: String, peer_key_hex: String) -> Result<SafetyInfo, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let peer = hex::decode(&peer_key_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    let me = hex::decode(client.identity_pubkey_hex()).map_err(|e| e.to_string())?;
    if peer == me {
        return Err("that's your own key".into());
    }
    let members = client.group_member_identities(&group_id).map_err(|e| e.to_string())?;
    if !members.contains(&peer) {
        return Err("not a member of this chat".into());
    }
    Ok(SafetyInfo {
        my_key_hex: hex::encode(&me),
        peer_key_hex: peer_key_hex.to_lowercase(),
        number: crypto::identity::safety_number(&me, &peer),
    })
}

pub async fn sync_safety_number(group_id_hex: String) -> Result<SafetyInfo, String> {
    let group_id = hex::decode(&group_id_hex).map_err(|e| e.to_string())?;
    let mut slot = sync_slot().lock().await;
    let client = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
    let me = hex::decode(client.identity_pubkey_hex()).map_err(|e| e.to_string())?;
    let members = client.group_member_identities(&group_id).map_err(|e| e.to_string())?;
    let others: Vec<Vec<u8>> = members.into_iter().filter(|k| *k != me).collect();
    let [peer] = others.as_slice() else {
        return Err(format!("expected one other member, found {}", others.len()));
    };
    Ok(SafetyInfo {
        my_key_hex: hex::encode(&me),
        peer_key_hex: hex::encode(peer),
        number: crypto::identity::safety_number(&me, peer),
    })
}


#[cfg(test)]
mod early_push_tests {
    use super::*;

    fn push(group: &[u8], sealed: bool, seq: u64) -> net::proto::Push {
        net::proto::Push {
            group_id: group.to_vec(),
            sealed_key_id: if sealed { vec![1] } else { Vec::new() },
            sequence: seq,
            ..Default::default()
        }
    }

    // Tech-debt 2.34 — a frame that overtook its group's Welcome waits for
    // the join instead of being dropped.
    #[test]
    fn frames_wait_for_their_group_and_come_back_in_order() {
        hold_early_push(push(b"group-a", false, 1));
        hold_early_push(push(b"", true, 2)); // sealed: its group shows when opened
        hold_early_push(push(b"group-b", false, 3));
        hold_early_push(push(b"group-a", false, 4));
        let a: Vec<u64> = take_early_pushes(b"group-a").iter().map(|p| p.sequence).collect();
        assert_eq!(a, vec![1, 2, 4]);
        assert!(take_early_pushes(b"group-a").is_empty(), "taken once");
        let b: Vec<u64> = take_early_pushes(b"group-b").iter().map(|p| p.sequence).collect();
        assert_eq!(b, vec![3]);
        for i in 0..(EARLY_MAX as u64 + 10) {
            hold_early_push(push(b"group-c", false, i));
        }
        let c = take_early_pushes(b"group-c");
        assert_eq!(c.len(), EARLY_MAX, "bounded");
        assert_eq!(c[0].sequence, 10, "the oldest go first");
    }
}

#[cfg(test)]
mod cancel_send_tests {
    use super::*;

    #[test]
    fn a_cancel_stops_that_send_once() {
        let id = "cancel-test-0001".to_string();
        assert!(!take_cancelled(&id));
        net_cancel_send(id.clone());
        assert!(take_cancelled(&id), "the send sees it");
        assert!(!take_cancelled(&id), "and only once — a retry under a new id isn't blocked");
    }

    #[tokio::test]
    async fn a_cancelled_send_never_encrypts() {
        let id = "cancel-test-0002".to_string();
        net_cancel_send(id.clone());
        // No sync client here: without the cancel this would fail with
        // "sync not initialised" — the cancel is checked first.
        let err = net_send_encrypted("00".repeat(16), b"hi".to_vec(), id).await.unwrap_err();
        assert_eq!(err, SEND_CANCELLED);
    }
}

#[cfg(test)]
mod video_note_tests {
    use super::*;

    fn round_video_json(round: bool) -> String {
        let (_, r) = sync::media::encrypt(b"mp4").unwrap();
        sync::envelope::media_to_json(&sync::envelope::MediaBody {
            kind: sync::envelope::MediaKind::Video as i32,
            file: Some(sync::envelope::MediaRef::from(&r)),
            mime_type: "video/mp4".into(),
            width: 480,
            height: 480,
            duration_ms: 7_000,
            round,
            ..Default::default()
        })
    }

    // ADR-048 — the bubble learns it's a round video from media_info.
    #[test]
    fn media_info_says_round() {
        let info = media_info(round_video_json(true)).unwrap();
        assert_eq!(info.kind, "video");
        assert!(info.round);
        assert_eq!((info.width, info.height, info.duration_ms), (480, 480, 7_000));
        assert!(!media_info(round_video_json(false)).unwrap().round);
    }

    // ADR-047 "Cancel sending" works for a round video too.
    #[tokio::test]
    async fn a_cancelled_round_video_never_uploads() {
        let id = "video-note-cancel-0001".to_string();
        net_cancel_send(id.clone());
        let err = net_send_video(
            "http://127.0.0.1:9".into(),
            "00".repeat(16),
            id,
            b"mp4".to_vec(),
            "video/mp4".into(),
            7_000,
            480,
            480,
            None,
            String::new(),
            None,
            true,
            0,
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(err, SEND_CANCELLED);
    }
}

#[cfg(test)]
mod push_preview_tests {
    use super::*;

    /// ADR-056 — only a real message gets a notification preview, and it
    /// says what kind it is.
    #[test]
    fn only_real_messages_get_a_preview() {
        assert_eq!(preview_of(&sync::envelope::encode_text("hi")), Some(("text".into(), "hi".into())));
        assert_eq!(preview_of(&sync::envelope::encode_typing(true)), None);
        assert_eq!(preview_of(&sync::envelope::encode_leave()), None);
        assert_eq!(preview_of(b"\xff\x01"), None);
    }

    /// storage-devices:17 — a disappearing message's text never sits in
    /// the notification list after it is gone from the chat.
    #[test]
    fn a_disappearing_message_has_no_text_in_its_preview() {
        let secret = sync::envelope::encode_text_expiring("код 4512", None, None, 30);
        assert_eq!(preview_of(&secret), Some(("text".into(), String::new())));
    }
}

/// The choice in `sealed_plan`: does a fetched key (week `w`) replace the one held (`old` = its week)?
fn takes_sealed_key(old: Option<u32>, week: u32, w: u32, signed: bool) -> bool {
    // Prefer this week's key over next week's, and the first row of a week:
    // the server lists the newest key first (ADR-084).
    let better = match old {
        // Also the first row of NEXT week when there is no key of this week.
        Some(old) if old == week || old == w => false,
        _ => w == week || w == week + 1,
    };
    // ADR-082: an unsigned key is the server's, not the person's —
    // never seal to it (the message then goes the plain way).
    better && signed
}

#[cfg(test)]
mod sealed_key_choice_tests {
    use super::*;

    /// Audit 2026-11b re-check of 0.12.0: the same for next week's keys when this week has none.
    #[test]
    fn newest_key_of_next_week_wins_too() {
        let week = 3000;
        let found = vec![(week + 1, vec![2u8; 32], true), (week + 1, vec![1u8; 32], true)];
        let mut cur: Option<(u32, Vec<u8>, bool)> = None;
        for (w, pk, signed) in found {
            if takes_sealed_key(cur.as_ref().map(|k| k.0), week, w, signed) {
                cur = Some((w, pk, signed));
            }
        }
        assert_eq!(cur.unwrap().1, vec![2u8; 32], "must seal to the newest key of next week");
        // This week's key still replaces a held next-week key.
        assert!(takes_sealed_key(Some(week + 1), week, week, true));
    }

    /// Security audit 2026-11b (keys-oldest-key-wins).
    #[test]
    fn newest_delivery_key_wins() {
        let week = 3000;
        // GET /v1/sealed-keys order: week ASC, created_at DESC — the new generation first.
        let found = vec![(week, vec![2u8; 32], true), (week, vec![1u8; 32], true), (week + 1, vec![3u8; 32], true)];
        let mut cur: Option<(u32, Vec<u8>, bool)> = None;
        for (w, pk, signed) in found {
            if takes_sealed_key(cur.as_ref().map(|k| k.0), week, w, signed) {
                cur = Some((w, pk, signed));
            }
        }
        assert_eq!(cur.unwrap().1, vec![2u8; 32], "must seal to the newest key of this week");
        // Unchanged: this week's key replaces next week's; an unsigned key is never taken.
        assert!(takes_sealed_key(Some(week + 1), week, week, true));
        assert!(!takes_sealed_key(None, week, week, false));
    }
}
