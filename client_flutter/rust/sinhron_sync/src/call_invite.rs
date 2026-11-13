// The caller's signature on its call invite — ADR-090 (security review
// 2026-11, calls:5).
//
// The server wrote every call invite a phone got, and the VoIP push that
// names the caller on the lock screen (its hint key is the server's too): an
// operator could ring any phone as "Mom". Now the caller signs the invite:
//   proof = u64 BE ts | Ed25519 signature (64) | credential
// by its device key over
//   "sinhron-call-invite-v1:" | u64 BE ts | kind (1 audio, 2 video)
//   | u8 len call_id | call_id | group_id
// `credential` ties the key to the person, as in push previews (ADR-056):
// the identity key itself (32 bytes, a first device) or the device
// certificate (132 bytes, ADR-025/027). The phone names the call only for a
// fresh proof by someone in that chat (`api/simple.rs`; the iPhone's CallKit
// path checks the same in `ios/Shared/PushShared.swift`, `CallProof`).

use ed25519_dalek::{Signer, SigningKey, VerifyingKey};

const DOMAIN: &[u8] = b"sinhron-call-invite-v1:";
/// A proof older (or further ahead) than this is refused: an invite rings
/// for at most a minute, and a replayed one must not ring again later.
pub const MAX_AGE_SECS: u64 = 120;
/// The largest proof: ts + signature + device certificate.
pub const MAX_LEN: usize = 8 + 64 + crate::identity::DEVICE_CERT_LEN;

fn message(ts: u64, video: bool, call_id: &str, group_id: &[u8]) -> Vec<u8> {
    let mut m = DOMAIN.to_vec();
    m.extend_from_slice(&ts.to_be_bytes());
    m.push(if video { 2 } else { 1 });
    m.push(call_id.len().min(255) as u8);
    m.extend_from_slice(call_id.as_bytes());
    m.extend_from_slice(group_id);
    m
}

/// Sign an invite. `certificate`: this device's on a linked device (None on
/// a first device, whose key is the identity key).
pub fn sign(device_seed: &[u8; 32], certificate: Option<&[u8]>, call_id: &str, group_id: &[u8], video: bool, ts: u64) -> Vec<u8> {
    let signer = SigningKey::from_bytes(device_seed);
    let mut out = ts.to_be_bytes().to_vec();
    out.extend_from_slice(&signer.sign(&message(ts, video, call_id, group_id)).to_bytes());
    match certificate {
        Some(c) => out.extend_from_slice(c),
        None => out.extend_from_slice(&signer.verifying_key().to_bytes()),
    }
    out
}

/// The caller's identity key, if [proof] is a fresh signature on this call
/// by a key its credential names; None for anything else.
pub fn verify(proof: &[u8], call_id: &str, group_id: &[u8], video: bool, now: u64) -> Option<[u8; 32]> {
    if proof.len() < 8 + 64 + 32 {
        return None;
    }
    let ts = u64::from_be_bytes(proof[..8].try_into().ok()?);
    if ts.abs_diff(now) > MAX_AGE_SECS {
        return None;
    }
    let sig = ed25519_dalek::Signature::from_slice(&proof[8..72]).ok()?;
    let credential = &proof[72..];
    let (identity, signer) = match credential.len() {
        32 => {
            let k: [u8; 32] = credential.try_into().ok()?;
            (k, k)
        }
        _ => crate::identity::device_of_certificate(credential)?,
    };
    VerifyingKey::from_bytes(&signer).ok()?.verify_strict(&message(ts, video, call_id, group_id), &sig).ok()?;
    Some(identity)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_793_800_000;
    const CALL: &str = "0192d6f0-1111-7222-8333-944445555666";

    /// FUZZ-ENV-1 — a small-order ("weak") key with a fixed signature used to
    /// pass for about one message in four (or every one): anyone could sign for it.
    #[test]
    fn a_weak_key_signs_nothing() {
        let mut one = [0u8; 32];
        one[0] = 1; // the neutral point: with `verify` it signed every message
        for key in [[0u8; 32], one] {
            for ts in NOW..NOW + 64 {
                let mut p = ts.to_be_bytes().to_vec();
                p.extend_from_slice(&key); // R
                p.extend_from_slice(&[0u8; 32]); // s
                p.extend_from_slice(&key); // the "identity"
                assert_eq!(verify(&p, CALL, &[0xab; 16], true, ts), None);
            }
        }
    }

    #[test]
    fn a_signed_invite_names_its_caller_and_nothing_else_does() {
        let seed = [9u8; 32];
        let me = SigningKey::from_bytes(&seed).verifying_key().to_bytes();
        let p = sign(&seed, None, CALL, &[0xab; 16], true, NOW);
        assert_eq!(verify(&p, CALL, &[0xab; 16], true, NOW + 30), Some(me));
        // Another chat, call, kind or a late copy: no name.
        assert_eq!(verify(&p, CALL, &[0xcd; 16], true, NOW), None, "another chat");
        assert_eq!(verify(&p, "0192d6f0-0000-7222-8333-944445555666", &[0xab; 16], true, NOW), None, "another call");
        assert_eq!(verify(&p, CALL, &[0xab; 16], false, NOW), None, "audio, not video");
        assert_eq!(verify(&p, CALL, &[0xab; 16], true, NOW + MAX_AGE_SECS + 1), None, "replayed later");
        // The operator signs with its own key in Mom's name: no.
        let mut forged = sign(&[5u8; 32], None, CALL, &[0xab; 16], true, NOW);
        forged[72..].copy_from_slice(&me);
        assert_eq!(verify(&forged, CALL, &[0xab; 16], true, NOW), None, "someone else's key under my identity");
        assert_eq!(verify(&[], CALL, &[0xab; 16], true, NOW), None, "no proof at all");
    }

    #[test]
    fn a_linked_device_signs_with_its_certificate() {
        let identity = [3u8; 32];
        let device = [4u8; 32];
        let device_pub = SigningKey::from_bytes(&device).verifying_key().to_bytes();
        let cert = crate::identity::device_certificate(&identity, &device_pub);
        let p = sign(&device, Some(&cert), CALL, b"chat", false, NOW);
        assert_eq!(p.len(), MAX_LEN);
        assert_eq!(verify(&p, CALL, b"chat", false, NOW), Some(SigningKey::from_bytes(&identity).verifying_key().to_bytes()));
        // A certificate for another device doesn't cover this key.
        let other = crate::identity::device_certificate(&identity, &[0x11; 32]);
        let mut wrong = p.clone();
        wrong[72..].copy_from_slice(&other);
        assert_eq!(verify(&wrong, CALL, b"chat", false, NOW), None);
    }

    /// The vector `ios/SharedTests/main.swift` checks `CallProof` with
    /// (`cargo test -p sinhron_sync call_proof_vector -- --nocapture`).
    #[test]
    fn call_proof_vector() {
        let p = sign(&[9u8; 32], None, "call-1", &[0xab; 16], false, 1_760_000_000);
        println!("proof={}", hex::encode(&p));
        assert!(verify(&p, "call-1", &[0xab; 16], false, 1_760_000_000).is_some());
    }
}
