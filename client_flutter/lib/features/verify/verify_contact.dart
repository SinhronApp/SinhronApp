// Verify a contact — UI backlog §6 item 49.
//
// The safety number is computed from both identity keys (mine and the
// other member's, as authenticated by the MLS group), so both phones
// show the same 60 digits. The user compares them in person or over a
// call — or the other person scans this screen's QR — and marks the
// contact verified. "Verified" is pinned to THAT key: if their key ever
// changes, the mark drops and the chat says so.

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr/qr.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../core/qr_scan.dart';
import '../../core/providers/settings_providers.dart';
import '../contacts_list/contacts_list_screen.dart' show ContactEntry;
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../l10n/l10n.dart';

/// What is being verified: a 1:1 chat (`<chat>`) or one member of a
/// group (`<chat>|<member key>`, tech-debt 2.27). Everything below is keyed
/// by it, so a group member's mark is separate from the chat's.
String verifySubject(String chatId, String? peerKeyHex) => peerKeyHex == null ? chatId : '$chatId|$peerKeyHex';

/// Safety info for a subject (MLS FFI; faked in tests).
final safetyInfoLoaderProvider = Provider<Future<core.SafetyInfo> Function(String subject)>(
  (ref) => (subject) {
    final bar = subject.indexOf('|');
    return bar < 0
        ? core.syncSafetyNumber(groupIdHex: subject)
        : core.syncSafetyNumberWith(groupIdHex: subject.substring(0, bar), peerKeyHex: subject.substring(bar + 1));
  },
);

enum VerifyState { unverified, verified, changed }

/// The verified key stored for a chat (settings `verified:<chat>`).
class VerifiedKeys {
  VerifiedKeys(this._ref);
  final Ref _ref;

  Future<String?> get(String chatId) async {
    try {
      final v = await _ref.read(settingsStoreProvider).get('verified:$chatId');
      return v == null || v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  Future<void> set(String chatId, String? peerKeyHex) =>
      _ref.read(settingsStoreProvider).set('verified:$chatId', peerKeyHex ?? '');
}

final verifiedKeysProvider = Provider<VerifiedKeys>((ref) => VerifiedKeys(ref));

/// The contacts whose safety number I confirmed, by their key (lower-case
/// hex) — the Contacts tab's "Verified" section. Only while the stored key
/// is still theirs: a changed key drops them out (tech-debt 2.34). Keyed by
/// [verifiedPeersKey] (a list isn't a stable family key).
final verifiedPeersProvider = FutureProvider.autoDispose.family<Set<String>, String>((ref, key) async {
  final keys = ref.read(verifiedKeysProvider);
  final out = <String>{};
  for (final pair in key.split(',')) {
    final i = pair.indexOf(':');
    if (i <= 0) continue;
    final peer = pair.substring(i + 1).toLowerCase();
    final stored = await keys.get(pair.substring(0, i));
    if (stored != null && stored.toLowerCase() == peer) out.add(peer);
  }
  return out;
});

/// `chat:peer,chat:peer…` for [verifiedPeersProvider].
/// Contacts without a chat have nothing checked (the mark is per chat).
String verifiedPeersKey(List<ContactEntry> people) => [
  for (final c in people)
    if (c.chatId != null) '${c.chatId}:${c.peerId}',
].join(',');

/// Verification state of a chat: compares the stored key with the
/// current one. Invalidate after marking / unmarking. autoDispose: re-checked
/// each time a screen opens, so a changed key is not hidden until restart.
final verifyStateProvider = FutureProvider.autoDispose.family<VerifyState, String>((ref, chatId) async {
  final stored = await ref.read(verifiedKeysProvider).get(chatId);
  if (stored == null) return VerifyState.unverified;
  try {
    final info = await ref.read(safetyInfoLoaderProvider)(chatId);
    return info.peerKeyHex == stored ? VerifyState.verified : VerifyState.changed;
  } catch (_) {
    return VerifyState.unverified;
  }
});

/// What the QR carries: both keys, so a scanner can check the pair.
String verifyQrPayload(core.SafetyInfo i) => 'sinhron-verify:1:${i.myKeyHex}:${i.peerKeyHex}';

enum ScanMatch { match, mismatch, notSafetyCode }

/// Their screen shows `sinhron-verify:1:<their key>:<my key>` — the same
/// pair seen from the other side. Anything else is not a match.
ScanMatch checkScannedVerify(String scanned, core.SafetyInfo mine) {
  final p = scanned.trim().split(':');
  if (p.length != 4 || p[0] != 'sinhron-verify' || p[1] != '1') return ScanMatch.notSafetyCode;
  final theirs = p[2].toLowerCase();
  final mineSeenByThem = p[3].toLowerCase();
  return theirs == mine.peerKeyHex.toLowerCase() && mineSeenByThem == mine.myKeyHex.toLowerCase()
      ? ScanMatch.match
      : ScanMatch.mismatch;
}

class VerifyContactScreen extends ConsumerStatefulWidget {
  const VerifyContactScreen({
    super.key,
    required this.chatId,
    required this.contactName,
    this.onBack,
    this.peerKeyHex,
  });

  final String chatId;
  final String contactName;

  /// Group chats: the member to verify (null = the other person of a 1:1).
  final String? peerKeyHex;
  final VoidCallback? onBack;

  @override
  ConsumerState<VerifyContactScreen> createState() => _VerifyContactScreenState();
}

class _VerifyContactScreenState extends ConsumerState<VerifyContactScreen> {
  late final String _subject = verifySubject(widget.chatId, widget.peerKeyHex);
  late final Future<core.SafetyInfo> _info = ref.read(safetyInfoLoaderProvider)(_subject);
  bool _qr = false;

  /// Result of the last camera scan (null = none yet).
  ScanMatch? _scan;

  /// Tech-debt 2.27 — scan the QR on their screen with the camera.
  Future<void> _scanTheirs(core.SafetyInfo info) async {
    final text = await ref.read(qrScannerProvider)();
    if (!mounted || text == null) return; // closed / no camera
    final m = checkScannedVerify(text, info);
    setState(() => _scan = m);
    if (m == ScanMatch.match) {
      await _mark(info, true);
    } else {
      DsHaptics.play(Haptic.error);
    }
  }

  Future<void> _mark(core.SafetyInfo info, bool verified) async {
    await ref.read(verifiedKeysProvider).set(_subject, verified ? info.peerKeyHex : null);
    DsHaptics.play(verified ? Haptic.success : Haptic.selection);
    ref.invalidate(verifyStateProvider(_subject));
    ref.invalidate(verifiedPeersProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final state = ref.watch(verifyStateProvider(_subject)).value ?? VerifyState.unverified;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(title: context.l10n.verifyTitle(widget.contactName), onBack: widget.onBack),
            Expanded(
              child: FutureBuilder<core.SafetyInfo>(
                future: _info,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(DsSpace.x8),
                        child: Text(
                          context.l10n.verifyNotYet,
                          textAlign: TextAlign.center,
                          style: DsText.callout.copyWith(color: tokens.text3),
                        ),
                      ),
                    );
                  }
                  final info = snap.data;
                  if (info == null) return const SizedBox.shrink();
                  return ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, DsSpace.x6),
                    children: [
                      _StatusCard(state: state, name: widget.contactName),
                      const SizedBox(height: DsSpace.x5),
                      Center(
                        child: GestureDetector(
                          key: const ValueKey('verify-toggle-view'),
                          onTap: () => setState(() => _qr = !_qr),
                          child: Text(
                            _qr ? context.l10n.showNumber : context.l10n.showQr,
                            style: DsText.subhead.copyWith(color: tokens.accent),
                          ),
                        ),
                      ),
                      const SizedBox(height: DsSpace.x3),
                      AnimatedSwitcher(
                        duration: DsMotion.of(context, DsMotion.base),
                        child: _qr
                            ? _QrCard(key: const ValueKey('qr'), payload: verifyQrPayload(info))
                            : _NumberCard(key: const ValueKey('number'), number: info.number),
                      ),
                      const SizedBox(height: DsSpace.x5),
                      Text(
                        context.l10n.verifyExplain(widget.contactName),
                        textAlign: TextAlign.center,
                        style: DsText.callout.copyWith(color: tokens.text2),
                      ),
                      if (_scan != null) ...[
                        const SizedBox(height: DsSpace.x4),
                        Text(
                          switch (_scan!) {
                            ScanMatch.match => context.l10n.verifyScanMatch(widget.contactName),
                            ScanMatch.mismatch => context.l10n.verifyScanMismatch,
                            ScanMatch.notSafetyCode => context.l10n.verifyScanNotCode,
                          },
                          key: ValueKey('verify-scan-${_scan!.name}'),
                          textAlign: TextAlign.center,
                          style: DsText.callout.copyWith(
                            color: _scan == ScanMatch.match ? tokens.success : tokens.danger,
                          ),
                        ),
                      ],
                      const SizedBox(height: DsSpace.x6),
                      DsButton(
                        key: const ValueKey('verify-scan'),
                        label: context.l10n.verifyScan,
                        variant: DsButtonVariant.secondary,
                        onPressed: () => _scanTheirs(info),
                      ),
                      const SizedBox(height: DsSpace.x3),
                      if (state == VerifyState.verified)
                        DsButton(
                          key: const ValueKey('verify-clear'),
                          label: context.l10n.clearVerification,
                          variant: DsButtonVariant.secondary,
                          onPressed: () => _mark(info, false),
                        )
                      else
                        DsButton(
                          key: const ValueKey('verify-mark'),
                          label: context.l10n.markVerified,
                          onPressed: () => _mark(info, true),
                        ),
                    ],
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state, required this.name});
  final VerifyState state;
  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final (title, body, color) = switch (state) {
      VerifyState.verified => (context.l10n.verifiedTitle, context.l10n.verifiedBody(name), tokens.success),
      VerifyState.changed => (
        context.l10n.safetyChangedTitle,
          context.l10n.safetyChangedBody(name),
        tokens.danger,
      ),
      VerifyState.unverified => (
        context.l10n.notVerifiedTitle, context.l10n.notVerifiedBody,
        tokens.text3,
      ),
    };
    return Container(
      key: ValueKey('verify-status-${state.name}'),
      padding: const EdgeInsets.all(DsSpace.x4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(tokens.radiusCard),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(
              state == VerifyState.verified
                  ? CupertinoIcons.checkmark_alt
                  : (state == VerifyState.changed ? CupertinoIcons.exclamationmark : CupertinoIcons.question),
              size: 20,
              color: DsPalette.white,
            ),
          ),
          const SizedBox(width: DsSpace.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: DsText.headline.copyWith(color: tokens.text)),
                const SizedBox(height: 2),
                Text(body, style: DsText.subhead.copyWith(color: tokens.text2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NumberCard extends StatelessWidget {
  const _NumberCard({super.key, required this.number});
  final String number;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final groups = number.split(' ');
    return Container(
      key: const ValueKey('safety-number'),
      padding: const EdgeInsets.symmetric(vertical: DsSpace.x5, horizontal: DsSpace.x4),
      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(tokens.radiusCard)),
      child: Semantics(
        label: context.l10n.safetyNumberA11y(groups.join(', ')),
        excludeSemantics: true,
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: DsSpace.x4,
          runSpacing: DsSpace.x3,
          children: [
            for (final g in groups)
              Text(
                g,
                style: DsText.title3.copyWith(fontFamily: DsType.familyMono, color: tokens.text, letterSpacing: 1),
              ),
          ],
        ),
      ),
    );
  }
}

class _QrCard extends StatelessWidget {
  const _QrCard({super.key, required this.payload});
  final String payload;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final code = QrImage(QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M));
    return Center(
      child: Container(
        key: const ValueKey('safety-qr'),
        padding: const EdgeInsets.all(DsSpace.x4),
        decoration: BoxDecoration(color: DsPalette.white, borderRadius: BorderRadius.circular(tokens.radiusCard)),
        child: SizedBox(width: 220, height: 220, child: CustomPaint(painter: QrMatrixPainter(code))),
      ),
    );
  }
}

/// Paints a real QR matrix (black on white, always — scanners need it).
class QrMatrixPainter extends CustomPainter {
  QrMatrixPainter(this.code);
  final QrImage code;

  @override
  void paint(Canvas canvas, Size size) {
    final n = code.moduleCount;
    final cell = size.width / n;
    final p = Paint()..color = DsPalette.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (code.isDark(y, x)) canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.3, cell + 0.3), p);
      }
    }
  }

  @override
  bool shouldRepaint(QrMatrixPainter old) => old.code != code;
}
