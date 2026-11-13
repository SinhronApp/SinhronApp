// Invite landing — first screen a brand-new user sees when they open
// Sinhron via an invite link — ADR-043: `https://<server>/join#<signed>`
// (navigation.dart `handleInviteLink`).
//
// Per spec §6.1 (Invites), the invite token isn't a credential — it's a
// pointer to the server + first contact. The user still creates their own
// identity (display name + recovery phrase) afterwards. This landing
// surfaces who-invited-whom + server reachability so the user can confirm
// before committing to the account setup.
//
// Layout:
//   1. Top bar: back chevron (no title)
//   2. Eyebrow chip: "INVITE LINK" with link glyph
//   3. Big title + 1-line summary
//   4. Server card: gradient icon + mono host + green "Reachable · 28 ms"
//      + divider + inviter row (avatar + name)
//   5. Token row: bgSoft pill with mono token + amber "Expires in 22h" pill
//   6. "NEXT STEPS" numbered list (3 items)
//   7. Bottom: "Accept & set up" primary + "I already have an account" ghost

import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_icon.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_shared_glyphs.dart';

class InviteLandingScreen extends StatelessWidget {
  final String server;
  final String inviterName;
  final String inviterUsername;
  final String token;
  final String expiresIn;
  final VoidCallback? onBack;
  final VoidCallback? onAccept;
  final VoidCallback? onAlreadyHaveAccount;

  /// ADR-043 — a real signed invite link (the defaults above are the design
  /// gallery's). [reachability]: what the server check said (null → the
  /// gallery's sample); [reachable] colours it. [token] empty → no key row;
  /// [expiresIn] empty → no expiry pill. [showSteps]: the "next steps" list
  /// (a new account). [acceptLabel] replaces "Accept & set up" (adding a
  /// contact to an existing account). [busy]: checking / saving. [error]:
  /// shown under the card.
  final String? reachability;
  final bool reachable;
  final bool showSteps;
  final String? acceptLabel;
  final bool busy;
  final String? error;

  const InviteLandingScreen({
    super.key,
    this.server = 'cabin.sinhron.app',
    this.inviterName = 'Henry Park',
    this.inviterUsername = '@henry',
    this.token = 'inv_7K9d-c4eR-b8fA-zNm2',
    this.expiresIn = '22h',
    this.onBack,
    this.onAccept,
    this.onAlreadyHaveAccount,
    this.reachability,
    this.reachable = true,
    this.showSteps = true,
    this.acceptLabel,
    this.busy = false,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            _BareTopBar(onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(DsSpace.x5h5, DsSpace.x1, DsSpace.x5h5, 0),
                children: [
                  const _Eyebrow(),
                  const SizedBox(height: 14),
                  Text(
                    context.l10n.inviteLandingTitle,
                    style: DsText.title1.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.inviteLandingBody,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
                  ),
                  const SizedBox(height: 22),
                  _ServerCard(
                    server: server,
                    inviterName: inviterName,
                    inviterUsername: inviterUsername,
                    reachability: reachability ?? context.l10n.inviteReachable(28),
                    reachable: reachable,
                  ),
                  if (token.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _TokenRow(token: token, expiresIn: expiresIn),
                  ],
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      error!,
                      key: const ValueKey('invite-error'),
                      style: DsText.subhead.copyWith(color: tokens.danger),
                    ),
                  ],
                  if (showSteps) ...[
                    const SizedBox(height: 22),
                    const _StepsHeader(),
                    const SizedBox(height: 10),
                    _StepRow(n: 1, title: context.l10n.inviteStepName, body: context.l10n.inviteStepNameBody),
                    const SizedBox(height: 12),
                    _StepRow(n: 2, title: context.l10n.inviteStepPhrase, body: context.l10n.inviteStepPhraseBody),
                    const SizedBox(height: 12),
                    _StepRow(
                      n: 3,
                      title: context.l10n.inviteStepDone,
                      body: context.l10n.inviteStepDoneBody(inviterName),
                    ),
                  ],
                  const SizedBox(height: 28),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x5h5, DsSpace.x2h5, DsSpace.x5h5, DsSpace.x2),
              child: Column(
                children: [
                  DsButton(
                    key: const ValueKey('invite-accept'),
                    label: acceptLabel ?? context.l10n.inviteAccept,
                    variant: DsButtonVariant.primary,
                    loading: busy,
                    onPressed: busy ? null : onAccept,
                    leading: SizedBox(
                      width: 16,
                      height: 16,
                      child: CustomPaint(painter: DsGlyphPainter(DsGlyph.check, color: DsPalette.white)),
                    ),
                  ),
                  if (onAlreadyHaveAccount != null) ...[
                    const SizedBox(height: 6),
                    DsButton(
                      label: context.l10n.inviteHaveAccount,
                      variant: DsButtonVariant.ghost,
                      size: DsButtonSize.medium,
                      onPressed: onAlreadyHaveAccount,
                    ),
                  ],
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
// Top bar — no title
// ═════════════════════════════════════════════════════════════════════

class _BareTopBar extends StatelessWidget {
  final VoidCallback? onBack;
  const _BareTopBar({this.onBack});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          if (onBack != null)
            Semantics(button: true, label: context.l10n.a11yBack, excludeSemantics: true, onTap: onBack, child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onBack,
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CustomPaint(painter: DsGlyphPainter(DsGlyph.back, color: tokens.text)),
                  ),
                ),
              ),
            )),
          const Spacer(),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Eyebrow chip
// ═════════════════════════════════════════════════════════════════════

class _Eyebrow extends StatelessWidget {
  const _Eyebrow();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.nudge5, DsSpace.x2h5, DsSpace.nudge5),
        decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CustomPaint(painter: _LinkChainPainter(color: tokens.accent)),
            ),
            const SizedBox(width: 7),
            Text(
              context.l10n.inviteEyebrow,
              style: DsText.caption.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _LinkChainPainter extends CustomPainter {
  final Color color;
  _LinkChainPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final right = Path()
      ..moveTo(10, 14)
      ..arcToPoint(const Offset(15.66, 14), radius: const Radius.circular(4))
      ..lineTo(18.66, 11)
      ..arcToPoint(const Offset(13, 5.34), radius: const Radius.circular(4))
      ..lineTo(11.5, 7);
    canvas.drawPath(right, stroke);
    final left = Path()
      ..moveTo(14, 10)
      ..arcToPoint(const Offset(8.34, 10), radius: const Radius.circular(4), clockwise: false)
      ..lineTo(5.34, 13)
      ..arcToPoint(const Offset(11, 18.66), radius: const Radius.circular(4), clockwise: false)
      ..lineTo(12.5, 17);
    canvas.drawPath(left, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinkChainPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Server card — host + reachability + inviter row
// ═════════════════════════════════════════════════════════════════════

class _ServerCard extends StatelessWidget {
  final String server;
  final String inviterName;
  final String inviterUsername;
  final String reachability;
  final bool reachable;
  const _ServerCard({
    required this.server,
    required this.inviterName,
    required this.inviterUsername,
    required this.reachability,
    required this.reachable,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x4, DsSpace.x4, DsSpace.x3h5),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tokens.divider, width: 0.5),
        boxShadow: DsShadow.card,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [DsPalette.sky, DsPalette.blue],
                  ),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CustomPaint(painter: DsServerStackGlyph(color: DsPalette.white)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      server,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsTextArt.t14w600Monov2.copyWith(color: tokens.text),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: reachable ? tokens.success : tokens.text3,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            reachability,
                            style: DsText.footnote.copyWith(
                              fontWeight: FontWeight.w600,
                              height: 1.0,
                              color: reachable ? tokens.success : tokens.text3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(height: 0.5, color: tokens.divider),
          const SizedBox(height: 12),
          Row(
            children: [
              DsAvatar(name: inviterName, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.l10n.inviteInvitedBy,
                      style: DsText.footnote.copyWith(height: 1.1, color: tokens.text3),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      inviterUsername.isEmpty ? inviterName : '$inviterName · $inviterUsername',
                      style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Token row
// ═════════════════════════════════════════════════════════════════════

class _TokenRow extends StatelessWidget {
  final String token;
  final String expiresIn;
  const _TokenRow({required this.token, required this.expiresIn});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.nudge11, DsSpace.nudge11, DsSpace.nudge11),
      decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CustomPaint(painter: _KeyGlyphPainter(color: tokens.text3)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              token,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsTextArt.t13w500Monov2.copyWith(color: tokens.text),
            ),
          ),
          if (expiresIn.isNotEmpty) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.nudge3, DsSpace.x2, DsSpace.nudge3),
              decoration: BoxDecoration(color: DsPalette.orange14, borderRadius: BorderRadius.circular(5)),
              child: Text(context.l10n.inviteExpiresInHours(22), style: DsTextArt.t10p5w700),
            ),
          ],
        ],
      ),
    );
  }
}

class _KeyGlyphPainter extends CustomPainter {
  final Color color;
  _KeyGlyphPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(8, 14), 4, stroke);
    canvas.drawLine(const Offset(11, 11), const Offset(20, 2), stroke);
    canvas.drawLine(const Offset(20, 2), const Offset(22, 4), stroke);
    canvas.drawLine(const Offset(18, 4), const Offset(20, 6), stroke);
    canvas.drawLine(const Offset(15.5, 6.5), const Offset(17.5, 8.5), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_KeyGlyphPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Steps
// ═════════════════════════════════════════════════════════════════════

class _StepsHeader extends StatelessWidget {
  const _StepsHeader();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        context.l10n.inviteNextSteps,
        style: DsText.caption.copyWith(fontWeight: FontWeight.w700, color: tokens.text3),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final int n;
  final String title;
  final String body;
  const _StepRow({required this.n, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 24,
          height: 24,
          margin: const EdgeInsets.only(top: DsSpace.nudge1),
          decoration: BoxDecoration(color: tokens.accentSoft, shape: BoxShape.circle),
          child: Center(
            child: Text(
              '$n',
              style: DsText.footnote.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.accent),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: DsText.subhead.copyWith(color: tokens.text2),
              children: [
                TextSpan(
                  text: title,
                  style: TextStyle(fontWeight: FontWeight.w600, color: tokens.text),
                ),
                TextSpan(text: ' · $body'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
