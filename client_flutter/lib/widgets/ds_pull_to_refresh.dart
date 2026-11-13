// iOS-native pull-to-refresh — pull a scrollable down past the top to
// reveal a rotating loader, release past threshold to commit refresh.
//
// Built without flutter/material.dart. We listen to ScrollNotifications,
// compute an overscroll offset, and reveal an iOS-style spoke wheel that
// fills progressively as you pull. Once you cross the threshold (~80px),
// releasing fires the [onRefresh] callback and the wheel spins until
// the Future resolves.
//
// Usage:
//   DsPullToRefresh(
//     onRefresh: () async => await viewModel.reload(),
//     child: ListView(...),
//   )

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import '../core/haptics.dart';

enum _PullState { idle, pulling, releasing, refreshing }

class DsPullToRefresh extends StatefulWidget {
  final Future<void> Function() onRefresh;
  final Widget child;

  /// Pixels to pull before the refresh commits.
  final double threshold;

  const DsPullToRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.threshold = 80,
  });

  @override
  State<DsPullToRefresh> createState() => _DsPullToRefreshState();
}

class _DsPullToRefreshState extends State<DsPullToRefresh>
    with SingleTickerProviderStateMixin {
  _PullState _state = _PullState.idle;
  double _overscroll = 0;
  late final AnimationController _spinner;

  @override
  void initState() {
    super.initState();
    // Spins only while refreshing — an always-running ticker would keep
    // the chat list producing frames at idle.
    _spinner = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _spinner.dispose();
    super.dispose();
  }

  bool _onNotification(ScrollNotification n) {
    // Only respond to vertical, top-overscroll on the immediate child.
    if (n.depth != 0) return false;
    if (n.metrics.axisDirection != AxisDirection.down) return false;

    // Don't react while a refresh is already in-flight — keep the
    // spinner pinned at threshold instead of letting fresh scroll
    // events reset it.
    if (_state == _PullState.refreshing) return false;

    // iOS `BouncingScrollPhysics` allows `metrics.pixels` to go negative
    // when the user pulls past the top, and DOES NOT emit
    // `OverscrollNotification` for that motion (it's not an overscroll
    // in the clamping sense). So we read negative pixels as our pull
    // signal on every update — that's the canonical iOS-friendly path.
    //
    // We still accept `OverscrollNotification` as a fallback for
    // clamping platforms (Android-style) so the widget stays portable.
    final pulled = n.metrics.pixels < 0 ? -n.metrics.pixels : 0.0;

    if (n is ScrollUpdateNotification || n is OverscrollNotification) {
      if (pulled > 0) {
        final next = pulled >= widget.threshold ? _PullState.releasing : _PullState.pulling;
        if (next == _PullState.releasing && _state == _PullState.pulling) {
          DsHaptics.play(Haptic.threshold);
        }
        setState(() {
          _overscroll = pulled.clamp(0.0, widget.threshold * 1.6);
          _state = next;
        });
      } else if (_overscroll > 0 && _state != _PullState.refreshing) {
        // Pull released or scrolled back into positive — reset unless
        // we're already past threshold (ScrollEndNotification will
        // commit the trigger).
        setState(() {
          _overscroll = 0;
          _state = _PullState.idle;
        });
      }
    } else if (n is ScrollEndNotification) {
      if (_state == _PullState.releasing) {
        _trigger();
      } else if (_state == _PullState.pulling) {
        setState(() {
          _overscroll = 0;
          _state = _PullState.idle;
        });
      }
    }
    return false;
  }

  Future<void> _trigger() async {
    setState(() {
      _state = _PullState.refreshing;
      _overscroll = widget.threshold;
    });
    _spinner.repeat();
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        _spinner.stop();
        setState(() {
          _state = _PullState.idle;
          _overscroll = 0;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final progress = (_overscroll / widget.threshold).clamp(0.0, 1.0);
    return Stack(
      children: [
        Positioned.fill(
          child: NotificationListener<ScrollNotification>(
            onNotification: _onNotification,
            child: widget.child,
          ),
        ),
        // Loader sits at the top — fades in with pull, spins when refreshing.
        if (_overscroll > 4 || _state == _PullState.refreshing)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SizedBox(
                height: _overscroll.clamp(0, widget.threshold * 1.4),
                child: Center(
                  child: AnimatedBuilder(
                    animation: _spinner,
                    builder: (_, _) {
                      return SizedBox(
                        width: 24,
                        height: 24,
                        child: CustomPaint(
                          painter: _SpokeWheelPainter(
                            progress: progress,
                            t: _state == _PullState.refreshing
                                ? _spinner.value
                                : 0,
                            color: tokens.text3,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SpokeWheelPainter extends CustomPainter {
  /// 0..1 — how revealed the spokes are while pulling.
  final double progress;

  /// 0..1 — rotation phase while refreshing.
  final double t;
  final Color color;
  _SpokeWheelPainter({
    required this.progress,
    required this.t,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const spokes = 12;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final outerR = size.width * 0.45;
    final innerR = size.width * 0.18;
    final isSpinning = t > 0;
    final highlightIndex = isSpinning ? (t * spokes).floor() % spokes : -1;
    for (var i = 0; i < spokes; i++) {
      final angle = (i / spokes) * 2 * math.pi - math.pi / 2;
      double alpha;
      if (isSpinning) {
        // Fade trailing spokes for the spinning state.
        final dist = (i - highlightIndex + spokes) % spokes;
        alpha = (1.0 - dist / spokes) * 0.85 + 0.15;
      } else {
        // Pull: reveal spokes proportionally to progress.
        alpha = i / spokes <= progress ? 1.0 : 0.2;
      }
      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      final cosA = math.cos(angle);
      final sinA = math.sin(angle);
      canvas.drawLine(
        Offset(cx + cosA * innerR, cy + sinA * innerR),
        Offset(cx + cosA * outerR, cy + sinA * outerR),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SpokeWheelPainter old) =>
      old.progress != progress || old.t != t || old.color != color;
}
