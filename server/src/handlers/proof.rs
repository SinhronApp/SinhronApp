// Ed25519 proof verification — reusable across endpoints.
//
// Two proof flavors so far:
//
//   1. Registration proof (idempotent, no timestamp):
//      sig = Ed25519_sign(identity_priv,
//                         b"sinhron-register-v1:" || identity_pubkey)
//      Used by POST /v1/identity. Replayable but lands on the same row via
//      UNIQUE(identity_pubkey).
//
//   2. Action proof (timestamped, fresh):
//      sig = Ed25519_sign(action_priv,
//                         action_domain || ":" ||
//                         sha256(body_bytes)   || ":" ||
//                         be8(timestamp_secs))
//      Used by all post-registration mutating endpoints (KeyPackage upload,
//      message send, state-backup write, etc.). The server checks the
//      timestamp is within +-CLOCK_SKEW_SECS of now so replays past that
//      window fail. body_hash binds the proof to the specific payload so
//      an attacker can't reuse a signature against a different body.
//
// Each action gets its own domain prefix (`sinhron-upload-kp-v1:`,
// `sinhron-send-msg-v1:`, ...) so a signature minted for one action
// cannot be repurposed as another action's proof.
//
// ADR-086 — every signature this server checks (both flavors above and
// the WS login) names the server it is meant for: what is really signed
// is `SERVER_HOST_DOMAIN || host || 0x00 || <message above>`, where host
// is the name the app dialed (its server URL, never an address from a
// DNS fallback). The server accepts only its own names
// (`SINHRON_PUBLIC_HOSTNAME`, see [`public_hosts`]), so a proof the app
// made for another server can't be passed on to this one.

use ed25519_dalek::{Signature, VerifyingKey};
use sha2::{Digest, Sha256};

/// Domain prefix for [`verify_registration_proof`]. NEVER change without
/// bumping to v2.
pub const REGISTRATION_DOMAIN: &[u8] = b"sinhron-register-v1:";

/// ADR-086 — the prefix that binds a signature to one server's name.
pub const SERVER_HOST_DOMAIN: &[u8] = b"sinhron-server-host-v1:";

/// ADR-086 — the names this server answers to, lowercased: the
/// comma-separated `SINHRON_PUBLIC_HOSTNAME` (docker-compose passes the
/// installer's domain). Unset: only loopback names (local runs, tests).
pub fn public_hosts() -> Vec<String> {
    #[cfg(test)]
    if let Some(v) = PUBLIC_HOSTS_TEST.with(|c| c.borrow().clone()) {
        return v;
    }
    static HOSTS: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    HOSTS.get_or_init(|| parse_hosts(std::env::var("SINHRON_PUBLIC_HOSTNAME").ok().as_deref())).clone()
}

#[cfg(test)]
thread_local! {
    pub static PUBLIC_HOSTS_TEST: std::cell::RefCell<Option<Vec<String>>> = const { std::cell::RefCell::new(None) };
}

fn parse_hosts(v: Option<&str>) -> Vec<String> {
    let hosts: Vec<String> =
        v.unwrap_or("").split(',').map(|h| h.trim().to_ascii_lowercase()).filter(|h| !h.is_empty()).collect();
    if hosts.is_empty() {
        return ["localhost", "127.0.0.1", "[::1]"].map(String::from).to_vec();
    }
    hosts
}

/// ADR-086 — `msg` as signed for the server named `host`.
pub fn bind_to_host(host: &str, msg: &[u8]) -> Vec<u8> {
    let mut m = Vec::with_capacity(SERVER_HOST_DOMAIN.len() + host.len() + 1 + msg.len());
    m.extend_from_slice(SERVER_HOST_DOMAIN);
    m.extend_from_slice(host.as_bytes());
    m.push(0);
    m.extend_from_slice(msg);
    m
}

/// Test helper: `msg` as an app connected to `http://localhost` signs it.
#[cfg(test)]
pub fn for_localhost(msg: &[u8]) -> Vec<u8> {
    bind_to_host("localhost", msg)
}

/// Is `sig` the key's signature over `msg` bound to one of this server's
/// names? Unbound (pre-ADR-086) signatures are refused.
fn verify_bound(vk: &VerifyingKey, msg: &[u8], sig: &Signature) -> Result<(), ProofError> {
    public_hosts()
        .iter()
        // PROOF-3 — strict: small-order keys and non-canonical points are refused.
        .any(|h| vk.verify_strict(&bind_to_host(h, msg), sig).is_ok())
        .then_some(())
        .ok_or(ProofError::SignatureMismatch)
}

/// The WS login: the key's signature over `WS_AUTH_DOMAIN || challenge`,
/// bound to this server (ADR-086).
pub fn verify_ws_auth(pubkey: &[u8], signature: &[u8], challenge: &[u8]) -> Result<(), ProofError> {
    let vk = parse_pubkey(pubkey)?;
    let sig = parse_signature(signature)?;
    let mut msg = WS_AUTH_DOMAIN.to_vec();
    msg.extend_from_slice(challenge);
    verify_bound(&vk, &msg, &sig)
}

/// Domain prefix for KeyPackage upload action.
pub const UPLOAD_KP_DOMAIN: &[u8] = b"sinhron-upload-kp-v1";


/// Domain prefix for the WS auth handshake challenge signature.
/// Mirrored verbatim in `sinhron_net::client` (client side); MUST stay
/// in sync.
pub const WS_AUTH_DOMAIN: &[u8] = b"sinhron-ws-auth-v1:";

/// CA3 — domain for POST /v1/call/token requests. Body is
/// "<group_id_hex>:<kind>" (e.g. `"abc123:video"`).
pub const CALL_TOKEN_DOMAIN: &[u8] = b"sinhron-call-token-v1:";

/// CA4 — domain for GET /v1/call/turn requests. Body is the requesting
/// identity pubkey hex.
pub const CALL_TURN_DOMAIN: &[u8] = b"sinhron-call-turn-v1:";

/// Domain for POST /v1/media. Body is the uploaded blob's sha256 as
/// lowercase hex — the proof binds the claimed hash, the handler then
/// checks the streamed bytes against it.
pub const MEDIA_UPLOAD_DOMAIN: &[u8] = b"sinhron-media-upload-v1:";

/// Domain for GET /v1/media/{sha256}. Body is the requested sha256 hex.
pub const MEDIA_GET_DOMAIN: &[u8] = b"sinhron-media-get-v1:";

/// ADR-064 — POST /v1/media/touch: keep these blobs, say which are gone.
/// Body = sha256 hex of the JSON request body.
pub const MEDIA_TOUCH_DOMAIN: &[u8] = b"sinhron-media-touch-v1:";

/// ADR-023 — publishing sealed-sender delivery keys (PUT /v1/sealed-keys).
pub const PUT_SEALED_KEYS_DOMAIN: &[u8] = b"sinhron-sealed-keys-put-v1:";

/// ADR-025 — a linked device registers itself (POST /v1/devices). Signed
/// by the NEW device's key; body = its device certificate.
pub const DEVICE_ADD_DOMAIN: &[u8] = b"sinhron-device-add-v1:";

/// ADR-025 — revoking a linked device (DELETE /v1/devices/{pk}). Signed by
/// the identity key; body = the revoked device_pk.
pub const DEVICE_REVOKE_DOMAIN: &[u8] = b"sinhron-device-revoke-v1:";

/// Tech-debt 2.5 — a member sets the chat's server-side timer
/// (PUT /v1/groups/{id}/retention). Body = group_id || be8(after_secs).
pub const GROUP_RETENTION_DOMAIN: &[u8] = b"sinhron-group-retention-v1:";

/// ADR-075 — a member's device leaves the chat's card (PUT
/// /v1/groups/{id}/card). Body = group_id || be8(epoch) || card. Signed
/// by that device's own key (the first device's is the identity key).
pub const GROUP_CARD_PUT_DOMAIN: &[u8] = b"sinhron-group-card-put-v1:";

/// ADR-075 — a device of a person who is (or whose cut-off device was) in
/// the chat fetches its card (POST /v1/groups/{id}/card). Body = group_id.
/// Signed by that device's own key.
pub const GROUP_CARD_GET_DOMAIN: &[u8] = b"sinhron-group-card-get-v1:";

/// ADR-035 — a person leaves a group's fan-out (POST /v1/groups/{id}/leave):
/// after leaving, or after seeing that the group removed them. Body =
/// group_id. Signed by the identity key or an active linked device.
pub const GROUP_LEAVE_DOMAIN: &[u8] = b"sinhron-group-leave-v1:";

/// ADR-083 — a device puts devices into a chat's roster (POST /v1/groups).
/// Body = group_id || each member device key. Signed by the creator device.
pub const GROUP_ANNOUNCE_DOMAIN: &[u8] = b"sinhron-group-announce-v1:";

/// ADR-083 — a member takes the people its Commit removed out of the
/// chat's roster (POST /v1/groups/{id}/remove). Body = group_id || each
/// identity key. Signed by the identity key or an active linked device.
pub const GROUP_REMOVE_DOMAIN: &[u8] = b"sinhron-group-remove-v1:";

/// server-http:5 (security review 2026-11) — taking someone's KeyPackages
/// (GET /v1/keypackages/consume). Body = the target identity key. Signed by
/// the identity key or an active linked device.
pub const KP_CONSUME_DOMAIN: &[u8] = b"sinhron-kp-consume-v1:";

/// Tech-debt 4.2 — leaving the sealed account secret for a new device
/// (PUT /v1/pairing/{id}). Body = pairing_id || ciphertext.
pub const PAIRING_PUT_DOMAIN: &[u8] = b"sinhron-pairing-put-v1:";

/// ADR-037 — delete my account (body = my identity key). Only the
/// identity key itself may sign it, never a linked device.
pub const ACCOUNT_DELETE_DOMAIN: &[u8] = b"sinhron-account-delete-v1:";

/// ADR-037 — a report to the operator (body = sha256 of the report JSON).
pub const REPORT_DOMAIN: &[u8] = b"sinhron-report-v1:";

/// ADR-077 — an administrator reads the server's service notices
/// (POST /v1/admin/notices). Body = `after_id` in decimal.
pub const ADMIN_NOTICES_DOMAIN: &[u8] = b"sinhron-admin-notices-v1:";

/// Overnight item 8 — a device's APNs token (body = kind ‖ 0 ‖ token ‖
/// sandbox), signed by that device's own key.
pub const PUSH_TOKEN_DOMAIN: &[u8] = b"sinhron-push-token-v1:";

/// ADR-062 — asking for a Telegram sticker pack by name
/// (POST /v1/stickers/telegram). Body = the name.
pub const TG_STICKERS_DOMAIN: &[u8] = b"sinhron-tg-stickers-v1:";

/// ADR-062 — one file of it (GET /v1/stickers/telegram/{name}/{i}[/thumb]).
/// Body = the path after `/v1/stickers/telegram/`.
pub const TG_STICKER_FILE_DOMAIN: &[u8] = b"sinhron-tg-sticker-file-v1:";

/// ADR-071 — `PUT /v1/access-keys`: the person's per-contact access-key
/// hashes, blocks and unblocks (signed by the identity key).
pub const PUT_ACCESS_KEYS_DOMAIN: &[u8] = b"sinhron-access-keys-put-v1:";

/// ADR-090 (storage-devices:14) — `POST /v1/backup-mark`. Body = cloud ‖
/// be8(created_ts), signed by an active device of the account.
pub const BACKUP_MARK_DOMAIN: &[u8] = b"sinhron-backup-mark-v1:";

/// ADR-090 (calls:5) — the caller's own signature on a call invite, checked
/// by the phones (`sinhron_sync::call_invite`); never by the server.
pub const CALL_INVITE_DOMAIN: &[u8] = b"sinhron-call-invite-v1:";

/// ADR-025 — domain of the identity key's signature inside a device
/// certificate. Mirrored in `sinhron_sync::identity`; not an action proof.
pub const DEVICE_CERT_DOMAIN: &[u8] = b"sinhron-device-cert-v1:";

/// Risk #2 (signature-replay defense). Centralized list of every
/// domain prefix used in Ed25519 signatures across the protocol.
/// Anyone adding a new flavor MUST register it here. The
/// `signature_domains_are_pairwise_non_prefix` test below verifies no
/// two entries are prefixes of each other — silent prefix overlap
/// would let an attacker re-purpose a signature minted under one
/// domain as a valid proof under another (signature-replay /
/// domain-collision attack).
pub const ALL_SIG_DOMAINS: &[&[u8]] = &[
    SERVER_HOST_DOMAIN,
    ACCOUNT_DELETE_DOMAIN,
    REPORT_DOMAIN,
    ADMIN_NOTICES_DOMAIN,
    PUSH_TOKEN_DOMAIN,
    REGISTRATION_DOMAIN,
    UPLOAD_KP_DOMAIN,
    WS_AUTH_DOMAIN,
    CALL_TOKEN_DOMAIN,
    CALL_TURN_DOMAIN,
    MEDIA_UPLOAD_DOMAIN,
    MEDIA_GET_DOMAIN,
    MEDIA_TOUCH_DOMAIN,
    PUT_SEALED_KEYS_DOMAIN,
    PUT_ACCESS_KEYS_DOMAIN,
    DEVICE_ADD_DOMAIN,
    DEVICE_REVOKE_DOMAIN,
    DEVICE_CERT_DOMAIN,
    GROUP_RETENTION_DOMAIN,
    GROUP_LEAVE_DOMAIN,
    GROUP_ANNOUNCE_DOMAIN,
    GROUP_REMOVE_DOMAIN,
    GROUP_CARD_PUT_DOMAIN,
    GROUP_CARD_GET_DOMAIN,
    PAIRING_PUT_DOMAIN,
    TG_STICKERS_DOMAIN,
    TG_STICKER_FILE_DOMAIN,
    BACKUP_MARK_DOMAIN,
    CALL_INVITE_DOMAIN,
];

/// How much clock skew we tolerate either side of `now()` for timestamped
/// proofs. 60s is the standard JWT-ish window — large enough that an
/// honest client with mild NTP drift succeeds, small enough that a
/// replay window is bounded.
pub const ACTION_CLOCK_SKEW_SECS: i64 = 60;

#[derive(Debug, thiserror::Error)]
pub enum ProofError {
    #[error("pubkey must be 32 bytes, got {0}")]
    PubkeyLen(usize),
    #[error("invalid Ed25519 pubkey: {0}")]
    PubkeyInvalid(String),
    #[error("signature must be 64 bytes, got {0}")]
    SignatureLen(usize),
    #[error("signature verification failed")]
    SignatureMismatch,
    #[error("timestamp skew exceeds {limit}s window (Δ={delta}s)")]
    StaleTimestamp { delta: i64, limit: i64 },
}

/// Verify a registration proof — see flavor (1) above.
pub fn verify_registration_proof(pubkey: &[u8], signature: &[u8]) -> Result<(), ProofError> {
    let vk = parse_pubkey(pubkey)?;
    let sig = parse_signature(signature)?;
    let mut msg = Vec::with_capacity(REGISTRATION_DOMAIN.len() + 32);
    msg.extend_from_slice(REGISTRATION_DOMAIN);
    msg.extend_from_slice(pubkey);
    verify_bound(&vk, &msg, &sig)
}

/// Verify a timestamped action proof — see flavor (2) above.
///
/// `now_secs` lets the caller inject a clock (tests, time-warp).
/// Production callers should pass `OffsetDateTime::now_utc().unix_timestamp()`.
pub fn verify_action_proof(
    domain: &[u8],
    signer_pubkey: &[u8],
    body_bytes: &[u8],
    timestamp_secs: i64,
    signature: &[u8],
    now_secs: i64,
) -> Result<(), ProofError> {
    let delta = now_secs.saturating_sub(timestamp_secs).saturating_abs();
    if delta > ACTION_CLOCK_SKEW_SECS {
        return Err(ProofError::StaleTimestamp {
            delta,
            limit: ACTION_CLOCK_SKEW_SECS,
        });
    }

    let vk = parse_pubkey(signer_pubkey)?;
    let sig = parse_signature(signature)?;

    let body_hash = {
        let mut h = Sha256::new();
        h.update(body_bytes);
        h.finalize()
    };

    // Canonical message: domain || b":" || body_hash || b":" || be8(ts)
    let mut msg = Vec::with_capacity(domain.len() + 1 + 32 + 1 + 8);
    msg.extend_from_slice(domain);
    msg.push(b':');
    msg.extend_from_slice(&body_hash);
    msg.push(b':');
    msg.extend_from_slice(&timestamp_secs.to_be_bytes());

    verify_bound(&vk, &msg, &sig)
}

fn parse_pubkey(bytes: &[u8]) -> Result<VerifyingKey, ProofError> {
    if bytes.len() != 32 {
        return Err(ProofError::PubkeyLen(bytes.len()));
    }
    let arr: [u8; 32] = bytes.try_into().expect("checked length");
    VerifyingKey::from_bytes(&arr).map_err(|e| ProofError::PubkeyInvalid(e.to_string()))
}

fn parse_signature(bytes: &[u8]) -> Result<Signature, ProofError> {
    if bytes.len() != 64 {
        return Err(ProofError::SignatureLen(bytes.len()));
    }
    let arr: [u8; 64] = bytes.try_into().expect("checked length");
    Ok(Signature::from_bytes(&arr))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};

    fn fresh_register_proof() -> (Vec<u8>, Vec<u8>) {
        let sk = SigningKey::from_bytes(&[42u8; 32]);
        let pk = sk.verifying_key().to_bytes().to_vec();
        let mut msg = Vec::new();
        msg.extend_from_slice(REGISTRATION_DOMAIN);
        msg.extend_from_slice(&pk);
        let sig = sk.sign(&for_localhost(&msg)).to_bytes().to_vec();
        (pk, sig)
    }

    fn fresh_action_proof(
        domain: &[u8],
        seed: u8,
        body: &[u8],
        ts: i64,
    ) -> (Vec<u8>, Vec<u8>) {
        let sk = SigningKey::from_bytes(&[seed; 32]);
        let pk = sk.verifying_key().to_bytes().to_vec();
        let body_hash = {
            let mut h = Sha256::new();
            h.update(body);
            h.finalize()
        };
        let mut msg = Vec::new();
        msg.extend_from_slice(domain);
        msg.push(b':');
        msg.extend_from_slice(&body_hash);
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        let sig = sk.sign(&for_localhost(&msg)).to_bytes().to_vec();
        (pk, sig)
    }

    #[test]
    fn valid_registration_proof_accepted() {
        let (pk, sig) = fresh_register_proof();
        assert!(verify_registration_proof(&pk, &sig).is_ok());
    }

    #[test]
    fn tampered_registration_proof_rejected() {
        let (pk, mut sig) = fresh_register_proof();
        sig[0] ^= 0x01;
        let err = verify_registration_proof(&pk, &sig).unwrap_err();
        assert!(matches!(err, ProofError::SignatureMismatch));
    }

    #[test]
    fn wrong_pubkey_length_rejected() {
        let err = verify_registration_proof(&[0u8; 31], &[0u8; 64]).unwrap_err();
        assert!(matches!(err, ProofError::PubkeyLen(31)));
    }

    #[test]
    fn wrong_signature_length_rejected() {
        let (pk, _) = fresh_register_proof();
        let err = verify_registration_proof(&pk, &[0u8; 63]).unwrap_err();
        assert!(matches!(err, ProofError::SignatureLen(63)));
    }

    #[test]
    fn proof_for_different_pubkey_rejected() {
        let (_pk_a, sig_a) = fresh_register_proof();
        let pk_b = vec![1u8; 32];
        let res = verify_registration_proof(&pk_b, &sig_a);
        assert!(res.is_err());
    }

    #[test]
    fn action_proof_valid_when_fresh() {
        let body = b"hello world";
        let ts = 1_700_000_000_i64;
        let (pk, sig) = fresh_action_proof(UPLOAD_KP_DOMAIN, 7, body, ts);
        assert!(
            verify_action_proof(UPLOAD_KP_DOMAIN, &pk, body, ts, &sig, ts).is_ok()
        );
    }

    /// srv-http-F1 — a timestamp 2^63 seconds away is stale, not an overflow.
    #[test]
    fn action_proof_rejected_when_the_timestamp_is_absurdly_far() {
        let body = b"hello world";
        let now = 1_700_000_000_i64;
        for ts in [now.wrapping_sub(i64::MIN), i64::MIN, i64::MAX] {
            let (pk, sig) = fresh_action_proof(UPLOAD_KP_DOMAIN, 7, body, ts);
            let err = verify_action_proof(UPLOAD_KP_DOMAIN, &pk, body, ts, &sig, now).unwrap_err();
            assert!(matches!(err, ProofError::StaleTimestamp { .. }), "ts {ts}");
        }
    }

    /// `now - ts` overflowed for a timestamp near i64::MIN / i64::MAX: a
    /// panic with overflow checks, and without them a wrapped delta that
    /// slipped past the freshness check.
    #[test]
    fn action_proof_with_an_extreme_timestamp_is_stale_not_a_panic() {
        for ts in [i64::MIN, i64::MIN + 1, i64::MAX, 1_700_000_000_i64.wrapping_sub(i64::MIN)] {
            let err = verify_action_proof(UPLOAD_KP_DOMAIN, &[0u8; 32], b"x", ts, &[0u8; 64], 1_700_000_000).unwrap_err();
            assert!(matches!(err, ProofError::StaleTimestamp { .. }), "ts {ts}");
        }
    }

    #[test]
    fn action_proof_rejected_when_stale() {
        let body = b"hello world";
        let ts = 1_700_000_000_i64;
        let (pk, sig) = fresh_action_proof(UPLOAD_KP_DOMAIN, 7, body, ts);
        // Now is ts + 120s — beyond the 60s skew window.
        let err =
            verify_action_proof(UPLOAD_KP_DOMAIN, &pk, body, ts, &sig, ts + 120)
                .unwrap_err();
        assert!(matches!(err, ProofError::StaleTimestamp { .. }));
    }

    #[test]
    fn action_proof_rejected_when_body_tampered() {
        let body = b"hello world";
        let ts = 1_700_000_000_i64;
        let (pk, sig) = fresh_action_proof(UPLOAD_KP_DOMAIN, 7, body, ts);
        // Signature was over `body`, but we submit `body_tampered`.
        let body_tampered = b"hello WORLD";
        let err = verify_action_proof(
            UPLOAD_KP_DOMAIN,
            &pk,
            body_tampered,
            ts,
            &sig,
            ts,
        )
        .unwrap_err();
        assert!(matches!(err, ProofError::SignatureMismatch));
    }

    #[test]
    fn action_proof_rejected_under_wrong_domain() {
        let body = b"x";
        let ts = 100_i64;
        let (pk, sig) = fresh_action_proof(UPLOAD_KP_DOMAIN, 7, body, ts);
        // Signed with UPLOAD_KP_DOMAIN; verified under a hypothetical other.
        let other_domain = b"sinhron-send-msg-v1";
        let err = verify_action_proof(other_domain, &pk, body, ts, &sig, ts).unwrap_err();
        assert!(matches!(err, ProofError::SignatureMismatch));
    }

    fn raw_action_msg(domain: &[u8], body: &[u8], ts: i64) -> Vec<u8> {
        let mut m = domain.to_vec();
        m.push(b':');
        m.extend_from_slice(&Sha256::digest(body));
        m.push(b':');
        m.extend_from_slice(&ts.to_be_bytes());
        m
    }

    fn as_server(hosts: &[&str]) {
        PUBLIC_HOSTS_TEST.with(|c| *c.borrow_mut() = Some(hosts.iter().map(|h| h.to_string()).collect()));
    }

    /// ADR-086 (mls-identity:5, server-http:8) — a device revocation the
    /// app signed for server B (an invite to a hostile server) is refused
    /// by server A; the same one signed for A is taken.
    #[test]
    fn a_proof_signed_for_another_server_is_refused() {
        as_server(&["chat.a.example"]);
        let sk = SigningKey::from_bytes(&[9u8; 32]);
        let pk = sk.verifying_key().to_bytes();
        let (device, ts) = ([7u8; 32], 1_700_000_000_i64);
        let msg = raw_action_msg(DEVICE_REVOKE_DOMAIN, &device, ts);
        let for_b = sk.sign(&bind_to_host("evil.b.example", &msg)).to_bytes();
        let err = verify_action_proof(DEVICE_REVOKE_DOMAIN, &pk, &device, ts, &for_b, ts).unwrap_err();
        assert!(matches!(err, ProofError::SignatureMismatch));
        let for_a = sk.sign(&bind_to_host("chat.a.example", &msg)).to_bytes();
        assert!(verify_action_proof(DEVICE_REVOKE_DOMAIN, &pk, &device, ts, &for_a, ts).is_ok());
    }

    /// ADR-086 — the old form names no server at all: refused (no
    /// transition, the owner's call 2026-11-04). Same for registration.
    #[test]
    fn an_old_proof_that_names_no_server_is_refused() {
        as_server(&["chat.a.example"]);
        let sk = SigningKey::from_bytes(&[9u8; 32]);
        let pk = sk.verifying_key().to_bytes();
        let ts = 1_700_000_000_i64;
        let old = sk.sign(&raw_action_msg(ACCOUNT_DELETE_DOMAIN, &pk, ts)).to_bytes();
        assert!(verify_action_proof(ACCOUNT_DELETE_DOMAIN, &pk, &pk, ts, &old, ts).is_err());
        let mut reg = REGISTRATION_DOMAIN.to_vec();
        reg.extend_from_slice(&pk);
        assert!(verify_registration_proof(&pk, &sk.sign(&reg).to_bytes()).is_err());
        assert!(verify_registration_proof(&pk, &sk.sign(&bind_to_host("chat.a.example", &reg)).to_bytes()).is_ok());
    }

    /// ADR-086 — a hostile server shows the app a challenge it took from
    /// the real server; the app's login names the hostile server, so the
    /// real one refuses it. An old login (no server name) is refused too.
    #[test]
    fn a_ws_login_relayed_from_another_server_is_refused() {
        as_server(&["chat.a.example", "chat2.a.example"]);
        let sk = SigningKey::from_bytes(&[5u8; 32]);
        let pk = sk.verifying_key().to_bytes();
        let challenge = [3u8; 32];
        let mut msg = WS_AUTH_DOMAIN.to_vec();
        msg.extend_from_slice(&challenge);
        let relayed = sk.sign(&bind_to_host("evil.b.example", &msg)).to_bytes();
        assert!(verify_ws_auth(&pk, &relayed, &challenge).is_err());
        assert!(verify_ws_auth(&pk, &sk.sign(&msg).to_bytes(), &challenge).is_err(), "old login");
        for host in ["chat.a.example", "chat2.a.example"] {
            let ok = sk.sign(&bind_to_host(host, &msg)).to_bytes();
            assert!(verify_ws_auth(&pk, &ok, &challenge).is_ok(), "{host}");
        }
    }

    /// ADR-086 — fixed vector, computed outside Rust (Python
    /// `cryptography`, seed 0x42 x 32, host "localhost"); the app's side
    /// (`sinhron_sync` `the_signed_bytes_match_the_servers_fixed_vector`)
    /// checks the same one, so both build the same bytes.
    #[test]
    fn the_apps_registration_for_localhost_matches_the_fixed_vector() {
        as_server(&["localhost"]);
        let pk = SigningKey::from_bytes(&[0x42; 32]).verifying_key().to_bytes();
        assert!(verify_registration_proof(&pk, &hex::decode("59c56fabd8fda461df87fde60dc460c0267c421b6504419ed816101e6a3b3b465082e2bb8277b4f841eff2ccb7b0f735dc5749856e38b87fd09ffb891c156f08").unwrap()).is_ok());
    }

    #[test]
    fn public_hosts_come_from_the_setting_or_default_to_loopback() {
        assert_eq!(parse_hosts(Some(" Chat.A.Example , b.example,")), vec!["chat.a.example", "b.example"]);
        assert_eq!(parse_hosts(None), vec!["localhost", "127.0.0.1", "[::1]"]);
        assert_eq!(parse_hosts(Some(" ")), parse_hosts(None));
    }

    /// Risk #2 — pairwise non-prefix invariant. Catches the entire
    /// class of "signature minted for action A accidentally validates
    /// as action B" attacks at build-time.
    ///
    /// Why this matters: if `sinhron-foo-v1` were a prefix of
    /// `sinhron-foo-v10` (silly example but illustrative), and both
    /// happened to use the same SHA-256 transcript shape, a signer
    /// who legitimately signed under `foo-v1` would have effectively
    /// also signed under `foo-v10` — a domain-collision replay attack.
    ///
    /// We additionally check that NONE of the domains are empty —
    /// empty would match every other prefix vacuously.
    #[test]
    fn signature_domains_are_pairwise_non_prefix() {
        for (i, a) in ALL_SIG_DOMAINS.iter().enumerate() {
            assert!(
                !a.is_empty(),
                "domain #{i} is empty — would collide with every other prefix"
            );
            for (j, b) in ALL_SIG_DOMAINS.iter().enumerate() {
                if i == j {
                    continue;
                }
                assert!(
                    !b.starts_with(a),
                    "domain #{i} (`{a_str}`) is a prefix of #{j} (`{b_str}`) — \
                     signature-replay attack vector! Pick a different version \
                     suffix or separator.",
                    a_str = String::from_utf8_lossy(a),
                    b_str = String::from_utf8_lossy(b),
                );
            }
        }
    }

    /// Companion check — every domain ends in either `:` or a digit
    /// (version suffix `v1`, `v2`, …). This is a stylistic invariant
    /// but it ALSO mathematically guarantees pairwise-non-prefix as
    /// long as we never mix the two styles for overlapping name stems.
    /// Tripping this test is your reminder to follow the convention.
    #[test]
    fn signature_domains_follow_termination_convention() {
        for domain in ALL_SIG_DOMAINS {
            let last = *domain.last().expect("never empty — checked above");
            let ok = last == b':' || last.is_ascii_digit();
            assert!(
                ok,
                "domain `{}` must end with ':' or a digit — see Risk #2 \
                 convention notes in handlers/proof.rs",
                String::from_utf8_lossy(domain)
            );
        }
    }

    /// PROOF-3 — the identity point as a "key" made (R = base point, S = 1)
    /// a valid signature over every message; strict verification refuses
    /// small-order keys.
    #[test]
    fn small_order_key_signs_nothing() {
        let mut pk = [0u8; 32];
        pk[0] = 1;
        // R = the base point (0x58, 0x66 × 31), S = 1.
        let mut sig = [0u8; 64];
        sig[..32].fill(0x66);
        sig[0] = 0x58;
        sig[32] = 1;
        assert!(verify_registration_proof(&pk, &sig).is_err());
        assert!(verify_ws_auth(&pk, &sig, b"any challenge").is_err());
        assert!(verify_action_proof(DEVICE_ADD_DOMAIN, &pk, b"any body", 1000, &sig, 1000).is_err());
    }

    /// FUZZ-ENV-1 — both weak keys (00…00 and 01 00…00) with the fixed
    /// signature (R = the key, s = 0): it passed for every message or about
    /// one in four, so 64 different messages each. The app's real signature
    /// is the fixed vector above.
    #[test]
    fn the_weak_keys_sign_no_registration_login_or_request() {
        as_server(&["localhost"]);
        let mut one = [0u8; 32];
        one[0] = 1;
        for pk in [[0u8; 32], one] {
            let mut sig = [0u8; 64];
            sig[..32].copy_from_slice(&pk);
            assert!(verify_registration_proof(&pk, &sig).is_err());
            for i in 0..64u8 {
                assert!(verify_ws_auth(&pk, &sig, &[i; 32]).is_err(), "login {i}");
                assert!(verify_action_proof(DEVICE_ADD_DOMAIN, &pk, &[i], 1000, &sig, 1000).is_err(), "request {i}");
            }
        }
    }
}
