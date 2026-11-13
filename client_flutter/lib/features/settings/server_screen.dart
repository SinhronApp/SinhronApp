// Server sub-screen. Reached from Settings → Server section → "Server" row.
//
// Unique to Sinhron: a server is operated by a community ("cabin") and the
// user explicitly chose it during onboarding. This screen is the trust
// surface for *that* choice — connection status + the policies this
// operator promises + a short, blunt "what this server sees vs can't see"
// breakdown so the user doesn't have to take it on faith.
//
// Only what this phone knows: the host it joined, whether it is connected,
// the transport, and the trust comparison (true of every Sinhron server).
// Operator, policies, latency and Switch server have no backend yet.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_app_bar.dart';
import '_shared.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_shared_glyphs.dart';

class ServerScreen extends StatelessWidget {
  final VoidCallback? onBack;

  /// The server this phone joined (host[:port]).
  final String host;

  /// Connected right now.
  final bool connected;

  /// "WSS" / "WS".
  final String protocol;

  const ServerScreen({super.key, this.onBack, required this.host, this.connected = false, this.protocol = ''});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final l = context.l10n;
    final status = connected ? l.netConnected : l.netOffline;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            DsAppBar(title: l.server, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x1h5, bottom: DsSpace.x6),
                children: [
                  _ServerHero(hostname: host, status: status, connected: connected),
                  SettingsSection(
                    title: l.connection,
                    children: [
                      SettingsRow(label: l.serverStatus, value: status),
                      SettingsRow(label: l.serverProtocol, value: protocol, mono: true, isLast: true),
                    ],
                  ),
                  const _TrustComparison(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero: server identicon + hostname + status + operator line
// ═════════════════════════════════════════════════════════════════════

class _ServerHero extends StatelessWidget {
  final String hostname;
  final String status;
  final bool connected;
  const _ServerHero({required this.hostname, required this.status, required this.connected});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1h5, DsSpace.x3h5, DsSpace.x5h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(tokens.radiusCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(14)),
                  child: Icon(CupertinoIcons.globe, size: 24, color: tokens.text2),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        hostname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsTextArt.t17w600Mono.copyWith(color: tokens.text),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: connected ? tokens.success : tokens.text4,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(status, style: DsText.subhead.copyWith(color: tokens.text2)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Trust comparison: two chip lists (sees / can't see)
// ═════════════════════════════════════════════════════════════════════

class _TrustComparison extends StatelessWidget {
  const _TrustComparison();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpace.x5h5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x7, 0, DsSpace.x7, DsSpace.x2),
            child: Text(
              context.l10n.serverTrustTitle,
              style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
            child: Container(
              padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x4, DsSpace.x4, DsSpace.x4),
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: BorderRadius.circular(tokens.radiusCard),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TrustGroupHeader(label: context.l10n.serverSees, color: tokens.text3),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _TrustItem(label: context.l10n.serverSeesTiming, positive: false),
                      _TrustItem(label: context.l10n.serverSeesOnline, positive: false),
                      _TrustItem(label: context.l10n.serverSeesPush, positive: false),
                      _TrustItem(label: context.l10n.serverSeesQuota, positive: false),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _TrustGroupHeader(label: context.l10n.serverCantSee, color: tokens.success),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _TrustItem(label: context.l10n.serverHiddenContent, positive: true),
                      _TrustItem(label: context.l10n.serverHiddenFiles, positive: true),
                      _TrustItem(label: context.l10n.serverHiddenContacts, positive: true),
                      _TrustItem(label: context.l10n.tabCalls, positive: true),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x2, DsSpace.x7, 0),
            child: Text(
              context.l10n.serverTrustFooter,
              style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrustGroupHeader extends StatelessWidget {
  final String label;
  final Color color;
  const _TrustGroupHeader({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: color),
    );
  }
}

class _TrustItem extends StatelessWidget {
  final String label;
  final bool positive; // true = "can't see" (green), false = "sees" (neutral)
  const _TrustItem({required this.label, required this.positive});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final fg = positive ? tokens.success : tokens.text2;
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.nudge5, DsSpace.x2h5, DsSpace.nudge5),
      decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CustomPaint(
              painter: positive ? DsChipCheckGlyph(color: fg) : _ChipDotPainter(color: fg),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: DsText.caption.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipDotPainter extends CustomPainter {
  final Color color;
  _ChipDotPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), size.width * 0.28, paint);
  }

  @override
  bool shouldRepaint(_ChipDotPainter old) => old.color != color;
}
