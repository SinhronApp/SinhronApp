// Swipe a bubble left to reply — UI backlog §3 item 22 (Telegram-style).
// A reply arrow fades in; crossing the threshold ticks a haptic, letting
// go past it replies; the bubble springs back either way.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';

class SwipeToReply extends StatefulWidget {
  const SwipeToReply({super.key, required this.child, this.onReply, this.onThreshold});

  final Widget child;

  /// null = swiping disabled (e.g. deleted messages, selection mode).
  final VoidCallback? onReply;

  /// Crossed the threshold (haptic).
  final VoidCallback? onThreshold;

  static const threshold = 64.0;
  static const maxPull = 96.0;

  @override
  State<SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<SwipeToReply> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this);
  bool _armed = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _update(DragUpdateDetails d) {
    // Only leftwards; rubber-band past the threshold.
    var x = (_c.value + d.delta.dx).clamp(-SwipeToReply.maxPull, 0.0);
    if (x < -SwipeToReply.threshold) {
      final over = -x - SwipeToReply.threshold;
      x = -SwipeToReply.threshold - over * 0.5;
    }
    _c.value = x;
    final armed = -x >= SwipeToReply.threshold * 0.95;
    if (armed && !_armed) widget.onThreshold?.call();
    _armed = armed;
  }

  void _end(DragEndDetails _) {
    if (_armed) widget.onReply?.call();
    _armed = false;
    if (DsMotion.reduced(context)) {
      _c.value = 0;
    } else {
      _c.animateWith(SpringSimulation(DsMotion.spring, _c.value, 0, 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onReply == null) return widget.child;
    final tokens = DsTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: _end,
      onHorizontalDragCancel: () => _end(DragEndDetails()),
      child: AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          final t = (-_c.value / SwipeToReply.threshold).clamp(0.0, 1.0);
          return Stack(
            alignment: Alignment.centerRight,
            children: [
              if (t > 0)
                Positioned(
                  right: 14,
                  child: Opacity(
                    opacity: t,
                    child: Transform.scale(
                      scale: 0.6 + 0.4 * t,
                      child: Container(
                        key: const ValueKey('reply-arrow'),
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
                        alignment: Alignment.center,
                        child: Icon(CupertinoIcons.reply, size: 18, color: tokens.text2),
                      ),
                    ),
                  ),
                ),
              Transform.translate(offset: Offset(_c.value, 0), child: child),
            ],
          );
        },
      ),
    );
  }
}
