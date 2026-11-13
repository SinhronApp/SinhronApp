// Settings → Chat backup (ADR-073). Where it is kept (iCloud — nothing to
// do; Google Drive — one "Sign in with Google"), the daily switch, when the
// last one finished, "Back up now" with progress, and "Restore from backup"
// (asks first: date and how much). The footer says the one thing to know:
// it is encrypted with the 24 words. A device linked before backups gets
// "Turn on backup here" (the 24 words once — backup_words_sheet.dart).
// [offerBackupRestore] — the same restore, offered right after signing in
// with the 24 words on a new phone.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/backup/backup_service.dart';
import '../../core/backup/cloud_store.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../chat_list/chat_data.dart' show formatChatTime;
import '_shared.dart';
import 'backup_words_sheet.dart';

/// Is the cloud ready now (iCloud on / Google signed in)? Re-read on open.
final backupCloudReadyProvider = FutureProvider.autoDispose<bool>((ref) async {
  final store = ref.watch(cloudStoreProvider);
  return store != null && await store.available();
});

String _whereName(AppL10n l, CloudStore? store) => switch (store) {
  IcloudStore() => 'iCloud',
  DriveStore() => l.backupWhereDrive,
  _ => store?.kind ?? '—',
};

/// "Restore your chats? Backup of …" → restore. True when it ran.
Future<bool> _askAndRestore(BuildContext context, ChatBackup backup, BackupContents found) async {
  final l = context.l10n;
  // ADR-090 — the cloud lost a newer backup (or was rolled back): say so.
  final newer = found.missingNewer;
  final older = newer == null ? '' : '\n${l.backupRestoreOlder(formatChatTime(newer.millisecondsSinceEpoch ~/ 1000))}';
  final go = await showDsActionSheet<bool>(
    context,
    title:
        '${l.backupRestoreAskTitle}\n${l.backupRestoreAskBody(formatChatTime(found.created.millisecondsSinceEpoch ~/ 1000), found.messages, found.chats, found.media)}$older',
    actions: [DsSheetAction(l.backupRestoreGo, true)],
  );
  if (go != true) return false;
  appNotice.value = l.backupRestoreStarted;
  if (await backup.restore(found)) {
    final added = backup.lastRestoreAdded;
    showDone(added > 0 ? l.backupRestoredAdded(added) : l.backupRestoredNothingNew);
  }
  return true;
}

/// Right after the 24 words on a new phone: is there a backup to bring
/// back? iPhone — iCloud is looked in at once (nothing shown when there is
/// none); Android — asks first, since it takes "Sign in with Google".
Future<void> offerBackupRestore(NavigatorState nav) async {
  final container = ProviderScope.containerOf(nav.context);
  final store = container.read(cloudStoreProvider);
  if (store == null) return;
  try {
    if (!await store.available()) {
      if (store is! DriveStore || !nav.mounted) return;
      final l = nav.context.l10n;
      final ask = await showDsActionSheet<bool>(
        nav.context,
        title: '${l.backupOfferDriveTitle}\n${l.backupOfferDriveBody}',
        actions: [DsSheetAction(l.backupOfferDriveGo, true)],
      );
      if (ask != true || !await store.connect()) return;
      await container.read(backupEnabledProvider.notifier).save(true);
      final found = await container.read(chatBackupProvider.notifier).find();
      if (found == null) {
        appNotice.value = l.backupRestoreNone(l.backupWhereDrive);
        return;
      }
      if (nav.mounted) await _askAndRestore(nav.context, container.read(chatBackupProvider.notifier), found);
      return;
    }
    final found = await container.read(chatBackupProvider.notifier).find();
    if (found == null || !nav.mounted) return;
    await _askAndRestore(nav.context, container.read(chatBackupProvider.notifier), found);
  } catch (e) {
    // ignore: avoid_print
    print('[sinhron][backup] restore offer: $e');
  }
}

class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key, this.onBack});
  final VoidCallback? onBack;

  String _when(BuildContext context, String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return context.l10n.backupNever;
    return formatChatTime(t.millisecondsSinceEpoch ~/ 1000);
  }

  Future<void> _connect(WidgetRef ref) async {
    final store = ref.read(cloudStoreProvider);
    if (store == null) return;
    final bool connected;
    try {
      connected = await store.connect();
    } catch (_) {
      // Google sign-in failed (not cancelled): it used to say nothing.
      appNotice.value = lookupAppL10n(Locale(currentLanguage)).backupFailed;
      ref.invalidate(backupCloudReadyProvider);
      return;
    }
    if (connected) {
      await ref.read(backupEnabledProvider.notifier).save(true);
      ref.invalidate(backupCloudReadyProvider);
      await ref.read(chatBackupProvider.notifier).run();
    } else {
      ref.invalidate(backupCloudReadyProvider);
    }
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final store = ref.read(cloudStoreProvider);
    final backup = ref.read(chatBackupProvider.notifier);
    final l = context.l10n;
    // Looking in the cloud takes a few seconds: say so, and say when it
    // fails (a tap used to seem to do nothing).
    appNotice.value = l.backupSearching;
    final BackupContents? found;
    try {
      found = await backup.find();
    } catch (_) {
      appNotice.value = l.backupFailed;
      return;
    }
    if (appNotice.value == l.backupSearching) appNotice.value = '';
    if (!context.mounted) return;
    if (found == null) {
      appNotice.value = context.l10n.backupRestoreNone(_whereName(context.l10n, store));
      return;
    }
    await _askAndRestore(context, backup, found);
  }

  Future<void> _unlock(BuildContext context, WidgetRef ref) async {
    if (await showBackupWordsSheet(context) == true) await ref.read(chatBackupProvider.notifier).run();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final store = ref.watch(cloudStoreProvider);
    final ready = ref.watch(backupCloudReadyProvider).value ?? false;
    final enabled = ref.watch(backupEnabledProvider).value ?? true;
    final last = ref.watch(backupLastProvider).value ?? '';
    final s = ref.watch(chatBackupProvider);
    final can = ref.watch(backupCanProvider).value ?? true;
    final isDrive = store is DriveStore;

    final String nowSubtitle;
    if (s.running) {
      nowSubtitle = s.stage == 'media' && s.total > 0 ? l.backupRunningMedia(s.done, s.total) : l.backupRunning;
    } else if (s.restoring) {
      nowSubtitle = l.backupRestoring(s.done, s.total);
    } else if (s.error != null && s.error != 'not_connected' && s.error != 'no_key') {
      nowSubtitle = l.backupFailed;
    } else {
      nowSubtitle = '';
    }

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: l.backupTitle, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.only(bottom: pad.bottom + DsSpace.x6),
                children: [
                  SettingsSection(
                    footer: l.backupFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('backup-where'),
                        icon: SettingsRowIcon.storage,
                        tint: SettingsRowTint.storage,
                        label: l.backupWhere,
                        value: ready ? _whereName(l, store) : l.backupNotConnected,
                        chevron: false,
                      ),
                      if (!ready && isDrive)
                        SettingsRow(
                          key: const ValueKey('backup-sign-in'),
                          label: l.backupSignInGoogle,
                          onTap: () => _connect(ref),
                        ),
                      if (!ready && !isDrive && store != null)
                        SettingsRow(key: const ValueKey('backup-icloud-off'), label: l.backupIcloudOff, chevron: false),
                      if (ready && !can)
                        SettingsRow(
                          key: const ValueKey('backup-unlock'),
                          label: l.backupUnlockRow,
                          subtitle: l.backupUnlockRowHint,
                          onTap: () => _unlock(context, ref),
                        ),
                      SettingsRow(
                        key: const ValueKey('backup-daily'),
                        label: l.backupDaily,
                        toggle: enabled,
                        onToggle: (v) => ref.read(backupEnabledProvider.notifier).save(v),
                      ),
                      SettingsRow(
                        key: const ValueKey('backup-last'),
                        label: l.backupLast,
                        value: _when(context, last),
                        subtitle: s.uploadPending ? l.backupUploadPending : null,
                        chevron: false,
                      ),
                      SettingsRow(
                        key: const ValueKey('backup-now'),
                        label: l.backupNow,
                        subtitle: nowSubtitle.isEmpty ? null : nowSubtitle,
                        onTap: !ready || !can || s.running || s.restoring
                            ? null
                            : () async {
                                if (await ref.read(chatBackupProvider.notifier).run()) showDone(l.backupDone);
                              },
                        isLast: !(ready && isDrive),
                      ),
                      if (ready && isDrive)
                        SettingsRow(
                          key: const ValueKey('backup-sign-out'),
                          label: l.backupSignOutGoogle,
                          chevron: false,
                          onTap: () async {
                            await store.disconnect();
                            ref.invalidate(backupCloudReadyProvider);
                          },
                          isLast: true,
                        ),
                    ],
                  ),
                  SettingsSection(
                    title: l.backupRestoreSection,
                    children: [
                      SettingsRow(
                        key: const ValueKey('backup-restore'),
                        label: l.backupRestore,
                        onTap: !ready || !can || s.running || s.restoring ? null : () => _restore(context, ref),
                        isLast: true,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
