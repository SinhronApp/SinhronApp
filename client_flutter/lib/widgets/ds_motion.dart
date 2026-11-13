// Small motion building blocks (owner, 2026-10-18: "побольше плавных
// анимаций"). Transforms and opacity only — no size animation, so nothing
// re-lays out per frame — and every one of them is a no-op under Reduce
// Motion (DsMotion.reduced). None of them delays a tap: the child is
// there and hit-testable from the first frame.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';

/// Fades in and rises a few points the first time it is built. [index]
/// staggers a list (30 ms a step, capped at [maxStagger] steps, so a long
/// list never waits).
class DsAppear extends StatefulWidget {
  const DsAppear({
    super.key,
    required this.child,
    this.index = 0,
    this.offset = const Offset(0, 10),
    this.duration = DsMotion.base,
    this.maxStagger = 8,
    this.animate = true,
  });

  final Widget child;
  final int index;

  /// false: already in place (a row scrolled into view later, not one
  /// arriving with the screen). Same tree either way.
  final bool animate;

  /// Where it starts, in logical pixels, relative to where it ends.
  final Offset offset;
  final Duration duration;
  final int maxStagger;

  static const step = Duration(milliseconds: 30);

  @override
  State<DsAppear> createState() => _DsAppearState();
}

class _DsAppearState extends State<DsAppear> with SingleTickerProviderStateMixin {
  late final Duration _delay = DsAppear.step * math.min(math.max(widget.index, 0), widget.maxStagger);
  late final AnimationController _c = AnimationController(vsync: this, duration: _delay + widget.duration);
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Interval(_delay.inMicroseconds / (_delay + widget.duration).inMicroseconds, 1, curve: DsMotion.enter),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final gate = context.getInheritedWidgetOfExactType<_AppearGate>();
    if (!widget.animate || !(gate?.isOpen() ?? true) || DsMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  // The same tree at rest as in flight (opacity 1 adds no layer), so a
  // stateful child is never rebuilt from scratch when the motion ends.
  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (_, child) => Transform.translate(offset: widget.offset * (1 - _t.value), child: child),
      ),
    );
  }
}

/// [children] as a staggered entrance — for a `ListView(children: …)`
/// under a [DsAppearScope].
List<Widget> dsStaggered(List<Widget> children) => [
  for (var i = 0; i < children.length; i++) DsAppear(index: i, child: children[i]),
];

/// Lets the rows under it animate in only while the screen arrives: rows
/// that mount in the first frame play their [DsAppear]; rows that mount
/// later (scrolled into view, a search result) are simply there.
class DsAppearScope extends StatefulWidget {
  const DsAppearScope({super.key, required this.child});

  final Widget child;

  @override
  State<DsAppearScope> createState() => _DsAppearScopeState();
}

class _DsAppearScopeState extends State<DsAppearScope> {
  bool _open = true;
  bool _closing = false;

  bool _query() {
    if (_open && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _open = false);
    }
    return _open;
  }

  @override
  Widget build(BuildContext context) => _AppearGate(isOpen: _query, child: widget.child);
}

class _AppearGate extends InheritedWidget {
  const _AppearGate({required this.isOpen, required super.child});

  final bool Function() isOpen;

  @override
  bool updateShouldNotify(_AppearGate old) => false;
}

/// Pops in with a small spring the first time it is built — badges, the
/// active tab's icon, a pill that just showed up.
class DsPopIn extends StatefulWidget {
  const DsPopIn({super.key, required this.child, this.from = 0.6, this.alignment = Alignment.center});

  final Widget child;

  /// Starting scale.
  final double from;
  final Alignment alignment;

  @override
  State<DsPopIn> createState() => _DsPopInState();
}

class _DsPopInState extends State<DsPopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: DsMotion.base);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (DsMotion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = CurvedAnimation(parent: _c, curve: DsMotion.springy);
    final fade = CurvedAnimation(parent: _c, curve: const Interval(0, 0.5));
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: Tween(begin: widget.from, end: 1.0).animate(scale),
        alignment: widget.alignment,
        child: widget.child,
      ),
    );
  }
}

/// A strip that slides open under a header (a search field) and folds away
/// again: height, fade and a few points of drop together, [DsMotion.emphasized]
/// out and [DsMotion.exit] back. The one size animation here — a ~50 pt strip
/// above a list, so the list glides down instead of jumping. While closed the
/// child is not built (no focus, no hit-testing).
class DsReveal extends StatefulWidget {
  const DsReveal({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<DsReveal> createState() => _DsRevealState();
}

class _DsRevealState extends State<DsReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: DsMotion.base,
    value: widget.open ? 1 : 0,
  );
  late final CurvedAnimation _t = CurvedAnimation(parent: _c, curve: DsMotion.emphasized, reverseCurve: DsMotion.exit);

  @override
  void didUpdateWidget(DsReveal old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    _c.duration = DsMotion.of(context, DsMotion.base);
    widget.open ? _c.forward() : _c.reverse();
  }

  @override
  void dispose() {
    _t.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (_, child) {
        final v = _t.value;
        if (v == 0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: v,
            child: Opacity(
              opacity: v,
              child: Transform.translate(offset: Offset(0, -8 * (1 - v)), child: child),
            ),
          ),
        );
      },
    );
  }
}

/// A crossfade (with a hint of rise) when [child]'s key changes. Under
/// Reduce Motion it swaps at once.
class DsFadeSwitcher extends StatelessWidget {
  const DsFadeSwitcher({
    super.key,
    required this.child,
    this.duration = DsMotion.fast,
    this.alignment = Alignment.center,
    this.rise = 0,
    this.scaleFrom = 1,
    this.expand = false,
  });

  final Widget child;
  final Duration duration;

  /// Where the old and new child sit while both are on screen.
  final AlignmentGeometry alignment;

  /// The incoming child starts this many points lower (0 = fade only).
  final double rise;

  /// …and this much smaller (1 = no scale) — badges, indicators.
  final double scaleFrom;

  /// Children fill the box (whole-page bodies: a list, a skeleton).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: DsMotion.of(context, duration),
      switchInCurve: DsMotion.enter,
      switchOutCurve: DsMotion.exit,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        fit: expand ? StackFit.expand : StackFit.loose,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, anim) {
        Widget faded = FadeTransition(opacity: anim, child: child);
        if (scaleFrom != 1) {
          faded = ScaleTransition(scale: Tween(begin: scaleFrom, end: 1.0).animate(anim), child: faded);
        }
        if (rise == 0) return faded;
        return AnimatedBuilder(
          animation: anim,
          child: faded,
          builder: (_, c) => Transform.translate(offset: Offset(0, rise * (1 - anim.value)), child: c),
        );
      },
      child: child,
    );
  }
}

/// A list row that glides to its new place when the list reorders (a chat
/// pinned to the top, a new message lifting a chat, a row archived from
/// above). FLIP: after each layout it compares its offset in the list's
/// content with the last one and paints from the old place back to zero.
/// Scrolling doesn't move content offsets, so it never animates a scroll.
///
/// The list must keep row state across moves — a keyed row and
/// `findChildIndexCallback` on a `ListView.builder`.
class DsReorderSlide extends StatefulWidget {
  const DsReorderSlide({super.key, required this.child});

  final Widget child;

  /// Moves farther than this jump (a row that went from the bottom of a
  /// long list to the top glides only the last stretch).
  static const double maxTravel = 320;

  @override
  State<DsReorderSlide> createState() => _DsReorderSlideState();
}

class _DsReorderSlideState extends State<DsReorderSlide> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: DsMotion.base, value: 1);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: DsMotion.emphasized);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ReorderSlide(
    progress: _t,
    enabled: !DsMotion.reduced(context),
    // Started after the frame that noticed the move (painting can't start a
    // ticker); that frame already paints from the old place.
    restart: () => WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _c.forward(from: 0);
    }),
    child: widget.child,
  );
}

class _ReorderSlide extends SingleChildRenderObjectWidget {
  const _ReorderSlide({required this.progress, required this.enabled, required this.restart, super.child});

  final Animation<double> progress;
  final bool enabled;
  final VoidCallback restart;

  @override
  _RenderReorderSlide createRenderObject(BuildContext context) =>
      _RenderReorderSlide(progress: progress, enabled: enabled, restart: restart);

  @override
  void updateRenderObject(BuildContext context, _RenderReorderSlide r) => r
    ..progress = progress
    ..enabled = enabled
    ..restart = restart
    // A rebuilt list may have moved this row without repainting it (its
    // repaint boundary is just placed elsewhere) — look again.
    ..markNeedsPaint();
}

class _RenderReorderSlide extends RenderProxyBox {
  _RenderReorderSlide({required Animation<double> progress, required this.enabled, required this.restart})
    : _progress = progress;

  Animation<double> _progress;
  set progress(Animation<double> v) {
    if (v == _progress) return;
    if (attached) _progress.removeListener(markNeedsPaint);
    _progress = v;
    if (attached) _progress.addListener(markNeedsPaint);
  }

  bool enabled;
  VoidCallback restart;

  double? _last;
  double _from = 0;

  /// A move was seen this frame; the animation starts after it.
  bool _pending = false;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  /// This row's offset along the list's content, or null outside a sliver
  /// list.
  double? _offsetInList() {
    RenderObject child = this;
    var parent = child.parent;
    while (parent != null && parent is! RenderSliverMultiBoxAdaptor) {
      child = parent;
      parent = parent.parent;
    }
    final data = child.parentData;
    return parent != null && data is SliverMultiBoxAdaptorParentData ? data.layoutOffset : null;
  }

  double get _dy => _from * (1 - (_pending ? 0 : _progress.value));

  @override
  void paint(PaintingContext context, Offset offset) {
    final now = _offsetInList();
    final last = _last;
    _last = now;
    if (enabled && now != null && last != null && (now - last).abs() >= 0.5) {
      // Mid-glide moves start from where it is painted now.
      _from = (last - now + _dy).clamp(-DsReorderSlide.maxTravel, DsReorderSlide.maxTravel);
      _pending = true;
      restart();
    } else if (_pending && _progress.value < 1) {
      _pending = false;
    }
    final dy = enabled ? _dy : 0.0;
    super.paint(context, dy == 0 ? offset : offset.translate(0, dy));
  }

  // Hit testing stays at the laid-out place (where the row is going): the
  // list finds rows by layout, and a tap mid-glide must never fall through.

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final dy = enabled ? _dy : 0.0;
    transform.translateByDouble(0, dy, 0, 1);
  }
}
