// Settings root screen. Per design/app/settings.jsx + spec §6.7, §8, §9.2.
//
// Structure (owner, 2026-10-18 — what people actually look for first):
// the profile card (→ My profile), then notifications / privacy / app lock /
// appearance / language, Chats & folders, Account & devices, Help & rules,
// and the expert things (server, connection, proxy) under "Advanced" at the
// bottom, then About. Every navigating row says in a subtitle what it is
// for; chevrons only on rows that open a screen.
//
// Per README cross-cutting #1: E2EE is "always on", NOT a toggle — the
// privacy story lives on the Privacy screen.
//
// Row/section/toggle primitives live in _shared.dart so the sub-screens
// (Storage, Privacy, Devices, …) inherit them.

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/appearance.dart';
import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../../core/haptics.dart';
import '../../core/providers/core_providers.dart';
import '../../core/providers/people.dart' show myAvatarProvider;
import '../../core/providers/settings_providers.dart';
import '../../core/services/net_service.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_tab_bar.dart';
import '../app_lock/app_lock.dart';
import '../app_update/update_banner.dart' show UpdateSettingsRow;
import '../chat_list/folders.dart' show tabFoldersProvider;
import '_shared.dart';
import '../server_notices/server_notices.dart' show ServerNoticesSettingsRow;

/// Shown under About. Must equal pubspec `version` (test/core/app_version_test.dart);
/// raise it with every update the owner installs (CLAUDE.md § Versions).
const kAppVersion = '0.12.0';

/// The build number of this upload (TestFlight / APK), passed by
/// `scripts/testflight.sh` and `scripts/android_release.sh` as
/// `--dart-define=SINHRON_BUILD=…` — tells two installs of one version apart.
/// Empty in dev builds.
const kAppBuild = String.fromEnvironment('SINHRON_BUILD');

/// "0.2.0 (202610160530)", or just the version in dev builds.
String appVersionLabel([String version = kAppVersion, String build = kAppBuild]) =>
    build.isEmpty ? version : '$version ($build)';

class SettingsScreen extends StatefulWidget {
  final ValueChanged<DsTabId>? onTabChange;
  final VoidCallback? onStorageTap;

  /// ADR-037 — Rules & support: terms of use, privacy, help.
  final VoidCallback? onTermsTap;
  final VoidCallback? onPrivacyPolicyTap;
  final VoidCallback? onSupportTap;

  /// ADR-073 — Settings → Chat backup.
  final VoidCallback? onBackupTap;

  /// "Report a problem" — the app's journal to whoever helps (2026-10-22).
  final VoidCallback? onReportProblemTap;

  /// The Storage section. Its screen is static sample data (no real usage
  /// numbers yet), so the app wiring hides it; the design gallery and the
  /// golden screenshots keep it.
  final bool showStorage;

  /// Settings → Appearance (theme, accent, wallpaper).
  final VoidCallback? onAppearanceTap;
  final VoidCallback? onLinkedDevicesTap;
  final VoidCallback? onPrivacyTap;
  final VoidCallback? onServerTap;
  final VoidCallback? onNotificationsTap;
  final VoidCallback? onAppLockTap;
  final VoidCallback? onRecoveryPhraseTap;
  final VoidCallback? onProfileTap;

  /// Settings → Chats → Chat folders.
  final VoidCallback? onChatFoldersTap;
  final VoidCallback? onArchiveTap;

  /// Advanced → Proxy (Tor) and the calls' backup route.
  final VoidCallback? onProxyTap;

  const SettingsScreen({
    super.key,
    this.onTabChange,
    this.onStorageTap,
    this.onTermsTap,
    this.onPrivacyPolicyTap,
    this.onSupportTap,
    this.onReportProblemTap,
    this.onBackupTap,
    this.showStorage = true,
    this.onAppearanceTap,
    this.onLinkedDevicesTap,
    this.onPrivacyTap,
    this.onServerTap,
    this.onNotificationsTap,
    this.onAppLockTap,
    this.onRecoveryPhraseTap,
    this.onProfileTap,
    this.onChatFoldersTap,
    this.onArchiveTap,
    this.onProxyTap,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // No local toggle state: every switch here is a saved setting (§6 item 52).

  // Boot diagnostics: always in debug; in release only after tapping the
  // version row 5 times (UI backlog §9 item 61) — still reachable for an
  // on-device check, invisible to everyone else.
  bool _diagnostics = kDebugMode;
  int _versionTaps = 0;

  void _onVersionTap() {
    if (_diagnostics || ++_versionTaps < 5) return;
    DsHaptics.play(Haptic.success);
    setState(() => _diagnostics = true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top),
        child: Column(
          children: [
            const _SettingsHeader(),
            Expanded(
              // Sections rise in, one after another, as the tab opens.
              child: DsAppearScope(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.only(bottom: DsSpace.x4h5),
                  children: dsStaggered([
                    _ProfileCard(onTap: widget.onProfileTap),
                    // What people look for first (owner, 2026-10-18); every row
                    // says in one line what it is for.
                    SettingsSection(
                      children: [
                        SettingsRow(
                          key: const ValueKey('settings-notifications'),
                          icon: SettingsRowIcon.bell,
                          tint: SettingsRowTint.notif,
                          label: context.l10n.notifications,
                          subtitle: context.l10n.settingsNotificationsHint,
                          onTap: widget.onNotificationsTap,
                        ),
                        SettingsRow(
                          key: const ValueKey('settings-privacy'),
                          icon: SettingsRowIcon.shield,
                          tint: SettingsRowTint.privacy,
                          label: context.l10n.privacyTitle,
                          subtitle: context.l10n.settingsPrivacyHint,
                          onTap: widget.onPrivacyTap,
                        ),
                        Consumer(
                          builder: (context, ref, _) => SettingsRow(
                            key: const ValueKey('settings-app-lock'),
                            icon: SettingsRowIcon.lock,
                            tint: SettingsRowTint.lock,
                            label: context.l10n.appLockTitle,
                            subtitle: Platform.isAndroid
                                ? context.l10n.settingsAppLockHintAndroid
                                : context.l10n.settingsAppLockHint,
                            value: (ref.watch(appLockEnabledProvider).value ?? false)
                                ? context.l10n.on
                                : context.l10n.off,
                            onTap: widget.onAppLockTap,
                          ),
                        ),
                        Consumer(
                          builder: (context, ref, _) => SettingsRow(
                            key: const ValueKey('settings-theme'),
                            icon: SettingsRowIcon.paint,
                            tint: SettingsRowTint.appear,
                            label: context.l10n.appearance,
                            subtitle: context.l10n.settingsAppearanceHint,
                            value: switch (parseTheme(ref.watch(themeChoiceProvider).value)) {
                              ThemeChoice.system => context.l10n.themeSystem,
                              ThemeChoice.light => context.l10n.themeLight,
                              ThemeChoice.dark => context.l10n.themeDark,
                              ThemeChoice.oled => context.l10n.themeOled,
                            },
                            onTap: widget.onAppearanceTap,
                          ),
                        ),
                        // Backlog §7 item 53 — Russian / English.
                        Consumer(
                          builder: (context, ref, _) {
                            final l = context.l10n;
                            final lang = ref.watch(languageProvider).value ?? 'system';
                            return SettingsRow(
                              key: const ValueKey('settings-language'),
                              icon: SettingsRowIcon.text,
                              tint: SettingsRowTint.text,
                              label: l.language,
                              value: switch (lang) {
                                'en' => l.langEn,
                                'ru' => l.langRu,
                                _ => l.langSystem,
                              },
                              onTap: () async {
                                final picked = await showDsActionSheet<String>(
                                  context,
                                  title: l.language,
                                  actions: [
                                    DsSheetAction(l.langSystem, 'system'),
                                    DsSheetAction(l.langEn, 'en'),
                                    DsSheetAction(l.langRu, 'ru'),
                                  ],
                                );
                                if (picked != null) await ref.read(languageProvider.notifier).save(picked);
                              },
                              isLast: true,
                            );
                          },
                        ),
                      ],
                    ),
                    SettingsSection(
                      title: context.l10n.settingsChatsSection,
                      children: [
                        // Owner, 2026-10-18: every folder setting in one place
                        // (show / hide, order, new, edit) — the folders screen.
                        Consumer(
                          builder: (context, ref, _) => SettingsRow(
                            key: const ValueKey('settings-chat-folders'),
                            icon: SettingsRowIcon.chats,
                            tint: SettingsRowTint.chats,
                            label: context.l10n.chatFolders,
                            value: '${ref.watch(tabFoldersProvider).length}',
                            onTap: widget.onChatFoldersTap,
                            isLast: widget.onArchiveTap == null && !widget.showStorage,
                          ),
                        ),
                        if (widget.onArchiveTap != null)
                          SettingsRow(
                            key: const ValueKey('settings-archive'),
                            icon: SettingsRowIcon.download,
                            tint: SettingsRowTint.download,
                            label: context.l10n.archivedChats,
                            subtitle: context.l10n.settingsArchiveHint,
                            onTap: widget.onArchiveTap,
                            isLast: !widget.showStorage,
                          ),
                        if (widget.showStorage)
                          SettingsRow(
                            key: const ValueKey('settings-storage'),
                            icon: SettingsRowIcon.storage,
                            tint: SettingsRowTint.storage,
                            label: context.l10n.storage,
                            subtitle: context.l10n.settingsStorageHint,
                            onTap: widget.onStorageTap,
                            isLast: true,
                          ),
                      ],
                    ),
                    SettingsSection(
                      title: context.l10n.settingsAccountSection,
                      children: [
                        SettingsRow(
                          key: const ValueKey('settings-devices'),
                          icon: SettingsRowIcon.devices,
                          tint: SettingsRowTint.devices,
                          label: context.l10n.linkedDevices,
                          subtitle: context.l10n.settingsDevicesHint,
                          onTap: widget.onLinkedDevicesTap,
                        ),
                        if (widget.onBackupTap != null)
                          SettingsRow(
                            key: const ValueKey('settings-backup'),
                            icon: SettingsRowIcon.cache,
                            tint: SettingsRowTint.storage,
                            label: context.l10n.backupTitle,
                            subtitle: context.l10n.backupHint,
                            onTap: widget.onBackupTap,
                          ),
                        // ADR-059 — "Not saved" while the words wait on this phone.
                        Consumer(
                          builder: (context, ref, _) => SettingsRow(
                            key: const ValueKey('settings-secret-words'),
                            icon: SettingsRowIcon.key,
                            tint: SettingsRowTint.recovery,
                            label: context.l10n.accountKey,
                            subtitle: context.l10n.settingsWordsHint,
                            value: (ref.watch(accountAccessProvider).value?.needsSaving ?? false)
                              ? context.l10n.wordsNotSaved
                              : null,
                            onTap: widget.onRecoveryPhraseTap,
                            isLast: true,
                          ),
                        ),
                      ],
                    ),
                    if (widget.onTermsTap != null || widget.onSupportTap != null)
                      SettingsSection(
                        title: context.l10n.legalSection,
                        children: [
                          SettingsRow(
                            key: const ValueKey('settings-support'),
                            icon: SettingsRowIcon.info,
                            tint: SettingsRowTint.info,
                            label: context.l10n.legalSupportRow,
                            subtitle: context.l10n.settingsHelpHint,
                            onTap: widget.onSupportTap,
                          ),
                          if (widget.onReportProblemTap != null)
                            SettingsRow(
                              key: const ValueKey('settings-report-problem'),
                              icon: SettingsRowIcon.document,
                              tint: SettingsRowTint.info,
                              label: context.l10n.reportProblemTitle,
                              subtitle: context.l10n.reportProblemHint,
                              onTap: widget.onReportProblemTap,
                            ),
                          SettingsRow(
                            key: const ValueKey('settings-terms'),
                            icon: SettingsRowIcon.document,
                            tint: SettingsRowTint.text,
                            label: context.l10n.legalTermsRow,
                            onTap: widget.onTermsTap,
                          ),
                          SettingsRow(
                            key: const ValueKey('settings-privacy-policy'),
                            icon: SettingsRowIcon.shield,
                            tint: SettingsRowTint.privacy,
                            label: context.l10n.legalPrivacyRow,
                            onTap: widget.onPrivacyPolicyTap,
                            isLast: true,
                          ),
                        ],
                      ),
                    // Expert things last: the server, the connection, a proxy.
                    SettingsSection(
                      title: context.l10n.settingsAdvanced,
                      footer: context.l10n.serverFooter,
                      children: [
                        Consumer(
                          builder: (context, ref, _) {
                            final net = ref.watch(netServiceProvider);
                            final host = Uri.tryParse(net.httpBaseUrl ?? '')?.host ?? '';
                            return SettingsRow(
                              key: const ValueKey('settings-server'),
                              icon: SettingsRowIcon.server,
                              tint: SettingsRowTint.server,
                              label: context.l10n.server,
                              value: host.isEmpty ? context.l10n.notConnected : host,
                              mono: host.isNotEmpty,
                              onTap: widget.onServerTap,
                            );
                          },
                        ),
                        // Tech-debt 2.4 — live state + "Reconnect" with the
                        // device key (ADR-021); no phrase needed. Acts in
                        // place, so no chevron.
                        Consumer(
                          builder: (context, ref, _) {
                            final status = ref.watch(netStatusProvider);
                            final l = context.l10n;
                            return SettingsRow(
                              key: const ValueKey('settings-reconnect'),
                              icon: SettingsRowIcon.server,
                              tint: SettingsRowTint.server,
                              label: status == NetStatus.connected ? l.connection : l.reconnect,
                              value: switch (status) {
                                NetStatus.connected => l.netConnected,
                                NetStatus.connecting => l.netConnecting,
                                _ => l.netOffline,
                              },
                              chevron: false,
                              // Also while "Connecting…": a connect stuck
                              // behind a VPN can be started over by hand.
                              onTap: () => ref.read(sessionProvider).resume(force: true),
                              isLast: widget.onProxyTap == null,
                            );
                          },
                        ),
                        if (widget.onProxyTap != null)
                          Consumer(
                            builder: (context, ref, _) {
                              final proxy = ref.watch(socksProxyProvider).value ?? '';
                              return SettingsRow(
                                key: const ValueKey('settings-proxy'),
                                icon: SettingsRowIcon.shield,
                                tint: SettingsRowTint.server,
                                label: context.l10n.proxyTitle,
                                subtitle: context.l10n.settingsProxyHint,
                                value: proxy.isEmpty ? context.l10n.off : proxy,
                                onTap: widget.onProxyTap,
                                isLast: true,
                              );
                            },
                          ),
                      ],
                    ),
                    // Status 223 — the server's service notices (administrators).
                    const ServerNoticesSettingsRow(),
                    SettingsSection(
                      title: context.l10n.about,
                      children: [
                        // ADR-058 — Android with our APK only (hidden elsewhere).
                        const UpdateSettingsRow(),
                        // Five taps open the boot diagnostics — a hidden
                        // check, so the row shows no chevron.
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _onVersionTap,
                          child: SettingsRow(
                            icon: SettingsRowIcon.info,
                            tint: SettingsRowTint.info,
                            key: const ValueKey('settings-version'),
                            label: 'Sinhron',
                            value: appVersionLabel(),
                            mono: true,
                            isLast: true,
                          ),
                        ),
                      ],
                    ),
                    // WU 73.2 — boot diagnostics, read on device to confirm
                    // storage actually opened in release builds (silent
                    // fall-through hid bugs in the 2026-05-22 iPhone test).
                    if (_diagnostics) const _DiagnosticsBlock(),
                  ]),
                ),
              ),
            ),
            Consumer(
              builder: (context, ref, _) => DsTabBar(
                active: DsTabId.settings,
                items: [
                  DsTabItem(
                    id: DsTabId.chats,
                    label: context.l10n.tabChats,
                    icon: DsIconShape.tabChats,
                    badge: ref.watch(unreadChatsCountProvider),
                  ),
                  DsTabItem(id: DsTabId.calls, label: context.l10n.tabCalls, icon: DsIconShape.tabCalls),
                  DsTabItem(id: DsTabId.contacts, label: context.l10n.tabContacts, icon: DsIconShape.tabContacts),
                  DsTabItem(id: DsTabId.settings, label: context.l10n.tabSettings, icon: DsIconShape.tabSettings),
                ],
                safeBottomPadding: EdgeInsets.only(bottom: mq.padding.bottom > 0 ? mq.padding.bottom : DsSpace.x4),
                onSelect: (t) {
                  if (t != DsTabId.settings && widget.onTabChange != null) {
                    widget.onTabChange!(t);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Header
// ═════════════════════════════════════════════════════════════════════

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1h5, DsSpace.x4, DsSpace.x3h5),
      child: Row(
        children: [
          Expanded(
            child: Text(context.l10n.tabSettings, style: DsText.title1.copyWith(height: 1.1, color: tokens.text)),
          ),
          // No search in Settings yet — the old magnifier did nothing.
          // Keep its height so the title sits where it did.
          const SizedBox(width: 36, height: 36),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Profile card
// ═════════════════════════════════════════════════════════════════════

class _ProfileCard extends ConsumerWidget {
  final VoidCallback? onTap;
  const _ProfileCard({this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    // Real profile (local name + identity fingerprint), never a demo person.
    final saved = ref.watch(profileNameProvider).value ?? '';
    final name = saved.isEmpty ? context.l10n.yourName : saved;
    final photo = ref.watch(myAvatarProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, 0, DsSpace.x3h5, DsSpace.x5h5),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap?.call(),
        child: Container(
          padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5),
          decoration: BoxDecoration(
            color: tokens.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: tokens.dividerStrong, width: 0.5),
            boxShadow: DsShadow.card,
          ),
          child: Row(
            children: [
              DsAvatar(name: name, size: 62, image: photo),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.title3.copyWith(color: tokens.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.settingsProfileHint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.fromLTRB(
                        DsSpace.nudge9,
                        DsSpace.nudge3,
                        DsSpace.nudge9,
                        DsSpace.nudge3,
                      ),
                      decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(999)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 11,
                            height: 11,
                            child: CustomPaint(painter: _MiniCheckPainter(tokens.accent)),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              context.l10n.e2eTitle,
                              style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8, height: 14, child: CustomPaint(painter: RowChevronPainter(tokens.text4))),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniCheckPainter extends CustomPainter {
  final Color color;
  _MiniCheckPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(4, 12)
      ..lineTo(9, 17)
      ..lineTo(20, 6);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MiniCheckPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Boot diagnostics (WU 73.2)
//
// On-device visibility into what Phase 2 storage is actually doing.
// Shown at the bottom of the Settings list — green strip when everything
// is OK, red strip with the failing error when storage didn't open.
// ═════════════════════════════════════════════════════════════════════

class _DiagnosticsBlock extends ConsumerWidget {
  const _DiagnosticsBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final boot = ref.watch(bootDiagnosticsProvider);
    final identity = ref.watch(identityProvider);

    final identityLine = identity.when(
      loading: () => 'identity: loading…',
      error: (e, _) => 'identity: ERROR · $e',
      data: (row) =>
          row == null ? 'identity: none persisted yet' : 'identity: fp=${row.fingerprint} · saved ${row.createdAtUnix}',
    );

    final headerColor = boot.ok ? tokens.success : tokens.danger;
    final headerBg = boot.ok ? tokens.success : tokens.danger;
    final headerLabel = boot.ok ? 'Boot OK' : 'Boot FAILED';

    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x5, DsSpace.x3h5, DsSpace.x1h5),
      child: Container(
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(tokens.radiusCard.toDouble()),
          border: Border.all(color: headerColor.withValues(alpha: 0.35)),
        ),
        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x3, DsSpace.x3h5, DsSpace.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.nudge3, DsSpace.x2, DsSpace.nudge3),
                  decoration: BoxDecoration(
                    color: headerBg.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(headerLabel, style: DsTextArt.t11w700Monov2.copyWith(color: headerColor)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Phase 2 diagnostics',
                    style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _DiagLine('core', boot.coreVersion.isEmpty ? '—' : boot.coreVersion, err: boot.coreError),
            _DiagLine('db', boot.dbPath.isEmpty ? '—' : boot.dbPath, err: boot.docsDirError ?? boot.storageError),
            _DiagLine(
              'mls',
              boot.mlsDbPath.isEmpty
                  ? '— (no docs dir)'
                  : (boot.mlsDbBytes < 0
                        ? '${boot.mlsDbPath} (not created yet)'
                        : '${boot.mlsDbPath} (${_humanBytes(boot.mlsDbBytes)})'),
            ),
            _DiagLine('id', identityLine),
          ],
        ),
      ),
    );
  }
}

/// Compact human-readable byte count for the diagnostics block. Drops
/// fractional digits for sub-KiB values, one decimal otherwise.
String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB';
}

class _DiagLine extends StatelessWidget {
  final String label;
  final String value;
  final String? err;

  const _DiagLine(this.label, this.value, {this.err});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final hasErr = err != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpace.x1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 36,
            child: Text(label, style: DsTextArt.t11w700Monov3.copyWith(color: tokens.text3)),
          ),
          Expanded(
            child: Text(
              hasErr ? '$value\nERROR · $err' : value,
              style: DsTextArt.t11w500Monov4.copyWith(color: hasErr ? tokens.danger : tokens.text2),
            ),
          ),
        ],
      ),
    );
  }
}
