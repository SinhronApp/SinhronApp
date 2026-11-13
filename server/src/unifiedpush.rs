// UnifiedPush — Android push without Google (ADR-040).
//
// An Android phone gives the server an endpoint URL from its push
// distributor (ntfy — the operator's own, `docs/android-plan.md`). The server
// POSTs a tiny JSON there, encrypted to the phone (Web Push, RFC 8291 —
// `webpush.rs`: the distributor sees only ciphertext); it wakes the app, which draws its own
// notification. Same rules as APNs (ADR-038): no text, no chat, no caller —
//   {"t":"msg","n":<badge>}            a real message arrived
//   {"t":"req"}                        ADR-071: a message request (the app
//                                      decides whether to show anything)
//   {"t":"call","id":"…","v":true,"c":"…"}  an incoming call (video?; the
//                                      caller's key — inside the encryption)
//
// SSRF guard: the server only ever POSTs to `https://` URLs whose host is in
// `SINHRON_UNIFIEDPUSH_HOSTS` (comma-separated; the operator's ntfy). Empty →
// UnifiedPush off and such tokens are refused at registration.
//
// deploy-deps:16 — the own ntfy takes publishes only with the server's token
// (`SINHRON_UNIFIEDPUSH_TOKEN`, `Authorization: Bearer`); phones subscribe
// without one. The token goes only to the first host of the list (the own
// ntfy — the installer writes just that one), never to another distributor.

use std::time::Duration;

use tracing::{info, warn};

use crate::apns::ApnsResult;

/// Longest endpoint URL kept.
pub const MAX_ENDPOINT_LEN: usize = 512;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UnifiedPushConfig {
    pub hosts: Vec<String>,
    /// deploy-deps:16 — the publish token for the own ntfy (`hosts[0]`).
    pub token: Option<String>,
}

impl UnifiedPushConfig {
    pub fn from_env() -> Self {
        let mut c = Self::from_value(std::env::var("SINHRON_UNIFIEDPUSH_HOSTS").ok().as_deref());
        c.token = std::env::var("SINHRON_UNIFIEDPUSH_TOKEN").ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        c
    }

    pub fn from_value(v: Option<&str>) -> Self {
        let hosts = v
            .unwrap_or("")
            .split(',')
            .map(|h| h.trim().trim_end_matches('.').to_ascii_lowercase())
            .filter(|h| !h.is_empty())
            .collect();
        Self { hosts, token: None }
    }

    /// The token to send to [endpoint]: only the own ntfy's (`hosts[0]`).
    pub fn token_for(&self, endpoint: &str) -> Option<&str> {
        let host = reqwest::Url::parse(endpoint).ok()?.host_str()?.to_ascii_lowercase();
        (self.hosts.first() == Some(&host)).then_some(self.token.as_deref()).flatten()
    }

    pub fn enabled(&self) -> bool {
        !self.hosts.is_empty()
    }

    /// May the server POST to [endpoint]? `https`, an allowed host, port 443,
    /// no credentials in the URL, not too long.
    pub fn allows(&self, endpoint: &str) -> bool {
        if endpoint.len() > MAX_ENDPOINT_LEN {
            return false;
        }
        let Ok(url) = reqwest::Url::parse(endpoint) else { return false };
        url.scheme() == "https"
            && url.username().is_empty()
            && url.password().is_none()
            && url.port().is_none_or(|p| p == 443)
            && url.host_str().is_some_and(|h| self.hosts.iter().any(|a| a == &h.to_ascii_lowercase()))
    }
}

/// An endpoint-looking token (vs an APNs hex token).
pub fn is_endpoint(token: &str) -> bool {
    token.starts_with("https://")
}

pub fn message_body(unread: u32) -> serde_json::Value {
    serde_json::json!({ "t": "msg", "n": unread })
}

/// ADR-071 (amended) — [caller]: the caller's identity key (hex), so the
/// phone doesn't ring for someone it blocked (the body is encrypted to the
/// phone; ntfy and Google see ciphertext).
pub fn call_body(call_id: &str, video: bool, caller: Option<&str>) -> serde_json::Value {
    let mut b = serde_json::json!({ "t": "call", "id": call_id, "v": video });
    if let Some(c) = caller {
        b["c"] = c.into();
    }
    b
}

/// ADR-071 (amended) — a message request: the app wakes, fetches it and
/// decides itself (blocked sender → nothing; else one quiet "New message
/// request"). No count, no sender.
pub fn request_body() -> serde_json::Value {
    serde_json::json!({ "t": "req" })
}

pub struct UnifiedPush {
    cfg: UnifiedPushConfig,
    http: reqwest::Client,
}

impl UnifiedPush {
    pub fn new(cfg: UnifiedPushConfig) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            // A redirect could lead anywhere: never follow one.
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        info!(hosts = ?cfg.hosts, "UnifiedPush enabled");
        Ok(Self { cfg, http })
    }

    /// POST an already encrypted ([crate::webpush::encrypt]) body.
    pub async fn send(&self, endpoint: &str, sealed: Vec<u8>, call: bool) -> ApnsResult {
        if !self.cfg.allows(endpoint) {
            // Allowlist changed since registration: drop the token.
            return ApnsResult::Gone;
        }
        let mut req = self.http.post(endpoint);
        if let Some(t) = self.cfg.token_for(endpoint) {
            req = req.bearer_auth(t);
        }
        let req = req
            // WebPush-style hints ntfy understands: a call is useless later.
            .header("TTL", if call { "45" } else { "86400" })
            .header("Urgency", "high")
            .header("Content-Encoding", "aes128gcm")
            .header("Content-Type", "application/octet-stream")
            .body(sealed);
        match req.send().await {
            Ok(r) if r.status().is_success() => ApnsResult::Sent,
            Ok(r) if matches!(r.status().as_u16(), 404 | 410) => ApnsResult::Gone,
            Ok(r) => {
                let status = r.status().as_u16();
                warn!(status, "UnifiedPush endpoint refused a push");
                ApnsResult::Failed(status, String::new())
            }
            Err(e) => {
                // critic:6 — the error names the URL: the phone's endpoint
                // (a push token) went into the log.
                let e = e.without_url();
                warn!(error = %e, "UnifiedPush endpoint unreachable");
                ApnsResult::Failed(0, e.to_string())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_https_endpoints_on_the_operators_hosts() {
        let c = UnifiedPushConfig::from_value(Some(" push.example.org , ntfy.example.net."));
        assert_eq!(c.hosts, vec!["push.example.org", "ntfy.example.net"]);
        assert!(c.allows("https://push.example.org/upAbC123?up=1"));
        assert!(c.allows("https://PUSH.example.org:443/up1"));
        assert!(!c.allows("http://push.example.org/up1"), "plain http");
        assert!(!c.allows("https://evil.example.com/up1"), "another host");
        assert!(!c.allows("https://push.example.org.evil.com/up1"), "suffix trick");
        assert!(!c.allows("https://user:pw@push.example.org/up1"), "credentials");
        assert!(!c.allows("https://push.example.org:8080/up1"), "other port");
        assert!(!c.allows("https://127.0.0.1/up1"));
        assert!(!c.allows(&format!("https://push.example.org/{}", "a".repeat(600))));
        assert!(!UnifiedPushConfig::from_value(None).enabled());
    }

    // deploy-deps:16 — the publish token goes to the own ntfy only.
    #[test]
    fn the_publish_token_goes_only_to_the_own_ntfy() {
        let mut c = UnifiedPushConfig::from_value(Some("push.example.org,ntfy.example.net"));
        assert_eq!(c.token_for("https://push.example.org/up1"), None, "no token configured");
        c.token = Some("tk_x".into());
        assert_eq!(c.token_for("https://PUSH.example.org/up1"), Some("tk_x"));
        assert_eq!(c.token_for("https://ntfy.example.net/up1"), None, "another distributor never gets it");
        assert_eq!(c.token_for("not a url"), None);
    }

    #[test]
    fn bodies_carry_no_content() {
        assert_eq!(message_body(3), serde_json::json!({"t": "msg", "n": 3}));
        assert_eq!(call_body("c1", false, None), serde_json::json!({"t": "call", "id": "c1", "v": false}));
        assert_eq!(call_body("c1", true, Some("ab")), serde_json::json!({"t": "call", "id": "c1", "v": true, "c": "ab"}));
        assert_eq!(request_body(), serde_json::json!({"t": "req"}));
        assert!(is_endpoint("https://x/y") && !is_endpoint("abcdef"));
    }
}
