// ADR-043 — invite links: `https://<this server>/join#<signed payload>`,
// shared as the short `https://<this server>/i/<id>#<key>` (invites.rs).
//
//     GET /join, GET /i/{id}                      the page for a phone without the app
//     GET /.well-known/apple-app-site-association  iOS: open /join links in the app;
//                                                  ADR-059: webcredentials (secret words in Passwords)
//     GET /.well-known/assetlinks.json             Android: the same
//
// The signed part of a link is after `#` — browsers never send it, so this
// server never sees who invited whom. With the app installed the phone opens
// the link in the app directly (the two files above); without it the
// browser shows this page: how to install, then "Open in the app"
// (`sinhron://join#…`, or `sinhron://i/<host>/<id>#…` for a short link —
// the fragment is copied by a tiny script, the only one the page may run,
// see `JOIN_SCRIPT_SHA256` and the Caddyfile CSP).
//
// App identifiers default to the official builds; an operator shipping its
// own build sets `SINHRON_APPLE_APP_ID`, `SINHRON_ANDROID_PACKAGE`,
// `SINHRON_ANDROID_CERT_SHA256`. Install links: `SINHRON_IOS_INSTALL_URL`
// (e.g. a public TestFlight link), `SINHRON_ANDROID_INSTALL_URL` (an APK).

use axum::{
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};

const DEFAULT_APPLE_APP_ID: &str = "CBJTTRBDF3.com.sinhron.sinhron";
const DEFAULT_ANDROID_PACKAGE: &str = "com.sinhron.sinhron";
const DEFAULT_ANDROID_CERT_SHA256: &str =
    "6F:04:86:35:C6:99:1F:E6:BB:3A:40:84:E4:4A:F3:9F:B3:1D:63:16:2A:A7:5B:DD:5C:8C:8B:8A:6C:6A:69:18";

/// The page's only script: point "Open in the app" at `sinhron://join#…`
/// (on /join) or `sinhron://i/<host>/<id>#…` (on a short link's /i/<id>).
pub const JOIN_SCRIPT: &str = "var h=location.hash,p=location.pathname,a=document.getElementById('open');if(h.length>1){a.href=p.indexOf('/i/')==0?'sinhron://i/'+location.host+p.slice(2)+h:'sinhron://join'+h}else{a.style.display='none'}";
/// `sha256-…` of [`JOIN_SCRIPT`] — the Caddyfile's CSP for /join allows it
/// (a test keeps the two in step).
pub const JOIN_SCRIPT_SHA256: &str = "sha256-6FclWoJyYXY0mN8JKrLf/LA8iX0VitVk7UzjtuXBG8M=";

fn env_or(key: &str, fallback: &str) -> String {
    std::env::var(key).ok().filter(|v| !v.trim().is_empty()).unwrap_or_else(|| fallback.to_string())
}

/// An https link from the environment, safe to put in an attribute.
fn https_env(key: &str) -> Option<String> {
    let v = std::env::var(key).ok()?;
    let v = v.trim();
    (v.starts_with("https://") && !v.contains(['"', '<', '>', '\'', ' '])).then(|| v.to_string())
}

pub async fn apple_app_site_association() -> Response {
    let app = env_or("SINHRON_APPLE_APP_ID", DEFAULT_APPLE_APP_ID);
    // ADR-059 — `webcredentials`: the app may save the person's secret words
    // to iOS Passwords under this domain. The server never sees them; this
    // only tells iOS the app and the domain belong together.
    let body = serde_json::json!({
        "applinks": {
            "details": [{
                "appIDs": [app],
                "components": [{ "/": "/join" }, { "/": "/join/*" }, { "/": "/i/*" }],
            }]
        },
        "webcredentials": { "apps": [app] },
    });
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

pub async fn assetlinks() -> Response {
    let body = serde_json::json!([{
        "relation": ["delegate_permission/common.handle_all_urls"],
        "target": {
            "namespace": "android_app",
            "package_name": env_or("SINHRON_ANDROID_PACKAGE", DEFAULT_ANDROID_PACKAGE),
            "sha256_cert_fingerprints": [env_or("SINHRON_ANDROID_CERT_SHA256", DEFAULT_ANDROID_CERT_SHA256)],
        }
    }]);
    ([(header::CONTENT_TYPE, "application/json")], body.to_string()).into_response()
}

struct Words {
    lang: &'static str,
    title: &'static str,
    lead: &'static str,
    step_install: &'static str,
    step_tap: &'static str,
    ios: &'static str,
    android: &'static str,
    ask: &'static str,
    open: &'static str,
}

const RU: Words = Words {
    lang: "ru",
    title: "Вас пригласили в Sinhron",
    lead: "Sinhron — мессенджер со сквозным шифрованием. Пригласивший появится у вас в контактах сам.",
    step_install: "1. Установите приложение Sinhron на этот телефон.",
    step_tap: "2. Вернитесь к сообщению с приглашением и нажмите ссылку ещё раз — или кнопку ниже.",
    ios: "Установить на iPhone",
    android: "Установить на Android",
    ask: "Ссылки на установку нет — попросите пригласившего прислать её.",
    open: "Открыть в приложении",
};

const EN: Words = Words {
    lang: "en",
    title: "You're invited to Sinhron",
    lead: "Sinhron is an end-to-end encrypted messenger. The person who invited you is added to your contacts by itself.",
    step_install: "1. Install the Sinhron app on this phone.",
    step_tap: "2. Go back to the message with the invite and tap the link again — or the button below.",
    ios: "Install on iPhone",
    android: "Install on Android",
    ask: "No install link here — ask the person who invited you to send one.",
    open: "Open in the app",
};

pub async fn page(headers: HeaderMap) -> Response {
    let ru = headers
        .get(header::ACCEPT_LANGUAGE)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v.trim_start().to_ascii_lowercase().starts_with("ru"));
    let w = if ru { &RU } else { &EN };
    let ios = https_env("SINHRON_IOS_INSTALL_URL");
    let android = https_env("SINHRON_ANDROID_INSTALL_URL");
    let mut links = String::new();
    if let Some(u) = &ios {
        links.push_str(&format!(r#"<a class="b" href="{u}">{}</a>"#, w.ios));
    }
    if let Some(u) = &android {
        links.push_str(&format!(r#"<a class="b" href="{u}">{}</a>"#, w.android));
    }
    if links.is_empty() {
        links = format!("<p>{}</p>", w.ask);
    }
    let html = format!(
        r##"<!doctype html><html lang="{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>{title}</title><style>body{{font:17px/1.45 -apple-system,system-ui,sans-serif;margin:0;padding:32px 20px;background:#f7f6f2;color:#111}}main{{max-width:440px;margin:auto}}h1{{font-size:24px}}.b{{display:block;text-align:center;padding:14px;margin:12px 0;border-radius:12px;background:#2563eb;color:#fff;text-decoration:none;font-weight:600}}#open{{background:#111}}p{{color:#444}}@media(prefers-color-scheme:dark){{body{{background:#0b0e14;color:#eee}}p{{color:#aaa}}#open{{background:#eee;color:#111}}}}</style></head><body><main><h1>{title}</h1><p>{lead}</p><p>{s1}</p>{links}<p>{s2}</p><a class="b" id="open" href="#">{open}</a></main><script>{script}</script></body></html>"##,
        lang = w.lang,
        title = w.title,
        lead = w.lead,
        s1 = w.step_install,
        s2 = w.step_tap,
        open = w.open,
        script = JOIN_SCRIPT,
    );
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, "text/html; charset=utf-8"), (header::CACHE_CONTROL, "no-store")],
        html,
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;
    use sha2::{Digest, Sha256};

    #[test]
    fn the_csp_hash_matches_the_script_and_the_caddyfile() {
        let hash = format!(
            "sha256-{}",
            base64::engine::general_purpose::STANDARD.encode(Sha256::digest(JOIN_SCRIPT.as_bytes()))
        );
        assert_eq!(JOIN_SCRIPT_SHA256, hash);
        let caddy = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/Caddyfile")).unwrap();
        assert!(caddy.contains(&format!("'{hash}'")), "Caddyfile CSP for /join must allow {hash}");
    }

    #[tokio::test]
    async fn the_page_speaks_the_phones_language_and_never_needs_the_fragment() {
        let mut h = HeaderMap::new();
        h.insert(header::ACCEPT_LANGUAGE, "ru-RU,ru;q=0.9".parse().unwrap());
        let body = axum::body::to_bytes(page(h).await.into_body(), 1 << 16).await.unwrap();
        let s = String::from_utf8(body.to_vec()).unwrap();
        assert!(s.contains("Вас пригласили в Sinhron"));
        assert!(s.contains(JOIN_SCRIPT));
        // A short link's page (/i/<id>) is the same page: the script sends
        // its button to `sinhron://i/<host>/<id>#<key>`.
        assert!(JOIN_SCRIPT.contains("'sinhron://i/'+location.host+p.slice(2)+h"));
        let en = axum::body::to_bytes(page(HeaderMap::new()).await.into_body(), 1 << 16).await.unwrap();
        assert!(String::from_utf8(en.to_vec()).unwrap().contains("You're invited"));
    }

    #[tokio::test]
    async fn the_app_link_files_name_the_official_apps() {
        let a = axum::body::to_bytes(apple_app_site_association().await.into_body(), 1 << 16).await.unwrap();
        let a: serde_json::Value = serde_json::from_slice(&a).unwrap();
        assert_eq!(a["applinks"]["details"][0]["appIDs"][0], DEFAULT_APPLE_APP_ID);
        assert_eq!(a["applinks"]["details"][0]["components"][2]["/"], "/i/*", "short links open in the app");
        assert_eq!(a["webcredentials"]["apps"][0], DEFAULT_APPLE_APP_ID);
        let g = axum::body::to_bytes(assetlinks().await.into_body(), 1 << 16).await.unwrap();
        let g: serde_json::Value = serde_json::from_slice(&g).unwrap();
        assert_eq!(g[0]["target"]["package_name"], DEFAULT_ANDROID_PACKAGE);
        assert_eq!(g[0]["target"]["sha256_cert_fingerprints"][0], DEFAULT_ANDROID_CERT_SHA256);
    }
}
