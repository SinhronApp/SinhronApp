// Loading screen shown after the user pairs a device (or finishes "Get
// started"). Simulates the post-link / post-recovery flow: connect to the
// server, verify the device identity (Ed25519 challenge), apply the MLS
// Welcome messages for every group the user belongs to, sync contacts.
//
// Source: design/app/entry.jsx SnSettingUp.
//
// No work happens here — the account is already made on the previous step
// (SaveAccess), so this is a short confirmation: 4 steps x 300 ms + 300 ms
// = 1.5 s (ADR-108; was 5.3 s).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/sinhron_mark.dart';
import '../../l10n/l10n.dart';

enum _StepState { pending, active, done }

class _Step {
  /// Text in the app's language (resolved at build time).
  final String Function(AppL10n l) label;
  _StepState state;
  _Step(this.label, this.state);
}

class SettingUpScreen extends StatefulWidget {
  final VoidCallback? onFinished;
  final String serverHost;
  final Duration stepDuration;

  const SettingUpScreen({
    super.key,
    this.onFinished,
    // Real flows pass the chosen server (`serverHostOf(serverUrlProvider)`);
    // the default only feeds the design previews.
    this.serverHost = 'cabin.sinhron.app',
    this.stepDuration = DsMotion.slow,
  });

  @override
  State<SettingUpScreen> createState() => _SettingUpScreenState();
}

class _SettingUpScreenState extends State<SettingUpScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _spin;
  late final List<_Step> _steps;
  Timer? _stepTimer;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

    _steps = [
      _Step((l) => l.setupConnecting(widget.serverHost), _StepState.active),
      _Step((l) => l.setupIdentity, _StepState.pending),
      _Step((l) => l.setupGroups, _StepState.pending),
      _Step((l) => l.setupContacts, _StepState.pending),
    ];

    _scheduleNextStep();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The arc stands still under Reduce Motion; the steps still tick.
    if (DsMotion.reduced(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    _spin.dispose();
    super.dispose();
  }

  void _scheduleNextStep() {
    _stepTimer = Timer(widget.stepDuration, () {
      if (!mounted) return;
      final activeIdx = _steps.indexWhere((s) => s.state == _StepState.active);
      setState(() {
        if (activeIdx >= 0) _steps[activeIdx].state = _StepState.done;
        final nextIdx = activeIdx + 1;
        if (nextIdx < _steps.length) {
          _steps[nextIdx].state = _StepState.active;
          _scheduleNextStep();
        } else {
          // All done — short pause then notify parent
          Timer(DsMotion.slow, () {
            if (!mounted) return;
            widget.onFinished?.call();
          });
        }
      });
    });
  }

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
            // Top : bottom = 1 : 1.5 per design
            const Spacer(flex: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Mark + spinning arc (96pt — much more presence than 64)
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        const SinhronMark(size: 96),
                        AnimatedBuilder(
                          animation: _spin,
                          builder: (context, _) {
                            return CustomPaint(
                              size: const Size.square(96),
                              painter: _SpinningArcPainter(color: tokens.accent, rotation: _spin.value * 2 * math.pi),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 44),
                  Text(
                    context.l10n.settingUp,
                    style: DsText.title1.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                  const SizedBox(height: 36),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < _steps.length; i++) ...[
                        if (i > 0) const SizedBox(height: 18),
                        _StepRow(step: _steps[i]),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const Spacer(flex: 3),
          ],
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final _Step step;
  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final isPending = step.state == _StepState.pending;
    return Row(
      children: [
        _StepIndicator(state: step.state),
        const SizedBox(width: 14),
        Text(step.label(context.l10n), style: DsText.bodyLarge.copyWith(color: isPending ? tokens.text3 : tokens.text)),
      ],
    );
  }
}

class _StepIndicator extends StatelessWidget {
  final _StepState state;
  const _StepIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      width: 24,
      height: 24,
      child: switch (state) {
        _StepState.done => DecoratedBox(
          decoration: BoxDecoration(color: tokens.success, shape: BoxShape.circle),
          child: Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CustomPaint(painter: DsGlyphPainter(DsGlyph.check, color: tokens.accentText)),
            ),
          ),
        ),
        _StepState.active => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: tokens.accent, width: 2.5),
          ),
          child: Padding(
            padding: const EdgeInsets.all(DsSpace.x0h5),
            child: DecoratedBox(
              decoration: BoxDecoration(color: tokens.accent, shape: BoxShape.circle),
            ),
          ),
        ),
        _StepState.pending => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: tokens.text4, width: 1.5),
          ),
        ),
      },
    );
  }
}

class _SpinningArcPainter extends CustomPainter {
  final Color color;
  final double rotation;
  _SpinningArcPainter({required this.color, required this.rotation});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    // r = 30 in the 64-viewBox per design (stroke is centred, so radius
    // slightly smaller than half-width to avoid clipping).
    final radius = size.width / 2 - 2;
    final rect = Rect.fromCircle(center: Offset(size.width / 2, size.height / 2), radius: radius);
    // Sweep ≈ 72° to roughly match strokeDasharray="40 200" on circumference≈188.
    const sweep = math.pi * 2 / 5;
    canvas.drawArc(rect, rotation, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_SpinningArcPainter old) => old.rotation != rotation || old.color != color;
}
