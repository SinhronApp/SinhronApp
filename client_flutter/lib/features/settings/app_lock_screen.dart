// Settings → App lock — UI backlog §6 items 47-48. Real settings: App
// Lock with Face ID / Touch ID / device passcode, how soon it locks
// again, and hiding chats from the app switcher.
//
// Turning App Lock on asks for Face ID / the passcode first, so a
// device that can't authenticate never locks you out.

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_picker_sheet.dart';
import '../app_lock/app_lock.dart';
import '_shared.dart';
import '../../l10n/l10n.dart';

class AppLockScreen extends ConsumerStatefulWidget {
  final VoidCallback? onBack;

  const AppLockScreen({super.key, this.onBack});

  @override
  ConsumerState<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends ConsumerState<AppLockScreen> {
  String? _error;

  Future<void> _setLock(bool on) async {
    setState(() => _error = null);
    final auth = ref.read(appAuthenticatorProvider);
    final l = context.l10n;
    if (on) {
      if (!await auth.available()) {
        if (mounted) setState(() => _error = Platform.isAndroid ? l.setPasscodeFirstAndroid : l.setPasscodeFirst);
        return;
      }
      if (!await auth.authenticate(l.turnOnAppLock)) return;
    } else if (!await confirmOwner(ref, l.appLockTitle)) {
      // Audit LOCK-8 — switching it off is the owner's call too.
      return;
    }
    await ref.read(appLockEnabledProvider.notifier).save(on);
  }

  Future<void> _pickAfter(String current) async {
    final picked = await showDsPickerSheet(
      context: context,
      title: context.l10n.lockAgain,
            options: [for (final k in kLockAfterKeys) lockAfterLabel(context.l10n, k)],
      current: lockAfterLabel(context.l10n, current),
    );
    if (picked == null || !mounted) return;
    // Audit LOCK-8 — so is "lock again after an hour".
    if (!await confirmOwner(ref, context.l10n.appLockTitle) || !mounted) return;
        final key = kLockAfterKeys.firstWhere((k) => lockAfterLabel(context.l10n, k) == picked);
    await ref.read(appLockAfterProvider.notifier).save(key);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final lockOn = ref.watch(appLockEnabledProvider).value ?? false;
    final after = ref.watch(appLockAfterProvider).value ?? '60';
    final hide = ref.watch(hideInSwitcherProvider).value ?? true;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(title: context.l10n.appLockTitle, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x2, bottom: DsSpace.x6),
                children: [
                  SettingsSection(
                    title: context.l10n.lockSection,
                    footer: _error ??
                        (Platform.isAndroid ? context.l10n.appLockFooterAndroid : context.l10n.appLockFooter),
                    children: [
                      SettingsRow(
                        key: const ValueKey('app-lock-toggle'),
                        icon: SettingsRowIcon.key,
                        tint: SettingsRowTint.recovery,
                        label: context.l10n.appLockToggle,
                        toggle: lockOn,
                        onToggle: _setLock,
                      ),
                      SettingsRow(
                        key: const ValueKey('app-lock-after'),
                        label: context.l10n.lockAgain,
                        value: lockAfterLabel(context.l10n, after),
                        onTap: lockOn ? () => _pickAfter(after) : null,
                        isLast: true,
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: context.l10n.appSwitcher,
                    footer: context.l10n.appSwitcherFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('hide-in-switcher'),
                        label: context.l10n.hideInSwitcher,
                        toggle: hide,
                        onToggle: (v) => ref.read(hideInSwitcherProvider.notifier).save(v),
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
