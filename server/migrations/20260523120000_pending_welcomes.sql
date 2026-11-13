-- pending_welcomes — durable queue for MLS Welcomes whose recipient is
-- offline at delivery time. Risk #10 fix.
--
-- Background. The WU C4 Welcome handler (server/src/ws.rs handle_welcome)
-- forwards Welcome frames only to currently-connected sessions in the
-- SessionRegistry. If Alice invites Bob while Bob is offline, the server
-- returned 503 to Alice and **the Welcome was lost** — Bob would never
-- learn he'd been added to the group, even after he came online.
--
-- This table stores Welcomes for offline recipients. On WS auth-success
-- the server drains the recipient's queue and pushes each Welcome as a
-- standard WsFrame.Welcome event, then DELETEs the row.
--
-- Retention (per spec §7.6 + §13.x):
--   • 7 days TTL by default. Anything older is dropped by the sweep
--     worker (see retention.rs). 7d covers a normal "offline for a
--     vacation" case; longer storage would just leak metadata.
--   • `recipient_user_pk` cascades on user delete so account-deletion
--     wipes pending state too.
--
-- This is metadata leak surface (§13.x): server sees Welcome ciphertext
-- + recipient + group_id + sender's view of when it was enqueued. The
-- Welcome body is MLS-opaque (HPKE-sealed), but membership timing is
-- observable to operators. Documented in the threat model.

CREATE TABLE pending_welcomes (
    id                BIGSERIAL    PRIMARY KEY,
    recipient_user_pk UUID         NOT NULL REFERENCES users(user_pk) ON DELETE CASCADE,
    group_id          BYTEA        NOT NULL,
    welcome_bytes     BYTEA        NOT NULL,
    enqueued_at       TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    expires_at        TIMESTAMPTZ  NOT NULL
);

-- Hot path: "drain queue for user X" on every Auth success.
-- Without this index, every login does a seq-scan of the whole table.
CREATE INDEX pending_welcomes_recipient_idx
    ON pending_welcomes (recipient_user_pk, enqueued_at);

-- Retention sweep: "find expired" — bounded scan by expires_at.
CREATE INDEX pending_welcomes_expires_idx
    ON pending_welcomes (expires_at);
