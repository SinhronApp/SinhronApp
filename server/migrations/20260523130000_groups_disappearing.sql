-- T3.4 — per-chat disappearing messages timer (server-side base).
--
-- Each group can opt-in to a TTL shorter than the global retention
-- window (`SINHRON_MESSAGE_RETENTION_DAYS`). When set, the retention
-- sweep deletes messages in that group older than the local TTL,
-- regardless of the global default.
--
-- NULL (default) = no per-chat TTL; global retention applies.
-- Set in seconds (BIGINT covers up to ~292 billion years, but realistic
-- values are 60 (1m) to 7*86400 (7d)).
--
-- Setting / clearing the value is an admin operation in v1 — exposed
-- via a future ChatSettings frame (deferred WU). For now operators
-- can `UPDATE groups SET disappearing_after_secs = 3600 WHERE …`
-- directly if they want to evaluate the cleanup logic.
--
-- The UI for disappearing messages (WU 38 in Phase 1) is already
-- built; just not yet wired to set this column. Cross-cutting follow-up.

-- Note: base schema (20260522120000_init.sql) creates table `mls_groups`
-- (not `groups`). Earlier draft of this migration + retention.rs used
-- the wrong name; fixed 2026-05-23 during LAN-TEST-1 stand-up.
ALTER TABLE mls_groups
    ADD COLUMN disappearing_after_secs BIGINT NULL;

-- Index for the retention sweep — "find groups with TTL set". Sparse
-- (most groups will have NULL); partial index keeps it tiny.
CREATE INDEX mls_groups_disappearing_idx
    ON mls_groups (disappearing_after_secs)
    WHERE disappearing_after_secs IS NOT NULL;
