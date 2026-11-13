// TLS pinning per spec §6.1 — WU B3.
//
// The default WS + HTTP transports trust whatever's in `webpki-roots`
// (i.e. every public CA in Mozilla's trust store). That's fine for
// dev (`ws://localhost`) and acceptable-but-not-great for prod: a
// compromised public CA could issue a fraudulent cert for our operator
// hostname and we'd accept it.
//
// `TlsPinning` switches the trust store to **only** the bundled
// operator CA. Any cert that doesn't chain to that CA — even if it's
// from a "valid" public root — fails the TLS handshake.
//
// Wiring story:
//
//   • Operator deploys with a self-issued (or restricted-CA) cert.
//   • The CA's public PEM is shipped INSIDE the app binary
//     (e.g. `include_bytes!("../assets/operator_ca.pem")` from the FFI
//     layer or via a build-time env-var).
//   • Client constructs `TlsPinning::from_pem(...)` and passes the
//     resulting `Arc<rustls::ClientConfig>` to `WsClientConfig.tls`
//     (sinhron_net) and `HttpApi::new_pinned` (sinhron_sync).
//
// Pinning is OPT-IN — when `WsClientConfig.tls` is `None`, the WS
// client uses the default `tokio-tungstenite` rustls connector with
// webpki roots, exactly like before. This keeps the dev experience
// (`ws://localhost`) and unit tests unchanged.

use std::sync::Arc;

use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::Item;

/// Pre-built rustls config trusted only by the bundled operator CA.
///
/// Hand to `WsClientConfig.tls` or `HttpApi::new_pinned`.
#[derive(Clone)]
pub struct TlsPinning {
    pub(crate) config: Arc<ClientConfig>,
}

impl std::fmt::Debug for TlsPinning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Don't dump the cert details — the ClientConfig Debug includes
        // raw bytes, and we never want those in log records.
        f.debug_struct("TlsPinning")
            .field("trusts", &"operator-bundled CA (opaque)")
            .finish()
    }
}

impl TlsPinning {
    /// Build a pinned config from a PEM blob containing one or more
    /// CA certificates. Every cert in the blob is added to the trust
    /// store; certs that aren't actual `CERTIFICATE` PEM blocks are
    /// rejected with `TlsPinError::NoCertificates`.
    ///
    /// On iOS the PEM is typically embedded via
    /// `include_bytes!("../assets/operator_ca.pem")` so it ships
    /// inside the app binary, can't be swapped at runtime, and the
    /// supply chain is the same as the rest of the Rust artifact.
    pub fn from_pem(pem_bytes: &[u8]) -> Result<Self, TlsPinError> {
        // Install the platform's default crypto provider once. Rustls
        // 0.23 requires this; calling `install_default()` twice is
        // safe (returns Err but the global is already set).
        let _ = rustls::crypto::ring::default_provider().install_default();

        let mut store = RootCertStore::empty();
        let mut cursor = std::io::Cursor::new(pem_bytes);
        let mut added = 0usize;
        for item in rustls_pemfile::read_all(&mut cursor) {
            let item = item.map_err(|e| TlsPinError::Decode(format!("pem: {e}")))?;
            if let Item::X509Certificate(der) = item {
                store
                    .add(der)
                    .map_err(|e| TlsPinError::Decode(format!("cert: {e}")))?;
                added += 1;
            }
        }
        if added == 0 {
            return Err(TlsPinError::NoCertificates);
        }

        let config = ClientConfig::builder()
            .with_root_certificates(store)
            .with_no_client_auth();
        Ok(Self {
            config: Arc::new(config),
        })
    }

    /// Borrow the inner `rustls::ClientConfig` — for callers that need
    /// to plug it into reqwest (`use_preconfigured_tls`) or
    /// tokio-tungstenite (`Connector::Rustls`).
    pub fn client_config(&self) -> Arc<ClientConfig> {
        self.config.clone()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TlsPinError {
    #[error("failed to decode pinned CA: {0}")]
    Decode(String),
    #[error("no CERTIFICATE entries in the supplied PEM")]
    NoCertificates,
}

#[cfg(test)]
mod tests {
    use super::*;

    // Note: a positive test (well-formed CA → parses) needs a real
    // X.509 blob, which we'd either commit (drifts) or generate via
    // `rcgen`. Generating via rcgen costs a dev-dep + an extra
    // signature scheme in the linker; not worth it for one assertion.
    // The negative tests below cover the error paths; positive
    // plumbing is exercised end-to-end by the integration smoke when
    // a real operator CA is shipped.

    #[test]
    fn from_pem_rejects_garbage_when_no_certificates() {
        let err = TlsPinning::from_pem(b"not pem at all").unwrap_err();
        match err {
            TlsPinError::NoCertificates => {}
            other => panic!("expected NoCertificates, got {other:?}"),
        }
    }

    #[test]
    fn from_pem_rejects_pem_with_only_private_key() {
        let pem = b"-----BEGIN PRIVATE KEY-----\n\
                    MC4CAQAwBQYDK2VwBCIEIPdiKKLcG6dCfYrZ6yJYWvJyQ0V+sgKqMcsy5cN8s/Lz\n\
                    -----END PRIVATE KEY-----\n";
        match TlsPinning::from_pem(pem).unwrap_err() {
            TlsPinError::NoCertificates => {}
            other => panic!("expected NoCertificates (private key only), got {other:?}"),
        }
    }
}
