// Entry point. Boots the Rust Core (flutter_rust_bridge 2.11.1), opens
// the local SQLite database, then mounts [SinhronApp] inside a
// `ProviderScope` so the Riverpod tree is alive for all routes.
//
// Phase 2 progress:
//   - WU 67 · frb 2.11.1 hello-world
//   - WU 68 · sinhron_crypto step 1 (BIP-39 + X25519)
//   - WU 69 · sinhron_crypto step 2 (HKDF + Ed25519 + identity)
//   - WU 70 · MLS Alice↔Bob round-trip
//   - WU 71 · sinhron_storage (SQLite identity persistence)
//   - WU 72 · Riverpod 3.x scaffold (this file)
//   - WU 73 · chats/messages storage tables
//   - WU 73.1 · ChatView message persistence
//   - WU 73.2 · Boot diagnostics + identity-aware boot routing (this file)

import 'dart:async';
import 'dart:io' show File, HttpOverrides, Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'core/providers/core_providers.dart';
import 'core/background_connection.dart' show watchNetworkChanges;
import 'core/diag_log.dart';
import 'core/push.dart' show connectWithoutScreen;
import 'core/notification_reply.dart' show listenForNotificationReplies;
import 'core/push_wake.dart' show listenForPushWakes;
import 'core/server_dns.dart';
import 'core/session.dart';
import 'features/documents/document_share.dart' show sweepShareCopies;
import 'features/calls/active_call_provider.dart' show activeCallProvider;
import 'src/rust/api/simple.dart';
import 'src/rust/frb_generated.dart';

/// Cached Rust Core identification string. Read from the linked Rust
/// library at boot — never changes during a session. Available via the
/// `coreVersionProvider` Riverpod provider for new code; this global is
/// kept as a compatibility cache for the few spots that still read it
/// directly before the full Riverpod migration lands.
String coreVersionString = '';

// Report a problem (owner, 2026-10-22): every print also goes to the app's
// journal (lib/core/diag_log.dart), and so do uncaught errors.
Future<void> main() => runZonedGuarded(
  _main,
  (e, st) {
    // ignore: avoid_print
    print('[sinhron] uncaught: $e');
  },
  zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      DiagLog.instance.add(line);
      parent.print(zone, line);
    },
  ),
)!;

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // ADR-072 — every HttpClient (LiveKit signalling, the APK download) goes
  // to Rust's checked address when the phone's DNS answers wrong for our
  // host. First thing: dart:io makes the one WebSocket.connect client on
  // first use, from whatever is set then. Until Rust is up the lookup fails
  // and the usual connection is made.
  HttpOverrides.global = ServerDnsOverrides((host, port) => netDnsOverride(host: host, port: port));

  unawaited(DiagLog.instance.open());
  WidgetsBinding.instance.addObserver(_LifecycleToJournal());
  final flutterError = FlutterError.onError;
  FlutterError.onError = (d) {
    DiagLog.instance.add('[sinhron] flutter error: ${d.exceptionAsString()}');
    flutterError?.call(d);
  };

  // Phase 0 — Rust Core load. If this fails we can't do anything useful;
  // capture the error and let the UI show it.
  String? coreError;
  try {
    await RustLib.init();
    coreVersionString = coreVersion();
  } catch (e) {
    coreError = e.toString();
  }

  // Phase 1 — resolve the app documents directory (iOS sandbox / Android
  // internal storage). Failing this means we have no place to persist.
  // Both `sinhron.db` (chats/messages) and `sinhron-mls.sqlite` (MLS
  // group state — WU C6) live here.
  String dbPath = '';
  String mlsDbPath = '';
  String? docsDirError;
  if (coreError == null) {
    try {
      final docs = await getApplicationDocumentsDirectory();
      dbPath = '${docs.path}/sinhron.db';
      mlsDbPath = '${docs.path}/sinhron-mls.sqlite';
    } catch (e) {
      docsDirError = e.toString();
    }
  }

  // Phase 2 — open the local SQLite DB. The identity row (if any) is
  // read lazily on first `identityProvider` evaluation; we don't pre-load
  // here so cold-launch boot stays minimal.
  String? storageError;
  var storageLocked = false;
  if (coreError == null && docsDirError == null) {
    try {
      // ADR-021 — open the chats DB with the device key from the
      // Keychain (or plain before onboarding). A DB this phone can't
      // open is reported as locked — never erased.
      // KEYS-1 — started before the first unlock after a restart (a push):
      // wait for the Keychain instead of showing "no account".
      final boot = await whenKeychainOpens(
        () async => openStorageAtBoot(
          path: dbPath,
          fileExists: await File(dbPath).exists(),
          keys: KeychainDeviceKeyStore(),
          ops: StorageOps.ffi,
          leftovers: const [
            KeychainDeviceKeyStore(account: 'device-seed'),
            KeychainDeviceKeyStore(account: 'pending-phrase'),
          ],
        ),
      );
      storageLocked = boot == StorageBoot.locked;
    } catch (e) {
      storageError = e.toString();
    }
  }

  // Phase 3 — stat the MLS-state file (WU C6 proof). After first
  // bootstrap this file holds the openmls_sqlite_storage tables — group
  // ratchets, signature keys, etc. Size > 0 on the second cold-launch
  // is direct evidence that persistence is working. -1 = file absent
  // (pre-onboarding) or stat() failed (logged below, non-fatal).
  int mlsDbBytes = -1;
  if (coreError == null && docsDirError == null && mlsDbPath.isNotEmpty) {
    try {
      final f = File(mlsDbPath);
      if (await f.exists()) {
        mlsDbBytes = await f.length();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] could not stat mls-state file: $e');
    }
  }

  final diag = BootDiagnostics(
    coreVersion: coreVersionString,
    dbPath: dbPath,
    mlsDbPath: mlsDbPath,
    mlsDbBytes: mlsDbBytes,
    coreError: coreError,
    docsDirError: docsDirError,
    storageError: storageError,
    storageLocked: storageLocked,
  );

  // ignore: avoid_print
  print(
    '[sinhron] boot: ${diag.ok ? "ok" : "FAILED"} · core=$coreVersionString · '
    'db=$dbPath · mls=$mlsDbPath ($mlsDbBytes B) · coreErr=$coreError · '
    'docsErr=$docsDirError · storageErr=$storageError · locked=$storageLocked',
  );

  final container = ProviderContainer(overrides: [bootDiagnosticsProvider.overrideWithValue(diag)]);
  runApp(UncontrolledProviderScope(container: container, child: const SinhronApp()));
  watchNetworkChanges();
  unawaited(sweepShareCopies()); // storage-devices:7 — a shared file's plaintext copy
  // Android: the engine may run with no screen (a push woke it, "always
  // connected", the screen was swiped away) — no widget listens for call
  // invites then; the call machine must be up before the first connection
  // (bug 2026-10-19), else an invite is lost and nothing rings.
  if (Platform.isAndroid && diag.ok && !storageLocked) container.read(activeCallProvider);
  if (diag.ok && !storageLocked) unawaited(connectWithoutScreen(container));
  // ADR-057 — Google push may have started this engine (no screen).
  if (Platform.isAndroid) unawaited(listenForPushWakes(container, canConnect: diag.ok && !storageLocked));
  // ADR-066 — replies typed into notifications (both platforms).
  unawaited(listenForNotificationReplies(container, canConnect: diag.ok && !storageLocked));
}

/// Foreground / background in the journal — half the push and call
/// questions are "was the app open then?".
class _LifecycleToJournal with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // ignore: avoid_print
    print('[sinhron] app ${state.name}');
  }
}
