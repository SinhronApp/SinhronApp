// First-launch onboarding splash. 3 swipeable cards, shown ONCE before Welcome.
// Source: design/app/onboarding-splash.jsx
//
// Cards:
//   1. "Premium chat. Private by default." — hero: layered chat bubbles + lock
//   2. "No email, no phone, no password." — hero: crossed-out @ symbol
//   3. "Sinhron runs on a server you trust." — hero: server rack + devices
//
// Per README cross-cutting #1 (E2EE invisible by default): card 1's lock badge
// is the ONE exception — it's the explicit "welcome to encryption" moment.
// All other screens hide the encryption story.

import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_button.dart';
import '../../l10n/l10n.dart';

class OnboardingSplashScreen extends StatefulWidget {
  final VoidCallback? onFinish;
  const OnboardingSplashScreen({super.key, this.onFinish});

  @override
  State<OnboardingSplashScreen> createState() => _OnboardingSplashScreenState();
}

class _OnboardingSplashScreenState extends State<OnboardingSplashScreen> {
  late final PageController _pager;
  int _index = 0;
  static const int _total = 3;

  @override
  void initState() {
    super.initState();
    _pager = PageController();
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _onContinue() {
    if (_index < _total - 1) {
      _pager.nextPage(duration: DsMotion.of(context, DsMotion.base), curve: DsMotion.enter);
    } else {
      widget.onFinish?.call();
    }
  }

  void _onSkip() => widget.onFinish?.call();

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
            // Top: Skip
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x3h5, DsSpace.x4h5, 0),
              child: Row(
                children: [
                  const Spacer(),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _onSkip,
                    child: Padding(
                      padding: const EdgeInsets.all(DsSpace.x1h5),
                      child: Text(
                        context.l10n.skip,
                        style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Pager
            Expanded(
              child: PageView(
                controller: _pager,
                onPageChanged: (i) => setState(() => _index = i),
                physics: const BouncingScrollPhysics(),
                children: const [_CardWelcome(), _CardNoIdentity(), _CardServer()],
              ),
            ),

            // Bottom: dots + CTA
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x5h5, 0, DsSpace.x5h5, DsSpace.x4h5),
              child: Column(
                children: [
                  _Dots(index: _index, total: _total),
                  const SizedBox(height: 8),
                  DsButton(
                    label: _index == _total - 1 ? context.l10n.getStarted : context.l10n.continueBtn,
                    variant: DsButtonVariant.primary,
                    trailing: const _ChevronRight(),
                    onPressed: _onContinue,
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

// ─────────────────────────────────────────────────────────────────────
// Card 1 — Welcome
// ─────────────────────────────────────────────────────────────────────
class _CardWelcome extends StatelessWidget {
  const _CardWelcome();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return _CardLayout(
      hero: const _HeroLayered(),
      eyebrow: context.l10n.welcome,
      title: context.l10n.privateByDefault,
      content: Text(context.l10n.splash1Body, style: _bodyStyle(tokens)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Card 2 — No identity
// ─────────────────────────────────────────────────────────────────────
class _CardNoIdentity extends StatelessWidget {
  const _CardNoIdentity();

  @override
  Widget build(BuildContext context) {
    return _CardLayout(
      hero: const _HeroNoIdentity(),
      eyebrow: context.l10n.splash2Eyebrow,
      title: context.l10n.splash2Title,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChecklistItem(no: true, k: context.l10n.noEmail, v: context.l10n.noEmailV),
          SizedBox(height: 14),
          _ChecklistItem(no: true, k: context.l10n.noPhone, v: context.l10n.noPhoneV),
          SizedBox(height: 14),
          _ChecklistItem(no: true, k: context.l10n.noPassword, v: context.l10n.noPasswordV),
          SizedBox(height: 14),
          _ChecklistItem(no: false, k: context.l10n.ownKey, v: context.l10n.ownKeyV),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Card 3 — Self-hosted
// ─────────────────────────────────────────────────────────────────────
class _CardServer extends StatelessWidget {
  const _CardServer();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return _CardLayout(
      hero: const _HeroServer(),
      eyebrow: context.l10n.selfHosted,
      title: context.l10n.serverTrust,
      content: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: context.l10n.serverRun),
            TextSpan(text: context.l10n.serverData),
          ],
          style: _bodyStyle(tokens),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Shared layout for one card: hero + eyebrow + title + content
// ─────────────────────────────────────────────────────────────────────
class _CardLayout extends StatelessWidget {
  final Widget hero;
  final String eyebrow;
  final String title;
  final Widget content;

  const _CardLayout({required this.hero, required this.eyebrow, required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6h5, 0, DsSpace.x6h5, 0),
      physics: const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 32),
          Center(child: hero),
          const SizedBox(height: 30),
          _EyebrowPill(text: eyebrow),
          const SizedBox(height: 14),
          Text(
            title,
            style: DsText.display.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
          ),
          const SizedBox(height: 12),
          content,
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

TextStyle _bodyStyle(DsTokens tokens) => DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text2);

// ─────────────────────────────────────────────────────────────────────
// Eyebrow — small accent-soft pill with accent text
// ─────────────────────────────────────────────────────────────────────
class _EyebrowPill extends StatelessWidget {
  final String text;
  const _EyebrowPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x1),
      decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(999)),
      child: Text(
        text.toUpperCase(),
        style: DsText.caption.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.accent),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Checklist item: 24px round icon (accent-soft or bg-soft) + bold key + value
// ─────────────────────────────────────────────────────────────────────
class _ChecklistItem extends StatelessWidget {
  final bool no;
  final String k;
  final String v;
  const _ChecklistItem({required this.no, required this.k, required this.v});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final bg = no ? tokens.bgSoft : tokens.accentSoft;
    final fg = no ? tokens.text3 : tokens.accent;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: DsSpace.x0h5),
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            child: Center(
              child: SizedBox(
                width: 12,
                height: 12,
                child: CustomPaint(
                  painter: _CheckOrCrossPainter(color: fg, isCross: no),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: k,
                  style: TextStyle(fontFamily: DsType.family, fontWeight: FontWeight.w600, color: tokens.text),
                ),
                TextSpan(
                  text: ' · $v',
                  style: TextStyle(fontFamily: DsType.family, fontWeight: FontWeight.w500, color: tokens.text2),
                ),
              ],
            ),
            style: DsText.callout,
          ),
        ),
      ],
    );
  }
}

class _CheckOrCrossPainter extends CustomPainter {
  final Color color;
  final bool isCross;
  _CheckOrCrossPainter({required this.color, required this.isCross});

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = isCross ? 2.8 : 3.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (isCross) {
      canvas.drawLine(const Offset(5, 5), const Offset(19, 19), paint);
      canvas.drawLine(const Offset(19, 5), const Offset(5, 19), paint);
    } else {
      final p = Path()
        ..moveTo(5, 12)
        ..lineTo(10, 17)
        ..lineTo(20, 7);
      canvas.drawPath(p, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CheckOrCrossPainter old) => old.color != color || old.isCross != isCross;
}

// ─────────────────────────────────────────────────────────────────────
// Pager dots: active = 22×6 accent, inactive = 6×6 text-4
// ─────────────────────────────────────────────────────────────────────
class _Dots extends StatelessWidget {
  final int index;
  final int total;
  const _Dots({required this.index, required this.total});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: DsSpace.x1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (int i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            AnimatedContainer(
              duration: DsMotion.of(context, DsMotion.fast),
              curve: Curves.easeOut,
              width: i == index ? 22 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == index ? tokens.accent : tokens.text4,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
// Chevron-right icon for the CTA trailing slot
// ─────────────────────────────────────────────────────────────────────
class _ChevronRight extends StatelessWidget {
  const _ChevronRight();

  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color ?? DsPalette.white;
    return SizedBox(width: 16, height: 16, child: CustomPaint(painter: _ChevronRightPainter(color)));
  }
}

class _ChevronRightPainter extends CustomPainter {
  final Color color;
  _ChevronRightPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(9, 5)
      ..lineTo(16, 12)
      ..lineTo(9, 19);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ChevronRightPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Hero illustrations
// ═════════════════════════════════════════════════════════════════════

class _HeroLayered extends StatelessWidget {
  const _HeroLayered();

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: 200, height: 170, child: CustomPaint(painter: _HeroLayeredPainter()));
  }
}

class _HeroLayeredPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 3 layered chat bubbles
    final amber = Paint()..color = DsPalette.peach;
    final blue = Paint()..color = DsPalette.sky;
    final violet = Paint()..color = DsPalette.lilac;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(20, 32, 120, 36), const Radius.circular(14)), amber);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(55, 76, 130, 36), const Radius.circular(14)), blue);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(30, 120, 100, 36), const Radius.circular(14)), violet);

    // Lock badge
    final accent = Paint()..color = DsPalette.blue;
    canvas.drawCircle(const Offset(170, 38), 22, accent);

    final white = Paint()
      ..color = DsPalette.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // lock body
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(160, 34, 20, 14), const Radius.circular(3)), white);
    // lock shackle
    final shackle = Path()
      ..moveTo(163, 34)
      ..lineTo(163, 31)
      ..arcToPoint(const Offset(177, 31), radius: const Radius.circular(7))
      ..lineTo(177, 34);
    canvas.drawPath(shackle, white);
  }

  @override
  bool shouldRepaint(_HeroLayeredPainter old) => false;
}

class _HeroNoIdentity extends StatelessWidget {
  const _HeroNoIdentity();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      width: 200,
      height: 170,
      child: CustomPaint(painter: _HeroNoIdentityPainter(strokeColor: tokens.text4)),
    );
  }
}

class _HeroNoIdentityPainter extends CustomPainter {
  final Color strokeColor;
  _HeroNoIdentityPainter({required this.strokeColor});

  @override
  void paint(Canvas canvas, Size size) {
    // @ symbol — outer + inner circle + dangling stroke
    final stroke = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawCircle(const Offset(80, 85), 60, stroke);
    canvas.drawCircle(const Offset(80, 85), 22, stroke);

    final dangle = Path()
      ..moveTo(105, 85)
      ..lineTo(105, 100)
      ..arcToPoint(const Offset(129, 100), radius: const Radius.circular(12))
      ..lineTo(129, 85);
    canvas.drawPath(dangle, stroke);

    // Diagonal strike-through
    final strike = Paint()
      ..color = DsPalette.salmon
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(30, 30), const Offset(150, 150), strike);

    // Recovery-phrase tiles
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(120, 20, 60, 22), const Radius.circular(6)),
      Paint()..color = DsPalette.sky,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(130, 48, 60, 22), const Radius.circular(6)),
      Paint()..color = DsPalette.mint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(const Rect.fromLTWH(140, 76, 50, 22), const Radius.circular(6)),
      Paint()..color = DsPalette.lilac,
    );
  }

  @override
  bool shouldRepaint(_HeroNoIdentityPainter old) => old.strokeColor != strokeColor;
}

class _HeroServer extends StatelessWidget {
  const _HeroServer();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      width: 200,
      height: 170,
      child: CustomPaint(
        painter: _HeroServerPainter(deviceStroke: tokens.text3, linkStroke: tokens.text4),
      ),
    );
  }
}

class _HeroServerPainter extends CustomPainter {
  final Color deviceStroke;
  final Color linkStroke;
  _HeroServerPainter({required this.deviceStroke, required this.linkStroke});

  @override
  void paint(Canvas canvas, Size size) {
    // Server rack — 3 stacked rounded rects with white indicator dot
    final rack = [(DsPalette.blue, 20.0), (DsPalette.violet, 64.0), (DsPalette.emerald, 108.0)];
    final white = Paint()..color = DsPalette.white;
    for (final (color, y) in rack) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(50, y, 100, 36), const Radius.circular(6)),
        Paint()..color = color,
      );
      canvas.drawCircle(Offset(64, y + 18), 3, white);
    }

    // Side devices — outlined rounded rects
    final device = Paint()
      ..color = deviceStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(6, 58, 28, 44), const Radius.circular(5)), device);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(166, 58, 28, 44), const Radius.circular(5)), device);

    // Connection lines
    final link = Paint()
      ..color = linkStroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(34, 80), const Offset(46, 80), link);
    canvas.drawLine(const Offset(154, 80), const Offset(166, 80), link);
  }

  @override
  bool shouldRepaint(_HeroServerPainter old) => old.deviceStroke != deviceStroke || old.linkStroke != linkStroke;
}
