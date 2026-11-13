// Sender IP — the app's server traffic through a SOCKS5 proxy (Tor /
// Orbot in real use), through a real server (SINHRON_E2E_HTTP) and a proxy
// (SINHRON_E2E_SOCKS, host:port).
//
//   1. With the proxy set, HTTP (register, KeyPackage) and the WS login go
//      through it — the proxy sees the connections, the server sees only
//      the proxy's address.
//   2. With a dead proxy set, nothing connects (no silent direct fallback).
//
// Usage: cargo run --example proxy_e2e

use std::time::Duration;

use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::{HttpApi, SyncClient, SyncClientConfig};
use tokio::time::timeout;

// Its own test identity: the KeyPackage it publishes is never used, and
// must not be handed to another example's invite.
const PHRASE: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo \
                      zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote";

async fn ws_connects(url: &str, c: &SyncClient) -> bool {
    let ws = WsClient::start(WsClientConfig {
        url: format!("{}/v1/sync", url.replacen("http", "ws", 1)),
        identity_seed: c.login_seed_bytes(),
        tls: None,
        resume_cursor: None,
    });
    let ok = matches!(timeout(Duration::from_secs(5), ws.recv()).await, Ok(Some(Event::Connected)));
    ws.shutdown();
    ok
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let url = std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    let proxy = std::env::var("SINHRON_E2E_SOCKS").unwrap_or_else(|_| "127.0.0.1:1080".to_string());
    println!("→ proxy_e2e · http={url} socks={proxy}");

    sinhron_net::set_socks_proxy(Some(proxy));
    let http = HttpApi::new(url.clone());
    let mut bob = SyncClient::new(SyncClientConfig { phrase: PHRASE.into(), db_path: None, device_seed: None })?;
    bob.bootstrap_with_server(&http).await?;
    println!("✓ HTTP through the proxy");
    anyhow::ensure!(ws_connects(&url, &bob).await, "WS login through the proxy");
    println!("✓ WS through the proxy");

    sinhron_net::set_socks_proxy(Some("127.0.0.1:9".into())); // nothing listens
    anyhow::ensure!(!ws_connects(&url, &bob).await, "a dead proxy means no connection");
    anyhow::ensure!(HttpApi::new(url).list_devices(&bob.identity_pubkey_hex()).await.is_err(), "nor HTTP");
    println!("✓ dead proxy → no direct fallback");

    println!("\n🎯 proxy_e2e · server traffic through SOCKS5 ✓");
    Ok(())
}
