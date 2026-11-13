// iOS-native "swipe-row" reveal — drag a row left to expose 1-3 action
// buttons (Archive / Mute / Delete pattern from Messages.app + Mail.app).
//
// Behaviour:
//   - Pan-left reveals actions (transform.translate the child by -dx).
//   - Release before the "snap-open" threshold → spring back closed.
//   - Release past the snap-open threshold → settle to fully-open
//     (actions visible at their natural width).
//   - Tap the dim backdrop area on the child while open → close.
//   - Pan past the "commit" threshold (≥ 2× actions width) → fire the
//     last action's callback and close (iOS swipe-to-delete pattern).
//   - Tap on an action button → fire its callback, then close.
//
// Built without `flutter/material.dart`. Pure widgets + AnimationController
// for spring physics.
//
// For golden screenshots: pass [debugForceRevealed] = true to lock the
// row in the open state.

import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/tokens.dart';
import '../core/haptics.dart';

class DsSwipeAction {
  final String label;
  final Color background;
  final Color foreground;
  final Widget icon;
  final VoidCallback? onTap;
  const DsSwipeAction({
    required this.label,
    required this.background,
    required this.foreground,
    required this.icon,
    this.onTap,
  });
}

class DsSwipeActions extends StatefulWidget {
  /// The row's main content. Slides left to reveal actions.
  final Widget child;

  /// 1-3 actions, drawn right-to-left in the order given (so the LAST
  /// action sits closest to the edge — that's the "destructive" slot).
  final List<DsSwipeAction> actions;

  /// Width of each action button. Defaults to 78 — same as iOS Mail.app.
  final double actionWidth;

  /// For golden screenshots; forces the open state.
  final bool debugForceRevealed;

  const DsSwipeActions({
    super.key,
    required this.child,
    required this.actions,
    this.actionWidth = 78,
    this.debugForceRevealed = false,
  });

  @override
  State<DsSwipeActions> createState() => _DsSwipeActionsState();
}

class _DsSwipeActionsState extends State<DsSwipeActions> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  double _dragStart = 0; // anchor at start of pan, in "offset" units
  double _offset = 0; // current revealed pixels (positive = open)

  double get _maxOpen => widget.actions.length * widget.actionWidth;
  double get _snapOpenThreshold => _maxOpen * 0.55;
  double get _commitThreshold => _maxOpen * 2.2; // far-swipe = delete

  @override
  void initState() {
    super.initState();
    // Ticks go through _handleTick only (attached per animation in
    // _animateTo); a second permanent listener here used to double the
    // setState calls on every frame.
    _ctrl = AnimationController(vsync: this, duration: DsMotion.base);
    if (widget.debugForceRevealed) _offset = _maxOpen;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _animateTo(double target) {
    _ctrl.stop();
    final tween = Tween<double>(begin: _offset, end: target);
    final curved = CurvedAnimation(parent: _ctrl, curve: DsMotion.springy);
    _ctrl
      ..removeListener(_handleTick)
      ..value = 0
      ..addListener(_handleTick);
    _tweenInProgress = tween.animate(curved);
    _ctrl.forward();
  }

  late Animation<double> _tweenInProgress;
  void _handleTick() {
    setState(() => _offset = _tweenInProgress.value);
  }

  void _onPanStart(DragStartDetails d) {
    _dragStart = _offset;
    _ctrl.stop();
  }

  void _onPanUpdate(DragUpdateDetails d) {
    // Negative dx (drag-left) increases the revealed offset.
    final next = (_dragStart - d.localPosition.dx + _dragStartX).clamp(0.0, _commitThreshold + 30);
    // Tick when crossing into "open" and into "far-swipe commits".
    if ((_offset < _snapOpenThreshold) != (next < _snapOpenThreshold) ||
        (_offset < _commitThreshold) != (next < _commitThreshold)) {
      DsHaptics.play(Haptic.threshold);
    }
    setState(() => _offset = next);
  }

  double _dragStartX = 0;
  void _captureStartX(DragStartDetails d) {
    _dragStartX = d.localPosition.dx;
  }

  void _onPanEnd(DragEndDetails d) {
    if (_offset >= _commitThreshold) {
      // Far swipe — commit the last action.
      widget.actions.last.onTap?.call();
      _animateTo(0);
      return;
    }
    if (_offset >= _snapOpenThreshold) {
      _animateTo(_maxOpen);
    } else {
      _animateTo(0);
    }
  }

  void _close() => _animateTo(0);

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        children: [
          // Action buttons on the right (drawn behind the row content) —
          // only while the row is pulled open: left underneath a closed
          // row they bled through its anti-aliased bottom edge as a
          // coloured hairline (seen in the key-screen goldens).
          if (_offset > 0)
            Positioned.fill(
              child: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < widget.actions.length; i++)
                      _ActionButton(
                        action: widget.actions[i],
                        width: widget.actionWidth,
                        onTap: () {
                          widget.actions[i].onTap?.call();
                          _close();
                        },
                      ),
                  ],
                ),
              ),
            ),
          // Row content, transformed left by [_offset]. Wrapped in a
          // ColoredBox(tokens.bg) so the action buttons stay hidden when
          // the row is closed — DsChatRow / DsCallRow don't have their
          // own background.
          Transform.translate(
            offset: Offset(-_offset, 0),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Tap on the content (while open) closes the row.
              onTap: _offset > 0 ? _close : null,
              onHorizontalDragStart: (d) {
                _captureStartX(d);
                _onPanStart(d);
              },
              onHorizontalDragUpdate: _onPanUpdate,
              onHorizontalDragEnd: _onPanEnd,
              child: ColoredBox(color: DsTheme.of(context).bg, child: widget.child),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final DsSwipeAction action;
  final double width;
  final VoidCallback onTap;
  const _ActionButton({required this.action, required this.width, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: width,
        color: action.background,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 22, height: 22, child: action.icon),
              const SizedBox(height: 4),
              Text(
                action.label,
                style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: action.foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
