import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import '../core/haptics.dart';
import 'ds_count_badge.dart';
import 'ds_pressable.dart';

class DsFilterPill extends StatelessWidget {
  final String label;
  final bool active;
  final int? count;
  final VoidCallback? onTap;

  const DsFilterPill({super.key, required this.label, this.active = false, this.count, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);

    final bgColor = active ? tokens.text : tokens.bgSoft;
    final fgColor = active ? tokens.bg : tokens.text2;
    final countBg = active
        ? DsPalette
              .white20 // rgba(255,255,255,0.20)
        : tokens.accentSoft;
    final countFg = active ? fgColor : tokens.accent;

    final pill = AnimatedContainer(
      duration: DsMotion.of(context, DsMotion.base),
      curve: DsMotion.enter,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.nudge7),
      decoration: BoxDecoration(color: bgColor, borderRadius: BorderRadius.circular(tokens.radiusPill)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: DsType.filterPill.copyWith(color: fgColor)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.nudge1),
              decoration: BoxDecoration(color: countBg, borderRadius: BorderRadius.circular(999)),
              child: DsAnimatedCount(
                count: count!,
                style: DsType.filterCount.copyWith(color: countFg),
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) return pill;
    return DsPressable(onTap: onTap, haptic: Haptic.selection, child: pill);
  }
}

class DsFilters extends StatelessWidget {
  final List<String> filters;
  final String active;
  final Map<String, int> counts;
  final ValueChanged<String>? onSelect;

  const DsFilters({super.key, required this.filters, required this.active, this.counts = const {}, this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1, DsSpace.x4, DsSpace.x2h5),
      child: Row(
        children: [
          for (int i = 0; i < filters.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            DsFilterPill(
              label: filters[i],
              active: filters[i] == active,
              count: counts[filters[i]],
              onTap: onSelect == null ? null : () => onSelect!(filters[i]),
            ),
          ],
        ],
      ),
    );
  }
}
