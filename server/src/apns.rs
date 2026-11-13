// APNs client — overnight item 8 (push), item 9 (VoIP).
//
// Token-based auth: an ES256 JWT (`{alg: ES256, kid}` . `{iss: team, iat}`)
// signed with the operator's .p8 key, reused for 50 minutes (Apple wants
// 20–60). HTTP/2 POST to `/3/device/<token>` on the production or sandbox
// host — the app says which one its token belongs to (Xcode builds are
// sandbox, TestFlight / App Store production).
//
// Configuration (all four, or push stays off — `from_env` returns None):
//   APNS_KEY_PATH  path to AuthKey_XXXX.p8 (root-only file; never logged)
//   APNS_KEY_ID    the key's id
//   APNS_TEAM_ID   the Apple team id
//   APNS_TOPIC     the app's bundle id (default com.sinhron.sinhron);
//                  VoIP pushes use `<topic>.voip`
//
// The payload never carries readable message content or a chat id
// (tech-debt 2.7): "New message" in the phone's language (sent with its
// token) and the badge — plus, ADR-056, the sender's sealed preview that
// only the phone opens, and in a call push an HMAC of the chat under the
// phone's own key.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Context;
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use p256::ecdsa::{Signature, SigningKey, signature::Signer};
use p256::pkcs8::DecodePrivateKey;
use tracing::{info, warn};

const PRODUCTION: &str = "https://api.push.apple.com";
const SANDBOX: &str = "https://api.sandbox.push.apple.com";
const JWT_LIFETIME: Duration = Duration::from_secs(50 * 60);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApnsConfig {
    pub key_path: String,
    pub key_id: String,
    pub team_id: String,
    pub topic: String,
}

impl ApnsConfig {
    /// From `APNS_*`; None (push off) unless key path, key id and team id
    /// are all set.
    pub fn from_env() -> Option<Self> {
        Self::from_vars(|k| std::env::var(k).ok())
    }

    pub fn from_vars(get: impl Fn(&str) -> Option<String>) -> Option<Self> {
        let val = |k: &str| get(k).map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        Some(Self {
            key_path: val("APNS_KEY_PATH")?,
            key_id: val("APNS_KEY_ID")?,
            team_id: val("APNS_TEAM_ID")?,
            topic: val("APNS_TOPIC").unwrap_or_else(|| "com.sinhron.sinhron".to_string()),
        })
    }
}

/// What APNs said about one push.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApnsResult {
    Sent,
    /// The token is dead (app removed, token rotated): forget it.
    Gone,
    /// `BadDeviceToken`: usually a token of the other environment (an Xcode
    /// build's sandbox token sent to production, or the reverse) — try the
    /// other one before giving up.
    WrongEnvironment,
    /// Anything else — kept, logged.
    Failed(u16, String),
}

pub struct Apns {
    cfg: ApnsConfig,
    key: SigningKey,
    http: reqwest::Client,
    jwt: Mutex<Option<(String, Instant)>>,
    /// Overridable in tests (a local server instead of Apple).
    hosts: (String, String),
}

impl Apns {
    pub fn new(cfg: ApnsConfig) -> anyhow::Result<Self> {
        let pem = std::fs::read_to_string(&cfg.key_path).context("read APNs key")?;
        let key = SigningKey::from_pkcs8_pem(&pem).map_err(|_| anyhow::anyhow!("APNs key is not a PKCS#8 P-256 key"))?;
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .context("http client")?;
        info!(key_id = %cfg.key_id, topic = %cfg.topic, "APNs push enabled");
        Ok(Self { cfg, key, http, jwt: Mutex::new(None), hosts: (PRODUCTION.into(), SANDBOX.into()) })
    }

    #[cfg(test)]
    pub fn with_key(cfg: ApnsConfig, key: SigningKey, hosts: (String, String)) -> Self {
        Self { cfg, key, http: reqwest::Client::new(), jwt: Mutex::new(None), hosts }
    }

    /// The provider token, signed now or reused (≤ 50 min old).
    pub fn jwt(&self) -> String {
        let mut slot = self.jwt.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((t, at)) = slot.as_ref() {
            if at.elapsed() < JWT_LIFETIME {
                return t.clone();
            }
        }
        let iat = time::OffsetDateTime::now_utc().unix_timestamp();
        let t = make_jwt(&self.key, &self.cfg.key_id, &self.cfg.team_id, iat);
        *slot = Some((t.clone(), Instant::now()));
        t
    }

    /// POST one push. `voip` → topic `<topic>.voip`, push type voip.
    pub async fn send(&self, token: &str, sandbox: bool, kind: ApnsKind, body: &serde_json::Value, collapse: Option<&str>) -> ApnsResult {
        let host = if sandbox { &self.hosts.1 } else { &self.hosts.0 };
        let voip = kind == ApnsKind::Voip;
        let topic = if voip { format!("{}.voip", self.cfg.topic) } else { self.cfg.topic.clone() };
        let mut req = self
            .http
            .post(format!("{host}/3/device/{token}"))
            .bearer_auth(self.jwt())
            .header("apns-topic", topic)
            .header("apns-push-type", kind.push_type())
            // Apple requires 5 for background pushes.
            .header("apns-priority", if kind == ApnsKind::Background { "5" } else { "10" })
            // A call is useless later; a message notification may wait a day.
            .header("apns-expiration", if voip { "0".to_string() } else { (time::OffsetDateTime::now_utc().unix_timestamp() + 86_400).to_string() })
            .json(body);
        if let Some(c) = collapse {
            req = req.header("apns-collapse-id", c);
        }
        match req.send().await {
            Ok(r) if r.status().is_success() => ApnsResult::Sent,
            Ok(r) => {
                let status = r.status().as_u16();
                let reason = r.text().await.unwrap_or_default();
                if reason.contains("BadDeviceToken") {
                    ApnsResult::WrongEnvironment
                } else if status == 410 || reason.contains("Unregistered") || reason.contains("DeviceTokenNotForTopic") {
                    ApnsResult::Gone
                } else {
                    warn!(status, reason = %reason, "APNs refused a push");
                    ApnsResult::Failed(status, reason)
                }
            }
            Err(e) => {
                // critic:6 — the error names the URL, which ends in the
                // phone's push token: it went into the log.
                let e = e.without_url();
                warn!(error = %e, "APNs unreachable");
                ApnsResult::Failed(0, e.to_string())
            }
        }
    }
}

/// `base64url(header).base64url(claims).base64url(r‖s)`.
pub fn make_jwt(key: &SigningKey, key_id: &str, team_id: &str, iat: i64) -> String {
    let header = serde_json::json!({ "alg": "ES256", "kid": key_id });
    let claims = serde_json::json!({ "iss": team_id, "iat": iat });
    let signing_input = format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(header.to_string()),
        URL_SAFE_NO_PAD.encode(claims.to_string())
    );
    let sig: Signature = key.sign(signing_input.as_bytes());
    format!("{signing_input}.{}", URL_SAFE_NO_PAD.encode(sig.to_bytes()))
}

/// "New message" in [lang] (Russian or English; anything else English).
pub fn new_message_text(lang: &str) -> &'static str {
    match lang {
        "ru" => "Новое сообщение",
        _ => "New message",
    }
}

/// A message notification: "New message", the badge — nothing readable.
pub fn alert_body(unread: u32, lang: &str, preview: Option<&[u8]>) -> serde_json::Value {
    let mut b = serde_json::json!({
        "aps": {
            "alert": { "body": new_message_text(lang) },
            "badge": unread,
            "sound": "default",
            "thread-id": "sinhron",
        }
    });
    // ADR-056 — the sender's sealed preview: the phone's Notification
    // Service Extension opens it and writes the name and text itself. The
    // server can't read it; Apple sees the same opaque bytes.
    if let Some(p) = preview {
        b["aps"]["mutable-content"] = 1.into();
        b["p"] = base64::engine::general_purpose::STANDARD.encode(p).into();
    }
    b
}

/// What kind of APNs push (its `apns-push-type`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApnsKind {
    /// A notification iOS shows (the extension may rewrite it).
    Alert,
    /// PushKit: an incoming call.
    Voip,
    /// ADR-071 (amended) — `content-available` only: iOS shows nothing, the
    /// app wakes in the background and decides itself.
    Background,
}

impl ApnsKind {
    pub fn push_type(self) -> &'static str {
        match self {
            Self::Alert => "alert",
            Self::Voip => "voip",
            Self::Background => "background",
        }
    }
}

/// ADR-071 (amended) — a message request: a background push with the
/// sender's sealed preview. iOS shows nothing by itself; the app opens the
/// preview, and unless the sender is blocked there posts one quiet "New
/// message request" (`RequestNotice` in ios/Shared/PushShared.swift). No
/// badge, no sound, no alert text: an alert can't be taken back on iOS
/// without Apple's filtering entitlement, a background push can.
pub fn request_body(preview: &[u8]) -> serde_json::Value {
    serde_json::json!({
        "aps": { "content-available": 1 },
        "r": 1,
        "p": base64::engine::general_purpose::STANDARD.encode(preview),
    })
}

/// A VoIP push (overnight item 9): what CallKit needs to show the call at
/// once — the call id and audio / video. No caller, no group; ADR-056 adds
/// `h`, an HMAC only this phone can match to one of its chats.
pub fn call_body(call_id: &str, video: bool, hint: Option<&str>, proof: Option<&str>) -> serde_json::Value {
    let mut b = serde_json::json!({ "call_id": call_id, "video": video });
    if let Some(h) = hint {
        b["h"] = h.into();
    }
    // ADR-090 — the caller's sealed signature (`push::seal_call_proof`).
    if let Some(s) = proof {
        b["s"] = s.into();
    }
    b
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::{VerifyingKey, signature::Verifier};

    #[test]
    fn config_needs_key_path_id_and_team() {
        let env = |pairs: &'static [(&'static str, &'static str)]| move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
        assert_eq!(ApnsConfig::from_vars(env(&[("APNS_KEY_ID", "K"), ("APNS_TEAM_ID", "T")])), None);
        let c = ApnsConfig::from_vars(env(&[("APNS_KEY_PATH", "/k.p8"), ("APNS_KEY_ID", "K"), ("APNS_TEAM_ID", "T")])).unwrap();
        assert_eq!(c.topic, "com.sinhron.sinhron");
        assert_eq!(ApnsConfig::from_vars(env(&[("APNS_KEY_PATH", " "), ("APNS_KEY_ID", "K"), ("APNS_TEAM_ID", "T")])), None);
    }

    #[test]
    fn jwt_is_es256_with_kid_and_team_and_verifies() {
        let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
        let t = make_jwt(&key, "KEY123", "TEAM456", 1_700_000_000);
        let parts: Vec<&str> = t.split('.').collect();
        assert_eq!(parts.len(), 3);
        let header: serde_json::Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[0]).unwrap()).unwrap();
        let claims: serde_json::Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(header, serde_json::json!({"alg": "ES256", "kid": "KEY123"}));
        assert_eq!(claims, serde_json::json!({"iss": "TEAM456", "iat": 1_700_000_000}));
        let sig = Signature::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
        VerifyingKey::from(&key).verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &sig).unwrap();
    }

    #[test]
    fn the_jwt_is_reused_not_signed_per_push() {
        let key = SigningKey::from_slice(&[9u8; 32]).unwrap();
        let cfg = ApnsConfig { key_path: String::new(), key_id: "K".into(), team_id: "T".into(), topic: "t".into() };
        let a = Apns::with_key(cfg, key, (String::new(), String::new()));
        assert_eq!(a.jwt(), a.jwt());
    }

    #[test]
    fn a_call_push_says_only_which_call() {
        let b = call_body("0190-call", true, None, None);
        assert_eq!(b, serde_json::json!({"call_id": "0190-call", "video": true}));
        let h = call_body("0190-call", false, Some("00ff"), Some("c2VhbGVk"));
        assert_eq!(h, serde_json::json!({"call_id": "0190-call", "video": false, "h": "00ff", "s": "c2VhbGVk"}));
    }

    #[test]
    fn the_alert_carries_no_content() {
        let b = alert_body(3, "ru", None);
        assert_eq!(b["aps"]["badge"], 3);
        assert_eq!(b["aps"]["alert"]["body"], "Новое сообщение");
        assert_eq!(alert_body(1, "de", None)["aps"]["alert"]["body"], "New message");
        assert_eq!(b.as_object().unwrap().len(), 1, "only `aps` — no chat id, no text");
        assert!(b["aps"].get("mutable-content").is_none());
    }

    /// ADR-056 — with a sealed preview the extension may rewrite the
    /// notification; the preview goes as it came (base64), and the visible
    /// fallback is still only "New message".
    #[test]
    fn a_sealed_preview_rides_along_for_the_extension() {
        let b = alert_body(2, "en", Some(&[1, 2, 3]));
        assert_eq!(b["aps"]["mutable-content"], 1);
        assert_eq!(b["p"], "AQID");
        assert_eq!(b["aps"]["alert"]["body"], "New message");
        assert_eq!(b.as_object().unwrap().len(), 2);
    }

    /// ADR-071 (amended) — a message request is a background push: no
    /// alert, badge or sound for iOS to show; only the sealed preview.
    #[test]
    fn a_request_is_a_background_push() {
        let b = request_body(&[1, 2, 3]);
        assert_eq!(b["aps"], serde_json::json!({ "content-available": 1 }));
        assert_eq!(b["r"], 1);
        assert_eq!(b["p"], "AQID");
        assert_eq!(ApnsKind::Background.push_type(), "background");
    }
}
