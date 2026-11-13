-- ADR-090 (docs/security-review-2026-11.md, storage-devices:14) — when the
-- newest chat backup of an account's devices was made, per cloud ("icloud",
-- "drive"): a new phone warns before restoring an older one the cloud kept.
CREATE TABLE backup_marks (
    user_pk     UUID        NOT NULL REFERENCES users(user_pk) ON DELETE CASCADE,
    cloud       TEXT        NOT NULL,
    created_ts  BIGINT      NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_pk, cloud)
);
