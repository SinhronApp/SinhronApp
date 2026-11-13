// MLS group operations — create, add member, send/receive App messages.
//
// `GroupHandle` is the runtime view of a group: it owns the live MlsGroup
// state plus the cached group_id. SyncClient holds a HashMap<group_id,
// GroupHandle> indexed by opaque ID so incoming Push frames route to
// the right decryption path.
//
// Boundaries:
//   • Creating a group emits a Welcome (sent out-of-band today; via a
//     `Welcome` WS frame once the .proto schema gains one).
//   • Sending an app message: caller hands plaintext bytes, this returns
//     MLS PrivateMessage TLS-encoded bytes. The bytes ride on the WS
//     `Submit.ciphertext` field.
//   • Receiving: caller hands the MLS-encrypted bytes from a Push frame,
//     this returns the plaintext if it decoded as ApplicationMessage.
//     Commits / Proposals get processed but produce no plaintext.
//
// Provider generics: every method takes `&P: OpenMlsProvider` so the
// same code path works for the in-memory `OpenMlsRustCrypto` and the
// disk-backed `SinhronProvider`.

use openmls::prelude::*;
use openmls_traits::OpenMlsProvider;
use tls_codec::{Deserialize, Serialize};
use tracing::{debug, info, warn};

use crate::identity::{MlsIdentity, CIPHERSUITE};

/// MLS PrivateMessage padding block (RFC 9420 §6.3.1, OpenMLS
/// `padding_size`). The encrypted content is padded to a multiple of
/// this, so the server (and a DB dump) sees size buckets instead of the
/// exact plaintext length — threat-model limitation #5. 512 bytes puts
/// almost every chat line (~200 Cyrillic chars) into the same bucket.
pub const PADDING_SIZE: usize = 512;

/// Join config for groups we enter via Welcome — padded like our own,
/// and embedding the ratchet tree in *our* Welcomes too. Without that a
/// member who joined (anyone but the creator) produced Welcomes the new
/// member couldn't open (`MissingRatchetTree`) — found by
/// `concurrent_commits_are_ordered_and_the_loser_retries`.
/// Previous epochs whose keys a member keeps, so a message sent just
/// before a Commit still decrypts after it (device sync, concurrent
/// senders). Costs a little forward secrecy: the last 2 epochs' message
/// keys stay until 2 more Commits happen.
pub const MAX_PAST_EPOCHS: usize = 2;

pub fn join_config() -> MlsGroupJoinConfig {
    MlsGroupJoinConfig::builder()
        .max_past_epochs(MAX_PAST_EPOCHS)
        .padding_size(PADDING_SIZE)
        .use_ratchet_tree_extension(true)
        .build()
}

/// `config` with `padding_size` (and the ratchet-tree extension) set,
/// every other field kept.
/// `MlsGroupJoinConfig` has no getters for all fields and its builder
/// starts from defaults, so round-trip through its serde form instead.
fn with_padding(config: &MlsGroupJoinConfig) -> Result<MlsGroupJoinConfig, GroupError> {
    let mut value =
        serde_json::to_value(config).map_err(|e| GroupError::Load(e.to_string()))?;
    value["padding_size"] = serde_json::json!(PADDING_SIZE);
    value["use_ratchet_tree_extension"] = serde_json::json!(true);
    serde_json::from_value(value).map_err(|e| GroupError::Load(e.to_string()))
}

/// `use_ratchet_tree_extension` has no public getter on the join config.
fn embeds_ratchet_tree(config: &MlsGroupJoinConfig) -> bool {
    serde_json::to_value(config)
        .ok()
        .and_then(|v| v.get("use_ratchet_tree_extension").and_then(|b| b.as_bool()))
        .unwrap_or(false)
}

/// Live state for one group. Wraps OpenMLS's `MlsGroup` plus the
/// opaque group_id bytes used over the wire.
pub struct GroupHandle {
    pub group_id: Vec<u8>,
    pub group: MlsGroup,
}

/// Incoming-message classification. The caller routes by variant:
///   • `App(plaintext)` → display in UI
///   • `Commit` → MLS state advanced (member added/removed); UI updates
///   • `Welcome` → already handled inside SyncClient::handle_welcome
///   • `StaleEpoch` → WU C5: out-of-order Commit per spec §9.3. The
///                   sender's group epoch doesn't match ours, so the
///                   message is either ancient or from the future
///                   (concurrent Commit race). Caller logs + drops.
///                   Real reconciliation lands when the server signs
///                   off on commit ordering — for now MLS itself
///                   handles the linearization, we just don't panic.
///   • `OwnCommitEcho` → server fanned out a Commit we ourselves sent
///                   (e.g. multi-device replay). Already applied
///                   locally via `merge_pending_commit`; safe to drop.
#[derive(Debug)]
pub enum IncomingMessage {
    App(Vec<u8>),
    /// `added` / `removed`: people (identity keys) who came in or are gone
    /// entirely — a person's extra or revoked device is not listed.
    Commit { new_epoch: u64, added: Vec<[u8; 32]>, removed: Vec<[u8; 32]> },
    StaleEpoch { my_epoch: u64 },
    OwnCommitEcho,
    Other,
}

impl GroupHandle {
    /// Create a new MLS group. Caller is the only initial member;
    /// invite additional members via [`add_member`].
    pub fn create<P: OpenMlsProvider>(
        provider: &P,
        me: &MlsIdentity,
    ) -> Result<Self, GroupError> {
        let create_config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .max_past_epochs(MAX_PAST_EPOCHS)
            // Embed the ratchet tree in Welcome / GroupInfo. Without
            // this, Bob's `join_via_welcome` fails with
            // "MissingRatchetTree" because it would otherwise need to
            // fetch the tree out-of-band.
            .use_ratchet_tree_extension(true)
            .padding_size(PADDING_SIZE)
            // ADR-088 — I am the admin, in the state every member shares.
            .with_group_context_extensions(
                Extensions::single(admin_record(&me.identity_public)).map_err(|e| GroupError::Create(format!("{e:?}")))?,
            )
            .build();
        let group = MlsGroup::new(provider, &me.signer, &create_config, me.credential.clone())
            .map_err(|e| GroupError::Create(format!("{e:?}")))?;
        let group_id = group.group_id().to_vec();
        info!(group_id = %hex::encode(&group_id), "mls group created");
        Ok(Self { group_id, group })
    }

    /// Load an MLS group from the provider's storage if it exists there.
    /// Returns `Ok(None)` if no group with the given id has been
    /// persisted. Used by `SyncClient` to lazily re-hydrate groups on
    /// app restart — the in-memory HashMap starts empty, and the first
    /// encrypt/decrypt for an unknown group_id falls through to here.
    pub fn try_load<P: OpenMlsProvider>(
        provider: &P,
        group_id_bytes: &[u8],
    ) -> Result<Option<Self>, GroupError> {
        let group_id = GroupId::from_slice(group_id_bytes);
        let maybe_group = MlsGroup::load(provider.storage(), &group_id)
            .map_err(|e| GroupError::Load(format!("{e:?}")))?;
        let Some(mut group) = maybe_group else {
            return Ok(None);
        };
        // Groups persisted before PADDING_SIZE existed carry
        // padding_size = 0; upgrade them in place so their next message
        // is padded too.
        // Same for groups joined before the ratchet-tree fix.
        if group.configuration().padding_size() != PADDING_SIZE
            || !embeds_ratchet_tree(group.configuration())
        {
            let padded = with_padding(group.configuration())?;
            group
                .set_configuration(provider.storage(), &padded)
                .map_err(|e| GroupError::Load(format!("{e:?}")))?;
            info!(group_id = %hex::encode(group_id_bytes), "mls group config upgraded (padding, ratchet tree)");
        }
        Ok(Some(Self {
            group_id: group_id_bytes.to_vec(),
            group,
        }))
    }

    /// Add a member by their pre-published KeyPackage. Produces the
    /// (Commit, Welcome) pair: Commit is broadcast to existing members,
    /// Welcome is delivered to the new member out-of-band.
    pub fn add_member<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        new_member_kp: KeyPackageIn,
    ) -> Result<AddMemberOutcome, GroupError> {
        self.add_members(provider, me, vec![new_member_kp])
    }

    /// ADR-025 — add several leaves in ONE Commit (all devices of a new
    /// member, or our own newly linked device). Applied immediately —
    /// use only where no other member can race (a fresh group, our own
    /// device sync); otherwise wrap in the pending flow (ADR-022).
    pub fn add_members<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        key_packages: Vec<KeyPackageIn>,
    ) -> Result<AddMemberOutcome, GroupError> {
        let pending = self.add_members_pending(provider, me, key_packages)?;
        self.confirm_pending_commit(provider)?;
        Ok(AddMemberOutcome {
            commit_bytes: pending.commit_bytes,
            welcome_bytes: pending.welcome_bytes.unwrap_or_default(),
        })
    }

    /// ADR-025 + tech-debt 2.3 — [`add_members`] with the Commit left
    /// pending until the server orders it (device sync can race another
    /// of the person's devices doing the same).
    pub fn add_members_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        key_packages: Vec<KeyPackageIn>,
    ) -> Result<PendingCommit, GroupError> {
        let mut validated = Vec::with_capacity(key_packages.len());
        for kp in key_packages {
            validated.push(
                kp.validate(provider.crypto(), ProtocolVersion::Mls10)
                    .map_err(|e| GroupError::InvalidKeyPackage(format!("{e:?}")))?,
            );
        }
        // Every new leaf must name a person: legacy identity key or a valid
        // device certificate, for the key that signs the leaf (a forged
        // certificate, or Bob's credential on an attacker's key, is nobody).
        for kp in &validated {
            let Some(who) = crate::identity::identity_of_leaf_node(kp.leaf_node()) else {
                return Err(GroupError::InvalidKeyPackage("leaf names nobody".into()));
            };
            // The rule every member checks (`may_add_people`): a Commit the
            // others would refuse is never sent.
            if self.device_keys_of(&who).is_empty() && !self.may_add_people(&me.identity_public) {
                return Err(GroupError::AddMember("only the group's admin adds people".into()));
            }
        }
        self.commit_pending(provider, me, validated, Vec::new())
    }

    /// ADR-025 / ADR-074 — more devices of people already in this group
    /// (a new phone of mine, or of another member who lost theirs), in one
    /// pending Commit. Each key package must carry a valid device
    /// certificate of the person it was fetched for, and that person must
    /// already have a leaf here: a server answering "Bob's devices" with
    /// someone else's key package can't slip a new person in this way.
    /// Packages that fail are left out (one bad one doesn't stop the
    /// rest); none left → an error. Returns the Commit and who got which
    /// new leaf (person, device key).
    pub fn add_devices_of_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        packages: Vec<([u8; 32], KeyPackageIn)>,
    ) -> Result<(PendingCommit, Vec<([u8; 32], Vec<u8>)>), GroupError> {
        let mut validated = Vec::with_capacity(packages.len());
        let mut added = Vec::with_capacity(packages.len());
        let mut last_err = String::from("nothing to add");
        for (owner, kp) in packages {
            let kp = match kp.validate(provider.crypto(), ProtocolVersion::Mls10) {
                Ok(kp) => kp,
                Err(e) => {
                    last_err = format!("{e:?}");
                    continue;
                }
            };
            let named = crate::identity::identity_of_leaf_node(kp.leaf_node());
            if named != Some(owner) {
                last_err = "key package of another person".into();
                warn!(group_id = %hex::encode(&self.group_id), "refused a key package that isn't the expected person's");
                continue;
            }
            if self.device_keys_of(&owner).is_empty() {
                last_err = "that person is not in this group".into();
                continue;
            }
            let key = kp.leaf_node().signature_key().as_slice().to_vec();
            if added.iter().any(|(_, k)| *k == key) || self.group.members().any(|m| m.signature_key == key) {
                continue; // already here (or twice in the batch)
            }
            added.push((owner, key));
            validated.push(kp);
        }
        if validated.is_empty() {
            return Err(GroupError::InvalidKeyPackage(last_err));
        }
        Ok((self.commit_pending(provider, me, validated, Vec::new())?, added))
    }

    /// ADR-075 — the chat's card: its GroupInfo with the ratchet tree and
    /// the epoch's external key (public — the server keeps it so a member's
    /// new phone can join by itself). Returns (epoch, bytes).
    pub fn export_card<P: OpenMlsProvider>(&self, provider: &P, me: &MlsIdentity) -> Result<(u64, Vec<u8>), GroupError> {
        let gi = self
            .group
            .export_group_info(provider.crypto(), &me.signer, true)
            .map_err(|e| GroupError::Serialize(format!("group info: {e:?}")))?;
        let bytes = gi.tls_serialize_detached().map_err(|e| GroupError::Serialize(e.to_string()))?;
        Ok((self.group.epoch().as_u64(), bytes))
    }

    /// ADR-075 — join the chat `group_id` by its card (external commit): this
    /// device's new leaf. OpenMLS applies an external commit at once, so the
    /// group is already in the new epoch; if the server refuses the Commit
    /// (another change came first), [`forget`](Self::forget) it and try again
    /// from a fresh card. The returned `epoch` is the card's — `Submit.commit_epoch`.
    ///
    /// ADR-100 — the card is taken only when ANOTHER DEVICE OF MINE signed
    /// it. The server keeps my devices' key packages, so "a leaf of mine is
    /// in the tree" proves nothing (it can build its own group around one
    /// and read all I write there); a signature of my device it cannot make.
    /// Checked before anything is built or stored: the card is of this chat,
    /// this device is not in the chat already (a card of another chat must
    /// not overwrite a live one), and the card is not older than a copy of
    /// the chat this device still holds from before it was removed.
    pub fn join_by_card<P: OpenMlsProvider>(
        provider: &P,
        me: &MlsIdentity,
        my_identity: &[u8; 32],
        group_id: &[u8],
        card: &[u8],
    ) -> Result<(Self, PendingCommit), GroupError> {
        let refuse = |why: &str| Err(GroupError::Create(format!("card refused: {why}")));
        let Some(signer) = card_signer(card) else {
            return refuse("not a card of our cipher suite");
        };
        let msg = MlsMessageIn::tls_deserialize_exact(card).map_err(|e| GroupError::Deserialize(e.to_string()))?;
        let info = match msg.extract() {
            MlsMessageBodyIn::GroupInfo(gi) => gi,
            _ => return Err(GroupError::WrongMessageType("card is not a GroupInfo".into())),
        };
        let epoch = info.epoch().as_u64();
        if info.group_id().as_slice() != group_id {
            return refuse("it is of another chat");
        }
        if let Some(old) = Self::try_load(provider, group_id)? {
            if old.is_active() {
                return refuse("this device is in that chat already");
            }
            if epoch < old.current_epoch() {
                return refuse("older than the chat this device knew");
            }
        }
        let (group, bundle) = MlsGroup::external_commit_builder()
            .with_config(join_config())
            // ADR-100 — an old member's leaf past its key package's lifetime
            // must not lock the chat for everyone who joins later.
            .skip_lifetime_validation()
            .build_group(provider, info, me.credential.clone())
            .map_err(|e| GroupError::Create(format!("external join: {e:?}")))?
            .load_psks(provider.storage())
            .map_err(|e| GroupError::Create(format!("external join psks: {e:?}")))?
            .build(provider.rand(), provider.crypto(), &me.signer, |_| true)
            .map_err(|e| GroupError::Create(format!("external join: {e:?}")))?
            .finalize(provider)
            .map_err(|e| GroupError::Create(format!("external join: {e:?}")))?;
        let mut handle = Self { group_id: group.group_id().to_vec(), group };
        // OpenMLS verified the card's signature against the leaf `signer`
        // of the card's own tree: that leaf must be another device of mine.
        // And, as with a Welcome, every leaf must name a person.
        let my_key = me.credential.signature_key.as_slice();
        let signed_by_mine = handle.group.member_at(LeafNodeIndex::new(signer)).is_some_and(|m| {
            m.signature_key.as_slice() != my_key && crate::identity::identity_of_member(&m).as_ref() == Some(my_identity)
        });
        let all_named = handle.group.members().all(|m| crate::identity::identity_of_member(&m).is_some());
        if !signed_by_mine || !all_named {
            handle.forget(provider);
            return refuse("not signed by another device of mine");
        }
        let (commit, _welcome, _info) = bundle.into_contents();
        let commit_bytes = commit.tls_serialize_detached().map_err(|e| GroupError::Serialize(e.to_string()))?;
        Ok((handle, PendingCommit { epoch, commit_bytes, welcome_bytes: None }))
    }

    /// ADR-075 — drop this group from storage (an external join the
    /// server refused: the next try starts from a fresh card).
    pub fn forget<P: OpenMlsProvider>(&mut self, provider: &P) {
        if let Err(e) = self.group.delete(provider.storage()) {
            warn!(group_id = %hex::encode(&self.group_id), error = ?e, "dropping a refused external join");
        }
    }

    /// ADR-075 — remove several leaves (devices) in one pending Commit.
    pub fn remove_devices_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        device_keys: &[Vec<u8>],
    ) -> Result<PendingCommit, GroupError> {
        let leaves: Vec<LeafNodeIndex> = self
            .group
            .members()
            .filter(|m| device_keys.iter().any(|k| *k == m.signature_key))
            .map(|m| m.index)
            .collect();
        if leaves.is_empty() {
            return Err(GroupError::Process("none of those devices is in this group".into()));
        }
        self.commit_pending(provider, me, Vec::new(), leaves)
    }

    /// ADR-035 — remove every leaf (device) of these people in one Commit,
    /// left pending until the server orders it (like [`add_members_pending`]).
    /// My own leaves are never taken: MLS can't commit its own removal —
    /// a member who leaves asks the others (`leave` action) to do it.
    pub fn remove_identities_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        identities: &[[u8; 32]],
    ) -> Result<PendingCommit, GroupError> {
        let my_key = me.credential.signature_key.as_slice().to_vec();
        let leaves: Vec<_> = self
            .group
            .members()
            .filter(|m| m.signature_key != my_key)
            .filter(|m| {
                crate::identity::identity_of_member(m)
                    .is_some_and(|id| identities.contains(&id))
            })
            .map(|m| m.index)
            .collect();
        if leaves.is_empty() {
            return Err(GroupError::Process("nobody to remove".into()));
        }
        self.commit_pending(provider, me, Vec::new(), leaves)
    }

    /// ADR-035 — still a member? False once a processed Commit removed me.
    pub fn is_active(&self) -> bool {
        self.group.is_active()
    }

    /// ADR-088 — who manages the group: the admin named in the group's
    /// shared state, the same on every phone (not "whoever holds leaf 0" —
    /// a newcomer took that leaf once the creator left). `None` only in an
    /// empty tree.
    pub fn admin_identity(&self) -> Option<[u8; 32]> {
        self.admin_after(&[])
    }

    /// ADR-088 — the admin once the leaves `gone` are removed: the recorded
    /// admin while any device of theirs stays, otherwise the earliest
    /// remaining person (lowest leaf) — every phone computes the same. A
    /// chat from before the record gets it the same way, at its next Commit.
    fn admin_after(&self, gone: &[LeafNodeIndex]) -> Option<[u8; 32]> {
        let mut people: Vec<[u8; 32]> = Vec::new();
        for m in self.group.members().filter(|m| !gone.contains(&m.index)) {
            if let Some(id) = crate::identity::identity_of_member(&m).filter(|id| !people.contains(id)) {
                people.push(id);
            }
        }
        let recorded = admin_in(self.group.extensions());
        people.iter().find(|p| recorded == Some(&admin_record(p))).or(people.first()).copied()
    }

    /// ADR-088 — every Commit this app makes: `adds` and `removes`, plus the
    /// admin record when it is missing or must move (the admin is removed).
    fn commit_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        adds: Vec<KeyPackage>,
        removes: Vec<LeafNodeIndex>,
    ) -> Result<PendingCommit, GroupError> {
        fn err(e: impl std::fmt::Debug) -> GroupError {
            GroupError::Process(format!("commit: {e:?}"))
        }
        // ADR-101 — one Commit at a time: OpenMLS would let a new one take
        // the place of a Commit still waiting for the server's answer, and
        // that answer (or the Commit coming back) would then apply the
        // wrong one — this device alone in an epoch of its own.
        if self.group.pending_commit().is_some() {
            return Err(GroupError::Process("an earlier change is still waiting for the server".into()));
        }
        let epoch = self.group.epoch().as_u64();
        let mut record = None;
        if let Some(admin) = self.admin_after(&removes) {
            if admin_in(self.group.extensions()) != Some(&admin_record(&admin)) {
                let mut ext = self.group.extensions().clone();
                ext.add_or_replace(admin_record(&admin)).map_err(err)?;
                record = Some(ext);
            }
        }
        let mut builder = self.group.commit_builder().propose_adds(adds).propose_removals(removes).force_self_update(true);
        if let Some(ext) = record {
            builder = builder.propose_group_context_extensions(ext).map_err(err)?;
        }
        let bundle = builder
            .load_psks(provider.storage())
            .map_err(err)?
            .build(provider.rand(), provider.crypto(), &me.signer, |_| true)
            .map_err(err)?
            .stage_commit(provider)
            .map_err(err)?;
        let ser = |m: MlsMessageOut| m.tls_serialize_detached().map_err(|e| GroupError::Serialize(e.to_string()));
        let welcome_bytes = bundle.to_welcome_msg().map(ser).transpose()?;
        Ok(PendingCommit { epoch, commit_bytes: ser(bundle.into_commit())?, welcome_bytes })
    }

    /// Security review 2026-11 (mls-identity:3) — may `who` bring a new
    /// person in? The admin, or anyone once there is none — the rule the
    /// app shows ("Add member", `GroupRole.canManage`). Read from the tree
    /// all members share, so every phone gives the same answer.
    fn may_add_people(&self, who: &[u8]) -> bool {
        self.admin_identity().is_none_or(|c| c.as_slice() == who)
    }

    /// ADR-025 — device keys (leaf signature keys) of `identity`'s leaves.
    pub fn device_keys_of(&self, identity: &[u8; 32]) -> Vec<Vec<u8>> {
        self.group
            .members()
            .filter(|m| crate::identity::identity_of_member(m).as_ref() == Some(identity))
            .map(|m| m.signature_key.clone())
            .collect()
    }

    /// ADR-025 — remove the leaf whose signature key is `device_key`
    /// (revoking a lost device). Returns the Commit for the other members.
    pub fn remove_device<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        device_key: &[u8],
    ) -> Result<Vec<u8>, GroupError> {
        let pending = self.remove_device_pending(provider, me, device_key)?;
        self.confirm_pending_commit(provider)?;
        Ok(pending.commit_bytes)
    }

    /// [`remove_device`] with the Commit left pending (see
    /// [`add_member_pending`]).
    pub fn remove_device_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        device_key: &[u8],
    ) -> Result<PendingCommit, GroupError> {
        let leaf = self
            .group
            .members()
            .find(|m| m.signature_key.as_slice() == device_key)
            .map(|m| m.index)
            .ok_or_else(|| GroupError::Process("no such device in this group".into()))?;
        self.commit_pending(provider, me, Vec::new(), vec![leaf])
    }

    /// Tech-debt 2.3 — like [`add_member`], but the Commit stays *pending*:
    /// nothing changes locally until the server accepts it. The caller
    /// submits `commit_bytes` with `Submit.commit_epoch = epoch`; on Ack 0
    /// → [`confirm_pending_commit`]; on 409 (another member's Commit for
    /// this epoch won the race) → [`discard_pending_commit`], apply the
    /// winner's Commit as it arrives, and try again. Without this both
    /// sides merged their own Commit at once and the group forked.
    pub fn add_member_pending<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        new_member_kp: KeyPackageIn,
    ) -> Result<PendingCommit, GroupError> {
        self.add_members_pending(provider, me, vec![new_member_kp])
    }

    /// ADR-092 — a Commit with nothing in it but our new keys: after a
    /// Commit we didn't take, it makes the chat's epoch (and its card) an
    /// honest member's again. Pending, like every Commit.
    pub fn self_update_pending<P: OpenMlsProvider>(&mut self, provider: &P, me: &MlsIdentity) -> Result<PendingCommit, GroupError> {
        self.commit_pending(provider, me, Vec::new(), Vec::new())
    }

    /// ADR-101 — the devices our pending Commit adds: (person, device key).
    /// Kept with a Commit the server did not answer, to welcome them once
    /// it turns out the server took it.
    pub fn pending_adds(&self) -> Vec<([u8; 32], Vec<u8>)> {
        let Some(c) = self.group.pending_commit() else { return Vec::new() };
        c.add_proposals()
            .filter_map(|p| {
                let leaf = p.add_proposal().key_package().leaf_node();
                crate::identity::identity_of_leaf_node(leaf).map(|id| (id, leaf.signature_key().as_slice().to_vec()))
            })
            .collect()
    }

    pub fn has_pending_commit(&self) -> bool {
        self.group.pending_commit().is_some()
    }

    /// The server accepted our pending Commit: apply it. Returns the new epoch.
    pub fn confirm_pending_commit<P: OpenMlsProvider>(&mut self, provider: &P) -> Result<u64, GroupError> {
        self.group
            .merge_pending_commit(provider)
            .map_err(|e| GroupError::AddMember(format!("merge: {e:?}")))?;
        Ok(self.group.epoch().as_u64())
    }

    /// The server rejected our pending Commit (lost the race): forget it,
    /// so the winner's Commit can be applied and the change retried.
    pub fn discard_pending_commit<P: OpenMlsProvider>(&mut self, provider: &P) -> Result<(), GroupError> {
        self.group
            .clear_pending_commit(provider.storage())
            .map_err(|e| GroupError::AddMember(format!("clear pending: {e:?}")))
    }

    /// CC3 — MLS Exporter (RFC 9420 §8.5).
    ///
    /// Derives `length` bytes from the group's current `exporter_secret`
    /// using a domain-separation `label` + arbitrary `context`. Two
    /// members of the same group at the same epoch derive identical
    /// output for identical inputs — this is what makes SFrame key
    /// derivation work cross-party (spec §10.3, RFC 9605 §5.2).
    ///
    /// The derived bytes rotate on every Commit (epoch bump) — same
    /// label+context yields fresh bytes after each membership change.
    /// Forward secrecy: a leaked epoch's exporter doesn't reveal past
    /// or future epochs.
    pub fn export_secret<P: OpenMlsProvider>(
        &self,
        provider: &P,
        label: &str,
        context: &[u8],
        length: usize,
    ) -> Result<Vec<u8>, GroupError> {
        self.group
            .export_secret(provider.crypto(), label, context, length)
            .map_err(|e| GroupError::CreateMessage(format!("export_secret: {e:?}")))
    }

    /// CC3 — our own leaf index in the ratchet tree. Stable across
    /// epochs as long as we remain in the group (gets reassigned on
    /// remove + re-add). SFrame uses this as the `sender_index` input
    /// to `sender_base_key[i]`.
    pub fn own_leaf_index(&self) -> u32 {
        self.group.own_leaf_index().u32()
    }

    /// Current MLS epoch. Bumps on every Commit. Used by SFrame KID
    /// composition (epoch mod 2^E) per RFC 9605 Figure 8.
    pub fn current_epoch(&self) -> u64 {
        self.group.epoch().as_u64()
    }

    /// Encrypt a plaintext app message. Returns MLS PrivateMessage bytes
    /// ready for the WS `Submit.ciphertext` field.
    pub fn encrypt_message<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        me: &MlsIdentity,
        plaintext: &[u8],
    ) -> Result<Vec<u8>, GroupError> {
        let out = self
            .group
            .create_message(provider, &me.signer, plaintext)
            .map_err(|e| GroupError::CreateMessage(format!("{e:?}")))?;
        out.tls_serialize_detached()
            .map_err(|e| GroupError::Serialize(e.to_string()))
    }

    /// Decrypt an incoming MLS frame. Returns the plaintext if it was
    /// an ApplicationMessage; otherwise reports what happened (Commit,
    /// Proposal, etc.) so the caller's UI can react.
    ///
    /// WU C5 — gracefully handles **stale-epoch** input (`ValidationError
    /// ::WrongEpoch`, `StageCommitError::EpochMismatch`) and our own
    /// Commit echoed back by the server (OpenMLS 0.9: `OwnPendingCommit` /
    /// `OwnPrivateMessage` content, `StageCommitError::OwnCommitMismatch`).
    /// Per spec §9.3, real conflict resolution requires a sender→server
    /// ordering signal we don't yet have on the wire; until then the
    /// safest thing is to drop stale messages and log loudly. Without
    /// this WU, a concurrent-Commit race used to panic the SyncClient
    /// with an opaque `Process(...)` string and the chat session went
    /// dead.
    pub fn process_incoming<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        wire_bytes: &[u8],
    ) -> Result<IncomingMessage, GroupError> {
        self.process_incoming_with_sender(provider, wire_bytes).map(|(m, _)| m)
    }

    /// [`process_incoming`] plus, for application messages, the sender's
    /// MLS credential identity (their Ed25519 identity public key). MLS
    /// authenticates it, so callers can check that an edit / delete comes
    /// from the author of the original message (ADR-019).
    pub fn process_incoming_with_sender<P: OpenMlsProvider>(
        &mut self,
        provider: &P,
        wire_bytes: &[u8],
    ) -> Result<(IncomingMessage, Option<Vec<u8>>), GroupError> {
        use openmls::framing::errors::{MessageDecryptionError, SecretTreeError};
        use openmls::group::{ProcessMessageError, StageCommitError, ValidationError};

        let incoming = MlsMessageIn::tls_deserialize_exact(wire_bytes)
            .map_err(|e| GroupError::Deserialize(e.to_string()))?;
        let protocol_message: ProtocolMessage = incoming
            .try_into_protocol_message()
            .map_err(|e| GroupError::WrongMessageType(format!("{e:?}")))?;

        let processed = match self.group.process_message(provider, protocol_message) {
            // ADR-025 — the server delivers to all of the sender's devices,
            // including the one that sent it. OpenMLS 0.9 hands our own echo
            // back as content (0.8 failed with `CannotDecryptOwnMessage` /
            // `OwnCommit`): our application message, our pending Commit
            // (merged by `confirm_pending_commit`, never here), or — 0.9
            // stages it — our own Commit without a path. Ignored, as before.
            // ADR-101 — a frame from our own leaf can't be opened or checked
            // here (MLS), so whether it is the Commit we are waiting on is
            // the caller's to tell: it compares the bytes with what it sent
            // and then confirms the pending Commit.
            Ok(p) if matches!(
                p.content(),
                ProcessedMessageContent::OwnPrivateMessage | ProcessedMessageContent::OwnPendingCommit
            ) || (matches!(p.content(), ProcessedMessageContent::StagedCommitMessage(_))
                && matches!(p.sender(), Sender::Member(i) if *i == self.group.own_leaf_index())) =>
            {
                debug!(group_id = %hex::encode(&self.group_id), "own message echoed; ignored");
                return Ok((IncomingMessage::OwnCommitEcho, None));
            }
            Ok(p) => p,
            // Pure epoch-mismatch surfaces directly when the wire
            // epoch differs from the group epoch (PublicMessage path
            // or Commit-time validation).
            Err(ProcessMessageError::ValidationError(ValidationError::WrongEpoch))
            | Err(ProcessMessageError::InvalidCommit(StageCommitError::EpochMismatch)) => {
                let my_epoch = self.group.epoch().as_u64();
                info!(
                    group_id = %hex::encode(&self.group_id),
                    my_epoch,
                    "dropping stale-epoch frame (spec §9.3 — WrongEpoch)"
                );
                return Ok((IncomingMessage::StaleEpoch { my_epoch }, None));
            }
            // For PrivateMessage (the normal app-message path) MLS
            // doesn't directly report epoch — it tries to use the
            // SecretTree for the ciphertext's epoch and fails with
            // `SecretTreeError::TooDistantInThePast` (we've ratcheted
            // past) or `IndexOutOfBounds` (the sender's key index isn't
            // in our tree yet). Both are the "I can't decrypt at this
            // epoch" signal — treat as stale, not a panic.
            Err(ProcessMessageError::ValidationError(
                ValidationError::UnableToDecrypt(MessageDecryptionError::SecretTreeError(
                    SecretTreeError::TooDistantInThePast | SecretTreeError::IndexOutOfBounds,
                )),
            )) => {
                let my_epoch = self.group.epoch().as_u64();
                info!(
                    group_id = %hex::encode(&self.group_id),
                    my_epoch,
                    "dropping stale-epoch frame (spec §9.3 — SecretTree miss)"
                );
                return Ok((IncomingMessage::StaleEpoch { my_epoch }, None));
            }
            // Server fanned back our own Commit (with a path) that isn't the
            // pending one — silently swallow, as 0.8's `OwnCommit`.
            Err(ProcessMessageError::InvalidCommit(StageCommitError::OwnCommitMismatch)) => {
                debug!(group_id = %hex::encode(&self.group_id), "own commit echoed; ignored");
                return Ok((IncomingMessage::OwnCommitEcho, None));
            }
            // Anything else is a real bug — bubble up.
            Err(e) => return Err(GroupError::Process(format!("{e:?}"))),
        };

        // ADR-025 — the sender as a *person* (identity key), whichever of
        // their devices sent it; an invalid device certificate, or a
        // credential not bound to the sending leaf's key → no sender.
        let staged = match processed.content() {
            ProcessedMessageContent::StagedCommitMessage(c) => Some(c),
            _ => None,
        };
        let sender_key = match processed.sender() {
            Sender::Member(i) => self.group.member_at(*i).map(|m| m.signature_key),
            Sender::NewMemberCommit => staged.and_then(|c| c.update_path_leaf_node()).map(|l| l.signature_key().as_slice().to_vec()),
            _ => None,
        };
        let sender = sender_key
            .and_then(|k| crate::identity::identity_of_leaf(processed.credential().serialized_content(), &k))
            .map(|id| id.to_vec())
            .unwrap_or_default();
        // Security review 2026-11 (mls-identity:1) — a Commit may bring in
        // only leaves that name a person (added, updated, the committer's
        // own new leaf): a forged leaf from a member's modified app is refused.
        if let Some(c) = staged {
            let mut leaves = c
                .add_proposals()
                .map(|p| crate::identity::identity_of_leaf_node(p.add_proposal().key_package().leaf_node()))
                .chain(c.update_proposals().map(|p| crate::identity::identity_of_leaf_node(p.update_proposal().leaf_node())))
                .chain(c.update_path_leaf_node().map(crate::identity::identity_of_leaf_node));
            if leaves.any(|id| id.is_none()) {
                warn!(group_id = %hex::encode(&self.group_id), "refused a commit with a leaf that names nobody");
                return Ok((IncomingMessage::Other, None));
            }
            // Audit CM-07 — a member's new leaf (their Commit's path, or an
            // Update of theirs) must name the same person as their leaf
            // now: no handing one's place to somebody else past the admin.
            let person_at = |s: &Sender| match s {
                Sender::Member(i) => self.group.member_at(*i).and_then(|m| crate::identity::identity_of_member(&m)),
                _ => None,
            };
            let path_swapped = matches!(processed.sender(), Sender::Member(_))
                && c.update_path_leaf_node().is_some_and(|l| crate::identity::identity_of_leaf_node(l) != person_at(processed.sender()));
            let update_swapped = c
                .update_proposals()
                .any(|p| crate::identity::identity_of_leaf_node(p.update_proposal().leaf_node()) != person_at(p.sender()));
            if path_swapped || update_swapped {
                warn!(group_id = %hex::encode(&self.group_id), "refused a commit that puts another person on a member's leaf");
                return Ok((IncomingMessage::Other, None));
            }
        }
        // Security review 2026-11 (mls-identity:3) — who came in and who is
        // gone, read before the merge; a new person only from someone who
        // may add people (a member's modified app can't slip one in).
        let (mut added, mut removed) = (Vec::new(), Vec::new());
        if let Some(c) = staged {
            let incoming: Vec<_> = c
                .add_proposals()
                .filter_map(|p| crate::identity::identity_of_leaf_node(p.add_proposal().key_package().leaf_node()))
                .collect();
            for who in &incoming {
                if self.device_keys_of(who).is_empty() && !added.contains(who) {
                    added.push(*who);
                }
            }
            let gone: Vec<_> = c.remove_proposals().map(|p| p.remove_proposal().removed()).collect();
            for m in self.group.members().filter(|m| gone.contains(&m.index)) {
                let Some(who) = crate::identity::identity_of_member(&m) else { continue };
                let all_gone = self.group.members().all(|o| gone.contains(&o.index) || crate::identity::identity_of_member(&o) != Some(who));
                if all_gone && !incoming.contains(&who) && !removed.contains(&who) {
                    removed.push(who);
                }
            }
            if !added.is_empty() && !self.may_add_people(&sender) {
                warn!(group_id = %hex::encode(&self.group_id), "refused a commit adding people by someone who isn't the admin");
                return Ok((IncomingMessage::Other, None));
            }
            // A join by the card may take out only the joiner's own other
            // devices (RFC 9420 §12.2 leaves this check to the application).
            if matches!(processed.sender(), Sender::NewMemberCommit) {
                let foreign = self
                    .group
                    .members()
                    .filter(|m| gone.contains(&m.index))
                    .any(|m| crate::identity::identity_of_member(&m).map(|id| id.to_vec()) != Some(sender.clone()));
                if foreign {
                    warn!(group_id = %hex::encode(&self.group_id), "refused a join by the card that removes other people's devices");
                    return Ok((IncomingMessage::Other, None));
                }
            }
            // ADR-088 — the admin record after this Commit must be the one
            // every phone computes (`admin_after`); a chat without a record
            // may stay without. Nothing else in the group context changes.
            let (old, new) = (self.group.extensions(), c.group_context().extensions());
            let want = self.admin_after(&gone).map(|a| admin_record(&a));
            let others = |e: &Extensions<GroupContext>| {
                e.iter().filter(|x| x.extension_type() != ExtensionType::ExternalSenders).cloned().collect::<Vec<_>>()
            };
            let record_ok = admin_in(new) == want.as_ref() || (admin_in(old).is_none() && admin_in(new).is_none());
            if !record_ok || others(old) != others(new) {
                warn!(group_id = %hex::encode(&self.group_id), "refused a commit that sets the wrong admin");
                return Ok((IncomingMessage::Other, None));
            }
        }
        // ADR-075 — someone entered by the chat's card (external commit):
        // only a device of a person who already has a leaf here — a phone
        // they signed in again. Anyone else is not let in (the server
        // checks the same, so this only fires with a misbehaving server).
        if matches!(processed.sender(), Sender::NewMemberCommit) {
            let ok = <[u8; 32]>::try_from(sender.as_slice()).map(|p| !self.device_keys_of(&p).is_empty()).unwrap_or(false);
            if !ok {
                warn!(group_id = %hex::encode(&self.group_id), "refused an external join by someone not in this chat");
                return Ok((IncomingMessage::Other, None));
            }
            info!(group_id = %hex::encode(&self.group_id), "a member's new device joined by the chat's card");
        }
        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app) => {
                // Audit CM-09 — no proven sender (someone since removed,
                // writing in an older epoch; a leaf that names nobody): not
                // shown. It used to pass as "from the other side".
                if sender.is_empty() {
                    warn!(group_id = %hex::encode(&self.group_id), "dropped a message whose sender is not a member");
                    return Ok((IncomingMessage::Other, None));
                }
                let bytes = app.into_bytes();
                debug!(group_id = %hex::encode(&self.group_id), bytes = bytes.len(), "decrypted app msg");
                return Ok((IncomingMessage::App(bytes), Some(sender)));
            }
            ProcessedMessageContent::StagedCommitMessage(commit) => {
                self.group
                    .merge_staged_commit(provider, *commit)
                    .map_err(|e| GroupError::Process(format!("merge_staged: {e:?}")))?;
                let epoch = self.group.epoch().as_u64();
                info!(group_id = %hex::encode(&self.group_id), new_epoch = epoch, "commit applied");
                Ok((IncomingMessage::Commit { new_epoch: epoch, added, removed }, (!sender.is_empty()).then_some(sender)))
            }
            _ => Ok((IncomingMessage::Other, None)),
        }
    }
}

/// ADR-100 — the leaf that signed a card: an Ed25519 GroupInfo ends with the
/// signer's leaf index (4 bytes) and the 64-byte signature behind its
/// two-byte length. `None`: not a card of our cipher suite.
pub fn card_signer(card: &[u8]) -> Option<u32> {
    let tail = card.len().checked_sub(4 + 2 + 64)?;
    (card[tail + 4..tail + 6] == [0x40, 0x40]).then(|| u32::from_be_bytes([card[tail], card[tail + 1], card[tail + 2], card[tail + 3]]))
}

/// ADR-092 — the epoch a Commit was made at, from its plain header (RFC 9420
/// §6); `None` for anything else (an application message, a proposal, no
/// MLS at all). Read exactly as the server reads it (`ws::mls_commit_head`):
/// whatever it orders as a Commit — garbage behind the header included — is
/// a Commit here too, so a phone can say it saw it and did not take it.
pub fn commit_epoch(b: &[u8]) -> Option<u64> {
    // A variable-length vector: 2-bit width (1, 2 or 4 bytes), then the bytes.
    fn skip(b: &[u8], at: &mut usize) -> Option<()> {
        let width = [1usize, 2, 4].get(usize::from(*b.get(*at)? >> 6)).copied()?;
        let len = b.get(*at..*at + width)?.iter().fold(0usize, |v, x| (v << 8) | usize::from(*x)) & ((1 << (8 * width - 2)) - 1);
        b.get(*at + width..*at + width + len)?;
        *at += width + len;
        Some(())
    }
    let wire = u16::from_be_bytes(b.get(2..4)?.try_into().ok()?);
    let mut at = 4;
    skip(b, &mut at)?;
    let epoch = u64::from_be_bytes(b.get(at..at + 8)?.try_into().ok()?);
    at += 8;
    let content_type = match wire {
        2 => *b.get(at)?,
        1 => {
            at += match *b.get(at)? {
                1 | 2 => 5,
                3 | 4 => 1,
                _ => return None,
            };
            skip(b, &mut at)?;
            *b.get(at)?
        }
        _ => return None,
    };
    (content_type == 3).then_some(epoch)
}

/// ADR-088 — the admin's record in the group context: the standard
/// `external_senders` extension with one entry, the admin's identity key.
/// Every phone supports this extension type already, so old chats take it
/// on at their next Commit with no capability upgrade (a custom extension
/// type would need every leaf, dead phones too, to announce it first). The
/// app never processes proposals, so the entry grants nothing.
pub(crate) fn admin_record(identity: &[u8; 32]) -> Extension {
    Extension::ExternalSenders(vec![ExternalSender::new(
        identity.to_vec().into(),
        BasicCredential::new(identity.to_vec()).into(),
    )])
}

/// ADR-088 — the admin record in a group context, if there is one.
fn admin_in(ext: &Extensions<GroupContext>) -> Option<&Extension> {
    ext.iter().find(|e| e.extension_type() == ExtensionType::ExternalSenders)
}

/// A Commit waiting for the server's verdict — [`GroupHandle::add_member_pending`].
#[derive(Debug, Clone)]
pub struct PendingCommit {
    /// The epoch the Commit was made in (`Submit.commit_epoch`).
    pub epoch: u64,
    pub commit_bytes: Vec<u8>,
    pub welcome_bytes: Option<Vec<u8>>,
}

/// Output of [`GroupHandle::add_member`].
pub struct AddMemberOutcome {
    /// MLS Commit frame — broadcast to existing group members so they
    /// can advance their epoch.
    pub commit_bytes: Vec<u8>,
    /// MLS Welcome frame — sent to the new member only.
    pub welcome_bytes: Vec<u8>,
}

#[derive(Debug, thiserror::Error)]
pub enum GroupError {
    #[error("group create failed: {0}")]
    Create(String),
    #[error("group load failed: {0}")]
    Load(String),
    #[error("invalid key package: {0}")]
    InvalidKeyPackage(String),
    #[error("add member failed: {0}")]
    AddMember(String),
    #[error("create message failed: {0}")]
    CreateMessage(String),
    #[error("process message failed: {0}")]
    Process(String),
    #[error("wrong message type: {0}")]
    WrongMessageType(String),
    #[error("tls_codec serialize: {0}")]
    Serialize(String),
    #[error("tls_codec deserialize: {0}")]
    Deserialize(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls_rust_crypto::OpenMlsRustCrypto;

    const PHRASE: &str = "abandon abandon abandon abandon abandon abandon \
                          abandon abandon abandon abandon abandon abandon \
                          abandon abandon abandon abandon abandon abandon \
                          abandon abandon abandon abandon abandon art";

    /// A group persisted before PADDING_SIZE existed (padding_size = 0)
    /// is upgraded on load, the upgrade is written back to storage, and
    /// the other join-config fields survive the serde round-trip.
    #[test]
    fn try_load_upgrades_unpadded_group() {
        let provider = OpenMlsRustCrypto::default();
        let me = MlsIdentity::from_phrase(&provider, PHRASE).unwrap();
        let legacy_config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .build();
        let legacy =
            MlsGroup::new(&provider, &me.signer, &legacy_config, me.credential.clone()).unwrap();
        assert_eq!(legacy.configuration().padding_size(), 0);
        let gid = legacy.group_id().to_vec();
        drop(legacy);

        let handle = GroupHandle::try_load(&provider, &gid).unwrap().unwrap();
        assert_eq!(handle.group.configuration().padding_size(), PADDING_SIZE);
        assert_eq!(
            handle.group.configuration(),
            &with_padding(legacy_config.join_config()).unwrap(),
        );

        let reloaded = MlsGroup::load(provider.storage(), &GroupId::from_slice(&gid))
            .unwrap()
            .unwrap();
        assert_eq!(reloaded.configuration().padding_size(), PADDING_SIZE);
    }
}
