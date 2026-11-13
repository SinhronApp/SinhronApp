// Show my QR — reached from Profile edit → "Show my QR" row.
//
// Per spec §6.4 (Identity), a Sinhron QR encodes @username plus the home
// server host so another Sinhron user can scan it and request a chat. The
// QR is NOT a key exchange — that happens through the safety-number flow.
// This is the equivalent of a contact card.
//
// Layout (top to bottom):
//   1. Top bar: back chevron · "My QR code" title · scan-instead trailing
//   2. Hero: avatar, name, server-host pill, then the Signal-style accent
//      card (DsQrCard, owner 2026-10-20) — white QR tile, handle and
//      "on <server>" under it
//   3. Action row: Share / Copy (+ Save image in the preview) — DsActionButton
//   4. Footer: warning text about who can use the code

import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_action_button.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_qr_card.dart';
import '../../widgets/sinhron_mark.dart';
import '../../l10n/l10n.dart';
import '../verify/verify_contact.dart' show QrMatrixPainter;

/// Which surface is showing the QR. Affects the title and the footer copy.
///   - myQr:  "My QR code" — Profile edit's "Show my QR"
///   - invite: "Invite to Sinhron" — Compose's "Invite by QR" (framed as
///     a contact share, not an identity reveal)
enum ShowQrMode { myQr, invite }

class ShowQrScreen extends StatelessWidget {
  final ShowQrMode mode;
  final String name;
  final String username; // includes leading @
  final String server;

  /// My photo, if I set one.
  final Uint8List? photo;
  final VoidCallback? onBack;
  final VoidCallback? onScanInstead;

  /// Real mode (navigation): the QR's text (`contactQrPayload`) — drawn as
  /// a real, scannable code. Null = design preview with the drawn mock.
  final String? qrPayload;
  final VoidCallback? onShare;
  final VoidCallback? onCopyKey;

  const ShowQrScreen({
    super.key,
    this.mode = ShowQrMode.myQr,
    this.name = 'Vera Kuznetsova',
    this.username = '@vera',
    this.server = 'cabin.sinhron.app',
    this.photo,
    this.onBack,
    this.onScanInstead,
    this.qrPayload,
    this.onShare,
    this.onCopyKey,
  });

  String get _title => switch (mode) {
    ShowQrMode.myQr => lookupAppL10n(Locale(currentLanguage)).showQrTitleMy,
    ShowQrMode.invite => lookupAppL10n(Locale(currentLanguage)).showQrTitleInvite,
  };

  String get _footerCopy => qrPayload != null
      ? lookupAppL10n(Locale(currentLanguage)).showQrFooterReal
      : switch (mode) {
          ShowQrMode.myQr => lookupAppL10n(Locale(currentLanguage)).showQrFooterMy(username),
          ShowQrMode.invite => lookupAppL10n(Locale(currentLanguage)).showQrFooterInvite(server),
        };

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
            _TopBar(title: _title, onBack: onBack, onScanInstead: onScanInstead),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, DsSpace.x6),
                children: [
                  _IdentityHero(name: name, username: username, server: server, qrPayload: qrPayload, photo: photo),
                  const SizedBox(height: 18),
                  qrPayload == null ? const _ActionRow() : _ActionRow.real(onShare: onShare, onCopyKey: onCopyKey),
                  const SizedBox(height: 22),
                  _FooterNote(copy: _footerCopy),
                ],
              ),
            ),
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
  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onScanInstead;
  const _TopBar({required this.title, this.onBack, this.onScanInstead});

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
                  title,
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
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onScanInstead,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CustomPaint(painter: _ScanGlyphPainter(color: tokens.text)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ScanGlyphPainter extends CustomPainter {
  final Color color;
  _ScanGlyphPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 4 corner-brackets
    canvas.drawPath(
      Path()
        ..moveTo(4, 8)
        ..lineTo(4, 4)
        ..lineTo(8, 4),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(16, 4)
        ..lineTo(20, 4)
        ..lineTo(20, 8),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(20, 16)
        ..lineTo(20, 20)
        ..lineTo(16, 20),
      paint,
    );
    canvas.drawPath(
      Path()
        ..moveTo(8, 20)
        ..lineTo(4, 20)
        ..lineTo(4, 16),
      paint,
    );
    canvas.drawLine(const Offset(4, 12), const Offset(20, 12), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScanGlyphPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Identity hero — avatar + name + username + server pill + QR card
// ═════════════════════════════════════════════════════════════════════

class _IdentityHero extends StatelessWidget {
  final String name;
  final String username;
  final String server;
  final String? qrPayload;
  final Uint8List? photo;
  const _IdentityHero({required this.name, required this.username, required this.server, this.qrPayload, this.photo});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: DsSpace.x3),
      child: Column(
        children: [
          DsAvatar(name: name, size: 84, image: photo),
          const SizedBox(height: DsSpace.x3),
          Text(
            name,
            textAlign: TextAlign.center,
            style: DsText.title2.copyWith(fontWeight: FontWeight.w700, color: tokens.text),
          ),
          const SizedBox(height: DsSpace.x2),
          _ServerPill(server: server),
          const SizedBox(height: DsSpace.x6),
          // Signal-style: the code on white inside an accent card.
          DsQrCard(
            code: qrPayload == null ? const _QrCard() : _RealQrCard(payload: qrPayload!),
            title: username,
            subtitle: context.l10n.showQrOnServer(server),
          ),
        ],
      ),
    );
  }
}

class _ServerPill extends StatelessWidget {
  final String server;
  const _ServerPill({required this.server});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.nudge5, DsSpace.nudge11, DsSpace.nudge5),
      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CustomPaint(painter: _GlobeGlyphPainter(color: tokens.text3)),
          ),
          const SizedBox(width: 6),
          Text(server, style: DsTextArt.t12p5w500Monov2.copyWith(color: tokens.text2)),
        ],
      ),
    );
  }
}

class _GlobeGlyphPainter extends CustomPainter {
  final Color color;
  _GlobeGlyphPainter({required this.color});
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
    canvas.drawCircle(const Offset(12, 12), 9, stroke);
    canvas.drawLine(const Offset(3, 12), const Offset(21, 12), stroke);
    final p = Path()
      ..moveTo(12, 3)
      ..cubicTo(15, 7, 15, 17, 12, 21)
      ..moveTo(12, 3)
      ..cubicTo(9, 7, 9, 17, 12, 21);
    canvas.drawPath(p, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlobeGlyphPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// QR card — always-white background so it stays scannable in any theme.
// Custom-painted pseudo-QR (deterministic data modules + finder patterns).
// ═════════════════════════════════════════════════════════════════════

/// The real, scannable code (black on white — scanners need it).
class _RealQrCard extends StatelessWidget {
  const _RealQrCard({required this.payload});
  final String payload;

  @override
  Widget build(BuildContext context) {
    final code = QrImage(QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M));
    return CustomPaint(key: const ValueKey('my-contact-qr'), painter: QrMatrixPainter(code));
  }
}

/// Design preview: a drawn mock with the mark in the middle.
class _QrCard extends StatelessWidget {
  const _QrCard();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        const Positioned.fill(child: _QrMatrix()),
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: DsPalette.white, borderRadius: BorderRadius.circular(10)),
          padding: const EdgeInsets.all(DsSpace.x1h5),
          child: const SinhronMark(size: 40),
        ),
      ],
    );
  }
}

class _QrMatrix extends StatelessWidget {
  const _QrMatrix();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _QrPainter(seed: 0x51A4));
  }
}

class _QrPainter extends CustomPainter {
  final int seed;
  _QrPainter({required this.seed});

  // 25×25 module grid — keeps modules visually chunky for screenshots.
  static const _n = 25;

  @override
  void paint(Canvas canvas, Size size) {
    final module = size.width / _n;
    final fill = Paint()..color = DsPalette.ink;

    // 1) Pre-compute reserved-areas mask: finder patterns, alignment,
    //    timing, and the centre cutout for the Sinhron mark.
    final reserved = List.generate(_n, (_) => List.filled(_n, false));

    void reserve(int x0, int y0, int w, int h) {
      for (int y = y0; y < y0 + h; y++) {
        for (int x = x0; x < x0 + w; x++) {
          if (x >= 0 && y >= 0 && x < _n && y < _n) reserved[y][x] = true;
        }
      }
    }

    reserve(0, 0, 8, 8); // top-left finder + separator
    reserve(_n - 8, 0, 8, 8); // top-right
    reserve(0, _n - 8, 8, 8); // bottom-left
    reserve(_n - 6, _n - 6, 5, 5); // alignment pattern (bottom-right)
    // timing rows / cols
    for (int i = 8; i < _n - 8; i++) {
      reserved[6][i] = true;
      reserved[i][6] = true;
    }
    // centre cutout for mark (10×10 modules)
    final c = _n ~/ 2;
    reserve(c - 5, c - 5, 10, 10);

    // 2) Deterministic pseudo-random data modules — looks busy/QR-like.
    final rand = math.Random(seed);
    for (int y = 0; y < _n; y++) {
      for (int x = 0; x < _n; x++) {
        if (reserved[y][x]) continue;
        if (rand.nextDouble() < 0.46) {
          canvas.drawRect(Rect.fromLTWH(x * module, y * module, module, module), fill);
        }
      }
    }

    // 3) Finder patterns — 7×7 outer outline (stroked filled rect)
    //    with 3×3 filled centre.
    void finder(int gx, int gy) {
      final outerRect = Rect.fromLTWH(gx * module, gy * module, module * 7, module * 7);
      canvas.drawRRect(RRect.fromRectAndRadius(outerRect, Radius.circular(module * 0.9)), fill);
      // White inner ring
      final innerRect = Rect.fromLTWH((gx + 1) * module, (gy + 1) * module, module * 5, module * 5);
      canvas.drawRRect(
        RRect.fromRectAndRadius(innerRect, Radius.circular(module * 0.6)),
        Paint()..color = DsPalette.white,
      );
      // Filled centre
      final centerRect = Rect.fromLTWH((gx + 2) * module, (gy + 2) * module, module * 3, module * 3);
      canvas.drawRRect(RRect.fromRectAndRadius(centerRect, Radius.circular(module * 0.4)), fill);
    }

    finder(0, 0);
    finder(_n - 7, 0);
    finder(0, _n - 7);

    // 4) Alignment pattern (5×5) — bottom-right
    final ax = _n - 6;
    final ay = _n - 6;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(ax * module, ay * module, module * 5, module * 5),
        Radius.circular(module * 0.6),
      ),
      fill,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH((ax + 1) * module, (ay + 1) * module, module * 3, module * 3),
        Radius.circular(module * 0.4),
      ),
      Paint()..color = DsPalette.white,
    );
    canvas.drawRect(Rect.fromLTWH((ax + 2) * module, (ay + 2) * module, module, module), fill);

    // 5) Timing patterns — alternating modules along row/col 6
    for (int i = 8; i < _n - 8; i++) {
      if (i.isEven) {
        canvas.drawRect(Rect.fromLTWH(i * module, 6 * module, module, module), fill);
        canvas.drawRect(Rect.fromLTWH(6 * module, i * module, module, module), fill);
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.seed != seed;
}

// ═════════════════════════════════════════════════════════════════════
// Action row — 3 tiles (Share / Copy link / Save image)
// ═════════════════════════════════════════════════════════════════════

class _ActionRow extends StatelessWidget {
  const _ActionRow() : real = false, onShare = null, onCopyKey = null;
  const _ActionRow.real({this.onShare, this.onCopyKey}) : real = true;

  final bool real;
  final VoidCallback? onShare;
  final VoidCallback? onCopyKey;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    Widget glyph(DsActionGlyph g) =>
        CustomPaint(painter: DsActionGlyphPainter(g, color: tokens.accent, strokeWidth: kActionIconStroke));
    final l = context.l10n;
    // Real mode: share the key and copy it — no "Save image" (not built).
    // The design preview shows all three, with nothing behind them.
    return DsActionRow(
      children: [
        DsActionButton(
          key: const ValueKey('show-qr-share'),
          label: l.share,
          icon: glyph(DsActionGlyph.share),
          onTap: real ? onShare : null,
        ),
        DsActionButton(
          key: const ValueKey('show-qr-copy'),
          label: real ? l.showQrCopyKey : l.showQrCopyLink,
          icon: glyph(DsActionGlyph.copy),
          onTap: real ? onCopyKey : null,
        ),
        if (!real) DsActionButton(label: l.showQrSaveImage, icon: glyph(DsActionGlyph.save)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Footer — explanation note
// ═════════════════════════════════════════════════════════════════════

class _FooterNote extends StatelessWidget {
  final String copy;
  const _FooterNote({required this.copy});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5),
      child: Column(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CustomPaint(painter: _InfoGlyphPainter(color: tokens.text3)),
          ),
          const SizedBox(height: 8),
          Text(
            copy,
            textAlign: TextAlign.center,
            style: DsText.footnote.copyWith(color: tokens.text3),
          ),
        ],
      ),
    );
  }
}

class _InfoGlyphPainter extends CustomPainter {
  final Color color;
  _InfoGlyphPainter({required this.color});
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
    canvas.drawCircle(const Offset(12, 12), 9, stroke);
    canvas.drawLine(const Offset(12, 11), const Offset(12, 16), stroke);
    canvas.drawCircle(const Offset(12, 8), 0.8, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_InfoGlyphPainter old) => old.color != color;
}
