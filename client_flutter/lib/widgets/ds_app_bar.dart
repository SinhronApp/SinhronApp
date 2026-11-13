// Minimal app bar for sub-screens. Based on design/app/entry.jsx DsHeader:
// - 44 minHeight, 6/10 padding
// - Left: optional back chevron (22×22 icon, 36×36 tap target, 10r)
// - Center: optional title (17/600/-0.3, single line)
// - Right: optional step counter ("1 / 3", mono 12/600/text-3) OR custom trailing
//
// Distinct from `DsHeader` in widgets/ds_header.dart which is chat-list specific
// (avatar + title + actions row). This `DsAppBar` is for entry/settings sub-screens.
//
// §18.17: NOT a Material AppBar — pure custom widget.

import 'package:flutter/widgets.dart';

import '../l10n/l10n.dart';

import '../app/theme/tokens.dart';
import 'ds_icon.dart';

class DsAppBar extends StatelessWidget {
  final String? title;
  final VoidCallback? onBack;

  /// Step counter like "1 / 3". Rendered in mono, right-aligned. Ignored if [trailing] is set.
  final String? step;

  /// Custom trailing widget. Takes precedence over [step].
  final Widget? trailing;

  /// Whether to show the back chevron. Default: true if [onBack] != null, else false.
  final bool? showBack;

  const DsAppBar({super.key, this.title, this.onBack, this.step, this.trailing, this.showBack});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final showBackButton = showBack ?? (onBack != null);

    Widget? backButton;
    if (showBackButton) {
      // VoiceOver: "Back, button" (it read as a bare "button" — tech-debt 2.29).
      backButton = Semantics(
        button: true,
        label: context.l10n.a11yBack,
        excludeSemantics: true,
        onTap: onBack,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onBack,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: CustomPaint(
                size: const Size.square(22),
                painter: DsGlyphPainter(DsGlyph.back, color: tokens.text),
              ),
            ),
          ),
        ),
      );
    }

    Widget? trailingWidget;
    if (trailing != null) {
      trailingWidget = trailing;
    } else if (step != null) {
      trailingWidget = Padding(
        padding: const EdgeInsets.only(right: DsSpace.x3h5),
        child: Text(step!, style: DsTextArt.t12w600Mono.copyWith(color: tokens.text3)),
      );
    }

    final centerTitle = title == null
        ? null
        : _FittingTitle(title!, style: DsText.headline.copyWith(height: 1.0, color: tokens.text));

    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x1h5),
      child: Stack(
        children: [
          // Center title (centered absolutely so it ignores left/right widget widths)
          if (centerTitle != null)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x14),
                child: Center(child: centerTitle),
              ),
            ),
          // Left + right slots
          Row(children: [?backButton, const Spacer(), ?trailingWidget]),
        ],
      ),
    );
  }
}

/// A title that shrinks a little (to 82 %) before it gives up and ends in
/// "…" — "Подключить новое устройс…" and "Политика конфиденциальн…" were
/// cut on a 375-pt phone (2026-10-16 UI audit).
class _FittingTitle extends StatelessWidget {
  const _FittingTitle(this.text, {required this.style});
  final String text;
  final TextStyle style;

  static const double _minScale = 0.82;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      final scale = width <= box.maxWidth ? 1.0 : (box.maxWidth / width).clamp(_minScale, 1.0);
      return Text(
        text,
        style: style.copyWith(fontSize: (style.fontSize ?? 17) * scale),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      );
    },
  );
}
