// Formatted message text — ADR-070.
//
// A message is clean text plus formatted ranges ("entities", the way
// Telegram does it): `FormattedText('Hello world', [bold 0..5])`. The text
// itself never carries markers, so search, the chat list, notifications,
// reply quotes and older apps all see plain words. Offsets and lengths
// count UTF-16 code units — what Dart strings index by (an emoji is 2).
//
// On the wire the ranges travel beside the text inside the encrypted
// envelope (`TextBody.entities`, Rust `envelope.rs`); between Dart and
// Rust and in the local database as JSON: `[{"t":"bold","o":0,"l":5}]`
// (`"url"` for links, `"lang"` for code blocks). JSON `null` (no
// `entities_json`) means an older app sent it: its `*stars*` may be the
// markers 0.6.0 rendered — [FormattedText.stored] reads those.

import 'dart:convert';

import 'mentions.dart';

enum EntityType {
  bold('bold'),
  italic('italic'),
  underline('underline'),
  strike('strike'),

  /// Inline monospace.
  code('code'),

  /// A code block — whole lines, monospace, with a copy button.
  pre('pre'),
  spoiler('spoiler'),

  /// Words that lead to [TextEntity.url].
  link('link'),

  /// A quote block — whole lines, with a bar at the side.
  quote('quote');

  const EntityType(this.wire);

  /// Name in the JSON form.
  final String wire;

  int get bit => 1 << index;

  /// Spans whole lines and renders as its own block.
  bool get isBlock => this == pre || this == quote;

  static EntityType? fromWire(String name) {
    for (final t in values) {
      if (t.wire == name) return t;
    }
    return null;
  }
}

/// Bits of the block kinds (code block, quote).
final int blockBits = EntityType.pre.bit | EntityType.quote.bit;

/// Bits inside which nothing else is read as formatting (code).
final int codeBits = EntityType.code.bit | EntityType.pre.bit;

class TextEntity {
  const TextEntity(this.type, this.offset, this.length, {this.url, this.language});

  final EntityType type;
  final int offset;
  final int length;

  /// [EntityType.link] only.
  final String? url;

  /// [EntityType.pre] only ("dart", may be null).
  final String? language;

  int get end => offset + length;

  Map<String, Object> toJson() => {
    't': type.wire,
    'o': offset,
    'l': length,
    if (type == EntityType.link && url != null) 'url': url!,
    if (type == EntityType.pre && language != null && language!.isNotEmpty) 'lang': language!,
  };

  static TextEntity? fromJson(Object? j) {
    if (j is! Map) return null;
    final type = EntityType.fromWire('${j['t']}');
    final o = j['o'], l = j['l'];
    if (type == null || o is! int || l is! int) return null;
    final url = j['url'], lang = j['lang'];
    return TextEntity(
      type,
      o,
      l,
      url: type == EntityType.link && url is String ? url : null,
      language: type == EntityType.pre && lang is String && lang.isNotEmpty ? lang : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TextEntity &&
      other.type == type &&
      other.offset == offset &&
      other.length == length &&
      other.url == url &&
      other.language == language;

  @override
  int get hashCode => Object.hash(type, offset, length, url, language);

  @override
  String toString() =>
      '${type.wire}($offset+$length${url == null ? '' : ' → $url'}${language == null ? '' : ' $language'})';
}

/// A stretch of text with one set of styles ([FormattedText.runs]).
class StyleRun {
  const StyleRun(this.start, this.end, this.mask, {this.url, this.language});
  final int start;
  final int end;

  /// [EntityType.bit]s that apply.
  final int mask;
  final String? url;
  final String? language;

  bool has(EntityType t) => mask & t.bit != 0;

  bool sameStyle(StyleRun o) => o.mask == mask && o.url == url && o.language == language;

  @override
  bool operator ==(Object other) =>
      other is StyleRun && other.start == start && other.end == end && sameStyle(other);

  @override
  int get hashCode => Object.hash(start, end, mask, url, language);

  @override
  String toString() =>
      'run($start..$end ${[for (final t in EntityType.values) if (has(t)) t.wire].join('+')}'
      '${url == null ? '' : ' → $url'})';
}

/// A link target we open: web, mail, phone (the same rule as Rust's
/// `entity_url_ok` — anything else is dropped, the words stay).
bool linkTargetOk(String url) {
  final lower = url.toLowerCase();
  if (url.isEmpty || url.length > 2048 || RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(url)) return false;
  for (final p in const ['https://', 'http://', 'mailto:', 'tel:']) {
    if (lower.startsWith(p) && lower.length > p.length) return true;
  }
  return false;
}

/// What the person typed as an address → a target to store ("ya.ru" →
/// "https://ya.ru"); null if it isn't one.
String? normalizeLinkTarget(String input) {
  final t = input.trim();
  if (t.isEmpty) return null;
  if (linkTargetOk(t)) return t;
  if (RegExp(r'^[\w.+-]+@[\w-]+(\.[\w-]+)+$').hasMatch(t)) return 'mailto:$t';
  if (RegExp(r'^\+?[\d\s()-]{7,}$').hasMatch(t)) return 'tel:${t.replaceAll(RegExp(r'[^\d+]'), '')}';
  if (!t.contains(RegExp(r'\s')) && t.contains('.') && !t.contains('://')) {
    final u = 'https://$t';
    return linkTargetOk(u) ? u : null;
  }
  return null;
}

class FormattedText {
  const FormattedText(this.text, [this.entities = const []]);

  /// No formatting.
  const FormattedText.plain(this.text) : entities = const [];

  final String text;
  final List<TextEntity> entities;

  static const empty = FormattedText('');

  /// A stored / received message: [entitiesJson] null → an older app's
  /// text, whose 0.6.0 markers (`*bold*` `_italic_` `` `mono` `` `~strike~`
  /// `||spoiler||`) become formatting here.
  factory FormattedText.stored(String body, String? entitiesJson) {
    if (entitiesJson == null) return FormattedText.legacy(body);
    return FormattedText(body, parseEntities(entitiesJson)).normalized();
  }

  /// 0.6.0's markers → clean text + ranges. One left-to-right pass, no
  /// nesting; links, phone numbers and mentions are never read as markers.
  factory FormattedText.legacy(String text) {
    // The pass below is quadratic: a long text stays plain (audit T01).
    if (text.length > 4096) return FormattedText(text);
    final out = StringBuffer();
    final ents = <TextEntity>[];
    var pos = 0;
    while (pos < text.length) {
      (EntityType?, RegExpMatch)? best;
      for (final (type, re) in _legacyPatterns) {
        final m = re.firstMatch(text.substring(pos));
        if (m == null) continue;
        if (best == null || m.start < best.$2.start) best = (type, m);
      }
      if (best == null) {
        out.write(text.substring(pos));
        break;
      }
      final (type, m) = best;
      out.write(text.substring(pos, pos + m.start));
      if (type == null) {
        out.write(m.group(0));
      } else {
        final inner = m.group(1)!;
        ents.add(TextEntity(type, out.length, inner.length));
        out.write(inner);
      }
      pos += m.end;
    }
    return FormattedText(out.toString(), ents);
  }

  /// Markdown pasted from another app (an AI's answer, notes) → clean text
  /// + ranges. What Sinhron has no form for is written plainly: a heading
  /// is a bold line, `- item` is `• item`, a table row is its cells joined
  /// by ` · ` (the header row bold), `---` is a dash line. `__x__` is
  /// italic, as typed in Sinhron and as [toMarkdown] writes it.
  factory FormattedText.markdown(String md) {
    final lines = md.replaceAll('\r\n', '\n').split('\n');
    var out = FormattedText.empty;
    var any = false;
    var lastQuote = false;
    void add(FormattedText line, {bool quote = false}) {
      if (any) {
        out += quote && lastQuote
            ? const FormattedText('\n', [TextEntity(EntityType.quote, 0, 1)])
            : const FormattedText('\n');
      }
      out += quote ? _wrap(line, EntityType.quote) : line;
      any = true;
      lastQuote = quote;
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final fence = _mdFence.firstMatch(line);
      if (fence != null) {
        final mark = fence.group(1)!;
        final body = <String>[];
        var j = i + 1;
        while (j < lines.length && !_closesFence(lines[j], mark)) {
          body.add(lines[j]);
          j++;
        }
        i = j;
        final code = body.join('\n');
        if (code.isNotEmpty) {
          final lang = fence.group(2)!;
          add(FormattedText(code, [
            TextEntity(EntityType.pre, 0, code.length, language: lang.isEmpty ? null : lang),
          ]));
        }
        continue;
      }
      final heading = _mdHeading.firstMatch(line);
      if (heading != null) {
        add(_wrap(_mdInline(heading.group(1)!), EntityType.bold));
        continue;
      }
      if (_mdRule.hasMatch(line)) {
        add(const FormattedText('———'));
        continue;
      }
      final quote = _mdQuote.firstMatch(line);
      if (quote != null) {
        add(_mdInline(quote.group(1)!), quote: true);
        continue;
      }
      final item = _mdBullet.firstMatch(line);
      if (item != null) {
        final rest = item.group(2)!;
        final task = RegExp(r'^\[([ xX])\]\s+').firstMatch(rest);
        final mark = task == null ? '• ' : (task.group(1) == ' ' ? '☐ ' : '☑ ');
        add(FormattedText.plain('${item.group(1)}$mark') + _mdInline(task == null ? rest : rest.substring(task.end)));
        continue;
      }
      final numbered = _mdNumbered.firstMatch(line);
      if (numbered != null) {
        add(FormattedText.plain('${numbered.group(1)}${numbered.group(2)}. ') + _mdInline(numbered.group(3)!));
        continue;
      }
      if (_mdTableRule.hasMatch(line)) continue;
      final row = _mdTableRow.firstMatch(line);
      if (row != null) {
        final cells = [for (final c in row.group(1)!.split('|')) c.trim()];
        var joined = FormattedText.empty;
        for (var k = 0; k < cells.length; k++) {
          if (k > 0) joined += const FormattedText(' · ');
          joined += _mdInline(cells[k]);
        }
        final header = i + 1 < lines.length && _mdTableRule.hasMatch(lines[i + 1]);
        add(header ? _wrap(joined, EntityType.bold) : joined);
        continue;
      }
      add(_mdInline(line));
    }
    return out.normalized();
  }

  static final _mdFence = RegExp(r'^\s*(`{3,}|~{3,})\s*([\w+#.-]*)\s*$');
  static final _mdHeading = RegExp(r'^\s{0,3}#{1,6}\s+(.*?)(?:\s+#+)?\s*$');
  static final _mdRule = RegExp(r'^\s{0,3}([-*_])(?:\s*\1){2,}\s*$');
  static final _mdQuote = RegExp(r'^\s{0,3}>\s?(.*)$');
  static final _mdBullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  static final _mdNumbered = RegExp(r'^(\s*)(\d{1,9})[.)]\s+(.*)$');
  static final _mdTableRule = RegExp(r'^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$');
  static final _mdTableRow = RegExp(r'^\s*\|(.*)\|\s*$');

  static bool _closesFence(String line, String mark) {
    final t = line.trim();
    return t.length >= mark.length && t.startsWith(mark[0] * mark.length) && t.replaceAll(mark[0], '').isEmpty;
  }

  static FormattedText _wrap(FormattedText t, EntityType type, {String? url}) =>
      t.text.isEmpty ? t : FormattedText(t.text, [...t.entities, TextEntity(type, 0, t.text.length, url: url)]);

  /// One line's inline Markdown, nested: `**bold `code` inside**`.
  static FormattedText _mdInline(String s) {
    var out = FormattedText.empty;
    var pos = 0;
    while (pos < s.length) {
      final rest = s.substring(pos);
      (_Md, RegExpMatch)? best;
      for (final (kind, re) in _mdInlinePatterns) {
        final m = re.firstMatch(rest);
        if (m != null && (best == null || m.start < best.$2.start)) best = (kind, m);
      }
      if (best == null) {
        out += FormattedText.plain(rest);
        break;
      }
      final (kind, m) = best;
      out += FormattedText.plain(rest.substring(0, m.start));
      out += switch (kind) {
        _Md.literal => FormattedText.plain(m.group(0)!),
        _Md.escape => FormattedText.plain(m.group(1)!),
        _Md.code => _wrap(FormattedText.plain(m.group(1)!), EntityType.code),
        _Md.link =>
          linkTargetOk(m.group(2)!) ? _wrap(_mdInline(m.group(1)!), EntityType.link, url: m.group(2)) : _mdInline(m.group(1)!),
        _Md.bold => _wrap(_mdInline(m.group(1)!), EntityType.bold),
        _Md.strike => _wrap(_mdInline(m.group(1)!), EntityType.strike),
        _Md.italic => _wrap(_mdInline(m.group(1)!), EntityType.italic),
      };
      pos += m.end;
    }
    return out;
  }

  // Earliest match wins; on a tie, the one listed first.
  static final _mdInlinePatterns = <(_Md, RegExp)>[
    (_Md.escape, RegExp(r'\\([\\`*_{}\[\]()#+\-.!~|>])')),
    (_Md.code, RegExp(r'`([^`\n]+)`')),
    (_Md.link, RegExp(r'\[([^\]\n]+)\]\(([^)\s]+)\)')),
    (_Md.literal, linkPattern),
    (_Md.bold, RegExp(r'\*\*(?!\s)(.+?)(?<!\s)\*\*')),
    (_Md.strike, RegExp(r'~~(?!\s)(.+?)(?<!\s)~~')),
    (_Md.italic, RegExp(r'(?<![\w_])__(?!\s)(.+?)(?<!\s)__(?![\w_])')),
    (_Md.italic, RegExp(r'(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])')),
    (_Md.italic, RegExp(r'(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])')),
  ];

  static final _legacyPatterns = <(EntityType?, RegExp)>[
    // Kept as they are (null): never markers.
    (null, mentionToken),
    (null, linkPattern),
    (EntityType.code, RegExp(r'`([^`\n]+)`')),
    (EntityType.spoiler, RegExp(r'\|\|([^|\n]+)\|\|')),
    (EntityType.bold, RegExp(r'(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])')),
    (EntityType.italic, RegExp(r'(?<![\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?![\w_])')),
    (EntityType.strike, RegExp(r'(?<![\w~])~(?!\s)([^~\n]+?)(?<!\s)~(?![\w~])')),
  ];

  static List<TextEntity> parseEntities(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final list = jsonDecode(json);
      if (list is! List) return const [];
      return [for (final j in list) ?TextEntity.fromJson(j)];
    } catch (_) {
      return const [];
    }
  }

  /// The JSON form for Rust / the database (`[]` when plain).
  String get entitiesJson => jsonEncode([for (final e in normalized().entities) e.toJson()]);

  bool get hasFormatting => entities.isNotEmpty;

  bool get isEmpty => text.isEmpty;

  // ── Runs ──────────────────────────────────────────────────────────

  /// The text cut into stretches of one style each, covering all of it
  /// (unformatted stretches have mask 0). Ranges are clipped to the text
  /// and to whole characters; a link or code block nested in another
  /// takes the inner one's target / language.
  List<StyleRun> runs() {
    final len = text.length;
    if (len == 0) return const [];
    final events = <(int, int, int)>[]; // (pos, +1 start / -1 end, entity index)
    final clean = <TextEntity>[];
    for (final e in entities) {
      var s = e.offset.clamp(0, len), t = e.end.clamp(0, len);
      s = _snapBack(s);
      t = _snapForward(t);
      if (t <= s) continue;
      if (e.type == EntityType.link && (e.url == null || !linkTargetOk(e.url!))) continue;
      final i = clean.length;
      clean.add(TextEntity(e.type, s, t - s, url: e.url, language: e.language));
      events
        ..add((s, 1, i))
        ..add((t, -1, i));
    }
    if (clean.isEmpty) return [StyleRun(0, len, 0)];
    events.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final active = <int>[];
    final out = <StyleRun>[];
    var at = 0;
    void emit(int to) {
      if (to <= at) return;
      var mask = 0;
      String? url, lang;
      for (final i in active) {
        final e = clean[i];
        mask |= e.type.bit;
        if (e.type == EntityType.link) url = e.url;
        if (e.type == EntityType.pre) lang = e.language;
      }
      final run = StyleRun(at, to, mask, url: url, language: lang);
      if (out.isNotEmpty && out.last.end == at && out.last.sameStyle(run)) {
        out[out.length - 1] = StyleRun(out.last.start, to, mask, url: url, language: lang);
      } else {
        out.add(run);
      }
      at = to;
    }

    for (final (pos, kind, i) in events) {
      emit(pos);
      if (kind > 0) {
        active.add(i);
      } else {
        active.remove(i);
      }
    }
    emit(len);
    return out;
  }

  int _snapBack(int p) =>
      p > 0 && p < text.length && _isLow(text.codeUnitAt(p)) && _isHigh(text.codeUnitAt(p - 1)) ? p - 1 : p;

  int _snapForward(int p) =>
      p > 0 && p < text.length && _isLow(text.codeUnitAt(p)) && _isHigh(text.codeUnitAt(p - 1)) ? p + 1 : p;

  static bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
  static bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;

  /// Ranges back from [runs] — one per stretch of a style.
  static List<TextEntity> entitiesFromRuns(List<StyleRun> runs) {
    final out = <TextEntity>[];
    for (final t in EntityType.values) {
      int? start;
      String? url, lang;
      var end = 0;
      void close() {
        if (start != null && end > start!) {
          out.add(TextEntity(t, start!, end - start!, url: url, language: lang));
        }
        start = null;
      }

      for (final r in runs) {
        final on = r.has(t);
        final keyChanged = on && start != null && (r.url != url && t == EntityType.link || r.language != lang && t == EntityType.pre);
        if (!on || r.start != end || keyChanged) close();
        if (on && start == null) {
          start = r.start;
          url = t == EntityType.link ? r.url : null;
          lang = t == EntityType.pre ? r.language : null;
        }
        end = r.end;
      }
      close();
    }
    out.sort((a, b) => a.offset != b.offset ? a.offset.compareTo(b.offset) : b.length.compareTo(a.length));
    return out;
  }

  /// Same formatting, tidied: clipped, merged, one range per stretch.
  FormattedText normalized() => FormattedText(text, entitiesFromRuns(runs()));

  // ── Edits ─────────────────────────────────────────────────────────

  /// The part [start]..[end] with its formatting.
  FormattedText slice(int start, int end) {
    final s = start.clamp(0, text.length), t = end.clamp(s, text.length);
    final ents = <TextEntity>[];
    for (final e in entities) {
      final a = e.offset.clamp(s, t), b = e.end.clamp(s, t);
      if (b > a) ents.add(TextEntity(e.type, a - s, b - a, url: e.url, language: e.language));
    }
    return FormattedText(text.substring(s, t), ents);
  }

  /// [start]..[end] replaced by [insert] (plain, taking the style of what
  /// it replaces — a range that covered the replaced words covers the new
  /// ones).
  FormattedText replaceRange(int start, int end, String insert) {
    final delta = insert.length - (end - start);
    final ents = <TextEntity>[];
    for (final e in entities) {
      // A pure insertion at a range's edge stays outside it.
      final a = e.offset < start ? e.offset : (e.offset >= end ? e.offset + delta : start);
      final b = e.end <= start ? e.end : (e.end >= end ? e.end + delta : start + insert.length);
      if (b > a) ents.add(TextEntity(e.type, a, b - a, url: e.url, language: e.language));
    }
    return FormattedText(text.replaceRange(start, end, insert), ents);
  }

  /// Every match of [re] replaced, formatting kept around it.
  FormattedText replaceAllMapped(RegExp re, String Function(Match m) replace) {
    var out = this;
    final matches = re.allMatches(text).toList();
    for (final m in matches.reversed) {
      out = out.replaceRange(m.start, m.end, replace(m));
    }
    return out;
  }

  /// [this] followed by [other].
  FormattedText operator +(FormattedText other) => FormattedText(text + other.text, [
    ...entities,
    for (final e in other.entities)
      TextEntity(e.type, e.offset + text.length, e.length, url: e.url, language: e.language),
  ]);

  /// Leading / trailing whitespace cut, formatting kept on what remains.
  FormattedText trimmed() {
    final lead = text.length - text.trimLeft().length;
    final keep = text.trim().length;
    return slice(lead, lead + keep);
  }

  /// The text as Markdown-like markers, for places that only take plain
  /// text and are read by people (copying a formatted message to another
  /// app keeps a hint of it). Not parsed back anywhere.
  String toMarkdown() {
    final buf = StringBuffer();
    for (final r in runs()) {
      var s = text.substring(r.start, r.end);
      if (r.has(EntityType.pre)) {
        buf.write(s);
        continue;
      }
      if (r.has(EntityType.code)) s = '`$s`';
      if (r.has(EntityType.bold)) s = '**$s**';
      if (r.has(EntityType.italic)) s = '__${s}__';
      if (r.has(EntityType.strike)) s = '~~$s~~';
      if (r.has(EntityType.spoiler)) s = '||$s||';
      if (r.has(EntityType.link)) s = '[$s](${r.url})';
      buf.write(s);
    }
    return buf.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is FormattedText && other.text == text && _listEq(other.entities, entities);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(entities));

  @override
  String toString() => 'FormattedText("$text", $entities)';
}

bool _listEq<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

enum _Md { literal, escape, code, link, bold, strike, italic }

/// Pasted text that is surely Markdown — something only Markdown writes:
/// `**bold**`, `~~strike~~`, `` `code` ``, a ``` fence, a `# heading`, a
/// `[words](https://…)` link. A lone `*star*` or `- dash` isn't enough.
bool looksLikeMarkdown(String s) => _markdownSigns.any((re) => re.hasMatch(s));

final _markdownSigns = [
  RegExp(r'\*\*(?!\s)[^\n]+?(?<!\s)\*\*'),
  RegExp(r'~~(?!\s)[^\n]+?(?<!\s)~~'),
  RegExp(r'`[^`\n]+`'),
  RegExp(r'^\s*(?:`{3,}|~{3,})', multiLine: true),
  RegExp(r'^\s{0,3}#{1,6}\s+\S', multiLine: true),
  RegExp(r'\[[^\]\n]+\]\((?:https?://|mailto:|tel:)[^)\s]+\)'),
];

/// `https://` / `www.` addresses in text (tappable; never markers).
final RegExp linkPattern = RegExp(r'''\b(?:https?://|www\.)[^\s<>"]*[^\s<>".,;:!?)\]'”»]''', caseSensitive: false);

/// Phone numbers in text (tappable when they have ≥9 digits).
final RegExp phonePattern = RegExp(r'(?<![\w+])\+?\d[\d \-()]{6,}\d(?!\w)');

/// Mentions as the composer shows them ("@Name") → wire tokens, keeping
/// the formatting ([encodeMentions] with ranges).
FormattedText encodeMentionsFormatted(FormattedText t, Map<String, String> picked) {
  if (picked.isEmpty) return t;
  final names = picked.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  final pattern = RegExp('@(${names.map(RegExp.escape).join('|')})(?![\\p{L}\\p{N}_])', unicode: true);
  return t.replaceAllMapped(pattern, (m) => mentionOf(picked[m.group(1)!]!));
}

/// A stored text back to the composer's form ([decodeForEditing] with
/// ranges).
(FormattedText, Map<String, String>) decodeForEditingFormatted(FormattedText t, String Function(String key) nameOf) {
  final picked = <String, String>{};
  final shown = t.replaceAllMapped(mentionToken, (m) {
    final key = m.group(1)!;
    final name = nameOf(key);
    picked[name] = key;
    return '@$name';
  });
  return (shown, picked);
}

/// What "Copy" put on the clipboard last, with its formatting: pasting the
/// same text back into a Sinhron composer brings the formatting along (the
/// system clipboard only carries plain text here).
class RichClipboard {
  RichClipboard._();

  static FormattedText? _last;

  static void remember(FormattedText t) => _last = t.hasFormatting ? t : null;

  /// The formatting for pasted [text], if it's what was copied here last.
  static FormattedText? match(String text) {
    final l = _last;
    if (l == null || text.isEmpty) return null;
    if (l.text == text) return l;
    // The system may trim what it pastes.
    final t = l.trimmed();
    return t.text == text ? t : null;
  }

  static void clear() => _last = null;
}

/// Starts a formatted draft as stored (a private-use character nobody types).
const _draftMark = '';

/// A composer draft for `chats.draft`: plain text as before, or — with
/// formatting — the mark + `{"t": text, "e": ranges}` (never sent; drafts
/// stay on this device).
String encodeDraft(FormattedText t) {
  if (!t.hasFormatting) return t.text;
  return '$_draftMark${jsonEncode({'t': t.text, 'e': jsonDecode(t.entitiesJson)})}';
}

/// [encodeDraft] back; plain text stays plain.
FormattedText decodeDraft(String? raw) {
  if (raw == null || raw.isEmpty) return FormattedText.empty;
  if (!raw.startsWith(_draftMark)) return FormattedText.plain(raw);
  try {
    final j = jsonDecode(raw.substring(_draftMark.length)) as Map;
    final text = j['t'] as String;
    return FormattedText(text, [for (final e in (j['e'] as List? ?? const [])) ?TextEntity.fromJson(e)]).normalized();
  } catch (_) {
    return FormattedText.plain(raw.substring(_draftMark.length));
  }
}
