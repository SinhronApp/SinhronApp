// ADR-070 — the formatted-text model: legacy markers, runs (overlaps,
// nesting, emoji, RTL, out-of-range), edits, JSON, drafts, links.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/rich_text.dart';

const b = EntityType.bold, i = EntityType.italic, s = EntityType.strike, c = EntityType.code;

TextEntity e(EntityType t, int o, int l, {String? url, String? lang}) => TextEntity(t, o, l, url: url, language: lang);

void main() {
  group('older apps\' markers (0.6.0)', () {
    test('become clean text + ranges', () {
      expect(FormattedText.legacy('a *bold* b'), FormattedText('a bold b', [e(b, 2, 4)]));
      expect(
        FormattedText.legacy('_it_ `x = 1` ~no~ ||secret||'),
        FormattedText('it x = 1 no secret', [
          e(i, 0, 2),
          e(c, 3, 5),
          e(s, 9, 2),
          e(EntityType.spoiler, 12, 6),
        ]),
      );
    });

    test('prose with stray markers stays plain', () {
      for (final t in ['2 * 3 * 4', 'snake_case_name', 'a*b*c', 'price ~ 5', '* not bold *', 'file_name.txt']) {
        expect(FormattedText.legacy(t), FormattedText(t), reason: t);
      }
    });

    test('markers inside links and mentions are never read', () {
      expect(FormattedText.legacy('see https://ex.com/a_b_c_ ok').text, 'see https://ex.com/a_b_c_ ok');
      final key = 'ab' * 32;
      expect(FormattedText.legacy('@[$key] *hi*'), FormattedText('@[$key] hi', [e(b, 68, 2)]));
    });

    test('stored: null JSON = an older app\'s message, [] = plain on purpose', () {
      expect(FormattedText.stored('*x*', null), FormattedText('x', [e(b, 0, 1)]));
      expect(FormattedText.stored('*x*', '[]'), const FormattedText('*x*'));
      expect(FormattedText.stored('Hi', '[{"t":"bold","o":0,"l":2}]'), FormattedText('Hi', [e(b, 0, 2)]));
      expect(FormattedText.stored('Hi', 'garbage'), const FormattedText('Hi'), reason: 'broken JSON = plain');
    });
  });

  group('runs', () {
    test('overlapping and nested ranges split into stretches', () {
      final t = FormattedText('abcdefgh', [e(b, 0, 6), e(i, 3, 5), e(EntityType.link, 4, 1, url: 'https://x.org')]);
      expect(t.runs(), [
        StyleRun(0, 3, b.bit),
        StyleRun(3, 4, b.bit | i.bit),
        StyleRun(4, 5, b.bit | i.bit | EntityType.link.bit, url: 'https://x.org'),
        StyleRun(5, 6, b.bit | i.bit),
        StyleRun(6, 8, i.bit),
      ]);
    });

    test('ranges past the end are clipped, empty / negative ones dropped', () {
      final t = FormattedText('abc', [e(b, 1, 99), e(i, -5, 2), e(s, 2, 0)]);
      expect(t.runs(), [StyleRun(0, 1, 0), StyleRun(1, 3, b.bit)]);
    });

    test('never half an emoji: a range inside a surrogate pair widens', () {
      final t = FormattedText('a😀b', [e(b, 2, 1)]); // starts between the halves
      expect(t.runs(), [StyleRun(0, 1, 0), StyleRun(1, 3, b.bit), StyleRun(3, 4, 0)]);
      final u = FormattedText('a😀b', [e(b, 0, 2)]); // ends between them
      expect(u.runs().first, StyleRun(0, 3, b.bit));
    });

    test('a link to javascript: is dropped, the words stay', () {
      final t = FormattedText('click', [e(EntityType.link, 0, 5, url: 'javascript:alert(1)')]);
      expect(t.runs(), [StyleRun(0, 5, 0)]);
    });

    test('RTL text: offsets are code units, direction doesn\'t matter', () {
      const text = 'שלום עולם مرحبا';
      final t = FormattedText(text, [e(b, 0, 4), e(i, 10, 5)]);
      expect(text.substring(0, 4), 'שלום');
      expect(t.runs().where((r) => r.mask != 0).map((r) => text.substring(r.start, r.end)), ['שלום', 'مرحبا']);
    });

    test('normalized merges touching / overlapping ranges of a kind', () {
      final t = FormattedText('abcdef', [e(b, 0, 2), e(b, 2, 2), e(b, 3, 3), e(EntityType.link, 0, 2, url: 'https://a.org'),
        e(EntityType.link, 2, 2, url: 'https://b.org')]).normalized();
      expect(t.entities, [
        e(b, 0, 6),
        e(EntityType.link, 0, 2, url: 'https://a.org'),
        e(EntityType.link, 2, 2, url: 'https://b.org'),
      ]);
    });

    test('very long text with many ranges stays fast', () {
      final text = 'x' * 65536;
      final ents = [for (var k = 0; k < 1000; k++) e(EntityType.values[k % 9], k * 60, 70, url: 'https://e.org/$k')];
      final sw = Stopwatch()..start();
      final runs = FormattedText(text, ents).runs();
      final back = FormattedText.entitiesFromRuns(runs);
      expect(runs.last.end, 65536);
      expect(back, isNotEmpty);
      expect(sw.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('edits', () {
    test('slice keeps the formatting of the part', () {
      final t = FormattedText('Hello world', [e(b, 0, 5), e(i, 4, 3)]);
      expect(t.slice(3, 8), FormattedText('lo wo', [e(b, 0, 2), e(i, 1, 3)]));
    });

    test('replaceRange: replaced words keep the style around them', () {
      final t = FormattedText('say @Ann now', [e(b, 4, 4)]);
      final r = t.replaceRange(4, 8, '@[${'cd' * 32}]');
      expect(r.text, 'say @[${'cd' * 32}] now');
      expect(r.entities, [e(b, 4, 67)]);
      // A pure insertion at a range's edge stays outside it.
      final ins = FormattedText('ab', [e(b, 0, 1)]).replaceRange(1, 1, 'X');
      expect(ins.entities, [e(b, 0, 1)]);
      final pre = FormattedText('ab', [e(b, 1, 1)]).replaceRange(1, 1, 'X');
      expect(pre.entities, [e(b, 2, 1)]);
    });

    test('mentions encode / decode with the formatting kept', () {
      final key = 'ef' * 32;
      final shown = FormattedText('hi @Вера! ok', [e(b, 0, 9), e(i, 10, 2)]);
      final wire = encodeMentionsFormatted(shown, {'Вера': key});
      expect(wire.text, 'hi @[$key]! ok');
      expect(wire.normalized().entities, [e(b, 0, 71), e(i, 72, 2)]);
      final (back, picked) = decodeForEditingFormatted(wire, (_) => 'Вера');
      expect(back.normalized(), shown.normalized());
      expect(picked, {'Вера': key});
    });

    test('trimmed and +', () {
      expect(FormattedText('  ab  ', [e(b, 2, 2)]).trimmed(), FormattedText('ab', [e(b, 0, 2)]));
      expect(FormattedText('a', [e(b, 0, 1)]) + FormattedText('b', [e(i, 0, 1)]), FormattedText('ab', [e(b, 0, 1), e(i, 1, 1)]));
    });
  });

  group('JSON', () {
    test('round trip; unknown kinds from a newer app are skipped', () {
      final t = FormattedText('abcdefgh', [e(b, 0, 2), e(EntityType.link, 2, 2, url: 'https://x.org'), e(EntityType.pre, 4, 4, lang: 'dart')]);
      expect(t.entitiesJson, '[{"t":"bold","o":0,"l":2},{"t":"link","o":2,"l":2,"url":"https://x.org"},{"t":"pre","o":4,"l":4,"lang":"dart"}]');
      expect(FormattedText.parseEntities(t.entitiesJson), t.entities);
      expect(FormattedText.parseEntities('[{"t":"sparkle","o":0,"l":1},{"t":"bold","o":0,"l":1}]'), [e(b, 0, 1)]);
      expect(const FormattedText('x').entitiesJson, '[]');
    });

    test('drafts: plain stays plain, formatted round-trips', () {
      expect(encodeDraft(const FormattedText('hello')), 'hello');
      expect(decodeDraft('hello'), const FormattedText('hello'));
      final f = FormattedText('Жирный текст', [e(b, 0, 6)]);
      final stored = encodeDraft(f);
      expect(stored, isNot('Жирный текст'));
      expect(decodeDraft(stored), f);
      expect(decodeDraft(null), FormattedText.empty);
    });
  });

  test('link targets: web, mail, phone only; typed addresses normalized', () {
    expect(linkTargetOk('https://sinhron.app'), isTrue);
    expect(linkTargetOk('mailto:a@b.c'), isTrue);
    expect(linkTargetOk('tel:+7999'), isTrue);
    for (final bad in ['javascript:alert(1)', 'file:///etc/passwd', 'intent://x', 'https://a b', 'https://', '']) {
      expect(linkTargetOk(bad), isFalse, reason: bad);
    }
    expect(normalizeLinkTarget('ya.ru'), 'https://ya.ru');
    expect(normalizeLinkTarget(' https://x.org/a '), 'https://x.org/a');
    expect(normalizeLinkTarget('me@mail.ru'), 'mailto:me@mail.ru');
    expect(normalizeLinkTarget('+7 999 123-45-67'), 'tel:+79991234567');
    expect(normalizeLinkTarget('просто слова'), isNull);
    expect(normalizeLinkTarget('javascript:alert(1)'), isNull);
  });

  test('copied formatting comes back only for the same text', () {
    RichClipboard.remember(FormattedText(' Hi ', [e(b, 1, 2)]));
    expect(RichClipboard.match(' Hi '), FormattedText(' Hi ', [e(b, 1, 2)]));
    expect(RichClipboard.match('Hi'), FormattedText('Hi', [e(b, 0, 2)]), reason: 'trimmed by the system');
    expect(RichClipboard.match('other'), isNull);
    RichClipboard.remember(const FormattedText('plain'));
    expect(RichClipboard.match('plain'), isNull, reason: 'nothing to restore');
    RichClipboard.clear();
  });

  test('toMarkdown gives a readable hint for plain-text places', () {
    final t = FormattedText('bold and link', [e(b, 0, 4), e(EntityType.link, 9, 4, url: 'https://x.org')]);
    expect(t.toMarkdown(), '**bold** and [link](https://x.org)');
  });

  group('Markdown pasted from another app', () {
    TextEntity at(FormattedText t, EntityType type, String words, {String? url, String? lang}) =>
        TextEntity(type, t.text.indexOf(words), words.length, url: url, language: lang);

    test('an AI answer: heading → bold line, list → bullets, **bold** inside', () {
      final t = FormattedText.markdown('## С чем могу помочь\n\n- **Законный сбор отзывов.** Можно сделать\n- Второй пункт');
      expect(t.text, 'С чем могу помочь\n\n• Законный сбор отзывов. Можно сделать\n• Второй пункт');
      expect(t.entities, [at(t, b, 'С чем могу помочь'), at(t, b, 'Законный сбор отзывов.')]);
    });

    test('inline: code, link, strike, italic both ways, nesting', () {
      final t = FormattedText.markdown('`код`, [ссылка](https://ya.ru), ~~нет~~, *да*, __тоже__, **жирный `моно`**');
      expect(t.text, 'код, ссылка, нет, да, тоже, жирный моно');
      expect(
        t.entities.toSet(),
        {
          at(t, c, 'код'),
          at(t, EntityType.link, 'ссылка', url: 'https://ya.ru'),
          at(t, s, 'нет'),
          at(t, i, 'да'),
          at(t, i, 'тоже'),
          at(t, b, 'жирный моно'),
          at(t, c, 'моно'),
        },
      );
    });

    test('a code block keeps its lines and language; markers inside stay', () {
      final t = FormattedText.markdown('Пример:\n```dart\nfinal x = **2**;\n```\nвсё');
      expect(t.text, 'Пример:\nfinal x = **2**;\nвсё');
      expect(t.entities, [at(t, EntityType.pre, 'final x = **2**;', lang: 'dart')]);
    });

    test('quote lines make one quote; a table reads as lines', () {
      final q = FormattedText.markdown('> раз\n> два\nпосле');
      expect(q.text, 'раз\nдва\nпосле');
      expect(q.entities, [TextEntity(EntityType.quote, 0, 'раз\nдва'.length)]);

      final t = FormattedText.markdown('| Что | Где |\n| --- | --- |\n| ключ | сервер |');
      expect(t.text, 'Что · Где\nключ · сервер');
      expect(t.entities, [at(t, b, 'Что · Где')]);
    });

    test('escapes, addresses with underscores, odd links stay words', () {
      expect(FormattedText.markdown(r'\*не курсив\*').text, '*не курсив*');
      final url = FormattedText.markdown('**см.** https://a.org/x_y_z');
      expect(url.text, 'см. https://a.org/x_y_z');
      expect(url.entities, [at(url, b, 'см.')]);
      final js = FormattedText.markdown('[жми](javascript:alert(1)) и **всё**');
      expect(js.entities.where((x) => x.type == EntityType.link), isEmpty);
    });

    test('numbered items, task boxes and rules', () {
      final t = FormattedText.markdown('1. один\n- [ ] сделать\n- [x] готово\n---');
      expect(t.text, '1. один\n☐ сделать\n☑ готово\n———');
    });

    test('only surely-Markdown text is converted', () {
      for (final yes in ['**жирный**', '## Заголовок', 'это `код`', '~~нет~~', '[тут](https://ya.ru)', '```\nx\n```']) {
        expect(looksLikeMarkdown(yes), isTrue, reason: yes);
      }
      for (final no in ['привет *всем*', '- пункт', 'snake_case_name', '2*3*4', '#хэштег', 'обычный текст']) {
        expect(looksLikeMarkdown(no), isFalse, reason: no);
      }
    });
  });
}
