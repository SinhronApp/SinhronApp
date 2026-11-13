// ADR-076 — iPad: two columns from 700 pt, the phone layout in a narrow
// window, what is open survives rotating / resizing, popups instead of
// full-width sheets, keys in the composer.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/adaptive.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/widgets/ds_action_sheet.dart';

const ipadPortrait = Size(1024, 1366); // iPad Pro 12.9" standing up
const ipadLandscape = Size(1366, 1024);
const slideOver = Size(375, 1024); // Slide Over / a third of Split View
const phoneLandscape = Size(844, 390);

final size = ValueNotifier<Size>(ipadPortrait);

Future<void> setSize(WidgetTester t, Size s) async {
  t.view.physicalSize = s;
  t.view.devicePixelRatio = 1;
  size.value = s;
  await t.pumpAndSettle();
}

Widget app(Widget home) => DsTheme(
  tokens: DsTokens.light,
  isDark: false,
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: ValueListenableBuilder<Size>(
      valueListenable: size,
      builder: (_, s, child) => MediaQuery(
        data: MediaQueryData(size: s),
        child: child!,
      ),
      // Esc → "dismiss", as WidgetsApp maps it.
      child: Shortcuts(
        shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => home)),
      ),
    ),
  ),
);

Route<void> fade(WidgetBuilder b) => PageRouteBuilder<void>(pageBuilder: (c, _, _) => b(c));

/// As in the app: Esc closes what is open on the right.
Route<void> paneFade(WidgetBuilder b) =>
    PageRouteBuilder<void>(pageBuilder: (c, _, _) => b(c), barrierDismissible: true);

/// A detail screen: its own text, a Back, and a "photo" pushed over the app.
Widget detail(BuildContext context, String name) => ColoredBox(
  key: ValueKey('detail-$name'),
  color: const Color(0xFFFFFFFF),
  child: Column(
    children: [
      Text('detail $name'),
      GestureDetector(onTap: () => Navigator.of(context).pop(), child: const Text('back')),
      GestureDetector(
        onTap: () => rootNavigator(
          context,
        ).push(fade((_) => const ColoredBox(key: ValueKey('over-all'), color: Color(0xFF000000)))),
        child: const Text('photo'),
      ),
    ],
  ),
);

/// The list: two rows, the open one says so.
Widget list(BuildContext context) => ColoredBox(
  key: const ValueKey('list'),
  color: const Color(0xFFEEEEEE),
  child: Column(
    children: [
      for (final name in ['a', 'b'])
        GestureDetector(
          key: ValueKey('row-$name'),
          onTap: () => openDetail(context, (c) => detail(c, name), id: name, fallback: fade),
          child: Text(AdaptiveSplit.selectedOf(context) == name ? 'row $name ✓' : 'row $name'),
        ),
    ],
  ),
);

Widget split({Object memoryKey = 'chats', Map<ShortcutActivator, void Function(BuildContext, PaneController)>? keys}) =>
    AdaptiveSplit(
      memoryKey: memoryKey,
      list: list,
      placeholder: 'Choose a chat',
      phoneRoute: fade,
      paneRoute: paneFade,
      shortcuts: keys ?? const {},
    );

Rect rectOf(WidgetTester t, String key) => t.getRect(find.byKey(ValueKey(key)));

void main() {
  setUp(AdaptiveSplit.forgetAll);
  tearDown(() => size.value = ipadPortrait);

  test('wide: an iPad either way and half a big one; not an iPhone on its side', () {
    expect(isWideSize(ipadPortrait), isTrue);
    expect(isWideSize(ipadLandscape), isTrue);
    expect(isWideSize(const Size(744, 1133)), isTrue, reason: 'iPad mini standing up');
    expect(isWideSize(const Size(683, 1024)), isFalse, reason: 'half of the 12.9" — the phone layout');
    expect(isWideSize(slideOver), isFalse);
    expect(isWideSize(phoneLandscape), isFalse);
    expect(listColumnWidth(1024), 320);
    expect(listColumnWidth(1180), 380, reason: 'iPad Air on its side');
    expect(listColumnWidth(1366), 380);
  });

  test('bubbles: 78 % of the chat, never past 560', () {
    expect(bubbleMaxWidth(390), closeTo(304.2, 0.01));
    expect(bubbleMaxWidth(1366 - 380), kBubbleMaxWidth);
  });

  for (final (s, listWidth) in [(ipadPortrait, 320.0), (ipadLandscape, 380.0)]) {
    testWidgets('${s.width.toInt()} pt: the list on the left, the chat on the right', (t) async {
      addTearDown(t.view.reset);
      await setSize(t, s);
      await t.pumpWidget(app(split()));
      expect(rectOf(t, 'list').width, listWidth);
      expect(find.text('Choose a chat'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('row-a')));
      await t.pumpAndSettle();
      final pane = rectOf(t, 'detail-a');
      expect(pane.left, greaterThan(listWidth), reason: 'beside the list, not over it');
      expect(pane.width, closeTo(s.width - listWidth - 0.5, 0.01));
      expect(find.text('row a ✓'), findsOneWidget, reason: 'the open chat is marked in the list');

      // Another row replaces it (no stack of chats on the right).
      await t.tap(find.byKey(const ValueKey('row-b')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-a')), findsNothing);
      expect(find.text('row b ✓'), findsOneWidget);

      // Back: "choose a chat" again, nothing marked.
      await t.tap(find.text('back'));
      await t.pumpAndSettle();
      expect(find.text('Choose a chat'), findsOneWidget);
      expect(find.textContaining('✓'), findsNothing);
    });
  }

  testWidgets('a photo / call from the right column covers both columns', (t) async {
    addTearDown(t.view.reset);
    await setSize(t, ipadLandscape);
    await t.pumpWidget(app(split()));
    await t.tap(find.byKey(const ValueKey('row-a')));
    await t.pumpAndSettle();
    await t.tap(find.text('photo'));
    await t.pumpAndSettle();
    expect(rectOf(t, 'over-all'), Offset.zero & ipadLandscape);
  });

  for (final s in [slideOver, const Size(507, 1024), phoneLandscape]) {
    testWidgets('narrow ${s.width.toInt()}×${s.height.toInt()}: one column, the chat over the list', (t) async {
      addTearDown(t.view.reset);
      await setSize(t, s);
      await t.pumpWidget(app(split()));
      expect(find.text('Choose a chat'), findsNothing);
      expect(rectOf(t, 'list').width, s.width);
      await t.tap(find.byKey(const ValueKey('row-a')));
      await t.pumpAndSettle();
      expect(rectOf(t, 'detail-a'), Offset.zero & s);
      expect(find.text('row a ✓', skipOffstage: false), findsNothing, reason: 'nothing is beside the list');
      await t.tap(find.text('back'));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('list')), findsOneWidget);
    });
  }

  testWidgets('rotating / Split View keeps the open chat: right column ⇄ full screen', (t) async {
    addTearDown(t.view.reset);
    await setSize(t, ipadLandscape);
    await t.pumpWidget(app(split()));
    await t.tap(find.byKey(const ValueKey('row-a')));
    await t.pumpAndSettle();

    // Into Slide Over: the chat is still open, full screen.
    await setSize(t, slideOver);
    expect(find.byKey(const ValueKey('detail-a')), findsOneWidget);
    expect(rectOf(t, 'detail-a'), Offset.zero & slideOver);

    // Back to the whole screen: beside the list again — one copy.
    await setSize(t, ipadPortrait);
    expect(find.byKey(const ValueKey('detail-a'), skipOffstage: false), findsOneWidget);
    expect(rectOf(t, 'detail-a').left, greaterThan(320));
    expect(find.text('row a ✓'), findsOneWidget);

    // A chat opened in the narrow window moves to the right column too.
    await setSize(t, slideOver);
    await t.tap(find.text('back'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('row-b')));
    await t.pumpAndSettle();
    await setSize(t, ipadLandscape);
    expect(rectOf(t, 'detail-b').left, greaterThan(380));
    expect(find.byKey(const ValueKey('detail-b'), skipOffstage: false), findsOneWidget);

    // Closed on the phone layout → nothing comes back on the wide one.
    await setSize(t, slideOver);
    await t.tap(find.text('back'));
    await t.pumpAndSettle();
    await setSize(t, ipadLandscape);
    expect(find.text('Choose a chat'), findsOneWidget);
  });

  testWidgets('another tab and back: the chat that was open is open again', (t) async {
    addTearDown(t.view.reset);
    await setSize(t, ipadPortrait);
    final tab = ValueNotifier<String>('chats');
    await t.pumpWidget(
      app(
        ValueListenableBuilder<String>(
          valueListenable: tab,
          builder: (_, v, _) => KeyedSubtree(
            key: ValueKey(v),
            child: split(memoryKey: v),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('row-b')));
    await t.pumpAndSettle();
    tab.value = 'settings';
    await t.pumpAndSettle();
    expect(find.text('Choose a chat'), findsOneWidget, reason: 'the other tab has its own right column');
    tab.value = 'chats';
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-b')), findsOneWidget);
    expect(find.text('row b ✓'), findsOneWidget);
  });

  testWidgets('Esc closes the chat on the right; tab shortcuts reach the split', (t) async {
    addTearDown(t.view.reset);
    await setSize(t, ipadPortrait);
    PaneController? got;
    await t.pumpWidget(
      app(split(keys: {const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true): (_, pane) => got = pane})),
    );
    await t.tap(find.byKey(const ValueKey('row-a')));
    await t.pumpAndSettle();
    await t.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    expect(got?.selected.value, 'a');
    expect(got?.wide, isTrue);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(find.text('Choose a chat'), findsOneWidget);
  });

  group('sheets', () {
    Future<BuildContext> host(WidgetTester t, Size s) async {
      addTearDown(t.view.reset);
      await setSize(t, s);
      late BuildContext ctx;
      await t.pumpWidget(
        app(
          Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      );
      return ctx;
    }

    void open(BuildContext ctx) =>
        showDsActionSheet<String>(ctx, actions: const [DsSheetAction('Archive', 'a')], cancelLabel: 'Cancel');

    testWidgets('on an iPad: a popup of 440 in the middle, Esc closes it', (t) async {
      final ctx = await host(t, ipadPortrait);
      open(ctx);
      await t.pumpAndSettle();
      final popup = rectOf(t, 'sheet-popup');
      expect(popup.width, lessThanOrEqualTo(kPopupMaxWidth));
      expect(popup.center.dx, closeTo(ipadPortrait.width / 2, 0.5));
      expect(popup.center.dy, closeTo(ipadPortrait.height / 2, 0.5), reason: 'in the middle, not at the bottom');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('Archive'), findsNothing);
    });

    testWidgets('on a phone / narrow column: at the bottom, the screen\'s width', (t) async {
      final ctx = await host(t, slideOver);
      open(ctx);
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('sheet-popup')), findsNothing);
      final row = t.getRect(find.byKey(const ValueKey('sheet-action-Archive')));
      expect(row.width, greaterThan(slideOver.width - 40));
      expect(t.getRect(find.text('Cancel')).bottom, greaterThan(slideOver.height - 80));
    });
  });

  testWidgets('forms: a readable column in the middle of an iPad, as is on a phone', (t) async {
    addTearDown(t.view.reset);
    await setSize(t, ipadLandscape);
    await t.pumpWidget(app(const DsReadableWidth(child: SizedBox.expand(key: ValueKey('form')))));
    expect(rectOf(t, 'form').width, kFormMaxWidth);
    expect(rectOf(t, 'form').center.dx, ipadLandscape.width / 2);
    await setSize(t, slideOver);
    expect(rectOf(t, 'form').width, slideOver.width);
  });

  group('composer keys (hardware keyboard)', () {
    late int sent;
    late int edits;
    late TextEditingController text;
    late FocusNode focus;

    Future<void> pump(WidgetTester t) async {
      sent = 0;
      edits = 0;
      text = TextEditingController();
      focus = FocusNode();
      addTearDown(text.dispose);
      addTearDown(focus.dispose);
      await t.pumpWidget(
        app(
          SendShortcuts(
            controller: text,
            onSend: () => sent++,
            onEditLast: () => edits++,
            child: EditableText(
              controller: text,
              focusNode: focus,
              style: const TextStyle(fontSize: 14),
              cursorColor: const Color(0xFF000000),
              backgroundCursorColor: const Color(0xFF888888),
              maxLines: 4,
            ),
          ),
        ),
      );
      focus.requestFocus();
      await t.pump();
    }

    testWidgets('Enter and ⌘Enter send; Shift+Enter does not', (t) async {
      await pump(t);
      text.text = 'hi';
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, 1);
      await t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(sent, 2);
      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(sent, 2, reason: 'Shift+Enter is a new line');
    });

    testWidgets('letters still being composed keep their Enter', (t) async {
      await pump(t);
      text.value = const TextEditingValue(
        text: 'にほん',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, 0);
    });

    testWidgets('↑ in an empty field edits my last message; with text it moves the caret', (t) async {
      await pump(t);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(edits, 1);
      text.text = 'draft';
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      expect(edits, 1);
    });
  });
}
