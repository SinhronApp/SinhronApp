// Phones that update must keep their chats: state written by the old stack
// (openmls 0.8.1 + openmls_sqlite_storage 0.2.0, rusqlite 0.32.1 / SQLCipher)
// opens with the current one and keeps working.
//
// `tests/fixtures/mls-0.8/` was made by `gen_fixtures.rs` (kept there) on
// main 139b6a4a: Alice's and Bob's encrypted MLS stores with one shared group
// (one message each way), and Alice's encrypted app DB with a chat and two
// messages. The tests work on copies; the fixtures are never written.

use std::path::{Path, PathBuf};

use sinhron_sync::{IncomingMessage, SyncClient, SyncClientConfig};

const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const BOB: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mls-0.8")
}

/// A fresh temp dir with copies of the given fixture files.
fn copies(files: &[&str]) -> PathBuf {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("sinhron-upgrade-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    for f in files {
        std::fs::copy(fixtures().join(f), dir.join(f)).unwrap();
    }
    dir
}

fn client(phrase: &str, db: PathBuf) -> SyncClient {
    SyncClient::new(SyncClientConfig { phrase: phrase.into(), db_path: Some(db), device_seed: None })
        .expect("open the old MLS store")
}

fn app(m: IncomingMessage) -> Vec<u8> {
    match m {
        IncomingMessage::App(b) => b,
        other => panic!("expected an application message, got {other:?}"),
    }
}

#[test]
fn old_mls_groups_keep_working() {
    let dir = copies(&["alice-mls.sqlite", "bob-mls.sqlite"]);
    let group = hex::decode(std::fs::read_to_string(fixtures().join("group_id.hex")).unwrap().trim()).unwrap();
    let mut alice = client(ALICE, dir.join("alice-mls.sqlite"));
    let mut bob = client(BOB, dir.join("bob-mls.sqlite"));

    // Both load the group from the old store, in the same epoch.
    let epoch = alice.group_epoch(&group).expect("alice loads the old group");
    assert_eq!(bob.group_epoch(&group).expect("bob loads the old group"), epoch);
    assert_eq!(alice.group_member_identities(&group).unwrap().len(), 2);

    // Alice sends, Bob reads; Alice's own copy back from the server is an echo.
    let ct = alice.encrypt(&group, b"after the upgrade").unwrap();
    assert_eq!(app(bob.decrypt(&group, &ct).unwrap()), b"after the upgrade");
    assert!(matches!(alice.decrypt(&group, &ct).unwrap(), IncomingMessage::OwnCommitEcho));

    // Bob commits (new keys); his pending Commit echoed back is ignored, the
    // server's yes applies it, Alice follows.
    let commit = bob.self_update_pending(&group).unwrap();
    assert!(matches!(bob.decrypt(&group, &commit.commit_bytes).unwrap(), IncomingMessage::OwnCommitEcho));
    assert!(bob.has_pending_commit(&group).unwrap());
    let new_epoch = bob.confirm_commit(&group).unwrap();
    assert_eq!(new_epoch, epoch + 1);
    match alice.decrypt(&group, &commit.commit_bytes).unwrap() {
        IncomingMessage::Commit { new_epoch: e, added, removed } => {
            assert_eq!(e, new_epoch);
            assert!(added.is_empty() && removed.is_empty());
        }
        other => panic!("expected Bob's commit, got {other:?}"),
    }

    // Messages both ways in the new epoch.
    let ct = bob.encrypt(&group, b"new keys").unwrap();
    assert_eq!(app(alice.decrypt(&group, &ct).unwrap()), b"new keys");
    let ct = alice.encrypt(&group, b"still here").unwrap();
    assert_eq!(app(bob.decrypt(&group, &ct).unwrap()), b"still here");

    // And the state the new stack wrote survives a restart.
    drop((alice, bob));
    let mut alice = client(ALICE, dir.join("alice-mls.sqlite"));
    let mut bob = client(BOB, dir.join("bob-mls.sqlite"));
    assert_eq!(alice.group_epoch(&group).unwrap(), new_epoch);
    let ct = alice.encrypt(&group, b"after a restart").unwrap();
    assert_eq!(app(bob.decrypt(&group, &ct).unwrap()), b"after a restart");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn old_encrypted_app_db_opens() {
    let dir = copies(&["app.db"]);
    let key = sinhron_crypto::identity::account_view(ALICE).unwrap().storage_key;
    sinhron_storage::open(&dir.join("app.db"), Some(&key)).expect("open the old SQLCipher app DB");

    let chats = sinhron_storage::chats_list().unwrap();
    assert_eq!(chats.len(), 1);
    assert_eq!((chats[0].id.as_str(), chats[0].display_name.as_str()), ("chat-1", "Bob"));
    let mut bodies: Vec<_> = sinhron_storage::messages_list_for_chat("chat-1", None)
        .unwrap()
        .into_iter()
        .map(|m| (m.id, m.body, m.is_mine))
        .collect();
    bodies.sort();
    assert_eq!(
        bodies,
        vec![("m1".into(), "hello from 0.8".into(), true), ("m2".into(), "reply from 0.8".into(), false)]
    );
}
