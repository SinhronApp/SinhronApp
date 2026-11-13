-- Per-recipient delivery log + sequence counter — WU A7.
--
-- Background. The fanout in WU A6 broadcasts a Push to each connected
-- group member. But clients reconnect after wifi drops, app restarts,
-- backgrounding, etc. — they need a way to ask "give me everything I
-- missed since last_acked_seq". The Resume frame (spec §7.3 line 364)
-- carries that cursor; this table is the index that answers it.
--
-- Schema choices:
--   • One row per (recipient × message) — populated at Submit fanout time.
--   • `seq` is BIGSERIAL — globally monotonic. Clients track *their own*
--     max-seen seq. Server SELECT WHERE recipient = me AND seq > cursor
--     replays everything newer in order.
--   • PRIMARY KEY (recipient_user_pk, seq) — composite, so the per-recipient
--     index is implicit and Resume queries hit it via a backward range scan.
--   • No FK on message_id — when retention drops a partition, dangling
--     delivery rows are fine: the JOIN onto `messages` simply returns no
--     row for those, and the replay logic skips them with a debug log.
--   • Idempotent on retry: if the same (recipient, message_id) hits twice
--     (e.g. duplicate Submit) the second insert violates the unique
--     index below and we log + skip.

CREATE TABLE IF NOT EXISTS message_deliveries (
    recipient_user_pk UUID        NOT NULL,
    seq               BIGSERIAL   NOT NULL,
    message_id        UUID        NOT NULL,
    delivered_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (recipient_user_pk, seq)
);

-- Dedup-on-retry index. Concurrent submit retries land on the same
-- recipient+message pair; we accept the first INSERT and silently drop
-- subsequent (via ON CONFLICT DO NOTHING at the handler).
CREATE UNIQUE INDEX IF NOT EXISTS message_deliveries_recipient_message_uq
    ON message_deliveries(recipient_user_pk, message_id);
