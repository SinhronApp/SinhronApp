// Chat backup — ADR-073. The FFI over `sinhron_sync::backup`: the ADR-064
// transfer machinery with a staging folder in place of the server, and a
// root sealed with the account's cloud backup key (from the 24 words, the
// device key that stands for them — ADR-021 — or a linked device's bundle).
// Each device's files go under its own tag (`chat_backup_tag`).
//
// The app drives it:
//   backup   — `chat_backup_step` writes, into the staging folder, the next
//              files the cloud doesn't have (names = SHA-256 of their bytes)
//              and, once the parts are written, `root.sinhron`; the app
//              uploads them (root last) and calls again until `done`; then
//              deletes from the cloud what `chat_backup_keep` doesn't list.
//   restore  — `chat_restore_info` opens a root; `chat_restore_start` sets
//              the import up; `chat_restore_step` merges what is in the
//              staging folder and names the next files it needs; then
//              `chat_restore_media` / `chat_restore_adopt` bring the media.

use std::path::PathBuf;

use sinhron_storage as storage;
use sinhron_sync as sync;
use sync::backup::{self as bk, DirTransport, ROOT_NAME};
use sync::transfer::{ExportJob, ExportStage, ImportJob, ImportStage, TransferError};

use super::simple::{account_roots, adopt_saved_chat, now_unix, roots_changed, roots_setting, SAVED_CHAT_SETTING};
use super::transfer::step_lock;

/// The backup under way (encrypted DB; survives the app closing).
const OUT_SETTING: &str = "backup_out";
/// Names the newest finished backup uses (for cleaning the cloud folder).
const KEEP_SETTING: &str = "backup_keep";
/// The restore under way.
const IN_SETTING: &str = "backup_in";

/// Where a backup run stands.
pub struct BackupProgress {
    /// "build" | "upload" | "media" | "done".
    pub stage: String,
    pub done: bool,
    /// Files now in the staging folder for the cloud (upload these first).
    pub files: Vec<String>,
    /// `root.sinhron` is in the staging folder too: upload it after [files].
    pub root_ready: bool,
    pub messages: u64,
    pub chats: u64,
    pub media_total: u64,
    pub media_checked: u64,
    pub media_uploaded: u64,
    /// Media this phone no longer has a copy of (not in the backup).
    pub media_missing: u64,
}

/// What a backup holds — for "Restore N messages from …?".
pub struct BackupInfo {
    pub created_ts: i64,
    pub messages: u64,
    pub chats: u64,
    pub media: u64,
}

/// Where a restore stands.
pub struct RestoreProgress {
    /// "manifest" | "parts" | "packs" | "done" | "failed".
    pub stage: String,
    /// Files to download into the staging folder before the next call.
    pub need: Vec<String>,
    pub done: bool,
    pub error: Option<String>,
    pub parts_done: u32,
    pub parts_total: u32,
    pub messages: u64,
    pub messages_added: u64,
    /// Something changed — refresh chats, contacts, settings…
    pub changed: bool,
}

fn backup_key_and_account(secret: &str) -> Result<([u8; 32], String), String> {
    bk::key_and_account(secret)
}

/// ADR-090 (storage-devices:14) — the server's note of this account's newest
/// backup in [cloud] ("icloud" / "drive"): [created_ts] > 0 says one made
/// then is there now; 0 only asks. Returns the newest known (0: none) — a
/// restore warns when the cloud has nothing that new (rolled back).
pub async fn chat_backup_mark(server_base_url: String, cloud: String, created_ts: i64) -> Result<i64, String> {
    let seed = super::simple::sync_slot().lock().await.as_ref().ok_or("sync not initialised")?.login_seed_bytes();
    sync::HttpApi::new(server_base_url).backup_mark(seed, &cloud, created_ts).await.map_err(|e| e.to_string())
}

/// This device's name prefix in the cloud folder (16 hex): the app keeps
/// the files as `<tag>-<name>`.
pub fn chat_backup_tag(secret: String) -> Result<String, String> {
    bk::device_tag(&secret)
}

/// Can this device back up? False on a linked device whose bundle predates
/// the backup key — `chat_backup_unlock` with the 24 words fixes that.
pub fn chat_backup_can(secret: String) -> bool {
    bk::key_and_account(&secret).is_ok()
}

/// With the 24 words: the device key to keep instead (the same device and
/// database, plus the backup key). "other_words" for another account's.
pub fn chat_backup_unlock(phrase: String, secret: String) -> Result<String, String> {
    bk::unlock_with_phrase(&phrase, &secret)
}

fn load<T: serde::de::DeserializeOwned>(key: &str) -> Option<T> {
    storage::setting_get(key).ok().flatten().filter(|s| !s.is_empty()).and_then(|s| serde_json::from_str(&s).ok())
}

fn save<T: serde::Serialize>(key: &str, v: Option<&T>) -> Result<(), String> {
    let s = v.map(|v| serde_json::to_string(v).expect("plain data serializes")).unwrap_or_default();
    storage::setting_set(key, &s).map_err(|e| e.to_string())
}

fn device_transfer_running() -> bool {
    sync::transfer::load_exports().iter().any(|j| !j.done())
        || sync::transfer::load_import().map(|j| !j.finished()).unwrap_or(false)
}

fn stage_name(s: ExportStage) -> &'static str {
    match s {
        ExportStage::Build => "build",
        ExportStage::Upload | ExportStage::Offer => "upload",
        ExportStage::Media => "media",
        ExportStage::Done => "done",
    }
}

/// Do the next piece of the backup: write up to about [budget_bytes] of
/// files the cloud lacks ([cloud_has]: names already there) into
/// [staging_dir]. Call again (after uploading) until `done`. A backup
/// interrupted by the app closing goes on from where it was.
pub async fn chat_backup_step(
    secret: String,
    staging_dir: String,
    cloud_has: Vec<String>,
    budget_bytes: u64,
) -> Result<BackupProgress, String> {
    let _l = step_lock().lock().await;
    if device_transfer_running() {
        return Err("a transfer to another device is running — the backup waits for it".into());
    }
    let (_, account) = backup_key_and_account(&secret)?;
    let mut job: ExportJob = load(OUT_SETTING).unwrap_or_else(|| {
        let now = now_unix() as i64;
        ExportJob::new(format!("backup-{now}"), "00".repeat(32), "backup".into(), now)
    });
    let t = DirTransport::new(PathBuf::from(&staging_dir), cloud_has);
    let mut root_ready = false;
    while !job.done() {
        let before = job.stage;
        let r = job.step(&t, SAVED_CHAT_SETTING).await;
        if matches!(&r, Err(TransferError::Storage(m)) if m.contains("waiting part")) {
            // A transfer to another device started meanwhile and cleared the
            // packed parts: this backup starts afresh next time.
            save::<ExportJob>(OUT_SETTING, None)?;
            return Err("interrupted by a transfer to another device — the backup starts again next time".into());
        }
        save(OUT_SETTING, Some(&job))?;
        r.map_err(|e| e.to_string())?;
        if before == ExportStage::Upload && job.stage == ExportStage::Offer {
            let root = bk::root_of(&job, &account).ok_or("no manifest")?;
            std::fs::create_dir_all(&staging_dir).map_err(|e| e.to_string())?;
            // ADR-084 — with the newest key (generation) of the account roots.
            let sealed = bk::seal_root_for(&secret, &account_roots(), &root)?;
            std::fs::write(PathBuf::from(&staging_dir).join(ROOT_NAME), sealed).map_err(|e| e.to_string())?;
            let media = sync::transfer::media_list(&job.id).map_err(|e| e.to_string())?;
            save(KEEP_SETTING, Some(&bk::keep_names(&job, &media)))?;
            root_ready = true;
            break; // parts + root up before the media
        }
        if t.written_bytes() >= budget_bytes {
            break;
        }
    }
    let done = job.done();
    let p = BackupProgress {
        stage: stage_name(job.stage).into(),
        done,
        files: t.written().into_iter().map(|(n, _)| n).collect(),
        root_ready,
        messages: job.messages,
        chats: job.chats,
        media_total: job.media_total,
        media_checked: job.media_checked,
        media_uploaded: job.media_uploaded,
        media_missing: job.media_missing,
    };
    if done {
        save::<ExportJob>(OUT_SETTING, None)?;
    }
    Ok(p)
}

/// Names the newest finished backup uses — everything else in the cloud
/// folder is left over from older ones (empty: no backup finished yet).
pub fn chat_backup_keep() -> Vec<String> {
    load(KEEP_SETTING).unwrap_or_default()
}

/// Drop a backup under way (it starts afresh next time).
pub async fn chat_backup_reset() -> Result<(), String> {
    let _l = step_lock().lock().await;
    if !device_transfer_running() {
        storage::transfer::parts_clear();
    }
    save::<ExportJob>(OUT_SETTING, None)
}

/// What the backup with [root] holds; an error if these words don't open
/// it (or it belongs to another account).
pub fn chat_restore_info(secret: String, root: Vec<u8>) -> Result<BackupInfo, String> {
    let (_, account) = backup_key_and_account(&secret)?;
    let r = bk::open_root_for(&secret, &account_roots(), &root).map_err(|e| e.to_string())?;
    if r.account != account {
        return Err("this backup belongs to another account".into());
    }
    if r.created_ts > now_unix() as i64 + bk::ROOT_FUTURE_SECS {
        return Err("this backup is dated in the future".into()); // BKP-1
    }
    Ok(BackupInfo { created_ts: r.created_ts, messages: r.messages, chats: r.chats, media: r.media })
}

/// Set up restoring the backup with [root] (replaces one under way).
pub async fn chat_restore_start(secret: String, root: Vec<u8>) -> Result<BackupInfo, String> {
    let info = chat_restore_info(secret.clone(), root.clone())?;
    let r = bk::open_root_for(&secret, &account_roots(), &root).map_err(|e| e.to_string())?;
    let job = ImportJob::from_offer(&r.offer().map_err(|e| e.to_string())?, bk::BACKUP_GROUP).map_err(|e| e.to_string())?;
    let _l = step_lock().lock().await;
    save(IN_SETTING, Some(&job))?;
    Ok(info)
}

/// Merge what is in [staging_dir]; stops when the next file isn't there
/// yet (`need`) or the restore is done.
pub async fn chat_restore_step(staging_dir: String) -> Result<RestoreProgress, String> {
    let _l = step_lock().lock().await;
    let mut job: ImportJob = load(IN_SETTING).ok_or("no restore under way")?;
    let t = DirTransport::new(PathBuf::from(&staging_dir), Vec::<String>::new());
    let mut changed = false;
    let mut need = Vec::new();
    let roots_before = roots_setting();
    let was_done = job.finished();
    while !job.finished() {
        match job.step(&t).await {
            Ok(Some(out)) => {
                changed |= out.chats || out.settings || out.packs;
                if let Some(saved) = out.saved_chat_id {
                    adopt_saved_chat(&saved);
                }
            }
            Ok(None) => break,
            Err(TransferError::Net(_)) if !t.needed().is_empty() => {
                need = t.needed();
                break;
            }
            Err(e) => {
                save(IN_SETTING, Some(&job))?;
                return Err(e.to_string());
            }
        }
        save(IN_SETTING, Some(&job))?;
    }
    save(IN_SETTING, Some(&job))?;
    // ADR-084 — the backup brought a newer generation of the account roots.
    let roots_were = roots_before.clone();
    roots_changed(roots_before).await;
    // BKP-1 (ADR-105) — a backup's root isn't signed by a device: the roots it
    // brought may be known to a device I disconnected. This device makes a
    // fresh generation; my other devices get it in my own-devices group.
    // Also as soon as the backup's roots are taken (a restore that then fails
    // or is abandoned must not leave them as the newest generation).
    let brought = roots_setting() != roots_were;
    if brought || (!was_done && job.stage == ImportStage::Done) {
        let before = super::simple::new_account_roots()?;
        roots_changed(before).await;
    }
    Ok(RestoreProgress {
        stage: match job.stage {
            ImportStage::Manifest => "manifest",
            ImportStage::Parts => "parts",
            ImportStage::Packs => "packs",
            ImportStage::Done => "done",
            ImportStage::Failed => "failed",
        }
        .into(),
        need,
        done: job.stage == ImportStage::Done,
        error: job.error.clone(),
        parts_done: if job.stage == ImportStage::Parts { job.next } else if job.finished() { job.parts.len() as u32 } else { 0 },
        parts_total: job.parts.len() as u32,
        messages: job.messages,
        messages_added: job.messages_added,
        changed,
    })
}

/// Media the restored messages point to that this phone has no copy of.
pub fn chat_restore_media() -> Result<Vec<String>, String> {
    bk::media_to_restore().map_err(|e| e.to_string())
}

/// Keep the media files downloaded into [staging_dir] ([names]) as local
/// copies (each checked against its name; the files are removed).
pub fn chat_restore_adopt(staging_dir: String, names: Vec<String>) -> Result<u32, String> {
    bk::adopt_media(&PathBuf::from(staging_dir), &names).map_err(|e| e.to_string())
}

/// Forget a finished (or abandoned) restore.
pub fn chat_restore_clear() -> Result<(), String> {
    save::<ImportJob>(IN_SETTING, None)
}
