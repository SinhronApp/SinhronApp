// Message text rendering — UI backlog §3 item 30, ADR-070.
//
//   • 1-3 emoji alone → big emoji, no bubble chrome needed
//   • formatting from the message's ranges (lib/core/rich_text.dart):
//     bold, italic, underline, strikethrough, monospace, spoilers (hidden
//     under moving dust until tapped, revealed softly — at once with
//     Reduce Motion), links in words, quotes (a bar at the side) and code
//     blocks (monospace, a Copy button); styles nest freely
//   • a message from an older app has no ranges: its 0.6.0 markers
//     (`*bold*` `_italic_` `` `mono` `` `~strike~` `||spoiler||`) are read
//   • https:// / www. links and phone numbers are tappable — opening goes
//     through [MessageText.onOpenLink] (the chat asks before leaving the
//     app; words whose address differs say so)
//   • `@[<key>]` mentions show as "@Name" ([MentionNames] above in the
//     tree supplies the names; tech-debt 2.21)

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/mentions.dart';
import '../../core/providers/people.dart' show displayNameOf;
import '../../core/rich_text.dart';
import '../../l10n/l10n.dart';

/// Names for `@[<key>]` mentions in message text below it in the tree.
class MentionNames extends InheritedWidget {
  const MentionNames({super.key, required this.nameOf, this.myKey, required super.child});

  final String Function(String identityKeyHex) nameOf;

  /// My identity key — mentions of me stand out.
  final String? myKey;

  static MentionNames? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MentionNames>();

  @override
  bool updateShouldNotify(MentionNames old) => old.nameOf != nameOf || old.myKey != myKey;
}

/// How the chat opens words that lead elsewhere than they say (ADR-070):
/// it shows the real address and asks first. Below it in the tree,
/// [MessageText.onOpenHiddenLink] isn't needed.
class HiddenLinkOpener extends InheritedWidget {
  const HiddenLinkOpener({super.key, required this.open, required super.child});

  final void Function(String url, String shown) open;

  static HiddenLinkOpener? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HiddenLinkOpener>();

  @override
  bool updateShouldNotify(HiddenLinkOpener old) => old.open != open;
}

bool _isEmojiRune(int r) =>
    (r >= 0x1F000 && r <= 0x1FAFF) ||
    (r >= 0x2600 && r <= 0x27BF) ||
    (r >= 0x2300 && r <= 0x23FF) ||
    (r >= 0x2B00 && r <= 0x2BFF) ||
    (r >= 0x2190 && r <= 0x21FF) ||
    (r >= 0x25A0 && r <= 0x25FF) ||
    r == 0x00A9 ||
    r == 0x00AE ||
    r == 0x203C ||
    r == 0x2049 ||
    r == 0x2122 ||
    r == 0x2139 ||
    r == 0x3030 ||
    r == 0x303D ||
    r == 0x3297 ||
    r == 0x3299;

/// Joiners / modifiers that may appear inside an emoji grapheme.
bool _isEmojiGlue(int r) =>
    r == 0x200D ||
    r == 0xFE0F ||
    r == 0xFE0E ||
    r == 0x20E3 ||
    (r >= 0x1F3FB && r <= 0x1F3FF) ||
    (r >= 0xE0020 && r <= 0xE007F);

/// 1-3 emoji and nothing else (whitespace allowed) → shown big.
int bigEmojiCount(String text) {
  final t = text.trim();
  if (t.isEmpty) return 0;
  var n = 0;
  for (final g in t.characters) {
    if (g.trim().isEmpty) continue;
    final runes = g.runes.toList();
    final hasEmoji = runes.any(_isEmojiRune);
    final keycap = runes.length >= 2 && runes.last == 0x20E3;
    if (!(hasEmoji || keycap) || !runes.every((r) => _isEmojiRune(r) || _isEmojiGlue(r) || keycap)) return 0;
    n++;
    if (n > 3) return 0;
  }
  return n;
}

// ── Layout model (pure, tested) ─────────────────────────────────────

enum BlockKind { paragraph, quote, code }

/// One block of a message: a paragraph, a quote or a code block over
/// [start]..[end] of the text.
class TextBlock {
  const TextBlock(this.kind, this.start, this.end, {this.language});
  final BlockKind kind;
  final int start;
  final int end;
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is TextBlock && other.kind == kind && other.start == start && other.end == end && other.language == language;

  @override
  int get hashCode => Object.hash(kind, start, end, language);

  @override
  String toString() => '${kind.name}($start..$end${language == null ? '' : ' $language'})';
}

/// The text cut into blocks. The line break between a block and its
/// neighbour belongs to neither (it's the block edge), so "a\n> q\nb"
/// is three blocks with no blank lines.
List<TextBlock> blocksOf(FormattedText t) {
  final text = t.text;
  final out = <TextBlock>[];
  BlockKind kindOf(StyleRun r) =>
      r.has(EntityType.pre) ? BlockKind.code : (r.has(EntityType.quote) ? BlockKind.quote : BlockKind.paragraph);
  for (final r in t.runs()) {
    final k = kindOf(r);
    final lang = k == BlockKind.code ? r.language : null;
    if (out.isNotEmpty && out.last.kind == k && out.last.end == r.start && out.last.language == lang) {
      out[out.length - 1] = TextBlock(k, out.last.start, r.end, language: lang);
    } else {
      out.add(TextBlock(k, r.start, r.end, language: lang));
    }
  }
  bool nl(int i) => i >= 0 && i < text.length && text.codeUnitAt(i) == 0x0A;
  final trimmed = <TextBlock>[];
  for (var i = 0; i < out.length; i++) {
    var b = out[i];
    var s = b.start, e = b.end;
    final prevBlock = i > 0 && out[i - 1].kind != BlockKind.paragraph;
    final nextBlock = i + 1 < out.length && out[i + 1].kind != BlockKind.paragraph;
    if (b.kind == BlockKind.paragraph) {
      if (prevBlock && nl(s)) s++;
      if (nextBlock && e > s && nl(e - 1)) e--;
    } else {
      // A block's own edge line breaks.
      while (e > s && nl(e - 1)) {
        e--;
      }
      while (s < e && nl(s)) {
        s++;
      }
      if (i + 1 < out.length && out[i + 1].kind == BlockKind.paragraph && nl(b.end)) {
        // "…quote\nnext" — the break after the block is its edge too.
        final n = out[i + 1];
        if (n.start == b.end) out[i + 1] = TextBlock(n.kind, n.start + 1, n.end);
      }
    }
    if (e > s || b.kind != BlockKind.paragraph) {
      if (e > s) trimmed.add(TextBlock(b.kind, s, e, language: b.language));
    }
  }
  return trimmed;
}

/// Something tappable found in the text itself: a web address, a phone
/// number or a mention.
class AutoMark {
  const AutoMark(this.kind, this.start, this.end, this.target);

  /// 'link' / 'phone' / 'mention' (target = the identity key).
  final String kind;
  final int start;
  final int end;
  final String target;

  @override
  bool operator ==(Object other) =>
      other is AutoMark && other.kind == kind && other.start == start && other.end == end && other.target == target;

  @override
  int get hashCode => Object.hash(kind, start, end, target);

  @override
  String toString() => '$kind($start..$end → $target)';
}

/// Addresses, phone numbers and mentions in [t] — never inside code.
List<AutoMark> autoMarksOf(FormattedText t) {
  final text = t.text;
  final runs = t.runs();
  bool inCode(int s, int e) => runs.any((r) => r.start < e && r.end > s && r.mask & codeBits != 0);
  final out = <AutoMark>[];
  bool free(int s, int e) => !out.any((m) => m.start < e && m.end > s);
  for (final m in mentionToken.allMatches(text)) {
    if (!inCode(m.start, m.end)) out.add(AutoMark('mention', m.start, m.end, m.group(1)!));
  }
  for (final m in linkPattern.allMatches(text)) {
    if (inCode(m.start, m.end) || !free(m.start, m.end)) continue;
    final whole = m.group(0)!;
    out.add(AutoMark('link', m.start, m.end, whole.toLowerCase().startsWith('www.') ? 'https://$whole' : whole));
  }
  for (final m in phonePattern.allMatches(text)) {
    if (inCode(m.start, m.end) || !free(m.start, m.end)) continue;
    final digits = m.group(0)!.replaceAll(RegExp(r'[^\d+]'), '');
    // Too few digits for a phone (dates, amounts) → plain text.
    if (digits.replaceAll('+', '').length < 9) continue;
    out.add(AutoMark('phone', m.start, m.end, 'tel:$digits'));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// Words that lead somewhere other than what they say (Telegram's "open
/// this link?" case): the shown text isn't the address itself.
bool linkTextDiffers(String shown, String url) {
  String bare(String s) => s
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^(https?://|mailto:|tel:)'), '')
      .replaceFirst(RegExp(r'^www\.'), '')
      .replaceFirst(RegExp(r'/$'), '');
  return bare(shown) != bare(url);
}

// ── Widget ──────────────────────────────────────────────────────────

/// Renders [text] with its formatting; links / phones call [onOpenLink].
class MessageText extends StatefulWidget {
  const MessageText({
    super.key,
    required this.text,
    this.entities,
    required this.style,
    required this.linkColor,
    this.onOpenLink,
    this.onOpenHiddenLink,
    this.trailing,
    this.maxLines,
  });

  final String text;

  /// The message's ranges; null = an older app's message (markers read).
  final List<TextEntity>? entities;
  final TextStyle style;
  final Color linkColor;
  final ValueChanged<String>? onOpenLink;

  /// Words whose address differs from them: (address, the words). Falls
  /// back to [onOpenLink].
  final void Function(String url, String shown)? onOpenHiddenLink;

  /// Inline widget after the last word (time + ticks).
  final InlineSpan? trailing;

  /// Set: one compact paragraph (previews) — quotes and code inline.
  final int? maxLines;

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> with TickerProviderStateMixin {
  final _recognizers = <GestureRecognizer>[];
  late FormattedText _ft;
  late List<StyleRun> _runs;
  late List<AutoMark> _marks;
  late List<TextBlock> _blocks;
  late final AnimationController _reveal = AnimationController(vsync: this, duration: DsMotion.slow)
    ..addListener(() => setState(() {}));
  AnimationController? _drift;
  Offset? _revealFrom;
  bool _revealed = false;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  void _parse() {
    _ft = widget.entities == null
        ? FormattedText.legacy(widget.text)
        : FormattedText(widget.text, widget.entities!).normalized();
    _runs = _ft.runs();
    _marks = autoMarksOf(_ft);
    _blocks = blocksOf(_ft);
  }

  bool get _hasSpoiler => _ft.entities.any((e) => e.type == EntityType.spoiler);

  @override
  void didUpdateWidget(MessageText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text || !_sameEntities(old.entities, widget.entities)) {
      _parse();
      _revealed = false;
      _reveal.value = 0;
    }
  }

  static bool _sameEntities(List<TextEntity>? a, List<TextEntity>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _reveal.dispose();
    _drift?.dispose();
    super.dispose();
  }

  void _revealSpoilers(Offset? globalTap) {
    if (_revealed) return;
    setState(() {
      _revealed = true;
      _revealFrom = globalTap;
    });
    if (DsMotion.reduced(context)) {
      _reveal.value = 1;
    } else {
      _reveal.forward(from: 0);
    }
  }

  /// Dust moves while a spoiler is hidden (not with Reduce Motion).
  AnimationController? _driftFor(bool hidden) {
    if (!hidden || DsMotion.reduced(context)) {
      _drift?.stop();
      return _drift;
    }
    final d = _drift ??= AnimationController(vsync: this, duration: const Duration(seconds: 6));
    if (!d.isAnimating) d.repeat();
    return d;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final hidden = _hasSpoiler && _reveal.value < 1;
    final drift = _driftFor(hidden);
    if (widget.maxLines != null || (_blocks.length <= 1 && (_blocks.isEmpty || _blocks.first.kind == BlockKind.paragraph))) {
      return _paragraph(0, _ft.text.length, widget.style, widget.trailing, drift, maxLines: widget.maxLines);
    }
    final children = <Widget>[];
    for (var i = 0; i < _blocks.length; i++) {
      final b = _blocks[i];
      final last = i == _blocks.length - 1;
      final trailing = last && b.kind != BlockKind.code ? widget.trailing : null;
      if (i > 0) children.add(const SizedBox(height: DsSpace.x1));
      switch (b.kind) {
        case BlockKind.paragraph:
          children.add(_paragraph(b.start, b.end, widget.style, trailing, drift));
        case BlockKind.quote:
          children.add(_QuoteBlock(color: widget.linkColor, child: _paragraph(b.start, b.end, widget.style, trailing, drift)));
        case BlockKind.code:
          children.add(
            _CodeBlock(
              code: _ft.text.substring(b.start, b.end),
              language: b.language,
              style: widget.style,
              child: _paragraph(b.start, b.end, widget.style, null, drift),
            ),
          );
      }
    }
    if (_blocks.isNotEmpty && _blocks.last.kind == BlockKind.code && widget.trailing != null) {
      children.add(Align(alignment: AlignmentDirectional.centerEnd, child: Text.rich(TextSpan(children: [widget.trailing!]))));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);
  }

  /// One paragraph of [start]..[end]: spans, plus the dust over hidden
  /// spoilers.
  Widget _paragraph(int start, int end, TextStyle base, InlineSpan? trailing, Animation<double>? drift, {int? maxLines}) {
    final spoilers = <TextRange>[];
    final spans = _spans(start, end, base, spoilers);
    if (trailing != null) spans.add(trailing);
    final text = Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
    );
    if (spoilers.isEmpty || _reveal.value >= 1) return text;
    return _SpoilerVeil(
      ranges: spoilers,
      color: base.color ?? const Color.fromRGBO(0, 0, 0, 1),
      drift: drift,
      reveal: Curves.easeOut.transform(_reveal.value),
      revealFrom: _revealFrom,
      child: text,
    );
  }

  /// Spans of [start]..[end]. [spoilers] gets the rendered offsets of
  /// hidden spoiler text (for the dust).
  List<InlineSpan> _spans(int start, int end, TextStyle base, List<TextRange> spoilers) {
    final text = _ft.text;
    final cuts = <int>{start, end};
    final runs = _runs.where((r) => r.end > start && r.start < end).toList();
    for (final r in runs) {
      cuts
        ..add(r.start.clamp(start, end))
        ..add(r.end.clamp(start, end));
    }
    final marks = _marks.where((m) => m.start >= start && m.end <= end).toList();
    for (final m in marks) {
      cuts
        ..add(m.start)
        ..add(m.end);
    }
    final points = cuts.toList()..sort();
    final out = <InlineSpan>[];
    var rendered = 0;
    final reveal = _reveal.value;
    // Pieces, runs and marks are all in order: walk them together.
    var ri = 0, mi = 0;
    for (var k = 0; k + 1 < points.length; k++) {
      final a = points[k], b = points[k + 1];
      if (b <= a) continue;
      while (ri < runs.length && runs[ri].end <= a) {
        ri++;
      }
      while (mi < marks.length && marks[mi].end <= a) {
        mi++;
      }
      final run = ri < runs.length && runs[ri].start <= a ? runs[ri] : StyleRun(a, b, 0);
      final mark = mi < marks.length && marks[mi].start <= a ? marks[mi] : null;
      var piece = text.substring(a, b);
      var style = _styleOf(run, base);
      GestureRecognizer? recognizer;
      String? semantics;
      if (mark != null && mark.kind == 'mention') {
        // Only the first piece of a mention shows "@Name".
        if (a != mark.start) continue;
        final names = MentionNames.maybeOf(context);
        final key = mark.target;
        final name = names?.nameOf(key) ?? displayNameOf(key, const {});
        piece = '@$name';
        style = style.merge(
          TextStyle(
            color: widget.linkColor,
            fontWeight: FontWeight.w600,
            backgroundColor: names?.myKey == key ? widget.linkColor.withValues(alpha: 0.16) : null,
          ),
        );
      } else if (run.has(EntityType.link) || mark != null) {
        final target = run.url ?? mark!.target;
        final shown = run.has(EntityType.link) ? _wordsOf(run) : piece;
        final hiddenOpen = widget.onOpenHiddenLink ?? HiddenLinkOpener.maybeOf(context)?.open;
        final r = TapGestureRecognizer()
          ..onTap = () {
            if (run.has(EntityType.link) && linkTextDiffers(shown, target) && hiddenOpen != null && widget.onOpenLink != null) {
              hiddenOpen(target, shown);
            } else {
              widget.onOpenLink?.call(target);
            }
          };
        _recognizers.add(r);
        recognizer = r;
        style = style.merge(
          TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.combine([?style.decoration, TextDecoration.underline]),
            decorationColor: widget.linkColor,
          ),
        );
      }
      if (run.has(EntityType.spoiler) && reveal < 1) {
        // Hidden: the words are there (layout), invisible under the dust.
        final c = style.color ?? base.color ?? const Color.fromRGBO(0, 0, 0, 1);
        style = style.copyWith(color: c.withValues(alpha: c.a * reveal), decorationColor: c.withValues(alpha: 0));
        if (!_revealed) {
          final r = TapGestureRecognizer()..onTapUp = (d) => _revealSpoilers(d.globalPosition);
          _recognizers.add(r);
          recognizer = r;
          semantics = context.l10n.a11ySpoiler;
        }
        spoilers.add(TextRange(start: rendered, end: rendered + piece.length));
      }
      out.add(TextSpan(text: piece, style: style, recognizer: recognizer, semanticsLabel: semantics));
      rendered += piece.length;
    }
    return out;
  }

  /// All the words of the link [run] is part of.
  String _wordsOf(StyleRun run) {
    for (final e in _ft.entities) {
      if (e.type == EntityType.link && e.offset <= run.start && e.end >= run.end) {
        return _ft.text.substring(e.offset, e.end);
      }
    }
    return _ft.text.substring(run.start, run.end);
  }

  TextStyle _styleOf(StyleRun r, TextStyle base) {
    bool has(EntityType e) => r.mask & e.bit != 0;
    final decorations = [
      if (has(EntityType.underline)) TextDecoration.underline,
      if (has(EntityType.strike)) TextDecoration.lineThrough,
    ];
    final code = has(EntityType.code);
    final pre = has(EntityType.pre);
    final fg = base.color ?? const Color.fromRGBO(0, 0, 0, 1);
    return TextStyle(
      fontWeight: has(EntityType.bold) ? FontWeight.w700 : null,
      fontStyle: has(EntityType.italic) ? FontStyle.italic : null,
      decoration: decorations.isEmpty ? null : TextDecoration.combine(decorations),
      decorationColor: decorations.isEmpty ? null : fg,
      fontFamily: code || pre ? DsType.familyMono : null,
      fontSize: (code || pre) && base.fontSize != null ? base.fontSize! - 1.5 : null,
      backgroundColor: code ? fg.withValues(alpha: 0.10) : null,
    );
  }
}

/// A quote: a bar at the side, a light tint of [color].
class _QuoteBlock extends StatelessWidget {
  const _QuoteBlock({required this.color, required this.child});
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: context.l10n.a11yQuote,
      child: Container(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(DsSpace.x1h5),
          border: BorderDirectional(start: BorderSide(color: color, width: DsSpace.nudge3)),
        ),
        padding: const EdgeInsetsDirectional.fromSTEB(DsSpace.x2h5, DsSpace.x1, DsSpace.x2, DsSpace.x1),
        child: child,
      ),
    );
  }
}

/// A code block: monospace on a tint, its language and a Copy button.
class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.code, required this.language, required this.style, required this.child});
  final String code;
  final String? language;
  final TextStyle style;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fg = style.color ?? const Color.fromRGBO(0, 0, 0, 1);
    final small = DsText.caption.copyWith(color: fg.withValues(alpha: 0.7), fontWeight: FontWeight.w600);
    return Semantics(
      label: context.l10n.a11yCodeBlock,
      child: Container(
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(DsSpace.x2),
          border: Border.all(color: fg.withValues(alpha: 0.12), width: 0.5),
        ),
        padding: const EdgeInsets.fromLTRB(DsSpace.x2h5, DsSpace.x1h5, DsSpace.x2h5, DsSpace.x2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: Text(language ?? '', style: small, maxLines: 1, overflow: TextOverflow.ellipsis)),
                GestureDetector(
                  key: const ValueKey('code-copy'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: code));
                    if (context.mounted) showDone(context.l10n.codeCopied);
                  },
                  child: Semantics(
                    button: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1, vertical: DsSpace.x0h5),
                      child: Text(context.l10n.codeCopy, style: small),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: DsSpace.x1),
            // Long lines wrap (a phone is narrow); spaces stay as typed.
            child,
          ],
        ),
      ),
    );
  }
}

// ── Spoiler dust ────────────────────────────────────────────────────

/// Grain for the spoiler dust, made once (64×64, white specks of varying
/// strength). Until it's ready a hidden spoiler shows as a soft tint.
class _Dust {
  static ui.Image? image;
  static bool _started = false;

  static void ensure(VoidCallback onReady) {
    if (image != null || _started) return;
    _started = true;
    const n = 64;
    final px = Uint8List(n * n * 4);
    final rnd = math.Random(70);
    for (var i = 0; i < n * n; i++) {
      final on = rnd.nextDouble() < 0.28;
      px[i * 4] = 255;
      px[i * 4 + 1] = 255;
      px[i * 4 + 2] = 255;
      px[i * 4 + 3] = on ? 90 + rnd.nextInt(165) : 0;
    }
    ui.decodeImageFromPixels(px, n, n, ui.PixelFormat.rgba8888, (img) {
      image = img;
      onReady();
    });
  }
}

/// Paints dust over the hidden spoiler [ranges] of the paragraph below it
/// (offsets in the paragraph's own text). [reveal] 0 → 1 clears it,
/// spreading from [revealFrom] (the tap), as the words fade in.
class _SpoilerVeil extends SingleChildRenderObjectWidget {
  const _SpoilerVeil({
    required this.ranges,
    required this.color,
    required this.drift,
    required this.reveal,
    this.revealFrom,
    required super.child,
  });

  final List<TextRange> ranges;
  final Color color;

  /// 0 → 1, repeating: the dust drifts (null: still).
  final Animation<double>? drift;
  final double reveal;
  final Offset? revealFrom;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSpoilerVeil(ranges, color, drift, reveal, revealFrom);

  @override
  void updateRenderObject(BuildContext context, _RenderSpoilerVeil r) {
    r
      ..ranges = ranges
      ..color = color
      ..drift = drift
      ..reveal = reveal
      ..revealFrom = revealFrom
      ..markNeedsPaint();
  }
}

class _RenderSpoilerVeil extends RenderProxyBox {
  _RenderSpoilerVeil(this.ranges, this.color, this._drift, this.reveal, this.revealFrom) {
    _Dust.ensure(() {
      if (attached) markNeedsPaint();
    });
  }

  List<TextRange> ranges;
  Color color;
  double reveal;
  Offset? revealFrom;

  // Only a repaint per frame of drift — never a new layout.
  Animation<double>? _drift;
  set drift(Animation<double>? d) {
    if (d == _drift) return;
    if (attached) _drift?.removeListener(markNeedsPaint);
    _drift = d;
    if (attached) _drift?.addListener(markNeedsPaint);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _drift?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _drift?.removeListener(markNeedsPaint);
    super.detach();
  }

  RenderParagraph? _paragraph(RenderObject? r) {
    if (r == null || r is RenderParagraph) return r as RenderParagraph?;
    RenderParagraph? found;
    r.visitChildren((c) => found ??= _paragraph(c));
    return found;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final p = _paragraph(child);
    if (p == null || !p.hasSize || reveal >= 1) return;
    final shift = p.localToGlobal(Offset.zero, ancestor: this);
    final canvas = context.canvas;
    final boxes = <Rect>[
      for (final r in ranges)
        for (final b in p.getBoxesForSelection(TextSelection(baseOffset: r.start, extentOffset: r.end)))
          b.toRect().shift(offset + shift).inflate(1),
    ];
    if (boxes.isEmpty) return;
    final fade = 1 - reveal;
    final from = revealFrom == null ? null : globalToLocal(revealFrom!) + offset;
    var radius = 0.0;
    if (from != null && reveal > 0) {
      final far = boxes.fold<double>(0, (m, b) => math.max(m, (b.center - from).distance + b.longestSide));
      radius = far * reveal;
    }
    canvas.save();
    if (radius > 0) {
      // The dust clears outward from the tap.
      final all = boxes.reduce((a, b) => a.expandToInclude(b)).inflate(DsSpace.x1);
      canvas.clipPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect(all),
          Path()..addOval(Rect.fromCircle(center: from!, radius: radius)),
        ),
      );
    }
    final drift = _drift?.value ?? 0;
    final tint = Paint()..color = color.withValues(alpha: 0.10 * fade);
    final img = _Dust.image;
    final dust = img == null
        ? null
        : (Paint()
            ..shader = ui.ImageShader(
              img,
              TileMode.repeated,
              TileMode.repeated,
              (Matrix4.identity()
                    ..translateByDouble(math.sin(drift * 2 * math.pi) * 6, -drift * 64, 0, 1)
                    ..scaleByDouble(0.5, 0.5, 1, 1))
                  .storage,
            )
            ..colorFilter = ColorFilter.mode(color.withValues(alpha: color.a * fade), BlendMode.srcIn));
    for (final b in boxes) {
      final rr = RRect.fromRectAndRadius(b, const Radius.circular(DsSpace.x1));
      canvas.drawRRect(rr, tint);
      if (dust != null) canvas.drawRRect(rr, dust);
    }
    canvas.restore();
  }
}
