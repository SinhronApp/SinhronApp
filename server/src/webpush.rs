// Web Push message encryption (RFC 8291, "aes128gcm" — RFC 8188) for
// UnifiedPush bodies (ADR-040). The phone's connector gave us its P-256
// public key and a 16-byte auth secret with its endpoint; only the phone can
// read what we send, not the distributor (ntfy) in between.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes128Gcm, Nonce};
use hkdf::Hkdf;
use p256::elliptic_curve::sec1::ToEncodedPoint;
use p256::{PublicKey, SecretKey};
use sha2::Sha256;

/// Record size we declare (one record is all a push needs).
const RS: u32 = 4096;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum WebPushError {
    #[error("bad phone key")]
    BadKey,
    #[error("message too long")]
    TooLong,
}

/// Encrypt [plaintext] to the phone's key ([ua_public]: 65-byte uncompressed
/// P-256 point, [auth]: 16 bytes) with a fresh ephemeral key and salt.
pub fn encrypt(ua_public: &[u8], auth: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, WebPushError> {
    let salt: [u8; 16] = rand::random();
    loop {
        let seed: [u8; 32] = rand::random();
        if let Ok(sk) = SecretKey::from_slice(&seed) {
            return encrypt_with(ua_public, auth, plaintext, &sk, salt);
        }
    }
}

/// [encrypt] with a given ephemeral key and salt (tests).
pub fn encrypt_with(
    ua_public: &[u8],
    auth: &[u8],
    plaintext: &[u8],
    as_secret: &SecretKey,
    salt: [u8; 16],
) -> Result<Vec<u8>, WebPushError> {
    if auth.len() != 16 {
        return Err(WebPushError::BadKey);
    }
    // One record: content + the 0x02 last-record delimiter + 16-byte tag.
    if plaintext.len() + 1 + 16 > RS as usize {
        return Err(WebPushError::TooLong);
    }
    let ua = PublicKey::from_sec1_bytes(ua_public).map_err(|_| WebPushError::BadKey)?;
    let ua_bytes = ua.to_encoded_point(false);
    let as_pub = as_secret.public_key().to_encoded_point(false);
    let shared = p256::ecdh::diffie_hellman(as_secret.to_nonzero_scalar(), ua.as_affine());

    // RFC 8291 §3.3: IKM from the ECDH secret, keyed by the auth secret.
    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(ua_bytes.as_bytes());
    key_info.extend_from_slice(as_pub.as_bytes());
    let mut ikm = [0u8; 32];
    Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes())
        .expand(&key_info, &mut ikm)
        .map_err(|_| WebPushError::BadKey)?;
    // RFC 8188 §2.2: content key and nonce from the salt.
    let hk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
    let mut cek = [0u8; 16];
    let mut nonce = [0u8; 12];
    hk.expand(b"Content-Encoding: aes128gcm\0", &mut cek).map_err(|_| WebPushError::BadKey)?;
    hk.expand(b"Content-Encoding: nonce\0", &mut nonce).map_err(|_| WebPushError::BadKey)?;

    let mut padded = plaintext.to_vec();
    padded.push(0x02);
    let ct = Aes128Gcm::new_from_slice(&cek)
        .map_err(|_| WebPushError::BadKey)?
        .encrypt(Nonce::from_slice(&nonce), padded.as_slice())
        .map_err(|_| WebPushError::BadKey)?;

    // Header: salt ‖ rs ‖ idlen ‖ keyid (our ephemeral public key).
    let mut out = Vec::with_capacity(16 + 4 + 1 + 65 + ct.len());
    out.extend_from_slice(&salt);
    out.extend_from_slice(&RS.to_be_bytes());
    out.push(as_pub.as_bytes().len() as u8);
    out.extend_from_slice(as_pub.as_bytes());
    out.extend_from_slice(&ct);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The phone's side (what the UnifiedPush connector does): decrypt.
    fn decrypt(ua_secret: &SecretKey, auth: &[u8], body: &[u8]) -> Vec<u8> {
        let salt = &body[..16];
        let rs = u32::from_be_bytes(body[16..20].try_into().unwrap());
        assert_eq!(rs, RS);
        let idlen = body[20] as usize;
        let as_pub = PublicKey::from_sec1_bytes(&body[21..21 + idlen]).unwrap();
        let ct = &body[21 + idlen..];
        let ua_pub = ua_secret.public_key().to_encoded_point(false);
        let shared = p256::ecdh::diffie_hellman(ua_secret.to_nonzero_scalar(), as_pub.as_affine());
        let mut key_info = b"WebPush: info\0".to_vec();
        key_info.extend_from_slice(ua_pub.as_bytes());
        key_info.extend_from_slice(as_pub.to_encoded_point(false).as_bytes());
        let mut ikm = [0u8; 32];
        Hkdf::<Sha256>::new(Some(auth), shared.raw_secret_bytes()).expand(&key_info, &mut ikm).unwrap();
        let hk = Hkdf::<Sha256>::new(Some(salt), &ikm);
        let (mut cek, mut nonce) = ([0u8; 16], [0u8; 12]);
        hk.expand(b"Content-Encoding: aes128gcm\0", &mut cek).unwrap();
        hk.expand(b"Content-Encoding: nonce\0", &mut nonce).unwrap();
        let mut pt = Aes128Gcm::new_from_slice(&cek).unwrap().decrypt(Nonce::from_slice(&nonce), ct).unwrap();
        assert_eq!(pt.pop(), Some(0x02), "last-record delimiter");
        pt
    }

    #[test]
    fn only_the_phone_reads_the_note() {
        let phone = SecretKey::from_slice(&[0x11; 32]).unwrap();
        let phone_pub = phone.public_key().to_encoded_point(false);
        let auth = [0x22u8; 16];
        let note = br#"{"t":"msg","n":3}"#;
        let a = encrypt(phone_pub.as_bytes(), &auth, note).unwrap();
        let b = encrypt(phone_pub.as_bytes(), &auth, note).unwrap();
        assert_ne!(a, b, "fresh key and salt every time");
        assert_eq!(decrypt(&phone, &auth, &a), note);
        assert!(!a.windows(note.len()).any(|w| w == note), "no plaintext in the body");
        // Someone else's key can't read it.
        let other = SecretKey::from_slice(&[0x33; 32]).unwrap();
        assert!(std::panic::catch_unwind(|| decrypt(&other, &auth, &a)).is_err());
    }

    /// RFC 8291 Appendix A — the same bytes as the standard's example, so
    /// any Web Push client (the UnifiedPush connector) decrypts ours.
    #[test]
    fn matches_the_rfc_8291_example() {
        use base64::Engine;
        let b = |s: &str| base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(s).unwrap();
        let as_secret = SecretKey::from_slice(&b("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")).unwrap();
        let ua_public = b("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
        let auth = b("BTBZMqHH6r4Tts7J_aSIgg");
        let salt: [u8; 16] = b("DGv6ra1nlYgDCS1FRnbzlw").try_into().unwrap();
        let body =
            encrypt_with(&ua_public, &auth, b"When I grow up, I want to be a watermelon", &as_secret, salt).unwrap();
        assert_eq!(
            base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(body),
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        );
    }

    #[test]
    fn bad_keys_and_huge_notes_are_refused() {
        let phone = SecretKey::from_slice(&[0x11; 32]).unwrap();
        let p = phone.public_key().to_encoded_point(false);
        assert_eq!(encrypt(&[4u8; 65], &[0; 16], b"x"), Err(WebPushError::BadKey));
        assert_eq!(encrypt(p.as_bytes(), &[0; 15], b"x"), Err(WebPushError::BadKey));
        assert_eq!(encrypt(p.as_bytes(), &[0; 16], &[0; 5000]), Err(WebPushError::TooLong));
    }
}
