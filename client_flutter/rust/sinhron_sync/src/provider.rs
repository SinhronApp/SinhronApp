// SinhronProvider — composite OpenMLS provider with SQLite-backed storage.
//
// OpenMLS splits its provider into three parts (`OpenMlsProvider` trait):
//
//   • CryptoProvider — ciphersuite implementations (AES-GCM, HKDF, …)
//   • RandProvider   — CSPRNG
//   • StorageProvider — durable backing for groups, ratchet trees, keys
//
// `openmls_rust_crypto::OpenMlsRustCrypto` bundles these but pairs the
// excellent `RustCrypto`-backed crypto with `MemoryStorage`, which is
// in-process only. After a process restart every MLS group is dead.
//
// This module composes:
//
//   • `RustCrypto`            (same crate, public)
//   • `SqliteStorageProvider` (openmls_sqlite_storage 0.3 — official
//     OpenMLS workspace member, codec-agnostic via the `Codec` trait)
//
// We pick JSON as the codec for readability during early debugging —
// bincode would be tighter, but the difference is meaningless next to
// the actual key material the rows hold.
//
// WU C6 — without this, full_e2e and `cargo run --example bootstrap_smoke`
// happen to work only because they keep one process alive end-to-end.

use std::path::Path;

use openmls_rust_crypto::RustCrypto;
use openmls_sqlite_storage::{Codec, Connection, SqliteStorageProvider};
use openmls_traits::OpenMlsProvider;
use serde::{de::DeserializeOwned, Serialize};

/// JSON-via-`serde_json` codec — readable on disk, fully deterministic
/// for our entity types (all `Serialize + DeserializeOwned`). The
/// `Default` impl is required by the `Codec` trait.
#[derive(Default)]
pub struct JsonCodec;

impl Codec for JsonCodec {
    type Error = serde_json::Error;

    fn to_vec<T: Serialize>(value: &T) -> Result<Vec<u8>, Self::Error> {
        serde_json::to_vec(value)
    }

    fn from_slice<T: DeserializeOwned>(slice: &[u8]) -> Result<T, Self::Error> {
        serde_json::from_slice(slice)
    }
}

/// Sinhron's `OpenMlsProvider` — uses `RustCrypto` for sig/HPKE/RNG and
/// `SqliteStorageProvider` for persistent MLS state.
pub struct SinhronProvider {
    crypto: RustCrypto,
    storage: SqliteStorageProvider<JsonCodec, Connection>,
}

// Risk #3 (resolved 2026-05-23):
//
// Previously this module carried `unsafe impl Sync for SinhronProvider`
// because `rusqlite::Connection` is `!Sync` (it holds a
// `RefCell<InnerConnection>`) and our FFI used `slot.as_ref()` →
// `&SyncClient` across `.await`, which requires `SyncClient: Sync`.
//
// The unsafe was correct under the documented contract (external
// `tokio::sync::Mutex` serializes all access), but it was a **mine**:
// any future refactor that cloned an `Arc<SinhronProvider>` into a
// parallel tokio task would silently UB.
//
// Resolution: every async method on `SyncClient` that previously took
// `&self` now takes `&mut self`. The resulting `Future` requires only
// `Self: Send` (not `Self: Sync`), which holds without unsafe. FFI
// callers use `slot.as_mut()` instead of `slot.as_ref()`. Net effect:
// the compiler is now able to enforce the "one borrow at a time"
// contract that we used to assert by hand.
//
// If you ever need shared concurrent access (e.g. multi-device split
// per §6.5), the right path is an actor-pattern wrapper that owns the
// provider on one task and accepts commands over an `mpsc` channel —
// NOT to re-add `unsafe impl Sync`.

impl SinhronProvider {
    /// Open (or create) the MLS state DB at the given filesystem path.
    /// Runs `openmls_sqlite_storage`'s embedded refinery migrations on
    /// first use; subsequent opens are idempotent.
    ///
    /// The parent directory MUST exist — we don't `mkdir -p` here so
    /// the caller (Flutter app via `path_provider`) stays in control of
    /// where on-disk state lives.
    ///
    /// **T1.1 — SQLCipher encryption-at-rest.** `key` is the 32-byte
    /// raw AES-256 key (derived from BIP-39 phrase via HKDF in
    /// `sinhron_crypto::identity`, field `storage_key`). `None` opens
    /// the DB unencrypted — kept for dev / legacy migration only.
    /// Production callers MUST pass `Some(&storage_key)`.
    pub fn open(db_path: &Path, key: Option<&[u8; 32]>) -> Result<Self, ProviderError> {
        // Try to open with the provided key. If the file was sealed by a
        // PREVIOUS phrase's key (e.g. user generated a new phrase during
        // onboarding because the old one wasn't restored), SQLCipher will
        // return "file is not a database" when we try to use the conn.
        // Same tech-debt 2.16 pattern as sinhron_storage::open — auto-heal
        // by wiping the file and starting fresh. MLS group state is lost,
        // but identity is re-derived from phrase so the user is unblocked.
        let conn = Connection::open(db_path)
            .map_err(|e| ProviderError::OpenDb(format!("{db_path:?}: {e}")))?;
        match Self::new_with_connection(conn, key) {
            Ok(provider) => Ok(provider),
            Err(e) if format!("{e}").contains("file is not a database") => {
                // Wipe + retry from scratch.
                let _ = std::fs::remove_file(db_path);
                let _ = std::fs::remove_file(format!("{}-wal", db_path.display()));
                let _ = std::fs::remove_file(format!("{}-shm", db_path.display()));
                let fresh = Connection::open(db_path)
                    .map_err(|e| ProviderError::OpenDb(format!("retry {db_path:?}: {e}")))?;
                Self::new_with_connection(fresh, key)
            }
            Err(e) => Err(e),
        }
    }

    /// In-memory variant — used by unit tests and `examples/full_e2e.rs`,
    /// where DB state is intentionally ephemeral (each run starts fresh).
    /// Equivalent to `OpenMlsRustCrypto::default()` in lifetime semantics
    /// but exercises the same SQL code path as production.
    pub fn in_memory() -> Result<Self, ProviderError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| ProviderError::OpenDb(format!("in-memory: {e}")))?;
        // In-memory DBs don't persist anywhere so encryption is moot.
        Self::new_with_connection(conn, None)
    }

    fn new_with_connection(conn: Connection, key: Option<&[u8; 32]>) -> Result<Self, ProviderError> {
        // T1.1 — apply SQLCipher PRAGMA key before ANY other statement.
        // Must precede WAL pragma and refinery migrations alike,
        // otherwise SQLite reads page 0 as plaintext and tags the DB
        // as "not a database" on subsequent encrypted opens.
        if let Some(k) = key {
            let pragma = format!("PRAGMA key = \"x'{}'\";", hex::encode(k));
            conn.execute_batch(&pragma)
                .map_err(|e| ProviderError::Migration(format!("SQLCipher key: {e}")))?;
        }

        // Risk #1 fix — same WAL story as `sinhron_storage::apply_migrations`:
        // iOS can kill the process at any moment, default rollback-journal
        // mode risks half-written multi-statement transactions corrupting
        // the MLS state. WAL gives atomic-commit-via-rename + automatic
        // crash recovery. `synchronous = NORMAL` is the safe pairing.
        //
        // openmls_sqlite_storage uses INSERT OR REPLACE per-row, so each
        // call is single-statement → atomic by itself. WAL adds the
        // "future multi-statement writes stay atomic too" insurance and
        // the better concurrent-readers story we'll want for the call
        // path eventually.
        conn.execute_batch(
            "PRAGMA journal_mode = WAL; \
             PRAGMA synchronous = NORMAL;",
        )
        .map_err(|e| ProviderError::Migration(format!("WAL pragma: {e}")))?;

        let mut storage = SqliteStorageProvider::<JsonCodec, Connection>::new(conn);
        storage
            .run_migrations()
            .map_err(|e| ProviderError::Migration(e.to_string()))?;
        Ok(Self {
            crypto: RustCrypto::default(),
            storage,
        })
    }
}

impl OpenMlsProvider for SinhronProvider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = SqliteStorageProvider<JsonCodec, Connection>;

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }
}

#[derive(Debug, thiserror::Error)]
pub enum ProviderError {
    #[error("open db: {0}")]
    OpenDb(String),
    #[error("migration: {0}")]
    Migration(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_provider_opens_and_migrates() {
        let provider = SinhronProvider::in_memory().expect("in_memory provider");
        // Touch every accessor — guarantees the trait wiring isn't a
        // typo (would be a compile error too, but explicit is better).
        let _ = provider.crypto();
        let _ = provider.rand();
        let _ = provider.storage();
    }

    #[test]
    fn open_creates_or_reopens_file_db() {
        let dir = tempdir_in_tmp();
        let path = dir.join("mls-state.sqlite");

        let _p1 = SinhronProvider::open(&path, None).expect("create");
        assert!(path.exists(), "DB file must be created on first open");

        // Reopen — should run migrations idempotently and not fail.
        let _p2 = SinhronProvider::open(&path, None).expect("reopen");
    }

    /// Risk #1 regression — file-backed provider must enable WAL.
    /// In-memory DBs don't use WAL (no -wal file possible), so we test
    /// file-backed specifically.
    #[test]
    fn file_provider_enables_wal_journal() {
        let dir = tempdir_in_tmp();
        let path = dir.join("wal-check.sqlite");
        let _p = SinhronProvider::open(&path, None).expect("open");

        // Open a fresh independent connection to verify the on-disk
        // journal_mode persisted — proves the PRAGMA wasn't connection-
        // local fluke.
        let probe = Connection::open(&path).expect("probe");
        let mode: String = probe
            .query_row("PRAGMA journal_mode", [], |row| row.get(0))
            .expect("read journal_mode");
        assert_eq!(
            mode.to_ascii_lowercase(),
            "wal",
            "MLS provider must use WAL journal — got {mode:?}",
        );
    }

    /// Minimal tempdir helper — avoids pulling in the `tempfile` crate
    /// just for two tests. Cleans nothing up — test runs are in
    /// `target/`, periodic `cargo clean` is fine.
    fn tempdir_in_tmp() -> std::path::PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!(
            "sinhron-provider-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).expect("mkdir tempdir");
        dir
    }
}
