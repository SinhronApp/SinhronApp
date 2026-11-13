// Blocked contacts — reached from Privacy & security → "Blocked contacts".
//
// Per spec §6.4 (Contacts) + §13.3 (User control), the block list is local
// state — the server isn't told who you've blocked. Outbound messages from
// blocked senders are silently dropped on the receiving device after the
// MLS unwrap step. The receiver never knows their MLS message was rejected.
//
// The list from this device's storage — names from people's own
// profiles, unblock removes the entry (tech-debt 2.27); none → a large
// glyph + explanation.
//
// The list lives under one card so the row-pressed feedback matches the
// Settings/Contact-info pattern (single rounded surface, internal dividers).

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_notice.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/message_actions.dart';
import '../../core/providers/people.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_icon.dart';
import '../../l10n/l10n.dart';

class BlockedContactsScreen extends ConsumerWidget {
  final VoidCallback? onBack;

  const BlockedContactsScreen({super.key, this.onBack});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
    final blocked = [
      for (final id in ref.watch(blockedPeersProvider).value ?? const <String>{})
        _Blocked(
          name: names[id] ?? context.l10n.blockedUnnamed,
          username: shortKey(id),
          peerId: id,
          photo: peerAvatarOf(ref, id),
        ),
    ];
    final failed = context.l10n.groupActionFailed;
    void unblock(_Blocked b) =>
        ref.read(peopleProvider).setBlocked(b.peerId, false).catchError((Object _) => appNotice.value = failed);
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
                padding: const EdgeInsets.fromLTRB(0, DsSpace.x1, 0, DsSpace.x6),
                children: blocked.isEmpty
                    ? [const _EmptyState()]
                    : [
                        _ListSection(blocked: blocked, onUnblock: unblock),
                        const SizedBox(height: 24),
                        const _WhatBlockingDoes(),
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
                  context.l10n.blockedTitle,
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
// List section
// ═════════════════════════════════════════════════════════════════════

class _Blocked {
  final String name;
  final String username; // short key
  final String peerId; // identity key (hex)
  final Uint8List? photo;
  const _Blocked({required this.name, required this.username, required this.peerId, this.photo});
}

class _ListSection extends StatelessWidget {
  final List<_Blocked> blocked;
  final void Function(_Blocked) onUnblock;
  const _ListSection({required this.blocked, required this.onUnblock});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x2h5),
          child: Text(
            context.l10n.blockedCount(blocked.length).toUpperCase(),
            style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              border: Border.all(color: tokens.divider, width: 0.5),
              boxShadow: DsShadow.card,
            ),
            child: Column(
              children: [
                for (var i = 0; i < blocked.length; i++)
                  _Row(blocked: blocked[i], isLast: i == blocked.length - 1, onUnblock: () => onUnblock(blocked[i])),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  final _Blocked blocked;
  final bool isLast;
  final VoidCallback onUnblock;
  const _Row({required this.blocked, required this.isLast, required this.onUnblock});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.nudge11, DsSpace.x3, DsSpace.nudge11),
          child: Row(
            children: [
              // Dimmed avatar. (A "lighten" colour filter here washed out the
              // whole card: it also paints where the avatar is not.)
              Opacity(
                opacity: 0.6,
                child: DsAvatar(name: blocked.name, size: 42, image: blocked.photo),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      blocked.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            blocked.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DsTextArt.t12w500Monov2.copyWith(color: tokens.text3),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _UnblockPill(onTap: onUnblock),
            ],
          ),
        ),
        if (!isLast) Positioned(left: 68, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

class _UnblockPill extends StatelessWidget {
  final VoidCallback onTap;
  const _UnblockPill({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.nudge11, DsSpace.nudge7, DsSpace.nudge11, DsSpace.nudge7),
        decoration: BoxDecoration(
          color: tokens.bgSoft,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tokens.divider, width: 0.5),
        ),
        child: Text(
          context.l10n.blockedUnblock,
          style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.text),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// What blocking does — info section
// ═════════════════════════════════════════════════════════════════════

class _WhatBlockingDoes extends StatelessWidget {
  const _WhatBlockingDoes();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x2h5),
          child: Text(
            context.l10n.blockedWhatItDoes.toUpperCase(),
            style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
          child: Container(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x4, DsSpace.x4h5, DsSpace.x4),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(tokens.radiusCard),
              border: Border.all(color: tokens.divider, width: 0.5),
              boxShadow: DsShadow.card,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Bullet(glyph: _InfoGlyph.eye, text: context.l10n.blockedNoPresence),
                _Bullet(glyph: _InfoGlyph.ban, text: context.l10n.blockedMessagesDiscarded),
                _Bullet(glyph: _InfoGlyph.phoneOff, text: context.l10n.blockedCallsRejected),
                _Bullet(glyph: _InfoGlyph.group, text: context.l10n.blockedNoGroups, isLast: true),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
          child: Text(context.l10n.blockedLocalFooter, style: DsText.footnote.copyWith(color: tokens.text3)),
        ),
      ],
    );
  }
}

enum _InfoGlyph { eye, ban, phoneOff, group }

class _Bullet extends StatelessWidget {
  final _InfoGlyph glyph;
  final String text;
  final bool isLast;
  const _Bullet({required this.glyph, required this.text, this.isLast = false});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : DsSpace.x3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            margin: const EdgeInsets.only(top: DsSpace.nudge1),
            decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(8)),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CustomPaint(
                  painter: _BulletGlyphPainter(shape: glyph, color: tokens.text2),
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

class _BulletGlyphPainter extends CustomPainter {
  final _InfoGlyph shape;
  final Color color;
  _BulletGlyphPainter({required this.shape, required this.color});

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

    switch (shape) {
      case _InfoGlyph.eye:
        // eye-off (slashed)
        final p = Path()
          ..moveTo(3, 12)
          ..cubicTo(5, 7, 8.5, 5, 12, 5)
          ..cubicTo(15.5, 5, 19, 7, 21, 12)
          ..moveTo(21, 12)
          ..cubicTo(19, 17, 15.5, 19, 12, 19)
          ..cubicTo(8.5, 19, 5, 17, 3, 12);
        canvas.drawPath(p, stroke);
        canvas.drawCircle(const Offset(12, 12), 2.5, stroke);
        canvas.drawLine(const Offset(4, 4), const Offset(20, 20), stroke);
      case _InfoGlyph.ban:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawLine(const Offset(5.5, 5.5), const Offset(18.5, 18.5), stroke);
      case _InfoGlyph.phoneOff:
        final p = Path()
          ..moveTo(10.7, 13.5)
          ..arcToPoint(const Offset(8.5, 11.3), radius: const Radius.circular(2), clockwise: false)
          ..lineTo(8.5, 8.5)
          ..arcToPoint(const Offset(10.5, 6.5), radius: const Radius.circular(2))
          ..lineTo(13.5, 6.5);
        canvas.drawPath(p, stroke);
        canvas.drawLine(const Offset(4, 4), const Offset(20, 20), stroke);
        // Echo arc representing the call wave
        final wave = Path()
          ..moveTo(15.5, 9)
          ..lineTo(15.5, 13.5)
          ..arcToPoint(const Offset(13.3, 15.5), radius: const Radius.circular(2), clockwise: false)
          ..lineTo(11, 15.5);
        canvas.drawPath(wave, stroke);
      case _InfoGlyph.group:
        // Two-person glyph with no-symbol cross? Simpler: a basic users
        // icon — clear that it's "group".
        canvas.drawCircle(const Offset(9, 8), 3, stroke);
        final shoulders = Path()
          ..moveTo(3, 19)
          ..arcToPoint(const Offset(15, 19), radius: const Radius.circular(6));
        canvas.drawPath(shoulders, stroke);
        canvas.drawCircle(const Offset(17, 9), 2.4, stroke);
        canvas.drawLine(const Offset(15, 19), const Offset(21, 19), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BulletGlyphPainter old) => old.shape != shape || old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Empty state
// ═════════════════════════════════════════════════════════════════════

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x10, DsSpace.x20, DsSpace.x10, DsSpace.x10),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
            child: Center(
              child: SizedBox(
                width: 36,
                height: 36,
                child: CustomPaint(
                  painter: _BulletGlyphPainter(shape: _InfoGlyph.ban, color: tokens.text3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(context.l10n.blockedEmptyTitle, style: DsText.title3.copyWith(color: tokens.text)),
          const SizedBox(height: 8),
          Text(
            context.l10n.blockedEmptyHint,
            textAlign: TextAlign.center,
            style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text3),
          ),
        ],
      ),
    );
  }
}
