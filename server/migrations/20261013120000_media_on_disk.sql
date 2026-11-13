-- ADR-017 — media blobs move from an inline BYTEA column to content-
-- addressed files under SINHRON_MEDIA_DIR. Postgres keeps metadata only:
-- multi-MB rows bloat WAL/backups and force whole blobs through memory.
--
-- No production data existed in `media` (no handler wrote to it before
-- this migration), so dropping the column loses nothing. The
-- media_size_matches CHECK referenced `blob` and is dropped with it.
ALTER TABLE media DROP COLUMN blob;

ALTER TABLE media
    ADD CONSTRAINT media_size_positive CHECK (size_bytes > 0);

-- Retention sweep scans by last access (spec §7.6: 90 days).
CREATE INDEX media_last_referenced_idx ON media (last_referenced_at);
