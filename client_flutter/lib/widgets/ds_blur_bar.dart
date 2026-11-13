// A bar. Solid by default; `glass: true` (only the tab bar on iPhone / iPad)
// makes it translucent: content scrolls under it and shows through blurred.
// Blur is costly — every frame of scrolling under it is re-blurred — so
// nothing else asks for it. High-contrast mode is always solid.

import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';

class DsBlurBar extends StatelessWidget {
  const DsBlurBar({super.key, required this.child, this.top = false, this.bottom = false, this.glass = false});

  final Widget child;

  /// Hairline on the top / bottom edge.
  final bool top;
  final bool bottom;

  /// true → translucent with blur; false (default) → opaque, no blur.
  final bool glass;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final solid = !glass || (MediaQuery.maybeHighContrastOf(context) ?? false);
    final side = BorderSide(color: tokens.divider, width: 0.5);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: solid ? tokens.bg : tokens.bg.withValues(alpha: 0.88),
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
