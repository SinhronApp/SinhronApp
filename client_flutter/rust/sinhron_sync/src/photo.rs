// Photo preparation before encryption — spec §11.2, ADR-017 (stage 2).
//
// Every outgoing photo is DECODED and RE-ENCODED here, never passed
// through. That is what strips metadata: the JPEG encoder writes pixels
// only, so EXIF (GPS position, device model, timestamps, owner names),
// XMP and IPTC from the camera never leave the device. EXIF orientation
// is applied to the pixels first, so the picture still shows upright.
//
// Output:
//   • full image  — longest side ≤ MAX_DIMENSION, JPEG q82
//   • thumbnail   — longest side ≤ 320, JPEG, ≤ MAX_THUMBNAIL_BYTES
//   • BlurHash    — 4×3 components, instant placeholder (spec §8.6)
//
// Input formats: JPEG, PNG (what iOS image_picker hands over when asked
// for JPEG output). Anything else is rejected rather than forwarded.

use std::io::Cursor;

use image::codecs::jpeg::JpegEncoder;
use image::imageops::FilterType;
use image::{DynamicImage, ImageDecoder, ImageReader, RgbImage};

use crate::media::MAX_THUMBNAIL_BYTES;

/// Longest side of the sent photo. 2048 keeps full-screen detail on any
/// phone while bounding upload size (~300-800 KB).
pub const MAX_DIMENSION: u32 = 2048;
pub const THUMB_DIMENSION: u32 = 320;
const FULL_QUALITY: u8 = 82;
/// Refuse absurd inputs before allocating (decompression bombs).
const MAX_INPUT_PIXELS: u64 = 100_000_000;

#[derive(Debug, thiserror::Error)]
pub enum PhotoError {
    #[error("unsupported or corrupt image: {0}")]
    Decode(String),
    #[error("image too large")]
    TooLarge,
    #[error("encode failed: {0}")]
    Encode(String),
}

#[derive(Debug, Clone)]
pub struct PreparedPhoto {
    pub jpeg: Vec<u8>,
    pub thumbnail: Vec<u8>,
    pub blurhash: String,
    pub width: u32,
    pub height: u32,
}

pub fn prepare(input: &[u8]) -> Result<PreparedPhoto, PhotoError> {
    prepare_max(input, u32::MAX)
}

/// Longest side of a picture a website offers for a link preview: its bytes
/// are the site's, not mine, so a huge one is refused from the header.
pub const MAX_WEB_SIDE: u32 = 4096;

pub fn prepare_web(input: &[u8]) -> Result<PreparedPhoto, PhotoError> {
    prepare_max(input, MAX_WEB_SIDE)
}

fn prepare_max(input: &[u8], max_side: u32) -> Result<PreparedPhoto, PhotoError> {
    let img = decode_upright(input, max_side)?;
    let img = fit(img, MAX_DIMENSION);
    let rgb = flatten(&img);
    let (width, height) = rgb.dimensions();

    let jpeg = encode_jpeg(&rgb, FULL_QUALITY)?;
    let thumbnail = thumbnail_jpeg(&rgb)?;
    let blurhash = blurhash_of(&rgb)?;
    Ok(PreparedPhoto { jpeg, thumbnail, blurhash, width, height })
}

/// A video's poster frame (tech-debt 2.24): the frame the platform grabbed,
/// re-encoded like a photo (EXIF/GPS gone, ≤32 KB thumbnail, BlurHash).
/// Only the thumbnail travels — the frame itself is not sent.
pub struct VideoPoster {
    pub thumbnail: Vec<u8>,
    pub blurhash: String,
    pub width: u32,
    pub height: u32,
}

pub fn video_poster(frame: &[u8]) -> Result<VideoPoster, PhotoError> {
    let p = prepare(frame)?;
    Ok(VideoPoster { thumbnail: p.thumbnail, blurhash: p.blurhash, width: p.width, height: p.height })
}

/// Longest side of a photo from someone else's profile. A real one is a
/// 320 px thumbnail; a bigger "avatar" is a memory bomb, refused before any
/// pixel is decoded (security-review-2026-11 app-surface:8).
pub const MAX_AVATAR_SIDE: u32 = 1024;

/// A photo that came in someone's `profile` → my ≤32 KB JPEG of it.
pub fn prepare_avatar(input: &[u8]) -> Result<Vec<u8>, PhotoError> {
    thumbnail_jpeg(&flatten(&decode_upright(input, MAX_AVATAR_SIDE)?))
}

/// Decode and apply the EXIF orientation to the pixels; a side over
/// `max_side` is refused from the header.
fn decode_upright(input: &[u8], max_side: u32) -> Result<DynamicImage, PhotoError> {
    let reader = ImageReader::new(Cursor::new(input))
        .with_guessed_format()
        .map_err(|e| PhotoError::Decode(e.to_string()))?;
    match reader.format() {
        Some(image::ImageFormat::Jpeg) | Some(image::ImageFormat::Png) => {}
        other => return Err(PhotoError::Decode(format!("format {other:?} not accepted"))),
    }
    let mut decoder = reader.into_decoder().map_err(|e| PhotoError::Decode(e.to_string()))?;
    let (w, h) = decoder.dimensions();
    if (w as u64) * (h as u64) > MAX_INPUT_PIXELS || w.max(h) > max_side {
        return Err(PhotoError::TooLarge);
    }
    let orientation = decoder.orientation().map_err(|e| PhotoError::Decode(e.to_string()))?;
    let mut img = DynamicImage::from_decoder(decoder).map_err(|e| PhotoError::Decode(e.to_string()))?;
    img.apply_orientation(orientation);
    Ok(img)
}

fn fit(img: DynamicImage, max: u32) -> DynamicImage {
    if img.width() <= max && img.height() <= max {
        img
    } else {
        img.resize(max, max, FilterType::Lanczos3)
    }
}

/// JPEG has no alpha: composite transparent pixels onto white instead of
/// letting them turn black.
fn flatten(img: &DynamicImage) -> RgbImage {
    if !img.color().has_alpha() {
        return img.to_rgb8();
    }
    let rgba = img.to_rgba8();
    let mut out = RgbImage::new(rgba.width(), rgba.height());
    for (o, p) in out.pixels_mut().zip(rgba.pixels()) {
        let a = p[3] as u32;
        for c in 0..3 {
            o[c] = ((p[c] as u32 * a + 255 * (255 - a)) / 255) as u8;
        }
    }
    out
}

fn encode_jpeg(rgb: &RgbImage, quality: u8) -> Result<Vec<u8>, PhotoError> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality)
        .encode_image(rgb)
        .map_err(|e| PhotoError::Encode(e.to_string()))?;
    Ok(out)
}

fn thumbnail_jpeg(rgb: &RgbImage) -> Result<Vec<u8>, PhotoError> {
    let mut dim = THUMB_DIMENSION;
    loop {
        let small = DynamicImage::ImageRgb8(rgb.clone()).thumbnail(dim, dim).to_rgb8();
        for q in [70u8, 55, 40] {
            let jpeg = encode_jpeg(&small, q)?;
            if jpeg.len() <= MAX_THUMBNAIL_BYTES {
                return Ok(jpeg);
            }
        }
        if dim <= 80 {
            return Err(PhotoError::Encode("thumbnail cannot fit 32 KB".into()));
        }
        dim = dim * 3 / 4;
    }
}

fn blurhash_of(rgb: &RgbImage) -> Result<String, PhotoError> {
    // BlurHash only needs a tiny sample; 32 px keeps it fast.
    let small = DynamicImage::ImageRgb8(rgb.clone()).thumbnail(32, 32).to_rgba8();
    blurhash::encode(4, 3, small.width(), small.height(), small.as_raw())
        .map_err(|e| PhotoError::Encode(format!("blurhash: {e:?}")))
}

/// Render a BlurHash to a small PNG for an instant placeholder. Input is
/// peer-supplied — bad hashes are an error, not a panic.
pub fn blurhash_png(hash: &str, width: u32, height: u32) -> Result<Vec<u8>, PhotoError> {
    let (w, h) = (width.clamp(1, 64), height.clamp(1, 64));
    let rgba = blurhash::decode(hash, w, h, 1.0).map_err(|e| PhotoError::Decode(format!("blurhash: {e:?}")))?;
    let img = image::RgbaImage::from_raw(w, h, rgba)
        .ok_or_else(|| PhotoError::Decode("blurhash size".into()))?;
    let mut out = Vec::new();
    DynamicImage::ImageRgba8(img)
        .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
        .map_err(|e| PhotoError::Encode(e.to_string()))?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// T05 (audit 2026-11b): a website's picture with a huge side is refused
    /// from the header, before any pixel is decoded.
    #[test]
    fn web_image_with_huge_side_is_refused() {
        let mut png = Vec::new();
        image::GrayImage::new(MAX_WEB_SIDE + 1, 8)
            .write_to(&mut Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        assert!(matches!(prepare_web(&png), Err(PhotoError::TooLarge)));
        // The owner's own camera photo of that size still goes through.
        assert!(prepare(&png).is_ok());
    }

    fn gradient(w: u32, h: u32) -> RgbImage {
        RgbImage::from_fn(w, h, |x, y| image::Rgb([(x % 256) as u8, (y % 256) as u8, ((x + y) % 256) as u8]))
    }

    /// Insert an APP1/Exif segment right after SOI. `orientation` and a
    /// fake GPS tag ("GPSTEST") so we can check both are gone.
    fn with_exif(jpeg: &[u8], orientation: u16) -> Vec<u8> {
        // TIFF header (big-endian) + IFD0 with 1 entry: Orientation.
        let mut tiff = vec![b'M', b'M', 0, 42, 0, 0, 0, 8];
        tiff.extend_from_slice(&1u16.to_be_bytes()); // entry count
        tiff.extend_from_slice(&0x0112u16.to_be_bytes()); // Orientation
        tiff.extend_from_slice(&3u16.to_be_bytes()); // SHORT
        tiff.extend_from_slice(&1u32.to_be_bytes()); // count
        tiff.extend_from_slice(&orientation.to_be_bytes());
        tiff.extend_from_slice(&[0, 0]);
        tiff.extend_from_slice(&0u32.to_be_bytes()); // next IFD
        tiff.extend_from_slice(b"GPSTEST-55.7558N-37.6173E");
        let mut app1 = b"Exif\0\0".to_vec();
        app1.extend_from_slice(&tiff);
        let mut out = jpeg[..2].to_vec(); // SOI
        out.extend_from_slice(&[0xFF, 0xE1]);
        out.extend_from_slice(&((app1.len() + 2) as u16).to_be_bytes());
        out.extend_from_slice(&app1);
        out.extend_from_slice(&jpeg[2..]);
        out
    }

    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn strips_exif_and_gps_and_applies_orientation() {
        let src = encode_jpeg(&gradient(400, 200), 90).unwrap();
        let tagged = with_exif(&src, 6); // 6 = rotate 90° CW
        assert!(contains(&tagged, b"Exif") && contains(&tagged, b"GPSTEST"));

        let p = prepare(&tagged).unwrap();
        assert!(!contains(&p.jpeg, b"Exif"), "EXIF must be stripped");
        assert!(!contains(&p.jpeg, b"GPSTEST"), "GPS must be stripped");
        assert!(!contains(&p.thumbnail, b"Exif"));
        assert_eq!((p.width, p.height), (200, 400), "orientation 6 swaps sides");
    }

    #[test]
    fn a_huge_peer_avatar_is_refused_before_decoding() {
        let png = |w, h| {
            let mut out = Vec::new();
            DynamicImage::ImageLuma8(image::GrayImage::new(w, h)).write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png).unwrap();
            out
        };
        // A 12 KB PNG of 100,000,000 x 1 px passed the old pixel cap and cost ~1.9 GB.
        assert!(matches!(prepare_avatar(&png(1_000_000, 1)), Err(PhotoError::TooLarge)));
        assert!(matches!(prepare_avatar(&png(1025, 1025)), Err(PhotoError::TooLarge)));
        let ok = prepare_avatar(&png(320, 320)).unwrap();
        assert!(ok.len() <= MAX_THUMBNAIL_BYTES && image::load_from_memory(&ok).is_ok());
    }

    #[test]
    fn video_poster_is_a_clean_bounded_thumbnail() {
        let frame = with_exif(&encode_jpeg(&gradient(1920, 1080), 90).unwrap(), 1);
        let v = video_poster(&frame).unwrap();
        assert!(v.thumbnail.len() <= MAX_THUMBNAIL_BYTES);
        assert!(!contains(&v.thumbnail, b"GPSTEST"), "frame metadata must not travel");
        assert!(!v.blurhash.is_empty());
        assert_eq!(v.width * 1080, v.height * 1920, "aspect kept");
        assert!(video_poster(b"not an image").is_err());
    }

    #[test]
    fn downscales_and_bounds_thumbnail() {
        let src = encode_jpeg(&gradient(4000, 3000), 90).unwrap();
        let p = prepare(&src).unwrap();
        assert_eq!((p.width, p.height), (2048, 1536));
        assert!(p.thumbnail.len() <= MAX_THUMBNAIL_BYTES);
        let t = image::load_from_memory(&p.thumbnail).unwrap();
        assert!(t.width() <= THUMB_DIMENSION && t.height() <= THUMB_DIMENSION);
        assert!(!p.blurhash.is_empty());
        assert!(blurhash_png(&p.blurhash, 32, 24).is_ok());
    }

    #[test]
    fn small_image_is_not_upscaled() {
        let src = encode_jpeg(&gradient(300, 100), 90).unwrap();
        let p = prepare(&src).unwrap();
        assert_eq!((p.width, p.height), (300, 100));
    }

    #[test]
    fn transparent_png_becomes_white_not_black() {
        let png = {
            let img = image::RgbaImage::from_pixel(10, 10, image::Rgba([0, 0, 0, 0]));
            let mut out = Vec::new();
            DynamicImage::ImageRgba8(img)
                .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
                .unwrap();
            out
        };
        let p = prepare(&png).unwrap();
        let back = image::load_from_memory(&p.jpeg).unwrap().to_rgb8();
        assert!(back.get_pixel(5, 5)[0] > 240);
    }

    #[test]
    fn rejects_garbage_and_bad_blurhash() {
        assert!(prepare(b"not an image").is_err());
        assert!(prepare(b"GIF89a....").is_err());
        assert!(blurhash_png("!!", 10, 10).is_err());
    }
}
