// Settings → Sounds & vibration. Only real, saved settings (UI backlog
// §1 item 8, §4 items 34 and 38). Push notification options arrive with
// the App Store build (Apple account needed — tech-debt); until then the
// screen says so instead of showing switches that do nothing.
//
// ADR-040 (Android): which server to set in the ntfy app — the server names
// it (`core/push_server.dart`), so nobody types it from a guide.
// ADR-057 (Android): first of all "Calls will reach you: yes / what to do"
// (`core/call_reach.dart`), with a button for each fix.

import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/tokens.dart';
import '../../core/app_badge.dart';
import '../../core/app_notice.dart';
import '../../core/call_reach.dart';
import '../../core/providers/settings_providers.dart' show incomingCallsProvider;
import '../../core/push.dart';
import '../../core/push_server.dart';
import '../../core/haptics.dart';
import '../../core/ui_sounds.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';
import '../banners/in_app_banner.dart';
import '_shared.dart';

class NotificationsScreen extends ConsumerWidget {
  final VoidCallback? onBack;

  const NotificationsScreen({super.key, this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final pushOn = ref.watch(pushEnabledProvider).value ?? true;
    final ntfy = pushOn ? ref.watch(ntfyHintProvider).value : null;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(title: l.soundsVibration, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x2, bottom: DsSpace.x6),
                children: [
                  if (ref.watch(isAndroidProvider)) const _CallReachSection(),
                  SettingsSection(
                    title: l.inApp,
                    children: [
                      SettingsRow(
                        key: const ValueKey('setting-vibration'),
                        label: l.vibration,
                        toggle: ref.watch(hapticsEnabledProvider).value ?? true,
                        onToggle: (v) => ref.read(hapticsEnabledProvider.notifier).save(v),
                      ),
                      SettingsRow(
                        key: const ValueKey('setting-in-chat-sounds'),
                        label: l.inChatSounds,
                        toggle: ref.watch(uiSoundsEnabledProvider).value ?? true,
                        onToggle: (v) => ref.read(uiSoundsEnabledProvider.notifier).save(v),
                        isLast: Platform.isAndroid,
                      ),
                      // Android launchers draw the badge from notifications.
                      if (!Platform.isAndroid)
                        SettingsRow(
                          key: const ValueKey('setting-icon-badge'),
                          label: l.iconBadge,
                          toggle: ref.watch(iconBadgeEnabledProvider).value ?? false,
                          onToggle: (v) => setIconBadge(ref, v),
                          isLast: true,
                        ),
                    ],
                  ),
                  SettingsSection(
                    title: l.inAppBanners,
                    footer: l.bannersFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('setting-in-app-banners'),
                        label: l.inAppBanners,
                        toggle: ref.watch(inAppBannersEnabledProvider).value ?? true,
                        onToggle: (v) => ref.read(inAppBannersEnabledProvider.notifier).save(v),
                        isLast: true,
                      ),
                    ],
                  ),
                  // Owner, 2026-10-16: choose what a notification shows.
                  SettingsSection(
                    title: l.notificationPreviewTitle,
                    footer: l.notificationPreviewFooter,
                    children: [
                      for (final p in NotificationPreview.values)
                        SettingsRow(
                          key: ValueKey('notification-preview-${p.name}'),
                          label: switch (p) {
                            NotificationPreview.nameAndText => l.notificationPreviewNameAndText,
                            NotificationPreview.nameOnly => l.notificationPreviewNameOnly,
                            NotificationPreview.nothing => l.notificationPreviewNothing,
                          },
                          selected: p == (ref.watch(notificationPreviewProvider).value ?? NotificationPreview.nameAndText),
                          onTap: () => ref.read(notificationPreviewProvider.notifier).save(p),
                          isLast: p == NotificationPreview.nothing,
                        ),
                    ],
                  ),
                  // Overnight item 8 — real push (APNs).
                  SettingsSection(
                    title: l.pushNotifications,
                    footer: switch (pushOn ? ref.watch(pushPermissionProvider).value : null) {
                      'denied' => l.pushDenied,
                      // ADR-040 — the ntfy section below says what to do.
                      _ when ntfy?.step == NtfyStep.serverHasNone => l.ntfyServerHasNone,
                      _ when ntfy != null => null,
                      // ADR-040 — Android without ntfy (UnifiedPush).
                      'noDistributor' => l.pushNoDistributor,
                      _ => l.pushFooterOn,
                    },
                    children: [
                      SettingsRow(
                        key: const ValueKey('setting-push'),
                        label: l.pushToggle,
                        toggle: ref.watch(pushEnabledProvider).value ?? true,
                        onToggle: (v) => ref.read(pushServiceProvider).setEnabled(v),
                        isLast: true,
                      ),
                    ],
                  ),
                  if (ntfy != null && ntfy.step != NtfyStep.serverHasNone) _NtfySection(hint: ntfy),
                  // ADR-040 fallback: Android phones without ntfy.
                  if (Platform.isAndroid)
                    SettingsSection(
                      footer: l.keepConnectedFooter,
                      children: [
                        SettingsRow(
                          key: const ValueKey('setting-keep-connected'),
                          label: l.keepConnected,
                          toggle: ref.watch(keepConnectedProvider).value ?? false,
                          onToggle: (v) => ref.read(pushServiceProvider).setKeepConnected(v),
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

/// ADR-057 — will calls reach this phone, and what to tap if not.
class _CallReachSection extends ConsumerStatefulWidget {
  const _CallReachSection();

  @override
  ConsumerState<_CallReachSection> createState() => _CallReachSectionState();
}

class _CallReachSectionState extends ConsumerState<_CallReachSection> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from a system screen: look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(callReachProvider);
      ref.invalidate(pushPermissionProvider);
    }
  }

  Future<void> _fix(ReachFix f) async {
    final battery = ref.read(batteryPlatformProvider);
    switch (f) {
      case ReachFix.allowNotifications:
        // Refused for good: Android asks no more — its settings page.
        if (!await ref.read(pushPlatformProvider).register()) await battery.openApp();
      case ReachFix.turnOnCalls:
        await ref.read(incomingCallsProvider.notifier).save(true);
      case ReachFix.turnOnAlwaysConnected:
        await ref.read(pushServiceProvider).setKeepConnected(true);
      case ReachFix.allowBackground:
        await battery.askExempt();
    }
    ref.invalidate(callReachProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final r = ref.watch(callReachProvider).value;
    if (r == null) return const SizedBox.shrink();
    final rows = <Widget>[
      // The verdict in a full-size row — not a small caption.
      SettingsRow(
        key: const ValueKey('reach-verdict'),
        label: r.ok ? l.callsReachYes : l.callsReachNo,
        chevron: false,
        isLast: r.fixes.isEmpty && !r.samsung,
      ),
      for (final f in r.fixes)
        SettingsRow(
          key: ValueKey('reach-fix-${f.name}'),
          label: switch (f) {
            ReachFix.allowNotifications => l.reachFixNotifications,
            ReachFix.turnOnCalls => l.reachFixCalls,
            ReachFix.turnOnAlwaysConnected => l.reachFixAlways,
            ReachFix.allowBackground => l.reachFixBackground,
          },
          onTap: () => unawaited(_fix(f)),
          isLast: !r.samsung && f == r.fixes.last,
        ),
      if (r.samsung)
        SettingsRow(
          key: const ValueKey('reach-samsung'),
          label: l.reachSamsung,
          subtitle: l.reachSamsungSub,
          onTap: () => unawaited(ref.read(batteryPlatformProvider).openSamsung()),
          isLast: true,
        ),
    ];
    return SettingsSection(
      key: const ValueKey('call-reach'),
      footer: switch (r.via) {
        ReachVia.google => l.callsReachViaGoogle,
        ReachVia.ntfy => l.callsReachViaNtfy,
        ReachVia.alwaysConnected => l.callsReachViaAlways,
        ReachVia.none => l.callsReachNone,
      },
      children: rows,
    );
  }
}

/// ADR-040 — the steps for ntfy: our server's address to copy, ntfy to
/// install or open, and "Connect ntfy" once it is set there.
class _NtfySection extends ConsumerStatefulWidget {
  const _NtfySection({required this.hint});
  final NtfyHint hint;

  @override
  ConsumerState<_NtfySection> createState() => _NtfySectionState();
}

class _NtfySectionState extends ConsumerState<_NtfySection> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from ntfy or Google Play: look again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    ref.invalidate(ntfyHintProvider);
    ref.invalidate(ntfyInstalledProvider);
    ref.invalidate(pushPermissionProvider);
  }

  Future<void> _connect() async {
    final l = context.l10n;
    await ref.read(pushPlatformProvider).reconnect();
    showDone(l.ntfyConnecting);
    // ntfy answers with the new address a moment later.
    await Future<void>.delayed(const Duration(seconds: 3));
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final h = widget.hint;
    final installed = ref.watch(ntfyInstalledProvider).value ?? false;
    return SettingsSection(
      title: l.ntfyTitle,
      footer: switch (h.step) {
        NtfyStep.install => l.ntfyInstallSteps(h.serverUrl),
        NtfyStep.otherServer => l.ntfyOtherServerSteps(h.otherHost, h.serverUrl),
        _ => l.ntfySetServerSteps(h.serverUrl),
      },
      children: [
        SettingsRow(
          key: const ValueKey('ntfy-copy'),
          label: l.ntfyCopyAddress,
          subtitle: h.serverUrl,
          chevron: false,
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: h.serverUrl));
            showDone(l.ntfyAddressCopied);
          },
        ),
        if (installed)
          SettingsRow(
            key: const ValueKey('ntfy-open'),
            label: l.ntfyOpen,
            onTap: () => unawaited(ref.read(pushPlatformProvider).openNtfy()),
          )
        else
          SettingsRow(
            key: const ValueKey('ntfy-install'),
            label: l.ntfyInstall,
            onTap: () => unawaited(launchUrl(Uri.parse(kNtfyPlayUrl), mode: LaunchMode.externalApplication)),
          ),
        SettingsRow(
          key: const ValueKey('ntfy-connect'),
          label: l.ntfyConnect,
          chevron: false,
          onTap: () => unawaited(_connect()),
          isLast: true,
        ),
      ],
    );
  }
}
