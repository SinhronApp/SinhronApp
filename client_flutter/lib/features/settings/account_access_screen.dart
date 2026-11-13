// Settings → Secret words, wired — ADR-059. [RecoveryPhraseStatusScreen]
// draws; this decides what it shows and does:
//   - "Save to Passwords" — the words waiting on this phone go to the
//     password manager; saved → they leave the phone;
//   - "Write the words down" — the words screen (2-word check, sheet),
//     after Face ID / the passcode;
//   - "Check the words" — all 24 (typed or pasted from Passwords),
//     compared with this account's fingerprint;
//   - the second device row → Linked devices.

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/account_access.dart';
import '../../core/app_notice.dart';
import '../../core/haptics.dart';
import '../../core/providers/device_providers.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_page_route.dart';
import '../app_lock/app_lock.dart';
import '../onboarding/recovery_phrase_screen.dart';
import 'phrase_prompt.dart';
import 'recovery_phrase_status_screen.dart';

class AccountAccessScreen extends ConsumerWidget {
  const AccountAccessScreen({super.key, this.onBack, this.onLinkDevice});

  final VoidCallback? onBack;
  final VoidCallback? onLinkDevice;

  Future<void> _savePasswords(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    // Audit SEED-1 — once in Passwords, "Paste from…" would show them.
    if (!await confirmOwner(ref, Platform.isAndroid ? l.saveToPasswordsAndroid : l.saveToPasswordsIos)) return;
    String name = '';
    try {
      name = await ref.read(profileNameProvider.future);
    } catch (_) {}
    var fp = '';
    try {
      fp = await ref.read(secretOpsProvider).storedFingerprint() ?? '';
    } catch (_) {}
    final r = await ref.read(accountAccessProvider.notifier).saveWaitingToPasswords(name: name, fingerprint: fp);
    switch (r) {
      case VaultResult.saved:
        DsHaptics.play(Haptic.success);
        showDone(l.accessSavedDone);
      case VaultResult.failed:
        appNotice.value = l.passwordsFailed;
      case VaultResult.cancelled:
        break;
    }
  }

  Future<void> _writeDown(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final nav = Navigator.of(context);
    final access = ref.read(accountAccessProvider.notifier);
    // Audit storage-devices:5 — whoever holds the open phone saw them.
    if (!await confirmOwner(ref, l.writeWordsAction)) return;
    final words = await access.pendingWords();
    if (words == null) return;
    final way = await nav.push<AccessWay>(
      DsPageRoute<AccessWay>(
        builder: (ctx) => RecoveryPhraseScreen(
          words: words.split(' '),
          onBack: () => Navigator.of(ctx).pop(),
          onSaved: (w) => Navigator.of(ctx).pop(w),
        ),
      ),
    );
    if (way == null) return;
    await access.markSaved(way);
    showDone(l.accessSavedDone);
  }

  /// ADR-085 — iPhone: the words saved as a Safari password before move to
  /// iCloud Keychain (the native side deletes the old entry).
  Future<void> _moveToKeychain(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final words = await ref.read(passwordVaultProvider).pick();
    if (words == null) return;
    if (!await _mine(ref, words)) {
      DsHaptics.play(Haptic.error);
      appNotice.value = l.wordsDontMatch;
      return;
    }
    await ref.read(accountAccessProvider.notifier).markSaved(AccessWay.keychain);
    DsHaptics.play(Haptic.success);
    showDone(l.accessSavedDone);
  }

  /// The words are this account's.
  Future<bool> _mine(WidgetRef ref, String phrase) async {
    final secrets = ref.read(secretOpsProvider);
    try {
      final stored = await secrets.storedFingerprint();
      return stored != null && stored == await secrets.fingerprintFor(phrase);
    } catch (_) {
      return false;
    }
  }

  Future<void> _check(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final phrase = await promptPhrase(
      context,
      title: l.checkWordsTitle,
      body: l.checkWordsBody,
      action: l.checkWordsAction,
    );
    if (phrase == null) return;
    if (!await _mine(ref, phrase)) {
      DsHaptics.play(Haptic.error);
      appNotice.value = l.wordsDontMatch;
      return;
    }
    DsHaptics.play(Haptic.success);
    showDone(l.wordsMatch);
    final s = ref.read(accountAccessProvider).value;
    // Keep "saved to Passwords" as it is; otherwise they're known now.
    if (s == null || s.needsSaving || s.unknown) {
      await ref.read(accountAccessProvider.notifier).markSaved(AccessWay.checked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(linkedDevicesProvider).value ?? const [];
    return RecoveryPhraseStatusScreen(
      onBack: onBack,
      access: ref.watch(accountAccessProvider).value,
      passwordsAvailable: ref.watch(passwordVaultProvider).available,
      otherDevices: devices.where((d) => !d.isThisDevice).length,
      formatDate: formatAccessDate,
      onSavePasswords: () => _savePasswords(context, ref),
      onWriteDown: () => _writeDown(context, ref),
      onMoveToKeychain: () => _moveToKeychain(context, ref),
      onReVerify: () => _check(context, ref),
      onLinkDevice: onLinkDevice,
    );
  }
}
