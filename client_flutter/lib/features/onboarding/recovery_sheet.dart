// Recovery sheet — ADR-059. For people who still want paper: a picture
// (A4 at 150 dpi) with the 24 words, a QR of them, whose account it is and
// a plain warning, handed to the share sheet to print or keep in Files.
// The QR is the words as they are — the restore screen scans it
// ("I already have an account" → "Scan the recovery sheet").
//
// It's a file with the words in it: written to a fresh temp folder only
// for the share sheet and deleted when the sheet closes (as documents,
// ADR-017); the sheet itself says "print it, then delete the file".

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr/qr.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_l10n.dart';
import '../documents/document_share.dart';
import '../verify/verify_contact.dart' show QrMatrixPainter;

const kSheetSize = Size(1240, 1754);

/// The sheet as PNG bytes.
Future<Uint8List> renderRecoverySheet({
  required List<String> words,
  required AppL10n l,
  required String name,
  required String server,
  required String date,
}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec, Offset.zero & kSheetSize);
  c.drawRect(Offset.zero & kSheetSize, Paint()..color = DsPalette.white);
  const margin = 96.0;
  final width = kSheetSize.width - margin * 2;
  var y = margin;

  double text(String s, TextStyle style, {double? x, double? w}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w ?? width);
    tp.paint(c, Offset(x ?? margin, y));
    return tp.height;
  }

  final ink = DsText.body.copyWith(color: DsPalette.black, height: 1.3);
  y += text(l.sheetTitle, ink.copyWith(fontSize: 56, fontWeight: FontWeight.w700));
  y += 20;
  final who = [if (name.trim().isNotEmpty) name.trim(), if (server.isNotEmpty) server, date].join(' · ');
  y += text(who, ink.copyWith(fontSize: 30, color: DsPalette.black.withValues(alpha: 0.6)));
  y += 56;

  // 24 words in 3 columns × 8 rows.
  const cols = 3;
  final rows = (words.length / cols).ceil();
  final colW = width / cols;
  final wordStyle = ink.copyWith(fontSize: 40, fontFamily: DsType.familyMono, fontWeight: FontWeight.w600);
  final numStyle = ink.copyWith(fontSize: 26, fontFamily: DsType.familyMono);
  const rowH = 72.0;
  for (var i = 0; i < words.length; i++) {
    final col = i ~/ rows, row = i % rows;
    final x = margin + col * colW;
    final top = y + row * rowH;
    final n = TextPainter(
      text: TextSpan(text: '${i + 1}'.padLeft(2), style: numStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    n.paint(c, Offset(x, top + 12));
    final w = TextPainter(
      text: TextSpan(text: words[i], style: wordStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: colW - 64);
    w.paint(c, Offset(x + 56, top));
  }
  y += rows * rowH + 48;

  // QR with the words, left; how to restore, right.
  const qrSide = 420.0;
  final code = QrImage(QrCode.fromData(data: words.join(' '), errorCorrectLevel: QrErrorCorrectLevel.M));
  c.save();
  c.translate(margin, y);
  QrMatrixPainter(code).paint(c, const Size.square(qrSide));
  c.restore();
  final sideX = margin + qrSide + 56;
  final sideW = width - qrSide - 56;
  final keepY = y;
  y += text(l.sheetHowTitle, ink.copyWith(fontSize: 34, fontWeight: FontWeight.w700), x: sideX, w: sideW);
  y += 12;
  text(l.sheetHowBody, ink.copyWith(fontSize: 28), x: sideX, w: sideW);
  y = keepY + qrSide + 64;

  // The warning, in a box.
  final warn = TextPainter(
    text: TextSpan(
      text: l.sheetWarning,
      style: ink.copyWith(fontSize: 30, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width - 64);
  final box = Rect.fromLTWH(margin, y, width, warn.height + 64);
  c.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(24)), Paint()..color = DsPalette.danger10);
  warn.paint(c, Offset(margin + 32, y + 32));

  final img = await rec.endRecording().toImage(kSheetSize.width.toInt(), kSheetSize.height.toInt());
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// Hands the PNG to the share sheet; false when it was closed unused.
/// Faked in tests.
typedef RecoverySheetSharer = Future<bool> Function(Uint8List png, {Rect? origin});

final recoverySheetSharerProvider = Provider<RecoverySheetSharer>(
  (ref) => (png, {origin}) =>
      shareDecryptedFile(png, fileName: 'sinhron-recovery-sheet.png', mimeType: 'image/png', origin: origin),
);
