// Identity derivation from BIP-39 recovery phrase.
//
// Per spec §6.2 / §6.8.1 / §6.10 — four sub-keys derived deterministically
// from the 64-byte BIP-39 seed via HKDF-SHA256, each with its own
// `info` context so the keys are domain-separated:
//
//   "sinhron-id-ed25519/v1"  → Ed25519 signing keypair  (identity)
//   "sinhron-id-x25519/v1"   → X25519 keypair           (key agreement / HPKE)
//   "sinhron-state-backup/v1" → 32-byte AEAD key        (encrypts MLS state
//                                                       backup on server,
//                                                       per spec §6.8.1)
//   "sinhron-storage-key/v1"  → 32-byte SQLCipher key   (encrypts local
//                                                       SQLite DBs at rest,
//                                                       per spec §6.10 — T1.1)
//
// The user's recovery phrase is the SINGLE secret. Lose it = lose the
// account (no escrow, no recovery flow). All other key material is
// derived from this seed.
//
// The MLS-credential key, when we wire OpenMLS in a later WU, will be
// the Ed25519 keypair returned by [derive_identity].

use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use hkdf::Hkdf;
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey as X25519Public, StaticSecret as X25519Secret};

use crate::{phrase_to_seed_hex_internal, KeyError};

const HKDF_INFO_ED25519: &[u8] = b"sinhron-id-ed25519/v1";
const HKDF_INFO_X25519: &[u8] = b"sinhron-id-x25519/v1";
const HKDF_INFO_BACKUP: &[u8] = b"sinhron-state-backup/v1";
/// T1.1 — SQLCipher PRAGMA key for at-rest encryption of `sinhron.db`
/// (chats/messages) and `sinhron-mls.sqlite` (MLS state). Spec §6.10.
const HKDF_INFO_STORAGE: &[u8] = b"sinhron-storage-key/v1";
/// ADR-023 — root of the weekly sealed-sender delivery keys.
const HKDF_INFO_DELIVERY: &[u8] = b"sinhron-delivery/v1";
/// Tech-debt 2.2 — root of the sealed-sender access keys (per version).
const HKDF_INFO_ACCESS: &[u8] = b"sinhron-access-root/v1";
/// ADR-073 — the chat backup in the person's own cloud, from the backup key.
const HKDF_INFO_CLOUD_BACKUP: &[u8] = b"sinhron-cloud-backup/v1";

/// ADR-073 — the key of the chat backup in iCloud / Google Drive. One step
/// below [`DerivedIdentity::backup_key`], so a linked device (ADR-027) can be
/// given this one alone: it opens the cloud copy of the chats it already
/// has, never the server's state backup or anything signed.
pub fn cloud_backup_key(backup_key: &[u8; 32]) -> [u8; 32] {
    let mut out = [0u8; 32];
    Hkdf::<Sha256>::new(None, backup_key)
        .expand(HKDF_INFO_CLOUD_BACKUP, &mut out)
        .expect("32 bytes is well below HKDF expand limit");
    out
}

/// ADR-084 — a new generation of the account's delivery root and cloud
/// backup key, made when a device is disconnected: from fresh random bytes
/// the disconnected device never saw (it keeps only generation 0, the
/// phrase-derived ones above). Travels to my other devices inside my
/// own-devices MLS group (a synced setting, ADR-064). Kept as `<gen>:<hex>`.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct RootsGen {
    pub gen: u32,
    pub secret: [u8; 32],
}

impl RootsGen {
    fn expand(&self, label: &[u8]) -> [u8; 32] {
        let mut info = label.to_vec();
        info.extend_from_slice(&self.gen.to_be_bytes());
        let mut out = [0u8; 32];
        Hkdf::<Sha256>::new(None, &self.secret).expand(&info, &mut out).expect("32 bytes is well below HKDF expand limit");
        out
    }

    pub fn delivery_root(&self) -> [u8; 32] {
        self.expand(HKDF_INFO_DELIVERY)
    }

    pub fn cloud_key(&self) -> [u8; 32] {
        self.expand(HKDF_INFO_CLOUD_BACKUP)
    }

    pub fn encode(&self) -> String {
        format!("{}:{}", self.gen, hex::encode(self.secret))
    }

    /// A comma-separated list of [`Self::encode`]; malformed entries are skipped.
    pub fn decode_list(s: &str) -> Vec<RootsGen> {
        s.split(',')
            .filter_map(|e| {
                let (g, h) = e.trim().split_once(':')?;
                let secret = hex::decode(h).ok()?.try_into().ok()?;
                Some(RootsGen { gen: g.parse().ok().filter(|g| *g > 0)?, secret })
            })
            .collect()
    }
}

/// All sub-keys derived from one recovery phrase. Public keys are
/// returned hex-encoded for transport across FFI; secrets stay in this
/// struct and never cross the FFI boundary directly.
#[derive(Clone)]
pub struct DerivedIdentity {
    pub ed25519_secret: [u8; 32],
    pub ed25519_public: [u8; 32],
    pub x25519_secret: [u8; 32],
    pub x25519_public: [u8; 32],
    pub backup_key: [u8; 32],
    /// T1.1 — SQLCipher key for local SQLite databases. Derived from
    /// the same phrase so re-installing the app with the same phrase
    /// can decrypt previously-encrypted databases. Format: passed to
    /// `PRAGMA key = "x'<hex>'"` as 64-char hex.
    pub storage_key: [u8; 32],
    /// ADR-023 — root for the weekly HPKE delivery keys (sealed sender).
    pub delivery_root: [u8; 32],
    /// Tech-debt 2.2 — root of the sealed-sender access keys.
    pub access_root: [u8; 32],
}

/// Debug shows only the public keys: a stray `{:?}` in a log must never print a secret.
impl std::fmt::Debug for DerivedIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DerivedIdentity")
            .field("ed25519_public", &hex::encode(self.ed25519_public))
            .field("x25519_public", &hex::encode(self.x25519_public))
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod debug_redaction_tests {
    #[test]
    fn debug_hides_secrets() {
        let mut id = super::DerivedIdentity {
            ed25519_secret: [0xAB; 32], ed25519_public: [1; 32], x25519_secret: [0xAB; 32],
            x25519_public: [2; 32], backup_key: [0xAB; 32], storage_key: [0xAB; 32],
            delivery_root: [0xAB; 32], access_root: [0xAB; 32],
        };
        let s = format!("{id:?}");
        assert!(!s.contains("abab") && !s.contains("171"), "{s}");
        id.ed25519_public = [3; 32];
        assert!(format!("{id:?}").contains("0303"));
    }
}

/// ADR-021 — the "device key": the 64-byte BIP-39 seed, tagged. It is
/// what the phone keeps in the iOS Keychain so the app can open its
/// database and reconnect after a restart without the phrase. Spec §6.8
/// forbids storing the phrase itself; the seed is the phrase run
/// through PBKDF2-HMAC-SHA512 (2048 rounds) — one-way, so the phrase
/// can't be read back from it — and every key below is derived from it.
pub const DEVICE_KEY_PREFIX: &str = "sinhron-device-key:v1:";

/// Turn a recovery phrase into the device key (see [`DEVICE_KEY_PREFIX`]).
pub fn device_key_from_phrase(phrase: &str) -> Result<String, KeyError> {
    let seed = phrase_to_seed_hex_internal(phrase)?;
    Ok(format!("{DEVICE_KEY_PREFIX}{}", hex::encode(seed)))
}

/// The 64-byte root seed behind a secret: either a BIP-39 phrase or a
/// device key. Everything that used to take "the phrase" accepts both.
fn root_seed(secret: &str) -> Result<[u8; 64], KeyError> {
    match secret.strip_prefix(DEVICE_KEY_PREFIX) {
        Some(hex_seed) => {
            let bytes = hex::decode(hex_seed.trim()).map_err(|e| KeyError::InvalidKey(format!("device key: {e}")))?;
            bytes
                .try_into()
                .map_err(|_| KeyError::InvalidKey("device key must be 64 bytes".to_string()))
        }
        None => phrase_to_seed_hex_internal(secret),
    }
}

/// Derive the full identity from a BIP-39 recovery phrase or a device
/// key (ADR-021). Returns Err if it doesn't parse / fails the checksum.
pub fn derive_identity(secret: &str) -> Result<DerivedIdentity, KeyError> {
    let seed = root_seed(secret)?;
    let hk = Hkdf::<Sha256>::new(None, &seed);

    let mut ed_seed = [0u8; 32];
    hk.expand(HKDF_INFO_ED25519, &mut ed_seed)
        .expect("32 bytes is well below HKDF expand limit");
    let ed_signing = SigningKey::from_bytes(&ed_seed);
    let ed_verifying = ed_signing.verifying_key();

    let mut x_seed = [0u8; 32];
    hk.expand(HKDF_INFO_X25519, &mut x_seed)
        .expect("32 bytes is well below HKDF expand limit");
    let x_secret = X25519Secret::from(x_seed);
    let x_public = X25519Public::from(&x_secret);

    let mut backup_key = [0u8; 32];
    hk.expand(HKDF_INFO_BACKUP, &mut backup_key)
        .expect("32 bytes is well below HKDF expand limit");

    let mut storage_key = [0u8; 32];
    hk.expand(HKDF_INFO_STORAGE, &mut storage_key)
        .expect("32 bytes is well below HKDF expand limit");

    let mut delivery_root = [0u8; 32];
    hk.expand(HKDF_INFO_DELIVERY, &mut delivery_root)
        .expect("32 bytes is well below HKDF expand limit");

    let mut access_root = [0u8; 32];
    hk.expand(HKDF_INFO_ACCESS, &mut access_root)
        .expect("32 bytes is well below HKDF expand limit");

    Ok(DerivedIdentity {
        ed25519_secret: ed_signing.to_bytes(),
        ed25519_public: ed_verifying.to_bytes(),
        x25519_secret: x_seed,
        x25519_public: x_public.to_bytes(),
        backup_key,
        storage_key,
        delivery_root,
        access_root,
    })
}

// ─────────────────────────────────────────────────────────────────────
// ADR-027 — a linked device's account material (no identity key)
// ─────────────────────────────────────────────────────────────────────

/// What a device paired by QR keeps instead of the account secret: the
/// public identity, its device certificate (signed by the identity key on
/// the device that added it) and the roots it needs to *receive* — never
/// the identity key itself.
pub const LINKED_PREFIX: &str = "sinhron-linked:v1:";
const LINKED_CERT_LEN: usize = 4 + 32 + 32 + 64;
const LINKED_LEN: usize = 32 + 32 + LINKED_CERT_LEN + 32 + 32;

#[derive(Clone, PartialEq, Eq)]
pub struct LinkedBundle {
    pub identity_public: [u8; 32],
    pub x25519_public: [u8; 32],
    pub certificate: Vec<u8>,
    pub delivery_root: [u8; 32],
    pub access_root: [u8; 32],
    /// ADR-073 — [`cloud_backup_key`], so this device can back up and
    /// restore the chats; `None` in bundles made before it (they are 32
    /// bytes shorter and still decode).
    pub cloud_key: Option<[u8; 32]>,
}

impl std::fmt::Debug for LinkedBundle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LinkedBundle").field("identity_public", &hex::encode(self.identity_public)).finish_non_exhaustive()
    }
}

impl LinkedBundle {
    /// `sinhron-linked:v1:<hex>` — the form kept in the Keychain.
    pub fn encode(&self) -> String {
        let mut b = self.base_bytes();
        if let Some(k) = &self.cloud_key {
            b.extend_from_slice(k);
        }
        format!("{LINKED_PREFIX}{}", hex::encode(b))
    }

    fn base_bytes(&self) -> Vec<u8> {
        let mut b = Vec::with_capacity(LINKED_LEN + 32);
        b.extend_from_slice(&self.identity_public);
        b.extend_from_slice(&self.x25519_public);
        b.extend_from_slice(&self.certificate);
        b.extend_from_slice(&self.delivery_root);
        b.extend_from_slice(&self.access_root);
        b
    }

    pub fn decode(secret: &str) -> Result<Self, KeyError> {
        let h = secret.trim().strip_prefix(LINKED_PREFIX).ok_or_else(|| KeyError::InvalidKey("not a linked-device key".into()))?;
        let b = hex::decode(h).map_err(|e| KeyError::InvalidKey(format!("linked key: {e}")))?;
        if b.len() != LINKED_LEN && b.len() != LINKED_LEN + 32 {
            return Err(KeyError::InvalidKey("linked key length".into()));
        }
        let take = |from: usize| -> [u8; 32] { b[from..from + 32].try_into().expect("len checked") };
        let c = 64;
        Ok(Self {
            identity_public: take(0),
            x25519_public: take(32),
            certificate: b[c..c + LINKED_CERT_LEN].to_vec(),
            delivery_root: take(c + LINKED_CERT_LEN),
            access_root: take(c + LINKED_CERT_LEN + 32),
            cloud_key: (b.len() == LINKED_LEN + 32).then(|| take(LINKED_LEN)),
        })
    }

    /// SQLCipher key for this device's local DB (the bundle is secret).
    /// Over the bundle without [`Self::cloud_key`]: adding that key later
    /// (ADR-073) leaves the database key as it was.
    pub fn storage_key(&self) -> [u8; 32] {
        let mut h = Sha256::new();
        h.update(b"sinhron-linked-storage/v1");
        h.update(format!("{LINKED_PREFIX}{}", hex::encode(self.base_bytes())).as_bytes());
        h.finalize().into()
    }
}

/// What every account secret gives — a phrase, a device key (ADR-021) or a
/// linked-device bundle (ADR-027). `identity_secret` is `None` for the last.
pub struct AccountView {
    pub ed25519_public: [u8; 32],
    pub x25519_public: [u8; 32],
    pub storage_key: [u8; 32],
    pub delivery_root: [u8; 32],
    pub access_root: [u8; 32],
    pub identity_secret: Option<[u8; 32]>,
    /// ADR-073 — [`cloud_backup_key`]; `None` on a linked device whose
    /// bundle predates it.
    pub cloud_key: Option<[u8; 32]>,
}

pub fn account_view(secret: &str) -> Result<AccountView, KeyError> {
    if secret.trim().starts_with(LINKED_PREFIX) {
        let b = LinkedBundle::decode(secret)?;
        return Ok(AccountView {
            ed25519_public: b.identity_public,
            x25519_public: b.x25519_public,
            storage_key: b.storage_key(),
            delivery_root: b.delivery_root,
            access_root: b.access_root,
            identity_secret: None,
            cloud_key: b.cloud_key,
        });
    }
    let id = derive_identity(secret)?;
    Ok(AccountView {
        ed25519_public: id.ed25519_public,
        x25519_public: id.x25519_public,
        storage_key: id.storage_key,
        delivery_root: id.delivery_root,
        access_root: id.access_root,
        identity_secret: Some(id.ed25519_secret),
        cloud_key: Some(cloud_backup_key(&id.backup_key)),
    })
}

/// [`fingerprint_hex`] from the two public keys alone.
pub fn fingerprint_of(ed25519_public: &[u8; 32], x25519_public: &[u8; 32]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(ed25519_public);
    hasher.update(x25519_public);
    let digest = hasher.finalize();
    let hex = hex::encode(&digest[..6]);
    format!("{} {} {}", &hex[0..4], &hex[4..8], &hex[8..12])
}

/// Render the public identity as a 12-character hex fingerprint formatted
/// in 3 groups of 4 (e.g. "9a3e 4d12 8b71"), matching the design in
/// contact-info.jsx and our safety_number/contact_info widgets.
///
/// Algorithm:
///   1. Hash `ed25519_public || x25519_public` (64 bytes) with SHA-256
///   2. Take the first 6 bytes (12 hex chars)
///   3. Format as 3 groups of 4 separated by spaces
pub fn fingerprint_hex(id: &DerivedIdentity) -> String {
    let mut hasher = Sha256::new();
    hasher.update(id.ed25519_public);
    hasher.update(id.x25519_public);
    let digest = hasher.finalize();
    let head = &digest[..6];
    let hex = hex::encode(head);
    // hex is 12 chars: "9a3e4d128b71" → split into "9a3e 4d12 8b71"
    format!("{} {} {}", &hex[0..4], &hex[4..8], &hex[8..12])
}

/// Sign [message] with the Ed25519 secret derived from [phrase].
/// Returns the 64-byte signature. The signature can be verified with
/// [verify_signature] given the matching [DerivedIdentity::ed25519_public].
pub fn sign_with_phrase(phrase: &str, message: &[u8]) -> Result<Vec<u8>, KeyError> {
    let id = derive_identity(phrase)?;
    let signing = SigningKey::from_bytes(&id.ed25519_secret);
    let sig: Signature = signing.sign(message);
    Ok(sig.to_bytes().to_vec())
}

/// Verify an Ed25519 [signature] over [message] given the signer's
/// [public_key]. Returns Err on key/signature parse failure, Ok(true)
/// on valid signature, Ok(false) on invalid.
pub fn verify_signature(
    public_key: &[u8; 32],
    message: &[u8],
    signature: &[u8],
) -> Result<bool, KeyError> {
    let vk = VerifyingKey::from_bytes(public_key)
        .map_err(|e| KeyError::InvalidKey(e.to_string()))?;
    let sig = Signature::from_slice(signature)
        .map_err(|e| KeyError::InvalidSignature(e.to_string()))?;
    Ok(vk.verify_strict(message, &sig).is_ok())
}

#[cfg(test)]
mod tests {
    /// FUZZ-ENV-1 — a small-order ("weak") key signs nothing.
    #[test]
    fn a_weak_key_signs_nothing() {
        let mut one = [0u8; 32];
        one[0] = 1;
        for key in [[0u8; 32], one] {
            let mut sig = [0u8; 64];
            sig[..32].copy_from_slice(&key);
            for i in 0..64u8 {
                assert_eq!(super::verify_signature(&key, &[i], &sig).ok(), Some(false));
            }
        }
    }

    /// The stricter check refuses only weak keys: every signature the app
    /// itself made (this release or 0.11.2 — the signing never changed) passes.
    #[test]
    fn genuine_signatures_still_pass_the_strict_check() {
        use ed25519_dalek::{Signer, SigningKey};
        for i in 0..=255u8 {
            let sk = SigningKey::from_bytes(&[i; 32]);
            let msg = [i; 40];
            let sig = sk.sign(&msg).to_bytes();
            assert_eq!(super::verify_signature(sk.verifying_key().as_bytes(), &msg, &sig).ok(), Some(true));
            assert_eq!(super::verify_signature(sk.verifying_key().as_bytes(), &msg[1..], &sig).ok(), Some(false));
        }
    }

    const PHRASE_A: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn device_key_derives_the_same_identity_as_the_phrase() {
        let dk = device_key_from_phrase(PHRASE_A).expect("device key");
        assert!(dk.starts_with(DEVICE_KEY_PREFIX));
        assert_eq!(dk.len(), DEVICE_KEY_PREFIX.len() + 128);
        let a = derive_identity(PHRASE_A).unwrap();
        let b = derive_identity(&dk).unwrap();
        assert_eq!(a.ed25519_public, b.ed25519_public);
        assert_eq!(a.storage_key, b.storage_key);
        assert_eq!(a.backup_key, b.backup_key);
        // The phrase is not in it.
        assert!(!dk.contains("abandon"));
    }

    /// ADR-073 — a bundle with the cloud key decodes back to it; one from
    /// before (32 bytes shorter) still decodes, and adding the key keeps the
    /// database key the same.
    #[test]
    fn linked_bundle_carries_the_cloud_key_and_keeps_the_storage_key() {
        let id = derive_identity(PHRASE_A).unwrap();
        let old = LinkedBundle {
            identity_public: id.ed25519_public,
            x25519_public: id.x25519_public,
            certificate: vec![7u8; LINKED_CERT_LEN],
            delivery_root: id.delivery_root,
            access_root: id.access_root,
            cloud_key: None,
        };
        let with = LinkedBundle { cloud_key: Some(cloud_backup_key(&id.backup_key)), ..old.clone() };
        assert_eq!(LinkedBundle::decode(&old.encode()).unwrap(), old);
        assert_eq!(LinkedBundle::decode(&with.encode()).unwrap(), with);
        assert_eq!(old.encode().len() + 64, with.encode().len());
        assert_eq!(old.storage_key(), with.storage_key());
        assert_eq!(account_view(&with.encode()).unwrap().cloud_key, account_view(PHRASE_A).unwrap().cloud_key);
        assert_eq!(account_view(&old.encode()).unwrap().cloud_key, None);
        assert_ne!(cloud_backup_key(&id.backup_key), id.backup_key);
        assert!(LinkedBundle::decode(&format!("{}00", with.encode())).is_err());
    }

    /// ADR-084 — a generation of the roots keeps its form; generation 0 (the
    /// phrase's) and junk never parse; each generation gives other keys.
    #[test]
    fn rotated_roots_round_trip_and_differ_from_the_phrase() {
        let g = RootsGen { gen: 2, secret: [9u8; 32] };
        let list = format!("{},0:{},x,3:zz", g.encode(), hex::encode([1u8; 32]));
        assert!(RootsGen::decode_list(&list) == vec![g]);
        assert!(RootsGen::decode_list("").is_empty());
        let id = derive_identity(PHRASE_A).unwrap();
        assert_ne!(g.delivery_root(), id.delivery_root);
        assert_ne!(g.cloud_key(), cloud_backup_key(&id.backup_key));
        assert_ne!(g.delivery_root(), RootsGen { gen: 3, ..g }.delivery_root());
    }

    #[test]
    fn malformed_device_keys_are_rejected() {
        assert!(derive_identity(&format!("{DEVICE_KEY_PREFIX}zz")).is_err());
        assert!(derive_identity(&format!("{DEVICE_KEY_PREFIX}{}", "ab".repeat(32))).is_err(), "32 bytes is too short");
        assert!(device_key_from_phrase("not a phrase").is_err());
    }

    use super::*;

    const TEST_PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                               abandon abandon abandon abandon abandon abandon \
                               abandon abandon abandon abandon abandon abandon \
                               abandon abandon abandon abandon abandon art";

    #[test]
    fn derive_identity_deterministic() {
        let id1 = derive_identity(TEST_PHRASE).unwrap();
        let id2 = derive_identity(TEST_PHRASE).unwrap();
        assert_eq!(id1.ed25519_public, id2.ed25519_public);
        assert_eq!(id1.x25519_public, id2.x25519_public);
        assert_eq!(id1.backup_key, id2.backup_key);
    }

    #[test]
    fn sub_keys_are_domain_separated() {
        let id = derive_identity(TEST_PHRASE).unwrap();
        // Four independent 32-byte secrets — none should collide.
        // T1.1 added `storage_key`; all six pairwise checks below.
        assert_ne!(id.ed25519_secret, id.x25519_secret);
        assert_ne!(id.ed25519_secret, id.backup_key);
        assert_ne!(id.ed25519_secret, id.storage_key);
        assert_ne!(id.x25519_secret, id.backup_key);
        assert_ne!(id.x25519_secret, id.storage_key);
        assert_ne!(id.backup_key, id.storage_key);
    }

    #[test]
    fn fingerprint_format() {
        let id = derive_identity(TEST_PHRASE).unwrap();
        let fp = fingerprint_hex(&id);
        // "xxxx xxxx xxxx" = 14 chars
        assert_eq!(fp.len(), 14);
        assert_eq!(fp.matches(' ').count(), 2);
        for group in fp.split(' ') {
            assert_eq!(group.len(), 4);
            assert!(group.chars().all(|c| c.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn sign_verify_round_trip() {
        let id = derive_identity(TEST_PHRASE).unwrap();
        let msg = b"hello sinhron";
        let sig = sign_with_phrase(TEST_PHRASE, msg).unwrap();
        assert_eq!(sig.len(), 64);
        assert!(verify_signature(&id.ed25519_public, msg, &sig).unwrap());
    }

    #[test]
    fn verify_rejects_tampered_message() {
        let id = derive_identity(TEST_PHRASE).unwrap();
        let sig = sign_with_phrase(TEST_PHRASE, b"hello sinhron").unwrap();
        assert!(!verify_signature(&id.ed25519_public, b"hello attacker", &sig).unwrap());
    }
}

/// Safety number for a pair of identity keys — UI backlog §6 item 49.
/// 60 digits (12 groups of 5) that both sides compute identically: each
/// key gives 30 digits from SHA-512 over a versioned domain tag + key,
/// and the two halves are ordered by key so neither side's order matters.
/// Compare aloud / by QR; any key change changes the number.
pub fn safety_number(a: &[u8], b: &[u8]) -> String {
    use sha2::Sha512;
    fn half(key: &[u8]) -> String {
        let mut h = Sha512::new();
        h.update(b"sinhron-safety-number-v1");
        h.update(key);
        let d = h.finalize();
        (0..6)
            .map(|i| {
                let chunk = &d[i * 5..i * 5 + 5];
                let n = chunk.iter().fold(0u64, |acc, &x| (acc << 8) | x as u64) % 100_000;
                format!("{n:05}")
            })
            .collect::<Vec<_>>()
            .join(" ")
    }
    let (first, second) = if a <= b { (a, b) } else { (b, a) };
    format!("{} {}", half(first), half(second))
}

#[cfg(test)]
mod safety_tests {
    use super::safety_number;

    #[test]
    fn same_for_both_sides_and_changes_with_any_key() {
        let a = [1u8; 32];
        let b = [2u8; 32];
        let n = safety_number(&a, &b);
        assert_eq!(n, safety_number(&b, &a), "order-independent");
        assert_eq!(n.split(' ').count(), 12);
        assert!(n.split(' ').all(|g| g.len() == 5 && g.chars().all(|c| c.is_ascii_digit())));
        let mut c = b;
        c[31] ^= 1;
        assert_ne!(n, safety_number(&a, &c), "a changed key changes the number");
        assert_eq!(n, safety_number(&a, &b), "deterministic");
    }
}
