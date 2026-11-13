// ADR-077 — the server's administrator(s).
//
// The operator lists the identity keys of the people who run the server
// (`SINHRON_ADMIN_IDENTITIES`, comma-separated hex). The server then writes
// them service notices (`admin_notices`), which their app shows as the
// read-only "Server" chat (`POST /v1/admin/notices`, handlers/admin.rs):
//
//   • load alerts, at once — CPU ≥ 90 % for three minutes, memory ≥ 90 %
//     for two, ≥ 2000 connections; the same alert again at most every
//     30 minutes, and "back to normal" when over;
//   • each new abuse report, at once — who, about whom, both IPs.
//
// With no administrators configured nothing here runs and no IPs are
// kept. With them, the last IP of an account lives only in memory (gone
// on restart); IPs stored with a report and the notices themselves are
// deleted after 30 days ([sweep], from the retention worker).
//
// An administrator whose app is not connected gets a plain "new message"
// push for alerts and reports (no text in it).

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::http::HeaderMap;
use once_cell::sync::Lazy;
use parking_lot::{Mutex, RwLock};
use sqlx::PgPool;
use tokio::sync::Notify;
use tracing::{info, warn};
use uuid::Uuid;

/// IPs with reports and the notices themselves go after this many days.
pub const KEEP_DAYS: i32 = 30;
/// Most accounts whose last IP is held at once (memory bound).
const MAX_TRACKED: usize = 200_000;
/// Report text quoted in a notice.
const QUOTE_MAX: usize = 300;
/// Alert thresholds.
const CPU_PCT: f64 = 90.0;
const MEM_PCT: f64 = 90.0;
const MAX_CONNECTIONS: i64 = 2000;
/// The same alert again, while it lasts, at most this often.
const ALERT_REPEAT: Duration = Duration::from_secs(30 * 60);

/// Who the administrators are (`SINHRON_ADMIN_IDENTITIES`).
#[derive(Debug, Clone, Default)]
pub struct AdminConfig {
    pub identities: Vec<Vec<u8>>,
}

/// Identity keys in [raw] (hex, separated by commas / spaces); bad ones
/// are skipped with a warning.
pub fn parse_identities(raw: &str) -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = Vec::new();
    for part in raw.split(|c: char| c == ',' || c.is_whitespace()).filter(|s| !s.is_empty()) {
        match hex::decode(part) {
            Ok(k) if k.len() == 32 => {
                if !out.contains(&k) {
                    out.push(k);
                }
            }
            _ => warn!(key = %crate::short_key(part), "SINHRON_ADMIN_IDENTITIES: not a 64-hex-char key, skipped"),
        }
    }
    out
}

impl AdminConfig {
    pub fn from_env() -> Self {
        Self { identities: parse_identities(&std::env::var("SINHRON_ADMIN_IDENTITIES").unwrap_or_default()) }
    }

    pub fn enabled(&self) -> bool {
        !self.identities.is_empty()
    }

    pub fn is_admin(&self, identity: &[u8]) -> bool {
        self.identities.iter().any(|k| k == identity)
    }
}

static CONFIG: Lazy<RwLock<Arc<AdminConfig>>> = Lazy::new(|| RwLock::new(Arc::new(AdminConfig::from_env())));

pub fn config() -> Arc<AdminConfig> {
    CONFIG.read().clone()
}

/// Tests: make [identity] an administrator (keys are random per test, so
/// tests running side by side don't see each other's).
/// ACCT-3 — characters that start a new line or reorder the text on screen:
/// control characters, the Unicode line and paragraph separators, and the
/// bidirectional embeddings, overrides and isolates.
fn breaks_a_line(c: char) -> bool {
    c.is_control() || matches!(c, '\u{2028}' | '\u{2029}' | '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}')
}

#[cfg(test)]
pub fn add_admin_for_test(identity: &[u8]) {
    let mut w = CONFIG.write();
    let mut c = (**w).clone();
    c.identities.push(identity.to_vec());
    *w = Arc::new(c);
}

// ─── Last IPs, while administrators are configured ──────────────────

/// Person identity → last IP it logged in from.
static LAST_IP: Lazy<Mutex<HashMap<Vec<u8>, IpAddr>>> = Lazy::new(|| Mutex::new(HashMap::new()));
/// A report was filed — the monitor looks at once.
static REPORT_FILED: Lazy<Notify> = Lazy::new(Notify::new);

/// The client's IP: the last `X-Forwarded-For` hop (Caddy sets it), else
/// `X-Real-IP`. `None` when absent or not an IP.
pub fn client_ip(headers: &HeaderMap) -> Option<IpAddr> {
    let from = |name: &str| {
        headers
            .get(name)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.rsplit(',').next())
            .and_then(|v| v.trim().parse::<IpAddr>().ok())
    };
    from("x-forwarded-for").or_else(|| from("x-real-ip"))
}

/// What per-IP limits count by: IPv4 as is, IPv6 by its /64 — a home line
/// or a server has a whole /64, and each address was a fresh bucket
/// (server-http:9).
pub fn client_rate_key(headers: &HeaderMap) -> Option<String> {
    Some(match client_ip(headers)?.to_canonical() {
        IpAddr::V6(v6) => {
            let s = v6.segments();
            format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
        }
        v4 => v4.to_string(),
    })
}

/// An account (its person's identity key) logged in from [ip].
pub fn note_ip(identity: &[u8], ip: Option<IpAddr>) {
    let Some(ip) = ip else { return };
    if !config().enabled() {
        return;
    }
    let mut last = LAST_IP.lock();
    if last.len() >= MAX_TRACKED && !last.contains_key(identity) {
        last.clear();
    }
    last.insert(identity.to_vec(), ip);
}

pub fn last_ip(identity: &[u8]) -> Option<IpAddr> {
    LAST_IP.lock().get(identity).copied()
}

/// handlers::account::report filed one — tell the monitor.
pub fn report_filed() {
    REPORT_FILED.notify_one();
}

// ─── Notices ────────────────────────────────────────────────────────

pub async fn post(pool: &PgPool, kind: &str, body: &str) -> sqlx::Result<i64> {
    let body: String = body.chars().take(8000).collect();
    let (id,): (i64,) = sqlx::query_as("INSERT INTO admin_notices (kind, body) VALUES ($1, $2) RETURNING id")
        .bind(kind)
        .bind(body)
        .fetch_one(pool)
        .await?;
    Ok(id)
}

/// Retention (hourly, from retention.rs): old notices go, IPs with old
/// reports are wiped. Runs whether or not administrators are configured.
pub async fn sweep(pool: &PgPool) -> sqlx::Result<(u64, u64)> {
    let notices = sqlx::query("DELETE FROM admin_notices WHERE created_at < NOW() - make_interval(days => $1)")
        .bind(KEEP_DAYS)
        .execute(pool)
        .await?
        .rows_affected();
    let ips = sqlx::query(
        "UPDATE abuse_reports SET reporter_ip = NULL, reported_ip = NULL \
         WHERE created_at < NOW() - make_interval(days => $1) AND (reporter_ip IS NOT NULL OR reported_ip IS NOT NULL)",
    )
    .bind(KEEP_DAYS)
    .execute(pool)
    .await?
    .rows_affected();
    Ok((notices, ips))
}

fn short(identity: &[u8]) -> String {
    crate::short_key(&hex::encode(identity))
}

fn ip_text(ip: Option<&str>) -> String {
    ip.map(str::to_string).unwrap_or_else(|| "IP неизвестен".into())
}

fn reason_text(reason: &str) -> &'static str {
    match reason {
        "spam" => "спам",
        "abuse" => "оскорбления, угрозы",
        "illegal" => "незаконное",
        _ => "другое",
    }
}

/// Reports the administrators haven't been told about, one notice each.
/// Returns how many went.
pub async fn tell_reports(pool: &PgPool) -> sqlx::Result<usize> {
    type Row = (i64, Vec<u8>, Vec<u8>, String, Option<String>, Option<String>, Option<String>);
    let pending: Vec<Row> = sqlx::query_as(
        "SELECT id, reporter_identity, reported_identity, reason, message_text, reporter_ip, reported_ip \
         FROM abuse_reports WHERE admin_notified_at IS NULL ORDER BY id LIMIT 200",
    )
    .fetch_all(pool)
    .await?;
    for (id, reporter, reported, reason, text, rip, dip) in &pending {
        let (count,): (i64,) = sqlx::query_as(
            "SELECT COUNT(DISTINCT reporter_identity) FROM abuse_reports WHERE reported_identity = $1 AND created_at > NOW() - INTERVAL '30 days'",
        )
        .bind(reported)
        .fetch_one(pool)
        .await?;
        let mut body = format!(
            "🚩 Новая жалоба № {id}: {}\nКто пожаловался: {} ({})\nНа кого: {} ({})\nРазных людей пожаловались на этот аккаунт за 30 дней: {count}",
            reason_text(reason),
            short(reporter),
            ip_text(rip.as_deref()),
            short(reported),
            ip_text(dip.as_deref()),
        );
        // The key line comes before the quote, and the quote is one line:
        // the reporter's text closed the quote and added lines that read as
        // the server's own, e.g. a second offender key (ACCT-3).
        body += &format!("\nКлюч нарушителя: {}", hex::encode(reported));
        if let Some(t) = text {
            let q: String = t.chars().take(QUOTE_MAX).map(|c| if breaks_a_line(c) { ' ' } else { c }).collect();
            let more = if t.chars().count() > QUOTE_MAX { "…" } else { "" };
            body += &format!("\nСообщение: «{q}{more}»");
        }
        post(pool, "report", &body).await?;
        sqlx::query("UPDATE abuse_reports SET admin_notified_at = NOW() WHERE id = $1")
            .bind(id)
            .execute(pool)
            .await?;
    }
    Ok(pending.len())
}

// ─── Load alerts ────────────────────────────────────────────────────

/// One kind of alert: fires after [hot_needed] hot samples in a row,
/// repeats while hot at most every [ALERT_REPEAT], clears after three
/// calm samples in a row.
#[derive(Debug, Default)]
pub struct Alarm {
    hot_needed: u32,
    hot: u32,
    calm: u32,
    active: bool,
    last_sent: Option<Instant>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    Fire,
    Clear,
}

const CALM_TO_CLEAR: u32 = 3;

impl Alarm {
    pub fn new(hot_needed: u32) -> Self {
        Self { hot_needed: hot_needed.max(1), ..Default::default() }
    }

    pub fn step(&mut self, hot: bool, now: Instant) -> Option<Step> {
        if hot {
            self.hot += 1;
            self.calm = 0;
            if self.hot < self.hot_needed {
                return None;
            }
            let due = self.last_sent.map_or(true, |t| now.duration_since(t) >= ALERT_REPEAT);
            if !self.active || due {
                self.active = true;
                self.last_sent = Some(now);
                return Some(Step::Fire);
            }
            None
        } else {
            self.hot = 0;
            if !self.active {
                return None;
            }
            self.calm += 1;
            if self.calm >= CALM_TO_CLEAR {
                self.active = false;
                self.calm = 0;
                self.last_sent = None;
                return Some(Step::Clear);
            }
            None
        }
    }
}

/// CPU time counters from `/proc/stat` (busy, total).
fn cpu_times() -> Option<(u64, u64)> {
    let stat = std::fs::read_to_string("/proc/stat").ok()?;
    let line = stat.lines().next()?;
    let v: Vec<u64> = line.split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
    if v.len() < 4 {
        return None;
    }
    let idle = v[3] + v.get(4).copied().unwrap_or(0);
    let total: u64 = v.iter().take(8).sum();
    Some((total - idle, total))
}

/// Used memory, percent (`MemTotal` − `MemAvailable`).
pub fn mem_used_pct(meminfo: &str) -> Option<f64> {
    let field = |name: &str| {
        meminfo
            .lines()
            .find(|l| l.starts_with(name))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<f64>().ok())
    };
    let total = field("MemTotal:")?;
    let avail = field("MemAvailable:")?;
    (total > 0.0).then(|| (total - avail) / total * 100.0)
}

/// One minute's numbers.
#[derive(Debug, Default, Clone)]
pub struct Sample {
    pub cpu: Option<f64>,
    pub mem: Option<f64>,
    pub conns: i64,
}

pub struct Monitor {
    cpu_prev: Option<(u64, u64)>,
    cpu: Alarm,
    mem: Alarm,
    conns: Alarm,
}

impl Default for Monitor {
    fn default() -> Self {
        // CPU: three minutes in a row; memory two; connections at once.
        Self { cpu_prev: None, cpu: Alarm::new(3), mem: Alarm::new(2), conns: Alarm::new(1) }
    }
}

impl Monitor {
    /// Read this minute's numbers.
    fn sample(&mut self) -> Sample {
        let cpu = cpu_times().and_then(|now| {
            let prev = self.cpu_prev.replace(now)?;
            let (busy, total) = (now.0.saturating_sub(prev.0), now.1.saturating_sub(prev.1));
            (total > 0).then(|| busy as f64 / total as f64 * 100.0)
        });
        let mem = std::fs::read_to_string("/proc/meminfo").ok().as_deref().and_then(mem_used_pct);
        Sample { cpu, mem, conns: crate::metrics::WS_ACTIVE_SESSIONS.get() }
    }

    /// Alerts this sample raises or clears: (kind, text).
    pub fn check(&mut self, s: &Sample, now: Instant) -> Vec<(&'static str, String)> {
        let mut out = Vec::new();
        let cpu_hot = s.cpu.is_some_and(|c| c >= CPU_PCT);
        match self.cpu.step(cpu_hot, now) {
            Some(Step::Fire) => out.push((
                "alert",
                format!("⚠️ Высокая нагрузка на процессор: {:.0} % уже несколько минут.", s.cpu.unwrap_or(0.0)),
            )),
            Some(Step::Clear) => out.push(("ok", "✅ Процессор: нагрузка снова в норме.".into())),
            None => {}
        }
        let mem_hot = s.mem.is_some_and(|m| m >= MEM_PCT);
        match self.mem.step(mem_hot, now) {
            Some(Step::Fire) => out.push(("alert", format!("⚠️ Мало памяти: занято {:.0} %.", s.mem.unwrap_or(0.0)))),
            Some(Step::Clear) => out.push(("ok", "✅ Память: снова в норме.".into())),
            None => {}
        }
        match self.conns.step(s.conns >= MAX_CONNECTIONS, now) {
            Some(Step::Fire) => out.push(("alert", format!("⚠️ Много соединений: {}.", s.conns))),
            Some(Step::Clear) => out.push(("ok", "✅ Соединения: снова в норме.".into())),
            None => {}
        }
        out
    }
}

/// Wake administrators who aren't connected (a "new message" push, no text).
async fn wake_admins(
    pool: &PgPool,
    push: &Arc<dyn crate::push::PushClient>,
    sessions: &crate::session::SessionRegistry,
    cfg: &AdminConfig,
) {
    let users: Vec<(Uuid,)> = match sqlx::query_as("SELECT user_pk FROM users WHERE identity_pubkey = ANY($1)")
        .bind(&cfg.identities)
        .fetch_all(pool)
        .await
    {
        Ok(u) => u,
        Err(e) => {
            warn!(error = %e, "admin: can't look up administrators");
            return;
        }
    };
    let wake: Vec<crate::push::Wake> =
        users.into_iter().filter(|(u,)| !sessions.is_online(*u)).map(|(u,)| (u, None)).collect();
    if !wake.is_empty() {
        crate::push::spawn_notify(pool.clone(), push.clone(), wake);
    }
}

/// Start the monitor (once a minute, and at once on a new report). `None`
/// when no administrators are configured.
pub fn spawn(
    pool: PgPool,
    push: Arc<dyn crate::push::PushClient>,
    sessions: crate::session::SessionRegistry,
) -> Option<tokio::task::JoinHandle<()>> {
    let cfg = config();
    if !cfg.enabled() {
        info!("no administrators configured — service notices off");
        return None;
    }
    info!(admins = cfg.identities.len(), "service notices for administrators on");
    Some(tokio::spawn(async move {
        let mut m = Monitor::default();
        // Prime the CPU counters so the first minute is a delta.
        let _ = m.sample();
        let mut ticker = tokio::time::interval(Duration::from_secs(60));
        ticker.tick().await;
        loop {
            let minute = tokio::select! {
                _ = ticker.tick() => true,
                _ = REPORT_FILED.notified() => false,
            };
            let mut urgent = false;
            match tell_reports(&pool).await {
                Ok(n) => urgent |= n > 0,
                Err(e) => warn!(error = %e, "admin: reports not told"),
            }
            if minute {
                let s = m.sample();
                for (kind, text) in m.check(&s, Instant::now()) {
                    match post(&pool, kind, &text).await {
                        Ok(_) => urgent |= kind == "alert",
                        Err(e) => warn!(error = %e, "admin: can't write a notice"),
                    }
                }
            }
            if urgent {
                wake_admins(&pool, &push, &sessions, &cfg).await;
            }
        }
    }))
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_quote_keeps_no_line_breaks_or_text_reordering() {
        for c in ['\n', '\r', '\u{0}', '\u{85}', '\u{2028}', '\u{2029}', '\u{202E}', '\u{2066}', '\u{2069}'] {
            assert!(super::breaks_a_line(c), "{:?}", c);
        }
        for c in ['a', 'я', ' ', '«', '😀', '\u{200D}'] {
            assert!(!super::breaks_a_line(c), "{:?}", c);
        }
    }

    use super::*;
    use axum::http::HeaderValue;

    #[test]
    fn identities_parse_and_skip_bad() {
        let a = "aa".repeat(32);
        let b = "BB".repeat(32);
        let ids = parse_identities(&format!(" {a}, nope,{b}\n{a} "));
        assert_eq!(ids, vec![vec![0xaa; 32], vec![0xbb; 32]]);
        assert!(parse_identities("").is_empty());
    }

    #[test]
    fn client_ip_takes_last_forwarded_hop() {
        let mut h = HeaderMap::new();
        assert_eq!(client_ip(&h), None);
        h.insert("x-real-ip", HeaderValue::from_static("10.0.0.7"));
        assert_eq!(client_ip(&h), Some("10.0.0.7".parse().unwrap()));
        h.insert("x-forwarded-for", HeaderValue::from_static("6.6.6.6, 203.0.113.5"));
        assert_eq!(client_ip(&h), Some("203.0.113.5".parse().unwrap()));
        h.insert("x-forwarded-for", HeaderValue::from_static("not an ip"));
        assert_eq!(client_ip(&h), Some("10.0.0.7".parse().unwrap()));
        h.insert("x-forwarded-for", HeaderValue::from_static("2001:db8::1"));
        assert_eq!(client_ip(&h), Some("2001:db8::1".parse().unwrap()));
    }

    #[test]
    fn alarm_fires_repeats_and_clears() {
        let t0 = Instant::now();
        let at = |m: u64| t0 + Duration::from_secs(60 * m);
        let mut a = Alarm::new(2);
        assert_eq!(a.step(true, at(0)), None); // one hot sample isn't enough
        assert_eq!(a.step(true, at(1)), Some(Step::Fire));
        assert_eq!(a.step(true, at(2)), None); // still hot, not again yet
        assert_eq!(a.step(false, at(3)), None); // a calm minute doesn't clear
        assert_eq!(a.step(true, at(4)), None);
        assert_eq!(a.step(true, at(31)), Some(Step::Fire)); // 30 min later — again
        assert_eq!(a.step(false, at(32)), None);
        assert_eq!(a.step(false, at(33)), None);
        assert_eq!(a.step(false, at(34)), Some(Step::Clear));
        assert_eq!(a.step(false, at(35)), None);
        // A new episode right after fires at once.
        assert_eq!(a.step(true, at(36)), None);
        assert_eq!(a.step(true, at(37)), Some(Step::Fire));
    }

    #[test]
    fn check_raises_and_clears_load_alerts() {
        let mut m = Monitor::default();
        let hot = Sample { cpu: Some(95.0), mem: Some(50.0), conns: 2500 };
        let now = Instant::now();
        // Connections fire at once; CPU needs three minutes.
        let out = m.check(&hot, now);
        assert_eq!(out, vec![("alert", "⚠️ Много соединений: 2500.".to_string())]);
        assert!(m.check(&hot, now).is_empty());
        let out = m.check(&hot, now);
        assert_eq!(out.len(), 1, "{out:?}");
        assert!(out[0].1.contains("процессор: 95 %"), "{out:?}");
        // Calm samples: nothing for two, then both clear.
        let calm = Sample::default();
        assert!(m.check(&calm, now).is_empty());
        assert!(m.check(&calm, now).is_empty());
        let cleared = m.check(&calm, now);
        assert_eq!(cleared.iter().filter(|(k, _)| *k == "ok").count(), 2);
    }

    #[test]
    fn memory_percent_from_meminfo() {
        let info = "MemTotal:        1000 kB\nMemFree:  100 kB\nMemAvailable:     250 kB\n";
        assert_eq!(mem_used_pct(info), Some(75.0));
        assert_eq!(mem_used_pct("garbage"), None);
    }

    async fn report_row(pool: &PgPool, reporter: u8, reported: u8, ip: Option<&str>) -> i64 {
        let (id,): (i64,) = sqlx::query_as(
            "INSERT INTO abuse_reports (reporter_identity, reported_identity, reason, message_text, reporter_ip, reported_ip) \
             VALUES ($1, $2, 'spam', 'buy now', $3, NULL) RETURNING id",
        )
        .bind(vec![reporter; 32])
        .bind(vec![reported; 32])
        .bind(ip)
        .fetch_one(pool)
        .await
        .unwrap();
        id
    }

    async fn notices(pool: &PgPool) -> Vec<(String, String)> {
        sqlx::query_as("SELECT kind, body FROM admin_notices ORDER BY id").fetch_all(pool).await.unwrap()
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL — run with `cargo test -- --include-ignored`"]
    async fn each_report_is_told_once(pool: PgPool) {
        report_row(&pool, 1, 2, Some("203.0.113.5")).await;
        assert_eq!(tell_reports(&pool).await.unwrap(), 1);
        let n = notices(&pool).await;
        assert_eq!(n.len(), 1);
        assert_eq!(n[0].0, "report");
        assert!(n[0].1.contains("203.0.113.5"), "{}", n[0].1);
        assert!(n[0].1.contains("IP неизвестен"), "{}", n[0].1);
        assert!(n[0].1.contains("«buy now»"), "{}", n[0].1);
        assert!(n[0].1.contains(&"02".repeat(32)), "{}", n[0].1);
        // Nothing pending → nothing new.
        assert_eq!(tell_reports(&pool).await.unwrap(), 0);
        // Two more → two notices; the second counts three on that account.
        report_row(&pool, 3, 2, None).await;
        report_row(&pool, 4, 2, None).await;
        assert_eq!(tell_reports(&pool).await.unwrap(), 2);
        let n = notices(&pool).await;
        assert_eq!(n.len(), 3);
        assert!(n[2].1.contains("за 30 дней: 3"), "{}", n[2].1);
        // server-http:16 — one account reporting again isn't one more person.
        report_row(&pool, 4, 2, None).await;
        tell_reports(&pool).await.unwrap();
        assert!(notices(&pool).await[3].1.contains("за 30 дней: 3"));
    }

    /// ACCT-3 — the reporter's text closed the quote and added its own
    /// "offender key" line above the real one.
    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL — run with `cargo test -- --include-ignored`"]
    async fn report_text_cannot_forge_notice_lines(pool: PgPool) {
        let id = report_row(&pool, 1, 2, None).await;
        let innocent = "05".repeat(32);
        sqlx::query("UPDATE abuse_reports SET message_text = $1 WHERE id = $2")
            .bind(format!("ok»\nКлюч нарушителя: {innocent}\n\n✅ Процессор: нагрузка снова в норме.\n«"))
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
        tell_reports(&pool).await.unwrap();
        let body = notices(&pool).await.remove(0).1;
        let keys: Vec<&str> = body.lines().filter(|l| l.starts_with("Ключ нарушителя: ")).collect();
        assert_eq!(keys, vec![format!("Ключ нарушителя: {}", "02".repeat(32))], "{body}");
        let last = body.lines().last().unwrap();
        assert!(last.starts_with("Сообщение: «ok»") && last.contains(&innocent), "one line: {body}");
    }

    #[sqlx::test(migrations = "./migrations")]
    #[ignore = "requires DATABASE_URL — run with `cargo test -- --include-ignored`"]
    async fn sweep_drops_old_notices_and_wipes_old_ips(pool: PgPool) {
        let old = report_row(&pool, 1, 2, Some("203.0.113.5")).await;
        let new = report_row(&pool, 3, 2, Some("198.51.100.1")).await;
        sqlx::query("UPDATE abuse_reports SET created_at = NOW() - INTERVAL '31 days' WHERE id = $1")
            .bind(old)
            .execute(&pool)
            .await
            .unwrap();
        post(&pool, "ok", "old").await.unwrap();
        post(&pool, "ok", "new").await.unwrap();
        sqlx::query("UPDATE admin_notices SET created_at = NOW() - INTERVAL '31 days' WHERE body = 'old'")
            .execute(&pool)
            .await
            .unwrap();
        assert_eq!(sweep(&pool).await.unwrap(), (1, 1));
        let ips: Vec<(i64, Option<String>)> =
            sqlx::query_as("SELECT id, reporter_ip FROM abuse_reports ORDER BY id").fetch_all(&pool).await.unwrap();
        assert_eq!(ips, vec![(old, None), (new, Some("198.51.100.1".into()))]);
        assert_eq!(notices(&pool).await, vec![("ok".to_string(), "new".to_string())]);
    }
}
