// Translucent bar — UI backlog §5 item 41. Content scrolls under it and
// shows through blurred, like iOS bars. Reduce Transparency is honoured
// through high-contrast mode (solid background).

import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';

class DsBlurBar extends StatelessWidget {
  const DsBlurBar({super.key, required this.child, this.top = false, this.bottom = false});

  final Widget child;

  /// Hairline on the top / bottom edge.
  final bool top;
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final solid = MediaQuery.maybeHighContrastOf(context) ?? false;
    final side = BorderSide(color: tokens.dividerStrong, width: 0.5);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: solid ? tokens.bg : tokens.bg.withValues(alpha: 0.82),
        border: Border(top: top ? side : BorderSide.none, bottom: bottom ? side : BorderSide.none),
      ),
      child: child,
    );
    if (solid) return box;
    return ClipRect(
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20), child: box),
    );
  }
}
