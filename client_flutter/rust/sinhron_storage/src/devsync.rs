// Ongoing sync between my own devices — ADR-064.
//
// What a person sets on one of their devices (contacts, blocked people,
// a chat's mute / pin / archive, sticker packs, folders, profile, privacy
// switches) should be the same on the others. Each such thing is an
// *item* with a clock row in `sync_clock` (schema v16):
//
//   set:<key>        a setting from [`SYNCED_SETTINGS`] (value = the string)
//   chat:<id>        muted / archived / pinned / pin_order of a chat
//   read:<id>        read up to: the newest incoming message (unix s) that
//                    was read there (status 223 — read on one device, read
//                    on all; the notifications go too)
//   contact:<peer>   a contact (name, star, date); deleted = removed
//   blocked:<peer>   blocked; deleted = unblocked
//   pack:<id>        an added sticker pack (its index entry with the
//                    file's key); deleted = removed
//
// A local change stamps the item (wall-clock ms for last-writer-wins, a
// local sequence number for "not sent yet"). The app sends the stamped
// items with their *current* values to my other devices inside my
// own-devices MLS group (`DeviceSync`, sealed to my own delivery key), and
// a device applies an item only when its clock is newer than its own.
// Applying writes the value directly (no stamp) and keeps the sender's
// clock, so nothing echoes back.

use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

use crate::{stickers, with_db, StorageError};

/// Settings that follow the person to every device and stay equal.
pub const SYNCED_SETTINGS: &[&str] = &[
    "profile_name",
    "profile_avatar",
    "profile_about",
    "read_receipts",
    "typing_indicators",
    "show_online",
    "link_previews",
    "incoming_calls",
    "blocked_chats",
    "chat_folders",
    "chat_folder_layout",
    "sticker_recent",
    "emoji_recent",
    "emoji_tones",
    // ADR-084 — the account roots' current generation (made when one of my
    // devices is disconnected; it never gets it).
    "account_roots",
];

/// Prefixes of per-item settings that sync (`verified:<chat id>`;
/// `device_name:<device key>` — the name each of my devices gives itself;
/// `device_revoked:<device key>` — PAIR-1: a device I disconnected).
const SYNCED_PREFIXES: &[&str] = &["verified:", "device_name:", REVOKED_DEVICE_PREFIX];

/// PAIR-1 (ADR-104) — my devices remember the devices I disconnected: the
/// server's (unsigned) list can't bring one back into my chats. "1" =
/// disconnected; pairing the same key again by QR clears it ("").
const REVOKED_DEVICE_PREFIX: &str = "device_revoked:";

pub fn device_revoked_set(device_pk_hex: &str, revoked: bool) -> Result<(), crate::StorageError> {
    crate::setting_set(&format!("{REVOKED_DEVICE_PREFIX}{device_pk_hex}"), if revoked { "1" } else { "" })
}

pub fn device_revoked(device_pk_hex: &str) -> bool {
    crate::setting_get(&format!("{REVOKED_DEVICE_PREFIX}{device_pk_hex}")).ok().flatten().as_deref() == Some("1")
}

/// The server's device list without the ones I disconnected.
pub fn without_revoked_devices(keys: Vec<Vec<u8>>) -> Vec<Vec<u8>> {
    keys.into_iter().filter(|k| !device_revoked(&hex::encode(k))).collect()
}

/// Settings a new device takes once, at the transfer, as its starting
/// point; after that each device keeps its own (how it looks and sounds).
pub const COPIED_ONCE_SETTINGS: &[&str] = &[
    "theme",
    "accent",
    "wallpaper",
    "language",
    "haptics",
    "ui_sounds",
    "in_app_banners",
    "icon_badge",
    "notification_preview",
    "calls_reserve_always",
];

pub fn is_synced_setting(key: &str) -> bool {
    SYNCED_SETTINGS.contains(&key) || SYNCED_PREFIXES.iter().any(|p| key.starts_with(p) && key.len() > p.len())
}

pub fn is_copied_once_setting(key: &str) -> bool {
    COPIED_ONCE_SETTINGS.contains(&key)
}

/// One synced item with its clock and current value.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SyncItem {
    pub key: String,
    /// Wall-clock ms of the change (last writer wins).
    pub ts: i64,
    pub deleted: bool,
    /// The value: a setting's string, JSON for the rest; empty when deleted.
    pub value: String,
}

pub fn chat_item(id: &str) -> String {
    format!("chat:{id}")
}
pub fn read_item(id: &str) -> String {
    format!("read:{id}")
}
pub fn contact_item(peer: &str) -> String {
    format!("contact:{}", peer.to_lowercase())
}
pub fn blocked_item(peer: &str) -> String {
    format!("blocked:{peer}")
}
pub fn setting_item(key: &str) -> String {
    format!("set:{key}")
}
pub fn pack_item(id: &str) -> String {
    format!("pack:{id}")
}

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Record a local change of [item] (later than any clock it had).
pub(crate) fn stamp(conn: &Connection, item: &str, deleted: bool) -> Result<(), StorageError> {
    let old: Option<i64> =
        conn.query_row("SELECT ts FROM sync_clock WHERE item = ?", params![item], |r| r.get(0)).optional()?;
    let ts = now_ms().max(old.map_or(0, |t| t.saturating_add(1)));
    conn.execute(
        "INSERT INTO sync_clock (item, ts, seq, local, deleted) \
         VALUES (?1, ?2, (SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_clock), 1, ?3) \
         ON CONFLICT(item) DO UPDATE SET ts = excluded.ts, seq = excluded.seq, local = 1, deleted = excluded.deleted",
        params![item, ts, deleted],
    )?;
    Ok(())
}

/// Keep another device's clock for [item] (after applying its value).
pub(crate) fn set_clock(conn: &Connection, item: &str, ts: i64, deleted: bool) -> Result<(), StorageError> {
    conn.execute(
        "INSERT INTO sync_clock (item, ts, seq, local, deleted) VALUES (?1, ?2, 0, 0, ?3) \
         ON CONFLICT(item) DO UPDATE SET ts = excluded.ts, seq = 0, local = 0, deleted = excluded.deleted",
        params![item, ts, deleted],
    )?;
    Ok(())
}

pub(crate) fn clock_of(conn: &Connection, item: &str) -> Result<Option<i64>, StorageError> {
    Ok(conn.query_row("SELECT ts FROM sync_clock WHERE item = ?", params![item], |r| r.get(0)).optional()?)
}

/// Synced settings set before ADR-064 (schema v16) have no clock, so
/// DeviceSync never sent them (owner, 2026-10-26: the name and photo
/// didn't reach the new device). Each such value gets the oldest clock
/// (1): it goes out to my other devices, and a real change made there (a
/// newer clock) still wins. Run on every open; does nothing once stamped.
pub(crate) fn stamp_unclocked_settings(conn: &Connection) -> Result<usize, StorageError> {
    let mut n = 0;
    for key in SYNCED_SETTINGS {
        if !conn.prepare("SELECT 1 FROM settings WHERE key = ?")?.exists(params![key])? {
            continue;
        }
        let item = setting_item(key);
        if clock_of(conn, &item)?.is_some() {
            continue;
        }
        conn.execute(
            "INSERT INTO sync_clock (item, ts, seq, local, deleted) \
             VALUES (?1, 1, (SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_clock), 1, 0)",
            params![item],
        )?;
        n += 1;
    }
    Ok(n)
}

/// `setting_set` hook: a synced setting changed here; the sticker pack
/// index changed → stamp the packs that were added, changed or removed.
pub(crate) fn on_setting_set(conn: &Connection, key: &str, old: Option<&str>, new: &str) -> Result<(), StorageError> {
    if is_synced_setting(key) {
        if old != Some(new) {
            stamp(conn, &setting_item(key), false)?;
        }
    } else if key == stickers::INDEX_SETTING {
        let before = pack_entries(old.unwrap_or("[]"));
        let after = pack_entries(new);
        for (id, entry) in &after {
            if before.iter().find(|(i, _)| i == id).map(|(_, e)| e) != Some(entry) {
                stamp(conn, &pack_item(id), false)?;
            }
        }
        for (id, _) in &before {
            if !after.iter().any(|(i, _)| i == id) {
                stamp(conn, &pack_item(id), true)?;
            }
        }
    }
    Ok(())
}

/// (id, entry without the device-local share info) of a pack index.
fn pack_entries(index_json: &str) -> Vec<(String, Value)> {
    let Ok(Value::Array(list)) = serde_json::from_str::<Value>(index_json) else {
        return Vec::new();
    };
    list.into_iter()
        .filter_map(|mut e| {
            let id = e.get("id")?.as_str()?.to_string();
            if let Some(o) = e.as_object_mut() {
                o.remove("share");
            }
            Some((id, e))
        })
        .collect()
}

/// The pack file's sha256 named by an index entry.
pub fn pack_entry_sha(entry: &Value) -> Option<String> {
    entry.get("file")?.get("sha256")?.as_str().map(str::to_string)
}

/// The current value of [item] here; None = it is gone (deleted).
fn current_value(conn: &Connection, item: &str) -> Result<Option<String>, StorageError> {
    let (kind, id) = item.split_once(':').unwrap_or(("", ""));
    Ok(match kind {
        "set" => conn.query_row("SELECT value FROM settings WHERE key = ?", params![id], |r| r.get(0)).optional()?,
        "chat" => conn
            .query_row(
                "SELECT muted, archived, pinned, pin_order FROM chats WHERE id = ?",
                params![id],
                |r| {
                    Ok(json!({
                        "muted": r.get::<_, i64>(0)? != 0,
                        "archived": r.get::<_, i64>(1)? != 0,
                        "pinned": r.get::<_, i64>(2)? != 0,
                        "pin_order": r.get::<_, i64>(3)?,
                    })
                    .to_string())
                },
            )
            .optional()?,
        "read" => conn
            .query_row(
                "SELECT (SELECT COALESCE(MAX(ts_unix), 0) FROM messages WHERE chat_id = c.id AND is_mine = 0) \
                 FROM chats c WHERE c.id = ?",
                params![id],
                |r| Ok(json!({"up_to": r.get::<_, i64>(0)?}).to_string()),
            )
            .optional()?,
        "contact" => conn
            .query_row(
                "SELECT name, favourite, added_ts FROM contacts WHERE peer_id = ?",
                params![id],
                |r| {
                    Ok(json!({"name": r.get::<_, String>(0)?, "favourite": r.get::<_, bool>(1)?, "added_ts": r.get::<_, i64>(2)?})
                        .to_string())
                },
            )
            .optional()?,
        "blocked" => conn
            .query_row("SELECT blocked_ts FROM blocked_peers WHERE peer_id = ?", params![id], |r| {
                Ok(json!({"ts": r.get::<_, i64>(0)?}).to_string())
            })
            .optional()?,
        "pack" => {
            let index: Option<String> = conn
                .query_row("SELECT value FROM settings WHERE key = ?", params![stickers::INDEX_SETTING], |r| r.get(0))
                .optional()?;
            pack_entries(index.as_deref().unwrap_or("[]")).into_iter().find(|(i, _)| i == id).map(|(_, e)| e.to_string())
        }
        _ => None,
    })
}

fn items_where(conn: &Connection, sql: &str, p: impl rusqlite::Params) -> Result<Vec<SyncItem>, StorageError> {
    let rows: Vec<(String, i64, bool)> =
        conn.prepare(sql)?.query_map(p, |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<rusqlite::Result<_>>()?;
    let mut out = Vec::with_capacity(rows.len());
    for (key, ts, deleted) in rows {
        let value = if deleted { None } else { current_value(conn, &key)? };
        // A chat that is gone here says nothing (deleting a chat stays local).
        if value.is_none() && !deleted && (key.starts_with("chat:") || key.starts_with("read:")) {
            continue;
        }
        out.push(SyncItem { deleted: value.is_none(), value: value.unwrap_or_default(), key, ts });
    }
    Ok(out)
}

/// Local changes not yet sent (sequence above [after_seq]) and the highest
/// sequence among them (pass it back once they are sent).
pub fn pending(after_seq: i64) -> Result<(Vec<SyncItem>, i64), StorageError> {
    with_db(|conn| {
        let items = items_where(
            conn,
            "SELECT item, ts, deleted FROM sync_clock WHERE local = 1 AND seq > ? ORDER BY seq",
            params![after_seq],
        )?;
        let max: i64 = conn.query_row("SELECT COALESCE(MAX(seq), 0) FROM sync_clock", [], |r| r.get(0))?;
        Ok((items, max.max(after_seq)))
    })
}

/// Every item with a clock (a full snapshot — for a device that may have
/// missed something; the receiver keeps whatever is newer).
pub fn all_items() -> Result<Vec<SyncItem>, StorageError> {
    with_db(|conn| items_where(conn, "SELECT item, ts, deleted FROM sync_clock ORDER BY item", []))
}

/// What applying items changed (the app refreshes those screens).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Applied {
    pub settings: Vec<String>,
    pub chats: bool,
    pub contacts: bool,
    pub blocked: bool,
    pub packs: bool,
    /// Chats read on my other device (their notifications go here too).
    pub read: Vec<String>,
}

impl Applied {
    pub fn is_empty(&self) -> bool {
        self.settings.is_empty() && !self.chats && !self.contacts && !self.blocked && !self.packs && self.read.is_empty()
    }
}

/// Apply items from my other device: each only if its clock is newer
/// than the one here. Unknown or local-only settings are ignored.
pub fn apply(items: &[SyncItem]) -> Result<Applied, StorageError> {
    let removed_packs = with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut out = Applied::default();
        let mut removed = Vec::new();
        // DEV-2 — a clock from the future would pin the item for ever: no
        // later change, mine or another device's, could replace it.
        let horizon = now_ms().saturating_add(24 * 3600 * 1000);
        for it in items {
            // Cut, not dropped: a device of mine whose date ran ahead (or this
            // one's is behind) still syncs — as before 0.12.0.
            let ts = it.ts.min(horizon);
            if clock_of(&tx, &it.key)?.is_some_and(|t| t >= ts) {
                continue;
            }
            if apply_one(&tx, it, &mut out, &mut removed)? {
                set_clock(&tx, &it.key, ts, it.deleted)?;
            }
        }
        tx.commit()?;
        Ok((out, removed))
    })?;
    let (applied, removed) = removed_packs;
    for sha in removed {
        stickers::remove(&sha);
    }
    Ok(applied)
}

/// Write one item's value. Returns false when it doesn't apply here (an
/// unknown key, a chat this device doesn't have, a malformed value).
fn apply_one(conn: &Connection, it: &SyncItem, out: &mut Applied, removed: &mut Vec<String>) -> Result<bool, StorageError> {
    let Some((kind, id)) = it.key.split_once(':') else { return Ok(false) };
    if id.is_empty() {
        return Ok(false);
    }
    let v: Value = if it.deleted || kind == "set" { Value::Null } else { serde_json::from_str(&it.value).unwrap_or(Value::Null) };
    match kind {
        "set" => {
            if !is_synced_setting(id) {
                return Ok(false);
            }
            // PAIR-1 — "disconnected" only ever arrives as set: taking the mark
            // off is done by pairing the key again on the device that does it.
            if id.starts_with(REVOKED_DEVICE_PREFIX) && (it.deleted || it.value != "1") {
                return Ok(false);
            }
            if it.deleted {
                conn.execute("DELETE FROM settings WHERE key = ?", params![id])?;
            } else {
                conn.execute(
                    "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    params![id, it.value],
                )?;
            }
            out.settings.push(id.to_string());
        }
        "chat" => {
            if it.deleted || !v.is_object() {
                return Ok(false);
            }
            let b = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
            let n = conn.execute(
                "UPDATE chats SET muted = ?, archived = ?, pinned = ?, pin_order = ? WHERE id = ?",
                params![b("muted"), b("archived"), b("pinned"), v.get("pin_order").and_then(Value::as_i64).unwrap_or(0), id],
            )?;
            if n == 0 {
                return Ok(false);
            }
            out.chats = true;
        }
        "read" => {
            let Some(up_to) = v.get("up_to").and_then(Value::as_i64) else { return Ok(false) };
            // Read there up to that message: what came here after it stays
            // unread (it may not have reached that device yet).
            let after: i64 = conn.query_row(
                "SELECT COUNT(*) FROM messages WHERE chat_id = ? AND is_mine = 0 AND ts_unix > ?",
                params![id, up_to],
                |r| r.get(0),
            )?;
            let n = conn.execute(
                "UPDATE chats SET unread_count = MIN(unread_count, ?1), marked_unread = 0, \
                 mentioned = CASE WHEN ?1 = 0 THEN 0 ELSE mentioned END WHERE id = ?2",
                params![after, id],
            )?;
            if n == 0 {
                return Ok(false);
            }
            out.chats = true;
            out.read.push(id.to_string());
        }
        "contact" => {
            if it.deleted {
                conn.execute("DELETE FROM contacts WHERE peer_id = ?", params![id])?;
            } else {
                if !v.is_object() {
                    return Ok(false);
                }
                let name = v.get("name").and_then(Value::as_str).unwrap_or("");
                let fav = v.get("favourite").and_then(Value::as_bool).unwrap_or(false);
                let added = v.get("added_ts").and_then(Value::as_i64).unwrap_or(it.ts / 1000);
                conn.execute(
                    "INSERT INTO contacts (peer_id, name, favourite, added_ts) VALUES (?1, ?2, ?3, ?4) \
                     ON CONFLICT(peer_id) DO UPDATE SET favourite = excluded.favourite, \
                       name = CASE WHEN excluded.name <> '' THEN excluded.name ELSE contacts.name END",
                    params![id, name, fav, added],
                )?;
            }
            out.contacts = true;
        }
        "blocked" => {
            if it.deleted {
                conn.execute("DELETE FROM blocked_peers WHERE peer_id = ?", params![id])?;
            } else {
                let ts = v.get("ts").and_then(Value::as_i64).unwrap_or(it.ts / 1000);
                conn.execute(
                    "INSERT INTO blocked_peers (peer_id, blocked_ts) VALUES (?, ?) ON CONFLICT(peer_id) DO NOTHING",
                    params![id, ts],
                )?;
            }
            out.blocked = true;
        }
        "pack" => {
            if crate_is_builtin_pack(id) {
                return Ok(false);
            }
            let index: Option<String> = conn
                .query_row("SELECT value FROM settings WHERE key = ?", params![stickers::INDEX_SETTING], |r| r.get(0))
                .optional()?;
            let mut list = match index.as_deref().map(serde_json::from_str::<Value>) {
                Some(Ok(Value::Array(l))) => l,
                _ => Vec::new(),
            };
            let at = list.iter().position(|e| e.get("id").and_then(Value::as_str) == Some(id));
            if it.deleted {
                let Some(i) = at else { return Ok(true) };
                let gone = list.remove(i);
                if let Some(sha) = pack_entry_sha(&gone) {
                    removed.push(sha);
                }
            } else {
                if v.get("id").and_then(Value::as_str) != Some(id) || pack_entry_sha(&v).is_none_or(|s| !crate::blobs::is_sha_hex(&s)) {
                    return Ok(false);
                }
                match at {
                    Some(i) => {
                        let mut v = v;
                        // Keep this device's own share code.
                        if let (Some(share), Some(o)) = (list[i].get("share").cloned(), v.as_object_mut()) {
                            o.insert("share".into(), share);
                        }
                        let old = std::mem::replace(&mut list[i], v);
                        if pack_entry_sha(&old) != pack_entry_sha(&list[i]) {
                            if let Some(sha) = pack_entry_sha(&old) {
                                removed.push(sha);
                            }
                        }
                    }
                    None => list.push(v),
                }
            }
            conn.execute(
                "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![stickers::INDEX_SETTING, Value::Array(list).to_string()],
            )?;
            out.packs = true;
        }
        _ => return Ok(false),
    }
    Ok(true)
}

/// Built-in packs ship with the app (ADR-049) and are never added.
fn crate_is_builtin_pack(id: &str) -> bool {
    id.starts_with("sinhron.")
}

/// Packs in the index whose encrypted file isn't on this device yet
/// (synced or transferred from my other device): (sha256, blob size).
pub fn packs_missing_files() -> Result<Vec<String>, StorageError> {
    let index = crate::setting_get(stickers::INDEX_SETTING)?;
    Ok(pack_entries(index.as_deref().unwrap_or("[]"))
        .into_iter()
        .filter_map(|(_, e)| pack_entry_sha(&e))
        .filter(|sha| stickers::get(sha).is_none())
        .collect())
}

/// Files of every added pack (sha256) — what my other device needs.
pub fn pack_shas() -> Result<Vec<String>, StorageError> {
    let index = crate::setting_get(stickers::INDEX_SETTING)?;
    Ok(pack_entries(index.as_deref().unwrap_or("[]")).into_iter().filter_map(|(_, e)| pack_entry_sha(&e)).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{db_test_lock, fresh_db};

    fn chat(id: &str) {
        crate::chat_upsert(id, "Chat", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
    }

    fn get(items: &[SyncItem], key: &str) -> SyncItem {
        items.iter().find(|i| i.key == key).cloned().unwrap_or_else(|| panic!("no item {key}"))
    }

    /// A change on one device reaches the other, the older one never wins,
    /// and applying doesn't make the receiver send it back.
    #[test]
    fn changes_flow_to_my_other_device_last_writer_wins() {
        let _db = db_test_lock();
        fresh_db("devsync_a");
        chat("g1");
        crate::chat_set_muted("g1", true).unwrap();
        crate::chat_set_pinned("g1", true).unwrap();
        crate::contact_add("AB01", "Anna", 10).unwrap();
        crate::contact_set_favourite("ab01", true).unwrap();
        crate::contact_add("cd02", "Bob", 11).unwrap();
        crate::contact_remove("cd02").unwrap();
        crate::peer_set_blocked("ef03", true, 12).unwrap();
        crate::setting_set("profile_name", "Гриша").unwrap();
        crate::setting_set("chat_folders", "[{\"name\":\"Work\"}]").unwrap();
        crate::setting_set("verified:g1", "ab01").unwrap();
        // Local-only settings are never stamped.
        crate::setting_set("socks_proxy", "127.0.0.1:9050").unwrap();
        crate::setting_set("theme", "dark").unwrap();
        let (items, seq) = pending(0).unwrap();
        assert!(seq > 0);
        let keys: Vec<&str> = items.iter().map(|i| i.key.as_str()).collect();
        for k in ["chat:g1", "contact:ab01", "contact:cd02", "blocked:ef03", "set:profile_name", "set:chat_folders", "set:verified:g1"] {
            assert!(keys.contains(&k), "{k} missing from {keys:?}");
        }
        assert!(!keys.iter().any(|k| k.contains("socks") || k.contains("theme")));
        assert!(get(&items, "contact:cd02").deleted);
        assert!(get(&items, "chat:g1").value.contains("\"muted\":true"));
        // Nothing new after it was sent.
        assert!(pending(seq).unwrap().0.is_empty());

        fresh_db("devsync_b");
        chat("g1");
        // B learnt Bob earlier (from A, before A removed him).
        let bob = SyncItem { key: "contact:cd02".into(), ts: 1, deleted: false, value: json!({"name": "Bob"}).to_string() };
        apply(&[bob]).unwrap();
        assert_eq!(crate::contacts_list().unwrap().len(), 1);
        // Device B's own change of the name is later than A's.
        std::thread::sleep(std::time::Duration::from_millis(5));
        crate::setting_set("profile_name", "Grisha (B)").unwrap();
        let (_, b_seq) = pending(0).unwrap();
        let applied = apply(&items).unwrap();
        assert!(applied.chats && applied.contacts && applied.blocked);
        assert!(applied.settings.contains(&"chat_folders".to_string()));
        let c = crate::chats_list().unwrap().into_iter().find(|c| c.id == "g1").unwrap();
        assert!(c.muted && c.pinned);
        let contacts = crate::contacts_list().unwrap();
        assert_eq!(contacts.len(), 1, "Bob was removed on A");
        assert!(contacts[0].favourite && contacts[0].name == "Anna");
        assert!(crate::peer_is_blocked("ef03").unwrap());
        assert_eq!(crate::setting_get("chat_folders").unwrap().as_deref(), Some("[{\"name\":\"Work\"}]"));
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Grisha (B)"), "B's newer change stays");
        // Applied items aren't B's to send (no echo); applying twice is a no-op.
        let (after, _) = pending(b_seq).unwrap();
        assert!(after.is_empty(), "echo: {after:?}");
        assert!(apply(&items).unwrap().is_empty());
        // An unblock later on A undoes the block on B.
        let unblock = SyncItem { key: "blocked:ef03".into(), ts: get(&items, "blocked:ef03").ts + 1, deleted: true, value: String::new() };
        apply(&[unblock]).unwrap();
        assert!(!crate::peer_is_blocked("ef03").unwrap());
    }

    /// Status 223 — read on one device: read on the other, up to the same
    /// message (what reached only this device stays unread); reading again
    /// with nothing new doesn't send anything.
    #[test]
    fn read_on_one_device_is_read_on_the_other() {
        let _db = db_test_lock();
        let unread = |n: i64| {
            crate::with_db(|c| Ok(c.execute("UPDATE chats SET unread_count = ? WHERE id = 'g1'", params![n])?)).unwrap();
        };
        let unread_of = || crate::chats_list().unwrap().into_iter().find(|c| c.id == "g1").unwrap().unread_count;
        fresh_db("devsync_read_a");
        chat("g1");
        crate::message_append("m1", "g1", 100, "hi", "text", false, None).unwrap();
        crate::message_append("m2", "g1", 200, "there", "text", false, None).unwrap();
        unread(2);
        crate::chat_mark_read("g1").unwrap();
        let (items, seq) = pending(0).unwrap();
        assert!(get(&items, "read:g1").value.contains("\"up_to\":200"));
        crate::chat_mark_read("g1").unwrap();
        assert!(pending(seq).unwrap().0.iter().all(|i| i.key != "read:g1"), "nothing new to tell");

        fresh_db("devsync_read_b");
        chat("g1");
        crate::message_append("m1", "g1", 100, "hi", "text", false, None).unwrap();
        crate::message_append("m2", "g1", 200, "there", "text", false, None).unwrap();
        crate::message_append("m3", "g1", 300, "only here yet", "text", false, None).unwrap();
        unread(3);
        let applied = apply(&items).unwrap();
        assert_eq!(applied.read, vec!["g1".to_string()]);
        assert_eq!(unread_of(), 1, "m3 came after what was read there");
    }

    /// My other device can't write internal or this-device-only settings.
    /// A name set before device sync existed (no clock) still goes out,
    /// and a real change on the other device beats it (2026-10-26).
    #[test]
    fn settings_from_before_device_sync_go_out_once() {
        let _db = db_test_lock();
        fresh_db("devsync_unclocked");
        with_db(|c| {
            c.execute("INSERT INTO settings (key, value) VALUES ('profile_name', 'Гриша'), ('theme', 'dark')", [])?;
            c.execute("DELETE FROM sync_clock", [])?;
            Ok(())
        })
        .unwrap();
        assert!(pending(0).unwrap().0.is_empty(), "no clock: nothing would go out");
        assert_eq!(with_db(stamp_unclocked_settings).unwrap(), 1, "only synced settings with a value");
        let (items, _) = pending(0).unwrap();
        let name = get(&items, "set:profile_name");
        assert_eq!((name.ts, name.value.as_str()), (1, "Гриша"));
        assert_eq!(with_db(stamp_unclocked_settings).unwrap(), 0, "once");

        // The other device: no clock of its own for the name → takes it;
        // a name changed there later → keeps its own.
        fresh_db("devsync_unclocked_b");
        assert!(!apply(&[name.clone()]).unwrap().settings.is_empty());
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Гриша"));
        crate::setting_set("profile_name", "Grisha").unwrap();
        apply(&[name]).unwrap();
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Grisha"));
    }

    #[test]
    fn only_synced_settings_are_accepted() {
        let _db = db_test_lock();
        fresh_db("devsync_reject");
        let evil = |k: &str| SyncItem { key: format!("set:{k}"), ts: now_ms(), deleted: false, value: "x".into() };
        let applied = apply(&[evil("saved_chat_id"), evil("server_url"), evil("access_key:ab"), evil("verified:")]).unwrap();
        assert!(applied.is_empty());
        assert_eq!(crate::setting_get("saved_chat_id").unwrap(), None);
        assert!(apply(&[SyncItem { key: "chat:nope".into(), ts: 1, deleted: false, value: "{}".into() }]).unwrap().is_empty());
    }

    /// Each device's own name reaches my other devices (owner, 2026-11-01:
    /// the device list showed a code instead of a name).
    #[test]
    fn device_names_sync() {
        let _db = db_test_lock();
        fresh_db("devsync_device_name");
        assert!(is_synced_setting("device_name:ab12") && !is_synced_setting("device_name:"));
        let item = SyncItem { key: "set:device_name:ab12".into(), ts: now_ms(), deleted: false, value: "iPad Air".into() };
        assert_eq!(apply(&[item]).unwrap().settings.len(), 1);
        assert_eq!(crate::setting_get("device_name:ab12").unwrap().as_deref(), Some("iPad Air"));
    }

    /// DEV-2 — a device of mine (stolen, before I disconnect it) can't pin a
    /// setting for ever with a clock from the future.
    #[test]
    fn an_item_from_the_future_is_not_applied() {
        let _db = db_test_lock();
        fresh_db("devsync_future");
        let item = |ts: i64, v: &str| SyncItem { key: "set:profile_name".into(), ts, deleted: false, value: v.into() };
        // Applied (a device with a wrong date still syncs), but its clock is
        // cut to now + a day: it pins nothing.
        assert_eq!(apply(&[item(i64::MAX, "Ahead")]).unwrap().settings.len(), 1);
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Ahead"));
        let clock = crate::with_db(|c| clock_of(c, "set:profile_name")).unwrap().unwrap();
        assert!(clock <= now_ms() + 24 * 3600 * 1000);
        // The same item again (a weekly full sync) changes nothing.
        assert!(apply(&[item(i64::MAX, "Ahead")]).unwrap().settings.is_empty());
        crate::setting_set("profile_name", "Mine").unwrap(); // a later local change still wins
        assert_eq!(crate::setting_get("profile_name").unwrap().as_deref(), Some("Mine"));
        let clock = crate::with_db(|c| clock_of(c, "set:profile_name")).unwrap().unwrap();
        assert!(clock <= now_ms() + 24 * 3600 * 1000 + 1, "and a local change after it is sent on, not stuck in 2262");
    }

    /// PAIR-1 — a device I disconnected stays out whatever the server lists,
    /// on all my devices (the mark syncs), until I pair that key again.
    #[test]
    fn a_disconnected_device_is_remembered_and_synced() {
        let _db = db_test_lock();
        fresh_db("devsync_device_revoked");
        let (ipad, laptop) = (vec![0xab; 32], vec![0xcd; 32]);
        let listed = || without_revoked_devices(vec![ipad.clone(), laptop.clone()]);
        assert_eq!(listed().len(), 2);
        device_revoked_set(&hex::encode(&ipad), true).unwrap();
        assert_eq!(listed(), vec![laptop.clone()], "the server lists the iPad again: not addable");
        // The mark reaches my other devices with the settings sync.
        assert!(is_synced_setting(&format!("device_revoked:{}", hex::encode(&ipad))));
        let item = SyncItem { key: format!("set:device_revoked:{}", hex::encode(&laptop)), ts: now_ms(), deleted: false, value: "1".into() };
        assert_eq!(apply(&[item]).unwrap().settings.len(), 1);
        assert!(listed().is_empty());
        // NF-R2-1 — the mark can't be taken off by a sync message (a device being
        // disconnected could send one): only "1" is ever applied.
        let off = |deleted: bool| SyncItem {
            key: format!("set:device_revoked:{}", hex::encode(&laptop)),
            ts: now_ms() + 1000,
            deleted,
            value: String::new(),
        };
        assert!(apply(&[off(false), off(true)]).unwrap().settings.is_empty());
        assert!(listed().is_empty());
        // Paired again by QR (the owner's own act): allowed again.
        device_revoked_set(&hex::encode(&ipad), false).unwrap();
        assert_eq!(listed(), vec![ipad.clone()]);
    }

    /// Sticker packs: adding / removing one in the list stamps it; the other
    /// device takes the entry (and later the file), and drops removed ones.
    #[test]
    fn sticker_packs_follow_by_entry() {
        let _db = db_test_lock();
        fresh_db("devsync_packs_a");
        let sha = "ab".repeat(32);
        let entry = json!({"id": "me.cats", "title": "Cats", "count": 3, "file": {"sha256": sha, "key": "k", "blob_size": 10, "plain_size": 5}});
        crate::setting_set(stickers::INDEX_SETTING, &json!([entry]).to_string()).unwrap();
        // A new share code alone isn't a change for my other devices.
        let mut shared = entry.clone();
        shared["share"] = json!({"code": "c", "ts": 1});
        let (_, seq) = pending(0).unwrap();
        crate::setting_set(stickers::INDEX_SETTING, &json!([shared]).to_string()).unwrap();
        assert!(pending(seq).unwrap().0.is_empty());
        let (items, _) = pending(0).unwrap();
        let added = get(&items, "pack:me.cats");
        assert!(!added.deleted && !added.value.contains("share"));

        fresh_db("devsync_packs_b");
        assert!(apply(&[added.clone()]).unwrap().packs);
        assert_eq!(pack_shas().unwrap(), vec![sha.clone()]);
        assert_eq!(packs_missing_files().unwrap(), vec![sha.clone()]);
        crate::stickers::put(&sha, b"blob").unwrap();
        assert!(packs_missing_files().unwrap().is_empty());
        let removed = SyncItem { key: "pack:me.cats".into(), ts: added.ts + 1, deleted: true, value: String::new() };
        apply(&[removed]).unwrap();
        assert!(pack_shas().unwrap().is_empty());
        assert!(crate::stickers::get(&sha).is_none(), "the file goes too");
        // Built-in packs are app assets — never synced in.
        let builtin = SyncItem { key: "pack:sinhron.emotions".into(), ts: now_ms(), deleted: false, value: entry.to_string() };
        assert!(apply(&[builtin]).unwrap().is_empty());
    }
}
