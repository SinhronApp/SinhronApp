// "Write the words down" — ADR-059. One of the ways to keep access to
// the account (sign-up step 3 "Keep access", or Settings → Secret words
// while the words still wait on this phone). No longer a wall: no
// checkboxes, a 2-word check, and a printable recovery sheet.
//
// Per spec §6.8 / §6.8.1 — these 24 words derive both the identity key AND
// the state-backup key. Losing them after losing all devices = losing the
// account, by design (sealed sender, server-not-trusted).
//
// UX guard rails:
//   - Grid starts BLURRED. User must tap to reveal — slows shoulder-surfing.
//   - Once revealed, stays revealed (no "tap to hide" — confusing UX).
//   - "Copy" appears after reveal — for people with their own password
//     manager (1Password / Bitwarden); the clipboard clears after 60 s.
//     Audit storage-devices:8: copied as a secret (`copySecret`) — iPhone:
//     this phone only, no Universal Clipboard; Android: hidden from the
//     clipboard preview and keyboard history.
//   - ADR-059 left screenshots alone; audit storage-devices:8 (owner
//     2026-11-04, «исправь всё»): on THIS screen Android blocks screenshots,
//     recording, screen share and the Recents picture (FLAG_SECURE), and
//     iPhone hides the words while the screen is recorded or mirrored
//     (a screenshot can't be blocked there — the line below stays).

import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/motion.dart';
import '../../core/account_access.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/screen_privacy.dart';
import '../../core/services/screenshot_watch.dart' show screenCaptured;
import '../../core/server_address.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_mnemonic_grid.dart';
import 'phrase_check.dart';
import 'recovery_sheet.dart';

/// Fallback if Rust Core hasn't booted yet (e.g. widget-tests that mount
/// the screen without `RustLib.init()`). The BIP-39 test vector "abandon
/// abandon … art" — a known-valid 24-word phrase.
const List<String> _fallbackPhrase = [
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'abandon',
  'art',
];

/// A new account's words: a real BIP-39 phrase via Rust Core, or the
/// fallback test vector if Rust hasn't booted (off-main code paths,
/// goldens, etc.).
List<String> newRecoveryWords() {
  try {
    return core.generateRecoveryPhrase().split(' ');
  } catch (_) {
    return _fallbackPhrase;
  }
}

class RecoveryPhraseScreen extends ConsumerStatefulWidget {
  final VoidCallback? onBack;

  /// Written down (2-word check passed) → [AccessWay.paper]; recovery
  /// sheet shared → [AccessWay.sheet].
  final ValueChanged<AccessWay>? onSaved;
  final List<String>? words;

  const RecoveryPhraseScreen({super.key, this.onBack, this.onSaved, this.words});

  @override
  ConsumerState<RecoveryPhraseScreen> createState() => _RecoveryPhraseScreenState();
}

class _RecoveryPhraseScreenState extends ConsumerState<RecoveryPhraseScreen> {
  bool _revealed = false;
  bool _justCopied = false;
  bool _sheetBusy = false;
  Timer? _copiedTimer;

  /// CRIT-1.3 — auto-clear clipboard timer. iOS clipboard is shared
  /// across devices via Handoff; sitting there indefinitely with 24
  /// words = exfiltration vector. Timer fires 60s after Copy and wipes
  /// the clipboard **iff it still contains our phrase** (don't clobber
  /// whatever the user copied since).
  Timer? _clipboardWipeTimer;

  /// How long the phrase is permitted to sit in clipboard before
  /// auto-wipe. Compromise between "long enough to paste into password
  /// manager" and "short enough to limit Handoff exposure window".
  static const Duration _clipboardWipeAfter = Duration(seconds: 60);

  /// Snapshot of what we placed on the clipboard. Used by the wipe
  /// timer to verify ownership before clearing — if the user has
  /// copied something else in the interim, we must not wipe it.
  String? _clipboardPhraseSnapshot;

  /// Risk #6 — phrase memory hygiene: dropped on dispose. `late` (not
  /// `late final`) so [_zeroizePhrase] can re-assign.
  late List<String> _phrase = widget.words ?? newRecoveryWords();

  /// Risk #6 — drop all references to the phrase when the screen goes.
  void _zeroizePhrase() => _phrase = const [];

  @override
  void initState() {
    super.initState();
    secureWordsScreen(true);
  }

  @override
  void dispose() {
    secureWordsScreen(false);
    _zeroizePhrase();
    _copiedTimer?.cancel();
    _clipboardWipeTimer?.cancel();
    // CRIT-1.3 — best-effort wipe on screen disposal. If user backs
    // out before the 60s timer fires, clear the clipboard now so the
    // phrase doesn't linger in pasteboard after the screen is gone.
    // Fire-and-forget; we can't await in dispose().
    _wipeClipboardIfStillOurs();
    super.dispose();
  }

  void _onCopy(List<String> words) {
    // C-63 — while the screen is recorded or shown in a call the words stay
    // put: no copy, no share sheet (the other side would see them).
    if (screenCaptured.value) return;
    final phrase = words.join(' ');
    copySecret(phrase, seconds: _clipboardWipeAfter.inSeconds);
    _clipboardPhraseSnapshot = phrase;
    setState(() => _justCopied = true);

    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _justCopied = false);
    });

    // CRIT-1.3 — schedule clipboard auto-wipe. Cancel any previous
    // pending wipe (re-tap Copy resets the window).
    _clipboardWipeTimer?.cancel();
    _clipboardWipeTimer = Timer(_clipboardWipeAfter, _wipeClipboardIfStillOurs);
  }

  /// CRIT-1.3 — wipe clipboard ONLY if it still contains the phrase we
  /// put there. The check guards against clobbering whatever the user
  /// has copied since (a password, a URL, anything). Fire-and-forget
  /// async so callers (Timer / dispose) don't have to await.
  void _wipeClipboardIfStillOurs() {
    final ours = _clipboardPhraseSnapshot;
    if (ours == null || ours.isEmpty) return;
    // Snapshot is one-shot — only one wipe attempt per copy.
    _clipboardPhraseSnapshot = null;
    () async {
      try {
        final current = await Clipboard.getData('text/plain');
        // Audit SEED-4 — Android 10+ shows the clipboard to nobody in the
        // background (null), which is where the person is after Copy (in
        // the password manager): clear it without the comparison.
        if (current?.text == ours || (current == null && defaultTargetPlatform == TargetPlatform.android)) {
          await Clipboard.setData(const ClipboardData(text: ''));
        }
      } catch (_) {
        // Platform channel may be unavailable in tests / shutdown.
        // Failure-safe: better to leave clipboard alone than crash.
      }
    }();
  }

  /// The recovery sheet → share sheet; shared = saved that way.
  Future<void> _shareSheet() async {
    if (screenCaptured.value) return; // C-63
    final l = context.l10n;
    final name = ref.read(profileNameProvider).value ?? '';
    final server = serverHostOf(ref.read(serverUrlProvider).value ?? '');
    final date = formatAccessDate(DateTime.now());
    setState(() => _sheetBusy = true);
    var shared = false;
    try {
      final png = await renderRecoverySheet(words: _phrase, l: l, name: name, server: server, date: date);
      shared = await ref.read(recoverySheetSharerProvider)(png);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] recovery sheet: $e');
    } finally {
      if (mounted) setState(() => _sheetBusy = false);
    }
    if (shared && mounted) widget.onSaved?.call(AccessWay.sheet);
  }

  Future<void> _written() async {
    if (!await showPhraseCheck(context, _phrase) || !mounted) return;
    widget.onSaved?.call(AccessWay.paper);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final words = _phrase;
    final l = context.l10n;

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            DsAppBar(title: '', onBack: widget.onBack),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2, DsSpace.x6, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.writeWordsTitle,
                    style: DsText.title1.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.writeWordsBody,
                    style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(DsSpace.x5, DsSpace.x4h5, DsSpace.x5, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: screenCaptured,
                      builder: (_, captured, _) => DsMnemonicGrid(
                        words: words,
                        revealed: _revealed && !captured,
                        onTap: captured ? null : () => setState(() => _revealed = true),
                      ),
                    ),
                    const SizedBox(height: 14),
                    AnimatedSwitcher(
                      duration: DsMotion.of(context, DsMotion.fast),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                      child: _revealed
                          ? Column(
                              key: ValueKey(_justCopied),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _CopyButton(copied: _justCopied, onTap: () => _onCopy(words)),
                                const SizedBox(height: 6),
                                // CRIT-1.3 — set expectation before auto-wipe
                                // surprises the user.
                                Text(l.clipboardClears, style: DsText.caption.copyWith(color: tokens.text2)),
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                    const SizedBox(height: DsSpace.x4),
                    Text(
                      l.screenshotNote,
                      textAlign: TextAlign.center,
                      style: DsText.footnote.copyWith(color: tokens.text3),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2, DsSpace.x6, DsSpace.x4h5),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DsButton(
                    key: const ValueKey('words-written'),
                    label: l.wordsWritten,
                    variant: DsButtonVariant.primary,
                    // A quick 2-word check first (ADR-059; was 3).
                    onPressed: _revealed ? _written : null,
                  ),
                  const SizedBox(height: DsSpace.x2),
                  DsButton(
                    key: const ValueKey('words-sheet'),
                    label: l.sheetAction,
                    variant: DsButtonVariant.ghost,
                    loading: _sheetBusy,
                    onPressed: _sheetBusy ? null : _shareSheet,
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

/// Small accent-soft pill with copy icon. Briefly transforms into a
/// "Copied ✓" success state after tap, then returns.
class _CopyButton extends StatelessWidget {
  final bool copied;
  final VoidCallback? onTap;

  const _CopyButton({required this.copied, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final fg = copied ? tokens.success : tokens.accent;
    final bg = copied ? tokens.success.withValues(alpha: tokens.success.a * 0.14) : tokens.accentSoft;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: copied ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.nudge9),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CustomPaint(painter: copied ? DsGlyphPainter(DsGlyph.check, color: fg) : _CopyPainter(fg)),
            ),
            const SizedBox(width: 8),
            Text(
              copied ? context.l10n.copied : context.l10n.copyPhrase,
              style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: fg),
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyPainter extends CustomPainter {
  final Color color;
  _CopyPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.save();
    canvas.scale(scale);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Two stacked rounded rects — typical "copy" glyph
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(8, 8, 13, 13), const Radius.circular(2.5)), stroke);
    // Behind rect — show only the L-shape that peeks out
    final p = Path()
      ..moveTo(5, 16)
      ..lineTo(3.5, 16)
      ..lineTo(3.5, 3.5)
      ..lineTo(16, 3.5)
      ..lineTo(16, 5);
    canvas.drawPath(p, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CopyPainter old) => old.color != color;
}
