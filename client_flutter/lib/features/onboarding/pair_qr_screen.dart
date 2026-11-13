// New device: "Link a device" by QR — tech-debt 4.2 / ADR-025.
//
// Makes this phone's own device key, shows a one-time pairing QR (Rust:
// id + HPKE public key + the device key) and waits for the user's other
// device to answer it (Settings → Linked devices → "Link a new device").
// The answer is a linked-device bundle sealed to the key in the QR — a
// certificate for this phone's key, no identity key (ADR-027); with it
// this phone signs in as one more device of the account. A fresh code is
// made when one expires. Before signing in it asks "Sign in to the account
// with address …?" — whoever saw the QR could have answered it with their
// own account (storage-devices:13); the address is on the other phone.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr/qr.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/contact_qr.dart' show keyFingerprint;
import '../../core/haptics.dart';
import '../../core/pairing.dart';
import '../../core/providers/core_providers.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../verify/verify_contact.dart' show QrMatrixPainter;

class PairQrScreen extends ConsumerStatefulWidget {
  const PairQrScreen({super.key, this.onBack, this.onDone, this.onUseWords, this.serverUrl});

  final VoidCallback? onBack;
  final VoidCallback? onDone;

  /// "Enter the 24 words instead".
  final VoidCallback? onUseWords;

  /// WS URL of the server to pair through (default: the one chosen before
  /// this screen, `server_url` — ADR-032).
  final String? serverUrl;

  @override
  ConsumerState<PairQrScreen> createState() => _PairQrScreenState();
}

class _PairQrScreenState extends ConsumerState<PairQrScreen> {
  /// One wait round; a code that wasn't answered by then is replaced.
  static const roundSecs = 120;

  String? _code;
  String? _note;

  /// This phone's own device key, the same across fresh codes.
  final String _seed = newDeviceSeedHex();
  bool _alive = true;
  late final PairingOps _ops;

  @override
  void initState() {
    super.initState();
    _ops = ref.read(pairingOpsProvider); // now, not lazily in dispose()
    unawaited(_run());
  }

  @override
  void dispose() {
    _alive = false;
    _ops.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final String stored = await ref.read(serverUrlProvider.future);
    if (!mounted) return;
    final url = widget.serverUrl ?? stored;
    if (url.isEmpty) {
      // ADR-032 — the server step comes first; without it there is nowhere to pair through.
      setState(() => _note = context.l10n.pairNoServer);
      return;
    }
    final base = httpBaseFromWs(url);
    while (_alive) {
      try {
        final code = await _ops.offer(_seed);
        if (!mounted) return;
        setState(() => _code = code);
        final secret = await _ops.wait(base, roundSecs);
        if (!_alive || !mounted) return;
        if (secret == null) continue; // expired — a new code
        if (!await _confirm(secret)) continue; // not my account — nothing kept, a new code
        await _signIn(secret, url);
        return;
      } catch (e) {
        // ignore: avoid_print
        print('[sinhron] pairing: $e');
        if (!mounted) return;
        // ADR-091 — another device took this code: a new one follows.
        setState(() => _note = isPairingUsedError(e) ? context.l10n.pairCodeUsed : context.l10n.pairFailed);
        await Future<void>.delayed(const Duration(seconds: 3));
      }
    }
  }

  /// storage-devices:13 — whose account answered: the start of the bundle's
  /// identity key (the certificate is checked against it in Rust), the
  /// address the other phone shows in its profile.
  Future<bool> _confirm(String secret) async {
    final l = context.l10n;
    final hex = secret.startsWith(kLinkedBundlePrefix) ? secret.substring(kLinkedBundlePrefix.length) : '';
    final ok = await showDsActionSheet<bool>(
      context,
      title: l.pairConfirm(keyFingerprint(hex.length >= 64 ? hex.substring(0, 64) : hex)),
      actions: [DsSheetAction(l.pairConfirmAction, true)],
    );
    return ok == true && _alive && mounted;
  }

  Future<void> _signIn(String secret, String url) async {
    try {
      await core.storageSavePhrase(phrase: secret);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] failed to persist identity: $e — continuing anyway');
    }
    // The certificate in the bundle is for exactly this key.
    await ref.read(deviceSeedStoreProvider).write(_seed);
    await ref.read(sessionProvider).establishLinked(secret, serverUrl: url);
    ref.invalidate(identityProvider);
    if (!mounted) return;
    DsHaptics.play(Haptic.success);
    widget.onDone?.call();
  }

  Future<void> _copy() async {
    final code = _code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) setState(() => _note = context.l10n.pairCopied);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final code = _code;
    return ColoredBox(
      key: const ValueKey('pair-qr-screen'),
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: '', onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x2, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  Text(
                    l.pairTitle,
                    textAlign: TextAlign.center,
                    style: DsText.title2.copyWith(color: tokens.text),
                  ),
                  const SizedBox(height: DsSpace.x2),
                  Text(
                    l.pairBody,
                    textAlign: TextAlign.center,
                    style: DsText.callout.copyWith(color: tokens.text2),
                  ),
                  const SizedBox(height: DsSpace.x5),
                  Center(
                    child: Container(
                      key: const ValueKey('pair-qr'),
                      padding: const EdgeInsets.all(DsSpace.x4),
                      decoration: BoxDecoration(
                        color: DsPalette.white,
                        borderRadius: BorderRadius.circular(tokens.radiusCard),
                      ),
                      child: SizedBox(
                        width: 220,
                        height: 220,
                        child: code == null
                            ? null
                            : CustomPaint(
                                painter: QrMatrixPainter(
                                  QrImage(QrCode.fromData(data: code, errorCorrectLevel: QrErrorCorrectLevel.M)),
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: DsSpace.x3),
                  Text(
                    _note ?? l.pairWaiting,
                    key: const ValueKey('pair-status'),
                    textAlign: TextAlign.center,
                    style: DsText.footnote.copyWith(color: tokens.text3),
                  ),
                  const SizedBox(height: DsSpace.x5),
                  DsButton(
                    key: const ValueKey('pair-copy'),
                    label: l.pairCopy,
                    variant: DsButtonVariant.secondary,
                    onPressed: code == null ? null : _copy,
                  ),
                  if (widget.onUseWords != null) ...[
                    const SizedBox(height: DsSpace.x2),
                    DsButton(label: l.pairUseWords, variant: DsButtonVariant.ghost, onPressed: widget.onUseWords),
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
