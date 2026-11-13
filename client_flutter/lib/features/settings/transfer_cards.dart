// ADR-064 — progress of device transfers: a card per transfer on the
// Devices screen, and a thin strip on the chat list of a new device while
// its chats are arriving. Nothing at all when there is no transfer.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/providers/device_transfer.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/transfer.dart' as core;
import '../../widgets/ds_spinner.dart';

/// Every known transfer (both ways), newest work first.
class TransferCards extends ConsumerWidget {
  const TransferCards({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(deviceTransfersProvider);
    if (all.isEmpty) return const SizedBox.shrink();
    final waiting = ref.read(deviceTransfersProvider.notifier).waiting;
    return Column(
      children: [
        for (final s in all)
          _TransferCard(
            key: ValueKey('transfer-${s.outgoing}-${s.deviceHex}'),
            status: s,
            waiting: waiting,
            onDismiss: () => ref.read(deviceTransfersProvider.notifier).dismiss(s),
          ),
      ],
    );
  }
}

class _TransferCard extends StatelessWidget {
  final core.TransferStatus status;
  final bool waiting;
  final VoidCallback onDismiss;
  const _TransferCard({super.key, required this.status, required this.waiting, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final s = status;
    final finished = s.stage == 'done' || s.stage == 'failed';
    final title = s.outgoing ? l.transferOutTitle : l.transferInTitle;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, 0, DsSpace.x3h5, DsSpace.x3),
      child: Container(
        padding: const EdgeInsets.all(DsSpace.x3h5),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tokens.dividerStrong, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!finished && !waiting) ...[DsSpinner(color: tokens.accent, size: 16), const SizedBox(width: 8)],
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                ),
                GestureDetector(
                  key: ValueKey('transfer-dismiss-${s.outgoing}-${s.deviceHex}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.only(left: DsSpace.x2),
                    child: Text(
                      finished || !s.outgoing ? l.transferHide : l.transferStop,
                      style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TransferBar(fraction: transferFraction(s), failed: s.stage == 'failed'),
            const SizedBox(height: 8),
            Text(
              transferLine(l, s, waiting: waiting),
              style: DsText.footnote.copyWith(color: s.stage == 'failed' ? tokens.danger : tokens.text3),
            ),
          ],
        ),
      ),
    );
  }
}

/// A thin progress bar; [fraction] null = still working out how much.
class TransferBar extends StatelessWidget {
  final double? fraction;
  final bool failed;
  const TransferBar({super.key, required this.fraction, this.failed = false});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 4,
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: tokens.bgSoft)),
            FractionallySizedBox(
              widthFactor: fraction ?? 0.08,
              heightFactor: 1,
              child: ColoredBox(color: failed ? tokens.danger : tokens.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chat list's strip on a new device while its chats are arriving.
class IncomingTransferStrip extends ConsumerWidget {
  const IncomingTransferStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(deviceTransfersProvider).where(isIncomingInProgress).firstOrNull;
    if (s == null) return const SizedBox.shrink();
    final tokens = DsTheme.of(context);
    final percent = ((transferFraction(s) ?? 0) * 100).round();
    return Padding(
      key: const ValueKey('incoming-transfer-strip'),
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, DsSpace.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.transferStrip(percent), style: DsText.footnote.copyWith(color: tokens.text2)),
          const SizedBox(height: 6),
          TransferBar(fraction: transferFraction(s)),
        ],
      ),
    );
  }
}
