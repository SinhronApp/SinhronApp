// "I already have an account" — ADR-025.
//
// The 24 words of an account that lives on another device. This phone
// becomes one more device of that person (its own MLS key + a
// certificate from the identity key), never a copy of the first one.
// Its chats arrive when another device of theirs is online (device
// sync); earlier messages stay where they were. Reached from Welcome →
// "Restore with your key" and "Link a device" (QR pairing isn't built).
//
// ADR-059 — the words needn't be typed: "Paste from Passwords" (the
// phone's password manager, where sign-up saved them) or "Scan the
// recovery sheet" (its QR is the words).

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../app_lock/app_lock.dart';
import '../../core/haptics.dart';
import '../../core/providers/core_providers.dart';
import '../../core/qr_scan.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../../core/services/net_service.dart';
import 'old_devices_sheet.dart';

class RestoreScreen extends ConsumerStatefulWidget {
  const RestoreScreen({super.key, this.onBack, this.onDone, this.onUseQr});

  final VoidCallback? onBack;

  /// "Link with a QR code instead" (tech-debt 4.2).
  final VoidCallback? onUseQr;

  /// Signed in — the caller leaves onboarding.
  final VoidCallback? onDone;

  @override
  ConsumerState<RestoreScreen> createState() => _RestoreScreenState();
}

class _RestoreScreenState extends ConsumerState<RestoreScreen> {
  final _phrase = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phrase.clear();
    _phrase.dispose();
    super.dispose();
  }

  void _fill(String? words) {
    if (words == null || !mounted) return;
    setState(() {
      _phrase.text = words.trim();
      _error = null;
    });
  }

  Future<void> _fromPasswords() async {
    final l = context.l10n;
    _fill(await pickSavedWords(ref, Platform.isAndroid ? l.pasteFromPasswordsAndroid : l.pasteFromPasswordsIos));
  }

  Future<void> _scanSheet() async {
    final text = await ref.read(qrScannerProvider)();
    if (text == null || !mounted) return;
    final clean = text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!ref.read(secretOpsProvider).isValidPhrase(clean)) {
      DsHaptics.play(Haptic.error);
      setState(() => _error = context.l10n.sheetNotWords);
      return;
    }
    _fill(clean);
  }

  Future<void> _continue() async {
    final l = context.l10n;
    final clean = _phrase.text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (!ref.read(secretOpsProvider).isValidPhrase(clean)) {
      DsHaptics.play(Haptic.error);
      setState(() => _error = l.unlockInvalidPhrase);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Same as onboarding: the identity row (fingerprint) for this phone.
      try {
        await core.storageSavePhrase(phrase: clean);
      } catch (e) {
        // ignore: avoid_print
        print('[sinhron] failed to persist identity: $e — continuing anyway');
      }
      await ref.read(sessionProvider).establishLinked(clean); // server chosen before this screen (ADR-032)
      ref.invalidate(identityProvider);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] sign-in failed: $e');
      if (!mounted) return;
      DsHaptics.play(Haptic.error);
      // The words stay in the box for another try, and the message says
      // what happened (it wiped all 24 and spoke of "devices" — 2026-10-16
      // UI audit).
      setState(() {
        _busy = false;
        _error = l.restoreFailed;
      });
      return;
    }
    if (!mounted) return;
    DsHaptics.play(Haptic.success);
    // ADR-075 — the lost phone: cut it off now, while the words are here
    // (this device keeps no account key afterwards).
    await _offerOldDevices(clean);
    _phrase.clear();
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onDone?.call();
  }

  Future<void> _offerOldDevices(String words) async {
    final net = ref.read(netServiceProvider);
    List<core.LinkedDevice> listed;
    try {
      listed = await net.listDevices().timeout(const Duration(seconds: 8));
    } catch (_) {
      return; // offline: Settings → Devices does it later (with the words)
    }
    final others = [
      for (final d in listed)
        if (!d.isThisDevice) OldDevice(pkHex: d.devicePkHex, primary: d.isPrimary, lastSeenUnix: d.lastSeenUnix.toInt()),
    ];
    if (others.isEmpty || !mounted) return;
    await showOldDevicesSheet(
      context,
      devices: others,
      disconnect: (pk) async {
        try {
          await net.revokeDevice(pk, phrase: words);
          return true;
        } catch (e) {
          // ignore: avoid_print
          print('[sinhron][devices] disconnect at sign-in failed: $e');
          return false;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    return ColoredBox(
      key: const ValueKey('restore-screen'),
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: '', onBack: _busy ? null : widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  Text(
                    l.restoreTitle,
                    textAlign: TextAlign.center,
                    style: DsText.title2.copyWith(color: tokens.text),
                  ),
                  const SizedBox(height: DsSpace.x2),
                  Text(
                    l.restoreBody,
                    textAlign: TextAlign.center,
                    style: DsText.callout.copyWith(color: tokens.text2),
                  ),
                  const SizedBox(height: DsSpace.x6),
                  DsTextField(
                    key: const ValueKey('restore-phrase'),
                    controller: _phrase,
                    hintText: l.unlockHint,
                    maxLines: 4,
                    keyboardType: TextInputType.visiblePassword,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: DsSpace.x2),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: DsSpace.x2,
                    children: [
                      if (ref.watch(passwordVaultProvider).available)
                        DsButton(
                          key: const ValueKey('restore-passwords'),
                          label: Platform.isAndroid ? l.pasteFromPasswordsAndroid : l.pasteFromPasswordsIos,
                          variant: DsButtonVariant.ghost,
                          size: DsButtonSize.small,
                          fullWidth: false,
                          onPressed: _busy ? null : _fromPasswords,
                        ),
                      DsButton(
                        key: const ValueKey('restore-scan-sheet'),
                        label: l.sheetScan,
                        variant: DsButtonVariant.ghost,
                        size: DsButtonSize.small,
                        fullWidth: false,
                        onPressed: _busy ? null : _scanSheet,
                      ),
                    ],
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: DsSpace.x2),
                    Text(
                      _error!,
                      key: const ValueKey('restore-error'),
                      style: DsText.subhead.copyWith(color: tokens.danger),
                    ),
                  ],
                  const SizedBox(height: DsSpace.x5),
                  DsButton(
                    key: const ValueKey('restore-button'),
                    label: l.restoreAction,
                    loading: _busy,
                    onPressed: _busy ? null : _continue,
                  ),
                  const SizedBox(height: DsSpace.x3),
                  Text(
                    Platform.isAndroid ? l.unlockPhraseNoteAndroid : l.unlockPhraseNote,
                    textAlign: TextAlign.center,
                    style: DsText.footnote.copyWith(color: tokens.text3),
                  ),
                  if (widget.onUseQr != null) ...[
                    const SizedBox(height: DsSpace.x4),
                    DsButton(
                      label: l.restoreUseQr,
                      variant: DsButtonVariant.ghost,
                      onPressed: _busy ? null : widget.onUseQr,
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
