// Generates the upgrade fixtures in `sinhron_sync/tests/fixtures/mls-0.8/`
// with the OLD stack (openmls 0.8.1 + openmls_sqlite_storage 0.2.0,
// rusqlite 0.32.1 / SQLCipher). Run on a checkout of the old code:
//
//   cargo run -p sinhron_sync --example gen_upgrade_fixtures -- <out_dir>
//
// It writes the state exactly the way the app does: the app DB through
// `sinhron_storage::open(path, Some(storage_key))`, and each person's MLS
// state through `SyncClient::new` with a `db_path` (SinhronProvider::open
// with the phrase's storage key — SQLCipher). Alice makes a group, adds
// Bob, they exchange a message each way.
//
// Kept next to the fixtures for reference only (not compiled on the new
// code: Cargo builds only `tests/*.rs` and `tests/*/main.rs`).

use std::path::PathBuf;

use sinhron_sync::group::IncomingMessage;
use sinhron_sync::{SyncClient, SyncClientConfig};

const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const BOB: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";

fn main() -> anyhow::Result<()> {
    let out = PathBuf::from(std::env::args().nth(1).expect("out dir"));
    std::fs::create_dir_all(&out)?;
    for f in ["alice-mls.sqlite", "bob-mls.sqlite", "app.db"] {
        let _ = std::fs::remove_file(out.join(f));
    }

    let client = |phrase: &str, file: &str| {
        SyncClient::new(SyncClientConfig {
            phrase: phrase.into(),
            db_path: Some(out.join(file)),
            device_seed: None,
        })
    };
    let group;
    {
        let mut alice = client(ALICE, "alice-mls.sqlite")?;
        let mut bob = client(BOB, "bob-mls.sqlite")?;
        group = alice.create_group()?;
        let add = alice.invite_to_group(&group, &bob.create_keypackage()?)?;
        assert_eq!(bob.join_via_welcome(&add.welcome_bytes)?, group);

        let ct = alice.encrypt(&group, b"hello from 0.8")?;
        match bob.decrypt(&group, &ct)? {
            IncomingMessage::App(b) => assert_eq!(b, b"hello from 0.8"),
            other => anyhow::bail!("bob: {other:?}"),
        }
        let ct = bob.encrypt(&group, b"reply from 0.8")?;
        match alice.decrypt(&group, &ct)? {
            IncomingMessage::App(b) => assert_eq!(b, b"reply from 0.8"),
            other => anyhow::bail!("alice: {other:?}"),
        }
        // Drop both clients: the SQLite connections close and SQLite folds
        // the WAL into the main file.
    }
    std::fs::write(out.join("group_id.hex"), hex::encode(&group))?;

    // The app DB, sealed with Alice's phrase-derived storage key.
    let key = sinhron_crypto::identity::account_view(ALICE)?.storage_key;
    let app = out.join("app.db");
    sinhron_storage::open(&app, Some(&key))?;
    sinhron_storage::chat_upsert(
        "chat-1", "Bob", false, false, false, 0, Some("reply from 0.8"), 1_700_000_100, "text", None, false, 1_700_000_000,
    )?;
    sinhron_storage::message_append("m1", "chat-1", 1_700_000_050, "hello from 0.8", "text", true, None)?;
    sinhron_storage::message_append("m2", "chat-1", 1_700_000_100, "reply from 0.8", "text", false, Some("Bob"))?;
    // The storage singleton never closes; fold its WAL into the main file
    // so `app.db` alone holds everything.
    let probe = rusqlite::Connection::open(&app)?;
    probe.execute_batch(&format!("PRAGMA key = \"x'{}'\";", hex::encode(key)))?;
    probe.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()))?;
    println!("group {} written to {}", hex::encode(&group), out.display());
    Ok(())
}
