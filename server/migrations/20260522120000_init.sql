-- Sinhron operator-server schema · v1 (WU A2 · 2026-05-22).
-- Per spec §7.4. Forward-only migrations (no down.sql) per §7.5.
--
-- Tables (9 total):
--   users           — UUIDv7 PK + identity_pubkey + registered_at + status
--   devices         — device_pk → user_pk + credential + last_seen + push_token
--   keypackages     — pool of MLS KeyPackages, consume-once via row-level lock
--   mls_groups      — opaque group_id blob + creator + created_at
--   group_members   — derived: group_id × device_pk (server knows fan-out
--                     recipients, NOT plaintext group names)
--   messages        — UUIDv7 PK + group_id + sender_device_pk + ciphertext +
--                     ts. PARTITIONED BY RANGE (ts) — month buckets per §7.4
--   media           — sha256 PK + size + uploaded_by + ts + ref_count
--   push_subscriptions — opaque delivery_key → apns/fcm token mapping
--   state_backups   — owner-encrypted MLS-state blob per user (§6.8.1)
--
-- Conventions:
--   • UUIDv7 generated client-side (we don't have pg_uuidv7 ext on stock
--     pg yet) — server just stores. message_id ordering relies on the
--     embedded timestamp.
--   • All PKs are BYTEA where they're cryptographic, UUID where they're
--     just identifiers.
--   • timestamptz everywhere — never plain timestamp (TZ drift bites).
--   • ON DELETE CASCADE for tight parent→child only (devices→user). We
--     keep messages and state_backups detached so user-purge is auditable.

-- ── Users ────────────────────────────────────────────────────────────
CREATE TABLE users (
    user_pk              UUID            NOT NULL PRIMARY KEY,
    -- ed25519 identity public key (32 bytes) per spec §6.2. Single-source-
    -- of-truth pubkey; the x25519 KEM key lives in devices/keypackages.
    identity_pubkey      BYTEA           NOT NULL,
    -- Optional opt-in handle for self-hosters who want search-by-handle.
    -- NULL if user did NOT opt in (spec §7.4 — "помечается флагом").
    handle               TEXT,
    handle_consented     BOOLEAN         NOT NULL DEFAULT FALSE,
    registered_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- 'active' / 'soft_deleted' / 'purged'. soft_marker for §7.6 retention.
    status               TEXT            NOT NULL DEFAULT 'active',
    CONSTRAINT users_identity_pubkey_len CHECK (octet_length(identity_pubkey) = 32),
    CONSTRAINT users_handle_only_if_consented CHECK (
        handle IS NULL OR handle_consented = TRUE
    )
);
CREATE UNIQUE INDEX users_identity_pubkey_uq ON users(identity_pubkey);
-- Sparse index — only rows where handle was opted in. Saves space on the
-- common case (no handle).
CREATE UNIQUE INDEX users_handle_uq ON users(handle) WHERE handle IS NOT NULL;

-- ── Devices ──────────────────────────────────────────────────────────
CREATE TABLE devices (
    device_pk            BYTEA           NOT NULL PRIMARY KEY,
    user_pk              UUID            NOT NULL REFERENCES users(user_pk)
                                                  ON DELETE CASCADE,
    -- MLS basic-credential bytes (Ed25519 pubkey wrapped per RFC 9420).
    credential           BYTEA           NOT NULL,
    last_seen_at         TIMESTAMPTZ,
    -- Opaque push delivery key (NOT the APNs/FCM token — see
    -- push_subscriptions table for that mapping per spec §9.4).
    delivery_key         BYTEA,
    registered_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    CONSTRAINT devices_device_pk_len CHECK (octet_length(device_pk) = 32),
    CONSTRAINT devices_credential_nonempty CHECK (octet_length(credential) > 0)
);
CREATE INDEX devices_user_pk_idx ON devices(user_pk);
CREATE UNIQUE INDEX devices_delivery_key_uq
    ON devices(delivery_key) WHERE delivery_key IS NOT NULL;

-- ── KeyPackages (consume-once pool) ──────────────────────────────────
-- Spec §7.4: row-level lock at consume time. We use `FOR UPDATE SKIP
-- LOCKED` in the consume query (application-side) so concurrent
-- consumers don't contend.
CREATE TABLE keypackages (
    keypackage_id        UUID            NOT NULL PRIMARY KEY,
    device_pk            BYTEA           NOT NULL REFERENCES devices(device_pk)
                                                  ON DELETE CASCADE,
    -- TLS-encoded MLS KeyPackage per RFC 9420.
    kp_bytes             BYTEA           NOT NULL,
    uploaded_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- TTL per spec §7.6 — 30 days OR until consume.
    expires_at           TIMESTAMPTZ     NOT NULL,
    consumed_at          TIMESTAMPTZ,
    CONSTRAINT keypackages_kp_nonempty CHECK (octet_length(kp_bytes) > 0),
    CONSTRAINT keypackages_expires_after_upload
        CHECK (expires_at > uploaded_at)
);
-- Hot path: "give me an unconsumed, non-expired KP for device X".
CREATE INDEX keypackages_consume_idx
    ON keypackages(device_pk)
    WHERE consumed_at IS NULL;

-- ── MLS groups ───────────────────────────────────────────────────────
-- group_id is OPAQUE — derived from MLS state, never a plaintext name.
-- Server fans messages out to group_members but does NOT know what the
-- group is called or what its purpose is.
CREATE TABLE mls_groups (
    group_id             BYTEA           NOT NULL PRIMARY KEY,
    -- The device that originally created the group (creator can be
    -- removed later; this stays as audit metadata).
    created_by_device_pk BYTEA           REFERENCES devices(device_pk)
                                                  ON DELETE SET NULL,
    created_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- Current MLS epoch — bumped on every Commit. Lets the server
    -- reject stale Commits per spec §9.3.
    current_epoch        BIGINT          NOT NULL DEFAULT 0,
    CONSTRAINT mls_groups_group_id_nonempty CHECK (octet_length(group_id) > 0)
);

-- ── Group members (server-side fan-out targets) ──────────────────────
-- Spec §7.4 calls this a "derived view" — we materialize it as a table
-- so fan-out is an INDEX SCAN rather than a join. Updated when the
-- server processes Welcome / Commit (Add/Remove member proposals).
CREATE TABLE group_members (
    group_id             BYTEA           NOT NULL REFERENCES mls_groups(group_id)
                                                  ON DELETE CASCADE,
    device_pk            BYTEA           NOT NULL REFERENCES devices(device_pk)
                                                  ON DELETE CASCADE,
    joined_at_epoch      BIGINT          NOT NULL,
    PRIMARY KEY (group_id, device_pk)
);
-- Reverse lookup: "all groups for device X" — used during reconciliation
-- on reconnect.
CREATE INDEX group_members_device_idx ON group_members(device_pk);

-- ── Messages (PARTITIONED BY RANGE (ts) per spec §7.4) ───────────────
-- Native PostgreSQL range partitioning by month. The retention worker
-- (WU A9) drops old partitions wholesale, which is dramatically cheaper
-- than DELETE FROM messages WHERE ts < ... on a partitioned table.
--
-- IMPORTANT: with partitioning, PRIMARY KEY must include the partition
-- key column. So we PK on (ts, message_id) instead of (message_id) alone.
-- UUIDv7 already embeds the timestamp, so (ts, message_id) ordering is
-- naturally chronological and the secondary index is essentially free.
CREATE TABLE messages (
    message_id           UUID            NOT NULL,
    group_id             BYTEA           NOT NULL,
    -- Sealed Sender (§6.6): server may receive NULL here when the sender
    -- identity is hidden inside the ciphertext envelope.
    sender_device_pk     BYTEA,
    -- MLS-encrypted PrivateMessage frame (or SFrame-wrapped for media).
    ciphertext           BYTEA           NOT NULL,
    ts                   TIMESTAMPTZ     NOT NULL,
    PRIMARY KEY (ts, message_id),
    CONSTRAINT messages_ciphertext_nonempty CHECK (octet_length(ciphertext) > 0)
) PARTITION BY RANGE (ts);

-- Initial partition: current month. WU A9 retention worker creates new
-- partitions ahead of time and drops old ones past the configured TTL.
CREATE TABLE messages_2026_05 PARTITION OF messages
    FOR VALUES FROM ('2026-05-01 00:00:00+00') TO ('2026-06-01 00:00:00+00');

-- Fan-out + reconciliation index — "all messages for group X newer than
-- ts Y" is the hottest query (every WS reconnect runs it).
CREATE INDEX messages_group_ts_idx ON messages(group_id, ts);

-- ── Media blobs ──────────────────────────────────────────────────────
-- Content-addressed by sha256(ciphertext). Multiple messages can
-- reference the same media (sharing/forwarding) — ref_count tracks
-- outstanding references; reaches 0 → eligible for cleanup per §7.6.
CREATE TABLE media (
    sha256               BYTEA           NOT NULL PRIMARY KEY,
    -- Bytes of the actual encrypted media object. We store inline rather
    -- than S3-style for v1 simplicity; storage backend swap is §12 work.
    blob                 BYTEA           NOT NULL,
    size_bytes           BIGINT          NOT NULL,
    uploaded_by_device   BYTEA           NOT NULL REFERENCES devices(device_pk)
                                                  ON DELETE NO ACTION,
    uploaded_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- Last-GET marker — drives "delete after 90d of no access" rule.
    last_referenced_at   TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    ref_count            INTEGER         NOT NULL DEFAULT 0,
    CONSTRAINT media_sha256_len CHECK (octet_length(sha256) = 32),
    CONSTRAINT media_size_matches CHECK (octet_length(blob) = size_bytes),
    CONSTRAINT media_ref_count_nonneg CHECK (ref_count >= 0)
);

-- ── Push subscriptions ───────────────────────────────────────────────
-- Maps an opaque delivery_key (issued to the device, NOT linkable to
-- user identity without the server's own table) to a real APNs/FCM
-- token. Decoupled from `devices` so we can rotate push tokens without
-- touching the device row.
CREATE TABLE push_subscriptions (
    delivery_key         BYTEA           NOT NULL PRIMARY KEY,
    -- 'apns' | 'fcm' — case-sensitive.
    provider             TEXT            NOT NULL,
    -- Provider-specific token (APNs: 64 hex chars; FCM: variable JWT-like).
    provider_token       TEXT            NOT NULL,
    registered_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    last_used_at         TIMESTAMPTZ,
    CONSTRAINT push_provider_known CHECK (provider IN ('apns', 'fcm')),
    CONSTRAINT push_token_nonempty CHECK (length(provider_token) > 0)
);

-- ── State backups (§6.8.1) ───────────────────────────────────────────
-- One row per user. Server stores the AES-256-GCM ciphertext only; the
-- key is HKDF-derived from the user's BIP-39 phrase and NEVER leaves
-- the client. version_seq is monotonic — UPDATE accepted only if
-- NEW.version_seq > OLD.version_seq (enforced application-side; we add
-- a CHECK constraint that the column itself is non-negative).
CREATE TABLE state_backups (
    user_pk              UUID            NOT NULL PRIMARY KEY
                                                  REFERENCES users(user_pk)
                                                  ON DELETE CASCADE,
    blob                 BYTEA           NOT NULL,
    version_seq          BIGINT          NOT NULL,
    updated_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- Hard cap per spec §7.4 — reject INSERT/UPDATE of blobs > 1 MB.
    CONSTRAINT state_backups_blob_max CHECK (octet_length(blob) <= 1048576),
    CONSTRAINT state_backups_version_nonneg CHECK (version_seq >= 0)
);
