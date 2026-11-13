// Sign out flow — reached from Profile edit → "Sign out".
//
// Per spec §6.7 (Linked devices) + §6.8 (Recovery phrase), signing out is
// a PER-DEVICE action — it clears the local keystore on THIS device but
// the user's identity (and the MLS state on other linked devices) stays
// intact. The only way to come back to THIS device is via the recovery
// phrase, so we lead with an amber recovery-phrase reminder.
//
// Distinct from Account delete (WU 31) which is destructive across all
// devices and triggers the 7-day grace card.
//
// Layout:
//   1. Top bar: back · "Sign out"
//   2. Hero: amber circle with door-exit glyph
//   3. Title + identity sub-line ("Vera Kuznetsova · @vera")
//   4. Recovery phrase reminder (amber call-out card — most important)
//   5. "What happens" checklist (4 rows)
//   6. Bottom actions: danger Sign-out button + Cancel

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_icon.dart';
import '../../l10n/l10n.dart';
import '../app_lock/app_lock.dart';

class SignOutScreen extends StatelessWidget {
  final String name;
  final String username; // includes leading @
  final int otherDeviceCount;
  final VoidCallback? onBack;
  final FutureOr<void> Function()? onConfirm;

  const SignOutScreen({
    super.key,
    this.name = 'Vera Kuznetsova',
    this.username = '@vera',
    this.otherDeviceCount = 2,
    this.onBack,
    this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            _TopBar(onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(0, DsSpace.x1, 0, DsSpace.x4),
                children: [
                  const _Hero(),
                  _IdentityLine(name: name, username: username),
                  const SizedBox(height: 22),
                  const _RecoveryReminder(),
                  const SizedBox(height: 18),
                  _WhatHappens(otherDeviceCount: otherDeviceCount),
                ],
              ),
            ),
            _BottomActions(onConfirm: onConfirm, onCancel: onBack),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Top bar
// ═════════════════════════════════════════════════════════════════════

class _TopBar extends StatelessWidget {
  final VoidCallback? onBack;
  const _TopBar({this.onBack});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x1h5),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x14),
              child: Center(
                child: Text(
                  context.l10n.signOutTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.headline.copyWith(height: 1.0, color: tokens.text),
                ),
              ),
            ),
          ),
          Row(
            children: [
              if (onBack != null)
                Semantics(button: true, label: context.l10n.a11yBack, excludeSemantics: true, onTap: onBack, child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBack,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CustomPaint(painter: DsGlyphPainter(DsGlyph.back, color: tokens.text)),
                      ),
                    ),
                  ),
                )),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero — amber circle with door-exit glyph
// ═════════════════════════════════════════════════════════════════════

class _Hero extends StatelessWidget {
  const _Hero();

  static const _amber = DsPalette.orange;
  static const _amberSoft = DsPalette.orange12;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x10, DsSpace.x5, DsSpace.x10, 0),
      child: Column(
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: const BoxDecoration(color: _amberSoft, shape: BoxShape.circle),
            child: Center(
              child: SizedBox(
                width: 38,
                height: 38,
                child: CustomPaint(painter: _DoorExitPainter(color: _amber)),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            context.l10n.signOutHeading,
            textAlign: TextAlign.center,
            style: DsText.title2.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
          ),
        ],
      ),
    );
  }
}

class _IdentityLine extends StatelessWidget {
  final String name;
  final String username;
  const _IdentityLine({required this.name, required this.username});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x10, DsSpace.x1h5, DsSpace.x10, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // A real name can be long — it gives way, the key stays readable.
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 3,
            height: 3,
            decoration: BoxDecoration(color: tokens.text4, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(username, style: DsTextArt.t13w500Monov6.copyWith(color: tokens.text3)),
        ],
      ),
    );
  }
}

class _DoorExitPainter extends CustomPainter {
  final Color color;
  _DoorExitPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // Door frame — left side
    final frame = Path()
      ..moveTo(10, 4)
      ..lineTo(5, 4)
      ..arcToPoint(const Offset(3, 6), radius: const Radius.circular(2))
      ..lineTo(3, 18)
      ..arcToPoint(const Offset(5, 20), radius: const Radius.circular(2))
      ..lineTo(10, 20);
    canvas.drawPath(frame, stroke);
    // Arrow pointing right (out)
    canvas.drawLine(const Offset(10, 12), const Offset(21, 12), stroke);
    final arrow = Path()
      ..moveTo(16, 7)
      ..lineTo(21, 12)
      ..lineTo(16, 17);
    canvas.drawPath(arrow, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DoorExitPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Recovery phrase reminder (amber call-out)
// ═════════════════════════════════════════════════════════════════════

class _RecoveryReminder extends StatelessWidget {
  const _RecoveryReminder();

  static const _amber = DsPalette.orange;
  static const _amberBg = DsPalette.artD97706a14;
  static const _amberBorder = DsPalette.artD97706a3D;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3h5, DsSpace.x3, DsSpace.x3h5),
        decoration: BoxDecoration(
          color: _amberBg,
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          border: Border.all(color: _amberBorder, width: 0.7),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CustomPaint(painter: _AlertTrianglePainter(color: _amber)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.l10n.signOutReminderTitle,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                  const SizedBox(height: 4),
                  Text(context.l10n.signOutReminderBody, style: DsText.subhead.copyWith(color: tokens.text2)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlertTrianglePainter extends CustomPainter {
  final Color color;
  _AlertTrianglePainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final tri = Path()
      ..moveTo(12, 3.5)
      ..lineTo(22, 20)
      ..lineTo(2, 20)
      ..close();
    canvas.drawPath(tri, stroke);
    canvas.drawLine(const Offset(12, 10), const Offset(12, 14.5), stroke);
    canvas.drawCircle(const Offset(12, 17.5), 1.1, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AlertTrianglePainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// What happens — 4-row checklist
// ═════════════════════════════════════════════════════════════════════

class _WhatHappens extends StatelessWidget {
  final int otherDeviceCount;
  const _WhatHappens({required this.otherDeviceCount});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x2h5),
          child: Text(
            context.l10n.signOutWhatHappens,
            style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
          child: Container(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3h5, DsSpace.x4, DsSpace.x3h5),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              border: Border.all(color: tokens.divider, width: 0.5),
              boxShadow: DsShadow.card,
            ),
            child: Column(
              children: [
                _Row(glyph: _RowGlyph.door, text: context.l10n.signOutRowSignedOut),
                // Only when there are other devices (0 / unknown offline: no row).
                if (otherDeviceCount > 0)
                  _Row(glyph: _RowGlyph.devices, text: context.l10n.signOutRowOtherDevices(otherDeviceCount)),
                _Row(glyph: _RowGlyph.lock, text: context.l10n.signOutRowWipe),
                _Row(glyph: _RowGlyph.key, text: context.l10n.signOutRowComeBack, isLast: true),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum _RowGlyph { door, devices, lock, key }

class _Row extends StatelessWidget {
  final _RowGlyph glyph;
  final String text;
  final bool isLast;
  const _Row({required this.glyph, required this.text, this.isLast = false});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : DsSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            margin: const EdgeInsets.only(top: DsSpace.nudge1),
            decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(8)),
            child: Center(
              child: SizedBox(
                width: 17,
                height: 17,
                child: CustomPaint(
                  painter: _RowGlyphPainter(shape: glyph, color: tokens.text2),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _RowGlyphPainter extends CustomPainter {
  final _RowGlyph shape;
  final Color color;
  _RowGlyphPainter({required this.shape, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (shape) {
      case _RowGlyph.door:
        final frame = Path()
          ..moveTo(10, 4)
          ..lineTo(5, 4)
          ..arcToPoint(const Offset(3, 6), radius: const Radius.circular(2))
          ..lineTo(3, 18)
          ..arcToPoint(const Offset(5, 20), radius: const Radius.circular(2))
          ..lineTo(10, 20);
        canvas.drawPath(frame, stroke);
        canvas.drawLine(const Offset(10, 12), const Offset(21, 12), stroke);
        final arrow = Path()
          ..moveTo(16, 7)
          ..lineTo(21, 12)
          ..lineTo(16, 17);
        canvas.drawPath(arrow, stroke);
      case _RowGlyph.devices:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 5, 13, 14), const Radius.circular(2)), stroke);
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(14, 9, 7, 10), const Radius.circular(1.5)),
          stroke,
        );
        canvas.drawLine(const Offset(8, 19), const Offset(8, 20.5), stroke);
        canvas.drawLine(const Offset(11, 19), const Offset(11, 20.5), stroke);
      case _RowGlyph.lock:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(5, 11, 14, 9), const Radius.circular(2)), stroke);
        final shackle = Path()
          ..moveTo(8, 11)
          ..lineTo(8, 8)
          ..arcToPoint(const Offset(16, 8), radius: const Radius.circular(4))
          ..lineTo(16, 11);
        canvas.drawPath(shackle, stroke);
        canvas.drawCircle(const Offset(12, 15.5), 1.3, fill);
      case _RowGlyph.key:
        canvas.drawCircle(const Offset(8, 14), 4, stroke);
        canvas.drawLine(const Offset(11, 11), const Offset(20, 4), stroke);
        canvas.drawLine(const Offset(17, 7), const Offset(19, 9), stroke);
        canvas.drawLine(const Offset(14.5, 9.5), const Offset(16.5, 11.5), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RowGlyphPainter old) => old.shape != shape || old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Bottom action bar — danger Sign-out + Cancel
// ═════════════════════════════════════════════════════════════════════

/// Sign out wipes the keys and the chats — seconds; a spinner meanwhile and
/// no second wipe from a second tap (2026-10-16 UI audit).
class _BottomActions extends ConsumerStatefulWidget {
  final FutureOr<void> Function()? onConfirm;
  final VoidCallback? onCancel;
  const _BottomActions({this.onConfirm, this.onCancel});

  @override
  ConsumerState<_BottomActions> createState() => _BottomActionsState();
}

class _BottomActionsState extends ConsumerState<_BottomActions> {
  bool _busy = false;

  Future<void> _confirm() async {
    final f = widget.onConfirm;
    if (f == null || _busy) return;
    // Audit LOCK-6 — only the owner: Face ID / the phone's passcode first.
    if (!await confirmOwner(ref, context.l10n.signOutTitle) || !mounted) return;
    setState(() => _busy = true);
    try {
      await f();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.bgSoft,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x3, DsSpace.x3h5, DsSpace.x2),
      child: Column(
        children: [
          DsButton(
            label: context.l10n.signOutTitle,
            variant: DsButtonVariant.danger,
            loading: _busy,
            onPressed: widget.onConfirm == null || _busy ? null : _confirm,
          ),
          const SizedBox(height: 6),
          DsButton(
            label: context.l10n.cancel,
            variant: DsButtonVariant.ghost,
            size: DsButtonSize.medium,
            onPressed: _busy ? null : widget.onCancel,
          ),
        ],
      ),
    );
  }
}
