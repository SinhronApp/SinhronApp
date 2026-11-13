// ADR-072 — what the app's resolver decides for a server, on this network.
//
//   cargo run -p sinhron_net --example dns_check -- https://chat.777400777.xyz
//
// Prints the system answer, whether it passes the TLS check, and the address
// the app would use (system / DoH / none). Real network: on a network whose
// DNS lies (one ISP), this asks Cloudflare / Google.

use std::sync::Arc;

use sinhron_net::dns::{tls_probe, webpki_config, Backend, NetBackend, Resolver};

#[tokio::main]
async fn main() {
    let url = std::env::args().nth(1).unwrap_or_else(|| "https://chat.777400777.xyz".into());
    let host = url::Url::parse(&url).ok().and_then(|u| u.host_str().map(str::to_string)).expect("https://host URL");
    let backend = Arc::new(NetBackend::new());

    match backend.system(&host).await {
        Ok(ips) => {
            println!("system answer: {ips:?}");
            for ip in ips {
                let p = tls_probe(webpki_config(), &host, std::net::SocketAddr::new(ip, 443)).await;
                println!("  {ip}: {p:?}");
            }
        }
        Err(e) => println!("system answer: error {e}"),
    }

    let r = Arc::new(Resolver::new(backend));
    r.add_our_host(&url);
    let addrs = r.resolve(&host, 443).await;
    println!("app uses: {addrs:?} (via {:?}, override {:?})", r.via(&host), r.override_ip(&host));
}
