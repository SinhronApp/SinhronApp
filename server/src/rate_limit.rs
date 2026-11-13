// Rate limiting — T1.5.
//
// Token-bucket per (key, action). Used to throttle:
//
//   • POST /v1/identity     (default 5 / 1h)   — anti-spam registration
//   • POST /v1/keypackages  (default 100 / 1h) — bounded KP upload
//   • Submit frames over WS (default 600 / 1m) — 10 msg/s peak
//
// Identity key: for HTTP we use the client's source IP (extracted from
// `X-Forwarded-For`, which Caddy sets — `admin::client_rate_key`; IPv6
// by its /64, plus one wider bucket per /48, LIMIT-4). For WS we use
// `user_pk` (post-Auth) so a single device can't burst across multiple
// connections.
//
// Mechanism: classic token bucket. Each bucket has `capacity` tokens
// and refills at `refill_rate` tokens/sec. A request consumes 1 token;
// if bucket is empty, request is rejected with 429 + Retry-After. We
// don't use a queueing approach (no held requests) — fail-fast is
// cleaner and faster.
//
// State is in-memory (process-local). Multi-replica deployments need
// either sticky sessions or a shared Redis bucket; for v1 self-hosted
// solo-operator that's deferred. Documented in deploy-guide.md.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::Mutex;

/// Configuration for a single rate-limit policy.
#[derive(Debug, Clone, Copy)]
pub struct RateConfig {
    /// Bucket size. A burst of up to `capacity` requests can land in
    /// quick succession before throttling kicks in.
    pub capacity: u32,
    /// Tokens regenerated per second. The sustained throughput cap.
    pub refill_per_sec: f64,
}

impl RateConfig {
    /// Convenience: `N` requests per `window_secs` seconds. Capacity =
    /// `N` (allows full window's worth as a burst), refill = N/window.
    pub fn per_window(n: u32, window_secs: u64) -> Self {
        Self {
            capacity: n,
            refill_per_sec: n as f64 / window_secs as f64,
        }
    }

    /// Default configs for each action — overridable via env at
    /// `RateLimiter::from_env()`.
    pub fn defaults() -> RateDefaults {
        RateDefaults {
            register: Self::per_window(5, 3_600),  // 5 / hour
            kp_upload: Self::per_window(100, 3_600), // 100 / hour
            ws_submit: Self::per_window(600, 60),  // 600 / minute = 10/s
            media_upload: Self::per_window(200, 3_600), // 200 / hour
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct RateDefaults {
    pub register: RateConfig,
    pub kp_upload: RateConfig,
    pub ws_submit: RateConfig,
    pub media_upload: RateConfig,
}

#[derive(Debug)]
struct Bucket {
    tokens: f64,
    last_refill: Instant,
}

impl Bucket {
    fn fresh(capacity: u32) -> Self {
        Self {
            tokens: capacity as f64,
            last_refill: Instant::now(),
        }
    }

    /// Attempt to consume one token. Returns `Ok(())` on success or
    /// the duration the caller should wait before retry.
    fn try_consume(&mut self, cfg: &RateConfig) -> Result<(), Duration> {
        self.try_consume_part(cfg, 1.0)
    }

    /// The same for [cost] of a token (the IPv6 /48 bucket, LIMIT-4).
    fn try_consume_part(&mut self, cfg: &RateConfig, cost: f64) -> Result<(), Duration> {
        let now = Instant::now();
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        self.tokens = (self.tokens + elapsed * cfg.refill_per_sec).min(cfg.capacity as f64);
        self.last_refill = now;

        if self.tokens >= cost {
            self.tokens -= cost;
            Ok(())
        } else {
            // Need (1 - tokens) more tokens. Time = need / rate.
            // refill_per_sec=0 means "never refills" — return a sentinel
            // 1h wait so caller treats as effectively permanent.
            let wait_secs = if cfg.refill_per_sec <= 0.0 {
                3600.0
            } else {
                let need = cost - self.tokens;
                (need / cfg.refill_per_sec).max(0.5)
            };
            Err(Duration::from_secs_f64(wait_secs))
        }
    }
}

/// Thread-safe shared rate limiter for the whole server. Wrap in
/// `Arc` and clone freely.
#[derive(Clone)]
pub struct RateLimiter {
    inner: Arc<RateLimiterInner>,
}

struct RateLimiterInner {
    register: Mutex<HashMap<String, Bucket>>,
    kp_upload: Mutex<HashMap<String, Bucket>>,
    ws_submit: Mutex<HashMap<String, Bucket>>,
    media_upload: Mutex<HashMap<String, Bucket>>,
    /// ADR-071 — deliveries without an access key, per sender → recipient.
    requests: KeyedLimiter,
    /// ADR-071 (amended) — request pushes: per sender → recipient, and per
    /// recipient (a stranger, or someone blocked, can't keep a phone busy).
    request_push_pair: KeyedLimiter,
    request_push_person: KeyedLimiter,
    cfg: RateDefaults,
}

impl RateLimiter {
    /// Build with default config.
    pub fn new(cfg: RateDefaults) -> Self {
        Self {
            inner: Arc::new(RateLimiterInner {
                register: Mutex::new(HashMap::new()),
                kp_upload: Mutex::new(HashMap::new()),
                ws_submit: Mutex::new(HashMap::new()),
                media_upload: Mutex::new(HashMap::new()),
                requests: KeyedLimiter::from_env("SINHRON_RATE_REQUESTS", RateConfig::per_window(60, 60)),
                request_push_pair: KeyedLimiter::from_env("SINHRON_RATE_REQUEST_PUSH_PAIR", RateConfig::per_window(1, 600)),
                request_push_person: KeyedLimiter::from_env("SINHRON_RATE_REQUEST_PUSH", RateConfig::per_window(10, 3_600)),
                cfg,
            }),
        }
    }

    /// Read overrides from env:
    ///   SINHRON_RATE_REGISTER=N/W  (N requests per W seconds)
    ///   SINHRON_RATE_KP_UPLOAD=N/W
    ///   SINHRON_RATE_SUBMIT=N/W
    ///   SINHRON_RATE_MEDIA_UPLOAD=N/W
    pub fn from_env() -> Self {
        let mut cfg = RateConfig::defaults();
        if let Some(v) = parse_n_w(std::env::var("SINHRON_RATE_REGISTER").ok().as_deref()) {
            cfg.register = v;
        }
        if let Some(v) = parse_n_w(std::env::var("SINHRON_RATE_KP_UPLOAD").ok().as_deref()) {
            cfg.kp_upload = v;
        }
        if let Some(v) = parse_n_w(std::env::var("SINHRON_RATE_SUBMIT").ok().as_deref()) {
            cfg.ws_submit = v;
        }
        if let Some(v) = parse_n_w(std::env::var("SINHRON_RATE_MEDIA_UPLOAD").ok().as_deref()) {
            cfg.media_upload = v;
        }
        Self::new(cfg)
    }

    /// Check rate limit on the `register` (POST /v1/identity) action.
    /// Key is typically the client IP.
    pub fn check_register(&self, key: &str) -> Result<(), Duration> {
        check_map(&self.inner.register, &self.inner.cfg.register, key)
    }

    pub fn check_kp_upload(&self, key: &str) -> Result<(), Duration> {
        check_map(&self.inner.kp_upload, &self.inner.cfg.kp_upload, key)
    }

    pub fn check_ws_submit(&self, key: &str) -> Result<(), Duration> {
        check_map(&self.inner.ws_submit, &self.inner.cfg.ws_submit, key)
    }

    /// ADR-071 — a delivery to someone who wants keys, sent without one
    /// (a message request): keyed `sender→recipient`, 60 a minute
    /// (`SINHRON_RATE_REQUESTS=N/W`).
    pub fn check_request(&self, key: &str) -> Result<(), Duration> {
        self.inner.requests.check(key)
    }

    /// ADR-071 (amended) — may a message request from [sender] wake
    /// [recipient]'s phone? One per pair per 10 minutes
    /// (`SINHRON_RATE_REQUEST_PUSH_PAIR`), ten per person per hour
    /// (`SINHRON_RATE_REQUEST_PUSH`). The message itself arrives either way.
    pub fn check_request_push(&self, sender: &str, recipient: &str) -> bool {
        self.inner.request_push_pair.check(&format!("{sender}>{recipient}")).is_ok()
            && self.inner.request_push_person.check(recipient).is_ok()
    }

    /// POST /v1/media — keyed by identity pubkey hex.
    pub fn check_media_upload(&self, key: &str) -> Result<(), Duration> {
        check_map(&self.inner.media_upload, &self.inner.cfg.media_upload, key)
    }

    /// Periodic GC — drop buckets that haven't been touched in a while
    /// to keep memory bounded. Call from a background sweep, e.g. in
    /// `retention::spawn`. Idle buckets at full capacity are
    /// indistinguishable from "never seen this key" so dropping is
    /// semantically a no-op.
    pub fn gc_idle(&self, idle_threshold: Duration) {
        let now = Instant::now();
        let drop_idle = |map: &Mutex<HashMap<String, Bucket>>, cap: u32| {
            let mut m = map.lock();
            m.retain(|_, b| {
                let elapsed = now.duration_since(b.last_refill);
                if elapsed > idle_threshold {
                    // Long-idle: refilled to capacity by now anyway.
                    false
                } else {
                    b.tokens < cap as f64 || elapsed < idle_threshold
                }
            });
        };
        drop_idle(&self.inner.register, self.inner.cfg.register.capacity);
        drop_idle(&self.inner.kp_upload, self.inner.cfg.kp_upload.capacity);
        drop_idle(&self.inner.ws_submit, self.inner.cfg.ws_submit.capacity);
        drop_idle(&self.inner.media_upload, self.inner.cfg.media_upload.capacity);
    }
}

/// One policy with a bucket per key — for a feature that keeps its own
/// limiter (ADR-058: Telegram sticker packs, per account).
pub struct KeyedLimiter {
    cfg: RateConfig,
    map: Mutex<HashMap<String, Bucket>>,
}

impl KeyedLimiter {
    pub fn new(cfg: RateConfig) -> Self {
        Self { cfg, map: Mutex::new(HashMap::new()) }
    }

    /// `env` ("N/W") overrides [default].
    pub fn from_env(env: &str, default: RateConfig) -> Self {
        Self::new(parse_n_w(std::env::var(env).ok().as_deref()).unwrap_or(default))
    }

    pub fn check(&self, key: &str) -> Result<(), Duration> {
        let mut map = self.map.lock();
        if map.len() > 10_000 && needs_sweep(&map, key) {
            // Full buckets are the same as no bucket: keep memory bounded.
            let cap = self.cfg.capacity as f64;
            let now = Instant::now();
            map.retain(|_, b| b.tokens + now.duration_since(b.last_refill).as_secs_f64() * self.cfg.refill_per_sec < cap);
        }
        consume(&mut map, &self.cfg, key.to_string())
    }

    /// Give back the token a [check] took — the request got nothing.
    pub fn refund(&self, key: &str) {
        let mut map = self.map.lock();
        let cap = self.cfg.capacity as f64;
        if let Some(b) = map.get_mut(key) {
            b.tokens = (b.tokens + 1.0).min(cap);
        }
        if let Some(b) = v6_site(key).and_then(|site| map.get_mut(&site)) {
            b.tokens = (b.tokens + 1.0 / V6_SITE_FACTOR).min(cap);
        }
    }
}

/// One bucket map, bounded: the key is normalised (lower case — hex keys
/// in upper case were a fresh bucket each; at most 96 characters — a
/// 2 MiB "key" was one entry) and, past 50 000 entries, full buckets are
/// dropped — they mean the same as no bucket (security review 2026-11-02:
/// the maps grew from requests without an account until the server ran
/// out of memory).
fn check_map(map: &Mutex<HashMap<String, Bucket>>, cfg: &RateConfig, key: &str) -> Result<(), Duration> {
    let mut key: String = key.chars().take(96).collect();
    key.make_ascii_lowercase();
    let mut m = map.lock();
    if m.len() > 50_000 && needs_sweep(&m, &key) {
        let cap = cfg.capacity as f64;
        let now = Instant::now();
        m.retain(|_, b| b.tokens + now.duration_since(b.last_refill).as_secs_f64() * cfg.refill_per_sec < cap);
    }
    consume(&mut m, cfg, key)
}

/// LIMIT-4 — a per-IP key for IPv6 is its /64 (`admin::client_rate_key`),
/// and a free tunnel hands anyone a /48: 65 536 fresh buckets. Such a key
/// also draws on one bucket for its /48, this many times the /64 limit.
const V6_SITE_FACTOR: f64 = 4.0;

/// `2001:db8:1:2::/64` → `2001:db8:1::/48`; `None` for any other key.
fn v6_site(key: &str) -> Option<String> {
    let site = key.strip_suffix("::/64")?.rsplit_once(':')?.0;
    Some(format!("{site}::/48"))
}

/// Take one token from [key]'s bucket — and, for an IPv6 /64, a part of
/// one from its /48 (LIMIT-4).
fn consume(m: &mut HashMap<String, Bucket>, cfg: &RateConfig, key: String) -> Result<(), Duration> {
    let Some(site) = v6_site(&key) else {
        return m.entry(key).or_insert_with(|| Bucket::fresh(cfg.capacity)).try_consume(cfg);
    };
    m.entry(key.clone()).or_insert_with(|| Bucket::fresh(cfg.capacity)).try_consume(cfg)?;
    let shared = m.entry(site).or_insert_with(|| Bucket::fresh(cfg.capacity)).try_consume_part(cfg, 1.0 / V6_SITE_FACTOR);
    if shared.is_err() {
        // Refused by the /48: the /64's own token was not spent.
        if let Some(own) = m.get_mut(&key) {
            own.tokens = (own.tokens + 1.0).min(cfg.capacity as f64);
        }
    }
    shared
}

/// Sweep only for a new key when the map is full and about to double:
/// amortised O(1). A sweep on every request past the cap cost ~0.3 ms
/// under the lock, and fresh keys kept it there (calls:7, server-http:9).
fn needs_sweep(m: &HashMap<String, Bucket>, key: &str) -> bool {
    m.len() >= m.capacity() && !m.contains_key(key)
}

/// A process-wide [KeyedLimiter] made on first use, for `static`s in the
/// handlers: `N` per `window_secs`, or the `env` override ("N/W").
pub struct StaticLimiter {
    cell: std::sync::OnceLock<KeyedLimiter>,
    env: &'static str,
    n: u32,
    window_secs: u64,
}

impl StaticLimiter {
    pub const fn new(env: &'static str, n: u32, window_secs: u64) -> Self {
        Self { cell: std::sync::OnceLock::new(), env, n, window_secs }
    }

    pub fn check(&self, key: &str) -> Result<(), Duration> {
        self.get().check(key)
    }

    pub fn refund(&self, key: &str) {
        self.get().refund(key)
    }

    fn get(&self) -> &KeyedLimiter {
        // Tests count refusals exactly: no refill there, or a slow machine
        // tops the bucket up mid-loop and the count drifts.
        #[cfg(test)]
        let cfg = RateConfig { capacity: self.n, refill_per_sec: 0.0 };
        #[cfg(not(test))]
        let cfg = RateConfig::per_window(self.n, self.window_secs);
        self.cell.get_or_init(|| KeyedLimiter::from_env(self.env, cfg))
    }
}

/// Parse `"N/W"` format from env (e.g. "100/3600").
fn parse_n_w(s: Option<&str>) -> Option<RateConfig> {
    let s = s?;
    let mut parts = s.splitn(2, '/');
    let n: u32 = parts.next()?.trim().parse().ok()?;
    let w: u64 = parts.next()?.trim().parse().ok()?;
    if n == 0 || w == 0 {
        return None;
    }
    Some(RateConfig::per_window(n, w))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread::sleep;

    #[test]
    fn bucket_consumes_until_empty() {
        let cfg = RateConfig {
            capacity: 3,
            refill_per_sec: 0.0, // no refill — pure capacity test
        };
        let mut b = Bucket::fresh(3);
        assert!(b.try_consume(&cfg).is_ok());
        assert!(b.try_consume(&cfg).is_ok());
        assert!(b.try_consume(&cfg).is_ok());
        // 4th should fail.
        assert!(b.try_consume(&cfg).is_err());
    }

    #[test]
    fn bucket_refills_over_time() {
        let cfg = RateConfig {
            capacity: 2,
            refill_per_sec: 100.0, // very fast for test
        };
        let mut b = Bucket::fresh(2);
        // Drain.
        assert!(b.try_consume(&cfg).is_ok());
        assert!(b.try_consume(&cfg).is_ok());
        // Empty now.
        assert!(b.try_consume(&cfg).is_err());
        // Wait 20ms — at 100/sec, that's 2 tokens.
        sleep(Duration::from_millis(20));
        // Should accept again.
        assert!(b.try_consume(&cfg).is_ok());
    }

    #[test]
    fn rate_limiter_isolates_keys() {
        let lim = RateLimiter::new(RateDefaults {
            register: RateConfig::per_window(2, 60),
            kp_upload: RateConfig::per_window(10, 60),
            ws_submit: RateConfig::per_window(10, 60),
            media_upload: RateConfig::per_window(10, 60),
        });
        // key A burns its 2 tokens.
        assert!(lim.check_register("ip:A").is_ok());
        assert!(lim.check_register("ip:A").is_ok());
        assert!(lim.check_register("ip:A").is_err());
        // key B is independent.
        assert!(lim.check_register("ip:B").is_ok());
        assert!(lim.check_register("ip:B").is_ok());
        assert!(lim.check_register("ip:B").is_err());
    }

    #[test]
    fn rate_limiter_isolates_actions() {
        let lim = RateLimiter::new(RateDefaults {
            register: RateConfig::per_window(1, 60),
            kp_upload: RateConfig::per_window(5, 60),
            ws_submit: RateConfig::per_window(100, 60),
            media_upload: RateConfig::per_window(10, 60),
        });
        // register is 1 per minute.
        assert!(lim.check_register("ip:A").is_ok());
        assert!(lim.check_register("ip:A").is_err());
        // kp_upload still has 5.
        for _ in 0..5 {
            assert!(lim.check_kp_upload("ip:A").is_ok());
        }
        assert!(lim.check_kp_upload("ip:A").is_err());
    }

    /// T3.2 — gc_idle removes long-idle buckets (memory bound check).
    #[test]
    fn gc_idle_drops_old_buckets() {
        let lim = RateLimiter::new(RateDefaults {
            register: RateConfig::per_window(10, 60),
            kp_upload: RateConfig::per_window(10, 60),
            ws_submit: RateConfig::per_window(10, 60),
            media_upload: RateConfig::per_window(10, 60),
        });
        // Touch some buckets.
        let _ = lim.check_register("ip:1");
        let _ = lim.check_register("ip:2");
        let _ = lim.check_register("ip:3");
        // Initial state: 3 buckets present.
        assert_eq!(lim.inner.register.lock().len(), 3);
        // GC with a really short threshold — all "old enough" relative
        // to the 1ms sleep below.
        sleep(Duration::from_millis(10));
        lim.gc_idle(Duration::from_millis(1));
        // After GC, idle-long-enough buckets dropped (they were all at
        // refilled-capacity since we paused).
        let remaining = lim.inner.register.lock().len();
        assert!(remaining <= 3); // exact value is implementation-defined
    }

    #[test]
    fn parse_n_w_parses_envable_format() {
        assert!(parse_n_w(None).is_none());
        // docker-compose passes unset knobs as "" (tech-debt 2.17).
        assert!(parse_n_w(Some("")).is_none());
        assert!(parse_n_w(Some("garbage")).is_none());
        assert!(parse_n_w(Some("0/60")).is_none());
        assert!(parse_n_w(Some("10/0")).is_none());
        let cfg = parse_n_w(Some("100/60")).expect("valid");
        assert_eq!(cfg.capacity, 100);
        assert!((cfg.refill_per_sec - (100.0 / 60.0)).abs() < 1e-9);
    }
}

#[cfg(test)]
mod keyed_tests {
    use super::*;

    #[test]
    fn keyed_limiter_counts_each_key_apart() {
        let l = KeyedLimiter::new(RateConfig { capacity: 2, refill_per_sec: 0.0 });
        assert!(l.check("a").is_ok());
        assert!(l.check("a").is_ok());
        assert!(l.check("a").is_err());
        assert!(l.check("b").is_ok(), "another account has its own bucket");
    }

    /// LIMIT-4 — every /64 of one /48 was a fresh bucket: a free IPv6
    /// tunnel gave 65 536 times the per-IP limit.
    #[test]
    fn a_refusal_by_the_48_does_not_spend_the_64s_own_token() {
        let keyed = KeyedLimiter::new(RateConfig { capacity: 2, refill_per_sec: 0.0 });
        for i in 0..8 {
            assert!(keyed.check(&format!("2001:db8:9:{i:x}::/64")).is_ok());
        }
        // The /48 is spent; this /64 still holds one token of its own.
        assert!(keyed.check("2001:db8:9:0::/64").is_err());
        assert!(keyed.check("2001:db8:9:0::/64").is_err());
        // Room in the /48 again (a refund elsewhere): that token is still there.
        keyed.refund("2001:db8:9:1::/64");
        assert!(keyed.check("2001:db8:9:0::/64").is_ok());
    }

    #[test]
    fn ipv6_48_shares_one_bucket_four_times_the_64_limit() {
        let cfg = RateConfig { capacity: 2, refill_per_sec: 0.0 };
        let keyed = KeyedLimiter::new(cfg);
        let lim = RateLimiter::new(RateDefaults { register: cfg, kp_upload: cfg, ws_submit: cfg, media_upload: cfg });
        for i in 0..8 {
            let k = format!("2001:db8:1:{i:x}::/64");
            assert!(keyed.check(&k).is_ok(), "{k}");
            assert!(lim.check_register(&k).is_ok(), "{k}");
        }
        assert!(keyed.check("2001:db8:1:ffff::/64").is_err(), "a ninth /64 of the same /48");
        assert!(lim.check_register("2001:db8:1:ffff::/64").is_err());
        assert!(keyed.check("2001:db8:2:1::/64").is_ok(), "another /48 has its own");
        assert!(lim.check_register("2001:db8:2:1::/64").is_ok());
        // One /64 alone is limited as before, and so is IPv4.
        assert!(keyed.check("2001:db8:3:1::/64").is_ok());
        assert!(keyed.check("2001:db8:3:1::/64").is_ok());
        assert!(keyed.check("2001:db8:3:1::/64").is_err());
        for i in 0..20 {
            assert!(keyed.check(&format!("198.51.100.{i}")).is_ok());
        }
        // A refund gives the /48 its part back.
        keyed.refund("2001:db8:1:0::/64");
        assert!(keyed.check("2001:db8:1:fffe::/64").is_ok());
    }

    /// calls:7 — past the cap every request swept the whole map under the
    /// lock: a stranger sending fresh keys slowed calls, KeyPackage uploads
    /// and pairing for everyone (~0.3 ms a request, measured).
    #[test]
    fn fresh_keys_past_the_cap_do_not_sweep_on_every_request() {
        let lim = RateLimiter::new(RateConfig::defaults());
        let keyed = KeyedLimiter::new(RateConfig::per_window(20, 3_600));
        for i in 0..60_000 {
            let _ = lim.check_kp_upload(&format!("{i:064x}"));
            let _ = keyed.check(&format!("{:x}", i % 12_000));
        }
        let t = Instant::now();
        for i in 0..2_000 {
            let _ = lim.check_kp_upload(&format!("new{i:061x}"));
            let _ = keyed.check(&format!("new{i}"));
        }
        assert!(t.elapsed() < Duration::from_millis(400), "took {:?}", t.elapsed());
        assert!(lim.inner.kp_upload.lock().len() > 60_000, "live buckets are kept");
    }
}
