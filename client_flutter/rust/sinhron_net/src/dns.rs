// Our server's address when the phone's DNS answers wrong — ADR-072.
//
// Found 2026-10-22: one ISP answers `chat.777400777.xyz`
// with one of its own hosts (80.179.79.171, a foreign TLS certificate),
// while 1.1.1.1 / 8.8.8.8 / Quad9 / Yandex give our 176.124.223.138. The
// TLS check refused the ISP's host — correctly — and the app said "no
// connection to the server".
//
// For OUR hosts only (the API / WS host, LiveKit, TURN — registered with
// [`Resolver::add_our_host`] from their https/wss URLs):
//
//   1. The system answer, checked: a TLS handshake to it with SNI and the
//      certificate check for our host name (the same trust the real
//      connection uses). Passes → used, remembered (no check next time
//      while the system keeps giving that address).
//   2. It fails (wrong certificate, no connection, no answer) → an address
//      we checked before, if any, checked again.
//   3. Still nothing → DNS-over-HTTPS: Cloudflare `https://1.1.1.1/dns-query`,
//      then Google `https://8.8.8.8/resolve` (by IP — no DNS needed), each
//      answer checked the same way. The good one is remembered (local
//      encrypted storage, via the hook the app sets) and used first next
//      time; a background re-check moves back to the system answer as soon
//      as it is right again.
//
// The address is the only thing that changes: the connection still runs
// TLS with SNI and the certificate check for our host name, so the ISP's
// host (or anyone's) is never accepted. Nothing verified → the plain
// system answer goes back and the real connection fails its TLS check,
// exactly as before.
//
// Privacy: a DoH query tells Cloudflare / Google our host name (only when
// the system answer failed) — docs/threat-model.md.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock, RwLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rustls::pki_types::ServerName;
use rustls::ClientConfig;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

/// TCP + TLS handshake of one address check.
const PROBE_TIMEOUT: Duration = Duration::from_secs(4);
/// The system resolver's answer.
const SYSTEM_TIMEOUT: Duration = Duration::from_secs(4);
/// One DoH query (A and AAAA go together).
const DOH_TIMEOUT: Duration = Duration::from_secs(4);
/// A checked system answer stays trusted this long while the system keeps
/// giving the same address (no new check on every connection).
const SYSTEM_TTL_SECS: u64 = 24 * 3600;
/// A DoH / kept address: used without a re-check for its DNS TTL, clamped…
const FALLBACK_TTL_MIN_SECS: u64 = 5 * 60;
const FALLBACK_TTL_MAX_SECS: u64 = 3600;
/// …and after that still used first (re-checked in the background) for up to
/// a week — a phone that reached us once keeps reaching us.
const MAX_STALE_SECS: u64 = 7 * 24 * 3600;
/// A background re-check that found nothing waits this long before the next.
const RECHECK_MIN_SECS: u64 = 5 * 60;
/// After a full check found nothing (offline, server down), the next ones
/// within this window skip the checks and the DoH query.
const FAILED_CHECK_PAUSE_SECS: u64 = 30;
/// Persisted cache format.
const CACHE_VERSION: u32 = 1;

/// DoH JSON endpoints, by IP so they need no DNS themselves; tried in order.
pub const DOH_ENDPOINTS: &[&str] = &["https://1.1.1.1/dns-query", "https://8.8.8.8/resolve"];

type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Where an address came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Via {
    /// The system resolver's answer, checked.
    System,
    /// DNS-over-HTTPS (the system answer was wrong).
    Doh,
    /// An address checked earlier, checked again (system and DoH failed).
    Kept,
}

/// Result of one address check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Probe {
    /// TLS came up and the certificate is valid for our host.
    Ok,
    /// Something answered, but not with our certificate (the ISP's host).
    BadCert(String),
    /// No TCP / TLS within [`PROBE_TIMEOUT`].
    Unreachable(String),
}

/// The network side of the resolver — real in the app, fake in tests.
pub trait Backend: Send + Sync + 'static {
    /// The system resolver's addresses for `host`.
    fn system<'a>(&'a self, host: &'a str) -> BoxFut<'a, io::Result<Vec<IpAddr>>>;
    /// DoH answers for `host`: (address, TTL seconds); empty when every
    /// endpoint failed.
    fn doh<'a>(&'a self, host: &'a str) -> BoxFut<'a, Vec<(IpAddr, u64)>>;
    /// TLS handshake to `addr` with SNI + certificate check for `host`.
    fn probe<'a>(&'a self, host: &'a str, addr: SocketAddr) -> BoxFut<'a, Probe>;
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    ips: Vec<IpAddr>,
    via: Via,
    /// When it was last checked (unix seconds).
    at: u64,
    /// Seconds after `at` it is used without a re-check.
    ttl: u64,
}

impl Entry {
    fn fresh(&self, now: u64) -> bool {
        now < self.at.saturating_add(self.ttl)
    }
    fn usable(&self, now: u64) -> bool {
        now < self.at.saturating_add(self.ttl.max(MAX_STALE_SECS))
    }
}

#[derive(Default)]
struct State {
    /// Our hosts → the TLS port to check them on.
    ours: HashMap<String, u16>,
    entries: HashMap<String, Entry>,
    /// Host → earliest next background re-check (unix seconds).
    next_recheck: HashMap<String, u64>,
    rechecking: HashSet<String>,
    /// Host → when a full check last found nothing.
    failed_at: HashMap<String, u64>,
}

#[derive(Serialize, Deserialize)]
struct Saved {
    v: u32,
    hosts: HashMap<String, Entry>,
}

type PersistFn = Arc<dyn Fn(String) + Send + Sync>;

pub struct Resolver {
    backend: Arc<dyn Backend>,
    state: Mutex<State>,
    /// One check at a time per host (a cold start fires several requests).
    locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
    persist: RwLock<Option<PersistFn>>,
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
}

impl Resolver {
    pub fn new(backend: Arc<dyn Backend>) -> Self {
        Self::with_clock(backend, Arc::new(unix_now))
    }

    /// [`Resolver::new`] with a test clock (unix seconds).
    pub fn with_clock(backend: Arc<dyn Backend>, clock: Arc<dyn Fn() -> u64 + Send + Sync>) -> Self {
        Self {
            backend,
            state: Mutex::new(State::default()),
            locks: Mutex::new(HashMap::new()),
            persist: RwLock::new(None),
            clock,
        }
    }

    fn now(&self) -> u64 {
        (self.clock)()
    }

    fn st(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Mark the host of an `https://` / `wss://` URL as ours. Plain http/ws
    /// (dev), IP literals and bad URLs are ignored.
    pub fn add_our_host(&self, url: &str) {
        let Ok(u) = url::Url::parse(url.trim()) else { return };
        if !matches!(u.scheme(), "https" | "wss") {
            return;
        }
        let Some(url::Host::Domain(host)) = u.host() else { return };
        let host = normalize(host);
        let port = u.port().unwrap_or(443);
        self.st().ours.entry(host).or_insert(port);
    }

    /// The TLS port of one of our hosts, `None` for anyone else's.
    pub fn our_port(&self, host: &str) -> Option<u16> {
        self.st().ours.get(&normalize(host)).copied()
    }

    /// Where the app persists the cache (the encrypted settings table);
    /// called with the whole cache as JSON after every change.
    pub fn set_persist(&self, f: Option<PersistFn>) {
        if let Ok(mut g) = self.persist.write() {
            *g = f;
        }
    }

    /// Load the persisted cache (bad / old JSON is ignored).
    pub fn load(&self, json: &str) {
        let Ok(saved) = serde_json::from_str::<Saved>(json) else { return };
        if saved.v != CACHE_VERSION {
            return;
        }
        let now = self.now();
        let mut st = self.st();
        for (host, e) in saved.hosts {
            if e.usable(now) && !e.ips.is_empty() {
                st.entries.entry(normalize(&host)).or_insert(e);
            }
        }
    }

    /// The cache as JSON (what [`Resolver::set_persist`] gets).
    pub fn export(&self) -> String {
        let hosts = self.st().entries.clone();
        serde_json::to_string(&Saved { v: CACHE_VERSION, hosts }).unwrap_or_default()
    }

    fn save(&self) {
        let f = self.persist.read().ok().and_then(|g| g.clone());
        if let Some(f) = f {
            f(self.export());
        }
    }

    fn store(&self, host: &str, e: Entry) {
        {
            let mut st = self.st();
            st.failed_at.remove(host);
            st.entries.insert(host.to_string(), e);
        }
        self.save();
    }

    fn entry(&self, host: &str) -> Option<Entry> {
        self.st().entries.get(host).cloned()
    }

    /// How a host is reached now: `None` = the system answer (or unknown).
    pub fn via(&self, host: &str) -> Option<Via> {
        let now = self.now();
        self.st().entries.get(&normalize(host)).filter(|e| e.usable(now)).map(|e| e.via)
    }

    /// The address to use INSTEAD of the system answer for one of our hosts
    /// — set only when the system answer was proven wrong (DoH or a kept
    /// address). No network; the Dart side and TURN URLs use it.
    pub fn override_ip(&self, host: &str) -> Option<IpAddr> {
        let now = self.now();
        let st = self.st();
        let e = st.entries.get(&normalize(host))?;
        (e.via != Via::System && e.usable(now)).then(|| e.ips.first().copied()).flatten()
    }

    /// A real connection to `ip` failed its TLS check: never use it again.
    pub fn note_bad(&self, host: &str, ip: IpAddr) {
        let host = normalize(host);
        let changed = {
            let mut st = self.st();
            let mut changed = false;
            let mut empty = false;
            if let Some(e) = st.entries.get_mut(&host) {
                let before = e.ips.len();
                e.ips.retain(|i| *i != ip);
                changed = e.ips.len() != before;
                empty = e.ips.is_empty();
            }
            if empty {
                st.entries.remove(&host);
            }
            changed
        };
        if changed {
            warn!(host = %host, ip = %ip, "dns: address failed TLS — dropped");
            self.save();
        }
    }

    /// Addresses for `host`, checked ones first. Not our host → the system
    /// resolver, untouched.
    pub async fn resolve(self: &Arc<Self>, host: &str, port: u16) -> io::Result<Vec<SocketAddr>> {
        if let Ok(ip) = host.trim_start_matches('[').trim_end_matches(']').parse::<IpAddr>() {
            return Ok(vec![SocketAddr::new(ip, port)]);
        }
        let host = normalize(host);
        let Some(tls_port) = self.our_port(&host) else {
            let ips = timed_system(&*self.backend, &host).await?;
            return Ok(to_addrs(&ips, port));
        };
        // In its own task: a caller that gives up (reqwest's connect timeout)
        // doesn't cancel a check half-way — the next caller finds its result.
        let me = self.clone();
        tokio::spawn(async move { me.resolve_ours(host, tls_port, port).await })
            .await
            .unwrap_or_else(|e| Err(io::Error::other(e)))
    }

    async fn resolve_ours(self: Arc<Self>, host: String, tls_port: u16, port: u16) -> io::Result<Vec<SocketAddr>> {
        let lock = self.host_lock(&host);
        let _one = lock.lock().await;
        let now = self.now();
        let paused = self.st().failed_at.get(&host).is_some_and(|t| now < t + FAILED_CHECK_PAUSE_SECS);
        if let Some(e) = self.entry(&host).filter(|e| e.usable(now)) {
            match e.via {
                Via::Doh | Via::Kept => {
                    if !e.fresh(now) {
                        self.spawn_recheck(&host, tls_port);
                    }
                    return Ok(to_addrs(&e.ips, port));
                }
                Via::System => {
                    let sys = timed_system(&*self.backend, &host).await.unwrap_or_default();
                    if sys.iter().any(|ip| e.ips.contains(ip)) {
                        // The same answer we checked: no new check.
                        let mut ips: Vec<IpAddr> = sys.iter().copied().filter(|ip| e.ips.contains(ip)).collect();
                        ips.extend(sys.iter().copied().filter(|ip| !e.ips.contains(ip)));
                        return Ok(to_addrs(&ips, port));
                    }
                    if paused {
                        return Ok(to_addrs(if sys.is_empty() { &e.ips } else { &sys }, port));
                    }
                    return self.check(&host, tls_port, port, Some(Ok(sys))).await;
                }
            }
        }
        if paused {
            let ips = timed_system(&*self.backend, &host).await?;
            return Ok(to_addrs(&ips, port));
        }
        self.check(&host, tls_port, port, None).await
    }

    /// [`Resolver::resolve`] for a connection the caller makes itself (the
    /// Dart side): the address to connect to instead of the system answer,
    /// or `None` to resolve as usual.
    pub async fn override_for(self: &Arc<Self>, host: &str, port: u16) -> Option<IpAddr> {
        self.our_port(host)?;
        let _ = self.resolve(host, port).await;
        self.override_ip(host)
    }

    fn host_lock(&self, host: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut g = self.locks.lock().unwrap_or_else(|e| e.into_inner());
        g.entry(host.to_string()).or_default().clone()
    }

    /// The full check: system answer → a kept address → DoH. Stores what
    /// passed. Nothing passed → the unchecked addresses go back (the real
    /// connection's TLS check refuses a wrong one).
    async fn check(
        &self,
        host: &str,
        tls_port: u16,
        port: u16,
        sys: Option<io::Result<Vec<IpAddr>>>,
    ) -> io::Result<Vec<SocketAddr>> {
        let sys = match sys {
            Some(s) => s,
            None => timed_system(&*self.backend, host).await,
        };
        let old = self.entry(host);
        let mut tried: Vec<IpAddr> = Vec::new();

        // 1. The system answer.
        if let Some(&ip) = sys.as_ref().ok().and_then(|s| s.first()) {
            tried.push(ip);
            match self.backend.probe(host, SocketAddr::new(ip, tls_port)).await {
                Probe::Ok => {
                    let ips = sys.as_ref().map(|s| s.clone()).unwrap_or_default();
                    if old.as_ref().map(|o| o.via) != Some(Via::System) {
                        info!(host, "dns: system answer checked — using it");
                    }
                    self.store(host, Entry { ips: ips.clone(), via: Via::System, at: self.now(), ttl: SYSTEM_TTL_SECS });
                    return Ok(to_addrs(&ips, port));
                }
                p => warn!(host, ip = %ip, probe = ?p, "dns: system answer failed the check"),
            }
        } else if let Err(e) = &sys {
            warn!(host, error = %e, "dns: no system answer");
        }

        // 2. An address that worked before (no DoH query, nothing leaks).
        if let Some(o) = &old {
            for &ip in &o.ips {
                if tried.contains(&ip) {
                    continue;
                }
                tried.push(ip);
                if self.backend.probe(host, SocketAddr::new(ip, tls_port)).await == Probe::Ok {
                    let via = if o.via == Via::System { Via::Kept } else { o.via };
                    let ttl = if o.via == Via::System { FALLBACK_TTL_MIN_SECS } else { o.ttl };
                    info!(host, ip = %ip, ?via, "dns: earlier address still good — using it");
                    self.store(host, Entry { ips: vec![ip], via, at: self.now(), ttl });
                    return Ok(to_addrs(&[ip], port));
                }
            }
        }

        // 3. DNS-over-HTTPS.
        let doh = self.backend.doh(host).await;
        for &(ip, ttl) in &doh {
            if tried.contains(&ip) {
                continue;
            }
            tried.push(ip);
            match self.backend.probe(host, SocketAddr::new(ip, tls_port)).await {
                Probe::Ok => {
                    let mut ips = vec![ip];
                    ips.extend(doh.iter().map(|d| d.0).filter(|i| *i != ip));
                    ips.dedup();
                    let ttl = ttl.clamp(FALLBACK_TTL_MIN_SECS, FALLBACK_TTL_MAX_SECS);
                    info!(host, ip = %ip, "dns: system answer wrong — using the DoH answer");
                    self.store(host, Entry { ips: ips.clone(), via: Via::Doh, at: self.now(), ttl });
                    return Ok(to_addrs(&ips, port));
                }
                p => warn!(host, ip = %ip, probe = ?p, "dns: DoH answer failed the check"),
            }
        }

        // Nothing checked out (offline, or our server is down): what we have,
        // unchecked — never with a weaker TLS check.
        self.st().failed_at.insert(host.to_string(), self.now());
        match sys {
            Ok(s) if !s.is_empty() => Ok(to_addrs(&s, port)),
            other => {
                let mut ips: Vec<IpAddr> = doh.iter().map(|d| d.0).collect();
                if let Some(o) = old {
                    ips.extend(o.ips);
                }
                ips.dedup();
                if ips.is_empty() {
                    Err(other.err().unwrap_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no address")))
                } else {
                    Ok(to_addrs(&ips, port))
                }
            }
        }
    }

    /// Re-check a DoH / kept address in the background — back to the system
    /// answer as soon as it is right again. Needs a tokio runtime.
    fn spawn_recheck(self: &Arc<Self>, host: &str, tls_port: u16) {
        let now = self.now();
        {
            let mut st = self.st();
            if st.rechecking.contains(host) || st.next_recheck.get(host).is_some_and(|t| now < *t) {
                return;
            }
            if tokio::runtime::Handle::try_current().is_err() {
                return;
            }
            st.rechecking.insert(host.to_string());
            st.next_recheck.insert(host.to_string(), now + RECHECK_MIN_SECS);
        }
        let me = self.clone();
        let host = host.to_string();
        tokio::spawn(async move {
            {
                let lock = me.host_lock(&host);
                let _one = lock.lock().await;
                let _ = me.check(&host, tls_port, tls_port, None).await;
            }
            me.st().rechecking.remove(&host);
        });
    }

    /// Wait until no background re-check runs (tests).
    pub async fn settle(&self) {
        for _ in 0..500 {
            if self.st().rechecking.is_empty() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

fn normalize(host: &str) -> String {
    host.trim().trim_end_matches('.').to_ascii_lowercase()
}

fn to_addrs(ips: &[IpAddr], port: u16) -> Vec<SocketAddr> {
    ips.iter().map(|ip| SocketAddr::new(*ip, port)).collect()
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

async fn timed_system(b: &dyn Backend, host: &str) -> io::Result<Vec<IpAddr>> {
    match tokio::time::timeout(SYSTEM_TIMEOUT, b.system(host)).await {
        Ok(Ok(v)) if v.is_empty() => Err(io::Error::new(io::ErrorKind::NotFound, "empty system answer")),
        Ok(r) => r,
        Err(_) => Err(io::Error::new(io::ErrorKind::TimedOut, "system resolver timed out")),
    }
}

// ─── The real network side ───────────────────────────────────────────

/// System resolver + DoH over reqwest + a TLS check with the trust the real
/// connections use (webpki roots, or the pinned operator CA).
pub struct NetBackend {
    tls: RwLock<Arc<ClientConfig>>,
    doh_endpoints: Vec<String>,
}

impl NetBackend {
    pub fn new() -> Self {
        Self::with_trust(webpki_config(), DOH_ENDPOINTS.iter().map(|s| s.to_string()).collect())
    }

    /// Custom trust and DoH endpoints (tests; a pinned operator CA).
    pub fn with_trust(tls: Arc<ClientConfig>, doh_endpoints: Vec<String>) -> Self {
        Self { tls: RwLock::new(tls), doh_endpoints }
    }

    /// Check addresses against the pinned operator CA instead (WU B3).
    pub fn set_trust(&self, tls: Arc<ClientConfig>) {
        if let Ok(mut g) = self.tls.write() {
            *g = tls;
        }
    }

    fn trust(&self) -> Arc<ClientConfig> {
        self.tls.read().map(|g| g.clone()).unwrap_or_else(|e| e.into_inner().clone())
    }
}

impl Default for NetBackend {
    fn default() -> Self {
        Self::new()
    }
}

/// The trust store the default WS / HTTP clients use.
pub fn webpki_config() -> Arc<ClientConfig> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    tls_config(roots)
}

/// A client config over `roots` with the ring provider (the one in the app).
pub fn tls_config(roots: rustls::RootCertStore) -> Arc<ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cfg = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .expect("ring supports the default TLS versions")
        .with_root_certificates(roots)
        .with_no_client_auth();
    Arc::new(cfg)
}

impl Backend for NetBackend {
    fn system<'a>(&'a self, host: &'a str) -> BoxFut<'a, io::Result<Vec<IpAddr>>> {
        Box::pin(async move {
            let mut ips: Vec<IpAddr> = tokio::net::lookup_host((host, 443)).await?.map(|a| a.ip()).collect();
            ips.dedup();
            Ok(ips)
        })
    }

    fn doh<'a>(&'a self, host: &'a str) -> BoxFut<'a, Vec<(IpAddr, u64)>> {
        Box::pin(async move {
            // No proxy, no custom resolver: the endpoints are IP addresses.
            let Ok(client) = reqwest::Client::builder().no_proxy().timeout(DOH_TIMEOUT).build() else {
                return Vec::new();
            };
            // One service after the other (the second learns the name only
            // when the first failed); IPv4 first.
            for ep in &self.doh_endpoints {
                let (a, aaaa) = tokio::join!(doh_query(&client, ep, host, "A"), doh_query(&client, ep, host, "AAAA"));
                let mut out = Vec::new();
                for (kind, r) in [("A", a), ("AAAA", aaaa)] {
                    match r {
                        Ok(v) => out.extend(v),
                        Err(e) => warn!(endpoint = %ep, kind, error = %e, "dns: DoH query failed"),
                    }
                }
                if !out.is_empty() {
                    return out;
                }
            }
            Vec::new()
        })
    }

    fn probe<'a>(&'a self, host: &'a str, addr: SocketAddr) -> BoxFut<'a, Probe> {
        Box::pin(async move { tls_probe(self.trust(), host, addr).await })
    }
}

async fn doh_query(client: &reqwest::Client, endpoint: &str, host: &str, kind: &str) -> Result<Vec<(IpAddr, u64)>, String> {
    let resp = client
        .get(endpoint)
        .query(&[("name", host), ("type", kind)])
        .header("accept", "application/dns-json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("HTTP {}", resp.status()));
    }
    let body = resp.text().await.map_err(|e| e.to_string())?;
    parse_doh_json(&body, kind)
}

/// The DoH JSON answer (Cloudflare and Google share it): the A / AAAA
/// records, CNAMEs skipped.
pub fn parse_doh_json(body: &str, kind: &str) -> Result<Vec<(IpAddr, u64)>, String> {
    #[derive(Deserialize)]
    struct Answer {
        #[serde(rename = "type")]
        kind: u16,
        #[serde(rename = "TTL", default)]
        ttl: u64,
        data: String,
    }
    #[derive(Deserialize)]
    struct Reply {
        #[serde(rename = "Status")]
        status: u32,
        #[serde(rename = "Answer", default)]
        answer: Vec<Answer>,
    }
    let r: Reply = serde_json::from_str(body).map_err(|e| format!("bad DoH JSON: {e}"))?;
    if r.status != 0 {
        return Err(format!("DNS status {}", r.status));
    }
    let want = if kind == "AAAA" { 28 } else { 1 };
    Ok(r.answer
        .into_iter()
        .filter(|a| a.kind == want)
        .filter_map(|a| a.data.trim().parse::<IpAddr>().ok().map(|ip| (ip, a.ttl)))
        .collect())
}

/// TCP + TLS handshake to `addr` with SNI and the certificate check for
/// `host`, then close.
pub async fn tls_probe(cfg: Arc<ClientConfig>, host: &str, addr: SocketAddr) -> Probe {
    let Ok(name) = ServerName::try_from(host.to_string()) else {
        return Probe::BadCert(format!("not a host name: {host}"));
    };
    let run = async {
        let tcp = tokio::net::TcpStream::connect(addr).await.map_err(|e| Probe::Unreachable(e.to_string()))?;
        let tls = tokio_rustls::TlsConnector::from(cfg);
        match tls.connect(name, tcp).await {
            Ok(_) => Ok(()),
            Err(e) => Err(if is_cert_error(&e) { Probe::BadCert(e.to_string()) } else { Probe::Unreachable(e.to_string()) }),
        }
    };
    match tokio::time::timeout(PROBE_TIMEOUT, run).await {
        Ok(Ok(())) => Probe::Ok,
        Ok(Err(p)) => p,
        Err(_) => Probe::Unreachable(format!("no TLS within {} s", PROBE_TIMEOUT.as_secs())),
    }
}

/// A TLS handshake refused the server's certificate (rustls inside an io error).
pub fn is_cert_error(e: &io::Error) -> bool {
    matches!(
        e.get_ref().and_then(|i| i.downcast_ref::<rustls::Error>()),
        Some(rustls::Error::InvalidCertificate(_)) | Some(rustls::Error::NoCertificatesPresented)
    )
}

/// Any TLS-level failure (certificate or protocol) in an io error.
pub fn is_tls_error(e: &io::Error) -> bool {
    e.get_ref().and_then(|i| i.downcast_ref::<rustls::Error>()).is_some()
}

// ─── Process-wide resolver ────────────────────────────────────────────

static GLOBAL: OnceLock<(Arc<Resolver>, Arc<NetBackend>)> = OnceLock::new();

fn global_pair() -> &'static (Arc<Resolver>, Arc<NetBackend>) {
    GLOBAL.get_or_init(|| {
        let backend = Arc::new(NetBackend::new());
        (Arc::new(Resolver::new(backend.clone())), backend)
    })
}

/// The resolver every connection to our server uses.
pub fn global() -> &'static Arc<Resolver> {
    &global_pair().0
}

/// The pinned operator CA (WU B3) for the address check too.
pub fn set_probe_trust(tls: Arc<ClientConfig>) {
    global_pair().1.set_trust(tls);
}

/// reqwest's resolver hook: [`Resolver::resolve`] for our hosts, the system
/// resolver for everyone else. Port 0: hyper puts the URL's port on it.
#[derive(Clone)]
pub struct ReqwestDns(pub Arc<Resolver>);

impl reqwest::dns::Resolve for ReqwestDns {
    fn resolve(&self, name: reqwest::dns::Name) -> reqwest::dns::Resolving {
        let r = self.0.clone();
        let host = name.as_str().to_string();
        Box::pin(async move {
            let addrs = r.resolve(&host, 0).await?;
            Ok(Box::new(addrs.into_iter()) as reqwest::dns::Addrs)
        })
    }
}

/// [`ReqwestDns`] over the process-wide resolver.
pub fn reqwest_resolver() -> Arc<ReqwestDns> {
    Arc::new(ReqwestDns(global().clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

    const HOST: &str = "chat.sinhron.test";
    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }
    // The owner's case: the ISP answers with its host, DoH with ours.
    fn isp() -> IpAddr {
        ip("80.179.79.171")
    }
    fn ours() -> IpAddr {
        ip("176.124.223.138")
    }

    /// Fake network: fixed answers, a set of addresses with our certificate.
    struct Fake {
        system: Mutex<io::Result<Vec<IpAddr>>>,
        doh: Mutex<Vec<(IpAddr, u64)>>,
        good: Mutex<HashSet<IpAddr>>,
        probes: Mutex<Vec<IpAddr>>,
        doh_calls: AtomicUsize,
    }

    impl Fake {
        fn new(system: Vec<IpAddr>, doh: Vec<IpAddr>, good: &[IpAddr]) -> Arc<Self> {
            Arc::new(Self {
                system: Mutex::new(Ok(system)),
                doh: Mutex::new(doh.into_iter().map(|i| (i, 300)).collect()),
                good: Mutex::new(good.iter().copied().collect()),
                probes: Mutex::new(Vec::new()),
                doh_calls: AtomicUsize::new(0),
            })
        }
        fn probes(&self) -> Vec<IpAddr> {
            self.probes.lock().unwrap().clone()
        }
    }

    impl Backend for Fake {
        fn system<'a>(&'a self, _host: &'a str) -> BoxFut<'a, io::Result<Vec<IpAddr>>> {
            let r = match &*self.system.lock().unwrap() {
                Ok(v) => Ok(v.clone()),
                Err(e) => Err(io::Error::new(e.kind(), e.to_string())),
            };
            Box::pin(async move { r })
        }
        fn doh<'a>(&'a self, _host: &'a str) -> BoxFut<'a, Vec<(IpAddr, u64)>> {
            self.doh_calls.fetch_add(1, Ordering::SeqCst);
            let v = self.doh.lock().unwrap().clone();
            Box::pin(async move { v })
        }
        fn probe<'a>(&'a self, _host: &'a str, addr: SocketAddr) -> BoxFut<'a, Probe> {
            self.probes.lock().unwrap().push(addr.ip());
            let ok = self.good.lock().unwrap().contains(&addr.ip());
            Box::pin(async move { if ok { Probe::Ok } else { Probe::BadCert("not our certificate".into()) } })
        }
    }

    fn resolver(f: &Arc<Fake>) -> (Arc<Resolver>, Arc<AtomicU64>) {
        let t = Arc::new(AtomicU64::new(1_800_000_000));
        let tc = t.clone();
        let r = Arc::new(Resolver::with_clock(f.clone(), Arc::new(move || tc.load(Ordering::SeqCst))));
        r.add_our_host(&format!("https://{HOST}"));
        (r, t)
    }

    #[tokio::test]
    async fn system_answer_that_passes_is_used_and_doh_never_asked() {
        let f = Fake::new(vec![ours()], vec![ours()], &[ours()]);
        let (r, _) = resolver(&f);
        let a = r.resolve(HOST, 443).await.unwrap();
        assert_eq!(a, vec![SocketAddr::new(ours(), 443)]);
        assert_eq!(f.doh_calls.load(Ordering::SeqCst), 0, "no DoH while the system answer works (privacy)");
        assert_eq!(r.via(HOST), Some(Via::System));
        assert_eq!(r.override_ip(HOST), None);
        // Same answer next time: no second check.
        r.resolve(HOST, 443).await.unwrap();
        assert_eq!(f.probes(), vec![ours()]);
    }

    #[tokio::test]
    async fn wrong_system_answer_falls_back_to_doh() {
        // The ISP's host fails the certificate check → DoH → ours.
        let f = Fake::new(vec![isp()], vec![ours()], &[ours()]);
        let (r, _) = resolver(&f);
        let a = r.resolve(HOST, 443).await.unwrap();
        assert_eq!(a, vec![SocketAddr::new(ours(), 443)]);
        assert_eq!(f.probes(), vec![isp(), ours()]);
        assert_eq!(r.via(HOST), Some(Via::Doh));
        assert_eq!(r.override_ip(HOST), Some(ours()));
    }

    #[tokio::test]
    async fn no_system_answer_falls_back_to_doh() {
        let f = Fake::new(vec![], vec![ours()], &[ours()]);
        *f.system.lock().unwrap() = Err(io::Error::new(io::ErrorKind::Other, "NXDOMAIN"));
        let (r, _) = resolver(&f);
        assert_eq!(r.resolve(HOST, 443).await.unwrap(), vec![SocketAddr::new(ours(), 443)]);
    }

    #[tokio::test]
    async fn remembered_address_is_used_first_next_time() {
        let f = Fake::new(vec![isp()], vec![ours()], &[ours()]);
        let (r, _) = resolver(&f);
        r.resolve(HOST, 443).await.unwrap();
        let saved = r.export();

        // App restart: a new resolver with the saved cache — no checks, no DoH.
        let f2 = Fake::new(vec![isp()], vec![], &[ours()]);
        let (r2, _) = resolver(&f2);
        r2.load(&saved);
        assert_eq!(r2.resolve(HOST, 8443).await.unwrap(), vec![SocketAddr::new(ours(), 8443)]);
        assert!(f2.probes().is_empty());
        assert_eq!(f2.doh_calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn stale_doh_address_still_used_and_rechecked_in_background() {
        let f = Fake::new(vec![isp()], vec![ours()], &[ours()]);
        let (r, t) = resolver(&f);
        r.resolve(HOST, 443).await.unwrap();
        // The ISP fixed its DNS; an hour later the DoH entry is stale.
        *f.system.lock().unwrap() = Ok(vec![ours()]);
        t.fetch_add(2 * 3600, Ordering::SeqCst);
        assert_eq!(r.resolve(HOST, 443).await.unwrap(), vec![SocketAddr::new(ours(), 443)]);
        r.settle().await;
        assert_eq!(r.via(HOST), Some(Via::System), "back on the system answer");
        assert_eq!(r.override_ip(HOST), None);
    }

    #[tokio::test]
    async fn doh_blocked_but_earlier_address_still_reached() {
        // Worked via the system yesterday; today the ISP lies and DoH is blocked.
        let f = Fake::new(vec![ours()], vec![], &[ours()]);
        let (r, t) = resolver(&f);
        r.resolve(HOST, 443).await.unwrap();
        *f.system.lock().unwrap() = Ok(vec![isp()]);
        t.fetch_add(60, Ordering::SeqCst);
        assert_eq!(r.resolve(HOST, 443).await.unwrap(), vec![SocketAddr::new(ours(), 443)]);
        assert_eq!(r.via(HOST), Some(Via::Kept));
        assert_eq!(r.override_ip(HOST), Some(ours()));
        assert_eq!(f.doh_calls.load(Ordering::SeqCst), 0, "a kept address is tried before DoH");
    }

    #[tokio::test]
    async fn nothing_passes_returns_unchecked_answer_and_remembers_nothing() {
        // Every answer has a wrong certificate: hand back the system answer
        // unchecked; the real connection's TLS check refuses it.
        let f = Fake::new(vec![isp()], vec![ip("203.0.113.9")], &[]);
        let (r, _) = resolver(&f);
        assert_eq!(r.resolve(HOST, 443).await.unwrap(), vec![SocketAddr::new(isp(), 443)]);
        assert_eq!(r.via(HOST), None);
        assert_eq!(r.override_ip(HOST), None);
        assert_eq!(r.export(), r#"{"v":1,"hosts":{}}"#);
    }

    #[tokio::test]
    async fn a_failed_check_is_not_repeated_on_every_connection() {
        // Offline / our server down: one full check, then a pause.
        let f = Fake::new(vec![ours()], vec![ours()], &[]);
        let (r, t) = resolver(&f);
        r.resolve(HOST, 443).await.unwrap();
        r.resolve(HOST, 443).await.unwrap();
        assert_eq!(f.doh_calls.load(Ordering::SeqCst), 1);
        t.fetch_add(FAILED_CHECK_PAUSE_SECS, Ordering::SeqCst);
        r.resolve(HOST, 443).await.unwrap();
        assert_eq!(f.doh_calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn not_our_host_is_left_to_the_system() {
        let f = Fake::new(vec![isp()], vec![ours()], &[ours()]);
        let (r, _) = resolver(&f);
        assert_eq!(r.resolve("example.org", 443).await.unwrap(), vec![SocketAddr::new(isp(), 443)]);
        assert!(f.probes().is_empty());
        assert_eq!(r.override_for("example.org", 443).await, None);
        assert_eq!(r.resolve("10.0.0.1", 80).await.unwrap(), vec![SocketAddr::new(ip("10.0.0.1"), 80)]);
    }

    #[tokio::test]
    async fn bad_tls_on_a_real_connection_drops_the_address() {
        let f = Fake::new(vec![isp()], vec![ours()], &[ours()]);
        let (r, _) = resolver(&f);
        r.resolve(HOST, 443).await.unwrap();
        r.note_bad(HOST, ours());
        assert_eq!(r.via(HOST), None);
    }

    #[test]
    fn only_https_and_wss_hosts_are_ours() {
        let f = Fake::new(vec![], vec![], &[]);
        let r = Resolver::new(f);
        r.add_our_host("http://localhost:8080");
        r.add_our_host("ws://chat.example:80/v1/sync");
        r.add_our_host("https://176.124.223.138");
        r.add_our_host("wss://LiveKit.Chat.Example.");
        r.add_our_host("https://turn.chat.example:8443");
        assert_eq!(r.our_port("localhost"), None);
        assert_eq!(r.our_port("chat.example"), None);
        assert_eq!(r.our_port("livekit.chat.example"), Some(443));
        assert_eq!(r.our_port("turn.chat.example"), Some(8443));
    }

    #[test]
    fn load_ignores_garbage_and_old_entries() {
        let f = Fake::new(vec![], vec![], &[]);
        let r = Resolver::new(f);
        r.load("not json");
        r.load(r#"{"v":99,"hosts":{}}"#);
        r.load(r#"{"v":1,"hosts":{"old.example":{"ips":["1.2.3.4"],"via":"doh","at":1,"ttl":300}}}"#);
        assert_eq!(r.export(), r#"{"v":1,"hosts":{}}"#);
    }

    #[test]
    fn parses_cloudflare_and_google_answers() {
        // Shape of both services' JSON answers (a CNAME, then the A record).
        let body = r#"{"Status":0,"TC":false,"Question":[{"name":"chat.example.","type":1}],
            "Answer":[{"name":"chat.example.","type":5,"TTL":60,"data":"edge.example."},
                      {"name":"edge.example.","type":1,"TTL":299,"data":"176.124.223.138"}]}"#;
        assert_eq!(parse_doh_json(body, "A").unwrap(), vec![(ours(), 299)]);
        assert!(parse_doh_json(r#"{"Status":3}"#, "A").is_err(), "NXDOMAIN");
        assert_eq!(parse_doh_json(r#"{"Status":0}"#, "AAAA").unwrap(), vec![]);
        let v6 = r#"{"Status":0,"Answer":[{"type":28,"TTL":30,"data":"2001:db8::1"}]}"#;
        assert_eq!(parse_doh_json(v6, "AAAA").unwrap(), vec![(ip("2001:db8::1"), 30)]);
    }
}
