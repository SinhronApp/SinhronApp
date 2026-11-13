// Telegram sticker packs by link — ADR-062. The phone asks its own Sinhron
// server (POST /v1/stickers/telegram, GET …/{name}/{i}[/thumb]); the server
// asks the Telegram Bot API with the operator's bot token and keeps the
// pack for a day. Telegram never sees the phone; the files become an own
// pack here, encrypted like any other (ADR-049).

use serde::Deserialize;

use crate::http_api::{action_proof, record_drift_from_response, HttpApi, HttpError};

/// Mirrors of the server's `TG_STICKERS_DOMAIN` / `TG_STICKER_FILE_DOMAIN`
/// (server/src/handlers/proof.rs).
const TG_STICKERS_DOMAIN: &[u8] = b"sinhron-tg-stickers-v1:";
const TG_STICKER_FILE_DOMAIN: &[u8] = b"sinhron-tg-sticker-file-v1:";

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct TelegramPack {
    pub name: String,
    pub title: String,
    /// "regular" | "mask" | "custom_emoji"
    #[serde(default)]
    pub kind: String,
    pub stickers: Vec<TelegramSticker>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct TelegramSticker {
    #[serde(default)]
    pub emoji: String,
    /// "tgs" | "webm" | "webp"
    pub format: String,
    #[serde(default)]
    pub width: u32,
    #[serde(default)]
    pub height: u32,
    /// Telegram has a small still for it (`…/thumb`).
    #[serde(default)]
    pub thumb: bool,
}

/// Why a pack didn't come, for plain words in the app:
/// `not_found`, `not_configured` (no bot token on the server),
/// `server_old` (a server without the feature), `unreachable` (the server
/// can't reach Telegram), `rate_limited`, `network` (can't reach our
/// server), `failed` (anything else).
pub fn error_code(e: &HttpError) -> &'static str {
    match e {
        HttpError::Transport(_) => "network",
        HttpError::Server { status, body } => {
            let code = serde_json::from_str::<serde_json::Value>(body)
                .ok()
                .and_then(|v| v.get("error").and_then(|c| c.as_str()).map(str::to_string));
            match (code.as_deref(), *status) {
                (Some("not_found"), _) => "not_found",
                (Some("not_configured"), _) => "not_configured",
                (Some("unreachable"), _) => "unreachable",
                (Some("rate_limited"), _) | (_, 429) => "rate_limited",
                // Our router's own 404 / 405: no such endpoint yet.
                (None, 404 | 405) => "server_old",
                _ => "failed",
            }
        }
        _ => "failed",
    }
}

async fn reply(resp: reqwest::Response) -> Result<reqwest::Response, HttpError> {
    record_drift_from_response(&resp);
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    let body = resp.text().await.unwrap_or_default();
    Err(HttpError::Server { status: status.as_u16(), body })
}

/// The pack's title and stickers (no files yet).
pub async fn fetch_pack(http: &HttpApi, identity_seed: [u8; 32], name: &str) -> Result<TelegramPack, HttpError> {
    let (identity_hex, ts, proof_hex) = action_proof(http.host(), identity_seed, TG_STICKERS_DOMAIN, name.as_bytes());
    let resp = http
        .client()
        .post(format!("{}/v1/stickers/telegram", http.base_url()))
        .header("x-sinhron-identity", identity_hex)
        .header("x-sinhron-ts", ts.to_string())
        .header("x-sinhron-proof", proof_hex)
        .json(&serde_json::json!({ "name": name }))
        .send()
        .await
        .map_err(|e| HttpError::Transport(e.to_string()))?;
    reply(resp).await?.json().await.map_err(|e| HttpError::Parse(e.to_string()))
}

/// One sticker's file, or Telegram's small still of it ([thumb]).
pub async fn fetch_file(
    http: &HttpApi,
    identity_seed: [u8; 32],
    name: &str,
    index: u32,
    thumb: bool,
) -> Result<Vec<u8>, HttpError> {
    let path = if thumb { format!("{name}/{index}/thumb") } else { format!("{name}/{index}") };
    let (identity_hex, ts, proof_hex) = action_proof(http.host(), identity_seed, TG_STICKER_FILE_DOMAIN, path.as_bytes());
    let resp = http
        .client()
        .get(format!("{}/v1/stickers/telegram/{path}", http.base_url()))
        .header("x-sinhron-identity", identity_hex)
        .header("x-sinhron-ts", ts.to_string())
        .header("x-sinhron-proof", proof_hex)
        .send()
        .await
        .map_err(|e| HttpError::Transport(e.to_string()))?;
    // Read in pieces and stop at the limit: a host that streams without end
    // must not fill the phone's memory before the size check.
    let mut resp = reply(resp).await?;
    let mut bytes = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| HttpError::Transport(e.to_string()))? {
        if bytes.len() + chunk.len() > crate::sticker::MAX_STICKER_BYTES {
            return Err(HttpError::Parse("sticker too large".into()));
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// One HTTP answer per connection, from a thread; hands back what the
    /// app sent.
    fn serve(answers: Vec<String>) -> (String, std::sync::mpsc::Receiver<String>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for (conn, answer) in listener.incoming().zip(answers) {
                let mut conn = conn.unwrap();
                let mut buf = [0u8; 8192];
                let n = conn.read(&mut buf).unwrap_or(0);
                let _ = tx.send(String::from_utf8_lossy(&buf[..n]).to_string());
                let _ = conn.write_all(answer.as_bytes());
            }
        });
        (format!("http://{addr}"), rx)
    }

    fn answer(status: &str, body: &str) -> String {
        format!("HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len())
    }

    /// ADR-062 — the pack and a file come from our server, signed; the
    /// server's error codes become the app's.
    #[tokio::test]
    async fn packs_and_files_come_signed_and_errors_have_codes() {
        let pack = r#"{"name":"Ziongo777","title":"Зионго","kind":"regular","stickers":[{"emoji":"😀","format":"tgs","width":512,"height":512,"thumb":true},{"format":"webp"}]}"#;
        let (base, sent) = serve(vec![
            answer("200 OK", pack),
            answer("200 OK", "GIF89a"),
            answer("404 Not Found", r#"{"error":"not_found"}"#),
            answer("503 Service Unavailable", r#"{"error":"not_configured"}"#),
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_string(),
        ]);
        let http = HttpApi::new(base);
        let seed = [5u8; 32];

        let p = fetch_pack(&http, seed, "Ziongo777").await.unwrap();
        assert_eq!(p.title, "Зионго");
        assert_eq!(p.stickers.len(), 2);
        assert!(p.stickers[0].thumb && !p.stickers[1].thumb);
        assert_eq!(p.stickers[1].emoji, "");
        let req = sent.recv().unwrap();
        assert!(req.starts_with("POST /v1/stickers/telegram "), "{req}");
        assert!(req.contains("x-sinhron-proof: ") && req.contains(r#"{"name":"Ziongo777"}"#));

        assert_eq!(fetch_file(&http, seed, "Ziongo777", 0, true).await.unwrap(), b"GIF89a");
        assert!(sent.recv().unwrap().starts_with("GET /v1/stickers/telegram/Ziongo777/0/thumb "));

        let code = |r: Result<TelegramPack, HttpError>| error_code(&r.unwrap_err());
        assert_eq!(code(fetch_pack(&http, seed, "Nope").await), "not_found");
        assert_eq!(code(fetch_pack(&http, seed, "Ziongo777").await), "not_configured");
        assert_eq!(code(fetch_pack(&http, seed, "Ziongo777").await), "server_old", "a server without the endpoint");
    }

    #[test]
    fn every_failure_has_a_plain_code() {
        let server = |status: u16, body: &str| HttpError::Server { status, body: body.into() };
        assert_eq!(error_code(&HttpError::Transport("dns".into())), "network");
        assert_eq!(error_code(&server(502, r#"{"error":"unreachable"}"#)), "unreachable");
        assert_eq!(error_code(&server(429, r#"{"error":"rate limited","retry_after_secs":3}"#)), "rate_limited");
        assert_eq!(error_code(&server(405, "")), "server_old");
        assert_eq!(error_code(&server(500, r#"{"error":"internal error"}"#)), "failed");
    }
}
