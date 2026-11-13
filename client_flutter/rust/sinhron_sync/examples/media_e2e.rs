// End-to-end media smoke (ADR-017): Alice sends Bob an encrypted photo
// through a real sinhron-server.
//
//   • identity registration over HTTP (both)
//   • MLS group Alice+Bob (in-process Welcome — WS transport is covered
//     by full_e2e)
//   • Alice: encrypt photo + thumbnail, POST /v1/media ×2, envelope
//     (0xFF v1 protobuf) inside an MLS application message
//   • Bob: MLS decrypt → envelope decode → GET /v1/media ×2 → verify
//     sha256 + AES-GCM → bytes identical to what Alice picked
//   • the storage JSON form round-trips; a wrong key is rejected
//
// Preconditions: sinhron-server with Postgres reachable at
// SINHRON_E2E_HTTP (default http://127.0.0.1:8080).
//
// Usage:
//   SINHRON_E2E_HTTP=http://127.0.0.1:18080 cargo run --example media_e2e

use anyhow::{anyhow, bail, Context};
use sinhron_sync::envelope::{self, Decoded, MediaKind};
use sinhron_sync::media::{self, MediaDraft};
use sinhron_sync::{HttpApi, IncomingMessage, SyncClient, SyncClientConfig};

const ALICE_PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon art";
const BOB_PHRASE: &str = "legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth title";

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let base = std::env::var("SINHRON_E2E_HTTP").unwrap_or_else(|_| "http://127.0.0.1:8080".into());
    println!("→ media_e2e · server={base}");
    let http = HttpApi::new(base.clone());

    let mut alice = SyncClient::new(SyncClientConfig { phrase: ALICE_PHRASE.into(), db_path: None, device_seed: None })?;
    let mut bob = SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: None, device_seed: None })?;
    http.register_identity(alice.identity_seed_bytes()).await.context("register alice")?;
    http.register_identity(bob.identity_seed_bytes()).await.context("register bob")?;
    println!("✓ identities registered");

    let bob_kp = bob.create_keypackage()?;
    let group_id = alice.create_group()?;
    let invite = alice.invite_to_group(&group_id, &bob_kp)?;
    bob.join_via_welcome(&invite.welcome_bytes)?;
    println!("✓ MLS group {}", hex::encode(&group_id[..6]));

    // A fake "photo": 300 KB of non-trivial bytes + a 2 KB thumbnail.
    let photo: Vec<u8> = (0..300_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 24) as u8).collect();
    let thumb: Vec<u8> = photo[..2048].to_vec();

    let body = media::upload(
        &http,
        alice.identity_seed_bytes(),
        MediaDraft {
            kind: Some(MediaKind::Photo),
            data: photo.clone(),
            thumbnail: Some(thumb.clone()),
            mime_type: "image/jpeg".into(),
            blurhash: "LEHV6nWB2yk8pyo0adR*.7kCMdnj".into(),
            width: 1280,
            height: 960,
            caption: "закат над морем".into(),
            ..Default::default()
        },
    )
    .await
    .context("alice upload")?;
    println!("✓ uploaded file + thumbnail ({} B ciphertext)", body.file.as_ref().unwrap().blob_size);

    let wire = alice.encrypt(&group_id, &envelope::encode_media(body.clone()))?;
    let IncomingMessage::App(plain) = bob.decrypt(&group_id, &wire)? else {
        bail!("bob: expected an application message");
    };
    let Decoded::Media(got) = envelope::decode(&plain)? else {
        bail!("bob: expected a media envelope");
    };
    if got != body {
        bail!("bob decoded a different media body");
    }
    println!("✓ bob decrypted the MLS message → {} \"{}\"", envelope::kind_name(got.kind), got.caption);

    let file = media::fetch(&http, bob.identity_seed_bytes(), got.file.as_ref().unwrap())
        .await
        .context("bob fetch file")?;
    let t = media::fetch(&http, bob.identity_seed_bytes(), got.thumbnail.as_ref().unwrap())
        .await
        .context("bob fetch thumbnail")?;
    if file != photo || t != thumb {
        bail!("downloaded bytes differ from what alice sent");
    }
    println!("✓ bob downloaded + decrypted: photo {} B, thumbnail {} B — identical", file.len(), t.len());

    // Local-storage form round-trips and still opens the blob.
    let stored = envelope::media_from_json(&envelope::media_to_json(&got))?;
    let again = media::fetch(&http, bob.identity_seed_bytes(), stored.file.as_ref().unwrap()).await?;
    if again != photo {
        bail!("re-fetch from stored JSON differs");
    }
    println!("✓ storage JSON round-trip re-fetches the same photo");

    // A wrong key must not decrypt.
    let mut bad = got.file.clone().unwrap();
    bad.key[0] ^= 1;
    match media::fetch(&http, bob.identity_seed_bytes(), &bad).await {
        Err(media::MediaTransferError::Crypto(media::MediaError::Decrypt)) => {
            println!("✓ wrong key rejected")
        }
        other => return Err(anyhow!("wrong key: expected Decrypt error, got {other:?}")),
    }

    // Text goes through the same envelope.
    let wire = bob.encrypt(&group_id, &envelope::encode_text("красиво!"))?;
    let IncomingMessage::App(plain) = alice.decrypt(&group_id, &wire)? else {
        bail!("alice: expected an application message");
    };
    if envelope::decode(&plain)? != Decoded::Text("красиво!".into()) {
        bail!("text envelope mismatch");
    }
    println!("✓ text reply through the envelope");

    println!("✅ media_e2e passed");
    Ok(())
}
