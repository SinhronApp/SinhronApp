// In-memory CallSession registry — WU CB3.
//
// Tracks active 1:1 and group calls (tech-debt 4.9, 2026-10-13) so the
// server can:
//   1. Reject duplicate `CallInvite` for the same group (one call per group)
//   2. Authorize `CallAccept` / `CallEnd` (only the caller or an invitee)
//   3. Auto-expire stuck "Ringing" calls (CB5 watchdog)
//   4. Surface metrics (active calls, total served)
//
// Storage is process-local — multi-replica deploys would need shared
// state (Redis), but v1 self-hosted operator runs single-replica. Sessions
// don't survive server restarts; in-progress calls drop. Client sees
// "Disconnected" via WS close + reconnects.
//
// Design note: a session is removed shortly AFTER its terminal state
// (5-second grace) so a late-arriving `CallEnd` from either side gets
// a normal ack instead of "unknown call_id". This makes signaling
// idempotent at the cost of a brief retention window.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use parking_lot::RwLock;
use uuid::Uuid;

/// Lifecycle state of a single call session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallStatus {
    /// Server has forwarded `CallInvite` to the callee. Awaiting
    /// `CallAccept`. Times out after `RINGING_TIMEOUT_SECS`.
    Ringing,
    /// Callee accepted. Both clients are connecting to LiveKit room.
    Active,
    /// Either side sent `CallEnd` (or timeout / network drop). Held for
    /// `GRACE_SECS` so late `CallEnd` from the other side is idempotent.
    Ended,
}

/// What kind of call this is — affects only metadata + UI; signaling
/// shape is identical.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CallKind {
    Audio,
    Video,
}

/// All known facts about an in-flight call. The registry holds one of
/// these per active `call_id`.
#[derive(Debug, Clone)]
pub struct CallSession {
    pub call_id: Uuid,
    pub group_id: Vec<u8>,
    pub caller_user_pk: Uuid,
    /// The caller's identity key — in every invite, so a phone can ignore a
    /// call from someone it blocked (tech-debt 2.27).
    pub caller_identity: Vec<u8>,
    /// ADR-090 (calls:5) — the caller's signature on the invite, passed on
    /// as is (to the invite, its replays and the VoIP push).
    pub caller_proof: Vec<u8>,
    /// Everyone invited — one user for a 1:1 call, the rest of the group
    /// for a group call.
    pub invitees: Vec<Uuid>,
    /// Invitees who picked up (a group call grows as people join).
    pub joined: Vec<Uuid>,
    /// Who declined or hung up (caller included). Not notified again.
    pub gone: Vec<Uuid>,
    /// Status 182 — invitees whose phone was already pushed for this call,
    /// or who must never be (no key: the open app only). The others got the
    /// invite down an open connection; if that connection closes while the
    /// call still rings (an iPhone going to the background), they get the
    /// push then ([CallSessionRegistry::take_unwoken]).
    pub woken: Vec<Uuid>,
    /// calls:10 — invitees the caller holds no key for (the open app only):
    /// the caller is never told the invite reached them.
    pub quiet: Vec<Uuid>,
    pub kind: CallKind,
    pub livekit_room: String,
    pub status: CallStatus,
    /// Wall-clock for diagnostics + metrics. We don't use this for
    /// timeouts — `last_activity` (monotonic) is the timeout source.
    pub created_at_unix: i64,
    /// Monotonic timestamp of the most recent state change. Used by
    /// `gc_expired` to evict Ringing-stuck and Ended-grace entries.
    pub last_activity: Instant,
}

impl CallSession {
    pub fn is_group(&self) -> bool {
        self.invitees.len() > 1
    }

    /// The only invitee of a 1:1 call.
    pub fn callee(&self) -> Option<Uuid> {
        (!self.is_group()).then(|| self.invitees.first().copied()).flatten()
    }

    fn is_party(&self, u: Uuid) -> bool {
        u == self.caller_user_pk || self.invitees.contains(&u)
    }

    /// In the call right now: the caller (until they leave) + joiners.
    pub fn present(&self) -> Vec<Uuid> {
        std::iter::once(self.caller_user_pk)
            .chain(self.joined.iter().copied())
            .filter(|u| !self.gone.contains(u))
            .collect()
    }

    /// Invitees still ringing (neither joined nor declined).
    pub fn pending(&self) -> Vec<Uuid> {
        self.invitees
            .iter()
            .copied()
            .filter(|u| !self.joined.contains(u) && !self.gone.contains(u))
            .collect()
    }

    /// Everyone to tell when the whole call ends.
    pub fn reachable(&self) -> Vec<Uuid> {
        let mut v = self.present();
        v.extend(self.pending());
        v
    }
}

/// Result of [`CallSessionRegistry::leave`].
#[derive(Debug, PartialEq, Eq)]
pub enum LeaveOutcome {
    Unknown,
    Unauthorized,
    /// `call_ended`: the whole call is over (1:1 always; group when the
    /// last-but-one person left or the caller cancelled before anyone
    /// joined). `notify`: who gets a CallEnd (empty when a group call
    /// simply goes on without this person — LiveKit shows them leave).
    Left { call_ended: bool, notify: Vec<Uuid> },
}

/// Server-wide CallSession store. Cheap to clone (Arc inside) so the
/// registry can be wired into [`AppState`] and accessed from any handler.
#[derive(Clone, Default)]
pub struct CallSessionRegistry {
    inner: Arc<RwLock<HashMap<Uuid, CallSession>>>,
    /// 2026-10-26 — (call, person) → the device that answered: a device of
    /// theirs that connects later (woken by a push) is told to stop ringing.
    answered_on: Arc<RwLock<HashMap<(Uuid, Uuid), Vec<u8>>>>,
}

/// How long a Ringing call stays valid before auto-ending. Spec §10
/// doesn't pin this; standard telephony is ~30s. Capped at 60 server-side
/// regardless of client-requested `ttl_secs`.
pub const RINGING_TIMEOUT_SECS: u64 = 30;

/// Hard upper bound on `CallInvite.ttl_secs` — server caps client
/// requests above this. Prevents a malicious client from holding
/// half-open sessions forever.
pub const RINGING_TIMEOUT_MAX_SECS: u64 = 60;

/// Linger interval after a call transitions to Ended. Lets late
/// `CallEnd` from the opposite side ack-202 instead of 404-style error.
pub const GRACE_SECS: u64 = 5;

/// Outcome of [`CallSessionRegistry::start_call`].
#[derive(Debug, PartialEq, Eq)]
pub enum StartCallOutcome {
    Started,
    /// Another active (Ringing or Active) call already exists for this
    /// group. Caller should display "busy" or just refuse.
    GroupBusy,
    /// `call_id` already exists in the registry (collision or replay).
    /// Caller should regenerate a fresh UUIDv7 and retry.
    DuplicateCallId,
}

/// Outcome of state-transition methods.
#[derive(Debug, PartialEq, Eq)]
pub enum CallUpdateOutcome {
    /// State changed.
    Updated,
    /// `call_id` not found in the registry (or already evicted past
    /// grace).
    Unknown,
    /// User is neither caller nor callee — refuse to apply.
    Unauthorized,
    /// Transition was invalid (e.g. trying to Accept after End).
    InvalidTransition,
}

impl CallSessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Try to register a new call. Returns:
    ///   * `GroupBusy` — another call for this group is Ringing/Active
    ///   * `DuplicateCallId` — this `call_id` already in the registry
    ///     (UUIDv7 collision astronomically rare but possible if a
    ///     malicious client replays an old id)
    ///   * `Started` — session inserted
    pub fn start_call(&self, session: CallSession) -> StartCallOutcome {
        let mut map = self.inner.write();
        if map.contains_key(&session.call_id) {
            return StartCallOutcome::DuplicateCallId;
        }
        let busy = map.values().any(|s| {
            s.group_id == session.group_id
                && (s.status == CallStatus::Ringing || s.status == CallStatus::Active)
        });
        if busy {
            return StartCallOutcome::GroupBusy;
        }
        map.insert(session.call_id, session);
        StartCallOutcome::Started
    }

    /// An invitee picks up. 1:1: Ringing → Active. Group: anyone invited
    /// can join while it rings or is already running, and anyone in the
    /// group who declined or left — the caller too — can come back while
    /// it runs ("Join" in the chat). The caller can never "accept" their
    /// own ringing call.
    pub fn accept(&self, call_id: Uuid, actor: Uuid) -> CallUpdateOutcome {
        let mut map = self.inner.write();
        let Some(s) = map.get_mut(&call_id) else {
            return CallUpdateOutcome::Unknown;
        };
        if !s.is_party(actor) {
            return CallUpdateOutcome::Unauthorized;
        }
        if s.status == CallStatus::Ended {
            return CallUpdateOutcome::InvalidTransition;
        }
        // Coming back to a group call I declined or left.
        if s.is_group() && s.gone.contains(&actor) {
            s.gone.retain(|u| *u != actor);
            if actor != s.caller_user_pk && !s.joined.contains(&actor) {
                s.joined.push(actor);
            }
            s.status = CallStatus::Active;
            s.last_activity = Instant::now();
            return CallUpdateOutcome::Updated;
        }
        let can_join = match s.status {
            CallStatus::Ringing => true,
            CallStatus::Active => s.is_group(),
            CallStatus::Ended => false,
        };
        if actor == s.caller_user_pk {
            return CallUpdateOutcome::Unauthorized; // can't accept my own ring
        }
        if !can_join || s.joined.contains(&actor) || s.gone.contains(&actor) {
            return CallUpdateOutcome::InvalidTransition;
        }
        s.joined.push(actor);
        s.status = CallStatus::Active;
        s.last_activity = Instant::now();
        CallUpdateOutcome::Updated
    }

    /// `actor` declines or hangs up. See [`LeaveOutcome`].
    pub fn leave(&self, call_id: Uuid, actor: Uuid) -> LeaveOutcome {
        let mut map = self.inner.write();
        let Some(s) = map.get_mut(&call_id) else {
            return LeaveOutcome::Unknown;
        };
        if !s.is_party(actor) {
            return LeaveOutcome::Unauthorized;
        }
        if s.status == CallStatus::Ended {
            // Double hang-up race — idempotent.
            return LeaveOutcome::Left { call_ended: true, notify: Vec::new() };
        }
        let was_ringing = s.status == CallStatus::Ringing;
        // Only a first decline counts as activity: repeated ones kept a
        // ringing group call alive past its timeout.
        if !s.gone.contains(&actor) {
            s.gone.push(actor);
            s.last_activity = Instant::now();
        }
        let present = s.present();
        let pending = s.pending();
        let ended = !s.is_group()
            || present.is_empty()
            || (present.len() == 1 && pending.is_empty())
            || (was_ringing && actor == s.caller_user_pk);
        if !ended {
            return LeaveOutcome::Left { call_ended: false, notify: Vec::new() };
        }
        s.status = CallStatus::Ended;
        s.last_activity = Instant::now();
        // Everyone in the group hears that it ended — also those who declined
        // or left, so their "Call in progress · Join" goes away.
        let mut notify: Vec<Uuid> = std::iter::once(s.caller_user_pk)
            .chain(s.invitees.iter().copied())
            .filter(|u| *u != actor)
            .collect();
        notify.dedup();
        LeaveOutcome::Left { call_ended: true, notify }
    }

    /// Compatibility wrapper over [`leave`] for callers that only need
    /// authorization (Updated / Unknown / Unauthorized).
    pub fn end(&self, call_id: Uuid, actor: Uuid) -> CallUpdateOutcome {
        match self.leave(call_id, actor) {
            LeaveOutcome::Unknown => CallUpdateOutcome::Unknown,
            LeaveOutcome::Unauthorized => CallUpdateOutcome::Unauthorized,
            LeaveOutcome::Left { .. } => CallUpdateOutcome::Updated,
        }
    }

    /// Drop sessions that are:
    ///   • Ringing > RINGING_TIMEOUT_SECS — auto-expired, returned so
    ///     the caller can broadcast `CallEnd { reason: "no_answer" }`
    ///   • Ended > GRACE_SECS — fully evicted, no further notifications
    ///
    /// Returns the list of expired sessions (status was Ringing). Callers
    /// (CB5 watchdog) iterate them to send terminal CallEnd frames.
    pub fn gc_expired(&self) -> Vec<CallSession> {
        let now = Instant::now();
        let mut map = self.inner.write();
        let mut expired_ringing = Vec::new();
        map.retain(|_id, s| {
            let elapsed = now.saturating_duration_since(s.last_activity);
            match s.status {
                CallStatus::Ringing if elapsed >= Duration::from_secs(RINGING_TIMEOUT_SECS) => {
                    expired_ringing.push(s.clone());
                    false // drop
                }
                CallStatus::Ended if elapsed >= Duration::from_secs(GRACE_SECS) => {
                    false // drop
                }
                _ => true, // keep
            }
        });
        expired_ringing
    }

    /// The group's Active call, untouched (no join / leave) for [min_idle]:
    /// marked Ended and returned, to tell its people. Called when LiveKit
    /// says its room is empty — everyone left without a CallEnd and the
    /// group stayed "busy" until a restart (server-ws:5).
    pub fn end_stale(&self, group_id: &[u8], min_idle: Duration) -> Option<CallSession> {
        let mut map = self.inner.write();
        let s = map.values_mut().find(|s| {
            s.group_id == group_id && s.status == CallStatus::Active && s.last_activity.elapsed() >= min_idle
        })?;
        s.status = CallStatus::Ended;
        s.last_activity = Instant::now();
        Some(s.clone())
    }

    /// Read-only lookup. Used by the WS handlers to display info / log
    /// metadata + by tests to assert state.
    /// Calls that still ring for [user]: invited, neither joined nor
    /// declined, call not over (overnight item 9 — replay on login).
    pub fn ringing_for(&self, user: Uuid) -> Vec<CallSession> {
        let map = self.inner.read();
        map.values()
            .filter(|s| s.status != CallStatus::Ended && s.pending().contains(&user))
            .cloned()
            .collect()
    }

    /// Status 182 — [users] were pushed (or must never be) for [call_id].
    pub fn mark_woken(&self, call_id: &Uuid, users: impl IntoIterator<Item = Uuid>) {
        if let Some(s) = self.inner.write().get_mut(call_id) {
            for u in users {
                if !s.woken.contains(&u) {
                    s.woken.push(u);
                }
            }
        }
    }

    /// Status 182 — calls still ringing for [user] whose phone hasn't been
    /// pushed yet; each is marked pushed (returned once).
    pub fn take_unwoken(&self, user: Uuid) -> Vec<CallSession> {
        let mut map = self.inner.write();
        let mut out = Vec::new();
        for s in map.values_mut() {
            if s.status != CallStatus::Ended && s.pending().contains(&user) && !s.woken.contains(&user) {
                s.woken.push(user);
                out.push(s.clone());
            }
        }
        out
    }

    /// [user] answered [call_id] on [device].
    pub fn note_answered_on(&self, call_id: Uuid, user: Uuid, device: &[u8]) {
        // Same lock order as [answered_elsewhere]: calls first.
        let live = self.inner.read();
        let mut m = self.answered_on.write();
        m.retain(|(c, _), _| live.get(c).is_some_and(|s| s.status != CallStatus::Ended));
        m.insert((call_id, user), device.to_vec());
    }

    /// Calls still on that [user] answered on a device other than [device]
    /// (it may still show them ringing).
    pub fn answered_elsewhere(&self, user: Uuid, device: &[u8]) -> Vec<Uuid> {
        let live = self.inner.read();
        self.answered_on
            .read()
            .iter()
            .filter(|((c, u), d)| *u == user && d.as_slice() != device && live.get(c).is_some_and(|s| s.status != CallStatus::Ended))
            .map(|((c, _), _)| *c)
            .collect()
    }

    pub fn get(&self, call_id: &Uuid) -> Option<CallSession> {
        self.inner.read().get(call_id).cloned()
    }

    /// Count active (non-Ended) sessions. Surfaced as the Prometheus
    /// gauge `calls_active`.
    pub fn count_active(&self) -> usize {
        self.inner
            .read()
            .values()
            .filter(|s| s.status != CallStatus::Ended)
            .count()
    }

    /// Total session count including grace-period Ended ones. Used by
    /// the watchdog to size its sleep interval.
    pub fn len(&self) -> usize {
        self.inner.read().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk_session(caller: Uuid, callee: Uuid, group: &[u8], status: CallStatus) -> CallSession {
        CallSession {
            call_id: Uuid::now_v7(),
            group_id: group.to_vec(),
            caller_user_pk: caller,
            caller_identity: Vec::new(),
            caller_proof: Vec::new(),
            invitees: vec![callee],
            joined: Vec::new(),
            gone: Vec::new(),
            woken: Vec::new(),
            quiet: Vec::new(),
            kind: CallKind::Audio,
            livekit_room: "sinhron-call-test".to_string(),
            status,
            created_at_unix: 1_700_000_000,
            last_activity: Instant::now(),
        }
    }

    #[test]
    fn start_call_first_succeeds_then_busy() {
        let reg = CallSessionRegistry::new();
        let a = Uuid::now_v7();
        let b = Uuid::now_v7();

        let s1 = mk_session(a, b, b"group1", CallStatus::Ringing);
        assert_eq!(reg.start_call(s1.clone()), StartCallOutcome::Started);

        // Second invite for the SAME group while first is Ringing → busy.
        let s2 = mk_session(a, b, b"group1", CallStatus::Ringing);
        assert_eq!(reg.start_call(s2), StartCallOutcome::GroupBusy);
    }

    #[test]
    fn start_call_different_groups_concurrent() {
        let reg = CallSessionRegistry::new();
        let a = Uuid::now_v7();
        let b = Uuid::now_v7();

        let s1 = mk_session(a, b, b"group1", CallStatus::Ringing);
        let s2 = mk_session(a, b, b"group2", CallStatus::Ringing);
        assert_eq!(reg.start_call(s1), StartCallOutcome::Started);
        assert_eq!(reg.start_call(s2), StartCallOutcome::Started);
        assert_eq!(reg.count_active(), 2);
    }

    #[test]
    fn accept_only_callee_allowed() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();
        let third = Uuid::now_v7();

        let s = mk_session(caller, callee, b"g", CallStatus::Ringing);
        let cid = s.call_id;
        reg.start_call(s);

        // Caller can't accept their own call.
        assert_eq!(reg.accept(cid, caller), CallUpdateOutcome::Unauthorized);
        // Stranger can't accept.
        assert_eq!(reg.accept(cid, third), CallUpdateOutcome::Unauthorized);
        // Callee can.
        assert_eq!(reg.accept(cid, callee), CallUpdateOutcome::Updated);

        let after = reg.get(&cid).expect("still present");
        assert_eq!(after.status, CallStatus::Active);
    }

    #[test]
    fn accept_after_end_is_invalid() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();

        let s = mk_session(caller, callee, b"g", CallStatus::Ringing);
        let cid = s.call_id;
        reg.start_call(s);
        assert_eq!(reg.end(cid, caller), CallUpdateOutcome::Updated);
        assert_eq!(reg.accept(cid, callee), CallUpdateOutcome::InvalidTransition);
    }

    #[test]
    fn end_by_either_side_is_authorized() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();

        let s = mk_session(caller, callee, b"g1", CallStatus::Active);
        let cid = s.call_id;
        reg.start_call(s);
        // Caller ends — ok.
        assert_eq!(reg.end(cid, caller), CallUpdateOutcome::Updated);

        // Second end — still Updated (idempotent for double-end-race).
        // Both sides can hang up simultaneously; we don't want the second
        // CallEnd to look like an error.
        assert_eq!(reg.end(cid, callee), CallUpdateOutcome::Updated);
    }

    #[test]
    fn end_by_third_party_unauthorized() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();
        let stranger = Uuid::now_v7();

        let s = mk_session(caller, callee, b"g", CallStatus::Ringing);
        let cid = s.call_id;
        reg.start_call(s);

        assert_eq!(reg.end(cid, stranger), CallUpdateOutcome::Unauthorized);
    }

    #[test]
    fn end_unknown_call_id() {
        let reg = CallSessionRegistry::new();
        assert_eq!(
            reg.end(Uuid::now_v7(), Uuid::now_v7()),
            CallUpdateOutcome::Unknown
        );
    }

    #[test]
    fn gc_expired_ringing_returns_session_for_notification() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();

        let mut s = mk_session(caller, callee, b"g", CallStatus::Ringing);
        // Backdate so it's expired.
        s.last_activity = Instant::now() - Duration::from_secs(RINGING_TIMEOUT_SECS + 1);
        let cid = s.call_id;
        let mut map = reg.inner.write();
        map.insert(cid, s);
        drop(map);

        let expired = reg.gc_expired();
        assert_eq!(expired.len(), 1, "ringing-timeout returns the session");
        assert_eq!(expired[0].call_id, cid);
        assert!(reg.get(&cid).is_none(), "evicted from registry");
    }

    #[test]
    fn gc_evicts_ended_after_grace() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();

        let mut s = mk_session(caller, callee, b"g", CallStatus::Ended);
        s.last_activity = Instant::now() - Duration::from_secs(GRACE_SECS + 1);
        let cid = s.call_id;
        let mut map = reg.inner.write();
        map.insert(cid, s);
        drop(map);

        let expired = reg.gc_expired();
        // Ended sessions are silently dropped — NOT returned for
        // notification. They've already had their CallEnd frame.
        assert_eq!(expired.len(), 0);
        assert!(reg.get(&cid).is_none());
    }

    #[test]
    fn gc_keeps_recent_sessions() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();

        let s = mk_session(caller, callee, b"g", CallStatus::Ringing);
        let cid = s.call_id;
        reg.start_call(s);

        let expired = reg.gc_expired();
        assert_eq!(expired.len(), 0, "fresh ringing not expired");
        assert!(reg.get(&cid).is_some(), "still present");
    }

    #[test]
    fn count_active_excludes_ended() {
        let reg = CallSessionRegistry::new();
        let caller = Uuid::now_v7();
        let callee = Uuid::now_v7();

        let s1 = mk_session(caller, callee, b"g1", CallStatus::Active);
        let s2 = mk_session(caller, callee, b"g2", CallStatus::Ringing);
        let mut s3 = mk_session(caller, callee, b"g3", CallStatus::Ended);
        s3.last_activity = Instant::now(); // within grace
        reg.start_call(s1);
        reg.start_call(s2);
        let mut map = reg.inner.write();
        map.insert(s3.call_id, s3);
        drop(map);

        assert_eq!(reg.count_active(), 2);
        assert_eq!(reg.len(), 3); // including the Ended one
    }

    fn mk_group(caller: Uuid, invitees: &[Uuid]) -> CallSession {
        CallSession { invitees: invitees.to_vec(), ..mk_session(caller, invitees[0], b"team", CallStatus::Ringing) }
    }

    #[test]
    fn group_call_people_join_and_leave_until_one_is_left() {
        let reg = CallSessionRegistry::new();
        let (a, b, c, d) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let s = mk_group(a, &[b, c, d]);
        let cid = s.call_id;
        reg.start_call(s);

        assert_eq!(reg.accept(cid, b), CallUpdateOutcome::Updated);
        assert_eq!(reg.get(&cid).unwrap().status, CallStatus::Active);
        // A late joiner may still come in while the call runs.
        assert_eq!(reg.accept(cid, c), CallUpdateOutcome::Updated);
        assert_eq!(reg.accept(cid, c), CallUpdateOutcome::InvalidTransition, "can't join twice");
        // D declines; the call goes on.
        assert_eq!(reg.leave(cid, d), LeaveOutcome::Left { call_ended: false, notify: vec![] });
        // The caller leaves; B and C keep talking.
        assert_eq!(reg.leave(cid, a), LeaveOutcome::Left { call_ended: false, notify: vec![] });
        assert_eq!(reg.get(&cid).unwrap().status, CallStatus::Active);
        // B leaves → only C remains → over; everyone in the group is told
        // (A and D too: their "Join" goes away).
        match reg.leave(cid, b) {
            LeaveOutcome::Left { call_ended: true, mut notify } => {
                notify.sort();
                let mut want = vec![a, c, d];
                want.sort();
                assert_eq!(notify, want);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(reg.get(&cid).unwrap().status, CallStatus::Ended);
    }

    #[test]
    fn group_caller_cancelling_before_anyone_joins_stops_every_ring() {
        let reg = CallSessionRegistry::new();
        let (a, b, c) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let s = mk_group(a, &[b, c]);
        let cid = s.call_id;
        reg.start_call(s);
        match reg.leave(cid, a) {
            LeaveOutcome::Left { call_ended: true, mut notify } => {
                notify.sort();
                let mut want = vec![b, c];
                want.sort();
                assert_eq!(notify, want);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn group_everyone_declining_ends_the_call_for_the_caller() {
        let reg = CallSessionRegistry::new();
        let (a, b, c) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let s = mk_group(a, &[b, c]);
        let cid = s.call_id;
        reg.start_call(s);
        assert_eq!(reg.leave(cid, b), LeaveOutcome::Left { call_ended: false, notify: vec![] });
        match reg.leave(cid, c) {
            LeaveOutcome::Left { call_ended: true, mut notify } => {
                notify.sort();
                let mut want = vec![a, b];
                want.sort();
                assert_eq!(notify, want);
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(reg.accept(cid, b), CallUpdateOutcome::InvalidTransition);
    }

    // Owner, 2026-10-15: "join a group call that is already going".
    #[test]
    fn group_member_who_declined_or_left_can_come_back_while_it_runs() {
        let reg = CallSessionRegistry::new();
        let (a, b, c, d) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let s = mk_group(a, &[b, c, d]);
        let cid = s.call_id;
        reg.start_call(s);
        assert_eq!(reg.accept(cid, a), CallUpdateOutcome::Unauthorized, "caller can't accept own ring");
        assert_eq!(reg.accept(cid, b), CallUpdateOutcome::Updated);
        // D declined the ring, then changes their mind.
        assert_eq!(reg.leave(cid, d), LeaveOutcome::Left { call_ended: false, notify: vec![] });
        assert_eq!(reg.accept(cid, d), CallUpdateOutcome::Updated);
        assert!(reg.get(&cid).unwrap().present().contains(&d));
        // The caller steps out and back in.
        assert_eq!(reg.leave(cid, a), LeaveOutcome::Left { call_ended: false, notify: vec![] });
        assert_eq!(reg.accept(cid, a), CallUpdateOutcome::Updated);
        assert!(reg.get(&cid).unwrap().present().contains(&a));
        // A stranger can't.
        assert_eq!(reg.accept(cid, Uuid::now_v7()), CallUpdateOutcome::Unauthorized);
        assert_eq!(reg.accept(cid, c), CallUpdateOutcome::Updated, "late joiner still fine");
    }

    #[test]
    fn one_to_one_semantics_unchanged() {
        let reg = CallSessionRegistry::new();
        let (a, b) = (Uuid::now_v7(), Uuid::now_v7());
        let s = mk_session(a, b, b"pair", CallStatus::Ringing);
        let cid = s.call_id;
        reg.start_call(s);
        assert_eq!(reg.accept(cid, b), CallUpdateOutcome::Updated);
        assert_eq!(reg.accept(cid, b), CallUpdateOutcome::InvalidTransition);
        assert_eq!(reg.leave(cid, b), LeaveOutcome::Left { call_ended: true, notify: vec![a] });
    }

    /// Status 182 — a callee who got the invite down an open connection is
    /// pushed once when it closes; one already pushed (or never to be) isn't.
    #[test]
    fn a_ringing_call_is_pushed_once_after_the_connection_closes() {
        let reg = CallSessionRegistry::new();
        let (caller, a, b) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let s = mk_group(caller, &[a, b]);
        let id = s.call_id;
        assert!(matches!(reg.start_call(s), StartCallOutcome::Started));
        reg.mark_woken(&id, [b]); // b was offline: pushed at invite time
        let got = reg.take_unwoken(a);
        assert_eq!(got.len(), 1, "a was online: pushed now");
        assert_eq!(got[0].call_id, id);
        assert!(reg.take_unwoken(a).is_empty(), "only once");
        assert!(reg.take_unwoken(b).is_empty(), "b was already pushed");
        assert!(reg.take_unwoken(caller).is_empty(), "the caller isn't invited");
    }

}

#[cfg(test)]
mod ring_deadline_tests {
    use super::*;

    /// An invitee of a group call that still rings sent CallEnd again and
    /// again: each one moved `last_activity`, the ringing never timed out —
    /// the phones rang and the group stayed "busy" for as long as they liked.
    #[test]
    fn declining_again_does_not_keep_a_group_call_ringing() {
        let reg = CallSessionRegistry::new();
        let (alice, bob, mallory) = (Uuid::now_v7(), Uuid::now_v7(), Uuid::now_v7());
        let id = Uuid::now_v7();
        let old = Instant::now() - Duration::from_secs(RINGING_TIMEOUT_SECS + 10);
        reg.start_call(CallSession {
            call_id: id,
            group_id: b"g".to_vec(),
            caller_user_pk: alice,
            caller_identity: Vec::new(),
            caller_proof: Vec::new(),
            invitees: vec![bob, mallory],
            joined: Vec::new(),
            gone: vec![mallory],
            woken: Vec::new(),
            quiet: Vec::new(),
            kind: CallKind::Audio,
            livekit_room: String::new(),
            status: CallStatus::Ringing,
            created_at_unix: 0,
            last_activity: old,
        });
        // Mallory already declined; she "declines" once more.
        assert_eq!(reg.leave(id, mallory), LeaveOutcome::Left { call_ended: false, notify: Vec::new() });
        assert_eq!(reg.gc_expired().len(), 1, "the ringing still times out");
    }
}
