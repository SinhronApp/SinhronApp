// Drag to reorder — tech-debt 2.21: pinned chats (folders moved to
// Settings → Chat folders, chat_folders_screen.dart, 2026-10-18).
//
// Hold a row (or grab its handle) and drag; the new order is saved on
// drop. The "Move up / down" and "Move left / right" menu items stay —
// they are the VoiceOver path.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';

class ReorderItem {
  const ReorderItem(this.id, this.label);
  final String id;
  final String label;
}

class ReorderScreen extends ConsumerStatefulWidget {
  const ReorderScreen({super.key, required this.title, required this.items, required this.onReorder, this.onBack});

  final String title;
  final List<ReorderItem> items;

  /// Called after each drop with every id in the new order.
  final Future<void> Function(List<String> ids) onReorder;
  final VoidCallback? onBack;

  @override
  ConsumerState<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends ConsumerState<ReorderScreen> {
  late final List<ReorderItem> _items = [...widget.items];

  void _move(int from, int to) {
    if (to > from) to -= 1; // ReorderableList reports the slot before removal
    if (to == from) return;
    setState(() => _items.insert(to, _items.removeAt(from)));
    unawaited(ref.read(hapticsProvider).play(Haptic.selection));
    unawaited(widget.onReorder([for (final i in _items) i.id]).catchError((Object _) {}));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(title: widget.title, onBack: widget.onBack ?? () => Navigator.of(context).maybePop()),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x2, DsSpace.gutter, DsSpace.x2),
              child: Text(context.l10n.reorderHint, style: DsText.footnote.copyWith(color: tokens.text3)),
            ),
            Expanded(
              child: ReorderableList(
                key: const ValueKey('reorder-list'),
                itemCount: _items.length,
                onReorder: _move,
                onReorderStart: (_) => unawaited(ref.read(hapticsProvider).play(Haptic.menu)),
                itemBuilder: (context, i) {
                  final item = _items[i];
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('reorder-${item.id}'),
                    index: i,
                    child: _Row(label: item.label, index: i),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.index});
  final String label;
  final int index;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: DsSpace.gutter),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.bodyLarge.copyWith(color: tokens.text),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: SizedBox(
              key: ValueKey('reorder-handle-$index'),
              width: 56,
              height: 56,
              child: ReorderHandle(color: tokens.text3),
            ),
          ),
        ],
      ),
    );
  }
}

/// Three short lines — the iOS drag handle: 18-pt strokes 1.6 thick with
/// round ends, 5 pt apart (drawn as rounded bars, no painter needed).
class ReorderHandle extends StatelessWidget {
  const ReorderHandle({super.key, required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    Widget bar() => Container(
      width: 18 + 1.6,
      height: 1.6,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(0.8)),
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [bar(), const SizedBox(height: 5 - 1.6), bar(), const SizedBox(height: 5 - 1.6), bar()],
      ),
    );
  }
}
