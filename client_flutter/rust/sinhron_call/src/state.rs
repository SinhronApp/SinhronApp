// Call FSM — local view of a single call's lifecycle.
//
// The server has its own CallSessionRegistry (server/src/call_session.rs)
// — this module is the CLIENT-side mirror. Each client device runs one
// instance per active call.
//
// States:
//
//             ┌──────────────┐
//   ──────────▶   Idle       │
//             └──────────────┘
//                  │ local invite
//                  ▼
//             ┌──────────────┐                Local end
//             │  Inviting    │ ─────────────────────────────┐
//             └──────────────┘                              │
//                  │ server CallRing                        │
//                  ▼                                        │
//             ┌──────────────┐                              │
//             │  Ringing     │  Local end / timeout         │
//             └──────────────┘ ─────────────────────────────┤
//                  │ remote Accept                          │
//                  ▼                                        │
//             ┌──────────────┐                              │
//             │  Active      │  Either-side end             │
//             └──────────────┘ ─────────────────────────────┤
//                                                           ▼
//                                              ┌────────────────┐
//                                              │     Ended      │
//                                              └────────────────┘
//
// `Idle` is the implicit pre-state — we instantiate the FSM in
// `Inviting` (outgoing) or `Ringing` (incoming). `Ended` is terminal:
// once there, no transitions accepted.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Caller vs callee. Determines which transitions are valid given a
/// network event (only the callee may `Accept`, etc.).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CallRole {
    Caller,
    Callee,
}

/// Re-export — semantically the same id used by server. Kept as
/// `Uuid` alias for ergonomic call-site reading.
pub type CallId = Uuid;

/// Lifecycle states. `Ringing` covers both "outgoing & waiting for
/// pickup" and "incoming & user hasn't decided yet" — the role
/// disambiguates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CallState {
    /// Outgoing call we just started — awaiting `CallRing` from server.
    Inviting,
    /// Either: (caller) server confirmed delivery, ringing on callee
    /// side OR (callee) we received an incoming CallInvite, awaiting
    /// user choice.
    Ringing,
    /// Both sides connected; LiveKit room is the source of truth for
    /// media. Local UI shows the call screen.
    Active,
    /// Terminal — either side ended, network dropped permanently,
    /// rejected, no-answer, etc. No further transitions accepted.
    Ended,
}

/// Possible inputs to [`Call::handle_event`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CallEvent {
    /// Server ack: invite was delivered, peer is ringing.
    ServerAcknowledgedRinging,
    /// Remote callee picked up — flip to Active.
    RemoteAccepted,
    /// Remote callee declined — flip to Ended.
    RemoteRejected,
    /// Remote party ended the call (either side, after Active).
    RemoteEnded { reason: String },
    /// Local user pressed "Hang up".
    LocalEnd,
    /// LiveKit signaled successful media connect.
    ConnectedToLiveKit,
    /// Network dropped — UI may show "Reconnecting", but if reconnect
    /// times out we flip to Ended via another event.
    NetworkLost,
    /// Server-side watchdog fired — ringing timed out without an answer.
    RingingTimeout,
}

#[derive(Debug, thiserror::Error)]
pub enum FsmError {
    #[error("event {event:?} not valid in state {state:?}")]
    InvalidTransition { state: CallState, event: CallEvent },
    #[error("already ended")]
    AlreadyEnded,
}

/// Per-call FSM. Owns a small bag of fields plus the discriminator.
/// Designed to be cheap to clone for the Flutter-side state mirror.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub call_id: CallId,
    pub role: CallRole,
    pub state: CallState,
    /// Last terminal reason, if any. Set when transitioning to Ended.
    pub end_reason: Option<String>,
}

impl Call {
    /// Construct a new outgoing call — starts in `Inviting`.
    pub fn new_outgoing(call_id: CallId) -> Self {
        Self {
            call_id,
            role: CallRole::Caller,
            state: CallState::Inviting,
            end_reason: None,
        }
    }

    /// Construct a new incoming call — starts in `Ringing` (user must
    /// accept or reject).
    pub fn new_incoming(call_id: CallId) -> Self {
        Self {
            call_id,
            role: CallRole::Callee,
            state: CallState::Ringing,
            end_reason: None,
        }
    }

    /// Apply an event. Returns `Ok` with the new state on success,
    /// `Err(FsmError)` if the event is invalid in the current state
    /// (state unchanged).
    pub fn handle_event(&mut self, event: CallEvent) -> Result<CallState, FsmError> {
        if self.state == CallState::Ended {
            return Err(FsmError::AlreadyEnded);
        }

        use CallEvent::*;
        use CallState::*;

        let new_state = match (self.state, &event) {
            // Outgoing call: Inviting → Ringing once server confirms
            // delivery via CallRing.
            (Inviting, ServerAcknowledgedRinging) => Ringing,

            // Ringing → Active: callee accepted (caller side) OR
            // LiveKit connected (could happen out-of-order with the
            // server CallAccept).
            (Ringing, RemoteAccepted) | (Ringing, ConnectedToLiveKit) => Active,

            // Active → Active: redundant ConnectedToLiveKit (e.g. after
            // a media reconnect). Idempotent.
            (Active, ConnectedToLiveKit) => Active,

            // Terminal transitions — any state may end on:
            //   - LocalEnd
            //   - RemoteRejected / RemoteEnded
            //   - RingingTimeout (only meaningful in Inviting/Ringing
            //     but we accept from any pre-terminal for safety)
            (_, LocalEnd) => {
                self.end_reason = Some("hangup".to_string());
                Ended
            }
            (_, RemoteRejected) => {
                self.end_reason = Some("rejected".to_string());
                Ended
            }
            (_, RemoteEnded { reason }) => {
                self.end_reason = Some(reason.clone());
                Ended
            }
            (Inviting, RingingTimeout) | (Ringing, RingingTimeout) => {
                self.end_reason = Some("no_answer".to_string());
                Ended
            }

            // Network lost mid-call. We don't flip to Ended immediately —
            // a reconnect attempt is in flight. UI may show
            // "Reconnecting" but the FSM stays in Active. Only when a
            // permanent failure surfaces (LocalEnd / RemoteEnded /
            // explicit timeout) do we move on.
            (Active, NetworkLost) => Active,

            // Anything else is an invalid transition.
            _ => {
                return Err(FsmError::InvalidTransition {
                    state: self.state,
                    event,
                });
            }
        };

        self.state = new_state;
        Ok(new_state)
    }

    /// Convenience: is the call in a terminal state?
    pub fn is_ended(&self) -> bool {
        self.state == CallState::Ended
    }

    /// Convenience: is media flowing (Active state)?
    pub fn is_active(&self) -> bool {
        self.state == CallState::Active
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cid() -> CallId {
        Uuid::now_v7()
    }

    #[test]
    fn outgoing_happy_path() {
        let mut call = Call::new_outgoing(cid());
        assert_eq!(call.state, CallState::Inviting);
        call.handle_event(CallEvent::ServerAcknowledgedRinging).unwrap();
        assert_eq!(call.state, CallState::Ringing);
        call.handle_event(CallEvent::RemoteAccepted).unwrap();
        assert_eq!(call.state, CallState::Active);
        call.handle_event(CallEvent::ConnectedToLiveKit).unwrap();
        assert_eq!(call.state, CallState::Active); // idempotent
        call.handle_event(CallEvent::LocalEnd).unwrap();
        assert_eq!(call.state, CallState::Ended);
        assert_eq!(call.end_reason.as_deref(), Some("hangup"));
    }

    #[test]
    fn incoming_happy_path() {
        let mut call = Call::new_incoming(cid());
        assert_eq!(call.state, CallState::Ringing);
        // Callee accepted — on incoming, this means "user tapped Accept".
        // The FSM doesn't distinguish; both sides see Ringing → Active.
        call.handle_event(CallEvent::ConnectedToLiveKit).unwrap();
        assert_eq!(call.state, CallState::Active);
        call.handle_event(CallEvent::RemoteEnded {
            reason: "hangup".to_string(),
        })
        .unwrap();
        assert_eq!(call.state, CallState::Ended);
        assert_eq!(call.end_reason.as_deref(), Some("hangup"));
    }

    #[test]
    fn incoming_decline_flow() {
        let mut call = Call::new_incoming(cid());
        // User taps Decline → caller side sees RemoteRejected.
        // (On the callee's own side, this is LocalEnd.)
        call.handle_event(CallEvent::LocalEnd).unwrap();
        assert_eq!(call.state, CallState::Ended);
        assert_eq!(call.end_reason.as_deref(), Some("hangup"));
    }

    #[test]
    fn caller_sees_decline_as_remote_rejected() {
        let mut call = Call::new_outgoing(cid());
        call.handle_event(CallEvent::ServerAcknowledgedRinging).unwrap();
        call.handle_event(CallEvent::RemoteRejected).unwrap();
        assert_eq!(call.state, CallState::Ended);
        assert_eq!(call.end_reason.as_deref(), Some("rejected"));
    }

    #[test]
    fn ringing_timeout_ends_with_no_answer() {
        let mut call = Call::new_outgoing(cid());
        call.handle_event(CallEvent::ServerAcknowledgedRinging).unwrap();
        call.handle_event(CallEvent::RingingTimeout).unwrap();
        assert_eq!(call.state, CallState::Ended);
        assert_eq!(call.end_reason.as_deref(), Some("no_answer"));
    }

    #[test]
    fn network_loss_keeps_active() {
        let mut call = Call::new_outgoing(cid());
        call.handle_event(CallEvent::ServerAcknowledgedRinging).unwrap();
        call.handle_event(CallEvent::RemoteAccepted).unwrap();
        call.handle_event(CallEvent::NetworkLost).unwrap();
        // Critical: NetworkLost does NOT end the call — reconnect is
        // possible. Only explicit LocalEnd / RemoteEnded ends.
        assert_eq!(call.state, CallState::Active);
    }

    #[test]
    fn invalid_transition_rejected() {
        let mut call = Call::new_outgoing(cid());
        // Can't be ConnectedToLiveKit while still Inviting (server
        // hasn't even confirmed delivery).
        let r = call.handle_event(CallEvent::ConnectedToLiveKit);
        assert!(matches!(r, Err(FsmError::InvalidTransition { .. })));
        // State unchanged.
        assert_eq!(call.state, CallState::Inviting);
    }

    #[test]
    fn already_ended_rejects_further_events() {
        let mut call = Call::new_outgoing(cid());
        call.handle_event(CallEvent::LocalEnd).unwrap();
        let r = call.handle_event(CallEvent::RemoteAccepted);
        assert!(matches!(r, Err(FsmError::AlreadyEnded)));
    }

    #[test]
    fn early_local_end_works_from_inviting() {
        let mut call = Call::new_outgoing(cid());
        // User changes mind before server even acknowledged.
        call.handle_event(CallEvent::LocalEnd).unwrap();
        assert_eq!(call.state, CallState::Ended);
    }

    #[test]
    fn is_active_and_is_ended_predicates() {
        let mut call = Call::new_outgoing(cid());
        assert!(!call.is_active());
        assert!(!call.is_ended());
        call.handle_event(CallEvent::ServerAcknowledgedRinging).unwrap();
        call.handle_event(CallEvent::RemoteAccepted).unwrap();
        assert!(call.is_active());
        assert!(!call.is_ended());
        call.handle_event(CallEvent::LocalEnd).unwrap();
        assert!(!call.is_active());
        assert!(call.is_ended());
    }
}
