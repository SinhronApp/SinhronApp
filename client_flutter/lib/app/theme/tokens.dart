import 'package:flutter/cupertino.dart' show CupertinoColors;
import 'package:flutter/widgets.dart';

import 'palette.dart';

@immutable
class DsTokens {
  final Color bg;
  final Color bgSoft;
  final Color surface;
  final Color elevated;
  final Color divider;
  final Color dividerStrong;

  final Color text;
  final Color text2;
  final Color text3;
  final Color text4;

  final Color accent;
  final Color accentSoft;
  final Color accentText;

  final Color danger;
  final Color dangerSoft;

  final Color success;

  final List<Color> avatarShadeStops;
  final List<double> avatarShadeOffsets;

  final List<BoxShadow> shadowRow;
  final List<BoxShadow> shadowSoft;
  final List<BoxShadow> shadowFab;

  final double radiusCard;
  final double radiusPill;
  final double radiusBubble;

  const DsTokens({
    required this.bg,
    required this.bgSoft,
    required this.surface,
    required this.elevated,
    required this.divider,
    required this.dividerStrong,
    required this.text,
    required this.text2,
    required this.text3,
    required this.text4,
    required this.accent,
    required this.accentSoft,
    required this.accentText,
    required this.danger,
    required this.dangerSoft,
    required this.success,
    required this.avatarShadeStops,
    required this.avatarShadeOffsets,
    required this.shadowRow,
    required this.shadowSoft,
    required this.shadowFab,
    required this.radiusCard,
    required this.radiusPill,
    required this.radiusBubble,
  });

  static const DsTokens light = DsTokens(
    // Neutral like Signal / iOS (2026-10-20, owner: "the beige is ugly"):
    // lists on white, grouped screens (settings, info) on system grey.
    bg: Color(0xFFFFFFFF),
    bgSoft: Color(0xFFF2F2F7),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    divider: Color(0x0F0F1720),
    dividerStrong: Color(0x1A0F1720),
    text: Color(0xFF0E141B),
    text2: Color(0xFF4A5562),
    text3: Color(0xFF636C76), // AA ≥ 4.5:1 on bg / bgSoft / surface
    text4: Color(0xFFB4BDC9),
    accent: Color(0xFF2864DE), // AA as text and under white text
    accentSoft: Color(0xFFE6EFFE),
    accentText: Color(0xFFFFFFFF),
    danger: Color(0xFFC53434),
    dangerSoft: Color(0xFFFDE9E9),
    success: Color(0xFF167A4D),
    avatarShadeStops: [Color(0x2EFFFFFF), Color(0x00FFFFFF), Color(0x14000000)],
    avatarShadeOffsets: [0.0, 0.4, 1.0],
    shadowRow: [BoxShadow(color: Color(0x0A0F1720), offset: Offset(0, 1), blurRadius: 0)],
    shadowSoft: [
      BoxShadow(color: Color(0x0A0F1720), offset: Offset(0, 1), blurRadius: 2),
      BoxShadow(color: Color(0x0F0F1720), offset: Offset(0, 8), blurRadius: 24),
    ],
    shadowFab: [
      BoxShadow(color: Color(0x4D2D6FF7), offset: Offset(0, 6), blurRadius: 16),
      BoxShadow(color: Color(0x2E2D6FF7), offset: Offset(0, 2), blurRadius: 4),
    ],
    radiusCard: 18,
    radiusPill: 999,
    radiusBubble: 14,
  );

  static const DsTokens dark = DsTokens(
    // Neutral greys (iOS dark system colours), not the old blue-black.
    bg: Color(0xFF121214),
    bgSoft: Color(0xFF0C0C0E),
    surface: Color(0xFF1C1C1F),
    elevated: Color(0xFF26262A),
    divider: Color(0x0FFFFFFF),
    dividerStrong: Color(0x1AFFFFFF),
    text: Color(0xFFECEEF1),
    text2: Color(0xFFA6AFBD),
    text3: Color(0xFF7C8695), // AA 4.7:1
    text4: Color(0xFF4A5365),
    accent: Color(0xFF4F8AFF),
    accentSoft: Color(0x294F8AFF),
    accentText: Color(0xFFFFFFFF),
    danger: Color(0xFFE45353),
    dangerSoft: Color(0x29E03B3B),
    success: Color(0xFF2BC58A),
    avatarShadeStops: [Color(0x1AFFFFFF), Color(0x00FFFFFF), Color(0x2E000000)],
    avatarShadeOffsets: [0.0, 0.4, 1.0],
    shadowRow: [BoxShadow(color: Color(0x66000000), offset: Offset(0, 1), blurRadius: 0)],
    shadowSoft: [
      BoxShadow(color: Color(0x73000000), offset: Offset(0, 1), blurRadius: 2),
      BoxShadow(color: Color(0x66000000), offset: Offset(0, 12), blurRadius: 28),
    ],
    shadowFab: [
      BoxShadow(color: Color(0x594F8AFF), offset: Offset(0, 6), blurRadius: 16),
      BoxShadow(color: Color(0x66000000), offset: Offset(0, 2), blurRadius: 4),
    ],
    radiusCard: 18,
    radiusPill: 999,
    radiusBubble: 14,
  );

  LinearGradient get avatarShade => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: avatarShadeStops,
    stops: avatarShadeOffsets,
  );
}

class DsTheme extends InheritedWidget {
  final DsTokens tokens;
  final bool isDark;

  const DsTheme({super.key, required this.tokens, required this.isDark, required super.child});

  static DsTokens of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<DsTheme>();
    assert(w != null, 'DsTheme.of() called without a DsTheme ancestor');
    return w!.tokens;
  }

  static bool isDarkOf(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<DsTheme>();
    return w?.isDark ?? false;
  }

  @override
  bool updateShouldNotify(DsTheme oldWidget) => tokens != oldWidget.tokens || isDark != oldWidget.isDark;
}

/// The type scale — UI backlog §5 item 39. Every text style in the app
/// is one of these steps (optionally recoloured / reweighted with
/// `copyWith`), instead of hand-tuned sizes per screen.
abstract final class DsText {
  static const _f = DsType.family;

  /// Hero numbers, onboarding headlines.
  static const display = TextStyle(
    fontFamily: _f,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
    height: 1.1,
  );

  /// Screen titles (large title).
  static const title1 = TextStyle(
    fontFamily: _f,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.15,
  );

  /// Section heroes, sheet titles.
  static const title2 = TextStyle(
    fontFamily: _f,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.4,
    height: 1.2,
  );

  static const title3 = TextStyle(
    fontFamily: _f,
    fontSize: 19,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
  );

  /// Nav bar titles, emphasised rows.
  static const headline = TextStyle(
    fontFamily: _f,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.25,
  );

  /// Row titles, buttons.
  static const bodyLarge = TextStyle(
    fontFamily: _f,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.2,
    height: 1.3,
  );

  /// Message text, most reading text.
  static const body = TextStyle(
    fontFamily: _f,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.15,
    height: 20 / 15,
  );

  /// Previews, secondary lines.
  static const callout = TextStyle(
    fontFamily: _f,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
    height: 19 / 14,
  );

  /// Supporting text, list values.
  static const subhead = TextStyle(
    fontFamily: _f,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.08,
    height: 18 / 13,
  );

  /// Footers, timestamps.
  static const footnote = TextStyle(
    fontFamily: _f,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 16 / 12,
  );

  /// Emoji in a reaction chip under a bubble.
  static const reactionEmoji = TextStyle(fontFamily: _f, fontSize: 16, height: 1.0);

  /// The count next to it.
  static const reactionCount = TextStyle(
    fontFamily: _f,
    fontSize: 12.5,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    height: 1.0,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Toast pill text (`AppNoticeHost`): white on dark glass.
  static const toast = TextStyle(
    fontFamily: _f,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.15,
    height: 18 / 14,
    color: DsPalette.white,
  );

  /// Section labels, meta.
  static const caption = TextStyle(
    fontFamily: _f,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 14 / 11,
  );

  /// Badges, tab labels.
  static const micro = TextStyle(
    fontFamily: _f,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.2,
  );

  static const all = [
    display,
    title1,
    title2,
    title3,
    headline,
    bodyLarge,
    body,
    callout,
    subhead,
    footnote,
    caption,
    micro,
  ];
}

/// Elevation — UI backlog §5 item 39. Fixed (not theme-dependent)
/// shadows used across screens; theme-tuned ones live in DsTokens
/// (shadowRow / shadowSoft / shadowFab).
abstract final class DsShadow {
  /// Context menus, reaction bar, popovers.
  static const menu = [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8))];

  /// Floating round buttons / chips over content.
  static const float = [BoxShadow(color: Color(0x26000000), blurRadius: 10, offset: Offset(0, 3))];

  /// Incoming bubble hairline lift.
  static const bubbleIn = [BoxShadow(color: Color(0x0D0F1720), offset: Offset(0, 1), blurRadius: 1)];

  /// Cards, rows and tiles resting on the background (the most common
  /// shadow — was hand-written 29 times).
  static const card = [BoxShadow(color: Color(0x0A0F1720), offset: Offset(0, 1), blurRadius: 2)];

  /// Thin lift for small chips and pills.
  static const hairline = [BoxShadow(color: Color(0x0D0F1720), offset: Offset(0, 1), blurRadius: 1)];

  /// Soft lift on media / dark surfaces.
  static const lift = [BoxShadow(color: Color(0x33000000), offset: Offset(0, 1), blurRadius: 2)];

  /// Subtle drop for floating controls.
  static const soft = [BoxShadow(color: Color(0x14000000), offset: Offset(0, 1), blurRadius: 3)];

  /// Green "success" glow (verified / connected badges).
  static const successGlow = [BoxShadow(color: Color(0x381FAF6E), offset: Offset(0, 2), blurRadius: 6)];

  /// Outgoing (accent) bubble glow.
  static const bubbleOut = [
    BoxShadow(color: Color(0x332D6FF7), offset: Offset(0, 1), blurRadius: 2),
    BoxShadow(color: Color(0x1F2D6FF7), offset: Offset(0, 4), blurRadius: 12),
  ];
  // Tech-debt 2.26 — screen-specific shadows, same values as before.
  static const art1 = BoxShadow(color: DsPalette.black20, blurRadius: 8, offset: Offset(0, 2));
  static const art2 = BoxShadow(color: DsPalette.navyShade20, offset: Offset(0, -2), blurRadius: 18);
  static const art3 = BoxShadow(color: DsPalette.black8, offset: Offset(0, 4), blurRadius: 16);
  static const art4 = BoxShadow(color: DsPalette.green22, offset: Offset(0, 2), blurRadius: 6);
  static const art5 = BoxShadow(color: DsPalette.green30, offset: Offset(0, 8), blurRadius: 22);
  static const art6 = BoxShadow(color: DsPalette.black30, offset: Offset(0, 18), blurRadius: 40);
  static const art7 = BoxShadow(color: DsPalette.black20, offset: Offset(0, 4), blurRadius: 18);
  static const art8 = BoxShadow(color: DsPalette.art1A2540a4D, offset: Offset(0, 24), blurRadius: 60);
  static const art9 = BoxShadow(color: DsPalette.navyShade20, offset: Offset(0, 2), blurRadius: 6);
  static const art10 = BoxShadow(color: DsPalette.black20, offset: Offset(0, 2), blurRadius: 6);
  static const art11 = BoxShadow(color: DsPalette.art0F1720a0F, offset: Offset(0, -2), blurRadius: 12);
  static const art12 = BoxShadow(color: DsPalette.art0F1720a1A, offset: Offset(0, 1), blurRadius: 2);
  static const art13 = BoxShadow(color: DsPalette.blue30, offset: Offset(0, 2), blurRadius: 6);
  static const art14 = BoxShadow(color: DsPalette.black20, offset: Offset(0, 1), blurRadius: 2);
  static const art15 = BoxShadow(color: DsPalette.art000000a1A, offset: Offset(0, 1), blurRadius: 3);
  static const art16 = BoxShadow(color: DsPalette.black8, offset: Offset(0, 2), blurRadius: 12);
  static const art17 = BoxShadow(color: DsPalette.black30, offset: Offset(0, -10), blurRadius: 40);
  static const art18 = BoxShadow(color: DsPalette.art000000a2E, offset: Offset(0, 1), blurRadius: 3);
  static const art19 = BoxShadow(color: DsPalette.art1A2540a14, offset: Offset(0, 6), blurRadius: 24);
  static const art20 = BoxShadow(color: DsPalette.art1A2540a66, offset: Offset(0, 24), blurRadius: 60);
  static const art21 = BoxShadow(color: DsPalette.blue30, offset: Offset(0, 1), blurRadius: 2);
  // Tech-debt 2.26 — shadows that depend on the theme / state, as tokens.

  /// A coloured glow under a control: `color` at `alpha`, dropped `y`.
  static BoxShadow glowOf(Color color, {required double alpha, double y = 2, double blur = 6}) => BoxShadow(
    color: color.withValues(alpha: alpha),
    offset: Offset(0, y),
    blurRadius: blur,
  );

  /// A hard focus / selection ring of `spread` around the box.
  static BoxShadow ring(Color color, {double spread = 2}) => BoxShadow(color: color, spreadRadius: spread);

  /// `s` with its colour faded to `opacity` (pressed / disabled states).
  static BoxShadow faded(BoxShadow s, double opacity) => BoxShadow(
    color: s.color.withValues(alpha: s.color.a * opacity),
    offset: s.offset,
    blurRadius: s.blurRadius,
    spreadRadius: s.spreadRadius,
  );
  static const art22 = BoxShadow(color: DsPalette.blue18, offset: Offset(0, 1), blurRadius: 1);
  static const art23 = BoxShadow(color: DsPalette.slate5, offset: Offset(0, 1), blurRadius: 1);
  static const art24 = BoxShadow(color: DsPalette.blue20, offset: Offset(0, 1), blurRadius: 2);
  static const art25 = BoxShadow(color: DsPalette.blue18, offset: Offset(0, 6), blurRadius: 16);
  static const art26 = BoxShadow(color: DsPalette.slate4, offset: Offset(0, 1), blurRadius: 2);
  static const art27 = BoxShadow(color: DsPalette.artFF4D4Da38, offset: Offset(0, 1), blurRadius: 2);
  static const art28 = BoxShadow(color: DsPalette.red20, offset: Offset(0, 6), blurRadius: 16);
}

/// Spacing grid (4 / 8) — UI backlog §5 item 39.
abstract final class DsSpace {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;

  // Tech-debt 2.26 — half steps (2-pt) and larger steps the screens use;
  // `xNh5` = N½ × 4 pt. Same values the screens had as bare numbers.
  static const double x0h5 = 2;
  static const double x1h5 = 6;
  static const double x2h5 = 10;
  static const double x3h5 = 14;
  static const double x4h5 = 18;
  static const double x5h5 = 22;
  static const double x6h5 = 26;
  static const double x7 = 28;
  static const double x7h5 = 30;
  static const double x9 = 36;
  static const double x10 = 40;
  static const double x11 = 44;
  static const double x12 = 48;
  static const double x9h5 = 38;
  static const double x14 = 56;
  static const double x15 = 60;
  static const double x16 = 64;
  static const double x19h5 = 78;
  static const double x20 = 80;
  static const double x24 = 96;
  static const double x25 = 100;

  // Optical nudges off the 2-pt grid — the odd values the mockups use to
  // line glyphs and text up by eye (tech-debt 2.26). Named so that every
  // spacing goes through a token; snapping them to the grid is a design
  // decision, not a refactor.
  static const double nudge1 = 1;
  static const double nudge3 = 3;
  static const double nudge5 = 5;
  static const double nudge7 = 7;
  static const double nudge9 = 9;
  static const double nudge11 = 11;
  static const double nudge13 = 13;
  static const double nudge15 = 15;

  /// Screen side gutter.
  static const double gutter = 16;
}

class DsType {
  DsType._();

  static const String family = 'Geist';
  static const String familyMono = 'GeistMono';

  static const TextStyle headerTitle = TextStyle(
    fontFamily: family,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.15,
  );

  static const TextStyle rowName = TextStyle(
    fontFamily: family,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.2,
  );

  static const TextStyle rowTime = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.0,
  );

  static const TextStyle rowPreview = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
    height: 19 / 14,
  );

  static const TextStyle rowSender = TextStyle(
    fontFamily: family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 19 / 14,
  );

  static const TextStyle filterPill = TextStyle(
    fontFamily: family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.0,
  );

  static const TextStyle filterCount = TextStyle(
    fontFamily: family,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.0,
  );

  static const TextStyle badge = TextStyle(
    fontFamily: family,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    height: 1.0,
    color: Color(0xFFFFFFFF),
  );

  static const TextStyle tabLabel = TextStyle(
    fontFamily: family,
    fontSize: 10.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
  );

  static const TextStyle tabLabelActive = TextStyle(
    fontFamily: family,
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
  );

  static TextStyle avatarInitials(double size) => TextStyle(
    fontFamily: family,
    fontSize: size * 0.38,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
    height: 1.0,
    color: const Color(0xFFFFFFFF),
  );
}

/// Tech-debt 2.26 — the type styles screens used to spell out by hand,
/// named once here with exactly the same values (`t<size><weight>`; a
/// colour from the theme is added with `.copyWith(color: …)`).
abstract final class DsTextArt {
  static const t12w500toast = TextStyle(
    color: DsPalette.white,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    fontFamily: DsType.family,
    height: 1.3,
  );
  static const t12p5w500sub = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
  );
  static const t12p5w500subMono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t10 = TextStyle(fontFamily: DsType.family, fontSize: 10, color: DsPalette.white80);
  static const t10p5w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 10.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t10p5w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 10.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    height: 1.15,
    color: DsPalette.white70,
  );
  static const t10p5w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t10p5w700 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 10.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    height: 1.0,
    color: DsPalette.orange700,
  );
  static const t10w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 10,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.artFFFFFFaA5,
  );
  static const t10w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t10w700 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.1,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t10w700v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    height: 1.0,
    letterSpacing: -0.1,
    color: DsPalette.white,
  );
  static const t11 = TextStyle(fontSize: 11, height: 1.0);
  static const t11p5w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.3,
  );
  static const t11p5w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t11p5w500Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t11p5w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t11p5w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11.5,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.0,
    color: DsPalette.white85,
  );
  static const t11v2 = TextStyle(fontFamily: DsType.family, fontSize: 11, color: DsPalette.white);
  static const t11w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white80,
  );
  static const t11w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
    height: 1.0,
  );
  static const t11w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t11w500Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t11w500Monov4 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.4,
  );
  static const t11w500v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white85,
  );
  static const t11w500v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white78,
  );
  static const t11w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t11w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t11w600Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.0,
    color: DsPalette.green,
  );
  static const t11w600Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    height: 1.0,
  );
  static const t11w600v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white92,
  );
  static const t11w600v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t11w700 = TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: DsPalette.white);
  static const t11w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    height: 1.0,
    color: DsPalette.gold,
  );
  static const t11w700Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t11w700Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.4,
  );
  static const t11w700v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 11,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.0,
    color: DsPalette.art0B1016,
  );
  static const t12 = TextStyle(fontSize: 12, height: 1.0);
  static const t12p5w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
    color: DsPalette.white80,
  );
  static const t12p5w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t12p5w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t12p5w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.danger,
  );
  static const t12p5w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t12p5w600v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.gold,
  );
  static const t12p5w600v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t12v2 = TextStyle(fontFamily: DsType.family, fontSize: 12, color: DsPalette.white70);
  static const t12w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
    color: DsPalette.white70,
  );
  static const t12w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.3,
    height: 1.0,
    color: DsPalette.white78,
  );
  static const t12w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t12w500Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.3,
  );
  static const t12w500Monov4 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t12w500v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white80,
  );
  static const t12w500v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
    color: DsPalette.green,
  );
  static const t12w500v4 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
    color: DsPalette.midnight80,
  );
  static const t12w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t12w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
    height: 1.0,
  );
  static const t12w600v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.periwinkle,
  );
  static const t12w700 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.gold,
  );
  static const t12w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.05,
    height: 1.0,
  );
  static const t13 = TextStyle(fontSize: 13, height: 1.0);
  static const t13p5w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 18 / 13.5,
    color: DsPalette.art1B2754aE6,
  );
  static const t13p5w500v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.3,
    color: DsPalette.midnight80,
  );
  static const t13p5w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t13p5w600v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t13v2 = TextStyle(fontSize: 13, height: 1.0, color: DsPalette.white);
  static const t13v3 = TextStyle(fontSize: 13, color: DsPalette.gray230);
  static const t13v4 = TextStyle(fontFamily: DsType.family, fontSize: 13, color: DsPalette.white);
  static const t13w400Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    height: 1.2,
  );
  static const t13w400Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.05,
    height: 1.3,
  );
  static const t13w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.2,
    color: DsPalette.white60,
  );
  static const t13w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.3,
  );
  static const t13w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.1,
  );
  static const t13w500Monov3 = TextStyle(fontFamily: DsType.familyMono, fontSize: 13, fontWeight: FontWeight.w500);
  static const t13w500Monov4 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.3,
  );
  static const t13w500Monov5 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t13w500Monov6 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t13w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.2,
    color: DsPalette.white92,
  );
  static const t13w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t13w600v2 = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t13w600v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.15,
    color: DsPalette.white,
  );
  static const t13w600v4 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.2,
    color: DsPalette.white,
  );
  static const t13w600v5 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.2,
    color: DsPalette.midnight,
  );
  static const t13w600v6 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t13w700 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t13w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t14 = TextStyle(fontFamily: DsType.family, fontSize: 14, color: DsPalette.white);
  static const t14p5w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.15,
    height: 1.2,
    color: DsPalette.white,
  );
  static const t14p5w600v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.3,
    color: DsPalette.midnight,
  );
  static const t14p5w600v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.3,
    color: DsPalette.crimson,
  );
  static const t14v2 = TextStyle(fontSize: 14, color: CupertinoColors.white);
  static const t14w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    height: 1.0,
    color: DsPalette.white80,
  );
  static const t14w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.3,
  );
  static const t14w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t14w500Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t14w500Monov4 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.6,
  );
  static const t14w500Monov5 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    height: 1.0,
  );
  static const t14w500v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.2,
    color: DsPalette.white80,
  );
  static const t14w500v3 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.4,
    color: DsPalette.white90,
  );
  static const t14w500v4 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.2,
    color: DsPalette.white90,
  );
  static const t14w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t14w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t14w600Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.2,
  );
  static const t14w600Monov3 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.2,
  );
  static const t15 = TextStyle(fontSize: 15, color: DsPalette.gray230);
  static const t15p5w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 15.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.2,
    color: DsPalette.white,
  );
  static const t15w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.15,
    height: 20 / 15,
    color: DsPalette.white,
  );
  static const t15w500v1 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.2,
  );
  static const t15w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: DsPalette.white,
  );
  static const t16 = TextStyle(fontSize: 16, height: 1.0);
  static const t16v2 = TextStyle(fontFamily: DsType.family, fontSize: 16, color: DsPalette.white);
  static const t16w500 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.2,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t16w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
    color: DsPalette.white80,
  );
  static const t16w500Monov2 = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 16,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t16w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.2,
  );
  static const t16w700 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.3,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t16w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: 0,
    height: 1.0,
  );
  static const t17w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t17w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    height: 1.2,
  );
  static const t18 = TextStyle(fontSize: 18, color: DsPalette.white);
  static const t18p5w500Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 18.5,
    fontWeight: FontWeight.w500,
    letterSpacing: 1.2,
    height: 1.2,
  );
  static const t18w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t19w600Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 19,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.15,
  );
  static const t22 = TextStyle(fontSize: 22, color: DsPalette.white);
  static const t22v2 = TextStyle(fontSize: 22, height: 1.0);
  static const t24w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
    height: 1.1,
    color: DsPalette.white,
  );
  static const t26 = TextStyle(fontSize: 26, height: 1.0);
  static const t28 = TextStyle(fontSize: 28, height: 1.0);
  static const t28w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.1,
    color: DsPalette.white,
  );
  static const t28w600v2 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t30 = TextStyle(fontSize: 30, height: 1.0);
  static const t32w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.1,
    color: DsPalette.white,
  );
  static const t40w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 40,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.0,
    height: 1.0,
  );
  static const t44w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 44,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.4,
    height: 1.0,
  );
  static const t64w600 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 64,
    fontWeight: FontWeight.w600,
    letterSpacing: -2.0,
    height: 1.0,
  );
  static const t7w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 7,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    height: 1.0,
  );
  static const t80w300 = TextStyle(
    fontFamily: DsType.family,
    fontSize: 80,
    fontWeight: FontWeight.w300,
    letterSpacing: -2.5,
    height: 1.0,
    color: DsPalette.white,
  );
  static const t9w700Mono = TextStyle(
    fontFamily: DsType.familyMono,
    fontSize: 9,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    height: 1.0,
  );
}
