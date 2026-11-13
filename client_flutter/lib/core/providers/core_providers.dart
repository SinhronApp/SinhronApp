// Core providers — Riverpod 3.0 surface over `sinhron_core` FFI.
//
// Conventions:
//   - One file per logical area in `lib/core/providers/`. Phase 2
//     stays small so we keep everything here.
//   - Providers are top-level `final` constants — no codegen yet
//     (`riverpod_annotation` may come later if the surface grows).
//   - Async work happens in `FutureProvider` / `StreamProvider`;
//     synchronous Rust calls (e.g. `coreVersion()`) wrap into plain
//     `Provider<T>`.
//   - `coreVersionString` global in `main.dart` is kept as a compatibility
//     cache for the few legacy spots that still read it directly. New
//     code should use `coreVersionProvider`.
//   - `persistedFingerprint` global has been REMOVED — read fingerprint
//     via `identityFingerprintProvider` instead (it watches `identityProvider`
//     and exposes just the string field).
//
// See ADR-009 for the rationale on Riverpod 3.x without codegen.

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat_list/chat_data.dart';
import 'chat_providers.dart';
import '../../src/rust/api/simple.dart' as core;

/// Captures what happened during app boot — Rust Core load, SQLite open,
/// docs-dir resolution — so the UI can surface any failure visibly rather
/// than silently continuing in volatile mode. Populated by `main.dart` and
/// overridden into the root [ProviderScope].
@immutable
class BootDiagnostics {
  /// Resolved Rust Core identification string (e.g. `sinhron_core 0.1.0
  /// · frb 2.11.1 · rustc 1.94.1`). Empty if [coreError] is set.
  final String coreVersion;

  /// Final absolute path the storage layer was opened against, or empty
  /// if [storageError] / [docsDirError] is set.
  final String dbPath;

  /// Path to the SQLite file that holds MLS group state
  /// (`openmls_sqlite_storage` — WU C6). Computed in `main.dart`
  /// alongside `dbPath` and used by `NetService.startFromPhrase` so the
  /// boot snapshot owns the layout instead of two places deciding
  /// independently. Empty if [docsDirError] is set.
  final String mlsDbPath;

  /// Size of the MLS-state file on disk at boot, in bytes. `-1` means
  /// either the file doesn't exist yet (pre-first-bootstrap) or the
  /// `stat()` itself failed. The Settings → Diagnostics block reads
  /// this to prove MLS persistence is actually working after the second
  /// cold-launch ("mls: file present · 12.3 KiB").
  final int mlsDbBytes;

  /// Error from `RustLib.init()` / `coreVersion()`. Null on success.
  final String? coreError;

  /// Error from `path_provider.getApplicationDocumentsDirectory()`. Null
  /// when the path was obtained.
  final String? docsDirError;

  /// Error from `storage_init(path)`. Null on success.
  final String? storageError;

  /// ADR-021 — the chats DB is encrypted and no device key on this phone
  /// opens it: the app shows the unlock screen (nothing was erased).
  final bool storageLocked;

  const BootDiagnostics({
    required this.coreVersion,
    required this.dbPath,
    required this.mlsDbPath,
    required this.mlsDbBytes,
    this.coreError,
    this.docsDirError,
    this.storageError,
    this.storageLocked = false,
  });

  /// True when every step succeeded — the app is running with persistent
  /// storage.
  bool get ok => coreError == null && docsDirError == null && storageError == null;

  /// Sentinel used when no override is set (e.g. widget tests). Reports
  /// the failure state honestly so tests don't accidentally assume real
  /// storage.
  static const unknown = BootDiagnostics(
    coreVersion: '',
    dbPath: '',
    mlsDbPath: '',
    mlsDbBytes: -1,
    storageError: 'no boot diagnostics override — main.dart never ran',
  );
}

/// Boot status surface. `main.dart` overrides this with the real value
/// before mounting the app tree.
final bootDiagnosticsProvider = Provider<BootDiagnostics>((ref) => BootDiagnostics.unknown);

/// Synchronous Rust version string. Cached at boot — never changes
/// during a session.
final coreVersionProvider = Provider<String>((ref) => core.coreVersion());

/// User's persisted identity, loaded from SQLite at app startup.
/// `null` = fresh install / pre-onboarding. The future resolves on
/// first read; subsequent reads return the cached value.
///
/// On phrase save (RecoveryPhraseScreen.onSaved), the caller should
/// `ref.invalidate(identityProvider)` so the next read picks up the
/// new row.
final identityProvider = FutureProvider<core.StoredIdentitySummary?>((ref) async {
  return await core.storageLoadIdentity();
});

/// Derived: just the fingerprint string, or null if no identity yet.
/// Used by screens that show a short identity preview without needing
/// the full struct.
final identityFingerprintProvider = Provider<String?>((ref) {
  final id = ref.watch(identityProvider);
  return id.whenOrNull(data: (v) => v?.fingerprint);
});

/// Number of chats waiting for you — the Chats-tab badge and the app
/// icon badge (UI backlog §8 item 58). Like Telegram: muted and
/// archived chats don't count, "Mark as unread" does.
final unreadChatsCountProvider = Provider<int>((ref) => unreadChatsCount(ref.watch(chatsProvider).value ?? const []));

int unreadChatsCount(List<ChatPreview> chats) => chats.where((c) => c.hasUnread && !c.muted && !c.archived).length;
