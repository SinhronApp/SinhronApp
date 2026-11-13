// SFrame key derivation — RFC 9605 §5.2.
//
// This module implements the precise key schedule referenced in spec
// §10.3:
//
//   sframe_epoch_secret = MLS-Exporter("SFrame 1.0 Base Key", "", AEAD.Nk)
//   sender_base_key[i]  = HKDF-Expand(sframe_epoch_secret,
//                                     encode_big_endian(i, 4), AEAD.Nk)
//   sframe_secret       = HKDF-Extract("", sender_base_key)
//   sframe_key          = HKDF-Expand(sframe_secret,
//                                     "SFrame 1.0 Secret key " + KID + cipher_suite,
//                                     AEAD.Nk)
//   sframe_salt         = HKDF-Expand(sframe_secret,
//                                     "SFrame 1.0 Secret salt " + KID + cipher_suite,
//                                     AEAD.Nn)
//
// KID layout (Figure 8 RFC 9605):
//   KID = (context << (S+E)) + (sender_index << E) + (epoch mod 2^E)
//
// We pick S=6 (up to 64 active senders — well above any 1:1 or small
// group call) and E=4 (16-entry LiveKit keyring overlap window).
//
// `MLS-Exporter` semantics are RFC 9420 §8.5 — it derives `length` bytes
// from the group's current `exporter_secret` using a label + context.
// The caller (sinhron_sync::SyncClient) feeds us the OUTPUT of that
// exporter call; this crate doesn't talk to openmls directly.

use hkdf::Hkdf;
use sha2::Sha256;

/// AEAD cipher suite identifier. Spec §10 doesn't pin a single cipher;
/// LiveKit defaults to AES-GCM-128 in JS/Swift SDKs. We expose both
/// 128- and 256-bit variants so the platform can pick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CipherSuite {
    /// AES-128-GCM with SHA-256 (RFC 9605 cipher suite 0x0001).
    AesGcm128Sha256,
    /// AES-256-GCM with SHA-256 (RFC 9605 cipher suite 0x0002).
    AesGcm256Sha256,
}

impl CipherSuite {
    /// AEAD key length in bytes (Nk).
    pub const fn key_len(&self) -> usize {
        match self {
            CipherSuite::AesGcm128Sha256 => 16,
            CipherSuite::AesGcm256Sha256 => 32,
        }
    }

    /// AEAD nonce / salt length in bytes (Nn).
    pub const fn nonce_len(&self) -> usize {
        // AES-GCM nonces are 12 bytes for both variants per RFC 5116.
        12
    }

    /// Two-byte SFrame cipher-suite identifier — appended verbatim to
    /// the HKDF info strings. Wire-level constant per RFC 9605 §6.
    pub const fn id_be_bytes(&self) -> [u8; 2] {
        match self {
            CipherSuite::AesGcm128Sha256 => [0x00, 0x01],
            CipherSuite::AesGcm256Sha256 => [0x00, 0x02],
        }
    }
}

/// Packed Key Identifier (KID) per RFC 9605 §6.1 Figure 8.
///
/// Layout:
///   high bits = context (per spec §10.3: 0 for "main call")
///   middle    = sender_index (S bits — we use 6)
///   low       = epoch mod 2^E (we use E=4)
///
/// Encoded as a u64 because the KID can be a variable-length integer
/// per the spec; 64 bits cover any reasonable group size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Kid(pub u64);

impl Kid {
    /// Sender-index width — supports up to 64 active members per call.
    pub const SENDER_BITS: u32 = 6;
    /// Epoch ring width — must match LiveKit's `keyRingSize=16`.
    pub const EPOCH_BITS: u32 = 4;

    /// Compose a KID from (context, sender_index, epoch).
    /// Context is `0` for the main call; reserved for future per-track
    /// derivations (e.g. data-channel might use context=1).
    pub fn compose(context: u32, sender_index: u32, epoch: u64) -> Self {
        let total = (Self::SENDER_BITS + Self::EPOCH_BITS) as u64;
        let context_bits = (context as u64) << total;
        let sender_bits = (sender_index as u64 & ((1 << Self::SENDER_BITS) - 1))
            << Self::EPOCH_BITS;
        let epoch_bits = epoch & ((1u64 << Self::EPOCH_BITS) - 1);
        Kid(context_bits | sender_bits | epoch_bits)
    }

    /// Extract sender_index from a packed KID.
    pub fn sender_index(&self) -> u32 {
        ((self.0 >> Self::EPOCH_BITS) & ((1 << Self::SENDER_BITS) - 1)) as u32
    }

    /// Extract epoch (mod 2^EPOCH_BITS) from a packed KID.
    pub fn epoch(&self) -> u64 {
        self.0 & ((1 << Self::EPOCH_BITS) - 1)
    }

    /// Variable-length encoding per RFC 9605 §6.1 — used inside HKDF
    /// info strings. For values < 2^7 it's a single byte; otherwise
    /// we use the full 8-byte big-endian encoding (the spec permits
    /// either compact or uniform encoding; we pick uniform for
    /// implementation simplicity since this only affects info strings,
    /// not on-wire size).
    pub fn to_info_bytes(&self) -> Vec<u8> {
        self.0.to_be_bytes().to_vec()
    }
}

/// Pair of `key` + `salt` materials handed to LiveKit's KeyProvider
/// for a single (sender_index, epoch) point in the keyring.
///
/// `key.len()` == `CipherSuite::key_len()`; `salt.len()` ==
/// `CipherSuite::nonce_len()`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SframeKeyMaterial {
    pub key: Vec<u8>,
    pub salt: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum SframeError {
    #[error("MLS exporter output too short: need {need} bytes, got {got}")]
    ExporterTooShort { need: usize, got: usize },
    #[error("HKDF expand failure: {0}")]
    Hkdf(String),
}

/// RFC 9605 §5.2 step 1 — `sframe_epoch_secret`.
///
/// **NOTE:** This is a re-export of the MLS-Exporter call's output. We
/// don't perform the MLS exporter call ourselves — that requires
/// `sinhron_sync::SyncClient::group_exporter()` which is async +
/// stateful. Callers do that, then pass the bytes here.
///
/// The function exists for symmetry / future-proofing: if we ever
/// extract MLS exporter into a sync-only path it's here for retry.
pub fn sframe_epoch_secret(
    mls_exporter_output: &[u8],
    cipher: CipherSuite,
) -> Result<Vec<u8>, SframeError> {
    let need = cipher.key_len();
    if mls_exporter_output.len() < need {
        return Err(SframeError::ExporterTooShort {
            need,
            got: mls_exporter_output.len(),
        });
    }
    Ok(mls_exporter_output[..need].to_vec())
}

/// RFC 9605 §5.2 step 2 — `sender_base_key[i]`.
///
/// `HKDF-Expand(sframe_epoch_secret, encode_big_endian(i, 4), AEAD.Nk)`.
///
/// Per RFC 5869, HKDF-Expand strictly requires PRK ≥ HashLen (32 bytes
/// for SHA-256). The MLS exporter output for AES-128 is only 16 bytes,
/// so we apply an empty-salt Extract first — semantically equivalent
/// to a single `HKDF(salt=empty, ikm=epoch_secret, info, L)` call.
/// LiveKit's Go reference implementation does the same.
///
/// `sender_index` is the leaf index inside the MLS group (i.e. the
/// member's position in the ratchet tree). Stable across re-keying as
/// long as membership doesn't change.
pub fn sender_base_key(
    epoch_secret: &[u8],
    sender_index: u32,
    cipher: CipherSuite,
) -> Result<Vec<u8>, SframeError> {
    let info = sender_index.to_be_bytes(); // 4 bytes BE
    // Hkdf::new = Extract(salt, ikm) followed by Expand on demand.
    let hk = Hkdf::<Sha256>::new(None, epoch_secret);
    let mut out = vec![0u8; cipher.key_len()];
    hk.expand(&info, &mut out)
        .map_err(|e| SframeError::Hkdf(format!("expand: {e}")))?;
    Ok(out)
}

/// RFC 9605 §5.2 step 3 — per-KID `sframe_key` + `sframe_salt`.
///
///   sframe_secret = HKDF-Extract("", base_key)
///   sframe_key    = HKDF-Expand(sframe_secret,
///                               "SFrame 1.0 Secret key " || KID || cipher_suite,
///                               AEAD.Nk)
///   sframe_salt   = HKDF-Expand(sframe_secret,
///                               "SFrame 1.0 Secret salt " || KID || cipher_suite,
///                               AEAD.Nn)
pub fn sframe_key_pair(
    base_key: &[u8],
    kid: Kid,
    cipher: CipherSuite,
) -> Result<SframeKeyMaterial, SframeError> {
    // HKDF-Extract with an empty salt collapses the (possibly short)
    // base_key into a full-HashLen PRK suitable for the two Expand
    // calls below. `Hkdf::new(None, base_key)` does exactly that.
    let hk = Hkdf::<Sha256>::new(None, base_key);

    // Build the two info strings. Each is the literal label + the
    // big-endian KID + the 2-byte cipher_suite identifier.
    let kid_bytes = kid.to_info_bytes();
    let cipher_id = cipher.id_be_bytes();

    let mut key_info = Vec::with_capacity(32);
    key_info.extend_from_slice(b"SFrame 1.0 Secret key ");
    key_info.extend_from_slice(&kid_bytes);
    key_info.extend_from_slice(&cipher_id);

    let mut salt_info = Vec::with_capacity(32);
    salt_info.extend_from_slice(b"SFrame 1.0 Secret salt ");
    salt_info.extend_from_slice(&kid_bytes);
    salt_info.extend_from_slice(&cipher_id);

    let mut key = vec![0u8; cipher.key_len()];
    hk.expand(&key_info, &mut key)
        .map_err(|e| SframeError::Hkdf(format!("expand key: {e}")))?;

    let mut salt = vec![0u8; cipher.nonce_len()];
    hk.expand(&salt_info, &mut salt)
        .map_err(|e| SframeError::Hkdf(format!("expand salt: {e}")))?;

    Ok(SframeKeyMaterial { key, salt })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fixed 32-byte "exporter output" used across tests. In production
    /// this comes from `MLS-Exporter("SFrame 1.0 Base Key", "", 32)`.
    const TEST_EXPORTER: [u8; 32] = [
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
        0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11,
        0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
    ];

    #[test]
    fn cipher_suite_lengths_match_aes_gcm_spec() {
        assert_eq!(CipherSuite::AesGcm128Sha256.key_len(), 16);
        assert_eq!(CipherSuite::AesGcm128Sha256.nonce_len(), 12);
        assert_eq!(CipherSuite::AesGcm256Sha256.key_len(), 32);
        assert_eq!(CipherSuite::AesGcm256Sha256.nonce_len(), 12);
    }

    #[test]
    fn kid_compose_round_trips() {
        let kid = Kid::compose(0, 5, 11);
        assert_eq!(kid.sender_index(), 5);
        assert_eq!(kid.epoch(), 11);

        // Boundary: max sender (63 with 6 bits) + max epoch (15 with 4 bits)
        let kid = Kid::compose(0, 63, 15);
        assert_eq!(kid.sender_index(), 63);
        assert_eq!(kid.epoch(), 15);
    }

    #[test]
    fn kid_truncates_oversized_inputs() {
        // sender_index >= 64 wraps mod 64 (6 bits)
        let kid = Kid::compose(0, 100, 5);
        assert_eq!(kid.sender_index(), 100 % 64);

        // epoch >= 16 wraps mod 16 (4 bits)
        let kid = Kid::compose(0, 1, 17);
        assert_eq!(kid.epoch(), 17 % 16);
    }

    #[test]
    fn epoch_secret_rejects_short_input() {
        let r = sframe_epoch_secret(&[1, 2, 3], CipherSuite::AesGcm128Sha256);
        assert!(matches!(r, Err(SframeError::ExporterTooShort { .. })));
    }

    #[test]
    fn epoch_secret_takes_first_nk_bytes() {
        let s128 = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm128Sha256).unwrap();
        assert_eq!(s128.len(), 16);
        assert_eq!(s128, &TEST_EXPORTER[..16]);

        let s256 = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm256Sha256).unwrap();
        assert_eq!(s256.len(), 32);
        assert_eq!(s256, &TEST_EXPORTER[..32]);
    }

    #[test]
    fn sender_base_key_differs_per_sender() {
        let epoch_secret = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm128Sha256).unwrap();
        let k0 = sender_base_key(&epoch_secret, 0, CipherSuite::AesGcm128Sha256).unwrap();
        let k1 = sender_base_key(&epoch_secret, 1, CipherSuite::AesGcm128Sha256).unwrap();
        assert_ne!(k0, k1, "different senders MUST get different base keys");
        assert_eq!(k0.len(), 16);
    }

    #[test]
    fn sender_base_key_is_deterministic() {
        let epoch_secret = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm128Sha256).unwrap();
        let a = sender_base_key(&epoch_secret, 7, CipherSuite::AesGcm128Sha256).unwrap();
        let b = sender_base_key(&epoch_secret, 7, CipherSuite::AesGcm128Sha256).unwrap();
        assert_eq!(a, b, "same inputs MUST yield same base key");
    }

    #[test]
    fn sframe_key_pair_has_correct_lengths() {
        let epoch_secret = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm128Sha256).unwrap();
        let base = sender_base_key(&epoch_secret, 0, CipherSuite::AesGcm128Sha256).unwrap();
        let kid = Kid::compose(0, 0, 0);
        let kp = sframe_key_pair(&base, kid, CipherSuite::AesGcm128Sha256).unwrap();
        assert_eq!(kp.key.len(), 16);
        assert_eq!(kp.salt.len(), 12);
    }

    #[test]
    fn sframe_key_pair_differs_per_kid() {
        let epoch_secret = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm128Sha256).unwrap();
        let base = sender_base_key(&epoch_secret, 0, CipherSuite::AesGcm128Sha256).unwrap();
        let a = sframe_key_pair(&base, Kid::compose(0, 0, 0), CipherSuite::AesGcm128Sha256).unwrap();
        let b = sframe_key_pair(&base, Kid::compose(0, 0, 1), CipherSuite::AesGcm128Sha256).unwrap();
        // Different epoch → different KID → different key + salt.
        assert_ne!(a.key, b.key);
        assert_ne!(a.salt, b.salt);
    }

    #[test]
    fn sframe_key_pair_differs_per_cipher_suite() {
        let epoch_secret_128 = sframe_epoch_secret(&TEST_EXPORTER, CipherSuite::AesGcm128Sha256).unwrap();
        let base_128 = sender_base_key(&epoch_secret_128, 0, CipherSuite::AesGcm128Sha256).unwrap();
        let kid = Kid::compose(0, 0, 0);
        let a = sframe_key_pair(&base_128, kid, CipherSuite::AesGcm128Sha256).unwrap();

        // The 2-byte cipher_suite identifier appended to the info string
        // makes the derived key fork between suites.
        let base_padded = {
            let mut v = base_128.clone();
            v.extend(std::iter::repeat(0u8).take(32 - v.len()));
            v
        };
        let b = sframe_key_pair(&base_padded, kid, CipherSuite::AesGcm256Sha256).unwrap();

        assert_ne!(a.key, b.key);
        assert_eq!(b.key.len(), 32, "256-bit cipher gets 32-byte key");
    }

    /// Cross-participant invariant: Alice's "outgoing for sender=2" and
    /// Bob's "incoming from sender=2" derive the SAME key/salt from the
    /// same MLS exporter output. This is the property that lets one
    /// side encrypt and the other decrypt without a key exchange.
    #[test]
    fn alice_outgoing_matches_bob_incoming_for_same_sender() {
        let cipher = CipherSuite::AesGcm128Sha256;
        let alice_view_epoch = sframe_epoch_secret(&TEST_EXPORTER, cipher).unwrap();
        let bob_view_epoch = sframe_epoch_secret(&TEST_EXPORTER, cipher).unwrap();

        let alice_base = sender_base_key(&alice_view_epoch, 2, cipher).unwrap();
        let bob_base = sender_base_key(&bob_view_epoch, 2, cipher).unwrap();
        assert_eq!(alice_base, bob_base);

        let kid = Kid::compose(0, 2, 0);
        let alice_kp = sframe_key_pair(&alice_base, kid, cipher).unwrap();
        let bob_kp = sframe_key_pair(&bob_base, kid, cipher).unwrap();
        assert_eq!(alice_kp.key, bob_kp.key);
        assert_eq!(alice_kp.salt, bob_kp.salt);
    }
}
