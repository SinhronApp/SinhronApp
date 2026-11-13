// sinhron_crypto — обёртки над BIP-39, X25519, Ed25519, HKDF.
// Self-contained, не зависит от транспорта/хранилища. Все функции pure.
//
// Modules:
//   - top-level (this file) → BIP-39 generation + phrase validation +
//                              ad-hoc X25519 (legacy from step 1)
//   - identity                → HKDF-based identity derivation per spec §6.2:
//                                Ed25519 (signing) + X25519 (key agreement)
//                                + backup-key, all from one phrase

pub mod identity;
pub mod mls;

use bip39::{Language, Mnemonic};
use rand::rngs::OsRng;
use rand::RngCore;
use x25519_dalek::{PublicKey, StaticSecret};

/// Crypto-side errors. We keep this small and explicit so the frb facade
/// can map onto a Dart sealed-class later (per spec §8.4 "ошибки —
/// sealed CoreError"). For now: stringified at the FFI boundary.
#[derive(Debug, Clone, thiserror::Error)]
pub enum KeyError {
    #[error("invalid mnemonic: {0}")]
    InvalidMnemonic(String),
    #[error("invalid key: {0}")]
    InvalidKey(String),
    #[error("invalid signature: {0}")]
    InvalidSignature(String),
}

// ─────────────────────────────────────────────────────────────────────
// BIP-39 generation / validation
// ─────────────────────────────────────────────────────────────────────

/// Generate a fresh 24-word BIP-39 phrase via OS CSPRNG (256-bit entropy).
/// English wordlist per spec §6.8.
pub fn generate_phrase() -> String {
    let mut entropy = [0u8; 32];
    OsRng.fill_bytes(&mut entropy);
    let mnemonic = Mnemonic::from_entropy_in(Language::English, &entropy)
        .expect("256-bit entropy is always valid for BIP-39 24-word phrase");
    mnemonic.to_string()
}

/// Validate that [phrase] parses as a BIP-39 mnemonic.
pub fn validate_phrase(phrase: &str) -> bool {
    Mnemonic::parse_in_normalized(Language::English, phrase).is_ok()
}

/// Derive the 64-byte BIP-39 seed from [phrase] (PBKDF2-SHA512, empty
/// passphrase per §6.8). Returns hex-encoded for transport across FFI.
pub fn phrase_to_seed_hex(phrase: &str) -> Result<String, String> {
    let m = Mnemonic::parse_in_normalized(Language::English, phrase)
        .map_err(|e| format!("invalid mnemonic: {e}"))?;
    Ok(hex::encode(m.to_seed_normalized("")))
}

/// Internal: 64-byte seed for in-Rust consumers (identity::derive_identity).
pub(crate) fn phrase_to_seed_hex_internal(phrase: &str) -> Result<[u8; 64], KeyError> {
    let m = Mnemonic::parse_in_normalized(Language::English, phrase)
        .map_err(|e| KeyError::InvalidMnemonic(e.to_string()))?;
    Ok(m.to_seed_normalized(""))
}

/// Derive a deterministic X25519 public key from [phrase] using direct
/// seed-prefix mapping. **Legacy from Phase 2 step 1.** Phase 2 step 2
/// switches to HKDF-domain-separated derivation via `identity::derive_identity`.
/// Kept for backwards compatibility of the demo FFI surface; will be
/// removed when the frb facade migrates fully to `identity`.
pub fn phrase_to_x25519_public_hex(phrase: &str) -> Result<String, String> {
    let m = Mnemonic::parse_in_normalized(Language::English, phrase)
        .map_err(|e| format!("invalid mnemonic: {e}"))?;
    let seed = m.to_seed_normalized("");
    let mut secret_bytes = [0u8; 32];
    secret_bytes.copy_from_slice(&seed[..32]);
    let secret = StaticSecret::from(secret_bytes);
    let public = PublicKey::from(&secret);
    Ok(hex::encode(public.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_phrase_is_24_words() {
        let p = generate_phrase();
        assert_eq!(p.split_whitespace().count(), 24);
        assert!(validate_phrase(&p));
    }

    #[test]
    fn known_phrase_validates() {
        let phrase = "abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon art";
        assert!(validate_phrase(phrase));
    }

    #[test]
    fn invalid_phrase_rejected() {
        assert!(!validate_phrase("hello world"));
        assert!(!validate_phrase("a b c d e f g h i j k l"));
    }

    #[test]
    fn x25519_derivation_deterministic() {
        let phrase = "abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon abandon \
                      abandon abandon abandon abandon abandon art";
        let p1 = phrase_to_x25519_public_hex(phrase).unwrap();
        let p2 = phrase_to_x25519_public_hex(phrase).unwrap();
        assert_eq!(p1, p2);
        assert_eq!(p1.len(), 64);
    }
}
