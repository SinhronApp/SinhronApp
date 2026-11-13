// "Keep access to your account" — ADR-059.
//
// The 24 secret words are the account (ADR-021). Sign-up no longer stops
// until they're written down: the person saves them to the phone's
// password manager in one tap, writes them down, or picks "Later". Until
// one of those is done the words wait on THIS phone only (Keychain /
// Android Keystore, account `pending-phrase`, same channel as the device
// key); the first save deletes them again.
//
// Non-secret bookkeeping (how and when they were saved, when to remind)
// lives in the settings table of the chats DB.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/settings_providers.dart';
import 'session.dart';

/// How the words were last kept safe.
enum AccessWay {
  /// The Android password manager; on iPhone — the old Safari website
  /// password (before ADR-085), still to move to [keychain].
  passwords,

  /// iPhone, ADR-085: an iCloud Keychain item only this app reads.
  keychain,

  /// Written down and passed the 2-word check.
  paper,

  /// The recovery sheet (picture with the words and a QR) was shared.
  sheet,

  /// All 24 typed in Settings → "Check the words" and they matched.
  checked,
}

/// Settings keys.
const kAccessSavedKey = 'access_saved'; // "<way>:<epoch ms>"
const kAccessRemindKey = 'access_remind_after'; // epoch ms

/// First reminder after "Later", and after each "Later" on the reminder.
const kFirstReminderAfter = Duration(days: 1);
const kNextReminderAfter = Duration(days: 7);

class AccessState {
  const AccessState({this.wordsOnPhone = false, this.savedWay, this.savedAt, this.remindAfter});

  /// The words wait on this phone — nobody has saved them yet.
  final bool wordsOnPhone;
  final AccessWay? savedWay;
  final DateTime? savedAt;
  final DateTime? remindAfter;

  /// Not saved yet (the words are still only here).
  bool get needsSaving => wordsOnPhone;

  /// Accounts made before ADR-059 (the old flow made people write the
  /// words down) and phones signed in with the words: nothing to nag about.
  bool get unknown => !wordsOnPhone && savedWay == null;

  bool reminderDue(DateTime now) => wordsOnPhone && (remindAfter == null || !now.isBefore(remindAfter!));
}

AccessState parseAccessState({required bool wordsOnPhone, String? saved, String? remind}) {
  AccessWay? way;
  DateTime? at;
  if (saved != null && saved.contains(':')) {
    final i = saved.indexOf(':');
    way = AccessWay.values.where((w) => w.name == saved.substring(0, i)).firstOrNull;
    final ms = int.tryParse(saved.substring(i + 1));
    if (ms != null) at = DateTime.fromMillisecondsSinceEpoch(ms);
  }
  final r = int.tryParse(remind ?? '');
  return AccessState(
    wordsOnPhone: wordsOnPhone,
    savedWay: way,
    savedAt: way == null ? null : at,
    remindAfter: r == null ? null : DateTime.fromMillisecondsSinceEpoch(r),
  );
}

// ─── The password manager seam ─────────────────────────────────────────

enum VaultResult { saved, cancelled, failed }

/// The phone's own password manager. iOS (ADR-085): an iCloud Keychain
/// item of this app (the old Safari password is read once and moved);
/// Android: Credential Manager. Native side: channel `dev.sinhron/passwords`
/// in `AppDelegate.swift` / `Passwords.kt`. Faked in tests.
abstract class PasswordVault {
  /// Is there one on this platform at all.
  bool get available;

  Future<VaultResult> save({required String account, required String secret});

  /// The person picks a saved entry; null when there's none or they closed it.
  Future<String?> pick();
}

class PlatformPasswordVault implements PasswordVault {
  const PlatformPasswordVault();

  static const _channel = MethodChannel('dev.sinhron/passwords');

  @override
  bool get available => Platform.isIOS || Platform.isAndroid;

  @override
  Future<VaultResult> save({required String account, required String secret}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('save', {'account': account, 'secret': secret});
      return ok == true ? VaultResult.saved : VaultResult.cancelled;
    } on MissingPluginException {
      return VaultResult.failed;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[sinhron] password manager: ${e.code}'); // never the secret
      return e.code == 'cancelled' ? VaultResult.cancelled : VaultResult.failed;
    }
  }

  @override
  Future<String?> pick() async {
    try {
      return await _channel.invokeMethod<String>('pick');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

final passwordVaultProvider = Provider<PasswordVault>((ref) => const PlatformPasswordVault());

/// What a save to the vault is noted as on this phone.
AccessWay get vaultWay => defaultTargetPlatform == TargetPlatform.iOS ? AccessWay.keychain : AccessWay.passwords;

/// Wall clock — fixed in tests.
final accessClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// 18.10.2026 — the same in both languages, no locale data needed.
String formatAccessDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

/// "Name · 1a2b3c4d" — the login of the password-manager entry, so two
/// accounts don't overwrite each other and the person knows which is which.
String vaultAccountLabel(String name, String fingerprint) {
  final fp = fingerprint.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final short = fp.length > 8 ? fp.substring(0, 8) : fp;
  final who = name.trim().isEmpty ? 'Sinhron' : name.trim();
  return short.isEmpty ? who : '$who · $short';
}

class AccountAccessNotifier extends AsyncNotifier<AccessState> {
  SettingsStore get _settings => ref.read(settingsStoreProvider);
  DeviceKeyStore get _pending => ref.read(pendingPhraseStoreProvider);
  DateTime get _now => ref.read(accessClockProvider)();

  @override
  Future<AccessState> build() async {
    String? saved, remind;
    try {
      saved = await _settings.get(kAccessSavedKey);
      remind = await _settings.get(kAccessRemindKey);
    } catch (_) {
      // DB not open yet (before sign-up).
    }
    String? words;
    try {
      words = await _pending.read();
    } catch (_) {}
    return parseAccessState(wordsOnPhone: words != null && words.isNotEmpty, saved: saved, remind: remind);
  }

  /// The words, while they wait on this phone; null once saved.
  Future<String?> pendingWords() async {
    try {
      return await _pending.read();
    } catch (_) {
      return null;
    }
  }

  /// Sign-up "Later": keep the words here, remind in a day.
  /// KEYS-1 — refuses when an earlier account's data here was not read at
  /// launch: its waiting words may be the only copy.
  Future<void> keepForLater(String phrase) async {
    ref.read(sessionProvider).refuseOverUnreadData();
    await _pending.write(phrase);
    await _setQuiet(kAccessRemindKey, '${_now.add(kFirstReminderAfter).millisecondsSinceEpoch}');
    ref.invalidateSelf();
    await future;
  }

  /// Saved somewhere safe: the copy on this phone goes.
  Future<void> markSaved(AccessWay way) async {
    try {
      await _pending.delete();
    } catch (_) {}
    await _setQuiet(kAccessSavedKey, '${way.name}:${_now.millisecondsSinceEpoch}');
    ref.invalidateSelf();
    await future;
  }

  /// "Later" on the reminder card.
  Future<void> remindLater() async {
    await _setQuiet(kAccessRemindKey, '${_now.add(kNextReminderAfter).millisecondsSinceEpoch}');
    ref.invalidateSelf();
    await future;
  }

  /// Settings → "Save to Passwords" (the words waiting on this phone).
  Future<VaultResult> saveWaitingToPasswords({required String name, required String fingerprint}) async {
    final words = await pendingWords();
    if (words == null) return VaultResult.failed;
    final r = await ref
        .read(passwordVaultProvider)
        .save(account: vaultAccountLabel(name, fingerprint), secret: words);
    if (r == VaultResult.saved) await markSaved(vaultWay);
    return r;
  }

  Future<void> _setQuiet(String key, String value) async {
    try {
      await _settings.set(key, value);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] access bookkeeping not saved: $e');
    }
  }
}

final accountAccessProvider = AsyncNotifierProvider<AccountAccessNotifier, AccessState>(AccountAccessNotifier.new);

/// The chat-list card is due (words still only here, reminder time came).
final accessReminderDueProvider = Provider<bool>((ref) {
  final s = ref.watch(accountAccessProvider).value;
  return s != null && s.reminderDue(ref.read(accessClockProvider)());
});
