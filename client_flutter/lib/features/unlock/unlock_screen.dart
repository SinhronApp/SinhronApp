// Unlock with the recovery phrase — ADR-021 (tech-debt 2.16 / 2.4).
//
// Shown when this phone has no device key in its Keychain:
//   • locked — the chats DB is encrypted; the phrase opens it;
//   • reconnect — the DB is readable (it was never sealed) but the app
//     can't reach the server without the key.
// The phrase is checked against what's on the phone before anything is
// stored. "Erase and start over" is the only way data gets deleted,
// and it asks first.

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../../widgets/sinhron_mark.dart';

class UnlockScreen extends ConsumerStatefulWidget {
  const UnlockScreen({super.key, required this.locked});

  /// true: the DB is encrypted; false: only the connection needs the key.
  final bool locked;

  @override
  ConsumerState<UnlockScreen> createState() => _UnlockScreenState();
}

class _UnlockScreenState extends ConsumerState<UnlockScreen> {
  final _phrase = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phrase.clear();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final l = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    UnlockResult r;
    try {
      r = await ref.read(sessionProvider).unlock(_phrase.text);
    } catch (e) {
      // Not the words (those come back as a result): something on the
      // phone failed. Calling it "wrong words" sent people to "Erase".
      // ignore: avoid_print
      print('[sinhron] unlock failed: $e');
      if (!mounted) return;
      DsHaptics.play(Haptic.error);
      setState(() {
        _busy = false;
        _error = l.unlockFailed;
      });
      return;
    }
    if (!mounted) return;
    if (r == UnlockResult.ok) {
      DsHaptics.play(Haptic.success);
      _phrase.clear();
      setState(() => _busy = false);
      return; // AppRoot moves on by itself
    }
    DsHaptics.play(Haptic.error);
    setState(() {
      _busy = false;
      _error = r == UnlockResult.invalidPhrase ? l.unlockInvalidPhrase : l.unlockWrongPhrase;
    });
  }

  Future<void> _erase() async {
    final l = context.l10n;
    final picked = await showDsActionSheet<bool>(
      context,
      title: l.eraseConfirmTitle,
      actions: [DsSheetAction(l.eraseConfirmAction, true, destructive: true)],
    );
    if (picked != true) return;
    await ref.read(sessionProvider).eraseAndStartOver();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    return ColoredBox(
      key: const ValueKey('unlock-screen'),
      color: tokens.bg,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(DsSpace.gutter, pad.top + DsSpace.x8, DsSpace.gutter, pad.bottom + DsSpace.x6),
        children: [
          const Center(child: SinhronMark(size: 64)),
          const SizedBox(height: DsSpace.x5),
          Text(
            widget.locked ? l.unlockTitle : l.reconnectTitle,
            textAlign: TextAlign.center,
            style: DsText.title2.copyWith(color: tokens.text),
          ),
          const SizedBox(height: DsSpace.x2),
          Text(
            widget.locked ? l.unlockBody : l.reconnectBody,
            textAlign: TextAlign.center,
            style: DsText.callout.copyWith(color: tokens.text2),
          ),
          const SizedBox(height: DsSpace.x6),
          DsTextField(
            key: const ValueKey('unlock-phrase'),
            controller: _phrase,
            hintText: l.unlockHint,
            maxLines: 4,
            keyboardType: TextInputType.visiblePassword,
            enabled: !_busy,
          ),
          if (_error != null) ...[
            const SizedBox(height: DsSpace.x2),
            Text(
              _error!,
              key: const ValueKey('unlock-error'),
              style: DsText.subhead.copyWith(color: tokens.danger),
            ),
          ],
          const SizedBox(height: DsSpace.x5),
          DsButton(
            key: const ValueKey('unlock-button'),
            label: l.unlockAction,
            loading: _busy,
            onPressed: _busy ? null : _unlock,
          ),
          const SizedBox(height: DsSpace.x3),
          Text(
            Platform.isAndroid ? l.unlockPhraseNoteAndroid : l.unlockPhraseNote,
            textAlign: TextAlign.center,
            style: DsText.footnote.copyWith(color: tokens.text3),
          ),
          const SizedBox(height: DsSpace.x8),
          DsButton(
            key: const ValueKey('unlock-erase'),
            label: l.eraseAndStartOver,
            variant: DsButtonVariant.ghost,
            onPressed: _busy ? null : _erase,
          ),
        ],
      ),
    );
  }
}
