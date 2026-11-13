import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import '../core/haptics.dart';
import '../l10n/l10n.dart';
import 'ds_blur_bar.dart';
import 'ds_count_badge.dart';
import 'ds_icon.dart';
import 'ds_motion.dart';
import 'ds_pressable.dart';

enum DsTabId { chats, calls, contacts, settings }

class DsTabItem {
  final DsTabId id;
  final String label;
  final DsIconShape icon;
  final int? badge;

  const DsTabItem({required this.id, required this.label, required this.icon, this.badge});
}

class DsTabBar extends StatelessWidget {
  final DsTabId active;
  final List<DsTabItem> items;
  final EdgeInsetsGeometry safeBottomPadding;
  final ValueChanged<DsTabId>? onSelect;

  const DsTabBar({
    super.key,
    required this.active,
    required this.items,
    this.safeBottomPadding = const EdgeInsets.only(bottom: DsSpace.x4),
    this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Translucent on iPhone / iPad: the list scrolls under it (backlog §5
    // item 41). Opaque elsewhere (Android). The boundaries keep the bar and
    // the list under it from repainting each other.
    return RepaintBoundary(
      child: DsBlurBar(
        top: true,
        glass: defaultTargetPlatform == TargetPlatform.iOS,
        child: RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x2, DsSpace.x2, 0).add(safeBottomPadding),
            child: Row(
              children: [
                for (final t in items)
                  Expanded(
                    child: _Tab(item: t, active: t.id == active, onTap: onSelect),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final DsTabItem item;
  final bool active;
  final ValueChanged<DsTabId>? onTap;

  const _Tab({required this.item, required this.active, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final color = active ? tokens.text : tokens.text3;
    // Labels come from the tab id, in the app's language (§7 item 53).
    final l = context.l10n;
    final label = switch (item.id) {
      DsTabId.chats => l.tabChats,
      DsTabId.calls => l.tabCalls,
      DsTabId.contacts => l.tabContacts,
      DsTabId.settings => l.tabSettings,
    };
    final labelStyle = (active ? DsType.tabLabelActive : DsType.tabLabel).copyWith(color: color);

    final iconWithBadge = SizedBox(
      width: 30,
      height: 22,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // No spring on the icon: bounce is for badges and reactions (ADR-108).
          DsIcon(shape: item.icon, size: 22, color: color),
          // Nothing unread → no badge (a "0" bubble used to show).
          if ((item.badge ?? 0) > 0)
            Positioned(
              top: -4,
              right: -8,
              child: DsPopIn(child: _TabBadge(count: item.badge!, bgColor: tokens.bg)),
            ),
        ],
      ),
    );

    final body = Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x1h5, DsSpace.x1, DsSpace.x0h5),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          iconWithBadge,
          const SizedBox(height: 4),
          Text(label, style: labelStyle),
        ],
      ),
    );

    if (onTap == null) return body;
    return Semantics(
      button: true,
      selected: active,
      label: item.badge != null && item.badge! > 0 ? '$label, ${context.l10n.a11yUnread(item.badge!)}' : label,
      excludeSemantics: true,
      onTap: () => onTap!(item.id),
      child: DsPressable(onTap: () => onTap!(item.id), haptic: Haptic.selection, scale: 0.9, child: body),
    );
  }
}

class _TabBadge extends StatelessWidget {
  final int count;
  final Color bgColor;

  const _TabBadge({required this.count, required this.bgColor});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
      decoration: BoxDecoration(
        color: tokens.accent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: bgColor, width: 2),
      ),
      alignment: Alignment.center,
      child: DsAnimatedCount(count: count, style: DsTextArt.t10w700v2.copyWith(color: tokens.accentText)),
    );
  }
}
