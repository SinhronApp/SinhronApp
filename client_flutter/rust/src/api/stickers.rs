// Stickers — ADR-049. The FFI surface for sticker packs on this phone
// (kept encrypted, see `sinhron_storage::stickers`), sharing them, and
// sending / opening sticker messages. Built-in packs ship as app assets
// and never pass through here except by id.

use base64::prelude::*;
use serde::{Deserialize, Serialize};
use sinhron_storage as storage;
use sinhron_sync as sync;

use super::simple::{net_send_encrypted, parse_reply, sync_slot, take_cancelled, ProgressGuard, SEND_CANCELLED};
use sync::envelope::{MediaRef, PackRef};
use sync::media::BlobRef;
use sync::sticker::{PackFile, PackSticker};

/// A pack re-shared after this long gets a fresh upload: the server
/// sweeps blobs nobody touched for 90 days.
const RESHARE_AFTER_SECS: i64 = 60 * 24 * 3600;

/// One sticker of a pack (plaintext, in RAM only).
pub struct StickerData {
    pub id: String,
    pub emoji: String,
    /// "webp" | "png" | "tgs" | "webm"
    pub format: String,
    pub data: Vec<u8>,
    /// Small still PNG (may be empty).
    pub preview: Vec<u8>,
}

pub struct StickerPackInfo {
    pub id: String,
    pub title: String,
    pub author: String,
    pub license: String,
    pub count: u32,
    pub animated: bool,
    /// The first sticker's preview PNG — the pack's tab icon.
    pub cover: Vec<u8>,
}

pub struct StickerPack {
    pub info: StickerPackInfo,
    pub stickers: Vec<StickerData>,
}

/// What a sticker message says about itself (no keys).
pub struct StickerMeta {
    pub emoji: String,
    pub format: String,
    pub width: u32,
    pub height: u32,
    pub pack_id: String,
    pub pack_title: String,
    pub pack_count: u32,
    /// The message carries the pack itself (a person's own pack), so it can
    /// be added from the message.
    pub pack_attached: bool,
}

// ── The list of added packs (setting `sticker_packs`, encrypted DB) ──

#[derive(Serialize, Deserialize, Clone)]
struct RefEntry {
    sha256: String,
    key: String,
    blob_size: u64,
    plain_size: u64,
}

impl RefEntry {
    fn of(r: &BlobRef) -> Self {
        Self { sha256: r.sha256_hex(), key: BASE64_STANDARD.encode(r.key), blob_size: r.blob_size, plain_size: r.plain_size }
    }
    fn blob(&self) -> Result<BlobRef, String> {
        let sha = hex::decode(&self.sha256).map_err(|e| e.to_string())?;
        let key = BASE64_STANDARD.decode(&self.key).map_err(|e| e.to_string())?;
        BlobRef::try_from(&MediaRef { sha256: sha, key, blob_size: self.blob_size, plain_size: self.plain_size })
            .map_err(|e| e.to_string())
    }
}

#[derive(Serialize, Deserialize, Clone)]
struct ShareEntry {
    code: String,
    ts: i64,
}

#[derive(Serialize, Deserialize, Clone)]
struct PackEntry {
    id: String,
    title: String,
    #[serde(default)]
    author: String,
    #[serde(default)]
    license: String,
    count: u32,
    #[serde(default)]
    animated: bool,
    #[serde(default)]
    cover: String,
    file: RefEntry,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    share: Option<ShareEntry>,
}

impl PackEntry {
    fn info(&self) -> StickerPackInfo {
        StickerPackInfo {
            id: self.id.clone(),
            title: self.title.clone(),
            author: self.author.clone(),
            license: self.license.clone(),
            count: self.count,
            animated: self.animated,
            cover: BASE64_STANDARD.decode(&self.cover).unwrap_or_default(),
        }
    }
}

fn index() -> Result<Vec<PackEntry>, String> {
    match storage::setting_get(storage::stickers::INDEX_SETTING).map_err(|e| e.to_string())? {
        Some(j) => serde_json::from_str(&j).map_err(|e| e.to_string()),
        None => Ok(Vec::new()),
    }
}

fn save_index(packs: &[PackEntry]) -> Result<(), String> {
    let j = serde_json::to_string(packs).map_err(|e| e.to_string())?;
    storage::setting_set(storage::stickers::INDEX_SETTING, &j).map_err(|e| e.to_string())
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn to_file(id: String, title: String, author: String, license: String, stickers: Vec<StickerData>) -> PackFile {
    PackFile {
        id,
        title,
        author,
        license,
        stickers: stickers
            .into_iter()
            .map(|s| PackSticker { id: s.id, emoji: s.emoji, format: s.format, data: s.data, preview: s.preview })
            .collect(),
    }
}

fn to_pack(entry_info: StickerPackInfo, p: PackFile) -> StickerPack {
    StickerPack {
        info: entry_info,
        stickers: p
            .stickers
            .into_iter()
            .map(|s| StickerData { id: s.id, emoji: s.emoji, format: s.format, data: s.data, preview: s.preview })
            .collect(),
    }
}

fn info_of(p: &PackFile) -> StickerPackInfo {
    StickerPackInfo {
        id: p.id.clone(),
        title: p.title.clone(),
        author: p.author.clone(),
        license: p.license.clone(),
        count: p.stickers.len() as u32,
        animated: sync::sticker::is_animated(p),
        cover: p.stickers.first().map(|s| s.preview.clone()).unwrap_or_default(),
    }
}

async fn seed() -> Result<[u8; 32], String> {
    let slot = sync_slot().lock().await;
    Ok(slot.as_ref().ok_or_else(|| "sync not initialised".to_string())?.identity_seed_bytes())
}

/// Add (or replace, same id) a pack: checked, encrypted, kept on this
/// phone. Built-in ids (`sinhron.…`) can't be added.
pub fn sticker_pack_save(
    id: String,
    title: String,
    author: String,
    license: String,
    stickers: Vec<StickerData>,
) -> Result<StickerPackInfo, String> {
    if sync::envelope::is_builtin_pack(&id) {
        return Err("built-in pack".into());
    }
    let mut file = to_file(id, title, author, license, stickers);
    file.title = sync::envelope::clean_profile_name(&file.title).ok_or("bad title")?;
    let bytes = sync::sticker::encode(&file).map_err(|e| e.to_string())?;
    let (blob, r) = sync::media::encrypt(&bytes).map_err(|e| e.to_string())?;
    drop(bytes);
    storage::stickers::put(&r.sha256_hex(), &blob).map_err(|e| e.to_string())?;
    let info = info_of(&file);
    let mut packs = index()?;
    let old = packs.iter().position(|p| p.id == file.id);
    let entry = PackEntry {
        id: info.id.clone(),
        title: info.title.clone(),
        author: info.author.clone(),
        license: info.license.clone(),
        count: info.count,
        animated: info.animated,
        cover: BASE64_STANDARD.encode(&info.cover),
        file: RefEntry::of(&r),
        share: None,
    };
    match old {
        Some(i) => {
            let gone = std::mem::replace(&mut packs[i], entry);
            if gone.file.sha256 != r.sha256_hex() {
                storage::stickers::remove(&gone.file.sha256);
            }
        }
        None => packs.push(entry),
    }
    save_index(&packs)?;
    Ok(info)
}

/// The packs this person added, in the order they were added.
pub fn sticker_packs_list() -> Result<Vec<StickerPackInfo>, String> {
    Ok(index()?.iter().map(PackEntry::info).collect())
}

/// Open one added pack (decrypted into RAM).
pub fn sticker_pack_load(id: String) -> Result<StickerPack, String> {
    let entry = index()?.into_iter().find(|p| p.id == id).ok_or("no such pack")?;
    let r = entry.file.blob()?;
    let blob = storage::stickers::get(&r.sha256_hex()).ok_or("pack file missing")?;
    let bytes = sync::media::decrypt(&blob, &r).map_err(|e| e.to_string())?;
    let file = sync::sticker::decode(&bytes).map_err(|e| e.to_string())?;
    Ok(to_pack(entry.info(), file))
}

pub fn sticker_pack_delete(id: String) -> Result<(), String> {
    let mut packs = index()?;
    if let Some(i) = packs.iter().position(|p| p.id == id) {
        let gone = packs.remove(i);
        save_index(&packs)?;
        storage::stickers::remove(&gone.file.sha256);
    }
    Ok(())
}

/// Move pack [id] to [to] in the list.
pub fn sticker_pack_move(id: String, to: u32) -> Result<(), String> {
    let mut packs = index()?;
    if let Some(i) = packs.iter().position(|p| p.id == id) {
        let p = packs.remove(i);
        packs.insert((to as usize).min(packs.len()), p);
        save_index(&packs)?;
    }
    Ok(())
}

/// The pack's share reference if it was shared recently — no upload.
fn shared_ref(id: &str) -> Option<PackRef> {
    let share = index().ok()?.into_iter().find(|p| p.id == id).and_then(|p| p.share)?;
    if now() - share.ts >= RESHARE_AFTER_SECS {
        return None;
    }
    sync::sticker::parse_share_code(&share.code).ok()
}

/// The pack's share reference, uploading it (encrypted) if it hasn't
/// been, or not for a long time.
async fn ensure_shared(server_base_url: &str, id: &str) -> Result<PackRef, String> {
    if let Some(r) = shared_ref(id) {
        return Ok(r);
    }
    let pack = sticker_pack_load(id.to_string())?;
    let file = to_file(pack.info.id, pack.info.title, pack.info.author, pack.info.license, pack.stickers);
    let http = sync::HttpApi::new(server_base_url.to_string());
    let r = sync::sticker::upload_pack(&http, seed().await?, &file).await.map_err(|e| e.to_string())?;
    let code = sync::sticker::share_code(&r);
    let mut packs = index()?;
    if let Some(p) = packs.iter_mut().find(|p| p.id == id) {
        p.share = Some(ShareEntry { code, ts: now() });
        save_index(&packs)?;
    }
    Ok(r)
}

/// A code another Sinhron user pastes to add this pack. Whoever has the
/// code can open the pack; the server only holds its ciphertext.
pub async fn sticker_pack_share(server_base_url: String, id: String) -> Result<String, String> {
    Ok(sync::sticker::share_code(&ensure_shared(&server_base_url, &id).await?))
}

async fn fetch_ref(server_base_url: String, r: PackRef) -> Result<StickerPack, String> {
    let http = sync::HttpApi::new(server_base_url);
    let file = sync::sticker::fetch_pack(&http, seed().await?, &r).await.map_err(|e| e.to_string())?;
    let info = info_of(&file);
    Ok(to_pack(info, file))
}

/// Open a pack from a share code (or text containing one) — to look at,
/// then add with [sticker_pack_save].
pub async fn sticker_pack_fetch(server_base_url: String, code: String) -> Result<StickerPack, String> {
    let r = sync::sticker::parse_share_code(&code).map_err(|e| e.to_string())?;
    fetch_ref(server_base_url, r).await
}

/// Open the pack a received sticker came from (when it carries one).
pub async fn sticker_pack_fetch_from_message(server_base_url: String, media_json: String) -> Result<StickerPack, String> {
    let m = sync::envelope::media_from_json(&media_json).map_err(|e| e.to_string())?;
    let r = m.sticker.and_then(|s| s.pack).filter(|p| p.file.is_some()).ok_or("no pack in this sticker")?;
    fetch_ref(server_base_url, r).await
}

/// A sticker message's emoji, format and pack.
pub fn sticker_meta(media_json: String) -> Result<StickerMeta, String> {
    let m = sync::envelope::media_from_json(&media_json).map_err(|e| e.to_string())?;
    let s = m.sticker.ok_or("not a sticker")?;
    let pack = s.pack.unwrap_or_default();
    Ok(StickerMeta {
        emoji: s.emoji,
        format: s.format,
        width: m.width,
        height: m.height,
        pack_attached: pack.file.is_some(),
        pack_id: pack.id,
        pack_title: pack.title,
        pack_count: pack.count,
    })
}

/// Download + decrypt a sticker message's file: the animation for a
/// moving sticker, else the picture (RAM only).
pub async fn sticker_fetch(server_base_url: String, media_json: String) -> Result<Vec<u8>, String> {
    let m = sync::envelope::media_from_json(&media_json).map_err(|e| e.to_string())?;
    let r = sync::sticker::sticker_file(&m).ok_or("not a sticker")?.clone();
    let http = sync::HttpApi::new(server_base_url);
    sync::media::fetch(&http, seed().await?, &r).await.map_err(|e| e.to_string())
}

/// Send a sticker: a Photo media message with the sticker info, so older
/// apps show [still_png] (animated) or the picture itself (still). For a
/// person's own pack the encrypted pack goes along (uploaded once), so the
/// receiver can add it; built-in packs travel by id with [pack_title].
/// Returns the media JSON to store with the message.
#[allow(clippy::too_many_arguments)]
pub async fn net_send_sticker(
    server_base_url: String,
    group_id_hex: String,
    message_id: String,
    format: String,
    data: Vec<u8>,
    still_png: Vec<u8>,
    thumbnail_png: Vec<u8>,
    emoji: String,
    width: u32,
    height: u32,
    pack_id: String,
    pack_title: String,
    pack_count: u32,
    reply_json: Option<String>,
    expire_secs: u32,
) -> Result<String, String> {
    let reply = parse_reply(reply_json)?;
    let _progress = ProgressGuard::start(&message_id);
    let pack = if pack_id.is_empty() {
        None
    } else if sync::envelope::is_builtin_pack(&pack_id) {
        Some(PackRef { id: pack_id, title: pack_title, file: None, count: pack_count })
    } else {
        // Owner, 2026-10-20 ("стикеры долго"): the first sticker of a pack
        // waited for the whole pack (up to 200 stickers) to upload. Only an
        // already shared pack goes along; the app shares it in the
        // background after this send, so the next stickers carry it.
        shared_ref(&pack_id)
    };
    if take_cancelled(&message_id) {
        return Err(SEND_CANCELLED.to_string());
    }
    let http = sync::HttpApi::new(server_base_url);
    let body = sync::sticker::upload_sticker(
        &http,
        seed().await?,
        sync::sticker::StickerDraft { format, data, still_png, thumbnail_png, emoji, width, height, pack },
    )
    .await
    .map_err(|e| e.to_string())?;
    let json = sync::envelope::media_to_json(&body);
    net_send_encrypted(group_id_hex, sync::envelope::encode_media_expiring(body, reply, expire_secs), message_id).await?;
    Ok(json)
}

// ── Telegram packs by link (ADR-062) ──

pub struct TelegramStickerInfo {
    pub emoji: String,
    /// "tgs" | "webm" | "webp"
    pub format: String,
    /// Telegram has a small still for it.
    pub thumb: bool,
}

pub struct TelegramPackInfo {
    pub name: String,
    pub title: String,
    pub stickers: Vec<TelegramStickerInfo>,
}

pub struct TelegramFile {
    pub index: u32,
    /// Empty when this one didn't come.
    pub data: Vec<u8>,
    /// Telegram's still (empty when not asked for or none).
    pub thumb: Vec<u8>,
}

fn tg_error(e: &sync::HttpError) -> String {
    format!("tg:{}", sync::telegram_stickers::error_code(e))
}

/// A Telegram pack's title and stickers, through our server. Errors are
/// "tg:<code>" (`sinhron_sync::telegram_stickers::error_code`).
pub async fn telegram_pack_info(server_base_url: String, name: String) -> Result<TelegramPackInfo, String> {
    let http = sync::HttpApi::new(server_base_url);
    let p = sync::telegram_stickers::fetch_pack(&http, seed().await?, &name).await.map_err(|e| tg_error(&e))?;
    Ok(TelegramPackInfo {
        name: p.name,
        title: p.title,
        stickers: p
            .stickers
            .into_iter()
            .map(|s| TelegramStickerInfo { emoji: s.emoji, format: s.format, thumb: s.thumb })
            .collect(),
    })
}

/// Files of stickers [indices] at once, with Telegram's still for those in
/// [thumb_for]. One that fails comes back empty; when all fail, the first
/// error ("tg:<code>").
pub async fn telegram_sticker_files(
    server_base_url: String,
    name: String,
    indices: Vec<u32>,
    thumb_for: Vec<u32>,
) -> Result<Vec<TelegramFile>, String> {
    let http = sync::HttpApi::new(server_base_url);
    let seed = seed().await?;
    let one = |i: u32| {
        let (http, name, thumb) = (&http, &name, thumb_for.contains(&i));
        async move {
            let data = sync::telegram_stickers::fetch_file(http, seed, name, i, false).await;
            let still = match (&data, thumb) {
                (Ok(_), true) => sync::telegram_stickers::fetch_file(http, seed, name, i, true).await.unwrap_or_default(),
                _ => Vec::new(),
            };
            (i, data, still)
        }
    };
    let got = futures_util::future::join_all(indices.iter().copied().map(one)).await;
    if let Some(Err(e)) = got.first().map(|g| &g.1).filter(|_| got.iter().all(|g| g.1.is_err())) {
        return Err(tg_error(e));
    }
    Ok(got
        .into_iter()
        .map(|(index, data, thumb)| TelegramFile { index, data: data.unwrap_or_default(), thumb })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\nrest";
    const TGS: &[u8] = &[0x1f, 0x8b, 8, 0, 0];

    fn sticker(id: &str) -> StickerData {
        StickerData { id: id.into(), emoji: "😀".into(), format: "tgs".into(), data: TGS.to_vec(), preview: PNG.to_vec() }
    }

    /// ADR-049 — an added pack is kept encrypted and opens again; saving
    /// the same id replaces it; deleting removes the file.
    #[test]
    fn packs_are_kept_encrypted_listed_and_removed() {
        let path = std::env::temp_dir().join(format!("sinhron_core_stickers_{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        storage::open(&path, None).unwrap();
        assert!(sticker_pack_save("sinhron.noto_faces".into(), "x".into(), String::new(), String::new(), vec![sticker("a")]).is_err());
        let info = sticker_pack_save("u01".into(), " Котики ".into(), "Аня".into(), "CC0".into(), vec![sticker("a"), sticker("b")]).unwrap();
        assert_eq!((info.title.as_str(), info.count, info.animated), ("Котики", 2, true));
        assert_eq!(info.cover, PNG);
        sticker_pack_save("u02".into(), "Второй".into(), String::new(), String::new(), vec![sticker("a")]).unwrap();
        let entry = index().unwrap().into_iter().find(|p| p.id == "u01").unwrap();
        let blob = storage::stickers::get(&entry.file.sha256).unwrap();
        assert!(sync::sticker::decode(&blob).is_err(), "kept as ciphertext, not a readable pack");
        assert_eq!(sticker_pack_load("u01".into()).unwrap().stickers.len(), 2);
        // Replace: one file, the old one gone.
        sticker_pack_save("u01".into(), "Котики".into(), String::new(), String::new(), vec![sticker("c")]).unwrap();
        assert!(storage::stickers::get(&entry.file.sha256).is_none());
        assert_eq!(sticker_pack_load("u01".into()).unwrap().stickers[0].id, "c");
        sticker_pack_move("u02".into(), 0).unwrap();
        assert_eq!(sticker_packs_list().unwrap().iter().map(|p| p.id.clone()).collect::<Vec<_>>(), ["u02", "u01"]);
        sticker_pack_delete("u01".into()).unwrap();
        assert!(sticker_pack_load("u01".into()).is_err());
        assert_eq!(sticker_packs_list().unwrap().len(), 1);
        assert_eq!(sync::sticker::format_of(TGS), Some("tgs"));
    }
}
