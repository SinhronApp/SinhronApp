// CC8 — Phase 3 Calls end-to-end key derivation proof.
//
// Demonstrates the entire key flow from an MLS group of two members
// down to LiveKit-ready SFrame key+salt pairs:
//
//   1. Alice + Bob create real MLS group via openmls (1:1 chat).
//   2. Both call `SyncClient::group_exporter(group_id, "SFrame 1.0
//      Base Key", "", 32)` — bytes match across parties (RFC 9420 §8.5).
//   3. Both derive `sender_base_key[alice_leaf]` and `[bob_leaf]` via
//      `sinhron_call::sender_base_key`.
//   4. Both derive per-KID `sframe_key + sframe_salt` for sender=Alice,
//      epoch=0 (the current epoch after the Welcome).
//   5. Assert: Alice's "outgoing for me" == Bob's "incoming from Alice".
//
// No real WebRTC — this proves only the crypto math is correct. Stage D
// wires the same keys into `livekit_client`'s BaseKeyProvider so
// LiveKit's SFrame implementation can encrypt/decrypt media in real time.
//
// Run:
//   cd client_flutter/rust
//   cargo run -p sinhron_sync --example calls_e2e

use anyhow::Result;
use sinhron_call::{sender_base_key, sframe_epoch_secret, sframe_key_pair, CipherSuite, Kid};
use sinhron_sync::{SyncClient, SyncClientConfig};

const SFRAME_LABEL: &str = "SFrame 1.0 Base Key";
const ALICE_PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon abandon \
                            abandon abandon abandon abandon abandon art";
const BOB_PHRASE: &str = "legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth useful \
                          legal winner thank year wave sausage worth title";

fn main() -> Result<()> {
    println!("─── Phase 3 calls — SFrame key derivation E2E proof ───");
    println!();

    // ── Step 1: bootstrap two MLS clients with distinct identities. ──
    let mut alice = SyncClient::new(SyncClientConfig {
        phrase: ALICE_PHRASE.to_string(),
        db_path: None,
        device_seed: None,
    })?;
    let mut bob = SyncClient::new(SyncClientConfig {
        phrase: BOB_PHRASE.to_string(),
        db_path: None,
        device_seed: None,
    })?;
    println!("✓ Alice + Bob identities created");
    println!("    alice id = {}", &alice.identity_pubkey_hex()[..16]);
    println!("    bob   id = {}", &bob.identity_pubkey_hex()[..16]);
    println!();

    // ── Step 2: form the 1:1 MLS group. ──
    let bob_kp = bob.create_keypackage()?;
    let group_id = alice.create_group()?;
    let outcome = alice.invite_to_group(&group_id, &bob_kp)?;
    let bob_group_id = bob.join_via_welcome(&outcome.welcome_bytes)?;
    assert_eq!(group_id, bob_group_id, "group ids must match");
    println!("✓ MLS 1:1 group formed");
    println!("    group_id = {}", hex::encode(&group_id));
    println!();

    // ── Step 3: confirm epoch + leaf index for each side. ──
    let alice_leaf = alice.group_own_leaf_index(&group_id)?;
    let bob_leaf = bob.group_own_leaf_index(&group_id)?;
    let alice_epoch = alice.group_epoch(&group_id)?;
    let bob_epoch = bob.group_epoch(&group_id)?;
    assert_eq!(alice_epoch, bob_epoch, "epochs must match");
    assert_eq!(alice_leaf, 0, "creator gets leaf 0");
    assert_eq!(bob_leaf, 1, "first invitee gets leaf 1");
    println!("✓ Leaves + epoch consistent");
    println!("    alice_leaf=0 bob_leaf=1 epoch={alice_epoch}");
    println!();

    // ── Step 4: derive SFrame epoch secret on BOTH sides. ──
    //
    // Pick AES-128-GCM-SHA256 (LiveKit's default in the JS/Swift SDKs).
    // Nk=16 bytes, Nn=12 bytes.
    let cipher = CipherSuite::AesGcm128Sha256;
    let alice_export = alice.group_exporter(&group_id, SFRAME_LABEL, b"", cipher.key_len())?;
    let bob_export = bob.group_exporter(&group_id, SFRAME_LABEL, b"", cipher.key_len())?;
    assert_eq!(
        alice_export, bob_export,
        "MLS exporter output MUST match across parties"
    );
    println!("✓ MLS-Exporter outputs identical across parties");
    println!("    exporter   = {}…", &hex::encode(&alice_export)[..16]);
    println!();

    let alice_epoch_secret = sframe_epoch_secret(&alice_export, cipher)?;
    let bob_epoch_secret = sframe_epoch_secret(&bob_export, cipher)?;
    assert_eq!(alice_epoch_secret, bob_epoch_secret);
    println!("✓ sframe_epoch_secret derived (Nk={} bytes)", cipher.key_len());
    println!();

    // ── Step 5: derive per-sender base keys. ──
    //
    // Alice's outgoing media uses HER OWN base key (sender_index = 0).
    // Bob's incoming-from-Alice path uses the SAME index — that's why
    // both sides must compute base keys for ALL relevant senders.
    let alice_base_for_self = sender_base_key(&alice_epoch_secret, alice_leaf, cipher)?;
    let bob_base_for_alice = sender_base_key(&bob_epoch_secret, alice_leaf, cipher)?;
    assert_eq!(
        alice_base_for_self, bob_base_for_alice,
        "Alice's outgoing base key MUST equal Bob's incoming-from-Alice base key"
    );
    println!("✓ sender_base_key[alice_leaf] matches across parties");
    println!();

    // ── Step 6: per-KID key+salt pair. ──
    //
    // KID composes (context, sender_index, epoch). context=0 = main
    // call. The epoch field is `epoch mod 2^EPOCH_BITS`; with our E=4
    // setting, that's the low 4 bits.
    let kid = Kid::compose(0, alice_leaf, alice_epoch);
    let alice_kp_for_self = sframe_key_pair(&alice_base_for_self, kid, cipher)?;
    let bob_kp_for_alice = sframe_key_pair(&bob_base_for_alice, kid, cipher)?;
    assert_eq!(alice_kp_for_self.key, bob_kp_for_alice.key);
    assert_eq!(alice_kp_for_self.salt, bob_kp_for_alice.salt);
    println!("✓ Final SFrame key+salt match across parties (KID={:#018x})", kid.0);
    println!("    key  = {}…", &hex::encode(&alice_kp_for_self.key)[..16]);
    println!("    salt = {}", hex::encode(&alice_kp_for_self.salt));
    println!();

    // ── Step 7: derive Bob's outgoing too — to round out the picture. ──
    let bob_base_for_self = sender_base_key(&bob_epoch_secret, bob_leaf, cipher)?;
    let alice_base_for_bob = sender_base_key(&alice_epoch_secret, bob_leaf, cipher)?;
    assert_eq!(bob_base_for_self, alice_base_for_bob);

    let kid_bob = Kid::compose(0, bob_leaf, alice_epoch);
    let bob_kp_for_self = sframe_key_pair(&bob_base_for_self, kid_bob, cipher)?;
    let alice_kp_for_bob = sframe_key_pair(&alice_base_for_bob, kid_bob, cipher)?;
    assert_eq!(bob_kp_for_self.key, alice_kp_for_bob.key);
    assert_eq!(bob_kp_for_self.salt, alice_kp_for_bob.salt);
    println!("✓ Reverse direction (Bob → Alice) also matches");
    println!();

    println!("─── ALL ASSERTIONS PASSED ───");
    println!();
    println!("Both sides can now hand their respective key+salt pairs to");
    println!("livekit_client.Room(e2ee: E2EEOptions(keyProvider: ...)) and");
    println!("call setKey(participant_id, key_index, material) per spec §10.4.");
    println!();
    println!("Next: Stage D — Flutter wiring (livekit_client + Riverpod");
    println!("activeCall + LiveKit room connect + setKey loop).");

    Ok(())
}
