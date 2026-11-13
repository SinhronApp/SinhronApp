// The chat's emoji panel — owner, 2026-10-16: "there are a couple of
// smileys and they don't even tap; make it like a premium messenger". It
// was a grid of 15 emoji with nothing behind a tap.
//
// In the keyboard's place: the categories as tabs on top (the one in view
// highlighted, a tap scrolls there), every emoji in one scroll, "Recent"
// first (the last 32 picked, kept on this phone), ⌫ in the corner (hold to
// keep deleting). A tap types the emoji at the cursor and the panel stays
// open, the way iOS does it; the composer's keyboard button (or a tap on
// the field) brings the keyboard back.
//
// ADR-049 (owner, 2026-10-18: "stickers and emoji, really good ones"):
// a search field (English and Russian names, from Unicode CLDR — while
// typing, the panel shrinks to the field and one row of results above the
// keyboard), skin tones (press and hold a hand or a person; the tone picked
// is remembered for that emoji), and a bottom bar to switch to stickers.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../core/providers/settings_providers.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_search_pill.dart';
import '../stickers/sticker_panel.dart';
import '../stickers/sticker_store.dart';
import 'emoji_data.dart';
import 'emoji_names.dart';

/// Recently picked emoji, newest first (space-separated, at most
/// [kRecentEmojiMax]).
final recentEmojiProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('emoji_recent', ''));

const kRecentEmojiMax = 32;

/// Skin tone picked per emoji ("👍=👍🏽 ✋=✋🏿").
final emojiTonesProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('emoji_tones', ''));

/// The five Fitzpatrick modifiers, light to dark.
const kSkinTones = ['\u{1F3FB}', '\u{1F3FC}', '\u{1F3FD}', '\u{1F3FE}', '\u{1F3FF}'];

/// [emoji] with [tone] (its variation selector dropped, as Unicode wants).
String withSkinTone(String emoji, String tone) => emoji.replaceAll('\u{FE0F}', '') + tone;

/// base → toned, from the setting.
Map<String, String> parseEmojiTones(String setting) => {
  for (final pair in setting.split(' '))
    if (pair.contains('=')) pair.substring(0, pair.indexOf('=')): pair.substring(pair.indexOf('=') + 1),
};

String withEmojiTone(String setting, String base, String toned) {
  final m = parseEmojiTones(setting)..remove(base);
  if (toned != base) m[base] = toned;
  return [for (final e in m.entries) '${e.key}=${e.value}'].join(' ');
}

/// Emoji whose name (English or Russian) has every word of [query].
List<String> searchEmoji(String query, {int limit = 60}) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return const [];
  final out = <String>[];
  for (final c in EmojiCategory.values) {
    for (final e in emojiOf(c)) {
      final name = kEmojiNames[e] ?? '';
      if (words.every((w) => name.contains(w) || e == w)) out.add(e);
      if (out.length >= limit) return out;
    }
  }
  return out;
}

/// [emoji] first, no repeats, at most [kRecentEmojiMax].
String withRecentEmoji(String setting, String emoji) {
  final list = [emoji, ...setting.split(' ').where((e) => e.isNotEmpty && e != emoji)];
  return list.take(kRecentEmojiMax).join(' ');
}

/// [value] with [emoji] typed over the selection (at the end when there
/// is none), the cursor after it.
TextEditingValue insertEmoji(TextEditingValue value, String emoji) {
  final text = value.text;
  final sel = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: text.length);
  final next = text.replaceRange(sel.start, sel.end, emoji);
  return TextEditingValue(text: next, selection: TextSelection.collapsed(offset: sel.start + emoji.length));
}

/// [value] with the character (whole emoji, flag or ZWJ sequence) before
/// the cursor removed — or the selection.
TextEditingValue deleteBackward(TextEditingValue value) {
  final text = value.text;
  final sel = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: text.length);
  if (!sel.isCollapsed) {
    return TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, ''),
      selection: TextSelection.collapsed(offset: sel.start),
    );
  }
  if (sel.start == 0) return value;
  final before = text.substring(0, sel.start).characters;
  final kept = before.skipLast(1).toString();
  return TextEditingValue(
    text: kept + text.substring(sel.start),
    selection: TextSelection.collapsed(offset: kept.length),
  );
}

class EmojiPanel extends ConsumerStatefulWidget {
  const EmojiPanel({
    super.key,
    required this.onPick,
    required this.onBackspace,
    this.bottomPad = 0,
    this.height = defaultHeight,
    this.onSticker,
  });

  final ValueChanged<String> onPick;
  final VoidCallback onBackspace;

  /// Send a sticker — when set, a bottom bar switches to the sticker panel.
  final void Function(Sticker sticker, StickerPackView pack)? onSticker;

  /// The home-indicator inset under the panel.
  final double bottomPad;

  /// The panel's height above [bottomPad]: the keyboard's when known.
  final double height;
  static const double defaultHeight = 292;

  @override
  ConsumerState<EmojiPanel> createState() => _EmojiPanelState();
}

class _Section {
  const _Section(this.key, this.icon, this.emoji);
  final String key;
  final String icon;
  final List<String> emoji;
}

class _EmojiPanelState extends ConsumerState<EmojiPanel> {
  static const _columns = 8;
  static const _headerH = 30.0;
  static const _side = DsSpace.x2;

  static const _searchH = 100.0;

  final _scroll = ScrollController();
  final _search = TextEditingController();
  int _current = 0;
  Timer? _repeat;

  /// 0 — emoji, 1 — stickers.
  int _mode = 0;
  bool _searchFocused = false;
  OverlayEntry? _tonePicker;

  bool get _searching => _mode == 0 && (_searchFocused || _search.text.isNotEmpty);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _repeat?.cancel();
    _tonePicker?.remove();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Press and hold an emoji that takes a skin tone: the six variants in a
  /// bubble over it; the one picked is typed and remembered.
  void _showTones(BuildContext cell, String base) {
    _tonePicker?.remove();
    final box = cell.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context);
    final ob = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || ob == null) return;
    DsHaptics.play(Haptic.selection);
    final rect = MatrixUtils.transformRect(box.getTransformTo(ob), Offset.zero & box.size);
    final options = [base, for (final t in kSkinTones) withSkinTone(base, t)];
    final w = rect.width * options.length + DsSpace.x2;
    final left = (rect.center.dx - w / 2).clamp(DsSpace.x1, ob.size.width - w - DsSpace.x1);
    void close() {
      _tonePicker?.remove();
      _tonePicker = null;
    }

    final entry = OverlayEntry(
      builder: (ctx) {
        final tokens = DsTheme.of(context);
        return Stack(
          children: [
            Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: close)),
            Positioned(
              left: left,
              top: rect.top - rect.height - DsSpace.x1,
              child: Container(
                key: const ValueKey('emoji-tones'),
                padding: const EdgeInsets.all(DsSpace.x1),
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: DsShadow.card,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, e) in options.indexed)
                      Semantics(
                        button: true,
                        label: '${context.l10n.emojiSkinTone} ${i + 1}',
                        excludeSemantics: true,
                        child: GestureDetector(
                          key: ValueKey('emoji-tone-$i'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            close();
                            _pick(e);
                            final setting = ref.read(emojiTonesProvider).value ?? '';
                            unawaited(
                              ref.read(emojiTonesProvider.notifier).save(withEmojiTone(setting, base, e)).catchError((Object _) {}),
                            );
                          },
                          child: SizedBox(
                            width: rect.width,
                            height: rect.height,
                            child: Center(child: Text(e, style: DsTextArt.t28)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
    _tonePicker = entry;
  }

  List<_Section> _sections(List<String> recent) => [
    if (recent.isNotEmpty) _Section('recent', '🕘', recent),
    for (final c in EmojiCategory.values) _Section(c.name, kEmojiCategoryIcon[c]!, emojiOf(c)),
  ];

  double _cell(double width) => (width - 2 * _side) / _columns;

  /// Where each section starts in the scroll — fixed sizes, so known
  /// without building the ones off screen.
  List<double> _offsets(List<_Section> sections, double width) {
    final cell = _cell(width);
    var y = 0.0;
    return [
      for (final s in sections)
        () {
          final at = y;
          y += _headerH + (s.emoji.length / _columns).ceil() * cell;
          return at;
        }(),
    ];
  }

  List<double> _lastOffsets = const [];

  void _onScroll() {
    final o = _scroll.offset + 1;
    var i = 0;
    while (i + 1 < _lastOffsets.length && _lastOffsets[i + 1] <= o) {
      i++;
    }
    if (i != _current) setState(() => _current = i);
  }

  void _jump(int i) {
    if (i >= _lastOffsets.length) return;
    DsHaptics.play(Haptic.selection);
    setState(() => _current = i);
    final target = _lastOffsets[i].clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: DsMotion.of(context, DsMotion.base), curve: DsMotion.emphasized);
  }

  void _pick(String e) {
    widget.onPick(e);
    final setting = ref.read(recentEmojiProvider).value ?? '';
    // Saved for next time; the order in view doesn't jump while picking.
    unawaited(ref.read(recentEmojiProvider.notifier).save(withRecentEmoji(setting, e)).catchError((Object _) {}));
  }

  String _label(AppL10n l, String key) => switch (key) {
    'recent' => l.emojiRecent,
    'smileys' => l.emojiSmileys,
    'people' => l.emojiPeople,
    'animals' => l.emojiAnimals,
    'food' => l.emojiFood,
    'activities' => l.emojiActivities,
    'travel' => l.emojiTravel,
    'objects' => l.emojiObjects,
    'symbols' => l.emojiSymbols,
    _ => l.emojiFlags,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final recentSetting = ref.watch(recentEmojiProvider).value ?? '';
    final tones = parseEmojiTones(ref.watch(emojiTonesProvider).value ?? '');
    final sections = _sections(recentSetting.split(' ').where((e) => e.isNotEmpty).toList());
    final searching = _searching;
    final onSticker = widget.onSticker;
    String shown(String e) => tones[e] ?? e;
    return Container(
      key: const ValueKey('emoji-panel'),
      height: searching ? _searchH : widget.height.clamp(240.0, 420.0) + widget.bottomPad,
      padding: EdgeInsets.only(bottom: searching ? 0 : widget.bottomPad),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border(top: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Column(
        children: [
          if (_mode == 1 && onSticker != null)
            Expanded(child: StickerPanel(onSend: onSticker))
          else ...[
            if (!searching)
              _Tabs(
                key: const ValueKey('emoji-tabs'),
                icons: [for (final s in sections) s.icon],
                labels: [for (final s in sections) _label(l, s.key)],
                current: _current.clamp(0, sections.length - 1),
                onTap: _jump,
              ),
            // Keyed: stays the same field (and keeps focus) when the panel
            // shrinks around it for typing.
            Padding(
              key: const ValueKey('emoji-search'),
              padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x1h5, DsSpace.x3, DsSpace.x1),
              child: Focus(
                onFocusChange: (f) => setState(() => _searchFocused = f),
                child: DsSearchPill(controller: _search, hint: l.emojiSearch),
              ),
            ),
            if (searching)
              Expanded(child: _SearchResults(found: [for (final e in searchEmoji(_search.text)) shown(e)], onPick: _pick))
            else
              Expanded(
                child: Stack(
                  children: [
                    LayoutBuilder(
                      builder: (context, box) {
                        _lastOffsets = _offsets(sections, box.maxWidth);
                        final cell = _cell(box.maxWidth);
                        return CustomScrollView(
                          controller: _scroll,
                          physics: const BouncingScrollPhysics(),
                          slivers: [
                            for (final s in sections) ...[
                              SliverToBoxAdapter(
                                child: SizedBox(
                                  height: _headerH,
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x3h5, 0),
                                    child: Text(
                                      _label(l, s.key).toUpperCase(),
                                      style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
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
                                      final e = s.emoji[i];
                                      final recent = s.key == 'recent';
                                      final toneable = !recent && kSkinToneEmoji.contains(e);
                                      return Builder(
                                        key: ValueKey('emoji-${s.key}-$i'),
                                        builder: (cellContext) => _EmojiCell(
                                          emoji: recent ? e : shown(e),
                                          onTap: () => _pick(recent ? e : shown(e)),
                                          onLongPress: toneable ? () => _showTones(cellContext, e) : null,
                                        ),
                                      );
                                    },
                                    childCount: s.emoji.length,
                                  ),
                                ),
                              ),
                            ],
                            // Room above the ⌫ button at the end.
                            const SliverToBoxAdapter(child: SizedBox(height: DsSpace.x12)),
                          ],
                        );
                      },
                    ),
                    Positioned(
                      right: DsSpace.x3,
                      bottom: DsSpace.x2h5,
                      child: _Backspace(
                        onTap: widget.onBackspace,
                        onHoldStart: () {
                          _repeat?.cancel();
                          _repeat = Timer.periodic(const Duration(milliseconds: 90), (_) => widget.onBackspace());
                        },
                        onHoldEnd: () => _repeat?.cancel(),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (onSticker != null && !searching)
            _ModeBar(
              mode: _mode,
              onMode: (m) {
                DsHaptics.play(Haptic.selection);
                setState(() => _mode = m);
              },
            ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({super.key, required this.icons, required this.labels, required this.current, required this.onTap});
  final List<String> icons;
  final List<String> labels;
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5))),
      child: Row(
        children: [
          for (var i = 0; i < icons.length; i++)
            Expanded(
              child: Semantics(
                button: true,
                selected: i == current,
                label: labels[i],
                excludeSemantics: true,
                onTap: () => onTap(i),
                child: GestureDetector(
                  key: ValueKey('emoji-tab-$i'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(i),
                  child: Center(
                    child: AnimatedContainer(
                      duration: DsMotion.of(context, DsMotion.fast),
                      curve: DsMotion.enter,
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: i == current ? tokens.bgSoft : tokens.surface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: AnimatedOpacity(
                          duration: DsMotion.of(context, DsMotion.fast),
                          opacity: i == current ? 1 : 0.45,
                          child: Text(icons[i], style: DsTextArt.t18),
                        ),
                      ),
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

class _EmojiCell extends StatelessWidget {
  const _EmojiCell({super.key, required this.emoji, required this.onTap, this.onLongPress});
  final String emoji;
  final VoidCallback onTap;

  /// Skin tones (people and hands).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: emoji,
    excludeSemantics: true,
    onTap: onTap,
    child: DsPressable(
      scale: 0.82,
      haptic: Haptic.selection,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Center(child: Text(emoji, style: DsTextArt.t28)),
    ),
  );
}

class _Backspace extends StatelessWidget {
  const _Backspace({required this.onTap, required this.onHoldStart, required this.onHoldEnd});
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Semantics(
      button: true,
      label: context.l10n.emojiDelete,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: const ValueKey('emoji-backspace'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          DsHaptics.play(Haptic.selection);
          onTap();
        },
        onLongPressStart: (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
        onLongPressCancel: onHoldEnd,
        child: Container(
          width: 48,
          height: 36,
          decoration: BoxDecoration(
            color: tokens.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tokens.divider, width: 0.5),
            boxShadow: DsShadow.card,
          ),
          child: Center(
            child: CustomPaint(
              size: const Size.square(22),
              painter: DsGlyphPainter(DsGlyph.backspace, color: tokens.text2),
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of search results above the keyboard.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.found, required this.onPick});
  final List<String> found;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    if (found.isEmpty) {
      return Center(child: Text(context.l10n.emojiNothingFound, style: DsText.subhead.copyWith(color: tokens.text3)));
    }
    return ListView(
      key: const ValueKey('emoji-results'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2),
      children: [
        for (final (i, e) in found.indexed)
          SizedBox(
            width: DsSpace.x11,
            child: _EmojiCell(key: ValueKey('emoji-found-$i'), emoji: e, onTap: () => onPick(e)),
          ),
      ],
    );
  }
}

/// Emoji | Stickers, at the bottom (Telegram's place for it).
class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.mode, required this.onMode});
  final int mode;
  final ValueChanged<int> onMode;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    Widget pill(int m, String label) => Semantics(
      button: true,
      selected: mode == m,
      label: label,
      excludeSemantics: true,
      onTap: () => onMode(m),
      child: GestureDetector(
        key: ValueKey(m == 0 ? 'panel-mode-emoji' : 'panel-mode-stickers'),
        behavior: HitTestBehavior.opaque,
        onTap: () => onMode(m),
        child: AnimatedContainer(
          duration: DsMotion.of(context, DsMotion.fast),
          curve: DsMotion.enter,
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x1h5),
          decoration: BoxDecoration(
            color: mode == m ? tokens.bgSoft : tokens.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: DsText.subhead.copyWith(
              fontWeight: mode == m ? FontWeight.w600 : FontWeight.w500,
              color: mode == m ? tokens.text : tokens.text3,
            ),
          ),
        ),
      ),
    );
    return Container(
      height: DsSpace.x10,
      decoration: BoxDecoration(border: Border(top: BorderSide(color: tokens.divider, width: 0.5))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [pill(0, l.emojiTab), const SizedBox(width: DsSpace.x2), pill(1, l.stickersTab)],
      ),
    );
  }
}
