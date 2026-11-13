// SyncClient — top-level handle for MLS-encrypted chat.
//
// Composes:
//   • `MlsIdentity` (this user's MLS credential)
//   • `SinhronProvider` (rust-crypto + SQLite-backed StorageProvider)
//   • `HashMap<group_id, GroupHandle>` (live group state — cache;
//     persisted under the hood via the storage provider, so this map
//     is just a hot-path optimization to avoid touching SQLite on every
//     encrypt/decrypt)
//
// WU C6: persistence. The `db_path` config knob points at an on-disk
// SQLite file (typically under iOS Documents/ via `path_provider`).
// In-memory mode (the test default) still works for examples and unit
// tests — same code path, different connection string.

use std::collections::HashMap;
use std::path::PathBuf;

use openmls::prelude::*;
use tls_codec::Serialize;
use tracing::{info, warn};

use crate::group::{GroupError, GroupHandle, IncomingMessage};
use crate::identity::{IdentityError, MlsIdentity, CIPHERSUITE};
use crate::provider::{ProviderError, SinhronProvider};

#[derive(Debug, Clone, Default)]
pub struct SyncClientConfig {
    /// User's 24-word BIP-39 phrase — used to derive both the WS auth
    /// seed (handled by sinhron_net) and the MLS credential here.
    pub phrase: String,

    /// Optional path to the persistent MLS-state SQLite file. When
    /// `None`, the provider runs in-memory and group state vanishes on
    /// `Drop` — fine for unit tests and `examples/`, **never** for
    /// production. The Flutter app passes
    /// `{ApplicationDocumentsDir}/sinhron/mls-state.sqlite`.
    pub db_path: Option<PathBuf>,

    /// ADR-025 — this device's own MLS signing key seed. `None`: the
    /// first/legacy device, whose MLS leaf is signed by the identity key.
    /// `Some`: a linked device with a certificate from the identity key.
    pub device_seed: Option<[u8; 32]>,
}

pub struct SyncClient {
    provider: SinhronProvider,
    identity: MlsIdentity,
    groups: HashMap<Vec<u8>, GroupHandle>,
    /// ADR-023 — root of this device's weekly delivery keys (published).
    delivery_root: [u8; 32],
    /// ADR-084 — the roots before a disconnect (envelopes a sender sealed to
    /// an older key still open) and the phrase's own (generation 0, as in
    /// new bundles).
    older_roots: Vec<[u8; 32]>,
    base_delivery_root: [u8; 32],
    /// Tech-debt 2.2 — version of the sealed-sender access key (rotation).
    access_version: u32,
    /// Root of the access keys (from the account; ADR-027 bundles carry it).
    access_root: [u8; 32],
    /// The identity's X25519 public key (fingerprint; ADR-027 bundles).
    x25519_public: [u8; 32],
    /// ADR-073 — the chat backup key, passed on in the bundles made here.
    cloud_key: Option<[u8; 32]>,
    /// ADR-074 — who (person) sent the Welcome each group was joined by
    /// in this run.
    welcome_senders: HashMap<Vec<u8>, [u8; 32]>,
}

impl SyncClient {
    /// Build a fresh SyncClient. Phrase stays on the heap for the
    /// duration of this call only; never written to disk. When
    /// `config.db_path` is set, MLS state persists there across
    /// process restarts; otherwise the provider is in-memory.
    ///
    /// **T1.1 — SQLCipher**: the phrase-derived `storage_key`
    /// (HKDF info `sinhron-storage-key/v1`) is passed to
    /// `SinhronProvider::open` so the on-disk SQLite file is
    /// encrypted at rest. In-memory provider (no db_path) skips
    /// encryption — irrelevant for ephemeral state.
    pub fn new(config: SyncClientConfig) -> Result<Self, SyncError> {
        let derive_err = |e: sinhron_crypto::KeyError| SyncError::Identity(IdentityError::Derive(e.to_string()));
        // A phrase / device key (ADR-021), or — ADR-027 — a linked-device
        // bundle that holds no identity key.
        let account = sinhron_crypto::identity::account_view(&config.phrase).map_err(derive_err)?;
        let provider = match config.db_path.as_deref() {
            Some(path) => SinhronProvider::open(path, Some(&account.storage_key))?,
            None => SinhronProvider::in_memory()?,
        };
        let identity = if config.phrase.trim().starts_with(sinhron_crypto::identity::LINKED_PREFIX) {
            let bundle = sinhron_crypto::identity::LinkedBundle::decode(&config.phrase).map_err(derive_err)?;
            let seed = config
                .device_seed
                .ok_or_else(|| SyncError::Identity(IdentityError::Derive("a linked device needs its device key".into())))?;
            MlsIdentity::from_linked_bundle(&provider, &bundle, seed)?
        } else {
            match config.device_seed {
                None => MlsIdentity::from_phrase(&provider, &config.phrase)?,
                Some(seed) => MlsIdentity::for_linked_device(&provider, &config.phrase, seed)?,
            }
        };
        Ok(Self {
            provider,
            identity,
            groups: HashMap::new(),
            delivery_root: account.delivery_root,
            older_roots: Vec::new(),
            base_delivery_root: account.delivery_root,
            access_root: account.access_root,
            x25519_public: account.x25519_public,
            cloud_key: account.cloud_key,
            welcome_senders: HashMap::new(),
            access_version: 0,
        })
    }

    // ── ADR-023 — sealed sender ─────────────────────────────────────

    /// ADR-084 — the account's rotated roots, newest first (none: generation
    /// 0, the phrase's). The newest one's keys are published; envelopes to
    /// any of them, or to the phrase's, still open.
    pub fn set_rotated_roots(&mut self, newest_first: &[sinhron_crypto::identity::RootsGen]) {
        let mut all: Vec<[u8; 32]> = newest_first.iter().map(|g| g.delivery_root()).collect();
        all.push(self.base_delivery_root);
        all.dedup();
        self.delivery_root = all.remove(0);
        self.older_roots = all;
    }

    fn all_delivery_roots(&self) -> impl Iterator<Item = &[u8; 32]> {
        std::iter::once(&self.delivery_root).chain(self.older_roots.iter())
    }

    /// This device's delivery keys to publish: this week's and next
    /// week's (so senders with a slightly fast clock still find one).
    pub fn delivery_keys_to_publish(&self, now_unix: u64) -> Result<Vec<crate::sealed::DeliveryKey>, SyncError> {
        let w = crate::sealed::week_of(now_unix);
        [w, w + 1]
            .into_iter()
            .map(|week| crate::sealed::delivery_key(self.provider.crypto(), &self.delivery_root, week))
            .collect::<Result<_, _>>()
            .map_err(|e| SyncError::Sealed(e.to_string()))
    }

    /// DEV-1 (ADR-103) — the key for messages to MY OWN devices (device sync,
    /// transfer, history for a new device): generation 0 of [week]. Every
    /// device of mine holds it for ever — also one that hasn't heard of a newer
    /// generation yet, and one just paired by QR. The content is MLS of the
    /// own-devices group, which a disconnected device has already left.
    pub fn own_devices_key(&self, week: u32) -> Result<crate::sealed::DeliveryKey, SyncError> {
        crate::sealed::delivery_key(self.provider.crypto(), &self.base_delivery_root, week)
            .map_err(|e| SyncError::Sealed(e.to_string()))
    }

    /// What `PUT /v1/sealed-keys` gets. After a rotation the generation-0
    /// keys go along (the server routes an envelope by its key, so
    /// [own_devices_key] must be known to it) — FIRST, so the newest
    /// generation is stored last and listed first for senders (ADR-084).
    pub fn sealed_keys_to_publish(&self, now_unix: u64) -> Result<Vec<crate::sealed::DeliveryKey>, SyncError> {
        let mut keys = Vec::new();
        if self.delivery_root != self.base_delivery_root {
            let w = crate::sealed::week_of(now_unix);
            keys.push(self.own_devices_key(w)?);
            keys.push(self.own_devices_key(w + 1)?);
        }
        keys.extend(self.delivery_keys_to_publish(now_unix)?);
        Ok(keys)
    }

    /// ADR-056 — a notification preview of a message for one recipient
    /// delivery key, signed by this device.
    pub fn push_preview_for(
        &self,
        recipient_public: &[u8],
        group_id: &[u8],
        kind: &str,
        text: &str,
        now_unix: u64,
    ) -> Result<Vec<u8>, SyncError> {
        let cert = self.device_certificate();
        crate::push_preview::seal(
            self.provider.crypto(),
            recipient_public,
            &self.identity.device_seed,
            cert.as_deref(),
            now_unix,
            group_id,
            kind,
            text,
        )
        .map_err(|e| SyncError::Sealed(e.to_string()))
    }

    /// ADR-090 (calls:5) — this device's signature on a call invite it sends.
    pub fn call_invite_proof(&self, call_id: &str, group_id: &[u8], video: bool, now_unix: u64) -> Vec<u8> {
        let cert = self.device_certificate();
        crate::call_invite::sign(&self.identity.device_seed, cert.as_deref(), call_id, group_id, video, now_unix)
    }

    /// ADR-056 — private delivery keys the notification extension needs to
    /// open previews: the weeks a sender may still seal to (two back,
    /// this one) and the next two (the app may not run for a while).
    pub fn push_preview_secrets(&self, now_unix: u64) -> Result<Vec<Vec<u8>>, SyncError> {
        let w = crate::sealed::week_of(now_unix);
        self.all_delivery_roots()
            .flat_map(|root| (w.saturating_sub(crate::sealed::WEEKS_ACCEPTED_BACK)..=w + 2).map(move |week| (root, week)))
            .map(|(root, week)| {
                crate::sealed::delivery_key(self.provider.crypto(), root, week)
                    .map(|k| k.secret_bytes().to_vec())
                    .map_err(|e| SyncError::Sealed(e.to_string()))
            })
            .collect()
    }

    /// Wrap an MLS message for each recipient delivery key (public key
    /// bytes). Returns `(key_id, envelope)` pairs for `Submit`.
    pub fn seal_for(
        &self,
        group_id: &[u8],
        mls_message: &[u8],
        recipient_keys: &[Vec<u8>],
    ) -> Result<Vec<([u8; 16], Vec<u8>)>, SyncError> {
        recipient_keys
            .iter()
            .map(|pk| {
                crate::sealed::seal(self.provider.crypto(), pk, group_id, mls_message)
                    .map(|env| (crate::sealed::key_id_of(pk), env))
                    .map_err(|e| SyncError::Sealed(e.to_string()))
            })
            .collect()
    }

    /// Open a sealed envelope addressed to `key_id` and decrypt the MLS
    /// message inside it — decapsulation, MLS processing and the sender's
    /// authenticated identity in one function, no intermediate state
    /// leaving it (spec §6.5). Accepts this week's key and a year of earlier
    /// ones (REL-01: a device that was off for weeks).
    pub fn open_sealed(
        &mut self,
        key_id: &[u8],
        envelope: &[u8],
        now_unix: u64,
    ) -> Result<(Vec<u8>, IncomingMessage, Option<Vec<u8>>), SyncError> {
        let w = crate::sealed::week_of(now_unix);
        let mut opened = None;
        'roots: for root in self.all_delivery_roots() {
            for week in (w.saturating_sub(crate::sealed::WEEKS_OPENED_BACK)..=w + 1).rev() {
                let key = crate::sealed::delivery_key(self.provider.crypto(), root, week)
                    .map_err(|e| SyncError::Sealed(e.to_string()))?;
                if key.key_id.as_slice() != key_id {
                    continue;
                }
                opened = Some(
                    crate::sealed::open(self.provider.crypto(), &key, envelope).map_err(|e| SyncError::Sealed(e.to_string()))?,
                );
                break 'roots;
            }
        }
        let (group_id, mls) = opened.ok_or_else(|| SyncError::Sealed("no current delivery key matches".into()))?;
        // ADR-092 — a Commit only by the ordered path (WS Submit): one
        // sealed past the server would move us on behind its back.
        if crate::group::commit_epoch(&mls).is_some() {
            warn!(group_id = %hex::encode(&group_id), "refused a Commit that came sealed");
            return Ok((group_id, IncomingMessage::Other, None));
        }
        let (msg, sender) = self.with_group_mut(&group_id, |provider, _identity, handle| {
            handle.process_incoming_with_sender(provider, &mls).map_err(Into::into)
        })?;
        Ok((group_id, msg, sender))
    }

    /// Generate a fresh KeyPackage for this device. Returns the
    /// TLS-encoded bytes ready for `POST /v1/keypackages` upload to
    /// the server.
    pub fn create_keypackage(&self) -> Result<Vec<u8>, SyncError> {
        let kp = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.provider,
                &self.identity.signer,
                self.identity.credential.clone(),
            )
            .map_err(|e| SyncError::KeyPackage(format!("{e:?}")))?;
        kp.key_package()
            .tls_serialize_detached()
            .map_err(|e| SyncError::KeyPackage(e.to_string()))
    }

    /// Create a new group with this user as the only member. Returns
    /// the opaque group_id; subsequent calls reference the group by
    /// these bytes.
    pub fn create_group(&mut self) -> Result<Vec<u8>, SyncError> {
        let handle = GroupHandle::create(&self.provider, &self.identity)?;
        let id = handle.group_id.clone();
        self.groups.insert(id.clone(), handle);
        Ok(id)
    }

    /// Add a member to an existing group. Returns the (commit, welcome)
    /// byte pair — caller is responsible for sending the commit to
    /// existing members and the welcome to the new member.
    pub fn invite_to_group(
        &mut self,
        group_id: &[u8],
        new_member_kp_bytes: &[u8],
    ) -> Result<crate::group::AddMemberOutcome, SyncError> {
        let kp_in = parse_keypackage_in(new_member_kp_bytes)?;
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.add_member(provider, identity, kp_in).map_err(Into::into)
        })
    }

    /// ADR-025 — add several devices (KeyPackages) in one Commit.
    pub fn invite_devices(
        &mut self,
        group_id: &[u8],
        key_packages: &[Vec<u8>],
    ) -> Result<crate::group::AddMemberOutcome, SyncError> {
        let kps = key_packages.iter().map(|b| parse_keypackage_in(b)).collect::<Result<Vec<_>, _>>()?;
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.add_members(provider, identity, kps).map_err(Into::into)
        })
    }

    /// ADR-025 — [`invite_devices`] with the Commit pending until the
    /// server orders it ([`confirm_commit`] / [`discard_commit`]).
    pub fn invite_devices_pending(
        &mut self,
        group_id: &[u8],
        key_packages: &[Vec<u8>],
    ) -> Result<crate::group::PendingCommit, SyncError> {
        let kps = key_packages.iter().map(|b| parse_keypackage_in(b)).collect::<Result<Vec<_>, _>>()?;
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.add_members_pending(provider, identity, kps).map_err(Into::into)
        })
    }

    /// ADR-025 / ADR-074 — add devices of people already in the group
    /// (`(person, key package)`; each checked to be that person's — see
    /// [`GroupHandle::add_devices_of_pending`]). Commit pending; returns it
    /// with who got which new leaf.
    pub fn invite_devices_of_pending(
        &mut self,
        group_id: &[u8],
        packages: &[([u8; 32], Vec<u8>)],
    ) -> Result<(crate::group::PendingCommit, Vec<([u8; 32], Vec<u8>)>), SyncError> {
        let kps = packages
            .iter()
            .map(|(who, b)| parse_keypackage_in(b).map(|kp| (*who, kp)))
            .collect::<Result<Vec<_>, _>>()?;
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.add_devices_of_pending(provider, identity, kps).map_err(Into::into)
        })
    }

    /// ADR-075 — this chat's card (its GroupInfo) for the server: (epoch, bytes).
    pub fn group_card(&mut self, group_id: &[u8]) -> Result<(u64, Vec<u8>), SyncError> {
        self.with_group_mut(group_id, |provider, identity, handle| handle.export_card(provider, identity).map_err(Into::into))
    }

    /// ADR-075 — join a chat I was in by its card (external commit),
    /// applied here at once; [`forget_group`] if the server refuses the
    /// Commit. Returns the group id and the Commit (its `epoch` = the card's).
    /// ADR-100 — only a card of `group_id` that another device of mine signed.
    pub fn join_by_card(&mut self, group_id: &[u8], card: &[u8]) -> Result<(Vec<u8>, crate::group::PendingCommit), SyncError> {
        let me: [u8; 32] = hex::decode(self.identity_pubkey_hex())
            .ok()
            .and_then(|v| v.try_into().ok())
            .ok_or_else(|| SyncError::Identity(IdentityError::Derive("identity".into())))?;
        let (handle, pending) = GroupHandle::join_by_card(&self.provider, &self.identity, &me, group_id, card)?;
        let gid = handle.group_id.clone();
        self.groups.insert(gid.clone(), handle);
        Ok((gid, pending))
    }

    /// ADR-075 — drop a group this device holds (a refused external join).
    pub fn forget_group(&mut self, group_id: &[u8]) {
        if let Some(mut h) = self.groups.remove(group_id) {
            h.forget(&self.provider);
        } else if let Ok(Some(mut h)) = GroupHandle::try_load(&self.provider, group_id) {
            h.forget(&self.provider);
        }
    }

    /// ADR-075 — remove several devices' leaves in one pending Commit.
    pub fn remove_devices_pending(&mut self, group_id: &[u8], device_keys: &[Vec<u8>]) -> Result<crate::group::PendingCommit, SyncError> {
        let keys = device_keys.to_vec();
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.remove_devices_pending(provider, identity, &keys).map_err(Into::into)
        })
    }

    /// ADR-025 — [`remove_device`] with the Commit pending.
    pub fn remove_device_pending(&mut self, group_id: &[u8], device_key: &[u8]) -> Result<crate::group::PendingCommit, SyncError> {
        let key = device_key.to_vec();
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.remove_device_pending(provider, identity, &key).map_err(Into::into)
        })
    }

    /// ADR-035 — remove these people (all their devices) from a group,
    /// Commit pending until the server orders it.
    pub fn remove_people_pending(
        &mut self,
        group_id: &[u8],
        identities: &[[u8; 32]],
    ) -> Result<crate::group::PendingCommit, SyncError> {
        let ids = identities.to_vec();
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.remove_identities_pending(provider, identity, &ids).map_err(Into::into)
        })
    }

    /// ADR-035 — am I still in this group?
    pub fn group_is_active(&mut self, group_id: &[u8]) -> Result<bool, SyncError> {
        self.with_group_mut(group_id, |_p, _i, handle| Ok(handle.is_active()))
    }

    /// ADR-088 — the group's admin, read from the state all members share.
    pub fn group_admin(&mut self, group_id: &[u8]) -> Result<Option<[u8; 32]>, SyncError> {
        self.with_group_mut(group_id, |_p, _i, handle| Ok(handle.admin_identity()))
    }

    /// ADR-074 — added back by someone else: the Welcome this device joined
    /// [group_id] by came from another person, and another device of mine
    /// is already in it (the lost phone's leaf) — I was a member, not a
    /// stranger's new request. A Welcome from my own device says nothing
    /// (a request there stays a request until my devices sync it).
    pub fn added_back_by_someone_else(&mut self, group_id: &[u8]) -> Result<bool, SyncError> {
        let me: [u8; 32] = hex::decode(self.identity_pubkey_hex()).ok().and_then(|v| v.try_into().ok()).unwrap_or([0u8; 32]);
        let Some(sender) = self.welcome_senders.get(group_id).copied() else { return Ok(false) };
        if sender == me {
            return Ok(false);
        }
        Ok(self.group_device_keys(group_id, &me)?.len() > 1)
    }

    /// ADR-025 — device keys present in a group for `identity_hex`.
    pub fn group_device_keys(&mut self, group_id: &[u8], identity: &[u8; 32]) -> Result<Vec<Vec<u8>>, SyncError> {
        let identity = *identity;
        self.with_group_mut(group_id, |_p, _i, handle| Ok(handle.device_keys_of(&identity)))
    }

    /// ADR-025 — revoke one device's leaf from a group.
    pub fn remove_device(&mut self, group_id: &[u8], device_key: &[u8]) -> Result<Vec<u8>, SyncError> {
        let key = device_key.to_vec();
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.remove_device(provider, identity, &key).map_err(Into::into)
        })
    }

    /// This device's own MLS signature key (= `device_pk` on the server).
    pub fn device_public_key(&self) -> Vec<u8> {
        self.identity.credential.signature_key.as_slice().to_vec()
    }

    /// Tech-debt 2.3 — [`invite_to_group`] with the Commit held pending
    /// until the server orders it (see [`GroupHandle::add_member_pending`]).
    pub fn invite_to_group_pending(
        &mut self,
        group_id: &[u8],
        new_member_kp_bytes: &[u8],
    ) -> Result<crate::group::PendingCommit, SyncError> {
        let kp_in = parse_keypackage_in(new_member_kp_bytes)?;
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle.add_member_pending(provider, identity, kp_in).map_err(Into::into)
        })
    }

    /// ADR-092 — an empty Commit of ours (new keys only), pending.
    pub fn self_update_pending(&mut self, group_id: &[u8]) -> Result<crate::group::PendingCommit, SyncError> {
        self.with_group_mut(group_id, |provider, identity, handle| handle.self_update_pending(provider, identity).map_err(Into::into))
    }

    /// Is a Commit of ours waiting for the server's verdict in this group?
    /// (Sending waits for it — ADR-025 device sync.)
    /// ADR-101 — who our pending Commit adds: (person, device key).
    pub fn pending_adds(&mut self, group_id: &[u8]) -> Result<Vec<([u8; 32], Vec<u8>)>, SyncError> {
        self.with_group_mut(group_id, |_p, _i, handle| Ok(handle.pending_adds()))
    }

    pub fn has_pending_commit(&mut self, group_id: &[u8]) -> Result<bool, SyncError> {
        self.with_group_mut(group_id, |_p, _i, handle| Ok(handle.has_pending_commit()))
    }

    /// Server accepted the pending Commit → apply it; returns the new epoch.
    pub fn confirm_commit(&mut self, group_id: &[u8]) -> Result<u64, SyncError> {
        self.with_group_mut(group_id, |provider, _identity, handle| {
            handle.confirm_pending_commit(provider).map_err(Into::into)
        })
    }

    /// Server rejected the pending Commit (409) → drop it.
    pub fn discard_commit(&mut self, group_id: &[u8]) -> Result<(), SyncError> {
        self.with_group_mut(group_id, |provider, _identity, handle| {
            handle.discard_pending_commit(provider).map_err(Into::into)
        })
    }

    /// Join a group via an incoming Welcome. Returns the group_id of
    /// the newly-joined group so the caller can wire it to its local
    /// chat row.
    pub fn join_via_welcome(&mut self, welcome_bytes: &[u8]) -> Result<Vec<u8>, SyncError> {
        use tls_codec::Deserialize;
        let msg = MlsMessageIn::tls_deserialize_exact(welcome_bytes)
            .map_err(|e| SyncError::Welcome(e.to_string()))?;
        let welcome = match msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err(SyncError::Welcome("frame was not a Welcome".to_string())),
        };
        let join_cfg = crate::group::join_config();
        // Processed first: the group id is known before staging, which
        // refuses any group already in storage.
        let processed = ProcessedWelcome::new_from_welcome(&self.provider, &join_cfg, welcome)
            .map_err(|e| SyncError::Welcome(format!("{e:?}")))?;
        // ADR-025 — Welcomes for a person with several devices stay queued
        // and come again; never let one replace a group we're still in.
        // A group we were removed from is different: invited back, the new
        // Welcome replaces the dead copy (owner, 2026-10-18: removed and
        // added again, nothing changed on their phone — "already in this
        // group").
        let gid = processed.unverified_group_info().group_id().to_vec();
        let existing = match self.groups.remove(&gid) {
            Some(h) => Some(h),
            None => GroupHandle::try_load(&self.provider, &gid)?,
        };
        if let Some(mut old) = existing {
            if old.is_active() {
                self.groups.insert(gid, old);
                return Err(SyncError::Welcome("already in this group".to_string()));
            }
            old.group
                .delete(self.provider.storage())
                .map_err(|e| SyncError::Welcome(format!("dropping the old copy: {e:?}")))?;
            info!(group_id = %hex::encode(&gid), "invited back into a group we were removed from");
        }
        // ADR-100 — an old member's leaf past its key package's lifetime
        // (84 days, never renewed unless they commit) must not lock the
        // chat for everyone invited later. A package being added is still
        // checked for its date, by the member who adds it.
        let staged = JoinBuilder::new(&self.provider, processed)
            .skip_lifetime_validation()
            .build()
            .map_err(|e| SyncError::Welcome(format!("{e:?}")))?;
        // Security review 2026-11 (mls-identity:1) — a chat with a leaf
        // that names nobody (someone's credential on another key) isn't joined.
        if staged.members().any(|m| crate::identity::identity_of_member(&m).is_none()) {
            return Err(SyncError::Welcome("a member of that chat is not who it claims".to_string()));
        }
        let sender = staged
            .welcome_sender()
            .ok()
            .and_then(crate::identity::identity_of_leaf_node);
        let group = staged
            .into_group(&self.provider)
            .map_err(|e| SyncError::Welcome(format!("{e:?}")))?;
        let group_id = group.group_id().to_vec();
        info!(group_id = %hex::encode(&group_id), "joined via welcome");
        if let Some(who) = sender {
            self.welcome_senders.insert(group_id.clone(), who);
        }
        self.groups.insert(
            group_id.clone(),
            GroupHandle {
                group_id: group_id.clone(),
                group,
            },
        );
        Ok(group_id)
    }

    /// Encrypt a plaintext message for the named group. Returns the
    /// MLS PrivateMessage bytes — caller sends via WS `Submit.ciphertext`.
    pub fn encrypt(&mut self, group_id: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, SyncError> {
        // `to_vec()` so the closure can drop the borrow on `plaintext`'s
        // call site cleanly — avoids fighting the borrow checker with
        // the `with_group_mut` indirection.
        let bytes = plaintext.to_vec();
        self.with_group_mut(group_id, |provider, identity, handle| {
            handle
                .encrypt_message(provider, identity, &bytes)
                .map_err(Into::into)
        })
    }

    /// Decrypt an MLS frame received via WS Push. Returns the plaintext
    /// when it's an ApplicationMessage; reports state changes otherwise.
    pub fn decrypt(
        &mut self,
        group_id: &[u8],
        wire_bytes: &[u8],
    ) -> Result<IncomingMessage, SyncError> {
        self.decrypt_with_sender(group_id, wire_bytes).map(|(m, _)| m)
    }

    /// [`decrypt`] plus the authenticated sender identity (Ed25519
    /// identity public key) of an application message — ADR-019.
    pub fn decrypt_with_sender(
        &mut self,
        group_id: &[u8],
        wire_bytes: &[u8],
    ) -> Result<(IncomingMessage, Option<Vec<u8>>), SyncError> {
        let bytes = wire_bytes.to_vec();
        self.with_group_mut(group_id, |provider, _identity, handle| {
            handle.process_incoming_with_sender(provider, &bytes).map_err(Into::into)
        })
    }

    /// CC3 — MLS Exporter binding for SFrame key derivation (spec §10.3).
    ///
    /// `length` MUST match the SFrame cipher suite's AEAD.Nk (16 for
    /// AES-128-GCM, 32 for AES-256-GCM). `label` is opaque to MLS but
    /// SFrame specifies `"SFrame 1.0 Base Key"`. `context` is the empty
    /// slice per RFC 9605 §5.2.
    ///
    /// Returns deterministic bytes derived from the group's CURRENT
    /// epoch. Caller must re-export after each Commit (epoch bump) —
    /// new epoch's exporter is uncorrelated with the old.
    pub fn group_exporter(
        &mut self,
        group_id: &[u8],
        label: &str,
        context: &[u8],
        length: usize,
    ) -> Result<Vec<u8>, SyncError> {
        let label = label.to_string();
        let context = context.to_vec();
        self.with_group_mut(group_id, |provider, _identity, handle| {
            handle
                .export_secret(provider, &label, &context, length)
                .map_err(Into::into)
        })
    }

    /// CC3 — our own leaf index within the named group. Used by callers
    /// (sinhron_call::sframe) as the `sender_index` input to per-sender
    /// key derivation.
    pub fn group_own_leaf_index(&mut self, group_id: &[u8]) -> Result<u32, SyncError> {
        self.with_group_mut(group_id, |_provider, _identity, handle| {
            Ok(handle.own_leaf_index())
        })
    }

    /// CC3 — current MLS epoch for the named group. Input to SFrame
    /// KID composition (epoch mod 2^E).
    pub fn group_epoch(&mut self, group_id: &[u8]) -> Result<u64, SyncError> {
        self.with_group_mut(group_id, |_provider, _identity, handle| {
            Ok(handle.current_epoch())
        })
    }

    /// Leaf index of the member whose MLS credential is `identity` (the
    /// Ed25519 identity public key) — SFrame's sender index for that
    /// person in a call (tech-debt 4.1/4.9).
    /// ADR-025 — `key` is a device key (a call participant is a *device*:
    /// LiveKit identity = the device's own key, so two devices of one
    /// person can be in a call together) or, as before, an identity key
    /// (first match among that person's leaves).
    pub fn group_member_leaf(&mut self, group_id: &[u8], key: &[u8]) -> Result<Option<u32>, SyncError> {
        let key = key.to_vec();
        self.with_group_mut(group_id, |_provider, _identity, handle| {
            let by_device = handle.group.members().find(|m| m.signature_key.as_slice() == key.as_slice());
            let by_identity = || {
                handle.group.members().find(|m| {
                    crate::identity::identity_of_member(m).as_ref().map(|i| i.as_slice())
                        == Some(key.as_slice())
                })
            };
            Ok(by_device.or_else(by_identity).map(|m| m.index.u32()))
        })
    }

    /// Identity keys (MLS credential content) of every member of a
    /// group, me included — for safety numbers (backlog §6 item 49).
    pub fn group_member_identities(&mut self, group_id: &[u8]) -> Result<Vec<Vec<u8>>, SyncError> {
        self.with_group_mut(group_id, |_provider, _identity, handle| {
            // ADR-025 — one entry per *person*: a user's devices share an
            // identity; an invalid certificate names nobody and is skipped.
            let mut ids: Vec<Vec<u8>> = Vec::new();
            for m in handle.group.members() {
                if let Some(id) = crate::identity::identity_of_member(&m) {
                    if !ids.iter().any(|x| x.as_slice() == id) {
                        ids.push(id.to_vec());
                    }
                }
            }
            Ok(ids)
        })
    }

    /// ADR-055 — is every leaf of this group one of my own devices? That
    /// is what a "Saved messages" chat is: a group of only me. (A chat whose
    /// other people all left looks the same — the app also asks for the
    /// explicit marker before treating a group as Saved messages.)
    pub fn is_own_devices_group(&mut self, group_id: &[u8]) -> Result<bool, SyncError> {
        // Every leaf must be mine — a leaf that names nobody isn't skipped.
        let me = self.identity.identity_public;
        self.with_group_mut(group_id, |_p, _i, handle| {
            Ok(handle.group.members().all(|m| crate::identity::identity_of_member(&m) == Some(me)))
        })
    }

    /// Read-only access to identity pubkey (for diagnostic surfaces).
    pub fn identity_pubkey_hex(&self) -> String {
        hex::encode(self.identity.identity_public)
    }

    /// CD6 — raw Ed25519 signing key bytes. Used by the call FFI layer
    /// to mint LiveKit JWT / TURN creds against the operator server
    /// WITHOUT re-deriving from the phrase (spec §6.8 — phrase never
    /// persists, but the seed lives in this struct after onboarding).
    /// Returns a 32-byte secret; copy carefully, do NOT log.
    ///
    /// ADR-025: the *identity* key's seed — on a linked device that is
    /// not the key its MLS leaf signs with (see [`device_seed_bytes`]).
    pub fn identity_seed_bytes(&self) -> [u8; 32] {
        // ADR-027: a QR-paired device has no identity key — it signs
        // account requests with its own key, which the server accepts
        // only while that device is active.
        self.identity.identity_secret.unwrap_or(self.identity.device_seed)
    }

    /// The key this device logs in to the WS with: its own device key when
    /// it has a leaf of its own (certificate) — so the server knows *which*
    /// device a connection is (device-addressed Welcomes, "last seen",
    /// revocation) — else the identity key (the first device, whose leaf
    /// key it is).
    pub fn login_seed_bytes(&self) -> [u8; 32] {
        if self.device_certificate().is_some() {
            self.identity.device_seed
        } else {
            self.identity_seed_bytes()
        }
    }

    /// ADR-027 — does this device hold the account (identity) key? Only
    /// such devices can add or revoke devices.
    pub fn has_account_key(&self) -> bool {
        self.identity.identity_secret.is_some()
    }

    /// ADR-027 — the bundle for a new device whose key is `device_pub`:
    /// the certificate for it (signed here with the identity key) plus
    /// what it needs to receive. The identity key itself never leaves.
    pub fn linked_bundle_for(&self, device_pub: &[u8; 32]) -> Result<String, SyncError> {
        let secret = self
            .identity
            .identity_secret
            .ok_or_else(|| SyncError::Identity(IdentityError::Derive("no account key on this device".into())))?;
        Ok(sinhron_crypto::identity::LinkedBundle {
            identity_public: self.identity.identity_public,
            x25519_public: self.x25519_public,
            certificate: crate::identity::device_certificate(&secret, device_pub),
            // ADR-084 — generation 0 (the phrase's): the current one reaches
            // the new device with the rest of my settings (transfer, sync).
            delivery_root: self.base_delivery_root,
            access_root: self.access_root,
            // ADR-073 — so the new device can back up the chats too.
            cloud_key: self.cloud_key,
        }
        .encode())
    }

    /// Tech-debt 2.2 — the person's sealed-sender access key: given to chat
    /// partners inside MLS so they can deliver to us without
    /// authenticating; the server only keeps its SHA-256. Derived from
    /// the account secret, so the same on all the person's devices.
    pub fn access_key(&self) -> [u8; crate::envelope::ACCESS_KEY_LEN] {
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        h.update(self.access_root);
        // Rotation: a new version → a new key; old holders are refused.
        h.update(self.access_version.to_be_bytes());
        let d = h.finalize();
        let mut k = [0u8; crate::envelope::ACCESS_KEY_LEN];
        k.copy_from_slice(&d[..crate::envelope::ACCESS_KEY_LEN]);
        k
    }

    pub fn access_version(&self) -> u32 {
        self.access_version
    }

    pub fn set_access_version(&mut self, v: u32) {
        self.access_version = v;
    }

    /// SHA-256 of [`access_key`] — what the server keeps to check it.
    pub fn access_hash(&self) -> [u8; 32] {
        use sha2::{Digest, Sha256};
        Sha256::digest(self.access_key()).into()
    }

    /// ADR-071 — the access key I give [contact] (their identity key) and
    /// nobody else, so blocking them revokes just theirs. Derived from the
    /// account secret: the same on all my devices; a new version (rotation)
    /// changes every one. My own identity → the key for my other devices.
    pub fn access_key_for(&self, contact: &[u8]) -> [u8; crate::envelope::ACCESS_KEY_LEN] {
        use sha2::{Digest, Sha256};
        let mut h = Sha256::new();
        h.update(b"sinhron-access-key/v2");
        h.update(self.access_root);
        h.update(self.access_version.to_be_bytes());
        h.update(contact);
        let d = h.finalize();
        let mut k = [0u8; crate::envelope::ACCESS_KEY_LEN];
        k.copy_from_slice(&d[..crate::envelope::ACCESS_KEY_LEN]);
        k
    }

    /// SHA-256 of [`access_key_for`] — what goes to the server.
    pub fn access_hash_for(&self, contact: &[u8]) -> [u8; 32] {
        use sha2::{Digest, Sha256};
        Sha256::digest(self.access_key_for(contact)).into()
    }

    /// ADR-025 — this device's own key seed (signs KeyPackage uploads and
    /// its registration). Equals [`identity_seed_bytes`] on the primary.
    pub fn device_seed_bytes(&self) -> [u8; 32] {
        self.identity.device_seed
    }

    /// ADR-025 — the device certificate, if this is a linked device.
    pub fn device_certificate(&self) -> Option<Vec<u8>> {
        let c = self.identity.credential.credential.serialized_content();
        (c.len() == crate::identity::DEVICE_CERT_LEN).then(|| c.to_vec())
    }

    /// ADR-082 — the certificate that goes with a signature by
    /// [`identity_seed_bytes`]: this device's when that is its own key (a
    /// QR-paired device without the identity key), else None.
    pub fn signer_certificate(&self) -> Option<Vec<u8>> {
        self.identity.identity_secret.is_none().then(|| self.device_certificate()).flatten()
    }

    /// How many groups are currently hydrated in the in-memory cache.
    /// Used by the Settings → Diagnostics surface. Does NOT reflect
    /// groups that exist on disk but haven't been touched this session —
    /// those re-hydrate lazily on first encrypt/decrypt.
    pub fn cached_group_count(&self) -> usize {
        self.groups.len()
    }

    /// Convenience: register this identity with the operator server.
    /// Idempotent — re-registering returns `already_existed: true`.
    ///
    /// **Risk #3 note**: takes `&mut self` (even though no mutation
    /// happens) so the resulting `Future` is `Send` iff `Self: Send`,
    /// not `Self: Sync`. This is what lets us drop the
    /// `unsafe impl Sync for SinhronProvider` — see provider.rs.
    /// Same pattern applied to `publish_keypackage`,
    /// `bootstrap_with_server`, `fetch_kp_and_invite`.
    pub async fn register_with_server(
        &mut self,
        http: &crate::http_api::HttpApi,
    ) -> Result<crate::http_api::RegisterOutcome, SyncError> {
        let secret = self.identity.identity_secret.ok_or_else(|| SyncError::Http("no account key on this device".into()))?;
        http.register_identity(secret)
            .await
            .map_err(|e| SyncError::Http(e.to_string()))
    }

    /// Convenience: create a fresh KeyPackage AND publish it to the
    /// operator server via HTTP. Returns the server-assigned id on success.
    pub async fn publish_keypackage(
        &mut self,
        http: &crate::http_api::HttpApi,
    ) -> Result<String, SyncError> {
        let kp_bytes = self.create_keypackage()?;
        http.publish_keypackage(self.identity.device_seed, &kp_bytes)
            .await
            .map_err(|e| SyncError::Http(e.to_string()))
    }

    /// Full onboarding bootstrap: register identity + publish first
    /// KeyPackage in sequence. Used at the end of recovery-phrase
    /// onboarding. Failures at any step bubble up — caller can retry.
    pub async fn bootstrap_with_server(
        &mut self,
        http: &crate::http_api::HttpApi,
    ) -> Result<BootstrapOutcome, SyncError> {
        // ADR-027 — a QR-paired device can't (and needn't) register the
        // identity: the device that added it did.
        let reg = if self.has_account_key() {
            self.register_with_server(http).await?
        } else {
            crate::http_api::RegisterOutcome {
                user_pk: String::new(),
                already_existed: true,
                identity_pubkey_hex: self.identity_pubkey_hex(),
            }
        };
        // ADR-025 — a linked device registers its own key under the identity.
        if let Some(cert) = self.device_certificate() {
            http.register_device(self.identity.device_seed, &cert)
                .await
                .map_err(|e| SyncError::Http(e.to_string()))?;
        }
        let kp_id = self.publish_keypackage(http).await?;
        Ok(BootstrapOutcome {
            user_pk: reg.user_pk,
            already_existed: reg.already_existed,
            identity_pubkey_hex: reg.identity_pubkey_hex,
            keypackage_id: kp_id,
        })
    }

    /// Convenience: fetch a KeyPackage for the target identity from the
    /// operator server, MLS-Add them locally, AND announce the group
    /// membership to the server. Server's `group_members` table needs
    /// to know both Alice + Bob's device_pks before WS Submit fanout
    /// will route correctly (server's Submit handler checks sender
    /// membership + iterates members for the Push list). Caller is
    /// still responsible for shipping the welcome to the target via
    /// `net_send_welcome` (or a future WS Welcome frame).
    ///
    /// ADR-025: every active device of the target is added; the inviter's
    /// own other devices join through device sync.
    pub async fn fetch_kp_and_invite(
        &mut self,
        http: &crate::http_api::HttpApi,
        group_id: &[u8],
        target_identity_hex: &str,
    ) -> Result<crate::group::AddMemberOutcome, SyncError> {
        self.fetch_kp_and_invite_devices(http, group_id, target_identity_hex).await.map(|(o, _)| o)
    }

    /// [`fetch_kp_and_invite`] that also returns the target's device keys
    /// that were added (the Welcome is addressed to them — ADR-025).
    pub async fn fetch_kp_and_invite_devices(
        &mut self,
        http: &crate::http_api::HttpApi,
        group_id: &[u8],
        target_identity_hex: &str,
    ) -> Result<(crate::group::AddMemberOutcome, Vec<Vec<u8>>), SyncError> {
        let (outcome, mut added) = self.fetch_kps_and_invite_people(http, group_id, &[target_identity_hex.to_string()]).await?;
        Ok((outcome, added.pop().map(|p| p.devices).unwrap_or_default()))
    }

    /// ADR-034 — a group of several people in ONE Commit: every active
    /// device of every target (one KeyPackage each, ADR-025), one Welcome
    /// for all of them, one announce of every device. Nobody is added
    /// unless everyone's KeyPackages were found. Returns the outcome and,
    /// per person, the devices added (each person's Welcome copy is
    /// addressed to theirs).
    pub async fn fetch_kps_and_invite_people(
        &mut self,
        http: &crate::http_api::HttpApi,
        group_id: &[u8],
        targets_hex: &[String],
    ) -> Result<(crate::group::AddMemberOutcome, Vec<InvitedPerson>), SyncError> {
        let (people, kp_bytes) = self.fetch_people_keypackages(http, targets_hex).await?;
        let outcome = self.invite_devices(group_id, &kp_bytes)?;

        // Tell the server which devices are in the group. Idempotent on
        // the server side (`ON CONFLICT DO NOTHING`).
        let mut members = vec![self.device_public_key()];
        members.extend(people.iter().flat_map(|p| p.devices.iter().cloned()));
        http.announce_group(self.login_seed_bytes(), group_id, self.group_epoch(group_id)?, &members)
            .await
            .map_err(|e| SyncError::Http(e.to_string()))?;

        Ok((outcome, people))
    }

    /// ADR-034 — one KeyPackage per active device of each person in
    /// `targets_hex` (duplicates and this person skipped — our own other
    /// devices join through device sync). Fails if anyone has none.
    pub async fn fetch_people_keypackages(
        &mut self,
        http: &crate::http_api::HttpApi,
        targets_hex: &[String],
    ) -> Result<(Vec<InvitedPerson>, Vec<Vec<u8>>), SyncError> {
        let me = self.identity_pubkey_hex();
        // Tech-debt 2.34 — ask first: claiming is per person, so one person
        // without KeyPackages used to fail the group after the others'
        // were already used up.
        let wanted: Vec<String> = {
            let mut w: Vec<String> = Vec::new();
            for t in targets_hex.iter().map(|t| t.to_lowercase()) {
                if t != me && !w.contains(&t) {
                    w.push(t);
                }
            }
            w
        };
        if !wanted.is_empty() {
            if let Ok(Some(missing)) = http.keypackages_missing(&wanted).await {
                if let Some(first) = missing.first() {
                    let short: String = first.chars().take(8).collect();
                    return Err(SyncError::Http(format!("{short}: no keypackage available")));
                }
            }
        }
        let mut people: Vec<InvitedPerson> = Vec::new();
        let mut kp_bytes = Vec::new();
        for target in targets_hex {
            let target = target.to_lowercase();
            if target == me || people.iter().any(|p| p.identity_hex == target) {
                continue;
            }
            let kps = http.fetch_device_keypackages(self.login_seed_bytes(), &target, &[]).await.map_err(|e| {
                let short: String = target.chars().take(8).collect();
                SyncError::Http(format!("{short}: {e}"))
            })?;
            // Security review 2026-11 (mls-identity:6) — each key package
            // must be this person's, from the device the server named.
            for (dev, kp) in &kps {
                let leaf = parse_keypackage_in(kp)?.unverified_credential();
                let named = crate::identity::identity_of_leaf(leaf.credential.serialized_content(), leaf.signature_key.as_slice());
                if named.map(hex::encode).as_ref() != Some(&target) || leaf.signature_key.as_slice() != dev.as_slice() {
                    let short: String = target.chars().take(8).collect();
                    return Err(SyncError::KeyPackage(format!("{short}: key package of another person")));
                }
            }
            let (devices, kps): (Vec<Vec<u8>>, Vec<Vec<u8>>) = kps.into_iter().unzip();
            kp_bytes.extend(kps);
            people.push(InvitedPerson { identity_hex: target, devices });
        }
        if people.is_empty() {
            return Err(SyncError::Http("no one to invite".to_string()));
        }
        Ok((people, kp_bytes))
    }

    /// Hot-path helper: borrow a mutable group, lazily re-hydrating it
    /// from the SQLite-backed storage if it's not in the in-memory map.
    /// All encrypt/decrypt/add_member flows funnel through here so the
    /// "group exists on disk but not in cache" case is handled in one
    /// place. Returns `UnknownGroup` if neither cache nor storage know
    /// about the id.
    fn with_group_mut<T>(
        &mut self,
        group_id: &[u8],
        body: impl FnOnce(&SinhronProvider, &MlsIdentity, &mut GroupHandle) -> Result<T, SyncError>,
    ) -> Result<T, SyncError> {
        if !self.groups.contains_key(group_id) {
            let loaded = GroupHandle::try_load(&self.provider, group_id)?;
            match loaded {
                Some(handle) => {
                    self.groups.insert(group_id.to_vec(), handle);
                }
                None => return Err(SyncError::UnknownGroup(hex::encode(group_id))),
            }
        }
        let handle = self
            .groups
            .get_mut(group_id)
            .expect("just inserted or already present");
        body(&self.provider, &self.identity, handle)
    }
}

/// ADR-034 — one person added to a group and the devices of theirs that
/// got a leaf (their copy of the Welcome is addressed to these).
#[derive(Debug, Clone)]
pub struct InvitedPerson {
    pub identity_hex: String,
    pub devices: Vec<Vec<u8>>,
}

fn parse_keypackage_in(bytes: &[u8]) -> Result<KeyPackageIn, SyncError> {
    use tls_codec::Deserialize;
    KeyPackageIn::tls_deserialize_exact(bytes)
        .map_err(|e| SyncError::KeyPackage(format!("deserialize: {e}")))
}

/// Full result of `SyncClient::bootstrap_with_server`.
#[derive(Debug, Clone)]
pub struct BootstrapOutcome {
    pub user_pk: String,
    pub already_existed: bool,
    pub identity_pubkey_hex: String,
    pub keypackage_id: String,
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("identity: {0}")]
    Identity(#[from] IdentityError),
    #[error("group: {0}")]
    Group(#[from] GroupError),
    #[error("provider: {0}")]
    Provider(#[from] ProviderError),
    #[error("key package: {0}")]
    KeyPackage(String),
    #[error("welcome: {0}")]
    Welcome(String),
    #[error("unknown group: {0}")]
    UnknownGroup(String),
    #[error("http: {0}")]
    Http(String),
    #[error("sealed sender: {0}")]
    Sealed(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::prelude::*;

    /// Tech-debt 4.1/4.9 — in a call every member must be able to find
    /// every other member's SFrame sender index from their identity:
    /// Alice's lookup of Bob's leaf equals Bob's own leaf, and both see
    /// the same exporter secret (so they derive the same keys).
    #[test]
    fn member_leaf_lookup_matches_own_leaf() {
        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".into(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: "legal winner thank year wave sausage worth useful legal winner thank yellow".into(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let group = alice.create_group().unwrap();
        let add = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();

        let bob_id = hex::decode(bob.identity_pubkey_hex()).unwrap();
        let alice_id = hex::decode(alice.identity_pubkey_hex()).unwrap();
        assert_eq!(alice.group_member_leaf(&group, &bob_id).unwrap(), Some(bob.group_own_leaf_index(&group).unwrap()));
        assert_eq!(bob.group_member_leaf(&group, &alice_id).unwrap(), Some(alice.group_own_leaf_index(&group).unwrap()));
        assert_eq!(alice.group_member_leaf(&group, &[9u8; 32]).unwrap(), None);
        assert_eq!(
            alice.group_exporter(&group, "SFrame 1.0 Base Key", &[], 16).unwrap(),
            bob.group_exporter(&group, "SFrame 1.0 Base Key", &[], 16).unwrap(),
        );
    }

    /// ADR-025 — Alice on two devices (her first phone and a linked
    /// laptop) and Bob. Each device is its own leaf; everyone sees two
    /// *people*; the sender is always the person; Alice's phone reads what
    /// she sent from the laptop; after revoking the laptop it reads nothing.
    /// A message sent in the old epoch reaches a member who already applied
    /// the Commit that ended it (e.g. sent while device sync's Commit was
    /// in flight). Groups keep the previous epochs' keys (MAX_PAST_EPOCHS).
    #[test]
    fn message_from_the_previous_epoch_still_decrypts() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mk = |phrase: &str, device_seed| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
        };
        let mut alice = mk(ALICE, None);
        let mut bob = mk("legal winner thank year wave sausage worth useful legal winner thank yellow", None);
        let laptop = mk(ALICE, Some([43u8; 32]));
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();

        // Alice starts a Commit, but her message is encrypted in the old
        // epoch before it's applied; Bob gets the Commit first.
        let pending = alice.invite_devices_pending(&group, &[laptop.create_keypackage().unwrap()]).unwrap();
        let late = alice.encrypt(&group, b"sent before the commit landed").unwrap();
        alice.confirm_commit(&group).unwrap();
        assert!(matches!(bob.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        let m = bob.decrypt(&group, &late).unwrap();
        assert!(matches!(m, IncomingMessage::App(ref b) if b == b"sent before the commit landed"), "got {m:?}");
        assert!(!alice.has_pending_commit(&group).unwrap());
    }

    /// ADR-082 — the signer and certificate a device publishes its
    /// delivery keys with verify as the person's: first device, a phrase
    /// laptop, and a QR-paired device without the identity key.
    #[test]
    fn delivery_keys_are_signed_as_the_person_on_every_kind_of_device() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mk = |phrase: String, device_seed| SyncClient::new(SyncClientConfig { phrase, db_path: None, device_seed }).unwrap();
        let alice = mk(ALICE.into(), None);
        let laptop = mk(ALICE.into(), Some([43u8; 32]));
        let pad_pub = ed25519_dalek::SigningKey::from_bytes(&[44u8; 32]).verifying_key().to_bytes();
        let paired = mk(alice.linked_bundle_for(&pad_pub).unwrap(), Some([44u8; 32]));
        assert!(paired.signer_certificate().is_some() && alice.signer_certificate().is_none());
        for c in [&alice, &laptop, &paired] {
            let id: [u8; 32] = hex::decode(c.identity_pubkey_hex()).unwrap().try_into().unwrap();
            let k = &c.delivery_keys_to_publish(1_800_000_000).unwrap()[0];
            let sig = crate::sealed::sign_delivery_key(&c.identity_seed_bytes(), &id, k.week, &k.public);
            assert!(crate::sealed::delivery_key_signed(&id, k.week, &k.public, &sig, c.signer_certificate().as_deref()));
        }
    }

    /// ADR-034 — a group of three people made in ONE Commit: Bob and
    /// Carol join from the same Welcome, everyone sees three people, and
    /// every member reads every other member. Dave added later by a
    /// pending Commit: the existing members apply it and read him too.
    // ADR-035 — the creator removes a member; the removed device notices,
    // the rest keep talking; nobody can remove themselves this way.
    #[test]
    fn creator_removes_a_member_who_then_knows_and_reads_nothing_new() {
        let mk = |phrase: &str| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed: None }).unwrap()
        };
        let mut alice = mk("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        let mut bob = mk("legal winner thank year wave sausage worth useful legal winner thank yellow");
        let mut carol = mk("letter advice cage absurd amount doctor acoustic avoid letter advice cage above");
        let group = alice.create_group().unwrap();
        let add = alice
            .invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()])
            .unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();

        // Everyone agrees who the creator (admin) is.
        let a_id: [u8; 32] = hex::decode(alice.identity_pubkey_hex()).unwrap().try_into().unwrap();
        for c in [&mut alice, &mut bob, &mut carol] {
            assert_eq!(c.group_admin(&group).unwrap(), Some(a_id));
            assert!(c.group_is_active(&group).unwrap());
        }

        // Removing yourself isn't possible through this.
        assert!(alice.remove_people_pending(&group, &[a_id]).is_err());

        let c_id: [u8; 32] = hex::decode(carol.identity_pubkey_hex()).unwrap().try_into().unwrap();
        let pending = alice.remove_people_pending(&group, &[c_id]).unwrap();
        alice.confirm_commit(&group).unwrap();
        for m in [&mut bob, &mut carol] {
            assert!(matches!(m.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        }
        assert!(!carol.group_is_active(&group).unwrap(), "Carol sees she was removed");
        assert!(bob.group_is_active(&group).unwrap());
        assert_eq!(bob.group_member_identities(&group).unwrap().len(), 2);

        // Alice and Bob go on; Carol can't read it.
        let ct = alice.encrypt(&group, b"after").unwrap();
        assert!(matches!(bob.decrypt(&group, &ct).unwrap(), IncomingMessage::App(ref b) if b == b"after"));
        assert!(carol.decrypt(&group, &ct).is_err(), "removed member reads nothing new");
    }

    /// Owner, 2026-10-18 — removed, then added again: the new Welcome
    /// replaces the dead copy and they read the group again; a Welcome for a
    /// group they're still in is still refused (ADR-025).
    #[test]
    fn a_removed_member_can_be_invited_back() {
        let mk = |phrase: &str| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed: None }).unwrap()
        };
        let mut alice = mk("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        let mut carol = mk("letter advice cage absurd amount doctor acoustic avoid letter advice cage above");
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[carol.create_keypackage().unwrap()]).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();
        assert!(carol.join_via_welcome(&add.welcome_bytes).is_err(), "a repeat Welcome is refused");

        let c_id: [u8; 32] = hex::decode(carol.identity_pubkey_hex()).unwrap().try_into().unwrap();
        let removed = alice.remove_people_pending(&group, &[c_id]).unwrap();
        alice.confirm_commit(&group).unwrap();
        carol.decrypt(&group, &removed.commit_bytes).unwrap();
        assert!(!carol.group_is_active(&group).unwrap());

        let again = alice.invite_devices(&group, &[carol.create_keypackage().unwrap()]).unwrap();
        alice.confirm_commit(&group).ok();
        assert_eq!(carol.join_via_welcome(&again.welcome_bytes).unwrap(), group);
        assert!(carol.group_is_active(&group).unwrap(), "back in");
        let ct = alice.encrypt(&group, b"welcome back").unwrap();
        assert!(matches!(carol.decrypt(&group, &ct).unwrap(), IncomingMessage::App(ref b) if b == b"welcome back"));
    }

    /// ADR-035 — leaving: MLS can't commit its own removal, so another member
    /// (here not the creator) commits it. When the creator leaves, the
    /// earliest remaining person is the admin (ADR-088) and the rest go on.
    #[test]
    fn a_member_commits_the_leavers_removal_even_the_creators() {
        let mk = |phrase: &str| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed: None }).unwrap()
        };
        let mut alice = mk("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        let mut bob = mk("legal winner thank year wave sausage worth useful legal winner thank yellow");
        let mut carol = mk("letter advice cage absurd amount doctor acoustic avoid letter advice cage above");
        let group = alice.create_group().unwrap();
        let add = alice
            .invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()])
            .unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();

        // Alice (the creator) says she leaves; Bob commits it.
        let a_id: [u8; 32] = hex::decode(alice.identity_pubkey_hex()).unwrap().try_into().unwrap();
        let pending = bob.remove_people_pending(&group, &[a_id]).unwrap();
        bob.confirm_commit(&group).unwrap();
        for m in [&mut alice, &mut carol] {
            assert!(matches!(m.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        }
        assert!(!alice.group_is_active(&group).unwrap());
        let b_id = id_of(&bob);
        for c in [&mut bob, &mut carol] {
            assert_eq!(c.group_admin(&group).unwrap(), Some(b_id), "the admin passed to Bob");
            assert_eq!(c.group_member_identities(&group).unwrap().len(), 2);
        }
        let ct = carol.encrypt(&group, b"still here").unwrap();
        assert!(matches!(bob.decrypt(&group, &ct).unwrap(), IncomingMessage::App(ref b) if b == b"still here"));
        assert!(alice.decrypt(&group, &ct).is_err(), "the leaver reads nothing new");
    }

    #[test]
    fn three_person_group_everyone_reads_everyone() {
        let mk = |phrase: &str| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed: None }).unwrap()
        };
        let mut alice = mk("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        let mut bob = mk("legal winner thank year wave sausage worth useful legal winner thank yellow");
        let mut carol = mk("letter advice cage absurd amount doctor acoustic avoid letter advice cage above");
        let mut dave = mk("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong");

        let group = alice.create_group().unwrap();
        let add = alice
            .invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()])
            .unwrap();
        assert_eq!(bob.join_via_welcome(&add.welcome_bytes).unwrap(), group);
        assert_eq!(carol.join_via_welcome(&add.welcome_bytes).unwrap(), group);
        for c in [&mut alice, &mut bob, &mut carol] {
            assert_eq!(c.group_member_identities(&group).unwrap().len(), 3, "three people");
        }

        fn round(group: &[u8], members: &mut [&mut SyncClient]) {
            for i in 0..members.len() {
                let text = format!("from {i}");
                let ct = members[i].encrypt(group, text.as_bytes()).unwrap();
                let from = members[i].identity_pubkey_hex();
                for (j, m) in members.iter_mut().enumerate() {
                    if i == j {
                        continue;
                    }
                    let (msg, sender) = m.decrypt_with_sender(group, &ct).unwrap();
                    assert!(matches!(msg, IncomingMessage::App(ref b) if b == text.as_bytes()), "{j} reads {i}: {msg:?}");
                    assert_eq!(hex::encode(sender.unwrap()), from);
                }
            }
        }
        round(&group, &mut [&mut alice, &mut bob, &mut carol]);

        // Later: Alice (the admin) adds Dave. The Commit reaches Bob and Carol.
        let pending = alice.invite_devices_pending(&group, &[dave.create_keypackage().unwrap()]).unwrap();
        alice.confirm_commit(&group).unwrap();
        for m in [&mut bob, &mut carol] {
            assert!(matches!(m.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        }
        dave.join_via_welcome(pending.welcome_bytes.as_ref().unwrap()).unwrap();
        round(&group, &mut [&mut alice, &mut bob, &mut carol, &mut dave]);
    }

    #[test]
    fn two_devices_one_person() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mk = |phrase: &str, device_seed| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
        };
        let mut phone = mk(ALICE, None);
        let mut laptop = mk(ALICE, Some([42u8; 32]));
        let mut bob = mk("legal winner thank year wave sausage worth useful legal winner thank yellow", None);
        assert_eq!(phone.identity_pubkey_hex(), laptop.identity_pubkey_hex(), "one person");
        assert_ne!(phone.device_public_key(), laptop.device_public_key(), "two leaves, two keys");

        let group = phone.create_group().unwrap();
        let add = phone
            .invite_devices(&group, &[bob.create_keypackage().unwrap(), laptop.create_keypackage().unwrap()])
            .unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        laptop.join_via_welcome(&add.welcome_bytes).unwrap();
        // The same Welcome again (queued Welcomes are re-sent) is refused.
        assert!(laptop.join_via_welcome(&add.welcome_bytes).is_err());
        // ADR-074 — added by my own phone: not "added back by someone else".
        assert!(!laptop.added_back_by_someone_else(&group).unwrap());
        assert!(!bob.added_back_by_someone_else(&group).unwrap(), "Bob is new here");

        let people = phone.group_member_identities(&group).unwrap();
        assert_eq!(people.len(), 2, "Alice's two devices are one person");
        let alice_id: [u8; 32] = hex::decode(phone.identity_pubkey_hex()).unwrap().try_into().unwrap();
        assert_eq!(bob.group_device_keys(&group, &alice_id).unwrap().len(), 2);

        // Calls (ADR-025): each device is its own participant — its leaf by
        // its device key; the identity key still finds one of the person's.
        let phone_leaf = bob.group_member_leaf(&group, &phone.device_public_key()).unwrap().unwrap();
        let laptop_leaf = bob.group_member_leaf(&group, &laptop.device_public_key()).unwrap().unwrap();
        assert_ne!(phone_leaf, laptop_leaf, "two devices, two SFrame senders");
        assert_eq!(laptop.group_member_leaf(&group, &laptop.device_public_key()).unwrap(), Some(laptop.group_own_leaf_index(&group).unwrap()));
        assert!(bob.group_member_leaf(&group, &alice_id).unwrap().is_some());

        // Bob → both of Alice's devices.
        let m = bob.encrypt(&group, b"hi Alice").unwrap();
        for d in [&mut phone, &mut laptop] {
            let (msg, sender) = d.decrypt_with_sender(&group, &m).unwrap();
            assert!(matches!(msg, IncomingMessage::App(ref b) if b == b"hi Alice"));
            assert_eq!(hex::encode(sender.unwrap()), bob.identity_pubkey_hex());
        }
        // Laptop → Bob sees Alice; the phone sees its own person (sent-sync).
        let m = laptop.encrypt(&group, b"from my laptop").unwrap();
        let (_, s_bob) = bob.decrypt_with_sender(&group, &m).unwrap();
        assert_eq!(hex::encode(s_bob.unwrap()), phone.identity_pubkey_hex());
        let (msg, s_phone) = phone.decrypt_with_sender(&group, &m).unwrap();
        assert!(matches!(msg, IncomingMessage::App(_)));
        assert_eq!(hex::encode(s_phone.unwrap()), phone.identity_pubkey_hex());
        // The laptop gets its own message back from the server: an echo, not an error.
        assert!(matches!(laptop.decrypt(&group, &m).unwrap(), IncomingMessage::OwnCommitEcho));

        // Revoke the laptop: Bob applies the Commit; the laptop is out.
        let commit = phone.remove_device(&group, &laptop.device_public_key()).unwrap();
        assert!(matches!(bob.decrypt(&group, &commit).unwrap(), IncomingMessage::Commit { .. }));
        assert_eq!(bob.group_device_keys(&group, &alice_id).unwrap().len(), 1);
        let after = bob.encrypt(&group, b"laptop can't read this").unwrap();
        assert!(laptop.decrypt(&group, &after).map(|m| !matches!(m, IncomingMessage::App(_))).unwrap_or(true));
        assert!(matches!(phone.decrypt(&group, &after).unwrap(), IncomingMessage::App(_)));
    }

    /// ADR-074 — Bob lost his phone and signed in on a new one: Alice (any
    /// member) adds the new device to their chat; it reads and writes as
    /// Bob. A key package of someone else, or of a person not in the chat,
    /// is refused — that is how the server can't slip a stranger in.
    #[test]
    fn a_member_adds_another_members_new_phone_and_nobody_else() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        const BOB: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";
        const CAROL: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
        let mk = |phrase: &str, device_seed| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
        };
        let mut alice = mk(ALICE, None);
        let mut bob_old = mk(BOB, None);
        let mut bob_new = mk(BOB, Some([7u8; 32]));
        let carol = mk(CAROL, None);
        let id = |c: &SyncClient| -> [u8; 32] { hex::decode(c.identity_pubkey_hex()).unwrap().try_into().unwrap() };
        let (bob_id, carol_id) = (id(&bob_old), id(&carol));

        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob_old.create_keypackage().unwrap()]).unwrap();
        bob_old.join_via_welcome(&add.welcome_bytes).unwrap();

        // Refused: Carol's package handed over as "Bob's", and Carol herself.
        let carol_kp = carol.create_keypackage().unwrap();
        assert!(alice.invite_devices_of_pending(&group, &[(bob_id, carol_kp.clone())]).is_err());
        assert!(alice.invite_devices_of_pending(&group, &[(carol_id, carol_kp)]).is_err());
        assert_eq!(alice.group_member_identities(&group).unwrap().len(), 2);

        // Bob's new phone.
        // A bad package next to a good one: the good one still goes in.
        let swapped = (bob_id, mk(CAROL, Some([8u8; 32])).create_keypackage().unwrap());
        let (pending, added) =
            alice.invite_devices_of_pending(&group, &[swapped, (bob_id, bob_new.create_keypackage().unwrap())]).unwrap();
        assert_eq!(added, vec![(bob_id, bob_new.device_public_key())]);
        alice.confirm_commit(&group).unwrap();
        assert!(matches!(bob_old.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        bob_new.join_via_welcome(pending.welcome_bytes.as_ref().unwrap()).unwrap();
        assert!(bob_new.added_back_by_someone_else(&group).unwrap(), "Bob was a member: added back, not a request");
        assert_eq!(alice.group_device_keys(&group, &bob_id).unwrap().len(), 2);
        assert_eq!(alice.group_member_identities(&group).unwrap().len(), 2, "still two people");

        let m = alice.encrypt(&group, b"welcome back").unwrap();
        assert!(matches!(bob_new.decrypt(&group, &m).unwrap(), IncomingMessage::App(ref b) if b == b"welcome back"));
        let r = bob_new.encrypt(&group, b"thanks").unwrap();
        let (msg, sender) = alice.decrypt_with_sender(&group, &r).unwrap();
        assert!(matches!(msg, IncomingMessage::App(_)));
        assert_eq!(sender.unwrap(), bob_id.to_vec(), "the new phone writes as Bob");
    }

    /// ADR-093 (server-http:10) — every member leaves its own card. Alice's
    /// and Carol's cards of one epoch say the same (only the signer
    /// differs); Mallory's from a branch nobody else took says something
    /// else and loses the vote, so Bob's new phone joins the real chat and
    /// Alice takes its join. Bob's own old phone's card wins even alone.
    #[test]
    fn a_new_phone_joins_by_the_card_most_people_left() {
        use crate::card_choice::{card_content, cards_to_try, CardFromServer};
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        const BOB: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";
        const CAROL: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
        const MALLORY: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";
        let mk = |phrase: &str, device_seed| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
        };
        let id = |c: &SyncClient| -> [u8; 32] { hex::decode(c.identity_pubkey_hex()).unwrap().try_into().unwrap() };
        let (mut alice, mut bob_old, mut carol, mut mallory) = (mk(ALICE, None), mk(BOB, None), mk(CAROL, None), mk(MALLORY, None));
        let mut bob_new = mk(BOB, Some([9u8; 32]));
        let group = alice.create_group().unwrap();
        let kps = [bob_old.create_keypackage().unwrap(), carol.create_keypackage().unwrap(), mallory.create_keypackage().unwrap()];
        let add = alice.invite_devices(&group, &kps).unwrap();
        for c in [&mut bob_old, &mut carol, &mut mallory] {
            c.join_via_welcome(&add.welcome_bytes).unwrap();
        }
        let epoch = alice.group_epoch(&group).unwrap();
        let (_, a_card) = alice.group_card(&group).unwrap();
        let (_, c_card) = carol.group_card(&group).unwrap();
        let (_, b_card) = bob_old.group_card(&group).unwrap();
        assert_ne!(a_card, c_card, "signed by each");
        assert_eq!(card_content(&a_card), card_content(&c_card), "and saying the same");
        assert!(card_content(&a_card).is_some());
        // Mallory's card from her own branch (a Commit only she merged).
        mallory.self_update_pending(&group).unwrap();
        mallory.confirm_commit(&group).unwrap();
        let (m_epoch, m_card) = mallory.group_card(&group).unwrap();
        assert_eq!(m_epoch, epoch + 1);

        let from = |epoch, card: &[u8], who: &SyncClient| CardFromServer { epoch, card: card.to_vec(), identity: id(who) };
        let honest = [from(m_epoch, &m_card, &mallory), from(epoch, &a_card, &alice), from(epoch, &c_card, &carol)];
        let order = cards_to_try(&honest, &id(&bob_new));
        assert_eq!(card_content(&order[0]), card_content(&a_card), "two people beat one");
        // ADR-100 — but a card is taken only when my own device signed it:
        // other people's, however many, are not a reason to enter.
        assert!(bob_new.join_by_card(&group, &order[0]).is_err(), "Alice's card is not mine");
        assert!(bob_new.group_epoch(&group).is_err(), "and nothing is left behind");
        let (gid, pending) = bob_new.join_by_card(&group, &b_card).unwrap();
        assert_eq!((gid, pending.epoch), (group.clone(), epoch));
        assert!(matches!(alice.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }), "the real chat takes it");

        // Bob's old phone's card is the one, even against everyone else.
        let mut with_mine = honest.to_vec();
        with_mine.push(from(epoch, &b_card, &bob_old));
        assert_eq!(cards_to_try(&with_mine, &id(&bob_new))[0], b_card);
    }

    /// ADR-075 — everyone else is offline: Bob's new phone joins his chat
    /// with Alice by its card (external commit); Alice applies it when she
    /// comes back; they write both ways; then Bob's new phone takes the
    /// lost phone out. A card can't pull a stranger in: Carol's join is
    /// refused at her end (none of hers in the chat) and at Alice's.
    #[test]
    fn a_new_phone_joins_by_the_chats_card_and_strangers_dont() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        const BOB: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";
        const CAROL: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
        let mk = |phrase: &str, device_seed| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
        };
        let mut alice = mk(ALICE, None);
        let mut bob_old = mk(BOB, None);
        let mut bob_new = mk(BOB, Some([9u8; 32]));
        let mut carol = mk(CAROL, None);
        let bob_id: [u8; 32] = hex::decode(bob_old.identity_pubkey_hex()).unwrap().try_into().unwrap();

        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob_old.create_keypackage().unwrap()]).unwrap();
        bob_old.join_via_welcome(&add.welcome_bytes).unwrap();
        // The old phone's card, left on the server after the last change
        // (ADR-100: only a card my own device signed opens the chat).
        let (epoch, card) = bob_old.group_card(&group).unwrap();
        assert_eq!(epoch, alice.group_epoch(&group).unwrap());

        // A stranger with the card gets nowhere.
        assert!(carol.join_by_card(&group, &card).is_err(), "none of Carol's devices is in that chat");
        assert!(carol.group_epoch(&group).is_err(), "and nothing is left behind");

        // Bob's new phone, Alice asleep.
        let (gid, pending) = bob_new.join_by_card(&group, &card).unwrap();
        assert_eq!(gid, group);
        assert_eq!(pending.epoch, epoch, "Submit.commit_epoch for the server's ordering");
        assert_eq!(bob_new.group_epoch(&group).unwrap(), epoch + 1, "applied at once");
        // Alice wakes up and applies it; so does the old phone (if it's on).
        assert!(matches!(alice.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        assert_eq!(alice.group_device_keys(&group, &bob_id).unwrap().len(), 2);
        assert_eq!(alice.group_epoch(&group).unwrap(), bob_new.group_epoch(&group).unwrap());

        let m = alice.encrypt(&group, b"you're back").unwrap();
        assert!(matches!(bob_new.decrypt(&group, &m).unwrap(), IncomingMessage::App(ref b) if b == b"you're back"));
        let r = bob_new.encrypt(&group, b"yes, new phone").unwrap();
        let (_, sender) = alice.decrypt_with_sender(&group, &r).unwrap();
        assert_eq!(sender.unwrap(), bob_id.to_vec());

        // The lost phone goes (Bob cut it off): one Commit from the new phone.
        let gone = bob_new.remove_devices_pending(&group, &[bob_old.device_public_key()]).unwrap();
        bob_new.confirm_commit(&group).unwrap();
        assert!(matches!(alice.decrypt(&group, &gone.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        assert_eq!(alice.group_device_keys(&group, &bob_id).unwrap(), vec![bob_new.device_public_key()]);
        let after = alice.encrypt(&group, b"the old phone can't read this").unwrap();
        assert!(bob_old.decrypt(&group, &after).map(|m| !matches!(m, IncomingMessage::App(_))).unwrap_or(true));

        // Carol forging her own join: Alice refuses it (a misbehaving server
        // would have to pass it on). Her card-join from an older card: she
        // can't even make one — so build it as if she could, from the card.
        let (fresh_epoch, fresh) = alice.group_card(&group).unwrap();
        let carol_join = {
            use tls_codec::Deserialize;
            let msg = MlsMessageIn::tls_deserialize_exact(&fresh).unwrap();
            let MlsMessageBodyIn::GroupInfo(info) = msg.extract() else { panic!("card") };
            let (_, bundle) = MlsGroup::external_commit_builder()
                .with_config(crate::group::join_config())
                .build_group(&carol.provider, info, carol.identity.credential.clone())
                .unwrap()
                .load_psks(carol.provider.storage())
                .unwrap()
                .build(carol.provider.rand(), carol.provider.crypto(), &carol.identity.signer, |_| true)
                .unwrap()
                .finalize(&carol.provider)
                .unwrap();
            bundle.into_contents().0.tls_serialize_detached().unwrap()
        };
        assert!(matches!(alice.decrypt(&group, &carol_join).unwrap(), IncomingMessage::Other), "refused");
        assert_eq!(alice.group_epoch(&group).unwrap(), fresh_epoch, "nothing applied");
        assert_eq!(alice.group_member_identities(&group).unwrap().len(), 2, "still Alice and Bob");
    }

    /// ADR-055 — "Saved messages": a group of only my own devices. It
    /// starts with this device alone, a newly linked device is added the
    /// device-sync way (pending Commit, Welcome), notes reach every device
    /// as mine, and a later device can be added by any of them.
    #[test]
    fn saved_messages_group_of_own_devices() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mk = |phrase: &str, device_seed| {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
        };
        let mut phone = mk(ALICE, None);
        let mut laptop = mk(ALICE, Some([42u8; 32]));
        let mut tablet = mk(ALICE, Some([7u8; 32]));
        let mut bob = mk("legal winner thank year wave sausage worth useful legal winner thank yellow", None);
        let me = phone.identity_pubkey_hex();

        let saved = phone.create_group().unwrap();
        assert!(phone.is_own_devices_group(&saved).unwrap(), "just me");
        assert_eq!(phone.group_member_identities(&saved).unwrap(), vec![hex::decode(&me).unwrap()]);

        // The laptop gets linked: device sync adds it (Commit held until the
        // server orders it), the Welcome brings it in.
        let pending = phone.invite_devices_pending(&saved, &[laptop.create_keypackage().unwrap()]).unwrap();
        phone.confirm_commit(&saved).unwrap();
        laptop.join_via_welcome(pending.welcome_bytes.as_ref().unwrap()).unwrap();
        for d in [&mut phone, &mut laptop] {
            assert!(d.is_own_devices_group(&saved).unwrap(), "still only me");
        }
        let alice_id: [u8; 32] = hex::decode(&me).unwrap().try_into().unwrap();
        assert_eq!(phone.group_device_keys(&saved, &alice_id).unwrap().len(), 2);

        // The marker that tells the laptop which chat this is (even empty).
        let marker = phone
            .encrypt(&saved, &crate::envelope::encode_history(vec![], "Saved messages", false, true))
            .unwrap();
        let (msg, sender) = laptop.decrypt_with_sender(&saved, &marker).unwrap();
        let IncomingMessage::App(bytes) = msg else { panic!("not an app message") };
        assert!(matches!(
            crate::envelope::decode_message(&bytes).unwrap().decoded,
            crate::envelope::Decoded::History { saved: true, .. }
        ));
        assert_eq!(hex::encode(sender.unwrap()), me, "from myself");

        // A note on the phone reaches the laptop as mine.
        let note = phone.encrypt(&saved, b"buy milk").unwrap();
        let (msg, sender) = laptop.decrypt_with_sender(&saved, &note).unwrap();
        assert!(matches!(msg, IncomingMessage::App(ref b) if b == b"buy milk"));
        assert_eq!(hex::encode(sender.unwrap()), me);

        // A third device, added from the laptop this time: everyone moves on.
        let pending = laptop.invite_devices_pending(&saved, &[tablet.create_keypackage().unwrap()]).unwrap();
        laptop.confirm_commit(&saved).unwrap();
        assert!(matches!(phone.decrypt(&saved, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        tablet.join_via_welcome(pending.welcome_bytes.as_ref().unwrap()).unwrap();
        assert!(tablet.is_own_devices_group(&saved).unwrap());
        assert_eq!(tablet.group_device_keys(&saved, &alice_id).unwrap().len(), 3);
        let note = tablet.encrypt(&saved, b"from the tablet").unwrap();
        for d in [&mut phone, &mut laptop] {
            let (msg, sender) = d.decrypt_with_sender(&saved, &note).unwrap();
            assert!(matches!(msg, IncomingMessage::App(ref b) if b == b"from the tablet"));
            assert_eq!(hex::encode(sender.unwrap()), me);
        }

        // A chat with someone else is never "only me".
        let chat = phone.create_group().unwrap();
        let add = phone.invite_to_group(&chat, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        assert!(!phone.is_own_devices_group(&chat).unwrap());
        assert!(!bob.is_own_devices_group(&chat).unwrap());
    }

    /// ADR-023 — Alice seals a message for Bob's delivery key; only Bob
    /// opens it, gets the group, the plaintext and Alice's identity back
    /// from one call, and an envelope for last week's key still opens.
    #[test]
    fn sealed_message_round_trip() {
        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".into(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: "legal winner thank year wave sausage worth useful legal winner thank yellow".into(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let group = alice.create_group().unwrap();
        let add = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();

        let now = 1_760_000_000u64;
        let bob_keys = bob.delivery_keys_to_publish(now).unwrap();
        assert_eq!(bob_keys.len(), 2);
        let mls = alice.encrypt(&group, b"sealed hello").unwrap();
        let sealed = alice.seal_for(&group, &mls, &[bob_keys[0].public.clone()]).unwrap();
        let (key_id, envelope) = &sealed[0];
        assert_eq!(key_id, &bob_keys[0].key_id);

        // A week later Bob still opens it.
        let (g, msg, sender) = bob.open_sealed(key_id, envelope, now + crate::sealed::WEEK_SECS).unwrap();
        assert_eq!(g, group);
        assert!(matches!(msg, IncomingMessage::App(ref m) if m == b"sealed hello"));
        assert_eq!(hex::encode(sender.unwrap()), alice.identity_pubkey_hex());

        // Alice's own keys don't open it; too old a week doesn't either.
        assert!(alice.open_sealed(key_id, envelope, now).is_err());
        let mls2 = alice.encrypt(&group, b"x").unwrap();
        let sealed2 = alice.seal_for(&group, &mls2, &[bob_keys[0].public.clone()]).unwrap();
        assert!(bob.open_sealed(&sealed2[0].0, &sealed2[0].1, now + 60 * crate::sealed::WEEK_SECS).is_err());
    }

    /// Tech-debt 2.3 — Alice and Bob add a member to the same group at
    /// the same time. The "server" (first Commit for an epoch wins, as
    /// `ws::handle_submit` does with `commit_epoch`) accepts Alice's;
    /// Bob's is rejected, he discards it, applies Alice's Commit, and his
    /// retry lands in the next epoch. Everyone ends on one epoch and can
    /// still talk — the group doesn't fork.
    #[test]
    fn concurrent_commits_are_ordered_and_the_loser_retries() {
        fn client(phrase: &str) -> SyncClient {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed: None }).unwrap()
        }
        let mut alice = client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        let mut bob = client("legal winner thank year wave sausage worth useful legal winner thank yellow");
        let mut carol = client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above");
        // Bob's second device: only the admin adds new people (mls-identity:3).
        let mut dave = SyncClient::new(SyncClientConfig {
            phrase: "legal winner thank year wave sausage worth useful legal winner thank yellow".to_string(),
            db_path: None,
            device_seed: Some([9u8; 32]),
        })
        .unwrap();

        let group = alice.create_group().unwrap();
        let add_bob = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add_bob.welcome_bytes).unwrap();
        assert_eq!(alice.group_epoch(&group).unwrap(), bob.group_epoch(&group).unwrap());
        let start = alice.group_epoch(&group).unwrap();

        // Both prepare a Commit in the same epoch.
        let carol_kp = carol.create_keypackage().unwrap();
        let dave_kp = dave.create_keypackage().unwrap();
        let a = alice.invite_to_group_pending(&group, &carol_kp).unwrap();
        let b = bob.invite_to_group_pending(&group, &dave_kp).unwrap();
        assert_eq!((a.epoch, b.epoch), (start, start));
        assert_eq!(alice.group_epoch(&group).unwrap(), start, "pending = nothing applied yet");

        // Server orders: Alice first.
        let mut server_epoch = start;
        let mut accept = |epoch: u64| {
            if epoch >= server_epoch {
                server_epoch = epoch + 1;
                true
            } else {
                false
            }
        };
        assert!(accept(a.epoch));
        assert!(!accept(b.epoch), "the second Commit for an epoch is refused");

        assert_eq!(alice.confirm_commit(&group).unwrap(), start + 1);
        carol.join_via_welcome(a.welcome_bytes.as_ref().unwrap()).unwrap();

        // Bob lost: discard, apply the winner, retry.
        bob.discard_commit(&group).unwrap();
        assert!(matches!(bob.decrypt(&group, &a.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        let retry = bob.invite_to_group_pending(&group, &dave_kp).unwrap();
        assert_eq!(retry.epoch, start + 1);
        assert!(accept(retry.epoch));
        assert_eq!(bob.confirm_commit(&group).unwrap(), start + 2);
        dave.join_via_welcome(retry.welcome_bytes.as_ref().unwrap()).unwrap();
        assert!(matches!(alice.decrypt(&group, &retry.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        assert!(matches!(carol.decrypt(&group, &retry.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));

        // One epoch for all four, and messages flow.
        for c in [&mut alice, &mut bob, &mut carol, &mut dave] {
            assert_eq!(c.group_epoch(&group).unwrap(), start + 2);
        }
        let ct = dave.encrypt(&group, b"hi all").unwrap();
        for c in [&mut alice, &mut bob, &mut carol] {
            match c.decrypt(&group, &ct).unwrap() {
                IncomingMessage::App(m) => assert_eq!(m, b"hi all"),
                other => panic!("{other:?}"),
            }
        }
    }

    /// ADR-092 (server-ws:2 variant B) — Mallory, a member with a modified
    /// app, sends a Commit nobody honest takes (she adds Carol, and isn't the
    /// admin — mls-identity:3), then garbage for her own next epoch. The server can't read
    /// them and fans both out. Alice and Bob refuse them and stay; Alice's
    /// Commit (removing Mallory) names what she saw, so the server — modelled
    /// here as `ws::handle_submit` does it — takes it, though Mallory's came
    /// first. Bob applies it, they talk and commit on; Mallory gains nothing.
    #[test]
    fn a_members_garbage_commit_does_not_freeze_the_chat() {
        use crate::commit_order::CommitLog;
        fn client(phrase: &str) -> SyncClient {
            SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed: None }).unwrap()
        }
        let mut alice = client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about");
        let mut bob = client("legal winner thank year wave sausage worth useful legal winner thank yellow");
        let mut mallory = client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above");
        let carol = client("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong");
        let group = alice.create_group().unwrap();
        let add_bob = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add_bob.welcome_bytes).unwrap();
        let add_mallory = alice.invite_to_group(&group, &mallory.create_keypackage().unwrap()).unwrap();
        assert!(matches!(bob.decrypt(&group, &add_mallory.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        mallory.join_via_welcome(&add_mallory.welcome_bytes).unwrap();
        let start = alice.group_epoch(&group).unwrap();

        // The server's rule (ADR-092): a Commit for epoch E is taken only if
        // every Commit it holds for E after the sender's parent is among the
        // ones the sender refused, and the sender has none there yet.
        let mut held: Vec<(u64, String, &str)> = Vec::new();
        let mut submit = |epoch: u64, id: &str, device: &'static str, (parent, refused): (String, Vec<String>)| {
            let after = held.iter().position(|(_, i, _)| *i == parent).map_or(0, |p| p + 1);
            let ok = !held.iter().any(|(e, _, d)| *e == epoch && *d == device)
                && held[after..].iter().filter(|(e, _, _)| *e == epoch).all(|(_, i, _)| refused.contains(i));
            if ok {
                held.push((epoch, id.to_string(), device));
            }
            ok
        };
        // What the app does with each delivered frame (`push_event`).
        let deliver = |c: &mut SyncClient, log: &mut CommitLog, id: &str, bytes: &[u8]| {
            let at = crate::group::commit_epoch(bytes).expect("a Commit");
            match c.decrypt(&group, bytes) {
                Ok(IncomingMessage::Commit { new_epoch, .. }) => {
                    log.moved("g", new_epoch, id);
                    true
                }
                _ => {
                    let mine = c.group_epoch(&group).unwrap();
                    log.refused("g", id, at, mine);
                    false
                }
            }
        };
        let (mut alice_log, mut bob_log, mut mallory_log) = (CommitLog::default(), CommitLog::default(), CommitLog::default());

        // Mallory's modified app adds Carol (her app's own check skipped):
        // first Commit of the epoch, so it goes out.
        let carol_kp = parse_keypackage_in(&carol.create_keypackage().unwrap()).unwrap();
        let sneak = mallory
            .with_group_mut(&group, |provider, me, handle| {
                let kp = carol_kp.validate(provider.crypto(), ProtocolVersion::Mls10).unwrap();
                let bundle = handle
                    .group
                    .commit_builder()
                    .propose_adds(vec![kp])
                    .load_psks(provider.storage())
                    .unwrap()
                    .build(provider.rand(), provider.crypto(), &me.signer, |_| true)
                    .unwrap()
                    .stage_commit(provider)
                    .unwrap();
                Ok(bundle.into_commit().tls_serialize_detached().unwrap())
            })
            .unwrap();
        assert!(submit(start, "sneak", "mallory", mallory_log.for_commit("g", start)));
        mallory.confirm_commit(&group).unwrap();
        mallory_log.moved("g", start + 1, "sneak");
        // Then garbage for her next epoch: a Commit's header, junk behind it.
        let mut garbage = mallory.self_update_pending(&group).unwrap().commit_bytes;
        garbage.truncate(garbage.len() / 2);
        assert!(submit(start + 1, "garbage", "mallory", mallory_log.for_commit("g", start + 1)));
        for (c, log) in [(&mut alice, &mut alice_log), (&mut bob, &mut bob_log)] {
            assert!(!deliver(c, log, "sneak", &sneak), "not the admin: refused");
            assert!(!deliver(c, log, "garbage", &garbage), "not for this epoch: dropped");
            assert_eq!(c.group_epoch(&group).unwrap(), start, "still at the chat's epoch");
            assert!(log.needs_heal("g"));
        }

        // Bob hasn't said what he saw → waits; Alice has → her Commit goes through.
        let mallory_id: [u8; 32] = hex::decode(mallory.identity_pubkey_hex()).unwrap().try_into().unwrap();
        assert!(!submit(start, "early", "bob", (String::new(), Vec::new())));
        let remove = alice.remove_people_pending(&group, &[mallory_id]).unwrap();
        assert_eq!(remove.epoch, start);
        assert!(submit(start, "remove", "alice", alice_log.for_commit("g", start)), "the chat isn't frozen");
        alice.confirm_commit(&group).unwrap();
        alice_log.moved("g", start + 1, "remove");
        assert!(deliver(&mut bob, &mut bob_log, "remove", &remove.commit_bytes), "Bob applies it");
        assert!(!bob_log.needs_heal("g"));

        // They talk, and the next Commit goes through too (Mallory's garbage
        // for this epoch came before its parent: it doesn't count).
        let ct = alice.encrypt(&group, b"still here").unwrap();
        assert!(matches!(bob.decrypt(&group, &ct).unwrap(), IncomingMessage::App(m) if m == b"still here"));
        let ct = bob.encrypt(&group, b"me too").unwrap();
        assert!(matches!(alice.decrypt(&group, &ct).unwrap(), IncomingMessage::App(m) if m == b"me too"));
        let next = bob.self_update_pending(&group).unwrap();
        assert!(submit(start + 1, "next", "bob", bob_log.for_commit("g", start + 1)));
        bob.confirm_commit(&group).unwrap();
        assert!(deliver(&mut alice, &mut alice_log, "next", &next.commit_bytes));
        assert_eq!(alice.group_epoch(&group).unwrap(), start + 2);

        // Mallory gains nothing: out of the chat, her words reach no one,
        // she reads nothing.
        let hers = mallory.encrypt(&group, b"hello?").unwrap();
        assert!(!matches!(alice.decrypt(&group, &hers), Ok(IncomingMessage::App(_))));
        let ct = alice.encrypt(&group, b"bye").unwrap();
        assert!(!matches!(mallory.decrypt(&group, &ct), Ok(IncomingMessage::App(_))));
        assert_eq!(alice.group_member_identities(&group).unwrap().len(), 2);
    }

    /// End-to-end: Alice creates group + invites Bob via his KeyPackage;
    /// Alice encrypts "hello" → Bob decrypts. Pure in-process test —
    /// validates the SyncClient surface independently of WS transport.
    #[test]
    fn alice_invites_bob_and_sends_message() {
        // Two clients with distinct identities (different phrases).
        let phrase_a = "abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon art"
            .to_string();
        let phrase_b = "legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth title"
            .to_string();

        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: phrase_a,
            db_path: None,
            device_seed: None,
        })
        .expect("alice");
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: phrase_b,
            db_path: None,
            device_seed: None,
        })
        .expect("bob");

        // Bob publishes a KeyPackage.
        let bob_kp = bob.create_keypackage().expect("bob kp");

        // Alice creates group + invites bob.
        let group_id = alice.create_group().expect("create group");
        let outcome = alice
            .invite_to_group(&group_id, &bob_kp)
            .expect("invite bob");

        // Bob joins via the Welcome.
        let bob_group_id = bob
            .join_via_welcome(&outcome.welcome_bytes)
            .expect("bob join");
        assert_eq!(bob_group_id, group_id, "group ids must match");

        // Alice encrypts a message; Bob decrypts.
        let ciphertext = alice
            .encrypt(&group_id, b"hello sinhron")
            .expect("alice encrypt");
        // base64 the ciphertext to prove it's not the plaintext.
        let _readable = BASE64_STANDARD.encode(&ciphertext);

        let decoded = bob.decrypt(&group_id, &ciphertext).expect("bob decrypt");
        match decoded {
            IncomingMessage::App(bytes) => {
                assert_eq!(bytes, b"hello sinhron");
            }
            other => panic!("expected App, got {other:?}"),
        }
    }

    /// Threat-model limitation #5: ciphertext length must not reveal
    /// plaintext length. With MLS padding a 1-byte and a 300-byte
    /// message land in the same PADDING_SIZE bucket, a longer one in a
    /// bigger bucket, and the receiver gets the exact plaintext back
    /// (padding stripped) — for both the creator and the Welcome joiner.
    #[test]
    fn app_message_ciphertext_hides_plaintext_length() {
        let phrase_a = "abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon art"
            .to_string();
        let phrase_b = "legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth title"
            .to_string();
        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: phrase_a,
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: phrase_b,
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let bob_kp = bob.create_keypackage().unwrap();
        let group_id = alice.create_group().unwrap();
        let outcome = alice.invite_to_group(&group_id, &bob_kp).unwrap();
        bob.join_via_welcome(&outcome.welcome_bytes).unwrap();

        let short = b"x".to_vec();
        let medium = vec![b'm'; 300];
        let long = vec![b'l'; 2 * crate::group::PADDING_SIZE];

        let ct_short = alice.encrypt(&group_id, &short).unwrap();
        let ct_medium = alice.encrypt(&group_id, &medium).unwrap();
        let ct_long = alice.encrypt(&group_id, &long).unwrap();
        assert_eq!(ct_short.len(), ct_medium.len(), "same bucket, same size");
        assert!(ct_long.len() > ct_medium.len(), "longer text, bigger bucket");

        for (ct, pt) in [(&ct_short, &short), (&ct_medium, &medium), (&ct_long, &long)] {
            match bob.decrypt(&group_id, ct).unwrap() {
                IncomingMessage::App(bytes) => assert_eq!(&bytes, pt),
                other => panic!("expected App, got {other:?}"),
            }
        }

        // Joiner's outgoing messages are padded too.
        let bob_short = bob.encrypt(&group_id, &short).unwrap();
        let bob_medium = bob.encrypt(&group_id, &medium).unwrap();
        assert_eq!(bob_short.len(), bob_medium.len());
    }

    /// ADR-019 — the receiver learns who sent an app message (the MLS-
    /// authenticated identity key), which gates edits and deletes.
    #[test]
    fn decrypt_reports_authenticated_sender() {
        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: "abandon abandon abandon abandon abandon abandon abandon abandon \
                     abandon abandon abandon abandon abandon abandon abandon abandon \
                     abandon abandon abandon abandon abandon abandon abandon art"
                .to_string(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: "legal winner thank year wave sausage worth useful legal winner thank year \
                     wave sausage worth useful legal winner thank year wave sausage worth title"
                .to_string(),
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let bob_kp = bob.create_keypackage().unwrap();
        let group_id = alice.create_group().unwrap();
        let outcome = alice.invite_to_group(&group_id, &bob_kp).unwrap();
        bob.join_via_welcome(&outcome.welcome_bytes).unwrap();

        let ct = alice.encrypt(&group_id, b"hi").unwrap();
        let (msg, sender) = bob.decrypt_with_sender(&group_id, &ct).unwrap();
        assert!(matches!(msg, IncomingMessage::App(ref b) if b == b"hi"));
        assert_eq!(hex::encode(sender.unwrap()), alice.identity_pubkey_hex());

        let back = bob.encrypt(&group_id, b"yo").unwrap();
        let (_, sender) = alice.decrypt_with_sender(&group_id, &back).unwrap();
        assert_eq!(hex::encode(sender.unwrap()), bob.identity_pubkey_hex());

        // Both see the same two members — the input to safety numbers.
        let mut a_view: Vec<String> = alice.group_member_identities(&group_id).unwrap().iter().map(hex::encode).collect();
        let mut b_view: Vec<String> = bob.group_member_identities(&group_id).unwrap().iter().map(hex::encode).collect();
        a_view.sort();
        b_view.sort();
        assert_eq!(a_view, b_view);
        assert!(a_view.contains(&alice.identity_pubkey_hex()) && a_view.contains(&bob.identity_pubkey_hex()));
    }

    /// CC3 regression — MLS-Exporter binding (RFC 9420 §8.5, spec §10.3).
    ///
    /// Critical property: both members of an MLS group, at the same
    /// epoch, derive **identical** bytes from `group_exporter` for the
    /// same (label, context, length). This is what makes SFrame key
    /// derivation work cross-party without a shared secret transmitted
    /// out-of-band.
    ///
    /// Also verifies that:
    ///   • Different labels produce different bytes (domain separation).
    ///   • Each side reports its own leaf index correctly.
    ///   • Epoch is consistent across both members after the Welcome.
    #[test]
    fn alice_and_bob_derive_identical_mls_exporter_output() {
        let phrase_a = "abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon art"
            .to_string();
        let phrase_b = "legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth title"
            .to_string();
        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: phrase_a,
            db_path: None,
            device_seed: None,
        })
        .unwrap();
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: phrase_b,
            db_path: None,
            device_seed: None,
        })
        .unwrap();

        let bob_kp = bob.create_keypackage().unwrap();
        let group_id = alice.create_group().unwrap();
        let outcome = alice.invite_to_group(&group_id, &bob_kp).unwrap();
        bob.join_via_welcome(&outcome.welcome_bytes).unwrap();

        // Both sides at the same epoch derive identical bytes from the
        // exporter for the SAME inputs. This is the property spec §10.3
        // relies on to make SFrame keys come out equal cross-party.
        let label = "SFrame 1.0 Base Key";
        let alice_export = alice
            .group_exporter(&group_id, label, b"", 32)
            .expect("alice exporter");
        let bob_export = bob
            .group_exporter(&group_id, label, b"", 32)
            .expect("bob exporter");
        assert_eq!(
            alice_export.len(),
            32,
            "exporter returns the requested length",
        );
        assert_eq!(
            alice_export, bob_export,
            "alice and bob MUST derive identical exporter bytes",
        );

        // Different label → different output (domain separation).
        let other_export = alice
            .group_exporter(&group_id, "different label", b"", 32)
            .unwrap();
        assert_ne!(
            other_export, alice_export,
            "label MUST domain-separate exporter output",
        );

        // Different context → different output.
        let with_ctx = alice
            .group_exporter(&group_id, label, b"call-1", 32)
            .unwrap();
        assert_ne!(
            with_ctx, alice_export,
            "context MUST domain-separate exporter output",
        );

        // Leaf indices: alice == 0 (creator), bob == 1 (first invitee).
        // These are the values that feed sframe::sender_base_key as
        // `sender_index`.
        let alice_leaf = alice.group_own_leaf_index(&group_id).unwrap();
        let bob_leaf = bob.group_own_leaf_index(&group_id).unwrap();
        assert_eq!(alice_leaf, 0, "creator gets leaf 0");
        assert_eq!(bob_leaf, 1, "first invitee gets leaf 1");

        // Same epoch on both sides post-Welcome (alice committed the add,
        // bob applied the same commit while joining).
        let alice_epoch = alice.group_epoch(&group_id).unwrap();
        let bob_epoch = bob.group_epoch(&group_id).unwrap();
        assert_eq!(alice_epoch, bob_epoch, "epochs MUST match across members");

        // Pick a key length common to AES-128 SFrame so we can confirm
        // the 16-byte path works too (sframe_epoch_secret uses Nk).
        let alice_export_16 = alice
            .group_exporter(&group_id, label, b"", 16)
            .unwrap();
        let bob_export_16 = bob.group_exporter(&group_id, label, b"", 16).unwrap();
        assert_eq!(alice_export_16, bob_export_16);
        assert_eq!(alice_export_16.len(), 16);
        // 16-byte and 32-byte outputs aren't simple prefixes of one
        // another — exporter derives by (label, context, length) tuple.
        assert_ne!(
            &alice_export[..16],
            &alice_export_16[..],
            "different length MUST produce different bytes",
        );
    }

    /// THE REGRESSION TEST FOR WU C6. Without disk-backed MLS state
    /// this would panic ("group not found") on the second SyncClient
    /// construction. With `openmls_sqlite_storage` wired in, group
    /// state must survive client drop + re-open from the same DB path.
    ///
    /// Flow:
    ///   1. Alice creates a fresh DB file.
    ///   2. Alice creates a group + invites Bob (in-memory).
    ///   3. Bob joins via the Welcome on his OWN db.
    ///   4. Alice sends one MLS-encrypted message ("first") through
    ///      her group — proves the group is alive.
    ///   5. **Drop** alice's SyncClient.
    ///   6. Re-open `SyncClient` from the same db_path.
    ///   7. Send another message ("second") via the SAME group_id.
    ///   8. Bob decrypts both messages — they must be in-order
    ///      plaintext "first" then "second", proving Alice's ratchet
    ///      survived the restart.
    #[test]
    fn mls_state_survives_client_restart() {
        let phrase_a = "abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon art"
            .to_string();
        let phrase_b = "legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth title"
            .to_string();

        let alice_db = tempdir_in_tmp().join("alice.sqlite");
        let bob_db = tempdir_in_tmp().join("bob.sqlite");

        // Bob's KP — created once on disk so the encryption key pair
        // also persists. Real Bob would publish via HTTP; for the unit
        // test we hand it over directly.
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: phrase_b.clone(),
            db_path: Some(bob_db.clone()),
            device_seed: None,
        })
        .expect("bob v1");
        let bob_kp = bob.create_keypackage().expect("bob kp");

        // Group_id + welcome captured before alice's session ends.
        let group_id;
        let first_ciphertext;
        let welcome_bytes;
        {
            let mut alice = SyncClient::new(SyncClientConfig {
                phrase: phrase_a.clone(),
                db_path: Some(alice_db.clone()),
                device_seed: None,
            })
            .expect("alice v1");
            group_id = alice.create_group().expect("create group");
            let outcome = alice
                .invite_to_group(&group_id, &bob_kp)
                .expect("invite bob");
            welcome_bytes = outcome.welcome_bytes;
            first_ciphertext = alice
                .encrypt(&group_id, b"first")
                .expect("alice encrypt #1");
            // Explicit drop for clarity — though the scope guard
            // would do the same.
            drop(alice);
        }

        // Bob processes Welcome + first message.
        let joined = bob
            .join_via_welcome(&welcome_bytes)
            .expect("bob join welcome");
        assert_eq!(joined, group_id, "group ids match across the welcome");
        match bob
            .decrypt(&group_id, &first_ciphertext)
            .expect("bob decrypt #1")
        {
            IncomingMessage::App(bytes) => assert_eq!(bytes, b"first"),
            other => panic!("expected App(first), got {other:?}"),
        }

        // *** restart Alice from the same SQLite db_path ***
        let mut alice2 = SyncClient::new(SyncClientConfig {
            phrase: phrase_a.clone(),
            db_path: Some(alice_db.clone()),
            device_seed: None,
        })
        .expect("alice v2 — reopen");

        // The in-memory `groups` map is empty here; the encrypt call
        // forces a lazy re-hydrate via `GroupHandle::try_load`. If C6
        // is broken (in-memory storage), this errors with UnknownGroup.
        let second_ciphertext = alice2
            .encrypt(&group_id, b"second")
            .expect("alice v2 encrypt #2 — state must survive restart");

        // Bob must still be able to decrypt — same group, advanced
        // ratchet on alice's side.
        match bob
            .decrypt(&group_id, &second_ciphertext)
            .expect("bob decrypt #2")
        {
            IncomingMessage::App(bytes) => assert_eq!(bytes, b"second"),
            other => panic!("expected App(second), got {other:?}"),
        }
    }

    /// WU C5 regression: a stale-epoch frame must surface as
    /// `IncomingMessage::StaleEpoch { my_epoch }` instead of bubbling
    /// up as an opaque `GroupError::Process(...)` (the pre-C5
    /// behavior, which left chats wedged after any concurrent Commit).
    ///
    /// Flow:
    ///   1. Alice creates a group, Bob joins via Welcome — both at
    ///      epoch 1 (epoch 0 → 1 happens on the Add Commit Alice
    ///      merges).
    ///   2. Bob encrypts "stale" at epoch 1.
    ///   3. Alice locally `invite_to_group`s a fresh KP (Carol's),
    ///      which advances HER to epoch 2 — but we never deliver that
    ///      Commit to Bob. Now Alice is at epoch 2, Bob is at epoch 1.
    ///   4. Alice tries to decrypt Bob's epoch-1 "stale" message → the
    ///      message's wire epoch (1) != Alice's epoch (2). Pre-C5
    ///      this returned `GroupError::Process(...)`; now it returns
    ///      `IncomingMessage::StaleEpoch { my_epoch: 2 }`.
    #[test]
    fn stale_epoch_frame_surfaces_as_typed_variant() {
        let phrase_a = "abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon abandon art"
            .to_string();
        let phrase_b = "legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth useful \
                        legal winner thank year wave sausage worth title"
            .to_string();
        // A third phrase for Carol — needed for the epoch-advancing Add.
        // BIP-39 valid 24-word sequence (the all-`zoo` one with a real
        // checksum at the end).
        let phrase_c = "zoo zoo zoo zoo zoo zoo zoo zoo \
                        zoo zoo zoo zoo zoo zoo zoo zoo \
                        zoo zoo zoo zoo zoo zoo zoo vote"
            .to_string();

        let mut alice = SyncClient::new(SyncClientConfig {
            phrase: phrase_a,
            db_path: None,
            device_seed: None,
        })
        .expect("alice");
        let mut bob = SyncClient::new(SyncClientConfig {
            phrase: phrase_b,
            db_path: None,
            device_seed: None,
        })
        .expect("bob");
        let carol = SyncClient::new(SyncClientConfig {
            phrase: phrase_c,
            db_path: None,
            device_seed: None,
        })
        .expect("carol");

        let bob_kp = bob.create_keypackage().expect("bob kp");
        let carol_kp = carol.create_keypackage().expect("carol kp");

        let group_id = alice.create_group().expect("create");
        let invite_out = alice.invite_to_group(&group_id, &bob_kp).expect("invite bob");
        bob.join_via_welcome(&invite_out.welcome_bytes).expect("bob join");

        // Bob encrypts at his current epoch (1).
        let stale_ct = bob.encrypt(&group_id, b"stale").expect("bob encrypt");

        // Alice advances HER epoch past the window of kept past epochs
        // (MAX_PAST_EPOCHS — a frame only one or two epochs old still
        // decrypts, see `message_from_the_previous_epoch_still_decrypts`)
        // by adding Carol's devices — Bob is not given these Commits.
        let _ = alice
            .invite_to_group(&group_id, &carol_kp)
            .expect("alice invite carol");
        for n in 0..crate::group::MAX_PAST_EPOCHS {
            // Carol's other devices (own keys — the same key twice is refused).
            let device = SyncClient::new(SyncClientConfig {
                phrase: "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote".into(),
                db_path: None,
                device_seed: Some([60 + n as u8; 32]),
            })
            .expect("carol device");
            let kp = device.create_keypackage().expect("carol device kp");
            let _ = alice.invite_to_group(&group_id, &kp).expect("alice invite carol device");
        }

        // Alice now tries to decrypt Bob's epoch-(her-old) frame at her
        // new epoch. Pre-C5 this panicked; now it surfaces as
        // StaleEpoch.
        let decoded = alice
            .decrypt(&group_id, &stale_ct)
            .expect("decrypt should NOT bubble — C5 swallows stale epoch");
        match decoded {
            IncomingMessage::StaleEpoch { my_epoch } => {
                // Alice is past the kept window after the Adds.
                assert_eq!(my_epoch as usize, 2 + crate::group::MAX_PAST_EPOCHS);
            }
            other => panic!(
                "expected IncomingMessage::StaleEpoch, got {other:?} — \
                 C5 stale-frame handling is regressed"
            ),
        }
    }

    // Security review 2026-11 (mls-identity:1, storage-devices:1,
    // mls-identity:6) — a leaf whose signature key isn't the one its
    // credential names (Bob's identity key or Bob's real certificate, but
    // the attacker's key) is nobody: never added, never "Bob", never "me".
    const BOB_PHRASE: &str = "legal winner thank year wave sausage worth useful legal winner thank yellow";
    fn mk_client(phrase: &str, device_seed: Option<[u8; 32]>) -> SyncClient {
        SyncClient::new(SyncClientConfig { phrase: phrase.to_string(), db_path: None, device_seed }).unwrap()
    }
    fn id_of(c: &SyncClient) -> [u8; 32] {
        hex::decode(c.identity_pubkey_hex()).unwrap().try_into().unwrap()
    }
    /// The attacker's provider, own signing key and a credential naming `who`.
    fn attacker(who: Vec<u8>) -> (openmls_rust_crypto::OpenMlsRustCrypto, openmls_basic_credential::SignatureKeyPair, CredentialWithKey) {
        let p = openmls_rust_crypto::OpenMlsRustCrypto::default();
        let mal = openmls_basic_credential::SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
        mal.store(p.storage()).unwrap();
        let cred = CredentialWithKey { credential: BasicCredential::new(who).into(), signature_key: mal.to_public_vec().into() };
        (p, mal, cred)
    }
    fn forged_kp(who: Vec<u8>) -> Vec<u8> {
        let (p, mal, cred) = attacker(who);
        KeyPackage::builder().build(CIPHERSUITE, &p, &mal, cred).unwrap().key_package().tls_serialize_detached().unwrap()
    }

    #[test]
    fn forged_bob_key_package_is_refused_by_every_add() {
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let bob_cert = mk_client(BOB_PHRASE, Some([5u8; 32])).device_certificate().unwrap();
        let group = alice.create_group().unwrap();
        for who in [bob.identity.identity_public.to_vec(), bob_cert] {
            let kp = forged_kp(who);
            assert!(alice.invite_to_group(&group, &kp).is_err());
            assert!(alice.invite_to_group_pending(&group, &kp).is_err());
            assert!(alice.invite_devices(&group, &[kp.clone()]).is_err());
            assert!(alice.invite_devices_pending(&group, &[kp]).is_err());
        }
        assert_eq!(alice.group_member_identities(&group).unwrap().len(), 1, "still only Alice");
        // With the real Bob in the chat, a forged "new phone of Bob's" is refused too.
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let fake = forged_kp(bob.identity.identity_public.to_vec());
        assert!(alice.invite_devices_of_pending(&group, &[(id_of(&bob), fake)]).is_err());
    }

    #[test]
    fn server_made_my_device_is_refused_by_device_sync() {
        const ME: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mut phone = mk_client(ME, None);
        let my_cert = mk_client(ME, Some([5u8; 32])).device_certificate().unwrap();
        let saved = phone.create_group().unwrap();
        for who in [phone.identity.identity_public.to_vec(), my_cert] {
            assert!(phone.invite_devices_of_pending(&saved, &[(id_of(&phone), forged_kp(who))]).is_err());
        }
        assert_eq!(phone.group_device_keys(&saved, &id_of(&phone)).unwrap().len(), 1, "only this phone");
        // A real linked device still goes in.
        let laptop = mk_client(ME, Some([6u8; 32]));
        assert!(phone.invite_devices_of_pending(&saved, &[(id_of(&phone), laptop.create_keypackage().unwrap())]).is_ok());
    }

    /// A forged Bob joining by the chat's card (external commit), and a
    /// malicious member committing a forged leaf: Alice applies neither.
    /// A forged leaf that got in anyway (Welcome from a malicious inviter)
    /// writes as nobody and isn't counted for safety numbers.
    #[test]
    fn forged_leaf_by_card_or_by_member_commit_is_refused() {
        use tls_codec::Deserialize;
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let carol = mk_client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above", None);
        let bob_cert = mk_client(BOB_PHRASE, Some([5u8; 32])).device_certificate().unwrap();
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let epoch = alice.group_epoch(&group).unwrap();

        let (_, card) = alice.group_card(&group).unwrap();
        let MlsMessageBodyIn::GroupInfo(info) = MlsMessageIn::tls_deserialize_exact(&card).unwrap().extract() else { panic!("card") };
        let (p, mal, cred) = attacker(bob_cert);
        let (_, bundle) = MlsGroup::external_commit_builder()
            .with_config(crate::group::join_config())
            .build_group(&p, info, cred)
            .unwrap()
            .load_psks(p.storage())
            .unwrap()
            .build(p.rand(), p.crypto(), &mal, |_| true)
            .unwrap()
            .finalize(&p)
            .unwrap();
        let join = bundle.into_contents().0.tls_serialize_detached().unwrap();
        assert!(matches!(alice.decrypt(&group, &join).unwrap(), IncomingMessage::Other), "forged card join refused");
        assert_eq!(alice.group_epoch(&group).unwrap(), epoch);

        // Bob (modified app) commits a leaf naming Carol, signed by his helper's key.
        let kp = parse_keypackage_in(&forged_kp(carol.identity.identity_public.to_vec())).unwrap();
        let kp = kp.validate(bob.provider.crypto(), ProtocolVersion::Mls10).unwrap();
        let h = bob.groups.get_mut(&group).unwrap();
        let (commit, _, _) = h.group.add_members(&bob.provider, &bob.identity.signer, &[kp]).unwrap();
        let commit = commit.tls_serialize_detached().unwrap();
        assert!(matches!(alice.decrypt(&group, &commit).unwrap(), IncomingMessage::Other), "forged add refused");
        assert_eq!(alice.group_epoch(&group).unwrap(), epoch);

        // Bob (modified app) invites Alice into his group with a forged
        // "Carol" leaf in it: the Welcome is refused.
        let carol_id = carol.identity.identity_public.to_vec();
        let mut welcome_with_fake = |alice: &SyncClient| {
            let (p, mal, cred) = attacker(carol_id.clone());
            let fake = KeyPackage::builder().build(CIPHERSUITE, &p, &mal, cred).unwrap().key_package().tls_serialize_detached().unwrap();
            let g = bob.create_group().unwrap();
            let kps = [fake, alice.create_keypackage().unwrap()]
                .map(|b| parse_keypackage_in(&b).unwrap().validate(bob.provider.crypto(), ProtocolVersion::Mls10).unwrap());
            let h = bob.groups.get_mut(&g).unwrap();
            let (_, welcome, _) = h.group.add_members(&bob.provider, &bob.identity.signer, &kps).unwrap();
            h.group.merge_pending_commit(&bob.provider).unwrap();
            (g, welcome.tls_serialize_detached().unwrap(), p, mal)
        };
        let (_, bytes, _, _) = welcome_with_fake(&alice);
        assert!(alice.join_via_welcome(&bytes).is_err(), "a chat with a forged leaf is refused");
        // Such a chat joined by an older app: the forged leaf writes as
        // nobody and isn't Carol for safety numbers.
        let (g2, bytes, p, mal) = welcome_with_fake(&alice);
        let w = || match MlsMessageIn::tls_deserialize_exact(&bytes).unwrap().extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => panic!("welcome"),
        };
        let cfg = crate::group::join_config();
        let group = StagedWelcome::new_from_welcome(&alice.provider, &cfg, w(), None).unwrap().into_group(&alice.provider).unwrap();
        alice.groups.insert(g2.clone(), GroupHandle { group_id: g2.clone(), group });
        let mut mallory = StagedWelcome::new_from_welcome(&p, &cfg, w(), None).unwrap().into_group(&p).unwrap();
        let msg = mallory.create_message(&p, &mal, b"I am Carol").unwrap().tls_serialize_detached().unwrap();
        let (_, sender) = alice.decrypt_with_sender(&g2, &msg).unwrap();
        assert_eq!(sender, None, "the forged leaf writes as nobody");
        assert!(!alice.group_member_identities(&g2).unwrap().contains(&carol_id));
    }

    /// mls-identity:6 — "Bob's key packages" from the server are Carol's
    /// (a real account of the operator's): refused before any Commit.
    #[tokio::test]
    async fn invite_bob_refuses_carols_key_package() {
        use std::io::{Read, Write};
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let bob = mk_client(BOB_PHRASE, None);
        let carol = mk_client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above", None);
        let ok = |body: String| format!("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len());
        let consume = format!(
            r#"[{{"keypackage_id":"x","device_pk_hex":"{}","kp_bytes_b64":"{}"}}]"#,
            hex::encode(carol.device_public_key()),
            BASE64_STANDARD.encode(carol.create_keypackage().unwrap())
        );
        let answers = vec!["HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_string(), ok(consume), ok("{}".into())];
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for (conn, answer) in listener.incoming().zip(answers) {
                let mut conn = conn.unwrap();
                let _ = conn.read(&mut [0u8; 8192]);
                let _ = conn.write_all(answer.as_bytes());
            }
        });
        let group = alice.create_group().unwrap();
        let http = crate::http_api::HttpApi::new(base);
        assert!(alice.fetch_kps_and_invite_people(&http, &group, &[bob.identity_pubkey_hex()]).await.is_err());
        assert_eq!(alice.group_member_identities(&group).unwrap().len(), 1, "Carol not added");
    }

    /// Security review 2026-11 (mls-identity:3) — a member's modified app
    /// adds a stranger while the admin is in the group: every phone refuses
    /// the Commit. The stock app doesn't even build it.
    #[test]
    fn a_member_cannot_slip_a_stranger_in_while_the_admin_is_there() {
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above", None);
        let dave = mk_client("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong", None);
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();
        let epoch = alice.group_epoch(&group).unwrap();

        assert!(carol.invite_devices_pending(&group, &[dave.create_keypackage().unwrap()]).is_err(), "stock app: not the admin");
        let kp = parse_keypackage_in(&dave.create_keypackage().unwrap()).unwrap();
        let kp = kp.validate(carol.provider.crypto(), ProtocolVersion::Mls10).unwrap();
        let h = carol.groups.get_mut(&group).unwrap();
        let (commit, _, _) = h.group.add_members(&carol.provider, &carol.identity.signer, &[kp]).unwrap();
        let commit = commit.tls_serialize_detached().unwrap();
        for m in [&mut alice, &mut bob] {
            assert!(matches!(m.decrypt(&group, &commit).unwrap(), IncomingMessage::Other), "Carol's add refused");
            assert_eq!(m.group_epoch(&group).unwrap(), epoch);
            assert_eq!(m.group_member_identities(&group).unwrap().len(), 3, "no Dave");
        }
    }

    /// mls-identity:3 — who came in and who left, with who did it: the
    /// admin's add, a removal by a member, an add by the new admin; a
    /// member adding another person's new device stays quiet (ADR-074).
    #[test]
    fn a_commit_names_who_added_or_removed_whom() {
        const CAROL: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client(CAROL, None);
        let carol_tablet = mk_client(CAROL, Some([3u8; 32]));
        let mut dave = mk_client("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong", None);
        let id = |c: &SyncClient| c.identity.identity_public;
        let (a, b, c, d) = (id(&alice), id(&bob), id(&carol), id(&dave));
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();

        let p = alice.invite_devices_pending(&group, &[carol.create_keypackage().unwrap()]).unwrap();
        alice.confirm_commit(&group).unwrap();
        carol.join_via_welcome(p.welcome_bytes.as_ref().unwrap()).unwrap();
        let (msg, by) = bob.decrypt_with_sender(&group, &p.commit_bytes).unwrap();
        assert!(matches!(msg, IncomingMessage::Commit { ref added, ref removed, .. } if *added == vec![c] && removed.is_empty()), "{msg:?}");
        assert_eq!(by, Some(a.to_vec()));

        let (p, _) = bob.invite_devices_of_pending(&group, &[(c, carol_tablet.create_keypackage().unwrap())]).unwrap();
        bob.confirm_commit(&group).unwrap();
        for m in [&mut alice, &mut carol] {
            let (msg, _) = m.decrypt_with_sender(&group, &p.commit_bytes).unwrap();
            assert!(matches!(msg, IncomingMessage::Commit { ref added, ref removed, .. } if added.is_empty() && removed.is_empty()), "{msg:?}");
        }

        let p = bob.remove_people_pending(&group, &[a]).unwrap();
        bob.confirm_commit(&group).unwrap();
        let (msg, by) = carol.decrypt_with_sender(&group, &p.commit_bytes).unwrap();
        assert!(matches!(msg, IncomingMessage::Commit { ref removed, .. } if *removed == vec![a]), "{msg:?}");
        assert_eq!(by, Some(b.to_vec()));

        // Bob is the admin now (ADR-088): he adds, and everyone sees who did.
        let p = bob.invite_devices_pending(&group, &[dave.create_keypackage().unwrap()]).unwrap();
        bob.confirm_commit(&group).unwrap();
        dave.join_via_welcome(p.welcome_bytes.as_ref().unwrap()).unwrap();
        let (msg, by) = carol.decrypt_with_sender(&group, &p.commit_bytes).unwrap();
        assert!(matches!(msg, IncomingMessage::Commit { ref added, .. } if *added == vec![d]), "{msg:?}");
        assert_eq!(by, Some(b.to_vec()));
    }

    // Security review 2026-11 (mls-identity:8) / ADR-088 — the admin is
    // recorded in the group's shared state, not read from leaf 0.
    const ALICE_PHRASE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const CAROL_PHRASE: &str = "letter advice cage absurd amount doctor acoustic avoid letter advice cage above";
    const DAVE_PHRASE: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";

    /// `who`'s modified app commits a group context naming `admin` (no other change).
    fn forged_record_commit(who: &mut SyncClient, group: &[u8], admin: &[u8; 32]) -> Vec<u8> {
        let h = who.groups.get_mut(group).unwrap();
        let mut ext = h.group.extensions().clone();
        ext.add_or_replace(crate::group::admin_record(admin)).unwrap();
        let bundle = h.group.commit_builder().propose_group_context_extensions(ext).unwrap()
            .load_psks(who.provider.storage()).unwrap()
            .build(who.provider.rand(), who.provider.crypto(), &who.identity.signer, |_| true).unwrap()
            .stage_commit(&who.provider).unwrap();
        h.group.clear_pending_commit(who.provider.storage()).unwrap();
        bundle.into_commit().tls_serialize_detached().unwrap()
    }

    /// The creator leaves; a newcomer lands on the creator's old leaf 0 and
    /// is still not the admin: the role went to the earliest remaining
    /// person, the same on every phone, and the others still can't add.
    #[test]
    fn a_newcomer_on_the_creators_old_leaf_is_not_the_admin() {
        let mut alice = mk_client(ALICE_PHRASE, None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client(CAROL_PHRASE, None);
        let mut dave = mk_client(DAVE_PHRASE, None);
        let (a, b) = (id_of(&alice), id_of(&bob));
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();

        let p = bob.remove_people_pending(&group, &[a]).unwrap(); // Alice left
        bob.confirm_commit(&group).unwrap();
        assert!(matches!(carol.decrypt(&group, &p.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        for m in [&mut bob, &mut carol] {
            assert_eq!(m.group_admin(&group).unwrap(), Some(b), "the role passed to Bob");
        }
        assert!(carol.invite_devices_pending(&group, &[dave.create_keypackage().unwrap()]).is_err(), "Carol can't add");

        let p = bob.invite_devices_pending(&group, &[dave.create_keypackage().unwrap()]).unwrap();
        bob.confirm_commit(&group).unwrap();
        assert!(matches!(carol.decrypt(&group, &p.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        dave.join_via_welcome(p.welcome_bytes.as_ref().unwrap()).unwrap();
        assert_eq!(dave.group_own_leaf_index(&group).unwrap(), 0, "Dave took the creator's old leaf");
        for m in [&mut bob, &mut carol, &mut dave] {
            assert_eq!(m.group_admin(&group).unwrap(), Some(b), "Bob, not the newcomer");
        }
    }

    /// The admin changes phone: the old one (leaf 0) is revoked, a newcomer
    /// lands on leaf 0 — the admin is still the same person.
    #[test]
    fn the_admin_keeps_the_role_after_changing_phone() {
        let mut old_phone = mk_client(ALICE_PHRASE, None);
        let mut new_phone = mk_client(ALICE_PHRASE, Some([7u8; 32]));
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut dave = mk_client(DAVE_PHRASE, None);
        let a = id_of(&old_phone);
        let group = old_phone.create_group().unwrap();
        let add = old_phone.invite_devices(&group, &[bob.create_keypackage().unwrap(), new_phone.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        new_phone.join_via_welcome(&add.welcome_bytes).unwrap();

        let commit = new_phone.remove_device(&group, &old_phone.device_public_key()).unwrap();
        assert!(matches!(bob.decrypt(&group, &commit).unwrap(), IncomingMessage::Commit { .. }));
        assert_eq!(bob.group_admin(&group).unwrap(), Some(a), "still Alice on her new phone");

        let p = new_phone.invite_devices_pending(&group, &[dave.create_keypackage().unwrap()]).unwrap();
        new_phone.confirm_commit(&group).unwrap();
        assert!(matches!(bob.decrypt(&group, &p.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        dave.join_via_welcome(p.welcome_bytes.as_ref().unwrap()).unwrap();
        assert_eq!(dave.group_own_leaf_index(&group).unwrap(), 0);
        for m in [&mut new_phone, &mut bob, &mut dave] {
            assert_eq!(m.group_admin(&group).unwrap(), Some(a), "Alice, not the newcomer");
        }
    }

    /// A member's modified app names itself admin, or removes the admin
    /// without passing the role on by the rule: every phone refuses it.
    #[test]
    fn a_member_cannot_make_itself_admin() {
        let mut alice = mk_client(ALICE_PHRASE, None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client(CAROL_PHRASE, None);
        let (a, c) = (id_of(&alice), id_of(&carol));
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();
        let epoch = alice.group_epoch(&group).unwrap();

        let me_admin = forged_record_commit(&mut carol, &group, &c);
        let h = carol.groups.get_mut(&group).unwrap();
        let (silent, _, _) = h.group.remove_members(&carol.provider, &carol.identity.signer, &[LeafNodeIndex::new(0)]).unwrap();
        h.group.clear_pending_commit(carol.provider.storage()).unwrap();
        let silent = silent.tls_serialize_detached().unwrap();
        for commit in [me_admin, silent] {
            for m in [&mut alice, &mut bob] {
                assert!(matches!(m.decrypt(&group, &commit).unwrap(), IncomingMessage::Other), "refused");
                assert_eq!(m.group_epoch(&group).unwrap(), epoch);
                assert_eq!(m.group_admin(&group).unwrap(), Some(a));
            }
        }
    }

    /// A chat made before the record (leaf 0 = the creator, as before):
    /// the creator stays admin, a member can't write itself in, and the
    /// next Commit writes the record every phone accepts.
    #[test]
    fn a_chat_from_before_the_record_keeps_its_admin_and_gets_the_record() {
        let mut alice = mk_client(ALICE_PHRASE, None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client(CAROL_PHRASE, None);
        let (a, b, c) = (id_of(&alice), id_of(&bob), id_of(&carol));
        let cfg = MlsGroupCreateConfig::builder().ciphersuite(CIPHERSUITE).use_ratchet_tree_extension(true).build();
        let mut g = MlsGroup::new(&alice.provider, &alice.identity.signer, &cfg, alice.identity.credential.clone()).unwrap();
        let kps: Vec<KeyPackage> = [bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()]
            .iter()
            .map(|b| parse_keypackage_in(b).unwrap().validate(alice.provider.crypto(), ProtocolVersion::Mls10).unwrap())
            .collect();
        let (_, welcome, _) = g.add_members(&alice.provider, &alice.identity.signer, &kps).unwrap();
        g.merge_pending_commit(&alice.provider).unwrap();
        assert!(g.extensions().external_senders().is_none(), "no record, like an old chat");
        let group = g.group_id().to_vec();
        alice.groups.insert(group.clone(), GroupHandle { group_id: group.clone(), group: g });
        let welcome = welcome.tls_serialize_detached().unwrap();
        bob.join_via_welcome(&welcome).unwrap();
        carol.join_via_welcome(&welcome).unwrap();
        for m in [&mut alice, &mut bob, &mut carol] {
            assert_eq!(m.group_admin(&group).unwrap(), Some(a), "the creator, as before");
        }

        let forged = forged_record_commit(&mut carol, &group, &c);
        for m in [&mut alice, &mut bob] {
            assert!(matches!(m.decrypt(&group, &forged).unwrap(), IncomingMessage::Other), "Carol can't write herself in");
        }

        let p = bob.remove_people_pending(&group, &[a]).unwrap(); // Alice left
        bob.confirm_commit(&group).unwrap();
        assert!(matches!(carol.decrypt(&group, &p.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        for m in [&mut bob, &mut carol] {
            assert_eq!(m.group_admin(&group).unwrap(), Some(b));
            let h = m.groups.get(&group).unwrap();
            assert_eq!(h.group.extensions().external_senders().map(|s| s.len()), Some(1), "record written");
        }
    }

    /// ADR-084 (status 238, audit mls-identity:2) — a disconnected linked
    /// device keeps its bundle, so it keeps the phrase's delivery root. After
    /// the disconnect the account publishes keys of a new generation it can't
    /// derive; a device that got that generation still matches, and an
    /// envelope sealed to the old key (a sender's cache) still opens. An
    /// account with no disconnect keeps generation 0: the same keys as before.
    #[test]
    fn a_disconnected_device_cannot_derive_the_delivery_keys_made_after_it() {
        use sinhron_crypto::identity::RootsGen;
        const WORDS: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let client = |phrase: String, device_seed| SyncClient::new(SyncClientConfig { phrase, db_path: None, device_seed }).unwrap();
        let bundle = |seed: u8| crate::identity::linked_bundle_from_phrase(WORDS, &[seed; 32]).unwrap();
        let now = 1_800_000_000;
        let keys = |c: &SyncClient| c.delivery_keys_to_publish(now).unwrap().into_iter().map(|k| k.public).collect::<Vec<_>>();
        let mut main = client(WORDS.into(), None);
        let stolen = client(bundle(5), Some([5; 32]));
        let mut ipad = client(bundle(6), Some([6; 32]));

        // Generation 0: the phrase's root, as before; every device the same.
        let id = sinhron_crypto::identity::derive_identity(WORDS).unwrap();
        let week = crate::sealed::week_of(now);
        let old_key = crate::sealed::delivery_key(main.provider.crypto(), &id.delivery_root, week).unwrap();
        assert_eq!(keys(&main)[0], old_key.public);
        assert_eq!(keys(&stolen), keys(&main));

        // The disconnect: a new generation from fresh bytes, to the iPad only.
        let roots = [RootsGen { gen: 1, secret: [0x77; 32] }];
        main.set_rotated_roots(&roots);
        ipad.set_rotated_roots(&roots);
        assert_ne!(keys(&stolen), keys(&main), "the stolen bundle no longer gives the published keys");
        assert_ne!(stolen.push_preview_secrets(now).unwrap()[..5], main.push_preview_secrets(now).unwrap()[..5]);
        assert_eq!(keys(&ipad), keys(&main));
        // What new devices get is still generation 0.
        assert_eq!(sinhron_crypto::identity::LinkedBundle::decode(&main.linked_bundle_for(&[9; 32]).unwrap()).unwrap().delivery_root, id.delivery_root);

        // A sender with the old key cached: the envelope still opens (MLS then
        // says "unknown group" here — the delivery key matched).
        let env = crate::sealed::seal(main.provider.crypto(), &old_key.public, b"g", b"mls").unwrap();
        let r = main.open_sealed(&old_key.key_id, &env, now);
        assert!(!matches!(r, Err(SyncError::Sealed(_))), "{:?}", r.err());
        assert!(main.push_preview_secrets(now).unwrap().contains(&old_key.secret_bytes().to_vec()));
    }

    fn tempdir_in_tmp() -> std::path::PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "sinhron-sync-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("mkdir tempdir");
        dir
    }

    // ── Security audit 2026-11b (01 crypto/MLS): the auditors' attack tests,
    // asserting the safe behaviour (ADR-100).
    #[test]
    fn audit_b_server_forged_card_reads_victim() {
        use tls_codec::{Deserialize, Serialize};
        // The victim: Bob, one device lost, restoring on a new phone (same
        // phrase -> same identity key). His OLD device's KeyPackage is what
        // the server holds unconsumed.
        let mut bob_new = mk_client(BOB_PHRASE, Some([9u8; 32]));
        let bob_old = mk_client(BOB_PHRASE, Some([3u8; 32]));
        let bob_id: [u8; 32] = id_of(&bob_new); // identity is per-person

        // The real chat id the server wants to impersonate.
        let chat_id = GroupId::from_slice(&[0x42u8; 32]);

        // --- The server builds ITS OWN MLS group with that id ---
        let srv = openmls_rust_crypto::OpenMlsRustCrypto::default();
        let srv_signer = openmls_basic_credential::SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).unwrap();
        srv_signer.store(srv.storage()).unwrap();
        // The server's own leaf credential — a raw 32-byte "identity" that is
        // just its signature key (names the server, not Bob).
        let srv_cred = CredentialWithKey {
            credential: BasicCredential::new(srv_signer.to_public_vec()).into(),
            signature_key: srv_signer.to_public_vec().into(),
        };
        let create_config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .max_past_epochs(crate::group::MAX_PAST_EPOCHS)
            .use_ratchet_tree_extension(true)
            .padding_size(crate::group::PADDING_SIZE)
            .build();
        let mut srv_group = MlsGroup::new_with_group_id(&srv, &srv_signer, &create_config, chat_id.clone(), srv_cred)
            .unwrap();

        // Seed the tree with Bob's OLD device KeyPackage (names Bob).
        let bob_kp = parse_keypackage_in(&bob_old.create_keypackage().unwrap())
            .unwrap()
            .validate(srv.crypto(), ProtocolVersion::Mls10)
            .unwrap();
        srv_group.add_members(&srv, &srv_signer, &[bob_kp]).unwrap();
        srv_group.merge_pending_commit(&srv).unwrap();

        // Export it as the "card" for the real chat.
        let gi = srv_group.export_group_info(srv.crypto(), &srv_signer, true).unwrap();
        let card = gi.tls_serialize_detached().unwrap();

        // --- The victim joins by that card ---
        // ADR-100 — refused: no device of Bob's signed this card.
        let Ok((gid, pending)) = bob_new.join_by_card(chat_id.as_slice(), &card) else {
            assert!(bob_new.group_epoch(chat_id.as_slice()).is_err(), "nothing is left behind");
            return;
        };
        assert_eq!(gid, chat_id.as_slice().to_vec(), "joined a group with the real chat id");

        // The server orders & applies the external commit on its own group.
        let commit_in = MlsMessageIn::tls_deserialize_exact(&pending.commit_bytes).unwrap();
        let proto = match commit_in.extract() {
            MlsMessageBodyIn::PrivateMessage(_) => panic!("external commit is public"),
            MlsMessageBodyIn::PublicMessage(m) => m,
            _ => panic!("unexpected external commit body"),
        };
        let processed = srv_group.process_message(&srv, proto).unwrap();
        match processed.into_content() {
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                srv_group.merge_staged_commit(&srv, *staged).unwrap();
            }
            _ => panic!("expected the external commit"),
        }

        // The victim now encrypts a private line "to the peer".
        let secret = b"meeting at 8, bring the key";
        let ct = bob_new.encrypt(&gid, secret).unwrap();
        let ct_in = MlsMessageIn::tls_deserialize_exact(&ct).unwrap();
        let app = match ct_in.extract() {
            MlsMessageBodyIn::PrivateMessage(m) => m,
            _ => panic!("app message is a PrivateMessage"),
        };
        let read = srv_group.process_message(&srv, app).unwrap();
        let plaintext = match read.into_content() {
            ProcessedMessageContent::ApplicationMessage(m) => m.into_bytes(),
            _ => panic!("expected the victim's application message"),
        };

        println!("SERVER DECRYPTED VICTIM LINE: {:?}", String::from_utf8_lossy(&plaintext));
        // SECURE BEHAVIOUR (fails today): the server must NOT read Bob's line.
        assert_ne!(
            plaintext, secret,
            "CLAIM A1 CONFIRMED: a forged card lets the server read the restored phone's messages"
        );
        let _ = bob_id;
    }

    // ── audit 2026-11b, claim B1 ────────────────────────────────────────
    // Mallory shares live chat Y with Bob. She leaves Y's card (GroupInfo)
    // on the server as "her card of chat X" — a chat Bob's phone has no MLS
    // state for (restored from backup). The server stores it unparsed.
    // join_by_cards() calls join_by_card(card_Y) for X. SECURE BEHAVIOUR
    // asserted: Bob's live chat Y survives (FAILS today).
    const AUDIT_MALLORY: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";

    /// Bob has one device in Y: join_by_card's own `!mine_here` branch
    /// calls forget() on the group it just overwrote.
    #[test]
    fn audit_b_card_of_other_chat_wipes_live_group_single_device() {
        let mut mallory = mk_client(AUDIT_MALLORY, None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let y = mallory.create_group().unwrap();
        let add = mallory.invite_devices(&y, &[bob.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let ct = mallory.encrypt(&y, b"before").unwrap();
        assert!(matches!(bob.decrypt(&y, &ct).unwrap(), IncomingMessage::App(_)));
        let epoch_before = bob.group_epoch(&y).unwrap();

        let (_, card_y) = mallory.group_card(&y).unwrap();
        let r = bob.join_by_card(&[0xAAu8; 16], &card_y); // the app does this for absent chat X
        println!("join_by_card(card of Y) -> {:?}", r.as_ref().map(|(g, p)| (hex::encode(g), p.epoch)));
        let after = bob.group_epoch(&y);
        println!("Bob's chat Y epoch before={epoch_before} after={after:?}");
        let ct2 = mallory.encrypt(&y, b"after").unwrap();
        let d = bob.decrypt(&y, &ct2);
        println!("Bob decrypts Mallory's next message in Y: {:?}", d.as_ref().map(|m| matches!(m, IncomingMessage::App(_))));
        assert_eq!(after.ok(), Some(epoch_before), "SECURE: a card must never touch a live group");
        assert!(matches!(d, Ok(IncomingMessage::App(_))), "SECURE: Bob still reads chat Y");
    }

    /// Same, with Bob's real on-disk storage and an app restart: the
    /// in-memory copy hides the damage until the next launch.
    #[test]
    fn audit_b_card_of_other_chat_wipes_live_group_after_restart() {
        let db = tempdir_in_tmp().join("bob.sqlite");
        let open = || SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: Some(db.clone()), device_seed: None }).unwrap();
        let mut mallory = mk_client(AUDIT_MALLORY, None);
        let mut bob = open();
        let y = mallory.create_group().unwrap();
        let add = mallory.invite_devices(&y, &[bob.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let epoch_before = bob.group_epoch(&y).unwrap();
        let (_, card_y) = mallory.group_card(&y).unwrap();
        let r = bob.join_by_card(&[0xAAu8; 16], &card_y);
        println!("join_by_card(card of Y) -> {:?}", r.as_ref().map(|(g, p)| (hex::encode(g), p.epoch)));
        println!("in memory before restart: {:?}", bob.group_epoch(&y));
        let ct = mallory.encrypt(&y, b"after").unwrap();
        let d = bob.decrypt(&y, &ct);
        println!("in memory, Bob decrypts Mallory's next message: {:?}", d.as_ref().map(|m| matches!(m, IncomingMessage::App(_))));
        drop(bob);
        let mut bob = open(); // the app is relaunched
        let after = bob.group_epoch(&y);
        println!("after restart, Bob's chat Y: {after:?} (before: {epoch_before})");
        let ct2 = mallory.encrypt(&y, b"after restart").unwrap();
        let d2 = bob.decrypt(&y, &ct2);
        println!("after restart, Bob decrypts Mallory's message: {:?}", d2.as_ref().map(|m| matches!(m, IncomingMessage::App(_))));
        assert!(matches!(d2, Ok(IncomingMessage::App(_))), "SECURE: Bob still reads chat Y after a restart");
    }

    /// Bob has two devices in Y: join_by_card returns Ok(gid = Y); the
    /// caller in api/simple.rs (join_by_cards) sees gid != X and calls
    /// forget_group(Y).
    #[test]
    fn audit_b_card_of_other_chat_wipes_live_group_via_caller_forget() {
        let mut mallory = mk_client(AUDIT_MALLORY, None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut bob_laptop = mk_client(BOB_PHRASE, Some([7u8; 32]));
        let y = mallory.create_group().unwrap();
        let add = mallory
            .invite_devices(&y, &[bob.create_keypackage().unwrap(), bob_laptop.create_keypackage().unwrap()])
            .unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        bob_laptop.join_via_welcome(&add.welcome_bytes).unwrap();
        let epoch_before = bob.group_epoch(&y).unwrap();
        let x = vec![0xAAu8; 16]; // the absent chat Bob asked the card for

        let (_, card_y) = mallory.group_card(&y).unwrap();
        let r = bob.join_by_card(&[0xAAu8; 16], &card_y);
        println!("join_by_card(card of Y) -> {:?}", r.as_ref().map(|(g, p)| (hex::encode(g), p.epoch)));
        let state_after_join = bob.group_epoch(&y);
        println!("Bob's Y right after join_by_card: {state_after_join:?} (before: {epoch_before})");
        // join_by_cards() in client_flutter/rust/src/api/simple.rs:
        if let Ok((gid, _)) = &r {
            if *gid != x {
                bob.forget_group(gid);
            }
        }
        let after = bob.group_epoch(&y);
        println!("Bob's chat Y after the caller's forget_group: {after:?}");
        let ct = mallory.encrypt(&y, b"after").unwrap();
        let d = bob.decrypt(&y, &ct);
        println!("Bob decrypts Mallory's next message in Y: {:?}", d.as_ref().map(|m| matches!(m, IncomingMessage::App(_))));
        assert_eq!(after.ok(), Some(epoch_before), "SECURE: a card must never touch a live group");
        assert!(matches!(d, Ok(IncomingMessage::App(_))), "SECURE: Bob still reads chat Y");
    }

    /// ADR-100 (audit CM-02) — a card older than the copy of the chat this
    /// device still holds (it was taken out, the copy is dead) is refused:
    /// the server can't walk the device back to a time when someone since
    /// removed could still read. The current card of my other device opens it.
    #[test]
    fn a_card_older_than_the_chat_this_device_knew_is_refused() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mut alice = mk_client(ALICE, None);
        let mut bob_a = mk_client(BOB_PHRASE, Some([3u8; 32]));
        let mut bob_b = mk_client(BOB_PHRASE, Some([9u8; 32]));
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob_a.create_keypackage().unwrap(), bob_b.create_keypackage().unwrap()]).unwrap();
        bob_a.join_via_welcome(&add.welcome_bytes).unwrap();
        bob_b.join_via_welcome(&add.welcome_bytes).unwrap();
        let (old_epoch, old_card) = bob_a.group_card(&group).unwrap();
        // The chat moves on, then phone B is taken out.
        let step = alice.self_update_pending(&group).unwrap();
        alice.confirm_commit(&group).unwrap();
        bob_a.decrypt(&group, &step.commit_bytes).unwrap();
        bob_b.decrypt(&group, &step.commit_bytes).unwrap();
        let out = alice.remove_device(&group, &bob_b.device_public_key()).unwrap();
        bob_a.decrypt(&group, &out).unwrap();
        bob_b.decrypt(&group, &out).unwrap();
        assert!(!bob_b.group_is_active(&group).unwrap(), "B holds a dead copy");
        assert!(bob_b.join_by_card(&group, &old_card).is_err(), "a card of epoch {old_epoch} is from before what B knew");
        let (epoch, card) = bob_a.group_card(&group).unwrap();
        let (_, pending) = bob_b.join_by_card(&group, &card).unwrap();
        assert_eq!(pending.epoch, epoch);
        assert!(matches!(alice.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
    }

    /// ADR-101 (audit CM-03) — the server took Bob's Commit and fanned it
    /// out, but its Ack never reached Bob (20 s of bad network). Bob keeps
    /// the Commit pending; when it comes back to him he applies it and
    /// stays with the chat: reads Alice, takes her later Commits, is read.
    #[test]
    fn a_commit_whose_ack_was_lost_is_applied_when_it_comes_back() {
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above", None);
        let group = alice.create_group().unwrap();
        let add = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let e0 = bob.group_epoch(&group).unwrap();

        // No Ack: the Commit stays pending (the app no longer drops it).
        let pending = bob.self_update_pending(&group).unwrap();
        assert!(matches!(alice.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        // Bob's own Commit comes back to him, as to every device: the very
        // bytes he sent, so the app applies the Commit it kept.
        assert!(matches!(bob.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::OwnCommitEcho));
        assert!(bob.has_pending_commit(&group).unwrap(), "still there to apply");
        assert_eq!(bob.confirm_commit(&group).unwrap(), e0 + 1);

        let msg = alice.encrypt(&group, b"hello Bob").unwrap();
        assert!(matches!(bob.decrypt(&group, &msg).unwrap(), IncomingMessage::App(ref b) if b == b"hello Bob"));
        for _ in 0..3 {
            let p = alice.self_update_pending(&group).unwrap();
            alice.confirm_commit(&group).unwrap();
            assert!(matches!(bob.decrypt(&group, &p.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        }
        let from_bob = bob.encrypt(&group, b"hi Alice").unwrap();
        assert!(matches!(alice.decrypt(&group, &from_bob).unwrap(), IncomingMessage::App(_)));
        assert_eq!(bob.group_epoch(&group).unwrap(), alice.group_epoch(&group).unwrap());

        // The same with a Commit that adds someone: who to welcome is known
        // while it is pending, and the Welcome made with it still opens.
        let add = alice.invite_devices_pending(&group, &[carol.create_keypackage().unwrap()]).unwrap();
        let adds = alice.pending_adds(&group).unwrap();
        assert_eq!(adds, vec![(id_of(&carol), carol.device_public_key())]);
        bob.decrypt(&group, &add.commit_bytes).unwrap();
        assert!(matches!(alice.decrypt(&group, &add.commit_bytes).unwrap(), IncomingMessage::OwnCommitEcho));
        alice.confirm_commit(&group).unwrap();
        carol.join_via_welcome(add.welcome_bytes.as_ref().unwrap()).unwrap();
        let m = carol.encrypt(&group, b"in").unwrap();
        assert!(matches!(alice.decrypt(&group, &m).unwrap(), IncomingMessage::App(_)));
    }

    /// ADR-100 (audit CM-04) — a member's leaf keeps the lifetime of the key
    /// package they were added by (84 days) until they make a Commit of
    /// their own, which ordinary members never do. Once it ran out, nobody
    /// new could open a Welcome into the chat. Here Bob's package lives 2 s.
    #[test]
    fn a_members_expired_leaf_does_not_lock_the_chat_for_newcomers() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mut alice = mk_client(ALICE, None);
        let mut alice_new = mk_client(ALICE, Some([9u8; 32]));
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above", None);
        let short = KeyPackage::builder()
            .key_package_lifetime(Lifetime::new(2))
            .build(CIPHERSUITE, &bob.provider, &bob.identity.signer, bob.identity.credential.clone())
            .unwrap();
        let short = short.key_package().tls_serialize_detached().unwrap();
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[short]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        std::thread::sleep(std::time::Duration::from_secs(4));

        // A new person, by Welcome.
        let add = alice.invite_devices(&group, &[carol.create_keypackage().unwrap()]).unwrap();
        bob.decrypt(&group, &add.commit_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).expect("the Welcome opens although Bob's old leaf is past its date");
        let m = carol.encrypt(&group, b"in").unwrap();
        assert!(matches!(bob.decrypt(&group, &m).unwrap(), IncomingMessage::App(_)));
        // A member's new phone, by the card.
        let (_, card) = alice.group_card(&group).unwrap();
        alice_new.join_by_card(&group, &card).expect("and so does the card");
        // A package that is itself past its date is still not added.
        let late = KeyPackage::builder()
            .key_package_lifetime(Lifetime::new(1))
            .build(CIPHERSUITE, &alice_new.provider, &alice_new.identity.signer, alice_new.identity.credential.clone())
            .unwrap();
        let late = late.key_package().tls_serialize_detached().unwrap();
        std::thread::sleep(std::time::Duration::from_secs(3));
        assert!(alice.invite_devices_pending(&group, &[late]).is_err());
    }

    /// Audit CM-07 — a member's Commit whose new leaf names ANOTHER person
    /// (their place handed to someone the admin never added) is refused.
    /// Audit CM-09 — and a message whose sender is no longer a member is
    /// not shown (it used to pass with no sender).
    #[test]
    fn a_member_cannot_hand_their_leaf_to_another_person_and_the_removed_are_not_heard() {
        const ALICE: &str = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let mut alice = mk_client(ALICE, None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let mut carol = mk_client("letter advice cage absurd amount doctor acoustic avoid letter advice cage above", None);
        let mallory = mk_client("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong", None);
        let group = alice.create_group().unwrap();
        let add = alice.invite_devices(&group, &[bob.create_keypackage().unwrap(), carol.create_keypackage().unwrap()]).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        carol.join_via_welcome(&add.welcome_bytes).unwrap();

        // Bob's modified app: a Commit with Mallory's credential and key on his leaf.
        let swap = {
            let h = bob.groups.get_mut(&group).unwrap();
            let bundle = h
                .group
                .commit_builder()
                .load_psks(bob.provider.storage())
                .unwrap()
                .build_with_new_signer(
                    bob.provider.rand(),
                    bob.provider.crypto(),
                    &bob.identity.signer,
                    NewSignerBundle { signer: &mallory.identity.signer, credential_with_key: mallory.identity.credential.clone() },
                    |_| true,
                )
                .unwrap()
                .stage_commit(&bob.provider)
                .unwrap();
            h.discard_pending_commit(&bob.provider).unwrap();
            bundle.into_commit().tls_serialize_detached().unwrap()
        };
        let epoch = alice.group_epoch(&group).unwrap();
        for c in [&mut alice, &mut carol] {
            assert!(matches!(c.decrypt(&group, &swap).unwrap(), IncomingMessage::Other), "Mallory on Bob's leaf is refused");
            assert_eq!(c.group_epoch(&group).unwrap(), epoch);
            assert!(!c.group_member_identities(&group).unwrap().contains(&id_of(&mallory).to_vec()));
        }

        // Carol is removed; what she writes afterwards (her keys of the old
        // epoch are still kept for late messages) is not shown.
        let late = carol.encrypt(&group, b"still me?").unwrap();
        let out = alice.remove_people_pending(&group, &[id_of(&carol)]).unwrap();
        alice.confirm_commit(&group).unwrap();
        bob.decrypt(&group, &out.commit_bytes).unwrap();
        assert!(!matches!(bob.decrypt(&group, &late), Ok(IncomingMessage::App(_))), "no message from someone who is out");
    }

    /// ADR-101 (audit recheck N1) — while a Commit waits for the server, a
    /// second one is not made: it would replace the first, and the first
    /// coming back would then apply the second.
    #[test]
    fn a_second_commit_is_not_made_while_one_waits() {
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = mk_client(BOB_PHRASE, None);
        let group = alice.create_group().unwrap();
        let add = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let first = alice.self_update_pending(&group).unwrap();
        assert!(alice.self_update_pending(&group).is_err(), "the first is still waiting");
        bob.decrypt(&group, &first.commit_bytes).unwrap();
        alice.confirm_commit(&group).unwrap();
        let m = alice.encrypt(&group, b"same epoch").unwrap();
        assert!(matches!(bob.decrypt(&group, &m).unwrap(), IncomingMessage::App(_)));
        alice.self_update_pending(&group).unwrap();
    }

    /// ADR-101 — the app is killed while its Commit waits for the server's
    /// answer: after the restart the Commit is still pending in the stored
    /// MLS state, and is applied when the answer (or the Commit) comes.
    #[test]
    fn a_waiting_commit_survives_a_restart() {
        let db = tempdir_in_tmp().join("bob.sqlite");
        let open = || SyncClient::new(SyncClientConfig { phrase: BOB_PHRASE.into(), db_path: Some(db.clone()), device_seed: None }).unwrap();
        let mut alice = mk_client("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", None);
        let mut bob = open();
        let group = alice.create_group().unwrap();
        let add = alice.invite_to_group(&group, &bob.create_keypackage().unwrap()).unwrap();
        bob.join_via_welcome(&add.welcome_bytes).unwrap();
        let e = bob.group_epoch(&group).unwrap();
        let pending = bob.self_update_pending(&group).unwrap();
        drop(bob); // killed before the Ack
        assert!(matches!(alice.decrypt(&group, &pending.commit_bytes).unwrap(), IncomingMessage::Commit { .. }));
        let mut bob = open();
        assert!(bob.has_pending_commit(&group).unwrap(), "still waiting after the restart");
        assert!(bob.self_update_pending(&group).is_err(), "and not replaced by a new one");
        assert_eq!(bob.confirm_commit(&group).unwrap(), e + 1);
        let m = alice.encrypt(&group, b"after").unwrap();
        assert!(matches!(bob.decrypt(&group, &m).unwrap(), IncomingMessage::App(_)));
    }
}
