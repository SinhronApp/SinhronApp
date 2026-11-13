// Settings → Chat backup → "Turn on backup here" (ADR-073): a device linked
// before backups existed has no backup key in its device key. The 24 words,
// typed (or picked from Passwords) once, add it — the same device, the same
// database; the words themselves are not kept. Pops true when it is on.

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../app_lock/app_lock.dart';
import '../../core/backup/backup_service.dart';
import '../../core/haptics.dart';
import '../../core/session.dart' show secretOpsProvider;
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../../app/adaptive.dart';

Future<bool?> showBackupWordsSheet(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<bool>(
    dsSheetRoute<bool>(context, (_) => const BackupWordsSheet()),
  );
}

class BackupWordsSheet extends ConsumerStatefulWidget {
  const BackupWordsSheet({super.key});

  @override
  ConsumerState<BackupWordsSheet> createState() => _BackupWordsSheetState();
}

class _BackupWordsSheetState extends ConsumerState<BackupWordsSheet> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _fromPasswords() async {
    final l = context.l10n;
    final words = await pickSavedWords(ref, Platform.isAndroid ? l.pasteFromPasswordsAndroid : l.pasteFromPasswordsIos);
    if (words == null || !mounted) return;
    setState(() {
      _ctrl.text = words.trim();
      _error = null;
    });
  }

  Future<void> _turnOn() async {
    final l = context.l10n;
    final clean = _ctrl.text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!ref.read(secretOpsProvider).isValidPhrase(clean)) {
      DsHaptics.play(Haptic.error);
      setState(() => _error = l.unlockInvalidPhrase);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await ref.read(chatBackupProvider.notifier).unlock(clean);
    if (!mounted) return;
    if (err != null) {
      DsHaptics.play(Haptic.error);
      setState(() {
        _busy = false;
        _error = err == 'other_words' ? l.backupUnlockOtherWords : l.backupFailed;
      });
      return;
    }
    _ctrl.clear();
    DsHaptics.play(Haptic.success);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return DsSheetPlacement(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return AnimatedPadding(
          duration: DsMotion.base,
          curve: DsMotion.enter,
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: GestureDetector(
            onTap: () {}, // absorbs taps: keeps the sheet open
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: Container(
                width: double.infinity,
                color: tokens.surface,
                padding: EdgeInsets.fromLTRB(
                  DsSpace.x5,
                  DsSpace.x2,
                  DsSpace.x5,
                  (mq.viewInsets.bottom > 0 ? 0 : mq.padding.bottom) + DsSpace.x4,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const DsSheetGrabber(),
                    const SizedBox(height: DsSpace.x5),
                    Text(
                      l.backupUnlockTitle,
                      textAlign: TextAlign.center,
                      style: DsText.title3.copyWith(fontWeight: FontWeight.w700, color: tokens.text),
                    ),
                    const SizedBox(height: DsSpace.x1h5),
                    Text(
                      l.backupUnlockBody,
                      textAlign: TextAlign.center,
                      style: DsText.footnote.copyWith(color: tokens.text3),
                    ),
                    const SizedBox(height: DsSpace.x5),
                    DsTextField(
                      key: const ValueKey('backup-words-field'),
                      controller: _ctrl,
                      hintText: l.unlockHint,
                      maxLines: 4,
                      keyboardType: TextInputType.visiblePassword,
                      enabled: !_busy,
                    ),
                    if (ref.watch(passwordVaultProvider).available) ...[
                      const SizedBox(height: DsSpace.x2),
                      DsButton(
                        key: const ValueKey('backup-words-passwords'),
                        label: Platform.isAndroid ? l.pasteFromPasswordsAndroid : l.pasteFromPasswordsIos,
                        variant: DsButtonVariant.ghost,
                        size: DsButtonSize.small,
                        fullWidth: false,
                        onPressed: _busy ? null : _fromPasswords,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: DsSpace.x2),
                      Text(
                        _error!,
                        key: const ValueKey('backup-words-error'),
                        textAlign: TextAlign.center,
                        style: DsText.subhead.copyWith(color: tokens.danger),
                      ),
                    ],
                    const SizedBox(height: DsSpace.x4),
                    DsButton(
                      key: const ValueKey('backup-words-go'),
                      label: l.backupUnlockGo,
                      loading: _busy,
                      onPressed: _busy ? null : _turnOn,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
