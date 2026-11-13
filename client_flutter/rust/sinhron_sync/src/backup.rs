// Chat backup — ADR-073 (owner, 2026-10-22: "lose the phone, lose every
// chat" — a copy in the person's own iCloud / Google Drive, no setup).
//
// It is the ADR-064 device transfer with the cloud in place of the server:
// the same encrypted parts (header + messages, fresh AES-256-GCM key each,
// Padmé sizes), sticker pack files and media blobs (already encrypted with
// their own keys — the local copies of ADR-033), all named by the SHA-256
// of their ciphertext. What MLS carried in a transfer — the key to the
// manifest — goes into one small `root.sinhron`, sealed with the account's
// cloud backup key (HKDF of the 24 words' backup key,
// `sinhron_crypto::identity::cloud_backup_key`; linked devices get it in
// their bundle): only someone with the words opens it; Apple / Google keep
// bytes they can't read.
//
// One cloud folder can hold several backups — the person's iPhone and iPad
// on one Apple ID, or two people's accounts on a shared one: the app puts
// each device's files under its own [`device_tag`], so no backup cleans
// out another's.
//
// The phone talks to the cloud from Dart / Swift / Kotlin; this side works
// on a staging folder ([`DirTransport`]): a backup step writes the files
// the cloud doesn't have yet there (Dart uploads and deletes them), a
// restore step reads from there and says which file it needs next (Dart
// downloads it). Media are named by content, so each one goes up once
// across daily backups; message parts are rebuilt each time.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use aes_gcm::aead::{Aead, Payload};
use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use openmls_rust_crypto::RustCrypto;
use openmls_traits::crypto::OpenMlsCrypto;
use openmls_traits::types::HpkeCiphertext;
use sinhron_crypto::identity::RootsGen;
use sinhron_storage as storage;

use crate::envelope::{Transfer, TRANSFER_OFFER};
use crate::transfer::{media_shas, BlobEntry, ExportJob, TransferError, Transport};

/// The one file that opens the rest (sealed with the backup key).
pub const ROOT_NAME: &str = "root.sinhron";
const ROOT_MAGIC: &[u8; 4] = b"SNBR";
const ROOT_VERSION: u8 = 1;
const ROOT_AAD: &[u8] = b"sinhron-chat-backup-root-v1";

/// What the root holds: the manifest's key and the totals for the
/// "restore N messages?" question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Root {
    /// The account it belongs to (ed25519 public, hex) — a root of another
    /// account sealed with the same key can't exist, but say so plainly.
    pub account: String,
    pub created_ts: i64,
    pub id: String,
    pub manifest: BlobEntry,
    pub messages: u64,
    pub chats: u64,
    pub media: u64,
}

impl Root {
    /// The transfer offer the importer starts from.
    pub fn offer(&self) -> Result<Transfer, TransferError> {
        Ok(Transfer {
            id: self.id.clone(),
            target_device: Vec::new(),
            stage: TRANSFER_OFFER,
            manifest: Some(self.manifest.media_ref()?),
            messages: self.messages,
            media: self.media,
            media_missing: 0,
        })
    }
}

/// `nonce || AES-256-GCM(magic || version || JSON)`.
pub fn seal_root(backup_key: &[u8; 32], root: &Root) -> Vec<u8> {
    seal_with(backup_key, ROOT_AAD, root)
}

fn seal_with(backup_key: &[u8; 32], aad: &[u8], root: &Root) -> Vec<u8> {
    let mut plain = Vec::new();
    plain.extend_from_slice(ROOT_MAGIC);
    plain.push(ROOT_VERSION);
    plain.extend_from_slice(&serde_json::to_vec(root).expect("plain data serializes"));
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let ct = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(backup_key))
        .encrypt(Nonce::from_slice(&nonce), Payload { msg: &plain, aad })
        .expect("AES-GCM encrypts any length we write");
    let mut out = nonce.to_vec();
    out.extend_from_slice(&ct);
    out
}

/// The root, if [backup_key] opens it (other words → `Bad`).
pub fn open_root(backup_key: &[u8; 32], bytes: &[u8]) -> Result<Root, TransferError> {
    open_with(backup_key, ROOT_AAD, bytes)
}

fn open_with(backup_key: &[u8; 32], aad: &[u8], bytes: &[u8]) -> Result<Root, TransferError> {
    if bytes.len() < 12 + 16 + 5 {
        return Err(TransferError::Bad("backup root too short".into()));
    }
    let (nonce, ct) = bytes.split_at(12);
    let plain = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(backup_key))
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad })
        .map_err(|_| TransferError::Bad("this backup was made with other secret words".into()))?;
    if &plain[..4] != ROOT_MAGIC {
        return Err(TransferError::Bad("not a Sinhron backup".into()));
    }
    if plain[4] != ROOT_VERSION {
        return Err(TransferError::Bad(format!("backup format {} (update the app)", plain[4])));
    }
    serde_json::from_slice(&plain[5..]).map_err(|e| TransferError::Bad(e.to_string()))
}

// ADR-084 — after one of my devices is disconnected the backup key is the
// newest generation's (`RootsGen::cloud_key`, from fresh bytes the
// disconnected device never saw). Such a root starts with
//   "SNB2" | generation (u32 BE) | HPKE(account X25519 key, the generation's secret)
// and the rest is the root as before, sealed with that key over this header
// too: my devices open it with the generation they hold; the 24 words alone
// (a new phone) open the secret first. A root without it: generation 0.
/// The "group" of an import job that restores a cloud backup (not a device transfer).
pub const BACKUP_GROUP: &str = "backup";
/// BKP-1 — a root "made" later than this from now is not a backup of mine:
/// it would sort first for ever and hide every real one.
pub const ROOT_FUTURE_SECS: i64 = 24 * 3600;

const ROOT2_MAGIC: &[u8; 4] = b"SNB2";
/// Magic, generation, HPKE encapsulated key (X25519) + sealed 32-byte secret.
const ROOT2_HEAD: usize = 4 + 4 + 32 + 32 + 16;
const ROOTS_INFO: &[u8] = b"sinhron-backup-roots/v1";

/// A new generation of the account roots after [newest], from fresh bytes.
pub fn new_generation(newest: Option<&RootsGen>) -> RootsGen {
    let mut secret = [0u8; 32];
    OsRng.fill_bytes(&mut secret);
    // DEV-2 — a planted generation number can't wrap round to 0 (= "not rotated").
    RootsGen { gen: newest.map_or(0, |g| g.gen).saturating_add(1), secret }
}

/// The root of this device's backup: as before while [roots] (newest first)
/// is empty, else sealed with the newest generation's key (see above).
pub fn seal_root_for(secret: &str, roots: &[RootsGen], root: &Root) -> Result<Vec<u8>, String> {
    let Some(g) = roots.first() else { return Ok(seal_root(&key_and_account(secret)?.0, root)) };
    let a = sinhron_crypto::identity::account_view(secret).map_err(|e| e.to_string())?;
    let gen = g.gen.to_be_bytes();
    let ct = RustCrypto::default()
        .hpke_seal(crate::sealed::HPKE, &a.x25519_public, ROOTS_INFO, &gen, &g.secret)
        .map_err(|e| format!("seal: {e:?}"))?;
    let mut head = ROOT2_MAGIC.to_vec();
    head.extend_from_slice(&gen);
    head.extend_from_slice(ct.kem_output.as_slice());
    head.extend_from_slice(ct.ciphertext.as_slice());
    if head.len() != ROOT2_HEAD {
        return Err("backup header size".into());
    }
    let body = seal_with(&g.cloud_key(), &[ROOT_AAD, &head[..]].concat(), root);
    head.extend_from_slice(&body);
    Ok(head)
}

/// Open a root with what [secret] and [roots] (every generation this device
/// holds) give. A newer generation's root needs the 24 words (or the device
/// key standing for them) — a disconnected device has neither.
pub fn open_root_for(secret: &str, roots: &[RootsGen], bytes: &[u8]) -> Result<Root, TransferError> {
    if bytes.len() > ROOT2_HEAD && bytes.starts_with(ROOT2_MAGIC) {
        let (head, body) = bytes.split_at(ROOT2_HEAD);
        let aad = [ROOT_AAD, head].concat();
        let gen = u32::from_be_bytes(head[4..8].try_into().expect("4 bytes"));
        let mut keys: Vec<[u8; 32]> = roots.iter().filter(|g| g.gen == gen).map(RootsGen::cloud_key).collect();
        if let Ok(id) = sinhron_crypto::identity::derive_identity(secret) {
            let ct = HpkeCiphertext { kem_output: head[8..40].to_vec().into(), ciphertext: head[40..].to_vec().into() };
            let opened = RustCrypto::default().hpke_open(crate::sealed::HPKE, &ct, &id.x25519_secret, ROOTS_INFO, &head[4..8]);
            if let Some(s) = opened.ok().and_then(|s| <[u8; 32]>::try_from(s.as_slice()).ok()) {
                keys.push(RootsGen { gen, secret: s }.cloud_key());
            }
        }
        if let Some(r) = keys.iter().find_map(|k| open_with(k, &aad, body).ok()) {
            return Ok(r);
        }
        // Not ours (or, once in 2^32, an old root whose nonce starts so).
        return key_and_account(secret)
            .ok()
            .and_then(|(k, _)| open_root(&k, bytes).ok())
            .ok_or_else(|| TransferError::Bad("this backup was made after a device was disconnected — the 24 words open it".into()));
    }
    open_root(&key_and_account(secret).map_err(TransferError::Bad)?.0, bytes)
}

/// The error for a linked device whose bundle predates the backup key
/// (ADR-027 bundles before ADR-073): the 24 words add it.
pub const NO_KEY: &str = "no_backup_key";

/// What a secret (24 words, device key, linked bundle) gives the backup:
/// the key and the account (ed25519 public, hex).
pub fn key_and_account(secret: &str) -> Result<([u8; 32], String), String> {
    let a = sinhron_crypto::identity::account_view(secret).map_err(|e| e.to_string())?;
    Ok((a.cloud_key.ok_or(NO_KEY)?, hex::encode(a.ed25519_public)))
}

/// The name prefix of this device's backup in the cloud folder (16 hex):
/// from the device's certificate on a linked device, from the account on
/// the one that holds the account key. Public, says nothing of either.
pub fn device_tag(secret: &str) -> Result<String, String> {
    let mut h = Sha256::new();
    h.update(b"sinhron-backup-tag/v1");
    match sinhron_crypto::identity::LinkedBundle::decode(secret) {
        Ok(b) => h.update(&b.certificate),
        Err(_) => h.update(sinhron_crypto::identity::account_view(secret).map_err(|e| e.to_string())?.ed25519_public),
    }
    Ok(hex::encode(&h.finalize()[..8]))
}

/// A linked device without the backup key ([`NO_KEY`]): from the 24 words,
/// its bundle with the key added — the same device, the same database key
/// and tag. Any other secret comes back as it is; words of another account
/// are refused.
pub fn unlock_with_phrase(phrase: &str, secret: &str) -> Result<String, String> {
    let Ok(mut b) = sinhron_crypto::identity::LinkedBundle::decode(secret) else {
        return Ok(secret.to_string());
    };
    if b.cloud_key.is_some() {
        return Ok(secret.to_string());
    }
    let id = sinhron_crypto::identity::derive_identity(phrase).map_err(|_| "not the 24 words".to_string())?;
    if id.ed25519_public != b.identity_public {
        return Err("other_words".into());
    }
    b.cloud_key = Some(sinhron_crypto::identity::cloud_backup_key(&id.backup_key));
    Ok(b.encode())
}

/// SHA-256 of a blob, hex — the name everything is kept under.
pub fn blob_name(blob: &[u8]) -> String {
    hex::encode(Sha256::digest(blob))
}

/// The transfer's I/O on a staging folder. Uploads write files the cloud
/// doesn't have ([`Self::cloud_has`]); downloads read them and note the
/// ones that aren't there yet ([`Self::needed`]) — Dart fetches those.
pub struct DirTransport {
    pub dir: PathBuf,
    cloud_has: HashSet<String>,
    written: Mutex<Vec<(String, u64)>>,
    needed: Mutex<Vec<String>>,
}

impl DirTransport {
    pub fn new(dir: impl Into<PathBuf>, cloud_has: impl IntoIterator<Item = String>) -> Self {
        Self {
            dir: dir.into(),
            cloud_has: cloud_has.into_iter().collect(),
            written: Mutex::new(Vec::new()),
            needed: Mutex::new(Vec::new()),
        }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    /// Files written to the staging folder by this transport (name, size).
    pub fn written(&self) -> Vec<(String, u64)> {
        self.written.lock().map(|w| w.clone()).unwrap_or_default()
    }

    pub fn written_bytes(&self) -> u64 {
        self.written().iter().map(|(_, n)| n).sum()
    }

    /// Files a download asked for that aren't in the staging folder.
    pub fn needed(&self) -> Vec<String> {
        self.needed.lock().map(|n| n.clone()).unwrap_or_default()
    }

    fn put(&self, name: &str, bytes: &[u8]) -> Result<(), TransferError> {
        std::fs::create_dir_all(&self.dir).map_err(|e| TransferError::Storage(e.to_string()))?;
        let tmp = self.path(&format!("{name}.tmp"));
        std::fs::write(&tmp, bytes).map_err(|e| TransferError::Storage(e.to_string()))?;
        std::fs::rename(&tmp, self.path(name)).map_err(|e| TransferError::Storage(e.to_string()))?;
        if let Ok(mut w) = self.written.lock() {
            w.push((name.to_string(), bytes.len() as u64));
        }
        Ok(())
    }
}

impl Transport for DirTransport {
    async fn upload(&self, blob: Vec<u8>) -> Result<(), TransferError> {
        let name = blob_name(&blob);
        if self.cloud_has.contains(&name) || self.path(&name).is_file() {
            return Ok(());
        }
        self.put(&name, &blob)
    }

    async fn download(&self, sha_hex: &str) -> Result<Vec<u8>, TransferError> {
        if !storage::blobs::is_sha_hex(sha_hex) {
            return Err(TransferError::Bad("blob name".into()));
        }
        match std::fs::read(self.path(sha_hex)) {
            Ok(b) => Ok(b),
            Err(_) => {
                if let Ok(mut n) = self.needed.lock() {
                    n.push(sha_hex.to_string());
                }
                // Net: the job stays where it is; the caller fetches the file.
                Err(TransferError::Net(format!("need {sha_hex}")))
            }
        }
    }

    async fn touch(&self, shas: &[String]) -> Result<Vec<String>, TransferError> {
        Ok(shas.iter().filter(|s| !self.cloud_has.contains(*s) && !self.path(s).is_file()).cloned().collect())
    }

    async fn send_own(&self, _group_hex: &str, _plaintext: Vec<u8>) -> Result<(), TransferError> {
        // The root (written by the caller once the manifest is up) takes
        // the place of the MLS offer.
        Ok(())
    }
}

/// The root for a finished upload stage of [job] (its manifest is set).
pub fn root_of(job: &ExportJob, account_hex: &str) -> Option<Root> {
    Some(Root {
        account: account_hex.to_string(),
        created_ts: job.created_ts,
        id: job.id.clone(),
        manifest: job.manifest.clone()?,
        messages: job.messages,
        chats: job.chats,
        media: job.media_total,
    })
}

/// Every name the newest backup uses (the root, manifest, parts, packs and
/// media) — the rest of the cloud folder is from older backups.
pub fn keep_names(job: &ExportJob, media: &[String]) -> Vec<String> {
    let mut out = vec![ROOT_NAME.to_string()];
    out.extend(job.manifest.iter().map(|m| m.sha256.clone()));
    out.extend(job.parts.iter().map(|p| p.sha256.clone()));
    out.extend(job.packs.iter().cloned());
    out.extend(media.iter().cloned());
    out.sort();
    out.dedup();
    out
}

/// After a restore: media the restored messages point to that this phone
/// has no copy of (to fetch from the backup).
pub fn media_to_restore() -> Result<Vec<String>, TransferError> {
    let mut all = Vec::new();
    for chat in storage::transfer::export_chat_ids()? {
        let mut after: Option<(i64, String)> = None;
        loop {
            let page = storage::transfer::export_messages(&chat, after.as_ref().map(|(t, i)| (*t, i.as_str())), 1000)?;
            let Some(last) = page.last() else { break };
            after = Some((last.ts, last.id.clone()));
            for m in page {
                if let Some(j) = &m.media_json {
                    media_shas(j, &mut all);
                }
            }
        }
    }
    all.sort();
    all.dedup();
    all.retain(|s| !storage::blobs::has(s));
    Ok(all)
}

/// Take the media files fetched into [dir] as this phone's local copies
/// (each checked against its name); the files are removed from [dir].
/// Returns how many were kept.
pub fn adopt_media(dir: &Path, names: &[String]) -> Result<u32, TransferError> {
    let mut kept = 0;
    for name in names {
        if !storage::blobs::is_sha_hex(name) {
            continue;
        }
        let path = dir.join(name);
        let Ok(blob) = std::fs::read(&path) else { continue };
        if blob_name(&blob) == *name {
            storage::blobs::put(name, &blob)?;
            kept += 1;
        }
        let _ = std::fs::remove_file(&path);
    }
    Ok(kept)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(b: u8) -> [u8; 32] {
        [b; 32]
    }

    fn root() -> Root {
        Root {
            account: "ab".repeat(32),
            created_ts: 1_760_000_000,
            id: "backup-1".into(),
            manifest: BlobEntry { sha256: "cd".repeat(32), key: "a2V5".into(), blob_size: 4096, plain_size: 1000 },
            messages: 1520,
            chats: 12,
            media: 340,
        }
    }

    #[test]
    fn the_root_opens_with_the_same_words_only() {
        let sealed = seal_root(&key(1), &root());
        assert_eq!(open_root(&key(1), &sealed).unwrap(), root());
        let err = open_root(&key(2), &sealed).unwrap_err();
        assert!(matches!(err, TransferError::Bad(m) if m.contains("other secret words")));
        assert!(open_root(&key(1), b"short").is_err());
        assert_ne!(seal_root(&key(1), &root()), sealed, "a fresh nonce every time");
    }

    #[tokio::test]
    async fn the_staging_folder_keeps_what_the_cloud_lacks_and_asks_for_what_it_needs() {
        let dir = std::env::temp_dir().join(format!("sinhron-backup-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let in_cloud = b"already up".to_vec();
        let t = DirTransport::new(&dir, [blob_name(&in_cloud)]);
        t.upload(in_cloud.clone()).await.unwrap();
        t.upload(b"new part".to_vec()).await.unwrap();
        t.upload(b"new part".to_vec()).await.unwrap();
        assert_eq!(t.written(), vec![(blob_name(b"new part"), 8)], "once, and not what the cloud has");
        assert_eq!(t.download(&blob_name(b"new part")).await.unwrap(), b"new part");

        let missing = blob_name(b"in the cloud only");
        assert!(matches!(t.download(&missing).await, Err(TransferError::Net(_))));
        assert_eq!(t.needed(), vec![missing.clone()]);
        assert_eq!(t.touch(&[missing.clone(), blob_name(&in_cloud)]).await.unwrap(), vec![missing]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    const WORDS: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const OTHER: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";

    fn without_key(bundle: &str) -> String {
        let mut b = sinhron_crypto::identity::LinkedBundle::decode(bundle).unwrap();
        b.cloud_key = None;
        b.encode()
    }

    #[test]
    fn every_device_of_an_account_has_the_key_and_its_own_tag() {
        let main = sinhron_crypto::identity::device_key_from_phrase(WORDS).unwrap();
        let ipad = crate::identity::linked_bundle_from_phrase(WORDS, &[5u8; 32]).unwrap();
        let phone = crate::identity::linked_bundle_from_phrase(WORDS, &[6u8; 32]).unwrap();
        let (k, account) = key_and_account(&main).unwrap();
        assert_eq!(key_and_account(&ipad).unwrap(), (k, account.clone()));
        assert_eq!(key_and_account(WORDS).unwrap().0, k);
        assert_ne!(key_and_account(OTHER).unwrap().0, k);
        let tags = [device_tag(&main).unwrap(), device_tag(&ipad).unwrap(), device_tag(&phone).unwrap()];
        assert!(tags.iter().all(|t| t.len() == 16));
        assert_ne!(tags[0], tags[1]);
        assert_ne!(tags[1], tags[2]);
        assert_eq!(device_tag(&ipad).unwrap(), tags[1], "stable");
    }

    /// ADR-084 (status 238, audit mls-identity:2 / storage-devices:10) — the
    /// owner disconnects his iPad; his phone makes the next backup. The iPad's
    /// bundle (every key it holds) no longer opens it; his other linked device
    /// with the new generation does, and so do the 24 words alone on a new
    /// phone. With no disconnect the root is the old format, opened as before.
    #[test]
    fn a_disconnected_device_cannot_open_the_backups_made_after_it() {
        let main = sinhron_crypto::identity::device_key_from_phrase(WORDS).unwrap();
        let stolen = crate::identity::linked_bundle_from_phrase(WORDS, &[5u8; 32]).unwrap();
        let laptop = crate::identity::linked_bundle_from_phrase(WORDS, &[6u8; 32]).unwrap();
        let r = root();
        let account = |s: &str| key_and_account(s).unwrap().1;
        let r = Root { account: account(&main), ..r };

        // Generation 0: today's format and key, every device opens it.
        let before = seal_root_for(&main, &[], &r).unwrap();
        assert_eq!(open_root(&key_and_account(&main).unwrap().0, &before).unwrap(), r);
        assert_eq!(open_root_for(&stolen, &[], &before).unwrap(), r);

        let gen = new_generation(None);
        assert_eq!(gen.gen, 1);
        assert_ne!(new_generation(None).secret, gen.secret, "fresh bytes");
        let after = seal_root_for(&main, &[gen], &r).unwrap();
        assert!(open_root_for(&stolen, &[], &after).is_err(), "the disconnected iPad can't open it");
        assert!(open_root(&key_and_account(&stolen).unwrap().0, &after).is_err());
        assert_eq!(open_root_for(&laptop, &[gen], &after).unwrap(), r, "my other device");
        assert_eq!(open_root_for(WORDS, &[], &after).unwrap(), r, "the 24 words on a new phone");
        assert_eq!(open_root_for(&main, &[], &after).unwrap(), r);
        assert!(open_root_for(OTHER, &[], &after).is_err());
        // The header is bound to the rest: a changed byte in it → refused.
        let mut swapped = after.clone();
        swapped[20] ^= 1;
        assert!(open_root_for(&laptop, &[gen], &swapped).is_err());
        // A device a generation behind still opens the older backups.
        let gen2 = new_generation(Some(&gen));
        assert_eq!(open_root_for(&laptop, &[gen2, gen], &after).unwrap(), r);
    }

    #[test]
    fn the_24_words_give_an_older_linked_device_the_key() {
        let ipad = crate::identity::linked_bundle_from_phrase(WORDS, &[5u8; 32]).unwrap();
        let old = without_key(&ipad);
        assert_eq!(key_and_account(&old).unwrap_err(), NO_KEY);
        assert_eq!(unlock_with_phrase(OTHER, &old).unwrap_err(), "other_words");
        assert!(unlock_with_phrase("not words", &old).is_err());
        let new = unlock_with_phrase(WORDS, &old).unwrap();
        assert_eq!(new, ipad);
        assert_eq!(device_tag(&new).unwrap(), device_tag(&old).unwrap());
        let db = |s: &str| sinhron_crypto::identity::account_view(s).unwrap().storage_key;
        assert_eq!(db(&new), db(&old), "the database stays open");
        assert_eq!(unlock_with_phrase(WORDS, &new).unwrap(), new, "already there");
    }

    fn fresh_db(name: &str) {
        let path = std::env::temp_dir().join(format!("sinhron_sync_backup_{name}_{}.db", std::process::id()));
        let _ = storage::open(&path, None);
        storage::erase_and_reopen_plain(&path).unwrap();
    }

    fn names_in(dir: &Path) -> Vec<String> {
        let mut v: Vec<String> = std::fs::read_dir(dir)
            .map(|r| r.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
            .unwrap_or_default();
        v.sort();
        v
    }

    /// The whole trip the app makes (`api/backup.rs` + backup_service.dart),
    /// with a folder for the cloud: the phone backs up in small runs, the
    /// cloud ends up with exactly the names the keep list gives; an empty
    /// phone opens the root with the same key and gets the chats, messages
    /// and the photo back. A second backup uploads no media again.
    #[tokio::test]
    async fn a_backup_in_a_folder_comes_back_on_an_empty_phone() {
        use crate::transfer::{ExportStage, ImportJob, ImportStage};
        use base64::Engine;
        let _db = crate::test_db_lock();
        let base = std::env::temp_dir().join(format!("sinhron-backup-e2e-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let (cloud, out, inn) = (base.join("cloud"), base.join("out"), base.join("in"));
        std::fs::create_dir_all(&cloud).unwrap();

        fresh_db("old");
        storage::chat_upsert("g1", "Anna", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
        let big = "x".repeat(4000);
        for i in 0..300 {
            let (id, wire) = (format!("m{i:04}"), format!("w{i:04}"));
            storage::message_insert(&storage::NewMessage {
                id: &id,
                chat_id: "g1",
                ts_unix: 1000 + i,
                body: &big,
                kind: "text",
                is_mine: i % 2 == 0,
                wire_id: Some(&wire),
                sender_id: Some("peer"),
                ..Default::default()
            })
            .unwrap();
        }
        let (blob, r) = crate::media::encrypt(b"a photo").unwrap();
        let photo = r.sha256_hex();
        storage::blobs::put(&photo, &blob).unwrap();
        let mj = serde_json::json!({"v": 1, "kind": "photo", "file": {"sha256": photo, "key": base64::engine::general_purpose::STANDARD.encode(r.key), "blob_size": r.blob_size, "plain_size": r.plain_size}}).to_string();
        storage::message_insert(&storage::NewMessage {
            id: "photo",
            chat_id: "g1",
            ts_unix: 5000,
            body: "",
            kind: "photo",
            is_mine: true,
            media_json: Some(&mj),
            wire_id: Some("wphoto"),
            ..Default::default()
        })
        .unwrap();

        let k = key(7);
        let account = "ab".repeat(32);
        let backup = |id: &str| ExportJob::new(id.into(), "00".repeat(32), "backup".into(), 1);
        // One "run" of the app: steps until the budget, then uploads (root last).
        async fn run(job: &mut ExportJob, cloud: &Path, out: &Path, k: &[u8; 32], account: &str) -> (Vec<String>, usize) {
            let mut keep = Vec::new();
            let mut uploads = 0;
            let mut runs = 0;
            while !job.done() {
                runs += 1;
                assert!(runs < 500);
                let t = DirTransport::new(out, names_in(cloud));
                let mut root = None;
                while !job.done() {
                    let before = job.stage;
                    job.step(&t, "saved_chat_id").await.unwrap();
                    if before == ExportStage::Upload && job.stage == ExportStage::Offer {
                        root = Some(seal_root(k, &root_of(job, account).unwrap()));
                        keep = keep_names(job, &crate::transfer::media_list(&job.id).unwrap());
                        break;
                    }
                    if t.written_bytes() >= 64 * 1024 {
                        break;
                    }
                }
                for (n, _) in t.written() {
                    std::fs::rename(out.join(&n), cloud.join(&n)).unwrap();
                    uploads += 1;
                }
                if let Some(r) = root {
                    std::fs::write(cloud.join(ROOT_NAME), r).unwrap();
                }
            }
            (keep, uploads)
        }
        let mut job = backup("backup-1");
        let (keep, _) = run(&mut job, &cloud, &out, &k, &account).await;
        let mut keep_sorted = keep.clone();
        keep_sorted.sort();
        assert_eq!(names_in(&cloud), keep_sorted, "the cloud holds the backup and nothing else");
        assert!(keep.contains(&photo));
        assert_eq!(job.media_uploaded, 1);
        // The server-side fields stay out: nothing in the clear.
        for n in names_in(&cloud) {
            let b = std::fs::read(cloud.join(&n)).unwrap();
            assert!(!b.windows(8).any(|w| w == b"xxxxxxxx"), "{n} is not encrypted");
        }

        // The next day: the photo is already there.
        let mut job2 = backup("backup-2");
        run(&mut job2, &cloud, &out, &k, &account).await;
        assert_eq!(job2.media_uploaded, 0, "media go up once");

        // ── An empty phone.
        fresh_db("new");
        let root = open_root(&k, &std::fs::read(cloud.join(ROOT_NAME)).unwrap()).unwrap();
        assert_eq!(root.messages, 301);
        let mut imp = ImportJob::from_offer(&root.offer().unwrap(), "backup").unwrap();
        let mut fetches = 0;
        while !imp.finished() {
            let t = DirTransport::new(&inn, Vec::<String>::new());
            loop {
                match imp.step(&t).await {
                    Ok(Some(_)) if !imp.finished() => continue,
                    Ok(_) => break,
                    Err(TransferError::Net(_)) if !t.needed().is_empty() => break,
                    Err(e) => panic!("{e}"),
                }
            }
            for n in t.needed() {
                std::fs::create_dir_all(&inn).unwrap();
                std::fs::copy(cloud.join(&n), inn.join(&n)).unwrap();
                fetches += 1;
            }
            assert!(fetches < 500);
        }
        assert_eq!(imp.stage, ImportStage::Done, "{:?}", imp.error);
        assert_eq!(storage::messages_list_for_chat("g1", None).unwrap().len(), 301);
        assert!(storage::chats_list().unwrap().iter().any(|c| c.id == "g1" && c.display_name == "Anna"));
        let media = media_to_restore().unwrap();
        assert_eq!(media, vec![photo.clone()]);
        std::fs::copy(cloud.join(&photo), inn.join(&photo)).unwrap();
        assert_eq!(adopt_media(&inn, &media).unwrap(), 1);
        assert!(storage::blobs::has(&photo));
        assert!(media_to_restore().unwrap().is_empty());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn keep_names_cover_the_whole_backup() {
        let mut job = ExportJob::new("b".into(), "00".into(), "backup".into(), 0);
        job.manifest = Some(root().manifest);
        job.parts = vec![BlobEntry { sha256: "11".repeat(32), key: String::new(), blob_size: 1, plain_size: 1 }];
        job.packs = vec!["22".repeat(32)];
        let keep = keep_names(&job, &["33".repeat(32), "22".repeat(32)]);
        assert_eq!(keep.len(), 5);
        assert!(keep.contains(&ROOT_NAME.to_string()));
    }
}
