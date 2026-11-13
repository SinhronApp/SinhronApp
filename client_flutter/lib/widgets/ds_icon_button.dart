import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import '../l10n/l10n.dart';
import 'ds_icon.dart';
import 'ds_pressable.dart';

class DsIconButton extends StatelessWidget {
  final DsIconShape shape;
  final double iconSize;
  final double tapSize;
  final int? badge;
  final VoidCallback? onTap;

  /// VoiceOver label (§7 item 55); defaults from the icon.
  final String? semanticLabel;

  const DsIconButton({
    super.key,
    required this.shape,
    this.iconSize = 20,
    this.tapSize = 36,
    this.badge,
    this.onTap,
    this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final child = SizedBox(
      width: tapSize,
      height: tapSize,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          DsIcon(shape: shape, size: iconSize, color: tokens.text),
          if (badge != null)
            Positioned(
              top: 2,
              right: 2,
              child: _DsBadge(count: badge!, bgColor: tokens.bg),
            ),
        ],
      ),
    );

    final l = context.l10n;
    final label =
        semanticLabel ??
        switch (shape) {
          DsIconShape.search => l.a11ySearch,
          DsIconShape.edit => l.newChat,
          DsIconShape.call => l.call,
          _ => null,
        };
    if (onTap == null) return child;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: label != null,
      onTap: onTap,
      child: DsPressable(onTap: onTap, child: child),
    );
  }
}

class _DsBadge extends StatelessWidget {
  final int count;
  final Color bgColor;

  const _DsBadge({required this.count, required this.bgColor});

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
      child: Center(child: Text(count.toString(), style: DsTextArt.t10w700v2.copyWith(color: tokens.accentText))),
    );
  }
}
