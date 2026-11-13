// Device transfer — ADR-064.
//
// MLS can't decrypt the past, so a newly linked device starts with nothing
// but what my other device hands it. The transfer does that in full:
//
//   old device                                server                new device
//   ──────────                                ──────                ──────────
//   build: header + message parts,            (ciphertext only)
//     each encrypted like a media blob
//     (fresh AES-256-GCM key, Padmé size)
//   upload packs' files, parts, manifest  ──▶ blobs (90 days)
//   Transfer{offer, manifest key}  ── MLS, my own-devices group, sealed to my key ──▶
//                                                                 download manifest,
//                                                                 each part → merge
//                                                                 (resumable), packs
//   media: "touch" every referenced blob ──▶ keeps them 90 days,
//     upload the ones the server lost         says which are gone
//     from my local copies (ADR-033)
//   Transfer{media done}  ─────────────── MLS ───────────────────▶ (media open on tap)
//
// The key to the manifest exists only inside MLS (my devices); the
// manifest holds the parts' keys. The server stores ciphertext it can't
// open and sees blob sizes in Padmé buckets — as for any media. Both sides
// keep their job in the encrypted DB after every step, so a transfer
// survives the app being closed, the network dropping, and the old device
// going offline once its parts are up.
//
// The I/O goes through [`Transport`] (HTTP + MLS in the app, a map in
// tests); everything else is here.

use std::future::Future;

use base64::{prelude::BASE64_STANDARD, Engine};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sinhron_storage::transfer::{Header, TMessage};
use sinhron_storage::{self as storage, devsync};

use crate::envelope::{self, MediaRef, Transfer, TRANSFER_MEDIA_DONE, TRANSFER_OFFER};
use crate::media::{self, BlobRef};

/// Magic + version at the start of a part's plaintext.
const PART_MAGIC: &[u8; 4] = b"SNTP";
const MANIFEST_MAGIC: &[u8; 4] = b"SNTM";
const FORMAT_VERSION: u8 = 1;

/// A message part is closed once its JSON is about this big.
pub const PART_TARGET_BYTES: usize = 2 * 1024 * 1024;
/// Messages read from the DB at a time while building.
const PAGE: i64 = 1000;
/// Settings holding the jobs (encrypted DB). Never synced.
pub const OUT_SETTING: &str = "transfer_out";
pub const IN_SETTING: &str = "transfer_in";
fn media_list_setting(id: &str) -> String {
    format!("transfer_media:{id}")
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TransferError {
    /// Network or server trouble — try again later.
    #[error("network: {0}")]
    Net(String),
    /// The server no longer has a part (expired or never uploaded).
    #[error("gone from the server: {0}")]
    Gone(String),
    /// Bytes that aren't what they should be.
    #[error("bad transfer data: {0}")]
    Bad(String),
    #[error("storage: {0}")]
    Storage(String),
}

impl From<storage::StorageError> for TransferError {
    fn from(e: storage::StorageError) -> Self {
        TransferError::Storage(e.to_string())
    }
}

/// The transfer's I/O: encrypted blobs on the server and MLS messages to
/// my own devices.
pub trait Transport {
    fn upload(&self, blob: Vec<u8>) -> impl Future<Output = Result<(), TransferError>> + Send;
    fn download(&self, sha_hex: &str) -> impl Future<Output = Result<Vec<u8>, TransferError>> + Send;
    /// Keep these blobs; returns the ones the server doesn't have.
    fn touch(&self, shas: &[String]) -> impl Future<Output = Result<Vec<String>, TransferError>> + Send;
    /// An MLS message in my own-devices group [group_hex], sealed to my key.
    fn send_own(&self, group_hex: &str, plaintext: Vec<u8>) -> impl Future<Output = Result<(), TransferError>> + Send;
}

/// One encrypted blob: where it is and how to open it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BlobEntry {
    pub sha256: String,
    pub key: String,
    pub blob_size: u64,
    pub plain_size: u64,
}

impl BlobEntry {
    pub fn of(r: &BlobRef) -> Self {
        Self { sha256: r.sha256_hex(), key: BASE64_STANDARD.encode(r.key), blob_size: r.blob_size, plain_size: r.plain_size }
    }
    pub fn blob_ref(&self) -> Result<BlobRef, TransferError> {
        let bad = |_| TransferError::Bad("blob reference".into());
        BlobRef::try_from(&MediaRef {
            sha256: hex::decode(&self.sha256).map_err(|_| TransferError::Bad("sha256".into()))?,
            key: BASE64_STANDARD.decode(&self.key).map_err(|_| TransferError::Bad("key".into()))?,
            blob_size: self.blob_size,
            plain_size: self.plain_size,
        })
        .map_err(bad)
    }
    pub fn media_ref(&self) -> Result<MediaRef, TransferError> {
        Ok(MediaRef::from(&self.blob_ref()?))
    }
    pub fn of_media_ref(m: &MediaRef) -> Result<Self, TransferError> {
        Ok(Self::of(&BlobRef::try_from(m).map_err(|_| TransferError::Bad("manifest reference".into()))?))
    }
}

// ── Parts and the manifest ─────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Part {
    Header(Box<Header>),
    Messages { messages: Vec<TMessage> },
}

fn framed(magic: &[u8; 4], json: Vec<u8>) -> Vec<u8> {
    let mut out = Vec::with_capacity(5 + json.len());
    out.extend_from_slice(magic);
    out.push(FORMAT_VERSION);
    out.extend_from_slice(&json);
    out
}

fn unframed<'a>(magic: &[u8; 4], b: &'a [u8]) -> Result<&'a [u8], TransferError> {
    if b.len() < 5 || &b[..4] != magic {
        return Err(TransferError::Bad("not a transfer part".into()));
    }
    if b[4] != FORMAT_VERSION {
        return Err(TransferError::Bad(format!("format {} (update the app)", b[4])));
    }
    Ok(&b[5..])
}

pub fn encode_part(p: &Part) -> Vec<u8> {
    framed(PART_MAGIC, serde_json::to_vec(p).expect("plain data serializes"))
}

pub fn decode_part(b: &[u8]) -> Result<Part, TransferError> {
    serde_json::from_slice(unframed(PART_MAGIC, b)?).map_err(|e| TransferError::Bad(e.to_string()))
}

/// What the new device fetches first: the parts in order, the sticker
/// pack files, totals for the progress screen.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    pub id: String,
    pub parts: Vec<BlobEntry>,
    /// sha256 of each added sticker pack's encrypted file (its key is in
    /// the header's pack index).
    #[serde(default)]
    pub packs: Vec<String>,
    #[serde(default)]
    pub messages: u64,
    #[serde(default)]
    pub chats: u64,
    #[serde(default)]
    pub media: u64,
}

pub fn encode_manifest(m: &Manifest) -> Vec<u8> {
    framed(MANIFEST_MAGIC, serde_json::to_vec(m).expect("plain data serializes"))
}

/// XFER-1 — of the server's "I don't have these" only what it was asked
/// about counts: it can't make this device upload other files, or grow the
/// queue without end.
fn only_asked(asked: &[String], missing: Vec<String>) -> Vec<String> {
    // Walk what was ASKED, not the answer: the same hash named a million
    // times is still one file, and the queue is never longer than the batch.
    let missing: std::collections::HashSet<String> = missing.into_iter().collect();
    asked.iter().filter(|s| missing.contains(*s)).cloned().collect()
}

pub fn decode_manifest(b: &[u8]) -> Result<Manifest, TransferError> {
    let m: Manifest =
        serde_json::from_slice(unframed(MANIFEST_MAGIC, b)?).map_err(|e| TransferError::Bad(e.to_string()))?;
    // XFER-9 — every hash goes into a request path: checked before any use.
    if m.parts.is_empty() || !m.packs.iter().chain(m.parts.iter().map(|p| &p.sha256)).all(|s| storage::blobs::is_sha_hex(s)) {
        return Err(TransferError::Bad("empty manifest".into()));
    }
    Ok(m)
}

/// Every blob a stored media / link / sticker JSON points to (sha256 hex,
/// any depth) — what the new device may want to open.
pub fn media_shas(media_json: &str, out: &mut Vec<String>) {
    fn walk(v: &serde_json::Value, out: &mut Vec<String>) {
        match v {
            serde_json::Value::Object(o) => {
                for (k, v) in o {
                    match v {
                        serde_json::Value::String(s) if k == "sha256" && storage::blobs::is_sha_hex(s) => out.push(s.clone()),
                        _ => walk(v, out),
                    }
                }
            }
            serde_json::Value::Array(a) => a.iter().for_each(|v| walk(v, out)),
            _ => {}
        }
    }
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(media_json) {
        walk(&v, out);
    }
}

fn message_weight(m: &TMessage) -> usize {
    200 + m.body.len()
        + m.media_json.as_ref().map_or(0, String::len)
        + m.reply_json.as_ref().map_or(0, String::len)
        + m.reactions_json.as_ref().map_or(0, String::len)
}

/// Encrypt one plaintext and keep the ciphertext until it is uploaded.
fn seal_and_keep(plain: &[u8]) -> Result<BlobEntry, TransferError> {
    let (blob, r) = media::encrypt(plain).map_err(|e| TransferError::Bad(e.to_string()))?;
    storage::transfer::part_put(&r.sha256_hex(), &blob)?;
    Ok(BlobEntry::of(&r))
}

// ── The old device ─────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExportStage {
    /// Pack the database into encrypted parts.
    Build,
    /// Upload sticker pack files, then parts, then the manifest.
    Upload,
    /// Tell the new device (MLS).
    Offer,
    /// Make sure every referenced media file is on the server.
    Media,
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExportJob {
    pub id: String,
    /// The new device (leaf key hex).
    pub device_hex: String,
    /// My own-devices group to tell it through.
    pub group_hex: String,
    pub created_ts: i64,
    pub stage: ExportStage,
    #[serde(default)]
    pub parts: Vec<BlobEntry>,
    #[serde(default)]
    pub packs: Vec<String>,
    /// Packs then parts uploaded so far.
    #[serde(default)]
    pub uploaded: u32,
    #[serde(default)]
    pub manifest: Option<BlobEntry>,
    #[serde(default)]
    pub messages: u64,
    #[serde(default)]
    pub chats: u64,
    #[serde(default)]
    pub media_total: u64,
    #[serde(default)]
    pub media_checked: u64,
    /// Of the batch just checked: ones the server lacks, to upload.
    #[serde(default)]
    pub media_queue: Vec<String>,
    #[serde(default)]
    pub media_uploaded: u64,
    /// Neither the server nor this device had them any more.
    #[serde(default)]
    pub media_missing: u64,
}

impl ExportJob {
    pub fn new(id: String, device_hex: String, group_hex: String, now: i64) -> Self {
        Self {
            id,
            device_hex,
            group_hex,
            created_ts: now,
            stage: ExportStage::Build,
            parts: Vec::new(),
            packs: Vec::new(),
            uploaded: 0,
            manifest: None,
            messages: 0,
            chats: 0,
            media_total: 0,
            media_checked: 0,
            media_queue: Vec::new(),
            media_uploaded: 0,
            media_missing: 0,
        }
    }

    pub fn done(&self) -> bool {
        self.stage == ExportStage::Done
    }

    fn offer(&self, stage: u32) -> Result<Transfer, TransferError> {
        Ok(Transfer {
            id: self.id.clone(),
            target_device: hex::decode(&self.device_hex).map_err(|_| TransferError::Bad("device".into()))?,
            stage,
            manifest: match (stage, &self.manifest) {
                (TRANSFER_OFFER, Some(m)) => Some(m.media_ref()?),
                _ => None,
            },
            messages: self.messages,
            media: self.media_total,
            media_missing: self.media_missing,
        })
    }

    /// Do the next piece of work. Returns false once nothing is left.
    /// On an error nothing moved: call again later.
    pub async fn step<T: Transport>(&mut self, t: &T, saved_setting: &str) -> Result<bool, TransferError> {
        match self.stage {
            ExportStage::Build => self.build(saved_setting)?,
            ExportStage::Upload => {
                let i = self.uploaded as usize;
                if i < self.packs.len() {
                    // A pack removed meanwhile has nothing to send.
                    if let Some(blob) = storage::stickers::get(&self.packs[i]) {
                        t.upload(blob).await?;
                    }
                    self.uploaded += 1;
                } else if i < self.packs.len() + self.parts.len() {
                    let part = &self.parts[i - self.packs.len()];
                    let blob = storage::transfer::part_get(&part.sha256)
                        .ok_or_else(|| TransferError::Storage("a waiting part is gone".into()))?;
                    t.upload(blob).await?;
                    self.uploaded += 1;
                } else {
                    let m = Manifest {
                        id: self.id.clone(),
                        parts: self.parts.clone(),
                        packs: self.packs.clone(),
                        messages: self.messages,
                        chats: self.chats,
                        media: self.media_total,
                    };
                    let (blob, r) = media::encrypt(&encode_manifest(&m)).map_err(|e| TransferError::Bad(e.to_string()))?;
                    t.upload(blob).await?;
                    self.manifest = Some(BlobEntry::of(&r));
                    self.stage = ExportStage::Offer;
                }
            }
            ExportStage::Offer => {
                t.send_own(&self.group_hex, envelope::encode_transfer(self.offer(TRANSFER_OFFER)?)).await?;
                // Everything is on the server now.
                storage::transfer::parts_clear();
                self.stage = ExportStage::Media;
            }
            ExportStage::Media => {
                if let Some(sha) = self.media_queue.first().cloned() {
                    match storage::blobs::get(&sha) {
                        Some(blob) => {
                            t.upload(blob).await?;
                            self.media_uploaded += 1;
                        }
                        None => self.media_missing += 1,
                    }
                    self.media_queue.remove(0);
                } else if self.media_checked < self.media_total {
                    let all = media_list(&self.id)?;
                    let from = (self.media_checked as usize).min(all.len());
                    let batch = &all[from..(from + crate::http_api::MEDIA_TOUCH_MAX).min(all.len())];
                    self.media_queue = only_asked(batch, t.touch(batch).await?);
                    self.media_checked = (from + batch.len()) as u64;
                    if batch.is_empty() {
                        self.media_checked = self.media_total;
                    }
                } else {
                    t.send_own(&self.group_hex, envelope::encode_transfer(self.offer(TRANSFER_MEDIA_DONE)?)).await?;
                    let _ = storage::setting_set(&media_list_setting(&self.id), "");
                    self.stage = ExportStage::Done;
                }
            }
            ExportStage::Done => return Ok(false),
        }
        Ok(true)
    }

    /// Pack this device's database: a header part, then message parts of
    /// about [`PART_TARGET_BYTES`], each encrypted and kept until uploaded.
    fn build(&mut self, saved_setting: &str) -> Result<(), TransferError> {
        storage::transfer::parts_clear();
        let header = storage::transfer::export_header(saved_setting)?;
        self.chats = header.chats.len() as u64;
        let mut parts = vec![seal_and_keep(&encode_part(&Part::Header(Box::new(header))))?];
        let mut media = Vec::new();
        let mut batch: Vec<TMessage> = Vec::new();
        let mut weight = 0;
        let mut count = 0u64;
        for chat in storage::transfer::export_chat_ids()? {
            let mut after: Option<(i64, String)> = None;
            loop {
                let page = storage::transfer::export_messages(&chat, after.as_ref().map(|(t, i)| (*t, i.as_str())), PAGE)?;
                let Some(last) = page.last() else { break };
                after = Some((last.ts, last.id.clone()));
                for m in page {
                    if let Some(j) = &m.media_json {
                        media_shas(j, &mut media);
                    }
                    weight += message_weight(&m);
                    count += 1;
                    batch.push(m);
                    if weight >= PART_TARGET_BYTES {
                        parts.push(seal_and_keep(&encode_part(&Part::Messages { messages: std::mem::take(&mut batch) }))?);
                        weight = 0;
                    }
                }
            }
        }
        if !batch.is_empty() {
            parts.push(seal_and_keep(&encode_part(&Part::Messages { messages: batch }))?);
        }
        media.sort();
        media.dedup();
        storage::setting_set(&media_list_setting(&self.id), &serde_json::to_string(&media).expect("strings serialize"))?;
        self.media_total = media.len() as u64;
        self.messages = count;
        self.parts = parts;
        self.packs = devsync::pack_shas()?;
        self.uploaded = 0;
        self.stage = ExportStage::Upload;
        Ok(())
    }
}

/// The media list an export built for its id (kept until the job's Media
/// stage ends).
pub fn media_list(id: &str) -> Result<Vec<String>, TransferError> {
    Ok(storage::setting_get(&media_list_setting(id))?
        .filter(|s| !s.is_empty())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default())
}

// ── The new device ─────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImportStage {
    Manifest,
    Parts,
    Packs,
    Done,
    /// The server lost a part (the transfer is older than 90 days, or
    /// the old device never finished uploading) — ask for a new one.
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportJob {
    pub id: String,
    pub group_hex: String,
    pub manifest: BlobEntry,
    pub stage: ImportStage,
    #[serde(default)]
    pub parts: Vec<BlobEntry>,
    #[serde(default)]
    pub packs: Vec<String>,
    /// Parts (then packs) done.
    #[serde(default)]
    pub next: u32,
    #[serde(default)]
    pub messages: u64,
    #[serde(default)]
    pub messages_added: u64,
    #[serde(default)]
    pub media: u64,
    #[serde(default)]
    pub media_done: bool,
    #[serde(default)]
    pub media_missing: u64,
    #[serde(default)]
    pub error: Option<String>,
}

/// What one import step changed (the app refreshes and adopts).
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Imported {
    pub chats: bool,
    pub settings: bool,
    pub packs: bool,
    /// The old device's "Saved messages" chat (ADR-055).
    pub saved_chat_id: Option<String>,
}

impl ImportJob {
    /// From a stage-1 [`Transfer`] in my own-devices group.
    pub fn from_offer(t: &Transfer, group_hex: &str) -> Result<Self, TransferError> {
        let manifest = BlobEntry::of_media_ref(t.manifest.as_ref().ok_or_else(|| TransferError::Bad("no manifest".into()))?)?;
        Ok(Self {
            id: t.id.clone(),
            group_hex: group_hex.to_string(),
            manifest,
            stage: ImportStage::Manifest,
            parts: Vec::new(),
            packs: Vec::new(),
            next: 0,
            messages: t.messages,
            messages_added: 0,
            media: t.media,
            media_done: false,
            media_missing: 0,
            error: None,
        })
    }

    pub fn finished(&self) -> bool {
        matches!(self.stage, ImportStage::Done | ImportStage::Failed)
    }

    async fn fetch<T: Transport>(t: &T, e: &BlobEntry) -> Result<Vec<u8>, TransferError> {
        let blob = t.download(&e.sha256).await?;
        media::decrypt(&blob, &e.blob_ref()?).map_err(|e| TransferError::Bad(e.to_string()))
    }

    /// Do the next piece of work; `Ok(None)` once nothing is left. A
    /// part the server no longer has fails the job (stage `Failed`); other
    /// errors leave it as it was, to try again.
    pub async fn step<T: Transport>(&mut self, t: &T) -> Result<Option<Imported>, TransferError> {
        match self.step_inner(t).await {
            Err(TransferError::Gone(what)) | Err(TransferError::Bad(what)) => {
                self.stage = ImportStage::Failed;
                self.error = Some(what);
                Ok(Some(Imported::default()))
            }
            other => other,
        }
    }

    async fn step_inner<T: Transport>(&mut self, t: &T) -> Result<Option<Imported>, TransferError> {
        let mut out = Imported::default();
        match self.stage {
            ImportStage::Manifest => {
                let m = decode_manifest(&Self::fetch(t, &self.manifest).await?)?;
                if m.id != self.id {
                    return Err(TransferError::Bad("manifest of another transfer".into()));
                }
                self.parts = m.parts;
                self.packs = m.packs;
                self.messages = m.messages;
                self.media = m.media;
                self.next = 0;
                self.stage = ImportStage::Parts;
            }
            ImportStage::Parts => {
                let Some(e) = self.parts.get(self.next as usize).cloned() else {
                    self.next = 0;
                    self.stage = ImportStage::Packs;
                    return Ok(Some(out));
                };
                match decode_part(&Self::fetch(t, &e).await?)? {
                    Part::Header(mut h) => {
                        if self.group_hex == crate::backup::BACKUP_GROUP {
                            storage::transfer::strip_for_backup(&mut h); // BKP-1
                        }
                        let rep = storage::transfer::import_header(&h)?;
                        out.chats = true;
                        out.settings = rep.settings > 0;
                        out.packs = !rep.packs_added.is_empty();
                        out.saved_chat_id = h.saved_chat_id.clone();
                    }
                    Part::Messages { messages } => {
                        self.messages_added += storage::transfer::import_messages(&messages)? as u64;
                        out.chats = true;
                    }
                }
                self.next += 1;
            }
            ImportStage::Packs => {
                // The index came with the header; fetch whatever file is missing.
                let missing = devsync::packs_missing_files()?;
                match missing.first() {
                    Some(sha) => {
                        fetch_pack_file(t, sha).await?;
                        out.packs = true;
                    }
                    None => self.stage = ImportStage::Done,
                }
            }
            ImportStage::Done | ImportStage::Failed => return Ok(None),
        }
        Ok(Some(out))
    }
}

/// Download one sticker pack file by its hash (checked) and keep it.
pub async fn fetch_pack_file<T: Transport>(t: &T, sha: &str) -> Result<(), TransferError> {
    let blob = t.download(sha).await?;
    if hex::encode(Sha256::digest(&blob)) != sha {
        return Err(TransferError::Bad("pack file doesn't match".into()));
    }
    storage::stickers::put(sha, &blob)?;
    Ok(())
}

// ── Jobs in the encrypted DB ───────────────────────────────────────

pub fn load_exports() -> Vec<ExportJob> {
    storage::setting_get(OUT_SETTING).ok().flatten().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

pub fn save_exports(jobs: &[ExportJob]) -> Result<(), TransferError> {
    storage::setting_set(OUT_SETTING, &serde_json::to_string(jobs).expect("plain data serializes"))?;
    Ok(())
}

pub fn load_import() -> Option<ImportJob> {
    storage::setting_get(IN_SETTING).ok().flatten().and_then(|s| serde_json::from_str(&s).ok())
}

pub fn save_import(job: Option<&ImportJob>) -> Result<(), TransferError> {
    let v = job.map(|j| serde_json::to_string(j).expect("plain data serializes")).unwrap_or_default();
    storage::setting_set(IN_SETTING, &v)?;
    Ok(())
}

/// Queue a transfer to [device_hex] (replacing an unfinished one to the
/// same device). Returns the new job's id.
pub fn queue_export(device_hex: &str, group_hex: &str, now: i64) -> Result<String, TransferError> {
    let mut jobs = load_exports();
    for j in jobs.iter().filter(|j| j.device_hex == device_hex) {
        let _ = storage::setting_set(&media_list_setting(&j.id), "");
    }
    jobs.retain(|j| j.device_hex != device_hex);
    let id = uuid::Uuid::now_v7().to_string();
    jobs.push(ExportJob::new(id.clone(), device_hex.to_string(), group_hex.to_string(), now));
    save_exports(&jobs)?;
    Ok(id)
}

/// A transfer offer for this device arrived: start (or keep) the import.
/// The same offer twice changes nothing; a newer one replaces the old.
pub fn accept_offer(t: &Transfer, group_hex: &str) -> Result<bool, TransferError> {
    if load_import().is_some_and(|j| j.id == t.id) {
        return Ok(false);
    }
    save_import(Some(&ImportJob::from_offer(t, group_hex)?))?;
    Ok(true)
}

/// The old device says the media are on the server.
pub fn media_done(t: &Transfer) -> Result<(), TransferError> {
    if let Some(mut j) = load_import().filter(|j| j.id == t.id) {
        j.media_done = true;
        j.media_missing = t.media_missing;
        save_import(Some(&j))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::sync::Mutex;

    /// The server (a map of blobs) and my own-devices group (a list of
    /// MLS plaintexts), with switches to make the network fail.
    #[derive(Default)]
    struct Fake {
        blobs: Mutex<BTreeMap<String, Vec<u8>>>,
        sent: Mutex<Vec<Vec<u8>>>,
        offline: Mutex<bool>,
        no_touch: bool,
        uploads: Mutex<u32>,
    }

    impl Fake {
        fn check(&self) -> Result<(), TransferError> {
            if *self.offline.lock().unwrap() {
                Err(TransferError::Net("offline".into()))
            } else {
                Ok(())
            }
        }
    }

    impl Transport for Fake {
        async fn upload(&self, blob: Vec<u8>) -> Result<(), TransferError> {
            self.check()?;
            *self.uploads.lock().unwrap() += 1;
            self.blobs.lock().unwrap().insert(hex::encode(Sha256::digest(&blob)), blob);
            Ok(())
        }
        async fn download(&self, sha: &str) -> Result<Vec<u8>, TransferError> {
            self.check()?;
            self.blobs.lock().unwrap().get(sha).cloned().ok_or_else(|| TransferError::Gone(sha.to_string()))
        }
        async fn touch(&self, shas: &[String]) -> Result<Vec<String>, TransferError> {
            self.check()?;
            if self.no_touch {
                // An older server: everything counts as missing.
                return Ok(shas.to_vec());
            }
            let b = self.blobs.lock().unwrap();
            Ok(shas.iter().filter(|s| !b.contains_key(*s)).cloned().collect())
        }
        async fn send_own(&self, _group: &str, plaintext: Vec<u8>) -> Result<(), TransferError> {
            self.check()?;
            self.sent.lock().unwrap().push(plaintext);
            Ok(())
        }
    }

    fn fresh_db(name: &str) {
        let path = std::env::temp_dir().join(format!("sinhron_sync_transfer_{name}.db"));
        let _ = storage::open(&path, None);
        storage::erase_and_reopen_plain(&path).unwrap();
    }

    fn photo_json(r: &BlobRef) -> String {
        serde_json::json!({"v": 1, "kind": "photo", "file": {"sha256": r.sha256_hex(), "key": BASE64_STANDARD.encode(r.key), "blob_size": r.blob_size, "plain_size": r.plain_size}})
            .to_string()
    }

    /// The old device's world: chats, many messages (several parts), a
    /// photo kept locally but gone from the server, a sticker pack.
    fn fill_old_device(messages: usize) -> (BlobRef, String) {
        storage::chat_upsert("g1", "Anna", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
        storage::chat_upsert("saved", "Saved", false, false, false, 0, None, 1, "text", None, false, 2).unwrap();
        storage::setting_set("saved_chat_id", "saved").unwrap();
        storage::chat_set_muted("g1", true).unwrap();
        let big = "x".repeat(4000);
        for i in 0..messages {
            let id = format!("m{i:05}");
            let wire = format!("w{i:05}");
            storage::message_insert(&storage::NewMessage {
                id: &id,
                chat_id: "g1",
                ts_unix: 1000 + i as i64,
                body: &big,
                kind: "text",
                is_mine: i % 2 == 0,
                wire_id: Some(&wire),
                sender_id: Some("peer"),
                ..Default::default()
            })
            .unwrap();
        }
        let (blob, r) = media::encrypt(b"a photo").unwrap();
        storage::blobs::put(&r.sha256_hex(), &blob).unwrap();
        let mj = photo_json(&r);
        storage::message_insert(&storage::NewMessage {
            id: "photo",
            chat_id: "saved",
            ts_unix: 5000,
            body: "",
            kind: "photo",
            is_mine: true,
            media_json: Some(&mj),
            wire_id: Some("wphoto"),
            ..Default::default()
        })
        .unwrap();
        // A sticker pack: its encrypted file next to the DB, its key in the index.
        let (pblob, pr) = media::encrypt(b"pack bytes").unwrap();
        storage::stickers::put(&pr.sha256_hex(), &pblob).unwrap();
        let entry = serde_json::json!([{"id": "me.cats", "title": "Cats", "count": 1, "file": BlobEntry::of(&pr)}]);
        storage::setting_set(storage::stickers::INDEX_SETTING, &entry.to_string()).unwrap();
        storage::contact_add("ab01", "Anna", 5).unwrap();
        storage::setting_set("profile_name", "Grisha").unwrap();
        (r, pr.sha256_hex())
    }

    async fn run_export(job: &mut ExportJob, t: &Fake) {
        let mut guard = 0;
        while job.step(t, "saved_chat_id").await.unwrap() {
            guard += 1;
            assert!(guard < 10_000);
        }
    }

    fn offer_of(t: &Fake) -> Transfer {
        let sent = t.sent.lock().unwrap();
        match envelope::decode(&sent[0]).unwrap() {
            envelope::Decoded::Transfer(o) => o,
            other => panic!("{other:?}"),
        }
    }

    /// The whole trip: the old device packs and uploads, says so over MLS,
    /// re-uploads a photo the server lost from its local copy; the new
    /// device (an empty DB) restores chats, all messages, contacts,
    /// settings and the sticker pack, surviving restarts and outages.
    #[tokio::test]
    async fn a_new_device_gets_everything_and_survives_interruptions() {
        let _db = crate::test_db_lock();
        fresh_db("old");
        let (photo, pack_sha) = fill_old_device(1200);
        let t = Fake::default();
        let device = "d".repeat(64);
        let id = queue_export(&device, "saved", 1).unwrap();
        let mut job = load_exports().pop().unwrap();
        assert_eq!(job.id, id);

        // Build, then a few uploads, then the network drops: the job (saved
        // as JSON, like the app does) picks up where it stopped.
        assert!(job.step(&t, "saved_chat_id").await.unwrap());
        assert!(job.parts.len() >= 3, "4 KB × 1200 messages → several parts, got {}", job.parts.len());
        assert_eq!(job.messages, 1201);
        assert_eq!(job.media_total, 1);
        job.step(&t, "saved_chat_id").await.unwrap();
        job.step(&t, "saved_chat_id").await.unwrap();
        *t.offline.lock().unwrap() = true;
        let before = job.clone();
        assert!(matches!(job.step(&t, "saved_chat_id").await, Err(TransferError::Net(_))));
        assert_eq!(job, before, "a failed step changes nothing");
        save_exports(&[job]).unwrap();
        *t.offline.lock().unwrap() = false;
        let mut job = load_exports().pop().unwrap();
        run_export(&mut job, &t).await;
        assert!(job.done());
        assert_eq!(job.media_uploaded, 1, "the server didn't have the photo: sent from the local copy");
        assert_eq!(job.media_missing, 0);
        assert!(storage::transfer::part_get(&job.parts[0].sha256).is_none(), "local parts are gone once uploaded");
        // Offer, then "media done".
        assert_eq!(t.sent.lock().unwrap().len(), 2);
        let offer = offer_of(&t);
        assert_eq!(offer.stage, TRANSFER_OFFER);
        assert_eq!(hex::encode(&offer.target_device), device);
        // The server never sees plaintext: no blob contains a message.
        assert!(t.blobs.lock().unwrap().values().all(|b| !b.windows(8).any(|w| w == b"xxxxxxxx")));

        // ── The new device: empty DB; the device sync already made g1.
        fresh_db("new");
        storage::chat_upsert("g1", "New chat", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
        assert!(accept_offer(&offer, "saved").unwrap());
        assert!(!accept_offer(&offer, "saved").unwrap(), "the same offer twice");
        let mut job = load_import().unwrap();
        let mut saved = None;
        let mut steps = 0;
        while let Some(out) = job.step(&t).await.unwrap() {
            saved = saved.or(out.saved_chat_id);
            steps += 1;
            if steps == 3 {
                // App closed mid-way: resume from the stored job.
                save_import(Some(&job)).unwrap();
                job = load_import().unwrap();
                // And a dropped network on the next step.
                *t.offline.lock().unwrap() = true;
                assert!(job.step(&t).await.is_err());
                *t.offline.lock().unwrap() = false;
            }
        }
        assert_eq!(job.stage, ImportStage::Done);
        assert_eq!(job.messages_added, 1201);
        assert_eq!(saved.as_deref(), Some("saved"));
        assert_eq!(storage::messages_list_for_chat("g1", None).unwrap().len(), 1200);
        let chats = storage::chats_list().unwrap();
        assert!(chats.iter().find(|c| c.id == "g1").unwrap().muted);
        assert_eq!(storage::contacts_list().unwrap().len(), 1);
        assert_eq!(storage::setting_get("profile_name").unwrap().as_deref(), Some("Grisha"));
        assert!(storage::stickers::get(&pack_sha).is_some(), "the pack file came along");
        assert!(devsync::packs_missing_files().unwrap().is_empty());
        // The photo opens from the server (it was re-uploaded).
        let photo_msg = storage::messages_list_for_chat("saved", None).unwrap().pop().unwrap();
        let mut shas = Vec::new();
        media_shas(photo_msg.media_json.as_deref().unwrap(), &mut shas);
        assert_eq!(shas, vec![photo.sha256_hex()]);
        assert!(t.blobs.lock().unwrap().contains_key(&shas[0]));
        // "Media done" lands on the job.
        let done = match envelope::decode(&t.sent.lock().unwrap()[1]).unwrap() {
            envelope::Decoded::Transfer(o) => o,
            other => panic!("{other:?}"),
        };
        save_import(Some(&job)).unwrap();
        media_done(&done).unwrap();
        assert!(load_import().unwrap().media_done);
    }

    /// An older server without `touch`: every local media file is sent
    /// (the server keeps one copy anyway). A part the server lost fails
    /// the import with a reason instead of retrying forever.
    #[tokio::test]
    async fn old_servers_and_lost_parts() {
        let _db = crate::test_db_lock();
        fresh_db("old2");
        fill_old_device(3);
        let t = Fake { no_touch: true, ..Default::default() };
        queue_export(&"e".repeat(64), "saved", 1).unwrap();
        let mut job = load_exports().pop().unwrap();
        run_export(&mut job, &t).await;
        assert_eq!(job.media_uploaded, 1);
        let offer = offer_of(&t);

        fresh_db("new2");
        let first_part = job.parts[0].sha256.clone();
        t.blobs.lock().unwrap().remove(&first_part);
        accept_offer(&offer, "saved").unwrap();
        let mut job = load_import().unwrap();
        while job.step(&t).await.unwrap().is_some() {}
        assert_eq!(job.stage, ImportStage::Failed);
        assert!(job.error.as_deref().unwrap().contains(&first_part));
    }

    #[test]
    fn parts_and_manifests_are_framed_and_checked() {
        let p = Part::Messages { messages: vec![TMessage { id: "a".into(), chat_id: "c".into(), ts: 1, kind: "text".into(), ..Default::default() }] };
        assert_eq!(decode_part(&encode_part(&p)).unwrap(), p);
        let mut wrong = encode_part(&p);
        wrong[4] = 9;
        assert!(decode_part(&wrong).unwrap_err().to_string().contains("update the app"));
        assert!(decode_part(b"SNTMx").is_err());
        let m = Manifest { id: "x".into(), parts: vec![], packs: vec![], messages: 0, chats: 0, media: 0 };
        assert!(decode_manifest(&encode_manifest(&m)).is_err(), "no parts");
        // XFER-1 — the server names files it wasn't asked about.
        let asked = vec!["aa".to_string(), "bb".to_string()];
        assert_eq!(only_asked(&asked, vec!["bb".into(), "unrelated".into(), "cc".into()]), vec!["bb".to_string()]);
        assert_eq!(only_asked(&asked, vec!["bb".to_string(); 1000]), vec!["bb".to_string()], "named many times — still one");
        // XFER-9 — a part "hash" that would steer the request elsewhere.
        let part = |sha: &str| BlobEntry { sha256: sha.into(), key: String::new(), blob_size: 0, plain_size: 0 };
        let m = Manifest { parts: vec![part(&"ab".repeat(32))], ..m };
        assert!(decode_manifest(&encode_manifest(&m)).is_ok());
        let m = Manifest { parts: vec![part("../v1/account")], ..m };
        assert!(decode_manifest(&encode_manifest(&m)).is_err(), "not a hash");
        let mut shas = Vec::new();
        media_shas(r#"{"file":{"sha256":"aa"},"sticker":{"pack":{"file":{"sha256":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}}}}"#, &mut shas);
        assert_eq!(shas, vec!["f".repeat(64)]);
    }
}
