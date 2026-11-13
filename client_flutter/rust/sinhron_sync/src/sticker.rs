// Sticker packs — ADR-049.
//
// A pack is one protobuf file (`PackFile`): title, author, licence and
// every sticker's bytes plus a small PNG preview. On this phone it is
// kept AES-GCM encrypted like any media blob (`sinhron_storage::stickers`,
// key in the encrypted DB); to share it, the same ciphertext form goes to
// the server as an ordinary media blob and the key travels only inside a
// message (`envelope::PackRef`) or a share code the person hands over.
//
// Formats (checked by their first bytes, not by file names):
//   • png / webp — still stickers;
//   • tgs — gzip-compressed Lottie JSON (Telegram's open format);
//   • webm — VP9 video stickers.
// Telegram's own limits are 64 KB (tgs) / 256 KB (webm) / 512 KB (still);
// ours are looser, so files people already have always fit.

use base64::{prelude::BASE64_URL_SAFE_NO_PAD, Engine};
use prost::Message;

use crate::envelope::{self, MediaBody, MediaKind, MediaRef, PackRef, Sticker};
use crate::http_api::HttpApi;
use crate::media::{self, BlobRef, MediaTransferError};

pub const MAX_PACK_STICKERS: usize = 200;
/// One sticker's file.
pub const MAX_STICKER_BYTES: usize = 1024 * 1024;
/// One sticker's preview PNG.
pub const MAX_PREVIEW_BYTES: usize = 64 * 1024;
/// Longest side a preview may claim (the app makes them 128 px).
pub const MAX_PREVIEW_SIDE: u32 = 2048;
/// A whole pack file.
pub const MAX_PACK_BYTES: usize = 64 * 1024 * 1024;
const MAX_TEXT_CHARS: usize = 64;
const MAX_LICENSE_CHARS: usize = 200;

/// Magic + version in front of the protobuf, so a wrong file is told
/// apart from a broken one.
const MAGIC: &[u8; 4] = b"SNSP";
const VERSION: u8 = 1;

/// What a share code starts with.
pub const CODE_PREFIX: &str = "sinhron-stickers:";

#[derive(Clone, PartialEq, Message)]
pub struct PackFile {
    #[prost(string, tag = "1")]
    pub id: String,
    #[prost(string, tag = "2")]
    pub title: String,
    #[prost(string, tag = "3")]
    pub author: String,
    #[prost(string, tag = "4")]
    pub license: String,
    #[prost(message, repeated, tag = "5")]
    pub stickers: Vec<PackSticker>,
}

#[derive(Clone, PartialEq, Message)]
pub struct PackSticker {
    #[prost(string, tag = "1")]
    pub id: String,
    #[prost(string, tag = "2")]
    pub emoji: String,
    #[prost(string, tag = "3")]
    pub format: String,
    #[prost(bytes = "vec", tag = "4")]
    pub data: Vec<u8>,
    /// Small still PNG for the panel (and a webm's only picture on phones
    /// that can't play it).
    #[prost(bytes = "vec", tag = "5")]
    pub preview: Vec<u8>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum StickerError {
    #[error("not a sticker pack")]
    NotAPack,
    #[error("invalid sticker pack: {0}")]
    Invalid(&'static str),
    #[error("not a sticker code")]
    BadCode,
}

/// The format of a sticker file from its first bytes.
pub fn format_of(data: &[u8]) -> Option<&'static str> {
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("png")
    } else if data.len() >= 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        Some("webp")
    } else if data.starts_with(&[0x1f, 0x8b]) {
        Some("tgs")
    } else if data.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) {
        Some("webm")
    } else {
        None
    }
}

fn short(s: &str, max: usize) -> bool {
    s.chars().count() <= max && !s.chars().any(char::is_control)
}

/// Check every bound a pack from a file or another person must meet.
pub fn validate(p: &PackFile) -> Result<(), StickerError> {
    if !envelope::valid_pack_id(&p.id) {
        return Err(StickerError::Invalid("bad id"));
    }
    if envelope::clean_profile_name(&p.title).is_none() {
        return Err(StickerError::Invalid("bad title"));
    }
    if !short(&p.author, MAX_TEXT_CHARS) || !short(&p.license, MAX_LICENSE_CHARS) {
        return Err(StickerError::Invalid("author or licence too long"));
    }
    if p.stickers.is_empty() || p.stickers.len() > MAX_PACK_STICKERS {
        return Err(StickerError::Invalid("wrong number of stickers"));
    }
    let mut ids = std::collections::HashSet::new();
    for s in &p.stickers {
        if !envelope::valid_pack_id(&s.id) || !ids.insert(s.id.as_str()) {
            return Err(StickerError::Invalid("bad sticker id"));
        }
        if !envelope::STICKER_FORMATS.contains(&s.format.as_str()) || format_of(&s.data) != Some(s.format.as_str()) {
            return Err(StickerError::Invalid("sticker format"));
        }
        if s.data.len() > MAX_STICKER_BYTES {
            return Err(StickerError::Invalid("sticker too large"));
        }
        if s.preview.len() > MAX_PREVIEW_BYTES || !(s.preview.is_empty() || format_of(&s.preview) == Some("png")) {
            return Err(StickerError::Invalid("bad preview"));
        }
        // Drawn as it is: the PNG header (width, height at bytes 16..24)
        // may not claim a giant picture (audit 2026-11b M03).
        if s.preview.get(16..24).is_some_and(|d| d.chunks(4).any(|n| u32::from_be_bytes([n[0], n[1], n[2], n[3]]) > MAX_PREVIEW_SIDE)) {
            return Err(StickerError::Invalid("preview picture too big"));
        }
        if !(s.emoji.is_empty() || (s.emoji.len() <= envelope::MAX_EMOJI_BYTES && short(&s.emoji, 16))) {
            return Err(StickerError::Invalid("bad emoji"));
        }
    }
    Ok(())
}

/// Serialize a valid pack.
pub fn encode(p: &PackFile) -> Result<Vec<u8>, StickerError> {
    validate(p)?;
    let mut out = Vec::with_capacity(5 + p.encoded_len());
    out.extend_from_slice(MAGIC);
    out.push(VERSION);
    p.encode(&mut out).expect("Vec has unbounded capacity");
    if out.len() > MAX_PACK_BYTES {
        return Err(StickerError::Invalid("pack too large"));
    }
    Ok(out)
}

/// Parse and check a pack file.
pub fn decode(bytes: &[u8]) -> Result<PackFile, StickerError> {
    if bytes.len() > MAX_PACK_BYTES || bytes.len() < 5 || &bytes[..4] != MAGIC || bytes[4] != VERSION {
        return Err(StickerError::NotAPack);
    }
    let p = PackFile::decode(&bytes[5..]).map_err(|_| StickerError::NotAPack)?;
    validate(&p)?;
    Ok(p)
}

/// True if any sticker in the pack moves.
pub fn is_animated(p: &PackFile) -> bool {
    p.stickers.iter().any(|s| envelope::sticker_is_animated(&s.format))
}

/// A share code for a pack someone uploaded: the pack's id, title, size
/// and blob reference (with its key) — whoever has the code can open it.
pub fn share_code(r: &PackRef) -> String {
    format!("{CODE_PREFIX}{}", BASE64_URL_SAFE_NO_PAD.encode(r.encode_to_vec()))
}

/// The pack reference in a share code — also when pasted inside other
/// text ("Here are my stickers: sinhron-stickers:…").
pub fn parse_share_code(text: &str) -> Result<PackRef, StickerError> {
    let at = text.find(CODE_PREFIX).ok_or(StickerError::BadCode)?;
    let code: String = text[at + CODE_PREFIX.len()..]
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_'))
        .collect();
    let bytes = BASE64_URL_SAFE_NO_PAD.decode(code).map_err(|_| StickerError::BadCode)?;
    let r = PackRef::decode(bytes.as_slice()).map_err(|_| StickerError::BadCode)?;
    let r = envelope::clean_pack_ref(r).ok_or(StickerError::BadCode)?;
    if r.file.is_none() {
        return Err(StickerError::BadCode);
    }
    Ok(r)
}

/// Encrypt + upload a pack for sharing; the reference to hand out.
pub async fn upload_pack(http: &HttpApi, identity_seed: [u8; 32], p: &PackFile) -> Result<PackRef, MediaTransferError> {
    let bytes = encode(p).map_err(|_| MediaTransferError::Invalid("bad sticker pack"))?;
    let (blob, r) = media::encrypt(&bytes)?;
    drop(bytes);
    media::keep_local(&r, &blob);
    http.upload_media_with_progress(identity_seed, blob, &|_| {}).await?;
    Ok(PackRef {
        id: p.id.clone(),
        title: p.title.clone(),
        file: Some(MediaRef::from(&r)),
        count: p.stickers.len() as u32,
    })
}

/// Download + decrypt + check a shared pack.
pub async fn fetch_pack(http: &HttpApi, identity_seed: [u8; 32], r: &PackRef) -> Result<PackFile, MediaTransferError> {
    let file = r.file.as_ref().ok_or(MediaTransferError::Invalid("built-in pack has no file"))?;
    if file.blob_size > MAX_PACK_BYTES as u64 + 64 {
        return Err(MediaTransferError::Invalid("pack too large"));
    }
    let bytes = media::fetch(http, identity_seed, file).await?;
    let p = decode(&bytes).map_err(|_| MediaTransferError::Invalid("not a sticker pack"))?;
    if p.id != r.id {
        return Err(MediaTransferError::Invalid("pack id does not match"));
    }
    Ok(p)
}

/// What the app hands over to send one sticker (plaintext; encrypted
/// here before any I/O).
#[derive(Debug, Clone, Default)]
pub struct StickerDraft {
    pub format: String,
    /// The sticker file itself.
    pub data: Vec<u8>,
    /// A still PNG of it — the message's `file` for animated stickers
    /// (what older apps show). Ignored for still stickers.
    pub still_png: Vec<u8>,
    /// ≤ 32 KB PNG — the thumbnail older apps put in the photo bubble.
    pub thumbnail_png: Vec<u8>,
    pub emoji: String,
    pub width: u32,
    pub height: u32,
    pub pack: Option<PackRef>,
}

/// Encrypt + upload a sticker; the media body to send (a Photo with
/// [`Sticker`] set). Every send uses fresh keys: the server can't tell two
/// messages carry the same sticker.
pub async fn upload_sticker(
    http: &HttpApi,
    identity_seed: [u8; 32],
    d: StickerDraft,
) -> Result<MediaBody, MediaTransferError> {
    if format_of(&d.data) != Some(d.format.as_str()) {
        return Err(MediaTransferError::Invalid("sticker format"));
    }
    if d.data.len() > MAX_STICKER_BYTES {
        return Err(MediaTransferError::Invalid("sticker too large"));
    }
    let animated = envelope::sticker_is_animated(&d.format);
    if animated && format_of(&d.still_png) != Some("png") {
        return Err(MediaTransferError::Invalid("animated sticker needs a still PNG"));
    }
    let mime = |f: &str| if f == "webp" { "image/webp" } else { "image/png" };
    let (file, file_mime, animation) = if animated {
        (d.still_png, "image/png", Some(d.data))
    } else {
        let m = mime(&d.format);
        (d.data, m, None)
    };
    let animation = match animation {
        Some(a) => {
            let (blob, r) = media::encrypt(&a)?;
            media::keep_local(&r, &blob);
            http.upload_media_with_progress(identity_seed, blob, &|_| {}).await?;
            Some(MediaRef::from(&r))
        }
        None => None,
    };
    let mut body = media::upload(
        http,
        identity_seed,
        media::MediaDraft {
            kind: Some(MediaKind::Photo),
            data: file,
            thumbnail: (!d.thumbnail_png.is_empty()).then_some(d.thumbnail_png),
            mime_type: file_mime.into(),
            width: d.width,
            height: d.height,
            ..Default::default()
        },
    )
    .await?;
    body.sticker = Some(Sticker { emoji: d.emoji, format: d.format, animation, pack: d.pack.and_then(envelope::clean_pack_ref) });
    Ok(body)
}

/// The sticker file of a sticker message: the animation, or the still
/// picture itself.
pub fn sticker_file(m: &MediaBody) -> Option<&MediaRef> {
    let s = m.sticker.as_ref()?;
    s.animation.as_ref().or(m.file.as_ref())
}

/// The blob reference of a pack ref (for local keeping).
pub fn pack_blob(r: &PackRef) -> Option<BlobRef> {
    r.file.as_ref().and_then(|f| BlobRef::try_from(f).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    // security-audit-2026-11b M03: a preview is drawn as it is, so a PNG
    // that says 16000x16000 (~1 GB decoded) is not a preview.
    #[test]
    fn m03_huge_preview_is_refused() {
        let mut p = pack();
        let mut png = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        png.extend_from_slice(&128u32.to_be_bytes());
        png.extend_from_slice(&128u32.to_be_bytes());
        p.stickers = vec![PackSticker { id: "s1".into(), emoji: String::new(), format: "webp".into(), data: WEBP.to_vec(), preview: png.clone() }];
        validate(&p).unwrap();
        png[16..20].copy_from_slice(&16000u32.to_be_bytes());
        png[20..24].copy_from_slice(&16000u32.to_be_bytes());
        p.stickers[0].preview = png;
        assert!(validate(&p).is_err(), "16000x16000 preview accepted");
    }
    use crate::envelope::{encode_media, media_from_json, media_to_json, message_kind, stored_kind, Decoded};

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nrest";
    const TGS: &[u8] = &[0x1f, 0x8b, 8, 0, 0];
    const WEBP: &[u8] = b"RIFF\x10\0\0\0WEBPVP8 ";
    const WEBM: &[u8] = &[0x1a, 0x45, 0xdf, 0xa3, 1];

    fn pack() -> PackFile {
        PackFile {
            id: "u0123abcd".into(),
            title: "Котики".into(),
            author: "Аня".into(),
            license: "CC BY 4.0".into(),
            stickers: vec![
                PackSticker { id: "s1".into(), emoji: "😀".into(), format: "tgs".into(), data: TGS.to_vec(), preview: PNG.to_vec() },
                PackSticker { id: "s2".into(), emoji: "🐱".into(), format: "webp".into(), data: WEBP.to_vec(), preview: vec![] },
                PackSticker { id: "s3".into(), emoji: String::new(), format: "webm".into(), data: WEBM.to_vec(), preview: PNG.to_vec() },
            ],
        }
    }

    #[test]
    fn formats_are_told_by_their_bytes() {
        assert_eq!(format_of(PNG), Some("png"));
        assert_eq!(format_of(WEBP), Some("webp"));
        assert_eq!(format_of(TGS), Some("tgs"));
        assert_eq!(format_of(WEBM), Some("webm"));
        assert_eq!(format_of(b"{\"v\":\"5.5\"}"), None);
        assert_eq!(format_of(b""), None);
    }

    #[test]
    fn pack_file_roundtrips_and_rejects_garbage() {
        let p = pack();
        let bytes = encode(&p).unwrap();
        assert_eq!(decode(&bytes).unwrap(), p);
        assert!(is_animated(&p));
        assert_eq!(decode(b"PK\x03\x04zip"), Err(StickerError::NotAPack));
        assert_eq!(decode(&bytes[..3]), Err(StickerError::NotAPack));
        let mut wrong_version = bytes.clone();
        wrong_version[4] = 9;
        assert_eq!(decode(&wrong_version), Err(StickerError::NotAPack));
    }

    #[test]
    fn hostile_packs_are_rejected() {
        let bad = |f: fn(&mut PackFile)| {
            let mut p = pack();
            f(&mut p);
            encode(&p).is_err()
        };
        assert!(bad(|p| p.id = "../etc".into()));
        assert!(bad(|p| p.title = "\u{202e}".into()));
        assert!(bad(|p| p.stickers.clear()));
        assert!(bad(|p| p.stickers[1].id = "s1".into()), "duplicate id");
        assert!(bad(|p| p.stickers[0].format = "webp".into()), "format must match the bytes");
        assert!(bad(|p| p.stickers[0].data = vec![0x1f; MAX_STICKER_BYTES + 1]));
        assert!(bad(|p| p.stickers[0].preview = TGS.to_vec()), "preview must be PNG");
        assert!(bad(|p| p.stickers[0].emoji = "x".repeat(40)));
        assert!(bad(|p| p.author = "a".repeat(MAX_TEXT_CHARS + 1)));
        assert!(bad(|p| {
            let one = p.stickers[1].clone();
            p.stickers = (0..=MAX_PACK_STICKERS).map(|i| PackSticker { id: format!("s{i}"), ..one.clone() }).collect();
        }));
    }

    #[test]
    fn share_codes_roundtrip_inside_text() {
        let (_, r) = crate::media::encrypt(b"pack").unwrap();
        let pr = PackRef { id: "u0123abcd".into(), title: "Котики".into(), file: Some(MediaRef::from(&r)), count: 3 };
        let code = share_code(&pr);
        assert!(code.starts_with(CODE_PREFIX));
        assert_eq!(parse_share_code(&code).unwrap(), pr);
        assert_eq!(parse_share_code(&format!("Лови стикеры: {code} — классные")).unwrap(), pr);
        assert_eq!(parse_share_code("sinhron-stickers:!!!"), Err(StickerError::BadCode));
        assert_eq!(parse_share_code("hello"), Err(StickerError::BadCode));
        // A built-in pack has nothing to download — not a code.
        let builtin = PackRef { id: "sinhron.noto_faces".into(), title: "Эмоции".into(), file: None, count: 45 };
        assert_eq!(parse_share_code(&share_code(&builtin)), Err(StickerError::BadCode));
    }

    fn sticker_media(s: Sticker) -> MediaBody {
        let (_, r) = crate::media::encrypt(b"still").unwrap();
        MediaBody {
            kind: MediaKind::Photo as i32,
            file: Some(MediaRef::from(&r)),
            mime_type: "image/png".into(),
            width: 512,
            height: 512,
            sticker: Some(s),
            ..Default::default()
        }
    }

    fn anim() -> MediaRef {
        let (_, r) = crate::media::encrypt(TGS).unwrap();
        MediaRef::from(&r)
    }

    /// ADR-049 — a sticker is a new message kind that older apps still show
    /// (as the still picture of a photo).
    #[test]
    fn sticker_message_roundtrips_and_reads_as_a_photo_to_older_apps() {
        let pack = PackRef { id: "sinhron.noto_faces".into(), title: "Эмоции".into(), file: None, count: 45 };
        let m = sticker_media(Sticker { emoji: "😀".into(), format: "tgs".into(), animation: Some(anim()), pack: Some(pack) });
        let wire = encode_media(m.clone());
        let Decoded::Media(got) = envelope::decode(&wire).unwrap() else { panic!("not media") };
        assert_eq!(got, m);
        assert_eq!(message_kind(&got), "sticker");
        assert_eq!(sticker_file(&got), got.sticker.as_ref().unwrap().animation.as_ref());
        // Local JSON keeps kind "photo" (older apps parse it in history) …
        let json = media_to_json(&got);
        assert!(json.contains("\"kind\":\"photo\""));
        assert_eq!(media_from_json(&json).unwrap(), got);
        assert_eq!(stored_kind("photo", &json), "sticker");
        assert_eq!(stored_kind("photo", &media_to_json(&sticker_media_none())), "photo");
        // … and an app without the field sees a plain photo: its still
        // picture as the file, the small PNG as the thumbnail.
        #[derive(Clone, PartialEq, prost::Message)]
        struct OlderMediaBody {
            #[prost(int32, tag = "1")]
            kind: i32,
            #[prost(message, optional, tag = "2")]
            file: Option<MediaRef>,
            #[prost(string, tag = "4")]
            mime_type: String,
        }
        let old = OlderMediaBody::decode(got.encode_to_vec().as_slice()).unwrap();
        assert_eq!(old.kind, MediaKind::Photo as i32);
        assert_eq!(old.file, got.file);
        assert_eq!(old.mime_type, "image/png");
    }

    fn sticker_media_none() -> MediaBody {
        let mut m = sticker_media(Sticker::default());
        m.sticker = None;
        m
    }

    #[test]
    fn hostile_sticker_info_is_dropped_not_the_message() {
        let cases = [
            Sticker { emoji: "😀".into(), format: "gif".into(), animation: None, pack: None },
            Sticker { emoji: "😀".into(), format: "tgs".into(), animation: None, pack: None },
            Sticker { emoji: "😀".into(), format: "png".into(), animation: Some(anim()), pack: None },
            Sticker { emoji: "abc".into(), format: "png".into(), animation: None, pack: None },
        ];
        for s in cases {
            let Decoded::Media(got) = envelope::decode(&encode_media(sticker_media(s.clone()))).unwrap() else { panic!() };
            assert_eq!(got.sticker, None, "{s:?}");
        }
        // A bad pack goes, the sticker stays.
        let bad_pack = PackRef { id: "u1".into(), title: "x".into(), file: None, count: 1 };
        let s = Sticker { emoji: "😀".into(), format: "png".into(), animation: None, pack: Some(bad_pack) };
        let Decoded::Media(got) = envelope::decode(&encode_media(sticker_media(s))).unwrap() else { panic!() };
        assert_eq!(got.sticker.unwrap().pack, None);
        // A sticker on a voice message isn't one.
        let mut v = sticker_media(Sticker { emoji: "😀".into(), format: "png".into(), animation: None, pack: None });
        v.kind = MediaKind::Voice as i32;
        let Decoded::Media(got) = envelope::decode(&encode_media(v)).unwrap() else { panic!() };
        assert_eq!(got.sticker, None);
    }
}
