// DEV-1 (audit 2026-11b, ADR-103): after "Disconnect" the phone holds a new
// generation of account roots (ADR-084). Messages to my own devices — the
// device sync that carries those very roots, and the transfer for a newly
// paired device — must open on devices that only know generation 0.
use sinhron_sync::envelope::{encode_device_sync, SyncEntry};
use sinhron_sync::{backup, sealed, SyncClient, SyncClientConfig};

const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const NOW: u64 = 1_800_000_000;

fn mk(secret: &str, seed: Option<[u8; 32]>) -> SyncClient {
    SyncClient::new(SyncClientConfig { phrase: secret.to_string(), db_path: None, device_seed: seed }).unwrap()
}

/// The phone + one more device of mine in the own-devices group.
fn pair(phone: &mut SyncClient, group: &[u8], seed: [u8; 32]) -> SyncClient {
    let me: [u8; 32] = hex::decode(phone.identity_pubkey_hex()).unwrap().try_into().unwrap();
    let bundle = phone.linked_bundle_for(&sinhron_sync::pairing::device_pub_of_seed(&seed)).unwrap();
    let mut other = mk(&bundle, Some(seed));
    let (p, _) = phone.invite_devices_of_pending(group, &[(me, other.create_keypackage().unwrap())]).unwrap();
    phone.confirm_commit(group).unwrap();
    other.join_via_welcome(p.welcome_bytes.as_ref().unwrap()).unwrap();
    other
}

/// What `send_own` does: MLS in the own-devices group, sealed to `own_delivery_key()`.
fn send_own(phone: &mut SyncClient, group: &[u8], plain: &[u8]) -> ([u8; 16], Vec<u8>) {
    let key = phone.own_devices_key(sealed::week_of(NOW)).unwrap();
    let ct = phone.encrypt(group, plain).unwrap();
    phone.seal_for(group, &ct, &[key.public]).unwrap().remove(0)
}

#[test]
fn the_new_roots_reach_my_other_device() {
    let mut phone = mk(ALICE, None);
    let group = phone.create_group().unwrap();
    let mut laptop = pair(&mut phone, &group, [0x43; 32]);

    let next = backup::new_generation(None);
    phone.set_rotated_roots(&[next]); // publish_sealed_keys after the disconnect
    let item = SyncEntry { key: "set:account_roots".into(), ts: 1_800_000_000_000, deleted: false, value: next.encode() };
    let (kid, env) = send_own(&mut phone, &group, &encode_device_sync(vec![item]));
    laptop.open_sealed(&kid, &env, NOW).expect("the laptop opens the message that carries the new roots");
}

#[test]
fn a_device_linked_after_the_rotation_opens_its_transfer() {
    let mut phone = mk(ALICE, None);
    let group = phone.create_group().unwrap();
    phone.set_rotated_roots(&[backup::new_generation(None)]);
    let mut tablet = pair(&mut phone, &group, [0x44; 32]);
    let (kid, env) = send_own(&mut phone, &group, b"transfer offer");
    tablet.open_sealed(&kid, &env, NOW).expect("the new tablet opens its transfer");
}

/// The server routes an envelope by its key: the generation-0 keys must be
/// published too — before the newest generation, which senders must get first.
#[test]
fn the_own_devices_key_is_published_before_the_newest_generation() {
    let mut phone = mk(ALICE, None);
    let week = sealed::week_of(NOW);
    let gen0 = phone.own_devices_key(week).unwrap().public;
    assert_eq!(phone.sealed_keys_to_publish(NOW).unwrap().len(), 2, "no rotation: the same two keys as before");
    assert_eq!(phone.sealed_keys_to_publish(NOW).unwrap()[0].public, gen0);

    phone.set_rotated_roots(&[backup::new_generation(None)]);
    let keys = phone.sealed_keys_to_publish(NOW).unwrap();
    assert_eq!(keys.len(), 4, "the server takes at most 4 keys in one PUT");
    assert_eq!(keys[0].public, gen0);
    assert_eq!(keys[3].public, phone.delivery_keys_to_publish(NOW).unwrap()[1].public, "the newest generation is stored last");
    assert_ne!(keys[2].public, gen0);
}

/// REL-01 — a device that was off for five weeks still opens what was sealed
/// to it then (the server keeps envelopes for a year); it used to lose them.
#[test]
fn an_envelope_five_weeks_old_still_opens() {
    let mut phone = mk(ALICE, None);
    let group = phone.create_group().unwrap();
    let mut laptop = pair(&mut phone, &group, [0x45; 32]);
    let (kid, env) = send_own(&mut phone, &group, b"written while the laptop was off");
    let later = NOW + 5 * sealed::WEEK_SECS;
    laptop.open_sealed(&kid, &env, later).expect("opens five weeks later");
    let mut tablet = pair(&mut phone, &group, [0x46; 32]);
    let (kid, env) = send_own(&mut phone, &group, b"older than a year");
    assert!(tablet.open_sealed(&kid, &env, NOW + 60 * sealed::WEEK_SECS).is_err(), "not for ever");
}
