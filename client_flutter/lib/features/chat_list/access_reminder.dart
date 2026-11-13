// "Keep access to your account" card at the top of the chat list —
// ADR-059. Shown only while the secret words wait on this phone unsaved
// ("Later" at sign-up), a day after sign-up and then at most once a week
// ("Later" on the card). "Save" opens Settings → Secret words.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_button.dart';
import '../settings/_shared.dart' show SettingsRowIcon, SettingsRowIconPainter;

class AccessReminderCard extends ConsumerWidget {
  const AccessReminderCard({super.key, this.onSave});

  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(accessReminderDueProvider)) return const SizedBox.shrink();
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return Padding(
      key: const ValueKey('access-reminder'),
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2, DsSpace.x3h5, DsSpace.x2),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3h5, DsSpace.x4, DsSpace.x3),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: tokens.dividerStrong, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(color: DsPalette.orange14, borderRadius: BorderRadius.circular(10)),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CustomPaint(
                        painter: SettingsRowIconPainter(shape: SettingsRowIcon.key, color: DsPalette.orange),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: DsSpace.x3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.saveAccessTitle,
                        style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                      ),
                      const SizedBox(height: 2),
                      Text(l.reminderBody, style: DsText.footnote.copyWith(color: tokens.text2)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: DsSpace.x3),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DsButton(
                  key: const ValueKey('access-reminder-later'),
                  label: l.saveLater,
                  variant: DsButtonVariant.ghost,
                  size: DsButtonSize.small,
                  fullWidth: false,
                  onPressed: () => ref.read(accountAccessProvider.notifier).remindLater(),
                ),
                const SizedBox(width: DsSpace.x2),
                DsButton(
                  key: const ValueKey('access-reminder-save'),
                  label: l.reminderSave,
                  size: DsButtonSize.small,
                  fullWidth: false,
                  onPressed: onSave,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
