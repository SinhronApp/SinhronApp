// Sinhron operator server — library crate. The binary in `src/main.rs`
// is a thin wrapper around [`run`]; everything else (routing, handlers,
// proto types, WS layer) lives here so integration tests and examples
// can pull in the internals via `sinhron_server::*`.

pub mod accounts;
pub mod admin;
pub mod apns;
pub mod call_session;
pub mod db;
pub mod fcm;
pub mod handlers;
pub mod healthcheck;
pub mod metrics;
pub mod proto;
pub mod push;
pub mod rate_limit;
pub mod retention;
pub mod session;
pub mod unifiedpush;
pub mod webpush;
pub mod ws;

/// Tech-debt 2.12 — public keys in logs are shortened to their first 12
/// hex chars: enough to correlate log lines, not enough to name a user
/// across systems. Internal ids (`user_pk` UUIDs) are logged as is.
/// Control characters become `?`: the key may be a stranger's unchecked
/// input, and the log formatter does not escape `%` fields (deploy-deps:11).
pub fn short_key(hex: &str) -> String {
    let head: String = hex
        .chars()
        .take(12)
        .map(|c| if c.is_control() { '?' } else { c })
        .collect();
    if hex.chars().count() > 12 {
        format!("{head}…")
    } else {
        head
    }
}

use std::sync::Arc;

use std::net::SocketAddr;
use std::str::FromStr;

use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use serde_json::json;
use sqlx::PgPool;
use tokio::net::TcpListener;
use tower_http::request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer};
use tower_http::trace::TraceLayer;
use tracing::{info, warn};
use tracing_subscriber::EnvFilter;

/// CARGO_PKG_VERSION at compile time — exposed in /_healthz so operators
/// can confirm the running build matches what they deployed.
pub const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Shared per-request state. Endpoints that require persistence
/// short-circuit to 503 when `pool` is None instead of crashing.
#[derive(Clone)]
pub struct AppState {
    pub pool: Option<PgPool>,
    /// In-memory registry of authenticated WS sessions. The Submit
    /// handler uses this to Push outgoing frames to other connected
    /// group members in real time. Cheap to clone (Arc inside).
    pub sessions: session::SessionRegistry,
    /// Push notification provider. Trait object so APNs / FCM clients
    /// can be swapped in via env / config. Defaults to a logging stub
    /// (WU A10); real impls land in later WUs.
    pub push: Arc<dyn push::PushClient>,
    /// T1.5 — process-wide rate limiter. Identity / KeyPackage /
    /// Submit endpoints check buckets keyed by source IP (HTTP) or
    /// user_pk (WS).
    pub rate: rate_limit::RateLimiter,
    /// CB3 — in-memory CallSession registry. Tracks active 1:1 (and
    /// future group) calls so the server can deduplicate `CallInvite`,
    /// authorize `CallAccept`/`CallEnd`, and run the ringing watchdog.
    pub calls: call_session::CallSessionRegistry,
}

/// Boot the server. Reads env (`SINHRON_LISTEN`, `SINHRON_DB_URL`,
/// `RUST_LOG`), wires the router, applies migrations, and serves until
/// SIGINT/SIGTERM. Returns when shutdown completes cleanly.
pub async fn run() -> anyhow::Result<()> {
    init_tracing();
    handlers::call::refuse_public_secrets().map_err(|e| anyhow::anyhow!(e))?;
    // ADR-086 — apps' signatures must name one of these (SINHRON_PUBLIC_HOSTNAME).
    tracing::info!(hosts = ?handlers::proof::public_hosts(), "signatures are taken for these server names");

    let listen =std::env::var("SINHRON_LISTEN").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    let addr = SocketAddr::from_str(&listen)
        .map_err(|e| anyhow::anyhow!("invalid SINHRON_LISTEN={listen}: {e}"))?;

    let pool = match std::env::var("SINHRON_DB_URL").ok().filter(|s| !s.is_empty()) {
        Some(url) => {
            let pool = db::connect_pool(&url).await?;
            // Tech-debt 2.13 — behind PgBouncer (transaction pooling) the
            // migrator's session-level advisory lock isn't safe, so
            // migrations can go straight to Postgres via
            // SINHRON_DB_MIGRATE_URL; queries keep using the pooler.
            let migrated = match std::env::var("SINHRON_DB_MIGRATE_URL").ok().filter(|s| !s.is_empty()) {
                Some(direct) => match db::connect_pool(&direct).await {
                    Ok(direct_pool) => {
                        let r = db::run_migrations(&direct_pool).await;
                        direct_pool.close().await;
                        r
                    }
                    Err(e) => Err(e),
                },
                None => db::run_migrations(&pool).await,
            };
            match migrated {
                Ok(()) => info!("migrations applied at startup"),
                // WEB-1 — not on the old schema: exit, Docker starts it again.
                Err(e) => return Err(anyhow::anyhow!("startup migration failed: {e}")),
            }
            // Background retention worker — periodic TTL cleanup per §7.6.
            // Detached task; ends when the pool drops on server shutdown.
            let _ = retention::spawn(pool.clone());
            Some(pool)
        }
        None => {
            warn!("SINHRON_DB_URL not set — running without persistent storage");
            None
        }
    };

    let state = AppState {
        pool,
        sessions: session::SessionRegistry::new(),
        push: push::from_env(),
        rate: rate_limit::RateLimiter::from_env(),
        calls: call_session::CallSessionRegistry::new(),
    };

    // CB5 — spawn the ringing watchdog. Detached task lives until process
    // exit. Broadcasts CallEnd { reason: "no_answer" } for Ringing sessions
    // that exceed `RINGING_TIMEOUT_SECS` and keeps the `calls_active`
    // gauge current.
    // ADR-077 — service notices for the server's administrators.
    if let Some(pool) = &state.pool {
        let _admin = admin::spawn(pool.clone(), state.push.clone(), state.sessions.clone());
    }

    let _watchdog = ws::spawn_call_watchdog(state.calls.clone(), state.sessions.clone());

    // ADR-062 — Telegram sticker packs: one client + day cache, swept hourly.
    let telegram = handlers::telegram_stickers::TelegramStickers::from_env();
    let _tg_sweeper = telegram.spawn_sweeper();

    let app = build_app_with(state, telegram);

    let listener = TcpListener::bind(addr)
        .await
        .map_err(|e| anyhow::anyhow!("bind {addr} failed: {e}"))?;
    info!(
        version = SERVER_VERSION,
        bind = %addr,
        "sinhron-server listening"
    );

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|e| anyhow::anyhow!("server crashed: {e}"))?;

    info!("sinhron-server shutdown complete");
    Ok(())
}

/// Build the application router. Public so integration tests + the
/// `ws_client` example can mount the same app in-process.
pub fn build_app(state: AppState) -> Router {
    build_app_with(state, handlers::telegram_stickers::TelegramStickers::from_env())
}

/// [build_app] with a given Telegram sticker client (ADR-062; tests pass
/// one that talks to a fake Bot API).
pub fn build_app_with(state: AppState, telegram: Arc<handlers::telegram_stickers::TelegramStickers>) -> Router {
    Router::new()
        .route("/_healthz", get(healthz))
        .route("/_readyz", get(readyz))
        // ADR-043 — invite links: the install page and the app-link files.
        .route("/join", get(handlers::join::page))
        .route("/i/{id}", get(handlers::join::page))
        // WEB-3 — a full invite is under 6 KiB of JSON.
        .route("/v1/invites", post(handlers::invites::create).layer(axum::extract::DefaultBodyLimit::max(8 * 1024)))
        .route("/v1/invites/{id}", get(handlers::invites::get))
        .route("/.well-known/apple-app-site-association", get(handlers::join::apple_app_site_association))
        .route("/.well-known/assetlinks.json", get(handlers::join::assetlinks))
        // T2.4 — Prometheus exposition. Public path; protect at
        // reverse-proxy layer if deploying to open internet.
        .route("/v1/identity", post(handlers::identity::register))
        .route("/v1/keypackages", post(handlers::keypackages::upload))
        .route(
            "/v1/keypackages/consume",
            get(handlers::keypackages::consume),
        )
        .route("/v1/keypackages/available", get(handlers::keypackages::available))
        .route("/v1/groups", post(handlers::groups::create))
        .route("/v1/groups/{group_id}/retention", axum::routing::put(handlers::groups::set_retention))
        .route("/v1/groups/{group_id}/leave", post(handlers::groups::leave))
        .route("/v1/groups/{group_id}/remove", post(handlers::groups::remove))
        .route("/v1/groups/{group_id}/card", axum::routing::put(handlers::groups::put_card).post(handlers::groups::get_card))
        // ADR-090 — the newest backup's time, against a rolled-back cloud.
        .route("/v1/backup-mark", post(handlers::backup_mark::mark))
        .route("/v1/account/delete", post(handlers::account::delete))
        .route("/v1/reports", post(handlers::account::report))
        .route("/v1/admin/notices", post(handlers::admin::notices))
        .route("/v1/push-token", axum::routing::put(handlers::push_tokens::put))
        .route("/v1/push/info", get(handlers::push_tokens::info))
        // ADR-025 — linked devices.
        .route("/v1/devices", get(handlers::devices::list).post(handlers::devices::add))
        .route("/v1/devices/{device_pk}", axum::routing::delete(handlers::devices::revoke))
        .route(
            "/v1/pairing/{pairing_id}",
            get(handlers::pairing::take).put(handlers::pairing::put),
        )
        .route(
            "/v1/sealed-keys",
            get(handlers::sealed_keys::get).put(handlers::sealed_keys::put),
        )
        // ADR-071 — per-contact access keys, blocks and unblocks.
        .route("/v1/access-keys", axum::routing::put(handlers::access_keys::put))
        .route(
            "/v1/sealed",
            post(handlers::sealed_keys::anonymous_submit_http).layer(handlers::sealed_keys::anonymous_body_limit()),
        )
        .route("/v1/sync", get(ws::ws_upgrade))
        // CA3 + CA4 — calls infrastructure: LiveKit JWT mint + TURN creds.
        .route("/v1/call/token", post(handlers::call::mint_token))
        .route("/v1/call/turn", get(handlers::call::mint_turn_creds))
        .route("/v1/call/live", post(handlers::call::call_live))
        // Encrypted media blobs (spec §6.9, ADR-017). The handler streams
        // the body itself and enforces SINHRON_MEDIA_MAX_BYTES, so axum's
        // 2 MiB extractor default must not apply.
        .route(
            "/v1/media",
            post(handlers::media::upload).layer(axum::extract::DefaultBodyLimit::disable()),
        )
        // ADR-064 — a device transfer keeps referenced blobs alive.
        .route("/v1/media/touch", post(handlers::media::touch))
        .route("/v1/media/{sha256}", get(handlers::media::download))
        // ADR-062 — Telegram sticker packs by link, fetched with the
        // operator's bot token and cached for a day.
        .route("/v1/stickers/telegram", post(handlers::telegram_stickers::pack))
        .route("/v1/stickers/telegram/{name}/{index}", get(handlers::telegram_stickers::file))
        .route("/v1/stickers/telegram/{name}/{index}/thumb", get(handlers::telegram_stickers::thumb))
        .layer(axum::Extension(telegram))
        // T2.5 — structured logging tightening.
        //
        // Order matters (Tower applies layers in reverse): outermost
        // sets the x-request-id, inner TraceLayer attaches it to span,
        // outermost again propagates the id into the response.
        // This gives each handler a stable request_id usable for
        // log-correlation across many lines (parse it from `info!`
        // structured fields).
        .layer(PropagateRequestIdLayer::x_request_id())
        // The span names the route template, never the real URI: paths and
        // queries carry invite ids, device keys, identity keys and proofs.
        .layer(TraceLayer::new_for_http().make_span_with(|r: &axum::http::Request<axum::body::Body>| {
            let route = r.extensions().get::<axum::extract::MatchedPath>().map(|p| p.as_str()).unwrap_or("");
            tracing::debug_span!("request", method = %r.method(), route)
        }))
        .layer(SetRequestIdLayer::x_request_id(MakeRequestUuid))
        .with_state(state)
}

/// Liveness probe — proves the process is alive. Never touches the DB
/// (that's `/_readyz`'s job).
async fn healthz() -> Json<serde_json::Value> {
    Json(json!({
        "status": "ok",
        "service": "sinhron-server",
        "version": SERVER_VERSION,
    }))
}

/// Readiness probe — proves the process can serve real traffic.
async fn readyz(
    State(state): State<AppState>,
) -> (StatusCode, Json<serde_json::Value>) {
    let (status, db_msg) = match &state.pool {
        None => (
            StatusCode::SERVICE_UNAVAILABLE,
            "no db configured".to_string(),
        ),
        Some(pool) => match db::ping(pool).await {
            Ok(()) => (StatusCode::OK, "ok".to_string()),
            // The detail goes to the log, not to whoever asks: it named the
            // database user (docs/security-review-2026-11.md, server-http:17).
            Err(e) => {
                tracing::warn!(error = %e, "readyz: database unreachable");
                (StatusCode::SERVICE_UNAVAILABLE, "unavailable".to_string())
            }
        },
    };
    (
        status,
        Json(json!({
            "status": if status == StatusCode::OK { "ready" } else { "not_ready" },
            "db": db_msg,
            "version": SERVER_VERSION,
        })),
    )
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(true)
        .try_init();
}

/// Resolves when SIGINT (Ctrl-C in dev) or SIGTERM (docker stop / k8s
/// preStop) is received. `axum::serve(...).with_graceful_shutdown(...)`
/// then stops accepting new connections but lets in-flight requests
/// finish — critical once we have multi-step WS reconciliation flows.
async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(e) = tokio::signal::ctrl_c().await {
            warn!(error = %e, "failed to install Ctrl-C handler");
        }
    };

    #[cfg(unix)]
    let terminate = async {
        use tokio::signal::unix::{signal, SignalKind};
        match signal(SignalKind::terminate()) {
            Ok(mut s) => {
                s.recv().await;
            }
            Err(e) => warn!(error = %e, "failed to install SIGTERM handler"),
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => info!("received Ctrl-C"),
        _ = terminate => info!("received SIGTERM"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;

    #[test]
    fn short_key_keeps_only_a_prefix() {
        let pk = "a".repeat(64);
        assert_eq!(short_key(&pk), format!("{}…", "a".repeat(12)));
        assert_eq!(short_key("abc"), "abc");
    }

    /// deploy-deps:11 — a stranger's key goes into a log line before it is
    /// checked (`device_prefix = %short_key(..)`). Terminal codes in it must
    /// come out escaped, or `docker compose logs -f` runs them on the
    /// operator's screen (clear it, retitle it). tracing-subscriber (even
    /// 0.3.20+) escapes only the message, so short_key() cleans the key.
    #[test]
    fn stranger_terminal_codes_in_a_logged_key_come_out_escaped() {
        #[derive(Clone, Default)]
        struct Buf(Arc<std::sync::Mutex<Vec<u8>>>);
        impl std::io::Write for Buf {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let buf = Buf::default();
        let w = buf.clone();
        // Same format as init_tracing().
        let sub = tracing_subscriber::fmt()
            .with_target(true)
            .with_writer(move || w.clone())
            .finish();
        tracing::subscriber::with_default(sub, || {
            info!(device_prefix = %short_key("\u{1b}[2J\u{1b}]0;x\u{7}"), "upload");
        });
        let out = String::from_utf8_lossy(&buf.0.lock().unwrap()).into_owned();
        assert!(out.contains("device_prefix"), "{out:?}");
        assert!(
            !out.contains("\u{1b}[2J") && !out.contains("\u{1b}]0;"),
            "{out:?}"
        );
    }

    /// server-http:13 / server-ws:8 — a log reader must not get full chat
    /// ids or who-invited/called-whom: those log fields carry a prefix only.
    #[test]
    fn logs_carry_no_full_group_ids_or_invite_graph() {
        let src = concat!(env!("CARGO_MANIFEST_DIR"), "/src");
        let mut files = vec![std::path::PathBuf::from(src)];
        let mut bad = vec![];
        while let Some(p) = files.pop() {
            if p.is_dir() {
                files.extend(std::fs::read_dir(&p).unwrap().map(|e| e.unwrap().path()));
                continue;
            }
            let text = std::fs::read_to_string(&p).unwrap();
            for (n, line) in text.lines().enumerate() {
                let field = ["group = %", "room = %", "caller = %", "callee = %", "actor = %", "recipient_user_pk = %"]
                    .iter()
                    .any(|f| line.trim_start().starts_with(f) || line.contains(&format!("({f}")));
                if field && !line.contains("short_key(") {
                    bad.push(format!("{}:{}: {}", p.display(), n + 1, line.trim()));
                }
            }
        }
        assert!(bad.is_empty(), "full ids in logs:\n{}", bad.join("\n"));
    }
    use axum::http::{Request, StatusCode};
    use http_body_util::BodyExt;
    use tower::ServiceExt;

    pub(crate) fn no_db_state() -> AppState {
        AppState {
            pool: None,
            sessions: session::SessionRegistry::new(),
            push: Arc::new(push::LoggingPush),
            rate: rate_limit::RateLimiter::new(rate_limit::RateConfig::defaults()),
            calls: call_session::CallSessionRegistry::new(),
        }
    }

    #[tokio::test]
    async fn healthz_returns_ok() {
        let app = build_app(no_db_state());
        let res = app
            .oneshot(
                Request::builder()
                    .uri("/_healthz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);

        let body = res.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(parsed["status"], "ok");
        assert_eq!(parsed["service"], "sinhron-server");
        assert!(parsed["version"].as_str().is_some_and(|s| !s.is_empty()));
    }

    #[tokio::test]
    async fn push_info_is_public() {
        let app = build_app(no_db_state());
        let res = app
            .oneshot(
                Request::builder()
                    .uri("/v1/push/info")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body = res.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(parsed["unifiedpush_hosts"].is_array());
    }

    #[tokio::test]
    async fn unknown_route_returns_404() {
        let app = build_app(no_db_state());
        let res = app
            .oneshot(
                Request::builder()
                    .uri("/does-not-exist")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn readyz_without_db_reports_503() {
        let app = build_app(no_db_state());
        let res = app
            .oneshot(
                Request::builder()
                    .uri("/_readyz")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);

        let body = res.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(parsed["status"], "not_ready");
        assert_eq!(parsed["db"], "no db configured");
    }

    // server-http:17 — a failing database: the answer says so, and no more.
    #[tokio::test]
    async fn readyz_hides_the_database_error() {
        let mut st = no_db_state();
        st.pool = Some(
            sqlx::postgres::PgPoolOptions::new()
                .acquire_timeout(std::time::Duration::from_secs(1))
                .connect_lazy("postgres://sinhron:wrong@127.0.0.1:1/sinhron")
                .unwrap(),
        );
        let res = build_app(st)
            .oneshot(Request::builder().uri("/_readyz").body(Body::empty()).unwrap())
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
        let body = res.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(parsed["db"], "unavailable");
    }
}
