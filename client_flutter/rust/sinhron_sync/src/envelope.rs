// Application-message envelope — what goes INSIDE the MLS ciphertext.
// ADR-017.
//
// Before this, the MLS plaintext was bare UTF-8 text with no type or
// version, so nothing but text could be sent. Layout now:
//
//   0xFF  version(1)  protobuf(AppMessage)
//
// 0xFF can never start (or appear in) valid UTF-8, so a decoder tells
// envelopes from legacy text unambiguously: anything not starting with
// the marker is decoded as a legacy UTF-8 text message. A version this
// build doesn't know surfaces as `Decoded::Unsupported` ("update the
// app") instead of garbage.
//
// The schema lives here as prost derives (no .proto/codegen): it is
// client-to-client only — the server never sees it, it's encrypted.
// Field tags are the compatibility contract: never reuse or renumber.

use prost::Message;

use crate::media::{BlobRef, KEY_LEN};

pub const MARKER: u8 = 0xFF;
pub const VERSION: u8 = 1;

/// Upper bounds on attacker-controlled metadata. A peer can put
/// anything in the envelope; the UI must not choke on it.
pub const MAX_WAVEFORM_POINTS: usize = 256;
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
pub const MAX_FILE_NAME_BYTES: usize = 255;
/// ADR-019 — message actions.
pub const MAX_ID_BYTES: usize = 64;
pub const MAX_EMOJI_BYTES: usize = 32;
pub const MAX_SNIPPET_CHARS: usize = 200;
pub const MAX_RECEIPT_IDS: usize = 200;
/// Longest disappearing-message timer (4 weeks), backlog §6 item 51.
pub const MAX_EXPIRE_SECS: u32 = 28 * 24 * 3600;

#[derive(Clone, PartialEq, Message)]
pub struct AppMessage {
    #[prost(oneof = "app_message::Body", tags = "1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 40, 41")]
    pub body: Option<app_message::Body>,
    /// ADR-019 — the message this one answers (Text / Media only).
    #[prost(message, optional, tag = "8")]
    pub reply_to: Option<ReplyRef>,
    /// Disappearing messages: seconds this message lives after it
    /// arrives (0 = keeps). Text / Media only.
    #[prost(uint32, tag = "9")]
    pub expire_secs: u32,
}

pub mod app_message {
    #[derive(Clone, PartialEq, prost::Oneof)]
    pub enum Body {
        #[prost(message, tag = "1")]
        Text(super::TextBody),
        #[prost(message, tag = "2")]
        Media(super::MediaBody),
        /// ADR-019 — actions on an earlier message, addressed by its
        /// wire message id (the UUID both sides already know).
        #[prost(message, tag = "3")]
        Reaction(super::Reaction),
        #[prost(message, tag = "4")]
        Edit(super::Edit),
        #[prost(message, tag = "5")]
        Delete(super::Delete),
        #[prost(message, tag = "6")]
        Receipt(super::Receipt),
        #[prost(message, tag = "7")]
        Typing(super::Typing),
        /// The chat's disappearing-message timer changed.
        #[prost(message, tag = "10")]
        Timer(super::Timer),
        /// Tech-debt 2.2 — the sender's sealed-sender access key, for the
        /// other members (lets them deliver to the sender without
        /// authenticating to the server).
        #[prost(message, tag = "11")]
        Access(super::Access),
        /// ADR-025 — recent messages of a chat, from one of the person's
        /// devices to a newly added one (sealed to their own key only).
        #[prost(message, tag = "12")]
        History(super::History),
        /// The sender's display name, so group members see who wrote what
        /// (tech-debt 2.22). Sent once per chat and again when it changes.
        #[prost(message, tag = "13")]
        Profile(super::Profile),
        /// Pin / unpin a message for everyone in the chat (tech-debt 2.22).
        #[prost(message, tag = "14")]
        Pin(super::Pin),
        /// The sender took a screenshot of this chat (ADR-030; sent only
        /// for chats with disappearing messages).
        #[prost(message, tag = "15")]
        Screenshot(super::Screenshot),
        /// "Online" / "last seen" for my contacts (ADR-031) — sent only into
        /// personal chats, only when the sender turned it on. Ephemeral.
        #[prost(message, tag = "16")]
        Presence(super::Presence),
        /// ADR-034 — the group's name: sent by its creator right after the
        /// Welcome (and again to people added later). Older clients ignore it.
        #[prost(message, tag = "17")]
        GroupName(super::GroupName),
        /// ADR-035 — the sender leaves the group; a remaining member commits
        /// their removal (MLS can't commit its own). Older clients ignore it.
        #[prost(message, tag = "18")]
        Leave(super::Leave),
        /// ADR-035 — the sender (the group's admin) removed these people;
        /// sent after the Commit, so only the remaining members read it.
        #[prost(message, tag = "19")]
        MembersRemoved(super::MembersRemoved),
        /// ADR-064 — a full device transfer is ready for my new device (or
        /// its media are). Only in my own-devices group, sealed to my own key.
        #[prost(message, tag = "40")]
        Transfer(super::Transfer),
        /// ADR-064 — what changed on my other device (contacts, packs,
        /// settings…). Only in my own-devices group, sealed to my own key.
        #[prost(message, tag = "41")]
        DeviceSync(super::DeviceSync),
    }
}

/// ADR-064 — [`Transfer::stage`] values.
pub const TRANSFER_OFFER: u32 = 1;
pub const TRANSFER_MEDIA_DONE: u32 = 2;
pub const TRANSFER_CANCELLED: u32 = 3;

/// ADR-064 — the old device tells the new one where its transfer is. The
/// manifest (an encrypted blob on the server, like media) lists the parts
/// and their keys; the key to the manifest is only here, inside MLS.
#[derive(Clone, PartialEq, Message)]
pub struct Transfer {
    /// Random id of this transfer (a UUID).
    #[prost(string, tag = "1")]
    pub id: String,
    /// The device it is for (its leaf key); my other devices ignore it.
    #[prost(bytes = "vec", tag = "2")]
    pub target_device: Vec<u8>,
    #[prost(uint32, tag = "3")]
    pub stage: u32,
    /// Stage 1: the manifest.
    #[prost(message, optional, tag = "4")]
    pub manifest: Option<MediaRef>,
    /// Messages in the transfer (for the progress screen).
    #[prost(uint64, tag = "5")]
    pub messages: u64,
    /// Media files the messages point to.
    #[prost(uint64, tag = "6")]
    pub media: u64,
    /// Stage 2: files neither the server nor the old device still had.
    #[prost(uint64, tag = "7")]
    pub media_missing: u64,
}

/// Most items in one [`DeviceSync`]; longest key and value.
pub const MAX_SYNC_ITEMS: usize = 500;
pub const MAX_SYNC_KEY_BYTES: usize = 200;
pub const MAX_SYNC_VALUE_BYTES: usize = 64 * 1024;

/// ADR-064 — changes for my other devices (`sinhron_storage::devsync`).
#[derive(Clone, PartialEq, Message)]
pub struct DeviceSync {
    #[prost(message, repeated, tag = "1")]
    pub items: Vec<SyncEntry>,
}

#[derive(Clone, PartialEq, Message)]
pub struct SyncEntry {
    #[prost(string, tag = "1")]
    pub key: String,
    /// Wall-clock ms of the change (last writer wins).
    #[prost(int64, tag = "2")]
    pub ts: i64,
    #[prost(bool, tag = "3")]
    pub deleted: bool,
    #[prost(string, tag = "4")]
    pub value: String,
}

/// Most messages in one history bundle.
pub const MAX_HISTORY_ITEMS: usize = 50;

/// A chat's recent messages for the person's new device (ADR-025).
#[derive(Clone, PartialEq, Message)]
pub struct History {
    #[prost(message, repeated, tag = "1")]
    pub items: Vec<HistoryItem>,
    /// The chat's name on the sending device (the new one only has a
    /// placeholder) and whether it's a group.
    #[prost(string, tag = "2")]
    pub chat_name: String,
    #[prost(bool, tag = "3")]
    pub is_group: bool,
    /// ADR-055 — this chat is the person's "Saved messages" (a group of
    /// only their own devices). Such a bundle may carry no messages: it
    /// still tells the new device which chat it is. Older clients reject
    /// an empty bundle and read a non-empty one as plain history.
    #[prost(bool, tag = "4")]
    pub saved: bool,
}

#[derive(Clone, PartialEq, Message, serde::Serialize)]
pub struct HistoryItem {
    #[prost(string, tag = "1")]
    pub wire_id: String,
    #[prost(int64, tag = "2")]
    pub ts: i64,
    /// `text` / `photo` / `voice` / `document` / `video`.
    #[prost(string, tag = "3")]
    pub kind: String,
    #[prost(string, tag = "4")]
    pub text: String,
    /// Media envelope JSON as stored (keys + blob refs); empty for text.
    #[prost(string, tag = "5")]
    pub media_json: String,
    /// Author's identity key (hex) — ours or a chat partner's.
    #[prost(string, tag = "6")]
    pub sender: String,
    /// ADR-070 — formatting of `text` (in JSON for Dart: `entities`, null =
    /// not `rich`, i.e. an older app's message).
    #[prost(message, repeated, tag = "20")]
    #[serde(skip)]
    pub entities: Vec<TextEntity>,
    #[prost(bool, tag = "21")]
    #[serde(skip)]
    pub rich: bool,
}

/// Longest display name in a [`Profile`] (characters).
pub const MAX_PROFILE_NAME_CHARS: usize = 64;

/// Longest bio in a [`Profile`] (characters); a longer one is cut.
pub const MAX_PROFILE_BIO_CHARS: usize = 200;

/// The sender's chosen display name (tech-debt 2.22).
#[derive(Clone, PartialEq, Message)]
pub struct Profile {
    #[prost(string, tag = "1")]
    pub name: String,
    /// Tech-debt 2.21 — the sender's photo as a small JPEG (≤ 32 KB, made by
    /// `photo::prepare`); empty = no photo. Receivers re-encode it again.
    #[prost(bytes = "vec", tag = "2")]
    pub avatar: Vec<u8>,
    /// ADR-052 — the sender's bio ("About"), one line, ≤ [`MAX_PROFILE_BIO_CHARS`];
    /// empty = none. Older clients ignore the field.
    #[prost(string, tag = "3")]
    pub bio: String,
}

/// "I took a screenshot of this chat" (ADR-030), or — `recording` — "I am
/// recording (or mirroring) the screen with this chat open". Older clients
/// ignore the field and show a screenshot notice, which is still true enough.
#[derive(Clone, PartialEq, Message)]
pub struct Screenshot {
    #[prost(bool, tag = "1")]
    pub recording: bool,
}

/// ADR-031 — "I am online" (`online`), "I just left" (`!online`), or
/// `hidden`: "I turned this off — forget when you last saw me". Never
/// stored as a message; the receiver keeps only a last-seen time.
#[derive(Clone, PartialEq, Message)]
pub struct Presence {
    #[prost(bool, tag = "1")]
    pub online: bool,
    #[prost(bool, tag = "2")]
    pub hidden: bool,
}

/// ADR-035 — "I leave this group".
#[derive(Clone, PartialEq, Message)]
pub struct Leave {}

/// ADR-035 — identity keys (32 bytes each) of the people removed.
#[derive(Clone, PartialEq, Message)]
pub struct MembersRemoved {
    #[prost(bytes = "vec", repeated, tag = "1")]
    pub identities: Vec<Vec<u8>>,
}

/// Most people one removal names.
pub const MAX_REMOVED_PEOPLE: usize = 64;

/// ADR-034 — a group chat's name (cleaned like a display name).
#[derive(Clone, PartialEq, Message)]
pub struct GroupName {
    #[prost(string, tag = "1")]
    pub name: String,
}

/// Pin (`pinned = true`) or unpin a message, addressed by its wire id.
#[derive(Clone, PartialEq, Message)]
pub struct Pin {
    #[prost(string, tag = "1")]
    pub target: String,
    #[prost(bool, tag = "2")]
    pub pinned: bool,
}

/// A display name as shown to others: trimmed, control characters
/// removed, at most [`MAX_PROFILE_NAME_CHARS`]; `None` if nothing is left.
pub fn clean_profile_name(name: &str) -> Option<String> {
    let cleaned = strip_invisible(name);
    let t = cleaned.trim();
    (looks_visible(t) && t.chars().count() <= MAX_PROFILE_NAME_CHARS).then(|| t.to_string())
}

/// ADR-052 — a bio as it may be shown: the same invisible / control
/// characters as a name are dropped, line breaks become spaces, at most
/// [`MAX_PROFILE_BIO_CHARS`] characters (cut, not refused — the name in the
/// same `profile` still counts). Blank → empty.
pub fn clean_profile_bio(bio: &str) -> String {
    let line_break = |c: char| matches!(c, '\n' | '\r' | '\t' | '\u{2028}' | '\u{2029}');
    let one_line: String = bio.chars().map(|c| if line_break(c) { ' ' } else { c }).collect();
    let cleaned = strip_invisible(&one_line);
    let t = cleaned.trim();
    if !looks_visible(t) {
        return String::new();
    }
    t.chars().take(MAX_PROFILE_BIO_CHARS).collect::<String>().trim_end().to_string()
}

/// A file name from someone else as it may be shown: "photo\u{202E}gpj.exe"
/// must not read as "photoexe.jpg" (security-review-2026-11 app-surface:6).
pub fn clean_file_name(name: &str) -> String {
    strip_invisible(name).trim().to_string()
}

/// Control characters, bidi overrides / marks, zero-width and other
/// invisible format characters, line separators removed: text from someone
/// else must not be able to reorder, break or hide text around it in the UI.
fn strip_invisible(text: &str) -> String {
    let invisible = |c: char| {
        matches!(c,
            '\u{00AD}' | '\u{061C}' | '\u{180E}'
            | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}' | '\u{2060}'..='\u{206F}'
            | '\u{FE00}'..='\u{FE0E}' | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}'
            | '\u{E0000}'..='\u{E007F}')
    };
    text.chars().filter(|c| !c.is_control() && !invisible(*c)).collect()
}

/// Has something you can see — not only spaces or characters that look
/// like nothing but aren't whitespace.
fn looks_visible(text: &str) -> bool {
    let blank = |c: char| matches!(c, '\u{115F}' | '\u{1160}' | '\u{3164}' | '\u{FFA0}' | '\u{2800}');
    text.chars().any(|c| !c.is_whitespace() && !blank(c))
}

/// Length of a sealed-sender access key.
pub const ACCESS_KEY_LEN: usize = 16;

/// The sender's access key (tech-debt 2.2).
#[derive(Clone, PartialEq, Message)]
pub struct Access {
    #[prost(bytes = "vec", tag = "1")]
    pub key: Vec<u8>,
}

/// New disappearing-message timer for the chat (0 = off).
#[derive(Clone, PartialEq, Message)]
pub struct Timer {
    #[prost(uint32, tag = "1")]
    pub secs: u32,
}

/// Quote of the replied-to message. The snippet travels with the reply
/// so it renders even if the original isn't on this device.
#[derive(Clone, PartialEq, Message)]
pub struct ReplyRef {
    #[prost(string, tag = "1")]
    pub id: String,
    #[prost(string, tag = "2")]
    pub snippet: String,
    /// "text" / "photo" / "voice" / "document" / "video".
    #[prost(string, tag = "3")]
    pub kind: String,
}

/// Set (or with an empty emoji, remove) the sender's reaction.
#[derive(Clone, PartialEq, Message)]
pub struct Reaction {
    #[prost(string, tag = "1")]
    pub target: String,
    #[prost(string, tag = "2")]
    pub emoji: String,
}

/// Replace the text of the sender's own earlier text message.
#[derive(Clone, PartialEq, Message)]
pub struct Edit {
    #[prost(string, tag = "1")]
    pub target: String,
    #[prost(string, tag = "2")]
    pub text: String,
    /// ADR-070 — as in [`TextBody`].
    #[prost(message, repeated, tag = "3")]
    pub entities: Vec<TextEntity>,
    #[prost(bool, tag = "4")]
    pub rich: bool,
}

/// Delete the sender's own earlier message for everyone.
#[derive(Clone, PartialEq, Message)]
pub struct Delete {
    #[prost(string, tag = "1")]
    pub target: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum ReceiptKind {
    Unspecified = 0,
    Delivered = 1,
    Read = 2,
}

/// Delivery / read receipts for a batch of the recipient's messages.
#[derive(Clone, PartialEq, Message)]
pub struct Receipt {
    #[prost(enumeration = "ReceiptKind", tag = "1")]
    pub kind: i32,
    #[prost(string, repeated, tag = "2")]
    pub ids: Vec<String>,
}

/// "Typing…" — ephemeral, never stored.
#[derive(Clone, PartialEq, Message)]
pub struct Typing {
    #[prost(bool, tag = "1")]
    pub active: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct TextBody {
    #[prost(string, tag = "1")]
    pub text: String,
    /// Sender-generated preview of a URL in `text` (ADR-018).
    #[prost(message, optional, tag = "2")]
    pub link_preview: Option<LinkPreview>,
    /// ADR-070 — formatting of `text` (bold, links, quotes…), which itself
    /// stays clean: search, previews and older apps see plain words.
    #[prost(message, repeated, tag = "3")]
    pub entities: Vec<TextEntity>,
    /// ADR-070 — `entities` is the whole formatting (none = plain text):
    /// don't read `*stars*` in `text` as markers, the way 0.6.0 did.
    #[prost(bool, tag = "4")]
    pub rich: bool,
}

#[derive(Clone, PartialEq, Message)]
pub struct LinkPreview {
    /// Must appear verbatim in the message text.
    #[prost(string, tag = "1")]
    pub url: String,
    #[prost(string, tag = "2")]
    pub title: String,
    #[prost(string, tag = "3")]
    pub description: String,
    /// Re-encoded preview image, padded 32 KiB blob.
    #[prost(message, optional, tag = "4")]
    pub image: Option<MediaRef>,
}

/// ADR-070 — one formatted range of a message's text, Telegram-style.
/// `offset` / `length` count UTF-16 code units (what the app's strings
/// use, and what Telegram counts). The text itself stays clean.
#[derive(Clone, PartialEq, Eq, Message)]
pub struct TextEntity {
    /// One of the `ENTITY_*` kinds; an unknown one is dropped on receipt.
    #[prost(uint32, tag = "1")]
    pub kind: u32,
    #[prost(uint32, tag = "2")]
    pub offset: u32,
    #[prost(uint32, tag = "3")]
    pub length: u32,
    /// [`ENTITY_LINK`] only: where the words lead.
    #[prost(string, tag = "4")]
    pub url: String,
    /// [`ENTITY_PRE`] only: the code's language ("rust"), may be empty.
    #[prost(string, tag = "5")]
    pub language: String,
}

pub const ENTITY_BOLD: u32 = 1;
pub const ENTITY_ITALIC: u32 = 2;
pub const ENTITY_UNDERLINE: u32 = 3;
pub const ENTITY_STRIKE: u32 = 4;
/// Inline monospace.
pub const ENTITY_CODE: u32 = 5;
/// A code block (whole lines).
pub const ENTITY_PRE: u32 = 6;
pub const ENTITY_SPOILER: u32 = 7;
/// Words that lead to `url` (the address isn't in the text).
pub const ENTITY_LINK: u32 = 8;
/// A quote block (whole lines).
pub const ENTITY_QUOTE: u32 = 9;

/// Most formatted ranges in one message; more are dropped.
pub const MAX_ENTITIES: usize = 1000;
pub const MAX_ENTITY_URL_BYTES: usize = 2048;
pub const MAX_ENTITY_LANGUAGE_BYTES: usize = 32;

/// Names of the kinds in the app's JSON (`entities_json`).
const ENTITY_NAMES: &[(u32, &str)] = &[
    (ENTITY_BOLD, "bold"),
    (ENTITY_ITALIC, "italic"),
    (ENTITY_UNDERLINE, "underline"),
    (ENTITY_STRIKE, "strike"),
    (ENTITY_CODE, "code"),
    (ENTITY_PRE, "pre"),
    (ENTITY_SPOILER, "spoiler"),
    (ENTITY_LINK, "link"),
    (ENTITY_QUOTE, "quote"),
];

/// A link target we open: web, mail, phone. Anything else (javascript:,
/// file:, intent:, app schemes) is dropped — the words stay.
pub fn entity_url_ok(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    !url.is_empty()
        && url.len() <= MAX_ENTITY_URL_BYTES
        && !url.chars().any(|c| c.is_control() || c.is_whitespace())
        && ["https://", "http://", "mailto:", "tel:"].iter().any(|p| lower.starts_with(p) && lower.len() > p.len())
}

/// ADR-070 — a peer's formatting, made safe for `text`: ranges inside the
/// text on whole characters (never half an emoji), known kinds only, a
/// link only to web / mail / phone, a short plain language name, at most
/// [`MAX_ENTITIES`]; sorted. Anything else is dropped — the text stays.
pub fn clean_entities(text: &str, entities: Vec<TextEntity>) -> Vec<TextEntity> {
    // UTF-16 positions where a character starts (plus the end).
    let mut starts = Vec::with_capacity(text.len() + 1);
    let mut at = 0u32;
    for c in text.chars() {
        starts.push(at);
        at += c.len_utf16() as u32;
    }
    let len = at;
    let on_char = |p: u32| p == len || starts.binary_search(&p).is_ok();
    let mut out: Vec<TextEntity> = entities
        .into_iter()
        .filter(|e| ENTITY_NAMES.iter().any(|(k, _)| *k == e.kind))
        .filter(|e| e.length > 0 && e.offset.checked_add(e.length).is_some_and(|end| end <= len))
        .filter(|e| on_char(e.offset) && on_char(e.offset + e.length))
        .filter(|e| e.kind != ENTITY_LINK || entity_url_ok(&e.url))
        .map(|mut e| {
            if e.kind != ENTITY_LINK {
                e.url.clear();
            }
            let lang_ok = e.language.len() <= MAX_ENTITY_LANGUAGE_BYTES
                && e.language.bytes().all(|b| b.is_ascii_alphanumeric() || b"+#._-".contains(&b));
            if e.kind != ENTITY_PRE || !lang_ok {
                e.language.clear();
            }
            e
        })
        .take(MAX_ENTITIES)
        .collect();
    out.sort_by_key(|e| (e.offset, std::cmp::Reverse(e.length), e.kind));
    out.dedup();
    out
}

/// The app's JSON form of one range: `{"t":"bold","o":0,"l":4}` plus
/// `"url"` (links) / `"lang"` (code blocks).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct EntityJson {
    t: String,
    o: u32,
    l: u32,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    url: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    lang: String,
}

/// `entities_json` for the app (always a JSON array, `[]` = no formatting).
pub fn entities_to_json(entities: &[TextEntity]) -> String {
    let items: Vec<EntityJson> = entities
        .iter()
        .filter_map(|e| {
            let (_, name) = ENTITY_NAMES.iter().find(|(k, _)| *k == e.kind)?;
            Some(EntityJson { t: (*name).into(), o: e.offset, l: e.length, url: e.url.clone(), lang: e.language.clone() })
        })
        .collect();
    serde_json::to_string(&items).expect("plain struct serializes")
}

/// Parse the app's `entities_json` and [`clean_entities`] it for `text`.
/// Unknown kind names are skipped (a newer app's JSON).
pub fn entities_from_json(text: &str, json: &str) -> Result<Vec<TextEntity>, EnvelopeError> {
    let items: Vec<EntityJson> = serde_json::from_str(json).map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
    let raw = items
        .into_iter()
        .filter_map(|j| {
            let (kind, _) = ENTITY_NAMES.iter().find(|(_, n)| *n == j.t)?;
            Some(TextEntity { kind: *kind, offset: j.o, length: j.l, url: j.url, language: j.lang })
        })
        .collect();
    Ok(clean_entities(text, raw))
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, prost::Enumeration)]
#[repr(i32)]
pub enum MediaKind {
    Unspecified = 0,
    Photo = 1,
    Voice = 2,
    Document = 3,
    Video = 4,
}

#[derive(Clone, PartialEq, Message)]
pub struct MediaBody {
    #[prost(enumeration = "MediaKind", tag = "1")]
    pub kind: i32,
    /// The full file.
    #[prost(message, optional, tag = "2")]
    pub file: Option<MediaRef>,
    /// Small encrypted preview (≤32 KB, spec §11.2) — photos.
    #[prost(message, optional, tag = "3")]
    pub thumbnail: Option<MediaRef>,
    #[prost(string, tag = "4")]
    pub mime_type: String,
    /// Original name — documents only.
    #[prost(string, tag = "5")]
    pub file_name: String,
    /// Instant placeholder before the thumbnail arrives (spec §8.6).
    #[prost(string, tag = "6")]
    pub blurhash: String,
    #[prost(uint32, tag = "7")]
    pub width: u32,
    #[prost(uint32, tag = "8")]
    pub height: u32,
    #[prost(uint32, tag = "9")]
    pub duration_ms: u32,
    /// Voice: amplitude per point, 0-255, ≤ MAX_WAVEFORM_POINTS.
    #[prost(bytes = "vec", tag = "10")]
    pub waveform: Vec<u8>,
    #[prost(string, tag = "11")]
    pub caption: String,
    /// Photos/videos sent together share an album id (one grid bubble).
    #[prost(string, tag = "12")]
    pub album_id: String,
    /// Video only (ADR-048): a round video message ("кружок") — square,
    /// ≤60 s, shown as a circle that plays muted inline. Older apps don't
    /// know the field and show a normal video.
    #[prost(bool, tag = "13")]
    pub round: bool,
    /// ADR-049 — this photo is a sticker. Older apps ignore the field and
    /// show the still picture in `file` / `thumbnail` as a photo. (Tag 13
    /// is the round-video flag, ADR-048.)
    #[prost(message, optional, tag = "14")]
    pub sticker: Option<Sticker>,
    /// ADR-070 — formatting of `caption`, as in [`TextBody`] (tags 20+ so
    /// the media fields 15–19 stay free for other features).
    #[prost(message, repeated, tag = "20")]
    pub caption_entities: Vec<TextEntity>,
    #[prost(bool, tag = "21")]
    pub caption_rich: bool,
}

/// ADR-049 — sticker formats.
pub const STICKER_FORMATS: &[&str] = &["webp", "png", "tgs", "webm"];

/// True for the formats that move (Lottie `.tgs`, `.webm` video).
pub fn sticker_is_animated(format: &str) -> bool {
    matches!(format, "tgs" | "webm")
}

/// ADR-049 — what makes a photo a sticker. For an animated one the
/// MediaBody's `file` is a still PNG (what older apps show) and the moving
/// file is [`Sticker::animation`].
#[derive(Clone, PartialEq, Message)]
pub struct Sticker {
    /// The emoji the sticker stands for (search, notifications, quotes).
    #[prost(string, tag = "1")]
    pub emoji: String,
    /// One of [`STICKER_FORMATS`].
    #[prost(string, tag = "2")]
    pub format: String,
    #[prost(message, optional, tag = "3")]
    pub animation: Option<MediaRef>,
    /// The pack it came from, so the receiver can add it.
    #[prost(message, optional, tag = "4")]
    pub pack: Option<PackRef>,
}

/// A sticker pack: built-in ones (`sinhron.` ids) by id alone, the
/// person's own ones with the encrypted pack file (`sticker::PackFile`).
#[derive(Clone, PartialEq, Message)]
pub struct PackRef {
    #[prost(string, tag = "1")]
    pub id: String,
    #[prost(string, tag = "2")]
    pub title: String,
    #[prost(message, optional, tag = "3")]
    pub file: Option<MediaRef>,
    #[prost(uint32, tag = "4")]
    pub count: u32,
}

/// Pack ids: `sinhron.<name>` built in, `u<hex>` made on a phone.
pub fn valid_pack_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_BYTES
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

/// A built-in pack every Sinhron app ships.
pub fn is_builtin_pack(id: &str) -> bool {
    id.starts_with("sinhron.")
}

/// A peer's pack reference, cleaned; None if unusable.
pub fn clean_pack_ref(p: PackRef) -> Option<PackRef> {
    if !valid_pack_id(&p.id) || p.count as usize > crate::sticker::MAX_PACK_STICKERS {
        return None;
    }
    if let Some(f) = &p.file {
        BlobRef::try_from(f).ok()?;
        if f.blob_size > crate::sticker::MAX_PACK_BYTES as u64 + 64 {
            return None;
        }
    } else if !is_builtin_pack(&p.id) {
        return None;
    }
    let title = clean_profile_name(&p.title)?;
    Some(PackRef { title, ..p })
}

/// The biggest encrypted blob an honest sticker / thumbnail is. Both are
/// fetched without a tap, so a bigger one is refused (audit 2026-11b M01).
const BLOB_EXTRA: u64 = (crate::media::NONCE_LEN + crate::media::TAG_LEN) as u64;
const MAX_STICKER_BLOB: u64 = crate::sticker::MAX_STICKER_BYTES as u64 + BLOB_EXTRA;
const MAX_THUMBNAIL_BLOB: u64 = crate::media::MAX_THUMBNAIL_BYTES as u64 + BLOB_EXTRA;

/// A peer's sticker info, cleaned: a malformed one is dropped (the
/// message still shows as its still picture), a bad pack just goes.
fn clean_sticker(s: Sticker) -> Option<Sticker> {
    if !STICKER_FORMATS.contains(&s.format.as_str()) {
        return None;
    }
    if !(s.emoji.is_empty() || valid_emoji(&s.emoji)) {
        return None;
    }
    match (&s.animation, sticker_is_animated(&s.format)) {
        (Some(a), true) => {
            BlobRef::try_from(a).ok()?;
            if a.plain_size > crate::sticker::MAX_STICKER_BYTES as u64 || a.blob_size > MAX_STICKER_BLOB {
                return None;
            }
        }
        (None, false) => {}
        _ => return None,
    }
    Some(Sticker { pack: s.pack.and_then(clean_pack_ref), ..s })
}

/// The message kind a media body is stored as: `sticker` for a sticker,
/// else its media kind (`photo`, `voice`…).
pub fn message_kind(m: &MediaBody) -> &'static str {
    if m.sticker.is_some() {
        "sticker"
    } else {
        kind_name(m.kind)
    }
}

/// History bundles carry stickers as `photo` (an older app rejects a
/// bundle with a kind it doesn't know); this turns them back.
pub fn stored_kind(kind: &str, media_json: &str) -> String {
    if kind == "photo" && media_from_json(media_json).is_ok_and(|m| m.sticker.is_some()) {
        "sticker".into()
    } else {
        kind.into()
    }
}

#[derive(Clone, PartialEq, Message)]
pub struct MediaRef {
    #[prost(bytes = "vec", tag = "1")]
    pub sha256: Vec<u8>,
    #[prost(bytes = "vec", tag = "2")]
    pub key: Vec<u8>,
    #[prost(uint64, tag = "3")]
    pub blob_size: u64,
    #[prost(uint64, tag = "4")]
    pub plain_size: u64,
}

impl From<&BlobRef> for MediaRef {
    fn from(r: &BlobRef) -> Self {
        Self {
            sha256: r.sha256.to_vec(),
            key: r.key.to_vec(),
            blob_size: r.blob_size,
            plain_size: r.plain_size,
        }
    }
}

impl TryFrom<&MediaRef> for BlobRef {
    type Error = EnvelopeError;
    fn try_from(m: &MediaRef) -> Result<Self, EnvelopeError> {
        Ok(BlobRef {
            sha256: m
                .sha256
                .as_slice()
                .try_into()
                .map_err(|_| EnvelopeError::Invalid("sha256 must be 32 bytes"))?,
            key: <[u8; KEY_LEN]>::try_from(m.key.as_slice())
                .map_err(|_| EnvelopeError::Invalid("media key must be 32 bytes"))?,
            blob_size: m.blob_size,
            plain_size: m.plain_size,
        })
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum EnvelopeError {
    #[error("malformed envelope: {0}")]
    Malformed(String),
    #[error("invalid envelope: {0}")]
    Invalid(&'static str),
}

/// What an incoming plaintext turned out to be.
#[derive(Debug, Clone, PartialEq)]
pub enum Decoded {
    Text(String),
    /// Text with a valid sender-side link preview.
    Link { text: String, preview: LinkPreview },
    Media(MediaBody),
    Reaction { target: String, emoji: String },
    Edit { target: String, text: String },
    Delete { target: String },
    Receipt { read: bool, ids: Vec<String> },
    Typing { active: bool },
    Timer { secs: u32 },
    /// Tech-debt 2.22 — the sender's display name (already cleaned), photo
    /// and (ADR-052) bio (cleaned, '' = none).
    Profile { name: String, avatar: Vec<u8>, bio: String },
    /// Tech-debt 2.22 — pin / unpin a message for the whole chat.
    Pin { target: String, pinned: bool },
    /// ADR-030 — the sender took a screenshot of the chat (or, `recording`,
    /// is recording the screen while it is open).
    Screenshot { recording: bool },
    /// ADR-031 — the sender's online state (`hidden` wins over `online`).
    Presence { online: bool, hidden: bool },
    /// ADR-034 — the group's name (already cleaned).
    GroupName { name: String },
    /// ADR-035 — the sender leaves the group.
    Leave,
    /// ADR-035 — the sender removed these people (identity keys).
    MembersRemoved { identities: Vec<[u8; 32]> },
    /// Tech-debt 2.2 — the sender's sealed-sender access key.
    Access { key: Vec<u8> },
    /// ADR-025 — a chat's recent messages for our new device, with its name;
    /// `saved` — it's my "Saved messages" chat (ADR-055).
    History { items: Vec<HistoryItem>, chat_name: String, is_group: bool, saved: bool },
    /// ADR-064 — a device transfer (stage 1: offer with the manifest; 2: its
    /// media are on the server; 3: cancelled).
    Transfer(Transfer),
    /// ADR-064 — changes from my other device.
    DeviceSync { items: Vec<SyncEntry> },
    /// Envelope from a newer client this build can't read.
    Unsupported { version: u8 },
}

/// A decoded message plus the quote it replies to (Text / Media only).
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedMessage {
    pub decoded: Decoded,
    pub reply_to: Option<ReplyRef>,
    /// Disappearing timer carried by a Text / Media message (0 = none).
    pub expire_secs: u32,
    /// ADR-070 — formatting of a Text / Link message, a Media caption or an
    /// Edit, already [`clean_entities`]-ed. None: an older app sent it (its
    /// `*stars*` may be markers).
    pub entities: Option<Vec<TextEntity>>,
}

pub fn encode_text(text: &str) -> Vec<u8> {
    encode(app_message::Body::Text(TextBody { text: text.to_string(), link_preview: None, ..Default::default() }))
}

pub fn encode_text_with_preview(text: &str, preview: LinkPreview) -> Vec<u8> {
    encode(app_message::Body::Text(TextBody { text: text.to_string(), link_preview: Some(preview), ..Default::default() }))
}

/// Text, optional link preview, optional reply quote.
pub fn encode_text_full(text: &str, preview: Option<LinkPreview>, reply_to: Option<ReplyRef>) -> Vec<u8> {
    encode_text_expiring(text, preview, reply_to, 0)
}

/// [`encode_text_full`] that disappears `expire_secs` after arrival.
pub fn encode_text_expiring(
    text: &str,
    preview: Option<LinkPreview>,
    reply_to: Option<ReplyRef>,
    expire_secs: u32,
) -> Vec<u8> {
    encode_full(
        app_message::Body::Text(TextBody { text: text.to_string(), link_preview: preview, ..Default::default() }),
        reply_to,
        expire_secs,
    )
}

/// ADR-070 — [`encode_text_expiring`] with its formatting (`rich`: the
/// receiver reads no markers in the text; `entities` may be empty).
pub fn encode_text_rich(
    text: &str,
    entities: Vec<TextEntity>,
    preview: Option<LinkPreview>,
    reply_to: Option<ReplyRef>,
    expire_secs: u32,
) -> Vec<u8> {
    encode_full(
        app_message::Body::Text(TextBody {
            text: text.to_string(),
            link_preview: preview,
            entities: clean_entities(text, entities),
            rich: true,
        }),
        reply_to,
        expire_secs,
    )
}

pub fn encode_media_reply(media: MediaBody, reply_to: Option<ReplyRef>) -> Vec<u8> {
    encode_media_expiring(media, reply_to, 0)
}

pub fn encode_media_expiring(media: MediaBody, reply_to: Option<ReplyRef>, expire_secs: u32) -> Vec<u8> {
    encode_full(app_message::Body::Media(media), reply_to, expire_secs)
}

pub fn encode_timer(secs: u32) -> Vec<u8> {
    encode(app_message::Body::Timer(Timer { secs }))
}

pub fn encode_profile(name: &str, avatar: &[u8], bio: &str) -> Vec<u8> {
    encode(app_message::Body::Profile(Profile {
        name: name.to_string(),
        avatar: avatar.to_vec(),
        bio: clean_profile_bio(bio),
    }))
}

/// ADR-034 — the group's name.
/// ADR-035 — "I leave this group".
pub fn encode_leave() -> Vec<u8> {
    encode(app_message::Body::Leave(Leave {}))
}

/// ADR-035 — "I removed these people" (identity keys).
pub fn encode_members_removed(identities: &[[u8; 32]]) -> Vec<u8> {
    encode(app_message::Body::MembersRemoved(MembersRemoved { identities: identities.iter().map(|i| i.to_vec()).collect() }))
}

pub fn encode_group_name(name: &str) -> Vec<u8> {
    encode(app_message::Body::GroupName(GroupName { name: name.to_string() }))
}

pub fn encode_screenshot(recording: bool) -> Vec<u8> {
    encode(app_message::Body::Screenshot(Screenshot { recording }))
}

pub fn encode_presence(online: bool, hidden: bool) -> Vec<u8> {
    // Hidden means "not online" — never both.
    encode(app_message::Body::Presence(Presence { online: online && !hidden, hidden }))
}

pub fn encode_pin(target: &str, pinned: bool) -> Vec<u8> {
    encode(app_message::Body::Pin(Pin { target: target.into(), pinned }))
}

pub fn encode_access(key: &[u8]) -> Vec<u8> {
    encode(app_message::Body::Access(Access { key: key.to_vec() }))
}

pub fn encode_history(items: Vec<HistoryItem>, chat_name: &str, is_group: bool, saved: bool) -> Vec<u8> {
    encode(app_message::Body::History(History { items, chat_name: chat_name.to_string(), is_group, saved }))
}

/// ADR-064 — a device transfer message (see [`Transfer`]).
pub fn encode_transfer(t: Transfer) -> Vec<u8> {
    encode(app_message::Body::Transfer(t))
}

/// ADR-064 — changes for my other devices.
pub fn encode_device_sync(items: Vec<SyncEntry>) -> Vec<u8> {
    encode(app_message::Body::DeviceSync(DeviceSync { items }))
}

pub fn encode_reaction(target: &str, emoji: &str) -> Vec<u8> {
    encode(app_message::Body::Reaction(Reaction { target: target.into(), emoji: emoji.into() }))
}

pub fn encode_edit(target: &str, text: &str) -> Vec<u8> {
    encode(app_message::Body::Edit(Edit { target: target.into(), text: text.into(), ..Default::default() }))
}

/// ADR-070 — an edit with the new text's formatting.
pub fn encode_edit_rich(target: &str, text: &str, entities: Vec<TextEntity>) -> Vec<u8> {
    encode(app_message::Body::Edit(Edit {
        target: target.into(),
        text: text.into(),
        entities: clean_entities(text, entities),
        rich: true,
    }))
}

pub fn encode_delete(target: &str) -> Vec<u8> {
    encode(app_message::Body::Delete(Delete { target: target.into() }))
}

pub fn encode_receipt(read: bool, ids: &[String]) -> Vec<u8> {
    let kind = if read { ReceiptKind::Read } else { ReceiptKind::Delivered };
    encode(app_message::Body::Receipt(Receipt { kind: kind as i32, ids: ids.to_vec() }))
}

pub fn encode_typing(active: bool) -> Vec<u8> {
    encode(app_message::Body::Typing(Typing { active }))
}

/// Bounded, printable message reference (a wire UUID in practice).
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= MAX_ID_BYTES && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn valid_emoji(e: &str) -> bool {
    e.len() <= MAX_EMOJI_BYTES && !e.chars().any(|c| c.is_control() || c.is_alphanumeric() || c.is_whitespace())
}

/// A peer's reply quote is dropped (the message itself stays) if it's
/// malformed; an over-long snippet is cut, not rejected.
fn clean_reply(r: Option<ReplyRef>) -> Option<ReplyRef> {
    let mut r = r?;
    if !valid_id(&r.id) || r.kind.len() > 16 {
        return None;
    }
    if r.snippet.chars().count() > MAX_SNIPPET_CHARS {
        r.snippet = r.snippet.chars().take(MAX_SNIPPET_CHARS).collect();
    }
    Some(r)
}

/// A peer's preview is only shown if it's for a URL actually in the
/// text and within bounds — otherwise it's dropped, the text stays.
fn valid_preview(text: &str, p: &LinkPreview) -> bool {
    p.url.starts_with("https://")
        && p.url.len() <= crate::link_preview::MAX_URL_LEN
        && text.contains(&p.url)
        && !p.title.is_empty()
        && p.title.chars().count() <= crate::link_preview::MAX_TITLE_CHARS
        && p.description.chars().count() <= crate::link_preview::MAX_DESCRIPTION_CHARS
        // The picture is a padded 32 KiB blob (+ nonce and tag), never a big file.
        && p.image.as_ref().map_or(true, |i| {
            BlobRef::try_from(i).is_ok() && i.blob_size <= crate::media::MAX_THUMBNAIL_BYTES as u64 + 64
        })
}

pub fn encode_media(media: MediaBody) -> Vec<u8> {
    encode(app_message::Body::Media(media))
}

fn encode(body: app_message::Body) -> Vec<u8> {
    encode_with_reply(body, None)
}

fn encode_with_reply(body: app_message::Body, reply_to: Option<ReplyRef>) -> Vec<u8> {
    encode_full(body, reply_to, 0)
}

fn encode_full(body: app_message::Body, reply_to: Option<ReplyRef>, expire_secs: u32) -> Vec<u8> {
    let msg = AppMessage { body: Some(body), reply_to, expire_secs };
    let mut out = Vec::with_capacity(2 + msg.encoded_len());
    out.push(MARKER);
    out.push(VERSION);
    msg.encode(&mut out).expect("Vec has unbounded capacity");
    out
}

/// Overnight item 8 — should this message wake an offline phone (push +
/// badge)? A real message — text, link, photo / video / voice / file — or
/// one from a newer client we can't read: yes. Receipts, "typing",
/// presence, reactions, edits, names and other bookkeeping: no.
pub fn wakes_recipient(plaintext: &[u8]) -> bool {
    matches!(
        decode(plaintext),
        Ok(Decoded::Text(_) | Decoded::Link { .. } | Decoded::Media(_) | Decoded::Unsupported { .. })
    )
}

/// Tech-debt 2.53 — how long "online" heartbeats and "typing" are worth
/// anything to a recipient who hasn't got them yet.
pub const STALE_AFTER_SECS: u32 = 120;

/// Tech-debt 2.53 — the server drops this message if the recipient hasn't
/// got it within this many seconds (0 = keep until delivered). "Online"
/// (every 25 s while the app is open) and "typing" — so a contact who is
/// away doesn't get an hour of them on login. "Left" and "hidden" stay:
/// one per session, and they say when I was last seen / to forget it.
pub fn drop_after_secs(plaintext: &[u8]) -> u32 {
    match decode(plaintext) {
        Ok(Decoded::Typing { .. } | Decoded::Presence { online: true, .. }) => STALE_AFTER_SECS,
        _ => 0,
    }
}

pub fn decode(plaintext: &[u8]) -> Result<Decoded, EnvelopeError> {
    decode_message(plaintext).map(|m| m.decoded)
}

/// [`decode`] plus the reply quote.
pub fn decode_message(plaintext: &[u8]) -> Result<DecodedMessage, EnvelopeError> {
    let plain = |decoded| Ok(DecodedMessage { decoded, reply_to: None, expire_secs: 0, entities: None });
    let Some((&MARKER, rest)) = plaintext.split_first() else {
        // Legacy (pre-envelope) peer: bare UTF-8 text.
        if plaintext.len() > MAX_TEXT_BYTES {
            return Err(EnvelopeError::Invalid("text too long"));
        }
        return plain(Decoded::Text(String::from_utf8_lossy(plaintext).into_owned()));
    };
    let Some((&version, payload)) = rest.split_first() else {
        return Err(EnvelopeError::Malformed("missing version".into()));
    };
    if version != VERSION {
        return plain(Decoded::Unsupported { version });
    }
    let msg = AppMessage::decode(payload).map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
    let reply_to = clean_reply(msg.reply_to);
    if msg.expire_secs > MAX_EXPIRE_SECS {
        return Err(EnvelopeError::Invalid("expire timer too long"));
    }
    let expire_secs = msg.expire_secs;
    let entities;
    let decoded = match msg.body {
        Some(app_message::Body::Text(t)) => {
            if t.text.len() > MAX_TEXT_BYTES {
                return Err(EnvelopeError::Invalid("text too long"));
            }
            entities = t.rich.then(|| clean_entities(&t.text, t.entities));
            match t.link_preview {
                Some(p) if valid_preview(&t.text, &p) => Decoded::Link { text: t.text, preview: p },
                _ => Decoded::Text(t.text),
            }
        }
        Some(app_message::Body::Media(mut m)) => {
            validate_media(&m)?;
            m.file_name = clean_file_name(&m.file_name);
            let raw = std::mem::take(&mut m.caption_entities);
            entities = m.caption_rich.then(|| clean_entities(&m.caption, raw));
            m.caption_rich = false;
            let small = m.file.as_ref().is_some_and(|f| f.blob_size <= MAX_STICKER_BLOB);
            m.sticker = m.sticker.take().and_then(clean_sticker).filter(|_| small);
            if m.kind != MediaKind::Photo as i32 {
                m.sticker = None;
            }
            Decoded::Media(m)
        }
        Some(app_message::Body::Reaction(r)) => {
            if !valid_id(&r.target) || !valid_emoji(&r.emoji) {
                return Err(EnvelopeError::Invalid("bad reaction"));
            }
            return plain(Decoded::Reaction { target: r.target, emoji: r.emoji });
        }
        Some(app_message::Body::Edit(e)) => {
            if !valid_id(&e.target) || e.text.trim().is_empty() || e.text.len() > MAX_TEXT_BYTES {
                return Err(EnvelopeError::Invalid("bad edit"));
            }
            let entities = e.rich.then(|| clean_entities(&e.text, e.entities));
            return Ok(DecodedMessage { decoded: Decoded::Edit { target: e.target, text: e.text }, reply_to: None, expire_secs: 0, entities });
        }
        Some(app_message::Body::Delete(d)) => {
            if !valid_id(&d.target) {
                return Err(EnvelopeError::Invalid("bad delete"));
            }
            return plain(Decoded::Delete { target: d.target });
        }
        Some(app_message::Body::Receipt(r)) => {
            let read = match ReceiptKind::try_from(r.kind).unwrap_or(ReceiptKind::Unspecified) {
                ReceiptKind::Read => true,
                ReceiptKind::Delivered => false,
                ReceiptKind::Unspecified => return Err(EnvelopeError::Invalid("bad receipt kind")),
            };
            if r.ids.is_empty() || r.ids.len() > MAX_RECEIPT_IDS || !r.ids.iter().all(|i| valid_id(i)) {
                return Err(EnvelopeError::Invalid("bad receipt ids"));
            }
            return plain(Decoded::Receipt { read, ids: r.ids });
        }
        Some(app_message::Body::Typing(t)) => return plain(Decoded::Typing { active: t.active }),
        Some(app_message::Body::Timer(t)) => {
            if t.secs > MAX_EXPIRE_SECS {
                return Err(EnvelopeError::Invalid("timer too long"));
            }
            return plain(Decoded::Timer { secs: t.secs });
        }
        Some(app_message::Body::Profile(p)) => {
            let Some(name) = clean_profile_name(&p.name) else {
                return Err(EnvelopeError::Invalid("bad profile name"));
            };
            if p.avatar.len() > crate::media::MAX_THUMBNAIL_BYTES {
                return Err(EnvelopeError::Invalid("avatar too large"));
            }
            return plain(Decoded::Profile { name, avatar: p.avatar, bio: clean_profile_bio(&p.bio) });
        }
        Some(app_message::Body::Pin(p)) => {
            if !valid_id(&p.target) {
                return Err(EnvelopeError::Invalid("bad pin"));
            }
            return plain(Decoded::Pin { target: p.target, pinned: p.pinned });
        }
        Some(app_message::Body::Screenshot(s)) => return plain(Decoded::Screenshot { recording: s.recording }),
        Some(app_message::Body::Presence(p)) => {
            return plain(Decoded::Presence { online: p.online && !p.hidden, hidden: p.hidden });
        }
        Some(app_message::Body::GroupName(g)) => {
            let Some(name) = clean_profile_name(&g.name) else {
                return Err(EnvelopeError::Invalid("bad group name"));
            };
            return plain(Decoded::GroupName { name });
        }
        Some(app_message::Body::Leave(_)) => return plain(Decoded::Leave),
        Some(app_message::Body::MembersRemoved(m)) => {
            if m.identities.is_empty() || m.identities.len() > MAX_REMOVED_PEOPLE {
                return Err(EnvelopeError::Invalid("bad removal"));
            }
            let mut ids = Vec::with_capacity(m.identities.len());
            for id in &m.identities {
                ids.push(<[u8; 32]>::try_from(id.as_slice()).map_err(|_| EnvelopeError::Invalid("bad identity"))?);
            }
            return plain(Decoded::MembersRemoved { identities: ids });
        }
        Some(app_message::Body::Access(a)) => {
            if a.key.len() != ACCESS_KEY_LEN {
                return Err(EnvelopeError::Invalid("bad access key"));
            }
            return plain(Decoded::Access { key: a.key });
        }
        Some(app_message::Body::History(h)) => {
            // ADR-055 — only a "Saved messages" marker may be empty.
            let ok = (!h.items.is_empty() || h.saved)
                && h.items.len() <= MAX_HISTORY_ITEMS
                && h.chat_name.len() <= MAX_FILE_NAME_BYTES
                && h.items.iter().all(|i| {
                    valid_id(&i.wire_id)
                        && i.text.len() <= MAX_TEXT_BYTES
                        && i.media_json.len() <= MAX_TEXT_BYTES
                        && matches!(i.kind.as_str(), "text" | "photo" | "voice" | "document" | "video" | "sticker")
                        && i.sender.len() == 64
                        && i.sender.bytes().all(|b| b.is_ascii_hexdigit())
                });
            if !ok {
                return Err(EnvelopeError::Invalid("bad history"));
            }
            let mut items = h.items;
            for i in &mut items {
                let raw = std::mem::take(&mut i.entities);
                if i.rich {
                    i.entities = clean_entities(&i.text, raw);
                }
            }
            return plain(Decoded::History { items, chat_name: h.chat_name, is_group: h.is_group, saved: h.saved });
        }
        Some(app_message::Body::Transfer(t)) => {
            let ok = valid_id(&t.id)
                && t.target_device.len() == 32
                && match t.stage {
                    TRANSFER_OFFER => t.manifest.as_ref().is_some_and(|m| BlobRef::try_from(m).is_ok()),
                    TRANSFER_MEDIA_DONE | TRANSFER_CANCELLED => true,
                    _ => false,
                };
            if !ok {
                return Err(EnvelopeError::Invalid("bad transfer"));
            }
            return plain(Decoded::Transfer(t));
        }
        Some(app_message::Body::DeviceSync(d)) => {
            let ok = !d.items.is_empty()
                && d.items.len() <= MAX_SYNC_ITEMS
                && d.items.iter().all(|i| {
                    !i.key.is_empty()
                        && i.key.len() <= MAX_SYNC_KEY_BYTES
                        && i.key.contains(':')
                        && i.value.len() <= MAX_SYNC_VALUE_BYTES
                        && i.ts > 0
                });
            if !ok {
                return Err(EnvelopeError::Invalid("bad device sync"));
            }
            return plain(Decoded::DeviceSync { items: d.items });
        }
        None => return Err(EnvelopeError::Invalid("empty message")),
    };
    Ok(DecodedMessage { decoded, reply_to, expire_secs, entities })
}

fn validate_media(m: &MediaBody) -> Result<(), EnvelopeError> {
    if MediaKind::try_from(m.kind).unwrap_or(MediaKind::Unspecified) == MediaKind::Unspecified {
        return Err(EnvelopeError::Invalid("unknown media kind"));
    }
    let file = m.file.as_ref().ok_or(EnvelopeError::Invalid("media without file"))?;
    BlobRef::try_from(file)?;
    if let Some(t) = &m.thumbnail {
        BlobRef::try_from(t)?;
        if t.blob_size > MAX_THUMBNAIL_BLOB {
            return Err(EnvelopeError::Invalid("thumbnail too large"));
        }
    }
    if m.waveform.len() > MAX_WAVEFORM_POINTS {
        return Err(EnvelopeError::Invalid("waveform too long"));
    }
    if m.file_name.len() > MAX_FILE_NAME_BYTES {
        return Err(EnvelopeError::Invalid("file name too long"));
    }
    if m.caption.len() > MAX_TEXT_BYTES {
        return Err(EnvelopeError::Invalid("caption too long"));
    }
    if m.album_id.len() > MAX_ID_BYTES {
        return Err(EnvelopeError::Invalid("album id too long"));
    }
    if m.round && m.kind != MediaKind::Video as i32 {
        return Err(EnvelopeError::Invalid("only a video can be round"));
    }
    Ok(())
}

// ── Local-storage form ───────────────────────────────────────────
//
// The app's SQLCipher DB keeps each media message as JSON (column
// messages.media_json) so it can be re-fetched later. Same content as
// the protobuf, readable fields, keys base64. Only ever stored inside
// the encrypted DB.

use base64::{prelude::BASE64_STANDARD, Engine};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct RefJson {
    sha256: String,
    key: String,
    blob_size: u64,
    plain_size: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct MediaJson {
    v: u8,
    kind: String,
    file: RefJson,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    thumbnail: Option<RefJson>,
    #[serde(default)]
    mime_type: String,
    #[serde(default)]
    file_name: String,
    #[serde(default)]
    blurhash: String,
    #[serde(default)]
    width: u32,
    #[serde(default)]
    height: u32,
    #[serde(default)]
    duration_ms: u32,
    #[serde(default)]
    waveform: String,
    #[serde(default)]
    caption: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    album_id: String,
    #[serde(default, skip_serializing_if = "is_false")]
    round: bool,
    /// ADR-049. `kind` stays "photo" — older apps read this JSON too
    /// (history bundles) and don't know a "sticker" kind.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    sticker: Option<StickerJson>,
}

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct StickerJson {
    #[serde(default)]
    emoji: String,
    format: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    animation: Option<RefJson>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pack: Option<PackJson>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct PackJson {
    id: String,
    #[serde(default)]
    title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    file: Option<RefJson>,
    #[serde(default)]
    count: u32,
}

fn sticker_to_json(s: &Sticker) -> StickerJson {
    StickerJson {
        emoji: s.emoji.clone(),
        format: s.format.clone(),
        animation: s.animation.as_ref().map(ref_to_json),
        pack: s.pack.as_ref().map(pack_ref_to_json),
    }
}

fn pack_ref_to_json(p: &PackRef) -> PackJson {
    PackJson { id: p.id.clone(), title: p.title.clone(), file: p.file.as_ref().map(ref_to_json), count: p.count }
}

fn pack_ref_from_json(p: &PackJson) -> Result<PackRef, EnvelopeError> {
    Ok(PackRef {
        id: p.id.clone(),
        title: p.title.clone(),
        file: p.file.as_ref().map(ref_from_json).transpose()?,
        count: p.count,
    })
}

fn sticker_from_json(s: &StickerJson) -> Result<Sticker, EnvelopeError> {
    Ok(Sticker {
        emoji: s.emoji.clone(),
        format: s.format.clone(),
        animation: s.animation.as_ref().map(ref_from_json).transpose()?,
        pack: s.pack.as_ref().map(pack_ref_from_json).transpose()?,
    })
}

pub fn kind_name(kind: i32) -> &'static str {
    match MediaKind::try_from(kind).unwrap_or(MediaKind::Unspecified) {
        MediaKind::Photo => "photo",
        MediaKind::Voice => "voice",
        MediaKind::Document => "document",
        MediaKind::Video => "video",
        MediaKind::Unspecified => "unknown",
    }
}

pub fn kind_from_name(name: &str) -> Option<MediaKind> {
    match name {
        "photo" => Some(MediaKind::Photo),
        "voice" => Some(MediaKind::Voice),
        "document" => Some(MediaKind::Document),
        "video" => Some(MediaKind::Video),
        _ => None,
    }
}

fn ref_to_json(r: &MediaRef) -> RefJson {
    RefJson {
        sha256: hex::encode(&r.sha256),
        key: BASE64_STANDARD.encode(&r.key),
        blob_size: r.blob_size,
        plain_size: r.plain_size,
    }
}

fn ref_from_json(r: &RefJson) -> Result<MediaRef, EnvelopeError> {
    let m = MediaRef {
        sha256: hex::decode(&r.sha256).map_err(|_| EnvelopeError::Invalid("sha256 hex"))?,
        key: BASE64_STANDARD
            .decode(&r.key)
            .map_err(|_| EnvelopeError::Invalid("key base64"))?,
        blob_size: r.blob_size,
        plain_size: r.plain_size,
    };
    BlobRef::try_from(&m)?;
    Ok(m)
}

pub fn media_to_json(m: &MediaBody) -> String {
    let j = MediaJson {
        v: 1,
        kind: kind_name(m.kind).to_string(),
        file: ref_to_json(m.file.as_ref().expect("validated MediaBody has a file")),
        thumbnail: m.thumbnail.as_ref().map(ref_to_json),
        mime_type: m.mime_type.clone(),
        file_name: m.file_name.clone(),
        blurhash: m.blurhash.clone(),
        width: m.width,
        height: m.height,
        duration_ms: m.duration_ms,
        waveform: BASE64_STANDARD.encode(&m.waveform),
        caption: m.caption.clone(),
        album_id: m.album_id.clone(),
        round: m.round,
        sticker: m.sticker.as_ref().map(sticker_to_json),
    };
    serde_json::to_string(&j).expect("plain struct serializes")
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct LinkJson {
    v: u8,
    #[serde(rename = "type")]
    kind: String,
    url: String,
    title: String,
    #[serde(default)]
    description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    image: Option<RefJson>,
}

/// Local form of a reply quote (`messages.reply_json`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct ReplyJson {
    id: String,
    #[serde(default)]
    snippet: String,
    #[serde(default)]
    kind: String,
}

pub fn reply_to_json(r: &ReplyRef) -> String {
    serde_json::to_string(&ReplyJson { id: r.id.clone(), snippet: r.snippet.clone(), kind: r.kind.clone() })
        .expect("plain struct serializes")
}

/// Parse + clean a reply quote from JSON (from Dart when sending).
pub fn reply_from_json(s: &str) -> Result<ReplyRef, EnvelopeError> {
    let j: ReplyJson = serde_json::from_str(s).map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
    clean_reply(Some(ReplyRef { id: j.id, snippet: j.snippet, kind: j.kind }))
        .ok_or(EnvelopeError::Invalid("bad reply"))
}

/// True if a stored `media_json` is a link preview (vs. a media file).
pub fn is_link_json(s: &str) -> bool {
    serde_json::from_str::<LinkJson>(s).map(|j| j.kind == "link").unwrap_or(false)
}

pub fn link_to_json(p: &LinkPreview) -> String {
    serde_json::to_string(&LinkJson {
        v: 1,
        kind: "link".into(),
        url: p.url.clone(),
        title: p.title.clone(),
        description: p.description.clone(),
        image: p.image.as_ref().map(ref_to_json),
    })
    .expect("plain struct serializes")
}

pub fn link_from_json(s: &str) -> Result<LinkPreview, EnvelopeError> {
    let j: LinkJson = serde_json::from_str(s).map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
    if j.kind != "link" {
        return Err(EnvelopeError::Invalid("not a link preview"));
    }
    Ok(LinkPreview {
        url: j.url,
        title: j.title,
        description: j.description,
        image: j.image.as_ref().map(ref_from_json).transpose()?,
    })
}

pub fn media_from_json(s: &str) -> Result<MediaBody, EnvelopeError> {
    let j: MediaJson =
        serde_json::from_str(s).map_err(|e| EnvelopeError::Malformed(e.to_string()))?;
    let kind = kind_from_name(&j.kind).ok_or(EnvelopeError::Invalid("unknown media kind"))?;
    let m = MediaBody {
        kind: kind as i32,
        file: Some(ref_from_json(&j.file)?),
        thumbnail: j.thumbnail.as_ref().map(ref_from_json).transpose()?,
        mime_type: j.mime_type,
        // Rows stored before the cleaning, too.
        file_name: clean_file_name(&j.file_name),
        blurhash: j.blurhash,
        width: j.width,
        height: j.height,
        duration_ms: j.duration_ms,
        waveform: BASE64_STANDARD
            .decode(&j.waveform)
            .map_err(|_| EnvelopeError::Invalid("waveform base64"))?,
        caption: j.caption,
        album_id: j.album_id,
        round: j.round,
        sticker: j.sticker.as_ref().map(sticker_from_json).transpose()?,
        ..Default::default()
    };
    validate_media(&m)?;
    Ok(m)
}

#[cfg(test)]
mod tests {
    #[test]
    fn only_real_messages_wake_an_offline_phone() {
        assert!(wakes_recipient(&encode_text("hi")));
        assert!(!wakes_recipient(&encode_typing(true)));
        assert!(!wakes_recipient(&encode_receipt(true, &["0f8fad5b-d9cb-469f-a165-70867728950e".to_string()])));
        assert!(!wakes_recipient(&encode_leave()));
        assert!(!wakes_recipient(b"\xff\x01"), "garbage");
    }

    #[test]
    fn only_heartbeats_and_typing_go_stale_on_the_server() {
        assert_eq!(drop_after_secs(&encode_presence(true, false)), STALE_AFTER_SECS);
        assert_eq!(drop_after_secs(&encode_typing(true)), STALE_AFTER_SECS);
        assert_eq!(drop_after_secs(&encode_typing(false)), STALE_AFTER_SECS);
        // "Left" sets "last seen"; "hidden" tells them to forget it.
        assert_eq!(drop_after_secs(&encode_presence(false, false)), 0);
        assert_eq!(drop_after_secs(&encode_presence(true, true)), 0);
        assert_eq!(drop_after_secs(&encode_text("hi")), 0);
        assert_eq!(drop_after_secs(&encode_receipt(true, &["0f8fad5b-d9cb-469f-a165-70867728950e".to_string()])), 0);
        assert_eq!(drop_after_secs(b"\xff\x01"), 0, "garbage");
    }

    use super::*;

    fn sample_media() -> MediaBody {
        let (_, r) = crate::media::encrypt(b"img").unwrap();
        MediaBody {
            kind: MediaKind::Photo as i32,
            file: Some(MediaRef::from(&r)),
            thumbnail: None,
            mime_type: "image/jpeg".into(),
            file_name: String::new(),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj".into(),
            width: 1024,
            height: 768,
            duration_ms: 0,
            waveform: vec![],
            caption: "закат".into(),
            album_id: String::new(),
            round: false,
            sticker: None,
            ..Default::default()
        }
    }

    // security-audit-2026-11b M01: a thumbnail / sticker is fetched without
    // a tap, so its blob may not be bigger than an honest one.
    #[test]
    fn m01_auto_fetched_blobs_are_size_capped() {
        let big = |r: &MediaRef| MediaRef { blob_size: 100 * 1024 * 1024, ..r.clone() };
        let mut m = sample_media();
        m.thumbnail = Some(big(m.file.as_ref().unwrap()));
        assert!(decode_message(&encode_media(m)).is_err(), "100 MB thumbnail accepted");

        let sticker = |m: &MediaBody| match decode_message(&encode_media(m.clone())).unwrap().decoded {
            Decoded::Media(m) => m.sticker,
            _ => None,
        };
        let mut m = sample_media();
        m.sticker = Some(Sticker { format: "webp".into(), ..Default::default() });
        assert!(sticker(&m).is_some());
        m.file = Some(big(m.file.as_ref().unwrap()));
        assert!(sticker(&m).is_none(), "100 MB still sticker accepted");

        let mut m = sample_media();
        let anim = MediaRef { plain_size: 10, ..big(m.file.as_ref().unwrap()) };
        m.sticker = Some(Sticker { format: "tgs".into(), animation: Some(anim), ..Default::default() });
        assert!(sticker(&m).is_none(), "100 MB animation accepted");
    }

    const ID: &str = "0f8fad5b-d9cb-469f-a165-70867728950e";

    #[test]
    fn reply_travels_with_text_and_media() {
        let r = ReplyRef { id: ID.into(), snippet: "see you at 9".into(), kind: "text".into() };
        let got = decode_message(&encode_text_full("ok", None, Some(r.clone()))).unwrap();
        assert_eq!(got.decoded, Decoded::Text("ok".into()));
        assert_eq!(got.reply_to, Some(r.clone()));
        let mut m = sample_media();
        m.album_id = "album-1".into();
        let got = decode_message(&encode_media_reply(m.clone(), Some(r.clone()))).unwrap();
        assert_eq!(got.decoded, Decoded::Media(m.clone()));
        assert_eq!(got.reply_to, Some(r));
        // JSON (local form) keeps the album.
        assert_eq!(media_from_json(&media_to_json(&m)).unwrap().album_id, "album-1");
    }

    #[test]
    fn a_file_name_cannot_hide_its_real_extension_with_bidi_characters() {
        let mut m = sample_media();
        m.kind = MediaKind::Document as i32;
        m.file_name = "photo\u{202E}gpj.exe".into();
        let Decoded::Media(got) = decode(&encode_media(m.clone())).unwrap() else { panic!() };
        assert_eq!(got.file_name, "photogpj.exe");
        m.file_name = "a\u{2066}b\u{2069}\nc.pdf".into();
        assert_eq!(media_from_json(&media_to_json(&m)).unwrap().file_name, "abc.pdf", "stored rows too");
    }

    #[test]
    fn bad_reply_is_dropped_long_snippet_is_cut() {
        let bad = ReplyRef { id: "not a valid id!".into(), snippet: "x".into(), kind: "text".into() };
        let got = decode_message(&encode_text_full("hi", None, Some(bad))).unwrap();
        assert_eq!(got.decoded, Decoded::Text("hi".into()), "message survives");
        assert_eq!(got.reply_to, None);
        let long = ReplyRef { id: ID.into(), snippet: "я".repeat(500), kind: "text".into() };
        let got = decode_message(&encode_text_full("hi", None, Some(long))).unwrap();
        assert_eq!(got.reply_to.unwrap().snippet.chars().count(), MAX_SNIPPET_CHARS);
        let j = reply_to_json(&ReplyRef { id: ID.into(), snippet: "q".into(), kind: "photo".into() });
        assert_eq!(reply_from_json(&j).unwrap().kind, "photo");
        assert!(reply_from_json(r#"{"id":"../../etc"}"#).is_err());
    }

    #[test]
    fn actions_roundtrip() {
        assert_eq!(
            decode(&encode_reaction(ID, "❤️")).unwrap(),
            Decoded::Reaction { target: ID.into(), emoji: "❤️".into() }
        );
        assert_eq!(
            decode(&encode_reaction(ID, "")).unwrap(),
            Decoded::Reaction { target: ID.into(), emoji: String::new() },
            "empty emoji = remove"
        );
        assert_eq!(
            decode(&encode_edit(ID, "fixed")).unwrap(),
            Decoded::Edit { target: ID.into(), text: "fixed".into() }
        );
        assert_eq!(decode(&encode_delete(ID)).unwrap(), Decoded::Delete { target: ID.into() });
        assert_eq!(
            decode(&encode_receipt(true, &[ID.to_string()])).unwrap(),
            Decoded::Receipt { read: true, ids: vec![ID.into()] }
        );
        assert_eq!(decode(&encode_typing(true)).unwrap(), Decoded::Typing { active: true });
    }

    #[test]
    fn hostile_actions_are_rejected() {
        assert!(decode(&encode_reaction(ID, "not an emoji")).is_err(), "text is not a reaction");
        assert!(decode(&encode_reaction(ID, &"😀".repeat(20))).is_err(), "too long");
        assert!(decode(&encode_reaction("bad id", "👍")).is_err());
        assert!(decode(&encode_edit(ID, "   ")).is_err(), "edit to blank");
        assert!(decode(&encode_edit(ID, &"a".repeat(MAX_TEXT_BYTES + 1))).is_err());
        assert!(decode(&encode_receipt(false, &[])).is_err());
        let many: Vec<String> = (0..=MAX_RECEIPT_IDS).map(|_| ID.to_string()).collect();
        assert!(decode(&encode_receipt(false, &many)).is_err());
        let mut m = sample_media();
        m.album_id = "a".repeat(MAX_ID_BYTES + 1);
        assert!(decode(&encode_media(m)).is_err());
    }

    #[test]
    fn profile_names_are_cleaned_and_bounded() {
        assert_eq!(decode(&encode_profile("  Аня ", &[], "")).unwrap(), Decoded::Profile { name: "Аня".into(), avatar: vec![], bio: String::new() });
        // Control characters (RTL override, newlines) never reach the UI.
        assert_eq!(
            decode(&encode_profile("Bo\u{202e}b\n", &[], "")).unwrap(),
            Decoded::Profile { name: "Bob".into(), avatar: vec![], bio: String::new() }
        );
        assert!(decode(&encode_profile("   ", &[], "")).is_err());
        assert!(decode(&encode_profile(&"я".repeat(MAX_PROFILE_NAME_CHARS + 1), &[], "")).is_err());
        assert!(decode(&encode_profile(&"я".repeat(MAX_PROFILE_NAME_CHARS), &[], "")).is_ok());
        assert_eq!(clean_profile_name("\u{0}"), None);
        // Line separators, soft hyphen, word joiner, Arabic letter mark, tags.
        assert_eq!(clean_profile_name("Ann\u{2028}Admin").as_deref(), Some("AnnAdmin"));
        assert_eq!(clean_profile_name("Ve\u{00AD}ra\u{2060}\u{061C}\u{E0041}").as_deref(), Some("Vera"));
        // Names that look blank are refused.
        assert_eq!(clean_profile_name("\u{3164}\u{3164}"), None);
        assert_eq!(clean_profile_name("\u{2800}"), None);
        // Emoji keep their presentation selector.
        assert_eq!(clean_profile_name("Вера ❤️").as_deref(), Some("Вера ❤️"));
        // A photo travels with the name; an oversized one is refused.
        let pic = vec![7u8; 1000];
        assert_eq!(
            decode(&encode_profile("Аня", &pic, "")).unwrap(),
            Decoded::Profile { name: "Аня".into(), avatar: pic, bio: String::new() }
        );
        assert!(decode(&encode_profile("Аня", &vec![0u8; crate::media::MAX_THUMBNAIL_BYTES + 1], "")).is_err());
    }

    /// ADR-052 — a bio travels with the name: one line, invisible characters
    /// gone, cut at the limit; a raw over-long one from another client is cut
    /// on arrival too, and never makes the name invalid.
    #[test]
    fn profile_bio_is_one_clean_line() {
        let bio = |b: &str| match decode(&encode_profile("Аня", &[], b)).unwrap() {
            Decoded::Profile { bio, .. } => bio,
            other => panic!("{other:?}"),
        };
        assert_eq!(bio("  Пишите\nднём \u{202e}✌️ "), "Пишите днём ✌️");
        assert_eq!(bio("\u{3164} \u{200b}"), "");
        assert_eq!(bio(&"я".repeat(MAX_PROFILE_BIO_CHARS + 50)).chars().count(), MAX_PROFILE_BIO_CHARS);
        let raw = encode(app_message::Body::Profile(Profile {
            name: "Аня".into(),
            avatar: vec![],
            bio: format!("{}\u{2066}", "б".repeat(MAX_PROFILE_BIO_CHARS * 2)),
        }));
        match decode(&raw).unwrap() {
            Decoded::Profile { name, bio, .. } => {
                assert_eq!(name, "Аня");
                assert_eq!(bio, "б".repeat(MAX_PROFILE_BIO_CHARS));
            }
            other => panic!("{other:?}"),
        }
        // A profile from an older client (no field 3) has no bio.
        assert_eq!(bio(""), "");
    }

    /// ADR-034 — a group's name is cleaned like a display name; a blank or
    /// overlong one is refused.
    #[test]
    fn leave_and_removals_travel() {
        assert_eq!(decode(&encode_leave()).unwrap(), Decoded::Leave);
        let ids = [[7u8; 32], [9u8; 32]];
        assert_eq!(decode(&encode_members_removed(&ids)).unwrap(), Decoded::MembersRemoved { identities: ids.to_vec() });
        assert!(decode(&encode_members_removed(&[])).is_err(), "names nobody");
        let bad = encode(app_message::Body::MembersRemoved(MembersRemoved { identities: vec![vec![1, 2, 3]] }));
        assert!(decode(&bad).is_err(), "not a 32-byte key");
    }

    #[test]
    fn group_names_travel() {
        assert_eq!(decode(&encode_group_name("  Дача \u{202e} ")).unwrap(), Decoded::GroupName { name: "Дача".into() });
        assert!(decode(&encode_group_name("   ")).is_err());
        assert!(decode(&encode_group_name(&"я".repeat(MAX_PROFILE_NAME_CHARS + 1))).is_err());
    }

    #[test]
    fn screenshots_travel() {
        assert_eq!(decode(&encode_screenshot(false)).unwrap(), Decoded::Screenshot { recording: false });
        assert_eq!(decode(&encode_screenshot(true)).unwrap(), Decoded::Screenshot { recording: true });
        // ADR-031 — presence: online, left, hidden (hidden is never online).
        assert_eq!(decode(&encode_presence(true, false)).unwrap(), Decoded::Presence { online: true, hidden: false });
        assert_eq!(decode(&encode_presence(false, false)).unwrap(), Decoded::Presence { online: false, hidden: false });
        assert_eq!(decode(&encode_presence(true, true)).unwrap(), Decoded::Presence { online: false, hidden: true });
        let forged = encode(app_message::Body::Presence(Presence { online: true, hidden: true }));
        assert_eq!(decode(&forged).unwrap(), Decoded::Presence { online: false, hidden: true });
        // A screenshot is the empty message: unchanged on the wire for older clients.
        assert_eq!(encode_screenshot(false), encode(app_message::Body::Screenshot(Screenshot::default())));
    }

    #[test]
    fn pins_travel_and_need_a_valid_target() {
        let id = "0190f0c2-0000-7000-8000-000000000001";
        assert_eq!(decode(&encode_pin(id, true)).unwrap(), Decoded::Pin { target: id.into(), pinned: true });
        assert_eq!(decode(&encode_pin(id, false)).unwrap(), Decoded::Pin { target: id.into(), pinned: false });
        assert!(decode(&encode_pin("", true)).is_err());
    }

    #[test]
    fn disappearing_timer_travels_and_is_bounded() {
        let got = decode_message(&encode_text_expiring("poof", None, None, 3600)).unwrap();
        assert_eq!((got.decoded, got.expire_secs), (Decoded::Text("poof".into()), 3600));
        let got = decode_message(&encode_media_expiring(sample_media(), None, 60)).unwrap();
        assert_eq!(got.expire_secs, 60);
        assert_eq!(decode_message(&encode_text_full("keep", None, None)).unwrap().expire_secs, 0);
        assert_eq!(decode(&encode_timer(86400)).unwrap(), Decoded::Timer { secs: 86400 });
        assert_eq!(decode(&encode_timer(0)).unwrap(), Decoded::Timer { secs: 0 });
        assert!(decode(&encode_timer(MAX_EXPIRE_SECS + 1)).is_err());
        // Tech-debt 2.2 — access keys travel too, and only 16-byte ones.
        assert_eq!(decode(&encode_access(&[3u8; 16])).unwrap(), Decoded::Access { key: vec![3u8; 16] });
        assert!(decode(&encode_access(&[3u8; 15])).is_err());
        // ADR-025 — history bundles, bounded and validated.
        let item = |k: &str| HistoryItem {
            wire_id: "0190f0c2-0000-7000-8000-000000000001".into(),
            ts: 1,
            kind: k.into(),
            text: "hi".into(),
            media_json: String::new(),
            sender: "ab".repeat(32),
            ..Default::default()
        };
        assert_eq!(
            decode(&encode_history(vec![item("text")], "Bob", false, false)).unwrap(),
            Decoded::History { items: vec![item("text")], chat_name: "Bob".into(), is_group: false, saved: false }
        );
        assert!(decode(&encode_history(vec![item("system")], "", false, false)).is_err());
        assert!(decode(&encode_history(vec![item("text"); MAX_HISTORY_ITEMS + 1], "", false, false)).is_err());
        assert!(decode(&encode_history(vec![], "", false, false)).is_err());
        assert!(decode(&encode_history(vec![item("text")], &"x".repeat(MAX_FILE_NAME_BYTES + 1), false, false)).is_err());
        // ADR-055 — the "Saved messages" marker: empty is fine, and it says so.
        assert_eq!(
            decode(&encode_history(vec![], "Saved", false, true)).unwrap(),
            Decoded::History { items: vec![], chat_name: "Saved".into(), is_group: false, saved: true }
        );
        assert!(decode(&encode_history(vec![item("system")], "", false, true)).is_err());
        assert!(decode(&encode_text_expiring("x", None, None, MAX_EXPIRE_SECS + 1)).is_err());
    }

    #[test]
    fn video_kind_roundtrips() {
        let mut m = sample_media();
        m.kind = MediaKind::Video as i32;
        m.duration_ms = 12_000;
        assert_eq!(decode(&encode_media(m.clone())).unwrap(), Decoded::Media(m.clone()));
        assert_eq!(kind_name(m.kind), "video");
        assert_eq!(media_from_json(&media_to_json(&m)).unwrap(), m);
    }

    /// ADR-048 — a round video message: a flag on the video, so the
    /// stored JSON and the history/forward paths stay "video".
    #[test]
    fn round_video_roundtrips_and_old_apps_see_a_video() {
        let mut m = sample_media();
        m.kind = MediaKind::Video as i32;
        m.mime_type = "video/mp4".into();
        m.width = 480;
        m.height = 480;
        m.duration_ms = 9_000;
        m.caption = String::new();
        m.round = true;
        let wire = encode_media(m.clone());
        assert_eq!(decode(&wire).unwrap(), Decoded::Media(m.clone()));
        let json = media_to_json(&m);
        assert!(json.contains("\"round\":true"), "{json}");
        assert!(json.contains("\"kind\":\"video\""), "{json}");
        assert_eq!(media_from_json(&json).unwrap(), m);

        // A plain video's JSON doesn't grow a key; JSON from before the
        // field reads as not round.
        m.round = false;
        assert!(!media_to_json(&m).contains("round"));
        let old = media_to_json(&m);
        assert!(!media_from_json(&old).unwrap().round);

        // An app built before the field: protobuf skips tag 13, the
        // message is a normal video.
        #[derive(Clone, PartialEq, prost::Message)]
        struct OldMediaBody {
            #[prost(enumeration = "MediaKind", tag = "1")]
            kind: i32,
            #[prost(message, optional, tag = "2")]
            file: Option<MediaRef>,
            #[prost(uint32, tag = "7")]
            width: u32,
            #[prost(uint32, tag = "9")]
            duration_ms: u32,
        }
        let mut round = sample_media();
        round.kind = MediaKind::Video as i32;
        round.round = true;
        let old = OldMediaBody::decode(round.encode_to_vec().as_slice()).unwrap();
        assert_eq!(old.kind, MediaKind::Video as i32);
        assert_eq!(old.duration_ms, round.duration_ms);
        assert!(old.file.is_some());
    }

    #[test]
    fn only_a_video_can_be_round() {
        let mut m = sample_media(); // a photo
        m.round = true;
        assert!(decode(&encode_media(m.clone())).is_err());
        let json = media_to_json(&m);
        assert!(media_from_json(&json).is_err());
    }

    #[test]
    fn text_roundtrip() {
        let bytes = encode_text("привет");
        assert_eq!(&bytes[..2], &[MARKER, VERSION]);
        assert_eq!(decode(&bytes).unwrap(), Decoded::Text("привет".into()));
    }

    #[test]
    fn media_roundtrip() {
        let m = sample_media();
        assert_eq!(decode(&encode_media(m.clone())).unwrap(), Decoded::Media(m));
    }

    #[test]
    fn legacy_plain_utf8_is_text() {
        assert_eq!(decode("hello".as_bytes()).unwrap(), Decoded::Text("hello".into()));
        assert_eq!(decode(b"").unwrap(), Decoded::Text(String::new()));
    }

    /// Security audit 2026-11b (crypto-legacy-text-unbounded).
    #[test]
    fn legacy_text_is_bounded_like_any_other_text() {
        let big = vec![b'a'; MAX_TEXT_BYTES + 1];
        assert!(decode(&big).is_err(), "a bare text over MAX_TEXT_BYTES must be refused");
        assert!(!wakes_recipient(&big));
        assert!(decode(&big[1..]).is_ok());
    }

    #[test]
    fn storage_json_roundtrip() {
        let mut m = sample_media();
        let (_, t) = crate::media::encrypt(b"thumb").unwrap();
        m.thumbnail = Some(MediaRef::from(&t));
        m.waveform = vec![1, 200, 3];
        let json = media_to_json(&m);
        assert_eq!(media_from_json(&json).unwrap(), m);
        assert!(media_from_json("{}").is_err());
        assert!(media_from_json(&json.replace("\"photo\"", "\"gif\"")).is_err());
    }

    #[test]
    fn link_preview_roundtrip_and_validation() {
        let (_, img) = crate::media::encrypt(b"img").unwrap();
        let p = LinkPreview {
            url: "https://example.org/a".into(),
            title: "Example".into(),
            description: "desc".into(),
            image: Some(MediaRef::from(&img)),
        };
        let text = "look https://example.org/a !";
        assert_eq!(
            decode(&encode_text_with_preview(text, p.clone())).unwrap(),
            Decoded::Link { text: text.into(), preview: p.clone() }
        );
        // Preview for a URL that is NOT in the text → dropped, text kept.
        let other = LinkPreview { url: "https://phish.example.net".into(), ..p.clone() };
        assert_eq!(decode(&encode_text_with_preview(text, other)).unwrap(), Decoded::Text(text.into()));
        // Non-https / empty title → dropped.
        let http = LinkPreview { url: "http://example.org/a".into(), ..p.clone() };
        assert_eq!(decode(&encode_text_with_preview("http://example.org/a", http)).unwrap(), Decoded::Text("http://example.org/a".into()));
        let untitled = LinkPreview { title: String::new(), ..p.clone() };
        assert!(matches!(decode(&encode_text_with_preview(text, untitled)).unwrap(), Decoded::Text(_)));
        // Storage JSON.
        let j = link_to_json(&p);
        assert!(is_link_json(&j));
        assert!(!is_link_json(&media_to_json(&sample_media())));
        assert_eq!(link_from_json(&j).unwrap(), p);
    }

    /// T03 (audit 2026-11b): a preview picture is a padded 32 KiB blob;
    /// a peer's reference to anything bigger drops the preview.
    #[test]
    fn link_preview_with_oversized_image_is_dropped() {
        let text = "look https://example.org/a !";
        let p = LinkPreview {
            url: "https://example.org/a".into(),
            title: "Example".into(),
            description: String::new(),
            image: Some(MediaRef { sha256: vec![0; 32], key: vec![0; 32], blob_size: 95 << 20, plain_size: 95 << 20 }),
        };
        assert_eq!(decode(&encode_text_with_preview(text, p)).unwrap(), Decoded::Text(text.into()));
    }

    #[test]
    fn future_version_is_unsupported_not_garbage() {
        assert_eq!(decode(&[MARKER, 9, 1, 2, 3]).unwrap(), Decoded::Unsupported { version: 9 });
    }

    #[test]
    fn hostile_envelopes_are_rejected() {
        assert!(decode(&[MARKER]).is_err());
        assert!(decode(&[MARKER, VERSION, 0xFF, 0xFF, 0xFF]).is_err());
        assert!(decode(&[MARKER, VERSION]).is_err(), "no body");

        let mut m = sample_media();
        m.file.as_mut().unwrap().key = vec![1; 5];
        assert!(decode(&encode_media(m)).is_err());

        let mut m = sample_media();
        m.waveform = vec![0; MAX_WAVEFORM_POINTS + 1];
        assert!(decode(&encode_media(m)).is_err());

        let mut m = sample_media();
        m.kind = 77;
        assert!(decode(&encode_media(m)).is_err());

        let mut m = sample_media();
        m.file = None;
        assert!(decode(&encode_media(m)).is_err());
    }

    /// ADR-064 — transfer and device-sync messages round-trip and are bounded.
    #[test]
    fn transfer_and_device_sync_are_validated() {
        let manifest = MediaRef { sha256: vec![1; 32], key: vec![2; 32], blob_size: 10, plain_size: 5 };
        let offer = Transfer {
            id: "0193-ab".into(),
            target_device: vec![9; 32],
            stage: TRANSFER_OFFER,
            manifest: Some(manifest.clone()),
            messages: 7,
            media: 2,
            media_missing: 0,
        };
        match decode(&encode_transfer(offer.clone())).unwrap() {
            Decoded::Transfer(t) => assert_eq!(t, offer),
            other => panic!("{other:?}"),
        }
        let bad = |t: Transfer| decode(&encode_transfer(t)).is_err();
        assert!(bad(Transfer { manifest: None, ..offer.clone() }), "an offer needs its manifest");
        assert!(bad(Transfer { target_device: vec![1; 5], ..offer.clone() }));
        assert!(bad(Transfer { id: "../x".into(), ..offer.clone() }));
        assert!(bad(Transfer { stage: 9, ..offer.clone() }));
        assert!(!bad(Transfer { stage: TRANSFER_MEDIA_DONE, manifest: None, ..offer.clone() }));

        let item = SyncEntry { key: "contact:ab".into(), ts: 5, deleted: false, value: "{}".into() };
        assert_eq!(
            decode(&encode_device_sync(vec![item.clone()])).unwrap(),
            Decoded::DeviceSync { items: vec![item.clone()] }
        );
        assert!(decode(&encode_device_sync(vec![])).is_err());
        assert!(decode(&encode_device_sync(vec![item.clone(); MAX_SYNC_ITEMS + 1])).is_err());
        assert!(decode(&encode_device_sync(vec![SyncEntry { key: "nocolon".into(), ..item.clone() }])).is_err());
        assert!(decode(&encode_device_sync(vec![SyncEntry { value: "x".repeat(MAX_SYNC_VALUE_BYTES + 1), ..item }])).is_err());
    }

    // ── ADR-070 — formatting ────────────────────────────────────────

    fn ent(kind: u32, offset: u32, length: u32) -> TextEntity {
        TextEntity { kind, offset, length, ..Default::default() }
    }

    #[test]
    fn formatting_travels_beside_clean_text() {
        let link = TextEntity { url: "https://sinhron.app".into(), ..ent(ENTITY_LINK, 6, 5) };
        let sent = vec![ent(ENTITY_BOLD, 0, 5), link.clone()];
        let got = decode_message(&encode_text_rich("Hello world", sent.clone(), None, None, 0)).unwrap();
        assert_eq!(got.decoded, Decoded::Text("Hello world".into()), "the text has no markers");
        assert_eq!(got.entities, Some(sent));
        // Plain but new: rich with no ranges (stars stay stars).
        let got = decode_message(&encode_text_rich("*not bold*", vec![], None, None, 0)).unwrap();
        assert_eq!(got.entities, Some(vec![]));
        // An older app: no formatting info at all.
        assert_eq!(decode_message(&encode_text("*bold*")).unwrap().entities, None);
        // What an older app reads from a new one: the clean text (the new
        // fields are unknown tags it skips).
        let raw = AppMessage::decode(&encode_text_rich("Hi", vec![ent(ENTITY_BOLD, 0, 2)], None, None, 0)[2..]).unwrap();
        let Some(app_message::Body::Text(t)) = raw.body else { panic!() };
        assert_eq!(t.text, "Hi");
    }

    #[test]
    fn hostile_formatting_is_dropped_the_text_stays() {
        let text = "a😀b"; // UTF-16: a=0, 😀=1..3, b=3
        let bad = vec![
            ent(ENTITY_BOLD, 0, 0),                                      // empty
            ent(ENTITY_BOLD, 3, 5),                                      // past the end
            ent(ENTITY_BOLD, u32::MAX, 2),                               // overflow
            ent(ENTITY_ITALIC, 2, 1),                                    // starts inside the emoji
            ent(ENTITY_ITALIC, 0, 2),                                    // ends inside the emoji
            ent(99, 0, 1),                                               // unknown kind
            TextEntity { url: "javascript:alert(1)".into(), ..ent(ENTITY_LINK, 0, 1) },
            TextEntity { url: "https://a b".into(), ..ent(ENTITY_LINK, 0, 1) },
            TextEntity { url: String::new(), ..ent(ENTITY_LINK, 0, 1) },
        ];
        assert!(clean_entities(text, bad).is_empty());
        let ok = clean_entities(
            text,
            vec![
                ent(ENTITY_STRIKE, 3, 1),
                TextEntity { url: "x".into(), language: "rust".into(), ..ent(ENTITY_BOLD, 1, 2) },
                TextEntity { language: "c++".into(), ..ent(ENTITY_PRE, 0, 4) },
                TextEntity { language: "<script>".into(), ..ent(ENTITY_PRE, 0, 1) },
                TextEntity { url: "MAILTO:me@x.org".into(), ..ent(ENTITY_LINK, 0, 1) },
            ],
        );
        assert_eq!(
            ok,
            vec![
                TextEntity { language: "c++".into(), ..ent(ENTITY_PRE, 0, 4) },
                ent(ENTITY_PRE, 0, 1),
                TextEntity { url: "MAILTO:me@x.org".into(), ..ent(ENTITY_LINK, 0, 1) },
                ent(ENTITY_BOLD, 1, 2),
                ent(ENTITY_STRIKE, 3, 1),
            ],
            "sorted; url / language only where they belong; a bad language is cleared"
        );
        // A flood of ranges is cut, not the message.
        let many = vec![ent(ENTITY_BOLD, 0, 1); MAX_ENTITIES + 50];
        let got = decode_message(&encode_full(
            app_message::Body::Text(TextBody { text: "x".into(), entities: many, rich: true, ..Default::default() }),
            None,
            0,
        ))
        .unwrap();
        assert_eq!(got.entities.unwrap().len(), 1, "duplicates fold");
        let distinct: Vec<TextEntity> = (0..MAX_ENTITIES as u32 + 10).map(|i| ent(ENTITY_BOLD, i, 1)).collect();
        let long = "x".repeat(MAX_ENTITIES + 10);
        assert_eq!(clean_entities(&long, distinct).len(), MAX_ENTITIES);
    }

    #[test]
    fn edit_caption_and_history_keep_formatting() {
        let e = vec![ent(ENTITY_ITALIC, 0, 3)];
        let got = decode_message(&encode_edit_rich(ID, "new text", e.clone())).unwrap();
        assert_eq!(got.decoded, Decoded::Edit { target: ID.into(), text: "new text".into() });
        assert_eq!(got.entities, Some(e.clone()));
        assert_eq!(decode_message(&encode_edit(ID, "plain")).unwrap().entities, None);

        let mut m = sample_media(); // caption "закат"
        m.caption_entities = vec![ent(ENTITY_SPOILER, 0, 5), ent(ENTITY_BOLD, 3, 9)];
        m.caption_rich = true;
        let got = decode_message(&encode_media(m)).unwrap();
        assert_eq!(got.entities, Some(vec![ent(ENTITY_SPOILER, 0, 5)]), "out-of-range one dropped");
        let Decoded::Media(md) = got.decoded else { panic!() };
        assert!(md.caption_entities.is_empty() && !md.caption_rich, "lives in DecodedMessage only");
        assert_eq!(decode_message(&encode_media(sample_media())).unwrap().entities, None);

        let item = HistoryItem {
            wire_id: ID.into(),
            ts: 1,
            kind: "text".into(),
            text: "hi there".into(),
            sender: "ab".repeat(32),
            entities: vec![ent(ENTITY_BOLD, 0, 2), ent(ENTITY_BOLD, 5, 50)],
            rich: true,
            ..Default::default()
        };
        let Decoded::History { items, .. } = decode(&encode_history(vec![item], "Bob", false, false)).unwrap() else {
            panic!()
        };
        assert_eq!(items[0].entities, vec![ent(ENTITY_BOLD, 0, 2)]);
        assert!(items[0].rich);
    }

    #[test]
    fn entities_json_for_the_app() {
        let e = vec![
            ent(ENTITY_BOLD, 0, 4),
            TextEntity { url: "https://x.org".into(), ..ent(ENTITY_LINK, 5, 3) },
            TextEntity { language: "dart".into(), ..ent(ENTITY_PRE, 9, 2) },
        ];
        let j = entities_to_json(&e);
        assert_eq!(
            j,
            r#"[{"t":"bold","o":0,"l":4},{"t":"link","o":5,"l":3,"url":"https://x.org"},{"t":"pre","o":9,"l":2,"lang":"dart"}]"#
        );
        assert_eq!(entities_from_json("abcd efg hi", &j).unwrap(), e);
        // A newer app's kind is skipped; ranges are cleaned for the text.
        assert_eq!(
            entities_from_json("ab", r#"[{"t":"sparkle","o":0,"l":1},{"t":"code","o":0,"l":9},{"t":"code","o":1,"l":1}]"#)
                .unwrap(),
            vec![ent(ENTITY_CODE, 1, 1)]
        );
        assert!(entities_from_json("ab", "nope").is_err());
        assert_eq!(entities_to_json(&[]), "[]");
    }

    /// Audit A03 - a "reaction" must not be words under a message.
    #[test]
    fn reaction_emoji_rejects_words() {
        assert!(valid_emoji("\u{1F44D}"));
        assert!(valid_emoji("\u{2764}\u{FE0F}"));
        assert!(!valid_emoji("\u{423}\u{434}\u{430}\u{43B}\u{435}\u{43D}\u{43E}"), "Cyrillic word");
        assert!(!valid_emoji("\u{1F44D} \u{1F44D}"), "whitespace");
    }
}
