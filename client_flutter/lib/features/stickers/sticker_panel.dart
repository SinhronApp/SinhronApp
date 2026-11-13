// The sticker panel — ADR-049 (owner, 2026-10-18: "stickers and emoji,
// really good ones, and adding packs"). Lives next to the emoji panel, in
// the keyboard's place.
//
//   • Tabs: Recent, then every pack (its first sticker as the icon), and +
//     to add packs (from files, or a code someone shared).
//   • A row of emoji on top filters by emoji — no keyboard needed.
//   • One scroll with a section per pack; the grid shows still frames, a
//     press and hold plays the sticker big; a tap sends it.

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/haptics.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_icon.dart';
import 'sticker_import.dart';
import 'sticker_pack_sheet.dart';
import 'sticker_store.dart';
import 'sticker_view.dart';

/// The emoji the filter row offers (the feelings people send most).
const kStickerFilterEmoji = ['😀', '😂', '😍', '🥰', '😎', '🤔', '😢', '😭', '😡', '😱', '👍', '👏', '🙏', '❤️', '🔥', '🎉', '🐱', '🐶'];

String _bare(String e) => e.replaceAll('\u{FE0F}', '');

/// Stickers of [packs] that stand for [emoji].
List<Sticker> stickersForEmoji(List<StickerPackView> packs, String emoji) {
  final e = _bare(emoji);
  return [
    for (final p in packs)
      for (final s in p.stickers)
        if (s.emoji.isNotEmpty && _bare(s.emoji).contains(e)) s,
  ];
}

class StickerPanel extends ConsumerStatefulWidget {
  const StickerPanel({super.key, required this.onSend});

  /// A sticker was tapped: send it. [pack] is where it's from.
  final void Function(Sticker sticker, StickerPackView pack) onSend;

  @override
  ConsumerState<StickerPanel> createState() => _StickerPanelState();
}

class _Section {
  const _Section(this.key, this.title, this.stickers, {this.pack});
  final String key;
  final String title;
  final List<Sticker> stickers;
  final StickerPackView? pack;
}

class _StickerPanelState extends ConsumerState<StickerPanel> {
  static const _columns = 5;
  static const _headerH = 30.0;
  static const _side = DsSpace.x2;

  final _scroll = ScrollController();
  int _current = 0;
  String? _filter;
  List<double> _offsets = const [];
  OverlayEntry? _peek;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _peek?.remove();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final o = _scroll.offset + 1;
    var i = 0;
    while (i + 1 < _offsets.length && _offsets[i + 1] <= o) {
      i++;
    }
    if (i != _current) setState(() => _current = i);
  }

  List<_Section> _sections(List<StickerPackView> packs, List<Sticker> recent, AppL10n l, String lang) {
    if (_filter != null) {
      return [_Section('found', l.stickersFound, stickersForEmoji(packs, _filter!))];
    }
    return [
      if (recent.isNotEmpty) _Section('recent', l.emojiRecent, recent),
      for (final p in packs) _Section(p.id, p.title(lang), p.stickers, pack: p),
    ];
  }

  double _cell(double width) => (width - 2 * _side) / _columns;

  List<double> _sectionOffsets(List<_Section> sections, double width) {
    final cell = _cell(width);
    var y = 0.0;
    return [
      for (final s in sections)
        () {
          final at = y;
          y += _headerH + (s.stickers.length / _columns).ceil() * cell;
          return at;
        }(),
    ];
  }

  void _jump(int i) {
    DsHaptics.play(Haptic.selection);
    void go() {
      if (!mounted || i >= _offsets.length || !_scroll.hasClients) return;
      setState(() => _current = i);
      final target = _offsets[i].clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.animateTo(target, duration: DsMotion.of(context, DsMotion.base), curve: DsMotion.emphasized);
    }

    if (_filter == null) return go();
    // Out of the filter first: the sections are laid out again, then jump.
    setState(() => _filter = null);
    WidgetsBinding.instance.addPostFrameCallback((_) => go());
  }

  StickerPackView? _packOf(List<StickerPackView> packs, Sticker s) => packs.where((p) => p.id == s.packId).firstOrNull;

  void _send(List<StickerPackView> packs, Sticker s) {
    final pack = _packOf(packs, s);
    if (pack == null) return;
    widget.onSend(s, pack);
    final setting = ref.read(recentStickersProvider).value ?? '';
    unawaited(ref.read(recentStickersProvider.notifier).save(withRecentSticker(setting, s.key)).catchError((Object _) {}));
  }

  /// Press and hold: the sticker big and moving over the chat.
  void _showPeek(Sticker s) {
    _peek?.remove();
    DsHaptics.play(Haptic.selection);
    final entry = OverlayEntry(
      builder: (ctx) => IgnorePointer(
        child: ColoredBox(
          color: DsPalette.black.withValues(alpha: 0.28),
          child: Center(
            child: StickerView.of(s, key: const ValueKey('sticker-peek'), size: MediaQuery.sizeOf(ctx).width * 0.62),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(entry);
    _peek = entry;
  }

  void _hidePeek() {
    _peek?.remove();
    _peek = null;
  }

  Future<void> _add() async {
    final l = context.l10n;
    final which = await showDsActionSheet<int>(
      context,
      title: l.stickersAdd,
      actions: [DsSheetAction(l.stickersFromFiles, 0), DsSheetAction(l.stickersFromCode, 1)],
    );
    if (!mounted || which == null) return;
    if (which == 1) {
      await addPackFromClipboard(context, ref);
      return;
    }
    await _importFiles();
  }

  Future<void> _importFiles() async {
    final l = context.l10n;
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        allowMultiple: true,
        withData: true,
        type: FileType.custom,
        allowedExtensions: const ['tgs', 'webp', 'png', 'webm', 'zip', 'json'],
      );
    } catch (_) {
      appNotice.value = l.stickersImportFailed;
      return;
    } finally {
      unawaited(FilePicker.clearTemporaryFiles());
    }
    final files = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.bytes != null) ImportedFile(f.name, f.bytes!),
    ];
    if (files.isEmpty || !mounted) return;
    setState(() => _importing = true);
    try {
      final r = await stickersFromFiles(files);
      if (r.stickers.isEmpty) {
        appNotice.value = l.stickersImportFailed;
        return;
      }
      final title = packTitleFor(files, l.myStickersTitle);
      final view = await ref.read(userStickerPacksProvider.notifier).addNew(title: title, stickers: r.stickers);
      showDone(l.stickersImported(view.title('')));
    } catch (_) {
      appNotice.value = l.stickersImportFailed;
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final lang = stickerLang(context);
    final packs = ref.watch(stickerPacksProvider);
    final all = {for (final p in packs) for (final s in p.stickers) s.key: s};
    final recent = [
      for (final k in (ref.watch(recentStickersProvider).value ?? '').split(' '))
        if (all[k] != null) all[k]!,
    ];
    final sections = _sections(packs, recent, l, lang);
    return Column(
      key: const ValueKey('sticker-panel'),
      children: [
        _PackTabs(
          packs: packs,
          hasRecent: recent.isNotEmpty,
          current: _filter != null ? -1 : _current,
          busy: _importing,
          onTap: _jump,
          onLongPress: (p) => showStickerPackSheet(context, ref, p),
          onAdd: _add,
        ),
        _FilterRow(
          selected: _filter,
          onTap: (e) => setState(() {
            _filter = _filter == e ? null : e;
            if (_scroll.hasClients) _scroll.jumpTo(0);
          }),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              _offsets = _sectionOffsets(sections, box.maxWidth);
              final cell = _cell(box.maxWidth);
              if (sections.isEmpty || (sections.length == 1 && sections.first.stickers.isEmpty)) {
                return Center(
                  child: Text(
                    _filter == null ? l.stickersAdd : l.stickersNone(_filter!),
                    style: DsText.subhead.copyWith(color: tokens.text3),
                  ),
                );
              }
              return CustomScrollView(
                controller: _scroll,
                physics: const BouncingScrollPhysics(),
                slivers: [
                  for (final s in sections) ...[
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: _headerH,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: s.pack == null ? null : () => showStickerPackSheet(context, ref, s.pack!),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x3h5, 0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    s.title.toUpperCase(),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
                                  ),
                                ),
                                if (s.pack != null)
                                  Semantics(
                                    button: true,
                                    label: l.stickerPackOptions,
                                    excludeSemantics: true,
                                    child: Text('•••', style: DsText.caption.copyWith(color: tokens.text3)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: _side),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _columns,
                          mainAxisExtent: cell,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, i) {
                            final st = s.stickers[i];
                            return _StickerCell(
                              key: ValueKey('sticker-${s.key}-${st.key}'),
                              sticker: st,
                              size: cell - DsSpace.x2,
                              onTap: () => _send(packs, st),
                              onHoldStart: () => _showPeek(st),
                              onHoldEnd: _hidePeek,
                            );
                          },
                          childCount: s.stickers.length,
                        ),
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: DsSpace.x4)),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _StickerCell extends StatelessWidget {
  const _StickerCell({
    super.key,
    required this.sticker,
    required this.size,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });
  final Sticker sticker;
  final double size;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final preview = sticker.preview;
    return Semantics(
      button: true,
      label: context.l10n.a11ySticker(sticker.emoji),
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onLongPressStart: (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
        onLongPressCancel: onHoldEnd,
        child: DsPressable(
          scale: 0.86,
          haptic: Haptic.selection,
          onTap: onTap,
          child: Center(
            // Still frames in the grid (dozens of animations at once would
            // cost battery); a hold plays it.
            child: preview != null && preview.isNotEmpty
                ? Image.memory(preview, width: size, height: size, fit: BoxFit.contain, gaplessPlayback: true)
                : StickerView.of(sticker, size: size, animate: false),
          ),
        ),
      ),
    );
  }
}

class _PackTabs extends StatelessWidget {
  const _PackTabs({
    required this.packs,
    required this.hasRecent,
    required this.current,
    required this.busy,
    required this.onTap,
    required this.onLongPress,
    required this.onAdd,
  });
  final List<StickerPackView> packs;
  final bool hasRecent;
  final int current;
  final bool busy;
  final ValueChanged<int> onTap;
  final ValueChanged<StickerPackView> onLongPress;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final lang = stickerLang(context);
    Widget tab(int i, String label, Widget icon, {StickerPackView? pack}) => Semantics(
      button: true,
      selected: i == current,
      label: label,
      excludeSemantics: true,
      onTap: () => onTap(i),
      child: GestureDetector(
        key: ValueKey('sticker-tab-$i'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(i),
        onLongPress: pack == null ? null : () => onLongPress(pack),
        child: AnimatedContainer(
          duration: DsMotion.of(context, DsMotion.fast),
          curve: DsMotion.enter,
          width: DsSpace.x10,
          height: DsSpace.x9,
          margin: const EdgeInsets.symmetric(horizontal: DsSpace.x0h5),
          decoration: BoxDecoration(
            color: i == current ? tokens.bgSoft : tokens.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(child: icon),
        ),
      ),
    );
    var i = 0;
    return Container(
      height: DsSpace.x11,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5))),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.nudge3),
              children: [
                if (hasRecent) tab(i++, l.emojiRecent, Text('🕘', style: DsTextArt.t18)),
                for (final p in packs)
                  tab(
                    i++,
                    p.title(lang),
                    p.cover.preview != null && p.cover.preview!.isNotEmpty
                        ? Image.memory(p.cover.preview!, width: DsSpace.x7, height: DsSpace.x7)
                        : StickerView.of(p.cover, size: DsSpace.x7, animate: false),
                    pack: p,
                  ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: l.stickersAdd,
            excludeSemantics: true,
            onTap: busy ? null : onAdd,
            child: GestureDetector(
              key: const ValueKey('sticker-add'),
              behavior: HitTestBehavior.opaque,
              onTap: busy ? null : onAdd,
              child: SizedBox(
                width: DsSpace.x11,
                height: DsSpace.x11,
                child: Center(
                  child: busy
                      ? Text('…', style: DsText.headline.copyWith(color: tokens.text3))
                      : CustomPaint(
                          size: const Size.square(DsSpace.x5h5),
                          painter: DsGlyphPainter(DsGlyph.plus, color: tokens.accent),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.selected, required this.onTap});
  final String? selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      height: DsSpace.x10,
      child: ListView(
        key: const ValueKey('sticker-filter'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x1),
        children: [
          for (final e in kStickerFilterEmoji)
            GestureDetector(
              key: ValueKey('sticker-filter-$e'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(e),
              child: AnimatedContainer(
                duration: DsMotion.of(context, DsMotion.fast),
                width: DsSpace.x9,
                margin: const EdgeInsets.symmetric(horizontal: DsSpace.x0h5),
                decoration: BoxDecoration(
                  color: selected == e ? tokens.accent.withValues(alpha: 0.16) : DsPalette.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(child: Text(e, style: DsTextArt.t22v2)),
              ),
            ),
        ],
      ),
    );
  }
}
