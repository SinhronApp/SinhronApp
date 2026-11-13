// sinhron_net — client side of the Sinhron WS protocol.
//
// Goal: a small, FFI-friendly client that the Flutter app can drive via
// flutter_rust_bridge. The public surface (in WU B4) will be a handful
// of `pub async fn net_*` functions wrapping a single connection. WU B1
// (this file) sets up the crate + the WsClient struct + the auth
// handshake; reconnect/TLS pinning land in B2/B3.
//
// Threading: the client is `Send + Sync` so the frb worker pool can
// pass it across awaits. Internally we use a single tokio runtime
// (provided by frb) and tokio_tungstenite for the WS transport.

pub mod proto {
    //! Generated protobuf types. Wraps the prost-build output so callers
    //! say `proto::WsFrame` instead of `sinhron::v1::WsFrame`.
    pub mod v1 {
        include!(concat!(env!("OUT_DIR"), "/sinhron.v1.rs"));
    }
    pub use v1::*;
}

mod client;
pub mod clock_drift;
pub mod dns;
pub mod proxy;
pub mod tls;

pub use client::{
    bind_to_host, connect_wss, url_host, ConnectError, Event, Keepalive, SendError, WsClient, WsClientConfig,
    WS_AUTH_DOMAIN,
};
pub use proxy::{set_socks_proxy, socks_proxy, socks_proxy_url};
pub use tls::{TlsPinError, TlsPinning};
