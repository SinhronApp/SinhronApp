// QR pairing of a new device — tech-debt 4.2 / ADR-025.
//
// The new device makes its own device key, a one-time HPKE key pair and
// a random 16-byte pairing id, and shows them as a QR:
//
//   sinhron-pair:2:<id hex>:<HPKE public key hex>:<device public key hex>
//
// The existing device (one that holds the account key) scans it, signs a
// device certificate for that device key and seals a *linked-device
// bundle* (`sinhron-linked:v1:…` — identity public key, certificate, the
// roots needed to receive; NOT the identity key) to the HPKE key —
// X25519 / HKDF-SHA256 / AES-128-GCM, info `sinhron-pair-v1`, aad = id —
// and leaves it on the server under the id (PUT /v1/pairing/{id}). The
// new device takes it (GET, once) and opens it. The HPKE key travels only
// in the QR, so the server can neither read the bundle nor slip in its
// own; the certificate names this device's key, so a bundle meant for
// another device won't open here (ADR-027).
//
// Wire format of the sealed secret: u16 BE len(enc) | enc | ciphertext.

use openmls_traits::crypto::OpenMlsCrypto;
use openmls_traits::types::HpkeCiphertext;
use rand_core::{OsRng, RngCore};

use crate::sealed::HPKE;

pub const QR_PREFIX: &str = "sinhron-pair:2:";
const INFO: &[u8] = b"sinhron-pair-v1";
/// What may be handed over: a linked-device bundle — never the account key.
pub const SECRET_PREFIX: &str = sinhron_crypto::identity::LINKED_PREFIX;

/// The new device's side: id + one-time key pair (never stored) + the
/// public half of its device key.
pub struct PairingOffer {
    pub id: [u8; 16],
    public: Vec<u8>,
    secret: Vec<u8>,
    device_pub: [u8; 32],
}

impl PairingOffer {
    pub fn new(crypto: &impl OpenMlsCrypto, device_pub: [u8; 32]) -> Result<Self, PairingError> {
        let mut id = [0u8; 16];
        OsRng.fill_bytes(&mut id);
        let mut ikm = [0u8; 32];
        OsRng.fill_bytes(&mut ikm);
        let kp = crypto
            .derive_hpke_keypair(HPKE, &ikm)
            .map_err(|e| PairingError::Crypto(format!("{e:?}")))?;
        Ok(Self { id, public: kp.public, secret: (*kp.private).to_vec(), device_pub })
    }

    /// What the QR shows.
    pub fn qr_text(&self) -> String {
        format!("{QR_PREFIX}{}:{}:{}", hex::encode(self.id), hex::encode(&self.public), hex::encode(self.device_pub))
    }

    /// Open what the existing device left → the account secret.
    pub fn open(&self, crypto: &impl OpenMlsCrypto, sealed: &[u8]) -> Result<String, PairingError> {
        if sealed.len() < 2 {
            return Err(PairingError::Format("short"));
        }
        let n = u16::from_be_bytes([sealed[0], sealed[1]]) as usize;
        let enc = sealed.get(2..2 + n).ok_or(PairingError::Format("truncated"))?;
        let ct = HpkeCiphertext { kem_output: enc.to_vec().into(), ciphertext: sealed[2 + n..].to_vec().into() };
        let plain = crypto
            .hpke_open(HPKE, &ct, &self.secret, INFO, &self.id)
            .map_err(|_| PairingError::NotForUs)?;
        let secret = String::from_utf8(plain).map_err(|_| PairingError::Format("not text"))?;
        check_bundle(&secret, &self.device_pub)?;
        Ok(secret)
    }
}

/// A bundle is acceptable only if its certificate is valid and names
/// exactly this device key.
fn check_bundle(bundle: &str, device_pub: &[u8; 32]) -> Result<(), PairingError> {
    let b = sinhron_crypto::identity::LinkedBundle::decode(bundle).map_err(|_| PairingError::Format("not a linked-device bundle"))?;
    match crate::identity::device_of_certificate(&b.certificate) {
        Some((identity, device)) if identity == b.identity_public && &device == device_pub => Ok(()),
        _ => Err(PairingError::Format("certificate is not for this device")),
    }
}

/// Read a pairing QR → (id, HPKE public key, new device's public key).
pub fn parse_qr(text: &str) -> Result<([u8; 16], Vec<u8>, [u8; 32]), PairingError> {
    let rest = text.trim().strip_prefix(QR_PREFIX).ok_or(PairingError::Format("not a Sinhron pairing code"))?;
    let mut parts = rest.split(':');
    let (Some(id_hex), Some(pk_hex), Some(dev_hex), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else {
        return Err(PairingError::Format("bad pairing code"));
    };
    let id: [u8; 16] = hex::decode(id_hex)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or(PairingError::Format("bad pairing id"))?;
    let pk = hex::decode(pk_hex).map_err(|_| PairingError::Format("bad key"))?;
    if pk.len() != 32 {
        return Err(PairingError::Format("bad key"));
    }
    let device: [u8; 32] = hex::decode(dev_hex)
        .ok()
        .and_then(|v| v.try_into().ok())
        .ok_or(PairingError::Format("bad device key"))?;
    Ok((id, pk, device))
}

/// The existing device's side: seal the bundle made for the QR's device.
pub fn seal_secret(crypto: &impl OpenMlsCrypto, qr_text: &str, bundle: &str) -> Result<([u8; 16], Vec<u8>), PairingError> {
    let (id, pk, device) = parse_qr(qr_text)?;
    check_bundle(bundle, &device)?;
    let ct = crypto
        .hpke_seal(HPKE, &pk, INFO, &id, bundle.as_bytes())
        .map_err(|e| PairingError::Crypto(format!("{e:?}")))?;
    let enc = ct.kem_output.as_slice();
    let mut out = Vec::with_capacity(2 + enc.len() + ct.ciphertext.as_slice().len());
    out.extend_from_slice(&(enc.len() as u16).to_be_bytes());
    out.extend_from_slice(enc);
    out.extend_from_slice(ct.ciphertext.as_slice());
    Ok((id, out))
}

/// Public half of a device key seed (what the QR carries).
pub fn device_pub_of_seed(seed: &[u8; 32]) -> [u8; 32] {
    ed25519_dalek::SigningKey::from_bytes(seed).verifying_key().to_bytes()
}

/// The crypto backend the app uses (RustCrypto, as in MLS).
pub fn default_crypto() -> openmls_rust_crypto::RustCrypto {
    openmls_rust_crypto::RustCrypto::default()
}

#[derive(Debug, thiserror::Error)]
pub enum PairingError {
    #[error("crypto: {0}")]
    Crypto(String),
    #[error("pairing code: {0}")]
    Format(&'static str),
    #[error("sealed for another pairing")]
    NotForUs,
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::RustCrypto;

    fn device(n: u8) -> ([u8; 32], [u8; 32]) {
        let seed = [n; 32];
        (seed, ed25519_dalek::SigningKey::from_bytes(&seed).verifying_key().to_bytes())
    }

    fn bundle_for(device_pub: &[u8; 32]) -> String {
        let identity = [9u8; 32];
        sinhron_crypto::identity::LinkedBundle {
            identity_public: ed25519_dalek::SigningKey::from_bytes(&identity).verifying_key().to_bytes(),
            x25519_public: [1u8; 32],
            certificate: crate::identity::device_certificate(&identity, device_pub),
            delivery_root: [2u8; 32],
            access_root: [3u8; 32],
            cloud_key: Some([4u8; 32]),
        }
        .encode()
    }

    #[test]
    fn qr_round_trip_hands_over_a_bundle_for_this_device() {
        let c = RustCrypto::default();
        let (_, dev) = device(4);
        let offer = PairingOffer::new(&c, dev).unwrap();
        let qr = offer.qr_text();
        assert!(qr.starts_with(QR_PREFIX));
        assert_eq!(parse_qr(&qr).unwrap().2, dev);
        let bundle = bundle_for(&dev);
        let (id, sealed) = seal_secret(&c, &qr, &bundle).unwrap();
        assert_eq!(id, offer.id);
        assert!(!sealed.windows(bundle.len()).any(|w| w == bundle.as_bytes()), "not in the clear");
        assert_eq!(offer.open(&c, &sealed).unwrap(), bundle);
    }

    #[test]
    fn another_offer_tampering_or_a_bundle_for_another_device_fails() {
        let c = RustCrypto::default();
        let (_, dev) = device(4);
        let offer = PairingOffer::new(&c, dev).unwrap();
        let other = PairingOffer::new(&c, dev).unwrap();
        let (_, sealed) = seal_secret(&c, &offer.qr_text(), &bundle_for(&dev)).unwrap();
        assert!(matches!(other.open(&c, &sealed), Err(PairingError::NotForUs)));
        let mut bad = sealed.clone();
        *bad.last_mut().unwrap() ^= 1;
        assert!(matches!(offer.open(&c, &bad), Err(PairingError::NotForUs)));
        // A bundle certified for another device isn't sealed…
        let (_, someone_else) = device(5);
        assert!(seal_secret(&c, &offer.qr_text(), &bundle_for(&someone_else)).is_err());
    }

    #[test]
    fn never_the_account_key_or_a_phrase() {
        let c = RustCrypto::default();
        let (_, dev) = device(4);
        let offer = PairingOffer::new(&c, dev).unwrap();
        assert!(parse_qr("https://example.com").is_err());
        assert!(parse_qr("sinhron-pair:1:00:11").is_err(), "old format");
        assert!(seal_secret(&c, &offer.qr_text(), "sinhron-device-key:v1:00ff").is_err(), "never the account key");
        assert!(seal_secret(&c, &offer.qr_text(), "abandon abandon …").is_err(), "never the phrase");
    }
}
