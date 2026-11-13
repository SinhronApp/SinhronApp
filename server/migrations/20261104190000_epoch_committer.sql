-- ADR-090 (docs/security-review-2026-11.md, server-ws:2 and server-http:10).
-- The device whose Commit made the current epoch: only it may replace that
-- epoch's chat card (NULL: nobody committed since the column came — the first
-- card of the epoch stays until a newer epoch).
ALTER TABLE mls_groups ADD COLUMN epoch_committer_device_pk BYTEA;

-- A chat the server never ordered (still 0) used to catch up on its first
-- Commit to anything up to 100 — a member jumped it to 101 and froze it. The
-- catch-up is gone; such chats take their real epoch once, from the card their
-- members left (one per epoch, ADR-075). A chat without a card stays at 0.
UPDATE mls_groups g SET current_epoch = c.epoch
  FROM group_cards c
 WHERE c.group_id = g.group_id AND g.current_epoch = 0 AND c.epoch BETWEEN 1 AND 100;
