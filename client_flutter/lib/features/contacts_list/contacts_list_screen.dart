// Contacts tab — alphabetical contact directory.
//
// No dedicated design file in the handoff (compose.jsx is the new-chat
// picker, not the directory). Built from spec §6.4 + native iOS
// Contacts.app pattern. Sinhron-specific bits:
//   - "MY CARD" at top showing the user's own identity with verified seal
//   - "VERIFIED" section for contacts whose safety number has been confirmed
//     (separates trusted from merely known)
//
// [ContactsListScreen.contacts] — ADR-052: my contacts
// are a list of their own (stored on this device; deleting a chat keeps the
// person) — and [ContactsListScreen.me]: my card, "Invite friends", then the
// starred people (Favourites), the people whose safety number I confirmed
// (Verified), everyone A–Я with a letter rail that jumps; search by name or
// key. A tap opens their profile (message / call / video, bio, key, common
// groups), the phone calls when there is a chat to call in.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/adaptive.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_header.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_tab_bar.dart';
import '../../core/providers/people.dart' show ContactRecord, shortKey;
import '../chat_list/chat_data.dart' show ChatPreview;
import '../../l10n/l10n.dart';
import '../../widgets/ds_search_pill.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../../widgets/ds_verified_badge.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_pressable.dart';
import '../../app/theme/motion.dart';

/// A person in my contacts (ADR-052), with our personal chat if there is one.
class ContactEntry {
  /// Our accepted personal chat — null when there is none (deleted, or
  /// never started): writing to them starts one.
  final String? chatId;

  /// Identity key, lower-case hex.
  final String peerId;
  final String name;
  final bool favourite;
  const ContactEntry({this.chatId, required this.peerId, required this.name, this.favourite = false});
}

/// My own card: name, short key, server.
class MyContactCard {
  final String name;
  final String keyLabel;
  final String server;

  /// My photo, if I set one.
  final Uint8List? photo;
  const MyContactCard({required this.name, required this.keyLabel, required this.server, this.photo});
}

/// My contacts (ADR-052) for the screens: each with the name they chose
/// (else the name I first knew them by, else our chat's name, else a short
/// key) and our accepted personal chat, if any. Sorted by name.
List<ContactEntry> contactEntries(List<ContactRecord> contacts, List<ChatPreview> chats, Map<String, String> names) {
  final chatOf = <String, ChatPreview>{};
  for (final c in chats) {
    final peer = c.peerId?.toLowerCase();
    if (c.group || c.request || peer == null || peer.isEmpty || c.id == null) continue;
    chatOf.putIfAbsent(peer, () => c);
  }
  final seen = <String>{};
  final out = <ContactEntry>[];
  for (final r in contacts) {
    final peer = r.peerId.toLowerCase();
    if (peer.isEmpty || !seen.add(peer)) continue;
    final chat = chatOf[peer];
    final name = names[peer] ?? names[r.peerId] ?? (r.name.isNotEmpty ? r.name : chat?.name ?? shortKey(peer));
    out.add(ContactEntry(chatId: chat?.id, peerId: peer, name: name, favourite: r.favourite));
  }
  return out..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

class ContactsListScreen extends StatelessWidget {
  final ValueChanged<DsTabId>? onTabChange;

  /// My contacts.
  final List<ContactEntry> contacts;

  /// My card (real mode).
  final MyContactCard? me;

  /// Unread chats for the Chats tab badge.
  final int unreadChats;

  /// Open a contact's profile (real mode).
  final ValueChanged<ContactEntry>? onOpen;

  /// The phone on a row: call them (real mode; rows without a chat show none).
  final ValueChanged<ContactEntry>? onCall;

  /// "Invite friends" — share my invite link (real mode).
  final VoidCallback? onInvite;

  /// Identity keys (lower-case hex) whose safety number I confirmed — their
  /// own section and a seal (real mode).
  final Set<String> verifiedPeers;

  /// Identity key (lower-case hex) → their photo (real mode).
  final Map<String, Uint8List> photos;

  /// My card → my QR code; the + → New chat (real mode).
  final VoidCallback? onMyCard;
  final VoidCallback? onAdd;

  /// My photo at the top-left → My profile.
  final VoidCallback? onProfile;

  const ContactsListScreen({
    super.key,
    this.onTabChange,
    required this.contacts,
    this.me,
    this.unreadChats = 0,
    this.onOpen,
    this.onCall,
    this.onInvite,
    this.verifiedPeers = const {},
    this.photos = const {},
    this.onMyCard,
    this.onAdd,
    this.onProfile,
  });

  @override
  Widget build(BuildContext context) => _RealContacts(screen: this, people: contacts);
}

/// Contacts whose name or key matches [query] (case-insensitive; a key by
/// its start, as `shortKey` shows it, or anywhere in the hex).
List<ContactEntry> contactsMatching(List<ContactEntry> people, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return people;
  final hex = q.replaceAll(RegExp(r'[\s·:]'), '');
  return [
    for (final c in people)
      if (c.name.toLowerCase().contains(q) || (hex.length >= 2 && c.peerId.toLowerCase().contains(hex))) c,
  ];
}

/// The letter a contact is filed under: its first character, upper case;
/// `#` for no name or a name that doesn't start with a letter.
String contactLetter(String name) {
  if (name.isEmpty) return '#';
  final f = name.characters.first.toUpperCase();
  return f.toLowerCase() != f ? f : '#';
}

/// From this many contacts on, the letter rail shows.
const kContactsRailMin = 15;

/// The real Contacts tab (tech-debt 2.34, ADR-052): search, invite, the
/// starred people, the people whose safety number I confirmed, everyone A–Я
/// with a letter rail that jumps.
class _RealContacts extends StatefulWidget {
  const _RealContacts({required this.screen, required this.people});
  final ContactsListScreen screen;
  final List<ContactEntry> people;

  @override
  State<_RealContacts> createState() => _RealContactsState();
}

class _RealContactsState extends State<_RealContacts> {
  final _query = TextEditingController();
  final _letterKeys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _jump(String letter) {
    final ctx = _letterKeys[letter]?.currentContext;
    if (ctx != null) Scrollable.ensureVisible(ctx, duration: DsMotion.of(context, DsMotion.fast));
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.screen;
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final l = context.l10n;
    final me = w.me ?? MyContactCard(name: l.you, keyLabel: '', server: '');
    final searching = _query.text.trim().isNotEmpty;
    // Sorted here too: sections follow the list's order.
    final shown = [...contactsMatching(widget.people, _query.text)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final favourites = searching ? const <ContactEntry>[] : [
      for (final c in shown)
        if (c.favourite) c,
    ];
    final verified = searching ? const <ContactEntry>[] : [
      for (final c in shown)
        if (w.verifiedPeers.contains(c.peerId.toLowerCase())) c,
    ];
    final sections = <String, List<ContactEntry>>{};
    for (final c in shown) {
      sections.putIfAbsent(contactLetter(c.name), () => []).add(c);
    }
    for (final k in sections.keys) {
      _letterKeys.putIfAbsent(k, GlobalKey.new);
    }
    Widget row(ContactEntry c, {required bool isLast, bool seal = false, String prefix = 'contact'}) => _ContactRow(
      key: ValueKey('$prefix-${c.peerId}'),
      contact: _Contact(name: c.name, subtitle: shortKey(c.peerId), photo: w.photos[c.peerId.toLowerCase()]),
      isLast: isLast,
      showSeal: seal || w.verifiedPeers.contains(c.peerId.toLowerCase()),
      starred: c.favourite,
      onTap: w.onOpen == null ? null : () => w.onOpen!(c),
      // ADR-076 — their profile is open beside the list (iPad).
      selected: AdaptiveSplit.selectedOf(context) == c.peerId,
      // Real rows: a phone only where there is a chat to call in.
      onCall: c.chatId == null || w.onCall == null ? null : () => w.onCall!(c),
      showPhone: c.chatId != null && w.onCall != null,
    );
    final children = <Widget>[
      _Header(name: me.name, photo: me.photo, onAdd: w.onAdd, onProfile: w.onProfile),
      if (widget.people.isNotEmpty)
        DsSearchPill(key: const ValueKey('contacts-search'), controller: _query, hint: l.searchContacts),
      if (!searching) ...[
        DsPressable(
          scale: 0.985,
          onTap: w.onMyCard,
          child: _MyCard(
            name: me.name,
            subtitle: [me.keyLabel, me.server].where((x) => x.isNotEmpty).join(' · '),
            photo: me.photo,
          ),
        ),
        if (w.onInvite != null) _InviteRow(onTap: w.onInvite!),
        const SizedBox(height: 18),
      ],
      if (widget.people.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x4, DsSpace.x6, 0),
          child: Text(l.contactsEmpty, textAlign: TextAlign.center, style: DsText.callout.copyWith(color: tokens.text3)),
        )
      else if (shown.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x4, DsSpace.x6, 0),
          child: Text(l.noResults(_query.text.trim()), textAlign: TextAlign.center, style: DsText.callout.copyWith(color: tokens.text3)),
        )
      else ...[
        if (favourites.isNotEmpty) ...[
          _SectionLabel(l.contactsFavourites.toUpperCase()),
          for (var i = 0; i < favourites.length; i++)
            row(favourites[i], isLast: i == favourites.length - 1, prefix: 'favourite'),
          const SizedBox(height: 18),
        ],
        if (verified.isNotEmpty) ...[
          _SectionLabel(l.contactsVerified.toUpperCase()),
          for (var i = 0; i < verified.length; i++)
            row(verified[i], isLast: i == verified.length - 1, seal: true, prefix: 'verified'),
          const SizedBox(height: 18),
        ],
        _SectionLabel(l.contactsAllCount(shown.length).toUpperCase()),
        for (final e in sections.entries) ...[
          _LetterHeader(key: _letterKeys[e.key], letter: e.key),
          for (var i = 0; i < e.value.length; i++) row(e.value[i], isLast: i == e.value.length - 1),
        ],
      ],
      const SizedBox(height: 18),
    ];
    final letters = sections.keys.toList();
    // The rail is for long lists; on a short one it sat on the call buttons
    // (2026-10-16 UI audit). With it, rows keep clear of it.
    final rail = !searching && letters.length > 1 && widget.people.length >= kContactsRailMin;
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top),
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  DsAppearScope(
                    child: ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: EdgeInsets.only(bottom: DsSpace.x2, right: rail ? DsSpace.x4 : 0),
                      children: dsStaggered(children),
                    ),
                  ),
                  if (rail)
                    Positioned(
                      top: 100,
                      bottom: 12,
                      right: 4,
                      child: Center(child: _LetterRail(letters: letters, onPick: _jump)),
                    ),
                ],
              ),
            ),
            DsTabBar(
              active: DsTabId.contacts,
              items: [
                DsTabItem(id: DsTabId.chats, label: l.tabChats, icon: DsIconShape.tabChats, badge: w.unreadChats),
                DsTabItem(id: DsTabId.calls, label: l.tabCalls, icon: DsIconShape.tabCalls),
                DsTabItem(id: DsTabId.contacts, label: l.tabContacts, icon: DsIconShape.tabContacts),
                DsTabItem(id: DsTabId.settings, label: l.tabSettings, icon: DsIconShape.tabSettings),
              ],
              safeBottomPadding: EdgeInsets.only(bottom: mq.padding.bottom),
              onSelect: w.onTabChange,
            ),
          ],
        ),
      ),
    );
  }
}

/// The real letter rail: the letters that have people; a tap (or a drag
/// along it) jumps to that letter.
class _LetterRail extends StatelessWidget {
  const _LetterRail({required this.letters, required this.onPick});
  final List<String> letters;
  final ValueChanged<String> onPick;

  static const double _row = 16;

  void _at(double dy) {
    final i = (dy / _row).floor().clamp(0, letters.length - 1);
    onPick(letters[i]);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      key: const ValueKey('contacts-letter-rail'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _at(d.localPosition.dy),
      onVerticalDragUpdate: (d) => _at(d.localPosition.dy),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in letters)
              SizedBox(
                height: _row,
                child: Center(
                  child: Text(
                    l,
                    style: DsText.micro.copyWith(fontWeight: FontWeight.w700, height: 1.05, color: tokens.accent),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Header
// ═════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final VoidCallback? onAdd;
  final VoidCallback? onProfile;
  const _Header({required this.name, this.photo, this.onAdd, this.onProfile});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1h5, DsSpace.x3, DsSpace.x3),
      child: Row(
        children: [
          DsMyAvatar(name: name, image: photo, onTap: onProfile),
          const SizedBox(width: 12),
          Expanded(
            child: Text(context.l10n.tabContacts, style: DsType.headerTitle.copyWith(color: tokens.text)),
          ),
          DsPressable(
            onTap: onAdd,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CustomPaint(painter: _UserPlusPainter(color: tokens.text)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _UserPlusPainter extends CustomPainter {
  final Color color;
  _UserPlusPainter({required this.color});
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
    canvas.drawCircle(const Offset(10, 8), 4, stroke);
    final shoulders = Path()
      ..moveTo(2, 21)
      ..cubicTo(2.6, 17.2, 5.7, 14.5, 10, 14.5)
      ..cubicTo(13, 14.5, 14.5, 15.5, 16, 17);
    canvas.drawPath(shoulders, stroke);
    // Plus
    canvas.drawLine(const Offset(20, 5), const Offset(20, 11), stroke);
    canvas.drawLine(const Offset(17, 8), const Offset(23, 8), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_UserPlusPainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// Search
// ═════════════════════════════════════════════════════════════════════

// ═════════════════════════════════════════════════════════════════════
// MY CARD
// ═════════════════════════════════════════════════════════════════════

class _MyCard extends StatelessWidget {
  final String name;
  final String subtitle;
  final Uint8List? photo;
  const _MyCard({required this.name, required this.subtitle, this.photo});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x3, DsSpace.x3h5, DsSpace.x3),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          border: Border.all(color: tokens.divider, width: 0.5),
          boxShadow: DsShadow.card,
        ),
        child: Row(
          children: [
            DsAvatar(name: name, size: 52, image: photo),
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
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: DsText.headline.copyWith(color: tokens.text),
                        ),
                      ),
                      const SizedBox(width: 6),
                      const _MeChip(),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsTextArt.t12p5w500Mono.copyWith(color: tokens.text3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 18,
              height: 18,
              child: CustomPaint(painter: DsQrShareGlyphGlyph(color: tokens.text2)),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeChip extends StatelessWidget {
  const _MeChip();
  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x1h5, DsSpace.x0h5, DsSpace.x1h5, DsSpace.x0h5),
      decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(999)),
      child: Text(
        context.l10n.you.toUpperCase(),
        style: DsText.micro.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.accent),
      ),
    );
  }
}

/// "Invite friends" under my card (ADR-052): shares my invite link.
class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return Semantics(
      button: true,
      child: DsPressable(
        key: const ValueKey('contacts-invite'),
        scale: 1,
        pressedColor: tokens.bgSoft,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, 0),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: tokens.accentSoft, shape: BoxShape.circle),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CustomPaint(painter: _UserPlusPainter(color: tokens.accent)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l.contactsInvite, style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.accent)),
                    const SizedBox(height: 2),
                    Text(
                      l.contactsInviteHint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.footnote.copyWith(color: tokens.text3),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Section labels + letter headers
// ═════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x1h5, DsSpace.x6, DsSpace.x2),
      child: Text(
        label,
        style: DsText.caption.copyWith(fontWeight: FontWeight.w700, color: tokens.text3),
      ),
    );
  }
}

class _LetterHeader extends StatelessWidget {
  final String letter;
  const _LetterHeader({super.key, required this.letter});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2h5, DsSpace.x6, DsSpace.x1),
      child: Text(
        letter,
        style: DsText.subhead.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.text2),
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
  final bool starred;
  final bool showSeal;
  final VoidCallback? onTap;

  /// The phone at the end: decorative in the gallery; real rows call (or
  /// show none — [showPhone]).
  final VoidCallback? onCall;
  final bool showPhone;
  final bool selected;
  const _ContactRow({
    super.key,
    required this.contact,
    required this.isLast,
    this.starred = false,
    this.showSeal = false,
    this.onTap,
    this.onCall,
    this.showPhone = true,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return DsPressable(
      scale: 1,
      pressedColor: tokens.bgSoft,
      onTap: onTap,
      child: Stack(
        children: [
          if (selected) Positioned.fill(child: ColoredBox(color: tokens.accentSoft)),
          Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2, DsSpace.x4, DsSpace.x2),
            child: Row(
              children: [
                DsAvatar(name: contact.name, size: 38, image: contact.photo),
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
                          if (showSeal) ...[
                            const SizedBox(width: 5),
                            const DsVerifiedBadge(size: 14),
                          ],
                          if (starred) ...[
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 13,
                              height: 13,
                              child: CustomPaint(painter: _StarPainter(color: DsPalette.orange)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        contact.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsTextArt.t12p5w500subMono.copyWith(
                          color: tokens.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showPhone) ...[
                  const SizedBox(width: 6),
                  Semantics(
                    button: onCall != null,
                    label: onCall != null ? context.l10n.call : null,
                    child: DsPressable(
                      key: onCall != null ? ValueKey('call-${contact.name}') : null,
                      onTap: onCall,
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CustomPaint(painter: _SmallPhonePainter(color: tokens.accent)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!isLast)
            Positioned(left: 66, right: 18, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
        ],
      ),
    );
  }
}

class _StarPainter extends CustomPainter {
  final Color color;
  _StarPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
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
    canvas.drawPath(p, fill);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StarPainter old) => old.color != color;
}

class _SmallPhonePainter extends CustomPainter {
  final Color color;
  _SmallPhonePainter({required this.color});
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
    final p = Path()
      ..moveTo(20, 16)
      ..lineTo(20, 19)
      ..arcToPoint(const Offset(17.5, 21.5), radius: const Radius.circular(2))
      ..arcToPoint(const Offset(2.5, 6.5), radius: const Radius.circular(15))
      ..arcToPoint(const Offset(5, 4), radius: const Radius.circular(2))
      ..lineTo(8, 4)
      ..arcToPoint(const Offset(10, 6), radius: const Radius.circular(2))
      ..cubicTo(10.13, 7.2, 10.4, 8.36, 10.81, 9.43)
      ..arcToPoint(const Offset(10.36, 11.45), radius: const Radius.circular(2))
      ..lineTo(9.09, 12.72)
      ..arcToPoint(const Offset(15.28, 18.91), radius: const Radius.circular(16), clockwise: false)
      ..lineTo(16.55, 17.64)
      ..arcToPoint(const Offset(18.57, 17.19), radius: const Radius.circular(2))
      ..cubicTo(19.64, 17.6, 20.8, 17.87, 22, 18);
    canvas.drawPath(p, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SmallPhonePainter old) => old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// A-Z index strip (right edge)
// ═════════════════════════════════════════════════════════════════════

// ═════════════════════════════════════════════════════════════════════
// Row model
// ═════════════════════════════════════════════════════════════════════

class _Contact {
  final String name;
  final String subtitle;
  final Uint8List? photo;
  const _Contact({required this.name, required this.subtitle, this.photo});
}
