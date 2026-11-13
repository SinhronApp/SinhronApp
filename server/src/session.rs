// In-memory registry of authenticated WS sessions.
//
// One process serves many connected devices. When a Submit frame lands
// the server must Push it to every other connected member of the same
// MLS group, NOW (not via the slow path of "client polls server on
// reconnect"). That's a 1-of-N broadcast keyed by user_pk; the registry
// is the in-memory index that makes the broadcast O(N) instead of O(all
// users).
//
// Per-user multi-conn: one user may have multiple authenticated
// sessions at once (phone + desktop). Each connection registers
// independently; fanout sends the Push to every connection of every
// target user.
//
// Lifetime: each call to [`SessionRegistry::register`] returns a
// [`SessionGuard`] which un-registers on Drop. WS handlers hold it in
// their async scope; when the task ends (clean close or error), the
// guard drops and the registry cleans up — no leaked entries.
//
// Threading: behind `Arc<RwLock<HashMap<..>>>` for simplicity. Lock is
// held only for the duration of a single insert / remove / read scan,
// so contention is low even at high fanout volumes. If profiling shows
// hotspot we'll move to DashMap or sharded locks in a later WU.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, RwLock};

use bytes::Bytes;
use tokio::sync::mpsc::UnboundedSender;
use tracing::debug;
use uuid::Uuid;

/// Per-connection sender handle. The receiving end is owned by the WS
/// forwarder task in [`crate::ws`]; pushing into this queue effectively
/// schedules a frame for transmission.
struct SessionSender {
    /// Pre-encoded WsFrame bytes — the WS task just wraps in
    /// `Message::Binary` and sends. Keeps the registry oblivious to
    /// protobuf encoding.
    tx: UnboundedSender<Bytes>,
    /// Per-connection id (UUIDv7). Lets [`SessionGuard`] remove ONLY
    /// its own row, not other connections of the same user.
    conn_id: Uuid,
    /// ADR-025 — the device key the connection logged in with (the
    /// identity key on the first device). `None` in older tests.
    device: Option<Vec<u8>>,
    /// Bytes in the queue, not yet written to the socket (the send task
    /// takes them off) — [STALLED] once it went over [MAX_QUEUED_BYTES].
    queued: Arc<AtomicUsize>,
}

/// Most bytes waiting for one connection. A device that stopped reading
/// grew the server's memory without end (docs/security-review-2026-11.md,
/// server-ws:3): past this it gets nothing more and its send task closes
/// it; the app reconnects and the rest comes as the backlog.
pub const MAX_QUEUED_BYTES: usize = 32 * 1024 * 1024;
/// The mark of a connection that went over [MAX_QUEUED_BYTES].
pub const STALLED: usize = usize::MAX / 2;

/// WS-11 — most connections one person holds at once (a few devices, plus
/// ones not yet noticed dead). Each may hold up to [MAX_QUEUED_BYTES], and
/// their number had no limit. One more closes the oldest.
pub const MAX_CONNECTIONS_PER_USER: usize = 16;

impl SessionSender {
    fn push(&self, frame: &Bytes) -> bool {
        if self.queued.fetch_add(frame.len(), Ordering::Relaxed) + frame.len() > MAX_QUEUED_BYTES {
            self.queued.store(STALLED, Ordering::Relaxed);
            return false;
        }
        self.tx.send(frame.clone()).is_ok()
    }
}

#[derive(Clone, Default)]
pub struct SessionRegistry {
    inner: Arc<RwLock<HashMap<Uuid /* user_pk */, Vec<SessionSender>>>>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a new authenticated connection. Returns a guard that
    /// MUST be held alive for the lifetime of the WS task — drop it on
    /// disconnect to release the slot.
    pub fn register(&self, user_pk: Uuid, tx: UnboundedSender<Bytes>) -> SessionGuard {
        self.register_device(user_pk, None, tx)
    }

    /// [`register`] for a connection that logged in with `device`'s key.
    pub fn register_device(&self, user_pk: Uuid, device: Option<Vec<u8>>, tx: UnboundedSender<Bytes>) -> SessionGuard {
        let conn_id = Uuid::now_v7();
        let queued = Arc::new(AtomicUsize::new(0));
        {
            let mut map = self.inner.write().unwrap_or_else(|e| e.into_inner());
            let conns = map.entry(user_pk).or_default();
            // Dropping its sender ends that connection's send task, and
            // with it the session.
            if conns.len() >= MAX_CONNECTIONS_PER_USER {
                conns.remove(0);
            }
            conns.push(SessionSender { tx, conn_id, device, queued: queued.clone() });
        }
        // T2.4 — bump active sessions gauge.
        #[cfg(not(test))]
        crate::metrics::WS_ACTIVE_SESSIONS.inc();
        debug!(user_pk = %user_pk, conn_id = %conn_id, "session registered");
        SessionGuard {
            registry: self.inner.clone(),
            user_pk,
            conn_id,
            queued,
        }
    }

    /// Status 182 — does [user_pk] have any open connection?
    pub fn is_online(&self, user_pk: Uuid) -> bool {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        map.get(&user_pk).is_some_and(|v| !v.is_empty())
    }

    /// Best-effort fanout. Iterates the target users; for each, pushes
    /// `frame_bytes` to every active connection. Channels closed since
    /// the last activity are silently skipped (their cleanup runs via
    /// the guard's Drop, just not in this call).
    pub fn fanout(&self, target_user_pks: &[Uuid], frame_bytes: Bytes) -> usize {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut delivered = 0usize;
        for user_pk in target_user_pks {
            if let Some(sessions) = map.get(user_pk) {
                for s in sessions {
                    if s.push(&frame_bytes) {
                        delivered += 1;
                    }
                }
            }
        }
        delivered
    }

    /// server-ws:9 — to one connection of [user_pk] (the one whose frame is
    /// answered). False when it is gone or over its cap.
    pub fn send_to(&self, user_pk: Uuid, conn_id: Uuid, frame_bytes: Bytes) -> bool {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        map.get(&user_pk)
            .and_then(|v| v.iter().find(|s| s.conn_id == conn_id))
            .is_some_and(|s| s.push(&frame_bytes))
    }

    /// ADR-025 — push only to `user_pk`'s connections logged in with one of
    /// `devices`. Returns the devices that got it.
    pub fn fanout_devices(&self, user_pk: Uuid, devices: &[Vec<u8>], frame_bytes: Bytes) -> Vec<Vec<u8>> {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut got = Vec::new();
        if let Some(sessions) = map.get(&user_pk) {
            for s in sessions {
                if let Some(d) = &s.device {
                    if devices.contains(d) && s.push(&frame_bytes) && !got.contains(d) {
                        got.push(d.clone());
                    }
                }
            }
        }
        got
    }

    /// 2026-10-26 — every connection of [user_pk] except those logged in
    /// with [device] (the person's other devices). Returns how many got it.
    pub fn fanout_user_except_device(&self, user_pk: Uuid, device: &[u8], frame_bytes: Bytes) -> usize {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut delivered = 0usize;
        if let Some(sessions) = map.get(&user_pk) {
            for s in sessions {
                if s.device.as_deref() != Some(device) && s.push(&frame_bytes) {
                    delivered += 1;
                }
            }
        }
        delivered
    }

    /// The devices of [users] with a live connection now.
    pub fn online_devices(&self, users: &[Uuid]) -> Vec<Vec<u8>> {
        let map = self.inner.read().unwrap_or_else(|e| e.into_inner());
        let mut out: Vec<Vec<u8>> = Vec::new();
        for u in users {
            for s in map.get(u).into_iter().flatten() {
                if let Some(d) = &s.device {
                    if !out.contains(d) {
                        out.push(d.clone());
                    }
                }
            }
        }
        out
    }

    /// ADR-027 — a revoked device: drop its live connections now (their
    /// send queues close, which ends the session) instead of letting them
    /// run until they reconnect and get refused. Returns how many.
    pub fn drop_device(&self, user_pk: Uuid, device: &[u8]) -> usize {
        let mut map = self.inner.write().unwrap_or_else(|e| e.into_inner());
        let Some(sessions) = map.get_mut(&user_pk) else { return 0 };
        let before = sessions.len();
        sessions.retain(|s| s.device.as_deref() != Some(device));
        let dropped = before - sessions.len();
        if sessions.is_empty() {
            map.remove(&user_pk);
        }
        dropped
    }

    /// ADR-037 — a deleted account: drop every live connection it has.
    pub fn drop_user(&self, user_pk: Uuid) -> usize {
        let mut map = self.inner.write().unwrap_or_else(|e| e.into_inner());
        map.remove(&user_pk).map(|s| s.len()).unwrap_or(0)
    }

    /// How many connections currently registered. Test helper.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.inner
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .values()
            .map(|v| v.len())
            .sum()
    }
}

/// Drop-guard returned by [`SessionRegistry::register`]. Removes the
/// connection from the registry when the WS task ends.
pub struct SessionGuard {
    registry: Arc<RwLock<HashMap<Uuid, Vec<SessionSender>>>>,
    user_pk: Uuid,
    conn_id: Uuid,
    queued: Arc<AtomicUsize>,
}

impl SessionGuard {
    /// The connection's queued-bytes counter, for its send task.
    pub fn queued(&self) -> Arc<AtomicUsize> {
        self.queued.clone()
    }

    /// This connection's id ([SessionRegistry::send_to]).
    pub fn conn_id(&self) -> Uuid {
        self.conn_id
    }
}

impl Drop for SessionGuard {
    fn drop(&mut self) {
        let mut map = self.registry.write().unwrap_or_else(|e| e.into_inner());
        if let Some(sessions) = map.get_mut(&self.user_pk) {
            sessions.retain(|s| s.conn_id != self.conn_id);
            if sessions.is_empty() {
                map.remove(&self.user_pk);
            }
        }
        // T2.4 — drop active sessions gauge.
        #[cfg(not(test))]
        crate::metrics::WS_ACTIVE_SESSIONS.dec();
        debug!(user_pk = %self.user_pk, conn_id = %self.conn_id, "session unregistered");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    /// WS-11 — one person's connections had no limit, each with its own
    /// queue of up to 32 MiB.
    #[test]
    fn one_more_connection_than_the_cap_closes_the_oldest() {
        let reg = SessionRegistry::new();
        let user = Uuid::now_v7();
        let (first_tx, mut first_rx) = mpsc::unbounded_channel();
        let _first = reg.register(user, first_tx);
        let mut guards = Vec::new();
        for _ in 0..MAX_CONNECTIONS_PER_USER {
            let (tx, rx) = mpsc::unbounded_channel();
            guards.push((reg.register(user, tx), rx));
        }
        assert_eq!(reg.len(), MAX_CONNECTIONS_PER_USER);
        assert!(matches!(first_rx.try_recv(), Err(mpsc::error::TryRecvError::Disconnected)), "the oldest is closed");
        assert_eq!(reg.fanout(&[user], Bytes::from_static(b"x")), MAX_CONNECTIONS_PER_USER);
    }

    /// A panic under the lock used to poison it: every later login and
    /// fan-out panicked, and the guard's Drop aborted the process.
    #[test]
    fn a_poisoned_lock_does_not_take_the_registry_down() {
        let reg = SessionRegistry::new();
        let user = Uuid::now_v7();
        let (tx, mut rx) = mpsc::unbounded_channel();
        let guard = reg.register(user, tx);
        let inner = reg.inner.clone();
        let _ = std::thread::spawn(move || {
            let _held = inner.write().unwrap();
            panic!("poison the session lock");
        })
        .join();
        assert!(reg.inner.is_poisoned());
        assert!(reg.is_online(user));
        assert_eq!(reg.fanout(&[user], Bytes::from_static(b"x")), 1);
        assert_eq!(rx.try_recv().unwrap().as_ref(), b"x");
        drop(guard);
        assert_eq!(reg.len(), 0);
    }

    #[test]
    fn register_and_drop() {
        let reg = SessionRegistry::new();
        assert_eq!(reg.len(), 0);

        let (tx, _rx) = mpsc::unbounded_channel();
        let user_pk = Uuid::now_v7();
        let guard = reg.register(user_pk, tx);
        assert_eq!(reg.len(), 1);

        drop(guard);
        assert_eq!(reg.len(), 0, "guard drop should un-register");
    }

    #[test]
    fn fanout_to_multiple_connections_of_same_user() {
        let reg = SessionRegistry::new();
        let user_pk = Uuid::now_v7();

        let (tx_a, mut rx_a) = mpsc::unbounded_channel();
        let (tx_b, mut rx_b) = mpsc::unbounded_channel();
        let _g_a = reg.register(user_pk, tx_a);
        let _g_b = reg.register(user_pk, tx_b);

        let payload = Bytes::from_static(b"hello");
        let n = reg.fanout(&[user_pk], payload);
        assert_eq!(n, 2);

        assert_eq!(rx_a.try_recv().unwrap().as_ref(), b"hello");
        assert_eq!(rx_b.try_recv().unwrap().as_ref(), b"hello");
    }

    #[test]
    fn fanout_ignores_unknown_user() {
        let reg = SessionRegistry::new();
        let n = reg.fanout(&[Uuid::now_v7()], Bytes::from_static(b"x"));
        assert_eq!(n, 0);
    }

    #[test]
    fn fanout_skips_closed_channels() {
        let reg = SessionRegistry::new();
        let user_pk = Uuid::now_v7();

        let (tx, rx) = mpsc::unbounded_channel();
        let _g = reg.register(user_pk, tx);
        drop(rx); // receiver gone → tx.send() will fail

        let n = reg.fanout(&[user_pk], Bytes::from_static(b"y"));
        assert_eq!(n, 0, "closed channel should not count as delivered");
    }

    #[test]
    fn online_while_a_connection_is_held() {
        let reg = SessionRegistry::new();
        let u = Uuid::now_v7();
        assert!(!reg.is_online(u));
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel();
        let guard = reg.register(u, tx);
        assert!(reg.is_online(u));
        drop(guard);
        assert!(!reg.is_online(u), "status 182: the last connection gone");
    }

    // server-ws:3 — a device that never reads: its queue stops at the cap
    // and stays stopped (the send task then closes it); a reading one,
    // whose send task takes bytes off, keeps getting everything.
    #[test]
    fn a_connection_that_never_reads_stops_growing_at_the_cap() {
        let reg = SessionRegistry::new();
        let u = Uuid::now_v7();
        let (stuck_tx, stuck_rx) = mpsc::unbounded_channel();
        let (live_tx, mut live_rx) = mpsc::unbounded_channel();
        let _stuck = reg.register(u, stuck_tx);
        let live = reg.register(u, live_tx);
        let mib = Bytes::from(vec![0u8; 1024 * 1024]);
        for _ in 0..100 {
            reg.fanout(&[u], mib.clone());
            while let Ok(b) = live_rx.try_recv() {
                live.queued().fetch_sub(b.len(), Ordering::Relaxed);
            }
        }
        assert_eq!(stuck_rx.len(), MAX_QUEUED_BYTES / mib.len(), "stopped at 32 MiB, not 100");
        assert_eq!(reg.fanout(&[u], Bytes::from_static(b"small")), 1, "stays stopped; the reader still gets it");
    }

}
