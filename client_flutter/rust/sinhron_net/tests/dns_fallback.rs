// ADR-072 — DoH fallback against real TLS servers on loopback.
//
// The ISP's DNS is played by a fake system answer 127.0.0.1, where a
// server shows a certificate for another name (signed by the same trusted
// test CA — a "valid" certificate, just not ours). DoH answers ::1, where
// the server has our certificate for chat.sinhron.test. Same port on both,
// so only the address differs — as on the phone.
//
// Test certificates (tests/data, valid to 2126): ca.pem = test CA;
// good = chat.sinhron.test; wrong = isp-portal.example (same CA);
// selfsigned = chat.sinhron.test, not from the CA.

use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::Arc;

use sinhron_net::dns::{tls_config, tls_probe, Backend, Probe, ReqwestDns, Resolver, Via};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::http::HeaderValue;

const HOST: &str = "chat.sinhron.test";
const CA: &[u8] = include_bytes!("data/ca.pem");
const GOOD: (&[u8], &[u8]) = (include_bytes!("data/good.pem"), include_bytes!("data/good.key"));
const WRONG: (&[u8], &[u8]) = (include_bytes!("data/wrong.pem"), include_bytes!("data/wrong.key"));
const SELF: (&[u8], &[u8]) = (include_bytes!("data/selfsigned.pem"), include_bytes!("data/selfsigned.key"));

fn v4() -> IpAddr {
    "127.0.0.1".parse().unwrap()
}
fn v6() -> IpAddr {
    "::1".parse().unwrap()
}

fn client_tls() -> Arc<rustls::ClientConfig> {
    let mut roots = rustls::RootCertStore::empty();
    for c in rustls_pemfile::certs(&mut &CA[..]) {
        roots.add(c.unwrap()).unwrap();
    }
    tls_config(roots)
}

fn acceptor((cert, key): (&[u8], &[u8])) -> tokio_rustls::TlsAcceptor {
    let certs = rustls_pemfile::certs(&mut &cert[..]).collect::<Result<Vec<_>, _>>().unwrap();
    let key = rustls_pemfile::private_key(&mut &key[..]).unwrap().unwrap();
    let cfg = rustls::ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .unwrap();
    tokio_rustls::TlsAcceptor::from(Arc::new(cfg))
}

#[derive(Clone, Copy)]
enum Serve {
    /// `HTTP/1.1 200` with body `ok` to any request.
    Http,
    /// A WebSocket upgrade answering the `sinhron.v1` subprotocol.
    Ws,
}

fn serve(listener: TcpListener, cert: (&'static [u8], &'static [u8]), mode: Serve) {
    let acc = acceptor(cert);
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { return };
            let acc = acc.clone();
            tokio::spawn(async move {
                let Ok(mut tls) = acc.accept(tcp).await else { return };
                match mode {
                    Serve::Http => {
                        let mut buf = vec![0u8; 4096];
                        let mut got = Vec::new();
                        while !got.windows(4).any(|w| w == b"\r\n\r\n") {
                            match tls.read(&mut buf).await {
                                Ok(0) | Err(_) => return,
                                Ok(n) => got.extend_from_slice(&buf[..n]),
                            }
                        }
                        let _ = tls
                            .write_all(b"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")
                            .await;
                        let _ = tls.shutdown().await;
                    }
                    Serve::Ws => {
                        let cb = |_req: &Request, mut resp: Response| {
                            resp.headers_mut().insert("sec-websocket-protocol", HeaderValue::from_static("sinhron.v1"));
                            Ok(resp)
                        };
                        if let Ok(ws) = tokio_tungstenite::accept_hdr_async(tls, cb).await {
                            // Keep it open until the client goes.
                            let mut ws = ws;
                            use futures_util::StreamExt;
                            while let Some(Ok(_)) = ws.next().await {}
                        }
                    }
                }
            });
        }
    });
}

/// The ISP-like server on 127.0.0.1:P with `isp_cert`, ours on [::1]:P.
async fn servers(isp_cert: (&'static [u8], &'static [u8]), mode: Serve) -> u16 {
    for _ in 0..50 {
        let good = TcpListener::bind((v6(), 0)).await.expect("IPv6 loopback");
        let port = good.local_addr().unwrap().port();
        if let Ok(bad) = TcpListener::bind((v4(), port)).await {
            serve(good, GOOD, mode);
            serve(bad, isp_cert, mode);
            return port;
        }
    }
    panic!("no free port pair");
}

type BoxFut<'a, T> = Pin<Box<dyn std::future::Future<Output = T> + Send + 'a>>;

/// Fake system / DoH answers; the address check is the real TLS one.
struct Net {
    system: Vec<IpAddr>,
    doh: Vec<IpAddr>,
    port: u16,
}

impl Backend for Net {
    fn system<'a>(&'a self, _host: &'a str) -> BoxFut<'a, io::Result<Vec<IpAddr>>> {
        let v = self.system.clone();
        Box::pin(async move { Ok(v) })
    }
    fn doh<'a>(&'a self, _host: &'a str) -> BoxFut<'a, Vec<(IpAddr, u64)>> {
        let v = self.doh.iter().map(|i| (*i, 300)).collect();
        Box::pin(async move { v })
    }
    fn probe<'a>(&'a self, host: &'a str, addr: SocketAddr) -> BoxFut<'a, Probe> {
        // The servers listen on the test port, not 443.
        let addr = SocketAddr::new(addr.ip(), self.port);
        Box::pin(async move { tls_probe(client_tls(), host, addr).await })
    }
}

fn resolver(system: Vec<IpAddr>, doh: Vec<IpAddr>, port: u16) -> Arc<Resolver> {
    let r = Arc::new(Resolver::new(Arc::new(Net { system, doh, port })));
    r.add_our_host(&format!("https://{HOST}"));
    r
}

fn http(r: &Arc<Resolver>) -> reqwest::Client {
    reqwest::Client::builder()
        .use_preconfigured_tls((*client_tls()).clone())
        .dns_resolver(Arc::new(ReqwestDns(r.clone())))
        .no_proxy()
        .build()
        .unwrap()
}

#[tokio::test]
async fn the_check_refuses_a_wrong_or_untrusted_certificate() {
    let port = servers(WRONG, Serve::Http).await;
    assert_eq!(tls_probe(client_tls(), HOST, SocketAddr::new(v6(), port)).await, Probe::Ok);
    assert!(matches!(tls_probe(client_tls(), HOST, SocketAddr::new(v4(), port)).await, Probe::BadCert(_)));
    let port = servers(SELF, Serve::Http).await;
    assert!(matches!(tls_probe(client_tls(), HOST, SocketAddr::new(v4(), port)).await, Probe::BadCert(_)));
    // Nobody there.
    let closed = TcpListener::bind((v4(), 0)).await.unwrap().local_addr().unwrap();
    assert!(matches!(tls_probe(client_tls(), HOST, closed).await, Probe::Unreachable(_)));
}

#[tokio::test]
async fn cert_mismatch_on_the_system_answer_makes_http_go_to_the_doh_address() {
    let port = servers(WRONG, Serve::Http).await;
    let r = resolver(vec![v4()], vec![v6()], port);
    let resp = http(&r).get(format!("https://{HOST}:{port}/v1/push/info")).send().await.expect("reaches our server");
    assert_eq!(resp.text().await.unwrap(), "ok");
    assert_eq!(r.via(HOST), Some(Via::Doh));
    assert_eq!(r.override_ip(HOST), Some(v6()));
}

#[tokio::test]
async fn never_connects_when_only_the_wrong_certificate_answers() {
    let port = servers(WRONG, Serve::Http).await;
    // DoH gives the same bad address: nothing passes.
    let r = resolver(vec![v4()], vec![v4()], port);
    let err = http(&r).get(format!("https://{HOST}:{port}/")).send().await.unwrap_err();
    assert!(err.is_connect() || err.to_string().contains("certificate") || format!("{err:?}").contains("Certificate"), "{err:?}");
    assert_eq!(r.via(HOST), None);
    // Untrusted (self-signed) one for our very name: refused too.
    let port = servers(SELF, Serve::Ws).await;
    let r = resolver(vec![v4()], vec![v4()], port);
    let res = sinhron_net::connect_wss(
        &format!("wss://{HOST}:{port}/v1/sync"),
        Some(tokio_tungstenite::Connector::Rustls(client_tls())),
        &r,
    )
    .await;
    assert!(res.is_err(), "connected to a server without our certificate");
}

#[tokio::test]
async fn websocket_goes_to_the_doh_address_with_our_host_name() {
    let port = servers(WRONG, Serve::Ws).await;
    let r = resolver(vec![v4()], vec![v6()], port);
    let (ws, resp) = sinhron_net::connect_wss(
        &format!("wss://{HOST}:{port}/v1/sync"),
        Some(tokio_tungstenite::Connector::Rustls(client_tls())),
        &r,
    )
    .await
    .expect("upgrade over the DoH address");
    assert_eq!(resp.status(), 101);
    drop(ws);
    assert_eq!(r.via(HOST), Some(Via::Doh));
}

#[tokio::test]
async fn system_answer_that_passes_needs_no_doh() {
    let port = servers(WRONG, Serve::Http).await;
    // The system answer is ours (::1); DoH would say the wrong one — never asked.
    let r = resolver(vec![v6()], vec![v4()], port);
    let resp = http(&r).get(format!("https://{HOST}:{port}/")).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(r.via(HOST), Some(Via::System));
    assert_eq!(r.override_ip(HOST), None);
}
