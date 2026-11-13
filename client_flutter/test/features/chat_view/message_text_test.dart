// Message text in bubbles — ADR-070: blocks, auto links, styles, spoilers,
// hidden links, code copy, quotes, older apps' markers, RTL, emoji.

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/core/rich_text.dart';
import 'package:sinhron/features/chat_view/message_text.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

TextEntity e(EntityType t, int o, int l, {String? url, String? lang}) => TextEntity(t, o, l, url: url, language: lang);

Widget host(Widget child, {bool reduceMotion = false, TextDirection dir = TextDirection.ltr}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduceMotion),
  child: Localizations(
    locale: const Locale('ru'),
    delegates: AppL10n.localizationsDelegates,
    child: DsTheme(
      tokens: DsTokens.light,
    isDark: false,
      child: Directionality(textDirection: dir, child: Center(child: SizedBox(width: 300, child: child))),
    ),
  ),
);

/// Every leaf TextSpan rendered (all paragraphs, in order).
List<TextSpan> leaves(WidgetTester t) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null) out.add(s);
      s.children?.forEach(walk);
    }
  }

  for (final rt in t.widgetList<RichText>(find.byType(RichText))) {
    walk(rt.text);
  }
  return out;
}

TextSpan leaf(WidgetTester t, String text) => leaves(t).firstWhere((s) => s.text == text);

MessageText mt(String text, {List<TextEntity>? entities, ValueChanged<String>? onOpenLink, InlineSpan? trailing, int? maxLines}) =>
    MessageText(
      text: text,
      entities: entities,
      style: const TextStyle(fontSize: 15, color: Color.fromRGBO(0, 0, 0, 1)),
      linkColor: const Color.fromRGBO(0, 0, 255, 1),
      onOpenLink: onOpenLink,
      trailing: trailing,
      maxLines: maxLines,
    );

void main() {
  group('blocks', () {
    test('a quote and a code block cut the text; their edge line breaks go', () {
      const text = 'intro\nquoted line\nsecond\nfn main() {}\noutro';
      final t = FormattedText(text, [e(EntityType.quote, 6, 18), e(EntityType.pre, 25, 12, lang: 'rust')]);
      expect(blocksOf(t), const [
        TextBlock(BlockKind.paragraph, 0, 5),
        TextBlock(BlockKind.quote, 6, 24),
        TextBlock(BlockKind.code, 25, 37, language: 'rust'),
        TextBlock(BlockKind.paragraph, 38, 43),
      ]);
    });

    test('plain text is one paragraph; a quote alone is one quote', () {
      expect(blocksOf(const FormattedText('hi\nthere')), const [TextBlock(BlockKind.paragraph, 0, 8)]);
      expect(blocksOf(FormattedText('q\n', [e(EntityType.quote, 0, 2)])), const [TextBlock(BlockKind.quote, 0, 1)]);
    });
  });

  group('auto links', () {
    test('addresses, phones, mentions — never inside code', () {
      final key = 'ab' * 32;
      const text = 'see https://ex.com/a_b. call +7 (999) 123-45-67';
      final marks = autoMarksOf(const FormattedText(text));
      expect(marks.map((m) => (m.kind, text.substring(m.start, m.end), m.target)), [
        ('link', 'https://ex.com/a_b', 'https://ex.com/a_b'),
        ('phone', '+7 (999) 123-45-67', 'tel:+79991234567'),
      ]);
      expect(autoMarksOf(const FormattedText('www.site.ru')).single.target, 'https://www.site.ru');
      expect(autoMarksOf(const FormattedText('on 12-05-2026 at 10')), isEmpty, reason: 'dates are not phones');
      expect(autoMarksOf(FormattedText('run https://x.org now', [e(EntityType.code, 4, 13)])), isEmpty);
      expect(autoMarksOf(FormattedText('@[$key]')).single.kind, 'mention');
    });

    test('words that say something other than their address', () {
      expect(linkTextDiffers('example.com', 'https://example.com/'), isFalse);
      expect(linkTextDiffers('www.Example.com', 'https://example.com'), isFalse);
      expect(linkTextDiffers('Сайт банка', 'https://evil.example'), isTrue);
      expect(linkTextDiffers('bank.ru', 'https://bank.ru.evil.example'), isTrue);
    });
  });

  test('big emoji: 1-3 emoji only', () {
    expect(bigEmojiCount('❤️'), 1);
    expect(bigEmojiCount('👍🏽 🔥'), 2);
    expect(bigEmojiCount('👨‍👩‍👧'), 1);
    expect(bigEmojiCount('🇷🇺😀😀'), 3);
    expect(bigEmojiCount('😀😀😀😀'), 0);
    expect(bigEmojiCount('ok 👍'), 0);
    expect(bigEmojiCount('123'), 0);
    expect(bigEmojiCount(''), 0);
  });

  testWidgets('styles nest: bold + italic, a link inside bold, underline + strike', (t) async {
    String? opened;
    await t.pumpWidget(host(mt(
      'Hello brave new world',
      entities: [
        e(EntityType.bold, 0, 11),
        e(EntityType.italic, 6, 9),
        e(EntityType.link, 6, 5, url: 'https://brave.example'),
        e(EntityType.underline, 16, 5),
        e(EntityType.strike, 16, 5),
      ],
      onOpenLink: (u) => opened = u,
    )));
    expect(leaf(t, 'Hello ').style!.fontWeight, FontWeight.w700);
    final brave = leaf(t, 'brave');
    expect((brave.style!.fontWeight, brave.style!.fontStyle), (FontWeight.w700, FontStyle.italic));
    expect(brave.style!.color, const Color.fromRGBO(0, 0, 255, 1));
    (brave.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, 'https://brave.example', reason: 'no opener above: plain callback');
    expect(leaf(t, ' new').style!.fontStyle, FontStyle.italic);
    expect(leaf(t, ' new').style!.fontWeight, isNull, reason: 'bold ended with "brave"');
    final world = leaf(t, 'world').style!.decoration!;
    expect(world.contains(TextDecoration.underline) && world.contains(TextDecoration.lineThrough), isTrue);
  });

  testWidgets('an older app\'s markers still render; a new plain message keeps its stars', (t) async {
    await t.pumpWidget(host(mt('a *bold* b')));
    expect(leaf(t, 'bold').style!.fontWeight, FontWeight.w700);
    await t.pumpWidget(host(mt('a *bold* b', entities: const [])));
    expect(leaves(t).map((s) => s.text).join(), 'a *bold* b');
  });

  testWidgets('hidden link goes through the chat\'s opener with the words', (t) async {
    (String, String)? hidden;
    String? plain;
    await t.pumpWidget(host(HiddenLinkOpener(
      open: (u, s) => hidden = (u, s),
      child: mt(
        'Мой банк and ex.com',
        entities: [
          e(EntityType.link, 0, 8, url: 'https://evil.example'),
          e(EntityType.link, 13, 6, url: 'https://ex.com'),
        ],
        onOpenLink: (u) => plain = u,
      ),
    )));
    (leaf(t, 'Мой банк').recognizer! as TapGestureRecognizer).onTap!();
    expect(hidden, ('https://evil.example', 'Мой банк'));
    (leaf(t, 'ex.com').recognizer! as TapGestureRecognizer).onTap!();
    expect(plain, 'https://ex.com', reason: 'the words are the address: no warning needed');
  });

  testWidgets('spoiler: hidden until tapped, then fades in', (t) async {
    await t.pumpWidget(host(mt('see ||secret|| now')));
    final hidden = leaf(t, 'secret');
    expect(hidden.style!.color!.a, 0, reason: 'invisible under the dust');
    expect(hidden.semanticsLabel, isNotNull);
    (hidden.recognizer! as TapGestureRecognizer).onTapUp!(TapUpDetails(kind: PointerDeviceKind.touch));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final mid = leaf(t, 'secret').style!.color!.a;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));
    await t.pumpAndSettle();
    expect(leaf(t, 'secret').style!.color, isNull, reason: 'the paragraph\'s own colour');
    expect(leaf(t, 'secret').recognizer, isNull);
  });

  testWidgets('spoiler with Reduce Motion: shown at once, no drifting dust', (t) async {
    await t.pumpWidget(host(mt('||x||'), reduceMotion: true));
    expect(t.binding.hasScheduledFrame, isFalse, reason: 'nothing animates while hidden');
    (leaf(t, 'x').recognizer! as TapGestureRecognizer).onTapUp!(TapUpDetails(kind: PointerDeviceKind.touch));
    await t.pump();
    expect(leaf(t, 'x').style!.color, isNull);
  });

  testWidgets('quote block has its bar; code block copies its code', (t) async {
    final clip = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final semantics = t.ensureSemantics();
    const text = 'Look:\nquoted\nvar x = 1;\ndone';
    await t.pumpWidget(host(mt(
      text,
      entities: [e(EntityType.quote, 6, 6), e(EntityType.pre, 13, 10, lang: 'dart')],
      trailing: const TextSpan(text: ' 12:00'),
    )));
    expect(find.bySemanticsLabel(RegExp('^Цитата')), findsOneWidget, reason: 'VoiceOver: «Цитата, …»');
    semantics.dispose();
    expect(find.text('dart'), findsOneWidget);
    expect(leaf(t, 'var x = 1;').style!.fontFamily, DsType.familyMono);
    expect(leaves(t).last.text, ' 12:00', reason: 'time after the last paragraph');
    await t.tap(find.byKey(const ValueKey('code-copy')));
    await t.pump();
    expect(clip, ['var x = 1;']);
    expect(appDone.value.text, 'Код скопирован');
  });

  testWidgets('a code block last: the time goes under it', (t) async {
    await t.pumpWidget(host(mt('x = 1', entities: [e(EntityType.pre, 0, 5)], trailing: const TextSpan(text: ' 12:00'))));
    expect(find.byKey(const ValueKey('code-copy')), findsOneWidget);
    expect(leaves(t).last.text, ' 12:00');
  });

  testWidgets('compact (maxLines): one paragraph, blocks inline', (t) async {
    await t.pumpWidget(host(mt('a\nquote\ncode', entities: [e(EntityType.quote, 2, 5), e(EntityType.pre, 8, 4)], maxLines: 2)));
    expect(find.byType(RichText), findsOneWidget);
    expect(find.byKey(const ValueKey('code-copy')), findsNothing);
  });

  testWidgets('mentions show names inside formatting', (t) async {
    final key = 'cd' * 32;
    await t.pumpWidget(host(MentionNames(
      nameOf: (_) => 'Вера',
      child: mt('hi @[$key]!', entities: [e(EntityType.bold, 0, 71)]),
    )));
    final m = leaf(t, '@Вера');
    expect(m.style!.fontWeight, FontWeight.w600);
    expect(leaf(t, '!').style!.fontWeight, FontWeight.w700);
  });

  testWidgets('RTL and emoji ranges render without a hitch', (t) async {
    await t.pumpWidget(host(
      mt('שלום 😀 עולם', entities: [e(EntityType.bold, 0, 4), e(EntityType.spoiler, 5, 2), e(EntityType.italic, 8, 4)]),
      dir: TextDirection.rtl,
    ));
    expect(leaf(t, 'שלום').style!.fontWeight, FontWeight.w700);
    expect(leaf(t, '😀').style!.color!.a, 0);
    expect(leaf(t, 'עולם').style!.fontStyle, FontStyle.italic);
    expect(t.takeException(), isNull);
  });

  testWidgets('hostile ranges (past the end, half an emoji) do not break it', (t) async {
    await t.pumpWidget(host(mt('a😀', entities: [e(EntityType.bold, 2, 99), e(EntityType.link, 0, 1, url: 'javascript:x')])));
    expect(leaves(t).map((s) => s.text).join(), 'a😀');
    expect(t.takeException(), isNull);
  });

  testWidgets('a very long message with many ranges renders', (t) async {
    final text = List.generate(2000, (k) => 'слово$k').join(' ');
    final ents = [
      for (var k = 0; k < 600; k++) e(EntityType.values[k % 5], k * 20, 12),
      e(EntityType.quote, 3000, 400),
      e(EntityType.pre, 5000, 300),
    ];
    final sw = Stopwatch()..start();
    await t.pumpWidget(host(SingleChildScrollView(child: mt(text, entities: ents))));
    expect(t.takeException(), isNull);
    expect(sw.elapsedMilliseconds, lessThan(5000));
    expect(find.byKey(const ValueKey('code-copy')), findsOneWidget);
  });
}
