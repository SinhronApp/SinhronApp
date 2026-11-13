// The composer's formatting — ADR-070: typing keeps styles, Telegram
// markers convert as typed, toolbar / shortcuts toggle, paste restores.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/rich_text.dart';
import 'package:sinhron/features/chat_view/rich_composer.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';
import 'package:sinhron/widgets/ds_text_field.dart';

TextEntity e(EntityType t, int o, int l, {String? url, String? lang}) => TextEntity(t, o, l, url: url, language: lang);

/// Type [s] at the caret one character at a time, like a keyboard.
void type(RichTextController c, String s) {
  for (final ch in s.split('')) {
    final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
    final text = c.text.replaceRange(sel.start, sel.end, ch);
    c.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: sel.start + ch.length));
  }
}

void backspace(RichTextController c) {
  final at = c.selection.baseOffset;
  c.value = TextEditingValue(text: c.text.replaceRange(at - 1, at, ''), selection: TextSelection.collapsed(offset: at - 1));
}

RichTextController fresh() => RichTextController()..selection = const TextSelection.collapsed(offset: 0);

void main() {
  group('Telegram markers convert as typed', () {
    test('**bold**, __italic__, ~~strike~~, ||spoiler||, `code`', () {
      final cases = {
        '**жирный**': EntityType.bold,
        '__курсив__': EntityType.italic,
        '~~зачёркнутый~~': EntityType.strike,
        '||спойлер||': EntityType.spoiler,
        '`код`': EntityType.code,
      };
      for (final MapEntry(key: typed, value: kind) in cases.entries) {
        final c = fresh();
        type(c, 'a $typed b');
        final word = typed.replaceAll(RegExp(r'[*_~|`]'), '');
        expect(c.formatted, FormattedText('a $word b', [e(kind, 2, word.length)]), reason: typed);
      }
    });

    test('typing after the closing marker is plain again', () {
      final c = fresh();
      type(c, '**Привет**');
      expect(c.selection.baseOffset, 6);
      type(c, ' мир');
      expect(c.formatted, FormattedText('Привет мир', [e(EntityType.bold, 0, 6)]));
    });

    test('not converted: spaces inside the markers, an empty pair, inside code', () {
      for (final s in ['** x **', '****', '2 ** 3 ** 4']) {
        final c = fresh();
        type(c, s);
        expect(c.formatted, FormattedText(s), reason: s);
      }
      final c = fresh()..setFormatted(FormattedText('xy', [e(EntityType.code, 0, 2)]));
      c.selection = const TextSelection.collapsed(offset: 1);
      type(c, '**b**');
      expect(c.formatted, FormattedText('x**b**y', [e(EntityType.code, 0, 7)]), reason: 'markers inside code stay');
    });

    test('```lang\\ncode``` → a code block with its language', () {
      final c = fresh();
      type(c, '```dart\nvar x = 1;```');
      expect(c.formatted, FormattedText('var x = 1;', [e(EntityType.pre, 0, 10, lang: 'dart')]));
      final d = fresh();
      type(d, '```\nplain\ncode\n```');
      expect(d.formatted, FormattedText('plain\ncode', [e(EntityType.pre, 0, 10)]));
    });

    test('[words](address) → a link; a bad address stays text', () {
      final c = fresh();
      type(c, 'see [our site](sinhron.app) ok');
      expect(c.formatted, FormattedText('see our site ok', [e(EntityType.link, 4, 8, url: 'https://sinhron.app')]));
      final d = fresh();
      type(d, '[x](javascript:alert)');
      expect(d.formatted.entities, isEmpty);
    });

    test('"> " starts a quote; Enter continues it; Enter on an empty line leaves it', () {
      final c = fresh();
      type(c, '> первая');
      expect(c.formatted, FormattedText('первая', [e(EntityType.quote, 0, 6)]));
      type(c, '\nвторая');
      expect(c.formatted, FormattedText('первая\nвторая', [e(EntityType.quote, 0, 13)]));
      type(c, '\n\nпосле');
      expect(c.text, 'первая\nвторая\nпосле', reason: 'the empty quote line is gone');
      expect(c.formatted.entities, [e(EntityType.quote, 0, 13)]);
    });

    test('emoji inside formatting keep whole', () {
      final c = fresh();
      type(c, '**ok 👍🏽**');
      final f = c.formatted;
      expect(f.text, 'ok 👍🏽');
      expect(f.entities, [e(EntityType.bold, 0, f.text.length)]);
    });
  });

  group('editing keeps formatting', () {
    test('typing inside a range continues it; deleting shrinks it', () {
      final c = fresh()..setFormatted(FormattedText('Hello', [e(EntityType.bold, 0, 5)]));
      c.selection = const TextSelection.collapsed(offset: 3);
      type(c, 'XY');
      expect(c.formatted, FormattedText('HelXYlo', [e(EntityType.bold, 0, 7)]));
      backspace(c);
      backspace(c);
      expect(c.formatted, FormattedText('Hello', [e(EntityType.bold, 0, 5)]));
      c.selection = const TextSelection.collapsed(offset: 5);
      type(c, '!');
      expect(c.formatted.entities, [e(EntityType.bold, 0, 6)], reason: 'typing at the end continues bold');
    });

    test('typing right after a link is not part of it; inside it is', () {
      final c = fresh()..setFormatted(FormattedText('link', [e(EntityType.link, 0, 4, url: 'https://x.org')]));
      c.selection = const TextSelection.collapsed(offset: 4);
      type(c, ' x');
      expect(c.formatted.entities, [e(EntityType.link, 0, 4, url: 'https://x.org')]);
      c.selection = const TextSelection.collapsed(offset: 2);
      type(c, 'N');
      expect(c.formatted.entities, [e(EntityType.link, 0, 5, url: 'https://x.org')]);
    });

    test('an autocorrected word keeps its style', () {
      final c = fresh()..setFormatted(FormattedText('teh end', [e(EntityType.italic, 0, 3)]));
      c.value = const TextEditingValue(text: 'the end', selection: TextSelection.collapsed(offset: 3));
      expect(c.formatted, FormattedText('the end', [e(EntityType.italic, 0, 3)]));
    });

    test('clear() empties the formatting too', () {
      final c = fresh()..setFormatted(FormattedText('x', [e(EntityType.bold, 0, 1)]));
      c.clear();
      type(c, 'y');
      expect(c.formatted, const FormattedText('y'));
    });

    test('pasting what was copied here brings its formatting', () {
      RichClipboard.remember(FormattedText('bold', [e(EntityType.bold, 0, 4)]));
      final c = fresh();
      type(c, 'a ');
      c.value = const TextEditingValue(text: 'a bold', selection: TextSelection.collapsed(offset: 6));
      expect(c.formatted, FormattedText('a bold', [e(EntityType.bold, 2, 4)]));
      RichClipboard.clear();
    });
  });

  group('toolbar actions', () {
    test('toggle on a selection: on, then off; nested styles', () {
      final c = fresh()..setFormatted(const FormattedText('Hello world'));
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      c.toggle(EntityType.bold);
      c.selection = const TextSelection(baseOffset: 3, extentOffset: 11);
      c.toggle(EntityType.italic);
      expect(c.formatted.entities, [e(EntityType.bold, 0, 5), e(EntityType.italic, 3, 8)]);
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      c.toggle(EntityType.bold);
      expect(c.formatted.entities, [e(EntityType.italic, 3, 8)]);
    });

    test('no selection: the style is for what is typed next', () {
      final c = fresh();
      type(c, 'a ');
      c.toggle(EntityType.bold);
      type(c, 'b');
      c.toggle(EntityType.bold);
      type(c, ' c');
      expect(c.formatted, FormattedText('a b c', [e(EntityType.bold, 2, 1)]));
    });

    test('monospace over lines makes a code block; quote takes whole lines', () {
      final c = fresh()..setFormatted(const FormattedText('one\ntwo\nthree'));
      c.selection = const TextSelection(baseOffset: 1, extentOffset: 6);
      c.toggle(EntityType.code);
      expect(c.formatted.entities, [e(EntityType.pre, 0, 7)]);
      c.selection = const TextSelection(baseOffset: 9, extentOffset: 10);
      c.toggle(EntityType.quote);
      expect(c.formatted.entities, [e(EntityType.pre, 0, 7), e(EntityType.quote, 8, 5)]);
    });

    test('link on, link off; clear formatting', () {
      final c = fresh()..setFormatted(FormattedText('go here', [e(EntityType.bold, 0, 7)]));
      c.selection = const TextSelection(baseOffset: 3, extentOffset: 7);
      c.toggle(EntityType.link, url: 'https://x.org');
      expect(c.linkAt(3), 'https://x.org');
      c.toggle(EntityType.link);
      expect(c.linkAt(3), isNull);
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
      c.clearFormatting();
      expect(c.formatted.entities, isEmpty);
    });
  });

  testWidgets('painted as typed: the field\'s spans carry the styles, text unchanged', (t) async {
    final c = RichTextController()..setFormatted(FormattedText('Hi you', [e(EntityType.bold, 0, 2), e(EntityType.code, 3, 3)]));
    late TextSpan span;
    await t.pumpWidget(DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: Builder(
        builder: (ctx) {
          span = c.buildTextSpan(context: ctx, style: const TextStyle(fontSize: 16), withComposing: true);
          return const SizedBox();
        },
      ),
    ));
    expect(span.toPlainText(), 'Hi you');
    final kids = span.children!.cast<TextSpan>();
    expect(kids.first.style!.fontWeight, FontWeight.w700);
    expect(kids.last.style!.fontFamily, DsType.familyMono);
  });

  Widget field(RichTextController c, FocusNode f) => WidgetsApp(
    color: const Color.fromRGBO(0, 0, 0, 1),
    locale: const Locale('ru'),
    supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    pageRouteBuilder: <T>(RouteSettings s, WidgetBuilder b) => PageRouteBuilder<T>(settings: s, pageBuilder: (ctx, _, _) => b(ctx)),
    builder: (ctx, child) => DsTheme(tokens: DsTokens.light, isDark: false, child: child!),
    home: Center(
      child: RichFormatShortcuts(
        controller: c,
        child: SizedBox(
          width: 300,
          child: DsPlainField(
            controller: c,
            focusNode: f,
            style: const TextStyle(fontSize: 16),
            contextMenuBuilder: richFormatToolbar(c),
          ),
        ),
      ),
    ),
  );

  testWidgets('⌘B / Ctrl+I on a hardware keyboard', (t) async {
    final c = RichTextController()..setFormatted(const FormattedText('word'));
    final f = FocusNode();
    addTearDown(f.dispose);
    await t.pumpWidget(field(c, f));
    f.requestFocus();
    await t.pump();
    c.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyB);
    await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyI);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(c.formatted.entities, [e(EntityType.bold, 0, 4), e(EntityType.italic, 0, 4)]);
  });

  testWidgets('selection menu: "Формат" → "Жирный"', (t) async {
    final c = RichTextController()..setFormatted(const FormattedText('word'));
    final f = FocusNode();
    addTearDown(f.dispose);
    await t.pumpWidget(field(c, f));
    // A double tap selects the word and opens the menu, as on a phone.
    final at = t.getTopLeft(find.byType(EditableText)) + const Offset(12, 8);
    await t.tapAt(at);
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(at);
    await t.pumpAndSettle();
    expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 4));
    await t.tap(find.text('Формат'));
    await t.pumpAndSettle();
    expect(find.text('Курсив'), findsOneWidget);
    await t.tap(find.text('Жирный'));
    await t.pumpAndSettle();
    expect(c.formatted.entities, [e(EntityType.bold, 0, 4)]);
  });

  group('Markdown pasted from another app', () {
    void paste(RichTextController c, String s) {
      final sel = c.selection.isValid ? c.selection : TextSelection.collapsed(offset: c.text.length);
      c.value = TextEditingValue(
        text: c.text.replaceRange(sel.start, sel.end, s),
        selection: TextSelection.collapsed(offset: sel.start + s.length),
      );
    }

    test('turns into formatting at once; "Undo" puts it back as it came', () {
      final c = fresh();
      type(c, 'Вот: ');
      paste(c, '## Итог\n- **да**');
      expect(c.text, 'Вот: Итог\n• да');
      expect(c.formatted.entities, [e(EntityType.bold, 5, 4), e(EntityType.bold, 12, 2)]);
      expect(c.selection, const TextSelection.collapsed(offset: 14));
      expect(c.pastedMarkdown.value, isNotNull);

      c.revertPastedMarkdown();
      expect(c.formatted, const FormattedText('Вот: ## Итог\n- **да**'));
      expect(c.selection.baseOffset, c.text.length);
      expect(c.pastedMarkdown.value, isNull);
    });

    test('typing after it forgets the offer; plain text is pasted as is', () {
      final c = fresh();
      paste(c, '**жирный**');
      expect(c.pastedMarkdown.value, isNotNull);
      type(c, '!');
      expect(c.pastedMarkdown.value, isNull);
      expect(c.formatted, FormattedText('жирный!', [e(EntityType.bold, 0, 6)]));

      final p = fresh();
      paste(p, 'привет *всем* - пункт');
      expect(p.text, 'привет *всем* - пункт');
      expect(p.pastedMarkdown.value, isNull);
    });

    test('inside a code block it stays as typed', () {
      final c = fresh()..setFormatted(FormattedText('код', [e(EntityType.pre, 0, 3)]));
      c.selection = const TextSelection.collapsed(offset: 1);
      paste(c, '**x**');
      expect(c.text, 'к**x**од');
    });
  });
}
