// ADR-043 — signed invite links.
//
//   https://<server host>/join#<payload>.<signature>
//
// One tap for someone new (the owner's parents, 2026-10-16): the app opens,
// the server is set, the person who shared the link becomes a contact. No
// address to type, no key to paste.
//
// Everything after `#` stays on the phone — browsers never send the
// fragment to the server, so the server (and its logs) never see who invited
// whom. The payload (base64url JSON) names the server, the inviter's identity
// key, their name and when the link was made; the signature (base64url
// Ed25519) covers `sinhron-invite-v1:` + the payload bytes.
//
// Who signs: the identity key when this device holds it; otherwise (a linked
// device, ADR-027) its own device key, and the link carries the device
// certificate (signed by the identity key) that ties the two together.
//
// What the signature does and doesn't do: a changed server, key or name in
// the link no longer verifies — the app refuses it. It does NOT prove that
// the name is true: anyone can make a valid link for their own key with any
// name. So the app shows the key's start and the server before adding, and
// the safety number is still how two people confirm each other.
//
// Short form (status 224, the owner's "variant 1") — the long link in a
// chat looked like garbage, so what is shared is
//
//   https://<server host>/i/<id>#<key>
//
// `id`: 10 random letters/digits; `key`: 16 random bytes (base64url). The
// long link's fragment is sealed under `key` (AES-128-GCM, random nonce in
// front, associated data `sinhron-short-invite-v1:` + id) and left on the
// server under `id` (`POST /v1/invites`, a year). The key is after `#`, so
// the server holds a blob it can't open; the opening phone fetches it
// (`GET /v1/invites/<id>`), opens it and goes on with the long link —
// checked exactly as before. No server, an old one, no network: the long
// link is shared instead (sharing never breaks).

use aes_gcm::aead::{Aead, Payload as AeadPayload};
use aes_gcm::{Aes128Gcm, Key, KeyInit, Nonce};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use ed25519_dalek::{Signer, SigningKey, VerifyingKey};
use rand_core::{OsRng, RngCore};
use serde::{Deserialize, Serialize};

const INVITE_DOMAIN: &[u8] = b"sinhron-invite-v1:";
const MAX_NAME_CHARS: usize = 64;
const MAX_LINK_LEN: usize = 2048;

#[derive(Debug, Serialize, Deserialize)]
struct Payload {
    /// Format version.
    v: u8,
    /// Server host the inviter is on.
    h: String,
    /// Inviter's identity key, hex.
    k: String,
    /// Inviter's name as they set it (may be empty).
    #[serde(default)]
    n: String,
    /// When the link was made (unix seconds).
    t: i64,
    /// Linked device: its certificate (base64url) — the signer is its key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    c: Option<String>,
}

/// A verified invite.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Invite {
    pub server_host: String,
    pub identity_hex: String,
    pub name: String,
    pub created_at: i64,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum InviteError {
    #[error("not a Sinhron invite link")]
    NotInvite,
    #[error("the invite link is damaged")]
    Malformed,
    #[error("the invite link's signature doesn't match — it was changed or forged")]
    BadSignature,
    #[error("the link's address doesn't match the server inside it")]
    HostMismatch,
}

/// Lower-case host without scheme, port 443, path or trailing dot.
fn clean_host(h: &str) -> String {
    h.trim().trim_end_matches('.').trim_end_matches(":443").to_ascii_lowercase()
}

/// A server as the app writes it into a link: a DNS name, `:port` at
/// most — no scheme (`http://` = no TLS), path, `user@`, space or bare IP
/// (security-review-2026-11 app-surface:1, :3).
fn plain_host(h: &str) -> bool {
    let (name, port) = h.rsplit_once(':').unwrap_or((h, "443"));
    name.len() <= 253
        && port.parse::<u16>().is_ok_and(|p| p > 0)
        && name.split('.').all(|l| !l.is_empty() && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        && !name.bytes().all(|b| b.is_ascii_digit() || b == b'.')
}

/// Make the link. `identity_secret`: the identity key if this device has it;
/// else `device_seed` + `device_certificate` sign for it.
pub fn make_link(
    identity_secret: Option<&[u8; 32]>,
    device_seed: &[u8; 32],
    device_certificate: Option<&[u8]>,
    server_host: &str,
    name: &str,
    now: i64,
) -> Result<String, InviteError> {
    let host = clean_host(server_host);
    let name: String = name.trim().chars().take(MAX_NAME_CHARS).collect();
    let (signer, identity_hex, cert) = match identity_secret {
        Some(s) => {
            let sk = SigningKey::from_bytes(s);
            let id = hex::encode(sk.verifying_key().to_bytes());
            (sk, id, None)
        }
        None => {
            let cert = device_certificate.ok_or(InviteError::Malformed)?;
            let (identity, _) = crate::identity::device_of_certificate(cert).ok_or(InviteError::Malformed)?;
            (SigningKey::from_bytes(device_seed), hex::encode(identity), Some(URL_SAFE_NO_PAD.encode(cert)))
        }
    };
    let payload = Payload { v: 1, h: host.clone(), k: identity_hex, n: name, t: now, c: cert };
    let json = serde_json::to_vec(&payload).map_err(|_| InviteError::Malformed)?;
    let mut msg = INVITE_DOMAIN.to_vec();
    msg.extend_from_slice(&json);
    let sig = signer.sign(&msg).to_bytes();
    Ok(format!("https://{host}/join#{}.{}", URL_SAFE_NO_PAD.encode(&json), URL_SAFE_NO_PAD.encode(sig)))
}

/// Open and verify a link: `https://<host>/join#…` or the app's own
/// `sinhron://join#…` (the web page's "Open in the app" button).
pub fn parse_link(link: &str) -> Result<Invite, InviteError> {
    let link = link.trim();
    if link.len() > MAX_LINK_LEN {
        return Err(InviteError::Malformed);
    }
    let (before, fragment) = link.split_once('#').ok_or(InviteError::NotInvite)?;
    let link_host = if let Some(rest) = before.strip_prefix("https://") {
        let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
        if path.trim_end_matches('/') != "join" {
            return Err(InviteError::NotInvite);
        }
        Some(clean_host(host))
    } else if before.trim_end_matches('/') == "sinhron://join" {
        None
    } else {
        return Err(InviteError::NotInvite);
    };
    let (p64, s64) = fragment.split_once('.').ok_or(InviteError::Malformed)?;
    let json = URL_SAFE_NO_PAD.decode(p64).map_err(|_| InviteError::Malformed)?;
    let sig = URL_SAFE_NO_PAD.decode(s64).map_err(|_| InviteError::Malformed)?;
    let sig = ed25519_dalek::Signature::from_slice(&sig).map_err(|_| InviteError::Malformed)?;
    let p: Payload = serde_json::from_slice(&json).map_err(|_| InviteError::Malformed)?;
    if p.v != 1 || !plain_host(&clean_host(&p.h)) {
        return Err(InviteError::Malformed);
    }
    let identity: [u8; 32] = hex::decode(&p.k)
        .ok()
        .and_then(|b| b.try_into().ok())
        .ok_or(InviteError::Malformed)?;
    let signer: [u8; 32] = match &p.c {
        None => identity,
        Some(c64) => {
            let cert = URL_SAFE_NO_PAD.decode(c64).map_err(|_| InviteError::Malformed)?;
            let (cert_identity, device) =
                crate::identity::device_of_certificate(&cert).ok_or(InviteError::BadSignature)?;
            if cert_identity != identity {
                return Err(InviteError::BadSignature);
            }
            device
        }
    };
    let vk = VerifyingKey::from_bytes(&signer).map_err(|_| InviteError::Malformed)?;
    let mut msg = INVITE_DOMAIN.to_vec();
    msg.extend_from_slice(&json);
    vk.verify_strict(&msg, &sig).map_err(|_| InviteError::BadSignature)?;
    // The link opened from one server must not send the person to another.
    if link_host.is_some_and(|h| h != clean_host(&p.h)) {
        return Err(InviteError::HostMismatch);
    }
    let name: String = p.n.trim().replace(['\n', '\r'], " ").chars().take(MAX_NAME_CHARS).collect();
    Ok(Invite { server_host: clean_host(&p.h), identity_hex: p.k.to_ascii_lowercase(), name, created_at: p.t })
}

/// Associated data prefix of a short link's sealed blob (+ its id).
const SHORT_DOMAIN: &[u8] = b"sinhron-short-invite-v1:";
const SHORT_ID_LEN: usize = 10;
const SHORT_KEY_LEN: usize = 16;
const SHORT_NONCE_LEN: usize = 12;
/// Largest blob the server keeps (mirror of the server's `MAX_BLOB`).
pub const SHORT_BLOB_MAX: usize = 4096;

/// A short link's parts: where the blob is and the key that opens it.
#[derive(Clone, PartialEq, Eq)]
pub struct ShortLink {
    pub host: String,
    pub id: String,
    pub key: [u8; SHORT_KEY_LEN],
}

impl std::fmt::Debug for ShortLink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ShortLink").field("host", &self.host).finish_non_exhaustive()
    }
}

impl ShortLink {
    /// A fresh id and key for `host`.
    pub fn new(host: &str) -> Self {
        const ABC: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        let mut id = String::with_capacity(SHORT_ID_LEN);
        while id.len() < SHORT_ID_LEN {
            let mut b = [0u8; 16];
            OsRng.fill_bytes(&mut b);
            // 248 = 4 × 62: every letter equally likely.
            let need = SHORT_ID_LEN - id.len();
            id.extend(b.iter().filter(|&&x| x < 248).map(|&x| ABC[(x % 62) as usize] as char).take(need));
        }
        let mut key = [0u8; SHORT_KEY_LEN];
        OsRng.fill_bytes(&mut key);
        Self { host: clean_host(host), id, key }
    }

    pub fn link(&self) -> String {
        format!("https://{}/i/{}#{}", self.host, self.id, URL_SAFE_NO_PAD.encode(self.key))
    }

    fn aad(&self) -> Vec<u8> {
        let mut ad = SHORT_DOMAIN.to_vec();
        ad.extend_from_slice(self.id.as_bytes());
        ad
    }

    /// Seal a long link's fragment (`<payload>.<signature>`).
    pub fn seal(&self, fragment: &str) -> Vec<u8> {
        let mut nonce = [0u8; SHORT_NONCE_LEN];
        OsRng.fill_bytes(&mut nonce);
        let ct = Aes128Gcm::new(Key::<Aes128Gcm>::from_slice(&self.key))
            .encrypt(Nonce::from_slice(&nonce), AeadPayload { msg: fragment.as_bytes(), aad: &self.aad() })
            .expect("AES-GCM encrypts any short input");
        let mut blob = nonce.to_vec();
        blob.extend_from_slice(&ct);
        blob
    }

    /// Open a sealed blob → the long link `https://<host>/join#<fragment>`.
    pub fn open(&self, blob: &[u8]) -> Result<String, InviteError> {
        if blob.len() <= SHORT_NONCE_LEN || blob.len() > SHORT_BLOB_MAX {
            return Err(InviteError::Malformed);
        }
        let (nonce, ct) = blob.split_at(SHORT_NONCE_LEN);
        let plain = Aes128Gcm::new(Key::<Aes128Gcm>::from_slice(&self.key))
            .decrypt(Nonce::from_slice(nonce), AeadPayload { msg: ct, aad: &self.aad() })
            .map_err(|_| InviteError::Malformed)?;
        let fragment = String::from_utf8(plain).map_err(|_| InviteError::Malformed)?;
        if !fragment.contains('.') || fragment.contains(['#', '/', ' ']) {
            return Err(InviteError::Malformed);
        }
        Ok(format!("https://{}/join#{fragment}", self.host))
    }
}

/// `https://<host>/i/<id>#<key>` or the app's own `sinhron://i/<host>/<id>#<key>`
/// (the web page's button). `NotInvite`: some other link; `Malformed`: a
/// short link with a broken id or key.
pub fn parse_short_link(link: &str) -> Result<ShortLink, InviteError> {
    let link = link.trim();
    if link.len() > MAX_LINK_LEN {
        return Err(InviteError::NotInvite);
    }
    let (before, key64) = link.split_once('#').unwrap_or((link, ""));
    // A messenger may add `?…` (tracking) to the path.
    let before = before.split('?').next().unwrap_or(before);
    let (host, id) = if let Some(rest) = before.strip_prefix("https://") {
        let (host, path) = rest.split_once('/').ok_or(InviteError::NotInvite)?;
        (host, path.strip_prefix("i/").ok_or(InviteError::NotInvite)?)
    } else if let Some(rest) = before.strip_prefix("sinhron://i/") {
        rest.split_once('/').ok_or(InviteError::Malformed)?
    } else {
        return Err(InviteError::NotInvite);
    };
    let id = id.trim_end_matches('/');
    let host = clean_host(host);
    if !plain_host(&host) || id.len() != SHORT_ID_LEN || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(InviteError::Malformed);
    }
    let key: [u8; SHORT_KEY_LEN] = URL_SAFE_NO_PAD
        .decode(key64)
        .ok()
        .and_then(|k| k.try_into().ok())
        .ok_or(InviteError::Malformed)?;
    Ok(ShortLink { host, id: id.to_string(), key })
}

/// The long link → the short one, if its server keeps it; else the long
/// link as it was (offline, an old server, two taken ids in a row).
pub async fn shorten(long: &str) -> String {
    let Some((before, fragment)) = long.split_once('#') else { return long.to_string() };
    let Some(host) = before.strip_prefix("https://").and_then(|r| r.strip_suffix("/join")) else {
        return long.to_string();
    };
    let api = crate::HttpApi::new(format!("https://{host}"));
    for _ in 0..2 {
        let short = ShortLink::new(host);
        match api.put_short_invite(&short.id, &short.seal(fragment)).await {
            Ok(()) => return short.link(),
            Err(crate::HttpError::Server { status: 409, .. }) => continue,
            Err(e) => {
                tracing::info!(error = %e, "short invite not stored — sharing the long link");
                break;
            }
        }
    }
    long.to_string()
}

/// Why a short link couldn't be opened.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum ResolveError {
    #[error("expired")]
    Expired,
    #[error("damaged")]
    Damaged,
    #[error("offline")]
    Offline,
}

/// A short link → the long link it stands for (fetched and opened); any
/// other link comes back unchanged.
pub async fn resolve(link: &str) -> Result<String, ResolveError> {
    let short = match parse_short_link(link) {
        Ok(s) => s,
        Err(InviteError::NotInvite) => return Ok(link.to_string()),
        Err(_) => return Err(ResolveError::Damaged),
    };
    let api = crate::HttpApi::new(format!("https://{}", short.host));
    match api.get_short_invite(&short.id).await {
        Ok(Some(blob)) => short.open(&blob).map_err(|_| ResolveError::Damaged),
        Ok(None) => Err(ResolveError::Expired),
        Err(crate::HttpError::Parse(_)) => Err(ResolveError::Damaged),
        Err(_) => Err(ResolveError::Offline),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: [u8; 32] = [7; 32];
    const DEV: [u8; 32] = [9; 32];

    #[test]
    fn a_link_round_trips_and_names_the_inviter() {
        let link = make_link(Some(&ID), &DEV, None, "Chat.Example.org", "Гриша", 1_760_000_000).unwrap();
        assert!(link.starts_with("https://chat.example.org/join#"));
        let inv = parse_link(&link).unwrap();
        assert_eq!(inv.server_host, "chat.example.org");
        assert_eq!(inv.identity_hex, hex::encode(SigningKey::from_bytes(&ID).verifying_key().to_bytes()));
        assert_eq!(inv.name, "Гриша");
        assert_eq!(inv.created_at, 1_760_000_000);
        // The app's own scheme (the web page's button) opens the same link.
        let (_, frag) = link.split_once('#').unwrap();
        assert_eq!(parse_link(&format!("sinhron://join#{frag}")).unwrap(), inv);
    }

    #[test]
    fn a_changed_server_key_or_name_is_refused() {
        let link = make_link(Some(&ID), &DEV, None, "chat.example.org", "Гриша", 1).unwrap();
        let (base, frag) = link.split_once('#').unwrap();
        let (p64, s64) = frag.split_once('.').unwrap();
        let json = String::from_utf8(URL_SAFE_NO_PAD.decode(p64).unwrap()).unwrap();
        for forged in [
            json.replace("chat.example.org", "evil.example.com"),
            json.replace("Гриша", "Мама"),
            json.replace(
                &hex::encode(SigningKey::from_bytes(&ID).verifying_key().to_bytes()),
                &hex::encode(SigningKey::from_bytes(&[5; 32]).verifying_key().to_bytes()),
            ),
        ] {
            let l = format!("{base}#{}.{s64}", URL_SAFE_NO_PAD.encode(&forged));
            assert_eq!(parse_link(&l), Err(InviteError::BadSignature), "{forged}");
        }
        // Re-signed with another key but claiming the inviter's key: refused.
        let other = make_link(Some(&[8; 32]), &DEV, None, "chat.example.org", "Гриша", 1).unwrap();
        let (_, of) = other.split_once('#').unwrap();
        let (_, os) = of.split_once('.').unwrap();
        assert_eq!(parse_link(&format!("{base}#{p64}.{os}")), Err(InviteError::BadSignature));
    }

    #[test]
    fn a_link_moved_to_another_host_is_refused() {
        let link = make_link(Some(&ID), &DEV, None, "chat.example.org", "", 1).unwrap();
        let moved = link.replace("https://chat.example.org/", "https://evil.example.com/");
        assert_eq!(parse_link(&moved), Err(InviteError::HostMismatch));
    }

    #[test]
    fn a_linked_device_signs_with_its_certificate() {
        let dev_pub = SigningKey::from_bytes(&DEV).verifying_key().to_bytes();
        let cert = crate::identity::device_certificate(&ID, &dev_pub);
        let link = make_link(None, &DEV, Some(&cert), "chat.example.org", "Гриша", 1).unwrap();
        let inv = parse_link(&link).unwrap();
        assert_eq!(inv.identity_hex, hex::encode(SigningKey::from_bytes(&ID).verifying_key().to_bytes()));
        // A certificate for another identity doesn't vouch for this one.
        let foreign = crate::identity::device_certificate(&[3; 32], &dev_pub);
        let (base, frag) = link.split_once('#').unwrap();
        let (p64, s64) = frag.split_once('.').unwrap();
        let json = String::from_utf8(URL_SAFE_NO_PAD.decode(p64).unwrap()).unwrap();
        let swapped = json.replace(&URL_SAFE_NO_PAD.encode(&cert), &URL_SAFE_NO_PAD.encode(&foreign));
        assert_eq!(parse_link(&format!("{base}#{}.{s64}", URL_SAFE_NO_PAD.encode(swapped))), Err(InviteError::BadSignature));
    }

    #[test]
    fn junk_is_not_an_invite() {
        assert_eq!(parse_link("https://chat.example.org/"), Err(InviteError::NotInvite));
        assert_eq!(parse_link("https://chat.example.org/other#x.y"), Err(InviteError::NotInvite));
        assert_eq!(parse_link("https://chat.example.org/join#garbage"), Err(InviteError::Malformed));
        assert_eq!(parse_link(&format!("https://chat.example.org/join#{}", "a".repeat(3000))), Err(InviteError::Malformed));
    }

    #[test]
    fn a_short_link_seals_and_opens_the_long_one() {
        let long = make_link(Some(&ID), &DEV, None, "chat.example.org", "Гриша", 1).unwrap();
        let (_, frag) = long.split_once('#').unwrap();
        let short = ShortLink::new("Chat.Example.org");
        let link = short.link();
        assert!(link.starts_with("https://chat.example.org/i/"));
        assert_eq!(link.len(), "https://chat.example.org/i/".len() + 10 + 1 + 22);
        assert_eq!(parse_short_link(&link).unwrap(), short);
        let blob = short.seal(frag);
        assert_eq!(short.open(&blob).unwrap(), long);
        assert_eq!(parse_link(&short.open(&blob).unwrap()).unwrap().name, "Гриша");
        // Another key, or the blob under another id: refused.
        let other = ShortLink::new("chat.example.org");
        assert_eq!(other.open(&blob), Err(InviteError::Malformed));
        let moved = ShortLink { id: other.id.clone(), ..short.clone() };
        assert_eq!(moved.open(&blob), Err(InviteError::Malformed));
        let mut flipped = blob.clone();
        *flipped.last_mut().unwrap() ^= 1;
        assert_eq!(short.open(&flipped), Err(InviteError::Malformed));
        // Ids differ and are letters/digits only.
        assert_ne!(ShortLink::new("h").id, ShortLink::new("h").id);
        assert!(short.id.bytes().all(|b| b.is_ascii_alphanumeric()));
    }

    #[test]
    fn a_self_signed_link_cannot_send_a_newcomer_to_a_cleartext_or_odd_server() {
        // Signed with the attacker's own key, so only the host check stops it.
        let link = |h: &str| {
            let k = hex::encode(SigningKey::from_bytes(&ID).verifying_key().to_bytes());
            let json = serde_json::to_vec(&Payload { v: 1, h: h.into(), k, n: "Mom".into(), t: 1, c: None }).unwrap();
            let sig = SigningKey::from_bytes(&ID).sign(&[INVITE_DOMAIN, &json].concat()).to_bytes();
            format!("sinhron://join#{}.{}", URL_SAFE_NO_PAD.encode(&json), URL_SAFE_NO_PAD.encode(sig))
        };
        for bad in ["http://evil.example", "ws://evil.example", "evil.example/x", "real.example@evil.example", "1.2.3.4", "[::1]", "a b.example", ""] {
            assert_eq!(parse_link(&link(bad)), Err(InviteError::Malformed), "{bad}");
        }
        assert_eq!(parse_link(&link("Chat.Example.org:8443")).unwrap().server_host, "chat.example.org:8443");
        let key = URL_SAFE_NO_PAD.encode([1u8; 16]);
        for bad in ["real.example@evil.example", "127.0.0.1:8443"] {
            assert_eq!(parse_short_link(&format!("sinhron://i/{bad}/AAAAAAAAAA#{key}")), Err(InviteError::Malformed), "{bad}");
        }
    }

    #[test]
    fn short_links_parse_in_both_forms_and_long_ones_are_left_alone() {
        let short = ShortLink::new("chat.example.org");
        let key = URL_SAFE_NO_PAD.encode(short.key);
        let app = format!("sinhron://i/chat.example.org/{}#{key}", short.id);
        assert_eq!(parse_short_link(&app).unwrap(), short);
        assert_eq!(parse_short_link(&format!("https://chat.example.org/i/{}/#{key}", short.id)).unwrap(), short);
        let long = make_link(Some(&ID), &DEV, None, "chat.example.org", "", 1).unwrap();
        assert_eq!(parse_short_link(&long), Err(InviteError::NotInvite));
        assert_eq!(parse_short_link("sinhron://join#a.b"), Err(InviteError::NotInvite));
        assert_eq!(parse_short_link("https://example.org/"), Err(InviteError::NotInvite));
        // Broken id or key: a damaged short link, not "some other link".
        assert_eq!(parse_short_link(&format!("https://chat.example.org/i/short#{key}")), Err(InviteError::Malformed));
        assert_eq!(parse_short_link(&format!("https://chat.example.org/i/{}#abc", short.id)), Err(InviteError::Malformed));
        assert_eq!(parse_short_link(&format!("https://chat.example.org/i/{}", short.id)), Err(InviteError::Malformed));
        assert_eq!(parse_short_link(&format!("https://chat.example.org/i/{}!#{key}", &short.id[..9])), Err(InviteError::Malformed));
    }

    #[test]
    fn a_short_link_that_looks_like_my_server_but_goes_elsewhere_is_refused() {
        let short = ShortLink::new("chat.example.org");
        let key = URL_SAFE_NO_PAD.encode(short.key);
        for host in ["chat.example.org@evil.example", "chat.example.org%40evil.example", "chat.example.org\\@evil"] {
            let link = format!("sinhron://i/{host}/{}#{key}", short.id);
            assert_eq!(parse_short_link(&link), Err(InviteError::Malformed), "{host}");
        }
        let ok = format!("sinhron://i/chat.example.org:8443/{}#{key}", short.id);
        assert_eq!(parse_short_link(&ok).unwrap().host, "chat.example.org:8443");
    }

    #[tokio::test]
    async fn resolving_a_long_link_returns_it_unchanged() {
        let long = make_link(Some(&ID), &DEV, None, "chat.example.org", "", 1).unwrap();
        assert_eq!(resolve(&long).await.unwrap(), long);
        assert_eq!(resolve("https://chat.example.org/i/x#y").await, Err(ResolveError::Damaged));
        // Not a /join link: nothing to shorten.
        assert_eq!(shorten("https://chat.example.org/other#a.b").await, "https://chat.example.org/other#a.b");
    }
}
