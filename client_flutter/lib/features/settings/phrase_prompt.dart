// "Confirm with your 24 words" — ADR-027.
//
// Devices other than the first don't keep the account (identity) key, so
// adding or revoking a device there asks for the 24 words. They're used
// for that one step (Rust derives the key, signs, drops it) and are
// never stored. Also Settings → Secret words → "Check the words"
// (ADR-059, own title and text). "Paste from Passwords" fills the box from
// the phone's password manager when the words were saved there.

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../app_lock/app_lock.dart';
import '../../core/haptics.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_page_route.dart';
import '../../widgets/ds_text_field.dart';

/// The 24 words (normalized), or null if the user backed out.
Future<String?> promptPhrase(BuildContext context, {String? title, String? body, String? action}) =>
    Navigator.of(context).push<String>(
      DsPageRoute<String>(builder: (_) => PhrasePromptScreen(title: title, body: body, action: action)),
    );

class PhrasePromptScreen extends ConsumerStatefulWidget {
  const PhrasePromptScreen({super.key, this.title, this.body, this.action});

  /// Defaults: the device-step wording (ADR-027).
  final String? title;
  final String? body;
  final String? action;

  @override
  ConsumerState<PhrasePromptScreen> createState() => _PhrasePromptScreenState();
}

class _PhrasePromptScreenState extends ConsumerState<PhrasePromptScreen> {
  final _phrase = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _phrase.clear();
    _phrase.dispose();
    super.dispose();
  }

  void _confirm() {
    final clean = _phrase.text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!ref.read(secretOpsProvider).isValidPhrase(clean)) {
      DsHaptics.play(Haptic.error);
      setState(() => _error = context.l10n.unlockInvalidPhrase);
      return;
    }
    _phrase.clear();
    Navigator.of(context).pop(clean);
  }

  Future<void> _fromPasswords() async {
    final l = context.l10n;
    final words = await pickSavedWords(ref, Platform.isAndroid ? l.pasteFromPasswordsAndroid : l.pasteFromPasswordsIos);
    if (words == null || !mounted) return;
    setState(() {
      _phrase.text = words;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    return ColoredBox(
      key: const ValueKey('phrase-prompt'),
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: widget.title ?? l.phrasePromptTitle, onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  Text(widget.body ?? l.phrasePromptBody, style: DsText.callout.copyWith(color: tokens.text2)),
                  const SizedBox(height: DsSpace.x5),
                  DsTextField(
                    key: const ValueKey('phrase-prompt-field'),
                    controller: _phrase,
                    hintText: l.unlockHint,
                    maxLines: 4,
                    keyboardType: TextInputType.visiblePassword,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: DsSpace.x2),
                    Text(_error!, style: DsText.subhead.copyWith(color: tokens.danger)),
                  ],
                  const SizedBox(height: DsSpace.x5),
                  DsButton(
                    key: const ValueKey('phrase-prompt-confirm'),
                    label: widget.action ?? l.phrasePromptAction,
                    onPressed: _confirm,
                  ),
                  if (ref.watch(passwordVaultProvider).available) ...[
                    const SizedBox(height: DsSpace.x3),
                    DsButton(
                      key: const ValueKey('phrase-prompt-passwords'),
                      label: Platform.isAndroid ? l.pasteFromPasswordsAndroid : l.pasteFromPasswordsIos,
                      variant: DsButtonVariant.ghost,
                      onPressed: _fromPasswords,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
