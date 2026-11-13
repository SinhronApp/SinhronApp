// Contact info / profile screen. Per design/app/contact-info.jsx + spec §6.4.
//
// One of the few places where E2EE BECOMES VISIBLE (per README cross-cutting
// #1): the Identity section surfaces the verified badge, fingerprint preview
// and linked-device count. Everywhere else the encryption stays quiet.
//
// The profile is [ContactProfileView] (ADR-052), filled by ContactProfileScreen
// with only what this device knows: their photo (tap → full screen), name,
// key, presence, bio, Message / Call / Video, safety number, media, groups
// in common, favourite, add / remove contact, block.

import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_action_button.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_verified_badge.dart';
import '../../l10n/l10n.dart';

/// A group we are both in (real profile).
class ContactCommonGroup {
  const ContactCommonGroup({required this.chatId, required this.name, this.members = 0});
  final String chatId;
  final String name;
  final int members;
}

/// The real contact profile (ADR-052): only what this device knows. Every
/// action is a callback; null hides what can't be done (no chat yet → no
/// call, no safety number, no media).
class ContactProfileView extends StatelessWidget {
  const ContactProfileView({
    super.key,
    required this.name,
    required this.keyLabel,
    this.status = '',
    this.online = false,
    this.photo,
    this.bio = '',
    this.verified = false,
    this.isContact = true,
    this.favourite = false,
    this.blocked = false,
    this.commonGroups = const [],
    this.onBack,
    this.onPhoto,
    this.onMessage,
    this.onCall,
    this.onVideo,
    this.onSafetyNumber,
    this.onSharedMedia,
    this.onOpenGroup,
    this.onEditName,
    this.onShare,
    this.onToggleContact,
    this.onToggleFavourite,
    this.onToggleBlock,
  });

  final String name;

  /// Their key's start ("ab12 cd34").
  final String keyLabel;

  /// Presence ("online", "last seen …"), '' when unknown.
  final String status;
  final bool online;
  final Uint8List? photo;

  /// What they wrote about themselves ('' = nothing shared).
  final String bio;
  final bool verified;
  final bool isContact;
  final bool favourite;
  final bool blocked;
  final List<ContactCommonGroup> commonGroups;
  final VoidCallback? onBack;
  final VoidCallback? onPhoto;
  final VoidCallback? onMessage;
  final VoidCallback? onCall;
  final VoidCallback? onVideo;
  final VoidCallback? onSafetyNumber;
  final VoidCallback? onSharedMedia;
  final ValueChanged<String>? onOpenGroup;
  /// "Edit name" — my own name for them (only I see it).
  final VoidCallback? onEditName;

  /// "Share contact": send their card into a chat (owner, 2026-11-03).
  final VoidCallback? onShare;
  final VoidCallback? onToggleContact;
  final VoidCallback? onToggleFavourite;
  final VoidCallback? onToggleBlock;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final l = context.l10n;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.only(top: mq.padding.top + DsSpace.x1h5, bottom: mq.padding.bottom + DsSpace.x6),
              children: [
                _Hero(
                  name: name,
                  username: keyLabel,
                  status: status,
                  online: online,
                  photo: photo,
                  onPhoto: photo == null ? null : onPhoto,
                  verified: verified,
                ),
                _ActionTiles(onMessage: onMessage, onCall: onCall, onVideo: onVideo),
                if (bio.isNotEmpty)
                  _Section(
                    label: l.contactAbout,
                    first: true,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(DsSpace.x5, DsSpace.x3h5, DsSpace.x5, DsSpace.x3h5),
                        child: Text(
                          bio,
                          key: const ValueKey('profile-bio'),
                          style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w400, color: tokens.text),
                        ),
                      ),
                    ],
                  ),
                _Section(
                  label: l.contactIdentity,
                  first: bio.isEmpty,
                  children: [
                    _Row(
                      key: const ValueKey('profile-safety'),
                      icon: _ContactIcon.shieldCheck,
                      label: verified ? l.contactIdentityVerified : l.safetyNumberTitle,
                      subtitle: '${l.contactKey} · $keyLabel',
                      trailing: onSafetyNumber == null ? null : const _Chevron(),
                      onTap: onSafetyNumber,
                    ),
                    if (onSharedMedia != null)
                      _Row(
                        key: const ValueKey('profile-media'),
                        icon: _ContactIcon.photo,
                        label: l.contactMediaLinksDocs,
                        trailing: const _Chevron(),
                        onTap: onSharedMedia,
                      ),
                  ],
                ),
                if (commonGroups.isNotEmpty)
                  _GroupsInCommon(
                    groups: [
                      for (final g in commonGroups)
                        _CommonGroup(
                          name: g.name,
                          members: g.members,
                          onTap: onOpenGroup == null ? null : () => onOpenGroup!(g.chatId),
                        ),
                    ],
                  ),
                _Section(
                  children: [
                    if (onEditName != null)
                      _Row.customLeading(
                        key: const ValueKey('profile-edit-name'),
                        customIcon: const _GlyphTile(CupertinoIcons.pencil),
                        label: l.contactEditName,
                        onTap: onEditName,
                      ),
                    if (onShare != null)
                      _Row(
                        key: const ValueKey('profile-share'),
                        icon: _ContactIcon.at,
                        glyph: CupertinoIcons.share,
                        label: l.shareContact,
                        onTap: onShare,
                      ),
                    if (isContact && onToggleFavourite != null)
                      _Row(
                        key: const ValueKey('profile-favourite'),
                        icon: _ContactIcon.star,
                        label: favourite ? l.contactFavouriteRemove : l.contactFavouriteAdd,
                        onTap: onToggleFavourite,
                      ),
                    if (onToggleContact != null)
                      _Row(
                        key: const ValueKey('profile-contact'),
                        icon: _ContactIcon.at,
                        glyph: isContact ? CupertinoIcons.person_badge_minus : CupertinoIcons.person_badge_plus,
                        label: isContact ? l.contactRemove : l.contactAdd,
                        danger: isContact,
                        onTap: onToggleContact,
                      ),
                    if (onToggleBlock != null)
                      _Row(
                        key: const ValueKey('profile-block'),
                        icon: _ContactIcon.block,
                        label: blocked ? l.blockedUnblock : l.chatInfoBlock,
                        danger: !blocked,
                        onTap: onToggleBlock,
                      ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: mq.padding.top,
            child: _FloatingTopBar(onBack: onBack, showMore: false),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Top bar (back + ⋯ overflow), floats over hero
// ═════════════════════════════════════════════════════════════════════

class _FloatingTopBar extends StatelessWidget {
  final VoidCallback? onBack;

  /// The gallery's "more" dots (nothing behind them — the real profile
  /// has none).
  final bool showMore;
  const _FloatingTopBar({this.onBack, this.showMore = true});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.x1h5, DsSpace.x2h5, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _RoundChromeButton(
            size: 36,
            onTap: onBack,
            label: context.l10n.a11yBack,
            child: SizedBox(
              width: 22,
              height: 22,
              child: CustomPaint(painter: _BackPainter(color: tokens.text)),
            ),
          ),
          // Design sample: nothing behind "more" yet — not announced as a
          // button that does nothing.
          if (showMore)
          _RoundChromeButton(
            size: 36,
            child: SizedBox(
              width: 20,
              height: 20,
              child: CustomPaint(painter: _OverflowDotsPainter(color: tokens.text)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundChromeButton extends StatelessWidget {
  final double size;
  final Widget child;
  final VoidCallback? onTap;

  /// What VoiceOver says ("Back").
  final String? label;
  const _RoundChromeButton({required this.size, required this.child, this.onTap, this.label});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: label,
      excludeSemantics: label != null,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: child),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero (large avatar + name + username + status)
// ═════════════════════════════════════════════════════════════════════

class _Hero extends StatelessWidget {
  final String name;
  final String username;
  final String status;
  final bool online;

  /// Real profile: their photo (tap → [onPhoto]) and the verified seal.
  final Uint8List? photo;
  final VoidCallback? onPhoto;
  final bool verified;

  const _Hero({
    required this.name,
    required this.username,
    required this.status,
    required this.online,
    this.photo,
    this.onPhoto,
    this.verified = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final statusColor = online ? tokens.success : tokens.text3;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x5, DsSpace.x6, DsSpace.x6),
      child: Column(
        children: [
          Semantics(
            button: onPhoto != null,
            label: onPhoto != null ? context.l10n.a11yOpenPhoto : null,
            child: DsPressable(
              key: const ValueKey('profile-avatar'),
              onTap: onPhoto,
              scale: 0.96,
              child: DsAvatar(name: name.isEmpty ? '?' : name, size: 120, image: photo),
            ),
          ),
          const SizedBox(height: 18),
          Text.rich(
            TextSpan(
              text: name,
              children: [
                if (verified)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(left: DsSpace.x1h5),
                      child: DsVerifiedBadge(
                        key: const ValueKey('profile-verified'),
                        size: 20,
                        semanticLabel: context.l10n.verifiedTitle,
                      ),
                    ),
                  ),
              ],
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DsText.title1.copyWith(fontWeight: FontWeight.w700, color: tokens.text),
          ),
          const SizedBox(height: 3),
          Text(username, style: DsTextArt.t14w500Mono.copyWith(color: tokens.text2)),
          if (status.isNotEmpty) const SizedBox(height: 6),
          if (status.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (online) ...[
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: tokens.success, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                status,
                style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: statusColor),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// 3 action tiles (Message / Call / Video) — gap-spaced, no wrapping card
// ═════════════════════════════════════════════════════════════════════

class _ActionTiles extends StatelessWidget {
  /// Only the tiles that do something (no call without a chat).
  const _ActionTiles({this.onMessage, this.onCall, this.onVideo});

  final VoidCallback? onMessage;
  final VoidCallback? onCall;
  final VoidCallback? onVideo;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    // Bold, Signal-sized glyphs on flat tiles (owner, 2026-10-20).
    Widget glyph(_ContactIcon icon) => CustomPaint(
      painter: _ContactIconPainter(shape: icon, color: tokens.accent, strokeWidth: kActionIconStroke),
    );
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, 0, DsSpace.x4, DsSpace.x6),
      child: DsActionRow(
        children: [
          if (onMessage != null)
            DsActionButton(
              key: const ValueKey('profile-message'),
              label: l.contactMessage,
              icon: glyph(_ContactIcon.chats),
              onTap: onMessage,
            ),
          if (onCall != null)
            DsActionButton(
              key: const ValueKey('profile-call'),
              label: l.call,
              icon: glyph(_ContactIcon.phone),
              onTap: onCall,
            ),
          if (onVideo != null)
            DsActionButton(
              key: const ValueKey('profile-video'),
              label: l.video,
              icon: glyph(_ContactIcon.video),
              onTap: onVideo,
            ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Section (rounded surface card with optional label/footer)
// ═════════════════════════════════════════════════════════════════════

class _Section extends StatelessWidget {
  final String? label;
  final bool first;
  final List<Widget> children;

  const _Section({this.label, this.first = false, required this.children});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: first ? DsSpace.x1 : DsSpace.x6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x2h5),
              child: Text(
                label!.toUpperCase(),
                style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(tokens.radiusCard)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Row (icon + label/subtitle + value + trailing)
// ═════════════════════════════════════════════════════════════════════

/// A [_Row] tile with a Cupertino glyph (for icons the painter lacks).
class _GlyphTile extends StatelessWidget {
  const _GlyphTile(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      width: 38,
      height: 38,
      child: Icon(icon, size: 23, color: tokens.text2),
    );
  }
}

class _Row extends StatelessWidget {
  final _ContactIcon icon;

  /// A system glyph instead of a drawn [icon].
  final IconData? glyph;
  final Widget? customIcon; // set only by [_Row.customLeading]
  final String label;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final bool danger;
  final VoidCallback? onTap;

  const _Row({
    super.key,
    required this.icon,
    this.glyph,
    required this.label,
    this.subtitle,
    this.trailing,
    this.danger = false,
    this.onTap,
  }) : customIcon = null,
       value = null;

  const _Row.customLeading({
    super.key,
    required Widget this.customIcon,
    required this.label,
    this.value,
    this.trailing,
    this.onTap,
  }) : icon = _ContactIcon.at,
       glyph = null,
       subtitle = null,
       danger = false;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    // The calm look: plain grey icons, no colour tile; only "danger" keeps its colour.
    final iconColor = danger ? tokens.danger : tokens.text2;
    final labelColor = danger ? tokens.danger : tokens.text;

    final leading =
        customIcon ??
        SizedBox(
          width: 38,
          height: 38,
          child: Center(
            child: glyph != null
                ? Icon(glyph, size: 23, color: iconColor)
                : SizedBox(
                    width: 23,
                    height: 23,
                    child: CustomPaint(
                      painter: _ContactIconPainter(shape: icon, color: iconColor, strokeWidth: 2.1),
                    ),
                  ),
          ),
        );

    final row = Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.nudge13, DsSpace.x5, DsSpace.nudge13),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.bodyLarge.copyWith(color: labelColor),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsTextArt.t13w500Mono.copyWith(color: tokens.text3),
                  ),
                ],
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 10),
            Text(
              value!,
              style: DsTextArt.t15w500v1.copyWith(color: tokens.text3),
            ),
          ],
          ?trailing,
        ],
      ),
    );

    // One VoiceOver element per row: label, value and its switch together.
    final content = MergeSemantics(
      child: DsPressable(onTap: onTap, scale: 1, pressedColor: tokens.bgSoft, child: row),
    );

    // No line between rows (the calm look).
    return content;
  }
}

class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: DsSpace.x1h5),
      child: SizedBox(
        width: 9,
        height: 16,
        child: CustomPaint(painter: DsGlyphPainter(DsGlyph.chevron, color: tokens.text4)),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Media row card (thumbnails strip + summary row)
// ═════════════════════════════════════════════════════════════════════

// ═════════════════════════════════════════════════════════════════════
// Groups in common — section with rows that use group avatars as leading
// ═════════════════════════════════════════════════════════════════════

class _CommonGroup {
  final String name;
  final int members;
  final VoidCallback? onTap;
  const _CommonGroup({required this.name, required this.members, this.onTap});
}

class _GroupsInCommon extends StatelessWidget {
  final List<_CommonGroup> groups;
  const _GroupsInCommon({required this.groups});

  @override
  Widget build(BuildContext context) {
    return _Section(
      label: context.l10n.contactGroupsInCommon(groups.length),
      children: [
        for (var i = 0; i < groups.length; i++)
          _Row.customLeading(
            customIcon: DsAvatar(name: groups[i].name, size: 36, group: true),
            label: groups[i].name,
            value: groups[i].members > 0 ? context.l10n.contactGroupMembers(groups[i].members) : null,
            trailing: const _Chevron(),
            onTap: groups[i].onTap,
          ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Icon enum + painter
// ═════════════════════════════════════════════════════════════════════

enum _ContactIcon {
  chats,
  phone,
  video,
  at,
  shieldCheck,
  star,
  block,
  photo,
}

class _ContactIconPainter extends CustomPainter {
  final _ContactIcon shape;
  final Color color;
  final double strokeWidth;
  _ContactIconPainter({required this.shape, required this.color, this.strokeWidth = 2});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (shape) {
      case _ContactIcon.chats:
        final p = Path()
          ..moveTo(4, 6.5)
          ..cubicTo(4, 5.12, 5.12, 4, 6.5, 4)
          ..lineTo(17.5, 4)
          ..cubicTo(18.88, 4, 20, 5.12, 20, 6.5)
          ..lineTo(20, 14.5)
          ..cubicTo(20, 15.88, 18.88, 17, 17.5, 17)
          ..lineTo(10, 17)
          ..lineTo(6, 20.5)
          ..lineTo(6, 17)
          ..lineTo(6.5, 17)
          ..cubicTo(5.12, 17, 4, 15.88, 4, 14.5)
          ..close();
        canvas.drawPath(p, stroke);
      case _ContactIcon.phone:
        final p = Path()
          ..moveTo(22, 16.92)
          ..lineTo(22, 19.92)
          ..arcToPoint(const Offset(19.82, 21.92), radius: const Radius.circular(2))
          ..arcToPoint(const Offset(11.19, 18.85), radius: const Radius.circular(19.79))
          ..arcToPoint(const Offset(5.19, 12.85), radius: const Radius.circular(19.5))
          ..arcToPoint(const Offset(2.12, 4.18), radius: const Radius.circular(19.79))
          ..arcToPoint(const Offset(4.11, 2), radius: const Radius.circular(2))
          ..lineTo(7.11, 2)
          ..arcToPoint(const Offset(9.11, 3.72), radius: const Radius.circular(2))
          ..cubicTo(9.24, 4.68, 9.47, 5.62, 9.81, 6.53)
          ..arcToPoint(const Offset(9.36, 8.64), radius: const Radius.circular(2))
          ..lineTo(8.09, 9.91)
          ..arcToPoint(const Offset(14.09, 15.91), radius: const Radius.circular(16), clockwise: false)
          ..lineTo(15.36, 14.64)
          ..arcToPoint(const Offset(17.47, 14.19), radius: const Radius.circular(2))
          ..cubicTo(18.38, 14.53, 19.32, 14.76, 20.28, 14.89)
          ..arcToPoint(const Offset(22, 16.92), radius: const Radius.circular(2))
          ..close();
        canvas.drawPath(p, stroke);
      case _ContactIcon.video:
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(2.5, 6, 13, 12), const Radius.circular(2.5)),
          stroke,
        );
        final wedge = Path()
          ..moveTo(15.5, 10)
          ..lineTo(20.5, 7.5)
          ..lineTo(20.5, 16.5)
          ..lineTo(15.5, 14)
          ..close();
        canvas.drawPath(wedge, stroke);
      case _ContactIcon.at:
        // Lucide "at-sign" — inner circle = the "a", outer path = ring + tail.
        // Both arcs are counterclockwise (sweep=0 in SVG).
        canvas.drawCircle(const Offset(12, 12), 4, stroke);
        final p = Path()
          ..moveTo(16, 12)
          ..lineTo(16, 13.5)
          ..arcToPoint(const Offset(21, 13.5), radius: const Radius.circular(2.5), clockwise: false)
          ..lineTo(21, 12)
          ..arcToPoint(const Offset(17.5, 19.1), radius: const Radius.circular(9), largeArc: true, clockwise: false);
        canvas.drawPath(p, stroke);
      case _ContactIcon.shieldCheck:
        final p = Path()
          ..moveTo(12, 2)
          ..lineTo(20, 6)
          ..lineTo(20, 12)
          ..cubicTo(20, 17, 16.5, 21, 12, 22)
          ..cubicTo(7.5, 21, 4, 17, 4, 12)
          ..lineTo(4, 6)
          ..close();
        canvas.drawPath(p, stroke);
        final tick = Path()
          ..moveTo(8.5, 12)
          ..lineTo(11, 14.5)
          ..lineTo(16, 9.5);
        canvas.drawPath(tick, stroke);
      case _ContactIcon.star:
        final p = Path()
          ..moveTo(12, 3.5)
          ..lineTo(14.7, 9)
          ..lineTo(20.7, 9.8)
          ..lineTo(16.3, 14)
          ..lineTo(17.4, 20)
          ..lineTo(12, 17.2)
          ..lineTo(6.6, 20)
          ..lineTo(7.7, 14)
          ..lineTo(3.3, 9.8)
          ..lineTo(9.3, 9)
          ..close();
        canvas.drawPath(p, stroke);
      case _ContactIcon.block:
        canvas.drawCircle(const Offset(12, 12), 9, stroke);
        canvas.drawLine(const Offset(5.5, 5.5), const Offset(18.5, 18.5), stroke);
      case _ContactIcon.photo:
        canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(3, 5, 18, 14), const Radius.circular(2)), stroke);
        canvas.drawCircle(const Offset(9, 11), 2, stroke);
        final p = Path()
          ..moveTo(3, 17)
          ..lineTo(8, 13)
          ..lineTo(12, 16)
          ..lineTo(15, 14)
          ..lineTo(21, 19);
        canvas.drawPath(p, stroke);
    }
    canvas.restore();
    // ignore: dead_code
    fill;
  }

  @override
  bool shouldRepaint(_ContactIconPainter old) =>
      old.shape != shape || old.color != color || old.strokeWidth != strokeWidth;
}

// ═════════════════════════════════════════════════════════════════════
// Chrome icon painters
// ═════════════════════════════════════════════════════════════════════

class _BackPainter extends CustomPainter {
  final Color color;
  _BackPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(15, 5)
      ..lineTo(8, 12)
      ..lineTo(15, 19);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BackPainter old) => old.color != color;
}

class _OverflowDotsPainter extends CustomPainter {
  final Color color;
  _OverflowDotsPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(const Offset(5, 12), 1.8, fill);
    canvas.drawCircle(const Offset(12, 12), 1.8, fill);
    canvas.drawCircle(const Offset(19, 12), 1.8, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OverflowDotsPainter old) => old.color != color;
}
