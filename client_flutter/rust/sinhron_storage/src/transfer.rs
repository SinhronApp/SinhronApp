// The device transfer's rows — ADR-064.
//
// When I link a new device, one of my devices packs everything this
// database holds that the new one should have (chats with their settings,
// the full message history, contacts, blocked people, other people's
// names / photos / bios, call history, synced and "copied once" settings,
// sticker packs) and the new device merges it in. This module reads and
// writes those rows; `sinhron_sync::transfer` packs, encrypts, uploads and
// resumes. Merging never loses what the new device already has:
// messages are matched by their wire id, settings by their sync clock.
//
// Never transferred: disappearing messages (ADR-020 — they are meant to
// go away, not spread), messages deleted for everyone, drafts, unread
// counts, this device's own keys and connection settings.
//
// The parts waiting to upload live encrypted in `<db>.transfer/` (same
// `nonce‖ct‖tag` form as media blobs), removed when the transfer ends and
// with the database.

use std::io::Write;
use std::path::{Path, PathBuf};

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::blobs::is_sha_hex;
use crate::devsync::{self, is_copied_once_setting, is_synced_setting};
use crate::{path_with_suffix, refresh_chat_preview, stickers, with_db, StorageError, DB};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TChat {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub is_group: bool,
    #[serde(default)]
    pub muted: bool,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub pin_order: i64,
    #[serde(default)]
    pub archived: bool,
    #[serde(default)]
    pub disappear_secs: i64,
    #[serde(default)]
    pub pinned_msg: Option<String>,
    #[serde(default)]
    pub peer_id: Option<String>,
    #[serde(default)]
    pub created_ts: i64,
    #[serde(default)]
    pub request: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TMessage {
    pub id: String,
    pub chat_id: String,
    pub ts: i64,
    #[serde(default)]
    pub body: String,
    pub kind: String,
    #[serde(default)]
    pub is_mine: bool,
    #[serde(default)]
    pub sender_label: Option<String>,
    #[serde(default)]
    pub media_json: Option<String>,
    #[serde(default)]
    pub wire_id: Option<String>,
    #[serde(default)]
    pub status: i64,
    #[serde(default)]
    pub reply_json: Option<String>,
    #[serde(default)]
    pub edited_ts: Option<i64>,
    #[serde(default)]
    pub reactions_json: Option<String>,
    #[serde(default)]
    pub sender_id: Option<String>,
    /// ADR-070 — the message's formatting (an older app's transfer has none).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entities_json: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TContact {
    pub peer_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub favourite: bool,
    #[serde(default)]
    pub added_ts: i64,
}

/// Another person as this device knows them (from their `profile`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TPeer {
    pub peer_id: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub name_ts: i64,
    /// Their ≤32 KB JPEG, hex.
    #[serde(default)]
    pub avatar_hex: Option<String>,
    #[serde(default)]
    pub avatar_ts: i64,
    #[serde(default)]
    pub bio: Option<String>,
    #[serde(default)]
    pub bio_ts: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TCall {
    pub id: String,
    pub chat_id: String,
    pub kind: String,
    pub status: String,
    #[serde(default)]
    pub outgoing: bool,
    pub started: i64,
    #[serde(default)]
    pub ended: Option<i64>,
    #[serde(default)]
    pub duration: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TBlocked {
    pub peer_id: String,
    #[serde(default)]
    pub ts: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TSetting {
    pub key: String,
    pub value: String,
    /// Its sync clock on the old device (0 = never changed since ADR-064).
    #[serde(default)]
    pub ts: i64,
}

/// Everything but the messages: the transfer's first part.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Header {
    #[serde(default)]
    pub chats: Vec<TChat>,
    #[serde(default)]
    pub contacts: Vec<TContact>,
    #[serde(default)]
    pub blocked: Vec<TBlocked>,
    #[serde(default)]
    pub peers: Vec<TPeer>,
    #[serde(default)]
    pub calls: Vec<TCall>,
    #[serde(default)]
    pub settings: Vec<TSetting>,
    /// Sticker pack index entries (with their files' keys).
    #[serde(default)]
    pub packs: Vec<serde_json::Value>,
    /// Sync clocks of chats / contacts / blocked people (item → ts).
    #[serde(default)]
    pub clocks: Vec<(String, i64)>,
    /// My "Saved messages" chat (ADR-055).
    #[serde(default)]
    pub saved_chat_id: Option<String>,
}

/// Settings that must never leave this device or be overwritten from
/// another one, even if a future list put them in by mistake.
fn transferable_setting(key: &str) -> bool {
    is_synced_setting(key) || is_copied_once_setting(key)
}

pub fn export_header(saved_setting: &str) -> Result<Header, StorageError> {
    with_db(|conn| {
        let chats = conn
            .prepare(
                "SELECT id, display_name, is_group, muted, pinned, pin_order, archived, disappear_secs, \
                        pinned_msg, peer_id, created_at_unix, request FROM chats ORDER BY created_at_unix",
            )?
            .query_map([], |r| {
                Ok(TChat {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    is_group: r.get::<_, i64>(2)? != 0,
                    muted: r.get::<_, i64>(3)? != 0,
                    pinned: r.get::<_, i64>(4)? != 0,
                    pin_order: r.get(5)?,
                    archived: r.get::<_, i64>(6)? != 0,
                    disappear_secs: r.get(7)?,
                    pinned_msg: r.get(8)?,
                    peer_id: r.get(9)?,
                    created_ts: r.get(10)?,
                    request: r.get::<_, i64>(11)? != 0,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let contacts = conn
            .prepare("SELECT peer_id, name, favourite, added_ts FROM contacts ORDER BY added_ts")?
            .query_map([], |r| Ok(TContact { peer_id: r.get(0)?, name: r.get(1)?, favourite: r.get(2)?, added_ts: r.get(3)? }))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let blocked = conn
            .prepare("SELECT peer_id, blocked_ts FROM blocked_peers")?
            .query_map([], |r| Ok(TBlocked { peer_id: r.get(0)?, ts: r.get(1)? }))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let mut peers: std::collections::BTreeMap<String, TPeer> = Default::default();
        let peer = |id: String| TPeer { peer_id: id, ..Default::default() };
        for (id, name, ts) in conn
            .prepare("SELECT peer_id, name, updated_ts FROM peer_names")?
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?
        {
            let p = peers.entry(id.clone()).or_insert_with(|| peer(id));
            p.name = Some(name);
            p.name_ts = ts;
        }
        for (id, jpeg, ts) in conn
            .prepare("SELECT peer_id, jpeg, updated_ts FROM peer_avatars")?
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Vec<u8>>(1)?, r.get::<_, i64>(2)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?
        {
            let p = peers.entry(id.clone()).or_insert_with(|| peer(id));
            p.avatar_hex = Some(hex::encode(jpeg));
            p.avatar_ts = ts;
        }
        for (id, bio, ts) in conn
            .prepare("SELECT peer_id, bio, updated_ts FROM peer_bios")?
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?
        {
            let p = peers.entry(id.clone()).or_insert_with(|| peer(id));
            p.bio = Some(bio);
            p.bio_ts = ts;
        }
        let calls = conn
            .prepare(
                "SELECT id, peer_chat_id, kind, status, is_outgoing, started_at_unix, ended_at_unix, duration_secs \
                 FROM calls ORDER BY started_at_unix",
            )?
            .query_map([], |r| {
                Ok(TCall {
                    id: r.get(0)?,
                    chat_id: r.get(1)?,
                    kind: r.get(2)?,
                    status: r.get(3)?,
                    outgoing: r.get::<_, i64>(4)? != 0,
                    started: r.get(5)?,
                    ended: r.get(6)?,
                    duration: r.get(7)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let clocks: Vec<(String, i64)> = conn
            .prepare("SELECT item, ts FROM sync_clock WHERE deleted = 0")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let clock = |k: &str| clocks.iter().find(|(i, _)| i == &devsync::setting_item(k)).map_or(0, |(_, t)| *t);
        let settings = conn
            .prepare("SELECT key, value FROM settings ORDER BY key")?
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?
            .into_iter()
            .filter(|(k, _)| transferable_setting(k))
            .map(|(key, value)| TSetting { ts: clock(&key), key, value })
            .collect();
        let packs_json: Option<String> = conn
            .query_row("SELECT value FROM settings WHERE key = ?", params![stickers::INDEX_SETTING], |r| r.get(0))
            .optional()?;
        let packs = match packs_json.as_deref().map(serde_json::from_str::<serde_json::Value>) {
            Some(Ok(serde_json::Value::Array(l))) => l
                .into_iter()
                .map(|mut e| {
                    if let Some(o) = e.as_object_mut() {
                        o.remove("share");
                    }
                    e
                })
                .collect(),
            _ => Vec::new(),
        };
        let saved_chat_id: Option<String> = conn
            .query_row("SELECT value FROM settings WHERE key = ?", params![saved_setting], |r| r.get(0))
            .optional()?
            .filter(|s: &String| !s.is_empty());
        Ok(Header {
            chats,
            contacts,
            blocked,
            peers: peers.into_values().collect(),
            calls,
            settings,
            packs,
            clocks: clocks.into_iter().filter(|(i, _)| !i.starts_with("set:")).collect(),
            saved_chat_id,
        })
    })
}

/// Chat ids that have transferable messages, in a stable order.
pub fn export_chat_ids() -> Result<Vec<String>, StorageError> {
    with_db(|conn| {
        Ok(conn
            .prepare("SELECT DISTINCT chat_id FROM messages WHERE deleted = 0 AND expire_at IS NULL ORDER BY chat_id")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?)
    })
}

/// Up to [limit] transferable messages of [chat_id] after the cursor
/// `(ts, id)` (oldest first) — the old device pages through each chat.
pub fn export_messages(chat_id: &str, after: Option<(i64, &str)>, limit: i64) -> Result<Vec<TMessage>, StorageError> {
    let (ts, id) = after.unwrap_or((i64::MIN, ""));
    with_db(|conn| {
        Ok(conn
            .prepare(
                "SELECT id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, wire_id, status, \
                        reply_json, edited_ts, reactions_json, sender_id, entities_json FROM messages \
                 WHERE chat_id = ?1 AND deleted = 0 AND expire_at IS NULL AND (ts_unix > ?2 OR (ts_unix = ?2 AND id > ?3)) \
                 ORDER BY ts_unix, id LIMIT ?4",
            )?
            .query_map(params![chat_id, ts, id, limit], |r| {
                Ok(TMessage {
                    id: r.get(0)?,
                    chat_id: r.get(1)?,
                    ts: r.get(2)?,
                    body: r.get(3)?,
                    kind: r.get(4)?,
                    is_mine: r.get::<_, i64>(5)? != 0,
                    sender_label: r.get(6)?,
                    media_json: r.get(7)?,
                    wire_id: r.get(8)?,
                    status: r.get(9)?,
                    reply_json: r.get(10)?,
                    edited_ts: r.get(11)?,
                    reactions_json: r.get(12)?,
                    sender_id: r.get(13)?,
                    entities_json: r.get(14)?,
                })
            })?
            .collect::<rusqlite::Result<_>>()?)
    })
}

/// How many messages [export_messages] would hand over in all.
pub fn export_message_count() -> Result<i64, StorageError> {
    with_db(|conn| {
        Ok(conn.query_row("SELECT COUNT(*) FROM messages WHERE deleted = 0 AND expire_at IS NULL", [], |r| r.get(0))?)
    })
}

/// BKP-1 (ADR-105) — a cloud backup's root carries no proof of which device
/// made it (a device I disconnected, with access to my cloud, can plant
/// one): "verified" marks are not taken from a backup — they come from my
/// own devices over MLS, or the person is verified again.
pub fn strip_for_backup(h: &mut Header) {
    h.settings.retain(|s| !s.key.starts_with("verified:"));
}

/// What [import_header] did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct HeaderReport {
    pub chats_added: u32,
    pub contacts: u32,
    pub settings: u32,
    /// Pack index entries this device didn't have (their files must be
    /// fetched): sha256 of each pack file.
    pub packs_added: Vec<String>,
}

fn local_clock(conn: &Connection, item: &str) -> Result<Option<i64>, StorageError> {
    Ok(conn.query_row("SELECT ts FROM sync_clock WHERE item = ?", params![item], |r| r.get(0)).optional()?)
}

/// Merge the old device's header into this one. Idempotent: running it
/// again (a resumed transfer) changes nothing more.
pub fn import_header(h: &Header) -> Result<HeaderReport, StorageError> {
    let clock = |item: &str| h.clocks.iter().find(|(i, _)| i == item).map_or(0, |(_, t)| *t);
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut rep = HeaderReport::default();
        for c in &h.chats {
            if c.id.is_empty() {
                continue;
            }
            let exists = tx.prepare("SELECT 1 FROM chats WHERE id = ?")?.exists(params![c.id])?;
            if !exists {
                tx.execute(
                    "INSERT INTO chats (id, display_name, is_group, muted, pinned, pin_order, archived, disappear_secs, \
                       pinned_msg, peer_id, created_at_unix, request, last_msg_ts_unix) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    params![
                        c.id,
                        c.name,
                        c.is_group,
                        c.muted,
                        c.pinned,
                        c.pin_order,
                        c.archived,
                        c.disappear_secs.max(0),
                        c.pinned_msg,
                        c.peer_id,
                        c.created_ts,
                        c.request,
                        c.created_ts
                    ],
                )?;
                rep.chats_added += 1;
            } else {
                // The chat came here with the device sync (placeholder name,
                // default flags): the old device knows better unless this one
                // changed the flags itself later.
                let item = devsync::chat_item(&c.id);
                if local_clock(&tx, &item)?.is_none_or(|t| t < clock(&item)) {
                    tx.execute(
                        "UPDATE chats SET muted = ?, pinned = ?, pin_order = ?, archived = ? WHERE id = ?",
                        params![c.muted, c.pinned, c.pin_order, c.archived, c.id],
                    )?;
                }
                tx.execute(
                    "UPDATE chats SET display_name = ?2, is_group = ?3 WHERE id = ?1 AND ?2 <> '' \
                       AND NOT EXISTS (SELECT 1 FROM messages WHERE chat_id = ?1 AND kind <> 'system')",
                    params![c.id, c.name, c.is_group],
                )?;
                tx.execute(
                    "UPDATE chats SET disappear_secs = ?2 WHERE id = ?1 AND disappear_secs = 0",
                    params![c.id, c.disappear_secs.max(0)],
                )?;
                tx.execute(
                    "UPDATE chats SET pinned_msg = ?2 WHERE id = ?1 AND pinned_msg IS NULL",
                    params![c.id, c.pinned_msg],
                )?;
                tx.execute("UPDATE chats SET peer_id = ?2 WHERE id = ?1 AND peer_id IS NULL", params![c.id, c.peer_id])?;
                // Mine on the old device → not a stranger's request here.
                if !c.request {
                    tx.execute("UPDATE chats SET request = 0 WHERE id = ?", params![c.id])?;
                }
            }
            let item = devsync::chat_item(&c.id);
            let t = clock(&item);
            if t > 0 && local_clock(&tx, &item)?.is_none_or(|l| l < t) {
                devsync::set_clock(&tx, &item, t, false)?;
            }
        }
        for k in &h.contacts {
            let id = k.peer_id.to_lowercase();
            if id.is_empty() {
                continue;
            }
            tx.execute(
                "INSERT INTO contacts (peer_id, name, favourite, added_ts) VALUES (?1, ?2, ?3, ?4) \
                 ON CONFLICT(peer_id) DO UPDATE SET favourite = contacts.favourite OR excluded.favourite, \
                   name = CASE WHEN contacts.name = '' THEN excluded.name ELSE contacts.name END, \
                   added_ts = MIN(contacts.added_ts, excluded.added_ts)",
                params![id, k.name, k.favourite, k.added_ts],
            )?;
            rep.contacts += 1;
            let item = devsync::contact_item(&id);
            let t = clock(&item);
            if t > 0 && local_clock(&tx, &item)?.is_none_or(|l| l < t) {
                devsync::set_clock(&tx, &item, t, false)?;
            }
        }
        for b in &h.blocked {
            tx.execute(
                "INSERT INTO blocked_peers (peer_id, blocked_ts) VALUES (?, ?) ON CONFLICT(peer_id) DO NOTHING",
                params![b.peer_id, b.ts],
            )?;
        }
        for p in &h.peers {
            if let Some(name) = &p.name {
                tx.execute(
                    "INSERT INTO peer_names (peer_id, name, updated_ts) VALUES (?1, ?2, ?3) \
                     ON CONFLICT(peer_id) DO UPDATE SET name = excluded.name, updated_ts = excluded.updated_ts \
                     WHERE peer_names.updated_ts < excluded.updated_ts",
                    params![p.peer_id, name, p.name_ts],
                )?;
            }
            if let Some(jpeg) = p.avatar_hex.as_deref().and_then(|h| hex::decode(h).ok()).filter(|j| !j.is_empty()) {
                tx.execute(
                    "INSERT INTO peer_avatars (peer_id, jpeg, updated_ts) VALUES (?1, ?2, ?3) \
                     ON CONFLICT(peer_id) DO UPDATE SET jpeg = excluded.jpeg, updated_ts = excluded.updated_ts \
                     WHERE peer_avatars.updated_ts < excluded.updated_ts",
                    params![p.peer_id, jpeg, p.avatar_ts],
                )?;
            }
            if let Some(bio) = p.bio.as_deref().filter(|b| !b.is_empty()) {
                tx.execute(
                    "INSERT INTO peer_bios (peer_id, bio, updated_ts) VALUES (?1, ?2, ?3) \
                     ON CONFLICT(peer_id) DO UPDATE SET bio = excluded.bio, updated_ts = excluded.updated_ts \
                     WHERE peer_bios.updated_ts < excluded.updated_ts",
                    params![p.peer_id, bio, p.bio_ts],
                )?;
            }
        }
        for c in &h.calls {
            tx.execute(
                "INSERT OR IGNORE INTO calls (id, peer_chat_id, kind, status, is_outgoing, started_at_unix, \
                   ended_at_unix, duration_secs) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                params![c.id, c.chat_id, c.kind, c.status, c.outgoing, c.started, c.ended, c.duration],
            )?;
        }
        // BKP-1 / DEV-2 — a clock from the future would pin the value for ever
        // (nothing newer could replace it, here or on my other devices).
        let horizon = devsync::now_ms().saturating_add(24 * 3600 * 1000);
        for s in &h.settings {
            if !transferable_setting(&s.key) {
                continue;
            }
            let s = &TSetting { ts: s.ts.min(horizon), ..s.clone() };
            let have = tx.prepare("SELECT 1 FROM settings WHERE key = ?")?.exists(params![s.key])?;
            let take = if is_synced_setting(&s.key) {
                let local = local_clock(&tx, &devsync::setting_item(&s.key))?;
                match local {
                    Some(l) => l < s.ts,
                    None => !have || s.ts > 0,
                }
            } else {
                // Copied once: only what this device hasn't set itself.
                !have
            };
            if !take {
                continue;
            }
            tx.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![s.key, s.value],
            )?;
            if s.ts > 0 {
                devsync::set_clock(&tx, &devsync::setting_item(&s.key), s.ts, false)?;
            }
            rep.settings += 1;
        }
        if !h.packs.is_empty() {
            let index: Option<String> = tx
                .query_row("SELECT value FROM settings WHERE key = ?", params![stickers::INDEX_SETTING], |r| r.get(0))
                .optional()?;
            let mut list = match index.as_deref().map(serde_json::from_str::<serde_json::Value>) {
                Some(Ok(serde_json::Value::Array(l))) => l,
                _ => Vec::new(),
            };
            for p in &h.packs {
                let Some(id) = p.get("id").and_then(|v| v.as_str()) else { continue };
                let Some(sha) = devsync::pack_entry_sha(p).filter(|s| is_sha_hex(s)) else { continue };
                if id.starts_with("sinhron.") || list.iter().any(|e| e.get("id").and_then(|v| v.as_str()) == Some(id)) {
                    continue;
                }
                list.push(p.clone());
                rep.packs_added.push(sha);
            }
            if !rep.packs_added.is_empty() {
                tx.execute(
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![stickers::INDEX_SETTING, serde_json::Value::Array(list).to_string()],
                )?;
            }
        }
        tx.commit()?;
        Ok(rep)
    })
}

/// Merge messages from the old device. A message this device already has
/// (same wire id in the chat — e.g. from the short history hand-off, or
/// received live) only gains what it lacks (reactions, edit, quote); the
/// rest are added as they were. Unread counts don't change. Returns how
/// many were added.
pub fn import_messages(ms: &[TMessage]) -> Result<usize, StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut added = 0;
        let mut touched: Vec<&str> = Vec::new();
        for m in ms {
            if !tx.prepare("SELECT 1 FROM chats WHERE id = ?")?.exists(params![m.chat_id])? {
                continue;
            }
            let existing: Option<String> = match &m.wire_id {
                Some(w) => tx
                    .query_row("SELECT id FROM messages WHERE chat_id = ? AND wire_id = ?", params![m.chat_id, w], |r| {
                        r.get(0)
                    })
                    .optional()?,
                None => None,
            };
            if let Some(id) = existing {
                tx.execute(
                    "UPDATE messages SET reactions_json = COALESCE(reactions_json, ?2), \
                       reply_json = COALESCE(reply_json, ?3), \
                       edited_ts = COALESCE(edited_ts, ?4), \
                       entities_json = CASE WHEN edited_ts IS NULL AND ?4 IS NOT NULL THEN ?7 \
                                       ELSE COALESCE(entities_json, ?7) END, \
                       body = CASE WHEN edited_ts IS NULL AND ?4 IS NOT NULL THEN ?5 ELSE body END, \
                       status = MAX(status, ?6) \
                     WHERE id = ?1 AND deleted = 0",
                    params![id, m.reactions_json, m.reply_json, m.edited_ts, m.body, m.status, m.entities_json],
                )?;
                continue;
            }
            let n = tx.execute(
                "INSERT OR IGNORE INTO messages (id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
                   wire_id, status, reply_json, edited_ts, reactions_json, sender_id, entities_json) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                params![
                    m.id,
                    m.chat_id,
                    m.ts,
                    m.body,
                    m.kind,
                    m.is_mine,
                    m.sender_label,
                    m.media_json,
                    m.wire_id,
                    m.status,
                    m.reply_json,
                    m.edited_ts,
                    m.reactions_json,
                    m.sender_id,
                    m.entities_json
                ],
            )?;
            if n > 0 {
                added += 1;
                if !touched.contains(&m.chat_id.as_str()) {
                    touched.push(&m.chat_id);
                }
            }
        }
        for c in touched {
            refresh_chat_preview(&tx, c)?;
        }
        tx.commit()?;
        Ok(added)
    })
}

// ── Encrypted parts waiting to upload (`<db>.transfer/`) ─────────────

pub(crate) fn dir_for(db: &Path) -> PathBuf {
    path_with_suffix(db, ".transfer")
}

fn current_dir() -> Option<PathBuf> {
    let guard = DB.lock().ok()?;
    guard.as_ref().map(|s| dir_for(&s.path))
}

fn bad_name() -> StorageError {
    StorageError::Io(std::io::Error::new(std::io::ErrorKind::InvalidInput, "part name must be 64 lowercase hex"))
}

/// Keep an encrypted part under [sha] until it is uploaded.
pub fn part_put(sha: &str, blob: &[u8]) -> Result<(), StorageError> {
    if !is_sha_hex(sha) {
        return Err(bad_name());
    }
    let dir = current_dir().ok_or(StorageError::NotInitialized)?;
    std::fs::create_dir_all(&dir)?;
    let tmp = dir.join(format!("{sha}.tmp"));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(blob)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, dir.join(sha)).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })?;
    Ok(())
}

pub fn part_get(sha: &str) -> Option<Vec<u8>> {
    if !is_sha_hex(sha) {
        return None;
    }
    std::fs::read(current_dir()?.join(sha)).ok()
}

/// Drop every waiting part (the transfer finished or was cancelled).
pub fn parts_clear() {
    if let Some(dir) = current_dir() {
        let _ = std::fs::remove_dir_all(dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{db_test_lock, fresh_db};
    use crate::NewMessage;

    fn msg(id: &str, chat: &str, ts: i64, body: &str, wire: Option<&str>) {
        crate::message_insert(&NewMessage {
            id,
            chat_id: chat,
            ts_unix: ts,
            body,
            kind: "text",
            is_mine: false,
            wire_id: wire,
            sender_id: Some("peer"),
            ..Default::default()
        })
        .unwrap();
    }

    fn all_messages() -> Vec<TMessage> {
        let mut out = Vec::new();
        for c in export_chat_ids().unwrap() {
            let mut after: Option<(i64, String)> = None;
            loop {
                let page = export_messages(&c, after.as_ref().map(|(t, i)| (*t, i.as_str())), 2).unwrap();
                if page.is_empty() {
                    break;
                }
                after = page.last().map(|m| (m.ts, m.id.clone()));
                out.extend(page);
            }
        }
        out
    }

    /// The old device's chats, history, people and settings merge into a
    /// new device that already got some of it through the device sync —
    /// nothing doubles, nothing the new device set itself is overwritten.
    /// BKP-1 — what a cloud backup (its root isn't signed by a device) may
    /// not bring: "verified" marks, and clocks from the future that would
    /// pin its values for ever.
    #[test]
    fn a_backup_brings_no_verified_marks_and_no_future_clocks() {
        let _db = db_test_lock();
        fresh_db("transfer_bkp1");
        let far = devsync::now_ms() + 400 * 24 * 3600 * 1000;
        let set = |k: &str, v: &str| TSetting { key: k.into(), value: v.into(), ts: far };
        let mut h = Header { settings: vec![set("verified:abcd", "1"), set("profile_name", "Planted")], ..Default::default() };
        strip_for_backup(&mut h);
        assert_eq!(import_header(&h).unwrap().settings, 1);
        assert_eq!(crate::setting_get("verified:abcd").unwrap(), None, "not taken from a backup");
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Planted"));
        let clock = crate::with_db(|c| local_clock(c, &devsync::setting_item("profile_name"))).unwrap().unwrap();
        assert!(clock <= devsync::now_ms() + 24 * 3600 * 1000, "the clock is cut to now + a day");
        // A device transfer (MLS, from my own device) still brings the marks.
        let h = Header { settings: vec![set("verified:abcd", "1")], ..Default::default() };
        import_header(&h).unwrap();
        assert_eq!(crate::setting_get("verified:abcd").unwrap().as_deref(), Some("1"));
    }

    #[test]
    fn old_device_state_merges_into_the_new_one() {
        let _db = db_test_lock();
        fresh_db("transfer_old");
        crate::chat_upsert("g1", "Anna", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
        crate::chat_upsert("g2", "Old group", true, false, false, 0, None, 1, "text", None, false, 2).unwrap();
        crate::chat_set_muted("g1", true).unwrap();
        crate::chat_set_pinned("g2", true).unwrap();
        crate::chat_set_disappear("g2", 0).unwrap();
        for i in 0..5 {
            msg(&format!("m{i}"), "g1", 100 + i, &format!("hello {i}"), Some(&format!("w{i}")));
        }
        msg("m5", "g2", 200, "in the group", Some("w5"));
        // Disappearing and deleted messages stay behind.
        crate::message_insert(&NewMessage {
            id: "gone",
            chat_id: "g1",
            ts_unix: 300,
            body: "secret",
            kind: "text",
            expire_at: Some(99_999_999_999),
            ..Default::default()
        })
        .unwrap();
        crate::contact_add("ab01", "Anna", 5).unwrap();
        crate::peer_set_blocked("ef03", true, 6).unwrap();
        crate::peer_name_set("ab01", "Anna K", 7).unwrap();
        crate::peer_bio_set("ab01", "hi", 7).unwrap();
        crate::call_append("call1", "g1", "audio", "completed", true, 50, Some(60), Some(10)).unwrap();
        crate::setting_set("profile_name", "Grisha").unwrap();
        crate::setting_set("theme", "dark").unwrap();
        crate::setting_set("wallpaper", "stars").unwrap();
        crate::setting_set("socks_proxy", "127.0.0.1:9050").unwrap();
        crate::setting_set("saved_chat_id", "g2").unwrap();
        let header = export_header("saved_chat_id").unwrap();
        let messages = all_messages();
        assert_eq!(export_message_count().unwrap(), 6);
        assert_eq!(messages.len(), 6, "paged through every chat");
        assert!(!messages.iter().any(|m| m.body == "secret"));
        assert!(!header.settings.iter().any(|s| s.key == "socks_proxy" || s.key == "saved_chat_id"));
        assert_eq!(header.saved_chat_id.as_deref(), Some("g2"));
        // Survives the wire (JSON) as is.
        let header: Header = serde_json::from_str(&serde_json::to_string(&header).unwrap()).unwrap();

        fresh_db("transfer_new");
        // Device sync already brought g1 (placeholder name, a history row).
        crate::chat_upsert("g1", "New chat", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
        crate::chat_set_request("g1", true).unwrap();
        msg("remote-w3", "g1", 103, "hello 3", Some("w3"));
        crate::setting_set("wallpaper", "mine").unwrap();
        let rep = import_header(&header).unwrap();
        assert_eq!(rep.chats_added, 1);
        assert_eq!(import_messages(&messages).unwrap(), 5, "w3 was already here");
        // Again (a resumed transfer): nothing more.
        assert_eq!(import_header(&header).unwrap().chats_added, 0);
        assert_eq!(import_messages(&messages).unwrap(), 0);

        let chats = crate::chats_list().unwrap();
        let g1 = chats.iter().find(|c| c.id == "g1").unwrap();
        assert!(g1.muted && !g1.request, "flags from the old device; not a request");
        assert_eq!(g1.last_msg_preview.as_deref(), Some("hello 4"));
        assert_eq!(g1.unread_count, 1, "only what was unread here");
        let g2 = chats.iter().find(|c| c.id == "g2").unwrap();
        assert!(g2.pinned && g2.is_group && g2.display_name == "Old group");
        assert_eq!(crate::messages_list_for_chat("g1", None).unwrap().len(), 5);
        assert_eq!(crate::contacts_list().unwrap()[0].name, "Anna");
        assert!(crate::peer_is_blocked("ef03").unwrap());
        assert_eq!(crate::peer_names().unwrap(), vec![("ab01".to_string(), "Anna K".to_string())]);
        assert_eq!(crate::peer_bios().unwrap()[0].1, "hi");
        assert_eq!(crate::calls_list().unwrap().len(), 1);
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Grisha"));
        assert_eq!(crate::setting_get("theme").unwrap().as_deref(), Some("dark"), "copied once");
        assert_eq!(crate::setting_get("wallpaper").unwrap().as_deref(), Some("mine"), "this device chose its own");
        assert_eq!(crate::setting_get("socks_proxy").unwrap(), None);
        // The transferred clock keeps the name from echoing back as "new".
        assert!(crate::devsync::pending(0).unwrap().0.iter().all(|i| i.key != "set:profile_name"));
    }

    #[test]
    fn parts_wait_encrypted_next_to_the_db_and_go_with_it() {
        let _db = db_test_lock();
        let path = fresh_db("transfer_parts");
        let sha = "cd".repeat(32);
        part_put(&sha, b"ciphertext").unwrap();
        assert_eq!(part_get(&sha).as_deref(), Some(&b"ciphertext"[..]));
        assert!(part_put("../etc", b"x").is_err());
        parts_clear();
        assert!(part_get(&sha).is_none());
        part_put(&sha, b"again").unwrap();
        crate::erase_and_reopen_plain(&path).unwrap();
        assert!(!dir_for(&path).exists());
    }
}
