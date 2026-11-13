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

  /// Message bubbles and the open filter chip / muted badge.
  final Color bubbleIn;
  final Color bubbleOut;
  final Color bubbleOutText;
  final Color bubbleOutMeta;
  final Color chipActive;

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
    required this.bubbleIn,
    required this.bubbleOut,
    required this.bubbleOutText,
    required this.bubbleOutMeta,
    required this.chipActive,
    required this.radiusCard,
    required this.radiusPill,
    required this.radiusBubble,
  });

  static const DsTokens light = DsTokens(
    // Neutral like Signal / iOS (2026-10-20, owner: "the beige is ugly"):
    // lists on white, grouped screens (settings, info) on system grey.
    bg: Color(0xFFFFFFFF),
    bgSoft: Color(0xFFF4F5F7),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFFFFF),
    divider: Color(0x12111316),
    dividerStrong: Color(0x1A111316),
    text: Color(0xFF111316),
    text2: Color(0xFF474C55),
    text3: Color(0xFF666C76), // AA ≥ 4.5:1 on bg / bgSoft / surface
    text4: Color(0xFFB4B9C1),
    accent: Color(0xFF2F5DC4), // AA as text and under white text
    accentSoft: Color(0xFFE6ECF8),
    accentText: Color(0xFFFFFFFF),
    danger: Color(0xFFC13333),
    dangerSoft: Color(0xFFFDE9E9),
    success: Color(0xFF15784B),
    bubbleIn: Color(0xFFEEF0F3),
    bubbleOut: Color(0xFF2F5DC4),
    bubbleOutText: Color(0xFFFFFFFF),
    bubbleOutMeta: Color(0xFFD5DFF3),
    chipActive: Color(0xFFE6E8EC),
    radiusCard: 20,
    radiusPill: 999,
    radiusBubble: 20,
  );

  static const DsTokens dark = DsTokens(
    // Neutral greys (iOS dark system colours), not the old blue-black.
    bg: Color(0xFF111113),
    bgSoft: Color(0xFF0A0A0C),
    surface: Color(0xFF1B1B1E),
    elevated: Color(0xFF262629),
    divider: Color(0x12FFFFFF),
    dividerStrong: Color(0x1AFFFFFF),
    text: Color(0xFFEDEEF0),
    text2: Color(0xFFB1B5BC),
    text3: Color(0xFF8B9099),
    text4: Color(0xFF50545C),
    accent: Color(0xFF7CA4F8),
    accentSoft: Color(0x297CA4F8),
    accentText: Color(0xFF0C1424), // dark text on the light accent
    danger: Color(0xFFF2776F),
    dangerSoft: Color(0x29E03B3B),
    success: Color(0xFF3FCB8F),
    bubbleIn: Color(0xFF232327),
    bubbleOut: Color(0xFF2F5DC4),
    bubbleOutText: Color(0xFFFFFFFF),
    bubbleOutMeta: Color(0xFFD5DFF3),
    chipActive: Color(0xFF2C2C31),
    radiusCard: 20,
    radiusPill: 999,
    radiusBubble: 20,
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
    fontSize: 30,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
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

/// Elevation — UI backlog §5 item 39. The few shadows left: things that
/// float over content. Cards, bubbles and buttons have none.
abstract final class DsShadow {
  /// Context menus, reaction bar, popovers.
  static const menu = [BoxShadow(color: Color(0x33000000), blurRadius: 24, offset: Offset(0, 8))];

  /// Floating round buttons / chips over content.
  static const float = [BoxShadow(color: Color(0x26000000), blurRadius: 10, offset: Offset(0, 3))];

  /// Cards, rows and tiles resting on the background: no shadow in this
  /// look (one place switches all of them).
  static const card = <BoxShadow>[];

  // Tech-debt 2.26 — screen-specific shadows, same values as before.
  static const art7 = BoxShadow(color: DsPalette.black20, offset: Offset(0, 4), blurRadius: 18);
  static const art10 = BoxShadow(color: DsPalette.black20, offset: Offset(0, 2), blurRadius: 6);
  static const art18 = BoxShadow(color: DsPalette.art000000a2E, offset: Offset(0, 1), blurRadius: 3);
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

  static const String family = 'GolosText';
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
    fontWeight: FontWeight.w500,
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
    fontSize: 11.5,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.05,
    height: 1.0,
  );

  static const TextStyle tabLabelActive = TextStyle(
    fontFamily: family,
    fontSize: 11.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.05,
    height: 1.0,
  );

  static TextStyle avatarInitials(double size, Color color) => TextStyle(
    fontFamily: family,
    fontSize: size * 0.36,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    height: 1.0,
    color: color,
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
