// Google push (FCM HTTP v1) — ADR-057, Android phones with Google services.
//
// A user swiped Sinhron away and a call didn't ring: without the
// ntfy app (ADR-040) nothing could wake the phone. FCM can — Google Play
// services keep one connection for every app. What Google gets is a
// high-priority data message with ONE field, `s`: our small JSON
// ({"t":"msg","n":…} / {"t":"req"} / {"t":"call","id":…,"v":…,"c":…}, the
// same as UnifiedPush, plus `ts`), padded to a fixed size and sealed with AES-256-GCM under a
// 32-byte key the phone made itself and registered with its token
// (`call_hint_key` column — the phone's own key). Messages and calls look
// the same to Google: same size, same priority, same TTL, no collapse key —
// Google sees only that something came for Sinhron on that phone, and when.
// The app wakes, connects and fetches the real thing from this server.
//
// Configuration — two files from the operator's Firebase project, kept
// outside git like the APNs key (`docs/open-items.md` says how to get them):
//   SINHRON_FCM_SERVICE_ACCOUNT  default /etc/sinhron/fcm/service-account.json
//                                (the private key — root/uid 10001, mode 400)
//   SINHRON_FCM_CLIENT_CONFIG    default /etc/sinhron/fcm/google-services.json
//                                (the Android app's ids — not secret: every
//                                Firebase app ships them inside its APK)
// Both there → FCM on, and `GET /v1/push/info` hands the app the client ids
// (so one APK works with any operator's Firebase project, nothing is baked
// in at build time). Either missing → FCM off, everything works as before.
//
// Auth: a service-account JWT (RS256, signed with `ring`, already in the tree
// through rustls) is traded at Google's token endpoint for an access token,
// reused until 5 minutes before it expires.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use anyhow::Context;
use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use tracing::{info, warn};

use crate::apns::ApnsResult;

/// A token as stored and as the app registers it: `fcm:` + Google's token.
pub const PREFIX: &str = "fcm:";
const SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_HOST: &str = "https://fcm.googleapis.com";
const DEFAULT_ACCOUNT: &str = "/etc/sinhron/fcm/service-account.json";
const DEFAULT_CLIENT: &str = "/etc/sinhron/fcm/google-services.json";
const PACKAGE: &str = "com.sinhron.sinhron";
/// The sealed body is padded to this (or the next multiple of it). 256
/// since ADR-071 (amended): a call carries the caller's key (64 hex), and a
/// message, a request and a call must still be the same size to Google.
pub const PAD: usize = 256;
/// Bound to the ciphertext — a body sealed for anything else won't open.
pub const AAD: &[u8] = b"sinhron-fcm-v1";
/// One TTL for messages and calls (Google must not tell them apart); the
/// phone drops a call older than 2 minutes itself (`ts`).
const TTL: &str = "86400s";

/// Is [token] an FCM token (vs APNs hex or a UnifiedPush URL)?
pub fn is_token(token: &str) -> bool {
    token.starts_with(PREFIX)
}

/// Google's registration tokens: ~150–200 of `[A-Za-z0-9_:-]`.
pub fn valid_token(token: &str) -> bool {
    token.strip_prefix(PREFIX).is_some_and(|t| {
        (20..=400).contains(&t.len()) && t.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b':' | b'-'))
    })
}

/// What the app needs to register with this server's Firebase project.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize)]
pub struct ClientConfig {
    pub project_id: String,
    pub app_id: String,
    pub api_key: String,
    pub sender_id: String,
}

impl ClientConfig {
    /// From `google-services.json`: the client entry of our package.
    pub fn parse(json: &str) -> anyhow::Result<Self> {
        let v: serde_json::Value = serde_json::from_str(json).context("google-services.json is not JSON")?;
        let s = |v: &serde_json::Value| v.as_str().map(str::to_string).filter(|s| !s.is_empty());
        let project = &v["project_info"];
        let client = v["client"]
            .as_array()
            .and_then(|c| {
                c.iter().find(|c| c["client_info"]["android_client_info"]["package_name"].as_str() == Some(PACKAGE))
            })
            .with_context(|| format!("google-services.json has no Android app {PACKAGE}"))?;
        Ok(Self {
            project_id: s(&project["project_id"]).context("project_id")?,
            sender_id: s(&project["project_number"]).context("project_number")?,
            app_id: s(&client["client_info"]["mobilesdk_app_id"]).context("mobilesdk_app_id")?,
            api_key: client["api_key"].as_array().and_then(|k| k.first()).and_then(|k| s(&k["current_key"])).context("api_key")?,
        })
    }
}

/// The service account's fields we use.
#[derive(Clone, Debug, serde::Deserialize)]
pub struct ServiceAccount {
    pub project_id: String,
    pub client_email: String,
    pub private_key: String,
    #[serde(default = "default_token_uri")]
    pub token_uri: String,
}

fn default_token_uri() -> String {
    "https://oauth2.googleapis.com/token".to_string()
}

/// The two files, or None (FCM off).
pub struct FcmConfig {
    pub account: ServiceAccount,
    pub client: ClientConfig,
}

impl FcmConfig {
    pub fn from_env() -> Option<Self> {
        let path = |k: &str, d: &str| std::env::var(k).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty()).unwrap_or(d.into());
        let account = path("SINHRON_FCM_SERVICE_ACCOUNT", DEFAULT_ACCOUNT);
        let client = path("SINHRON_FCM_CLIENT_CONFIG", DEFAULT_CLIENT);
        if !std::path::Path::new(&account).exists() || !std::path::Path::new(&client).exists() {
            info!("no FCM files in /etc/sinhron/fcm — Google push for Android off");
            return None;
        }
        let load = || -> anyhow::Result<Self> {
            let account: ServiceAccount =
                serde_json::from_str(&std::fs::read_to_string(&account).context("read service account")?)
                    .context("service account JSON")?;
            let client = ClientConfig::parse(&std::fs::read_to_string(&client).context("read google-services.json")?)?;
            anyhow::ensure!(account.project_id == client.project_id, "the two FCM files are from different Firebase projects");
            Ok(Self { account, client })
        };
        load().inspect_err(|e| warn!(error = %e, "FCM configured but unusable")).ok()
    }

    /// Only the client ids (for `/v1/push/info`), when FCM is usable.
    pub fn client_from_env() -> Option<ClientConfig> {
        Self::from_env().map(|c| c.client)
    }
}

/// PKCS#8 PEM → DER.
fn pem_to_der(pem: &str) -> anyhow::Result<Vec<u8>> {
    let b64: String = pem.lines().filter(|l| !l.starts_with("-----")).map(str::trim).collect();
    STANDARD.decode(b64).context("private key PEM")
}

/// `base64url(header).base64url(claims).base64url(RS256)` for Google's
/// token endpoint.
pub fn make_jwt(key: &ring::signature::RsaKeyPair, account: &ServiceAccount, iat: i64) -> anyhow::Result<String> {
    let header = serde_json::json!({ "alg": "RS256", "typ": "JWT" });
    let claims = serde_json::json!({
        "iss": account.client_email,
        "scope": SCOPE,
        "aud": account.token_uri,
        "iat": iat,
        "exp": iat + 3600,
    });
    let input = format!("{}.{}", URL_SAFE_NO_PAD.encode(header.to_string()), URL_SAFE_NO_PAD.encode(claims.to_string()));
    let mut sig = vec![0u8; key.public().modulus_len()];
    key.sign(&ring::signature::RSA_PKCS1_SHA256, &ring::rand::SystemRandom::new(), input.as_bytes(), &mut sig)
        .map_err(|_| anyhow::anyhow!("RS256 sign failed"))?;
    Ok(format!("{input}.{}", URL_SAFE_NO_PAD.encode(sig)))
}

/// Seal [body] for the phone: JSON padded with spaces to [PAD] bytes (a
/// multiple of it if longer), AES-256-GCM under its key; base64 of
/// nonce ‖ ciphertext. None when the key isn't 32 bytes.
pub fn seal(key: &[u8], body: &serde_json::Value) -> Option<String> {
    use aes_gcm::aead::{Aead, KeyInit, Payload};
    let cipher = aes_gcm::Aes256Gcm::new_from_slice(key).ok()?;
    let mut plain = body.to_string().into_bytes();
    let len = plain.len().div_ceil(PAD).max(1) * PAD;
    plain.resize(len, b' ');
    let nonce: [u8; 12] = rand::random();
    let mut out = nonce.to_vec();
    out.extend(cipher.encrypt(aes_gcm::Nonce::from_slice(&nonce), Payload { msg: &plain, aad: AAD }).ok()?);
    Some(STANDARD.encode(out))
}

pub struct Fcm {
    account: ServiceAccount,
    key: ring::signature::RsaKeyPair,
    http: reqwest::Client,
    access: Mutex<Option<(String, Instant)>>,
    /// Overridable in tests (a local server instead of Google).
    host: String,
}

impl Fcm {
    pub fn new(cfg: FcmConfig) -> anyhow::Result<Self> {
        let der = pem_to_der(&cfg.account.private_key)?;
        let key = ring::signature::RsaKeyPair::from_pkcs8(&der).map_err(|e| anyhow::anyhow!("service account key: {e}"))?;
        let http = reqwest::Client::builder().timeout(Duration::from_secs(10)).build().context("http client")?;
        info!(project = %cfg.account.project_id, "FCM (Google push for Android) enabled");
        Ok(Self { account: cfg.account, key, http, access: Mutex::new(None), host: FCM_HOST.into() })
    }

    #[cfg(test)]
    pub fn with_host(cfg: FcmConfig, host: String) -> anyhow::Result<Self> {
        Ok(Self { host, ..Self::new(cfg)? })
    }

    /// An access token, fetched now or reused.
    async fn access_token(&self, fresh: bool) -> anyhow::Result<String> {
        if !fresh {
            if let Some((t, until)) = self.access.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
                if Instant::now() < *until {
                    return Ok(t.clone());
                }
            }
        }
        let jwt = make_jwt(&self.key, &self.account, time::OffsetDateTime::now_utc().unix_timestamp())?;
        let r = self
            .http
            .post(&self.account.token_uri)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(format!("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={jwt}"))
            .send()
            .await
            .context("Google token endpoint unreachable")?;
        let status = r.status();
        let v: serde_json::Value = r.json().await.unwrap_or_default();
        let token = v["access_token"].as_str().filter(|_| status.is_success()).with_context(|| format!("token endpoint said {status}"))?;
        let ttl = v["expires_in"].as_u64().unwrap_or(3600).saturating_sub(300).clamp(60, 3600);
        *self.access.lock().unwrap_or_else(|e| e.into_inner()) = Some((token.to_string(), Instant::now() + Duration::from_secs(ttl)));
        Ok(token.to_string())
    }

    /// Send one sealed body ([seal]) to [token] (with or without `fcm:`).
    pub async fn send(&self, token: &str, sealed: &str) -> ApnsResult {
        let token = token.strip_prefix(PREFIX).unwrap_or(token);
        let body = serde_json::json!({
            "message": {
                "token": token,
                "data": { "s": sealed },
                "android": { "priority": "HIGH", "ttl": TTL },
            }
        });
        let url = format!("{}/v1/projects/{}/messages:send", self.host, self.account.project_id);
        for fresh in [false, true] {
            let access = match self.access_token(fresh).await {
                Ok(a) => a,
                Err(e) => {
                    warn!(error = %e, "FCM: no access token");
                    return ApnsResult::Failed(0, e.to_string());
                }
            };
            let r = match self.http.post(&url).bearer_auth(access).json(&body).send().await {
                Ok(r) => r,
                Err(e) => {
                    warn!(error = %e, "FCM unreachable");
                    return ApnsResult::Failed(0, e.to_string());
                }
            };
            let status = r.status().as_u16();
            if r.status().is_success() {
                return ApnsResult::Sent;
            }
            let text = r.text().await.unwrap_or_default();
            if status == 401 && !fresh {
                continue; // the access token expired early — once more with a new one
            }
            return classify(status, &text);
        }
        ApnsResult::Failed(401, String::new())
    }
}

/// What an FCM error means for the token: 404 UNREGISTERED (app removed,
/// token rotated), a malformed token, or a token of another Firebase
/// project (the operator switched projects) → forget it; anything else
/// (quota, Google down) → keep it.
pub fn classify(status: u16, body: &str) -> ApnsResult {
    let gone = status == 404
        || body.contains("UNREGISTERED")
        || body.contains("SENDER_ID_MISMATCH")
        || (status == 400 && body.contains("registration token"));
    if gone {
        ApnsResult::Gone
    } else {
        warn!(status, "FCM refused a push");
        ApnsResult::Failed(status, body.chars().take(200).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A throwaway 2048-bit RSA key for the tests only (never used anywhere).
    const TEST_KEY: &str = include_str!("../tests/fixtures/fcm_test_key.pem");

    fn account(token_uri: String) -> ServiceAccount {
        ServiceAccount {
            project_id: "sinhron-test".into(),
            client_email: "push@sinhron-test.iam.gserviceaccount.com".into(),
            private_key: TEST_KEY.into(),
            token_uri,
        }
    }

    fn client() -> ClientConfig {
        ClientConfig { project_id: "sinhron-test".into(), app_id: "1:42:android:ab".into(), api_key: "AIzaX".into(), sender_id: "42".into() }
    }

    #[test]
    fn tokens_are_told_apart_and_checked() {
        let t = format!("fcm:{}", "dGVzdA:APA91b_x-".repeat(10));
        assert!(is_token(&t) && valid_token(&t));
        assert!(!valid_token("fcm:short"));
        assert!(!valid_token(&format!("fcm:{}", "a b".repeat(20))));
        assert!(!is_token("https://push.example.org/up") && !is_token(&"ab".repeat(32)));
    }

    #[test]
    fn client_config_comes_from_google_services_json() {
        let json = r#"{"project_info":{"project_number":"42","project_id":"sinhron-test"},
          "client":[{"client_info":{"mobilesdk_app_id":"1:42:android:zz","android_client_info":{"package_name":"other.app"}},"api_key":[{"current_key":"no"}]},
                    {"client_info":{"mobilesdk_app_id":"1:42:android:ab","android_client_info":{"package_name":"com.sinhron.sinhron"}},"api_key":[{"current_key":"AIzaX"}]}]}"#;
        assert_eq!(ClientConfig::parse(json).unwrap(), client());
        assert!(ClientConfig::parse(r#"{"project_info":{},"client":[]}"#).is_err());
    }

    /// The phone opens it with AES/GCM/NoPadding, the same AAD
    /// (`android/.../Fcm.kt`); a message and a call are the same size.
    #[test]
    fn sealed_bodies_open_with_the_phone_key_and_all_look_alike() {
        use aes_gcm::aead::{Aead, KeyInit, Payload};
        let key = [9u8; 32];
        let msg = seal(&key, &serde_json::json!({ "t": "msg", "n": 3, "ts": 1 })).unwrap();
        // ADR-071 (amended) — with the caller's key, and a request: still
        // one size for Google.
        let mut call_body = crate::unifiedpush::call_body("0192d6f0-1111-7222-8333-944445555666", true, Some(&"ab".repeat(32)));
        call_body["ts"] = 1_760_000_000i64.into();
        let call = seal(&key, &call_body).unwrap();
        let req = seal(&key, &serde_json::json!({ "t": "req", "ts": 1_760_000_000i64 })).unwrap();
        assert_eq!(msg.len(), call.len());
        assert_eq!(msg.len(), req.len());
        let raw = STANDARD.decode(&call).unwrap();
        let cipher = aes_gcm::Aes256Gcm::new_from_slice(&key).unwrap();
        let plain = cipher.decrypt(aes_gcm::Nonce::from_slice(&raw[..12]), Payload { msg: &raw[12..], aad: AAD }).unwrap();
        assert_eq!(plain.len(), PAD);
        let v: serde_json::Value = serde_json::from_slice(&plain).unwrap();
        assert_eq!(v["t"], "call");
        assert!(cipher.decrypt(aes_gcm::Nonce::from_slice(&raw[..12]), Payload { msg: &raw[12..], aad: b"x" }).is_err());
        assert!(seal(&[1u8; 16], &v).is_none());
    }

    #[test]
    fn errors_that_mean_the_token_is_dead() {
        assert_eq!(classify(404, r#"{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}"#), ApnsResult::Gone);
        assert_eq!(classify(400, r#"{"error":{"message":"The registration token is not a valid FCM registration token"}}"#), ApnsResult::Gone);
        assert_eq!(classify(403, r#"{"error":{"details":[{"errorCode":"SENDER_ID_MISMATCH"}]}}"#), ApnsResult::Gone);
        assert!(matches!(classify(429, "QUOTA_EXCEEDED"), ApnsResult::Failed(429, _)));
        assert!(matches!(classify(503, ""), ApnsResult::Failed(503, _)));
    }

    /// The whole round: JWT to the token endpoint (checked with the key's
    /// public half), the access token on the send, only `s` in the data.
    #[tokio::test]
    async fn a_push_goes_through_googles_two_endpoints() {
        use axum::{Json, Router, extract::State, http::HeaderMap, routing::post};
        use std::sync::Arc;
        #[derive(Default)]
        struct Seen {
            sends: Mutex<Vec<(String, serde_json::Value)>>,
            tokens: Mutex<u32>,
        }
        let seen = Arc::new(Seen::default());
        let key = ring::signature::RsaKeyPair::from_pkcs8(&pem_to_der(TEST_KEY).unwrap()).unwrap();
        let public = key.public().as_ref().to_vec();
        let app = Router::new()
            .route(
                "/token",
                post(move |State(s): State<Arc<Seen>>, body: String| async move {
                    let jwt = body.split("assertion=").nth(1).unwrap().to_string();
                    let (input, sig) = jwt.rsplit_once('.').unwrap();
                    ring::signature::UnparsedPublicKey::new(&ring::signature::RSA_PKCS1_2048_8192_SHA256, &public)
                        .verify(input.as_bytes(), &URL_SAFE_NO_PAD.decode(sig).unwrap())
                        .expect("JWT signed with the service account key");
                    let claims: serde_json::Value =
                        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(input.split('.').nth(1).unwrap()).unwrap()).unwrap();
                    assert_eq!(claims["scope"], SCOPE);
                    *s.tokens.lock().unwrap() += 1;
                    Json(serde_json::json!({ "access_token": "ya29.test", "expires_in": 3599 }))
                }),
            )
            .route(
                "/v1/projects/sinhron-test/messages:send",
                post(|State(s): State<Arc<Seen>>, h: HeaderMap, Json(v): Json<serde_json::Value>| async move {
                    let auth = h["authorization"].to_str().unwrap().to_string();
                    s.sends.lock().unwrap().push((auth, v));
                    Json(serde_json::json!({ "name": "projects/sinhron-test/messages/1" }))
                }),
            )
            .with_state(seen.clone());
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
        let base = format!("http://{addr}");
        let fcm = Fcm::with_host(FcmConfig { account: account(format!("{base}/token")), client: client() }, base).unwrap();
        let sealed = seal(&[1u8; 32], &serde_json::json!({ "t": "msg", "n": 1, "ts": 1 })).unwrap();
        assert_eq!(fcm.send("fcm:tok-1", &sealed).await, ApnsResult::Sent);
        assert_eq!(fcm.send("fcm:tok-2", &sealed).await, ApnsResult::Sent);
        assert_eq!(*seen.tokens.lock().unwrap(), 1, "the access token is reused");
        let sends = seen.sends.lock().unwrap();
        assert_eq!(sends[0].0, "Bearer ya29.test");
        let m = &sends[0].1["message"];
        assert_eq!(m["token"], "tok-1");
        assert_eq!(m["android"]["priority"], "HIGH");
        assert_eq!(m["data"].as_object().unwrap().len(), 1, "nothing but the sealed body");
        assert!(m.get("notification").is_none());
    }
    /// `Instant + Duration` panics on overflow: a token endpoint answering
    /// with a huge `expires_in` must not take the push task down.
    #[tokio::test]
    async fn a_huge_expires_in_does_not_panic() {
        use axum::{Json, Router, routing::post};
        let app = Router::new()
            .route("/token", post(|| async { Json(serde_json::json!({ "access_token": "ya29.test", "expires_in": u64::MAX })) }));
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = l.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(l, app).await.unwrap() });
        let base = format!("http://{addr}");
        let fcm = Fcm::with_host(FcmConfig { account: account(format!("{base}/token")), client: client() }, base).unwrap();
        assert_eq!(fcm.access_token(true).await.unwrap(), "ya29.test");
        assert_eq!(fcm.access_token(false).await.unwrap(), "ya29.test", "kept for reuse");
    }
}
