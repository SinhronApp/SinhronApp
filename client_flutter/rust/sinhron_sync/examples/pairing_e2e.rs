// ADR-027 end-to-end — QR pairing with the identity key staying on the
// first device, through a real server (SINHRON_E2E_HTTP, default
// http://127.0.0.1:8080).
//
//   1. Alice's phone holds the account key. A new laptop makes its own
//      device key and shows a QR (one-time HPKE key + its device key).
//   2. The phone signs a certificate for the laptop's key and seals a
//      linked-device bundle (no identity key) to the QR's key.
//   3. The laptop opens it and signs in: no account key on it, so it
//      can't add devices; it logs in to the WS and signs requests with its
//      own key, which the server accepts as Alice's device.
//   4. The phone revokes it → the server refuses its WS login and its
//      signed requests: revocation no longer depends on the laptop.
//
// Usage: cargo run --example pairing_e2e

use std::time::Duration;

use rand_core::{OsRng, RngCore};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::pairing::{default_crypto, device_pub_of_seed, parse_qr, seal_secret, PairingOffer};
use sinhron_sync::{HttpApi, SyncClient, SyncClientConfig};
use tokio::time::timeout;

const ALICE_PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon art";

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()
}

/// Does a WS login with this client's signing key succeed?
async fn ws_login(url: &str, c: &SyncClient) -> anyhow::Result<bool> {
    let ws = WsClient::start(WsClientConfig {
        url: format!("{}/v1/sync", url.replacen("http", "ws", 1)),
        identity_seed: c.login_seed_bytes(),
        tls: None,
        resume_cursor: None,
    });
    // `Connected` comes only after the server accepted the login; a
    // refused one just keeps retrying in the background.
    let ok = matches!(timeout(Duration::from_secs(5), ws.recv()).await, Ok(Some(Event::Connected)));
    ws.shutdown();
    Ok(ok)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    println!("→ pairing_e2e · http={url}");
    let http = HttpApi::new(url.clone());
    let c = default_crypto();

    let device_key = sinhron_crypto::identity::device_key_from_phrase(ALICE_PHRASE).map_err(|e| anyhow::anyhow!("{e}"))?;
    let mut phone = SyncClient::new(SyncClientConfig { phrase: device_key, db_path: None, device_seed: None })?;
    phone.bootstrap_with_server(&http).await?;
    anyhow::ensure!(phone.has_account_key());

    // 1. Laptop: its own key + QR.
    let mut seed = [0u8; 32];
    OsRng.fill_bytes(&mut seed);
    let offer = PairingOffer::new(&c, device_pub_of_seed(&seed))?;
    let qr = offer.qr_text();
    println!("laptop shows QR ({} chars)", qr.len());

    // 2. Phone: certificate + bundle for exactly that key.
    let (_, _, laptop_pub) = parse_qr(&qr)?;
    let bundle = phone.linked_bundle_for(&laptop_pub)?;
    anyhow::ensure!(!bundle.contains("sinhron-device-key"), "the account key isn't in it");
    let (id, sealed) = seal_secret(&c, &qr, &bundle)?;
    http.put_pairing(phone.identity_seed_bytes(), &id, &sealed).await?;
    println!("✓ phone left a sealed linked-device bundle");

    // 3. Laptop: open, sign in — without the identity key.
    let got = http.take_pairing(&offer.id).await?.ok_or_else(|| anyhow::anyhow!("nothing to take"))?;
    let secret = offer.open(&c, &got)?;
    let mut laptop = SyncClient::new(SyncClientConfig { phrase: secret, db_path: None, device_seed: Some(seed) })?;
    anyhow::ensure!(!laptop.has_account_key(), "no identity key on the laptop");
    anyhow::ensure!(laptop.linked_bundle_for(&[7u8; 32]).is_err(), "so it can't add devices");
    anyhow::ensure!(laptop.identity_pubkey_hex() == phone.identity_pubkey_hex(), "same person");
    laptop.bootstrap_with_server(&http).await?;
    anyhow::ensure!(ws_login(&url, &laptop).await?, "WS login with its own key");
    let keys: Vec<(u32, Vec<u8>)> = laptop.delivery_keys_to_publish(now())?.into_iter().map(|k| (k.week, k.public)).collect();
    http.publish_sealed_keys(laptop.identity_seed_bytes(), &keys, Some((laptop.access_hash(), 0)), laptop.signer_certificate().as_deref()).await?;
    println!("✓ laptop signed in as Alice's device, without her identity key");

    // 4. Revoke → locked out on the server side, and its open connection
    //    is cut right away.
    let live = WsClient::start(WsClientConfig {
        url: format!("{}/v1/sync", url.replacen("http", "ws", 1)),
        identity_seed: laptop.login_seed_bytes(),
        tls: None,
        resume_cursor: None,
    });
    anyhow::ensure!(matches!(timeout(Duration::from_secs(5), live.recv()).await, Ok(Some(Event::Connected))));
    http.revoke_device(phone.identity_seed_bytes(), &laptop.device_public_key()).await?;
    anyhow::ensure!(
        matches!(timeout(Duration::from_secs(5), live.recv()).await, Ok(Some(Event::Disconnected { .. }))),
        "the revoked laptop's live connection is closed at once"
    );
    live.shutdown();
    anyhow::ensure!(!ws_login(&url, &laptop).await?, "a revoked device can't log in");
    anyhow::ensure!(
        http.publish_sealed_keys(laptop.identity_seed_bytes(), &keys, None, None).await.is_err(),
        "nor sign requests"
    );
    println!("✓ revoked laptop is locked out by the server");

    println!("\n🎯 pairing_e2e · QR pairing, identity key only on the first device ✓");
    Ok(())
}
