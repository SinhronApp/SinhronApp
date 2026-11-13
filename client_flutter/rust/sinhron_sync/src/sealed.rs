// Sealed sender — spec §6.5, ADR-023.
//
// An MLS application message still tells the server which group it is
// for (Submit.group_id) and is stored next to that group. Sealed
// delivery hides the group and the content from the server: the sender
// wraps `{group_id, mls_message}` once per recipient device with HPKE
// (RFC 9180, X25519 / HKDF-SHA256 / AES-128-GCM) under that device's
// short-lived *delivery key*. The server sees only "an envelope of this
// size for delivery key K" — not the group, not the sender's leaf, not
// the payload. (It still knows which authenticated connection submitted
// it; hiding that too needs unauthenticated submission — tech-debt.)
//
// Delivery keys rotate weekly and are derived, not stored: a 32-byte
// `delivery_root` (from the account secret, HKDF info `sinhron-delivery/v1`
// — the same on all of a person's devices, ADR-025)
// → per-week IKM → `derive_hpke_keypair`. A device publishes this and
// next week's public keys; it can open envelopes for the current week
// and the two before it (late delivery, clock skew).
//
// Envelope wire format (version 1):
//   0x01 | u16 BE len(enc) | enc (HPKE encapsulated key) | ciphertext
// HPKE info = "sinhron-sealed-v1", aad = key_id (16 bytes), so an
// envelope can't be replayed under another key. Plaintext:
//   u16 BE len(group_id) | group_id | mls_message
//
// Spec §6.5 rule (after IACR 2026/484 on Signal): decapsulation, MLS
// decryption and sender identity all happen in ONE Rust function —
// `SyncClient::open_sealed` — with no serialized intermediate state
// crossing a boundary in between.

use openmls_traits::crypto::OpenMlsCrypto;
use openmls_traits::types::{HpkeAeadType, HpkeCiphertext, HpkeConfig, HpkeKdfType, HpkeKemType};
use sha2::{Digest, Sha256};

pub const HPKE: HpkeConfig = HpkeConfig(HpkeKemType::DhKem25519, HpkeKdfType::HkdfSha256, HpkeAeadType::AesGcm128);
const INFO: &[u8] = b"sinhron-sealed-v1";
const ENVELOPE_V1: u8 = 1;
pub const WEEK_SECS: u64 = 7 * 24 * 3600;
/// Weeks back a device still accepts (current week + this many before).
pub const WEEKS_ACCEPTED_BACK: u32 = 2;
/// REL-01 — weeks back an envelope still OPENS: the server keeps one for a
/// year, and a phone or tablet that was off for three weeks used to lose
/// everything sealed to it in the first two. The keys come from the root, so
/// nothing is weaker; senders still seal only to the current weeks.
pub const WEEKS_OPENED_BACK: u32 = 54;

pub fn week_of(unix_secs: u64) -> u32 {
    (unix_secs / WEEK_SECS) as u32
}

/// A device's delivery key for one week.
#[derive(Clone)]
pub struct DeliveryKey {
    pub week: u32,
    /// First 16 bytes of SHA-256(public) — what the server indexes.
    pub key_id: [u8; 16],
    pub public: Vec<u8>,
    secret: Vec<u8>,
}

impl std::fmt::Debug for DeliveryKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DeliveryKey")
            .field("week", &self.week)
            .field("key_id", &hex::encode(self.key_id))
            .finish_non_exhaustive()
    }
}

pub fn key_id_of(public: &[u8]) -> [u8; 16] {
    let digest = Sha256::digest(public);
    let mut id = [0u8; 16];
    id.copy_from_slice(&digest[..16]);
    id
}

/// Deterministic delivery key for `week`, from the device's `delivery_root`.
pub fn delivery_key(crypto: &impl OpenMlsCrypto, root: &[u8; 32], week: u32) -> Result<DeliveryKey, SealedError> {
    let mut h = Sha256::new();
    h.update(b"sinhron-delivery-week/v1");
    h.update(root);
    h.update(week.to_be_bytes());
    let ikm = h.finalize();
    let kp = crypto
        .derive_hpke_keypair(HPKE, &ikm)
        .map_err(|e| SealedError::Crypto(format!("derive: {e:?}")))?;
    let public = kp.public;
    Ok(DeliveryKey {
        week,
        key_id: key_id_of(&public),
        public,
        secret: (*kp.private).to_vec(),
    })
}

/// ADR-082 (audit mls-identity:4) — what a published delivery key's owner
/// signs: domain || identity || week_be4 || public. Without it the server
/// could hand a sender its own key and read the notification preview.
fn delivery_signed_message(identity: &[u8; 32], week: u32, public: &[u8]) -> Vec<u8> {
    let mut m = b"sinhron-delivery-key-v1:".to_vec();
    m.extend_from_slice(identity);
    m.extend_from_slice(&week.to_be_bytes());
    m.extend_from_slice(public);
    m
}

/// Sign `public` as `identity`'s key for `week` — with the identity key,
/// or (linked device) with the device key, sent with its certificate.
pub fn sign_delivery_key(signer_seed: &[u8; 32], identity: &[u8; 32], week: u32, public: &[u8]) -> [u8; 64] {
    use ed25519_dalek::Signer;
    ed25519_dalek::SigningKey::from_bytes(signer_seed).sign(&delivery_signed_message(identity, week, public)).to_bytes()
}

/// True if `identity` itself signed this key, or a device whose
/// certificate (`cert`) names `identity`.
pub fn delivery_key_signed(identity: &[u8; 32], week: u32, public: &[u8], sig: &[u8], cert: Option<&[u8]>) -> bool {
    let signer = match cert {
        None => *identity,
        Some(c) => match crate::identity::device_of_certificate(c) {
            Some((id, device)) if id == *identity => device,
            _ => return false,
        },
    };
    let (Ok(vk), Ok(sig)) = (ed25519_dalek::VerifyingKey::from_bytes(&signer), ed25519_dalek::Signature::from_slice(sig)) else {
        return false;
    };
    vk.verify_strict(&delivery_signed_message(identity, week, public), &sig).is_ok()
}

impl DeliveryKey {
    /// The private key — only for the iPhone's notification extension
    /// (ADR-056: it opens push previews sealed to this key).
    pub fn secret_bytes(&self) -> &[u8] {
        &self.secret
    }
}

/// Wrap `{group_id, mls}` for one recipient delivery key.
pub fn seal(
    crypto: &impl OpenMlsCrypto,
    recipient_public: &[u8],
    group_id: &[u8],
    mls: &[u8],
) -> Result<Vec<u8>, SealedError> {
    if group_id.len() > u16::MAX as usize {
        return Err(SealedError::Format("group id too long".into()));
    }
    let key_id = key_id_of(recipient_public);
    let mut plain = Vec::with_capacity(2 + group_id.len() + mls.len());
    plain.extend_from_slice(&(group_id.len() as u16).to_be_bytes());
    plain.extend_from_slice(group_id);
    plain.extend_from_slice(mls);
    let ct = crypto
        .hpke_seal(HPKE, recipient_public, INFO, &key_id, &plain)
        .map_err(|e| SealedError::Crypto(format!("seal: {e:?}")))?;
    let enc = ct.kem_output.as_slice();
    let mut out = Vec::with_capacity(3 + enc.len() + ct.ciphertext.as_slice().len());
    out.push(ENVELOPE_V1);
    out.extend_from_slice(&(enc.len() as u16).to_be_bytes());
    out.extend_from_slice(enc);
    out.extend_from_slice(ct.ciphertext.as_slice());
    Ok(out)
}

/// Unwrap an envelope with one of our keys → `(group_id, mls)`. Only
/// [`crate::client::SyncClient::open_sealed`] calls this, and it goes
/// straight on to MLS decryption (spec §6.5 single-module rule).
pub(crate) fn open(crypto: &impl OpenMlsCrypto, key: &DeliveryKey, envelope: &[u8]) -> Result<(Vec<u8>, Vec<u8>), SealedError> {
    if envelope.len() < 3 || envelope[0] != ENVELOPE_V1 {
        return Err(SealedError::Format("unknown envelope version".into()));
    }
    let n = u16::from_be_bytes([envelope[1], envelope[2]]) as usize;
    let enc = envelope.get(3..3 + n).ok_or_else(|| SealedError::Format("truncated".into()))?;
    let ct = HpkeCiphertext { kem_output: enc.to_vec().into(), ciphertext: envelope[3 + n..].to_vec().into() };
    let plain = crypto
        .hpke_open(HPKE, &ct, &key.secret, INFO, &key.key_id)
        .map_err(|_| SealedError::NotForUs)?;
    if plain.len() < 2 {
        return Err(SealedError::Format("short plaintext".into()));
    }
    let g = u16::from_be_bytes([plain[0], plain[1]]) as usize;
    let group_id = plain.get(2..2 + g).ok_or_else(|| SealedError::Format("truncated group id".into()))?.to_vec();
    Ok((group_id, plain[2 + g..].to_vec()))
}

#[derive(Debug, thiserror::Error)]
pub enum SealedError {
    #[error("crypto: {0}")]
    Crypto(String),
    #[error("envelope format: {0}")]
    Format(String),
    /// None of our delivery keys opens it (wrong recipient, expired week, tampered).
    #[error("envelope not addressed to this device")]
    NotForUs,
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::RustCrypto;

    #[test]
    fn delivery_keys_are_deterministic_and_rotate_weekly() {
        let c = RustCrypto::default();
        let root = [7u8; 32];
        let a = delivery_key(&c, &root, 100).unwrap();
        let b = delivery_key(&c, &root, 100).unwrap();
        let next = delivery_key(&c, &root, 101).unwrap();
        assert_eq!(a.public, b.public);
        assert_eq!(a.key_id, key_id_of(&a.public));
        assert_ne!(a.public, next.public, "a new key every week");
        assert_ne!(delivery_key(&c, &[8u8; 32], 100).unwrap().public, a.public);
    }

    #[test]
    fn seal_open_round_trip_hides_the_group() {
        let c = RustCrypto::default();
        let bob = delivery_key(&c, &[1u8; 32], 5).unwrap();
        let group = b"family-group-id-0123456789".to_vec();
        let env = seal(&c, &bob.public, &group, b"mls-bytes").unwrap();
        assert!(!env.windows(group.len()).any(|w| w == group.as_slice()), "group id is not visible");
        assert_eq!(open(&c, &bob, &env).unwrap(), (group, b"mls-bytes".to_vec()));
    }

    #[test]
    fn other_keys_and_tampering_fail() {
        let c = RustCrypto::default();
        let bob = delivery_key(&c, &[1u8; 32], 5).unwrap();
        let eve = delivery_key(&c, &[2u8; 32], 5).unwrap();
        let bob_next_week = delivery_key(&c, &[1u8; 32], 6).unwrap();
        let env = seal(&c, &bob.public, b"g", b"m").unwrap();
        assert!(matches!(open(&c, &eve, &env), Err(SealedError::NotForUs)));
        assert!(matches!(open(&c, &bob_next_week, &env), Err(SealedError::NotForUs)));
        let mut bad = env.clone();
        let last = bad.len() - 1;
        bad[last] ^= 1;
        assert!(matches!(open(&c, &bob, &bad), Err(SealedError::NotForUs)));
        assert!(matches!(open(&c, &bob, &[9, 0, 0]), Err(SealedError::Format(_))));
    }
}
