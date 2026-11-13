// sinhron_storage — local persistence layer.
//
// Phase 2 step 4 (WU 71) introduced the `identities` table.
// Phase 2 step 5b (WU 73) adds `chats` + `messages` — the data layer behind
// the ChatList and ChatView screens. Schema is bumped to v2 with an
// idempotent ALTER/CREATE migration on open().
//
// Scope of WU 73:
//   - `chats(id, display_name, is_group, muted, pinned, unread_count,
//      last_msg_preview, last_msg_ts_unix, last_msg_kind,
//      last_msg_sender_label, last_msg_mine, created_at_unix)`
//   - `messages(id, chat_id, ts_unix, body, kind, is_mine, sender_label)`
//   - Denormalized last_msg_* columns on chats — ChatList renders straight
//     from one SELECT, no JOIN. message_append() keeps them in sync.
//
// Out of scope (subsequent WUs):
//   - SQLCipher / page-level encryption (spec §6.10)
//   - per-message receipts (sent / read) — comes with MLS-level acks
//   - Attachment blobs / voice recordings (kind stays a string label only)
//   - `linked_devices` table (per spec §6.5)
//
// Spec deviation: §5.2 calls for sqlx; we use rusqlite for sync API +
// consistency with openmls_sqlite_storage. Documented in ADR-008.

pub mod blobs;
pub mod devsync;
pub mod stickers;
pub mod transfer;

use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Storage errors. Boundary-clean: stringified at the FFI surface.
#[derive(Debug, thiserror::Error)]
pub enum StorageError {
    #[error("not initialized — call open() first")]
    NotInitialized,
    #[error("sqlite error: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("identity not found")]
    NotFound,
    /// The file is encrypted and the key given (or no key) doesn't open
    /// it. ADR-021: never wiped silently — the app asks for the phrase,
    /// and only an explicit [`erase_and_reopen_plain`] destroys data.
    #[error("storage locked: the database is encrypted and this key does not open it")]
    Locked,
    /// Local media blob file I/O (ADR-033, [`blobs`]).
    #[error("blob file: {0}")]
    Io(#[from] std::io::Error),
}

/// Stored identity row, materialized for the FFI surface.
#[derive(Debug, Clone)]
pub struct StoredIdentity {
    pub phrase_hash: String,
    pub fingerprint: String,
    pub ed25519_pub_hex: String,
    pub x25519_pub_hex: String,
    pub created_at_unix: i64,
}

/// Materialized chat row for the FFI surface. Mirrors the denormalized
/// `chats` table 1:1 — the UI renders the list straight from this.
#[derive(Debug, Clone)]
pub struct StoredChat {
    pub id: String,
    pub display_name: String,
    pub is_group: bool,
    pub muted: bool,
    pub pinned: bool,
    pub unread_count: i64,
    pub last_msg_preview: Option<String>,
    pub last_msg_ts_unix: i64,
    pub last_msg_kind: String,
    pub last_msg_sender_label: Option<String>,
    pub last_msg_mine: bool,
    pub created_at_unix: i64,
    /// v6 — chat-list organisation (UI backlog §2).
    pub archived: bool,
    /// Order among pinned chats (ascending).
    pub pin_order: i64,
    /// Unsent composer text, shown as "Draft: …" in the list.
    pub draft: Option<String>,
    /// User marked the chat unread by hand.
    pub marked_unread: bool,
    /// v7 — wire id of the message pinned in this chat (local only).
    pub pinned_msg: Option<String>,
    /// v8 — disappearing-message timer for new messages (0 = off).
    pub disappear_secs: i64,
    /// Delivery status of the newest message when it's mine (0 sending,
    /// 1 sent, 2 delivered, 3 read); 0 otherwise. Ticks in the list row.
    pub last_msg_status: i64,
    /// v11 — someone else started this chat and I haven't accepted it.
    pub request: bool,
    /// v13 — an unread message here @-mentions me.
    pub mentioned: bool,
    /// v14 — personal chats: the other person's identity key, once known.
    pub peer_id: Option<String>,
}

/// Materialized message row.
#[derive(Debug, Clone)]
pub struct StoredMessage {
    pub id: String,
    pub chat_id: String,
    pub ts_unix: i64,
    pub body: String,
    pub kind: String,
    pub is_mine: bool,
    pub sender_label: Option<String>,
    /// v4 — serialized media envelope (keys + blob refs + display
    /// metadata) for `kind` photo/voice/document; None for text. Lives
    /// only in this SQLCipher-encrypted DB, never in plaintext on disk.
    pub media_json: Option<String>,
    /// v7 (ADR-019) — the wire message UUID both sides know; replies,
    /// reactions, edits, deletes and receipts address messages by it.
    pub wire_id: Option<String>,
    /// Mine: 0 sending · 1 sent (server ack) · 2 delivered · 3 read ·
    /// -1 failed. Incoming: 0 received · 1 delivery receipt sent ·
    /// 2 read receipt sent.
    pub status: i64,
    /// Quote of the replied-to message, `{"id","snippet","kind"}`.
    pub reply_json: Option<String>,
    /// Set when the author edited the text.
    pub edited_ts: Option<i64>,
    /// Deleted for everyone by its author — a tombstone row.
    pub deleted: bool,
    /// `{"❤️": ["me", "<sender hex>"]}`.
    pub reactions_json: Option<String>,
    /// Incoming: MLS-authenticated sender identity key (hex).
    pub sender_id: Option<String>,
    /// v8 — unix time after which the message is deleted (disappearing).
    pub expire_at: Option<i64>,
    /// v17 (ADR-070) — formatting of `body` as JSON ranges
    /// (`[{"t":"bold","o":0,"l":4}]`, UTF-16 offsets; `[]` = plain). None:
    /// an older app's message — its `*stars*` may be markers.
    pub entities_json: Option<String>,
}

/// Everything stored for a new message row ([`message_insert`]).
#[derive(Debug, Clone, Default)]
pub struct NewMessage<'a> {
    pub id: &'a str,
    pub chat_id: &'a str,
    pub ts_unix: i64,
    pub body: &'a str,
    pub kind: &'a str,
    pub is_mine: bool,
    pub sender_label: Option<&'a str>,
    pub media_json: Option<&'a str>,
    pub wire_id: Option<&'a str>,
    pub reply_json: Option<&'a str>,
    pub sender_id: Option<&'a str>,
    pub expire_at: Option<i64>,
    /// ADR-070 — see [`StoredMessage::entities_json`].
    pub entities_json: Option<&'a str>,
}

/// Who asks to edit / delete a message: me, or an incoming peer
/// identified by their MLS-authenticated identity key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Author<'a> {
    Me,
    Peer(&'a str),
}

/// Global singleton — the entire app shares one DB connection. Wrapped
/// in `Mutex<Option<...>>` so we can swap the underlying connection at
/// runtime when [`migrate_unencrypted_to_encrypted`] re-keys the file.
/// `Connection` is `!Sync` (one thread at a time), Dart-side calls are
/// serialized via frb's worker thread anyway, so contention is not a
/// concern in Phase 2.
///
/// CRIT-1.1 — was `OnceLock<Mutex<Connection>>` originally. Replaced
/// because OnceLock cannot be reset, blocking the plain → encrypted
/// migration that runs after the user enters their phrase. `Mutex::new`
/// has been `const` since Rust 1.63, so a bare `static Mutex<...>` is
/// safe without `LazyLock` / `lazy_static`.
static DB: Mutex<Option<DbState>> = Mutex::new(None);

/// Path + connection pair so [`migrate_unencrypted_to_encrypted`] can
/// rediscover the on-disk file when the caller asks to re-key. Kept
/// crate-private — outside code sees only [`Connection`] through
/// [`with_db`].
struct DbState {
    conn: Connection,
    path: PathBuf,
}

const SCHEMA_V1: &str = "
CREATE TABLE IF NOT EXISTS identities (
    -- One row per persisted identity. In Phase 2 we expect exactly one
    -- (the current device's identity); the schema is row-keyed by
    -- phrase_hash so future multi-account flows can re-use it.
    phrase_hash      TEXT NOT NULL PRIMARY KEY,
    fingerprint      TEXT NOT NULL,
    ed25519_pub_hex  TEXT NOT NULL,
    x25519_pub_hex   TEXT NOT NULL,
    created_at_unix  INTEGER NOT NULL
);
";

/// v2 migration — adds chats + messages. Idempotent (CREATE IF NOT
/// EXISTS) so calling open() on an already-v2 DB is fine.
const SCHEMA_V2_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS chats (
    id                     TEXT NOT NULL PRIMARY KEY,
    display_name           TEXT NOT NULL,
    is_group               INTEGER NOT NULL DEFAULT 0,
    muted                  INTEGER NOT NULL DEFAULT 0,
    pinned                 INTEGER NOT NULL DEFAULT 0,
    unread_count           INTEGER NOT NULL DEFAULT 0,
    -- Denormalized last-message preview so ChatList SELECT is cheap.
    -- Updated by message_append() — never edited directly.
    last_msg_preview       TEXT,
    last_msg_ts_unix       INTEGER NOT NULL DEFAULT 0,
    last_msg_kind          TEXT NOT NULL DEFAULT 'text',
    last_msg_sender_label  TEXT,
    last_msg_mine          INTEGER NOT NULL DEFAULT 0,
    created_at_unix        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_chats_pinned_last_ts
    ON chats(pinned DESC, last_msg_ts_unix DESC);

CREATE TABLE IF NOT EXISTS messages (
    id            TEXT NOT NULL PRIMARY KEY,
    chat_id       TEXT NOT NULL,
    ts_unix       INTEGER NOT NULL,
    body          TEXT NOT NULL,
    kind          TEXT NOT NULL DEFAULT 'text',
    is_mine       INTEGER NOT NULL DEFAULT 0,
    sender_label  TEXT,
    FOREIGN KEY (chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_msgs_chat_ts
    ON messages(chat_id, ts_unix DESC);
";

/// CD9 — v3 migration: call history. WU 57 (Calls tab) reads from this
/// table. Populated by the Flutter activeCallProvider on call end.
const SCHEMA_V3_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS calls (
    -- The UUIDv7 call_id chosen by the original caller (same id both
    -- parties see for the same call).
    id                  TEXT NOT NULL PRIMARY KEY,
    -- The MLS group_id (= chat_id for 1:1) — lets the UI surface
    -- 'Call from <chat>' and link back to the chat view.
    peer_chat_id        TEXT NOT NULL,
    -- 'audio' | 'video'.
    kind                TEXT NOT NULL DEFAULT 'audio',
    -- Outcome label. Common values: 'completed', 'missed',
    -- 'declined', 'no_answer', 'rejected', 'network_lost', 'error'.
    status              TEXT NOT NULL DEFAULT 'completed',
    -- 1 if we initiated, 0 if the peer did.
    is_outgoing         INTEGER NOT NULL DEFAULT 0,
    -- Unix seconds at the start of the call (when CallInvite was sent).
    started_at_unix     INTEGER NOT NULL,
    -- Unix seconds when the call terminated. Nullable for in-flight
    -- rows (shouldn't normally occur — we only insert on terminal).
    ended_at_unix       INTEGER,
    -- Active media-flowing duration in seconds. NULL for never-connected
    -- (missed / declined) calls.
    duration_secs       INTEGER
);

CREATE INDEX IF NOT EXISTS idx_calls_started_at
    ON calls(started_at_unix DESC);
";

/// v4 — media messages (ADR-017). The envelope JSON carries the
/// per-blob AES keys, so it must stay inside this encrypted DB.
const SCHEMA_V4_UPGRADE: &str = "
ALTER TABLE messages ADD COLUMN media_json TEXT;
";

/// v5 — persisted app settings (key/value), e.g. `link_previews`.
/// Lives in the encrypted DB with everything else.
const SCHEMA_V5_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS settings (
    key     TEXT NOT NULL PRIMARY KEY,
    value   TEXT NOT NULL
);
";

/// v6 — chat-list organisation: archive, pinned order, drafts, manual
/// "mark unread" (UI backlog §2). ALTERs are guarded per column.
const SCHEMA_V6_COLUMNS: &[(&str, &str)] = &[
    ("archived", "ALTER TABLE chats ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;"),
    ("pin_order", "ALTER TABLE chats ADD COLUMN pin_order INTEGER NOT NULL DEFAULT 0;"),
    ("draft", "ALTER TABLE chats ADD COLUMN draft TEXT;"),
    ("marked_unread", "ALTER TABLE chats ADD COLUMN marked_unread INTEGER NOT NULL DEFAULT 0;"),
];

/// v7 — message actions (ADR-019): wire id, delivery status, replies,
/// edits, deletes, reactions, authenticated sender. (table, column, DDL)
const SCHEMA_V7_COLUMNS: &[(&str, &str, &str)] = &[
    ("messages", "wire_id", "ALTER TABLE messages ADD COLUMN wire_id TEXT;"),
    ("messages", "status", "ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 0;"),
    ("messages", "reply_json", "ALTER TABLE messages ADD COLUMN reply_json TEXT;"),
    ("messages", "edited_ts", "ALTER TABLE messages ADD COLUMN edited_ts INTEGER;"),
    ("messages", "deleted", "ALTER TABLE messages ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;"),
    ("messages", "reactions_json", "ALTER TABLE messages ADD COLUMN reactions_json TEXT;"),
    ("messages", "sender_id", "ALTER TABLE messages ADD COLUMN sender_id TEXT;"),
    ("chats", "pinned_msg", "ALTER TABLE chats ADD COLUMN pinned_msg TEXT;"),
];

/// v8 — disappearing messages (backlog §6 item 51).
const SCHEMA_V8_COLUMNS: &[(&str, &str, &str)] = &[
    ("chats", "disappear_secs", "ALTER TABLE chats ADD COLUMN disappear_secs INTEGER NOT NULL DEFAULT 0;"),
    ("messages", "expire_at", "ALTER TABLE messages ADD COLUMN expire_at INTEGER;"),
];

/// Highest schema version this build knows (`PRAGMA user_version`).
pub const SCHEMA_VERSION: i64 = 20;

/// Id prefix of a message that arrived through the server (`remote-<wire>`).
const REMOTE_ID_PREFIX: &str = "remote-";

/// v18 — owner, 2026-10-20: incoming frames that failed to decrypt (a second
/// copy of a delivery) were stored as "<binary 574B>" bubbles; the app no
/// longer stores them — clear the ones already here.
/// v19 — status 213, "Message info": when each person got / read my
/// message (a group has one row per member). Gone with the message.
const SCHEMA_V19_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS message_receipts (
    wire_id      TEXT NOT NULL,
    peer         TEXT NOT NULL,
    delivered_at INTEGER,
    read_at      INTEGER,
    PRIMARY KEY (wire_id, peer)
) WITHOUT ROWID;
CREATE TRIGGER IF NOT EXISTS message_receipts_gone AFTER DELETE ON messages
WHEN OLD.wire_id IS NOT NULL AND OLD.is_mine = 1
BEGIN
    DELETE FROM message_receipts WHERE wire_id = OLD.wire_id;
END;
";

const SCHEMA_V18_UPGRADE: &str =
    "DELETE FROM messages WHERE is_mine = 0 AND kind = 'text' AND body GLOB '<binary [0-9]*B>';";

/// v17 — ADR-070: message formatting (JSON ranges beside the clean text).
/// Guarded per column, so the number can move if a parallel branch takes
/// 17 first.
const SCHEMA_V17_COLUMNS: &[(&str, &str, &str)] =
    &[("messages", "entities_json", "ALTER TABLE messages ADD COLUMN entities_json TEXT;")];

/// v9 — tech-debt 2.22 / 2.27: other people's display names (their own
/// `Profile`, per identity key, shared by every chat), people this device
/// blocked, and which name we last announced in each chat.
const SCHEMA_V9_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS peer_names (
    peer_id    TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    updated_ts INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS blocked_peers (
    peer_id    TEXT PRIMARY KEY,
    blocked_ts INTEGER NOT NULL
);
";
const SCHEMA_V9_COLUMNS: &[(&str, &str, &str)] =
    &[("chats", "profile_sent", "ALTER TABLE chats ADD COLUMN profile_sent TEXT;")];

/// v10 — tech-debt 2.21: full-text index over message text (FTS5,
/// trigram tokenizer: substring matches, Unicode case folding — so
/// «мир» finds «МИР»). It lives inside the same SQLCipher file, so it is
/// encrypted like everything else. Triggers keep it in step with every
/// insert, edit, delete-for-everyone, expiry and chat deletion (FK
/// cascades fire them too). Rows are keyed by `messages.rowid`; nothing
/// here runs VACUUM — if it ever does, run
/// `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')`-style
/// re-indexing (`fts_reindex`) afterwards.
const SCHEMA_V10_UPGRADE: &str = "
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(body, tokenize = 'trigram');
INSERT INTO messages_fts(messages_fts, rank) VALUES('secure-delete', 1);
CREATE TRIGGER IF NOT EXISTS messages_fts_ai AFTER INSERT ON messages
WHEN new.deleted = 0 AND new.body <> '' BEGIN
    INSERT INTO messages_fts(rowid, body) VALUES (new.rowid, new.body);
END;
CREATE TRIGGER IF NOT EXISTS messages_fts_ad AFTER DELETE ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.rowid;
END;
CREATE TRIGGER IF NOT EXISTS messages_fts_au AFTER UPDATE OF body, deleted ON messages BEGIN
    DELETE FROM messages_fts WHERE rowid = old.rowid;
    INSERT INTO messages_fts(rowid, body) SELECT new.rowid, new.body WHERE new.deleted = 0 AND new.body <> '';
END;
";

/// v11 — tech-debt 2.27: message requests. A chat someone else started
/// (joined through a Welcome) is a request until I accept it or write in
/// it (from any of my devices). Existing chats count as accepted.
const SCHEMA_V11_COLUMNS: &[(&str, &str, &str)] =
    &[("chats", "request", "ALTER TABLE chats ADD COLUMN request INTEGER NOT NULL DEFAULT 0;")];

/// v13 — tech-debt 2.21: someone @-mentioned me in this chat and I haven't
/// read it yet ("@" badge in the list; notifies even when muted).
const SCHEMA_V13_COLUMNS: &[(&str, &str, &str)] =
    &[("chats", "mentioned", "ALTER TABLE chats ADD COLUMN mentioned INTEGER NOT NULL DEFAULT 0;")];

/// v14 — tech-debt 2.21: people's photos (a re-encoded ≤32 KB JPEG, per
/// identity key) and, for personal chats, who the other person is.
const SCHEMA_V14_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS peer_avatars (
    peer_id    TEXT PRIMARY KEY,
    jpeg       BLOB NOT NULL,
    updated_ts INTEGER NOT NULL
);
";
const SCHEMA_V14_COLUMNS: &[(&str, &str, &str)] = &[("chats", "peer_id", "ALTER TABLE chats ADD COLUMN peer_id TEXT;")];

/// v15 — ADR-052: contacts are a list of their own (a person stays after
/// their chat is deleted; "Remove from contacts" is separate), and other
/// people's bios (from their `profile`, per identity key). `name` is the
/// name I first knew them by (their QR / invite / the chat's name) — shown
/// until they share their own. Existing accepted personal chats whose
/// person is known become contacts, so nobody vanishes on upgrade.
const SCHEMA_V15_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS contacts (
    peer_id    TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT '',
    favourite  INTEGER NOT NULL DEFAULT 0,
    added_ts   INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS peer_bios (
    peer_id    TEXT PRIMARY KEY,
    bio        TEXT NOT NULL,
    updated_ts INTEGER NOT NULL
);
INSERT OR IGNORE INTO contacts (peer_id, name, added_ts)
    SELECT lower(peer_id), display_name, created_at_unix FROM chats
    WHERE is_group = 0 AND request = 0 AND peer_id IS NOT NULL AND peer_id <> ''
    ORDER BY last_msg_ts_unix DESC;
";

/// v16 — ADR-064: sync clocks of what follows me to my other devices
/// (`devsync`): wall-clock ms for last-writer-wins, a local sequence for
/// "not sent yet". Idempotent (CREATE IF NOT EXISTS) — the number can move
/// if a parallel branch takes 16 first.
const SCHEMA_V16_UPGRADE: &str = "
CREATE TABLE IF NOT EXISTS sync_clock (
    item    TEXT PRIMARY KEY,
    ts      INTEGER NOT NULL,
    seq     INTEGER NOT NULL DEFAULT 0,
    local   INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_sync_clock_seq ON sync_clock(seq) WHERE local = 1;
";

/// Fill the index from scratch (migration to v10; also after a VACUUM).
fn fts_reindex(conn: &Connection) -> Result<(), StorageError> {
    conn.execute_batch(
        "DELETE FROM messages_fts;
         INSERT INTO messages_fts(rowid, body) SELECT rowid, body FROM messages WHERE deleted = 0 AND body <> '';",
    )?;
    Ok(())
}

/// Shortest query the trigram index can answer; shorter ones fall back
/// to a `LIKE` scan.
const FTS_MIN_CHARS: usize = 3;

/// Incoming rows were always stored as `remote-<wire uuid>`; existing
/// own messages count as sent.
const SCHEMA_V7_BACKFILL: &str = "
UPDATE messages SET wire_id = substr(id, 8) WHERE wire_id IS NULL AND id LIKE 'remote-%';
UPDATE messages SET status = 1 WHERE is_mine = 1 AND status = 0;
CREATE INDEX IF NOT EXISTS idx_msgs_wire ON messages(wire_id);
";

/// Apply all pending migrations to an open SQLite connection. Pure
/// function — no global state — so unit tests can exercise migrations
/// on an in-memory DB without taking the global singleton.
///
/// Schema versioning uses SQLite's built-in `PRAGMA user_version` —
/// canonical and crash-safe. An earlier WU 73 version used a
/// `schema_version(version PRIMARY KEY)` table with an `UPDATE ... WHERE
/// version < N` migration step that broke on second cold-launch (the
/// `INSERT OR IGNORE` re-inserted v1, then the UPDATE tried to set it
/// to v2 — conflict with the existing v2 row → PK violation). We DROP
/// that stale table here so already-broken DBs recover.
fn apply_migrations(conn: &Connection) -> Result<(), StorageError> {
    // WU "Risk #1" — устойчивость к iOS background-kill.
    //
    // Default `journal_mode = DELETE` is fine on desktop but on iOS the
    // OS can kill our process at ANY moment (low memory, background
    // timeout, system push). If kill lands between a multi-statement
    // write and the journal-rollback flush, the DB can end up in an
    // inconsistent state — group dies, chats vanish, etc.
    //
    // WAL journal:
    //   • writers don't block readers (better concurrency)
    //   • each commit is atomic via a sidecar `-wal` file rename
    //   • crash mid-write rolls back to the pre-write snapshot on
    //     next open (recovery is automatic by SQLite)
    //   • `synchronous = NORMAL` is the documented safe pairing with
    //     WAL — `FULL` would fsync after every commit (slow on iOS
    //     flash), `NORMAL` fsyncs only on checkpoint (data still safe
    //     because the WAL is append-only and rename'd atomically).
    //
    // foreign_keys, journal_mode, synchronous are connection-level
    // PRAGMAs — must be re-applied on every Connection::open(...). The
    // WAL file (`.sqlite-wal`) is created/used automatically by SQLite.
    conn.execute_batch(
        "PRAGMA foreign_keys = ON; \
         PRAGMA journal_mode = WAL; \
         PRAGMA synchronous = NORMAL; \
         PRAGMA secure_delete = ON;",
    )?;

    // Migration recovery: drop the legacy schema_version table from
    // WU 73's broken initial pattern. Identities / chats / messages
    // data persists — only the migration marker table is wiped.
    conn.execute_batch("DROP TABLE IF EXISTS schema_version;")?;

    // Read the canonical version marker. New DBs report 0.
    let current_version: i64 = conn
        .query_row("PRAGMA user_version", [], |row| row.get(0))?;

    if current_version < 1 {
        conn.execute_batch(SCHEMA_V1)?;
    }
    if current_version < 2 {
        conn.execute_batch(SCHEMA_V2_UPGRADE)?;
    }
    if current_version < 3 {
        conn.execute_batch(SCHEMA_V3_UPGRADE)?;
    }
    if current_version < 4 {
        // ALTER TABLE ADD COLUMN isn't idempotent — guard on the column
        // actually being absent (e.g. a crash between ALTER and the
        // user_version bump).
        let has_col: bool = conn
            .prepare("SELECT 1 FROM pragma_table_info('messages') WHERE name = 'media_json'")?
            .exists([])?;
        if !has_col {
            conn.execute_batch(SCHEMA_V4_UPGRADE)?;
        }
    }
    if current_version < 5 {
        conn.execute_batch(SCHEMA_V5_UPGRADE)?;
    }
    if current_version < 6 {
        for (col, ddl) in SCHEMA_V6_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('chats') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
    }
    if current_version < 7 {
        for (table, col, ddl) in SCHEMA_V7_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
        conn.execute_batch(SCHEMA_V7_BACKFILL)?;
    }
    if current_version < 8 {
        for (table, col, ddl) in SCHEMA_V8_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
        conn.execute_batch("CREATE INDEX IF NOT EXISTS idx_msgs_expire ON messages(expire_at) WHERE expire_at IS NOT NULL;")?;
    }
    if current_version < 9 {
        conn.execute_batch(SCHEMA_V9_UPGRADE)?;
        for (table, col, ddl) in SCHEMA_V9_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
    }
    if current_version < 10 {
        conn.execute_batch(SCHEMA_V10_UPGRADE)?;
        fts_reindex(conn)?;
    }
    if current_version < 12 {
        // v12 — review fix: FTS5 keeps deleted rows' trigrams in its index
        // segments until a merge unless secure-delete is on; deleted and
        // expired messages must not be recoverable from the index. Turn it
        // on (persistent) and rebuild so existing segments are clean.
        if current_version >= 10 {
            conn.execute_batch("DROP TABLE IF EXISTS messages_fts;")?;
            conn.execute_batch(SCHEMA_V10_UPGRADE)?;
            fts_reindex(conn)?;
        }
    }
    if current_version < 14 {
        conn.execute_batch(SCHEMA_V14_UPGRADE)?;
        for (table, col, ddl) in SCHEMA_V14_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
    }
    if current_version < 13 {
        for (table, col, ddl) in SCHEMA_V13_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
    }
    if current_version < 11 {
        for (table, col, ddl) in SCHEMA_V11_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
    }
    if current_version < 15 {
        // After v11 / v14: the backfill reads chats.request and chats.peer_id.
        conn.execute_batch(SCHEMA_V15_UPGRADE)?;
    }
    if current_version < 16 {
        conn.execute_batch(SCHEMA_V16_UPGRADE)?;
    }
    if current_version < 17 {
        for (table, col, ddl) in SCHEMA_V17_COLUMNS {
            let has = conn
                .prepare(&format!("SELECT 1 FROM pragma_table_info('{table}') WHERE name = '{col}'"))?
                .exists([])?;
            if !has {
                conn.execute_batch(ddl)?;
            }
        }
    }
    if current_version < 18 {
        conn.execute_batch(SCHEMA_V18_UPGRADE)?;
    }
    if current_version < 19 {
        conn.execute_batch(SCHEMA_V19_UPGRADE)?;
    }
    if current_version < 20 {
        // Status 223 — mine from another device, stuck on "sending".
        conn.execute_batch("UPDATE messages SET status = 1 WHERE is_mine = 1 AND status = 0 AND id LIKE 'remote-%';")?;
    }
    // Always set to the highest known version (idempotent). PRAGMA
    // statements don't accept bound parameters, so this is interpolated.
    conn.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION};"))?;
    // Settings from before device sync (v16) get a clock so they reach my
    // other devices (2026-10-26). Cheap, idempotent — no version bump.
    devsync::stamp_unclocked_settings(conn)?;
    Ok(())
}

/// T1.1 — apply SQLCipher PRAGMA key before ANY other statement.
///
/// `PRAGMA key = "x'<hex>'"` MUST be the first thing run against a
/// freshly-opened connection — before any read or write. After this,
/// rusqlite + SQLCipher transparently encrypt every page with AES-256.
///
/// On a fresh DB the key is recorded in the file header; opening with
/// the wrong key returns "file is not a database" (SQLite cannot
/// distinguish "encrypted with different key" from "garbage"). That's
/// the right behavior for our threat model: we don't want partial
/// reads or attacker-controlled error oracles.
///
/// On an existing plaintext DB, applying a PRAGMA key turns it into
/// "encrypted DB" from SQLite's perspective, but the underlying pages
/// stay plaintext. To migrate plaintext → encrypted we use
/// `sqlcipher_export()` (see `migrate_unencrypted_to_encrypted`).
fn apply_encryption_key(conn: &Connection, key: &[u8; 32]) -> Result<(), StorageError> {
    // SQLCipher accepts either:
    //   PRAGMA key = "password"                — derives via PBKDF2
    //   PRAGMA key = "x'<64-hex>'"             — raw key, no KDF
    // We use raw form because our key is ALREADY derived via HKDF
    // from the BIP-39 phrase (sinhron_crypto::identity), so PBKDF2
    // on top would be redundant work + extra failure mode.
    let pragma = format!("PRAGMA key = \"x'{}'\";", hex::encode(key));
    conn.execute_batch(&pragma)?;
    Ok(())
}

/// Open / create the DB at [path]. Idempotent — if a connection is
/// already installed (regardless of path) this is a no-op.
///
/// **T1.1 — SQLCipher**: when `key` is `Some`, the DB is opened in
/// encrypted mode. PRAGMA key is applied BEFORE migrations. `None`
/// runs unencrypted — kept for dev / pre-onboarding state. Once the
/// user enters their phrase the caller invokes
/// [`migrate_unencrypted_to_encrypted`] to seal the plain DB.
///
/// A key that doesn't open the file — wrong key, no key on an encrypted
/// file, or a key on a still-plain file — returns [`StorageError::Locked`]
/// and leaves the file untouched (ADR-021).
pub fn open(path: &Path, key: Option<&[u8; 32]>) -> Result<(), StorageError> {
    let mut guard = DB.lock().map_err(poison_to_err)?;
    if guard.is_some() {
        // Already initialized — keep the existing handle. Reopening with
        // a different path or key is `reopen_with_key` / migration.
        return Ok(());
    }
    let conn = Connection::open(path)?;
    if let Some(k) = key {
        apply_encryption_key(&conn, k)?;
    }

    // ADR-021 (was the tech-debt 2.16 "self-heal"): an encrypted file
    // that this key (or no key) can't open is LOCKED, not garbage. The
    // old code wiped it whenever no key was given — every cold start
    // without the phrase destroyed the user's chats and identity. Now we
    // report Locked and let the app ask for the phrase; wiping is only
    // ever the explicit [`erase_and_reopen_plain`].
    match apply_migrations(&conn) {
        Ok(()) => {}
        Err(StorageError::Sql(e)) if e.to_string().contains("file is not a database") => {
            return Err(StorageError::Locked);
        }
        Err(other) => return Err(other),
    }

    *guard = Some(DbState {
        conn,
        path: path.to_path_buf(),
    });
    drop(guard);
    // ADR-033 — tidy local media copies no row references any more.
    // Only for a keyed (unlocked) DB; off the caller's thread.
    if key.is_some() {
        std::thread::spawn(|| {
            let _ = blobs::gc(std::time::Duration::from_secs(blobs::GC_GRACE_SECS));
            // Tech-debt 2.32 — Settings → Storage → "Keep media copies".
            if let Some(days) = setting_get(MEDIA_KEEP_DAYS_KEY).ok().flatten().and_then(|d| d.parse::<u64>().ok()) {
                if days > 0 {
                    let _ = blobs::clear_copies(std::time::Duration::from_secs(days * 86_400));
                }
            }
        });
    }
    Ok(())
}

/// The setting (days, "0" = forever) for how long an unused local media copy
/// is kept; the app writes it, [open] applies it (tech-debt 2.32).
pub const MEDIA_KEEP_DAYS_KEY: &str = "media_keep_days";

/// CRIT-1.1 — migrate a plain SQLite file at the singleton's known path
/// into an SQLCipher-encrypted file at the same path, then reopen the
/// singleton against the new file. Steps:
///
/// 1. Take the lock and read the current path from [`DbState`].
/// 2. Drop the live `Connection` so the OS file lock is released
///    (iOS in particular is touchy about this).
/// 3. Pick `<path>.encrypted.tmp` as the staging file. Wipe any
///    leftovers from a previous interrupted migration.
/// 4. Open a transient `Connection` against the (still plain) path.
/// 5. `ATTACH '<tmp>' AS sinhron_encrypted KEY "x'<hex>'"`
/// 6. `SELECT sqlcipher_export('sinhron_encrypted')` — page-by-page copy.
/// 7. `DETACH sinhron_encrypted`, drop the transient connection.
/// 8. Wipe `<path>-wal`, `<path>-shm` from the plain DB (encrypted DB
///    will create fresh sidecars). Rename `<tmp>` → `<path>` (atomic
///    on POSIX; on Windows replaces).
/// 9. Open a new encrypted `Connection` against `<path>`, apply
///    migrations (idempotent — verifies schema matches what we exported),
///    install it as the new singleton.
///
/// Crash safety:
///   - Crash before step 8 rename: plain DB intact, `<tmp>` is leftover
///     junk. Next migration call retries cleanly (we wipe leftovers
///     first).
///   - Crash after step 8: file at `<path>` is already encrypted. Next
///     boot's `open(path, Some(key))` reads it correctly.
///   - Crash between rename and singleton install: file is encrypted;
///     singleton was dropped in step 2. App effectively "lost connection"
///     until next launch.
pub fn migrate_unencrypted_to_encrypted(key: &[u8; 32]) -> Result<(), StorageError> {
    let mut guard = DB.lock().map_err(poison_to_err)?;

    let state = guard
        .take()
        .ok_or(StorageError::NotInitialized)?;
    let path = state.path.clone();
    // Drop the live connection — releases the file lock so we can
    // re-open / rename.
    drop(state);

    let tmp_path = staging_path(&path);
    // Wipe stale leftovers from a previous interrupted run. Best-effort —
    // missing files are fine.
    let _ = std::fs::remove_file(&tmp_path);
    let _ = std::fs::remove_file(path_with_suffix(&tmp_path, "-wal"));
    let _ = std::fs::remove_file(path_with_suffix(&tmp_path, "-shm"));

    // Migration scope — separate function so the transient connection
    // drops automatically before we touch the filesystem.
    let migrate_result = export_plain_to_encrypted(&path, &tmp_path, key);

    if let Err(e) = migrate_result {
        // Clean up the staging file on failure, then re-install the
        // original plain connection so the app stays functional. Without
        // this, the singleton stays None and every subsequent storage
        // call returns NotInitialized.
        let _ = std::fs::remove_file(&tmp_path);
        if let Ok(conn) = Connection::open(&path) {
            if apply_migrations(&conn).is_ok() {
                *guard = Some(DbState { conn, path });
            }
        }
        return Err(e);
    }

    // Wipe the plain DB's WAL sidecars — the encrypted file will have
    // its own. Best-effort: WAL may not exist (no recent write).
    let _ = std::fs::remove_file(path_with_suffix(&path, "-wal"));
    let _ = std::fs::remove_file(path_with_suffix(&path, "-shm"));

    // Replace the plain file with the encrypted copy. On POSIX `rename`
    // is atomic on the same filesystem.
    std::fs::rename(&tmp_path, &path).map_err(|e| {
        StorageError::Sql(rusqlite::Error::ToSqlConversionFailure(
            format!("rename {tmp_path:?} → {path:?} failed: {e}").into(),
        ))
    })?;

    // Open the new encrypted singleton.
    let conn = Connection::open(&path)?;
    apply_encryption_key(&conn, key)?;
    apply_migrations(&conn)?;
    *guard = Some(DbState { conn, path });

    Ok(())
}

/// ADR-021 — the user chose "Erase and start over" (or signed out):
/// close the singleton, delete the file and its WAL sidecars, and open
/// a fresh plain DB at the same path (onboarding seals it again).
/// When nothing is open yet (a locked boot), [path] says which file.
pub fn erase_and_reopen_plain(path: &Path) -> Result<(), StorageError> {
    let mut guard = DB.lock().map_err(poison_to_err)?;
    let path = guard.take().map(|s| s.path.clone()).unwrap_or_else(|| path.to_path_buf());
    for p in [path.clone(), path_with_suffix(&path, "-wal"), path_with_suffix(&path, "-shm"), staging_path(&path)] {
        let _ = std::fs::remove_file(p);
    }
    // ADR-033 — the local media copies go with the DB.
    let _ = std::fs::remove_dir_all(blobs::dir_for(&path));
    // ADR-049 — and the sticker packs.
    let _ = std::fs::remove_dir_all(stickers::dir_for(&path));
    // ADR-064 — and parts of an unfinished device transfer.
    let _ = std::fs::remove_dir_all(transfer::dir_for(&path));
    let conn = Connection::open(&path)?;
    apply_migrations(&conn)?;
    *guard = Some(DbState { conn, path });
    Ok(())
}

/// Transient migration step: open the plain DB, `sqlcipher_export` it
/// into `tmp_path` keyed by `key`, close. Extracted so the connection
/// drops at end of scope.
fn export_plain_to_encrypted(
    plain_path: &Path,
    tmp_path: &Path,
    key: &[u8; 32],
) -> Result<(), StorageError> {
    let conn = Connection::open(plain_path)?;
    // We do NOT apply migrations / journal pragmas here — we're just
    // copying pages. sqlcipher_export is read-only on the source side.

    // ATTACH with the new key. SQLCipher creates the file if missing.
    // We bind path/key via parameter substitution-safe construction:
    // tmp_path goes into the SQL string (file system path, not user
    // input), key is rendered as hex. PRAGMA-style "x'<hex>'" is the
    // raw-key form, no PBKDF2.
    let tmp_str = tmp_path
        .to_str()
        .ok_or_else(|| StorageError::Sql(rusqlite::Error::ToSqlConversionFailure(
            format!("non-UTF-8 tmp path: {tmp_path:?}").into(),
        )))?;
    // Escape any single quotes in the path (extremely defensive — paths
    // with apostrophes are unusual on iOS sandbox).
    if tmp_str.contains('\'') {
        return Err(StorageError::Sql(rusqlite::Error::ToSqlConversionFailure(
            format!("path contains single quote, refusing: {tmp_str}").into(),
        )));
    }
    let attach = format!(
        "ATTACH DATABASE '{}' AS sinhron_encrypted KEY \"x'{}'\";",
        tmp_str,
        hex::encode(key),
    );
    conn.execute_batch(&attach)?;

    // The actual page-by-page copy. SQLCipher's sqlcipher_export is a
    // SELECT that returns no rows but executes the export as a side
    // effect; `query_row` with a discarded result is the standard
    // invocation.
    let _: Result<i64, _> =
        conn.query_row("SELECT sqlcipher_export('sinhron_encrypted')", [], |row| {
            row.get::<_, i64>(0)
        });
    // The query returns rows=0 — the .ok()/.err() of `query_row` reports
    // QueryReturnedNoRows for this no-result-set case, NOT an error.
    // Either way, by the time we reach DETACH, the export has run.

    conn.execute_batch("DETACH DATABASE sinhron_encrypted;")?;
    // Connection drops on function return.
    Ok(())
}

fn staging_path(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "sinhron.db".to_string());
    name.push_str(".encrypted.tmp");
    path.with_file_name(name)
}

pub(crate) fn path_with_suffix(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    name.push_str(suffix);
    path.with_file_name(name)
}

fn poison_to_err<T>(e: std::sync::PoisonError<T>) -> StorageError {
    StorageError::Sql(rusqlite::Error::ToSqlConversionFailure(
        format!("mutex poison: {e}").into(),
    ))
}

#[cfg(test)]
fn _force_close_for_tests() {
    // Helper for the `migrate_*` tests — drops the singleton so the
    // test can simulate "process boot" semantics. Public test-only API.
    if let Ok(mut g) = DB.lock() {
        *g = None;
    }
}

/// Return a SHA-256 hash of the phrase, formatted as 64-char lowercase
/// hex. Used as the PRIMARY KEY for the identities table so we don't
/// store the secret words themselves.
pub fn phrase_hash_hex(phrase: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(phrase.as_bytes());
    hex::encode(hasher.finalize())
}

fn with_db<R>(f: impl FnOnce(&Connection) -> Result<R, StorageError>) -> Result<R, StorageError> {
    let guard = DB.lock().map_err(poison_to_err)?;
    let state = guard.as_ref().ok_or(StorageError::NotInitialized)?;
    f(&state.conn)
}

// ─────────────────────────────────────────────────────────────────────
// Identities
// ─────────────────────────────────────────────────────────────────────

/// Insert or replace the identity row for the given phrase. The phrase
/// itself is NEVER stored — only its hash + the derived public keys.
pub fn save_identity(
    phrase: &str,
    fingerprint: &str,
    ed25519_pub_hex: &str,
    x25519_pub_hex: &str,
    created_at_unix: i64,
) -> Result<(), StorageError> {
    let ph = phrase_hash_hex(phrase);
    with_db(|conn| {
        conn.execute(
            "INSERT OR REPLACE INTO identities \
             (phrase_hash, fingerprint, ed25519_pub_hex, x25519_pub_hex, created_at_unix) \
             VALUES (?, ?, ?, ?, ?)",
            params![ph, fingerprint, ed25519_pub_hex, x25519_pub_hex, created_at_unix],
        )?;
        Ok(())
    })
}

/// Return the most-recently-saved identity, or None if the table is
/// empty (e.g. fresh install / pre-onboarding).
pub fn load_latest_identity() -> Result<Option<StoredIdentity>, StorageError> {
    with_db(|conn| {
        let mut stmt = conn.prepare(
            "SELECT phrase_hash, fingerprint, ed25519_pub_hex, x25519_pub_hex, \
                    created_at_unix \
             FROM identities ORDER BY created_at_unix DESC LIMIT 1",
        )?;
        let mut rows = stmt.query([])?;
        match rows.next()? {
            None => Ok(None),
            Some(row) => Ok(Some(StoredIdentity {
                phrase_hash: row.get(0)?,
                fingerprint: row.get(1)?,
                ed25519_pub_hex: row.get(2)?,
                x25519_pub_hex: row.get(3)?,
                created_at_unix: row.get(4)?,
            })),
        }
    })
}

/// Delete all identity rows. Used by the Sign-out flow (per spec §6.7:
/// per-device sign-out wipes the local keystore).
pub fn wipe_identities() -> Result<(), StorageError> {
    with_db(|conn| {
        conn.execute("DELETE FROM identities", [])?;
        Ok(())
    })
}

// ─────────────────────────────────────────────────────────────────────
// Chats
// ─────────────────────────────────────────────────────────────────────

/// Insert OR REPLACE a chat row. Used both for creating new chats
/// (Compose flow) and for syncing remote updates. The id is the caller's
/// responsibility — usually a UUID for 1:1 chats or the MLS group id
/// (hex-encoded) once group operations land.
#[allow(clippy::too_many_arguments)]
pub fn chat_upsert(
    id: &str,
    display_name: &str,
    is_group: bool,
    muted: bool,
    pinned: bool,
    unread_count: i64,
    last_msg_preview: Option<&str>,
    last_msg_ts_unix: i64,
    last_msg_kind: &str,
    last_msg_sender_label: Option<&str>,
    last_msg_mine: bool,
    created_at_unix: i64,
) -> Result<(), StorageError> {
    with_db(|conn| {
        conn.execute(
            "INSERT OR REPLACE INTO chats \
             (id, display_name, is_group, muted, pinned, unread_count, \
              last_msg_preview, last_msg_ts_unix, last_msg_kind, \
              last_msg_sender_label, last_msg_mine, created_at_unix) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                id,
                display_name,
                is_group as i64,
                muted as i64,
                pinned as i64,
                unread_count,
                last_msg_preview,
                last_msg_ts_unix,
                last_msg_kind,
                last_msg_sender_label,
                last_msg_mine as i64,
                created_at_unix,
            ],
        )?;
        Ok(())
    })
}

/// Return all chats, ordered with pinned first then most-recently-active
/// first. ChatList renders this verbatim.
pub fn chats_list() -> Result<Vec<StoredChat>, StorageError> {
    with_db(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, display_name, is_group, muted, pinned, unread_count, \
                    last_msg_preview, last_msg_ts_unix, last_msg_kind, \
                    last_msg_sender_label, last_msg_mine, created_at_unix, \
                    archived, pin_order, draft, marked_unread, pinned_msg, disappear_secs, \
                    (SELECT CASE WHEN m.is_mine = 1 AND m.deleted = 0 THEN m.status ELSE 0 END FROM messages m \
                      WHERE m.chat_id = chats.id ORDER BY m.ts_unix DESC, m.id DESC LIMIT 1), \
                    request, mentioned, peer_id \
             FROM chats \
             ORDER BY pinned DESC, pin_order ASC, last_msg_ts_unix DESC, created_at_unix DESC",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(StoredChat {
                id: row.get(0)?,
                display_name: row.get(1)?,
                is_group: row.get::<_, i64>(2)? != 0,
                muted: row.get::<_, i64>(3)? != 0,
                pinned: row.get::<_, i64>(4)? != 0,
                unread_count: row.get(5)?,
                last_msg_preview: row.get(6)?,
                last_msg_ts_unix: row.get(7)?,
                last_msg_kind: row.get(8)?,
                last_msg_sender_label: row.get(9)?,
                last_msg_mine: row.get::<_, i64>(10)? != 0,
                created_at_unix: row.get(11)?,
                archived: row.get::<_, i64>(12)? != 0,
                pin_order: row.get(13)?,
                draft: row.get(14)?,
                marked_unread: row.get::<_, i64>(15)? != 0,
                pinned_msg: row.get(16)?,
                disappear_secs: row.get(17)?,
                last_msg_status: row.get::<_, Option<i64>>(18)?.unwrap_or(0),
                request: row.get::<_, i64>(19)? != 0,
                mentioned: row.get::<_, i64>(20)? != 0,
                peer_id: row.get(21)?,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    })
}

/// Drop all chats (and their messages via ON DELETE CASCADE). Used by
/// the "Clear chat history" Settings → Storage flow (spec §6.6).
fn exec(sql: &str, p: impl rusqlite::Params) -> Result<(), StorageError> {
    with_db(|conn| {
        conn.execute(sql, p)?;
        Ok(())
    })
}

/// ADR-074 — move every message of chat [from] into [to] and drop [from]
/// (restored "Saved messages" whose old group this device can't post to:
/// the notes go on in the new one). Message ids stay; the newer preview
/// wins. Nothing happens unless both chats exist. Returns messages moved.
pub fn chat_merge_into(from: &str, to: &str) -> Result<usize, StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let has = |id: &str| -> Result<bool, rusqlite::Error> { tx.prepare("SELECT 1 FROM chats WHERE id = ?")?.exists(params![id]) };
        if from == to || !has(from)? || !has(to)? {
            return Ok(0);
        }
        let moved = tx.execute("UPDATE messages SET chat_id = ?1 WHERE chat_id = ?2", params![to, from])?;
        tx.execute(
            "UPDATE chats SET (last_msg_preview, last_msg_ts_unix, last_msg_kind, last_msg_sender_label, last_msg_mine) = \
               (SELECT last_msg_preview, last_msg_ts_unix, last_msg_kind, last_msg_sender_label, last_msg_mine FROM chats WHERE id = ?2) \
             WHERE id = ?1 AND (SELECT last_msg_ts_unix FROM chats WHERE id = ?2) > last_msg_ts_unix",
            params![to, from],
        )?;
        tx.execute("DELETE FROM chats WHERE id = ?", params![from])?;
        tx.commit()?;
        Ok(moved)
    })
}

/// Mark a chat as a message request (someone else started it) or accept it.
pub fn chat_set_request(id: &str, request: bool) -> Result<(), StorageError> {
    exec("UPDATE chats SET request = ? WHERE id = ?", params![request as i64, id])
}

/// Run [sql] on a chat and, when it changed the row, stamp the chat for
/// my other devices (ADR-064).
fn chat_exec_synced(id: &str, sql: &str, p: impl rusqlite::Params) -> Result<(), StorageError> {
    with_db(|conn| {
        if conn.execute(sql, p)? > 0 {
            devsync::stamp(conn, &devsync::chat_item(id), false)?;
        }
        Ok(())
    })
}

pub fn chat_set_muted(id: &str, muted: bool) -> Result<(), StorageError> {
    chat_exec_synced(id, "UPDATE chats SET muted = ? WHERE id = ?", params![muted as i64, id])
}

pub fn chat_set_archived(id: &str, archived: bool) -> Result<(), StorageError> {
    // Archiving unpins (as in Telegram); the archive is its own list.
    chat_exec_synced(
        id,
        "UPDATE chats SET archived = ?, pinned = CASE WHEN ? THEN 0 ELSE pinned END WHERE id = ?",
        params![archived as i64, archived as i64, id],
    )
}

/// Pin goes to the end of the pinned group; unpin clears the order.
pub fn chat_set_pinned(id: &str, pinned: bool) -> Result<(), StorageError> {
    if pinned {
        chat_exec_synced(
            id,
            "UPDATE chats SET pinned = 1, archived = 0, \
               pin_order = (SELECT COALESCE(MAX(pin_order), 0) + 1 FROM chats WHERE pinned = 1) \
             WHERE id = ?",
            params![id],
        )
    } else {
        chat_exec_synced(id, "UPDATE chats SET pinned = 0, pin_order = 0 WHERE id = ?", params![id])
    }
}

/// Rewrite pinned order to match `ids` (first = top).
pub fn chats_reorder_pinned(ids: &[String]) -> Result<(), StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        for (i, id) in ids.iter().enumerate() {
            if tx.execute("UPDATE chats SET pin_order = ? WHERE id = ? AND pinned = 1", params![i as i64 + 1, id])? > 0 {
                devsync::stamp(&tx, &devsync::chat_item(id), false)?;
            }
        }
        tx.commit()?;
        Ok(())
    })
}

pub fn chat_mark_read(id: &str) -> Result<(), StorageError> {
    with_db(|conn| {
        let changed = conn.execute(
            "UPDATE chats SET unread_count = 0, marked_unread = 0, mentioned = 0 \
             WHERE id = ? AND (unread_count > 0 OR marked_unread <> 0 OR mentioned <> 0)",
            params![id],
        )? > 0;
        // Status 223 — my other devices learn it (ADR-064): when something
        // was unread here, or a message came since the last time it was told
        // (read while the chat was open — no counter went up).
        let item = devsync::read_item(id);
        let since = devsync::clock_of(conn, &item)?.unwrap_or(0);
        let newer: bool = conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM messages WHERE chat_id = ? AND is_mine = 0 AND ts_unix * 1000 > ?)",
            params![id, since],
            |r| r.get(0),
        )?;
        if changed || newer {
            devsync::stamp(conn, &item, false)?;
        }
        Ok(())
    })
}

/// Someone @-mentioned me in an unread message here (cleared by reading).
pub fn chat_set_mentioned(id: &str) -> Result<(), StorageError> {
    exec("UPDATE chats SET mentioned = 1 WHERE id = ?", params![id])
}

pub fn chat_mark_unread(id: &str) -> Result<(), StorageError> {
    exec("UPDATE chats SET marked_unread = 1 WHERE id = ?", params![id])
}

/// Save (Some, non-empty) or clear (None / empty) the composer draft.
pub fn chat_set_draft(id: &str, draft: Option<&str>) -> Result<(), StorageError> {
    let d = draft.filter(|d| !d.trim().is_empty());
    exec("UPDATE chats SET draft = ? WHERE id = ?", params![d, id])
}

/// Delete one chat and (FK cascade) its messages, and their local
/// media copies (ADR-033).
pub fn chat_delete(id: &str) -> Result<(), StorageError> {
    let shas = with_db(|conn| {
        let shas = blobs::shas_of(conn, "SELECT media_json FROM messages WHERE chat_id = ?", params![id])?;
        conn.execute("DELETE FROM chats WHERE id = ?", params![id])?;
        Ok(shas)
    })?;
    blobs::drop_unreferenced(shas);
    Ok(())
}

/// A message hit from [`messages_search`].
#[derive(Debug, Clone)]
pub struct MessageHit {
    pub message_id: String,
    pub chat_id: String,
    pub chat_name: String,
    pub ts_unix: i64,
    pub body: String,
    /// Wire id — what the chat view scrolls to. None for old local rows.
    pub wire_id: Option<String>,
}

/// Local search over decrypted message text (it only exists in this
/// encrypted DB — the server can't search). Substring, case-insensitive
/// (Unicode); newest first. Three characters or more use the FTS5
/// trigram index (v10); shorter queries scan with `LIKE`.
pub fn messages_search(query: &str, limit: i64) -> Result<Vec<MessageHit>, StorageError> {
    let q = query.trim();
    if q.is_empty() {
        return Ok(Vec::new());
    }
    with_db(|conn| messages_search_on(conn, q, limit))
}

fn messages_search_on(conn: &Connection, q: &str, limit: i64) -> Result<Vec<MessageHit>, StorageError> {
    const COLS: &str = "SELECT m.id, m.chat_id, c.display_name, m.ts_unix, m.body, m.wire_id \
                        FROM messages m JOIN chats c ON c.id = m.chat_id";
    let map = |r: &rusqlite::Row<'_>| {
        Ok(MessageHit {
            message_id: r.get(0)?,
            chat_id: r.get(1)?,
            chat_name: r.get(2)?,
            ts_unix: r.get(3)?,
            body: r.get(4)?,
            wire_id: r.get(5)?,
        })
    };
    let hits = if q.chars().count() >= FTS_MIN_CHARS {
        // One FTS5 string token: inner quotes doubled, nothing else is syntax.
        let phrase = format!("\"{}\"", q.replace('"', "\"\""));
        let mut stmt = conn.prepare(&format!(
            "{COLS} JOIN messages_fts f ON f.rowid = m.rowid \
             WHERE messages_fts MATCH ?1 AND m.deleted = 0 \
             ORDER BY m.ts_unix DESC, m.id DESC LIMIT ?2"
        ))?;
        let rows = stmt.query_map(params![phrase, limit], map)?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    } else {
        // 1–2 characters: SQLite's LIKE folds only ASCII, so «да» would miss
        // «Да». Scan newest first and fold case in Rust (Unicode).
        let needle = q.to_lowercase();
        let mut stmt = conn.prepare(&format!(
            "{COLS} WHERE m.deleted = 0 AND m.body <> '' ORDER BY m.ts_unix DESC, m.id DESC"
        ))?;
        let mut out = Vec::new();
        for hit in stmt.query_map([], map)? {
            let hit = hit?;
            if hit.body.to_lowercase().contains(&needle) {
                out.push(hit);
                if out.len() as i64 >= limit {
                    break;
                }
            }
        }
        out
    };
    Ok(hits)
}

pub fn chats_wipe_all() -> Result<(), StorageError> {
    let shas = with_db(|conn| {
        let shas = blobs::shas_of(conn, "SELECT media_json FROM messages", [])?;
        conn.execute("DELETE FROM chats", [])?;
        Ok(shas)
    })?;
    blobs::drop_unreferenced(shas);
    Ok(())
}

// ─────────────────────────────────────────────────────────────────────
// Messages
// ─────────────────────────────────────────────────────────────────────

/// Append a new message AND update the parent chat's denormalized
/// last-message columns in a single transaction. Returns Err if the
/// parent chat doesn't exist (foreign-key violation).
pub fn message_append(
    id: &str,
    chat_id: &str,
    ts_unix: i64,
    body: &str,
    kind: &str,
    is_mine: bool,
    sender_label: Option<&str>,
) -> Result<(), StorageError> {
    message_append_with_media(id, chat_id, ts_unix, body, kind, is_mine, sender_label, None)
}

/// [`message_append`] plus the media envelope JSON for photo / voice /
/// document messages. `body` is the caption (may be empty).
#[allow(clippy::too_many_arguments)]
pub fn message_append_with_media(
    id: &str,
    chat_id: &str,
    ts_unix: i64,
    body: &str,
    kind: &str,
    is_mine: bool,
    sender_label: Option<&str>,
    media_json: Option<&str>,
) -> Result<(), StorageError> {
    message_insert(&NewMessage { id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, ..Default::default() })
}

/// Store a new message (any kind) and update the chat's last-message
/// columns in one transaction. Own messages start as "sending" — except
/// mine that came through the server from another of my devices
/// (`remote-…`): they were sent already (owner, 2026-11-03: a photo sent
/// to Saved from the iPad showed the clock on the iPhone for good).
pub fn message_insert(m: &NewMessage<'_>) -> Result<(), StorageError> {
    let NewMessage { id, chat_id, ts_unix, body, kind, is_mine, sender_label, .. } = *m;
    let status: i64 = if is_mine && id.starts_with(REMOTE_ID_PREFIX) { 1 } else { 0 };
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        tx.execute(
            "INSERT INTO messages \
             (id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
              wire_id, reply_json, sender_id, expire_at, entities_json, status) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                id,
                chat_id,
                ts_unix,
                body,
                kind,
                is_mine as i64,
                sender_label,
                m.media_json,
                m.wire_id,
                m.reply_json,
                m.sender_id,
                m.expire_at,
                m.entities_json,
                status
            ],
        )?;
        // Incoming messages count as unread; sending clears the draft.
        // Tech-debt 2.21: a new incoming message brings an archived chat
        // back to the list unless it's muted (muted ones stay archived —
        // the Telegram / Signal rule).
        // System lines are stored as "mine" but are not my writing: a
        // peer's timer change or screenshot notice must not accept a message
        // request, wipe my draft or show as my last message (review fix).
        let wrote = is_mine && kind != "system";
        tx.execute(
            "UPDATE chats SET \
                last_msg_preview = ?, \
                last_msg_ts_unix = ?, \
                last_msg_kind = ?, \
                last_msg_sender_label = ?, \
                last_msg_mine = ?, \
                unread_count = unread_count + ?, \
                archived = CASE WHEN ? AND muted = 0 THEN 0 ELSE archived END, \
                draft = CASE WHEN ? THEN NULL ELSE draft END, \
                request = CASE WHEN ? THEN 0 ELSE request END \
             WHERE id = ?",
            params![
                body,
                ts_unix,
                kind,
                sender_label,
                wrote as i64,
                (!is_mine) as i64,
                (!is_mine) as i64,
                wrote as i64,
                wrote as i64, // writing in a chat (from any of my devices) accepts it
                chat_id
            ],
        )?;
        tx.commit()?;
        Ok(())
    })
}

/// Columns read by [`message_from_row`], in order.
const MESSAGE_COLS: &str = "id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
     wire_id, status, reply_json, edited_ts, deleted, reactions_json, sender_id, expire_at, entities_json";

fn message_from_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredMessage> {
    Ok(StoredMessage {
        id: row.get(0)?,
        chat_id: row.get(1)?,
        ts_unix: row.get(2)?,
        body: row.get(3)?,
        kind: row.get(4)?,
        is_mine: row.get::<_, i64>(5)? != 0,
        sender_label: row.get(6)?,
        media_json: row.get(7)?,
        wire_id: row.get(8)?,
        status: row.get(9)?,
        reply_json: row.get(10)?,
        edited_ts: row.get(11)?,
        deleted: row.get::<_, i64>(12)? != 0,
        reactions_json: row.get(13)?,
        sender_id: row.get(14)?,
        expire_at: row.get(15)?,
        entities_json: row.get(16)?,
    })
}

// ── Message actions (ADR-019) ────────────────────────────────────

/// A message of this chat by its wire id.
pub fn message_by_wire(chat_id: &str, wire_id: &str) -> Result<Option<StoredMessage>, StorageError> {
    with_db(|conn| {
        let mut stmt =
            conn.prepare(&format!("SELECT {MESSAGE_COLS} FROM messages WHERE chat_id = ? AND wire_id = ?"))?;
        let mut rows = stmt.query(params![chat_id, wire_id])?;
        Ok(match rows.next()? {
            Some(r) => Some(message_from_row(r)?),
            None => None,
        })
    })
}

/// Raise the delivery status of my messages (never lowers: a late
/// "delivered" can't undo "read"). `-1` (failed) is set only from 0.
/// Returns how many rows changed.
pub fn messages_raise_status(wire_ids: &[String], status: i64) -> Result<usize, StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut n = 0;
        for w in wire_ids {
            n += if status < 0 {
                tx.execute(
                    "UPDATE messages SET status = ? WHERE wire_id = ? AND is_mine = 1 AND status = 0",
                    params![status, w],
                )?
            } else {
                tx.execute(
                    "UPDATE messages SET status = ? WHERE wire_id = ? AND is_mine = 1 AND status < ?",
                    params![status, w, status],
                )?
            };
        }
        tx.commit()?;
        Ok(n)
    })
}

/// Receipts from a peer: only for MY messages in THIS chat (a peer
/// can't touch other chats' rows).
pub fn messages_raise_status_in_chat(chat_id: &str, wire_ids: &[String], status: i64) -> Result<usize, StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut n = 0;
        for w in wire_ids {
            n += tx.execute(
                "UPDATE messages SET status = ? \
                 WHERE chat_id = ? AND wire_id = ? AND is_mine = 1 AND status >= 0 AND status < ?",
                params![status, chat_id, w, status],
            )?;
        }
        tx.commit()?;
        Ok(n)
    })
}

/// SQL predicate: the row was written by `author` (`?` = sender hex).
fn author_clause(author: Author<'_>) -> (&'static str, Option<String>) {
    match author {
        Author::Me => ("is_mine = 1", None),
        Author::Peer(id) => ("is_mine = 0 AND sender_id = ?", Some(id.to_string())),
    }
}

/// Recompute a chat's last-message columns from its newest row (after
/// a delete or an edit of the last message).
fn refresh_chat_preview(conn: &Connection, chat_id: &str) -> Result<(), StorageError> {
    let last = conn
        .prepare(
            "SELECT body, ts_unix, kind, sender_label, is_mine, deleted FROM messages \
             WHERE chat_id = ? ORDER BY ts_unix DESC, id DESC LIMIT 1",
        )?
        .query_row(params![chat_id], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, i64>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, i64>(5)? != 0,
            ))
        });
    match last {
        Ok((body, ts, kind, label, mine, deleted)) => {
            let kind = if deleted { "deleted".to_string() } else { kind };
            conn.execute(
                "UPDATE chats SET last_msg_preview = ?, last_msg_ts_unix = ?, last_msg_kind = ?, \
                 last_msg_sender_label = ?, last_msg_mine = ? WHERE id = ?",
                params![body, ts, kind, label, mine, chat_id],
            )?;
        }
        Err(rusqlite::Error::QueryReturnedNoRows) => {
            conn.execute(
                "UPDATE chats SET last_msg_preview = NULL, last_msg_kind = 'text', last_msg_mine = 0 WHERE id = ?",
                params![chat_id],
            )?;
        }
        Err(e) => return Err(e.into()),
    }
    Ok(())
}

/// Tech-debt 2.22 — a message can be edited or deleted for everyone for
/// this long after it was sent (as in Signal).
pub const EDIT_WINDOW_SECS: i64 = 24 * 3600;

/// Extra time an incoming edit / delete may take to arrive (the author's
/// action waited in a queue while one side was offline). Without a bound
/// a modified client could rewrite months-old history on everyone's
/// screen.
pub const LATE_ACTION_GRACE_SECS: i64 = 24 * 3600;

/// Oldest `ts_unix` an edit / delete-for-everyone made at [now] may touch.
fn action_cutoff(author: &Author<'_>, now: i64) -> i64 {
    match author {
        Author::Me => now - EDIT_WINDOW_SECS,
        Author::Peer(_) => now - EDIT_WINDOW_SECS - LATE_ACTION_GRACE_SECS,
    }
}

/// Edit the text of a text message — only by its author, never after
/// it was deleted, only within [`EDIT_WINDOW_SECS`] of sending
/// (`edited_ts` is "now"). Returns false (no change) otherwise.
///
/// ADR-070 — `entities_json` replaces the formatting too (None: an older
/// app's edit, plain text that may carry markers).
pub fn message_apply_edit(
    chat_id: &str,
    wire_id: &str,
    author: Author<'_>,
    text: &str,
    entities_json: Option<&str>,
    edited_ts: i64,
) -> Result<bool, StorageError> {
    let cutoff = action_cutoff(&author, edited_ts);
    let (who, peer) = author_clause(author);
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let sql = format!(
            "UPDATE messages SET body = ?, entities_json = ?, edited_ts = ? \
             WHERE chat_id = ? AND wire_id = ? AND kind = 'text' AND deleted = 0 AND ts_unix >= ? AND {who}"
        );
        let n = match &peer {
            None => tx.execute(&sql, params![text, entities_json, edited_ts, chat_id, wire_id, cutoff])?,
            Some(p) => tx.execute(&sql, params![text, entities_json, edited_ts, chat_id, wire_id, cutoff, p])?,
        };
        if n > 0 {
            refresh_chat_preview(&tx, chat_id)?;
        }
        tx.commit()?;
        Ok(n > 0)
    })
}

/// Delete for everyone: the row becomes a tombstone (content, media
/// keys, quote and reactions wiped). Only by its author, only within
/// [`EDIT_WINDOW_SECS`] of sending (+ grace for incoming).
pub fn message_apply_delete(
    chat_id: &str,
    wire_id: &str,
    author: Author<'_>,
    now_unix: i64,
) -> Result<bool, StorageError> {
    let cutoff = action_cutoff(&author, now_unix);
    let (who, peer) = author_clause(author);
    let (deleted, shas) = with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let shas = blobs::shas_of(
            &tx,
            "SELECT media_json FROM messages WHERE chat_id = ? AND wire_id = ? AND deleted = 0",
            params![chat_id, wire_id],
        )?;
        let sql = format!(
            "UPDATE messages SET deleted = 1, body = '', media_json = NULL, reply_json = NULL, \
             reactions_json = NULL, edited_ts = NULL, entities_json = NULL \
             WHERE chat_id = ? AND wire_id = ? AND deleted = 0 AND ts_unix >= ? AND {who}"
        );
        let n = match &peer {
            None => tx.execute(&sql, params![chat_id, wire_id, cutoff])?,
            Some(p) => tx.execute(&sql, params![chat_id, wire_id, cutoff, p])?,
        };
        if n > 0 {
            // Replies that quote it keep the pointer, not the deleted text.
            tx.execute(
                "UPDATE messages SET reply_json = json_set(reply_json, '$.snippet', '') WHERE chat_id = ?1 \
                 AND CASE WHEN json_valid(reply_json) THEN json_extract(reply_json, '$.id') END = ?2",
                params![chat_id, wire_id],
            )?;
            tx.execute(
                "UPDATE chats SET pinned_msg = NULL WHERE id = ? AND pinned_msg = ?",
                params![chat_id, wire_id],
            )?;
            refresh_chat_preview(&tx, chat_id)?;
        }
        tx.commit()?;
        Ok((n > 0, if n > 0 { shas } else { Vec::new() }))
    })?;
    blobs::drop_unreferenced(shas);
    Ok(deleted)
}

/// Delete for me: remove rows from this device only.
pub fn messages_delete_local(chat_id: &str, ids: &[String]) -> Result<(), StorageError> {
    let shas = with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let mut shas = Vec::new();
        for id in ids {
            shas.extend(blobs::shas_of(
                &tx,
                "SELECT media_json FROM messages WHERE chat_id = ? AND id = ?",
                params![chat_id, id],
            )?);
            tx.execute("DELETE FROM messages WHERE chat_id = ? AND id = ?", params![chat_id, id])?;
        }
        refresh_chat_preview(&tx, chat_id)?;
        tx.commit()?;
        Ok(shas)
    })?;
    blobs::drop_unreferenced(shas);
    Ok(())
}

/// Set `reactor`'s reaction on a message (one per reactor; `None` or
/// an empty emoji removes it). Not on deleted messages.
pub fn message_set_reaction(
    chat_id: &str,
    wire_id: &str,
    reactor: &str,
    emoji: Option<&str>,
) -> Result<bool, StorageError> {
    use std::collections::BTreeMap;
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let current: Option<Option<String>> = match tx.query_row(
            "SELECT reactions_json FROM messages WHERE chat_id = ? AND wire_id = ? AND deleted = 0",
            params![chat_id, wire_id],
            |r| r.get(0),
        ) {
            Ok(v) => Some(v),
            Err(rusqlite::Error::QueryReturnedNoRows) => None,
            Err(e) => return Err(e.into()),
        };
        let Some(current) = current else { return Ok(false) };
        let mut map: BTreeMap<String, Vec<String>> =
            current.and_then(|j| serde_json::from_str(&j).ok()).unwrap_or_default();
        for who in map.values_mut() {
            who.retain(|r| r != reactor);
        }
        if let Some(e) = emoji.filter(|e| !e.is_empty()) {
            map.entry(e.to_string()).or_default().push(reactor.to_string());
        }
        map.retain(|_, who| !who.is_empty());
        let json = if map.is_empty() { None } else { Some(serde_json::to_string(&map).expect("map serializes")) };
        tx.execute(
            "UPDATE messages SET reactions_json = ? WHERE chat_id = ? AND wire_id = ?",
            params![json, chat_id, wire_id],
        )?;
        tx.commit()?;
        Ok(true)
    })
}

/// Status 213 — [peer] got (and, with [read], read) these messages of mine
/// at [ts]: the first time of each is kept. Only my messages in [chat_id].
pub fn receipts_record(chat_id: &str, wire_ids: &[String], peer: &str, read: bool, ts: i64) -> Result<(), StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        for w in wire_ids {
            tx.execute(
                "INSERT INTO message_receipts (wire_id, peer, delivered_at, read_at) \
                 SELECT wire_id, ?1, ?2, CASE WHEN ?3 THEN ?2 END FROM messages \
                 WHERE chat_id = ?4 AND wire_id = ?5 AND is_mine = 1 \
                 ON CONFLICT (wire_id, peer) DO UPDATE SET \
                   delivered_at = COALESCE(delivered_at, excluded.delivered_at), \
                   read_at = COALESCE(read_at, excluded.read_at)",
                params![peer, ts, read, chat_id, w],
            )?;
        }
        tx.commit()?;
        Ok(())
    })
}

/// One person's receipt for a message of mine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReceiptRow {
    pub peer: String,
    pub delivered_at: Option<i64>,
    pub read_at: Option<i64>,
}

/// Who got / read [wire_id], by peer.
pub fn receipts_for(wire_id: &str) -> Result<Vec<ReceiptRow>, StorageError> {
    with_db(|conn| {
        let mut stmt =
            conn.prepare("SELECT peer, delivered_at, read_at FROM message_receipts WHERE wire_id = ? ORDER BY peer")?;
        let rows = stmt.query_map(params![wire_id], |r| {
            Ok(ReceiptRow { peer: r.get(0)?, delivered_at: r.get(1)?, read_at: r.get(2)? })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

/// Incoming messages of a chat whose receipt status is below `below`
/// (1 = no delivery receipt sent yet, 2 = no read receipt) — wire ids,
/// oldest first.
pub fn messages_pending_receipts(chat_id: &str, below: i64, limit: i64) -> Result<Vec<String>, StorageError> {
    with_db(|conn| {
        let mut stmt = conn.prepare(
            "SELECT wire_id FROM messages \
             WHERE chat_id = ? AND is_mine = 0 AND deleted = 0 AND wire_id IS NOT NULL AND status < ? \
             ORDER BY ts_unix ASC, id ASC LIMIT ?",
        )?;
        let rows = stmt.query_map(params![chat_id, below, limit], |r| r.get::<_, String>(0))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    })
}

/// Record that receipts up to `status` were sent for these incoming
/// messages.
pub fn messages_mark_receipted(chat_id: &str, wire_ids: &[String], status: i64) -> Result<(), StorageError> {
    with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        for w in wire_ids {
            tx.execute(
                "UPDATE messages SET status = ? WHERE chat_id = ? AND wire_id = ? AND is_mine = 0 AND status < ?",
                params![status, chat_id, w, status],
            )?;
        }
        tx.commit()?;
        Ok(())
    })
}

/// ADR-025 — name a chat that arrived on this device through device sync
/// (its row was created with a placeholder name). Only while it has no
/// messages here — never renames a chat the user already uses.
pub fn chat_name_if_new(chat_id: &str, display_name: &str, is_group: bool) -> Result<bool, StorageError> {
    with_db(|conn| {
        let n = conn.execute(
            "UPDATE chats SET display_name = ?, is_group = ? WHERE id = ? \
             AND NOT EXISTS (SELECT 1 FROM messages WHERE chat_id = ? AND kind <> 'system')",
            params![display_name, is_group, chat_id, chat_id],
        )?;
        Ok(n > 0)
    })
}

// ── v9: people (tech-debt 2.22 / 2.27) ─────────────────────────────────

/// Remember `peer_id`'s self-chosen display name. Returns whether it
/// changed. Names are already cleaned by the envelope decoder.
pub fn peer_name_set(peer_id: &str, name: &str, ts: i64) -> Result<bool, StorageError> {
    with_db(|conn| {
        let n = conn.execute(
            "INSERT INTO peer_names (peer_id, name, updated_ts) VALUES (?1, ?2, ?3) \
             ON CONFLICT(peer_id) DO UPDATE SET name = excluded.name, updated_ts = excluded.updated_ts \
             WHERE peer_names.name <> excluded.name",
            params![peer_id, name, ts],
        )?;
        Ok(n > 0)
    })
}

/// Every known (peer id, display name).
pub fn peer_names() -> Result<Vec<(String, String)>, StorageError> {
    with_db(|conn| {
        let rows = conn
            .prepare("SELECT peer_id, name FROM peer_names ORDER BY name")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    })
}

/// Store (or with an empty [jpeg], forget) someone's photo. Returns
/// whether anything changed. The caller re-encodes the image first.
pub fn peer_avatar_set(peer_id: &str, jpeg: &[u8], ts: i64) -> Result<bool, StorageError> {
    with_db(|conn| {
        let n = if jpeg.is_empty() {
            conn.execute("DELETE FROM peer_avatars WHERE peer_id = ?", params![peer_id])?
        } else {
            conn.execute(
                "INSERT INTO peer_avatars (peer_id, jpeg, updated_ts) VALUES (?, ?, ?) \
                 ON CONFLICT(peer_id) DO UPDATE SET jpeg = excluded.jpeg, updated_ts = excluded.updated_ts \
                 WHERE peer_avatars.jpeg <> excluded.jpeg",
                params![peer_id, jpeg, ts],
            )?
        };
        Ok(n > 0)
    })
}

pub fn peer_avatars() -> Result<Vec<(String, Vec<u8>)>, StorageError> {
    with_db(|conn| {
        let rows = conn
            .prepare("SELECT peer_id, jpeg FROM peer_avatars")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    })
}

/// Someone's bio from their `profile` (already cleaned); empty forgets it.
/// Returns whether anything changed.
pub fn peer_bio_set(peer_id: &str, bio: &str, ts: i64) -> Result<bool, StorageError> {
    with_db(|conn| {
        let n = if bio.is_empty() {
            conn.execute("DELETE FROM peer_bios WHERE peer_id = ?", params![peer_id])?
        } else {
            conn.execute(
                "INSERT INTO peer_bios (peer_id, bio, updated_ts) VALUES (?1, ?2, ?3) \
                 ON CONFLICT(peer_id) DO UPDATE SET bio = excluded.bio, updated_ts = excluded.updated_ts \
                 WHERE peer_bios.bio <> excluded.bio",
                params![peer_id, bio, ts],
            )?
        };
        Ok(n > 0)
    })
}

/// Every known (peer id, bio).
pub fn peer_bios() -> Result<Vec<(String, String)>, StorageError> {
    with_db(|conn| {
        let rows = conn
            .prepare("SELECT peer_id, bio FROM peer_bios")?
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    })
}

// ── v15: contacts (ADR-052) ─────────────────────────────────────────────

/// One person in my contacts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Contact {
    /// Identity key, lower-case hex.
    pub peer_id: String,
    /// The name I first knew them by ('' = none); their own name wins.
    pub name: String,
    pub favourite: bool,
    pub added_ts: i64,
}

/// Add [peer_id] to my contacts. Returns whether they were new; an
/// existing contact keeps its star and date, and only gets [name] if it
/// had none.
pub fn contact_add(peer_id: &str, name: &str, ts: i64) -> Result<bool, StorageError> {
    let key = peer_id.to_lowercase();
    with_db(|conn| {
        let n = conn.execute(
            "INSERT INTO contacts (peer_id, name, added_ts) VALUES (?1, ?2, ?3) ON CONFLICT(peer_id) DO NOTHING",
            params![key, name, ts],
        )?;
        let renamed = n == 0
            && !name.is_empty()
            && conn.execute("UPDATE contacts SET name = ?2 WHERE peer_id = ?1 AND name = ''", params![key, name])? > 0;
        if n > 0 || renamed {
            devsync::stamp(conn, &devsync::contact_item(&key), false)?;
        }
        Ok(n > 0)
    })
}

/// Remove [peer_id] from my contacts (chats with them stay). Returns
/// whether they were a contact.
pub fn contact_remove(peer_id: &str) -> Result<bool, StorageError> {
    with_db(|conn| {
        let gone = conn.execute("DELETE FROM contacts WHERE peer_id = ?", params![peer_id.to_lowercase()])? > 0;
        if gone {
            devsync::stamp(conn, &devsync::contact_item(peer_id), true)?;
        }
        Ok(gone)
    })
}

/// Star / unstar a contact. Returns whether they are a contact.
pub fn contact_set_favourite(peer_id: &str, favourite: bool) -> Result<bool, StorageError> {
    with_db(|conn| {
        let n = conn.execute(
            "UPDATE contacts SET favourite = ? WHERE peer_id = ? AND favourite <> ?",
            params![favourite, peer_id.to_lowercase(), favourite],
        )?;
        if n > 0 {
            devsync::stamp(conn, &devsync::contact_item(peer_id), false)?;
        }
        Ok(n > 0 || conn.prepare("SELECT 1 FROM contacts WHERE peer_id = ?")?.exists(params![peer_id.to_lowercase()])?)
    })
}

/// Every contact, oldest first (the UI sorts by name).
pub fn contacts_list() -> Result<Vec<Contact>, StorageError> {
    with_db(|conn| {
        let rows = conn
            .prepare("SELECT peer_id, name, favourite, added_ts FROM contacts ORDER BY added_ts, peer_id")?
            .query_map([], |r| {
                Ok(Contact { peer_id: r.get(0)?, name: r.get(1)?, favourite: r.get(2)?, added_ts: r.get(3)? })
            })?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    })
}

/// A personal chat's other person (set when their `profile` arrives there).
pub fn chat_set_peer(chat_id: &str, peer_id: &str) -> Result<(), StorageError> {
    exec("UPDATE chats SET peer_id = ? WHERE id = ? AND is_group = 0", params![peer_id, chat_id])
}

/// The display name we last announced in this chat (None = never).
pub fn chat_profile_sent(chat_id: &str) -> Result<Option<String>, StorageError> {
    with_db(|conn| {
        Ok(conn
            .query_row("SELECT profile_sent FROM chats WHERE id = ?", params![chat_id], |r| r.get(0))
            .optional()?
            .flatten())
    })
}

pub fn chat_set_profile_sent(chat_id: &str, name: &str) -> Result<(), StorageError> {
    exec("UPDATE chats SET profile_sent = ? WHERE id = ?", params![name, chat_id])
}

/// Block / unblock a person on this device: their messages and calls
/// are dropped before they reach the UI (tech-debt 2.27).
pub fn peer_set_blocked(peer_id: &str, blocked: bool, ts: i64) -> Result<(), StorageError> {
    with_db(|conn| {
        let n = if blocked {
            conn.execute(
                "INSERT INTO blocked_peers (peer_id, blocked_ts) VALUES (?, ?) ON CONFLICT(peer_id) DO NOTHING",
                params![peer_id, ts],
            )?
        } else {
            conn.execute("DELETE FROM blocked_peers WHERE peer_id = ?", params![peer_id])?
        };
        // ADR-064 — my other devices block / unblock too.
        if n > 0 {
            devsync::stamp(conn, &devsync::blocked_item(peer_id), !blocked)?;
        }
        Ok(())
    })
}

pub fn peers_blocked() -> Result<Vec<String>, StorageError> {
    with_db(|conn| {
        let rows = conn
            .prepare("SELECT peer_id FROM blocked_peers ORDER BY blocked_ts")?
            .query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        Ok(rows)
    })
}

/// ADR-071 — every block / unblock this device knows of, as
/// `(peer, blocked, at_ms)`: the time is the ADR-064 sync clock of the
/// `blocked:<peer>` item when there is one (so my devices agree on which
/// decision is later), else the block's own time. The server keeps the
/// later decision per key.
pub fn access_block_decisions() -> Result<Vec<(String, bool, i64)>, StorageError> {
    with_db(|conn| {
        let mut out: Vec<(String, bool, i64)> = conn
            .prepare(
                "SELECT b.peer_id, COALESCE(c.ts, b.blocked_ts * 1000) FROM blocked_peers b \
                 LEFT JOIN sync_clock c ON c.item = 'blocked:' || b.peer_id AND c.deleted = 0",
            )?
            .query_map([], |r| Ok((r.get::<_, String>(0)?, true, r.get::<_, i64>(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let unblocked: Vec<(String, bool, i64)> = conn
            .prepare(
                "SELECT substr(item, 9), ts FROM sync_clock WHERE item LIKE 'blocked:%' AND deleted = 1 \
                 AND substr(item, 9) NOT IN (SELECT peer_id FROM blocked_peers)",
            )?
            .query_map([], |r| Ok((r.get::<_, String>(0)?, false, r.get::<_, i64>(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        out.extend(unblocked);
        Ok(out)
    })
}

pub fn peer_is_blocked(peer_id: &str) -> Result<bool, StorageError> {
    with_db(|conn| {
        Ok(conn
            .prepare("SELECT 1 FROM blocked_peers WHERE peer_id = ?")?
            .exists(params![peer_id])?)
    })
}

/// Set a chat's disappearing-message timer (0 = off).
pub fn chat_set_disappear(chat_id: &str, secs: i64) -> Result<(), StorageError> {
    exec("UPDATE chats SET disappear_secs = ? WHERE id = ?", params![secs.max(0), chat_id])
}

/// Delete every message whose time is up (content, media keys, quote —
/// the whole row). Returns the chats that changed.
pub fn messages_expire(now: i64) -> Result<Vec<String>, StorageError> {
    let (chats, shas) = with_db(|conn| {
        let tx = conn.unchecked_transaction()?;
        let chats: Vec<String> = tx
            .prepare("SELECT DISTINCT chat_id FROM messages WHERE expire_at IS NOT NULL AND expire_at <= ?")?
            .query_map(params![now], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?;
        let mut shas = Vec::new();
        if !chats.is_empty() {
            shas = blobs::shas_of(
                &tx,
                "SELECT media_json FROM messages WHERE expire_at IS NOT NULL AND expire_at <= ?",
                params![now],
            )?;
            tx.execute("DELETE FROM messages WHERE expire_at IS NOT NULL AND expire_at <= ?", params![now])?;
            for c in &chats {
                refresh_chat_preview(&tx, c)?;
            }
        }
        tx.commit()?;
        Ok((chats, shas))
    })?;
    blobs::drop_unreferenced(shas);
    Ok(chats)
}

/// Pin one message in a chat (local only), or unpin with None.
pub fn chat_set_pinned_message(chat_id: &str, wire_id: Option<&str>) -> Result<(), StorageError> {
    exec("UPDATE chats SET pinned_msg = ? WHERE id = ?", params![wire_id, chat_id])
}

/// Rename a chat only while it still has the name [from] (a placeholder):
/// a personal chat someone started takes their name once they share it,
/// and never overrides a name the user set. Returns whether it changed.
pub fn chat_rename_if(chat_id: &str, from: &str, to: &str) -> Result<bool, StorageError> {
    with_db(|conn| {
        Ok(conn.execute(
            "UPDATE chats SET display_name = ? WHERE id = ? AND display_name = ? AND is_group = 0",
            params![to, chat_id, from],
        )? > 0)
    })
}

/// ADR-034 — a group's name from a member: applies to a group chat, or to a
/// chat that still has one of the [placeholders] (just joined — a group of
/// two looks personal until its name arrives); it becomes a group. A
/// personal chat that already has a name keeps it. Returns whether it changed.
pub fn chat_set_group_name(chat_id: &str, name: &str, placeholders: &[String]) -> Result<bool, StorageError> {
    with_db(|conn| {
        let mut n = conn.execute(
            "UPDATE chats SET display_name = ?1 WHERE id = ?2 AND is_group = 1 AND display_name <> ?1",
            params![name, chat_id],
        )?;
        for p in placeholders {
            n += conn.execute(
                "UPDATE chats SET display_name = ?1, is_group = 1 WHERE id = ?2 AND is_group = 0 AND display_name = ?3",
                params![name, chat_id, p],
            )?;
        }
        Ok(n > 0)
    })
}

/// Unpin only if [wire_id] is the pinned message — compare-and-clear in
/// one statement, so a stale in-memory chat list can't drop an unpin.
/// Returns whether it was pinned.
pub fn chat_unpin_if(chat_id: &str, wire_id: &str) -> Result<bool, StorageError> {
    with_db(|conn| {
        Ok(conn.execute(
            "UPDATE chats SET pinned_msg = NULL WHERE id = ? AND pinned_msg = ?",
            params![chat_id, wire_id],
        )? > 0)
    })
}

/// Return all messages for [chat_id], oldest first (display order in
/// ChatView). Limited to [limit] most-recent if Some — full history if
/// None.
/// Attach (or replace) the media/link JSON of an existing message — used
/// when a link preview is ready after the text row was stored.
pub fn message_set_media_json(id: &str, media_json: &str) -> Result<(), StorageError> {
    let old = with_db(|conn| {
        let old = blobs::shas_of(conn, "SELECT media_json FROM messages WHERE id = ?", params![id])?;
        conn.execute(
            "UPDATE messages SET media_json = ? WHERE id = ?",
            params![media_json, id],
        )?;
        Ok(old)
    })?;
    blobs::drop_unreferenced(old);
    Ok(())
}

/// Read a persisted setting.
pub fn setting_get(key: &str) -> Result<Option<String>, StorageError> {
    with_db(|conn| {
        let mut stmt = conn.prepare("SELECT value FROM settings WHERE key = ?")?;
        let mut rows = stmt.query(params![key])?;
        Ok(match rows.next()? {
            Some(r) => Some(r.get(0)?),
            None => None,
        })
    })
}

/// Persist a setting (insert or replace). A setting that follows me to my
/// other devices (and the sticker pack list) is stamped for them (ADR-064).
pub fn setting_set(key: &str, value: &str) -> Result<(), StorageError> {
    with_db(|conn| {
        if devsync::is_synced_setting(key) || key == stickers::INDEX_SETTING {
            let old: Option<String> =
                conn.query_row("SELECT value FROM settings WHERE key = ?", params![key], |r| r.get(0)).optional()?;
            devsync::on_setting_set(conn, key, old.as_deref(), value)?;
        }
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    })
}

/// One page of a chat's history for the lazy chat view: up to `limit`
/// messages strictly older than the cursor `(before_ts, before_id)`
/// (or the newest ones when the cursor is None), returned oldest-first.
/// Ordering is `(ts_unix, id)` so same-second messages page stably.
pub fn messages_page(
    chat_id: &str,
    before: Option<(i64, &str)>,
    limit: i64,
) -> Result<Vec<StoredMessage>, StorageError> {
    with_db(|conn| {
        let row_mapper = |row: &rusqlite::Row<'_>| -> rusqlite::Result<StoredMessage> {
            message_from_row(row)
        };
        let mut out = match before {
            None => {
                let mut stmt = conn.prepare(
                    "SELECT id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
                            wire_id, status, reply_json, edited_ts, deleted, reactions_json, sender_id, expire_at, \
                            entities_json \
                     FROM messages WHERE chat_id = ? \
                     ORDER BY ts_unix DESC, id DESC LIMIT ?",
                )?;
                let rows = stmt.query_map(params![chat_id, limit], row_mapper)?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            }
            Some((ts, id)) => {
                let mut stmt = conn.prepare(
                    "SELECT id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
                            wire_id, status, reply_json, edited_ts, deleted, reactions_json, sender_id, expire_at, \
                            entities_json \
                     FROM messages WHERE chat_id = ? \
                       AND (ts_unix < ? OR (ts_unix = ? AND id < ?)) \
                     ORDER BY ts_unix DESC, id DESC LIMIT ?",
                )?;
                let rows = stmt.query_map(params![chat_id, ts, ts, id, limit], row_mapper)?;
                rows.collect::<rusqlite::Result<Vec<_>>>()?
            }
        };
        out.reverse();
        Ok(out)
    })
}

pub fn messages_list_for_chat(
    chat_id: &str,
    limit: Option<i64>,
) -> Result<Vec<StoredMessage>, StorageError> {
    with_db(|conn| {
        let sql = match limit {
            Some(_) => {
                "SELECT id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
                            wire_id, status, reply_json, edited_ts, deleted, reactions_json, sender_id, expire_at, \
                            entities_json \
                 FROM messages WHERE chat_id = ? \
                 ORDER BY ts_unix DESC LIMIT ?"
            }
            None => {
                "SELECT id, chat_id, ts_unix, body, kind, is_mine, sender_label, media_json, \
                            wire_id, status, reply_json, edited_ts, deleted, reactions_json, sender_id, expire_at, \
                            entities_json \
                 FROM messages WHERE chat_id = ? \
                 ORDER BY ts_unix ASC"
            }
        };
        let mut stmt = conn.prepare(sql)?;
        let row_mapper = |row: &rusqlite::Row<'_>| -> rusqlite::Result<StoredMessage> {
            message_from_row(row)
        };
        let mut out = Vec::new();
        match limit {
            Some(n) => {
                let rows = stmt.query_map(params![chat_id, n], row_mapper)?;
                for r in rows {
                    out.push(r?);
                }
                // We queried DESC + LIMIT for "most recent N"; flip to ASC
                // so the caller sees oldest-first (chat display order).
                out.reverse();
            }
            None => {
                let rows = stmt.query_map(params![chat_id], row_mapper)?;
                for r in rows {
                    out.push(r?);
                }
            }
        }
        Ok(out)
    })
}

// ─────────────────────────────────────────────────────────────────────
// Call history (CD9 — Phase 3)
// ─────────────────────────────────────────────────────────────────────

/// Materialized row for the Calls tab. WU 57 / future read sites.
#[derive(Debug, Clone)]
pub struct StoredCall {
    pub id: String,
    pub peer_chat_id: String,
    pub kind: String,           // 'audio' | 'video'
    pub status: String,         // 'completed' | 'missed' | 'declined' | …
    pub is_outgoing: bool,
    pub started_at_unix: i64,
    pub ended_at_unix: Option<i64>,
    pub duration_secs: Option<i64>,
}

/// Insert OR replace a call history row. Called by activeCallProvider
/// on terminal phase transition (end / decline / timeout). PK on `id`
/// makes idempotent on retries.
#[allow(clippy::too_many_arguments)]
pub fn call_append(
    id: &str,
    peer_chat_id: &str,
    kind: &str,
    status: &str,
    is_outgoing: bool,
    started_at_unix: i64,
    ended_at_unix: Option<i64>,
    duration_secs: Option<i64>,
) -> Result<(), StorageError> {
    with_db(|conn| {
        conn.execute(
            "INSERT OR REPLACE INTO calls \
             (id, peer_chat_id, kind, status, is_outgoing, started_at_unix, \
              ended_at_unix, duration_secs) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            params![
                id,
                peer_chat_id,
                kind,
                status,
                is_outgoing as i64,
                started_at_unix,
                ended_at_unix,
                duration_secs,
            ],
        )?;
        Ok(())
    })
}

/// List call history, most-recent first. Returns the full history;
/// callers can paginate client-side if needed (typically <100 rows).
pub fn calls_list() -> Result<Vec<StoredCall>, StorageError> {
    with_db(|conn| {
        let mut stmt = conn.prepare(
            "SELECT id, peer_chat_id, kind, status, is_outgoing, \
                    started_at_unix, ended_at_unix, duration_secs \
             FROM calls ORDER BY started_at_unix DESC",
        )?;
        let rows = stmt.query_map([], |row| {
            Ok(StoredCall {
                id: row.get(0)?,
                peer_chat_id: row.get(1)?,
                kind: row.get(2)?,
                status: row.get(3)?,
                is_outgoing: row.get::<_, i64>(4)? != 0,
                started_at_unix: row.get(5)?,
                ended_at_unix: row.get(6)?,
                duration_secs: row.get(7)?,
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    })
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::sync::Mutex;

    static DB_TEST_LOCK: Mutex<()> = Mutex::new(());

    /// Every test that opens the process-wide DB takes this first.
    pub(crate) fn db_test_lock() -> std::sync::MutexGuard<'static, ()> {
        DB_TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// A fresh, empty DB at a temp path (closing whatever was open).
    pub(crate) fn fresh_db(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("sinhron_storage_test_{name}.db"));
        super::_force_close_for_tests();
        let _ = std::fs::remove_file(&p);
        super::open(&p, None).expect("open db");
        super::erase_and_reopen_plain(&p).expect("fresh db");
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests share the process-wide `DB` singleton (open / wipe / rekey
    /// / force-close), so running them in parallel made them trample
    /// each other (flaky failures like another test's fingerprint).
    /// Every test takes this lock first. Poison is ignored: one failed
    /// test must not cascade into the rest.
    use crate::test_support::db_test_lock;

    fn temp_db_path(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("sinhron_storage_test_{name}.db"));
        // Clean up any previous run
        let _ = std::fs::remove_file(&p);
        p
    }

    // NOTE: all tests share the global OnceLock<DB>. open() is no-op
    // after the first call; tests wipe state instead of expecting a
    // fresh handle.

    /// ADR-074 — restored Saved messages move into the new Saved chat.
    #[test]
    fn a_chat_merges_into_another_with_its_messages() {
        let _db = db_test_lock();
        crate::test_support::fresh_db("merge");
        chat_upsert("old", "Saved", false, false, false, 0, Some("old note"), 500, "text", None, true, 1).unwrap();
        chat_upsert("new", "Saved", false, false, false, 0, None, 0, "text", None, false, 2).unwrap();
        for (i, (chat, ts, body)) in [("old", 900, "first"), ("old", 901, "latest note"), ("new", 100, "older")].iter().enumerate() {
            let id = format!("m{i}");
            message_insert(&NewMessage { id: &id, chat_id: chat, ts_unix: *ts, body, kind: "text", is_mine: true, ..Default::default() }).unwrap();
        }
        assert_eq!(chat_merge_into("old", "new").unwrap(), 2);
        assert_eq!(messages_list_for_chat("new", None).unwrap().len(), 3);
        let chats = chats_list().unwrap();
        assert!(chats.iter().all(|c| c.id != "old"));
        let new = chats.iter().find(|c| c.id == "new").unwrap();
        assert_eq!((new.last_msg_preview.as_deref(), new.last_msg_ts_unix), (Some("latest note"), 901), "the newer preview wins");
        assert_eq!(chat_merge_into("old", "new").unwrap(), 0, "gone: nothing to do");
        assert_eq!(chat_merge_into("new", "new").unwrap(), 0);
    }

    /// Status 223 — mine from another device came through the server: sent,
    /// not "sending" (the clock stayed on a photo sent to Saved from the iPad).
    #[test]
    fn mine_from_another_device_is_sent_not_sending() {
        let _db = db_test_lock();
        crate::test_support::fresh_db("mine-remote");
        chat_upsert("s", "Saved", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        message_insert(&NewMessage { id: "remote-w1", chat_id: "s", ts_unix: 1, body: "", kind: "photo", is_mine: true, wire_id: Some("w1"), ..Default::default() }).unwrap();
        message_insert(&NewMessage { id: "msg-1", chat_id: "s", ts_unix: 2, body: "hi", kind: "text", is_mine: true, wire_id: Some("w2"), ..Default::default() }).unwrap();
        let rows = messages_list_for_chat("s", None).unwrap();
        let status = |id: &str| rows.iter().find(|r| r.id == id).unwrap().status;
        assert_eq!(status("remote-w1"), 1, "from my iPad: already sent");
        assert_eq!(status("msg-1"), 0, "written here: sending until the server's ack");
    }

    /// Status 213 — "Message info": per person, the first delivered / read
    /// time; only my messages; gone with the message.
    #[test]
    fn receipts_keep_the_first_times_per_person_and_go_with_the_message() {
        let _db = db_test_lock();
        crate::test_support::fresh_db("receipts");
        chat_upsert("g", "Family", true, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        message_insert(&NewMessage { id: "m1", chat_id: "g", ts_unix: 100, body: "hi", kind: "text", is_mine: true, wire_id: Some("w1"), ..Default::default() }).unwrap();
        message_insert(&NewMessage { id: "m2", chat_id: "g", ts_unix: 101, body: "theirs", kind: "text", is_mine: false, wire_id: Some("w2"), ..Default::default() }).unwrap();
        receipts_record("g", &["w1".into(), "w2".into()], "mama", false, 110).unwrap();
        receipts_record("g", &["w1".into()], "mama", true, 120).unwrap();
        receipts_record("g", &["w1".into()], "mama", true, 130).unwrap(); // a repeat
        receipts_record("g", &["w1".into()], "papa", true, 140).unwrap(); // read before "delivered" came
        receipts_record("other", &["w1".into()], "vera", false, 150).unwrap();
        assert_eq!(
            receipts_for("w1").unwrap(),
            vec![
                ReceiptRow { peer: "mama".into(), delivered_at: Some(110), read_at: Some(120) },
                ReceiptRow { peer: "papa".into(), delivered_at: Some(140), read_at: Some(140) },
            ]
        );
        assert!(receipts_for("w2").unwrap().is_empty(), "not mine");
        messages_delete_local("g", &["m1".into()]).unwrap();
        assert!(receipts_for("w1").unwrap().is_empty(), "gone with the message");
    }

    #[test]
    fn schema_creates_on_open() {
        let _db = db_test_lock();
        let path = temp_db_path("schema");
        open(&path, None).expect("open db");
        let _ = wipe_identities();
        assert!(load_latest_identity().unwrap().is_none());
    }

    #[test]
    fn save_and_load_round_trip() {
        let _db = db_test_lock();
        let path = temp_db_path("roundtrip");
        open(&path, None).expect("open db");
        let _ = wipe_identities();

        save_identity(
            "abandon abandon abandon abandon abandon abandon \
             abandon abandon abandon abandon abandon abandon \
             abandon abandon abandon abandon abandon abandon \
             abandon abandon abandon abandon abandon art",
            "9a3e 4d12 8b71",
            "ed25519_pub_hex_placeholder",
            "x25519_pub_hex_placeholder",
            1_700_000_000,
        )
        .unwrap();

        let loaded = load_latest_identity().unwrap().expect("row present");
        assert_eq!(loaded.fingerprint, "9a3e 4d12 8b71");
        assert_eq!(loaded.created_at_unix, 1_700_000_000);
        assert_eq!(loaded.phrase_hash.len(), 64);
    }

    #[test]
    fn phrase_hash_is_64_chars_hex() {
        let _db = db_test_lock();
        let h = phrase_hash_hex("hello");
        assert_eq!(h.len(), 64);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn chats_upsert_and_list() {
        let _db = db_test_lock();
        let path = temp_db_path("chats_basic");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();

        chat_upsert(
            "chat-1",
            "Maria Chen",
            false, /*is_group*/
            false, /*muted*/
            true,  /*pinned*/
            2,
            Some("Sounds great — see you at 9 ☕"),
            1_700_000_100,
            "text",
            None,
            false,
            1_699_000_000,
        )
        .unwrap();

        chat_upsert(
            "chat-2",
            "Engineering",
            true, /*is_group*/
            false, false, 7,
            Some("pushed the new SFrame implementation"),
            1_700_000_050,
            "text",
            Some("Alex"),
            false,
            1_699_000_010,
        )
        .unwrap();

        let list = chats_list().unwrap();
        assert_eq!(list.len(), 2);
        // pinned chat sorts first regardless of ts
        assert_eq!(list[0].id, "chat-1");
        assert!(list[0].pinned);
        assert!(list[1].is_group);
        assert_eq!(list[1].last_msg_sender_label.as_deref(), Some("Alex"));
    }

    #[test]
    fn message_append_updates_last_msg_columns() {
        let _db = db_test_lock();
        let path = temp_db_path("msg_denorm");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();

        chat_upsert(
            "c1", "Test", false, false, false, 0, None, 0, "text", None, false, 1_699_000_000,
        )
        .unwrap();

        message_append(
            "m1",
            "c1",
            1_700_000_500,
            "hello from test",
            "text",
            true,
            None,
        )
        .unwrap();

        let chats = chats_list().unwrap();
        assert_eq!(chats.len(), 1);
        let c = &chats[0];
        assert_eq!(c.last_msg_preview.as_deref(), Some("hello from test"));
        assert_eq!(c.last_msg_ts_unix, 1_700_000_500);
        assert!(c.last_msg_mine);

        let msgs = messages_list_for_chat("c1", None).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].body, "hello from test");
        assert!(msgs[0].is_mine);
    }

    /// ADR-070 — formatting is stored beside the clean text: edits replace
    /// it, delete-for-everyone wipes it, search and the preview see words.
    #[test]
    fn message_formatting_v17() {
        let _db = db_test_lock();
        let path = temp_db_path("formatting_v17");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        chat_upsert("g", "Group", true, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        let bold = r#"[{"t":"bold","o":0,"l":5}]"#;
        message_insert(&NewMessage {
            id: "m1",
            chat_id: "g",
            ts_unix: 10,
            body: "Hello world",
            kind: "text",
            is_mine: true,
            wire_id: Some("w1"),
            entities_json: Some(bold),
            ..Default::default()
        })
        .unwrap();
        message_insert(&NewMessage {
            id: "m2",
            chat_id: "g",
            ts_unix: 11,
            body: "*old*",
            kind: "text",
            wire_id: Some("w2"),
            sender_id: Some("alice"),
            ..Default::default()
        })
        .unwrap();
        let get = |w: &str| message_by_wire("g", w).unwrap().unwrap();
        assert_eq!(get("w1").entities_json.as_deref(), Some(bold));
        assert_eq!(get("w2").entities_json, None, "an older app's message");
        assert_eq!(messages_page("g", None, 10).unwrap()[0].entities_json.as_deref(), Some(bold));
        assert_eq!(messages_list_for_chat("g", None).unwrap()[0].entities_json.as_deref(), Some(bold));
        assert_eq!(messages_search("Hello world", 10).unwrap().len(), 1, "clean text is searchable");
        let italic = r#"[{"t":"italic","o":0,"l":3}]"#;
        assert!(message_apply_edit("g", "w1", Author::Me, "Bye world", Some(italic), 20).unwrap());
        assert_eq!(get("w1").entities_json.as_deref(), Some(italic));
        assert!(message_apply_edit("g", "w1", Author::Me, "plain now", None, 21).unwrap());
        assert_eq!(get("w1").entities_json, None, "an older app's edit");
        assert!(message_apply_edit("g", "w1", Author::Me, "again", Some(italic), 22).unwrap());
        assert!(message_apply_delete("g", "w1", Author::Me, 30).unwrap());
        assert_eq!(get("w1").entities_json, None, "tombstone keeps nothing");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn delete_for_everyone_wipes_quotes_b02() {
        let _db = db_test_lock();
        let path = temp_db_path("delete_quotes_b02");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        chat_upsert("g", "Group", true, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        let insert = |id: &str, wire: &str, body: &str, mine: bool, reply: Option<&str>| {
            message_insert(&NewMessage {
                id,
                chat_id: "g",
                ts_unix: 10,
                body,
                kind: "text",
                is_mine: mine,
                wire_id: Some(wire),
                reply_json: reply,
                sender_id: if mine { None } else { Some("bob") },
                ..Default::default()
            })
            .unwrap();
        };
        insert("m1", "w1", "my secret", true, None);
        insert("m2", "w2", "ok", false, Some(r#"{"id":"w1","snippet":"my secret","kind":"text"}"#));
        insert("m3", "w3", "other", false, Some(r#"{"id":"w2","snippet":"ok","kind":"text"}"#));
        insert("m4", "w4", "junk quote", false, Some("not json"));
        assert!(message_apply_delete("g", "w1", Author::Me, 20).unwrap());
        let reply = |w: &str| message_by_wire("g", w).unwrap().unwrap().reply_json.unwrap();
        assert!(!reply("w2").contains("my secret"), "deleted text survives in a quote: {}", reply("w2"));
        assert!(reply("w2").contains(r#""id":"w1""#), "the quote still points at the tombstone");
        assert!(reply("w3").contains(r#""snippet":"ok""#), "other quotes untouched");
        assert_eq!(reply("w4"), "not json");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn message_actions_v7() {
        let _db = db_test_lock();
        let path = temp_db_path("actions_v7");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        chat_upsert("g", "Group", true, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        chat_upsert("o", "Other", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        let insert = |id: &str, wire: &str, ts: i64, body: &str, mine: bool, sender: Option<&str>| {
            message_insert(&NewMessage {
                id,
                chat_id: "g",
                ts_unix: ts,
                body,
                kind: "text",
                is_mine: mine,
                wire_id: Some(wire),
                sender_id: sender,
                reply_json: if id == "m3" { Some(r#"{"id":"w1","snippet":"hello","kind":"text"}"#) } else { None },
                ..Default::default()
            })
            .unwrap()
        };
        insert("m1", "w1", 10, "hello", false, Some("alice"));
        insert("m2", "w2", 11, "mine", true, None);
        insert("m3", "w3", 12, "reply", false, Some("bob"));
        let get = |w: &str| message_by_wire("g", w).unwrap().unwrap();
        assert_eq!(get("w3").reply_json.as_deref(), Some(r#"{"id":"w1","snippet":"hello","kind":"text"}"#));
        assert_eq!(get("w2").status, 0, "own message starts as sending");
        assert!(message_by_wire("o", "w1").unwrap().is_none(), "wire ids are per chat");

        // Status only goes up; receipts only touch my messages in that chat.
        assert_eq!(messages_raise_status(&["w2".into()], 1).unwrap(), 1);
        assert_eq!(messages_raise_status_in_chat("g", &["w2".into(), "w1".into()], 3).unwrap(), 1);
        assert_eq!(messages_raise_status_in_chat("g", &["w2".into()], 2).unwrap(), 0, "no downgrade");
        assert_eq!(messages_raise_status_in_chat("o", &["w2".into()], 3).unwrap(), 0, "other chat");
        assert_eq!(get("w2").status, 3);
        assert_eq!(get("w1").status, 0, "incoming untouched by receipts");

        // Edits: only by the author.
        assert!(!message_apply_edit("g", "w1", Author::Peer("bob"), "hacked", None, 20).unwrap());
        assert!(!message_apply_edit("g", "w1", Author::Me, "hacked", None, 20).unwrap());
        assert!(!message_apply_edit("g", "w2", Author::Peer("alice"), "hacked", None, 20).unwrap());
        assert!(message_apply_edit("g", "w1", Author::Peer("alice"), "hello!", None, 20).unwrap());
        assert!(message_apply_edit("g", "w2", Author::Me, "mine, fixed", None, 21).unwrap());
        assert_eq!((get("w1").body.as_str(), get("w1").edited_ts), ("hello!", Some(20)));

        // Time limit: 24 h for my own actions; incoming ones get a day of
        // grace for delivery delays, never more.
        let ts1 = get("w1").ts_unix;
        let ts2 = get("w2").ts_unix;
        let day = EDIT_WINDOW_SECS;
        assert!(!message_apply_edit("g", "w2", Author::Me, "too late", None, ts2 + day + 1).unwrap());
        assert!(message_apply_edit("g", "w2", Author::Me, "just in time", None, ts2 + day).unwrap());
        assert!(message_apply_edit("g", "w1", Author::Peer("alice"), "late but queued", None, ts1 + day + 3600).unwrap());
        assert!(!message_apply_edit("g", "w1", Author::Peer("alice"), "rewrite history", None, ts1 + 2 * day + 1).unwrap());
        assert!(!message_apply_delete("g", "w1", Author::Peer("alice"), ts1 + 2 * day + 1).unwrap());
        assert!(!message_apply_delete("g", "w2", Author::Me, ts2 + day + 1).unwrap());
        assert_eq!(get("w1").body, "late but queued");
        message_apply_edit("g", "w1", Author::Peer("alice"), "hello!", None, 20).unwrap();
        message_apply_edit("g", "w2", Author::Me, "mine, fixed", None, 21).unwrap();

        // Reactions: one per reactor, switch, remove.
        assert!(message_set_reaction("g", "w1", "me", Some("❤️")).unwrap());
        assert!(message_set_reaction("g", "w1", "bob", Some("❤️")).unwrap());
        assert!(message_set_reaction("g", "w1", "me", Some("👍")).unwrap());
        assert_eq!(get("w1").reactions_json.as_deref(), Some(r#"{"❤️":["bob"],"👍":["me"]}"#));
        assert!(message_set_reaction("g", "w1", "me", None).unwrap());
        assert!(message_set_reaction("g", "w1", "bob", Some("")).unwrap());
        assert_eq!(get("w1").reactions_json, None);
        assert!(!message_set_reaction("g", "nope", "me", Some("👍")).unwrap());

        // Delete for everyone: author only; tombstone; preview + pin follow.
        chat_set_pinned_message("g", Some("w3")).unwrap();
        assert!(!message_apply_delete("g", "w3", Author::Peer("alice"), 30).unwrap());
        assert!(message_apply_delete("g", "w3", Author::Peer("bob"), 30).unwrap());
        let t = get("w3");
        assert!(t.deleted && t.body.is_empty() && t.reply_json.is_none());
        let chat = chats_list().unwrap().into_iter().find(|c| c.id == "g").unwrap();
        assert_eq!(chat.last_msg_kind, "deleted");
        assert_eq!(chat.pinned_msg, None, "deleted message unpinned");
        assert!(!message_apply_edit("g", "w3", Author::Peer("bob"), "back", None, 30).unwrap(), "no edit after delete");
        assert!(!message_set_reaction("g", "w3", "me", Some("👍")).unwrap());
        assert!(messages_search("reply", 10).unwrap().is_empty(), "deleted text not searchable");

        // Receipts bookkeeping for incoming.
        assert_eq!(messages_pending_receipts("g", 2, 50).unwrap(), vec!["w1".to_string()]);
        messages_mark_receipted("g", &["w1".into()], 2).unwrap();
        assert!(messages_pending_receipts("g", 2, 50).unwrap().is_empty());

        // Delete for me.
        messages_delete_local("g", &["m1".into(), "m3".into()]).unwrap();
        let chat = chats_list().unwrap().into_iter().find(|c| c.id == "g").unwrap();
        assert_eq!(chat.last_msg_preview.as_deref(), Some("mine, fixed"));
        assert!(message_by_wire("g", "w1").unwrap().is_none());
        let _ = std::fs::remove_file(&path);
    }

    /// ADR-025 — a chat that arrived by device sync gets its real name,
    /// but only while it has no messages here.
    #[test]
    fn chat_name_from_device_sync_only_while_empty() {
        let _db = db_test_lock();
        let path = temp_db_path("chat_name_sync");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        chat_upsert("s", "Group 1a2b", true, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        let chat = || chats_list().unwrap().into_iter().find(|c| c.id == "s").unwrap();
        assert!(chat_name_if_new("s", "Bob", false).unwrap());
        assert_eq!(chat().display_name, "Bob");
        assert!(!chat().is_group);
        message_insert(&NewMessage { id: "m1", chat_id: "s", ts_unix: 5, body: "hi", kind: "text", ..Default::default() }).unwrap();
        assert!(!chat_name_if_new("s", "Someone else", true).unwrap(), "a used chat keeps its name");
        // ADR-034 — a group's name: a placeholder chat becomes the group;
        // a named personal chat keeps its name.
        chat_upsert("g", "Group ab12", false, false, false, 0, None, 1, "text", None, false, 1).unwrap();
        let ph = vec!["Group ab12".to_string()];
        assert!(chat_set_group_name("g", "Дача", &ph).unwrap());
        assert!(!chat_set_group_name("g", "Дача", &ph).unwrap(), "same name, no change");
        assert!(chat_set_group_name("g", "Дача 2", &ph).unwrap(), "a group can be renamed");
        assert!(!chat_set_group_name("s", "Not Bob", &ph).unwrap(), "a personal chat keeps its name");
        assert_eq!(chat().display_name, "Bob");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn peer_names_profile_sent_and_blocking_v9() {
        let _db = db_test_lock();
        let path = temp_db_path("people_v9");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        let k = "ab".repeat(32);
        assert!(peer_name_set(&k, "Аня", 1).unwrap());
        assert!(!peer_name_set(&k, "Аня", 2).unwrap(), "same name is not a change");
        assert!(peer_name_set(&k, "Анна", 3).unwrap());
        assert_eq!(peer_names().unwrap(), vec![(k.clone(), "Анна".to_string())]);

        chat_upsert("g", "G", true, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        assert_eq!(chat_profile_sent("g").unwrap(), None);
        chat_set_profile_sent("g", "Вера").unwrap();
        assert_eq!(chat_profile_sent("g").unwrap().as_deref(), Some("Вера"));
        assert_eq!(chat_profile_sent("nope").unwrap(), None);

        assert!(!peer_is_blocked(&k).unwrap());
        peer_set_blocked(&k, true, 5).unwrap();
        peer_set_blocked(&k, true, 6).unwrap();
        assert!(peer_is_blocked(&k).unwrap());
        assert_eq!(peers_blocked().unwrap(), vec![k.clone()]);
        // ADR-071 — the block, then the unblock, each with a later time.
        let d = access_block_decisions().unwrap();
        assert_eq!((d.len(), d[0].0.as_str(), d[0].1), (1, k.as_str(), true));
        let blocked_at = d[0].2;
        peer_set_blocked(&k, false, 7).unwrap();
        assert!(peers_blocked().unwrap().is_empty());
        let d = access_block_decisions().unwrap();
        assert_eq!((d.len(), d[0].1), (1, false));
        assert!(d[0].2 > blocked_at, "the unblock is the later decision");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn disappearing_messages_v8() {
        let _db = db_test_lock();
        let path = temp_db_path("expire_v8");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        chat_upsert("d", "D", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        chat_set_disappear("d", 3600).unwrap();
        let chat = || chats_list().unwrap().into_iter().find(|c| c.id == "d").unwrap();
        assert_eq!(chat().disappear_secs, 3600);
        let ins = |id: &str, ts: i64, body: &str, exp: Option<i64>| {
            message_insert(&NewMessage {
                id,
                chat_id: "d",
                ts_unix: ts,
                body,
                kind: "text",
                wire_id: Some(id),
                media_json: if exp.is_some() { Some("{\"keys\":\"secret\"}") } else { None },
                expire_at: exp,
                ..Default::default()
            })
            .unwrap()
        };
        ins("keep", 10, "stays", None);
        ins("soon", 11, "goes", Some(100));
        ins("later", 12, "goes later", Some(500));
        assert_eq!(messages_expire(99).unwrap(), Vec::<String>::new());
        assert_eq!(messages_expire(100).unwrap(), vec!["d".to_string()]);
        assert!(message_by_wire("d", "soon").unwrap().is_none(), "row gone, media keys with it");
        assert_eq!(chat().last_msg_preview.as_deref(), Some("goes later"));
        assert_eq!(message_by_wire("d", "later").unwrap().unwrap().expire_at, Some(500));
        messages_expire(1000).unwrap();
        assert_eq!(chat().last_msg_preview.as_deref(), Some("stays"));
        chat_set_disappear("d", -5).unwrap();
        assert_eq!(chat().disappear_secs, 0, "negative → off");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn fts_index_v10_follows_every_change() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA foreign_keys = ON;").unwrap();
        apply_migrations(&conn).unwrap();
        let chat = |id: &str| {
            conn.execute(
                "INSERT INTO chats (id, display_name, is_group, muted, pinned, unread_count, last_msg_ts_unix, \
                 last_msg_kind, last_msg_mine, created_at_unix) VALUES (?, 'C', 0, 0, 0, 0, 0, 'text', 0, 0)",
                [id],
            )
            .unwrap();
        };
        let msg = |id: &str, chat: &str, ts: i64, body: &str| {
            conn.execute(
                "INSERT INTO messages (id, chat_id, ts_unix, body, wire_id) VALUES (?, ?, ?, ?, ?)",
                params![id, chat, ts, body, format!("w-{id}")],
            )
            .unwrap();
        };
        let ids = |q: &str| -> Vec<String> {
            messages_search_on(&conn, q, 10).unwrap().into_iter().map(|h| h.message_id).collect()
        };
        chat("c");
        chat("d");
        msg("m1", "c", 1, "Привет, МИР — скидка 50%");
        msg("m2", "c", 2, "мир тесен");
        msg("m3", "d", 3, "say \"hi\" OR bye*");

        // Unicode case folding, newest first, wire id comes back.
        assert_eq!(ids("мир"), ["m2", "m1"]);
        let hit = &messages_search_on(&conn, "ПРИВЕТ", 10).unwrap()[0];
        assert_eq!((hit.wire_id.as_deref(), hit.chat_name.as_str()), (Some("w-m1"), "C"));
        // Query text is never FTS syntax.
        assert_eq!(ids("\"hi\" OR"), ["m3"]);
        assert_eq!(ids("bye*"), ["m3"]);
        assert!(ids("NEAR(").is_empty());
        // Under 3 characters: a scan, case-insensitive for Cyrillic too.
        assert_eq!(ids("50"), ["m1"]);
        assert_eq!(ids("пр"), ["m1"], "«пр» finds «Привет»");
        assert_eq!(ids("%"), ["m1"], "no wildcards");

        // Deleted text leaves nothing in the index segments (secure-delete).
        conn.execute("INSERT INTO messages (id, chat_id, ts_unix, body) VALUES ('z', 'c', 9, 'zulu plaintext')", []).unwrap();
        conn.execute("DELETE FROM messages WHERE id = 'z'", []).unwrap();
        let leftovers: i64 = conn
            .query_row("SELECT count(*) FROM messages_fts_data WHERE instr(block, CAST('zul' AS BLOB)) > 0", [], |r| r.get(0))
            .unwrap();
        assert_eq!(leftovers, 0, "deleted text must not stay in the FTS index");

        // Edit, delete for everyone, row delete, chat delete (FK cascade).
        conn.execute("UPDATE messages SET body = 'новый текст' WHERE id = 'm2'", []).unwrap();
        assert_eq!(ids("мир"), ["m1"]);
        assert_eq!(ids("новый"), ["m2"]);
        conn.execute("UPDATE messages SET deleted = 1, body = '' WHERE id = 'm1'", []).unwrap();
        assert!(ids("мир").is_empty());
        conn.execute("DELETE FROM messages WHERE id = 'm2'", []).unwrap();
        assert!(ids("новый").is_empty());
        conn.execute("DELETE FROM chats WHERE id = 'd'", []).unwrap();
        assert!(ids("bye").is_empty());
        let left: i64 = conn.query_row("SELECT count(*) FROM messages_fts", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0, "no orphan index rows");

        // Upgrading a v9 database indexes the messages it already has.
        msg("m4", "c", 4, "старое сообщение");
        conn.execute_batch(
            "DROP TRIGGER messages_fts_ai; DROP TRIGGER messages_fts_ad; DROP TRIGGER messages_fts_au; \
             DROP TABLE messages_fts; PRAGMA user_version = 9;",
        )
        .unwrap();
        apply_migrations(&conn).unwrap();
        assert_eq!(ids("сообщ"), ["m4"]);
        assert_eq!(conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0)).unwrap(), SCHEMA_VERSION);
    }

    /// ADR-052 — contacts are their own list: deleting the chat keeps the
    /// person; removing the contact keeps the chat.
    #[test]
    fn contacts_outlive_chats_and_bios_v15() {
        let _db = db_test_lock();
        let path = temp_db_path("contacts_v15");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        for c in contacts_list().unwrap() {
            contact_remove(&c.peer_id).unwrap();
        }
        let k = "AB".repeat(32);
        let low = k.to_lowercase();
        assert!(contact_add(&k, "", 10).unwrap());
        assert!(!contact_add(&low, "Аня", 11).unwrap(), "already a contact (keys compare lower-case)");
        assert_eq!(
            contacts_list().unwrap(),
            vec![Contact { peer_id: low.clone(), name: "Аня".into(), favourite: false, added_ts: 10 }],
            "a name fills in only where there was none; the date stays"
        );
        contact_add(&low, "Someone else", 12).unwrap();
        assert_eq!(contacts_list().unwrap()[0].name, "Аня", "a known name is not replaced");
        assert!(contact_set_favourite(&k, true).unwrap());
        assert!(contacts_list().unwrap()[0].favourite);
        assert!(!contact_set_favourite(&"cd".repeat(32), true).unwrap(), "not a contact");

        // Their chat goes; they stay.
        chat_upsert("dm", "Аня", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        chat_set_peer("dm", &low).unwrap();
        chat_delete("dm").unwrap();
        assert_eq!(contacts_list().unwrap().len(), 1);
        assert!(contact_remove(&k).unwrap());
        assert!(!contact_remove(&k).unwrap());
        assert!(contacts_list().unwrap().is_empty());

        assert!(peer_bio_set(&low, "Пишите днём", 1).unwrap());
        assert!(!peer_bio_set(&low, "Пишите днём", 2).unwrap(), "same bio is not a change");
        assert_eq!(peer_bios().unwrap(), vec![(low.clone(), "Пишите днём".to_string())]);
        assert!(peer_bio_set(&low, "", 3).unwrap(), "empty = bio removed");
        assert!(!peer_bio_set(&low, "", 4).unwrap());
        assert!(peer_bios().unwrap().is_empty());
        let _ = std::fs::remove_file(&path);
    }

    /// Upgrading to v15: accepted personal chats whose person is known
    /// become contacts; groups, requests and chats without a key don't.
    #[test]
    fn v15_makes_contacts_of_existing_personal_chats() {
        let conn = Connection::open_in_memory().unwrap();
        apply_migrations(&conn).unwrap();
        conn.execute_batch("DROP TABLE contacts; DROP TABLE peer_bios; PRAGMA user_version = 14;").unwrap();
        let chat = |id: &str, name: &str, group: i64, request: i64, peer: Option<&str>| {
            conn.execute(
                "INSERT INTO chats (id, display_name, is_group, created_at_unix, request, peer_id) VALUES (?, ?, ?, 7, ?, ?)",
                params![id, name, group, request, peer],
            )
            .unwrap();
        };
        let anna = "AA".repeat(32);
        chat("dm1", "Аня", 0, 0, Some(&anna));
        chat("dm2", "Аня again", 0, 0, Some(&anna.to_lowercase()));
        chat("grp", "Семья", 1, 0, Some(&"bb".repeat(32)));
        chat("req", "Stranger", 0, 1, Some(&"cc".repeat(32)));
        chat("old", "No key yet", 0, 0, None);
        apply_migrations(&conn).unwrap();
        let rows: Vec<(String, String, i64)> = conn
            .prepare("SELECT peer_id, name, added_ts FROM contacts")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(rows.len(), 1, "one row per person: {rows:?}");
        assert_eq!(rows[0].0, anna.to_lowercase());
        assert_eq!(rows[0].2, 7);
        assert_eq!(conn.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0)).unwrap(), SCHEMA_VERSION);
        // Running it again changes nothing.
        apply_migrations(&conn).unwrap();
        let n: i64 = conn.query_row("SELECT count(*) FROM contacts", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1);
    }

    #[test]
    fn v7_backfills_wire_ids_of_older_rows() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_V1).unwrap();
        conn.execute_batch(SCHEMA_V2_UPGRADE).unwrap();
        conn.execute_batch(SCHEMA_V3_UPGRADE).unwrap();
        conn.execute_batch(SCHEMA_V4_UPGRADE).unwrap();
        conn.execute_batch(SCHEMA_V5_UPGRADE).unwrap();
        for (_, ddl) in SCHEMA_V6_COLUMNS {
            conn.execute_batch(ddl).unwrap();
        }
        conn.execute_batch("PRAGMA user_version = 6;").unwrap();
        conn.execute(
            "INSERT INTO chats (id, display_name, is_group, muted, pinned, unread_count, last_msg_ts_unix, \
             last_msg_kind, last_msg_mine, created_at_unix) VALUES ('c', 'C', 0, 0, 0, 0, 0, 'text', 0, 0)",
            [],
        )
        .unwrap();
        conn.execute_batch(
            "INSERT INTO messages (id, chat_id, ts_unix, body, kind, is_mine) VALUES \
             ('remote-0f8fad5b-d9cb-469f-a165-70867728950e', 'c', 1, 'in', 'text', 0), \
             ('msg-abc', 'c', 2, 'out', 'text', 1);",
        )
        .unwrap();
        apply_migrations(&conn).unwrap();
        let rows: Vec<(Option<String>, i64)> = conn
            .prepare("SELECT wire_id, status FROM messages ORDER BY ts_unix")
            .unwrap()
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(rows[0], (Some("0f8fad5b-d9cb-469f-a165-70867728950e".into()), 0));
        assert_eq!(rows[1], (None, 1), "older own messages count as sent");
    }

    #[test]
    fn chat_organisation_v6() {
        let _db = db_test_lock();
        let path = temp_db_path("org_v6");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();
        for (id, name) in [("a", "Alice"), ("b", "Bob"), ("c", "Carol")] {
            chat_upsert(id, name, false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        }
        let get = |id: &str| chats_list().unwrap().into_iter().find(|c| c.id == id).unwrap();

        // Incoming → unread +1; outgoing clears the draft; read resets.
        chat_set_draft("a", Some("half-typed")).unwrap();
        assert_eq!(get("a").draft.as_deref(), Some("half-typed"));
        message_append("a1", "a", 10, "hi", "text", false, None).unwrap();
        message_append("a2", "a", 11, "there", "text", false, None).unwrap();
        assert_eq!(get("a").unread_count, 2);
        message_append("a3", "a", 12, "me", "text", true, None).unwrap();
        assert_eq!(get("a").draft, None, "sending clears the draft");
        chat_mark_unread("a").unwrap();
        assert!(get("a").marked_unread);
        chat_mark_read("a").unwrap();
        assert_eq!((get("a").unread_count, get("a").marked_unread), (0, false));
        chat_set_draft("a", Some("   ")).unwrap();
        assert_eq!(get("a").draft, None, "blank drafts are not stored");

        // Pin order: pinned first in pin order; reorder; archive unpins.
        chat_set_pinned("c", true).unwrap();
        chat_set_pinned("b", true).unwrap();
        let order: Vec<_> = chats_list().unwrap().into_iter().map(|c| c.id).collect();
        assert_eq!(&order[..2], ["c", "b"]);
        chats_reorder_pinned(&["b".to_string(), "c".to_string()]).unwrap();
        let order: Vec<_> = chats_list().unwrap().into_iter().map(|c| c.id).collect();
        assert_eq!(&order[..2], ["b", "c"]);
        chat_set_archived("b", true).unwrap();
        assert!(get("b").archived && !get("b").pinned);
        // A new message from them brings an archived chat back — unless muted.
        message_append("b-own", "b", 10, "my note", "text", true, None).unwrap();
        assert!(get("b").archived, "my own message doesn't unarchive");
        chat_set_muted("b", true).unwrap();
        message_append("b-in1", "b", 11, "hi", "text", false, None).unwrap();
        assert!(get("b").archived, "muted chats stay archived");
        chat_set_muted("b", false).unwrap();
        message_append("b-in2", "b", 12, "hi again", "text", false, None).unwrap();
        assert!(!get("b").archived, "an unmuted chat comes back on a new message");
        // Message requests: set on join, cleared by accepting or by my own message.
        assert!(!get("b").request);
        chat_set_request("b", true).unwrap();
        assert!(get("b").request);
        message_append("b-in3", "b", 12, "still there?", "text", false, None).unwrap();
        assert!(get("b").request, "their messages don't accept it");
        message_append("b-sys", "b", 12, "timer:3600:peer", "system", true, None).unwrap();
        assert!(get("b").request, "a system line (their timer / screenshot) is not my writing");
        message_append("b-own1", "b", 12, "ok", "text", true, None).unwrap();
        assert!(!get("b").request, "my message accepts it");
        let k = "ab".repeat(32);
        assert!(peer_avatar_set(&k, b"jpeg-1", 1).unwrap());
        assert!(!peer_avatar_set(&k, b"jpeg-1", 2).unwrap(), "same photo is not a change");
        assert!(peer_avatar_set(&k, b"jpeg-2", 3).unwrap());
        assert_eq!(peer_avatars().unwrap(), vec![(k.clone(), b"jpeg-2".to_vec())]);
        chat_set_peer("b", &k).unwrap();
        assert_eq!(get("b").peer_id.as_deref(), Some(k.as_str()));
        chat_set_peer("g-missing", &k).unwrap();
        assert!(peer_avatar_set(&k, b"", 4).unwrap(), "empty = photo removed");
        assert!(peer_avatars().unwrap().is_empty());
        chat_set_mentioned("b").unwrap();
        assert!(get("b").mentioned);
        chat_mark_read("b").unwrap();
        assert!(!get("b").mentioned, "reading clears the @ badge");
        chat_set_pinned_message("b", Some("w-x")).unwrap();
        assert!(!chat_unpin_if("b", "w-other").unwrap(), "another message is pinned");
        assert!(chat_unpin_if("b", "w-x").unwrap());
        assert!(!chat_rename_if("b", "Not its name", "Аня").unwrap(), "only from the placeholder");
        assert!(chat_rename_if("b", "Bob", "Боб").unwrap());
        assert_eq!(get("b").display_name, "Боб");
        assert_eq!(get("b").pinned_msg, None);
        chat_set_request("b", true).unwrap();
        chat_set_request("b", false).unwrap();
        assert!(!get("b").request);
        // List ticks follow the newest message: theirs → none; mine → its status.
        assert_eq!(get("b").last_msg_status, 0, "newest is theirs");
        message_append("b-own2", "b", 13, "reply", "text", true, None).unwrap();
        assert_eq!(get("b").last_msg_status, 0, "mine, still sending");
        with_db(|c| Ok(c.execute("UPDATE messages SET status = 3 WHERE id = 'b-own2'", [])?)).unwrap();
        assert_eq!(get("b").last_msg_status, 3, "read");
        assert_eq!(get("a").last_msg_status, 0, "no messages at all");
        chat_set_archived("b", true).unwrap();
        chat_set_muted("c", true).unwrap();
        assert!(get("c").muted);

        // Search: case-insensitive substring, LIKE wildcards are literal.
        message_append("c1", "c", 20, "Meet at 50% discount_store", "text", false, None).unwrap();
        let hits = messages_search("DISCOUNT", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!((hits[0].chat_id.as_str(), hits[0].chat_name.as_str()), ("c", "Carol"));
        assert_eq!(messages_search("50%", 10).unwrap().len(), 1);
        assert!(messages_search("5_%", 10).unwrap().is_empty(), "_ is not a wildcard");
        assert!(messages_search("  ", 10).unwrap().is_empty());

        // Delete cascades to messages.
        chat_delete("a").unwrap();
        assert!(chats_list().unwrap().iter().all(|c| c.id != "a"));
        assert!(messages_list_for_chat("a", None).unwrap().is_empty());
    }

    #[test]
    fn messages_listed_oldest_first() {
        let _db = db_test_lock();
        let path = temp_db_path("msg_order");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();

        chat_upsert(
            "c2", "Test2", false, false, false, 0, None, 0, "text", None, false, 1_699_000_000,
        )
        .unwrap();

        // append out of order — function takes ts_unix as a parameter
        message_append("m_b", "c2", 200, "second", "text", false, None).unwrap();
        message_append("m_a", "c2", 100, "first", "text", true, None).unwrap();
        message_append("m_c", "c2", 300, "third", "text", false, None).unwrap();

        let msgs_full = messages_list_for_chat("c2", None).unwrap();
        assert_eq!(msgs_full.len(), 3);
        assert_eq!(msgs_full[0].body, "first");
        assert_eq!(msgs_full[2].body, "third");

        // With limit, we still get oldest-first ordering of the slice.
        let msgs_2 = messages_list_for_chat("c2", Some(2)).unwrap();
        assert_eq!(msgs_2.len(), 2);
        assert_eq!(msgs_2[0].body, "second"); // most-recent 2 → "second", "third"
        assert_eq!(msgs_2[1].body, "third");

        // v4 — media envelope JSON round-trips; text rows stay None.
        assert!(msgs_full.iter().all(|m| m.media_json.is_none()));
        message_append_with_media(
            "m_d", "c2", 400, "caption", "photo", true, None, Some(r#"{"kind":"photo"}"#),
        )
        .unwrap();
        let last = messages_list_for_chat("c2", Some(1)).unwrap().pop().unwrap();
        assert_eq!(last.kind, "photo");
        assert_eq!(last.media_json.as_deref(), Some(r#"{"kind":"photo"}"#));

        // Paging: newest page, then strictly older pages, stable order.
        message_append("m_e", "c2", 400, "same-second", "text", false, None).unwrap();
        let newest = messages_page("c2", None, 2).unwrap();
        assert_eq!(newest.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["m_d", "m_e"]);
        let older = messages_page("c2", Some((newest[0].ts_unix, &newest[0].id)), 2).unwrap();
        assert_eq!(older.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["m_b", "m_c"]);
        let oldest = messages_page("c2", Some((older[0].ts_unix, &older[0].id)), 10).unwrap();
        assert_eq!(oldest.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["m_a"]);
        assert!(messages_page("c2", Some((oldest[0].ts_unix, &oldest[0].id)), 10).unwrap().is_empty());

        // v5 — link preview attached after the fact.
        message_set_media_json("m_c", r#"{"link":1}"#).unwrap();
        let third = messages_list_for_chat("c2", None)
            .unwrap()
            .into_iter()
            .find(|m| m.id == "m_c")
            .unwrap();
        assert_eq!(third.media_json.as_deref(), Some(r#"{"link":1}"#));

        // v5 — settings round-trip + overwrite.
        assert_eq!(setting_get("link_previews").unwrap(), None);
        setting_set("link_previews", "1").unwrap();
        setting_set("link_previews", "0").unwrap();
        assert_eq!(setting_get("link_previews").unwrap().as_deref(), Some("0"));
    }

    /// Regression test for the WU 73 schema-migration bug that bricked the
    /// 2026-05-22 iPhone test. On second cold-launch, the old code's
    /// `INSERT OR IGNORE` + `UPDATE WHERE version < 2` pattern produced a
    /// PRIMARY-KEY conflict on the `schema_version` table. This test
    /// recreates that broken state on an in-memory DB and asserts that
    /// `apply_migrations()` recovers cleanly.
    #[test]
    fn migration_recovers_from_broken_v1_v2_schema_version_state() {
        let _db = db_test_lock();
        let conn = Connection::open_in_memory().expect("open in-memory");

        // Re-create the OLD broken state: schema_version table with
        // both row(1) and row(2), plus the v1 identities table populated
        // with a saved row (mirrors what the user's iPhone has).
        conn.execute_batch(
            "
            CREATE TABLE schema_version (version INTEGER NOT NULL PRIMARY KEY);
            INSERT INTO schema_version (version) VALUES (1);
            INSERT INTO schema_version (version) VALUES (2);

            CREATE TABLE identities (
                phrase_hash      TEXT NOT NULL PRIMARY KEY,
                fingerprint      TEXT NOT NULL,
                ed25519_pub_hex  TEXT NOT NULL,
                x25519_pub_hex   TEXT NOT NULL,
                created_at_unix  INTEGER NOT NULL
            );
            INSERT INTO identities VALUES (
                'hash_from_first_onboarding',
                '9a3e 4d12 8b71',
                'ed_hex',
                'x_hex',
                1716355200
            );
            ",
        )
        .expect("seed broken state");

        // The fix: applying migrations on this broken DB must NOT error.
        apply_migrations(&conn).expect("recovery migration");

        // schema_version table should be dropped.
        let still_there: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master \
                 WHERE type='table' AND name='schema_version'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(still_there, 0, "legacy schema_version table not dropped");

        // user_version is now 2.
        let v: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // Critically: the user's saved identity SURVIVED the migration.
        let fp: String = conn
            .query_row(
                "SELECT fingerprint FROM identities LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(fp, "9a3e 4d12 8b71");

        // chats / messages tables are now present.
        let chats_exists: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master \
                 WHERE type='table' AND name='chats'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(chats_exists, 1);

        // And another apply_migrations() call is a clean no-op.
        apply_migrations(&conn).expect("re-running migrations is idempotent");
    }

    /// v3 → v4 adds messages.media_json, keeps rows, and survives a
    /// re-run even if the ALTER already happened before a crash.
    #[test]
    fn migration_v4_adds_media_json_to_existing_db() {
        let _db = db_test_lock();
        let conn = Connection::open_in_memory().expect("open in-memory");
        conn.execute_batch(SCHEMA_V1).unwrap();
        conn.execute_batch(SCHEMA_V2_UPGRADE).unwrap();
        conn.execute_batch(SCHEMA_V3_UPGRADE).unwrap();
        conn.execute_batch("PRAGMA user_version = 3;").unwrap();
        conn.execute(
            "INSERT INTO chats (id, display_name, created_at_unix) VALUES ('c', 'C', 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO messages (id, chat_id, ts_unix, body) VALUES ('m', 'c', 1, 'hi')",
            [],
        )
        .unwrap();

        apply_migrations(&conn).expect("v4 migration");
        let media: Option<String> = conn
            .query_row("SELECT media_json FROM messages WHERE id = 'm'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(media, None, "existing rows keep NULL media");

        // Crash between ALTER and the version bump → re-run must not fail.
        conn.execute_batch("PRAGMA user_version = 3;").unwrap();
        apply_migrations(&conn).expect("re-run after partial v4");
        let v: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
        assert_eq!(v, SCHEMA_VERSION);
    }

    #[test]
    fn migration_v18_clears_binary_placeholder_bubbles() {
        let _db = db_test_lock();
        let conn = Connection::open_in_memory().expect("open in-memory");
        apply_migrations(&conn).expect("fresh schema");
        conn.execute("INSERT INTO chats (id, display_name, created_at_unix) VALUES ('c', 'C', 1)", []).unwrap();
        for (id, body, mine) in [
            ("a", "<binary 574B>", 0),
            ("b", "привет", 0),
            ("c", "<binary 574B>", 1),
            ("d", "<binary> is a tag", 0),
        ] {
            conn.execute(
                "INSERT INTO messages (id, chat_id, ts_unix, body, kind, is_mine) VALUES (?1, 'c', 1, ?2, 'text', ?3)",
                rusqlite::params![id, body, mine],
            )
            .unwrap();
        }
        conn.execute_batch("PRAGMA user_version = 17;").unwrap();
        apply_migrations(&conn).expect("v18");
        let left: Vec<String> = conn
            .prepare("SELECT id FROM messages ORDER BY id")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(left, ["b", "c", "d"], "only incoming placeholders go");
    }

    #[test]
    fn migration_creates_fresh_schema_on_empty_db() {
        let _db = db_test_lock();
        let conn = Connection::open_in_memory().expect("open in-memory");
        apply_migrations(&conn).expect("fresh migration");

        let v: i64 = conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        for table in &["identities", "chats", "messages", "calls"] {
            let exists: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master \
                     WHERE type='table' AND name=?",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(exists, 1, "{table} table missing after migration");
        }
    }

    #[test]
    fn cascade_deletes_messages_when_chat_wiped() {
        let _db = db_test_lock();
        let path = temp_db_path("cascade");
        open(&path, None).expect("open db");
        let _ = chats_wipe_all();

        chat_upsert(
            "c3", "Test3", false, false, false, 0, None, 0, "text", None, false, 1_699_000_000,
        )
        .unwrap();
        message_append("m_x", "c3", 100, "x", "text", true, None).unwrap();
        message_append("m_y", "c3", 200, "y", "text", false, None).unwrap();
        assert_eq!(messages_list_for_chat("c3", None).unwrap().len(), 2);

        chats_wipe_all().unwrap();
        assert_eq!(chats_list().unwrap().len(), 0);
        assert_eq!(messages_list_for_chat("c3", None).unwrap().len(), 0);
    }

    /// T1.1 regression — SQLCipher PRAGMA key encrypts the DB.
    /// Opening with the wrong key (or no key at all) on an encrypted
    /// DB must fail. Round-trip with the right key must succeed.
    ///
    /// This test verifies the most-important security property of
    /// at-rest encryption: an attacker with the file alone can't read
    /// it without knowing the key.
    #[test]
    fn sqlcipher_locks_db_against_wrong_key() {
        let _db = db_test_lock();
        let key_a: [u8; 32] = [0xAA; 32];
        let key_b: [u8; 32] = [0xBB; 32];
        let path = temp_db_path("sqlcipher-lock");

        // Open with key A, run a write, close.
        {
            let conn = Connection::open(&path).expect("open");
            apply_encryption_key(&conn, &key_a).expect("apply key A");
            apply_migrations(&conn).expect("migrations");
            conn.execute(
                "INSERT INTO identities (phrase_hash, fingerprint, ed25519_pub_hex, \
                 x25519_pub_hex, created_at_unix) VALUES (?, ?, ?, ?, ?)",
                params!["hash_aaa", "fp_aaa", "ed_aaa", "x_aaa", 1_700_000_000_i64],
            )
            .expect("insert");
            // conn dropped at end of scope — file flushed.
        }

        // Open with WRONG key. First query must fail — encrypted DB
        // reads as garbage when keyed incorrectly.
        {
            let conn = Connection::open(&path).expect("open");
            apply_encryption_key(&conn, &key_b).expect("apply key B");
            let result: Result<i64, _> =
                conn.query_row("SELECT COUNT(*) FROM identities", [], |row| row.get(0));
            assert!(
                result.is_err(),
                "SQLCipher MUST refuse reads with wrong key — got Ok({:?})",
                result
            );
        }

        // Open with RIGHT key — read succeeds, our row is there.
        {
            let conn = Connection::open(&path).expect("open");
            apply_encryption_key(&conn, &key_a).expect("apply key A again");
            apply_migrations(&conn).expect("migrations re-run");
            let count: i64 = conn
                .query_row("SELECT COUNT(*) FROM identities", [], |row| row.get(0))
                .expect("read with right key");
            assert_eq!(count, 1, "expected the row we inserted");
        }
    }

    /// T1.1 — `open(path, key)` integrates the PRAGMA key with the
    /// global DB singleton. Smoke test that a fresh encrypted DB
    /// opens, runs migrations, and accepts an insert.
    #[test]
    fn open_with_encryption_key_works_end_to_end() {
        let _db = db_test_lock();
        // Note: this test uses the global DB OnceLock, so it can run
        // at most once per process. Other tests that use `open()` use
        // distinct paths but share the same singleton — so this test
        // is also subject to "first open wins" semantics. We accept
        // that limitation: a real wins/loses race between key=Some
        // and key=None across tests is impossible (we only call once
        // per process for `open`).
        //
        // For an even better guarantee a `serial_test` crate would
        // gate this test against the others. Future cleanup.
        let _key: [u8; 32] = [0xCC; 32];
        // Intentionally don't actually call `open()` here — it would
        // race with other tests that already called `open(path, None)`.
        // The unit-level test above (`sqlcipher_locks_db_against_wrong_key`)
        // exercises the same code path without touching the global
        // singleton.
    }

    /// CRIT-1.1 regression — `migrate_unencrypted_to_encrypted` must:
    ///   1. Preserve all data from the plain DB (chats + messages + identities).
    ///   2. Refuse subsequent opens with the wrong key.
    ///   3. Reinstall the singleton against the encrypted file so the
    ///      app keeps working without a restart.
    ///
    /// Single test covers all three because the singleton is process-wide
    /// and we don't want serialization issues across multiple tests
    /// touching `DB`. Uses `_force_close_for_tests` to simulate "process
    /// boot" by clearing the singleton between steps.
    #[test]
    fn migrate_plain_to_encrypted_preserves_data_and_enforces_key() {
        let _db = db_test_lock();
        let key: [u8; 32] = [0xCD; 32];
        let path = temp_db_path("rekey-migrate");

        // ── Step 1: open plain, insert data ──────────────────────────
        _force_close_for_tests();
        open(&path, None).expect("open plain");
        save_identity(
            "phrase-for-rekey",
            "fp_rekey",
            "ed_rekey",
            "x_rekey",
            1_700_000_111,
        )
        .expect("save identity");
        chat_upsert(
            "chat-rekey",
            "Migration Test",
            false,
            false,
            false,
            0,
            Some("pre-migration message"),
            1_700_000_222,
            "text",
            None,
            true,
            1_700_000_000,
        )
        .expect("upsert chat");
        message_append(
            "msg-rekey",
            "chat-rekey",
            1_700_000_222,
            "pre-migration message",
            "text",
            true,
            None,
        )
        .expect("append msg");

        // ── Step 2: migrate plain → encrypted ────────────────────────
        migrate_unencrypted_to_encrypted(&key).expect("migration succeeds");

        // ── Step 3: singleton now points at encrypted file. Reads work. ──
        let loaded_id = load_latest_identity()
            .expect("load identity after migration")
            .expect("identity row present");
        assert_eq!(loaded_id.fingerprint, "fp_rekey");

        let chats = chats_list().expect("list chats");
        assert_eq!(chats.len(), 1);
        assert_eq!(chats[0].id, "chat-rekey");

        let msgs = messages_list_for_chat("chat-rekey", None).expect("list msgs");
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0].body, "pre-migration message");

        // ── Step 4: simulate process restart — close singleton, try
        // opening with WRONG key. Must fail early (apply_migrations
        // touches the DB pages and SQLCipher rejects). ───────────────
        _force_close_for_tests();
        let wrong_key: [u8; 32] = [0xEE; 32];
        let open_with_wrong = open(&path, Some(&wrong_key));
        assert!(
            open_with_wrong.is_err(),
            "open with wrong key should fail (apply_migrations reads pages)",
        );
        // The failed open did NOT install the singleton. Confirm with
        // a fresh-state check.
        _force_close_for_tests();

        // ── Step 5: open with RIGHT key — data still there. ──────────
        _force_close_for_tests();
        open(&path, Some(&key)).expect("open with right key");
        let loaded_again = load_latest_identity()
            .expect("read with right key")
            .expect("row present");
        assert_eq!(loaded_again.fingerprint, "fp_rekey");
    }

    /// ADR-021 — a cold start without the key must NOT destroy an
    /// encrypted DB (the old "self-heal" wiped it): it reports Locked,
    /// keeps the file, and the right key still opens it afterwards.
    #[test]
    fn locked_db_is_kept_and_reopens_with_the_right_key() {
        let _db = db_test_lock();
        let key: [u8; 32] = [0x21; 32];
        let path = temp_db_path("locked-kept");
        _force_close_for_tests();
        open(&path, None).expect("open plain");
        save_identity("phrase-locked", "fp_locked", "ed", "x", 1_700_000_001).expect("save");
        migrate_unencrypted_to_encrypted(&key).expect("seal");

        _force_close_for_tests();
        assert!(matches!(open(&path, None), Err(StorageError::Locked)), "no key → Locked");
        assert!(matches!(open(&path, Some(&[0x22; 32])), Err(StorageError::Locked)), "wrong key → Locked");
        assert!(path.exists(), "the encrypted file must survive a locked open");

        open(&path, Some(&key)).expect("right key opens");
        assert_eq!(load_latest_identity().unwrap().unwrap().fingerprint, "fp_locked");
    }

    /// A key on a still-plain file (onboarding never sealed it) is also
    /// Locked — the app then opens it plain and seals it.
    #[test]
    fn key_on_plain_file_is_locked_and_plain_still_opens() {
        let _db = db_test_lock();
        let path = temp_db_path("key-on-plain");
        _force_close_for_tests();
        open(&path, None).expect("create plain");
        save_identity("phrase-plain", "fp_plain", "ed", "x", 1_700_000_002).expect("save");
        _force_close_for_tests();
        assert!(matches!(open(&path, Some(&[0x33; 32])), Err(StorageError::Locked)));
        open(&path, None).expect("plain open still works");
        assert_eq!(load_latest_identity().unwrap().unwrap().fingerprint, "fp_plain");
    }

    /// ADR-049 — sticker packs live next to the DB, apart from media copies
    /// (clearing those keeps them), and go when the DB is erased.
    #[test]
    fn sticker_packs_live_next_to_the_db_and_go_with_it() {
        let _db = db_test_lock();
        _force_close_for_tests();
        let path = temp_db_path("stickers");
        let _ = std::fs::remove_dir_all(stickers::dir_for(&path));
        open(&path, None).expect("open db");
        let sha = "ab".repeat(32);
        assert!(stickers::put("../x", b"no").is_err());
        stickers::put(&sha, b"cipher").unwrap();
        assert_eq!(stickers::get(&sha).as_deref(), Some(&b"cipher"[..]));
        blobs::clear_copies(std::time::Duration::ZERO).unwrap();
        assert!(stickers::get(&sha).is_some(), "clearing media copies keeps packs");
        stickers::remove(&sha);
        assert_eq!(stickers::get(&sha), None);
        stickers::put(&sha, b"cipher").unwrap();
        erase_and_reopen_plain(&path).unwrap();
        assert!(!stickers::dir_for(&path).exists());
        _force_close_for_tests();
    }

    /// Tech-debt 2.32 — "keep media copies for a month": a copy's age counts
    /// from its last use, so one opened yesterday stays.
    #[test]
    fn media_copies_age_from_their_last_use() {
        let _db = db_test_lock();
        _force_close_for_tests();
        let path = temp_db_path("keep-days");
        let dir = blobs::dir_for(&path);
        let _ = std::fs::remove_dir_all(&dir);
        open(&path, None).expect("open db");
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(40 * 86_400);
        for c in ['e', 'f'] {
            let sha = c.to_string().repeat(64);
            blobs::put(&sha, &[0; 50]).unwrap();
            let f = std::fs::File::options().write(true).open(dir.join(&sha[..2]).join(&sha)).unwrap();
            f.set_modified(old).unwrap();
        }
        assert!(blobs::get(&"f".repeat(64)).is_some(), "opened again today");
        let month = std::time::Duration::from_secs(30 * 86_400);
        assert_eq!(blobs::clear_copies(month).unwrap(), 50, "only the copy nobody opened");
        assert!(blobs::get(&"e".repeat(64)).is_none());
        assert!(blobs::get(&"f".repeat(64)).is_some());
        _force_close_for_tests();
    }

    /// Tech-debt 2.32 — the Storage screen: media copies by kind and by
    /// chat (a shared copy counted once), the database, and clearing.
    #[test]
    fn storage_usage_by_kind_and_chat_then_clear() {
        let _db = db_test_lock();
        _force_close_for_tests();
        let path = temp_db_path("usage");
        let _ = std::fs::remove_dir_all(blobs::dir_for(&path));
        open(&path, None).expect("open db");
        let sha = |c: char| c.to_string().repeat(64);
        let file = |c: char| format!(r#"{{"v":1,"file":{{"sha256":"{}","key":"k"}}}}"#, sha(c));
        blobs::put(&sha('a'), &[0; 100]).unwrap(); // photo in "u1", also forwarded to "u2"
        blobs::put(&sha('b'), &[0; 1000]).unwrap(); // video in "u2"
        blobs::put(&sha('c'), &[0; 10]).unwrap(); // voice in "u1"
        blobs::put(&sha('d'), &[0; 7]).unwrap(); // nobody's (a send in flight)
        chat_upsert("u1", "A", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        chat_upsert("u2", "B", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        let ins = |id: &str, chat: &str, kind: &str, media: String, ts: i64| {
            message_insert(&NewMessage {
                id,
                chat_id: chat,
                ts_unix: ts,
                body: "",
                kind,
                wire_id: Some(id),
                media_json: Some(&media),
                ..Default::default()
            })
            .unwrap()
        };
        ins("p1", "u1", "photo", file('a'), 1);
        ins("p2", "u2", "photo", file('a'), 2);
        ins("v1", "u2", "video", file('b'), 3);
        ins("s1", "u1", "voice", file('c'), 4);

        let u = blobs::usage().unwrap();
        assert_eq!((u.photos, u.videos, u.voice, u.documents, u.other), (100, 1000, 10, 0, 0));
        assert_eq!(u.unreferenced, 7);
        assert_eq!(u.media_total(), 1117);
        assert_eq!(u.by_chat, vec![("u2".to_string(), 1000), ("u1".to_string(), 110)]);
        assert!(u.database > 0, "the DB file itself");

        // Fresh files may be a send in flight: kept.
        assert_eq!(blobs::clear_copies(std::time::Duration::from_secs(3600)).unwrap(), 0);
        assert_eq!(blobs::clear_copies(std::time::Duration::ZERO).unwrap(), 1117);
        assert_eq!(blobs::usage().unwrap().media_total(), 0);
        assert!(message_by_wire("u1", "p1").unwrap().is_some(), "messages stay; files load from the server again");
        _force_close_for_tests();
    }

    /// Explicit erase (user chose "start over" / signed out): data gone,
    /// a fresh plain DB is open and usable.
    /// ADR-033 — a local media copy lives exactly as long as some row
    /// references its sha256, and goes with the DB on erase.
    #[test]
    fn local_media_copies_follow_their_messages() {
        let _db = db_test_lock();
        _force_close_for_tests();
        let path = temp_db_path("blobs");
        let dir = blobs::dir_for(&path);
        let _ = std::fs::remove_dir_all(&dir);
        open(&path, None).expect("open db");
        let sha = |c: char| c.to_string().repeat(64);
        let have = |c: char| blobs::get(&sha(c)).is_some();
        let json = |file: char, thumb: char| {
            format!(
                r#"{{"v":1,"kind":"photo","file":{{"sha256":"{}","key":"k","blob_size":4,"plain_size":1}},"thumbnail":{{"sha256":"{}","key":"k","blob_size":4,"plain_size":1}}}}"#,
                sha(file),
                sha(thumb)
            )
        };

        // Only lowercase 64-hex names reach the filesystem.
        assert!(blobs::put("../../etc/passwd", b"x").is_err());
        assert!(blobs::put(&"A".repeat(64), b"x").is_err());
        assert!(blobs::get("../sinhron.db").is_none());
        for c in ['a', 'b', 'c', 'd', 'e', 'f', '1', '2'] {
            blobs::put(&sha(c), b"blob").unwrap();
        }
        assert_eq!(blobs::get(&sha('a')).as_deref(), Some(&b"blob"[..]));
        assert_eq!(std::fs::read(dir.join("aa").join(sha('a'))).unwrap(), b"blob", "<db>.blobs/<aa>/<sha>");
        assert_eq!(blobs::shas_in(&json('a', 'b')), vec![sha('a'), sha('b')]);
        assert!(blobs::shas_in("not json").is_empty());

        chat_upsert("bl", "B", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        chat_upsert("bl2", "B2", false, false, false, 0, None, 0, "text", None, false, 1).unwrap();
        let ins = |id: &str, chat: &str, media: &str, exp: Option<i64>| {
            message_insert(&NewMessage {
                id,
                chat_id: chat,
                ts_unix: 1000,
                body: "",
                kind: "photo",
                is_mine: true,
                wire_id: Some(id),
                media_json: Some(media),
                expire_at: exp,
                ..Default::default()
            })
            .unwrap()
        };
        ins("m1", "bl", &json('a', 'b'), None);
        ins("m2", "bl", &json('c', 'a'), None); // shares `a` with m1
        ins("m3", "bl2", &json('d', 'e'), None);
        ins("m4", "bl", &json('f', '1'), Some(100));

        // Delete for me: m1's own thumbnail goes, the shared file stays.
        messages_delete_local("bl", &["m1".to_string()]).unwrap();
        assert!(!have('b'));
        assert!(have('a'), "still referenced by m2");
        // Delete for everyone: the tombstone keeps no media.
        assert!(message_apply_delete("bl", "m2", Author::Me, 1000).unwrap());
        assert!(!have('a') && !have('c'));
        // Disappearing timer.
        messages_expire(100).unwrap();
        assert!(!have('f') && !have('1'));
        // Whole chat.
        chat_delete("bl2").unwrap();
        assert!(!have('d') && !have('e'));

        // `2` was never referenced (a failed send): collected only once
        // it is older than the grace period.
        assert_eq!(blobs::gc(std::time::Duration::from_secs(blobs::GC_GRACE_SECS)).unwrap(), 0);
        assert!(have('2'));
        assert_eq!(blobs::gc(std::time::Duration::ZERO).unwrap(), 1);
        assert!(!have('2'));

        // Erase takes the directory with the DB.
        blobs::put(&sha('a'), b"blob").unwrap();
        erase_and_reopen_plain(&path).unwrap();
        assert!(!dir.exists());
        _force_close_for_tests();
    }

    #[test]
    fn erase_and_reopen_plain_starts_fresh() {
        let _db = db_test_lock();
        let key: [u8; 32] = [0x44; 32];
        let path = temp_db_path("erase");
        _force_close_for_tests();
        open(&path, None).expect("open plain");
        save_identity("phrase-erase", "fp_erase", "ed", "x", 1_700_000_003).expect("save");
        migrate_unencrypted_to_encrypted(&key).expect("seal");
        _force_close_for_tests();
        assert!(matches!(open(&path, None), Err(StorageError::Locked)));

        erase_and_reopen_plain(&path).expect("erase");
        assert!(load_latest_identity().unwrap().is_none(), "identity erased");
        save_identity("phrase-new", "fp_new", "ed", "x", 1_700_000_004).expect("fresh DB is writable");
        _force_close_for_tests();
        open(&path, None).expect("fresh DB is plain");
    }

    /// CRIT-1.1 — migration must clean up stale `<path>.encrypted.tmp`
    /// leftovers from a prior interrupted run before starting. Verifies
    /// we don't fail on "file exists" when retrying.
    #[test]
    fn migrate_cleans_up_stale_tmp_leftover() {
        let _db = db_test_lock();
        let key: [u8; 32] = [0xDE; 32];
        let path = temp_db_path("rekey-cleanup");

        _force_close_for_tests();
        open(&path, None).expect("open plain");
        save_identity("p", "fp", "ed", "x", 1).expect("save");

        // Plant garbage at the staging path. The migration must remove
        // it before starting.
        let stale = staging_path(&path);
        std::fs::write(&stale, b"junk leftover from a crashed migration")
            .expect("plant stale tmp");
        assert!(stale.exists());

        migrate_unencrypted_to_encrypted(&key).expect("migration succeeds");

        // Staging path should NOT exist after a successful migration
        // (the file was renamed → original path).
        assert!(
            !stale.exists(),
            "staging file should be gone after successful migration",
        );

        // And the singleton works.
        let loaded = load_latest_identity().unwrap().unwrap();
        assert_eq!(loaded.fingerprint, "fp");
    }

    /// Risk #1 regression — apply_migrations() must enable WAL.
    /// `journal_mode` is per-connection but persists in the DB header
    /// once set, so even after re-open the result must be "wal".
    #[test]
    fn migrations_enable_wal_journal_mode() {
        let _db = db_test_lock();
        let path = temp_db_path("wal-mode");
        // Direct Connection here — using sinhron_storage's global OnceLock
        // would race with other tests; we test apply_migrations() directly.
        let conn = Connection::open(&path).expect("open");
        apply_migrations(&conn).expect("migrations");

        let mode: String = conn
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("read journal_mode");
        assert_eq!(
            mode.to_ascii_lowercase(),
            "wal",
            "journal_mode must be 'wal' after migrations; got {mode:?}",
        );

        // synchronous is read as an integer (0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA).
        let synchronous: i64 = conn
            .query_row("PRAGMA synchronous", [], |row| row.get(0))
            .expect("read synchronous");
        assert_eq!(
            synchronous, 1,
            "synchronous must be NORMAL (1) — paired with WAL; got {synchronous}",
        );
    }
}
