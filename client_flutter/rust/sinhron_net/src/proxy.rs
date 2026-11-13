// Optional SOCKS5 proxy for everything the app sends to its server —
// hides the phone's IP from it (sealed sender, ADR-026, hides the account;
// this hides the network address). Point it at Tor (e.g. Orbot,
// `127.0.0.1:9050`). Remote DNS: the proxy resolves the host name, so
// `.onion` servers work too.
//
// One process-wide setting, read by the WS client (here) and by the HTTP
// client (`sinhron_sync::HttpApi`). Calls / LiveKit media don't go
// through it (WebRTC).

use std::sync::RwLock;

static SOCKS: RwLock<Option<String>> = RwLock::new(None);

/// `host:port` of a SOCKS5 proxy, or `None` to connect directly.
pub fn set_socks_proxy(proxy: Option<String>) {
    let p = proxy.map(|s| s.trim().trim_start_matches("socks5h://").trim_start_matches("socks5://").to_string());
    if let Ok(mut g) = SOCKS.write() {
        *g = p.filter(|s| !s.is_empty());
    }
}

/// The current proxy (`host:port`), if any.
pub fn socks_proxy() -> Option<String> {
    SOCKS.read().ok().and_then(|g| g.clone())
}

/// `socks5h://host:port` for HTTP clients (remote DNS).
pub fn socks_proxy_url() -> Option<String> {
    socks_proxy().map(|p| format!("socks5h://{p}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn set_and_clear() {
        set_socks_proxy(Some("socks5h://127.0.0.1:9050".into()));
        assert_eq!(socks_proxy().as_deref(), Some("127.0.0.1:9050"));
        assert_eq!(socks_proxy_url().as_deref(), Some("socks5h://127.0.0.1:9050"));
        set_socks_proxy(Some("  ".into()));
        assert_eq!(socks_proxy(), None);
        set_socks_proxy(None);
        assert_eq!(socks_proxy(), None);
    }
}
