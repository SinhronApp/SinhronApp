// Sender-side link previews — ADR-018.
//
// The SENDER fetches the page (only when the user enabled previews), so
// recipients never contact the site and never reveal their IP to it.
// The preview (title, description, small re-encoded image) travels
// inside the encrypted envelope; the image as a padded 32 KiB blob.
//
// Fetch rules (the URL comes from the user's own message, but the site
// and its redirects are untrusted):
//   • https only, default port, no userinfo
//   • host must be a DNS name — no IP literals, no localhost / *.local /
//     single-label names — so a preview can't be used to probe the LAN
//   • ≤ 3 redirects, each re-validated by the same rules
//   • 8 s total timeout, HTML capped at 512 KiB, image at 2 MiB
//   • neutral User-Agent, no cookies
// Known gap: a public DNS name resolving to a private IP isn't caught
// (no custom resolver) — documented in the threat model.

use std::time::Duration;

use reqwest::Url;

pub const MAX_HTML_BYTES: usize = 512 * 1024;
pub const MAX_IMAGE_BYTES: usize = 2 * 1024 * 1024;
pub const MAX_URL_LEN: usize = 2048;
pub const MAX_TITLE_CHARS: usize = 200;
pub const MAX_DESCRIPTION_CHARS: usize = 400;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PreviewError {
    #[error("url not allowed: {0}")]
    Url(&'static str),
    #[error("fetch failed: {0}")]
    Fetch(String),
    #[error("not an html page")]
    NotHtml,
    #[error("page has no title")]
    Empty,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PageMeta {
    pub title: String,
    pub description: String,
    pub image_url: Option<String>,
}

#[derive(Debug, Clone)]
pub struct FetchedPreview {
    /// The URL as written in the message (not the post-redirect one).
    pub url: String,
    pub title: String,
    pub description: String,
    /// Raw image bytes from the site — must go through photo::prepare.
    pub image: Option<Vec<u8>>,
}

/// First `https://…` URL in `text`, trailing punctuation trimmed.
pub fn first_https_url(text: &str) -> Option<String> {
    for raw in text.split(char::is_whitespace) {
        let Some(pos) = raw.find("https://") else { continue };
        let candidate = raw[pos..]
            .trim_end_matches(|c: char| matches!(c, '.' | ',' | '!' | '?' | ')' | ']' | '}' | '"' | '\'' | '»' | ':' | ';'));
        if candidate.len() > "https://".len() && candidate.len() <= MAX_URL_LEN {
            return Some(candidate.to_string());
        }
    }
    None
}

/// Apply the fetch rules above.
pub fn validate_url(raw: &str) -> Result<Url, PreviewError> {
    if raw.len() > MAX_URL_LEN {
        return Err(PreviewError::Url("too long"));
    }
    let url = Url::parse(raw).map_err(|_| PreviewError::Url("unparseable"))?;
    if url.scheme() != "https" {
        return Err(PreviewError::Url("https only"));
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(PreviewError::Url("credentials in url"));
    }
    if url.port().is_some() {
        return Err(PreviewError::Url("non-default port"));
    }
    match url.host() {
        Some(url::Host::Domain(d)) => {
            let d = d.trim_end_matches('.').to_ascii_lowercase();
            if !d.contains('.') || d == "localhost" || d.ends_with(".localhost") || d.ends_with(".local") {
                return Err(PreviewError::Url("local host name"));
            }
        }
        Some(_) => return Err(PreviewError::Url("ip literal")),
        None => return Err(PreviewError::Url("no host")),
    }
    Ok(url)
}

/// Pull og:/twitter: title, description, image and <title> out of HTML.
/// Small hand-rolled scanner — only <meta> and <title> are looked at.
pub fn parse_meta(html: &str, base: &Url) -> PageMeta {
    let lower = html.to_ascii_lowercase();
    let mut og_title = None;
    let mut og_desc = None;
    let mut og_image = None;
    let mut name_desc = None;
    let mut from = 0;
    while let Some(rel) = lower[from..].find("<meta") {
        let start = from + rel;
        let Some(end_rel) = lower[start..].find('>') else { break };
        let tag = &html[start..start + end_rel];
        from = start + end_rel + 1;
        let key = attr(tag, "property").or_else(|| attr(tag, "name")).map(|k| k.to_ascii_lowercase());
        let Some(content) = attr(tag, "content") else { continue };
        match key.as_deref() {
            Some("og:title") | Some("twitter:title") => {
                og_title.get_or_insert(content);
            }
            Some("og:description") | Some("twitter:description") => {
                og_desc.get_or_insert(content);
            }
            Some("description") => {
                name_desc.get_or_insert(content);
            }
            Some("og:image") | Some("og:image:url") | Some("og:image:secure_url") | Some("twitter:image") => {
                og_image.get_or_insert(content);
            }
            _ => {}
        }
    }
    let title_tag = lower.find("<title").and_then(|t| {
        let open_end = t + lower[t..].find('>')? + 1;
        let close = open_end + lower[open_end..].find("</title")?;
        Some(html[open_end..close].to_string())
    });
    PageMeta {
        title: clean(&og_title.or(title_tag).unwrap_or_default(), MAX_TITLE_CHARS),
        description: clean(&og_desc.or(name_desc).unwrap_or_default(), MAX_DESCRIPTION_CHARS),
        image_url: og_image
            .and_then(|i| base.join(decode_entities(i.trim()).as_str()).ok())
            .map(|u| u.to_string()),
    }
}

fn attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let mut search = 0;
    while let Some(rel) = lower[search..].find(name) {
        let at = search + rel;
        search = at + name.len();
        // whole attribute name, followed by '='
        let before_ok = at == 0 || !lower.as_bytes()[at - 1].is_ascii_alphanumeric() && lower.as_bytes()[at - 1] != b'-' && lower.as_bytes()[at - 1] != b':';
        let rest = lower[search..].trim_start();
        if !before_ok || !rest.starts_with('=') {
            continue;
        }
        let value_start = tag.len() - rest.len() + 1;
        let value = tag[value_start..].trim_start();
        let (quote, body) = match value.chars().next() {
            Some(q @ ('"' | '\'')) => (Some(q), &value[1..]),
            _ => (None, value),
        };
        let end = match quote {
            Some(q) => body.find(q).unwrap_or(body.len()),
            None => body.find(|c: char| c.is_whitespace() || c == '/').unwrap_or(body.len()),
        };
        return Some(body[..end].to_string());
    }
    None
}

fn decode_entities(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let tail = &rest[amp..];
        let Some(semi) = tail.as_bytes()[..tail.len().min(12)].iter().position(|&b| b == b';') else {
            out.push('&');
            rest = &tail[1..];
            continue;
        };
        let ent = &tail[1..semi];
        let decoded = match ent {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            _ if ent.starts_with("#x") || ent.starts_with("#X") => {
                u32::from_str_radix(&ent[2..], 16).ok().and_then(char::from_u32)
            }
            _ if ent.starts_with('#') => ent[1..].parse::<u32>().ok().and_then(char::from_u32),
            _ => None,
        };
        match decoded {
            Some(c) => {
                out.push(c);
                rest = &tail[semi + 1..];
            }
            None => {
                out.push('&');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Decode entities, collapse whitespace, drop control chars, cap length.
fn clean(s: &str, max_chars: usize) -> String {
    let decoded = decode_entities(s);
    let collapsed = decoded
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>();
    if collapsed.chars().count() <= max_chars {
        collapsed
    } else {
        let mut t: String = collapsed.chars().take(max_chars - 1).collect();
        t.push('…');
        t
    }
}

fn client() -> Result<reqwest::Client, PreviewError> {
    crate::http_api::with_proxy(reqwest::Client::builder())
        .timeout(Duration::from_secs(8))
        .user_agent("Mozilla/5.0")
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 3 {
                attempt.error("too many redirects")
            } else if validate_url(attempt.url().as_str()).is_err() {
                attempt.error("redirect to a disallowed url")
            } else {
                attempt.follow()
            }
        }))
        .build()
        .map_err(|e| PreviewError::Fetch(e.to_string()))
}

async fn read_capped(mut resp: reqwest::Response, cap: usize) -> Result<Vec<u8>, PreviewError> {
    let mut out = Vec::new();
    while let Some(chunk) = resp.chunk().await.map_err(|e| PreviewError::Fetch(e.to_string()))? {
        let room = cap.saturating_sub(out.len());
        out.extend_from_slice(&chunk[..chunk.len().min(room)]);
        if out.len() >= cap {
            break;
        }
    }
    Ok(out)
}

/// Fetch the page (and its preview image, best effort).
pub async fn fetch(url_in_message: &str) -> Result<FetchedPreview, PreviewError> {
    let url = validate_url(url_in_message)?;
    let http = client()?;
    let resp = http.get(url).send().await.map_err(|e| PreviewError::Fetch(e.to_string()))?;
    if !resp.status().is_success() {
        return Err(PreviewError::Fetch(format!("status {}", resp.status())));
    }
    let final_url = resp.url().clone();
    let is_html = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|ct| ct.to_ascii_lowercase().contains("text/html"))
        .unwrap_or(false);
    if !is_html {
        return Err(PreviewError::NotHtml);
    }
    let body = read_capped(resp, MAX_HTML_BYTES).await?;
    let meta = parse_meta(&String::from_utf8_lossy(&body), &final_url);
    if meta.title.is_empty() {
        return Err(PreviewError::Empty);
    }
    let image = match meta.image_url.as_deref().map(validate_url) {
        Some(Ok(img_url)) => match http.get(img_url).send().await {
            Ok(r) if r.status().is_success() => read_capped(r, MAX_IMAGE_BYTES).await.ok(),
            _ => None,
        },
        _ => None,
    };
    Ok(FetchedPreview {
        url: url_in_message.to_string(),
        title: meta.title,
        description: meta.description,
        image,
    })
}

/// Fetch the page and build the envelope preview: the image (if any)
/// is re-encoded via `photo::prepare` (EXIF dropped) and uploaded as a
/// padded 32 KiB encrypted blob. Image problems never fail the preview.
pub async fn build(
    http: &crate::http_api::HttpApi,
    identity_seed: [u8; 32],
    url_in_message: &str,
) -> Result<crate::envelope::LinkPreview, PreviewError> {
    let fetched = fetch(url_in_message).await?;
    let mut image = None;
    if let Some(raw) = fetched.image {
        if let Ok(p) = crate::photo::prepare_web(&raw) {
            if let Ok((blob, r)) =
                crate::media::encrypt_padded(&p.thumbnail, crate::media::MAX_THUMBNAIL_BYTES as u64)
            {
                crate::media::keep_local(&r, &blob); // ADR-033
                if http.upload_media(identity_seed, blob).await.is_ok() {
                    image = Some(crate::envelope::MediaRef::from(&r));
                }
            }
        }
    }
    Ok(crate::envelope::LinkPreview {
        url: fetched.url,
        title: fetched.title,
        description: fetched.description,
        image,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_ampersand_before_a_non_latin_letter_does_not_panic() {
        // The 12-byte window used to end inside a multi-byte character.
        assert_eq!(decode_entities("&aaaaaaaaaaé"), "&aaaaaaaaaaé");
        assert_eq!(decode_entities("&ёёёёёёёё &amp; я"), "&ёёёёёёёё & я");
        let base = Url::parse("https://example.org/").unwrap();
        assert_eq!(parse_meta("<title>&aaaaaaaaaaé</title>", &base).title, "&aaaaaaaaaaé");
    }

    #[test]
    fn finds_first_https_url_and_trims_punctuation() {
        assert_eq!(
            first_https_url("смотри https://example.org/a?b=1, круто!").as_deref(),
            Some("https://example.org/a?b=1")
        );
        assert_eq!(first_https_url("(https://example.org/x).").as_deref(), Some("https://example.org/x"));
        assert_eq!(first_https_url("http://plain.example.org no"), None);
        assert_eq!(first_https_url("nothing here"), None);
    }

    #[test]
    fn url_rules() {
        assert!(validate_url("https://example.org/page").is_ok());
        for bad in [
            "http://example.org",
            "https://127.0.0.1/",
            "https://[::1]/",
            "https://192.168.1.10/admin",
            "https://localhost/",
            "https://router.local/",
            "https://intranet/",
            "https://user:pw@example.org/",
            "https://example.org:8443/",
            "file:///etc/passwd",
        ] {
            assert!(validate_url(bad).is_err(), "{bad} must be rejected");
        }
    }

    #[test]
    fn parses_og_tags_entities_and_relative_image() {
        let base = Url::parse("https://news.example.org/story/1").unwrap();
        let html = r#"<html><head><title>Fallback</title>
            <meta property="og:title" content="Sinhron &amp; MLS &#8212; E2EE">
            <meta name='description' content='plain desc'>
            <meta property="og:description" content="  Multi
              line   text  ">
            <meta content="/img/cover.jpg" property="og:image">
            </head></html>"#;
        let m = parse_meta(html, &base);
        assert_eq!(m.title, "Sinhron & MLS — E2EE");
        assert_eq!(m.description, "Multi line text");
        assert_eq!(m.image_url.as_deref(), Some("https://news.example.org/img/cover.jpg"));
    }

    #[test]
    fn falls_back_to_title_tag_and_caps_length() {
        let base = Url::parse("https://example.org/").unwrap();
        let long = "x".repeat(500);
        let m = parse_meta(&format!("<TITLE>{long}</TITLE>"), &base);
        assert_eq!(m.title.chars().count(), MAX_TITLE_CHARS);
        assert!(m.title.ends_with('…'));
        assert_eq!(m.image_url, None);
        assert_eq!(parse_meta("<p>no meta</p>", &base), PageMeta::default());
    }

    #[test]
    fn data_attribute_does_not_shadow_content() {
        let base = Url::parse("https://example.org/").unwrap();
        let m = parse_meta(r#"<meta data-content="x" property="og:title" content="Real">"#, &base);
        assert_eq!(m.title, "Real");
    }
}
