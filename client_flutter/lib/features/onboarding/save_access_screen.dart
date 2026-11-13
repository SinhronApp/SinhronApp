// Sign-up step 3 / 3 "Keep access to your account" — ADR-059.
//
// Was a wall: 24 words, two checkboxes and a 3-word test before the
// account existed — so people took a screenshot, passed the test and
// deleted it. Now three ways, none of them blocks:
//   - "Save to Passwords" (iOS) / "Save to password manager" (Android) —
//     the system save sheet, one tap; no word is shown or typed;
//   - "Write the words down" — the words screen, a 2-word check, or the
//     printable recovery sheet;
//   - "Later" — straight to the chats; the words wait on this phone only
//     (Keychain / Keystore) and Settings + a calm reminder ask again.
// The account is made at the end of this step, whichever way (as before).

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../../core/haptics.dart';
import '../../core/providers/core_providers.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_page_route.dart';
import '../settings/_shared.dart' show SettingsRowIcon, SettingsRowIconPainter;
import 'recovery_phrase_screen.dart';

/// Makes the account from the words: the identity row, the device key in
/// the Keychain, the connection, the sealed DB (ADR-021).
typedef AccountCreator = Future<void> Function(WidgetRef ref, String phrase);

Future<void> createAccountFromPhrase(WidgetRef ref, String phrase) async {
  // NEVER add the phrase to a log line, error message or analytics payload.
  try {
    final fp = await core.storageSavePhrase(phrase: phrase);
    // ignore: avoid_print
    print('[sinhron] identity persisted · fingerprint=$fp');
    ref.invalidate(identityProvider);
  } catch (e) {
    // ignore: avoid_print
    print('[sinhron] failed to persist identity: $e — continuing anyway');
  }
  await ref.read(sessionProvider).establish(phrase); // server chosen in step 1 (ADR-032)
}

class SaveAccessScreen extends ConsumerStatefulWidget {
  const SaveAccessScreen({super.key, this.onBack, this.onDone, this.words, this.createAccount = createAccountFromPhrase});

  final VoidCallback? onBack;

  /// The account exists — on to "Setting up".
  final VoidCallback? onDone;

  /// Fixed words (tests, the design gallery); otherwise new ones.
  final List<String>? words;
  final AccountCreator createAccount;

  @override
  ConsumerState<SaveAccessScreen> createState() => _SaveAccessScreenState();
}

enum _Busy { none, passwords, later, paper }

class _SaveAccessScreenState extends ConsumerState<SaveAccessScreen> {
  late List<String> _words = widget.words ?? newRecoveryWords();
  _Busy _busy = _Busy.none;
  bool _failed = false;
  bool _done = false;

  String get _phrase => _words.join(' ');

  @override
  void dispose() {
    _words = const []; // Risk #6 — no reference left once the screen goes
    super.dispose();
  }

  Future<void> _finish(AccessWay? way, _Busy busy) async {
    if (_done) return;
    setState(() => _busy = busy);
    final phrase = _phrase;
    final access = ref.read(accountAccessProvider.notifier);
    if (way == null) {
      // SEED-2 — "Later": the words go onto this phone BEFORE the account is
      // made, so a crash or an error while it is being made can't leave an
      // account whose words are nowhere. Not kept → no account: stay here.
      try {
        await access.keepForLater(phrase);
      } catch (e) {
        // ignore: avoid_print
        print('[sinhron] words not kept on this phone: $e');
        // Not silent: the red line says to try again or write the words down.
        if (mounted) {
          setState(() {
            _busy = _Busy.none;
            _failed = true;
          });
        }
        return;
      }
    }
    try {
      await widget.createAccount(ref, phrase);
      if (way != null) await access.markSaved(way);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] account set-up: $e');
    }
    _done = true;
    if (!mounted) return;
    setState(() => _busy = _Busy.none);
    widget.onDone?.call();
  }

  Future<void> _savePasswords() async {
    setState(() {
      _busy = _Busy.passwords;
      _failed = false;
    });
    var fp = '';
    try {
      fp = await ref.read(secretOpsProvider).fingerprintFor(_phrase);
    } catch (_) {}
    String name = '';
    try {
      name = await ref.read(profileNameProvider.future);
    } catch (_) {}
    final r = await ref.read(passwordVaultProvider).save(account: vaultAccountLabel(name, fp), secret: _phrase);
    if (!mounted) return;
    if (r == VaultResult.saved) {
      DsHaptics.play(Haptic.success);
      await _finish(vaultWay, _Busy.passwords);
      return;
    }
    setState(() {
      _busy = _Busy.none;
      _failed = r == VaultResult.failed;
    });
  }

  Future<void> _writeDown() async {
    final nav = Navigator.of(context);
    final way = await nav.push<AccessWay>(
      DsPageRoute<AccessWay>(
        builder: (ctx) => RecoveryPhraseScreen(
          words: _words,
          onBack: () => Navigator.of(ctx).pop(),
          onSaved: (w) => Navigator.of(ctx).pop(w),
        ),
      ),
    );
    if (way != null && mounted) await _finish(way, _Busy.paper);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final vault = ref.watch(passwordVaultProvider);
    final busy = _busy != _Busy.none;
    final android = Platform.isAndroid;
    return ColoredBox(
      key: const ValueKey('save-access'),
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(step: '3 / 3', onBack: busy ? null : widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x4, DsSpace.x6, DsSpace.x4),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(color: DsPalette.orange14, borderRadius: BorderRadius.circular(18)),
                      child: Center(
                        child: SizedBox(
                          width: 32,
                          height: 32,
                          child: CustomPaint(
                            painter: SettingsRowIconPainter(shape: SettingsRowIcon.key, color: DsPalette.orange),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: DsSpace.x5),
                  Text(l.saveAccessTitle, style: DsText.title1.copyWith(fontWeight: FontWeight.w600, color: tokens.text)),
                  const SizedBox(height: DsSpace.x2),
                  Text(l.saveAccessBody, style: DsText.callout.copyWith(color: tokens.text2)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2, DsSpace.x6, DsSpace.x4h5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (vault.available) ...[
                    DsButton(
                      key: const ValueKey('save-passwords'),
                      label: android ? l.saveToPasswordsAndroid : l.saveToPasswordsIos,
                      loading: _busy == _Busy.passwords,
                      onPressed: busy ? null : _savePasswords,
                    ),
                    const SizedBox(height: DsSpace.x2),
                    Text(
                      _failed ? l.passwordsFailed : (android ? l.savePasswordsHintAndroid : l.savePasswordsHintIos),
                      key: const ValueKey('save-passwords-hint'),
                      textAlign: TextAlign.center,
                      style: DsText.footnote.copyWith(color: _failed ? tokens.danger : tokens.text3),
                    ),
                    const SizedBox(height: DsSpace.x4),
                  ],
                  DsButton(
                    key: const ValueKey('save-write'),
                    label: l.writeWordsAction,
                    variant: vault.available ? DsButtonVariant.secondary : DsButtonVariant.primary,
                    loading: _busy == _Busy.paper,
                    onPressed: busy ? null : _writeDown,
                  ),
                  const SizedBox(height: DsSpace.x2),
                  DsButton(
                    key: const ValueKey('save-later'),
                    label: l.saveLater,
                    variant: DsButtonVariant.ghost,
                    loading: _busy == _Busy.later,
                    onPressed: busy ? null : () => _finish(null, _Busy.later),
                  ),
                  Text(
                    l.saveLaterHint,
                    textAlign: TextAlign.center,
                    style: DsText.footnote.copyWith(color: tokens.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
