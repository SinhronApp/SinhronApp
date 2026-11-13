// Compose / New chat screen. Reached from the FAB in ChatList (and from
// EmptyChats' "Start a new chat" CTA).
//
// Sinhron-specific framing: your contacts are people who share a Sinhron
// server with you. The search field is the only way to surface someone you
// haven't messaged before; the alphabetical list comes from your local
// address book (per spec §6.7, contacts are stored client-side only and
// never uploaded — your server can't enumerate your social graph).
//
// Composition:
//   1. Cancel-style app-bar with "New chat" title + Cancel left.
//   2. DsTextField search box (filters the list as you type).
//   3. Quick-action tiles row — New group · Invite via QR · Scan QR.
//   4. ALPHABETICAL list with sticky-ish section headers (A / B / …).
//      Each row: avatar + name + @username + verification check + online dot.
//   5. Footer link "Invite someone new" (QR pairing flow — ComingSoon).

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_text_field.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_shared_glyphs.dart';
import 'paste_key_sheet.dart';

// ═════════════════════════════════════════════════════════════════════
// Contacts
// ═════════════════════════════════════════════════════════════════════

class _Contact {
  final String name;
  final String username;
  /// "online" / "last seen …" from real presence (ADR-031); '' = unknown
  /// (presence is off, or nothing heard yet) — then only the key shows.
  final String status;
  final bool online;
  final bool verified;

  /// Real mode: the chat and the key.
  final String? chatId;
  final String? key;
  final Uint8List? photo;
  const _Contact({
    required this.name,
    required this.username,
    this.chatId,
    this.key,
    this.photo,
    this.status = '',
    this.online = false,
    // ignore: unused_element_parameter
    this.verified = false,
  });
}

// ═════════════════════════════════════════════════════════════════════
// Screen
// ═════════════════════════════════════════════════════════════════════

/// A person I already chat with (real mode).
class ComposeContact {
  const ComposeContact({
    required this.chatId,
    required this.name,
    required this.key,
    this.status = '',
    this.online = false,
    this.photo,
  });
  final String chatId;
  final String name;

  /// Their photo, if they shared one.
  final Uint8List? photo;

  /// Real presence (`presenceLabel`): '' when nothing is known.
  final String status;
  final bool online;

  /// Identity key, hex — searchable, shown short.
  final String key;
}

class ComposeScreen extends StatefulWidget {
  final VoidCallback? onCancel;

  /// Real mode: my contacts (the search used to look through an empty
  /// placeholder list — 2026-10-16 UI audit) and opening one's chat.
  final List<ComposeContact> contacts;
  final void Function(ComposeContact contact)? onOpenContact;
  final VoidCallback? onNewGroup;
  final VoidCallback? onInviteQr;
  final VoidCallback? onScanQr;

  /// MLS-encrypted chat by identity-pubkey paste (WU E4). When non-null,
  /// "Paste address" opens a sheet for the recipient's identity hex
  /// (paste_key_sheet.dart); "Start" calls this with the key. Navigation
  /// handles the MLS dance + push into ChatView (see
  /// `chat_providers.createMlsChat`).
  final Future<void> Function(String identityHex)? onInviteByIdentity;

  const ComposeScreen({
    super.key,
    this.onCancel,
    this.onNewGroup,
    this.onInviteQr,
    this.onScanQr,
    this.onInviteByIdentity,
    this.contacts = const [],
    this.onOpenContact,
  });

  @override
  State<ComposeScreen> createState() => _ComposeScreenState();
}

class _ComposeScreenState extends State<ComposeScreen> {
  String _query = '';

  /// "Paste address" → the sheet; a key back starts the chat (the sheet is
  /// gone by then, so the chat replaces New chat as before).
  Future<void> _pasteKey() async {
    final start = widget.onInviteByIdentity;
    if (start == null) return;
    final key = await showPasteKeySheet(context);
    if (key == null || !mounted) return;
    await start(key);
  }

  List<_Contact> get _all => [
    for (final c in widget.contacts)
      _Contact(
        name: c.name,
        username: _shortKey(c.key),
        chatId: c.chatId,
        key: c.key,
        status: c.status,
        online: c.online,
        photo: c.photo,
      ),
  ];

  static String _shortKey(String hex) {
    final h = hex.toLowerCase();
    return h.length < 8 ? h : '${h.substring(0, 4)} ${h.substring(4, 8)}';
  }

  List<_Contact> get _filtered {
    final q = _query.trim().toLowerCase();
    final all = [..._all]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (q.isEmpty) return all;
    final hex = q.replaceAll(RegExp(r'\s'), '');
    return all
        .where(
          (c) =>
              c.name.toLowerCase().contains(q) ||
              c.username.toLowerCase().contains(q) ||
              (hex.length >= 2 && (c.key ?? '').contains(hex)),
        )
        .toList();
  }

  void _pick(_Contact c) {
    // By key: a contact without a chat (ADR-052) has no chat id yet.
    final real = widget.contacts.where((x) => c.key != null ? x.key == c.key : x.chatId == c.chatId).firstOrNull;
    if (real != null) widget.onOpenContact?.call(real);
  }

  Map<String, List<_Contact>> get _grouped {
    final out = <String, List<_Contact>>{};
    for (final c in _filtered) {
      final letter = c.name.isEmpty ? '#' : c.name.characters.first.toUpperCase();
      out.putIfAbsent(letter, () => []).add(c);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final grouped = _grouped;
    final letters = grouped.keys.toList();

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            _CancelAppBar(onCancel: widget.onCancel),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1h5, DsSpace.x3h5, DsSpace.x3),
              child: DsTextField(hintText: context.l10n.searchContacts, onChanged: (v) => setState(() => _query = v)),
            ),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: DsSpace.x6),
                children: [
                  if (_query.isEmpty)
                    _QuickActionsRow(
                      onNewGroup: widget.onNewGroup,
                      onInviteQr: widget.onInviteQr,
                      onScanQr: widget.onScanQr,
                      onEncryptedByIdentity: widget.onInviteByIdentity == null ? null : _pasteKey,
                    ),
                  for (final letter in letters) ...[
                    _SectionHeader(label: letter, isLetter: true),
                    for (var i = 0; i < grouped[letter]!.length; i++)
                      _ContactRow(
                        contact: grouped[letter]![i],
                        isLast: i == grouped[letter]!.length - 1,
                        onTap: () => _pick(grouped[letter]![i]),
                      ),
                  ],
                  if (_query.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x4h5, DsSpace.x7, 0),
                      child: Text(
                        context.l10n.contactsFooter,
                        textAlign: TextAlign.center,
                        style: DsText.footnote.copyWith(color: tokens.text3),
                      ),
                    )
                  else if (grouped.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x15, DsSpace.x7, 0),
                      child: Column(
                        children: [
                          Text(
                            context.l10n.noContactNamed(_query),
                            textAlign: TextAlign.center,
                            style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            context.l10n.noContactHint,
                            textAlign: TextAlign.center,
                            style: DsText.subhead.copyWith(color: tokens.text3),
                          ),
                        ],
                      ),
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

// ═════════════════════════════════════════════════════════════════════
// Cancel-style app bar
// ═════════════════════════════════════════════════════════════════════

class _CancelAppBar extends StatelessWidget {
  final VoidCallback? onCancel;
  const _CancelAppBar({this.onCancel});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    // Full width, so "New chat" sits in the middle of the screen (it sat
    // left of centre — 2026-10-16 UI audit).
    return Container(
      height: 44,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            left: 4,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onCancel?.call(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3),
                child: Center(
                  child: Text(
                    context.l10n.cancel,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w500, height: 1.0, color: tokens.accent),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Text(
              context.l10n.newChat,
              style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.text),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Quick actions row — soft neutral tiles
// ═════════════════════════════════════════════════════════════════════

class _QuickActionsRow extends StatelessWidget {
  final VoidCallback? onNewGroup;
  final VoidCallback? onInviteQr;
  final VoidCallback? onScanQr;

  /// When non-null, a 4th tile appears: "Paste address" — opens the
  /// paste-key sheet (paste_key_sheet.dart).
  final VoidCallback? onEncryptedByIdentity;
  const _QuickActionsRow({this.onNewGroup, this.onInviteQr, this.onScanQr, this.onEncryptedByIdentity});

  @override
  Widget build(BuildContext context) {
    final fg = DsTheme.of(context).text2;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, 0, DsSpace.x3h5, DsSpace.x4h5),
      child: Row(
        children: [
          // No handler = no tile (groups of several people are not built yet).
          if (onNewGroup != null) ...[
            Expanded(
              child: _QuickTile(
                label: context.l10n.newGroup,
                painter: _GroupGlyphPainter(color: fg),
                onTap: onNewGroup,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: _QuickTile(
              label: context.l10n.inviteByQr,
              painter: _QrShareGlyphPainter(color: fg),
              onTap: onInviteQr,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _QuickTile(
              label: context.l10n.scanQr,
              painter: _QrScanGlyphPainter(color: fg),
              onTap: onScanQr,
            ),
          ),
          if (onEncryptedByIdentity != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: _QuickTile(
                label: context.l10n.pasteKey,
                painter: DsKeyGlyphGlyph(color: fg),
                onTap: onEncryptedByIdentity,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  final String label;
  final CustomPainter painter;
  final VoidCallback? onTap;
  const _QuickTile({
    required this.label,
    required this.painter,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return DsPressable(
      onTap: onTap,
      scale: 0.95,
      child: Container(
        height: 80,
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
        decoration: BoxDecoration(
          // A soft neutral tile: visible on white and on the dark background.
          color: DsTheme.isDarkOf(context) ? tokens.surface : tokens.bgSoft,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 23, height: 23, child: CustomPaint(painter: painter)),
            const SizedBox(height: 10),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, fontSize: 11.5, height: 1.1, color: tokens.text),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Section header (uppercase eyebrow inside the list)
// ═════════════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  final String label;
  final bool isLetter;
  const _SectionHeader({required this.label, this.isLetter = false});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(DsSpace.x7, isLetter ? DsSpace.x3h5 : DsSpace.x1, DsSpace.x7, DsSpace.x1h5),
      child: Text(
        isLetter ? label : label.toUpperCase(),
        style: TextStyle(
          fontFamily: DsType.family,
          fontSize: isLetter ? 13 : 11,
          fontWeight: isLetter ? FontWeight.w700 : FontWeight.w600,
          letterSpacing: isLetter ? -0.1 : 0.5,
          height: 1.2,
          color: isLetter ? tokens.text2 : tokens.text3,
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Contact row
// ═════════════════════════════════════════════════════════════════════

class _ContactRow extends StatelessWidget {
  final _Contact contact;
  final bool isLast;
  final VoidCallback? onTap;
  const _ContactRow({required this.contact, required this.isLast, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onTap?.call(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2h5),
            child: Row(
              children: [
                DsAvatar(name: contact.name, size: 42, image: contact.photo, online: contact.online),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              contact.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                            ),
                          ),
                          if (contact.verified) ...[
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CustomPaint(painter: _VerifiedSealPainter(color: tokens.accent, onColor: tokens.accentText)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        contact.status.isEmpty ? contact.username : '${contact.username} · ${contact.status}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsTextArt.t12p5w500sub.copyWith(
                          color: contact.online ? tokens.success : tokens.text3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!isLast) Positioned(left: 70, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Painters
// ═════════════════════════════════════════════════════════════════════

class _VerifiedSealPainter extends CustomPainter {
  final Color color;
  final Color onColor;
  _VerifiedSealPainter({required this.color, required this.onColor});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    // Zig-zag seal background
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const points = 10;
    const cx = 12.0;
    const cy = 12.0;
    const rOuter = 10.0;
    const rInner = 8.0;
    final path = Path();
    for (var i = 0; i < points * 2; i++) {
      final r = i.isEven ? rOuter : rInner;
      final ang = (i / (points * 2)) * 6.2831853 - 1.5707963;
      final dx = cx + r * _cos(ang);
      final dy = cy + r * _sin(ang);
      if (i == 0) {
        path.moveTo(dx, dy);
      } else {
        path.lineTo(dx, dy);
      }
    }
    path.close();
    canvas.drawPath(path, fill);
    // Inner check (white)
    final tickPaint = Paint()
      ..color = onColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final tick = Path()
      ..moveTo(7.5, 12)
      ..lineTo(10.5, 15)
      ..lineTo(16.5, 9);
    canvas.drawPath(tick, tickPaint);
    canvas.restore();
  }

  // Tiny trig — avoid importing dart:math just for sin/cos
  double _sin(double x) {
    var t = x;
    while (t > 3.1415926535) {
      t -= 6.2831853;
    }
    while (t < -3.1415926535) {
      t += 6.2831853;
    }
    final t2 = t * t;
    return t * (1 - t2 / 6 + t2 * t2 / 120 - t2 * t2 * t2 / 5040);
  }

  double _cos(double x) => _sin(x + 1.5707963267948966);

  @override
  bool shouldRepaint(_VerifiedSealPainter old) => old.color != color || old.onColor != onColor;
}

class _GroupGlyphPainter extends CustomPainter {
  final Color color;
  _GroupGlyphPainter({required this.color});

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
    // Two heads + shoulders
    canvas.drawCircle(const Offset(9, 8), 3, stroke);
    canvas.drawCircle(const Offset(16, 10), 2.4, stroke);
    final shoulders1 = Path()
      ..moveTo(3, 19)
      ..cubicTo(3, 15.5, 5.7, 13, 9, 13)
      ..cubicTo(12.3, 13, 15, 15.5, 15, 19);
    canvas.drawPath(shoulders1, stroke);
    final shoulders2 = Path()
      ..moveTo(15, 19)
      ..cubicTo(15, 16.5, 17.2, 14.5, 19, 14.5)
      ..cubicTo(20, 14.5, 20.5, 14.7, 21, 15);
    canvas.drawPath(shoulders2, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GroupGlyphPainter old) => old.color != color;
}

class _QrShareGlyphPainter extends CustomPainter {
  final Color color;
  _QrShareGlyphPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    void cornerSq(double x, double y) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, y, 6, 6), const Radius.circular(1)), stroke);
      canvas.drawRect(Rect.fromLTWH(x + 2, y + 2, 2, 2), fill);
    }

    cornerSq(3, 3);
    cornerSq(15, 3);
    cornerSq(3, 15);
    // Scattered dots
    canvas.drawRect(const Rect.fromLTWH(15, 15, 2, 2), fill);
    canvas.drawRect(const Rect.fromLTWH(19, 15, 2, 2), fill);
    canvas.drawRect(const Rect.fromLTWH(15, 19, 2, 2), fill);
    canvas.drawRect(const Rect.fromLTWH(19, 19, 2, 2), fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QrShareGlyphPainter old) => old.color != color;
}

class _QrScanGlyphPainter extends CustomPainter {
  final Color color;
  _QrScanGlyphPainter({required this.color});

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
    // Viewfinder brackets
    final tl = Path()
      ..moveTo(3, 8)
      ..lineTo(3, 4)
      ..lineTo(8, 4);
    canvas.drawPath(tl, stroke);
    final tr = Path()
      ..moveTo(16, 4)
      ..lineTo(21, 4)
      ..lineTo(21, 8);
    canvas.drawPath(tr, stroke);
    final br = Path()
      ..moveTo(21, 16)
      ..lineTo(21, 20)
      ..lineTo(16, 20);
    canvas.drawPath(br, stroke);
    final bl = Path()
      ..moveTo(8, 20)
      ..lineTo(3, 20)
      ..lineTo(3, 16);
    canvas.drawPath(bl, stroke);
    // Scan line
    canvas.drawLine(const Offset(5, 12), const Offset(19, 12), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_QrScanGlyphPainter old) => old.color != color;
}
