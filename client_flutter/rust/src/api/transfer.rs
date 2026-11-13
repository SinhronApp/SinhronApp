// Device transfer and ongoing sync between my own devices — ADR-064.
//
// The FFI over `sinhron_sync::transfer` (the full hand-over to a newly
// linked device) and `sinhron_storage::devsync` (contacts, packs,
// settings… kept equal afterwards). Both travel inside my own-devices
// group — "Saved messages" (ADR-055), a group of nobody but my devices —
// as MLS messages sealed only to my own delivery key; bulk data goes as
// encrypted blobs through the media store. The server sees ciphertext.
//
// The app drives the work: `device_transfer_step` does one piece and
// returns where things stand (call it until it returns None),
// `device_sync_flush` sends what changed here.

use sinhron_storage::{self as storage, devsync};
use sinhron_sync as sync;
use sync::envelope::{Decoded, SyncEntry, TRANSFER_CANCELLED, TRANSFER_MEDIA_DONE, TRANSFER_OFFER};
use sync::transfer::{ExportJob, ExportStage, ImportJob, ImportStage, TransferError};

use super::simple::{adopt_saved_chat, now_unix, own_delivery_key, send_sealed_to_self, sync_slot, SAVED_CHAT_SETTING};

/// Where one transfer stands, for the progress card.
pub struct TransferStatus {
    /// From this device to a new one (false: to this device).
    pub outgoing: bool,
    /// The other device's key (outgoing), '' for incoming.
    pub device_hex: String,
    /// Outgoing: "build" | "upload" | "offer" | "media" | "done".
    /// Incoming: "manifest" | "parts" | "packs" | "done" | "failed".
    pub stage: String,
    /// Progress through the current stage (done / total, both may be 0).
    pub done: u32,
    pub total: u32,
    pub messages: u32,
    pub chats: u32,
    pub media_total: u32,
    pub media_done: u32,
    /// Media neither the server nor the old device still had.
    pub media_missing: u32,
    /// Incoming: the old device has finished putting media on the server.
    pub media_ready: bool,
    pub error: Option<String>,
}

fn export_status(j: &ExportJob) -> TransferStatus {
    let (stage, done, total) = match j.stage {
        ExportStage::Build => ("build", 0, 0),
        ExportStage::Upload => ("upload", j.uploaded, (j.packs.len() + j.parts.len() + 1) as u32),
        ExportStage::Offer => ("offer", 0, 0),
        ExportStage::Media => ("media", j.media_checked as u32, j.media_total as u32),
        ExportStage::Done => ("done", 0, 0),
    };
    TransferStatus {
        outgoing: true,
        device_hex: j.device_hex.clone(),
        stage: stage.into(),
        done,
        total,
        messages: j.messages as u32,
        chats: j.chats as u32,
        media_total: j.media_total as u32,
        media_done: j.media_checked.saturating_sub(j.media_queue.len() as u64) as u32,
        media_missing: j.media_missing as u32,
        media_ready: j.done(),
        error: None,
    }
}

fn import_status(j: &ImportJob) -> TransferStatus {
    let (stage, done, total) = match j.stage {
        ImportStage::Manifest => ("manifest", 0, 0),
        ImportStage::Parts => ("parts", j.next, j.parts.len() as u32),
        ImportStage::Packs => ("packs", 0, j.packs.len() as u32),
        ImportStage::Done => ("done", 0, 0),
        ImportStage::Failed => ("failed", 0, 0),
    };
    TransferStatus {
        outgoing: false,
        device_hex: String::new(),
        stage: stage.into(),
        done,
        total,
        // Finished: what really landed here (2026-10-26 — "Done — 0
        // messages moved" while some had arrived; the old device's count
        // isn't what this one took in).
        messages: if j.stage == ImportStage::Done { j.messages_added as u32 } else { j.messages as u32 },
        chats: 0,
        media_total: j.media as u32,
        media_done: 0,
        media_missing: j.media_missing as u32,
        media_ready: j.media_done,
        error: j.error.clone(),
    }
}

/// Every transfer this device knows of (finished ones until dismissed).
#[flutter_rust_bridge::frb(sync)]
pub fn device_transfer_status() -> Vec<TransferStatus> {
    let mut out: Vec<TransferStatus> = sync::transfer::load_exports().iter().map(export_status).collect();
    if let Some(j) = sync::transfer::load_import() {
        out.push(import_status(&j));
    }
    out
}

/// The app's transport: blobs through the media API, messages through my
/// own-devices group.
struct AppTransport {
    http: sync::HttpApi,
    seed: [u8; 32],
}

fn net_err(e: sync::HttpError) -> TransferError {
    match e {
        sync::HttpError::Server { status: 404, body } => TransferError::Gone(body),
        sync::HttpError::Server { status, body } if (400..500).contains(&status) && status != 429 && status != 408 => {
            TransferError::Bad(format!("{status} {body}"))
        }
        other => TransferError::Net(other.to_string()),
    }
}

impl sync::transfer::Transport for AppTransport {
    async fn upload(&self, blob: Vec<u8>) -> Result<(), TransferError> {
        self.http.upload_media(self.seed, blob).await.map(|_| ()).map_err(net_err)
    }

    async fn download(&self, sha_hex: &str) -> Result<Vec<u8>, TransferError> {
        self.http.download_media(self.seed, sha_hex).await.map_err(net_err)
    }

    async fn touch(&self, shas: &[String]) -> Result<Vec<String>, TransferError> {
        match self.http.touch_media(self.seed, shas).await {
            Ok(missing) => Ok(missing),
            // A server from before ADR-064: treat all as missing (uploading a
            // blob it has is a no-op there).
            Err(sync::HttpError::Server { status: 404 | 405, .. }) => Ok(shas.to_vec()),
            Err(e) => Err(net_err(e)),
        }
    }

    async fn send_own(&self, group_hex: &str, plaintext: Vec<u8>) -> Result<(), TransferError> {
        let group = hex::decode(group_hex).map_err(|_| TransferError::Bad("group id".into()))?;
        // Never into a chat with other people in it.
        let own = {
            let mut slot = sync_slot().lock().await;
            let c = slot.as_mut().ok_or_else(|| TransferError::Net("sync not initialised".into()))?;
            c.is_own_devices_group(&group).map_err(|e| TransferError::Bad(e.to_string()))?
        };
        if !own {
            return Err(TransferError::Bad("not my own-devices group".into()));
        }
        let key = own_delivery_key().await.map_err(TransferError::Net)?;
        send_sealed_to_self(&group, &plaintext, &key).await.map_err(TransferError::Net)
    }
}

async fn transport(server_base_url: String) -> Result<AppTransport, String> {
    let seed = {
        let slot = sync_slot().lock().await;
        slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes()
    };
    Ok(AppTransport { http: sync::HttpApi::new(server_base_url), seed })
}

/// One step at a time across the app (the loop and a button can't race).
pub(crate) fn step_lock() -> &'static tokio::sync::Mutex<()> {
    static L: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
    L.get_or_init(|| tokio::sync::Mutex::new(()))
}

/// Send everything to my device [device_pk_hex] (again) — e.g. a device
/// linked before ADR-064, or a transfer that failed. Needs my
/// own-devices group with that device in it (the app makes "Saved
/// messages" and runs device sync first).
pub async fn device_transfer_start(device_pk_hex: String) -> Result<(), String> {
    let group_hex = storage::setting_get(SAVED_CHAT_SETTING)
        .map_err(|e| e.to_string())?
        .filter(|g| !g.is_empty())
        .ok_or("no own-devices group yet")?;
    let group = hex::decode(&group_hex).map_err(|e| e.to_string())?;
    let device = hex::decode(&device_pk_hex).map_err(|e| e.to_string())?;
    {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let me: [u8; 32] = hex::decode(c.identity_pubkey_hex()).ok().and_then(|v| v.try_into().ok()).ok_or("bad identity")?;
        if device == c.device_public_key() {
            return Err("that is this device".into());
        }
        if !c.group_device_keys(&group, &me).map_err(|e| e.to_string())?.contains(&device) {
            return Err("that device isn't in my own-devices group yet".into());
        }
    }
    let _l = step_lock().lock().await;
    sync::transfer::queue_export(&device_pk_hex, &group_hex, now_unix() as i64).map_err(|e| e.to_string())?;
    let _ = storage::setting_set(&super::simple::transfer_sent_key(&device), &now_unix().to_string());
    Ok(())
}

/// Do the next piece of a transfer — outgoing first, then incoming — and
/// return where it stands; None when there is nothing to do. On a network
/// error nothing moved: call again later.
pub async fn device_transfer_step(server_base_url: String) -> Result<Option<TransferStatus>, String> {
    let _l = step_lock().lock().await;
    let mut jobs = sync::transfer::load_exports();
    if let Some(i) = jobs.iter().position(|j| !j.done()) {
        let t = transport(server_base_url).await?;
        let r = jobs[i].step(&t, SAVED_CHAT_SETTING).await;
        if let Err(TransferError::Bad(e)) = &r {
            // Can't ever work (the group isn't only mine any more, the device
            // key is malformed…): drop it instead of retrying forever.
            tracing::warn!(error = %e, "device transfer dropped");
            jobs.remove(i);
            storage::transfer::parts_clear();
        }
        sync::transfer::save_exports(&jobs).map_err(|e| e.to_string())?;
        r.map_err(|e| e.to_string())?;
        return Ok(Some(export_status(&jobs[i])));
    }
    let Some(mut job) = sync::transfer::load_import().filter(|j| !j.finished()) else { return Ok(None) };
    let t = transport(server_base_url).await?;
    let before = super::simple::roots_setting();
    let r = job.step(&t).await;
    super::simple::roots_changed(before).await;
    sync::transfer::save_import(Some(&job)).map_err(|e| e.to_string())?;
    // XFER-6 — "Saved messages" is only ever the own-devices group the transfer
    // came through (never a chat with other people in it).
    if let Some(saved) = r.map_err(|e| e.to_string())?.and_then(|out| out.saved_chat_id).filter(|s| *s == job.group_hex) {
        adopt_saved_chat(&saved);
    }
    Ok(Some(import_status(&job)))
}

/// Forget a finished (or failed) transfer card; an unfinished outgoing one
/// is cancelled (the new device is told).
pub async fn device_transfer_dismiss(server_base_url: String, outgoing: bool, device_hex: String) -> Result<(), String> {
    let _l = step_lock().lock().await;
    if !outgoing {
        return sync::transfer::save_import(None).map_err(|e| e.to_string());
    }
    let mut jobs = sync::transfer::load_exports();
    if let Some(j) = jobs.iter().find(|j| j.device_hex == device_hex && !j.done()) {
        // Best effort: the new device stops waiting.
        if let (Ok(device), Ok(t)) = (hex::decode(&j.device_hex), transport(server_base_url).await) {
            let msg = sync::envelope::Transfer { id: j.id.clone(), target_device: device, stage: TRANSFER_CANCELLED, ..Default::default() };
            let _ = sync::transfer::Transport::send_own(&t, &j.group_hex, sync::envelope::encode_transfer(msg)).await;
        }
        storage::transfer::parts_clear();
    }
    jobs.retain(|j| j.device_hex != device_hex);
    sync::transfer::save_exports(&jobs).map_err(|e| e.to_string())
}

/// What `push_event` hands Dart for an own-devices message (JSON), or None
/// when it isn't from me in a group of only me (then it is dropped).
pub(crate) async fn on_own_message(plaintext: &[u8], sender_hex: &str, group_id: &[u8]) -> Option<String> {
    let decoded = sync::envelope::decode(plaintext).ok()?;
    if !matches!(decoded, Decoded::Transfer(_) | Decoded::DeviceSync { .. }) {
        return None;
    }
    let my_device = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut()?;
        if c.identity_pubkey_hex() != sender_hex || !c.is_own_devices_group(group_id).unwrap_or(false) {
            return None;
        }
        c.device_public_key()
    };
    let group_hex = hex::encode(group_id);
    match decoded {
        Decoded::Transfer(t) => {
            if t.target_device != my_device {
                return Some(serde_json::json!({"for_me": false}).to_string());
            }
            let _l = step_lock().lock().await;
            let started = match t.stage {
                TRANSFER_OFFER => sync::transfer::accept_offer(&t, &group_hex).unwrap_or(false),
                TRANSFER_MEDIA_DONE => {
                    let _ = sync::transfer::media_done(&t);
                    false
                }
                _ => {
                    if sync::transfer::load_import().is_some_and(|j| j.id == t.id && !j.finished()) {
                        let _ = sync::transfer::save_import(None);
                    }
                    false
                }
            };
            Some(serde_json::json!({"for_me": true, "stage": t.stage, "started": started}).to_string())
        }
        Decoded::DeviceSync { items } => {
            let items: Vec<devsync::SyncItem> = items
                .into_iter()
                .map(|e| devsync::SyncItem { key: e.key, ts: e.ts, deleted: e.deleted, value: e.value })
                .collect();
            let before = super::simple::roots_setting();
            let a = devsync::apply(&items).unwrap_or_default();
            super::simple::roots_changed(before).await;
            Some(
                serde_json::json!({
                    "settings": a.settings,
                    "chats": a.chats,
                    "contacts": a.contacts,
                    "blocked": a.blocked,
                    "packs": a.packs,
                    "read": a.read,
                })
                .to_string(),
            )
        }
        _ => None,
    }
}

/// Settings: the last change already sent, and when everything was last
/// sent in full.
const SENT_SEQ_SETTING: &str = "devsync_sent_seq";
const FULL_TS_SETTING: &str = "devsync_full_ts";
/// Everything goes again once a week, for a device that missed something.
const FULL_EVERY_SECS: i64 = 7 * 24 * 3600;
/// Bytes of items per message.
const BATCH_BYTES: usize = 256 * 1024;

fn waits_for_other_devices(items: &[devsync::SyncItem]) -> bool {
    items.iter().any(|i| i.key == "set:account_roots")
}

#[cfg(test)]
mod roots_wait_tests {
    use super::*;

    /// New account roots made while this device is alone in its own-devices
    /// group (after a restore from the cloud) are not marked as sent.
    #[test]
    fn new_roots_wait_for_my_other_devices() {
        let item = |k: &str| devsync::SyncItem { key: k.into(), ts: 1, deleted: false, value: "v".into() };
        assert!(waits_for_other_devices(&[item("set:profile_name"), item("set:account_roots")]));
        assert!(!waits_for_other_devices(&[item("set:profile_name"), item("contact:ab")]));
    }
}

/// Send what changed here (contacts, blocked, chat flags, packs, synced
/// settings) to my other devices. Returns how many items went out; 0 when
/// nothing changed or I have no other device.
pub async fn device_sync_flush(server_base_url: String) -> Result<u32, String> {
    let Some(group_hex) = storage::setting_get(SAVED_CHAT_SETTING).map_err(|e| e.to_string())?.filter(|g| !g.is_empty())
    else {
        return Ok(0);
    };
    let sent_seq: i64 = storage::setting_get(SENT_SEQ_SETTING).ok().flatten().and_then(|s| s.parse().ok()).unwrap_or(0);
    let (mut items, max_seq) = devsync::pending(sent_seq).map_err(|e| e.to_string())?;
    let now = now_unix() as i64;
    let full_ts: i64 = storage::setting_get(FULL_TS_SETTING).ok().flatten().and_then(|s| s.parse().ok()).unwrap_or(0);
    let full = now - full_ts >= FULL_EVERY_SECS;
    // The common case every 20 s: nothing changed — one local query.
    if items.is_empty() && !full {
        return Ok(0);
    }
    let group = hex::decode(&group_hex).map_err(|e| e.to_string())?;
    let others = {
        let mut slot = sync_slot().lock().await;
        let c = slot.as_mut().ok_or_else(|| "sync not initialised".to_string())?;
        let me: [u8; 32] = hex::decode(c.identity_pubkey_hex()).ok().and_then(|v| v.try_into().ok()).ok_or("bad identity")?;
        let keys = c.group_device_keys(&group, &me).unwrap_or_default();
        // New account roots never go out while a device I disconnected is
        // still in my own-devices group (its removal failed or has not run
        // yet): it would read them. The next device sync removes it first.
        if waits_for_other_devices(&items) && keys.iter().any(|k| devsync::device_revoked(&hex::encode(k))) {
            return Ok(0);
        }
        c.is_own_devices_group(&group).unwrap_or(false) && keys.len() > 1
    };
    if !others {
        // Nobody to tell; a device linked later gets it all in its transfer.
        // Except new account roots (ADR-084): an OLDER device of mine never
        // gets a transfer from this one — they wait here until it is in the group.
        if waits_for_other_devices(&items) {
            return Ok(0);
        }
        storage::setting_set(SENT_SEQ_SETTING, &max_seq.to_string()).map_err(|e| e.to_string())?;
        storage::setting_set(FULL_TS_SETTING, &now.to_string()).map_err(|e| e.to_string())?;
        return Ok(0);
    }
    if full {
        items = devsync::all_items().map_err(|e| e.to_string())?;
    }
    if items.is_empty() {
        storage::setting_set(FULL_TS_SETTING, &now.to_string()).map_err(|e| e.to_string())?;
        return Ok(0);
    }
    let t = transport(server_base_url).await?;
    // A pack's file must be on the server before my other device asks.
    for it in items.iter().filter(|i| i.key.starts_with("pack:") && !i.deleted) {
        let sha = serde_json::from_str::<serde_json::Value>(&it.value).ok().and_then(|v| devsync::pack_entry_sha(&v));
        if let Some(blob) = sha.as_deref().and_then(storage::stickers::get) {
            sync::transfer::Transport::upload(&t, blob).await.map_err(|e| e.to_string())?;
        }
    }
    // Oversized items can't travel (a huge setting) — they stay local.
    let entries: Vec<SyncEntry> = items
        .into_iter()
        .filter(|it| it.key.len() <= sync::envelope::MAX_SYNC_KEY_BYTES && it.value.len() <= sync::envelope::MAX_SYNC_VALUE_BYTES)
        .map(|it| SyncEntry { key: it.key, ts: it.ts, deleted: it.deleted, value: it.value })
        .collect();
    let mut sent = 0u32;
    for batch in sync_batches(entries) {
        sent += batch.len() as u32;
        sync::transfer::Transport::send_own(&t, &group_hex, sync::envelope::encode_device_sync(batch))
            .await
            .map_err(|e| e.to_string())?;
    }
    storage::setting_set(SENT_SEQ_SETTING, &max_seq.to_string()).map_err(|e| e.to_string())?;
    if full {
        storage::setting_set(FULL_TS_SETTING, &now.to_string()).map_err(|e| e.to_string())?;
    }
    Ok(sent)
}

/// Split items into `DeviceSync` messages: ≤ 500 items and about
/// [`BATCH_BYTES`] each, never an empty one.
fn sync_batches(entries: Vec<SyncEntry>) -> Vec<Vec<SyncEntry>> {
    let mut out = Vec::new();
    let mut batch: Vec<SyncEntry> = Vec::new();
    let mut bytes = 0;
    for e in entries {
        let size = e.key.len() + e.value.len() + 16;
        if !batch.is_empty() && (batch.len() >= sync::envelope::MAX_SYNC_ITEMS || bytes + size > BATCH_BYTES) {
            out.push(std::mem::take(&mut batch));
            bytes = 0;
        }
        bytes += size;
        batch.push(e);
    }
    if !batch.is_empty() {
        out.push(batch);
    }
    out
}

/// Fetch sticker pack files my other device added (synced or transferred)
/// that aren't here yet. Returns how many arrived.
pub async fn device_sync_fetch_packs(server_base_url: String) -> Result<u32, String> {
    let missing = devsync::packs_missing_files().map_err(|e| e.to_string())?;
    if missing.is_empty() {
        return Ok(0);
    }
    let t = transport(server_base_url).await?;
    let mut n = 0;
    for sha in missing {
        match sync::transfer::fetch_pack_file(&t, &sha).await {
            Ok(()) => n += 1,
            // Gone from the server: nothing to retry now.
            Err(TransferError::Gone(_)) | Err(TransferError::Bad(_)) => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(i: usize, value_len: usize) -> SyncEntry {
        SyncEntry { key: format!("contact:{i}"), ts: 1, deleted: false, value: "x".repeat(value_len) }
    }

    /// Every item goes out, in messages a receiver accepts (never empty,
    /// ≤ 500 items, ≈ 256 KB).
    #[test]
    fn sync_items_split_into_valid_messages() {
        assert!(sync_batches(vec![]).is_empty());
        let many: Vec<SyncEntry> = (0..1201).map(|i| entry(i, 10)).collect();
        let b = sync_batches(many);
        assert_eq!(b.iter().map(Vec::len).collect::<Vec<_>>(), vec![500, 500, 201]);
        let big: Vec<SyncEntry> = (0..10).map(|i| entry(i, 60 * 1024)).collect();
        let b = sync_batches(big);
        assert_eq!(b.iter().map(Vec::len).sum::<usize>(), 10);
        for batch in &b {
            let decoded = sync::envelope::decode(&sync::envelope::encode_device_sync(batch.clone()));
            assert!(decoded.is_ok(), "a receiver takes every message");
            assert!(batch.iter().map(|e| e.value.len()).sum::<usize>() <= BATCH_BYTES);
        }
    }
}
