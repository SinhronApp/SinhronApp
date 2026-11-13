// Media blob encryption — spec §6.9, §11.1. ADR-017.
//
//   • Fresh random 32-byte key + 12-byte nonce per blob, AES-256-GCM,
//     empty AAD. Never reused: one key encrypts exactly one blob.
//   • Wire/storage form: `nonce (12) || ciphertext || tag (16)`.
//   • Server name = sha256(blob). The key, hash and sizes travel only
//     inside the MLS application message (`envelope::MediaRef`), so the
//     server holds ciphertext it can't open.
//   • Decrypt verifies sha256 and size BEFORE touching AES, so a server
//     (or cache) that hands back the wrong bytes is caught as such
//     rather than as a generic auth-tag failure.
//   • Size hiding (tech-debt 2.19): the plaintext is zero-padded INSIDE
//     the AEAD before encryption — files to a Padmé bucket (≥1 KiB),
//     thumbnails to exactly 32 KiB — so the server sees a coarse size
//     class, not the exact length. The real length (`plain_size`)
//     travels only in the encrypted envelope; decrypt truncates to it.
//     Old unpadded blobs decrypt unchanged (nothing to truncate).
//   • Local copy (ADR-033): every blob this device uploads or downloads
//     is also kept as ciphertext next to the DB
//     (`sinhron_storage::blobs`), so media opens offline and survives
//     the server's 90-day sweep. [`fetch`] reads it first and verifies
//     it like a download; a copy that fails is dropped and re-fetched.

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, Key, KeyInit, Nonce};
use rand_core::{OsRng, RngCore};
use sha2::{Digest, Sha256};

pub const KEY_LEN: usize = 32;
pub const NONCE_LEN: usize = 12;
pub const TAG_LEN: usize = 16;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum MediaError {
    #[error("blob sha256 does not match the message")]
    HashMismatch,
    #[error("blob size {got} does not match the message ({want})")]
    SizeMismatch { got: u64, want: u64 },
    #[error("media key must be {KEY_LEN} bytes")]
    BadKey,
    #[error("blob too short")]
    Truncated,
    #[error("decryption failed (corrupted blob or wrong key)")]
    Decrypt,
    #[error("encryption failed")]
    Encrypt,
}

/// Everything a recipient needs to fetch and open one blob. Carried in
/// `envelope::MediaRef` on the wire.
#[derive(Clone, PartialEq, Eq)]
pub struct BlobRef {
    pub sha256: [u8; 32],
    pub key: [u8; KEY_LEN],
    /// Size of the encrypted blob as stored on the server.
    pub blob_size: u64,
    /// Size of the plaintext (for UI: "2.4 MB").
    pub plain_size: u64,
}

impl std::fmt::Debug for BlobRef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BlobRef").field("blob_size", &self.blob_size).field("plain_size", &self.plain_size).finish_non_exhaustive()
    }
}

impl BlobRef {
    pub fn sha256_hex(&self) -> String {
        hex::encode(self.sha256)
    }
}

/// Smallest padded file size — tiny files all look alike.
pub const MIN_PADDED_BYTES: u64 = 1024;

/// Padmé padding length (Nikitin et al., "Reducing Metadata Leakage
/// from Encrypted Files and Communication with PURBs", PETS 2019): keep
/// only the top ~log2(E) bits of the length. Overhead ≤ 12 % (≈2 % at
/// 100 MB), leaks O(log log L) bits instead of the exact size.
pub fn padme(len: u64) -> u64 {
    if len < 2 {
        return len;
    }
    let e = 63 - len.leading_zeros() as u64; // floor(log2 L)
    let s = 64 - e.leading_zeros() as u64; // floor(log2 E) + 1
    let last_bits = e - s;
    let mask = (1u64 << last_bits) - 1;
    (len + mask) & !mask
}

/// Padded plaintext length for a file of `len` bytes.
pub fn padded_len(len: u64) -> u64 {
    padme(len.max(MIN_PADDED_BYTES))
}

/// Encrypt `plaintext` under a fresh key, padded to its Padmé bucket.
/// Returns the blob to upload and the reference to put in the message.
pub fn encrypt(plaintext: &[u8]) -> Result<(Vec<u8>, BlobRef), MediaError> {
    encrypt_padded(plaintext, padded_len(plaintext.len() as u64))
}

/// Encrypt padded to exactly `padded` bytes of plaintext (≥ its length).
pub fn encrypt_padded(plaintext: &[u8], padded: u64) -> Result<(Vec<u8>, BlobRef), MediaError> {
    if (padded as usize) < plaintext.len() {
        return Err(MediaError::Encrypt);
    }
    let mut buf = Vec::with_capacity(padded as usize);
    buf.extend_from_slice(plaintext);
    buf.resize(padded as usize, 0);
    let mut key = [0u8; KEY_LEN];
    OsRng.fill_bytes(&mut key);
    let mut nonce = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce);

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&key));
    let ct = cipher
        .encrypt(Nonce::from_slice(&nonce), buf.as_slice())
        .map_err(|_| MediaError::Encrypt)?;
    drop(buf);

    let mut blob = Vec::with_capacity(NONCE_LEN + ct.len());
    blob.extend_from_slice(&nonce);
    blob.extend_from_slice(&ct);

    let sha256: [u8; 32] = Sha256::digest(&blob).into();
    let r = BlobRef {
        sha256,
        key,
        blob_size: blob.len() as u64,
        plain_size: plaintext.len() as u64,
    };
    Ok((blob, r))
}

/// Verify `blob` against `r` and decrypt it.
pub fn decrypt(blob: &[u8], r: &BlobRef) -> Result<Vec<u8>, MediaError> {
    if blob.len() as u64 != r.blob_size {
        return Err(MediaError::SizeMismatch {
            got: blob.len() as u64,
            want: r.blob_size,
        });
    }
    let sha256: [u8; 32] = Sha256::digest(blob).into();
    if sha256 != r.sha256 {
        return Err(MediaError::HashMismatch);
    }
    if blob.len() < NONCE_LEN + TAG_LEN {
        return Err(MediaError::Truncated);
    }
    let (nonce, ct) = blob.split_at(NONCE_LEN);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(&r.key));
    let mut pt = cipher
        .decrypt(Nonce::from_slice(nonce), ct)
        .map_err(|_| MediaError::Decrypt)?;
    // Strip the padding; the real length is authenticated via the MLS
    // envelope. A plaintext shorter than claimed is corrupt.
    if (pt.len() as u64) < r.plain_size {
        return Err(MediaError::Truncated);
    }
    pt.truncate(r.plain_size as usize);
    Ok(pt)
}

// ── Upload / fetch over HTTP ──────────────────────────────────────

use crate::envelope::{MediaBody, MediaKind, MediaRef};
use crate::http_api::{HttpApi, HttpError};

/// Spec §11.2 — the encrypted preview stays tiny so it can be fetched
/// eagerly for every visible bubble.
pub const MAX_THUMBNAIL_BYTES: usize = 32 * 1024;

/// Largest plaintext we send: its padded blob must stay under the
/// server's default SINHRON_MEDIA_MAX_BYTES (100 MiB). Padmé adds ≤ 2 %
/// at this size, AES-GCM 28 bytes.
pub const MAX_MEDIA_BYTES: u64 = 95 * 1024 * 1024;

/// What the UI hands over to send one media message. `data` and
/// `thumbnail` are plaintext; they're encrypted here before any I/O.
#[derive(Debug, Clone, Default)]
pub struct MediaDraft {
    pub kind: Option<MediaKind>,
    pub data: Vec<u8>,
    pub thumbnail: Option<Vec<u8>>,
    pub mime_type: String,
    pub file_name: String,
    pub blurhash: String,
    pub width: u32,
    pub height: u32,
    pub duration_ms: u32,
    pub waveform: Vec<u8>,
    pub caption: String,
}

#[derive(Debug, thiserror::Error)]
pub enum MediaTransferError {
    #[error("invalid media: {0}")]
    Invalid(&'static str),
    #[error(transparent)]
    Crypto(#[from] MediaError),
    #[error(transparent)]
    Http(#[from] HttpError),
    #[error(transparent)]
    Envelope(#[from] crate::envelope::EnvelopeError),
}

/// Encrypt + upload the file (and thumbnail), return the envelope body
/// to send over MLS. Nothing plaintext leaves this function.
pub async fn upload(
    http: &HttpApi,
    identity_seed: [u8; 32],
    draft: MediaDraft,
) -> Result<MediaBody, MediaTransferError> {
    upload_with_progress(http, identity_seed, draft, &|_, _| {}).await
}

/// [`upload`] reporting `(bytes_sent, bytes_total)` across both blobs
/// (thumbnail + file, ciphertext sizes) for an upload percentage.
pub async fn upload_with_progress(
    http: &HttpApi,
    identity_seed: [u8; 32],
    draft: MediaDraft,
    on_progress: &(dyn Fn(u64, u64) + Send + Sync),
) -> Result<MediaBody, MediaTransferError> {
    let kind = draft.kind.ok_or(MediaTransferError::Invalid("kind not set"))?;
    if kind == MediaKind::Unspecified {
        return Err(MediaTransferError::Invalid("kind not set"));
    }
    if draft.data.is_empty() {
        return Err(MediaTransferError::Invalid("empty file"));
    }
    if draft.data.len() as u64 > MAX_MEDIA_BYTES {
        return Err(MediaTransferError::Invalid("file larger than 95 MB"));
    }
    if draft.waveform.len() > crate::envelope::MAX_WAVEFORM_POINTS {
        return Err(MediaTransferError::Invalid("waveform too long"));
    }
    if draft.file_name.len() > crate::envelope::MAX_FILE_NAME_BYTES {
        return Err(MediaTransferError::Invalid("file name too long"));
    }

    // Encrypt everything first so the total is known for progress.
    let thumb = match draft.thumbnail {
        Some(t) if t.len() > MAX_THUMBNAIL_BYTES => {
            return Err(MediaTransferError::Invalid("thumbnail over 32 KB"));
        }
        // Every thumbnail is exactly 32 KiB on the wire.
        Some(t) if !t.is_empty() => Some(encrypt_padded(&t, MAX_THUMBNAIL_BYTES as u64)?),
        _ => None,
    };
    let (blob, r) = encrypt(&draft.data)?;
    drop(draft.data);
    let thumb_len = thumb.as_ref().map(|(b, _)| b.len() as u64).unwrap_or(0);
    let total = thumb_len + blob.len() as u64;
    on_progress(0, total);

    // ADR-033 — keep the ciphertext before it leaves. Best-effort: no
    // open DB (CLI, tests) or a full disk only costs the local copy.
    if let Some((tblob, tr)) = &thumb {
        keep_local(tr, tblob);
    }
    keep_local(&r, &blob);

    let thumbnail = match thumb {
        Some((tblob, tr)) => {
            http.upload_media_with_progress(identity_seed, tblob, &|sent| on_progress(sent, total))
                .await?;
            Some(MediaRef::from(&tr))
        }
        None => None,
    };
    http.upload_media_with_progress(identity_seed, blob, &|sent| on_progress(thumb_len + sent, total))
        .await?;

    Ok(MediaBody {
        kind: kind as i32,
        file: Some(MediaRef::from(&r)),
        thumbnail,
        mime_type: draft.mime_type,
        file_name: draft.file_name,
        blurhash: draft.blurhash,
        width: draft.width,
        height: draft.height,
        duration_ms: draft.duration_ms,
        waveform: draft.waveform,
        caption: draft.caption,
        // Set by the caller for multi-photo sends (ADR-019).
        album_id: String::new(),
        // Set by the caller for round video messages (ADR-048).
        round: false,
        sticker: None,
        // Set by the caller for a formatted caption (ADR-070).
        caption_entities: Vec::new(),
        caption_rich: false,
    })
}

/// Download + verify + decrypt one blob referenced by a message.
pub async fn fetch(
    http: &HttpApi,
    identity_seed: [u8; 32],
    r: &MediaRef,
) -> Result<Vec<u8>, MediaTransferError> {
    let r = BlobRef::try_from(r)?;
    let sha = r.sha256_hex();
    if let Some(local) = sinhron_storage::blobs::get(&sha) {
        match decrypt(&local, &r) {
            Ok(plain) => return Ok(plain),
            // Corrupt or truncated copy — drop it and fetch again.
            Err(_) => sinhron_storage::blobs::remove(&sha),
        }
    }
    let blob = http.download_media(identity_seed, &sha).await?;
    let plain = decrypt(&blob, &r)?;
    keep_local(&r, &blob);
    Ok(plain)
}

/// Keep [blob] as this device's copy of [r] (ADR-033). Errors are
/// logged, never returned: the copy is an optimisation of availability,
/// not part of sending or opening.
pub fn keep_local(r: &BlobRef, blob: &[u8]) {
    match sinhron_storage::blobs::put(&r.sha256_hex(), blob) {
        Ok(()) | Err(sinhron_storage::StorageError::NotInitialized) => {}
        Err(e) => tracing::warn!(error = %e, "media: local copy not kept"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ADR-033 — a blob this device already holds opens without the
    /// server; a corrupt local copy is dropped and fetched again.
    #[tokio::test]
    async fn fetch_opens_the_local_copy_offline() {
        let _db = crate::test_db_lock();
        let path = std::env::temp_dir().join("sinhron_sync_media_local.db");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir_all(path.with_file_name("sinhron_sync_media_local.db.blobs"));
        sinhron_storage::open(&path, None).unwrap();

        let (blob, r) = encrypt(b"photo bytes").unwrap();
        keep_local(&r, &blob);
        let wire = MediaRef::from(&r);
        // Nothing listens here: any network attempt fails.
        let offline = HttpApi::new("http://127.0.0.1:9".to_string());
        assert_eq!(fetch(&offline, [7; 32], &wire).await.unwrap(), b"photo bytes");

        let sha = r.sha256_hex();
        let mut bad = blob.clone();
        bad[NONCE_LEN] ^= 1;
        sinhron_storage::blobs::remove(&sha);
        sinhron_storage::blobs::put(&sha, &bad).unwrap();
        assert!(fetch(&offline, [7; 32], &wire).await.is_err(), "falls back to the server");
        assert!(sinhron_storage::blobs::get(&sha).is_none(), "the bad copy is gone");
    }

    #[test]
    fn padme_buckets() {
        assert_eq!(padme(0), 0);
        assert_eq!(padme(1), 1);
        assert_eq!(padme(1000), 1024);
        assert_eq!(padme(1024), 1024);
        assert_eq!(padme(1025), 1088); // E=10, S=4 → multiples of 64
        // Overhead never above 12 %, and ≈2 % around 100 MB.
        for len in [1_500u64, 9_999, 123_456, 3_333_333, 50_000_001, 99_000_000] {
            let p = padme(len);
            assert!(p >= len && (p - len) as f64 / len as f64 <= 0.12, "len {len} → {p}");
        }
        assert!((padme(99_000_000) - 99_000_000) as f64 / 99_000_000.0 < 0.03);
    }

    #[test]
    fn padding_hides_exact_size() {
        // Two files 1 KB apart land in the same bucket → identical blob size.
        let (a, ra) = encrypt(&vec![1u8; 300_000]).unwrap();
        let (b, rb) = encrypt(&vec![2u8; 301_000]).unwrap();
        assert_eq!(a.len(), b.len());
        assert_eq!(a.len() as u64, NONCE_LEN as u64 + padme(301_000) + TAG_LEN as u64);
        assert_eq!(decrypt(&a, &ra).unwrap().len(), 300_000);
        assert_eq!(decrypt(&b, &rb).unwrap().len(), 301_000);
        // Tiny files all pad to 1 KiB.
        let (t, rt) = encrypt(b"hi").unwrap();
        assert_eq!(t.len(), NONCE_LEN + 1024 + TAG_LEN);
        assert_eq!(decrypt(&t, &rt).unwrap(), b"hi");
    }

    #[test]
    fn unpadded_legacy_blob_still_decrypts() {
        let pt = b"legacy".to_vec();
        let (blob, r) = encrypt_padded(&pt, pt.len() as u64).unwrap();
        assert_eq!(blob.len(), NONCE_LEN + pt.len() + TAG_LEN);
        assert_eq!(decrypt(&blob, &r).unwrap(), pt);
    }

    #[test]
    fn claimed_size_larger_than_plaintext_is_rejected() {
        let (blob, mut r) = encrypt_padded(b"abc", 3).unwrap();
        r.plain_size = 10;
        assert_eq!(decrypt(&blob, &r), Err(MediaError::Truncated));
    }

    #[test]
    fn roundtrip_and_layout() {
        let pt = b"photo bytes".repeat(100);
        let (blob, r) = encrypt(&pt).unwrap();
        assert_eq!(blob.len() as u64, NONCE_LEN as u64 + padded_len(pt.len() as u64) + TAG_LEN as u64);
        assert_eq!(r.blob_size, blob.len() as u64);
        assert_eq!(r.plain_size, pt.len() as u64);
        assert_eq!(decrypt(&blob, &r).unwrap(), pt);
    }

    #[test]
    fn fresh_key_and_nonce_per_blob() {
        let (a, ra) = encrypt(b"same").unwrap();
        let (b, rb) = encrypt(b"same").unwrap();
        assert_ne!(ra.key, rb.key);
        assert_ne!(a[..NONCE_LEN], b[..NONCE_LEN]);
        assert_ne!(ra.sha256, rb.sha256);
    }

    #[test]
    fn tampering_is_detected() {
        let (mut blob, r) = encrypt(b"secret").unwrap();
        let last = blob.len() - 1;
        blob[last] ^= 1;
        assert_eq!(decrypt(&blob, &r), Err(MediaError::HashMismatch));

        // Matching hash but wrong key → AEAD failure.
        let (blob, mut r) = encrypt(b"secret").unwrap();
        r.key[0] ^= 1;
        assert_eq!(decrypt(&blob, &r), Err(MediaError::Decrypt));

        let (blob, r) = encrypt(b"secret").unwrap();
        assert!(matches!(
            decrypt(&blob[..blob.len() - 1], &r),
            Err(MediaError::SizeMismatch { .. })
        ));
    }
}
