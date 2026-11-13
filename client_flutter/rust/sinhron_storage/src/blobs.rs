// Local copies of encrypted media blobs — ADR-033.
//
// The server deletes a blob nobody has uploaded or fetched for 90 days
// (server `handlers/media.rs`). Before ADR-033 the app kept only the
// blob's key (in this DB) and downloaded the blob again on every cold
// open — so nothing opened offline, and a photo nobody looked at for
// three months was gone for everyone.
//
// Now the ciphertext exactly as the server stores it (`nonce‖ct‖tag`)
// is also kept next to the DB: `<db file>.blobs/<aa>/<sha256 hex>`.
// It is useless without the per-blob key, which lives only in
// `messages.media_json` inside the SQLCipher DB. Decrypted bytes still
// never touch the disk (`MediaCache`, spec §8.6).
//
// A file lives as long as a message row references its sha256:
//   • the delete paths (delete for me / for everyone, disappearing
//     timer, chat delete, wipe, replaced link preview) drop the files
//     their rows referenced, once no other row references them;
//   • [`gc`] (on every keyed open) removes anything else — an upload
//     that failed, a crash between writing the file and storing the
//     row — once it is older than [`GC_GRACE_SECS`];
//   • erasing the DB removes the whole directory.

use std::collections::HashSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, SystemTime};

use rusqlite::Connection;

use crate::{path_with_suffix, with_db, StorageError, DB};

/// Files younger than this are never collected: a send writes the blob
/// before its message row exists, and a fetch writes it while the row
/// may be mid-update.
pub const GC_GRACE_SECS: u64 = 24 * 3600;

/// `<db file>.blobs` — tied to the DB file, so erasing one erases both.
pub(crate) fn dir_for(db: &Path) -> PathBuf {
    path_with_suffix(db, ".blobs")
}

fn current_dir() -> Option<PathBuf> {
    let guard = DB.lock().ok()?;
    guard.as_ref().map(|s| dir_for(&s.path))
}

/// Lowercase 64-hex — the only names that reach the filesystem, so a
/// hostile `sha256` in a peer's message can't traverse paths.
pub fn is_sha_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn file_for(dir: &Path, sha: &str) -> PathBuf {
    dir.join(&sha[..2]).join(sha)
}

/// The stored ciphertext for [sha], if this device has it. None when
/// the DB isn't open (CLI, tests) or the name is invalid. The caller
/// verifies hash and size before decrypting (`media::decrypt`).
pub fn get(sha: &str) -> Option<Vec<u8>> {
    if !is_sha_hex(sha) {
        return None;
    }
    let path = file_for(&current_dir()?, sha);
    let bytes = std::fs::read(&path).ok()?;
    // Tech-debt 2.32 — "keep media copies for a month" counts from the last
    // time a copy was used, not from when it arrived.
    if let Ok(f) = std::fs::File::options().write(true).open(&path) {
        let _ = f.set_modified(SystemTime::now());
    }
    Some(bytes)
}

/// ADR-073 — whether this device has a local copy of [sha] (no read, and
/// the copy's age is left alone).
pub fn has(sha: &str) -> bool {
    is_sha_hex(sha) && current_dir().map(|d| file_for(&d, sha).is_file()).unwrap_or(false)
}

/// Keep [blob] as the local copy of [sha]. Written to a temp file and
/// renamed, so a crash never leaves a half-written blob under its name.
/// An existing copy of the same length is left as is.
pub fn put(sha: &str, blob: &[u8]) -> Result<(), StorageError> {
    if !is_sha_hex(sha) {
        return Err(StorageError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "blob name must be 64 lowercase hex",
        )));
    }
    let dir = current_dir().ok_or(StorageError::NotInitialized)?;
    let path = file_for(&dir, sha);
    if std::fs::metadata(&path).map(|m| m.len() == blob.len() as u64).unwrap_or(false) {
        return Ok(());
    }
    let parent = path.parent().expect("blob path has a parent");
    std::fs::create_dir_all(parent)?;
    // Unique per write: two loads of the same blob may race here.
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let tmp = parent.join(format!("{sha}.{}.tmp", SEQ.fetch_add(1, Ordering::Relaxed)));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(blob)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, &path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })?;
    Ok(())
}

/// Drop the local copy of [sha] (a copy that failed verification).
pub fn remove(sha: &str) {
    if let (true, Some(dir)) = (is_sha_hex(sha), current_dir()) {
        let _ = std::fs::remove_file(file_for(&dir, sha));
    }
}

/// Every blob hash a stored media / link-preview JSON references (file,
/// thumbnail, preview image): any `"sha256"` string field, at any depth.
pub fn shas_in(json: &str) -> Vec<String> {
    fn walk(v: &serde_json::Value, out: &mut Vec<String>) {
        match v {
            serde_json::Value::Object(m) => {
                for (k, v) in m {
                    match v {
                        serde_json::Value::String(s) if k == "sha256" && is_sha_hex(s) => out.push(s.clone()),
                        _ => walk(v, out),
                    }
                }
            }
            serde_json::Value::Array(a) => a.iter().for_each(|v| walk(v, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
        walk(&v, &mut out);
    }
    out
}

/// Blob hashes referenced by the `media_json` column [sql] selects —
/// read inside a delete's transaction, before the rows go.
pub(crate) fn shas_of(
    conn: &Connection,
    sql: &str,
    p: impl rusqlite::Params,
) -> Result<Vec<String>, StorageError> {
    let mut out = Vec::new();
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map(p, |r| r.get::<_, Option<String>>(0))?;
    for json in rows {
        if let Some(j) = json? {
            out.extend(shas_in(&j));
        }
    }
    Ok(out)
}

/// After a delete committed: remove the files of [candidates] that no
/// remaining row references. Best-effort — [`gc`] catches what's left.
pub(crate) fn drop_unreferenced(candidates: Vec<String>) {
    if candidates.is_empty() {
        return;
    }
    let unique: HashSet<String> = candidates.into_iter().collect();
    let gone: Vec<String> = with_db(|conn| {
        let mut stmt = conn.prepare("SELECT EXISTS(SELECT 1 FROM messages WHERE media_json LIKE ?)")?;
        let mut gone = Vec::new();
        for sha in unique {
            // `sha` is 64 hex (shas_in checked) — no LIKE metacharacters.
            let used: bool = stmt.query_row([format!("%{sha}%")], |r| r.get(0))?;
            if !used {
                gone.push(sha);
            }
        }
        Ok(gone)
    })
    .unwrap_or_default();
    if let Some(dir) = current_dir() {
        for sha in gone {
            let _ = std::fs::remove_file(file_for(&dir, &sha));
        }
    }
}

/// Remove every local blob no message references, except files younger
/// than [grace]. Returns how many files were removed.
pub fn gc(grace: Duration) -> Result<usize, StorageError> {
    let Some(dir) = current_dir() else { return Err(StorageError::NotInitialized) };
    let referenced: HashSet<String> = with_db(|conn| {
        shas_of(conn, "SELECT media_json FROM messages WHERE media_json IS NOT NULL", [])
    })?
    .into_iter()
    .collect();
    let Ok(shards) = std::fs::read_dir(&dir) else { return Ok(0) };
    let now = SystemTime::now();
    let mut removed = 0;
    for shard in shards.flatten() {
        let Ok(files) = std::fs::read_dir(shard.path()) else { continue };
        for f in files.flatten() {
            let name = f.file_name().to_string_lossy().into_owned();
            if referenced.contains(&name) {
                continue;
            }
            let old = f
                .metadata()
                .and_then(|m| m.modified())
                .map(|t| now.duration_since(t).unwrap_or_default() >= grace)
                .unwrap_or(false);
            if old && std::fs::remove_file(f.path()).is_ok() {
                removed += 1;
            }
        }
    }
    Ok(removed)
}

/// Space this phone uses for messages (tech-debt 2.32) — the Storage
/// screen. Local media copies by kind and by chat, plus the database.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Usage {
    pub photos: u64,
    pub videos: u64,
    pub voice: u64,
    pub documents: u64,
    /// Link-preview images and anything else with a blob.
    pub other: u64,
    /// Copies no message references yet (a send in flight) or any more
    /// (removed on the next start, [`gc`]).
    pub unreferenced: u64,
    /// `sinhron.db` with its WAL / SHM files.
    pub database: u64,
    /// (chat id, bytes of its media copies), heaviest first.
    pub by_chat: Vec<(String, u64)>,
}

impl Usage {
    pub fn media_total(&self) -> u64 {
        self.photos + self.videos + self.voice + self.documents + self.other + self.unreferenced
    }
}

/// Sizes of every local copy, by sha.
fn sizes_in(dir: &Path) -> std::collections::HashMap<String, u64> {
    let mut out = std::collections::HashMap::new();
    let Ok(shards) = std::fs::read_dir(dir) else { return out };
    for shard in shards.flatten() {
        let Ok(files) = std::fs::read_dir(shard.path()) else { continue };
        for f in files.flatten() {
            let name = f.file_name().to_string_lossy().into_owned();
            if let Ok(m) = f.metadata() {
                if m.is_file() {
                    out.insert(name, m.len());
                }
            }
        }
    }
    out
}

/// How much space messages take here. A copy shared by several messages
/// counts once, for the oldest one's chat and kind.
pub fn usage() -> Result<Usage, StorageError> {
    let (dir, db_path) = {
        let guard = DB.lock().map_err(|_| StorageError::NotInitialized)?;
        let s = guard.as_ref().ok_or(StorageError::NotInitialized)?;
        (dir_for(&s.path), s.path.clone())
    };
    let mut sizes = sizes_in(&dir);
    let rows: Vec<(String, String, String)> = with_db(|conn| {
        let mut stmt = conn.prepare(
            "SELECT chat_id, kind, media_json FROM messages WHERE media_json IS NOT NULL ORDER BY ts_unix, id",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        Ok(rows.collect::<Result<Vec<_>, _>>()?)
    })?;
    let mut u = Usage::default();
    let mut by_chat = std::collections::HashMap::<String, u64>::new();
    for (chat, kind, json) in rows {
        for sha in shas_in(&json) {
            let Some(n) = sizes.remove(&sha) else { continue };
            *match kind.as_str() {
                "photo" => &mut u.photos,
                "video" => &mut u.videos,
                "voice" => &mut u.voice,
                "document" => &mut u.documents,
                _ => &mut u.other,
            } += n;
            *by_chat.entry(chat.clone()).or_default() += n;
        }
    }
    u.unreferenced = sizes.values().sum();
    u.database = ["", "-wal", "-shm"]
        .iter()
        .filter_map(|s| std::fs::metadata(crate::path_with_suffix(&db_path, s)).ok())
        .map(|m| m.len())
        .sum();
    u.by_chat = by_chat.into_iter().collect();
    u.by_chat.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    Ok(u)
}

/// "Clear media copies": delete every local copy older than [min_age]
/// (younger ones may be a send in progress). Messages keep their keys —
/// a file opens again from the server while the server still has it
/// (90 days after anyone last loaded it). Returns the bytes freed.
pub fn clear_copies(min_age: Duration) -> Result<u64, StorageError> {
    let dir = current_dir().ok_or(StorageError::NotInitialized)?;
    let Ok(shards) = std::fs::read_dir(&dir) else { return Ok(0) };
    let now = SystemTime::now();
    let mut freed = 0;
    for shard in shards.flatten() {
        let Ok(files) = std::fs::read_dir(shard.path()) else { continue };
        for f in files.flatten() {
            let Ok(m) = f.metadata() else { continue };
            let old = m.modified().map(|t| now.duration_since(t).unwrap_or_default() >= min_age).unwrap_or(false);
            if m.is_file() && old && std::fs::remove_file(f.path()).is_ok() {
                freed += m.len();
            }
        }
    }
    Ok(freed)
}
