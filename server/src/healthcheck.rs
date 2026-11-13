// `sinhron-server --healthcheck` — the Docker healthcheck probe.
//
// The runtime image (debian:bookworm-slim) ships neither wget nor curl,
// so the binary checks itself: one plain HTTP/1.0 GET of `/_healthz` on
// its own listen port, exit 0 on a 200, 1 otherwise. No new deps, no
// extra packages in the image.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::str::FromStr;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// Well under the compose `timeout: 3s`, so a hung server shows up as a
/// probe failure with a message rather than a Docker-side kill.
const PROBE_TIMEOUT: Duration = Duration::from_secs(2);

/// Address the probe connects to: the port from `SINHRON_LISTEN`, with a
/// wildcard bind (`0.0.0.0` / `::`) swapped for loopback.
pub fn probe_addr(listen: &str) -> anyhow::Result<SocketAddr> {
    let mut addr = SocketAddr::from_str(listen)
        .map_err(|e| anyhow::anyhow!("invalid SINHRON_LISTEN={listen}: {e}"))?;
    if addr.ip().is_unspecified() {
        addr.set_ip(match addr.ip() {
            IpAddr::V4(_) => IpAddr::V4(Ipv4Addr::LOCALHOST),
            IpAddr::V6(_) => IpAddr::V6(Ipv6Addr::LOCALHOST),
        });
    }
    Ok(addr)
}

/// GET `/_healthz` at `addr`; Ok only on an HTTP 200.
pub async fn probe(addr: SocketAddr) -> anyhow::Result<()> {
    tokio::time::timeout(PROBE_TIMEOUT, get_healthz(addr))
        .await
        .map_err(|_| anyhow::anyhow!("no answer from {addr} within {PROBE_TIMEOUT:?}"))?
}

async fn get_healthz(addr: SocketAddr) -> anyhow::Result<()> {
    let mut stream = TcpStream::connect(addr)
        .await
        .map_err(|e| anyhow::anyhow!("connect {addr}: {e}"))?;
    // HTTP/1.0: the server closes after the response, so read_to_end ends.
    stream
        .write_all(b"GET /_healthz HTTP/1.0\r\nHost: localhost\r\n\r\n")
        .await?;
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;
    let status_line = response
        .split(|&b| b == b'\n')
        .next()
        .map(|l| String::from_utf8_lossy(l).trim().to_string())
        .unwrap_or_default();
    // "HTTP/1.x 200 OK" — the code is the second word.
    match status_line.split_whitespace().nth(1) {
        Some("200") => Ok(()),
        _ => anyhow::bail!("/_healthz at {addr} answered {status_line:?}"),
    }
}

/// Entry for `--healthcheck`: reads `SINHRON_LISTEN` like [`crate::run`]
/// and returns the process exit code. Prints only on failure — Docker
/// keeps the output in `docker inspect … .State.Health.Log`.
pub async fn run_cli() -> i32 {
    let listen = std::env::var("SINHRON_LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    match async { probe(probe_addr(&listen)?).await }.await {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("healthcheck failed: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[test]
    fn wildcard_bind_probes_loopback() {
        assert_eq!(
            probe_addr("0.0.0.0:8080").unwrap(),
            "127.0.0.1:8080".parse().unwrap()
        );
        assert_eq!(
            probe_addr("[::]:9000").unwrap(),
            "[::1]:9000".parse().unwrap()
        );
        assert_eq!(
            probe_addr("10.0.0.5:8080").unwrap(),
            "10.0.0.5:8080".parse().unwrap()
        );
        assert!(probe_addr("not-an-addr").is_err());
    }

    #[tokio::test]
    async fn healthy_server_passes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let app = crate::build_app(crate::tests::no_db_state());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        probe(addr).await.unwrap();
    }

    #[tokio::test]
    async fn closed_port_fails() {
        // Bind then drop: the port is free, nothing listens.
        let addr = TcpListener::bind("127.0.0.1:0")
            .await
            .unwrap()
            .local_addr()
            .unwrap();
        assert!(probe(addr).await.is_err());
    }

    #[tokio::test]
    async fn non_200_fails() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 256];
            let _ = s.read(&mut buf).await;
            s.write_all(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .await
                .unwrap();
        });
        let err = probe(addr).await.unwrap_err().to_string();
        assert!(err.contains("503"), "{err}");
    }
}
