// Animated count — UI backlog §4 item 36. A changed number pops in with
// a little spring instead of just swapping (unread badges, folder
// counts). Reduce Motion → plain swap.

import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';

class DsAnimatedCount extends StatelessWidget {
  const DsAnimatedCount({super.key, required this.count, required this.style, this.max = 99});

  final int count;
  final TextStyle style;

  /// Above this shows "99+".
  final int max;

  @override
  Widget build(BuildContext context) {
    final label = count > max ? '$max+' : '$count';
    return AnimatedSwitcher(
      duration: DsMotion.of(context, DsMotion.base),
      switchInCurve: DsMotion.springy,
      switchOutCurve: DsMotion.exit,
      transitionBuilder: (child, anim) => ScaleTransition(
        scale: Tween(begin: 0.6, end: 1.0).animate(anim),
        child: FadeTransition(opacity: anim, child: child),
      ),
      child: Text(label, key: ValueKey(label), style: style),
    );
  }
}
