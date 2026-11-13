// Welcome screen. The user lands here after splash (or immediately on first
// launch if splash was skipped previously). Three paths forward:
//   1. Get started — new account flow (server → profile → recovery phrase)
//   2. Link a device — pair via QR with an existing authorized device
//   3. Restore from phrase — recover identity + MLS state from 24-word seed
//
// Source: design/app/entry.jsx SnWelcome.
//
// Per spec §6.1, none of these paths involve a password, email, or phone.

import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/sinhron_mark.dart';
import '../../l10n/l10n.dart';

class WelcomeScreen extends StatelessWidget {
  final VoidCallback? onGetStarted;
  final VoidCallback? onLinkDevice;
  final VoidCallback? onRestore;

  /// ADR-037 — "By continuing you accept the Terms of use" (opens them).
  final VoidCallback? onTerms;

  const WelcomeScreen({super.key, this.onGetStarted, this.onLinkDevice, this.onRestore, this.onTerms});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            // 1 : 1.4 split (per entry.jsx) so brand sits slightly above center
            const Spacer(flex: 5),
            // Brand: mark + wordmark + tagline
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SinhronMark(size: 72),
                  const SizedBox(height: 22),
                  Text('Sinhron', style: DsTextArt.t40w600.copyWith(color: tokens.text)),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: Text(
                      context.l10n.tagline,
                      textAlign: TextAlign.center,
                      style: DsText.headline.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(flex: 7),
            // Actions
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x4h5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DsButton(
                    label: context.l10n.getStarted,
                    variant: DsButtonVariant.primary,
                    onPressed: () => onGetStarted?.call(),
                  ),
                  const SizedBox(height: 18),
                  DsButton(
                    label: context.l10n.linkDevice,
                    variant: DsButtonVariant.secondary,
                    onPressed: () => onLinkDevice?.call(),
                  ),
                  const SizedBox(height: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onRestore,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: DsSpace.x3),
                      child: Text(
                        context.l10n.restoreFromKey,
                        style: DsText.callout.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.accent),
                      ),
                    ),
                  ),
                  if (onTerms != null)
                    GestureDetector(
                      key: const ValueKey('welcome-terms'),
                      behavior: HitTestBehavior.opaque,
                      onTap: onTerms,
                      child: Padding(
                        padding: const EdgeInsets.only(top: DsSpace.x1),
                        child: Text(
                          context.l10n.welcomeAgreeTerms,
                          textAlign: TextAlign.center,
                          style: DsText.footnote.copyWith(color: tokens.text3),
                        ),
                      ),
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
