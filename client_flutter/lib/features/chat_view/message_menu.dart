// Message context menu — UI backlog §3 items 23-24. iMessage-style: the
// pressed bubble lifts out of a blurred chat, a reaction bar springs in
// above it and the action list below (or above, near the bottom).

import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../widgets/ds_action_sheet.dart' show DsMenuRow, dsSheetCard;
import '../../widgets/ds_pressable.dart';

/// What the user picked.
sealed class MenuChoice {
  const MenuChoice();
}

/// A reaction tapped in the bar (null = remove mine).
class MenuReaction extends MenuChoice {
  const MenuReaction(this.emoji);
  final String? emoji;
}

/// An action from the list.
class MenuAction extends MenuChoice {
  const MenuAction(this.id);
  final String id;
}

class MessageMenuItem {
  const MessageMenuItem(this.id, this.label, {this.destructive = false});
  final String id;
  final String label;
  final bool destructive;

  /// Owner, 2026-11-03: the menu was bare words — each action has its icon
  /// (by id, so every menu gets them), on the right as in iOS.
  IconData? get icon => switch (id) {
    'reply' => CupertinoIcons.arrowshape_turn_up_left,
    'copy' => CupertinoIcons.doc_on_doc,
    'select-text' => CupertinoIcons.text_cursor,
    'forward' => CupertinoIcons.arrowshape_turn_up_right,
    'save' => CupertinoIcons.bookmark,
    'pin' => CupertinoIcons.pin,
    'unpin' => CupertinoIcons.pin_slash,
    'edit' => CupertinoIcons.pencil,
    'select' => CupertinoIcons.checkmark_circle,
    'report' => CupertinoIcons.exclamationmark_bubble,
    'delete' => CupertinoIcons.trash,
    'retry' => CupertinoIcons.arrow_clockwise,
    'info' => CupertinoIcons.info_circle,
    'cancel-send' => CupertinoIcons.xmark_circle,
    _ => null,
  };
}

/// Show the menu for a bubble currently drawn at [origin] (global).
Future<MenuChoice?> showMessageMenu(
  BuildContext context, {
  required Rect origin,
  required Widget bubble,
  required bool alignRight,
  required List<MessageMenuItem> items,
  List<String> reactions = const [],
  String? myReaction,
}) {
  return Navigator.of(context, rootNavigator: true).push<MenuChoice>(
    PageRouteBuilder<MenuChoice>(
      opaque: false,
      barrierDismissible: true,
      barrierColor: DsPalette.transparent,
      transitionDuration: DsMotion.of(context, DsMotion.slow),
      reverseTransitionDuration: DsMotion.of(context, DsMotion.fast),
      pageBuilder: (ctx, anim, _) => _MessageMenu(
        animation: anim,
        origin: origin,
        bubble: bubble,
        alignRight: alignRight,
        items: items,
        reactions: reactions,
        myReaction: myReaction,
      ),
    ),
  );
}

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({
    required this.animation,
    required this.origin,
    required this.bubble,
    required this.alignRight,
    required this.items,
    required this.reactions,
    required this.myReaction,
  });

  final Animation<double> animation;
  final Rect origin;
  final Widget bubble;
  final bool alignRight;
  final List<MessageMenuItem> items;
  final List<String> reactions;
  final String? myReaction;

  static const _barH = 52.0;
  static const _itemH = DsMenuRow.height + 0.5;
  static const _gap = 8.0;

  /// The bubble keeps at least this much when the menu is long.
  static const _minBubble = 120.0;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final top = pad.top + 8;
    final bottom = size.height - pad.bottom - 8;
    final barSpace = reactions.isEmpty ? 0.0 : _barH + _gap;
    // The menu scrolls only when even a small bubble leaves it no room.
    final menuFull = items.length * _itemH;
    final menuRoom = (bottom - top) - barSpace - _minBubble - _gap;
    final menuH = menuFull < menuRoom ? menuFull : (menuRoom < 3 * _itemH ? 3 * _itemH : menuRoom);

    // Bar + bubble + menu always fit: a bubble taller than what's left is
    // shown in a box of that height that scrolls (iOS / Telegram), so the
    // whole message can still be read and the menu stays on screen.
    final maxBubble = (bottom - top) - menuH - barSpace - _gap;
    final cap = maxBubble < 80 ? 80.0 : maxBubble;
    final scrolls = origin.height > cap;
    final bubbleH = scrolls ? cap : origin.height;
    // Prefer the bubble where it was; shift it so everything fits.
    var bubbleTop = origin.top.clamp(top + barSpace, bottom - menuH - _gap - bubbleH);
    if (bubbleTop.isNaN) bubbleTop = top + barSpace;
    final menuTop = bubbleTop + bubbleH + _gap;

    final enter = CurvedAnimation(parent: animation, curve: DsMotion.springy, reverseCurve: DsMotion.exit);
    final fade = CurvedAnimation(parent: animation, curve: DsMotion.enter, reverseCurve: DsMotion.exit);

    Widget slot({required double t, required Widget child}) =>
        Positioned(top: t, left: alignRight ? null : 12, right: alignRight ? 12 : null, child: child);

    final rows = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Container(height: 0.5, color: tokens.divider),
          DsMenuRow(
            key: ValueKey('menu-${items[i].id}'),
            label: items[i].label,
            icon: items[i].icon,
            destructive: items[i].destructive,
            onTap: () => Navigator.of(context).pop(MenuAction(items[i].id)),
          ),
        ],
      ],
    );

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const ValueKey('menu-backdrop'),
              onTap: () => Navigator.of(context).maybePop(),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18 * fade.value, sigmaY: 18 * fade.value),
                child: ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.22 * fade.value)),
              ),
            ),
          ),
          // The bubble glides from where it was and lifts a little.
          Positioned(
            top: origin.top + (bubbleTop - origin.top) * fade.value,
            left: origin.left,
            width: origin.width,
            height: bubbleH,
            child: Transform.scale(
              scale: 1 + 0.03 * enter.value,
              child: scrolls
                  ? SingleChildScrollView(
                      key: const ValueKey('menu-bubble-scroll'),
                      physics: const BouncingScrollPhysics(),
                      child: IgnorePointer(child: bubble),
                    )
                  : IgnorePointer(
                      child: ClipRect(
                        child: OverflowBox(alignment: Alignment.topCenter, maxHeight: origin.height, child: bubble),
                      ),
                    ),
            ),
          ),
          if (reactions.isNotEmpty)
            slot(
              t: bubbleTop - _barH - _gap,
              child: Opacity(
                opacity: fade.value,
                child: Transform.scale(
                  scale: 0.6 + 0.4 * enter.value,
                  alignment: alignRight ? Alignment.bottomRight : Alignment.bottomLeft,
                  child: _ReactionBar(reactions: reactions, mine: myReaction, height: _barH),
                ),
              ),
            ),
          slot(
            t: menuTop,
            child: Opacity(
              opacity: fade.value,
              child: Transform.scale(
                scale: 0.85 + 0.15 * enter.value,
                alignment: alignRight ? Alignment.topRight : Alignment.topLeft,
                child: Container(
                  width: 250,
                  constraints: BoxConstraints(maxHeight: menuH),
                  decoration: dsSheetCard(tokens).copyWith(borderRadius: BorderRadius.circular(14)),
                  clipBehavior: Clip.antiAlias,
                  child: menuH < menuFull ? SingleChildScrollView(child: rows) : rows,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The quick reactions above a held message: emoji pop in one after
/// another, shrink under the finger, and my current one sits in a soft
/// accent ring (tap it again to take it back).
class _ReactionBar extends StatefulWidget {
  const _ReactionBar({required this.reactions, required this.mine, required this.height});
  final List<String> reactions;
  final String? mine;
  final double height;

  @override
  State<_ReactionBar> createState() => _ReactionBarState();
}

class _ReactionBarState extends State<_ReactionBar> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(vsync: this, duration: DsMotion.slow)..forward();

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final n = widget.reactions.length;
    return Container(
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(widget.height / 2),
        border: Border.all(color: tokens.divider, width: 0.5),
        boxShadow: DsShadow.menu,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < n; i++)
            _ReactionPick(
              key: ValueKey('react-${widget.reactions[i]}'),
              emoji: widget.reactions[i],
              selected: widget.reactions[i] == widget.mine,
              appear: CurvedAnimation(
                parent: _in,
                curve: Interval(i / (n + 2), (i + 3) / (n + 2), curve: Curves.easeOutBack),
              ),
              // Tapping my current reaction again removes it.
              onTap: () => Navigator.of(context).pop(MenuReaction(widget.reactions[i] == widget.mine ? null : widget.reactions[i])),
            ),
        ],
      ),
    );
  }
}

class _ReactionPick extends StatelessWidget {
  const _ReactionPick({super.key, required this.emoji, required this.selected, required this.appear, required this.onTap});
  final String emoji;
  final bool selected;
  final Animation<double> appear;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return DsPressable(
      onTap: onTap,
      scale: 0.78,
      haptic: Haptic.selection,
      child: AnimatedBuilder(
        animation: appear,
        builder: (_, child) => Transform.scale(scale: appear.value.clamp(0.0, 1.2), child: child),
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: selected
              ? BoxDecoration(
                  color: tokens.accentSoft,
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.accent.withValues(alpha: 0.45), width: 1.5),
                )
              : null,
          child: Text(emoji, style: DsTextArt.t26),
        ),
      ),
    );
  }
}
