// ADR-059 — keeping access to the account: the words wait on this phone
// only until they're saved; the reminder; the password-manager seam.

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/account_access.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/session.dart';

import 'session_test.dart' show FakeKeys;
import 'settings_providers_test.dart' show MemoryStore;

/// The phone's password manager, faked: answers with [next] and records.
class FakeVault implements PasswordVault {
  FakeVault({this.next = VaultResult.saved, this.stored, this.available = true});
  VaultResult next;
  String? stored;
  @override
  final bool available;
  final saves = <({String account, String secret})>[];

  @override
  Future<VaultResult> save({required String account, required String secret}) async {
    saves.add((account: account, secret: secret));
    if (next == VaultResult.saved) stored = secret;
    return next;
  }

  @override
  Future<String?> pick() async => stored;
}

const words24 =
    'abandon ability able about above absent absorb abstract absurd abuse access accident '
    'account accuse achieve acid acoustic acquire across act action actor actress actual';

final t0 = DateTime(2026, 10, 18, 12);

ProviderContainer container({
  MemoryStore? store,
  FakeKeys? pending,
  FakeVault? vault,
  DateTime Function()? now,
  String? bootError,
}) {
  final c = ProviderContainer(
    overrides: [
      if (bootError != null)
        bootDiagnosticsProvider.overrideWithValue(
          BootDiagnostics(coreVersion: 't', dbPath: 'db', mlsDbPath: '', mlsDbBytes: -1, storageError: bootError),
        ),
      settingsStoreProvider.overrideWithValue(store ?? MemoryStore()),
      pendingPhraseStoreProvider.overrideWithValue(pending ?? FakeKeys()),
      passwordVaultProvider.overrideWithValue(vault ?? FakeVault()),
      accessClockProvider.overrideWithValue(now ?? () => t0),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('old accounts and phones signed in with the words: nothing to nag about', () async {
    final c = container();
    final s = await c.read(accountAccessProvider.future);
    expect(s.unknown, isTrue);
    expect(s.needsSaving, isFalse);
    expect(s.reminderDue(t0.add(const Duration(days: 30))), isFalse);
  });

  test('KEYS-1 — the launch did not open the data: "Later" refuses, the earlier waiting words stay', () async {
    final pending = FakeKeys('the earlier account words');
    final c = container(pending: pending, bootError: 'keychain read failed: -25300');
    await c.read(accountAccessProvider.future);
    await expectLater(c.read(accountAccessProvider.notifier).keepForLater(words24), throwsStateError);
    expect(pending.value, 'the earlier account words');
  });

  test('"Later" keeps the words on this phone and reminds in a day', () async {
    final store = MemoryStore();
    final pending = FakeKeys();
    final c = container(store: store, pending: pending);
    await c.read(accountAccessProvider.future);
    await c.read(accountAccessProvider.notifier).keepForLater(words24);

    expect(pending.value, words24);
    final s = c.read(accountAccessProvider).value!;
    expect(s.needsSaving, isTrue);
    expect(s.reminderDue(t0), isFalse, reason: 'not the same day');
    expect(s.reminderDue(t0.add(const Duration(hours: 25))), isTrue);
    expect(await c.read(accountAccessProvider.notifier).pendingWords(), words24);
  });

  test('"Later" on the card: next reminder a week on', () async {
    final store = MemoryStore();
    var now = t0;
    final c = container(store: store, pending: FakeKeys(words24), now: () => now);
    await c.read(accountAccessProvider.future);
    now = t0.add(const Duration(days: 2));
    await c.read(accountAccessProvider.notifier).remindLater();
    final s = c.read(accountAccessProvider).value!;
    expect(s.reminderDue(now.add(const Duration(days: 6))), isFalse);
    expect(s.reminderDue(now.add(const Duration(days: 7))), isTrue);
  });

  test('saving deletes the words from the phone and remembers how and when', () async {
    final store = MemoryStore();
    final pending = FakeKeys(words24);
    final c = container(store: store, pending: pending);
    await c.read(accountAccessProvider.future);
    await c.read(accountAccessProvider.notifier).markSaved(AccessWay.paper);

    expect(pending.value, isNull);
    expect(store.map[kAccessSavedKey], 'paper:${t0.millisecondsSinceEpoch}');
    final s = c.read(accountAccessProvider).value!;
    expect(s.needsSaving, isFalse);
    expect(s.savedWay, AccessWay.paper);
    expect(s.savedAt, t0);
    expect(s.reminderDue(t0.add(const Duration(days: 365))), isFalse);
  });

  test('Settings "Save to Passwords": the waiting words, a recognisable login', () async {
    final pending = FakeKeys(words24);
    final vault = FakeVault();
    final c = container(pending: pending, vault: vault);
    await c.read(accountAccessProvider.future);
    final r = await c
        .read(accountAccessProvider.notifier)
        .saveWaitingToPasswords(name: 'Вера', fingerprint: '9a3e 4d12 8b71 c0f5');

    expect(r, VaultResult.saved);
    expect(vault.saves.single.secret, words24);
    expect(vault.saves.single.account, 'Вера · 9a3e4d12');
    expect(pending.value, isNull);
    expect(c.read(accountAccessProvider).value!.savedWay, AccessWay.passwords);
  });

  test('storage-devices:2 — on iPhone the words go to iCloud Keychain, not a website password', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final c = container(pending: FakeKeys(words24), vault: FakeVault());
    await c.read(accountAccessProvider.future);
    await c.read(accountAccessProvider.notifier).saveWaitingToPasswords(name: 'Вера', fingerprint: '9a3e4d12');
    expect(c.read(accountAccessProvider).value!.savedWay, AccessWay.keychain);
  });

  test('cancelled or failed save keeps the words waiting', () async {
    for (final next in [VaultResult.cancelled, VaultResult.failed]) {
      final pending = FakeKeys(words24);
      final c = container(
        pending: pending,
        vault: FakeVault(next: next),
      );
      await c.read(accountAccessProvider.future);
      expect(await c.read(accountAccessProvider.notifier).saveWaitingToPasswords(name: '', fingerprint: ''), next);
      expect(pending.value, words24);
      expect(c.read(accountAccessProvider).value!.needsSaving, isTrue);
    }
  });

  test('labels and dates', () {
    expect(vaultAccountLabel('', ''), 'Sinhron');
    expect(vaultAccountLabel('  ', 'abcdef0123456789'), 'Sinhron · abcdef01');
    expect(formatAccessDate(DateTime(2026, 3, 7)), '07.03.2026');
    final s = parseAccessState(wordsOnPhone: false, saved: 'nonsense:1', remind: 'x');
    expect(s.savedWay, isNull);
    expect(s.remindAfter, isNull);
  });
}
