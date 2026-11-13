-- Add DEFAULT partition to messages so inserts past the initial
-- `messages_2026_05` partition don't error with "no partition of
-- relation messages found". The retention worker (WU A9) will split
-- DEFAULT into explicit month partitions ahead of time; until then,
-- this catches everything.
--
-- Idempotent — IF NOT EXISTS handles the second-run case.

CREATE TABLE IF NOT EXISTS messages_default PARTITION OF messages DEFAULT;
