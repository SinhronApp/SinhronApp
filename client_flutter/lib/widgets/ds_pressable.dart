// Press feedback — UI backlog §4 item 36. Anything tappable shrinks a
// touch and dims while the finger is down, then eases back; optional
// haptic on tap. A quick tap stays pressed for DsMotion.minPress so it is
// seen (onTap itself is not delayed). Respects Reduce Motion (dim only, no
// scale).

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../core/haptics.dart';

class DsPressable extends StatefulWidget {
  const DsPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
        this.haptic,
    this.behavior = HitTestBehavior.opaque,
    this.pressedColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed (1 = no shrink, e.g. full-width rows use 0.985).
  final double scale;
    final Haptic? haptic;
  final HitTestBehavior behavior;

  /// List rows: tint the background while pressed instead of dimming.
  final Color? pressedColor;

  @override
  State<DsPressable> createState() => _DsPressableState();
}

class _DsPressableState extends State<DsPressable> {
  bool _down = false;
  final _held = Stopwatch(); // not the wall clock: that can jump
  Timer? _release;

  void _set(bool v) {
    _release?.cancel();
    if (v) {
      _held
        ..reset()
        ..start();
    } else if (_down) {
      // A quick tap: hold the highlight until it has been seen.
      final left = DsMotion.minPress - _held.elapsed;
      if (left > Duration.zero) {
        _release = Timer(left, () => _apply(false));
        return;
      }
    }
    _apply(v);
  }

  void _apply(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  void dispose() {
    _release?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final reduced = DsMotion.reduced(context);
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic != null) DsHaptics.play(widget.haptic!);
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down && !reduced ? widget.scale : 1,
        duration: _down ? DsMotion.fast : DsMotion.base,
        curve: DsMotion.enter,
        child: widget.pressedColor != null
            ? AnimatedContainer(
                duration: _down ? Duration.zero : DsMotion.base,
                color: _down ? widget.pressedColor : widget.pressedColor!.withValues(alpha: 0),
                child: widget.child,
              )
            : AnimatedOpacity(opacity: _down ? 0.75 : 1, duration: DsMotion.fast, child: widget.child),
      ),
    );
  }
}
