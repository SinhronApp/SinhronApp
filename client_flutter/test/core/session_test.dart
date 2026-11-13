// Session — ADR-021: device key in the Keychain, boot that never erases,
// unlock with the phrase, explicit erase.

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/background_connection.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/server_address.dart';
import 'package:sinhron/core/session.dart';

import 'settings_providers_test.dart' show MemoryStore;

/// A chats DB file: missing, plain, or sealed with a key.
class FakeDb {
  bool exists = false;
  String? sealedWith;
  bool erased = false;
  final calls = <String>[];

  StorageOps get ops => StorageOps(
    init: (path, keyHex) async {
      calls.add('init:$keyHex');
      if (!exists) {
        exists = true;
        sealedWith = keyHex.isEmpty ? null : keyHex;
        return;
      }
      if ((sealedWith ?? '') != keyHex) throw Exception('storage locked: wrong key');
    },
    rekey: (keyHex) async {
      calls.add('rekey:$keyHex');
      if (sealedWith != null) throw Exception('already encrypted');
      sealedWith = keyHex;
    },
    erase: (path) async {
      calls.add('erase');
      erased = true;
      exists = true;
      sealedWith = null;
    },
    keyHexFor: (secret) async => 'k($secret)',
  );
}

class FakeKeys implements DeviceKeyStore {
  FakeKeys([this.value]);
  String? value;

  /// KEYS-1 — the Keychain answers with an error, like iOS before the
  /// first unlock.
  PlatformException? readError;

  @override
  Future<String?> read() async => readError != null ? throw readError! : value;

  @override
  Future<void> write(String deviceKey) async => value = deviceKey;

  @override
  Future<void> delete() async => value = null;
}

const good = 'abandon ability able about above absent absorb abstract absurd abuse access accident';
const other = 'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong';

SecretOps secrets({String? storedFor}) => SecretOps(
  isValidPhrase: (p) => p.split(' ').length == 12,
  deviceKeyFor: (p) async => 'dk[$p]',
  fingerprintFor: (p) async => 'fp[$p]',
  storedFingerprint: () async => storedFor == null ? null : 'fp[$storedFor]',
  linkedBundleFor: (p, seed) async => 'sinhron-linked:v1:[$p|$seed]',
);

void main() {
  group('openStorageAtBoot', () {
    Future<StorageBoot> boot(FakeDb db, FakeKeys keys) =>
        openStorageAtBoot(path: 'db', fileExists: db.exists, keys: keys, ops: db.ops);

    test('fresh install, no key → opens plain', () async {
      final db = FakeDb();
      expect(await boot(db, FakeKeys()), StorageBoot.open);
      expect(db.sealedWith, isNull);
    });

    test('encrypted DB, no key → LOCKED and nothing erased (the old code wiped it)', () async {
      final db = FakeDb()
        ..exists = true
        ..sealedWith = 'k(dk)';
      expect(await boot(db, FakeKeys()), StorageBoot.locked);
      expect(db.erased, isFalse);
      expect(db.sealedWith, 'k(dk)');
    });

    test('device key opens the DB it sealed', () async {
      final db = FakeDb()
        ..exists = true
        ..sealedWith = 'k(dk)';
      expect(await boot(db, FakeKeys('dk')), StorageBoot.open);
      expect(db.calls, ['init:k(dk)']);
    });

    test('device key + still-plain DB → opened plain and sealed now', () async {
      final db = FakeDb()..exists = true;
      expect(await boot(db, FakeKeys('dk')), StorageBoot.open);
      expect(db.sealedWith, 'k(dk)');
    });

    test('stale Keychain key from an earlier install, no DB → key dropped, fresh plain DB', () async {
      final db = FakeDb();
      final keys = FakeKeys('old');
      expect(await boot(db, keys), StorageBoot.open);
      expect(keys.value, isNull);
      expect(db.sealedWith, isNull);
    });

    test('storage-devices:12 — reinstall: the previous owner\'s waiting 24 words and device seed are gone', () async {
      final db = FakeDb();
      final words = FakeKeys(good);
      final seed = FakeKeys('aa' * 32);
      await openStorageAtBoot(
        path: 'db',
        fileExists: false,
        keys: FakeKeys('old'),
        ops: db.ops,
        leftovers: [words, seed],
      );
      expect(words.value, isNull);
      expect(seed.value, isNull);
      // An update (the DB is there) keeps them: they are this account's.
      final kept = FakeKeys(good);
      await openStorageAtBoot(
        path: 'db',
        fileExists: true,
        keys: FakeKeys(),
        ops: (FakeDb()..exists = true).ops,
        leftovers: [kept],
      );
      expect(kept.value, good);
    });

    test('DB sealed with another key → locked', () async {
      final db = FakeDb()
        ..exists = true
        ..sealedWith = 'k(other)';
      expect(await boot(db, FakeKeys('dk')), StorageBoot.locked);
      expect(db.erased, isFalse);
    });
  });

  group('Session', () {
    late FakeDb db;
    late FakeKeys keys;
    late FakeKeys seeds;
    final pending = FakeKeys();
    late List<String> connected;
    late int shutdowns;
    late List<String> net;

    ProviderContainer container({bool locked = false, String? storedFor, String? bootError, bool noBoot = false}) {
      connected = [];
      shutdowns = 0;
      net = [];
      final c = ProviderContainer(
        overrides: [
          if (!noBoot)
            bootDiagnosticsProvider.overrideWithValue(
              BootDiagnostics(
                coreVersion: 't',
                dbPath: 'db',
                mlsDbPath: '',
                mlsDbBytes: -1,
                storageLocked: locked,
                storageError: bootError,
              ),
            ),
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          deviceKeyStoreProvider.overrideWithValue(keys),
          deviceSeedStoreProvider.overrideWithValue(seeds),
          pendingPhraseStoreProvider.overrideWithValue(pending),
          storageOpsProvider.overrideWithValue(db.ops),
          secretOpsProvider.overrideWithValue(secrets(storedFor: storedFor)),
          connectorProvider.overrideWithValue((secret, url) async => connected.add('$secret@$url')),
          reconnectorProvider.overrideWithValue((secret, url) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            connected.add('reopen $secret@$url');
            net.add('reopen');
          }),
          syncShutdownProvider.overrideWithValue(() async => shutdowns++),
          connectionSwitchProvider.overrideWithValue(
            ConnectionSwitch(close: () async => net.add('close'), open: () async {}),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      db = FakeDb()..exists = true;
      keys = FakeKeys();
      seeds = FakeKeys();
    });

    test('establish keeps the device key (not the phrase), connects with it and seals the DB', () async {
      final c = container();
      await c.read(sessionProvider).establish(good, serverUrl: 'ws://srv/v1/sync');
      expect(keys.value, 'dk[$good]');
      expect(connected, ['dk[$good]@ws://srv/v1/sync']);
      expect(connected.single.startsWith('$good@'), isFalse, reason: 'the phrase itself is never handed on');
      expect(db.sealedWith, 'k(dk[$good])');
      expect(await c.read(serverUrlProvider.future), 'ws://srv/v1/sync');
    });

    // Owner's phone, 2026-10-16: back from another app, two reconnects ran at
    // once and replaced each other's connection.
    test('reconnect: no key → false; calls at once share one reopen', () async {
      final c = container();
      expect(await c.read(sessionProvider).reconnect(), isFalse);
      keys.value = 'dk';
      final s = c.read(sessionProvider);
      final both = await Future.wait([s.reconnect(), s.reconnect()]);
      expect(both, [true, true]);
      expect(connected.where((e) => e.startsWith('reopen')).length, 1);
      await s.reconnect();
      expect(connected.where((e) => e.startsWith('reopen')).length, 2, reason: 'a later call opens again');
    });

    test('resume: no key → false; with key → connects once, force reconnects', () async {
      final c = container();
      expect(await c.read(sessionProvider).resume(), isFalse);
      keys.value = 'dk';
      expect(await c.read(sessionProvider).resume(), isTrue);
      await c.read(sessionProvider).resume();
      expect(connected.length, 1);
      await c.read(sessionProvider).resume(force: true);
      expect(connected.length, 2);
    });

    test('unlock a locked DB: garbage → invalid, other phrase → wrong (nothing stored), right → open', () async {
      db.sealedWith = 'k(dk[$good])';
      final c = container(locked: true);
      final s = c.read(sessionProvider);
      expect(await s.unlock('hello world'), UnlockResult.invalidPhrase);
      expect(await s.unlock(other), UnlockResult.wrongPhrase);
      expect(keys.value, isNull);
      expect(c.read(storageLockedProvider), isTrue);

      expect(await s.unlock('  ${good.toUpperCase()}  '), UnlockResult.ok, reason: 'case and spaces are forgiven');
      expect(keys.value, 'dk[$good]');
      expect(c.read(storageLockedProvider), isFalse);
      expect(connected, ['dk[$good]@$kDevServerUrl']);
    });

    test('reconnect mode: the phrase must belong to the identity on this phone', () async {
      final c = container(storedFor: good);
      final s = c.read(sessionProvider);
      expect(await s.unlock(other), UnlockResult.wrongPhrase);
      expect(keys.value, isNull);
      expect(await s.unlock(good), UnlockResult.ok);
      expect(keys.value, 'dk[$good]');
      expect(db.sealedWith, 'k(dk[$good])', reason: 'a plain DB gets sealed on the way');
    });

    // KEYS-1 — the launch could not read the key / open the chats: the first
    // screen is up, but a new account must not replace what is on the phone.
    group('KEYS-1', () {
      const closed = 'PlatformException(keychain, read failed: -25308, null, null)';

      test('launch failed → new account and sign-in by words refuse; key, seed and DB stay', () async {
        keys.value = 'dk-old';
        seeds.value = 'seed-old';
        db.sealedWith = 'k(dk-old)';
        final c = container(bootError: closed);
        final s = c.read(sessionProvider);
        await expectLater(s.establish(good, serverUrl: 'ws://srv/v1/sync'), throwsStateError);
        await expectLater(s.establishLinked(good), throwsStateError);
        expect(keys.value, 'dk-old');
        expect(seeds.value, 'seed-old');
        expect(db.sealedWith, 'k(dk-old)');
        expect(db.erased, isFalse);
        expect(connected, isEmpty);
      });

      // The refusal is only for a launch that SAID the data did not open: one
      // that reported nothing must not keep anyone out of the app.
      test('launch reported nothing (unknown) → sign-up and sign-in by words work as before', () async {
        final c = container(noBoot: true);
        expect(identical(c.read(bootDiagnosticsProvider), BootDiagnostics.unknown), isTrue);
        final s = c.read(sessionProvider);
        await s.establish(good, serverUrl: 'ws://srv/v1/sync');
        expect(keys.value, 'dk[$good]');
        keys.value = null;
        expect(await s.establishLinked(good), UnlockResult.ok);
      });

      test('Sign Out → sign in again by words works', () async {
        keys.value = 'dk-old';
        final c = container();
        final s = c.read(sessionProvider);
        await s.eraseAndStartOver();
        expect(await s.establishLinked(good), UnlockResult.ok);
        expect(keys.value, startsWith('sinhron-linked:v1:'));
      });

      test('Keychain unreadable at sign-up → nothing written', () async {
        keys.value = 'dk-old';
        keys.readError = PlatformException(code: 'keychain', message: 'read failed: -25300');
        final c = container();
        await expectLater(c.read(sessionProvider).establish(good), throwsA(isA<PlatformException>()));
        expect(keys.value, 'dk-old');
        expect(connected, isEmpty);
      });

      test('clean install → sign-up and sign-in by words work as before', () async {
        final c = container();
        await c.read(sessionProvider).establish(good, serverUrl: 'ws://srv/v1/sync');
        expect(keys.value, 'dk[$good]');
        keys.value = null;
        expect(await c.read(sessionProvider).establishLinked(good), UnlockResult.ok);
        expect(keys.value, startsWith('sinhron-linked:v1:'));
      });

      test('Sign Out / Delete account → a new account works, even in a launch that had failed', () async {
        for (final bootError in [null, closed]) {
          keys.value = 'dk-old';
          final c = container(bootError: bootError);
          final s = c.read(sessionProvider);
          await s.eraseAndStartOver();
          expect(keys.value, isNull);
          await s.establish(good, serverUrl: 'ws://srv/v1/sync');
          expect(keys.value, 'dk[$good]', reason: 'bootError=$bootError');
        }
      });

      test('whenKeychainOpens: waits out "closed until first unlock", passes other errors on', () async {
        final k = FakeKeys('dk')..readError = PlatformException(code: 'keychain', message: 'read failed: -25308');
        var tries = 0;
        final got = await whenKeychainOpens(() async {
          if (++tries == 3) k.readError = null;
          return k.read();
        }, wait: Duration.zero);
        expect(got, 'dk');
        expect(tries, 3);

        k.readError = PlatformException(code: 'keychain', message: 'read failed: -25300');
        await expectLater(whenKeychainOpens(k.read, wait: Duration.zero), throwsA(isA<PlatformException>()));
        await expectLater(
          whenKeychainOpens(() async => throw StateError('disk'), wait: Duration.zero),
          throwsStateError,
        );
      });
    });

    test('ADR-025/027 — sign in to an existing account: a fresh device seed, and only a bundle is kept', () async {
      final c = container();
      final s = c.read(sessionProvider);
      expect(await s.establishLinked('not a phrase'), UnlockResult.invalidPhrase);
      expect(seeds.value, isNull);
      expect(keys.value, isNull);
      expect(connected, isEmpty);

      expect(await s.establishLinked('  ${good.toUpperCase()} ', serverUrl: 'ws://srv/v1/sync'), UnlockResult.ok);
      expect(seeds.value, matches(RegExp(r'^[0-9a-f]{64}$')), reason: '32 random bytes, hex');
      final bundle = 'sinhron-linked:v1:[$good|${seeds.value}]';
      expect(keys.value, bundle, reason: 'no identity key on this device (ADR-027)');
      expect(connected, ['$bundle@ws://srv/v1/sync']);

      // A second sign-in on this phone keeps its device key (same device).
      final seed = seeds.value;
      await s.establishLinked(good);
      expect(seeds.value, seed);
    });

    test('QR pairing hands over the account secret: no phrase, used as the device key as is', () async {
      final c = container();
      const secret = 'sinhron-device-key:v1:abcdef';
      expect(await c.read(sessionProvider).establishLinked(secret), UnlockResult.ok);
      expect(keys.value, secret, reason: 'already in device-key form');
      expect(seeds.value, hasLength(64));
      expect(connected, ['$secret@$kDevServerUrl']);
    });

    test('ADR-027 — unlocking a linked device rebuilds its bundle (same DB key), not the identity key', () async {
      seeds.value = 'ab' * 32;
      final bundle = 'sinhron-linked:v1:[$good|${'ab' * 32}]';
      db.sealedWith = 'k($bundle)';
      final c = container(locked: true);
      expect(await c.read(sessionProvider).unlock(good), UnlockResult.ok);
      expect(keys.value, bundle);
    });

    test('device seeds are random', () {
      expect(newDeviceSeedHex(), isNot(newDeviceSeedHex()));
      expect(newDeviceSeedHex(), hasLength(64));
    });

    test('erase and start over: DB erased, MLS client closed, key removed, unlocked', () async {
      db.sealedWith = 'k(x)';
      keys.value = 'dk';
      seeds.value = 'ab' * 32;
      pending.value = 'words waiting to be saved';
      final c = container(locked: true);
      await c.read(sessionProvider).eraseAndStartOver();
      expect(pending.value, isNull, reason: 'ADR-059 — unsaved words leave with the account');
      expect(db.erased, isTrue);
      expect(keys.value, isNull);
      expect(seeds.value, isNull, reason: 'a linked device forgets its own key too');
      expect(shutdowns, 1);
      expect(c.read(storageLockedProvider), isFalse);
      expect(net, ['close', 'close'], reason: 'DART-1 — the old account goes offline; again once its key is gone');
    });

    test('DART-1 — sign out during a reconnect: the connection closes after it, not before', () async {
      keys.value = 'dk';
      final s = container().read(sessionProvider);
      final reconnect = s.reconnect();
      await s.eraseAndStartOver();
      await reconnect;
      expect(net, ['reopen', 'close', 'close'], reason: 'closed again after the device key is deleted');
      expect(keys.value, isNull);
    });
  });
}
