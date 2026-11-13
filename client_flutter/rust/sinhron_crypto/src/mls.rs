// MLS group operations (RFC 9420). Phase 2 step 3.
//
// Sinhron uses ciphersuite #1
// (`MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519`) per spec §5.1.
//
// This module wraps openmls 0.9.2 + openmls_rust_crypto 0.6.0 +
// openmls_basic_credential 0.6.0. The high-level smoke flow
// [demo_alice_bob_flow] proves end-to-end MLS works in-process:
//
//   1. Alice + Bob each generate a Credential + Ed25519 SignatureKeyPair
//   2. Bob pre-generates a KeyPackage and shares it
//   3. Alice creates an empty MLS group
//   4. Alice adds Bob via add_members → produces (Commit, Welcome)
//   5. Bob processes Welcome → has the group state
//   6. Alice sends a message — Bob decrypts it
//   7. Bob sends a reply — Alice decrypts it
//
// Real network transport (server WS, envelope queue) is out of scope —
// here we just round-trip the serialized MlsMessageOut bytes between
// in-memory groups, which is what `sinhron_net` will do over WSS later.

use openmls::prelude::tls_codec::Deserialize;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;

/// Sinhron's default MLS ciphersuite.
pub const CIPHERSUITE: Ciphersuite =
    Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

/// Human-readable ciphersuite identifier. Used by the frb facade.
pub fn ciphersuite_name() -> &'static str {
    "MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519"
}

/// Initialise a transient MLS provider — used by older smoke tests
/// (and still exposed via frb for sanity-checking linkage).
pub fn smoke_provider_init() -> bool {
    let provider = OpenMlsRustCrypto::default();
    let _ = provider.crypto();
    true
}

// ─────────────────────────────────────────────────────────────────────
// Helpers — credential + key package generation
// ─────────────────────────────────────────────────────────────────────

fn make_credential(
    identity: &[u8],
    provider: &impl OpenMlsProvider,
) -> (CredentialWithKey, SignatureKeyPair) {
    let credential = BasicCredential::new(identity.to_vec());
    let sig_keys = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
        .expect("signature keypair generation");
    sig_keys
        .store(provider.storage())
        .expect("store signature keys");
    (
        CredentialWithKey {
            credential: credential.into(),
            signature_key: sig_keys.to_public_vec().into(),
        },
        sig_keys,
    )
}

fn make_key_package(
    credential_with_key: CredentialWithKey,
    provider: &impl OpenMlsProvider,
    signer: &SignatureKeyPair,
) -> KeyPackageBundle {
    KeyPackage::builder()
        .build(CIPHERSUITE, provider, signer, credential_with_key)
        .expect("build keypackage")
}

// ─────────────────────────────────────────────────────────────────────
// End-to-end smoke flow
// ─────────────────────────────────────────────────────────────────────

/// Full Alice↔Bob MLS round-trip. Used as proof that the openmls stack
/// works end-to-end inside `sinhron_crypto`. Returns Ok(()) on success,
/// Err with the failing step on any issue.
///
/// Steps:
///   1. Both parties create credentials + signing keypairs
///   2. Bob pre-generates a KeyPackage
///   3. Alice creates a fresh group
///   4. Alice adds Bob → (Commit, Welcome, GroupInfo)
///   5. Bob processes Welcome → joins the group
///   6. Verify both groups have the same 2 members + same epoch authenticator
///   7. Alice → "hello sinhron!" → Bob decrypts
///   8. Bob → "ack from bob" → Alice decrypts
pub fn demo_alice_bob_flow() -> Result<MlsDemoSummary, String> {
    let alice_provider = OpenMlsRustCrypto::default();
    let bob_provider = OpenMlsRustCrypto::default();

    let (alice_cred, alice_sk) = make_credential(b"Alice", &alice_provider);
    let (bob_cred, bob_sk) = make_credential(b"Bob", &bob_provider);

    // 2. Bob → keypackage
    let bob_kp = make_key_package(bob_cred.clone(), &bob_provider, &bob_sk);

    // 3. Alice → empty group
    let create_config = MlsGroupCreateConfig::builder()
        .ciphersuite(CIPHERSUITE)
        .use_ratchet_tree_extension(true)
        .build();
    let mut alice_group = MlsGroup::new(
        &alice_provider,
        &alice_sk,
        &create_config,
        alice_cred.clone(),
    )
    .map_err(|e| format!("alice create group: {e}"))?;

    // 4. Alice adds Bob
    let (_commit_out, welcome_out, _group_info) = alice_group
        .add_members(
            &alice_provider,
            &alice_sk,
            core::slice::from_ref(bob_kp.key_package()),
        )
        .map_err(|e| format!("alice add bob: {e}"))?;
    alice_group
        .merge_pending_commit(&alice_provider)
        .map_err(|e| format!("alice merge commit: {e}"))?;

    // 5. Bob processes Welcome — production API requires serialize↔deserialize
    // round-trip (no direct Out→In conversion outside test-utils feature).
    let welcome_bytes = welcome_out
        .to_bytes()
        .map_err(|e| format!("welcome serialize: {e}"))?;
    let welcome_in = MlsMessageIn::tls_deserialize_exact(welcome_bytes.as_slice())
        .map_err(|e| format!("welcome deserialize: {e}"))?;
    let welcome = match welcome_in.extract() {
        MlsMessageBodyIn::Welcome(w) => w,
        _ => return Err("expected welcome message".into()),
    };
    let join_config = MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(true)
        .build();
    let staged = StagedWelcome::new_from_welcome(
        &bob_provider,
        &join_config,
        welcome,
        None,
    )
    .map_err(|e| format!("staged welcome: {e}"))?;
    let mut bob_group = staged
        .into_group(&bob_provider)
        .map_err(|e| format!("bob join: {e}"))?;

    // 6. Sanity checks
    if alice_group.members().count() != 2 || bob_group.members().count() != 2 {
        return Err("expected 2 members on both sides".into());
    }
    if alice_group.epoch_authenticator().as_slice()
        != bob_group.epoch_authenticator().as_slice()
    {
        return Err("epoch authenticator mismatch".into());
    }

    // 7. Alice → Bob app message
    let alice_msg = b"hello sinhron!";
    let alice_out = alice_group
        .create_message(&alice_provider, &alice_sk, alice_msg)
        .map_err(|e| format!("alice create_message: {e}"))?;
    let alice_bytes = alice_out
        .to_bytes()
        .map_err(|e| format!("alice serialize: {e}"))?;
    let alice_msg_in = MlsMessageIn::tls_deserialize_exact(alice_bytes)
        .map_err(|e| format!("alice deserialize on bob side: {e}"))?;
    let alice_protocol: ProtocolMessage = alice_msg_in
        .try_into_protocol_message()
        .map_err(|e| format!("not a protocol message: {e}"))?;
    let bob_processed = bob_group
        .process_message(&bob_provider, alice_protocol)
        .map_err(|e| format!("bob process: {e}"))?;
    let bob_received = match bob_processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(app) => app.into_bytes(),
        _ => return Err("bob expected application message".into()),
    };
    if bob_received != alice_msg {
        return Err(format!(
            "alice→bob plaintext mismatch (got {} bytes)",
            bob_received.len()
        ));
    }

    // 8. Bob → Alice reply
    let bob_msg = b"ack from bob";
    let bob_out = bob_group
        .create_message(&bob_provider, &bob_sk, bob_msg)
        .map_err(|e| format!("bob create_message: {e}"))?;
    let bob_bytes = bob_out
        .to_bytes()
        .map_err(|e| format!("bob serialize: {e}"))?;
    let bob_msg_in = MlsMessageIn::tls_deserialize_exact(bob_bytes)
        .map_err(|e| format!("bob deserialize on alice side: {e}"))?;
    let bob_protocol: ProtocolMessage = bob_msg_in
        .try_into_protocol_message()
        .map_err(|e| format!("not a protocol message: {e}"))?;
    let alice_processed = alice_group
        .process_message(&alice_provider, bob_protocol)
        .map_err(|e| format!("alice process: {e}"))?;
    let alice_received = match alice_processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(app) => app.into_bytes(),
        _ => return Err("alice expected application message".into()),
    };
    if alice_received != bob_msg {
        return Err(format!(
            "bob→alice plaintext mismatch (got {} bytes)",
            alice_received.len()
        ));
    }

    Ok(MlsDemoSummary {
        ciphersuite: ciphersuite_name().to_string(),
        epoch_after_add: alice_group.epoch().as_u64(),
        members: vec!["Alice".into(), "Bob".into()],
        alice_to_bob: String::from_utf8_lossy(&bob_received).into_owned(),
        bob_to_alice: String::from_utf8_lossy(&alice_received).into_owned(),
    })
}

/// Result summary of [demo_alice_bob_flow]. Surfaced via frb so the
/// Dart side can render a Phase-2 diagnostic / debug view.
#[derive(Debug, Clone)]
pub struct MlsDemoSummary {
    pub ciphersuite: String,
    pub epoch_after_add: u64,
    pub members: Vec<String>,
    pub alice_to_bob: String,
    pub bob_to_alice: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ciphersuite_constant_matches_name() {
        let _ = CIPHERSUITE;
        assert!(ciphersuite_name().contains("X25519"));
    }

    #[test]
    fn provider_initializes() {
        assert!(smoke_provider_init());
    }

    #[test]
    fn alice_bob_full_round_trip() {
        let summary = demo_alice_bob_flow().expect("MLS smoke flow failed");
        assert_eq!(summary.members.len(), 2);
        assert_eq!(summary.alice_to_bob, "hello sinhron!");
        assert_eq!(summary.bob_to_alice, "ack from bob");
        // Epoch starts at 0 (group creation), advances to 1 after Add+Commit.
        assert_eq!(summary.epoch_after_add, 1);
    }
}
