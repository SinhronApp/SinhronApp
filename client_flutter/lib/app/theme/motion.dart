// Motion tokens — UI backlog §4 items 33 and 37. One vocabulary for every
// animation in the app: durations, curves, springs, and "Reduce Motion".

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

abstract final class DsMotion {
  // The one speed table (ADR-108, "Тихий"): 120 / 200 / 300 ms. Explicit
  // durations elsewhere should be one of these three.

  /// Taps, toggles, small fades.
  static const fast = Duration(milliseconds: 120);

  /// Most transitions (sheets, bubbles, banners).
  static const base = Duration(milliseconds: 200);

  /// Large movements (full-screen, hero-like).
  static const slow = Duration(milliseconds: 300);

  /// A quick tap stays highlighted at least this long, so it is seen.
  static const minPress = Duration(milliseconds: 90);

  /// Things arriving / settling.
  static const Curve enter = Curves.easeOutCubic;

  /// Things leaving.
  static const Curve exit = Curves.easeInCubic;

  /// Material-3 "emphasized" — fast start, long gentle settle.
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// Snappy, no overshoot to speak of — sheets, menus.
  static const spring = SpringDescription(mass: 1, stiffness: 420, damping: 36);

  /// Playful overshoot — only reactions and count badges (ADR-108).
  static const springBouncy = SpringDescription(mass: 1, stiffness: 320, damping: 17);

  /// [springBouncy] as a curve (for transitions / animateTo).
  static final Curve springy = _SpringCurve(springBouncy);

  /// Any spring as a curve.
  static Curve springCurve(SpringDescription s) => _SpringCurve(s);

  /// iOS "Reduce Motion" / Android "Remove animations".
  static bool reduced(BuildContext context) {
    final mq = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final view = View.maybeOf(context);
    return mq || (view?.platformDispatcher.accessibilityFeatures.reduceMotion ?? false);
  }

  /// [d], or zero when the user asked for less motion.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}

/// Normalised spring response 0 → 1 (may overshoot above 1). The
/// curve's 0..1 time is mapped onto the time the spring needs to settle.
class _SpringCurve extends Curve {
  _SpringCurve(SpringDescription spring) : _sim = SpringSimulation(spring, 0, 1, 0) {
    var t = 0.0;
    while (t < 3 && !_sim.isDone(t)) {
      t += 0.01;
    }
    _settle = t;
  }

  final SpringSimulation _sim;
  late final double _settle;

  @override
  double transformInternal(double t) => _sim.x(t * _settle);
}
