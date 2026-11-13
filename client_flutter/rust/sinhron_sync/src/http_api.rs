// HTTP client for /v1/keypackages publish + consume — WU C3.
//
// The WS transport (sinhron_net) handles real-time chat traffic.
// KeyPackage management is RPC-shaped (request-response) so it stays
// on HTTP — easier idempotency, easier to debug with curl, doesn't
// need a session.
//
// The wire contracts mirror what `server/src/handlers/keypackages.rs`
// expects, including the timestamped action-proof signing.

use base64::{prelude::BASE64_STANDARD, Engine};
use ed25519_dalek::{Signer, SigningKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::time::Duration;

use tracing::{debug, info, warn};

/// Domain prefix for KeyPackage upload action — MUST match the server's
/// `UPLOAD_KP_DOMAIN`.
const UPLOAD_KP_DOMAIN: &[u8] = b"sinhron-upload-kp-v1";

/// Domain prefix for identity registration — MUST match the server's
/// `REGISTRATION_DOMAIN`.
const REGISTRATION_DOMAIN: &[u8] = b"sinhron-register-v1:";

/// CD6 — domain prefix for POST /v1/call/token. MUST match the
/// server's `CALL_TOKEN_DOMAIN` (server/src/handlers/proof.rs).
const CALL_TOKEN_DOMAIN: &[u8] = b"sinhron-call-token-v1:";

/// CD6 — domain prefix for GET /v1/call/turn. MUST match the
/// server's `CALL_TURN_DOMAIN`.
const CALL_TURN_DOMAIN: &[u8] = b"sinhron-call-turn-v1:";

/// Media upload/download domains — MUST match the server's
/// `MEDIA_UPLOAD_DOMAIN` / `MEDIA_GET_DOMAIN` (handlers/proof.rs).
const MEDIA_UPLOAD_DOMAIN: &[u8] = b"sinhron-media-upload-v1:";
const MEDIA_GET_DOMAIN: &[u8] = b"sinhron-media-get-v1:";
/// ADR-064 — "keep these blobs; which don't you have?" (handlers/proof.rs).
const MEDIA_TOUCH_DOMAIN: &[u8] = b"sinhron-media-touch-v1:";
/// Most hashes in one `POST /v1/media/touch`.
pub const MEDIA_TOUCH_MAX: usize = 256;
/// ADR-023 — mirrors server `PUT_SEALED_KEYS_DOMAIN`.
const PUT_SEALED_KEYS_DOMAIN: &[u8] = b"sinhron-sealed-keys-put-v1:";
/// ADR-071 — mirror of the server's `PUT_ACCESS_KEYS_DOMAIN`.
const PUT_ACCESS_KEYS_DOMAIN: &[u8] = b"sinhron-access-keys-put-v1:";
/// ADR-025 — mirror of server/src/handlers/proof.rs.
const DEVICE_ADD_DOMAIN: &[u8] = b"sinhron-device-add-v1:";
const DEVICE_REVOKE_DOMAIN: &[u8] = b"sinhron-device-revoke-v1:";
/// Tech-debt 2.5 — mirror of server/src/handlers/proof.rs.
const GROUP_RETENTION_DOMAIN: &[u8] = b"sinhron-group-retention-v1:";
/// ADR-035 — mirror of the server's `GROUP_LEAVE_DOMAIN`.
const GROUP_LEAVE_DOMAIN: &[u8] = b"sinhron-group-leave-v1:";
/// ADR-083 — mirrors of the server's `GROUP_ANNOUNCE_DOMAIN` / `GROUP_REMOVE_DOMAIN`.
const GROUP_ANNOUNCE_DOMAIN: &[u8] = b"sinhron-group-announce-v1:";
const GROUP_REMOVE_DOMAIN: &[u8] = b"sinhron-group-remove-v1:";
/// server-http:5 — mirror of the server's `KP_CONSUME_DOMAIN`.
const KP_CONSUME_DOMAIN: &[u8] = b"sinhron-kp-consume-v1:";
/// ADR-075 — a chat's card (MLS GroupInfo) left / fetched by a device.
const GROUP_CARD_PUT_DOMAIN: &[u8] = b"sinhron-group-card-put-v1:";
const GROUP_CARD_GET_DOMAIN: &[u8] = b"sinhron-group-card-get-v1:";
/// ADR-090 — mirror of the server's `BACKUP_MARK_DOMAIN`.
const BACKUP_MARK_DOMAIN: &[u8] = b"sinhron-backup-mark-v1:";

/// ADR-037 — mirrors of the server's `ACCOUNT_DELETE_DOMAIN` / `REPORT_DOMAIN`.
const ACCOUNT_DELETE_DOMAIN: &[u8] = b"sinhron-account-delete-v1:";
const REPORT_DOMAIN: &[u8] = b"sinhron-report-v1:";
const PUSH_TOKEN_DOMAIN: &[u8] = b"sinhron-push-token-v1:";
/// ADR-077 — mirror of the server's `ADMIN_NOTICES_DOMAIN`.
const ADMIN_NOTICES_DOMAIN: &[u8] = b"sinhron-admin-notices-v1:";

/// ADR-077 — one service notice from the server to its administrators.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct AdminNotice {
    pub id: i64,
    /// alert / ok / report.
    pub kind: String,
    pub text: String,
    /// Unix seconds.
    pub ts: i64,
}

/// Overnight item 8 — what a push token's signature covers (mirror of the
/// server's `push_tokens::token_body`).
pub fn push_token_body(
    kind: &str,
    token_hex: &str,
    sandbox: bool,
    lang: &str,
    keys: Option<(&str, &str)>,
    call_hint_key_hex: Option<&str>,
) -> Vec<u8> {
    let mut b = kind.as_bytes().to_vec();
    b.push(0);
    b.extend_from_slice(token_hex.as_bytes());
    b.push(sandbox as u8);
    b.extend_from_slice(lang.as_bytes());
    // ADR-040 — a UnifiedPush endpoint's Web Push keys are signed too.
    if let Some((p256dh, auth)) = keys {
        b.push(0);
        b.extend_from_slice(p256dh.as_bytes());
        b.push(0);
        b.extend_from_slice(auth.as_bytes());
    }
    // ADR-056 — a PushKit token's call hint key.
    if let Some(h) = call_hint_key_hex {
        b.push(1);
        b.extend_from_slice(h.as_bytes());
    }
    b
}

/// ADR-037 — what a report's signature covers (mirror of the server's
/// `report_body`): reported key ‖ reason ‖ 0 ‖ text.
pub fn report_body(reported: &[u8; 32], reason: &str, text: Option<&str>) -> Vec<u8> {
    let mut b = reported.to_vec();
    b.extend_from_slice(reason.as_bytes());
    b.push(0);
    if let Some(t) = text {
        b.extend_from_slice(t.as_bytes());
    }
    b
}
/// Tech-debt 4.2 — mirror of server/src/handlers/proof.rs.
const PAIRING_PUT_DOMAIN: &[u8] = b"sinhron-pairing-put-v1:";

pub struct HttpApi {
    base_url: String,
    /// ADR-086 — the server name every signature is bound to (from
    /// `base_url`, never from a DNS fallback's address).
    host: String,
    client: reqwest::Client,
}

impl HttpApi {
    /// Build an API client. `base_url` should be something like
    /// `http://localhost:8080` or `https://cabin.sinhron.app` — the
    /// per-endpoint path is appended internally. Uses webpki-roots
    /// trust store (default reqwest rustls behavior).
    pub fn new(base_url: String) -> Self {
        sinhron_net::dns::global().add_our_host(&base_url);
        Self {
            host: sinhron_net::url_host(&base_url),
            base_url,
            client: with_proxy(reqwest::Client::builder()).build().unwrap_or_else(|_| reqwest::Client::new()),
        }
    }

    /// The configured base URL (raw requests, e.g. Telegram sticker import).
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// ADR-086 — the server name this API's signatures are bound to.
    pub fn host(&self) -> &str {
        &self.host
    }

    /// The inner reqwest::Client, for raw requests (Telegram sticker
    /// import). Other endpoints use the typed methods on HttpApi.
    pub fn client(&self) -> &reqwest::Client {
        &self.client
    }

    /// Build an HTTP client that pins TLS to the supplied operator CA
    /// (WU B3 — spec §6.1). Any cert chain that doesn't terminate at
    /// `tls_pinning`'s CA — including normally-trusted public CAs —
    /// fails the handshake.
    ///
    /// The `TlsPinning` is shared with the WS client (sinhron_net),
    /// so a single bundled `operator_ca.pem` enforces a single trust
    /// boundary across both transports.
    ///
    /// Panics if the underlying reqwest builder rejects the rustls
    /// config (e.g. an incompatible rustls major version) — this is
    /// developer-error rather than runtime input.
    pub fn new_pinned(base_url: String, tls_pinning: &sinhron_net::TlsPinning) -> Self {
        // reqwest takes an owned `rustls::ClientConfig`; clone the
        // value out of the Arc the pinning struct holds.
        sinhron_net::dns::global().add_our_host(&base_url);
        let cfg = (*tls_pinning.client_config()).clone();
        let client = with_proxy(reqwest::Client::builder())
            .use_preconfigured_tls(cfg)
            .build()
            .expect("reqwest accepts rustls::ClientConfig of matching major version");
        Self {
            host: sinhron_net::url_host(&base_url),
            base_url,
            client,
        }
    }

    /// POST /v1/identity — register this device's identity with the
    /// server. Signs the `sinhron-register-v1:` self-proof with the
    /// identity seed. For Sinhron v1 we treat the identity key AS the
    /// device credential (single-device per-user), so `device_seed` is
    /// the same as `identity_seed`.
    ///
    /// Idempotent on server side: replays return `already_existed: true`.
    pub async fn register_identity(
        &self,
        identity_seed: [u8; 32],
    ) -> Result<RegisterOutcome, HttpError> {
        let sk = SigningKey::from_bytes(&identity_seed);
        let pk = sk.verifying_key().to_bytes();

        // Registration proof: sign "sinhron-register-v1:" || pubkey
        let mut msg = Vec::with_capacity(REGISTRATION_DOMAIN.len() + 32);
        msg.extend_from_slice(REGISTRATION_DOMAIN);
        msg.extend_from_slice(&pk);
        let sig = sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes();

        let req_body = RegisterRequest {
            identity_pubkey_hex: hex::encode(pk),
            registration_proof_hex: hex::encode(sig),
            primary_device: Some(PrimaryDevice {
                device_pk_hex: hex::encode(pk),
                // For single-device users the credential bytes ARE the
                // device pubkey (32 bytes). Multi-device split (separate
                // per-device credential key) lands in §6.5 work.
                device_credential_hex: hex::encode(pk),
            }),
        };

        let resp = self
            .client
            .post(format!("{}/v1/identity", self.base_url))
            .json(&req_body)
            .send()
            .await
            .map_err(transport)?;

        // Risk #4 — capture server's `Date:` header for clock-drift
        // correction. Best-effort; no-op if header absent/unparseable.
        record_drift_from_response(&resp);

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server {
                status: status.as_u16(),
                body: text,
            });
        }
        let parsed: RegisterResponse =
            serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        info!(
            user_pk = %parsed.user_pk,
            already_existed = parsed.already_existed,
            "identity registered"
        );
        Ok(RegisterOutcome {
            user_pk: parsed.user_pk,
            already_existed: parsed.already_existed,
            identity_pubkey_hex: hex::encode(pk),
        })
    }

    /// POST /v1/keypackages — uploads a fresh KP for the device
    /// identified by `device_seed`. Signs the action proof using the
    /// device's credential key (same seed as the WS auth signer).
    /// Returns the server-assigned keypackage_id.
    pub async fn publish_keypackage(
        &self,
        device_seed: [u8; 32],
        kp_bytes: &[u8],
    ) -> Result<String, HttpError> {
        let sk = SigningKey::from_bytes(&device_seed);
        let device_pk = sk.verifying_key().to_bytes();

        // Risk #4 — use the drift-corrected clock (server's view of
        // time) when computing the action-proof timestamp. Falls back
        // to raw local time if no measurement landed yet; subsequent
        // Date-header capture (see `record_drift_from_response`) will
        // self-correct future calls.
        let ts = sinhron_net::clock_drift::corrected_now_secs();

        let body_hash = sha256(kp_bytes);
        let mut msg = Vec::new();
        msg.extend_from_slice(UPLOAD_KP_DOMAIN);
        msg.push(b':');
        msg.extend_from_slice(&body_hash);
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        let sig = sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes();

        let req_body = UploadRequest {
            device_pk_hex: hex::encode(device_pk),
            kp_bytes_b64: BASE64_STANDARD.encode(kp_bytes),
            upload_proof_ts: ts,
            upload_proof_hex: hex::encode(sig),
        };

        let resp = self
            .client
            .post(format!("{}/v1/keypackages", self.base_url))
            .json(&req_body)
            .send()
            .await
            .map_err(transport)?;

        // Risk #4 — capture server's `Date:` header for clock-drift
        // correction. Best-effort; no-op if header absent/unparseable.
        record_drift_from_response(&resp);

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server {
                status: status.as_u16(),
                body: text,
            });
        }
        let parsed: UploadResponse =
            serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        info!(
            keypackage_id = %parsed.keypackage_id,
            device = %req_body.device_pk_hex,
            "kp published"
        );
        Ok(parsed.keypackage_id)
    }

    /// POST /v1/groups — tell the server which devices are in a chat (its
    /// fan-out, card and call room): a new chat, or devices just added.
    /// ADR-083 — signed by this device ([device_seed]: the key behind its
    /// leaf, `login_seed_bytes`), which the server takes only from a device
    /// of someone already in the chat. Idempotent on the server.
    /// ADR-090 — [epoch]: the chat's MLS epoch here; a new chat's Commits
    /// are ordered from it (the server ignores it for a chat it has).
    pub async fn announce_group(
        &self,
        device_seed: [u8; 32],
        group_id: &[u8],
        epoch: u64,
        member_device_pks: &[Vec<u8>],
    ) -> Result<(), HttpError> {
        let mut signed = group_id.to_vec();
        signed.extend_from_slice(&epoch.to_be_bytes());
        member_device_pks.iter().for_each(|d| signed.extend_from_slice(d));
        let (creator_hex, proof_ts, proof_hex) = action_proof(&self.host, device_seed, GROUP_ANNOUNCE_DOMAIN, &signed);
        let body = CreateGroupRequest {
            group_id_hex: hex::encode(group_id),
            creator_device_pk_hex: creator_hex,
            member_device_pks_hex: member_device_pks.iter().map(hex::encode).collect(),
            epoch,
            proof_ts,
            proof_hex,
        };

        let resp = self
            .client
            .post(format!("{}/v1/groups", self.base_url))
            .json(&body)
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server {
                status: status.as_u16(),
                body: text,
            });
        }
        info!(
            group = %hex::encode(group_id),
            members = member_device_pks.len(),
            "group announced to server"
        );
        Ok(())
    }

    /// Tech-debt 2.34 — who of [identities_hex] has no KeyPackage on any
    /// device; consumes nothing. `None` from a server that predates the
    /// endpoint (404) — the caller goes on as before.
    pub async fn keypackages_missing(&self, identities_hex: &[String]) -> Result<Option<Vec<String>>, HttpError> {
        #[derive(serde::Deserialize)]
        struct Reply {
            missing: Vec<String>,
        }
        let url = format!("{}/v1/keypackages/available?identities={}", self.base_url, identities_hex.join(","));
        let resp = self.client.get(url).send().await.map_err(transport)?;
        let status = resp.status();
        if status.as_u16() == 404 {
            return Ok(None);
        }
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let r: Reply = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(Some(r.missing))
    }

    /// ADR-025 — GET /v1/keypackages/consume?per_device=true: one
    /// KeyPackage from each of the person's active devices →
    /// `(device_pk, kp_bytes)`. Inviting a person = adding all of these.
    /// `only` (device keys) limits it to those devices — device sync adds
    /// just the missing ones without burning everyone's KeyPackages.
    /// server-http:5 — signed by [signer_seed] (the login key: identity on
    /// the first device, the device key on a linked one) over the target.
    pub async fn fetch_device_keypackages(
        &self,
        signer_seed: [u8; 32],
        identity_pubkey_hex: &str,
        only: &[Vec<u8>],
    ) -> Result<Vec<(Vec<u8>, Vec<u8>)>, HttpError> {
        let target = hex::decode(identity_pubkey_hex).map_err(|e| HttpError::Parse(format!("identity: {e}")))?;
        let (signer, ts, sig) = action_proof(&self.host, signer_seed, KP_CONSUME_DOMAIN, &target);
        let mut url = format!(
            "{}/v1/keypackages/consume?identity_pubkey_hex={}&per_device=true&signer_pk_hex={signer}&proof_ts={ts}&proof_hex={sig}",
            self.base_url, identity_pubkey_hex
        );
        if !only.is_empty() {
            url.push_str("&devices=");
            url.push_str(&only.iter().map(hex::encode).collect::<Vec<_>>().join(","));
        }
        let resp = self
            .client
            .get(url)
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let parsed: Vec<ConsumeItem> = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        if parsed.is_empty() {
            return Err(HttpError::Empty("no keypackage available".to_string()));
        }
        parsed
            .into_iter()
            .map(|i| {
                let pk = hex::decode(&i.device_pk_hex).map_err(|e| HttpError::Parse(format!("device_pk_hex: {e}")))?;
                let kp = BASE64_STANDARD.decode(&i.kp_bytes_b64).map_err(|e| HttpError::Parse(format!("kp_bytes_b64: {e}")))?;
                Ok((pk, kp))
            })
            .collect()
    }

    /// ADR-025 — POST /v1/devices: this (linked) device registers itself
    /// with its identity-signed certificate, proving it holds `device_seed`.
    pub async fn register_device(&self, device_seed: [u8; 32], certificate: &[u8]) -> Result<(), HttpError> {
        let (_, ts, sig) = action_proof(&self.host, device_seed, DEVICE_ADD_DOMAIN, certificate);
        let req = serde_json::json!({
            "certificate_hex": hex::encode(certificate),
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .post(format!("{}/v1/devices", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        info!("linked device registered");
        Ok(())
    }

    /// ADR-025 — GET /v1/devices: the person's active devices.
    pub async fn list_devices(&self, identity_pubkey_hex: &str) -> Result<Vec<DeviceInfo>, HttpError> {
        #[derive(serde::Deserialize)]
        struct Resp {
            devices: Vec<DeviceInfo>,
        }
        let resp = self
            .client
            .get(format!("{}/v1/devices?identity_pubkey_hex={}", self.base_url, identity_pubkey_hex))
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let parsed: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(parsed.devices)
    }

    /// ADR-075 — GET /v1/devices?revoked=1: active devices and the revoked
    /// ones with the identity key's signature over their revocation
    /// ([`revocation_is_signed`] checks it). An older server lists active
    /// ones only.
    pub async fn list_devices_with_revoked(&self, identity_pubkey_hex: &str) -> Result<Vec<DeviceInfo>, HttpError> {
        #[derive(serde::Deserialize)]
        struct Resp {
            devices: Vec<DeviceInfo>,
        }
        let resp = self
            .client
            .get(format!("{}/v1/devices?identity_pubkey_hex={}&revoked=1", self.base_url, identity_pubkey_hex))
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let parsed: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(parsed.devices)
    }

    /// ADR-075 — PUT /v1/groups/{id}/card: leave the chat's card (its MLS
    /// GroupInfo at [epoch]), signed by this device's key ([device_seed]:
    /// the key behind its leaf / `devices.device_pk`).
    pub async fn put_group_card(&self, device_seed: [u8; 32], group_id: &[u8], epoch: u64, card: &[u8]) -> Result<(), HttpError> {
        use base64::Engine;
        let mut body = group_id.to_vec();
        body.extend_from_slice(&(epoch as i64).to_be_bytes());
        body.extend_from_slice(card);
        let (device_hex, ts, sig) = action_proof(&self.host, device_seed, GROUP_CARD_PUT_DOMAIN, &body);
        let req = serde_json::json!({
            "device_pk_hex": device_hex,
            "epoch": epoch as i64,
            "card_b64": base64::engine::general_purpose::STANDARD.encode(card),
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .put(format!("{}/v1/groups/{}/card", self.base_url, hex::encode(group_id)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// ADR-090 (storage-devices:14) — POST /v1/backup-mark: tell the server a
    /// backup made at [created_ts] is in [cloud] (0: only ask), and hear the
    /// newest one it knows of for this account there (0: none).
    pub async fn backup_mark(&self, device_seed: [u8; 32], cloud: &str, created_ts: i64) -> Result<i64, HttpError> {
        #[derive(serde::Deserialize)]
        struct Resp {
            created_ts: i64,
        }
        let mut body = cloud.as_bytes().to_vec();
        body.extend_from_slice(&created_ts.to_be_bytes());
        let (device_hex, ts, sig) = action_proof(&self.host, device_seed, BACKUP_MARK_DOMAIN, &body);
        let req = serde_json::json!({
            "device_pk_hex": device_hex,
            "cloud": cloud,
            "created_ts": created_ts,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .post(format!("{}/v1/backup-mark", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(r.created_ts)
    }

    /// ADR-075 — POST /v1/groups/{id}/card: the chat's cards for a device of
    /// a person who is (or whose cut-off device was) in it. ADR-093 — one per
    /// active device still in the chat, newest epoch first, with its person
    /// ([`card_choice::cards_to_try`](crate::card_choice::cards_to_try)).
    /// Empty: no card yet.
    pub async fn get_group_cards(
        &self,
        device_seed: [u8; 32],
        group_id: &[u8],
    ) -> Result<Vec<crate::card_choice::CardFromServer>, HttpError> {
        use base64::Engine;
        #[derive(serde::Deserialize)]
        struct Card {
            epoch: i64,
            card_b64: String,
            identity_hex: String,
        }
        #[derive(serde::Deserialize)]
        struct Resp {
            cards: Vec<Card>,
        }
        let (device_hex, ts, sig) = action_proof(&self.host, device_seed, GROUP_CARD_GET_DOMAIN, group_id);
        let req = serde_json::json!({ "device_pk_hex": device_hex, "proof_ts": ts, "proof_hex": sig });
        let resp = self
            .client
            .post(format!("{}/v1/groups/{}/card", self.base_url, hex::encode(group_id)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if status.as_u16() == 404 {
            return Ok(Vec::new());
        }
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        r.cards
            .into_iter()
            .map(|c| {
                let card = base64::engine::general_purpose::STANDARD.decode(c.card_b64).map_err(|e| HttpError::Parse(e.to_string()))?;
                let identity = hex::decode(&c.identity_hex)
                    .ok()
                    .and_then(|v| <[u8; 32]>::try_from(v).ok())
                    .ok_or_else(|| HttpError::Parse("identity_hex".into()))?;
                Ok(crate::card_choice::CardFromServer { epoch: c.epoch.max(0) as u64, card, identity })
            })
            .collect()
    }

    /// ADR-025 — DELETE /v1/devices/{pk}: revoke a linked device (signed by
    /// the identity key). The server drops its KeyPackages and group rows;
    /// removing it from each MLS group is the caller's Commit.
    pub async fn revoke_device(&self, identity_seed: [u8; 32], device_pk: &[u8]) -> Result<(), HttpError> {
        let (identity_hex, ts, sig) = action_proof(&self.host, identity_seed, DEVICE_REVOKE_DOMAIN, device_pk);
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .delete(format!("{}/v1/devices/{}", self.base_url, hex::encode(device_pk)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// Tech-debt 4.2 — PUT /v1/pairing/{id}: leave the sealed account
    /// secret for a new device (signed by our identity key).
    pub async fn put_pairing(&self, identity_seed: [u8; 32], id: &[u8; 16], sealed: &[u8]) -> Result<(), HttpError> {
        let mut body = id.to_vec();
        body.extend_from_slice(sealed);
        let (identity_hex, ts, sig) = action_proof(&self.host, identity_seed, PAIRING_PUT_DOMAIN, &body);
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "ciphertext_b64": BASE64_STANDARD.encode(sealed),
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .put(format!("{}/v1/pairing/{}", self.base_url, hex::encode(id)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// Tech-debt 4.2 — GET /v1/pairing/{id}: take what the other device
    /// left (once). `None` while nothing is there yet.
    pub async fn take_pairing(&self, id: &[u8; 16]) -> Result<Option<Vec<u8>>, HttpError> {
        #[derive(serde::Deserialize)]
        struct Resp {
            ciphertext_b64: String,
        }
        let resp = self
            .client
            .get(format!("{}/v1/pairing/{}", self.base_url, hex::encode(id)))
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        if status.as_u16() == 404 {
            return Ok(None);
        }
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        BASE64_STANDARD.decode(r.ciphertext_b64).map(Some).map_err(|e| HttpError::Parse(e.to_string()))
    }

    /// ADR-043 (short links) — POST /v1/invites: leave a sealed invite under
    /// `id` (no account: the invite isn't tied to one). 409: the id is taken.
    /// At most 6 s — the Share sheet waits on it (then the long link goes).
    pub async fn put_short_invite(&self, id: &str, blob: &[u8]) -> Result<(), HttpError> {
        let req = serde_json::json!({ "id": id, "blob_b64": BASE64_STANDARD.encode(blob) });
        let resp = self
            .client
            .post(format!("{}/v1/invites", self.base_url))
            .timeout(Duration::from_secs(6))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// GET /v1/invites/{id} — the sealed invite; `None`: gone or never was.
    pub async fn get_short_invite(&self, id: &str) -> Result<Option<Vec<u8>>, HttpError> {
        #[derive(serde::Deserialize)]
        struct Resp {
            blob_b64: String,
        }
        let mut resp = self
            .client
            .get(format!("{}/v1/invites/{id}", self.base_url))
            .timeout(Duration::from_secs(20))
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        if status.as_u16() == 404 {
            return Ok(None);
        }
        // A real answer is a few KB: a host that streams more is cut off
        // (security-review-2026-11 app-surface:3).
        let mut body = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(transport)? {
            body.extend_from_slice(&chunk);
            if body.len() > 4 * crate::invite::SHORT_BLOB_MAX {
                return Err(HttpError::Parse("invite answer too large".into()));
            }
        }
        let text = String::from_utf8_lossy(&body).into_owned();
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        BASE64_STANDARD.decode(r.blob_b64).map(Some).map_err(|e| HttpError::Parse(e.to_string()))
    }

    /// Tech-debt 2.5 — PUT /v1/groups/{id}/retention: how long the server
    /// keeps this chat's stored ciphertexts (0 = its global default).
    pub async fn set_group_retention(&self, identity_seed: [u8; 32], group_id: &[u8], after_secs: i64) -> Result<(), HttpError> {
        let mut body = group_id.to_vec();
        body.extend_from_slice(&after_secs.to_be_bytes());
        let (identity_hex, ts, sig) = action_proof(&self.host, identity_seed, GROUP_RETENTION_DOMAIN, &body);
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "after_secs": after_secs,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .put(format!("{}/v1/groups/{}/retention", self.base_url, hex::encode(group_id)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// ADR-035 — POST /v1/groups/{id}/leave: stop receiving this group's
    /// messages (after leaving, or after the group removed me). Signed body
    /// = group_id.
    pub async fn leave_group(&self, identity_seed: [u8; 32], group_id: &[u8]) -> Result<(), HttpError> {
        let (identity_hex, ts, sig) = action_proof(&self.host, identity_seed, GROUP_LEAVE_DOMAIN, group_id);
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .post(format!("{}/v1/groups/{}/leave", self.base_url, hex::encode(group_id)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// ADR-083 — POST /v1/groups/{id}/remove: after my Commit removed these
    /// people, the server stops sending them the chat (and takes them out
    /// of its call room). Signed body = group_id || each identity key. An
    /// older server without the route: Ok (it keeps them, as before).
    pub async fn remove_group_members(&self, identity_seed: [u8; 32], group_id: &[u8], people: &[[u8; 32]]) -> Result<(), HttpError> {
        let mut signed = group_id.to_vec();
        people.iter().for_each(|p| signed.extend_from_slice(p));
        let (identity_hex, ts, sig) = action_proof(&self.host, identity_seed, GROUP_REMOVE_DOMAIN, &signed);
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "member_identities_hex": people.iter().map(hex::encode).collect::<Vec<_>>(),
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .post(format!("{}/v1/groups/{}/remove", self.base_url, hex::encode(group_id)))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() && status.as_u16() != 404 && status.as_u16() != 405 {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// ADR-037 — POST /v1/account/delete: remove this person from the
    /// server. Signed with the identity key itself over the identity key.
    pub async fn delete_account(&self, identity_seed: [u8; 32]) -> Result<(), HttpError> {
        let pubkey = ed25519_dalek::SigningKey::from_bytes(&identity_seed).verifying_key().to_bytes();
        let (identity_hex, ts, sig) = action_proof(&self.host, identity_seed, ACCOUNT_DELETE_DOMAIN, &pubkey);
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        self.post_signed("/v1/account/delete", &req).await
    }

    /// ADR-037 — POST /v1/reports: tell the operator about someone. The
    /// message text goes only when the reporter chose to share it.
    pub async fn report(
        &self,
        signer_seed: [u8; 32],
        reported_identity: &[u8; 32],
        reason: &str,
        message_text: Option<&str>,
    ) -> Result<(), HttpError> {
        let (identity_hex, ts, sig) =
            action_proof(&self.host, signer_seed, REPORT_DOMAIN, &report_body(reported_identity, reason, message_text));
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "reported_identity_hex": hex::encode(reported_identity),
            "reason": reason,
            "message_text": message_text,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        self.post_signed("/v1/reports", &req).await
    }

    /// ADR-077 — POST /v1/admin/notices: the server's service notices after
    /// `after_id`, oldest first. `None` when this person isn't one of the
    /// server's administrators (403) or the server is older (404).
    pub async fn admin_notices(
        &self,
        signer_seed: [u8; 32],
        after_id: i64,
    ) -> Result<Option<Vec<AdminNotice>>, HttpError> {
        #[derive(Deserialize)]
        struct Resp {
            notices: Vec<AdminNotice>,
        }
        let (identity_hex, ts, sig) = action_proof(&self.host, signer_seed, ADMIN_NOTICES_DOMAIN, after_id.to_string().as_bytes());
        let req = serde_json::json!({
            "identity_pubkey_hex": identity_hex,
            "after_id": after_id,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        let resp = self
            .client
            .post(format!("{}/v1/admin/notices", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if status == reqwest::StatusCode::FORBIDDEN || status == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        let r: Resp = resp.json().await.map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(Some(r.notices))
    }

    /// Overnight item 8 — PUT /v1/push-token: this device's APNs token
    /// (`kind` alert / voip; empty token = remove). Signed by the device's
    /// own login key.
    pub async fn put_push_token(
        &self,
        device_seed: [u8; 32],
        kind: &str,
        token_hex: &str,
        sandbox: bool,
        lang: &str,
        keys: Option<(&str, &str)>,
        call_hint_key_hex: Option<&str>,
    ) -> Result<(), HttpError> {
        let body = push_token_body(kind, token_hex, sandbox, lang, keys, call_hint_key_hex);
        let (device_hex, ts, sig) = action_proof(&self.host, device_seed, PUSH_TOKEN_DOMAIN, &body);
        let mut req = serde_json::json!({
            "device_pk_hex": device_hex,
            "kind": kind,
            "token_hex": token_hex,
            "sandbox": sandbox,
            "lang": lang,
            "proof_ts": ts,
            "proof_hex": sig,
        });
        if let Some((p256dh, auth)) = keys {
            req["p256dh"] = p256dh.into();
            req["auth"] = auth.into();
        }
        if let Some(h) = call_hint_key_hex {
            req["call_hint_key_hex"] = h.into();
        }
        let resp = self
            .client
            .put(format!("{}/v1/push-token", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    async fn post_signed(&self, path: &str, req: &serde_json::Value) -> Result<(), HttpError> {
        let resp = self
            .client
            .post(format!("{}{}", self.base_url, path))
            .json(req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        Ok(())
    }

    /// ADR-023 — PUT /v1/sealed-keys: publish this device's delivery keys
    /// (`(week, public)` pairs). Signed body = week_be4 || public, in order.
    /// Tech-debt 2.2: `access_hash` = SHA-256 of our access key, signed
    /// after the keys. ADR-082: each key also carries its owner's
    /// signature (`sealed::sign_delivery_key`); `cert` = this device's
    /// certificate when `identity_seed` is a linked device's own key.
    pub async fn publish_sealed_keys(
        &self,
        identity_seed: [u8; 32],
        keys: &[(u32, Vec<u8>)],
        access: Option<([u8; 32], u32)>,
        cert: Option<&[u8]>,
    ) -> Result<u32, HttpError> {
        let sk = SigningKey::from_bytes(&identity_seed);
        let identity =
            cert.and_then(crate::identity::device_of_certificate).map_or(sk.verifying_key().to_bytes(), |(id, _)| id);
        let ts = sinhron_net::clock_drift::corrected_now_secs();
        let mut body = Vec::with_capacity(keys.len() * 36 + 32);
        for (w, pk) in keys {
            body.extend_from_slice(&(*w as i32).to_be_bytes());
            body.extend_from_slice(pk);
        }
        if let Some((h, v)) = access {
            body.extend_from_slice(&h);
            body.extend_from_slice(&(v as i32).to_be_bytes());
        }
        let mut msg = Vec::new();
        msg.extend_from_slice(PUT_SEALED_KEYS_DOMAIN);
        msg.push(b':');
        msg.extend_from_slice(&sha256(&body));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        let req = serde_json::json!({
            "identity_pubkey_hex": hex::encode(sk.verifying_key().to_bytes()),
            "keys": keys.iter().map(|(w, pk)| serde_json::json!({
                "week": *w as i32,
                "public_hex": hex::encode(pk),
                "sig_hex": hex::encode(crate::sealed::sign_delivery_key(&identity_seed, &identity, *w, pk)),
            })).collect::<Vec<_>>(),
            "cert_hex": cert.map(hex::encode),
            "access_hash_hex": access.map(|(h, _)| hex::encode(h)),
            "access_version": access.map(|(_, v)| v as i32).unwrap_or(0),
            "proof_ts": ts,
            "proof_hex": hex::encode(sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes()),
        });
        let resp = self
            .client
            .put(format!("{}/v1/sealed-keys", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        // The server's current access-key version (another of our devices
        // may have rotated it).
        #[derive(serde::Deserialize)]
        struct Resp {
            #[serde(default)]
            access_version: i32,
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(r.access_version.max(0) as u32)
    }

    /// ADR-071 — `PUT /v1/access-keys`: hashes of the per-contact access
    /// keys we hand out ([adds]; never lifts a block) and block / unblock
    /// decisions `(hash, revoked, at_ms)` — the later decision wins on the
    /// server. Returns the server's access-key version: higher than
    /// [version] means another of our devices rotated, and nothing changed.
    /// A server without the route answers 404 (`HttpError::Server`).
    pub async fn publish_access_keys(
        &self,
        identity_seed: [u8; 32],
        version: u32,
        adds: &[[u8; 32]],
        decisions: &[([u8; 32], bool, i64)],
    ) -> Result<u32, HttpError> {
        let sk = SigningKey::from_bytes(&identity_seed);
        let ts = sinhron_net::clock_drift::corrected_now_secs();
        let msg = access_keys_proof_message(version as i32, adds, decisions, ts);
        let req = serde_json::json!({
            "identity_pubkey_hex": hex::encode(sk.verifying_key().to_bytes()),
            "access_version": version as i32,
            "add_hex": adds.iter().map(hex::encode).collect::<Vec<_>>(),
            "decisions": decisions
                .iter()
                .map(|(h, revoked, at)| serde_json::json!({"hash_hex": hex::encode(h), "revoked": revoked, "at_ms": at}))
                .collect::<Vec<_>>(),
            "proof_ts": ts,
            "proof_hex": hex::encode(sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes()),
        });
        let resp = self
            .client
            .put(format!("{}/v1/access-keys", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        #[derive(serde::Deserialize)]
        struct Resp {
            access_version: i32,
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(r.access_version.max(0) as u32)
    }

    /// Tech-debt 2.2 — POST /v1/sealed with NO authentication: each item
    /// is `(key_id, envelope, recipient access key)`. A fresh HTTP client
    /// per call, so the request shares no connection with our signed
    /// ones. Returns `(accepted, refused)`.
    pub async fn submit_sealed_anonymous(
        &self,
        message_id: &str,
        items: &[([u8; 16], Vec<u8>, Vec<u8>)],
        ttl_secs: u32,
        urgent: &[bool],
        previews: &[Option<Vec<u8>>],
        drop_after_secs: u32,
    ) -> Result<(usize, usize), HttpError> {
        #[derive(serde::Deserialize)]
        struct Resp {
            accepted: usize,
            refused: usize,
        }
        let req = serde_json::json!({
            "message_id": message_id,
            "deliveries": items.iter().enumerate().map(|(i, (k, env, access))| {
                let mut d = serde_json::json!({
                    "key_id_hex": hex::encode(k),
                    "envelope_b64": BASE64_STANDARD.encode(env),
                    "access_key_hex": hex::encode(access),
                    "ttl_secs": ttl_secs,
                    "urgent": urgent.get(i).copied().unwrap_or(false),
                });
                // ADR-056 — the sealed notification preview.
                if let Some(Some(p)) = previews.get(i) {
                    d["push_preview_b64"] = BASE64_STANDARD.encode(p).into();
                }
                // Tech-debt 2.53 — an older server ignores the key.
                if drop_after_secs > 0 {
                    d["drop_after_secs"] = drop_after_secs.into();
                }
                d
            }).collect::<Vec<_>>(),
        });
        let client = with_proxy(reqwest::Client::builder())
            .pool_max_idle_per_host(0)
            .build()
            .map_err(transport)?;
        let resp = client
            .post(format!("{}/v1/sealed", self.base_url))
            .json(&req)
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let r: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok((r.accepted, r.refused))
    }

    /// ADR-023 — GET /v1/sealed-keys: current delivery keys of these
    /// identities → `(identity_hex, week, public, signed)`. ADR-082:
    /// `signed` = that identity (or its certified device) signed the key;
    /// an unsigned one (old app, or a key the server swapped in) gets no
    /// notification preview.
    pub async fn fetch_sealed_keys(&self, identities_hex: &[String]) -> Result<Vec<(String, u32, Vec<u8>, bool)>, HttpError> {
        #[derive(serde::Deserialize)]
        struct Key {
            identity_pubkey_hex: String,
            week: i32,
            public_hex: String,
            #[serde(default)]
            sig_hex: Option<String>,
            #[serde(default)]
            cert_hex: Option<String>,
        }
        #[derive(serde::Deserialize)]
        struct Resp {
            keys: Vec<Key>,
        }
        let resp = self
            .client
            .get(format!("{}/v1/sealed-keys?identities={}", self.base_url, identities_hex.join(",")))
            .send()
            .await
            .map_err(transport)?;
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let parsed: Resp = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        parsed
            .keys
            .into_iter()
            .map(|k| {
                let pk = hex::decode(&k.public_hex).map_err(|e| HttpError::Parse(e.to_string()))?;
                let week = k.week.max(0) as u32;
                let id = <[u8; 32]>::try_from(hex::decode(&k.identity_pubkey_hex).unwrap_or_default());
                let signed = match (&k.sig_hex, id) {
                    (Some(sig), Ok(id)) => {
                        let cert = k.cert_hex.as_deref().map(|c| hex::decode(c).unwrap_or_default());
                        let sig = hex::decode(sig).unwrap_or_default();
                        let ok = crate::sealed::delivery_key_signed(&id, week, &pk, &sig, cert.as_deref());
                        if !ok {
                            warn!(identity = %k.identity_pubkey_hex, week, "delivery key with a bad signature: no preview");
                        }
                        ok
                    }
                    _ => false,
                };
                Ok((k.identity_pubkey_hex, week, pk, signed))
            })
            .collect()
    }

    /// CD6 — mint a LiveKit join token for a specific call.
    ///
    /// `identity_seed` is the user's Ed25519 identity-signing key.
    /// `group_id_hex` identifies the MLS group of the call. `kind` is
    /// either `"audio"` or `"video"`.
    ///
    /// Server validates the action proof + caller's group membership +
    /// 1:1ness, then returns a JWT signed with LIVEKIT_API_SECRET. The
    /// token has roomJoin / canPublish / canSubscribe granted for the
    /// canonical room name `sinhron-call-<group_id_hex>`.
    pub async fn request_livekit_token(
        &self,
        identity_seed: [u8; 32],
        group_id_hex: &str,
        kind: &str,
    ) -> Result<LivekitTokenResponse, HttpError> {
        let sk = SigningKey::from_bytes(&identity_seed);
        let identity_pk_hex = hex::encode(sk.verifying_key().to_bytes());
        let ts = sinhron_net::clock_drift::corrected_now_secs();

        // Action-proof body matches what server expects:
        // "<group_id_hex>:<kind>" (e.g. "abc:video"). The server
        // verifies sha256(body) appears verbatim in the signed message.
        let body = format!("{group_id_hex}:{kind}");
        let body_hash = sha256(body.as_bytes());

        let mut msg = Vec::new();
        msg.extend_from_slice(CALL_TOKEN_DOMAIN);
        msg.push(b':');
        msg.extend_from_slice(&body_hash);
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        let sig = sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes();

        let req_body = TokenRequest {
            identity_pubkey_hex: identity_pk_hex.clone(),
            group_id_hex: group_id_hex.to_string(),
            kind: kind.to_string(),
            request_ts: ts,
            request_proof_hex: hex::encode(sig),
        };

        let resp = self
            .client
            .post(format!("{}/v1/call/token", self.base_url))
            .json(&req_body)
            .send()
            .await
            .map_err(transport)?;

        record_drift_from_response(&resp);

        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server {
                status: status.as_u16(),
                body: text,
            });
        }
        let parsed: LivekitTokenResponse =
            serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        info!(
            room = %parsed.room,
            ttl = parsed.ttl_secs,
            "livekit token minted"
        );
        Ok(parsed)
    }

    /// Is anyone in this group's call right now? (`POST /v1/call/live`,
    /// LiveKit's own count.) A CallEnd reaches only devices online at that
    /// moment, so a phone that slept kept offering "Join" (owner,
    /// 2026-10-18). Older servers answer 404 — the caller keeps its guess.
    pub async fn request_call_live(&self, identity_seed: [u8; 32], group_id_hex: &str) -> Result<bool, HttpError> {
        let sk = SigningKey::from_bytes(&identity_seed);
        let ts = sinhron_net::clock_drift::corrected_now_secs();
        let body_hash = sha256(format!("{group_id_hex}:live").as_bytes());
        let mut msg = Vec::new();
        msg.extend_from_slice(CALL_TOKEN_DOMAIN);
        msg.push(b':');
        msg.extend_from_slice(&body_hash);
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        let req_body = LiveRequest {
            identity_pubkey_hex: hex::encode(sk.verifying_key().to_bytes()),
            group_id_hex: group_id_hex.to_string(),
            request_ts: ts,
            request_proof_hex: hex::encode(sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes()),
        };
        let resp = self
            .client
            .post(format!("{}/v1/call/live", self.base_url))
            .json(&req_body)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        let text = resp.text().await.map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server { status: status.as_u16(), body: text });
        }
        let parsed: LiveResponse = serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(parsed.live)
    }

    /// CD6 — request a TURN credential per RFC 5766 REST-API. Server
    /// returns a short-lived (`ttl_secs`) HMAC-SHA1 cred that the
    /// LiveKit WebRTC client uses as iceServers.
    pub async fn request_turn_creds(
        &self,
        identity_seed: [u8; 32],
    ) -> Result<TurnResponse, HttpError> {
        let sk = SigningKey::from_bytes(&identity_seed);
        let identity_pk_hex = hex::encode(sk.verifying_key().to_bytes());
        let ts = sinhron_net::clock_drift::corrected_now_secs();

        // Body is just the identity hex — TURN creds aren't bound to a
        // specific group, they're general-purpose ICE relay tokens.
        let body_hash = sha256(identity_pk_hex.as_bytes());

        let mut msg = Vec::new();
        msg.extend_from_slice(CALL_TURN_DOMAIN);
        msg.push(b':');
        msg.extend_from_slice(&body_hash);
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        let sig = sk.sign(&sinhron_net::bind_to_host(&self.host, &msg)).to_bytes();

        // Query params per server-side GET handler — no JSON body for
        // a read-style endpoint.
        let url = format!(
            "{}/v1/call/turn?identity_pubkey_hex={}&request_ts={}&request_proof_hex={}",
            self.base_url,
            identity_pk_hex,
            ts,
            hex::encode(sig),
        );
        let resp = self
            .client
            .get(&url)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(transport)?;
        if !status.is_success() {
            return Err(HttpError::Server {
                status: status.as_u16(),
                body: text,
            });
        }
        let parsed: TurnResponse =
            serde_json::from_str(&text).map_err(|e| HttpError::Parse(e.to_string()))?;
        debug!(urls = ?parsed.urls, ttl = parsed.ttl_secs, "turn creds minted");
        Ok(parsed)
    }
}

impl HttpApi {
    /// POST /v1/media — upload an encrypted blob (`media::encrypt`
    /// output). Idempotent: re-uploading the same blob is a no-op on
    /// the server. Returns the blob's sha256 hex.
    pub async fn upload_media(
        &self,
        identity_seed: [u8; 32],
        blob: Vec<u8>,
    ) -> Result<String, HttpError> {
        self.upload_media_with_progress(identity_seed, blob, &|_| {}).await
    }

    /// [`upload_media`] reporting bytes handed to the connection after
    /// each 64 KiB chunk (`on_sent(cumulative)`), for an upload %.
    pub async fn upload_media_with_progress(
        &self,
        identity_seed: [u8; 32],
        blob: Vec<u8>,
        on_sent: &(dyn Fn(u64) + Send + Sync),
    ) -> Result<String, HttpError> {
        const CHUNK: usize = 64 * 1024;
        let sha_hex = hex::encode(sha256(&blob));
        let len = blob.len();
        let data = bytes::Bytes::from(blob);
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel::<u64>();
        let body_stream = futures_util::stream::iter((0..len).step_by(CHUNK).map({
            let data = data.clone();
            move |start| {
                let end = (start + CHUNK).min(len);
                let _ = tx.send(end as u64);
                Ok::<_, std::io::Error>(data.slice(start..end))
            }
        }));
        let (identity_hex, ts, proof_hex) =
            action_proof(&self.host, identity_seed, MEDIA_UPLOAD_DOMAIN, sha_hex.as_bytes());
        let resp = self
            .client
            .post(format!("{}/v1/media", self.base_url))
            .header("x-sinhron-identity", identity_hex)
            .header("x-sinhron-ts", ts.to_string())
            .header("x-sinhron-proof", proof_hex)
            .header("x-sinhron-sha256", &sha_hex)
            .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
            // Explicit length: the server rejects oversize uploads before
            // reading the body, and no chunked encoding is needed.
            .header(reqwest::header::CONTENT_LENGTH, len.to_string())
            .body(reqwest::Body::wrap_stream(body_stream));
        // Drive the request and forward progress as chunks are pulled.
        let mut rx = rx;
        let send = resp.send();
        tokio::pin!(send);
        let resp = loop {
            tokio::select! {
                r = &mut send => break r,
                Some(sent) = rx.recv() => on_sent(sent),
            }
        }
        .map_err(transport)?;
        while let Ok(sent) = rx.try_recv() {
            on_sent(sent);
        }
        drop(data);
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server {
                status: status.as_u16(),
                body,
            });
        }
        debug!(sha256 = %&sha_hex[..12], "media uploaded");
        Ok(sha_hex)
    }

    /// ADR-064 — POST /v1/media/touch: keep these blobs for another 90
    /// days and say which of them the server no longer has (≤
    /// [`MEDIA_TOUCH_MAX`] at a time). The server learns nothing it didn't
    /// already: the same hashes as a download, without the bytes.
    pub async fn touch_media(&self, identity_seed: [u8; 32], shas: &[String]) -> Result<Vec<String>, HttpError> {
        #[derive(Deserialize)]
        struct Resp {
            missing: Vec<String>,
        }
        let body = serde_json::to_vec(&serde_json::json!({ "sha256": shas })).map_err(|e| HttpError::Parse(e.to_string()))?;
        let body_sha = hex::encode(sha256(&body));
        let (identity_hex, ts, proof_hex) = action_proof(&self.host, identity_seed, MEDIA_TOUCH_DOMAIN, body_sha.as_bytes());
        let resp = self
            .client
            .post(format!("{}/v1/media/touch", self.base_url))
            .header("x-sinhron-identity", identity_hex)
            .header("x-sinhron-ts", ts.to_string())
            .header("x-sinhron-proof", proof_hex)
            .header("x-sinhron-sha256", body_sha)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(HttpError::Server { status: status.as_u16(), body });
        }
        let r: Resp = resp.json().await.map_err(|e| HttpError::Parse(e.to_string()))?;
        Ok(r.missing)
    }

    /// GET /v1/media/{sha256} — fetch an encrypted blob. The caller
    /// verifies + decrypts with `media::decrypt`.
    pub async fn download_media(
        &self,
        identity_seed: [u8; 32],
        sha256_hex: &str,
    ) -> Result<Vec<u8>, HttpError> {
        self.download_media_capped(identity_seed, sha256_hex, MAX_BLOB_BYTES).await
    }

    /// XFER-2 — a host that streams more than a blob can be is cut off
    /// (it used to be read whole into memory before any check).
    async fn download_media_capped(&self, identity_seed: [u8; 32], sha256_hex: &str, cap: usize) -> Result<Vec<u8>, HttpError> {
        let (identity_hex, ts, proof_hex) =
            action_proof(&self.host, identity_seed, MEDIA_GET_DOMAIN, sha256_hex.as_bytes());
        let mut resp = self
            .client
            .get(format!("{}/v1/media/{}", self.base_url, sha256_hex))
            .header("x-sinhron-identity", identity_hex)
            .header("x-sinhron-ts", ts.to_string())
            .header("x-sinhron-proof", proof_hex)
            .send()
            .await
            .map_err(transport)?;
        record_drift_from_response(&resp);
        let status = resp.status();
        if !status.is_success() {
            // XFER-2 — the error text is cut too (an endless "error" filled memory just the same).
            let mut body = Vec::new();
            while let Ok(Some(chunk)) = resp.chunk().await {
                body.extend_from_slice(&chunk[..chunk.len().min(4096 - body.len())]);
                if body.len() >= 4096 {
                    break;
                }
            }
            let body = String::from_utf8_lossy(&body).into_owned();
            return Err(HttpError::Server {
                status: status.as_u16(),
                body,
            });
        }
        let mut blob = Vec::new();
        while let Some(chunk) = resp.chunk().await.map_err(transport)? {
            if blob.len() + chunk.len() > cap {
                return Err(HttpError::Parse("media answer too large".into()));
            }
            blob.extend_from_slice(&chunk);
        }
        Ok(blob)
    }
}

/// The server stores blobs up to 100 MiB (`DEFAULT_MAX_BYTES`).
const MAX_BLOB_BYTES: usize = 101 * 1024 * 1024;

/// The SOCKS5 proxy (Tor / Orbot) when one is set — `sinhron_net::proxy`,
/// remote DNS. A bad proxy address is ignored (direct connection) rather
/// than failing every request; the WS side reports it.
///
/// Also the timeouts every client gets (bug 2026-10-16, owner: after
/// switching from Wi-Fi to LTE the app stayed "net not connected" until a
/// restart). Without them a request on a socket of the network that is
/// gone waited forever — and the launch path waits for its HTTP calls
/// before it opens the connection. No total limit: a big photo or video
/// keeps going as long as bytes flow.
pub(crate) fn with_proxy(b: reqwest::ClientBuilder) -> reqwest::ClientBuilder {
    match sinhron_net::socks_proxy_url().and_then(|u| reqwest::Proxy::all(u).ok()) {
        // Tor builds a circuit first: give it longer.
        Some(p) => with_timeouts(b.proxy(p), Duration::from_secs(30), Duration::from_secs(60)),
        // ADR-072 — our hosts get a checked address (DoH when the system
        // answer is wrong); everyone else's go to the system resolver.
        None => with_timeouts(b.dns_resolver(sinhron_net::dns::reqwest_resolver()), Duration::from_secs(10), Duration::from_secs(30)),
    }
}

/// [connect]: to open the connection; [read]: of silence while waiting for
/// the server. Idle pooled connections go after 30 s — one from the
/// previous network isn't reused after a switch.
fn with_timeouts(b: reqwest::ClientBuilder, connect: Duration, read: Duration) -> reqwest::ClientBuilder {
    b.connect_timeout(connect).read_timeout(read).pool_idle_timeout(Duration::from_secs(30))
}

/// Action proof (media endpoints send it as headers, ADR-025 device
/// endpoints in the body):
/// `domain || ':' || sha256(body) || ':' || be8(ts)`, bound to the server
/// `host` (ADR-086, [`sinhron_net::bind_to_host`]), Ed25519 by the
/// identity key. Returns (identity hex, ts, signature hex).
pub(crate) fn action_proof(host: &str, identity_seed: [u8; 32], domain: &[u8], body: &[u8]) -> (String, i64, String) {
    let sk = SigningKey::from_bytes(&identity_seed);
    let ts = sinhron_net::clock_drift::corrected_now_secs();
    let mut msg = Vec::with_capacity(domain.len() + 1 + 32 + 1 + 8);
    msg.extend_from_slice(domain);
    msg.push(b':');
    msg.extend_from_slice(&sha256(body));
    msg.push(b':');
    msg.extend_from_slice(&ts.to_be_bytes());
    (
        hex::encode(sk.verifying_key().to_bytes()),
        ts,
        hex::encode(sk.sign(&sinhron_net::bind_to_host(host, &msg)).to_bytes()),
    )
}

/// ADR-075 — was [device_pk]'s revocation signed by [identity]'s key (the
/// server's DEVICE_REVOKE action proof, kept with the device)? Only then
/// does anyone else take that device out of a chat — the server can't cut
/// a person's device off for them. No freshness check: revocations last.
/// `host` is this app's server (ADR-086): the proof names it.
pub fn revocation_is_signed(host: &str, identity: &[u8; 32], device_pk: &[u8], ts: i64, sig_hex: &str) -> bool {
    use ed25519_dalek::{Signature, VerifyingKey};
    let (Ok(vk), Ok(sig)) = (VerifyingKey::from_bytes(identity), hex::decode(sig_hex)) else { return false };
    let Ok(sig) = <[u8; 64]>::try_from(sig.as_slice()) else { return false };
    let mut msg = Vec::with_capacity(DEVICE_REVOKE_DOMAIN.len() + 1 + 32 + 1 + 8);
    msg.extend_from_slice(DEVICE_REVOKE_DOMAIN);
    msg.push(b':');
    msg.extend_from_slice(&sha256(device_pk));
    msg.push(b':');
    msg.extend_from_slice(&ts.to_be_bytes());
    vk.verify_strict(&sinhron_net::bind_to_host(host, &msg), &Signature::from_bytes(&sig)).is_ok()
}

/// ADR-025 — one of a person's devices, as GET /v1/devices lists it.
#[derive(Debug, Clone, Deserialize)]
pub struct DeviceInfo {
    pub device_pk_hex: String,
    /// Empty for the primary device (its key is the identity key).
    pub certificate_hex: String,
    pub registered_at: i64,
    /// Last WS login / KeyPackage upload (ADR-025; older servers: 0).
    #[serde(default)]
    pub last_seen_at: i64,
    /// ADR-075 — only from [`HttpApi::list_devices_with_revoked`].
    #[serde(default)]
    pub revoked: bool,
    #[serde(default)]
    pub revoke_proof_hex: String,
    #[serde(default)]
    pub revoke_proof_ts: i64,
}

// ── CD6 — wire contracts mirror server/src/handlers/call.rs ────────

#[derive(Debug, Serialize)]
struct TokenRequest {
    identity_pubkey_hex: String,
    group_id_hex: String,
    kind: String,
    request_ts: i64,
    request_proof_hex: String,
}

#[derive(Debug, Serialize)]
struct LiveRequest {
    identity_pubkey_hex: String,
    group_id_hex: String,
    request_ts: i64,
    request_proof_hex: String,
}

#[derive(Debug, Deserialize)]
struct LiveResponse {
    live: bool,
}

#[derive(Clone, Deserialize)]
pub struct LivekitTokenResponse {
    pub token: String,
    pub livekit_url: String,
    pub room: String,
    pub expires_at_unix: i64,
    pub ttl_secs: i64,
    /// Video codecs the server's LiveKit takes (ADR-045); none from older
    /// servers.
    #[serde(default)]
    pub video_codecs: Vec<String>,
}

#[derive(Clone, Deserialize)]
pub struct TurnResponse {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
    pub ttl_secs: i64,
}

// Debug by hand: the LiveKit token and the TURN password are never printed.
impl std::fmt::Debug for LivekitTokenResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LivekitTokenResponse").field("room", &self.room).field("ttl_secs", &self.ttl_secs).finish_non_exhaustive()
    }
}

impl std::fmt::Debug for TurnResponse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TurnResponse").field("ttl_secs", &self.ttl_secs).finish_non_exhaustive()
    }
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().into()
}

/// Risk #4 — extract the standard HTTP `Date:` header from a response
/// (RFC 7231 §7.1.1.2) and feed it into the process-wide clock-drift
/// store. Every reqwest response in this module funnels through here.
/// No-ops if the header is missing or unparseable (e.g. Caddy strips
/// `Date` under some configs — we don't depend on it).
pub(crate) fn record_drift_from_response(resp: &reqwest::Response) {
    let Some(date_hv) = resp.headers().get(reqwest::header::DATE) else {
        return;
    };
    let Ok(date_str) = date_hv.to_str() else {
        return;
    };
    // RFC 7231 §7.1.1.1 — only IMF-fixdate is mandatory now; we just
    // try the parser shipped with `httpdate` would be nicest but
    // pulling a crate for one parse is overkill. Manual: try the
    // standard format. If fails, give up.
    match parse_imf_fixdate(date_str) {
        Some(server_unix) => {
            // CRIT-1.4 — record observation; Instant anchored internally.
            sinhron_net::clock_drift::record(server_unix);
        }
        None => {
            warn!(date = %date_str, "could not parse HTTP Date header — skipping clock drift update");
        }
    }
}

/// Parse `"Sun, 06 Nov 1994 08:49:37 GMT"` style — RFC 7231 IMF-fixdate.
/// Returns unix seconds (UTC) on success. This is the only widely-
/// guaranteed format; the older RFC 850 / asctime formats are
/// deprecated by RFC 7231 §7.1.1.1.
fn parse_imf_fixdate(s: &str) -> Option<i64> {
    // Months lookup.
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];

    // Expect: "Day, DD Mon YYYY HH:MM:SS GMT"
    //          0   1  2   3    4         5
    let parts: Vec<&str> = s.split_whitespace().collect();
    if parts.len() != 6 {
        return None;
    }
    let day: i64 = parts[1].parse().ok()?;
    let month_idx = MONTHS.iter().position(|m| *m == parts[2])? as i64;
    let year: i64 = parts[3].parse().ok()?;
    let hms: Vec<&str> = parts[4].split(':').collect();
    if hms.len() != 3 {
        return None;
    }
    let h: i64 = hms[0].parse().ok()?;
    let m: i64 = hms[1].parse().ok()?;
    let sec: i64 = hms[2].parse().ok()?;
    if parts[5] != "GMT" {
        return None;
    }
    // The header is the server's (or the network's) text: numbers outside a
    // real date would overflow the arithmetic below.
    if !(1..=31).contains(&day) || !(1970..=9999).contains(&year) || !(0..=23).contains(&h) || !(0..=59).contains(&m) || !(0..=60).contains(&sec) {
        return None;
    }

    // Compute days from 1970-01-01 to (year, month, day) — Howard
    // Hinnant's "days from civil" algorithm (well-known, branch-free,
    // handles leap years cleanly).
    let y = year - if month_idx <= 1 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * ((month_idx + if month_idx >= 2 { -2 } else { 10 })) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days_since_epoch = era * 146097 + doe - 719468;
    Some(days_since_epoch * 86400 + h * 3600 + m * 60 + sec)
}

#[derive(Debug)]
pub struct RegisterOutcome {
    pub user_pk: String,
    pub already_existed: bool,
    pub identity_pubkey_hex: String,
}

#[derive(Debug, Serialize)]
struct RegisterRequest {
    identity_pubkey_hex: String,
    registration_proof_hex: String,
    primary_device: Option<PrimaryDevice>,
}

#[derive(Debug, Serialize)]
struct PrimaryDevice {
    device_pk_hex: String,
    device_credential_hex: String,
}

#[derive(Debug, Deserialize)]
struct RegisterResponse {
    user_pk: String,
    already_existed: bool,
}

#[derive(Debug, Serialize)]
struct CreateGroupRequest {
    group_id_hex: String,
    creator_device_pk_hex: String,
    member_device_pks_hex: Vec<String>,
    epoch: u64,
    proof_ts: i64,
    proof_hex: String,
}

#[derive(Debug, Serialize)]
struct UploadRequest {
    device_pk_hex: String,
    kp_bytes_b64: String,
    upload_proof_ts: i64,
    upload_proof_hex: String,
}

#[derive(Debug, Deserialize)]
struct UploadResponse {
    keypackage_id: String,
}

#[derive(Debug, Deserialize)]
struct ConsumeItem {
    #[allow(dead_code)]
    keypackage_id: String,
    device_pk_hex: String,
    kp_bytes_b64: String,
}

/// ADR-071 — what `PUT /v1/access-keys` signs (mirrors the server's
/// `access_keys::signed_body`): version, each add (1 ‖ hash), each
/// decision (2 = revoke / 3 = unblock ‖ hash ‖ at_ms), in the action-proof
/// frame `domain ‖ ":" ‖ SHA-256(body) ‖ ":" ‖ ts`.
fn access_keys_proof_message(version: i32, adds: &[[u8; 32]], decisions: &[([u8; 32], bool, i64)], ts: i64) -> Vec<u8> {
    let mut body = Vec::with_capacity(4 + adds.len() * 33 + decisions.len() * 41);
    body.extend_from_slice(&version.to_be_bytes());
    for h in adds {
        body.push(1);
        body.extend_from_slice(h);
    }
    for (h, revoked, at) in decisions {
        body.push(if *revoked { 2 } else { 3 });
        body.extend_from_slice(h);
        body.extend_from_slice(&at.to_be_bytes());
    }
    let mut msg = Vec::with_capacity(PUT_ACCESS_KEYS_DOMAIN.len() + 42);
    msg.extend_from_slice(PUT_ACCESS_KEYS_DOMAIN);
    msg.push(b':');
    msg.extend_from_slice(&sha256(&body));
    msg.push(b':');
    msg.extend_from_slice(&ts.to_be_bytes());
    msg
}

/// Transport error text without the request URL: reqwest appends
/// "for url (...)", which carries the server address and, in some calls,
/// contacts' identity keys, group ids or pairing ids.
fn transport(e: reqwest::Error) -> HttpError {
    HttpError::Transport(e.without_url().to_string())
}

#[derive(Debug, thiserror::Error)]
pub enum HttpError {
    #[error("transport: {0}")]
    Transport(String),
    #[error("parse: {0}")]
    Parse(String),
    #[error("server {status}: {body}")]
    Server { status: u16, body: String },
    #[error("empty: {0}")]
    Empty(String),
}

#[cfg(test)]
mod imf_date_tests {
    use super::*;

    /// Risk #4 regression — the manual RFC 7231 IMF-fixdate parser
    /// must correctly handle the canonical reference cases. Failing
    /// these means HTTP-based drift correction is broken silently.
    #[test]
    fn parses_canonical_imf_fixdate() {
        // RFC 7231 example: 6 November 1994 08:49:37 GMT.
        let s = "Sun, 06 Nov 1994 08:49:37 GMT";
        // Verified via `date -u -j -f "%Y-%m-%d %H:%M:%S" "1994-11-06 08:49:37" "+%s"`
        // = 784111777
        assert_eq!(parse_imf_fixdate(s), Some(784_111_777));
    }

    #[test]
    fn parses_unix_epoch() {
        let s = "Thu, 01 Jan 1970 00:00:00 GMT";
        assert_eq!(parse_imf_fixdate(s), Some(0));
    }

    #[test]
    fn parses_leap_year_date() {
        // 2024 is a leap year — Feb 29 must parse correctly.
        let s = "Thu, 29 Feb 2024 12:00:00 GMT";
        // Verified: `date -u -j -f "%Y-%m-%d %H:%M:%S" "2024-02-29 12:00:00" "+%s"` = 1709208000
        assert_eq!(parse_imf_fixdate(s), Some(1_709_208_000));
    }

    #[test]
    fn rejects_non_gmt() {
        let s = "Sun, 06 Nov 1994 08:49:37 PST";
        assert_eq!(parse_imf_fixdate(s), None);
    }

    #[test]
    fn rejects_malformed() {
        assert_eq!(parse_imf_fixdate(""), None);
        assert_eq!(parse_imf_fixdate("garbage"), None);
        // Numbers no date has: no overflow panic, just "not a date".
        assert_eq!(parse_imf_fixdate("Sun, 99999999999999999 Jan 9223372036854775807 99999999999999999:0:0 GMT"), None);
        assert_eq!(parse_imf_fixdate("Sun, 06 Nov -9223372036854775808 08:49:37 GMT"), None);
        assert_eq!(parse_imf_fixdate("06 Nov 1994 08:49:37 GMT"), None); // missing weekday
    }
}

#[cfg(test)]
mod report_tests {
    use super::*;

    /// ADR-037 — must match the server's `handlers::account::report_body`
    /// byte for byte, or every report fails its signature.
    #[test]
    fn report_body_layout_matches_the_server() {
        let key = [7u8; 32];
        assert_eq!(report_body(&key, "spam", Some("hello")), [&key[..], b"spam\0hello"].concat());
        assert_eq!(report_body(&key, "abuse", None), [&key[..], b"abuse\0"].concat());
    }

    /// Overnight item 8 — must match the server's `push_tokens::token_body`.
    #[test]
    fn push_token_body_layout_matches_the_server() {
        assert_eq!(push_token_body("alert", "ab12", true, "ru", None, None), b"alert\0ab12\x01ru".to_vec());
        assert_eq!(push_token_body("voip", "", false, "en", None, None), b"voip\0\x00en".to_vec());
        assert_eq!(
            push_token_body("alert", "https://p/u", false, "en", Some(("BK", "au")), None),
            b"alert\0https://p/u\x00en\0BK\0au".to_vec()
        );
        // ADR-056 — the server's `token_body("voip", "ab", false, "ru", None, Some("0f"))`.
        assert_eq!(push_token_body("voip", "ab", false, "ru", None, Some("0f")), b"voip\0ab\0ru\x010f".to_vec());
    }
}

#[cfg(test)]
mod timeout_tests {
    use super::*;

    /// Bug 2026-10-16 — a server (or a socket of a network that's gone)
    /// that never answers: the request fails after the read timeout
    /// instead of hanging the launch path forever.
    #[tokio::test]
    async fn a_silent_server_times_out_instead_of_hanging() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            let held: Vec<_> = listener.incoming().take(2).collect();
            std::thread::sleep(Duration::from_secs(5));
            drop(held);
        });
        let client = with_timeouts(reqwest::Client::builder(), Duration::from_secs(1), Duration::from_millis(300))
            .build()
            .unwrap();
        let started = std::time::Instant::now();
        let err = client.get(format!("http://{addr}/v1/x")).send().await.unwrap_err();
        assert!(err.is_timeout(), "{err}");
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}

#[cfg(test)]
mod keypackages_available_tests {
    use super::*;
    use std::io::{Read, Write};

    /// One HTTP answer per connection, from a thread.
    fn serve(answers: Vec<&'static str>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for (conn, answer) in listener.incoming().zip(answers) {
                let mut conn = conn.unwrap();
                let mut buf = [0u8; 4096];
                let _ = conn.read(&mut buf);
                let _ = conn.write_all(answer.as_bytes());
            }
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn a_host_streaming_a_huge_invite_answer_is_cut_off() {
        let huge: &'static str = Box::leak(format!("HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n{{\"blob_b64\":\"{}\"}}", "A".repeat(1 << 20)).into_boxed_str());
        let api = HttpApi::new(serve(vec![huge]));
        assert!(matches!(api.get_short_invite("AAAAAAAAAA").await, Err(HttpError::Parse(_))));
    }

    // XFER-2 — a transfer part / media blob larger than a blob can be.
    #[tokio::test]
    async fn a_host_streaming_a_huge_blob_is_cut_off() {
        let answer = |n: usize| -> &'static str {
            Box::leak(format!("HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n{}", "A".repeat(n)).into_boxed_str())
        };
        let api = HttpApi::new(serve(vec![answer(1 << 20), answer(1000)]));
        assert!(matches!(api.download_media_capped([7; 32], "ab12", 4096).await, Err(HttpError::Parse(_))));
        assert_eq!(api.download_media_capped([7; 32], "ab12", 4096).await.unwrap().len(), 1000);
    }

    // Tech-debt 2.34 — who can't be added is asked first; an older server
    // without the endpoint changes nothing.
    #[tokio::test]
    async fn missing_keypackages_are_asked_first_and_old_servers_are_fine() {
        let body = r#"{"missing":["ab12"]}"#;
        let ok: &'static str = Box::leak(
            format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len())
                .into_boxed_str(),
        );
        let base = serve(vec![ok, "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"]);
        let api = HttpApi::new(base);
        let ids = vec!["ab12".to_string(), "cd34".to_string()];
        assert_eq!(api.keypackages_missing(&ids).await.unwrap(), Some(vec!["ab12".to_string()]));
        assert_eq!(api.keypackages_missing(&ids).await.unwrap(), None, "404: an older server");
    }

    // ADR-077 — an administrator gets the notices; anyone else (403) and an
    // older server (404) get None, not an error.
    #[tokio::test]
    async fn admin_notices_for_administrators_only() {
        let body = r#"{"notices":[{"id":7,"kind":"alert","text":"🔥 busy","ts":1761300000}]}"#;
        let ok: &'static str = Box::leak(
            format!(
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            )
            .into_boxed_str(),
        );
        let base = serve(vec![
            ok,
            "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
        ]);
        let api = HttpApi::new(base);
        let got = api.admin_notices([7u8; 32], 0).await.unwrap().unwrap();
        assert_eq!(got, vec![AdminNotice { id: 7, kind: "alert".into(), text: "🔥 busy".into(), ts: 1761300000 }]);
        assert_eq!(api.admin_notices([7u8; 32], 7).await.unwrap(), None);
        assert_eq!(api.admin_notices([7u8; 32], 7).await.unwrap(), None);
    }
}

#[cfg(test)]
mod livekit_token_tests {

    use super::*;

    // ADR-045 — newer servers list their video codecs; older ones don't.
    #[test]
    fn video_codecs_are_read_and_default_to_none() {
        let new: LivekitTokenResponse = serde_json::from_str(
            r#"{"token":"t","livekit_url":"wss://x","room":"r","expires_at_unix":1,"ttl_secs":60,"video_codecs":["h265","h264","vp8"]}"#,
        )
        .unwrap();
        assert_eq!(new.video_codecs, vec!["h265", "h264", "vp8"]);
        let old: LivekitTokenResponse =
            serde_json::from_str(r#"{"token":"t","livekit_url":"wss://x","room":"r","expires_at_unix":1,"ttl_secs":60}"#).unwrap();
        assert!(old.video_codecs.is_empty());
    }
}

#[cfg(test)]
mod revocation_tests {
    use super::*;

    /// ADR-075 — a revocation counts only with the person's own account-key
    /// signature over that very device (the server's proof, kept with it).
    #[test]
    fn a_revocation_counts_only_with_the_persons_signature() {
        let id_seed = [21u8; 32];
        let identity: [u8; 32] = SigningKey::from_bytes(&id_seed).verifying_key().to_bytes();
        let device = [7u8; 32];
        let (_, ts, sig) = action_proof("a.example", id_seed, DEVICE_REVOKE_DOMAIN, &device);
        assert!(revocation_is_signed("a.example", &identity, &device, ts, &sig));
        assert!(!revocation_is_signed("a.example", &identity, &[8u8; 32], ts, &sig), "another device");
        assert!(!revocation_is_signed("a.example", &identity, &device, ts + 1, &sig), "another time");
        let someone: [u8; 32] = SigningKey::from_bytes(&[22u8; 32]).verifying_key().to_bytes();
        assert!(!revocation_is_signed("a.example", &someone, &device, ts, &sig), "signed by someone else");
        let (_, ts2, other) = action_proof("a.example", id_seed, DEVICE_ADD_DOMAIN, &device);
        assert!(!revocation_is_signed("a.example", &identity, &device, ts2, &other), "another kind of proof");
        assert!(!revocation_is_signed("a.example", &identity, &device, ts, "zz"));
        assert!(!revocation_is_signed("b.example", &identity, &device, ts, &sig), "made for another server");
    }

    /// ADR-086 — the same fixed vector the server checks
    /// (`proof::tests::the_apps_registration_for_localhost_matches_the_fixed_vector`).
    #[test]
    fn the_signed_bytes_match_the_servers_fixed_vector() {
        let sk = SigningKey::from_bytes(&[0x42; 32]);
        let mut msg = REGISTRATION_DOMAIN.to_vec();
        msg.extend_from_slice(&sk.verifying_key().to_bytes());
        let sig = sk.sign(&sinhron_net::bind_to_host("localhost", &msg)).to_bytes();
        assert_eq!(hex::encode(sig), "59c56fabd8fda461df87fde60dc460c0267c421b6504419ed816101e6a3b3b465082e2bb8277b4f841eff2ccb7b0f735dc5749856e38b87fd09ffb891c156f08");
    }

    /// ADR-086 (mls-identity:5, server-http:8) — every proof names the
    /// server by the name in the app's URL (lowercase, no port, no path),
    /// so a hostile server can't pass it on to the real one.
    #[test]
    fn every_proof_names_the_server_from_the_apps_url() {
        let api = HttpApi::new("https://Chat.A.Example:8443/".into());
        assert_eq!(api.host(), "chat.a.example");
        assert_eq!(HttpApi::new("http://127.0.0.1:8080".into()).host(), "127.0.0.1");
        let seed = [21u8; 32];
        let vk = SigningKey::from_bytes(&seed).verifying_key();
        let device = [7u8; 32];
        let (_, ts, sig) = action_proof(api.host(), seed, DEVICE_REVOKE_DOMAIN, &device);
        let sig = ed25519_dalek::Signature::from_slice(&hex::decode(sig).unwrap()).unwrap();
        let mut msg = DEVICE_REVOKE_DOMAIN.to_vec();
        msg.push(b':');
        msg.extend_from_slice(&sha256(&device));
        msg.push(b':');
        msg.extend_from_slice(&ts.to_be_bytes());
        use ed25519_dalek::Verifier;
        assert!(vk.verify(&sinhron_net::bind_to_host("chat.a.example", &msg), &sig).is_ok());
        assert!(vk.verify(&sinhron_net::bind_to_host("evil.b.example", &msg), &sig).is_err());
        assert!(vk.verify(&msg, &sig).is_err(), "never the old form that names no server");
    }
}

#[cfg(test)]
mod sealed_key_signature_tests {
    use super::*;
    use std::io::{Read, Write};

    /// Answers each connection with the next JSON body and hands back the
    /// request bodies it got.
    fn serve(answers: Vec<String>) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for (conn, body) in listener.incoming().zip(answers) {
                let mut conn = conn.unwrap();
                let (mut req, mut buf) = (Vec::new(), [0u8; 4096]);
                loop {
                    let n = conn.read(&mut buf).unwrap();
                    req.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&req).to_string();
                    let Some(end) = text.find("\r\n\r\n") else { continue };
                    let len: usize = text[..end]
                        .lines()
                        .find_map(|l| l.to_ascii_lowercase().strip_prefix("content-length:").map(|v| v.trim().parse().unwrap()))
                        .unwrap_or(0);
                    if req.len() >= end + 4 + len || n == 0 {
                        let _ = tx.send(text[end + 4..].to_string());
                        break;
                    }
                }
                let head = format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n", body.len());
                let _ = conn.write_all(format!("{head}{body}").as_bytes());
            }
        });
        (format!("http://{addr}"), rx)
    }

    fn key(identity: &[u8; 32], week: u32, public: &[u8], sig: Option<[u8; 64]>, cert: Option<&[u8]>) -> serde_json::Value {
        serde_json::json!({
            "identity_pubkey_hex": hex::encode(identity), "week": week, "public_hex": hex::encode(public),
            "sig_hex": sig.map(hex::encode), "cert_hex": cert.map(hex::encode),
        })
    }

    // Audit mls-identity:4 / sealed-push:1 — the server answers with its
    // own key for Bob: unsigned, signed by itself, with Bob's signature of
    // another key, with someone else's device certificate, or a device
    // signature without a certificate. None is trusted, so no message
    // text is sealed to it; Bob's own signatures (identity, or certified
    // device) are.
    #[tokio::test]
    async fn a_delivery_key_the_server_swapped_in_gets_no_preview() {
        let bob_seed = [21u8; 32];
        let bob = SigningKey::from_bytes(&bob_seed).verifying_key().to_bytes();
        let device_seed = [22u8; 32];
        let device = SigningKey::from_bytes(&device_seed).verifying_key().to_bytes();
        let bob_cert = crate::identity::device_certificate(&bob_seed, &device);
        let carol_cert = crate::identity::device_certificate(&[23u8; 32], &device);
        let (eve, real, w) = ([0xEEu8; 32], [9u8; 32], 2900);
        let sign = |seed: &[u8; 32], public: &[u8]| Some(crate::sealed::sign_delivery_key(seed, &bob, w, public));
        let rows = vec![
            key(&bob, w, &eve, None, None),
            key(&bob, w, &eve, sign(&[66u8; 32], &eve), None),
            key(&bob, w, &eve, sign(&bob_seed, &real), None),
            key(&bob, w, &eve, sign(&device_seed, &eve), Some(&carol_cert)),
            key(&bob, w, &eve, sign(&device_seed, &eve), None),
            key(&bob, w + 1, &real, sign(&bob_seed, &real), None),
            key(&bob, w, &real, sign(&bob_seed, &real), None),
            key(&bob, w, &real, sign(&device_seed, &real), Some(&bob_cert)),
        ];
        let (base, _) = serve(vec![serde_json::json!({ "keys": rows }).to_string()]);
        let got = HttpApi::new(base).fetch_sealed_keys(&[hex::encode(bob)]).await.unwrap();
        let signed: Vec<bool> = got.iter().map(|k| k.3).collect();
        assert_eq!(signed, vec![false, false, false, false, false, false, true, true]);
    }

    // ADR-082 — what this app publishes (first device; linked device with
    // its certificate) reads back as signed; an old server's answer with
    // no signature still parses, as unsigned.
    #[tokio::test]
    async fn published_delivery_keys_verify_for_first_and_linked_devices() {
        let bob_seed = [31u8; 32];
        let bob = SigningKey::from_bytes(&bob_seed).verifying_key().to_bytes();
        let device_seed = [32u8; 32];
        let cert = crate::identity::device_certificate(&bob_seed, &SigningKey::from_bytes(&device_seed).verifying_key().to_bytes());
        let pairs = vec![(2900u32, vec![1u8; 32]), (2901, vec![2u8; 32])];
        for (seed, cert) in [(bob_seed, None), (device_seed, Some(&cert[..]))] {
            let (base, rx) = serve(vec![r#"{"stored":2,"access_version":0}"#.into()]);
            HttpApi::new(base).publish_sealed_keys(seed, &pairs, None, cert).await.unwrap();
            let put: serde_json::Value = serde_json::from_str(&rx.recv().unwrap()).unwrap();
            // What the server stores and returns, under Bob's identity.
            let rows: Vec<_> = put["keys"]
                .as_array()
                .unwrap()
                .iter()
                .map(|k| {
                    let mut k = k.clone();
                    k["identity_pubkey_hex"] = hex::encode(bob).into();
                    k["cert_hex"] = put["cert_hex"].clone();
                    k
                })
                .collect();
            let (base, _) = serve(vec![serde_json::json!({ "keys": rows }).to_string()]);
            let got = HttpApi::new(base).fetch_sealed_keys(&[hex::encode(bob)]).await.unwrap();
            assert_eq!(got.iter().map(|k| (k.1, k.3)).collect::<Vec<_>>(), vec![(2900, true), (2901, true)]);
        }
        let old = serde_json::json!({ "keys": [{"identity_pubkey_hex": hex::encode(bob), "week": 2900, "public_hex": "01".repeat(32)}] });
        let (base, _) = serve(vec![old.to_string()]);
        assert!(!HttpApi::new(base).fetch_sealed_keys(&[hex::encode(bob)]).await.unwrap()[0].3, "old server: unsigned");
    }
}
