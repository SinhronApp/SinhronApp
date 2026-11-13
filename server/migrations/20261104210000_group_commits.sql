-- ADR-092 (docs/security-review-2026-11.md, server-ws:2 variant B). The server
-- can't read a Commit: it took the first one of an epoch, garbage included,
-- and every honest phone (which refused it) got 409 from then on — the chat
-- froze. Now it keeps every Commit it fanned out, in order; a Commit for an
-- epoch is taken only from a device that has seen and not taken each one the
-- server holds for that epoch after the Commit that brought it there.
CREATE TABLE group_commits (
    n          BIGSERIAL PRIMARY KEY,
    group_id   BYTEA  NOT NULL REFERENCES mls_groups(group_id) ON DELETE CASCADE,
    epoch      BIGINT NOT NULL,
    message_id UUID   NOT NULL,
    device_pk  BYTEA  NOT NULL
);
CREATE INDEX group_commits_epoch ON group_commits (group_id, epoch);
CREATE UNIQUE INDEX group_commits_message ON group_commits (group_id, message_id);
