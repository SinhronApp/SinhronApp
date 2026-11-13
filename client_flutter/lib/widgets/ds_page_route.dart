// Push transition — UI backlog §4 items 35 and 37. iOS slide with the
// interactive edge-swipe back (CupertinoPageRoute); with Reduce Motion
// on, a plain crossfade instead (no sideways movement).

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';

class DsPageRoute<T> extends CupertinoPageRoute<T> {
  DsPageRoute({required super.builder, super.fullscreenDialog, super.settings});

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (DsMotion.reduced(context)) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: DsMotion.enter),
        child: child,
      );
    }
    return super.buildTransitions(context, animation, secondaryAnimation, child);
  }
}
