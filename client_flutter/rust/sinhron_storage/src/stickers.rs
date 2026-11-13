// Sticker packs on this phone — ADR-049.
//
// Each pack the person added is one encrypted file (AES-256-GCM, the same
// `nonce‖ct‖tag` form as a media blob, made by `sinhron_sync::sticker`):
// `<db file>.stickers/<sha256 hex>`. The key and the list of packs live in
// the encrypted DB (setting [`INDEX_SETTING`]), so the files are useless
// without it. Kept apart from `<db>.blobs` on purpose: media copies are
// collected and cleared by their own rules (ADR-033), packs stay until the
// person removes them. Erasing the DB removes this directory too.

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::blobs::is_sha_hex;
use crate::{path_with_suffix, StorageError, DB};

/// Setting holding the JSON list of added packs (with their keys).
pub const INDEX_SETTING: &str = "sticker_packs";

pub(crate) fn dir_for(db: &Path) -> PathBuf {
    path_with_suffix(db, ".stickers")
}

fn current_dir() -> Option<PathBuf> {
    let guard = DB.lock().ok()?;
    guard.as_ref().map(|s| dir_for(&s.path))
}

fn bad_name() -> StorageError {
    StorageError::Io(std::io::Error::new(std::io::ErrorKind::InvalidInput, "pack name must be 64 lowercase hex"))
}

/// Keep [blob] (an encrypted pack) under [sha]; temp file + rename.
pub fn put(sha: &str, blob: &[u8]) -> Result<(), StorageError> {
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

/// The encrypted pack stored under [sha], if any.
pub fn get(sha: &str) -> Option<Vec<u8>> {
    if !is_sha_hex(sha) {
        return None;
    }
    std::fs::read(current_dir()?.join(sha)).ok()
}

pub fn remove(sha: &str) {
    if let (true, Some(dir)) = (is_sha_hex(sha), current_dir()) {
        let _ = std::fs::remove_file(dir.join(sha));
    }
}
