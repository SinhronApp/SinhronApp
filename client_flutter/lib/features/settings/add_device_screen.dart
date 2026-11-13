// Existing device: "Link a new device" — tech-debt 4.2 / ADR-025.
//
// Scan the QR the new device shows (native camera) or paste its code,
// confirm, and this phone signs a certificate for the new device's key and
// seals a linked-device bundle (no identity key, ADR-027) to the QR's
// one-time key, left on the server for it. Device sync then adds it to
// the chats. Only a device holding the account key can do this. Face ID /
// the passcode first, App Lock on or not (audit storage-devices:3).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/contact_qr.dart' show keyFingerprint;
import '../../core/haptics.dart';
import '../../core/pairing.dart';
import '../../core/services/net_service.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../app_lock/app_lock.dart';
import 'phrase_prompt.dart';

class AddDeviceScreen extends ConsumerStatefulWidget {
  const AddDeviceScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  ConsumerState<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends ConsumerState<AddDeviceScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final text = await ref.read(pairingOpsProvider).scanQr();
    if (text == null || !mounted) return;
    _code.text = text;
    await _add();
  }

  Future<void> _add() async {
    final l = context.l10n;
    final ops = ref.read(pairingOpsProvider);
    final code = _code.text.trim();
    if (!await ops.isCode(code)) {
      if (!mounted) return;
      DsHaptics.play(Haptic.error);
      setState(() => _error = l.addDeviceNotACode);
      return;
    }
    if (!mounted) return;
    final ok = await showDsActionSheet<bool>(
      context,
      // storage-devices:13 — the new device asks to compare this address.
      title: l.addDeviceConfirm(keyFingerprint(ref.read(netServiceProvider).myIdentityHex ?? '')),
      actions: [DsSheetAction(l.addDeviceConfirmAction, true)],
    );
    if (ok != true || !mounted) return;
    if (!await confirmOwner(ref, l.devicesLinkNew) || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final net = ref.read(netServiceProvider);
      final base = net.httpBaseUrl;
      if (base == null) throw StateError('offline');
      try {
        await ops.send(base, code);
      } catch (e) {
        // ADR-027 — no account key here: the 24 words authorize it.
        if (!isNoAccountKeyError(e) || !mounted) rethrow;
        final phrase = await promptPhrase(context);
        if (phrase == null) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        await ops.sendWithPhrase(base, code, phrase);
      }
      // The new device registers and publishes KeyPackages first — then
      // device sync brings it into our chats (it also runs every 5 min).
      unawaited(Future<void>.delayed(const Duration(seconds: 20), () => net.syncDevices()));
      if (!mounted) return;
      DsHaptics.play(Haptic.success);
      setState(() {
        _busy = false;
        _done = true;
      });
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] pairing send failed: $e');
      if (!mounted) return;
      DsHaptics.play(Haptic.error);
      setState(() {
        _busy = false;
        // ADR-091 — someone else answered this code first: say so.
        _error = isPairingUsedError(e) ? l.addDeviceCodeUsed : l.addDeviceFailed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    return ColoredBox(
      key: const ValueKey('add-device-screen'),
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: l.devicesLinkNew, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  Text(l.addDeviceBody, style: DsText.callout.copyWith(color: tokens.text2)),
                  const SizedBox(height: DsSpace.x5),
                  if (_done)
                    Text(
                      l.addDeviceDone,
                      key: const ValueKey('add-device-done'),
                      style: DsText.body.copyWith(color: tokens.text),
                    )
                  else ...[
                    DsButton(
                      key: const ValueKey('add-device-scan'),
                      label: l.addDeviceScan,
                      onPressed: _busy ? null : _scan,
                    ),
                    const SizedBox(height: DsSpace.x5),
                    DsTextField(
                      key: const ValueKey('add-device-code'),
                      controller: _code,
                      hintText: l.addDevicePasteHint,
                      maxLines: 3,
                      keyboardType: TextInputType.visiblePassword,
                      enabled: !_busy,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: DsSpace.x2),
                      Text(
                        _error!,
                        key: const ValueKey('add-device-error'),
                        style: DsText.subhead.copyWith(color: tokens.danger),
                      ),
                    ],
                    const SizedBox(height: DsSpace.x3),
                    DsButton(
                      key: const ValueKey('add-device-add'),
                      label: l.addDeviceAction,
                      variant: DsButtonVariant.secondary,
                      loading: _busy,
                      onPressed: _busy ? null : _add,
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
