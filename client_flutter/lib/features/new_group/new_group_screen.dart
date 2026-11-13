// New group — reached from Compose → "New group".
//
// Two-step internal flow:
//   1. Pick members  — search field, selected-chips strip, alphabetical
//      contact list with check rows. Bottom CTA "Next · N selected".
//   2. Name & avatar — tappable group avatar (tap cycles gradient palette),
//      large name TextField, "MEMBERS · N" list, MLS-narrative footer,
//      bottom CTA "Create group".
//
// Per spec §6.5 (Groups), creating a group emits an MLS Add proposal for
// every member, batched into one Commit (ADR-034, `createMlsGroup`). The
// other members receive it via the Delivery Service and show the group on
// next sync.
//
// The people come from the wiring ([NewGroupScreen.contacts]: people I
// have a personal chat with). [NewGroupScreen.onAdd] turns it into
// "Add members" for an existing group: one step, no name.

import 'dart:typed_data';

import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter, TextInputAction;
import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../core/providers/people.dart' show shortKey;
import '../chat_list/chat_data.dart' show ChatPreview;
import '../contacts_list/contacts_list_screen.dart' show ContactEntry;
import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_verified_badge.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_icon.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_search_pill.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../../widgets/ds_text_field.dart';

enum NewGroupStep { pickMembers, nameAndCreate }

/// Someone who can be put in a group: [id] is their identity key (hex) for
/// real contacts, [subtitle] a short key or @handle.
class NewGroupContact {
  final String id;
  final String name;
  final String subtitle;
  final bool verified;

  /// Their photo, if they shared one.
  final Uint8List? photo;
  const NewGroupContact({
    required this.id,
    required this.name,
    required this.subtitle,
    this.verified = false,
    this.photo,
  });
}

/// ADR-034 — the real people a group can be made of: everyone I have an
/// accepted personal chat with whose key is known (`ChatPreview.peerId`),
/// named as they named themselves ([names]) or as the chat is called, and
/// (ADR-052) my [contacts], chat or not. Blocked people and [exclude] (me,
/// current members) are left out. Sorted by name.
List<NewGroupContact> groupCandidates(
  List<ChatPreview> chats,
  Map<String, String> names, {
  Set<String> exclude = const {},
  Set<String> blocked = const {},
  Map<String, Uint8List> photos = const {},
  Set<String> verified = const {},
  List<ContactEntry> contacts = const [],
}) {
  final out = <String, NewGroupContact>{};
  for (final c in contacts) {
    final peer = c.peerId;
    if (exclude.contains(peer) || blocked.contains(peer) || out.containsKey(peer)) continue;
    out[peer] = NewGroupContact(
      id: peer,
      name: c.name,
      subtitle: shortKey(peer),
      verified: verified.contains(peer.toLowerCase()),
      photo: photos[peer.toLowerCase()],
    );
  }
  for (final c in chats) {
    final peer = c.peerId;
    if (c.group || c.request || peer == null || peer.isEmpty) continue;
    if (exclude.contains(peer) || blocked.contains(peer) || out.containsKey(peer)) continue;
    out[peer] = NewGroupContact(
      id: peer,
      name: names[peer] ?? c.name,
      subtitle: shortKey(peer),
      verified: verified.contains(peer.toLowerCase()),
      photo: photos[peer.toLowerCase()],
    );
  }
  return out.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// Longest group name (the wire limit — `MAX_PROFILE_NAME_CHARS` in Rust).
const int kMaxGroupNameChars = 64;

class NewGroupScreen extends StatefulWidget {
  /// Start at step 2 (tests) without first picking members.
  final NewGroupStep initialStep;

  /// Pre-selected member ids if [initialStep] is nameAndCreate.
  final List<String> initialSelected;

  /// People to pick from.
  final List<NewGroupContact> contacts;

  /// The "You (admin)" row: my name and short key.
  final NewGroupContact me;

  final VoidCallback? onCancel;

  /// Create the group: its name and the picked member ids. While it runs
  /// the button is disabled; if it throws, the screen stays.
  final Future<void> Function(String name, List<String> memberIds)? onCreate;

  /// "Add members" to an existing group instead: one step, no name.
  final Future<void> Function(List<String> memberIds)? onAdd;

  const NewGroupScreen({
    super.key,
    this.initialStep = NewGroupStep.pickMembers,
    this.initialSelected = const [],
    required this.contacts,
    required this.me,
    this.onCancel,
    this.onCreate,
    this.onAdd,
  });

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  late NewGroupStep _step;
  late final TextEditingController _searchCtrl;
  late final TextEditingController _nameCtrl;
  late Set<String> _selected;
  int _paletteIndex = 2; // start on violet
  bool _busy = false;

  List<NewGroupContact> get _contacts => widget.contacts;

  @override
  void initState() {
    super.initState();
    _step = widget.initialStep;
    _searchCtrl = TextEditingController();
    _nameCtrl = TextEditingController();
    _selected = widget.initialSelected.toSet();
    _searchCtrl.addListener(() => setState(() {}));
    _nameCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  List<NewGroupContact> get _filteredContacts {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _contacts;
    return _contacts.where((c) => c.name.toLowerCase().contains(q) || c.subtitle.toLowerCase().contains(q)).toList();
  }

  /// Picked people, in the order they were picked.
  List<NewGroupContact> get _picked {
    final byId = {for (final c in _contacts) c.id: c};
    return [
      for (final id in _selected)
        if (byId[id] != null) byId[id]!,
    ];
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
    });
  }

  void _goNext() {
    if (_selected.isEmpty || _busy) return;
    final add = widget.onAdd;
    if (add != null) {
      _run(() => add(_picked.map((c) => c.id).toList()));
      return;
    }
    setState(() => _step = NewGroupStep.nameAndCreate);
  }

  void _create() {
    final name = _nameCtrl.text.trim();
    final create = widget.onCreate;
    if (name.isEmpty || create == null || _busy) return;
    _run(() => create(name, _picked.map((c) => c.id).toList()));
  }

  /// One create / add at a time; the caller reports errors.
  Future<void> _run(Future<void> Function() job) async {
    setState(() => _busy = true);
    try {
      await job();
    } catch (_) {
      // The wiring shows what went wrong; the screen stays for a retry.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _goBack() {
    if (_step == NewGroupStep.nameAndCreate) {
      setState(() => _step = NewGroupStep.pickMembers);
    } else {
      widget.onCancel?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: AnimatedSwitcher(
          duration: DsMotion.base,
          transitionBuilder: (child, anim) {
            final goingForward = child.key == const ValueKey('step2');
            final begin = Offset(goingForward ? 0.06 : -0.06, 0);
            final slide = Tween<Offset>(
              begin: begin,
              end: Offset.zero,
            ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut));
            return FadeTransition(
              opacity: anim,
              child: SlideTransition(position: slide, child: child),
            );
          },
          child: _step == NewGroupStep.pickMembers
              ? KeyedSubtree(
                  key: const ValueKey('step1'),
                  child: _PickMembersStep(
                    searchCtrl: _searchCtrl,
                    contacts: _filteredContacts,
                    noContacts: _contacts.isEmpty,
                    picked: _picked,
                    selected: _selected,
                    adding: widget.onAdd != null,
                    busy: _busy,
                    onToggle: _toggle,
                    onBack: _goBack,
                    onNext: _goNext,
                  ),
                )
              : KeyedSubtree(
                  key: const ValueKey('step2'),
                  child: _NameAndCreateStep(
                    nameCtrl: _nameCtrl,
                    selected: _picked,
                    me: widget.me,
                    busy: _busy,
                    paletteIndex: _paletteIndex,
                    onCyclePalette: () => setState(() => _paletteIndex = (_paletteIndex + 1) % _kPalettes.length),
                    onRemoveMember: _toggle,
                    onBack: _goBack,
                    onCreate: _create,
                  ),
                ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// STEP 1 — Pick members
// ═════════════════════════════════════════════════════════════════════

class _PickMembersStep extends StatelessWidget {
  final TextEditingController searchCtrl;
  final List<NewGroupContact> contacts;
  final bool noContacts;
  final List<NewGroupContact> picked;
  final Set<String> selected;
  final bool adding;
  final bool busy;
  final void Function(String) onToggle;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const _PickMembersStep({
    required this.searchCtrl,
    required this.contacts,
    required this.noContacts,
    required this.picked,
    required this.selected,
    required this.adding,
    required this.busy,
    required this.onToggle,
    required this.onBack,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      children: [
        _StepBar(title: adding ? l.groupInfoAddMember : l.newGroup, stepLabel: adding ? '' : '1 / 2', onBack: onBack),
        DsSearchPill(controller: searchCtrl, hint: context.l10n.searchContacts),
        if (picked.isNotEmpty) _SelectedChipsStrip(selected: picked, onRemove: onToggle),
        Expanded(
          child: noContacts
              ? _NoContacts(adding: adding)
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(0, DsSpace.x1h5, 0, DsSpace.x4),
                  itemCount: contacts.length + 1,
                  itemBuilder: (ctx, i) {
                    if (i == 0) return const _PickHeader();
                    final c = contacts[i - 1];
                    return _PickRow(
                      key: ValueKey('pick-${c.id}'),
                      contact: c,
                      checked: selected.contains(c.id),
                      onToggle: () => onToggle(c.id),
                    );
                  },
                ),
        ),
        _BottomCta(
          label: selected.isEmpty
              ? l.newGroupPickOne
              : (adding ? l.newGroupAddCta(selected.length) : l.newGroupNext(selected.length)),
          enabled: selected.isNotEmpty && !busy,
          onTap: onNext,
        ),
      ],
    );
  }
}

/// Nobody to pick yet: groups are made of people you already chat with.
class _NoContacts extends StatelessWidget {
  final bool adding;
  const _NoContacts({required this.adding});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.all(DsSpace.x6),
      child: Center(
        child: Text(
          adding ? context.l10n.newGroupNoOneToAdd : context.l10n.newGroupNoContacts,
          textAlign: TextAlign.center,
          style: DsText.callout.copyWith(color: tokens.text3),
        ),
      ),
    );
  }
}

class _PickHeader extends StatelessWidget {
  const _PickHeader();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2h5, DsSpace.x6, DsSpace.x2),
      child: Text(
        context.l10n.newGroupAllContacts.toUpperCase(),
        style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
      ),
    );
  }
}

class _PickRow extends StatelessWidget {
  final NewGroupContact contact;
  final bool checked;
  final VoidCallback onToggle;
  const _PickRow({super.key, required this.contact, required this.checked, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2, DsSpace.x4h5, DsSpace.x2),
        child: Row(
          children: [
            DsAvatar(name: contact.name, size: 42, image: contact.photo),
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
                        const SizedBox(width: 5),
                        const DsVerifiedBadge(size: 14),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    contact.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsTextArt.t12w500Monov2.copyWith(color: tokens.text3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _CheckBox(checked: checked),
          ],
        ),
      ),
    );
  }
}

/// 22×22 squircle checkbox without label (the design's DsCheck box) — it
/// stands alone as a trailing widget inside row layouts.
class _CheckBox extends StatelessWidget {
  final bool checked;
  const _CheckBox({required this.checked});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: checked ? tokens.accent : DsPalette.transparent,
        borderRadius: BorderRadius.circular(7),
        border: checked ? null : Border.all(color: tokens.text4, width: 1.5),
      ),
      child: checked
          ? Center(
              child: SizedBox(
                width: 13,
                height: 13,
                child: CustomPaint(painter: DsCheckmarkGlyph(color: tokens.accentText)),
              ),
            )
          : null,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Selected chips strip
// ═════════════════════════════════════════════════════════════════════

class _SelectedChipsStrip extends StatelessWidget {
  final List<NewGroupContact> selected;
  final void Function(String) onRemove;
  const _SelectedChipsStrip({required this.selected, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: DsSpace.x2),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3),
        itemCount: selected.length,
        itemBuilder: (ctx, i) {
          final c = selected[i];
          return _Chip(name: c.name, photo: c.photo, onRemove: () => onRemove(c.id));
        },
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final VoidCallback onRemove;
  const _Chip({required this.name, this.photo, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: DsSpace.x1h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x1, DsSpace.x1, DsSpace.nudge11, DsSpace.x1),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tokens.divider, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DsAvatar(name: name, size: 28, image: photo),
            const SizedBox(width: 8),
            Text(_firstName(name), style: DsText.subhead.copyWith(height: 1.0, color: tokens.text)),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
              child: SizedBox(
                width: 14,
                height: 14,
                child: CustomPaint(painter: DsXmarkGlyph(color: tokens.text3)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _firstName(String n) => n.split(' ').first;
}

// ═════════════════════════════════════════════════════════════════════
// STEP 2 — Name + Avatar + Members list
// ═════════════════════════════════════════════════════════════════════

const _kPalettes = <List<Color>>[
  [DsPalette.lilac, DsPalette.violet], // violet (default)
  [DsPalette.sky, DsPalette.blue500], // blue
  [DsPalette.mint, DsPalette.emerald], // teal
  [DsPalette.peach, DsPalette.salmon], // amber
  [DsPalette.rose200, DsPalette.pink], // pink
  [DsPalette.artFFE08A, DsPalette.amber], // gold
  [DsPalette.artB5E2A1, DsPalette.lime600], // olive
  [DsPalette.artD4B8FF, DsPalette.purple600], // purple
];

class _NameAndCreateStep extends StatelessWidget {
  final TextEditingController nameCtrl;
  final List<NewGroupContact> selected;
  final NewGroupContact me;
  final bool busy;
  final int paletteIndex;
  final VoidCallback onCyclePalette;
  final void Function(String) onRemoveMember;
  final VoidCallback onBack;
  final VoidCallback onCreate;

  const _NameAndCreateStep({
    required this.nameCtrl,
    required this.selected,
    required this.me,
    required this.busy,
    required this.paletteIndex,
    required this.onCyclePalette,
    required this.onRemoveMember,
    required this.onBack,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    final canCreate = nameCtrl.text.trim().isNotEmpty && selected.isNotEmpty && !busy;
    return Column(
      children: [
        _StepBar(title: context.l10n.newGroup, stepLabel: '2 / 2', onBack: onBack),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(0, DsSpace.x3, 0, DsSpace.x4),
            children: [
              _GroupAvatarHero(paletteIndex: paletteIndex, onTap: onCyclePalette),
              const SizedBox(height: 22),
              _NameField(controller: nameCtrl),
              const SizedBox(height: 28),
              _MembersSection(me: me, members: selected, onRemove: onRemoveMember),
              const SizedBox(height: 14),
              const _MlsFooter(),
            ],
          ),
        ),
        _BottomCta(label: context.l10n.newGroupCreate, enabled: canCreate, onTap: onCreate),
      ],
    );
  }
}

class _GroupAvatarHero extends StatelessWidget {
  final int paletteIndex;
  final VoidCallback onTap;
  const _GroupAvatarHero({required this.paletteIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final palette = _kPalettes[paletteIndex];
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: palette),
              ),
              child: Center(
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: CustomPaint(painter: _GroupGlyphPainter(color: DsPalette.white)),
                ),
              ),
            ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: tokens.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.bg, width: 2),
                ),
                child: Center(
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CustomPaint(painter: _CameraGlyphPainter(color: tokens.text)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    // Two people silhouettes
    canvas.drawCircle(const Offset(9, 8), 3, stroke);
    canvas.drawCircle(const Offset(17, 9), 2.4, stroke);
    final shoulders = Path()
      ..moveTo(3, 19)
      ..arcToPoint(const Offset(15, 19), radius: const Radius.circular(6));
    canvas.drawPath(shoulders, stroke);
    canvas.drawLine(const Offset(15, 19), const Offset(21, 19), stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GroupGlyphPainter old) => old.color != color;
}

class _CameraGlyphPainter extends CustomPainter {
  final Color color;
  _CameraGlyphPainter({required this.color});
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
    final body = Path()
      ..moveTo(4, 8)
      ..lineTo(8, 8)
      ..lineTo(10, 6)
      ..lineTo(14, 6)
      ..lineTo(16, 8)
      ..lineTo(20, 8)
      ..arcToPoint(const Offset(21, 9), radius: const Radius.circular(1))
      ..lineTo(21, 17)
      ..arcToPoint(const Offset(20, 18), radius: const Radius.circular(1))
      ..lineTo(4, 18)
      ..arcToPoint(const Offset(3, 17), radius: const Radius.circular(1))
      ..lineTo(3, 9)
      ..arcToPoint(const Offset(4, 8), radius: const Radius.circular(1))
      ..close();
    canvas.drawPath(body, stroke);
    canvas.drawCircle(const Offset(12, 13), 3, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CameraGlyphPainter old) => old.color != color;
}

// Stateful so the field keeps one FocusNode: a node made in build was
// replaced on every keystroke, so Done unfocused a fresh node and the
// keyboard never went away.
class _NameField extends StatefulWidget {
  final TextEditingController controller;
  const _NameField({required this.controller});

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  final FocusNode _focus = FocusNode();

  TextEditingController get controller => widget.controller;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final hasText = controller.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1, vertical: DsSpace.x2),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider, width: 0.8)),
        ),
        child: Stack(
          children: [
            if (!hasText)
              Text(
                context.l10n.newGroupName,
                style: DsText.title2.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
              ),
            DsPlainField(
              controller: controller,
              focusNode: _focus,
              textInputAction: TextInputAction.done,
              inputFormatters: [LengthLimitingTextInputFormatter(kMaxGroupNameChars)],
              onSubmitted: (_) => _focus.unfocus(),
              onTapOutside: (_) => _focus.unfocus(),
              style: DsText.title2.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
              cursorColor: tokens.accent,
              backgroundCursorColor: tokens.text4,
            ),
          ],
        ),
      ),
    );
  }
}

class _MembersSection extends StatelessWidget {
  final NewGroupContact me;
  final List<NewGroupContact> members;
  final void Function(String) onRemove;
  const _MembersSection({required this.me, required this.members, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x2h5),
          child: Text(
            context.l10n.newGroupMembersCount(members.length + 1).toUpperCase(), // +1 for "You (admin)"
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
                _MemberRow(contact: me, isYou: true),
                for (var i = 0; i < members.length; i++)
                  _MemberRow(
                    contact: members[i],
                    isLast: i == members.length - 1,
                    onRemove: () => onRemove(members[i].id),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  final NewGroupContact contact;
  final bool isLast;
  final bool isYou;
  final VoidCallback? onRemove;

  const _MemberRow({required this.contact, this.isLast = false, this.isYou = false, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final name = contact.name;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x3, DsSpace.x2h5),
          child: Row(
            children: [
              DsAvatar(name: name, size: 38, image: contact.photo),
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
                            isYou ? context.l10n.you : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                          ),
                        ),
                        if (isYou) ...[const SizedBox(width: 6), _AdminPill()],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(contact.subtitle, style: DsTextArt.t12w500Monov2.copyWith(color: tokens.text3)),
                  ],
                ),
              ),
              if (!isYou) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRemove,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
                    child: Center(
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CustomPaint(painter: DsXmarkGlyph(color: tokens.text3)),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (!isLast) Positioned(left: 64, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

class _AdminPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(DsSpace.x1h5, DsSpace.x0h5, DsSpace.x1h5, DsSpace.x0h5),
      decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(999)),
      child: Text(
        context.l10n.groupInfoAdmin.toUpperCase(),
        style: DsText.micro.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.accent),
      ),
    );
  }
}

class _MlsFooter extends StatelessWidget {
  const _MlsFooter();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
      child: Text(context.l10n.newGroupFooter, style: DsText.footnote.copyWith(color: tokens.text3)),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Shared chrome (step bar, bottom CTA)
// ═════════════════════════════════════════════════════════════════════

class _StepBar extends StatelessWidget {
  final String title;
  final String stepLabel;
  final VoidCallback onBack;
  const _StepBar({required this.title, required this.stepLabel, required this.onBack});

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
                child: Text(title, style: DsText.headline.copyWith(height: 1.0, color: tokens.text)),
              ),
            ),
          ),
          Row(
            children: [
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
              Padding(
                padding: const EdgeInsets.only(right: DsSpace.x3h5),
                child: Text(stepLabel, style: DsTextArt.t12w600Mono.copyWith(color: tokens.text3)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BottomCta extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  const _BottomCta({required this.label, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.bg,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x3h5, DsSpace.x1h5),
      child: DsButton(label: label, variant: DsButtonVariant.primary, onPressed: enabled ? onTap : null),
    );
  }
}
