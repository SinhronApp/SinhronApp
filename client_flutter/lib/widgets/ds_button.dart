import 'package:flutter/widgets.dart';

import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';

/// 4 variants matching design/app/spec-buttons.jsx:
/// - primary: accent fill, white text, dual shadow
/// - secondary: surface fill, text color, hairline outline
/// - ghost: transparent, accent text
/// - danger: red fill (#FF4D4D), white text
enum DsButtonVariant { primary, secondary, ghost, danger }

/// 4 sizes from spec-buttons.jsx (height / fontSize):
/// - small: 36h / 12.5
/// - medium: 42h / 14
/// - defaultSize: 50h / 16   ← spec default
/// - large: 60h / 16
enum DsButtonSize { small, medium, defaultSize, large }

extension on DsButtonSize {
  double get height => switch (this) {
    DsButtonSize.small => 36,
    DsButtonSize.medium => 42,
    DsButtonSize.defaultSize => 50,
    DsButtonSize.large => 60,
  };

  double get fontSize => switch (this) {
    DsButtonSize.small => 12.5,
    DsButtonSize.medium => 14,
    DsButtonSize.defaultSize || DsButtonSize.large => 16,
  };

  double get horizontalPadding => height >= 44 ? 18 : 14;
}

class DsButton extends StatefulWidget {
  final String label;
  final DsButtonVariant variant;
  final DsButtonSize size;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onPressed;
  final bool loading;
  final bool fullWidth;

  /// For golden tests only: force pressed-visual state at t=1.0.
  /// Production code should leave this null and rely on gestures.
  final bool? debugForcePressed;

  const DsButton({
    super.key,
    required this.label,
    this.variant = DsButtonVariant.primary,
    this.size = DsButtonSize.defaultSize,
    this.leading,
    this.trailing,
    this.onPressed,
    this.loading = false,
    this.fullWidth = true,
    this.debugForcePressed,
  });

  @override
  State<DsButton> createState() => _DsButtonState();
}

/// iOS-feel press animation:
///   - Tap-down: instant snap to pressed (t = 1.0) — "tap registered"
///   - Tap-up/cancel: animate back to default (t = 0.0) over 180ms ease-out
///   - Plus min 100ms total press visibility so quick taps still get visible feedback
///
/// All visual properties (bg, shadows, transform) interpolate from default → pressed
/// using the same animation `t`. Disabled buttons skip the controller entirely.
class _DsButtonState extends State<DsButton> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  DateTime? _pressedAt;

  static const Duration _minPressDuration = Duration(milliseconds: 100);
  static const Duration _releaseDuration = Duration(milliseconds: 180);

  bool get _disabled => widget.onPressed == null && !widget.loading;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _releaseDuration, value: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    _pressedAt = DateTime.now();
    _ctrl.value = 1.0; // instant snap to pressed
  }

  Future<void> _releasePress() async {
    final start = _pressedAt;
    if (start != null) {
      final elapsed = DateTime.now().difference(start);
      if (elapsed < _minPressDuration) {
        await Future.delayed(_minPressDuration - elapsed);
      }
    }
    if (!mounted) return;
    _ctrl.animateTo(0.0, curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = widget.debugForcePressed == true ? 1.0 : _ctrl.value;
        return _buildContent(tokens, t);
      },
    );
  }

  Widget _buildContent(DsTokens tokens, double t) {
    final styleA = _resolveStyle(
      tokens: tokens,
      variant: widget.variant,
      pressed: false,
      disabled: _disabled,
      loading: widget.loading,
    );
    final styleB = _resolveStyle(
      tokens: tokens,
      variant: widget.variant,
      pressed: true,
      disabled: _disabled,
      loading: widget.loading,
    );
    final bg = Color.lerp(styleA.bg, styleB.bg, t)!;
    final fg = styleA.fg; // fg doesn't change between default and pressed
    final shadows = _lerpShadows(styleA.shadows, t);

    final h = widget.size.height;
    final fontSize = widget.size.fontSize;
    final hp = widget.size.horizontalPadding;

    final children = <Widget>[];
    if (widget.loading) {
      children.add(_LoadingRing(color: fg, size: 16));
      children.add(const SizedBox(width: 8));
    } else if (widget.leading != null) {
      children.add(
        IconTheme(
          data: IconThemeData(color: fg, size: 16),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: fg),
            child: widget.leading!,
          ),
        ),
      );
      children.add(const SizedBox(width: 8));
    }
    children.add(
      Flexible(
        child: Text(
          widget.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: DsType.family,
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.15,
            height: 1.0,
            color: fg,
          ),
        ),
      ),
    );
    if (!widget.loading && widget.trailing != null) {
      children.add(const SizedBox(width: 8));
      children.add(
        IconTheme(
          data: IconThemeData(color: fg, size: 16),
          child: widget.trailing!,
        ),
      );
    }

    Widget body = Container(
      height: h,
      padding: EdgeInsets.symmetric(horizontal: hp),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        boxShadow: shadows,
        border: styleA.hairline ? Border.all(color: tokens.dividerStrong, width: 0.5) : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: widget.fullWidth ? MainAxisSize.max : MainAxisSize.min,
        children: children,
      ),
    );

    if (t != 0) {
      // Raw t (not clamped) so easeOutBack-style overshoot creates a visible
      // spring on release: t briefly < 0 → button lifts above default position.
      body = Transform.translate(
        offset: Offset(0, 1.0 * t),
        child: Transform.scale(scale: 1.0 - 0.015 * t, child: body),
      );
    }

    final result = widget.fullWidth ? SizedBox(width: double.infinity, child: body) : body;

    if (_disabled) return result;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _onTapDown,
      onTapUp: (_) => _releasePress(),
      onTapCancel: _releasePress,
      onTap: widget.loading ? null : widget.onPressed,
      child: result,
    );
  }
}

/// Interpolate shadow opacity from full (t=0) to none (t=1).
/// Default shadows fade out as the button moves into pressed state.
List<BoxShadow> _lerpShadows(List<BoxShadow> defaultShadows, double t) {
  if (t == 0) return defaultShadows;
  if (t == 1) return const [];
  final opacity = 1.0 - t;
  return defaultShadows.map((s) => DsShadow.faded(s, opacity)).toList();
}

class _ButtonStyle {
  final Color bg;
  final Color fg;
  final List<BoxShadow> shadows;
  final bool hairline;
  const _ButtonStyle({required this.bg, required this.fg, required this.shadows, this.hairline = false});
}

// Per design/app/spec-buttons.jsx palettes
const _kDangerBg = DsPalette.red;
const _kDangerBgPressed = DsPalette.red600;

_ButtonStyle _resolveStyle({
  required DsTokens tokens,
  required DsButtonVariant variant,
  required bool pressed,
  required bool disabled,
  required bool loading,
}) {
  if (disabled) {
    return _ButtonStyle(
      bg: variant == DsButtonVariant.ghost ? DsPalette.transparent : tokens.bgSoft,
      fg: tokens.text4,
      shadows: const [],
    );
  }

  switch (variant) {
    case DsButtonVariant.primary:
      return _ButtonStyle(
        bg: pressed ? _mix(tokens.accent, DsPalette.black, 0.88) : tokens.accent,
        fg: DsPalette.white,
        shadows: pressed ? const [] : const [DsShadow.art24 /* accent 20% */, DsShadow.art25 /* accent 18% */],
      );
    case DsButtonVariant.secondary:
      return _ButtonStyle(
        bg: pressed ? tokens.bgSoft : tokens.surface,
        fg: tokens.text,
        shadows: const [DsShadow.art26 /* text 4% */],
        hairline: true,
      );
    case DsButtonVariant.ghost:
      return _ButtonStyle(
        bg: pressed ? tokens.accentSoft : DsPalette.transparent,
        fg: tokens.accent,
        shadows: const [],
      );
    case DsButtonVariant.danger:
      return _ButtonStyle(
        bg: pressed ? _kDangerBgPressed : _kDangerBg,
        fg: DsPalette.white,
        shadows: pressed ? const [] : const [DsShadow.art27 /* danger 22% */, DsShadow.art28 /* danger 20% */],
      );
  }
}

/// Mix two colors at given t (0..1 of color1). Matches CSS color-mix.
Color _mix(Color a, Color b, double tOfA) {
  return Color.from(
    alpha: a.a * tOfA + b.a * (1 - tOfA),
    red: a.r * tOfA + b.r * (1 - tOfA),
    green: a.g * tOfA + b.g * (1 - tOfA),
    blue: a.b * tOfA + b.b * (1 - tOfA),
  );
}

/// Spinning loading ring — 2px stroke, 0.8s rotation per spec-buttons.jsx.
class _LoadingRing extends StatefulWidget {
  final Color color;
  final double size;
  const _LoadingRing({required this.color, this.size = 16});

  @override
  State<_LoadingRing> createState() => _LoadingRingState();
}

class _LoadingRingState extends State<_LoadingRing> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: CustomPaint(size: Size.square(widget.size), painter: _RingPainter(widget.color)),
    );
  }
}

class _RingPainter extends CustomPainter {
  final Color color;
  _RingPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromCircle(center: Offset(size.width / 2, size.height / 2), radius: size.width / 2 - 1);
    // 3/4 arc — leaves right side open (right-color: transparent in CSS)
    const start = -1.5707963; // -π/2 (top)
    const sweep = 4.712389; // 3π/2 (3 quarters)
    canvas.drawArc(rect, start, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color;
}
