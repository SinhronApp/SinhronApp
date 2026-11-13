// Sheets — one look everywhere (owner, 2026-11-03: "modal windows … the
// same everywhere, beautiful on iPad and iPhone"): the screen behind
// dims (no blur — it janked), the sheet is a rounded card that slides up from the bottom of
// a phone (with a grabber) or fades in as a centred card on a wide screen
// ([DsSheetPlacement]). Bare WidgetsApp has no showModalBottomSheet, so
// [dsSheetRoute] is our own route; every sheet uses it.
//
// The action sheet itself — UI backlog §2 (chat peek, folder menu,
// confirmations): an optional [header] (a chat preview, a sticker pack)
// above the actions.


import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import '../l10n/l10n.dart';
import '../app/adaptive.dart';

class DsSheetAction<T> {
  const DsSheetAction(this.label, this.value, {this.destructive = false, this.icon, this.checked = false});
  final String label;
  final T value;
  final bool destructive;

  /// The current choice (timer, wallpaper): a check icon after the words,
  /// not a "✓ " in them (owner's icons rule, 2026-11-03).
  final bool checked;

  /// Owner, 2026-11-03 ("a bare list of words"): with an icon the action is
  /// a menu row — words on the left, the icon on the right, as in iOS
  /// context menus. Without one it stays a centred action-sheet button.
  final IconData? icon;
}

/// The route every sheet is pushed with: a dimmed backdrop (no blur) (a tap
/// on it closes the sheet when [dismissible]), the sheet sliding up from
/// the bottom — or fading in, a little scaled, when [centred] and on a
/// wide screen, where it is a popup. [dragToDismiss]: pull it down to
/// close (a phone).
Route<T> dsSheetRoute<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool dismissible = true,
  bool centred = false,
  bool dragToDismiss = false,
}) {
  return PageRouteBuilder<T>(
    opaque: false,
    barrierDismissible: dismissible,
    barrierColor: DsPalette.transparent,
    transitionDuration: DsMotion.of(context, DsMotion.base),
    reverseTransitionDuration: DsMotion.of(context, DsMotion.fast),
    pageBuilder: (ctx, _, _) => Builder(builder: builder),
    transitionsBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(parent: anim, curve: DsMotion.emphasized, reverseCurve: DsMotion.exit);
      final popup = centred || isWide(ctx);
      final sheet = popup || !dragToDismiss ? child : _DragToDismiss(child: child);
      return AnimatedBuilder(
        animation: curved,
        builder: (_, _) => Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const ValueKey('sheet-backdrop'),
                onTap: dismissible ? () => Navigator.of(ctx).maybePop() : null,
                child: ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.34 * curved.value)),
              ),
            ),
            if (popup)
              Opacity(
                opacity: curved.value.clamp(0.0, 1.0),
                child: Transform.scale(scale: 0.94 + 0.06 * curved.value, child: sheet),
              )
            else
              // The slide is DsSheetPlacement's: the sheet rises by its own
              // height, so it is on screen from the first frame.
              sheet,
          ],
        ),
      );
    },
  );
}

/// The sheet's card: the surface, rounded all round, lifted off the dim.
BoxDecoration dsSheetCard(DsTokens tokens) => BoxDecoration(
  color: tokens.surface,
  borderRadius: BorderRadius.circular(tokens.radiusCard),
  boxShadow: DsShadow.menu,
);

/// The pill at the top of a bottom sheet ("pull me down"). Not on a wide
/// screen's popup.
class DsSheetGrabber extends StatelessWidget {
  const DsSheetGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    if (DsSheetPlacement.popupOf(context)) return const SizedBox.shrink();
    return Center(
      child: Container(
        key: const ValueKey('sheet-grabber'),
        width: 36,
        height: 5,
        decoration: BoxDecoration(color: DsTheme.of(context).dividerStrong, borderRadius: BorderRadius.circular(3)),
      ),
    );
  }
}

/// A sheet's heading: [title], and [subtitle] in small grey under it.
class DsSheetTitle extends StatelessWidget {
  const DsSheetTitle(this.title, {super.key, this.subtitle});
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x5, DsSpace.x2, DsSpace.x5, DsSpace.x2h5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, textAlign: TextAlign.center, style: DsText.headline.copyWith(color: tokens.text)),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: DsSpace.x1),
              child: Text(subtitle!, textAlign: TextAlign.center, style: DsText.footnote.copyWith(color: tokens.text3)),
            ),
        ],
      ),
    );
  }
}

/// One row of a menu — the chat peek, the message menu, a picker: words on
/// the left, the icon on the right, a soft highlight under the finger.
class DsMenuRow extends StatefulWidget {
  const DsMenuRow({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.destructive = false,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool destructive;

  /// The current choice (a picker): in the accent colour.
  final bool selected;

  static const double height = 46;

  @override
  State<DsMenuRow> createState() => _DsMenuRowState();
}

class _DsMenuRowState extends State<DsMenuRow> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final color = widget.destructive
        ? tokens.danger
        : widget.selected
        ? tokens.accent
        : tokens.text;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _press(true),
      onTapCancel: () => _press(false),
      onTapUp: (_) => _press(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: DsMotion.of(context, DsMotion.fast),
        height: DsMenuRow.height,
        color: _down ? tokens.divider : DsPalette.transparent,
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DsText.bodyLarge.copyWith(
                  fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ),
            if (widget.icon case final icon?)
              Padding(
                padding: const EdgeInsets.only(left: DsSpace.x3),
                child: Icon(icon, size: 20, color: widget.destructive || widget.selected ? color : tokens.text2),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shows [actions] (and an optional [header], e.g. a chat preview) in a
/// sheet over a dimmed backdrop. Resolves to the picked action's
/// value, or null on Cancel / tap outside / pulled down. A menu (every
/// action has its icon) has no Cancel — a tap outside closes it, as in iOS.
Future<T?> showDsActionSheet<T>(
  BuildContext context, {
  String? title,
  Widget? header,
  required List<DsSheetAction<T>> actions,
  String? cancelLabel,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    dsSheetRoute<T>(
      context,
      (ctx) => _ActionSheet<T>(title: title, header: header, actions: actions, cancelLabel: cancelLabel ?? ctx.l10n.cancel),
      dragToDismiss: true,
    ),
  );
}

/// Drag the sheet down: it follows with rubber-band resistance going up,
/// closes past a distance / flick, otherwise springs back. A list inside
/// that scrolls takes the drag itself.
class _DragToDismiss extends StatefulWidget {
  const _DragToDismiss({required this.child});
  final Widget child;

  @override
  State<_DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<_DragToDismiss> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        final next = _c.value + d.delta.dy;
        // Down: 1:1. Up: heavy resistance (rubber band).
        _c.value = next >= 0 ? next : _c.value + d.delta.dy * 0.2;
      },
      onVerticalDragEnd: (d) {
        final v = d.velocity.pixelsPerSecond.dy;
        if (_c.value > 120 || v > 900) {
          Navigator.of(context).maybePop();
        } else {
          _c.animateWith(SpringSimulation(DsMotion.spring, _c.value, 0, v));
        }
      },
      child: AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (_, child) => Transform.translate(offset: Offset(0, _c.value), child: child),
      ),
    );
  }
}

class _ActionSheet<T> extends StatelessWidget {
  const _ActionSheet({this.title, this.header, required this.actions, required this.cancelLabel});

  final String? title;
  final Widget? header;
  final List<DsSheetAction<T>> actions;
  final String cancelLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final menu = actions.isNotEmpty && actions.every((a) => a.icon != null);
    Widget button(
      String label,
      VoidCallback onTap, {
      bool destructive = false,
      bool bold = false,
      bool checked = false,
      Key? key,
    }) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.nudge15),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: DsText.headline.copyWith(
                  fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
                  color: destructive ? tokens.danger : tokens.accent,
                ),
              ),
            ),
            if (checked) ...[
              const SizedBox(width: 6),
              Icon(CupertinoIcons.checkmark_alt, key: const ValueKey('sheet-action-checked'), size: 20, color: tokens.accent),
            ],
          ],
        ),
      ),
    );
    Widget divider() => Container(height: 0.5, color: tokens.divider);
    const grabber = Padding(
      padding: EdgeInsets.only(top: DsSpace.x2, bottom: DsSpace.x1),
      child: DsSheetGrabber(),
    );

    return DsSheetPlacement(
      radius: tokens.radiusCard,
      builder: (context) {
        final mq = MediaQuery.of(context);
        final popup = DsSheetPlacement.popupOf(context);
        final h = mq.size.height;
        final bottom = mq.padding.bottom;
        final list = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header == null && !popup) grabber,
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2h5),
                child: Text(title!, textAlign: TextAlign.center, style: DsText.subhead.copyWith(color: tokens.text3)),
              ),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0 || title != null) divider(),
              if (actions[i].icon != null)
                DsMenuRow(
                  key: ValueKey('sheet-action-${actions[i].label}'),
                  label: actions[i].label,
                  icon: actions[i].icon,
                  destructive: actions[i].destructive,
                  onTap: () => Navigator.of(context).pop(actions[i].value),
                )
              else
                button(
                  actions[i].label,
                  () => Navigator.of(context).pop(actions[i].value),
                  destructive: actions[i].destructive,
                  checked: actions[i].checked,
                  key: ValueKey('sheet-action-${actions[i].label}'),
                ),
            ],
          ],
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(
            DsSpace.x2,
            popup ? DsSpace.x2 : mq.padding.top + DsSpace.x2,
            DsSpace.x2,
            bottom > 0 ? bottom : DsSpace.x2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (header != null) ...[
                // The header takes what the actions leave, up to its own
                // height (the chat peek asks for most of the screen).
                Flexible(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: h * 0.62),
                    child: Container(
                      width: double.infinity,
                      decoration: dsSheetCard(tokens),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [if (!popup) grabber, Flexible(child: header!)],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: DsSpace.x2),
              ],
              ConstrainedBox(
                // Many actions on a low screen scroll rather than overflow.
                constraints: BoxConstraints(maxHeight: h * (header == null ? 0.8 : 0.6)),
                child: Container(
                  decoration: dsSheetCard(tokens),
                  clipBehavior: Clip.antiAlias,
                  child: SingleChildScrollView(child: list),
                ),
              ),
              if (!menu) ...[
                const SizedBox(height: DsSpace.x2),
                Container(
                  decoration: dsSheetCard(tokens),
                  child: button(cancelLabel, () => Navigator.of(context).pop(), bold: true, key: const ValueKey('sheet-cancel')),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
