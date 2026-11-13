// sinhron-cli — headless dev/test client for the Sinhron protocol.
//
// Usage examples:
//
//   sinhron-cli bootstrap \
//       --phrase "abandon abandon ... art" \
//       --server http://localhost:8080
//
//   sinhron-cli create-group \
//       --phrase "..." --server http://localhost:8080
//
//   sinhron-cli invite \
//       --phrase "..." --server http://localhost:8080 \
//       --group <hex-id> --target <peer-pubkey-hex>
//
//   sinhron-cli send \
//       --phrase "..." --server http://localhost:8080 \
//       --group <hex-id> --text "hi from cli"
//
//   sinhron-cli listen \
//       --phrase "..." --server http://localhost:8080 \
//       --group <hex-id>
//
// Each phrase produces a stable per-fingerprint state dir under
// `~/.sinhron-cli/<fingerprint>/`. The SQLite DB inside is encrypted
// with the phrase-derived `storage_key` (SQLCipher).

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use base64::{prelude::BASE64_STANDARD, Engine};
use clap::{Parser, Subcommand};
use sinhron_net::proto::ws_frame::Body;
use sinhron_net::proto::{
    call_invite::CallKind as ProtoCallKind, CallAccept, CallEnd, CallInvite, Submit, WsFrame,
};
use sinhron_net::{Event, WsClient, WsClientConfig};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};

#[derive(Parser, Debug)]
#[command(
    name = "sinhron-cli",
    version,
    about = "Headless Sinhron protocol harness — bootstrap, invite, send, listen",
    long_about = "Drives the full Sinhron client stack (MLS, WS, HTTP) without the \
                  Flutter UI. Useful for stress-testing, scripted regression smokes, \
                  and verifying server deployments before app release."
)]
struct Cli {
    /// Increase log verbosity (-v info, -vv debug, -vvv trace)
    #[arg(short, long, action = clap::ArgAction::Count)]
    verbose: u8,

    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Register identity + publish first KeyPackage to the server.
    /// Idempotent — re-running for the same phrase reports
    /// `already_existed=true`.
    Bootstrap {
        #[arg(long)]
        phrase: String,
        /// HTTP base URL of the operator server, e.g. http://localhost:8080
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
    },

    /// Create a fresh MLS group with this user as the only member.
    /// Prints the group_id_hex to stdout.
    CreateGroup {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
    },

    /// Invite a peer to a group by their identity pubkey. Fetches their
    /// pre-published KeyPackage, performs MLS Add, ships the Welcome
    /// via WS to the peer's session.
    Invite {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
        /// Group ID hex (the value printed by `create-group`)
        #[arg(long)]
        group: String,
        /// Peer's identity_pubkey_hex (their 32-byte Ed25519 pubkey)
        #[arg(long)]
        target: String,
    },

    /// Encrypt + submit one text message to the group via WS.
    Send {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
        #[arg(long)]
        group: String,
        /// The plaintext to send. UTF-8 only; arbitrary bytes via stdin
        /// are not yet supported.
        #[arg(long)]
        text: String,
        /// WS URL. Default derives from `--server` (https → wss; http → ws)
        /// plus `/v1/sync` path.
        #[arg(long)]
        ws: Option<String>,
    },

    /// Open WS, wait for incoming messages on the group, print them
    /// as they arrive. Stays alive until Ctrl-C (or 5 min idle).
    Listen {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
        #[arg(long)]
        group: String,
        #[arg(long)]
        ws: Option<String>,
        /// Max seconds to wait for activity before exiting.
        #[arg(long, default_value_t = 300)]
        timeout_secs: u64,
    },

    /// CC7 — initiate a call to a peer. Sends CallInvite WS frame.
    /// Server verifies 1:1 group membership before forwarding. Prints
    /// the call_id; use it with `call-accept` / `call-end` to drive
    /// the lifecycle. Useful for headless 2-party signaling tests
    /// без iOS Sim.
    CallInvite {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
        /// MLS group_id (hex) — the 1:1 chat to call.
        #[arg(long)]
        group: String,
        /// "audio" or "video". Affects metadata only at this layer;
        /// real media transport (livekit_client) lives in the app.
        #[arg(long, default_value = "audio")]
        kind: String,
        /// Ringing TTL in seconds (server caps at 60).
        #[arg(long, default_value_t = 30)]
        ttl_secs: i64,
        #[arg(long)]
        ws: Option<String>,
    },

    /// CC7 — accept or decline an incoming call. `--accept=true` picks
    /// up; `--accept=false` declines (server translates to CallEnd
    /// {reason: "rejected"} for the caller).
    CallAccept {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
        /// The call_id from a received CallInvite (printed by `listen`).
        #[arg(long)]
        call_id: String,
        #[arg(long, default_value_t = true)]
        accept: bool,
        #[arg(long)]
        ws: Option<String>,
    },

    /// CC7 — end an in-progress call. Either side may end. `reason`
    /// is free-text for diagnostics (truncated server-side to 64 chars).
    CallEnd {
        #[arg(long)]
        phrase: String,
        #[arg(long, default_value = "http://localhost:8080")]
        server: String,
        #[arg(long)]
        call_id: String,
        #[arg(long, default_value = "hangup")]
        reason: String,
        #[arg(long)]
        ws: Option<String>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    init_tracing(cli.verbose);
    match cli.cmd {
        Cmd::Bootstrap { phrase, server } => cmd_bootstrap(&phrase, &server).await,
        Cmd::CreateGroup { phrase, server } => cmd_create_group(&phrase, &server).await,
        Cmd::Invite {
            phrase,
            server,
            group,
            target,
        } => cmd_invite(&phrase, &server, &group, &target).await,
        Cmd::Send {
            phrase,
            server,
            group,
            text,
            ws,
        } => cmd_send(&phrase, &server, &group, &text, ws.as_deref()).await,
        Cmd::Listen {
            phrase,
            server,
            group,
            ws,
            timeout_secs,
        } => cmd_listen(&phrase, &server, &group, ws.as_deref(), timeout_secs).await,
        Cmd::CallInvite {
            phrase,
            server,
            group,
            kind,
            ttl_secs,
            ws,
        } => cmd_call_invite(&phrase, &server, &group, &kind, ttl_secs, ws.as_deref()).await,
        Cmd::CallAccept {
            phrase,
            server,
            call_id,
            accept,
            ws,
        } => cmd_call_accept(&phrase, &server, &call_id, accept, ws.as_deref()).await,
        Cmd::CallEnd {
            phrase,
            server,
            call_id,
            reason,
            ws,
        } => cmd_call_end(&phrase, &server, &call_id, &reason, ws.as_deref()).await,
    }
}

fn init_tracing(verbosity: u8) {
    let level = match verbosity {
        0 => "warn",
        1 => "info",
        2 => "debug",
        _ => "trace",
    };
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| format!("sinhron_cli={level},sinhron_sync={level},sinhron_net={level}").into()),
        )
        .with_target(false)
        .try_init();
}

/// Per-phrase state directory under `~/.sinhron-cli/<fingerprint>/`.
/// The fingerprint is the first 12 hex chars of SHA-256(ed25519_public
/// || x25519_public) so colliding phrases (which can't happen with
/// proper BIP-39) would still produce different dirs.
fn state_dir(phrase: &str) -> Result<PathBuf> {
    let id = sinhron_crypto::identity::derive_identity(phrase)
        .map_err(|e| anyhow!("derive identity: {e}"))?;
    let fp_with_spaces = sinhron_crypto::identity::fingerprint_hex(&id);
    let fp = fp_with_spaces.replace(' ', "");
    let home = dirs_home()?;
    let dir = home.join(".sinhron-cli").join(&fp);
    std::fs::create_dir_all(&dir)
        .with_context(|| format!("mkdir {dir:?}"))?;
    Ok(dir)
}

/// Home directory: `$HOME` on Unix, `USERPROFILE` on Windows (std's resolver,
/// un-deprecated since Rust 1.86). Falls back to the temp dir if neither is set.
fn dirs_home() -> Result<PathBuf> {
    #[allow(deprecated)]
    let home = std::env::home_dir().filter(|p| !p.as_os_str().is_empty());
    Ok(home.unwrap_or_else(std::env::temp_dir))
}

fn mls_db_path(phrase: &str) -> Result<PathBuf> {
    Ok(state_dir(phrase)?.join("mls-state.sqlite"))
}

async fn cmd_bootstrap(phrase: &str, server: &str) -> Result<()> {
    let db = mls_db_path(phrase)?;
    println!("→ bootstrapping under {db:?}");
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: phrase.to_string(),
        db_path: Some(db),
        device_seed: None,
    })
    .context("SyncClient::new")?;
    let http = HttpApi::new(server.to_string());
    let outcome = client
        .bootstrap_with_server(&http)
        .await
        .context("bootstrap_with_server")?;
    println!(
        "✓ user_pk={} already_existed={} identity={} kp_id={}",
        outcome.user_pk,
        outcome.already_existed,
        outcome.identity_pubkey_hex,
        outcome.keypackage_id,
    );
    Ok(())
}

async fn cmd_create_group(phrase: &str, _server: &str) -> Result<()> {
    let db = mls_db_path(phrase)?;
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: phrase.to_string(),
        db_path: Some(db),
        device_seed: None,
    })?;
    let group_id = client.create_group().context("create_group")?;
    let hex_id = hex::encode(&group_id);
    println!("{hex_id}");
    eprintln!("(saved into your per-phrase state dir; reuse with --group {hex_id})");
    Ok(())
}

async fn cmd_invite(phrase: &str, server: &str, group_hex: &str, target_hex: &str) -> Result<()> {
    let db = mls_db_path(phrase)?;
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: phrase.to_string(),
        db_path: Some(db),
        device_seed: None,
    })?;
    let http = HttpApi::new(server.to_string());
    let group_id = hex::decode(group_hex).context("group hex")?;
    let outcome = client
        .fetch_kp_and_invite(&http, &group_id, target_hex)
        .await
        .context("fetch_kp_and_invite")?;
    println!(
        "✓ commit_bytes={} welcome_bytes={}",
        outcome.commit_bytes.len(),
        outcome.welcome_bytes.len()
    );
    println!("welcome_b64={}", BASE64_STANDARD.encode(&outcome.welcome_bytes));
    eprintln!(
        "(deliver this Welcome to {target_hex} via `sinhron-cli` listen on their side, \
         or via the live WS — see `Send` command)"
    );
    Ok(())
}

async fn cmd_send(
    phrase: &str,
    server: &str,
    group_hex: &str,
    text: &str,
    ws_url: Option<&str>,
) -> Result<()> {
    let db = mls_db_path(phrase)?;
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: phrase.to_string(),
        db_path: Some(db),
        device_seed: None,
    })?;
    let group_id = hex::decode(group_hex).context("group hex")?;
    let ciphertext = client
        .encrypt(&group_id, text.as_bytes())
        .context("encrypt")?;

    let derived = sinhron_crypto::identity::derive_identity(phrase)
        .map_err(|e| anyhow!("derive: {e}"))?;
    let ws_url = ws_url.map(String::from).unwrap_or_else(|| http_to_ws(server));
    let ws = WsClient::start(WsClientConfig {
        url: ws_url.clone(),
        identity_seed: derived.ed25519_secret,
        tls: None,
        resume_cursor: None,
    });
    wait_connected(&ws, "send").await?;

    let frame = WsFrame {
        frame_id: "cli-submit-1".to_string(),
        body: Some(Body::Submit(Submit {
            group_id,
            ciphertext: ciphertext.clone(),
            // UUIDv4 random-enough for CLI usage.
            message_id: format!(
                "cli-{}",
                hex::encode(rand_bytes_8())
            ),
            // T1.4 — CLI defaults to non-sealed for backward-compat
            // with existing server tests; sealed-mode is exposed via
            // a future `--sealed` flag once HPKE wrapping lands.
            sealed_sender: false,
            is_commit: false,
            commit_epoch: 0,
            urgent: false,
            access_keys: Vec::new(),
            refused_commit_ids: Vec::new(),
            parent_commit_id: String::new(),
        })),
    };
    ws.send(frame).await.context("ws send")?;
    println!(
        "✓ submitted · ws={ws_url} ciphertext_bytes={}",
        ciphertext.len()
    );

    // Wait briefly for server Ack so the user sees it.
    let _ = tokio::time::timeout(Duration::from_secs(3), wait_for_ack(&ws)).await;
    ws.shutdown();
    Ok(())
}

async fn cmd_listen(
    phrase: &str,
    server: &str,
    group_hex: &str,
    ws_url: Option<&str>,
    timeout_secs: u64,
) -> Result<()> {
    let db = mls_db_path(phrase)?;
    let mut client = SyncClient::new(SyncClientConfig {
        phrase: phrase.to_string(),
        db_path: Some(db),
        device_seed: None,
    })?;
    let group_id = hex::decode(group_hex).context("group hex")?;
    let derived = sinhron_crypto::identity::derive_identity(phrase)
        .map_err(|e| anyhow!("derive: {e}"))?;
    let ws_url = ws_url.map(String::from).unwrap_or_else(|| http_to_ws(server));

    let ws = WsClient::start(WsClientConfig {
        url: ws_url.clone(),
        identity_seed: derived.ed25519_secret,
        tls: None,
        resume_cursor: None,
    });
    wait_connected(&ws, "listen").await?;
    println!("✓ listening on {ws_url} group={group_hex} (timeout {timeout_secs}s)");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_secs);

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            println!("(timeout — exiting)");
            break;
        }
        let event = match tokio::time::timeout(remaining, ws.recv()).await {
            Ok(Some(e)) => e,
            Ok(None) => {
                println!("(ws closed)");
                break;
            }
            Err(_) => {
                println!("(idle timeout — exiting)");
                break;
            }
        };
        match event {
            Event::Connected => {}
            Event::Disconnected { reason } => {
                println!("(disconnected: {reason})");
            }
            Event::Frame(f) => match f.body {
                Some(Body::Push(p)) => {
                    if p.group_id != group_id {
                        // Not for us; skip silently.
                        continue;
                    }
                    let decoded = client
                        .decrypt(&p.group_id, &p.ciphertext)
                        .context("decrypt push")?;
                    match decoded {
                        IncomingMessage::App(bytes) => {
                            let preview = String::from_utf8_lossy(&bytes);
                            println!("← msg \"{preview}\"  (seq={} id={})", p.sequence, p.message_id);
                        }
                        IncomingMessage::Commit { new_epoch, .. } => {
                            println!("← commit applied · epoch={new_epoch}");
                        }
                        IncomingMessage::StaleEpoch { my_epoch } => {
                            println!("← stale-epoch frame dropped (my_epoch={my_epoch})");
                        }
                        IncomingMessage::OwnCommitEcho => {}
                        IncomingMessage::Other => {}
                    }
                }
                Some(Body::Welcome(w)) => {
                    println!(
                        "← welcome group={} welcome_bytes={}",
                        hex::encode(&w.group_id),
                        w.welcome_bytes.len()
                    );
                    if let Err(e) = client.join_via_welcome(&w.welcome_bytes) {
                        eprintln!("  (join failed: {e})");
                    }
                }
                Some(Body::Ack(a)) => {
                    println!(
                        "← ack frame={} code={} msg={}",
                        a.acked_frame_id, a.error_code, a.error_message
                    );
                }
                _ => {}
            },
        }
    }
    ws.shutdown();
    Ok(())
}

// ── CC7 — call signaling subcommands ────────────────────────────────

/// Spin up a WS connection signed by `phrase`, send a single frame,
/// briefly wait for Ack, shut down. Shared by all three call subcommands.
async fn send_call_frame_once(
    phrase: &str,
    server: &str,
    ws_url: Option<&str>,
    frame: WsFrame,
    label: &str,
) -> Result<()> {
    let derived = sinhron_crypto::identity::derive_identity(phrase)
        .map_err(|e| anyhow!("derive: {e}"))?;
    let ws_url = ws_url.map(String::from).unwrap_or_else(|| http_to_ws(server));
    let ws = WsClient::start(WsClientConfig {
        url: ws_url.clone(),
        identity_seed: derived.ed25519_secret,
        tls: None,
        resume_cursor: None,
    });
    wait_connected(&ws, label).await?;
    ws.send(frame).await.context(format!("{label}: ws send"))?;
    println!("✓ {label} sent · ws={ws_url}");
    // Short ack wait so user sees server's response code.
    let _ = tokio::time::timeout(Duration::from_secs(3), wait_for_ack(&ws)).await;
    ws.shutdown();
    Ok(())
}

async fn cmd_call_invite(
    phrase: &str,
    server: &str,
    group_hex: &str,
    kind: &str,
    ttl_secs: i64,
    ws_url: Option<&str>,
) -> Result<()> {
    let group_id = hex::decode(group_hex).context("group hex")?;
    let kind_enum = match kind.to_ascii_lowercase().as_str() {
        "audio" => ProtoCallKind::Audio,
        "video" => ProtoCallKind::Video,
        other => return Err(anyhow!("unknown kind '{}' (expected audio|video)", other)),
    };
    let call_id = uuid::Uuid::now_v7().to_string();
    println!("→ inviting · call_id={call_id} kind={kind} ttl={ttl_secs}s");
    // ADR-090 — signed by the caller (the identity key: a first device).
    let seed = sinhron_crypto::identity::derive_identity(phrase).context("derive identity")?.ed25519_secret;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    let caller_proof = sinhron_sync::call_invite::sign(&seed, None, &call_id, &group_id, kind_enum == ProtoCallKind::Video, now);

    let frame = WsFrame {
        frame_id: format!("cli-call-invite-{}", hex::encode(rand_bytes_8())),
        body: Some(Body::CallInvite(CallInvite {
            call_id: call_id.clone(),
            group_id,
            kind: kind_enum as i32,
            livekit_room: format!("sinhron-call-{call_id}"),
            ttl_secs,
            // The server fills in who calls.
            caller_identity: Vec::new(),
            access_keys: Vec::new(),
            sends_access_keys: true,
            caller_proof,
        })),
    };
    send_call_frame_once(phrase, server, ws_url, frame, "CallInvite").await
}

async fn cmd_call_accept(
    phrase: &str,
    server: &str,
    call_id: &str,
    accept: bool,
    ws_url: Option<&str>,
) -> Result<()> {
    let frame = WsFrame {
        frame_id: format!("cli-call-accept-{}", hex::encode(rand_bytes_8())),
        body: Some(Body::CallAccept(CallAccept {
            call_id: call_id.to_string(),
            accept,
        })),
    };
    let label = if accept { "CallAccept(accept)" } else { "CallAccept(decline)" };
    send_call_frame_once(phrase, server, ws_url, frame, label).await
}

async fn cmd_call_end(
    phrase: &str,
    server: &str,
    call_id: &str,
    reason: &str,
    ws_url: Option<&str>,
) -> Result<()> {
    let frame = WsFrame {
        frame_id: format!("cli-call-end-{}", hex::encode(rand_bytes_8())),
        body: Some(Body::CallEnd(CallEnd {
            call_id: call_id.to_string(),
            reason: reason.to_string(),
        })),
    };
    send_call_frame_once(phrase, server, ws_url, frame, "CallEnd").await
}

async fn wait_connected(ws: &WsClient, label: &str) -> Result<()> {
    let event = tokio::time::timeout(Duration::from_secs(10), ws.recv())
        .await
        .context(format!("{label}: connect timeout"))?
        .ok_or_else(|| anyhow!("{label}: ws closed before Connected"))?;
    match event {
        Event::Connected => Ok(()),
        Event::Disconnected { reason } => Err(anyhow!("{label}: disconnected before connect — {reason}")),
        Event::Frame(_) => Err(anyhow!("{label}: frame before Connected")),
    }
}

async fn wait_for_ack(ws: &WsClient) -> Result<()> {
    loop {
        let event = ws.recv().await.ok_or_else(|| anyhow!("ws closed"))?;
        if let Event::Frame(f) = event {
            if let Some(Body::Ack(_)) = f.body {
                return Ok(());
            }
        }
    }
}

/// Convert `http://...` / `https://...` to `ws://.../v1/sync` /
/// `wss://.../v1/sync` respectively.
fn http_to_ws(http_url: &str) -> String {
    let stripped = if let Some(s) = http_url.strip_suffix('/') {
        s
    } else {
        http_url
    };
    if let Some(rest) = stripped.strip_prefix("https://") {
        format!("wss://{rest}/v1/sync")
    } else if let Some(rest) = stripped.strip_prefix("http://") {
        format!("ws://{rest}/v1/sync")
    } else {
        format!("{stripped}/v1/sync")
    }
}

/// 8 random bytes for message_id suffix. Uses OS entropy via
/// `ed25519_dalek::SigningKey::generate` indirection would be heavy;
/// here we just call the libc rand_core path that's already pulled.
fn rand_bytes_8() -> [u8; 8] {
    use rand_core::{OsRng, RngCore};
    let mut out = [0u8; 8];
    OsRng.fill_bytes(&mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_to_ws_converts_correctly() {
        assert_eq!(http_to_ws("http://localhost:8080"), "ws://localhost:8080/v1/sync");
        assert_eq!(http_to_ws("https://sinhron.example"), "wss://sinhron.example/v1/sync");
        assert_eq!(http_to_ws("http://localhost:8080/"), "ws://localhost:8080/v1/sync");
        // Pass-through fallback (no scheme prefix): just append path.
        assert_eq!(http_to_ws("localhost:8080"), "localhost:8080/v1/sync");
    }

    #[test]
    fn parser_accepts_full_command_set() {
        // Smoke: every subcommand parses without panic. This catches
        // typos in #[arg] attributes that would otherwise only show
        // up at runtime.
        let cases = [
            vec!["sinhron-cli", "bootstrap", "--phrase", "p", "--server", "http://x"],
            vec!["sinhron-cli", "create-group", "--phrase", "p"],
            vec!["sinhron-cli", "invite", "--phrase", "p", "--group", "g", "--target", "t"],
            vec!["sinhron-cli", "send", "--phrase", "p", "--group", "g", "--text", "hi"],
            vec!["sinhron-cli", "listen", "--phrase", "p", "--group", "g"],
        ];
        for argv in cases {
            Cli::try_parse_from(argv).expect("parses");
        }
    }
}
