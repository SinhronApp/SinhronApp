// Notification previews — ADR-056.
//
// The server only sees ciphertext, so a message push used to say just
// "New message". Now the sender adds a small *preview* to each sealed
// delivery that wakes someone: who wrote, in which chat, what kind of
// message and the start of its text — sealed with HPKE to the recipient's
// delivery key (the one the envelope itself goes to, ADR-023), so only the
// recipient's phone opens it. The server copies it into the APNs payload
// unread; Apple sees the same opaque bytes. On the iPhone the Notification
// Service Extension opens it with CryptoKit (`HPKE.Recipient`, iOS 17+) and
// rewrites the notification — no MLS, no database in the extension.
//
// HPKE suite: X25519 / HKDF-SHA256 / ChaCha20-Poly1305 (the delivery key's
// KEM; CryptoKit has no AES-128-GCM suite), info `sinhron-push-preview-v1`,
// aad = the recipient key id (16 bytes). Wire:
//   0x01 | enc (32) | ciphertext (PLAIN_LEN + 16)
// Plaintext (always PLAIN_LEN bytes, zero-padded — every preview has the
// same size, so its length says nothing about the text):
//   body = 0x01 | u64 BE sent_at | u8 len kind | kind
//        | u16 BE len group_id | group_id | u16 BE len text | text
//        | u16 BE len credential | credential
//   body | Ed25519 signature (64) | zeros
// The signature covers `sinhron-push-preview-v1:` | recipient key id | body,
// by the sender's device key; `credential` ties it to the person: the
// identity key itself (32 bytes, a first device) or the device certificate
// (132 bytes, ADR-025/027). Without the signature anyone who can deliver to
// me could put "Mum: call me" on my lock screen; with the key id inside, a
// preview can't be re-sealed to another member.

use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use openmls_traits::crypto::OpenMlsCrypto;
use openmls_traits::types::{HpkeAeadType, HpkeCiphertext, HpkeConfig, HpkeKdfType, HpkeKemType};

pub const PREVIEW_HPKE: HpkeConfig =
    HpkeConfig(HpkeKemType::DhKem25519, HpkeKdfType::HkdfSha256, HpkeAeadType::ChaCha20Poly1305);
const INFO: &[u8] = b"sinhron-push-preview-v1";
const SIG_DOMAIN: &[u8] = b"sinhron-push-preview-v1:";
const VERSION: u8 = 1;
/// Plaintext size of every preview.
pub const PLAIN_LEN: usize = 640;
/// Text kept (bytes, cut on a character boundary).
pub const MAX_TEXT: usize = 320;
/// Sealed size: version + enc + plaintext + tag.
pub const SEALED_LEN: usize = 1 + 32 + PLAIN_LEN + 16;

/// What a preview says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Preview {
    pub sent_at: u64,
    pub group_id: Vec<u8>,
    /// "text", "photo", "voice", "video", "document"…
    pub kind: String,
    pub text: String,
    /// The sender's identity key (verified).
    pub sender: [u8; 32],
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PreviewError {
    #[error("preview crypto: {0}")]
    Crypto(String),
    #[error("preview format")]
    Format,
    #[error("preview signature")]
    Signature,
}

/// `text` cut to at most `max` bytes on a character boundary.
pub fn clip(text: &str, max: usize) -> &str {
    if text.len() <= max {
        return text;
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

fn body(sent_at: u64, kind: &str, group_id: &[u8], text: &str, credential: &[u8]) -> Result<Vec<u8>, PreviewError> {
    if kind.is_empty() || kind.len() > 32 || group_id.len() > 255 {
        return Err(PreviewError::Format);
    }
    let text = clip(text, MAX_TEXT);
    let mut b = Vec::with_capacity(PLAIN_LEN);
    b.push(VERSION);
    b.extend_from_slice(&sent_at.to_be_bytes());
    b.push(kind.len() as u8);
    b.extend_from_slice(kind.as_bytes());
    for part in [group_id, text.as_bytes(), credential] {
        b.extend_from_slice(&(part.len() as u16).to_be_bytes());
        b.extend_from_slice(part);
    }
    Ok(b)
}

fn signed_message(key_id: &[u8; 16], body: &[u8]) -> Vec<u8> {
    let mut m = SIG_DOMAIN.to_vec();
    m.extend_from_slice(key_id);
    m.extend_from_slice(body);
    m
}

/// Seal a preview for one recipient delivery key. `device_seed` signs;
/// `certificate` is this device's certificate on a linked device (None on
/// a first device, whose key is the identity key).
#[allow(clippy::too_many_arguments)]
pub fn seal(
    crypto: &impl OpenMlsCrypto,
    recipient_public: &[u8],
    device_seed: &[u8; 32],
    certificate: Option<&[u8]>,
    sent_at: u64,
    group_id: &[u8],
    kind: &str,
    text: &str,
) -> Result<Vec<u8>, PreviewError> {
    let signer = SigningKey::from_bytes(device_seed);
    let own;
    let credential = match certificate {
        Some(c) => c,
        None => {
            own = signer.verifying_key().to_bytes();
            &own[..]
        }
    };
    let key_id = crate::sealed::key_id_of(recipient_public);
    let mut plain = body(sent_at, kind, group_id, text, credential)?;
    let sig = signer.sign(&signed_message(&key_id, &plain)).to_bytes();
    plain.extend_from_slice(&sig);
    if plain.len() > PLAIN_LEN {
        return Err(PreviewError::Format);
    }
    plain.resize(PLAIN_LEN, 0);
    let ct = crypto
        .hpke_seal(PREVIEW_HPKE, recipient_public, INFO, &key_id, &plain)
        .map_err(|e| PreviewError::Crypto(format!("{e:?}")))?;
    let mut out = Vec::with_capacity(SEALED_LEN);
    out.push(VERSION);
    out.extend_from_slice(ct.kem_output.as_slice());
    out.extend_from_slice(ct.ciphertext.as_slice());
    Ok(out)
}

/// Read `u16 BE len | bytes` at `*at`.
fn take<'a>(b: &'a [u8], at: &mut usize) -> Result<&'a [u8], PreviewError> {
    let n = u16::from_be_bytes(b.get(*at..*at + 2).ok_or(PreviewError::Format)?.try_into().unwrap()) as usize;
    let v = b.get(*at + 2..*at + 2 + n).ok_or(PreviewError::Format)?;
    *at += 2 + n;
    Ok(v)
}

/// Open and verify (the same steps as `NotificationService.swift`; the
/// app itself never needs this — tests and the Swift test vector).
pub fn open(
    crypto: &impl OpenMlsCrypto,
    recipient_secret: &[u8],
    recipient_public: &[u8],
    sealed: &[u8],
) -> Result<Preview, PreviewError> {
    if sealed.len() != SEALED_LEN || sealed[0] != VERSION {
        return Err(PreviewError::Format);
    }
    let key_id = crate::sealed::key_id_of(recipient_public);
    let ct = HpkeCiphertext { kem_output: sealed[1..33].to_vec().into(), ciphertext: sealed[33..].to_vec().into() };
    let plain = crypto
        .hpke_open(PREVIEW_HPKE, &ct, recipient_secret, INFO, &key_id)
        .map_err(|e| PreviewError::Crypto(format!("{e:?}")))?;
    if plain.first() != Some(&VERSION) || plain.len() < 10 {
        return Err(PreviewError::Format);
    }
    let sent_at = u64::from_be_bytes(plain[1..9].try_into().unwrap());
    let kn = plain[9] as usize;
    let kind = std::str::from_utf8(plain.get(10..10 + kn).ok_or(PreviewError::Format)?).map_err(|_| PreviewError::Format)?;
    let mut at = 10 + kn;
    let group_id = take(&plain, &mut at)?.to_vec();
    let text = std::str::from_utf8(take(&plain, &mut at)?).map_err(|_| PreviewError::Format)?.to_string();
    let credential = take(&plain, &mut at)?;
    let body_end = at;
    let sig = ed25519_dalek::Signature::from_slice(plain.get(at..at + 64).ok_or(PreviewError::Format)?)
        .map_err(|_| PreviewError::Format)?;
    let (sender, signer) = match credential.len() {
        32 => {
            let k: [u8; 32] = credential.try_into().unwrap();
            (k, k)
        }
        _ => crate::identity::device_of_certificate(credential).ok_or(PreviewError::Signature)?,
    };
    VerifyingKey::from_bytes(&signer)
        .map_err(|_| PreviewError::Signature)?
        .verify_strict(&signed_message(&key_id, &plain[..body_end]), &sig)
        .map_err(|_| PreviewError::Signature)?;
    Ok(Preview { sent_at, group_id, kind: kind.to_string(), text, sender })
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::RustCrypto;

    fn bob(c: &RustCrypto) -> (Vec<u8>, Vec<u8>) {
        let k = crate::sealed::delivery_key(c, &[1u8; 32], 5).unwrap();
        (k.public.clone(), k.secret_bytes().to_vec())
    }

    #[test]
    fn a_preview_opens_for_its_recipient_with_the_senders_identity() {
        let c = RustCrypto::default();
        let (pk, sk) = bob(&c);
        let alice = [9u8; 32];
        let sealed = seal(&c, &pk, &alice, None, 1_760_000_000, b"group-1", "text", "привет, Боб").unwrap();
        assert_eq!(sealed.len(), SEALED_LEN, "every preview is the same size");
        let p = open(&c, &sk, &pk, &sealed).unwrap();
        assert_eq!(p.text, "привет, Боб");
        assert_eq!(p.kind, "text");
        assert_eq!(p.group_id, b"group-1");
        assert_eq!(p.sent_at, 1_760_000_000);
        assert_eq!(p.sender, SigningKey::from_bytes(&alice).verifying_key().to_bytes());
        let other = seal(&c, &pk, &alice, None, 1, b"g", "photo", "").unwrap();
        assert_eq!(other.len(), sealed.len());
        assert!(!sealed.windows(7).any(|w| w == b"group-1"), "nothing readable on the wire");
    }

    #[test]
    fn a_linked_device_signs_with_its_certificate() {
        let c = RustCrypto::default();
        let (pk, sk) = bob(&c);
        let identity = [3u8; 32];
        let device = [4u8; 32];
        let device_pub = SigningKey::from_bytes(&device).verifying_key().to_bytes();
        let cert = crate::identity::device_certificate(&identity, &device_pub);
        let sealed = seal(&c, &pk, &device, Some(&cert), 7, b"g", "voice", "").unwrap();
        let p = open(&c, &sk, &pk, &sealed).unwrap();
        assert_eq!(p.sender, SigningKey::from_bytes(&identity).verifying_key().to_bytes());
        // Someone else's device key with that certificate doesn't verify.
        let forged = seal(&c, &pk, &[5u8; 32], Some(&cert), 7, b"g", "voice", "").unwrap();
        assert_eq!(open(&c, &sk, &pk, &forged), Err(PreviewError::Signature));
    }

    #[test]
    fn long_text_is_cut_on_a_character_and_others_cant_open_it() {
        let c = RustCrypto::default();
        let (pk, sk) = bob(&c);
        let long = "щ".repeat(400);
        let sealed = seal(&c, &pk, &[9u8; 32], None, 1, &[7u8; 32], "text", &long).unwrap();
        let p = open(&c, &sk, &pk, &sealed).unwrap();
        assert_eq!(p.text.len(), MAX_TEXT);
        assert!(long.starts_with(&p.text));
        let eve = crate::sealed::delivery_key(&c, &[2u8; 32], 5).unwrap();
        assert!(matches!(open(&c, eve.secret_bytes(), &eve.public, &sealed), Err(PreviewError::Crypto(_))));
        let mut bad = sealed.clone();
        bad[100] ^= 1;
        assert!(open(&c, &sk, &pk, &bad).is_err());
        assert_eq!(clip("aé", 2), "a");
    }

    /// Prints a fixed vector for `ios/NotificationService` tests
    /// (`cargo test -p sinhron_sync push_preview_vector -- --nocapture`).
    #[test]
    fn push_preview_vector() {
        let c = RustCrypto::default();
        let (pk, sk) = bob(&c);
        let sealed = seal(&c, &pk, &[9u8; 32], None, 1_760_000_000, &[0xab; 16], "text", "Привет!").unwrap();
        println!("secret={}\nsealed={}", hex::encode(&sk), hex::encode(&sealed));
        assert!(open(&c, &sk, &pk, &sealed).is_ok());
    }
}
