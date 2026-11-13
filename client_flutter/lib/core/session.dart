// Session — ADR-021: staying signed in across restarts.
//
// The recovery phrase is never stored (spec §6.8). What the phone keeps
// instead is the *device key* — the BIP-39 seed derived from the phrase
// (one-way) — in the iOS Keychain, this device only. With it the app,
// on every launch:
//   1. opens the encrypted chats DB (key derived from the device key),
//   2. reconnects to the server (MLS state + WS auth derive from it too).
// Without it (Keychain wiped, restored phone) the data stays encrypted
// and the user unlocks it with the phrase — nothing is erased unless
// they choose "Erase and start over".
//
// Before this, a restart opened the DB without a key, the storage layer
// "self-healed" by deleting it, and the app sent the user through
// onboarding again with a brand-new phrase (tech-debt 2.16 / 2.4).

import 'dart:io' show File;
import 'dart:math' show Random;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/documents/document_share.dart' show sweepShareCopies;
import '../src/rust/api/simple.dart' as core;
import 'background_connection.dart' show connectionSwitchProvider;
import 'diag_log.dart';
import 'pairing.dart';
import 'providers/chat_providers.dart';
import 'providers/core_providers.dart';
import 'providers/settings_providers.dart';
import 'push.dart' show pushPlatformProvider, pushServiceProvider;
import 'server_address.dart';
import 'services/net_service.dart';

/// The server this phone signed up with (settings `server_url`). ADR-032:
/// chosen in onboarding — typed or scanned — never compiled in. Empty
/// until then (a dev build may prefill it with `SINHRON_WS_URL`).
final serverUrlProvider = AsyncNotifierProvider<StringSetting, String>(
  () => StringSetting('server_url', kDevServerUrl),
);

/// Where the device key lives. Native side: `ios/Runner/AppDelegate.swift`
/// (channel `dev.sinhron/keychain`, `AfterFirstUnlockThisDeviceOnly`).
abstract class DeviceKeyStore {
  Future<String?> read();
  Future<void> write(String deviceKey);
  Future<void> delete();
}

class KeychainDeviceKeyStore implements DeviceKeyStore {
  const KeychainDeviceKeyStore({this.account = 'device-key'});

  /// Keychain item name (`kSecAttrAccount`).
  final String account;

  static const _channel = MethodChannel('dev.sinhron/keychain');

  @override
  Future<String?> read() async {
    try {
      return await _channel.invokeMethod<String>('read', {'account': account});
    } on MissingPluginException {
      return null; // desktop / tests — no Keychain
    }
  }

  @override
  Future<void> write(String deviceKey) async {
    try {
      await _channel.invokeMethod<void>('write', {'account': account, 'value': deviceKey});
    } on MissingPluginException {
      // desktop / tests
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _channel.invokeMethod<void>('delete', {'account': account});
    } on MissingPluginException {
      // desktop / tests
    }
  }
}

final deviceKeyStoreProvider = Provider<DeviceKeyStore>((ref) => const KeychainDeviceKeyStore());

/// ADR-025 — on a *linked* device (signed in with an existing phrase):
/// this device's own key seed (hex), the key its MLS leaf signs with.
/// Absent on the account's first device. Same Keychain rules as the
/// device key: this device only, never backed up.
final deviceSeedStoreProvider = Provider<DeviceKeyStore>((ref) => const KeychainDeviceKeyStore(account: 'device-seed'));

/// ADR-059 — the 24 words of a new account while nobody has saved them
/// yet ("Later" at sign-up). This device only, never backed up; deleted
/// on the first save (`lib/core/account_access.dart`) and on sign-out.
final pendingPhraseStoreProvider = Provider<DeviceKeyStore>(
  (ref) => const KeychainDeviceKeyStore(account: 'pending-phrase'),
);

/// 32 random bytes as hex — a new linked device's own key.
String newDeviceSeedHex([Random? rng]) {
  final r = rng ?? Random.secure();
  return List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Is there a device key on this phone? Invalidated by [Session].
final hasDeviceKeyProvider = FutureProvider<bool>(
  (ref) async => (await ref.read(deviceKeyStoreProvider).read()) != null,
);

/// The storage calls [openStorageAtBoot] / [Session] need — the FFI in
/// the app, fakes in tests.
class StorageOps {
  const StorageOps({required this.init, required this.rekey, required this.erase, required this.keyHexFor});

  final Future<void> Function(String path, String keyHex) init;
  final Future<void> Function(String keyHex) rekey;
  final Future<void> Function(String path) erase;
  final Future<String> Function(String secret) keyHexFor;

  static final ffi = StorageOps(
    init: (path, keyHex) => core.storageInit(path: path, keyHex: keyHex),
    rekey: (keyHex) => core.storageRekey(keyHex: keyHex),
    erase: (path) => core.storageErase(path: path),
    keyHexFor: (secret) => core.deriveStorageKeyHex(phrase: secret),
  );
}

final storageOpsProvider = Provider<StorageOps>((ref) => StorageOps.ffi);

/// The key-derivation calls [Session] needs — Rust FFI in the app,
/// fakes in tests.
class SecretOps {
  const SecretOps({
    required this.isValidPhrase,
    required this.deviceKeyFor,
    required this.fingerprintFor,
    required this.storedFingerprint,
    required this.linkedBundleFor,
  });

  final bool Function(String phrase) isValidPhrase;
  final Future<String> Function(String phrase) deviceKeyFor;
  final Future<String> Function(String phrase) fingerprintFor;

  /// Fingerprint of the identity saved on this phone, or null.
  final Future<String?> Function() storedFingerprint;

  /// ADR-027 — this device's linked-device bundle from the phrase and its
  /// own key seed (the identity key isn't kept).
  final Future<String> Function(String phrase, String deviceSeedHex) linkedBundleFor;

  static final ffi = SecretOps(
    isValidPhrase: (p) => core.validateRecoveryPhrase(phrase: p),
    deviceKeyFor: (p) => core.deviceKeyFromPhrase(phrase: p),
    fingerprintFor: (p) => core.deriveIdentityFingerprint(phrase: p),
    storedFingerprint: () async => (await core.storageLoadIdentity())?.fingerprint,
    linkedBundleFor: (p, seed) async => core.linkedBundleFromPhrase(phrase: p, deviceSeedHex: seed),
  );
}

final secretOpsProvider = Provider<SecretOps>((ref) => SecretOps.ffi);

/// Starts the network with a secret (phrase or device key) — NetService
/// in the app, a recorder in tests.
typedef Connector = Future<void> Function(String secret, String url);

final connectorProvider = Provider<Connector>(
  (ref) =>
      (secret, url) => ref.read(netServiceProvider).startFromPhrase(phrase: secret, url: url),
);

/// Opens the connection again after the background — only the WS when the
/// sync client is already up (`NetService.reopen`); a recorder in tests.
final reconnectorProvider = Provider<Connector>(
  (ref) =>
      (secret, url) => ref.read(netServiceProvider).reopen(phrase: secret, url: url),
);

/// Closes the MLS client before its file is deleted.
final syncShutdownProvider = Provider<Future<void> Function()>(
  (ref) =>
      () async => core.syncShutdown(),
);

bool isStorageLocked(Object e) => e.toString().contains('storage locked');

/// KEYS-1 — the Keychain is closed for now, not empty: the phone was
/// restarted and nobody has unlocked it yet (iOS errSecInteractionNotAllowed,
/// -25308 — `AppDelegate.swift` reports "read failed: -25308").
bool isKeychainClosedForNow(Object e) => e is PlatformException && (e.message ?? '').contains('-25308');

/// KEYS-1 — runs [open] again while the Keychain is closed for now, so a
/// launch before the first unlock waits for the key instead of deciding
/// "no account here". Any other error propagates at once.
Future<T> whenKeychainOpens<T>(Future<T> Function() open, {Duration wait = const Duration(seconds: 1)}) async {
  for (;;) {
    try {
      return await open();
    } catch (e) {
      if (!isKeychainClosedForNow(e)) rethrow;
      await Future<void>.delayed(wait);
    }
  }
}

enum StorageBoot {
  /// Opened (encrypted with the device key, or plain before onboarding).
  open,

  /// Encrypted and no key here opens it → unlock with the phrase.
  locked,
}

/// Opens the chats DB at launch. Decision table (ADR-021):
///   • device key + file exists → open with its key; if the file is
///     still plain (onboarding never sealed it) open plain and seal it;
///   • device key but no file → a stale Keychain entry from an earlier
///     install (iOS keeps the Keychain across reinstalls) — drop it,
///     start plain;
///   • no device key → open plain; an encrypted file → [StorageBoot.locked].
/// No file = a new install: [leftovers] (an earlier install's waiting 24
/// words, device seed — storage-devices:12) go too, before anyone reads them.
/// Never erases the DB. Other errors propagate (boot diagnostics).
Future<StorageBoot> openStorageAtBoot({
  required String path,
  required bool fileExists,
  required DeviceKeyStore keys,
  required StorageOps ops,
  List<DeviceKeyStore> leftovers = const [],
}) async {
  if (!fileExists) {
    for (final s in leftovers) {
      await s.delete();
    }
  }
  var deviceKey = await keys.read();
  if (deviceKey != null && !fileExists) {
    await keys.delete();
    deviceKey = null;
  }
  if (deviceKey != null) {
    final keyHex = await ops.keyHexFor(deviceKey);
    try {
      await ops.init(path, keyHex);
      return StorageBoot.open;
    } catch (e) {
      if (!isStorageLocked(e)) rethrow;
    }
    try {
      await ops.init(path, '');
    } catch (e) {
      if (isStorageLocked(e)) return StorageBoot.locked; // encrypted with another key
      rethrow;
    }
    try {
      await ops.rekey(keyHex);
    } catch (_) {
      // Stays plain this launch; the next one tries again.
    }
    return StorageBoot.open;
  }
  try {
    await ops.init(path, '');
    return StorageBoot.open;
  } catch (e) {
    if (isStorageLocked(e)) return StorageBoot.locked;
    rethrow;
  }
}

/// Is the chats DB still locked this session? Starts from the boot
/// result; [Session.unlock] / [Session.eraseAndStartOver] clear it.
class StorageLockedNotifier extends Notifier<bool> {
  @override
  bool build() => ref.read(bootDiagnosticsProvider).storageLocked;

  void set(bool v) => state = v;
}

final storageLockedProvider = NotifierProvider<StorageLockedNotifier, bool>(StorageLockedNotifier.new);

enum UnlockResult { ok, invalidPhrase, wrongPhrase }

/// What the app does with the user's secret.
class Session {
  Session(this._ref);
  final Ref _ref;
  bool _resumed = false;
  bool _erased = false; // the person erased this phone's data in this run

  DeviceKeyStore get _keys => _ref.read(deviceKeyStoreProvider);
  StorageOps get _ops => _ref.read(storageOpsProvider);
  SecretOps get _secrets => _ref.read(secretOpsProvider);
  Connector get _connect => _ref.read(connectorProvider);

  Future<String> _url() async {
    try {
      return await _ref.read(serverUrlProvider.future);
    } catch (_) {
      return kDevServerUrl;
    }
  }

  /// KEYS-1 — throws when this launch said outright that the chats / the key
  /// on this phone could not be opened (and the person has not erased them
  /// since): nothing of a new account may be written over them. A launch
  /// that reported nothing ([BootDiagnostics.unknown]) is let through as
  /// before — the refusal must never be what keeps people out.
  void refuseOverUnreadData() {
    final boot = _ref.read(bootDiagnosticsProvider);
    if (!identical(boot, BootDiagnostics.unknown) && boot.storageError != null && !_erased) {
      throw StateError('this launch could not open the data on this phone — not replacing it');
    }
  }

  /// End of onboarding: keep the device key, connect, seal the DB.
  ///
  /// KEYS-1 — refuses (throws, nothing written) when this launch could not
  /// open what is already on the phone, or the Keychain can't be read: a
  /// new account must never replace a key and chats that only failed to
  /// load. The next launch tries again; "Erase and start over" / Sign Out
  /// stay the only ways to drop the old data.
  Future<void> establish(String phrase, {String? serverUrl}) async {
    refuseOverUnreadData();
    await _keys.read(); // throws while the Keychain is unreadable — before anything is written
    // QR pairing hands over the account secret already in device-key form.
    final deviceKey = isAccountSecret(phrase) ? phrase : await _secrets.deviceKeyFor(phrase);
    await _keys.write(deviceKey);
    _ref.invalidate(hasDeviceKeyProvider);
    final url = serverUrl ?? await _url();
    try {
      await _ref.read(serverUrlProvider.notifier).save(url);
    } catch (_) {}
    try {
      await _connect(deviceKey, url);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] connect failed: $e — continuing offline');
    }
    try {
      await _ops.rekey(await _ops.keyHexFor(deviceKey));
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] sealing the chats DB failed: $e — next launch retries');
    }
    _resumed = true;
  }

  /// ADR-025 — "I already have an account": the phrase of an account
  /// that lives on another device. This phone becomes one more device of
  /// that person — its own MLS key (a fresh seed in the Keychain) with a
  /// certificate from the identity key — never a second copy of the
  /// first device. Its chats arrive when another device of theirs is
  /// online (device sync); history comes from that device.
  ///
  /// ADR-027 — the identity key stays on the first device only: the
  /// phrase is used once to make this device's linked-device bundle, and
  /// only the bundle is kept. A bundle delivered by QR pairing is taken
  /// as is (no phrase typed at all).
  Future<UnlockResult> establishLinked(String phrase, {String? serverUrl}) async {
    final secret = phrase.trim();
    final clean = isAccountSecret(secret) ? secret : secret.toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!isAccountSecret(clean) && !_secrets.isValidPhrase(clean)) return UnlockResult.invalidPhrase;
    // KEYS-1 — same refusal as [establish], before the device seed is made.
    refuseOverUnreadData();
    final seeds = _ref.read(deviceSeedStoreProvider);
    var seed = await seeds.read();
    if (seed == null) {
      seed = newDeviceSeedHex();
      await seeds.write(seed);
    }
    final keep = isAccountSecret(clean) ? clean : await _secrets.linkedBundleFor(clean, seed);
    await establish(keep, serverUrl: serverUrl);
    return UnlockResult.ok;
  }

  /// Every launch (and "Reconnect"): connect with the stored device key.
  /// Returns false when there's no key — the UI asks for the phrase.
  Future<bool> resume({bool force = false}) async {
    if (_resumed && !force) return true;
    final deviceKey = await _keys.read();
    if (deviceKey == null) return false;
    _resumed = true;
    await _connect(deviceKey, await _url());
    return true;
  }

  /// Back from the background, or "no connection" on an action: open the
  /// connection again with the stored device key — the fast path (only the
  /// WS) when the sync client is up. Calls while one runs share it: two at
  /// once used to replace each other's connection (the server saw sessions
  /// of 80 ms — owner's phone, 2026-10-16). False when there's no key.
  Future<bool> reconnect() => _reconnecting ??= _reconnectOnce();

  Future<bool>? _reconnecting;

  Future<bool> _reconnectOnce() async {
    try {
      final deviceKey = await _keys.read();
      if (deviceKey == null) return false;
      _resumed = true;
      await _ref.read(reconnectorProvider)(deviceKey, await _url());
      return true;
    } finally {
      _reconnecting = null;
    }
  }

  /// Unlock screen. Checks the phrase against what's on the phone: a
  /// locked DB must open with it; an open one must hold the identity it
  /// derives. Only then is the device key stored and the app connected.
  Future<UnlockResult> unlock(String phrase) async {
    final clean = phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!_secrets.isValidPhrase(clean)) return UnlockResult.invalidPhrase;
    // ADR-027 — a linked device (its own key seed survived) rebuilds its
    // bundle from the phrase: the same bundle, so the same DB key; the
    // identity key is still not kept. The first device keeps its key.
    final seed = await _ref.read(deviceSeedStoreProvider).read();
    final deviceKey = seed != null ? await _secrets.linkedBundleFor(clean, seed) : await _secrets.deviceKeyFor(clean);
    final boot = _ref.read(bootDiagnosticsProvider);
    if (_ref.read(storageLockedProvider)) {
      try {
        await _ops.init(boot.dbPath, await _ops.keyHexFor(deviceKey));
      } catch (e) {
        if (isStorageLocked(e)) return UnlockResult.wrongPhrase;
        rethrow;
      }
    } else {
      final stored = await _secrets.storedFingerprint();
      if (stored != null && stored != await _secrets.fingerprintFor(clean)) {
        return UnlockResult.wrongPhrase;
      }
      try {
        await _ops.rekey(await _ops.keyHexFor(deviceKey)); // a plain DB gets sealed now
      } catch (_) {}
    }
    await _keys.write(deviceKey);
    _ref.read(storageLockedProvider.notifier).set(false);
    _ref.invalidate(hasDeviceKeyProvider);
    _ref.invalidate(identityProvider);
    _ref.invalidate(chatsProvider);
    await resume(force: true);
    return UnlockResult.ok;
  }

  /// "Erase and start over" on the unlock screen, and Sign Out: the
  /// local DB, the MLS state and the device key go; onboarding follows.
  Future<void> eraseAndStartOver() async {
    final boot = _ref.read(bootDiagnosticsProvider);
    // storage-devices:16 — the server stops pushing here (best effort).
    try {
      await _ref.read(pushServiceProvider).stopOnServer();
    } catch (_) {}
    // DART-1 — the old account goes offline: a reconnect under way ends
    // first (it would log in again after the wipe), then the WS closes.
    try {
      await _reconnecting;
    } catch (_) {}
    try {
      await _ref.read(connectionSwitchProvider).close();
    } catch (_) {}
    try {
      await _ref.read(syncShutdownProvider)();
    } catch (_) {}
    await _ops.erase(boot.dbPath);
    if (boot.mlsDbPath.isNotEmpty) {
      try {
        final f = File(boot.mlsDbPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await _keys.delete();
    // A reconnect that slipped in while the key was still here (network
    // change, back from the background) is closed too: the old account is gone.
    try {
      await _ref.read(connectionSwitchProvider).close();
    } catch (_) {}
    await _ref.read(deviceSeedStoreProvider).delete();
    await _ref.read(pendingPhraseStoreProvider).delete();
    await sweepShareCopies(); // storage-devices:7 — e.g. the recovery sheet PNG
    await DiagLog.instance.clear(); // storage-devices:15 — the old account's journal
    // ADR-056 — the notification extension's keys and names go too.
    try {
      await _ref.read(pushPlatformProvider).clearNotificationData();
    } catch (_) {}
    _resumed = false;
    _erased = true;
    _ref.read(storageLockedProvider.notifier).set(false);
    _ref.read(deviceRemovedProvider.notifier).set(false); // a fresh start
    _ref.invalidate(hasDeviceKeyProvider);
    _ref.invalidate(identityProvider);
    _ref.invalidate(chatsProvider);
  }
}

final sessionProvider = Provider<Session>((ref) => Session(ref));
