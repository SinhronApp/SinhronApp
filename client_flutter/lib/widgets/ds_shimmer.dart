// Shimmer primitive — wraps a tree of skeleton rectangles in an
// animated highlight sweep. Used while the local decrypted store is
// catching up after launch (the only time most surfaces have an empty
// state to fill in, per spec §8.4).
//
// Composition:
//   • [DsShimmer] — top-level wrapper. Applies a left-to-right gradient
//     sweep via ShaderMask + BlendMode.srcATop, so only existing pixels
//     get re-tinted (i.e. the skeleton shapes you placed inside).
//   • [DsSkel] — convenience rounded-rect in the bone color (bgSoft).
//     Take width / height / radius; defaults are reasonable for text-line
//     skeletons (radius 6).
//   • [DsSkelCircle] — same idea but a circle, for avatars.

import 'package:flutter/widgets.dart';

import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';

class DsShimmer extends StatefulWidget {
  final Widget child;
  final Duration period;

  const DsShimmer({
    super.key,
    required this.child,
    this.period = const Duration(milliseconds: 1400),
  });

  @override
  State<DsShimmer> createState() => _DsShimmerState();
}

class _DsShimmerState extends State<DsShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.period)..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final isDark = DsTheme.isDarkOf(context);
    final base = tokens.bgSoft;
    // Highlight: brighter on light theme, lighter-than-bone on dark theme.
    final highlight = isDark
        ? Color.lerp(base, DsPalette.white, 0.10)!
        : Color.lerp(base, DsPalette.white, 0.55)!;

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, child) {
        final t = _ctrl.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              // The sweep spans the rect twice — once travelling on, once off.
              colors: [base, highlight, base],
              stops: [
                (t - 0.35).clamp(0.0, 1.0),
                t.clamp(0.0, 1.0),
                (t + 0.35).clamp(0.0, 1.0),
              ],
            ).createShader(rect);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// Rounded-rectangle skeleton bone. Defaults to bgSoft + radius 6.
class DsSkel extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final EdgeInsetsGeometry? margin;

  const DsSkel({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.radius = 6,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: width,
      height: height,
      margin: margin,
      decoration: BoxDecoration(
        color: tokens.bgSoft,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Circular skeleton — for avatars and round buttons.
class DsSkelCircle extends StatelessWidget {
  final double size;
  const DsSkelCircle({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
    );
  }
}
