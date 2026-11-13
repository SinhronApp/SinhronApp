// Shared widgets for the Settings root + all sub-screens. Keeps the
// grouped-rows pattern (section card with hairline dividers, icon-tinted
// rows, optional toggle/value/chevron) consistent across all settings
// surfaces.
//
// Per design/app/settings.jsx + settings-detail.jsx.

import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_pressable.dart';

// ═════════════════════════════════════════════════════════════════════
// Section: title + rounded card with hairline-divided rows + footer
// ═════════════════════════════════════════════════════════════════════

class SettingsSection extends StatelessWidget {
  final String? title;
  final String? footer;
  final List<Widget> children;

  const SettingsSection({super.key, this.title, this.footer, required this.children});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: DsSpace.x5h5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x7, 0, DsSpace.x7, DsSpace.x2),
              child: Text(
                title!.toUpperCase(),
                style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tokens.dividerStrong, width: 0.5),
                boxShadow: DsShadow.card,
              ),
              child: Column(children: children),
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x2, DsSpace.x7, 0),
              child: Text(
                footer!,
                style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
              ),
            ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Row: icon (optional) + label + value/toggle/chevron
// ═════════════════════════════════════════════════════════════════════

class SettingsRow extends StatelessWidget {
  final SettingsRowIcon? icon;

  /// An icon from the system set instead of a drawn [icon] (owner,
  /// 2026-11-03: chat / contact actions had none) — same tinted square.
  final IconData? glyph;
  final SettingsRowTint? tint;
  final String label;

  /// One plain line under the label: what the row is for ("Bring your
  /// account back on a new phone") — owner, 2026-10-18.
  final String? subtitle;
  final String? value;
  final bool? toggle;
  final ValueChanged<bool>? onToggle;
  final VoidCallback? onTap;
  final bool mono;
  final bool isLast;

  /// One of a list of choices (theme, what notifications show): an accent
  /// check on the chosen one, no chevron — it doesn't lead anywhere
  /// (2026-10-16 UI audit; it was a "✓" value and a chevron).
  final bool? selected;

  /// False for a row that acts in place (reconnect, reset) instead of
  /// opening a screen — no chevron then.
  final bool chevron;

  const SettingsRow({
    super.key,
    this.icon,
    this.glyph,
    this.tint,
    required this.label,
    this.subtitle,
    this.value,
    this.toggle,
    this.onToggle,
    this.onTap,
    this.mono = false,
    this.isLast = false,
    this.selected,
    this.chevron = true,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final tintColors = resolveSettingsTint(tint ?? SettingsRowTint.neutral, tokens);
    final hasToggle = toggle != null;
    final isChoice = selected != null;
    // A chevron promises "this opens something" — only rows that do get one.
    // Info rows ("Timer · Per chat", server facts, "Text size · As on
    // iPhone") showed one and did nothing (owner, 2026-10-18).
    final hasValueChevron = chevron && !hasToggle && !isChoice && onTap != null;
    final labelText = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
    );

    final row = Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.nudge11, DsSpace.x3h5, DsSpace.nudge11),
      child: Row(
        children: [
          if (icon != null || glyph != null) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: tintColors.bg, borderRadius: BorderRadius.circular(8)),
              child: Center(
                child: glyph != null
                    ? Icon(glyph, size: 18, color: tintColors.fg)
                    : SizedBox(
                        width: 20,
                        height: 20,
                        child: CustomPaint(
                          painter: SettingsRowIconPainter(shape: icon!, color: tintColors.fg),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
          ] else
            const SizedBox(width: 0),
          Expanded(
            child: subtitle == null
                ? labelText
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      labelText,
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
                      ),
                    ],
                  ),
          ),
          if (value != null) ...[
            const SizedBox(width: 8),
            // The label is what the row means — the value gives way first
            // ("Показать слова ещё р…" next to "Не хранятся", 2026-10-16).
            ConstrainedBox(
              // A mono value (a key's fingerprint) is the least needed part.
              constraints: BoxConstraints(maxWidth: mono ? 104 : 128),
              child: Text(
                value!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: mono ? DsType.familyMono : DsType.family,
                  fontSize: mono ? 12 : 14,
                  fontWeight: mono ? FontWeight.w500 : FontWeight.w400,
                  letterSpacing: mono ? 0 : -0.1,
                  height: 1.2,
                  color: tokens.text3,
                ),
              ),
            ),
          ],
          if (hasToggle) ...[
            const SizedBox(width: 10),
            SettingsToggle(on: toggle!, onChanged: onToggle),
          ] else if (isChoice) ...[
            const SizedBox(width: 8),
            AnimatedOpacity(
              duration: DsMotion.of(context, DsMotion.fast),
              opacity: selected! ? 1 : 0,
              child: AnimatedScale(
                duration: DsMotion.of(context, DsMotion.fast),
                curve: DsMotion.springy,
                scale: selected! ? 1 : 0.6,
                child: CustomPaint(
                  size: const Size.square(20),
                  painter: DsGlyphPainter(DsGlyph.check, color: tokens.accent, strokeWidth: 2.2),
                ),
              ),
            ),
          ] else if (hasValueChevron) ...[
            const SizedBox(width: 8),
            SizedBox(width: 7, height: 12, child: CustomPaint(painter: RowChevronPainter(tokens.text4))),
          ],
        ],
      ),
    );

    // Suppress the gesture detector entirely if the row has nothing tappable
    // (no onTap, no toggle) — keeps hit-testing predictable.
    Widget content = (onTap != null || hasToggle)
        ? DsPressable(
            scale: 0.985,
            haptic: hasToggle ? Haptic.selection : null,
            onTap: hasToggle ? () => onToggle?.call(!toggle!) : onTap,
            child: row,
          )
        : row;
    // VoiceOver reads the row as one control: "Read receipts, switch, on"
    // (the switch alone had no name — tech-debt 2.29).
    if (hasToggle) content = MergeSemantics(child: content);
    if (isChoice) content = Semantics(selected: selected, inMutuallyExclusiveGroup: true, child: content);

    if (isLast) return content;

    // Hairline divider inset from the icon (left=56 if icon, else 14)
    return Stack(
      children: [
        content,
        Positioned(
          left: icon != null ? 56 : 14,
          right: 0,
          bottom: 0,
          height: 0.5,
          child: ColoredBox(color: tokens.divider),
        ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Toggle (iOS-style pill)
// ═════════════════════════════════════════════════════════════════════

class SettingsToggle extends StatefulWidget {
  final bool on;
  final ValueChanged<bool>? onChanged;

  /// What it switches, for VoiceOver — when no row label merges with it.
  final String? semanticLabel;

  const SettingsToggle({super.key, required this.on, this.onChanged, this.semanticLabel});

  @override
  State<SettingsToggle> createState() => _SettingsToggleState();
}

class _SettingsToggleState extends State<SettingsToggle> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: DsMotion.base, value: widget.on ? 1.0 : 0.0);
  }

  @override
  void didUpdateWidget(SettingsToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.on != oldWidget.on) {
      // Springy knob — UI backlog §4 item 36.
      _ctrl.animateTo(widget.on ? 1.0 : 0.0, curve: DsMotion.springy);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Semantics(
      toggled: widget.on,
      label: widget.semanticLabel,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DsHaptics.play(Haptic.selection);
        widget.onChanged?.call(!widget.on);
      },
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = _ctrl.value;
          final bg = Color.lerp(tokens.dividerStrong, tokens.accent, t)!;
          return Container(
            width: 44,
            height: 26,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              boxShadow: widget.on
                  ? [DsShadow.glowOf(tokens.accent, alpha: tokens.accent.a * 0.30, y: 1, blur: 2)]
                  : null,
            ),
            child: Stack(
              children: [
                Positioned(
                  top: 2,
                  left: 2 + 18 * t,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: DsPalette.white,
                      shape: BoxShape.circle,
                      boxShadow: [DsShadow.art18],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Row chevron (right caret used by every navigable row)
// ═════════════════════════════════════════════════════════════════════

class RowChevronPainter extends CustomPainter {
  final Color color;
  RowChevronPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 8;
    final sy = size.height / 14;
    canvas.save();
    canvas.scale(sx, sy);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(1, 1)
      ..lineTo(7, 7)
      ..lineTo(1, 13);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(RowChevronPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Icon + tint enums
// ═════════════════════════════════════════════════════════════════════

enum SettingsRowIcon {
  user,
  shield,
  devices,
  key,
  lock,
  bell,
  chats,
  paint,
  text,
  storage,
  download,
  server,
  info,
  trash,
  clock,
  photos,
  videos,
  voice,
  document,
  cache,
}

enum SettingsRowTint {
  privacy, // green
  devices, // violet
  recovery, // amber
  lock, // orange
  notif, // pink
  chats, // royal blue
  appear, // purple
  storage, // olive green
  download, // accent blue
  danger, // red
  // Grey trio (text/server/info/neutral) — theme-adaptive.
  text,
  server,
  info,
  neutral,
}

class SettingsTintColors {
  final Color bg;
  final Color fg;
  const SettingsTintColors(this.bg, this.fg);
}

/// Colored tints are theme-invariant (saturated brand colors read well on
/// both light cream and dark navy). Neutral/grey tints adapt to theme via
/// [tokens.text2] / [tokens.bgSoft].
SettingsTintColors resolveSettingsTint(SettingsRowTint tint, DsTokens tokens) {
  return switch (tint) {
    SettingsRowTint.privacy => const SettingsTintColors(DsPalette.green10, DsPalette.green),
    SettingsRowTint.devices => const SettingsTintColors(DsPalette.violet10, DsPalette.violet),
    SettingsRowTint.recovery => const SettingsTintColors(DsPalette.orange14, DsPalette.orange),
    SettingsRowTint.lock => const SettingsTintColors(DsPalette.artE0683Ba1F, DsPalette.coral),
    SettingsRowTint.notif => const SettingsTintColors(DsPalette.pink10, DsPalette.pink),
    SettingsRowTint.chats => const SettingsTintColors(DsPalette.blue600a10, DsPalette.blue600),
    SettingsRowTint.appear => const SettingsTintColors(DsPalette.art9333EAa1A, DsPalette.purple600),
    SettingsRowTint.storage => const SettingsTintColors(DsPalette.art65A30Da1F, DsPalette.lime600),
    SettingsRowTint.download => const SettingsTintColors(DsPalette.blue10, DsPalette.blue),
    SettingsRowTint.danger => const SettingsTintColors(DsPalette.red12, DsPalette.red),
    SettingsRowTint.text ||
    SettingsRowTint.server ||
    SettingsRowTint.info ||
    SettingsRowTint.neutral => SettingsTintColors(tokens.bgSoft, tokens.text2),
  };
}

// ═════════════════════════════════════════════════════════════════════
// Row icon painters (20pt viewBox=24, stroke 1.8)
// ═════════════════════════════════════════════════════════════════════

class SettingsRowIconPainter extends CustomPainter {
  final SettingsRowIcon shape;
  final Color color;
  SettingsRowIconPainter({required this.shape, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (shape) {
      case SettingsRowIcon.user:
        canvas.drawCircle(const Offset(12, 8), 4, stroke);
        final p = Path()
          ..moveTo(4, 21)
          ..cubicTo(4, 17, 7.6, 14, 12, 14)
          ..cubicTo(16.4, 14, 20, 17, 20, 21);
        canvas.drawPath(p, stroke);
      case SettingsRowIcon.shield:
        final p = Path()
          ..moveTo(12, 3)
          ..lineTo(20, 6)
          ..lineTo(20, 12)
          ..cubicTo(20, 17, 16.5, 20, 12, 21)
          ..cubicTo(7.5, 20, 4, 17, 4, 12)
          ..lineTo(4, 6)
          ..close();
        canvas.drawPath(p, stroke);
        final tick = Path()
          ..moveTo(9, 12)
          ..lineTo(11, 14)
          ..lineTo(15, 10);
        canvas.drawPath(tick, stroke);
      case SettingsRowIcon.devices:
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(3, 5, 13, 10), const Radius.circular(1.6)),
          stroke,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(14, 9, 7, 11), const Radius.circular(1.4)),
          stroke,
        );
        canvas.drawLine(const Offset(5, 18), const Offset(11, 18), stroke);
      case SettingsRowIcon.key:
        canvas.drawCircle(const Offset(8, 14), 4, stroke);
        canvas.drawLine(const Offset(11, 12), const Offset(20, 3), stroke);
        canvas.drawLine(const Offset(16, 5), const Offset(19, 8), stroke);
        canvas.drawLine(const Offset(14, 7), const Offset(17, 10), stroke);
      case SettingsRowIcon.lock:
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(4.5, 11, 15, 10), const Radius.circular(2.2)),
          stroke,
        );
        final shackle = Path()
          ..moveTo(8, 11)
          ..lineTo(8, 8)
          ..arcToPoint(const Offset(16, 8), radius: const Radius.circular(4))
          ..lineTo(16, 11);
        canvas.drawPath(shackle, stroke);
      case SettingsRowIcon.bell:
        final p = Path()
          ..moveTo(5, 16)
          ..lineTo(19, 16)
          ..lineTo(17, 13)
          ..lineTo(17, 9)
          ..cubicTo(17, 6.24, 14.76, 4, 12, 4)
          ..cubicTo(9.24, 4, 7, 6.24, 7, 9)
          ..lineTo(7, 13)
          ..close();
        canvas.drawPath(p, stroke);
        final clapper = Path()
          ..moveTo(10, 19)
          ..arcToPoint(const Offset(14, 19), radius: const Radius.circular(2));
        canvas.drawPath(clapper, stroke);
      case SettingsRowIcon.chats:
        final p = Path()
          ..moveTo(4, 6.5)
          ..cubicTo(4, 5.12, 5.12, 4, 6.5, 4)
          ..lineTo(17.5, 4)
          ..cubicTo(18.88, 4, 20, 5.12, 20, 6.5)
          ..lineTo(20, 14.5)
          ..cubicTo(20, 15.88, 18.88, 17, 17.5, 17)
          ..lineTo(10, 17)
          ..lineTo(6, 20.5)
          ..lineTo(6, 17)
          ..lineTo(6.5, 17)
          ..cubicTo(5.12, 17, 4, 15.88, 4, 14.5)
          ..close();
        canvas.drawPath(p, stroke);
      case SettingsRowIcon.paint:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawCircle(const Offset(7, 11), 1.2, fill);
        canvas.drawCircle(const Offset(10, 7), 1.2, fill);
        canvas.drawCircle(const Offset(15, 7), 1.2, fill);
        canvas.drawCircle(const Offset(17.5, 11.5), 1.2, fill);
        final dribble = Path()
          ..moveTo(12, 21)
          ..cubicTo(10.5, 21, 10, 20, 10.5, 19)
          ..cubicTo(11, 18, 12, 17.5, 12, 16.5)
          ..cubicTo(12, 15, 13.5, 14.5, 15, 15);
        canvas.drawPath(dribble, stroke);
      case SettingsRowIcon.text:
        canvas.drawLine(const Offset(4, 6), const Offset(20, 6), stroke);
        canvas.drawLine(const Offset(9, 6), const Offset(9, 20), stroke);
        canvas.drawLine(const Offset(15, 12), const Offset(20, 12), stroke);
        canvas.drawLine(const Offset(17, 12), const Offset(17, 20), stroke);
      case SettingsRowIcon.storage:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 4, 18, 6), const Radius.circular(1.6)), stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(3, 14, 18, 6), const Radius.circular(1.6)),
          stroke,
        );
        canvas.drawCircle(const Offset(7, 7), 0.9, fill);
        canvas.drawCircle(const Offset(7, 17), 0.9, fill);
      case SettingsRowIcon.download:
        final p = Path()
          ..moveTo(12, 4)
          ..lineTo(12, 16);
        canvas.drawPath(p, stroke);
        final arrow = Path()
          ..moveTo(7, 11)
          ..lineTo(12, 16)
          ..lineTo(17, 11);
        canvas.drawPath(arrow, stroke);
        canvas.drawLine(const Offset(5, 20), const Offset(19, 20), stroke);
      case SettingsRowIcon.server:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 5, 18, 6), const Radius.circular(1.6)), stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(3, 13, 18, 6), const Radius.circular(1.6)),
          stroke,
        );
        canvas.drawCircle(const Offset(7, 8), 0.9, fill);
        canvas.drawCircle(const Offset(7, 16), 0.9, fill);
        canvas.drawLine(const Offset(11, 8), const Offset(18, 8), stroke);
        canvas.drawLine(const Offset(11, 16), const Offset(18, 16), stroke);
      case SettingsRowIcon.info:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawLine(const Offset(12, 11), const Offset(12, 17), stroke);
        canvas.drawCircle(const Offset(12, 7.5), 1.1, fill);
      case SettingsRowIcon.trash:
        // Lid + bin
        canvas.drawLine(const Offset(3, 6), const Offset(21, 6), stroke);
        final bin = Path()
          ..moveTo(5, 6)
          ..lineTo(6, 20)
          ..cubicTo(6, 20.5, 6.5, 21, 7, 21)
          ..lineTo(17, 21)
          ..cubicTo(17.5, 21, 18, 20.5, 18, 20)
          ..lineTo(19, 6);
        canvas.drawPath(bin, stroke);
        // Handle
        final handle = Path()
          ..moveTo(9, 6)
          ..lineTo(9, 4)
          ..lineTo(15, 4)
          ..lineTo(15, 6);
        canvas.drawPath(handle, stroke);
        // Two vertical lines inside the bin
        canvas.drawLine(const Offset(10, 10), const Offset(10, 17), stroke);
        canvas.drawLine(const Offset(14, 10), const Offset(14, 17), stroke);
      case SettingsRowIcon.clock:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawLine(const Offset(12, 7), const Offset(12, 12), stroke);
        canvas.drawLine(const Offset(12, 12), const Offset(16, 14), stroke);
      case SettingsRowIcon.photos:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 5, 18, 14), const Radius.circular(2)), stroke);
        canvas.drawCircle(const Offset(8, 10), 1.6, stroke);
        final mountain = Path()
          ..moveTo(3, 18)
          ..lineTo(9, 12)
          ..lineTo(13, 15)
          ..lineTo(16, 12)
          ..lineTo(21, 17);
        canvas.drawPath(mountain, stroke);
      case SettingsRowIcon.videos:
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(2.5, 6, 14, 12), const Radius.circular(2)),
          stroke,
        );
        final play = Path()
          ..moveTo(21.5, 7)
          ..lineTo(16.5, 10)
          ..lineTo(16.5, 14)
          ..lineTo(21.5, 17)
          ..close();
        canvas.drawPath(play, stroke);
      case SettingsRowIcon.voice:
        // Waveform — 5 vertical bars of varying length, center-anchored.
        const xs = <double>[4.5, 8, 11.5, 15, 18.5];
        const tops = <double>[9.5, 7, 4, 8, 6];
        const heights = <double>[4.5, 10, 16, 8, 12];
        for (var i = 0; i < xs.length; i++) {
          canvas.drawLine(Offset(xs[i], tops[i]), Offset(xs[i], tops[i] + heights[i]), stroke);
        }
      case SettingsRowIcon.document:
        final p = Path()
          ..moveTo(6, 3)
          ..lineTo(14, 3)
          ..lineTo(19, 8)
          ..lineTo(19, 20)
          ..cubicTo(19, 20.55, 18.55, 21, 18, 21)
          ..lineTo(6, 21)
          ..cubicTo(5.45, 21, 5, 20.55, 5, 20)
          ..lineTo(5, 4)
          ..cubicTo(5, 3.45, 5.45, 3, 6, 3)
          ..close();
        canvas.drawPath(p, stroke);
        // Fold corner
        final fold = Path()
          ..moveTo(14, 3)
          ..lineTo(14, 8)
          ..lineTo(19, 8);
        canvas.drawPath(fold, stroke);
        // Text lines
        canvas.drawLine(const Offset(8, 13), const Offset(16, 13), stroke);
        canvas.drawLine(const Offset(8, 16), const Offset(16, 16), stroke);
        canvas.drawLine(const Offset(8, 19), const Offset(13, 19), stroke);
      case SettingsRowIcon.cache:
        // Database cylinder
        final top = Path()
          ..moveTo(4, 6)
          ..cubicTo(4, 4.9, 7.6, 4, 12, 4)
          ..cubicTo(16.4, 4, 20, 4.9, 20, 6)
          ..cubicTo(20, 7.1, 16.4, 8, 12, 8)
          ..cubicTo(7.6, 8, 4, 7.1, 4, 6)
          ..close();
        canvas.drawPath(top, stroke);
        final mid = Path()
          ..moveTo(4, 6)
          ..lineTo(4, 12)
          ..cubicTo(4, 13.1, 7.6, 14, 12, 14)
          ..cubicTo(16.4, 14, 20, 13.1, 20, 12)
          ..lineTo(20, 6);
        canvas.drawPath(mid, stroke);
        final bot = Path()
          ..moveTo(4, 12)
          ..lineTo(4, 18)
          ..cubicTo(4, 19.1, 7.6, 20, 12, 20)
          ..cubicTo(16.4, 20, 20, 19.1, 20, 18)
          ..lineTo(20, 12);
        canvas.drawPath(bot, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(SettingsRowIconPainter old) => old.shape != shape || old.color != color;
}
