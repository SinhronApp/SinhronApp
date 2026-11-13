-- 2026-10-26 (KISS) — the server copy of a person's MLS state
-- (`/v1/state-backup`, §6.8.1) is gone: no app calls it since the cloud
-- backup (ADR-073) took its place. Its rows go with it.
DROP TABLE IF EXISTS state_backups;
