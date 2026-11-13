// MLS credential + signing-key construction.
//
// Per spec §6.2: every user has one Ed25519 identity (derived from the
// 24-word BIP-39 phrase via HKDF) and every *device* is its own MLS leaf.
//
// Two leaf kinds (ADR-025):
//   • legacy / first device — the identity key itself is the leaf's
//     signature key, credential = identity_pub (32 bytes);
//   • linked device — its own random Ed25519 device key signs MLS, and
//     the credential is a device certificate (132 bytes):
//       "SDC1" | identity_pub | device_pub | Ed25519_identity(
//           "sinhron-device-cert-v1:" || device_pub)
//     RFC 9420 needs distinct signature keys per leaf, so two devices
//     can't both use the identity key.
// `identity_of_leaf` maps either kind to the user's identity key —
// what the app shows, verifies and routes by — only when the leaf signs
// with the key its credential names.

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_traits::types::Ciphersuite;
use openmls_traits::OpenMlsProvider;

/// Cipher-suite for all Sinhron MLS groups. Matches `sinhron_crypto::mls`.
pub const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

const DEVICE_CERT_MAGIC: &[u8; 4] = b"SDC1";
const DEVICE_CERT_DOMAIN: &[u8] = b"sinhron-device-cert-v1:";
pub(crate) const DEVICE_CERT_LEN: usize = 4 + 32 + 32 + 64;

/// Device certificate for `device_pub`, signed with the identity key.
pub fn device_certificate(identity_secret: &[u8; 32], device_pub: &[u8; 32]) -> Vec<u8> {
    use ed25519_dalek::Signer;
    let sk = ed25519_dalek::SigningKey::from_bytes(identity_secret);
    let mut msg = DEVICE_CERT_DOMAIN.to_vec();
    msg.extend_from_slice(device_pub);
    let sig = sk.sign(&msg).to_bytes();
    let mut out = Vec::with_capacity(DEVICE_CERT_LEN);
    out.extend_from_slice(DEVICE_CERT_MAGIC);
    out.extend_from_slice(&sk.verifying_key().to_bytes());
    out.extend_from_slice(device_pub);
    out.extend_from_slice(&sig);
    out
}

/// ADR-027 — a device where the 24 words were typed keeps NO identity key
/// either: from the phrase (used once, then dropped) build the same
/// linked-device bundle a QR pairing would deliver, with a certificate for
/// this device's own key. Deterministic for (phrase, device seed), so a
/// wiped Keychain can be rebuilt from the phrase.
pub fn linked_bundle_from_phrase(phrase: &str, device_seed: &[u8; 32]) -> Result<String, IdentityError> {
    let id = sinhron_crypto::identity::derive_identity(phrase).map_err(|e| IdentityError::Derive(e.to_string()))?;
    let device_pub = ed25519_dalek::SigningKey::from_bytes(device_seed).verifying_key().to_bytes();
    Ok(sinhron_crypto::identity::LinkedBundle {
        identity_public: id.ed25519_public,
        x25519_public: id.x25519_public,
        certificate: device_certificate(&id.ed25519_secret, &device_pub),
        delivery_root: id.delivery_root,
        access_root: id.access_root,
        cloud_key: Some(sinhron_crypto::identity::cloud_backup_key(&id.backup_key)),
    }
    .encode())
}

/// A linked-device bundle for `device_pub` straight from the phrase (adding
/// a device from one that holds no account key — the phrase authorizes).
pub fn linked_bundle_for_device(phrase: &str, device_pub: &[u8; 32]) -> Result<String, IdentityError> {
    let id = sinhron_crypto::identity::derive_identity(phrase).map_err(|e| IdentityError::Derive(e.to_string()))?;
    Ok(sinhron_crypto::identity::LinkedBundle {
        identity_public: id.ed25519_public,
        x25519_public: id.x25519_public,
        certificate: device_certificate(&id.ed25519_secret, device_pub),
        delivery_root: id.delivery_root,
        access_root: id.access_root,
        cloud_key: Some(sinhron_crypto::identity::cloud_backup_key(&id.backup_key)),
    }
    .encode())
}

/// The user identity behind an MLS leaf (credential + the key that signs
/// for it): the 32-byte identity key itself when the leaf signs with that
/// key (first device), or the identity of a *valid* device certificate for
/// the leaf's own key (linked device). `None` for anything else — a forged
/// certificate, or someone's credential on another key, names nobody
/// (security review 2026-11, mls-identity:1: MLS checks only the key).
pub fn identity_of_leaf(credential: &[u8], signature_key: &[u8]) -> Option<[u8; 32]> {
    if credential.len() == 32 {
        return (credential == signature_key).then(|| credential.try_into().ok()).flatten();
    }
    device_of_certificate(credential).filter(|(_, device)| device.as_slice() == signature_key).map(|(identity, _)| identity)
}

/// [`identity_of_leaf`] of a leaf node (key package, commit, tree).
pub fn identity_of_leaf_node(leaf: &LeafNode) -> Option<[u8; 32]> {
    identity_of_leaf(leaf.credential().serialized_content(), leaf.signature_key().as_slice())
}

/// [`identity_of_leaf`] of a group member.
pub fn identity_of_member(m: &Member) -> Option<[u8; 32]> {
    identity_of_leaf(m.credential.serialized_content(), &m.signature_key)
}

/// `(identity_pub, device_pub)` of a valid device certificate.
pub fn device_of_certificate(content: &[u8]) -> Option<([u8; 32], [u8; 32])> {
    if content.len() != DEVICE_CERT_LEN || &content[..4] != DEVICE_CERT_MAGIC {
        return None;
    }
    let identity: [u8; 32] = content[4..36].try_into().ok()?;
    let device: [u8; 32] = content[36..68].try_into().ok()?;
    let sig = ed25519_dalek::Signature::from_slice(&content[68..]).ok()?;
    let vk = ed25519_dalek::VerifyingKey::from_bytes(&identity).ok()?;
    let mut msg = DEVICE_CERT_DOMAIN.to_vec();
    msg.extend_from_slice(&device);
    vk.verify_strict(&msg, &sig).ok()?;
    Some((identity, device))
}

/// Materialized MLS identity for one device — credential + signing key.
pub struct MlsIdentity {
    pub credential: CredentialWithKey,
    pub signer: SignatureKeyPair,
    /// Raw 32-byte Ed25519 seed. Used by the HTTP API (`publish_keypackage`)
    /// which needs to sign action proofs separately from the OpenMLS
    /// signer. Stored here because OpenMLS's SignatureKeyPair doesn't
    /// expose the private bytes back out.
    pub(crate) device_seed: [u8; 32],
    /// ADR-025 — the identity key's seed (same on all the person's
    /// devices, from the phrase). Signs account-level requests: WS auth,
    /// sealed keys, calls, media, device revocation. Equals `device_seed`
    /// on the primary device.
    pub(crate) identity_secret: Option<[u8; 32]>,
    /// The user's identity public key (same on all their devices).
    pub identity_public: [u8; 32],
}

impl MlsIdentity {
    /// Build an MLS identity from a 24-word BIP-39 phrase. Re-derives
    /// the Ed25519 keypair via the same HKDF path used by
    /// `sinhron_crypto::identity::derive_identity` — deterministic for
    /// the same phrase. Generic over the OpenMLS provider so the same
    /// code path drives both the in-memory test provider and the
    /// SQLite-backed `SinhronProvider`.
    pub fn from_phrase<P: OpenMlsProvider>(
        provider: &P,
        phrase: &str,
    ) -> Result<Self, IdentityError> {
        let derived = sinhron_crypto::identity::derive_identity(phrase)
            .map_err(|e| IdentityError::Derive(e.to_string()))?;

        // Use the public Ed25519 bytes as the credential identity. Per
        // §6.2 the identity_pubkey IS what the world knows the user by;
        // we surface it verbatim into the BasicCredential.
        let credential = BasicCredential::new(derived.ed25519_public.to_vec());

        // OpenMLS's `SignatureKeyPair::from_raw(scheme, private, public)`
        // expects the Ed25519 "private" to be the 32-byte seed. We
        // pass the BIP-39-derived seed directly so MLS frames are
        // signed with the same key that the WS auth handshake uses —
        // single source of identity (spec §6.2).
        let signer = SignatureKeyPair::from_raw(
            CIPHERSUITE.signature_algorithm(),
            derived.ed25519_secret.to_vec(),
            derived.ed25519_public.to_vec(),
        );
        // `store` is idempotent under `openmls_sqlite_storage` (INSERT
        // OR REPLACE), so re-running this with the same phrase across
        // restarts safely no-ops.
        signer
            .store(provider.storage())
            .map_err(|e| IdentityError::Store(format!("{e:?}")))?;

        Ok(Self {
            credential: CredentialWithKey {
                credential: credential.into(),
                signature_key: derived.ed25519_public.to_vec().into(),
            },
            signer,
            device_seed: derived.ed25519_secret,
            identity_secret: Some(derived.ed25519_secret),
            identity_public: derived.ed25519_public,
        })
    }

    /// ADR-025 — a linked device: MLS leaf signed by its own `device_seed`,
    /// credential = device certificate from the identity key.
    pub fn for_linked_device<P: OpenMlsProvider>(
        provider: &P,
        phrase: &str,
        device_seed: [u8; 32],
    ) -> Result<Self, IdentityError> {
        let derived = sinhron_crypto::identity::derive_identity(phrase)
            .map_err(|e| IdentityError::Derive(e.to_string()))?;
        let device = ed25519_dalek::SigningKey::from_bytes(&device_seed);
        let device_pub = device.verifying_key().to_bytes();
        let cert = device_certificate(&derived.ed25519_secret, &device_pub);
        let signer = SignatureKeyPair::from_raw(
            CIPHERSUITE.signature_algorithm(),
            device_seed.to_vec(),
            device_pub.to_vec(),
        );
        signer
            .store(provider.storage())
            .map_err(|e| IdentityError::Store(format!("{e:?}")))?;
        Ok(Self {
            credential: CredentialWithKey {
                credential: BasicCredential::new(cert).into(),
                signature_key: device_pub.to_vec().into(),
            },
            signer,
            device_seed,
            identity_secret: Some(derived.ed25519_secret),
            identity_public: derived.ed25519_public,
        })
    }
}

impl MlsIdentity {
    /// ADR-027 — a device paired by QR: its own key and the certificate
    /// the adding device signed for it; NO identity key. Everything that
    /// needs the account key (adding devices, revoking, registering the
    /// identity) is refused on this device.
    pub fn from_linked_bundle<P: OpenMlsProvider>(
        provider: &P,
        bundle: &sinhron_crypto::identity::LinkedBundle,
        device_seed: [u8; 32],
    ) -> Result<Self, IdentityError> {
        let device_pub = ed25519_dalek::SigningKey::from_bytes(&device_seed).verifying_key().to_bytes();
        match device_of_certificate(&bundle.certificate) {
            Some((identity, device)) if identity == bundle.identity_public && device == device_pub => {}
            _ => return Err(IdentityError::Derive("device certificate doesn't match this device".into())),
        }
        let signer = SignatureKeyPair::from_raw(CIPHERSUITE.signature_algorithm(), device_seed.to_vec(), device_pub.to_vec());
        signer
            .store(provider.storage())
            .map_err(|e| IdentityError::Store(format!("{e:?}")))?;
        Ok(Self {
            credential: CredentialWithKey {
                credential: BasicCredential::new(bundle.certificate.clone()).into(),
                signature_key: device_pub.to_vec().into(),
            },
            signer,
            device_seed,
            identity_secret: None,
            identity_public: bundle.identity_public,
        })
    }
}

#[derive(Debug, thiserror::Error)]
pub enum IdentityError {
    #[error("derive identity from phrase failed: {0}")]
    Derive(String),
    #[error("store signing key failed: {0}")]
    Store(String),
}

#[cfg(test)]
mod cert_tests {
    use super::*;

    /// ADR-027 — 24 words typed on a new device leave only a bundle: same
    /// person, own key, no identity key; the same phrase + device key give
    /// the same bundle (and storage key), so a wiped Keychain is rebuilt.
    #[test]
    fn phrase_sign_in_keeps_no_identity_key() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let seed = [9u8; 32];
        let a = linked_bundle_from_phrase(phrase, &seed).unwrap();
        assert_eq!(a, linked_bundle_from_phrase(phrase, &seed).unwrap(), "deterministic");
        assert!(a.starts_with(sinhron_crypto::identity::LINKED_PREFIX));
        let client = crate::SyncClient::new(crate::SyncClientConfig { phrase: a.clone(), db_path: None, device_seed: Some(seed) }).unwrap();
        let full = crate::SyncClient::new(crate::SyncClientConfig { phrase: phrase.into(), db_path: None, device_seed: None }).unwrap();
        assert!(!client.has_account_key());
        assert_eq!(client.identity_pubkey_hex(), full.identity_pubkey_hex(), "same person");
        assert_eq!(client.access_key(), full.access_key(), "same access key (shared root)");
        // ADR-071 — and the same per-contact keys on both devices.
        assert_eq!(client.access_key_for(&[1u8; 32]), full.access_key_for(&[1u8; 32]));
        // The bundle can't be used with another device key.
        assert!(crate::SyncClient::new(crate::SyncClientConfig { phrase: a, db_path: None, device_seed: Some([8u8; 32]) }).is_err());
    }

    /// ADR-071 — each contact gets their own key: different from the
    /// others' and from the old shared one, new with every version.
    #[test]
    fn per_contact_access_keys() {
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mut c = crate::SyncClient::new(crate::SyncClientConfig { phrase: phrase.into(), db_path: None, device_seed: None }).unwrap();
        let (alice, carol) = ([1u8; 32], [2u8; 32]);
        let k = c.access_key_for(&alice);
        assert_eq!(k, c.access_key_for(&alice), "deterministic");
        assert_ne!(k, c.access_key_for(&carol));
        assert_ne!(k, c.access_key(), "not the shared key");
        use sha2::Digest;
        assert_eq!(c.access_hash_for(&alice), <[u8; 32]>::from(sha2::Sha256::digest(k)));
        c.set_access_version(1);
        assert_ne!(k, c.access_key_for(&alice), "rotation changes it");
        // Another account gives Alice another key.
        let other = crate::SyncClient::new(crate::SyncClientConfig {
            phrase: "legal winner thank year wave sausage worth useful legal winner thank yellow".into(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        assert_ne!(other.access_key_for(&alice), c.access_key_for(&alice));
    }

    #[test]
    fn device_certificate_names_its_identity_and_rejects_forgery() {
        let id = sinhron_crypto::identity::derive_identity(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        )
        .unwrap();
        let device = [7u8; 32];
        let device_pub = ed25519_dalek::SigningKey::from_bytes(&device).verifying_key().to_bytes();
        let cert = device_certificate(&id.ed25519_secret, &device_pub);
        assert_eq!(identity_of_leaf(&cert, &device_pub), Some(id.ed25519_public));
        assert_eq!(device_of_certificate(&cert), Some((id.ed25519_public, device_pub)));
        // Legacy credential = the identity key, signing with that key.
        assert_eq!(identity_of_leaf(&id.ed25519_public, &id.ed25519_public), Some(id.ed25519_public));
        // Someone's credential on another key names nobody (mls-identity:1).
        assert_eq!(identity_of_leaf(&id.ed25519_public, &device_pub), None, "identity key, attacker's leaf key");
        assert_eq!(identity_of_leaf(&cert, &id.ed25519_public), None, "real certificate, another leaf key");
        // A certificate for someone else's device signed by another key, or tampered, names nobody.
        let mut forged = cert.clone();
        forged[40] ^= 1;
        assert_eq!(identity_of_leaf(&forged, &device_pub), None);
        let other = device_certificate(&[9u8; 32], &device_pub);
        let mut swapped = other.clone();
        swapped[4..36].copy_from_slice(&id.ed25519_public);
        assert_eq!(identity_of_leaf(&swapped, &device_pub), None, "can't claim an identity you can't sign for");
        assert_eq!(identity_of_leaf(b"short", b"short"), None);
    }
}

