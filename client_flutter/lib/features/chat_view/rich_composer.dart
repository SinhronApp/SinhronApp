// The composer's formatting — ADR-070.
//
//   • [RichTextController] keeps a style for every character beside the
//     text and paints it as you type (WYSIWYG): bold looks bold, a quote
//     is tinted, code is monospace. `formatted` gives clean text + ranges.
//   • Markers typed by hand turn into formatting the moment the closing
//     one is typed, as in Telegram: `**bold**` `__italic__` `~~strike~~`
//     `||spoiler||` `` `code` `` ```` ```block``` ```` `[words](address)`,
//     and `> ` at the start of a line makes a quote.
//   • Markdown pasted from another app (an AI's answer) turns into
//     formatting at once ([FormattedText.markdown]); [pastedMarkdown] lets
//     the composer offer to put it back as it came.
//   • [richFormatToolbar] — the selection menu gets "Format" → Bold,
//     Italic, Underline, Strikethrough, Monospace, Spoiler, Link, Quote,
//     Clear formatting; [RichFormatShortcuts] — ⌘/Ctrl B, I, U, ⇧X, ⇧M,
//     ⇧P, K, ⇧. (quote), ⇧N (clear) on iPad / hardware keyboards.

import 'package:flutter/cupertino.dart'
    show CupertinoAdaptiveTextSelectionToolbar, CupertinoTextSelectionToolbarButton;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/rich_text.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_name_sheet.dart';
import '../../widgets/ds_text_field.dart';

/// Where [RichTextController] turned pasted Markdown into formatting.
class PastedMarkdown {
  const PastedMarkdown(this.at, this.length, this.raw);
  final int at;

  /// Length of the formatted text that replaced [raw].
  final int length;
  final String raw;
}

class RichTextController extends TextEditingController {
  RichTextController({super.text}) {
    _mask = List.filled(text.length, 0, growable: true);
    _url = List.filled(text.length, null, growable: true);
    _lang = List.filled(text.length, null, growable: true);
  }

  /// Style bits ([EntityType.bit]) of every UTF-16 unit of [text].
  late List<int> _mask;
  late List<String?> _url;
  late List<String?> _lang;

  /// What the next typed characters get.
  int _typing = 0;

  /// Caret offset where [_typing] was set on purpose (a toolbar toggle with
  /// no selection, a finished `**marker**`): moving the caret elsewhere
  /// forgets it.
  int? _typingPinnedAt;

  bool _quiet = false;

  /// Text + formatting, tidied.
  FormattedText get formatted => FormattedText(text, FormattedText.entitiesFromRuns(_runs(0, text.length))).normalized();

  /// Replace everything (editing a message, a restored draft).
  void setFormatted(FormattedText t, {TextSelection? selection}) {
    final n = t.text.length;
    _mask = List.filled(n, 0, growable: true);
    _url = List.filled(n, null, growable: true);
    _lang = List.filled(n, null, growable: true);
    for (final r in t.runs()) {
      for (var i = r.start; i < r.end; i++) {
        _mask[i] = r.mask;
        _url[i] = r.url;
        _lang[i] = r.language;
      }
    }
    _typingPinnedAt = null;
    pastedMarkdown.value = null;
    _quiet = true;
    try {
      super.value = TextEditingValue(text: t.text, selection: selection ?? TextSelection.collapsed(offset: n));
    } finally {
      _quiet = false;
    }
    _typing = _typingAt(this.selection.baseOffset);
  }

  /// Bits that apply to all of [start]..[end] (for the toolbar).
  int maskOver(int start, int end) {
    if (end <= start) return _typing;
    var m = -1;
    for (var i = start; i < end && i < _mask.length; i++) {
      m &= _mask[i];
    }
    return m == -1 ? 0 : m;
  }

  /// The link over the selection, if one covers its start.
  String? linkAt(int offset) => offset >= 0 && offset < _url.length ? _url[offset] : null;

  // ── Editing ───────────────────────────────────────────────────────

  @override
  set value(TextEditingValue newValue) {
    final old = super.value;
    if (_quiet || newValue.text == old.text) {
      if (!_quiet && newValue.selection != old.selection) _caretMoved(newValue);
      super.value = newValue;
      return;
    }
    final a = old.text, b = newValue.text;
    var p = 0;
    final maxP = a.length < b.length ? a.length : b.length;
    while (p < maxP && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    // Typing "a" after "a" is ambiguous — the old caret says where it was.
    final selStart = old.selection.isValid ? old.selection.start : p;
    if (p > selStart && selStart >= 0) p = selStart;
    var s = 0;
    while (s < a.length - p && s < b.length - p && a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    final oldEnd = a.length - s, newEnd = b.length - s;
    // Replaced characters hand their style to what replaces them (an
    // autocorrected word stays bold, stays a link); typed ones get [_typing].
    final replaced = oldEnd > p;
    final mask = replaced ? _mask[p] : _typing;
    final url = replaced ? _url[p] : _typingUrlAt(p);
    final lang = replaced ? _lang[p] : _langAt(p, mask);
    _splice(p, oldEnd, newEnd - p, mask, url, lang);

    var next = newValue;
    final inserted = b.substring(p, newEnd);
    final composing = newValue.composing.isValid && !newValue.composing.isCollapsed;
    FormattedText? markdown;
    if (inserted.length > 1) {
      final fmt = RichClipboard.match(inserted);
      if (fmt != null) {
        _applyRuns(p, fmt);
      } else if (inserted.length <= 16384 && _mask[p] & codeBits == 0 && looksLikeMarkdown(inserted)) {
        markdown = FormattedText.markdown(inserted);
      }
    } else if (inserted.length == 1 && !composing && newValue.selection.isCollapsed) {
      next = _afterTyped(next, p) ?? next;
    }
    super.value = next;
    if (next.selection.isCollapsed && _typingPinnedAt != next.selection.baseOffset) {
      _typing = _typingAt(next.selection.baseOffset);
      _typingPinnedAt = null;
    }
    pastedMarkdown.value = null;
    if (markdown != null && markdown != FormattedText.plain(inserted)) _formatPasted(p, inserted, markdown);
  }

  /// Markdown just pasted and turned into formatting — "Undo" in the
  /// composer puts the text back as it came ([revertPastedMarkdown]).
  /// Any other edit forgets it.
  final ValueNotifier<PastedMarkdown?> pastedMarkdown = ValueNotifier(null);

  void _formatPasted(int at, String raw, FormattedText md) {
    final now = formatted;
    final end = at + raw.length;
    if (end > now.text.length) return;
    setFormatted(now.slice(0, at) + md + now.slice(end, now.text.length), selection: TextSelection.collapsed(offset: at + md.text.length));
    // What's typed next is plain, as after a finished `**marker**`.
    _typing = 0;
    _typingPinnedAt = at + md.text.length;
    pastedMarkdown.value = PastedMarkdown(at, md.text.length, raw);
  }

  /// The pasted Markdown back as it was, markers and all.
  void revertPastedMarkdown() {
    final p = pastedMarkdown.value;
    if (p == null) return;
    final now = formatted;
    if (p.at + p.length > now.text.length) return;
    setFormatted(
      now.slice(0, p.at) + FormattedText.plain(p.raw) + now.slice(p.at + p.length, now.text.length),
      selection: TextSelection.collapsed(offset: p.at + p.raw.length),
    );
    pastedMarkdown.value = null;
  }

  @override
  void dispose() {
    pastedMarkdown.dispose();
    super.dispose();
  }

  void _caretMoved(TextEditingValue v) {
    final c = v.selection.isCollapsed ? v.selection.baseOffset : -1;
    if (c >= 0 && c == _typingPinnedAt) return;
    _typingPinnedAt = null;
    if (c >= 0) _typing = _typingAt(c);
  }

  /// The style typing at [c] continues: the character before it (no link —
  /// typing after a link isn't part of it — unless inside one); at a line
  /// start only the block it's in.
  int _typingAt(int c) {
    if (c <= 0 || c > _mask.length) return _mask.isEmpty || c != 0 ? 0 : _mask[0] & blockBits;
    final prev = _mask[c - 1] & ~EntityType.link.bit;
    if (text.codeUnitAt(c - 1) == 0x0A) return prev & blockBits;
    return prev | (_typingUrlAt(c) != null ? EntityType.link.bit : 0);
  }

  /// Inside a link (same link on both sides) typing stays part of it.
  String? _typingUrlAt(int c) {
    if (c <= 0 || c >= _url.length) return null;
    final u = _url[c - 1];
    return u != null && u == _url[c] ? u : null;
  }

  String? _langAt(int c, int mask) {
    if (mask & EntityType.pre.bit == 0) return null;
    if (c > 0 && c - 1 < _lang.length) return _lang[c - 1];
    return c < _lang.length ? _lang[c] : null;
  }

  void _splice(int start, int end, int count, int mask, String? url, String? lang) {
    _mask.replaceRange(start, end, List.filled(count, mask));
    _url.replaceRange(start, end, List.filled(count, mask & EntityType.link.bit != 0 ? url : null));
    _lang.replaceRange(start, end, List.filled(count, mask & EntityType.pre.bit != 0 ? lang : null));
  }

  void _applyRuns(int at, FormattedText fmt) {
    for (final r in fmt.runs()) {
      for (var i = r.start; i < r.end && at + i < _mask.length; i++) {
        _mask[at + i] = r.mask;
        _url[at + i] = r.url;
        _lang[at + i] = r.language;
      }
    }
  }

  // ── Telegram-style markers ────────────────────────────────────────

  static const _pairs = <String, EntityType>{
    '**': EntityType.bold,
    '__': EntityType.italic,
    '~~': EntityType.strike,
    '||': EntityType.spoiler,
  };

  /// One character was typed at [at]: finish a marker it closes.
  TextEditingValue? _afterTyped(TextEditingValue v, int at) {
    final t = v.text;
    final ch = t[at];
    final caret = at + 1;
    if (_mask[at] & codeBits != 0 && ch != '`') return null;
    final lineStart = _lastIndexOf(t, '\n', at - 1) + 1;

    // Enter on an empty quote line leaves the quote (Telegram).
    if (ch == '\n' && _mask[at] & EntityType.quote.bit != 0 && at == lineStart && at > 0) {
      _mask.removeAt(at);
      _url.removeAt(at);
      _lang.removeAt(at);
      _mask[at - 1] &= ~EntityType.quote.bit;
      _typing &= ~EntityType.quote.bit;
      _typingPinnedAt = at;
      return TextEditingValue(text: t.replaceRange(at, caret, ''), selection: TextSelection.collapsed(offset: at));
    }
    // "> " at the start of a line → a quote.
    if (ch == ' ' && at == lineStart + 1 && t[lineStart] == '>' && _mask[lineStart] & blockBits == 0) {
      final lineEnd = t.indexOf('\n', caret);
      final end = lineEnd < 0 ? t.length : lineEnd;
      return _rewrite(v, [(lineStart, caret, '')], lineStart, end, EntityType.quote, caretAfter: lineStart, keepTyping: true);
    }
    if (ch == '`') {
      // ```lang\ncode``` → a code block.
      if (caret >= 3 && t.startsWith('```', caret - 3)) {
        final open = _lastIndexOf(t, '```', caret - 4);
        if (open >= 0 && caret - 3 > open + 3) {
          var bodyStart = open + 3;
          String? lang;
          final m = RegExp(r'^([A-Za-z0-9+#._-]{1,32})\n').firstMatch(t.substring(bodyStart, caret - 3));
          if (m != null) {
            lang = m.group(1);
            bodyStart += m.end;
          } else if (t.codeUnitAt(bodyStart) == 0x0A) {
            bodyStart += 1;
          }
          var bodyEnd = caret - 3;
          if (bodyEnd > bodyStart && t.codeUnitAt(bodyEnd - 1) == 0x0A) bodyEnd -= 1;
          if (bodyEnd > bodyStart) {
            return _rewrite(
              v,
              [(open, bodyStart, ''), (bodyEnd, caret, '')],
              bodyStart,
              bodyEnd,
              EntityType.pre,
              lang: lang,
              caretAfter: caret,
            );
          }
        }
        return null;
      }
      // `code`
      if (at > 0 && t[at - 1] == '`') return null;
      final open = _lastIndexOf(t, '`', at - 1);
      if (open >= lineStart && open < at - 1 && (open == 0 || t[open - 1] != '`')) {
        return _rewrite(v, [(open, open + 1, ''), (at, caret, '')], open + 1, at, EntityType.code, caretAfter: caret);
      }
      return null;
    }
    // [words](address) → a link.
    if (ch == ')') {
      final m = RegExp(r'\[([^\[\]\n]+)\]\(([^()\s]+)\)$').firstMatch(t.substring(lineStart, caret));
      final target = m == null ? null : normalizeLinkTarget(m.group(2)!);
      if (m != null && target != null) {
        final s = lineStart + m.start;
        final wordsEnd = s + 1 + m.group(1)!.length;
        return _rewrite(v, [(s, s + 1, ''), (wordsEnd, caret, '')], s + 1, wordsEnd, EntityType.link, url: target, caretAfter: caret);
      }
      return null;
    }
    for (final MapEntry(key: mk, value: type) in _pairs.entries) {
      if (ch != mk[1] || caret < 2 || !t.startsWith(mk, caret - 2)) continue;
      final close = caret - 2;
      final open = _lastIndexOf(t, mk, close - 1);
      if (open < lineStart || close - open - 2 < 1) continue;
      final inner = t.substring(open + 2, close);
      if (inner.trim() != inner || inner.contains(mk)) continue;
      // `***x**`: the opening is the last two of the stars.
      if (open > 0 && t[open - 1] == mk[0] && open + 2 < close && t[open + 2] != mk[0]) {
        // fine: "a**" before is text
      }
      return _rewrite(v, [(open, open + 2, ''), (close, caret, '')], open + 2, close, type, caretAfter: caret);
    }
    return null;
  }

  /// Remove [cuts] (start, end, '' — in increasing order), give
  /// [start]..[end] (positions before the cuts) the [type], put the caret
  /// at [caretAfter] (also a pre-cut position) with typing that doesn't
  /// continue [type] (or does, [keepTyping]: a quote line).
  TextEditingValue _rewrite(
    TextEditingValue v,
    List<(int, int, String)> cuts,
    int start,
    int end,
    EntityType type, {
    String? url,
    String? lang,
    required int caretAfter,
    bool keepTyping = false,
  }) {
    for (var i = start; i < end; i++) {
      _mask[i] |= type.bit;
      if (type == EntityType.link) _url[i] = url;
      if (type == EntityType.pre) _lang[i] = lang;
    }
    var t = v.text;
    int shift(int p) {
      var d = 0;
      for (final (s, e, _) in cuts) {
        if (p >= e) {
          d += e - s;
        } else if (p > s) {
          d += p - s;
        }
      }
      return p - d;
    }

    for (final (s, e, _) in cuts.reversed) {
      t = t.replaceRange(s, e, '');
      _mask.removeRange(s, e);
      _url.removeRange(s, e);
      _lang.removeRange(s, e);
    }
    final caret = shift(caretAfter);
    final before = caret > 0 && caret - 1 < _mask.length ? _mask[caret - 1] & ~EntityType.link.bit : 0;
    _typing = keepTyping ? (before | type.bit) : (before & ~type.bit & ~codeBits);
    if (type.isBlock && !keepTyping) _typing &= ~blockBits;
    _typingPinnedAt = caret;
    return TextEditingValue(text: t, selection: TextSelection.collapsed(offset: caret));
  }

  // ── Toolbar / shortcuts ───────────────────────────────────────────

  /// Bold, italic… on the selection; with none, for what's typed next.
  /// "Monospace" over several lines makes a code block.
  void toggle(EntityType type, {String? url}) {
    final sel = selection;
    if (!sel.isValid) return;
    if (sel.isCollapsed && !type.isBlock) {
      _typing ^= type.bit;
      _typingPinnedAt = sel.baseOffset;
      notifyListeners();
      return;
    }
    var start = sel.start, end = sel.end;
    var t = type;
    if (t == EntityType.code && text.substring(start, end).contains('\n')) t = EntityType.pre;
    if (t.isBlock) {
      start = _lastIndexOf(text, '\n', start - 1) + 1;
      final e = end > start && text.codeUnitAt(end - 1) == 0x0A ? end - 1 : end;
      final nl = text.indexOf('\n', e);
      end = nl < 0 ? text.length : nl;
      if (end <= start) {
        // An empty line: the quote starts here, for typing.
        _typing ^= t.bit;
        _typingPinnedAt = sel.baseOffset;
        notifyListeners();
        return;
      }
    }
    final on = t == EntityType.link ? url != null : maskOver(start, end) & t.bit == 0;
    for (var i = start; i < end; i++) {
      _mask[i] = on ? _mask[i] | t.bit : _mask[i] & ~t.bit;
      if (t == EntityType.link) _url[i] = on ? url : null;
      if (t == EntityType.pre) _lang[i] = null;
    }
    notifyListeners();
  }

  /// Every style off on the selection (and for typing).
  void clearFormatting() {
    final sel = selection;
    if (!sel.isValid) return;
    for (var i = sel.start; i < sel.end; i++) {
      _mask[i] = 0;
      _url[i] = null;
      _lang[i] = null;
    }
    _typing = 0;
    _typingPinnedAt = sel.isCollapsed ? sel.baseOffset : null;
    notifyListeners();
  }

  /// Bits on for what the toolbar shows / the next character.
  int get activeMask => selection.isValid ? maskOver(selection.start, selection.end) : _typing;

  // ── Painting ──────────────────────────────────────────────────────

  List<StyleRun> _runs(int from, int to) {
    final out = <StyleRun>[];
    var i = from;
    while (i < to) {
      var j = i + 1;
      while (j < to && _mask[j] == _mask[i] && _url[j] == _url[i] && _lang[j] == _lang[i]) {
        j++;
      }
      out.add(StyleRun(i, j, _mask[i], url: _url[i], language: _lang[i]));
      i = j;
    }
    return out;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final t = text;
    if (_mask.length != t.length || !_mask.any((m) => m != 0)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final tokens = DsTheme.of(context);
    final c = value.composing;
    final cuts = <int>{0, t.length};
    final composing = withComposing && c.isValid && !c.isCollapsed && c.end <= t.length;
    if (composing) cuts.addAll([c.start, c.end]);
    final spans = <InlineSpan>[];
    for (final r in _runs(0, t.length)) {
      final inner = [r.start, ...cuts.where((x) => x > r.start && x < r.end), r.end]..sort();
      for (var k = 0; k + 1 < inner.length; k++) {
        final a = inner[k], b = inner[k + 1];
        var st = composerStyle(r.mask, tokens, style);
        if (composing && a >= c.start && b <= c.end) {
          st = st.copyWith(decoration: TextDecoration.combine([?st.decoration, TextDecoration.underline]));
        }
        spans.add(TextSpan(text: t.substring(a, b), style: st));
      }
    }
    return TextSpan(style: style, children: spans);
  }
}

/// How [mask] looks while typing (on the composer's soft background).
TextStyle composerStyle(int mask, DsTokens tokens, TextStyle? base) {
  bool has(EntityType e) => mask & e.bit != 0;
  final decorations = [
    if (has(EntityType.underline) || has(EntityType.link)) TextDecoration.underline,
    if (has(EntityType.strike)) TextDecoration.lineThrough,
  ];
  final mono = has(EntityType.code) || has(EntityType.pre);
  Color? bg;
  if (mono) bg = tokens.text.withValues(alpha: 0.08);
  if (has(EntityType.quote)) bg = tokens.accent.withValues(alpha: 0.10);
  if (has(EntityType.spoiler)) bg = tokens.text.withValues(alpha: 0.16);
  return TextStyle(
    fontWeight: has(EntityType.bold) ? FontWeight.w700 : null,
    fontStyle: has(EntityType.italic) ? FontStyle.italic : null,
    decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
    decorationColor: has(EntityType.link) ? tokens.accent : null,
    color: has(EntityType.link) ? tokens.accent : null,
    fontFamily: mono ? DsType.familyMono : null,
    fontSize: mono && base?.fontSize != null ? base!.fontSize! - 1 : null,
    backgroundColor: bg,
  );
}

/// [String.lastIndexOf] that takes a start before the text (none found).
int _lastIndexOf(String t, String pattern, int start) => start < 0 ? -1 : t.lastIndexOf(pattern, start);

// ── Selection menu ──────────────────────────────────────────────────

/// The composer's copy / paste menu with "Format" (ADR-070).
EditableTextContextMenuBuilder richFormatToolbar(RichTextController controller) =>
    (context, state) => _RichToolbar(controller: controller, state: state);

class _RichToolbar extends StatefulWidget {
  const _RichToolbar({required this.controller, required this.state});
  final RichTextController controller;
  final EditableTextState state;

  @override
  State<_RichToolbar> createState() => _RichToolbarState();
}

class _RichToolbarState extends State<_RichToolbar> {
  bool _format = false;

  EditableTextState get _s => widget.state;

  Widget _button(String label, VoidCallback onTap, {Key? key, bool on = false, TextStyle? style}) =>
      CupertinoTextSelectionToolbarButton(
        key: key,
        onPressed: onTap,
        child: Text(
          label,
          style: DsTextArt.t14v2.merge(style).copyWith(color: on ? DsPalette.sky : null),
        ),
      );

  void _apply(void Function() f) {
    f();
    _s.hideToolbar();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final c = widget.controller;
    final hasSel = c.selection.isValid && !c.selection.isCollapsed;
    final children = <Widget>[];
    if (!_format) {
      if (hasSel) children.add(_button(l.formatMenu, () => setState(() => _format = true), key: const ValueKey('fmt-open')));
      if (_s.cutEnabled) {
        children.add(_button(l.textCut, () {
          rememberSelectionForCopy(c);
          _s.cutSelection(SelectionChangedCause.toolbar);
        }));
      }
      if (_s.copyEnabled) {
        children.add(_button(l.copy, () {
          rememberSelectionForCopy(c);
          _s.copySelection(SelectionChangedCause.toolbar);
        }));
      }
      if (_s.pasteEnabled) children.add(_button(l.textPaste, () => _s.pasteText(SelectionChangedCause.toolbar)));
      if (_s.selectAllEnabled) children.add(_button(l.textSelectAll, () => _s.selectAll(SelectionChangedCause.toolbar)));
    } else {
      final m = c.activeMask;
      bool on(EntityType t) => m & t.bit != 0;
      children.addAll([
        _button(l.formatBold, () => _apply(() => c.toggle(EntityType.bold)),
            key: const ValueKey('fmt-bold'), on: on(EntityType.bold), style: const TextStyle(fontWeight: FontWeight.w700)),
        _button(l.formatItalic, () => _apply(() => c.toggle(EntityType.italic)),
            key: const ValueKey('fmt-italic'), on: on(EntityType.italic), style: const TextStyle(fontStyle: FontStyle.italic)),
        _button(l.formatUnderline, () => _apply(() => c.toggle(EntityType.underline)),
            key: const ValueKey('fmt-underline'),
            on: on(EntityType.underline),
            style: const TextStyle(decoration: TextDecoration.underline, decorationColor: DsPalette.white)),
        _button(l.formatStrike, () => _apply(() => c.toggle(EntityType.strike)),
            key: const ValueKey('fmt-strike'),
            on: on(EntityType.strike),
            style: const TextStyle(decoration: TextDecoration.lineThrough, decorationColor: DsPalette.white)),
        _button(l.formatMono, () => _apply(() => c.toggle(EntityType.code)),
            key: const ValueKey('fmt-mono'),
            on: on(EntityType.code) || on(EntityType.pre),
            style: const TextStyle(fontFamily: DsType.familyMono)),
        _button(l.formatSpoiler, () => _apply(() => c.toggle(EntityType.spoiler)),
            key: const ValueKey('fmt-spoiler'), on: on(EntityType.spoiler)),
        _button(l.formatLink, () {
          _s.hideToolbar();
          editLink(context, c);
        }, key: const ValueKey('fmt-link'), on: on(EntityType.link)),
        _button(l.formatQuote, () => _apply(() => c.toggle(EntityType.quote)),
            key: const ValueKey('fmt-quote'), on: on(EntityType.quote)),
        _button(l.formatClear, () => _apply(c.clearFormatting), key: const ValueKey('fmt-clear')),
      ]);
    }
    if (children.isEmpty) return const SizedBox.shrink();
    return CupertinoAdaptiveTextSelectionToolbar(anchors: _s.contextMenuAnchors, children: children);
  }
}

/// Copy / Cut in the composer: remember the selection's formatting, so
/// pasting it into a composer brings it along.
void rememberSelectionForCopy(RichTextController c) {
  final sel = c.selection;
  if (!sel.isValid || sel.isCollapsed) return;
  RichClipboard.remember(c.formatted.slice(sel.start, sel.end));
}

/// Ask for the address of a link over the selection ("Link": prefilled
/// with the one there, or an address on the clipboard). Empty removes it.
Future<void> editLink(BuildContext context, RichTextController c) async {
  final sel = c.selection;
  if (!sel.isValid || sel.isCollapsed) return;
  var current = c.linkAt(sel.start);
  if (current == null) {
    try {
      final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
      if (clip != null && linkTargetOk(clip)) current = clip;
    } catch (_) {}
  }
  if (!context.mounted) return;
  final picked = await showLinkSheet(context, current: current, hadLink: c.linkAt(sel.start) != null);
  if (picked == null) return;
  c.selection = sel;
  c.toggle(EntityType.link, url: picked.isEmpty ? null : picked);
}

/// The address sheet: resolves to the target, '' to remove the link, or
/// null on cancel.
Future<String?> showLinkSheet(BuildContext context, {String? current, bool hadLink = false}) =>
    showCentredSheet<String>(context, _LinkSheet(current: current, hadLink: hadLink));

class _LinkSheet extends StatefulWidget {
  const _LinkSheet({this.current, required this.hadLink});
  final String? current;
  final bool hadLink;

  @override
  State<_LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends State<_LinkSheet> {
  late final TextEditingController _c = TextEditingController(text: widget.current ?? '');
  bool _bad = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() {
    final target = normalizeLinkTarget(_c.text);
    if (target == null) {
      if (_c.text.trim().isEmpty && widget.hadLink) {
        Navigator.of(context).pop('');
        return;
      }
      setState(() => _bad = true);
      return;
    }
    Navigator.of(context).pop(target);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return DsCentredCard(
      key: const ValueKey('link-sheet'),
      children: [
        Text(l.linkSheetTitle, style: DsText.headline.copyWith(color: tokens.text)),
        const SizedBox(height: DsSpace.x3),
        DsTextField(
          controller: _c,
          hintText: l.linkSheetHint,
          autofocus: true,
          keyboardType: TextInputType.url,
          onSubmitted: (_) => _done(),
          onChanged: (_) {
            if (_bad) setState(() => _bad = false);
          },
        ),
        if (_bad) ...[
          const SizedBox(height: DsSpace.x2),
          Text(l.linkSheetBad, style: DsText.footnote.copyWith(color: tokens.danger)),
        ],
        const SizedBox(height: DsSpace.x4),
        DsButton(key: const ValueKey('link-done'), label: l.linkSheetDone, onPressed: _done),
        if (widget.hadLink) ...[
          const SizedBox(height: DsSpace.x2),
          DsButton(
            key: const ValueKey('link-remove'),
            label: l.linkSheetRemove,
            variant: DsButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(''),
          ),
        ],
        const SizedBox(height: DsSpace.x2),
        DsButton(
          label: l.cancel,
          variant: DsButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

// ── Keyboard shortcuts ──────────────────────────────────────────────

/// ⌘ (Ctrl on Android / Windows keyboards) + B / I / U, ⇧X strike, ⇧M
/// monospace, ⇧P spoiler, K link, ⇧. quote, ⇧N clear — Telegram's keys.
/// Copy / cut keep the formatting for pasting back here.
class RichFormatShortcuts extends StatelessWidget {
  const RichFormatShortcuts({super.key, required this.controller, required this.child});
  final RichTextController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final map = <ShortcutActivator, VoidCallback>{};
    for (final meta in [true, false]) {
      SingleActivator k(LogicalKeyboardKey key, {bool shift = false}) =>
          SingleActivator(key, meta: meta, control: !meta, shift: shift);
      map.addAll({
        k(LogicalKeyboardKey.keyB): () => c.toggle(EntityType.bold),
        k(LogicalKeyboardKey.keyI): () => c.toggle(EntityType.italic),
        k(LogicalKeyboardKey.keyU): () => c.toggle(EntityType.underline),
        k(LogicalKeyboardKey.keyX, shift: true): () => c.toggle(EntityType.strike),
        k(LogicalKeyboardKey.keyM, shift: true): () => c.toggle(EntityType.code),
        k(LogicalKeyboardKey.keyP, shift: true): () => c.toggle(EntityType.spoiler),
        k(LogicalKeyboardKey.period, shift: true): () => c.toggle(EntityType.quote),
        k(LogicalKeyboardKey.keyN, shift: true): c.clearFormatting,
        k(LogicalKeyboardKey.keyK): () => editLink(context, c),
        // Copy / cut keep going to the field itself; the formatting is
        // remembered first.
        k(LogicalKeyboardKey.keyC): () {
          rememberSelectionForCopy(c);
          Actions.maybeInvoke(primaryFocus!.context!, CopySelectionTextIntent.copy);
        },
        k(LogicalKeyboardKey.keyX): () {
          rememberSelectionForCopy(c);
          Actions.maybeInvoke(primaryFocus!.context!, CopySelectionTextIntent.cut(SelectionChangedCause.keyboard));
        },
      });
    }
    return CallbackShortcuts(bindings: map, child: child);
  }
}
