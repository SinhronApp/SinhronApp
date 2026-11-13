// Privacy & security sub-screen. Reached from Settings → Privacy section
// → "Privacy & security" row.
//
// This is the flagship Sinhron trust surface. The hero card frames E2EE as
// "always on, never a toggle" (per README cross-cutting #1) and surfaces
// three concrete trust properties without dumping MLS / OPAQUE jargon.
// Below that, the user gets fine-grained control over the *metadata* their
// server and contacts can see — which is the only thing the E2EE story
// leaves on the table.
//
// Composition:
//   1. App-bar with back chevron + "Privacy & security".
//   2. Encryption status hero card — green shield + headline + 3 mini-chips.
//   3. WHO CAN CONTACT YOU — Calls / Group invites pickers + Message requests
//      toggle.
//   4. WHAT OTHERS SEE — Profile photo / Last seen pickers + Read receipts /
//      Typing indicators toggles.
//   5. CONTENT PROTECTION — Screenshot warning / Block screenshots toggles +
//      Disappearing messages default picker.
//   6. BLOCKED — Blocked contacts row.
//   7. ADVANCED — Reset session keys destructive action.
//
// Picker rows cycle through Everyone → Contacts → Nobody on tap (no
// bottom sheet yet — kept inline so the demo stays self-contained).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/message_actions.dart';
import '../../core/providers/people.dart';
import '../../core/providers/presence.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/services/net_service.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../app_lock/app_lock.dart';
import '_shared.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_shared_glyphs.dart';

class PrivacySecurityScreen extends ConsumerWidget {
  final VoidCallback? onBack;
  final VoidCallback? onBlockedList;

  /// Settings → App lock (Face ID, app switcher).
  final VoidCallback? onAppLock;

  const PrivacySecurityScreen({super.key, this.onBack, this.onBlockedList, this.onAppLock});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    bool v(AsyncNotifierProvider<BoolSetting, bool> p, bool d) => ref.watch(p).value ?? d;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(title: context.l10n.privacyTitle, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x1h5, bottom: DsSpace.x6),
                children: [
                  const _EncryptionHero(),
                  // Backlog §6 item 52 — every switch here is real and saved.
                  SettingsSection(
                    title: context.l10n.whatOthersSee,
                    footer: context.l10n.whatOthersSeeFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('privacy-read-receipts'),
                        label: context.l10n.readReceipts,
                        toggle: v(readReceiptsProvider, true),
                        onToggle: (x) => ref.read(readReceiptsProvider.notifier).save(x),
                      ),
                      SettingsRow(
                        key: const ValueKey('privacy-typing'),
                        label: context.l10n.typingIndicators,
                        toggle: v(typingIndicatorsProvider, true),
                        onToggle: (x) => ref.read(typingIndicatorsProvider.notifier).save(x),
                      ),
                      // ADR-031 — only to contacts, and only while on.
                      SettingsRow(
                        key: const ValueKey('privacy-show-online'),
                        label: context.l10n.showOnline,
                        toggle: v(showOnlineProvider, false),
                        onToggle: (x) async {
                          await ref.read(showOnlineProvider.notifier).save(x);
                          await ref.read(presenceProvider).settingChanged(x);
                        },
                        isLast: true,
                      ),
                    ],
                  ),
                  // Tech-debt 2.27 — real call screening and block list.
                  SettingsSection(
                    footer: context.l10n.incomingCallsFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('privacy-incoming-calls'),
                        label: context.l10n.incomingCalls,
                        toggle: v(incomingCallsProvider, true),
                        onToggle: (x) => ref.read(incomingCallsProvider.notifier).save(x),
                      ),
                      SettingsRow(
                        key: const ValueKey('privacy-blocked'),
                        label: context.l10n.blockedTitle,
                        value: '${ref.watch(blockedPeersProvider).value?.length ?? 0}',
                        onTap: onBlockedList,
                        isLast: true,
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: context.l10n.disappearingMessages,
                    footer: context.l10n.disappearingFooter,
                    children: [SettingsRow(label: context.l10n.timer, value: context.l10n.perChat, isLast: true)],
                  ),
                  SettingsSection(
                    title: context.l10n.links,
                    footer: context.l10n.linksFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('privacy-link-previews'),
                        label: context.l10n.linkPreviews,
                        toggle: v(linkPreviewsEnabledProvider, false),
                        onToggle: (x) => ref.read(linkPreviewsEnabledProvider.notifier).save(x),
                        isLast: true,
                      ),
                    ],
                  ),
                  // Tech-debt 2.2 — who can reach you without the server
                  // knowing who sent it (ADR-026).
                  SettingsSection(
                    title: context.l10n.sealedSectionTitle,
                    footer: context.l10n.sealedResetFooter,
                    children: [
                      // Asks first and acts in place — no chevron. The
                      // proxy moved to Settings → Advanced (2026-10-18).
                      SettingsRow(
                        key: const ValueKey('privacy-reset-access'),
                        label: context.l10n.sealedResetAction,
                        chevron: false,
                        onTap: () => _resetAccess(context, ref),
                        isLast: true,
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: context.l10n.thisDevice,
                    children: [
                      SettingsRow(
                        key: const ValueKey('privacy-app-lock'),
                        label: context.l10n.appLockTitle,
                        value: v(appLockEnabledProvider, false) ? context.l10n.on : context.l10n.off,
                        onTap: onAppLock,
                      ),
                      SettingsRow(
                        key: const ValueKey('privacy-switcher'),
                        label: context.l10n.hideInSwitcher,
                        toggle: v(hideInSwitcherProvider, true),
                        onToggle: (x) => ref.read(hideInSwitcherProvider.notifier).save(x),
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

Future<void> _resetAccess(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  final ok = await showDsActionSheet<bool>(
    context,
    title: l.sealedResetConfirm,
    actions: [DsSheetAction(l.sealedResetAction, true, destructive: true)],
  );
  if (ok != true) return;
  String result;
  try {
    await ref.read(netServiceProvider).rotateAccessKey();
    result = l.sealedResetDone;
  } catch (_) {
    result = l.addDeviceFailed;
  }
  // No toast widget in this app: the outcome as a one-line sheet.
  if (context.mounted) {
    await showDsActionSheet<bool>(context, title: result, actions: const [], cancelLabel: 'OK');
  }
}

// ═════════════════════════════════════════════════════════════════════
// Encryption status hero
// ═════════════════════════════════════════════════════════════════════

class _EncryptionHero extends StatelessWidget {
  const _EncryptionHero();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1h5, DsSpace.x3h5, DsSpace.x5h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              tokens.surface,
              // Subtle green tint in the bottom-right so the card reads
              // "secure" without screaming it.
              Color.lerp(tokens.surface, DsPalette.green, 0.05)!,
            ],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tokens.dividerStrong, width: 0.5),
          boxShadow: DsShadow.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Shield + check + headline row
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(color: DsPalette.green10, borderRadius: BorderRadius.circular(12)),
                  child: Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CustomPaint(painter: DsShieldTickGlyph(color: DsPalette.green)),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(context.l10n.e2eTitle, style: DsText.headline.copyWith(color: tokens.text)),
                      const SizedBox(height: 2),
                      Text(context.l10n.e2eAlways, style: DsText.subhead.copyWith(color: tokens.text3)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(context.l10n.e2eBody, style: DsText.subhead.copyWith(color: tokens.text2)),
            const SizedBox(height: 16),
            // Three trust property chips
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TrustChip(label: context.l10n.chipKeys),
                _TrustChip(label: context.l10n.chipOld),
                _TrustChip(label: context.l10n.chipHeal),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustChip extends StatelessWidget {
  final String label;
  const _TrustChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.nudge5, DsSpace.x2h5, DsSpace.nudge5),
      decoration: BoxDecoration(color: DsPalette.green8, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CustomPaint(painter: DsChipCheckGlyph(color: DsTheme.of(context).success)),
          ),
          const SizedBox(width: 5),
          // Wraps at large text sizes instead of overflowing (§7 item 54);
          // success token = AA contrast.
          Flexible(
            child: Text(
              label,
              style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: DsTheme.of(context).success),
            ),
          ),
        ],
      ),
    );
  }
}
