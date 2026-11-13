// ADR-058 — "Update 0.6.0 is available": a calm card over Chats on an
// Android phone with our APK, and "Check for updates" under Settings →
// About. The work (manifest, download, checks, installer) is in
// core/app_update.dart.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/app_update.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_button.dart';
import '../settings/_shared.dart';

/// The banner's main button: Update → download; Install → (first explain
/// what Android will ask) the installer; Try again → download again.
Future<void> runUpdateAction(BuildContext context, WidgetRef ref) async {
  final c = ref.read(appUpdateProvider.notifier);
  switch (ref.read(appUpdateProvider).phase) {
    case UpdatePhase.available:
    case UpdatePhase.failed:
      await c.download();
      if (ref.read(appUpdateProvider).phase == UpdatePhase.ready && context.mounted) {
        await _install(context, ref);
      }
    case UpdatePhase.ready:
      await _install(context, ref);
    default:
      break;
  }
}

Future<void> _install(BuildContext context, WidgetRef ref) async {
  final c = ref.read(appUpdateProvider.notifier);
  if (!await c.canInstall()) {
    if (!context.mounted) return;
    // The first time Android asks "allow from this source" — say so before.
    final go = await showDsActionSheet<bool>(
      context,
      title: context.l10n.updatePermissionExplain,
      actions: [DsSheetAction(context.l10n.updateContinue, true)],
    );
    if (go != true) return;
  }
  await c.install();
}

class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  @override
  void initState() {
    super.initState();
    ref.read(appUpdateProvider.notifier).startAutoCheck();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appUpdateProvider);
    final rel = s.release;
    if (!s.showBanner || rel == null) return const SizedBox.shrink();
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final (title, body) = switch (s.phase) {
      UpdatePhase.downloading => (l.updateDownloading((s.progress * 100).floor()), null),
      UpdatePhase.ready => (l.updateReadyTitle, l.updateReadyBody),
      UpdatePhase.failed => (
        l.updateAvailableTitle(rel.version),
        switch (s.failure) {
          UpdateFailure.badFile => l.updateFailedBadFile,
          UpdateFailure.installer => l.updateFailedInstaller,
          _ => l.updateFailedOffline,
        },
      ),
      _ => (l.updateAvailableTitle(rel.version), rel.notes.isNotEmpty ? rel.notes : l.updateAvailableBody),
    };
    final action = switch (s.phase) {
      UpdatePhase.available => l.updateAction,
      UpdatePhase.ready => l.updateInstall,
      UpdatePhase.failed => l.updateRetry,
      _ => null,
    };
    return Padding(
      key: const ValueKey('update-banner'),
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1, DsSpace.x4, DsSpace.x2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, DsSpace.x3),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tokens.divider, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: DsText.subhead.copyWith(color: tokens.text, fontWeight: FontWeight.w600)),
            if (body != null) ...[
              const SizedBox(height: DsSpace.x1),
              Text(
                body,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: DsText.footnote.copyWith(color: tokens.text2),
              ),
            ],
            if (s.phase == UpdatePhase.downloading) ...[
              const SizedBox(height: DsSpace.x2h5),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 4,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: tokens.divider)),
                      FractionallySizedBox(
                        widthFactor: s.progress.clamp(0.0, 1.0),
                        child: ColoredBox(color: tokens.accent),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: DsSpace.x3),
              Row(
                children: [
                  DsButton(
                    key: const ValueKey('update-action'),
                    label: action,
                    size: DsButtonSize.small,
                    fullWidth: false,
                    onPressed: () => unawaited(runUpdateAction(context, ref)),
                  ),
                  const SizedBox(width: DsSpace.x2),
                  DsButton(
                    key: const ValueKey('update-later'),
                    label: l.updateLater,
                    size: DsButtonSize.small,
                    variant: DsButtonVariant.ghost,
                    fullWidth: false,
                    onPressed: ref.read(appUpdateProvider.notifier).dismiss,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Settings → About → "Check for updates" (only where the app updates
/// itself). Tap: look now; a newer build → the same steps as the banner.
class UpdateSettingsRow extends ConsumerWidget {
  const UpdateSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(selfUpdateSupportedProvider).value != true) return const SizedBox.shrink();
    final s = ref.watch(appUpdateProvider);
    final l = context.l10n;
    final value = switch (s.phase) {
      UpdatePhase.checking => l.updateChecking,
      UpdatePhase.downloading => '${(s.progress * 100).floor()}%',
      UpdatePhase.available || UpdatePhase.ready || UpdatePhase.failed when s.release != null =>
        l.updateNewVersion(s.release!.version),
      _ => null,
    };
    return SettingsRow(
      key: const ValueKey('settings-check-update'),
      icon: SettingsRowIcon.download,
      tint: SettingsRowTint.info,
      label: l.updateCheck,
      subtitle: l.updateCheckHint,
      value: value,
      chevron: false,
      onTap: () => unawaited(_tap(context, ref)),
    );
  }

  Future<void> _tap(BuildContext context, WidgetRef ref) async {
    final c = ref.read(appUpdateProvider.notifier);
    final before = ref.read(appUpdateProvider).phase;
    if (before == UpdatePhase.downloading || before == UpdatePhase.checking) return;
    if (before != UpdatePhase.ready) await c.check(manual: true);
    if (!context.mounted) return;
    final s = ref.read(appUpdateProvider);
    switch (s.phase) {
      case UpdatePhase.upToDate:
        showDone(context.l10n.updateUpToDate);
      case UpdatePhase.failed when s.release == null || s.failure == UpdateFailure.offline:
        appNotice.value = context.l10n.updateOffline;
      case UpdatePhase.available || UpdatePhase.ready || UpdatePhase.failed:
        await runUpdateAction(context, ref);
      default:
        break;
    }
  }
}
