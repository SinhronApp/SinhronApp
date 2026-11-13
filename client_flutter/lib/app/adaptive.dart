// ADR-076 — iPad: a tab's list on the left, what it opens on the right;
// a narrow window (Split View, Slide Over, iPhone) is the phone layout.
// Rotating or resizing keeps what is open: the open chat moves between
// the right column and full screen.
//
// Also here: what "wide" means, popups instead of full-width sheets, and
// the widths that keep text readable on a big screen.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'theme/motion.dart';
import 'theme/tokens.dart';

/// Two columns from this width — any iPad standing up, half of the big
/// iPad's screen (owner, 2026-10-24). Narrower: one column, as on iPhone.
const double kWideMinWidth = 700;

/// …and this height: an iPhone on its side is wide but low — it stays the
/// phone layout.
const double kWideMinHeight = 500;

bool isWideSize(Size s) => s.width >= kWideMinWidth && s.height >= kWideMinHeight;
bool isWide(BuildContext context) => isWideSize(MediaQuery.sizeOf(context));

/// The list column: narrower standing up (up to the big iPad's 1024),
/// wider on its side.
double listColumnWidth(double width) => width > 1100 ? 380 : 320;

/// A sheet on a wide screen is a popup this wide, not the screen's width.
const double kPopupMaxWidth = 440;

/// A message bubble never grows past this (78 % of a wide column is too
/// long a line to read).
const double kBubbleMaxWidth = 560;

/// Forms (onboarding, unlock) on a wide screen.
const double kFormMaxWidth = 560;

/// The bubble's widest: 78 % of the chat's width, at most [kBubbleMaxWidth].
double bubbleMaxWidth(double chatWidth) {
  final w = chatWidth * 0.78;
  return w > kBubbleMaxWidth ? kBubbleMaxWidth : w;
}

/// Over both columns (calls, sheets, menus, photos): the app's navigator,
/// not the right column's.
NavigatorState rootNavigator(BuildContext context) => Navigator.of(context, rootNavigator: true);

/// What a tab opens: [AdaptiveSplit] keeps it — on the right, or on top of
/// the tab on a phone — and moves it when the window changes.
abstract interface class PaneController {
  /// Two columns right now.
  bool get wide;

  /// The row shown on the right ([open]'s `id`) — the list marks it.
  ValueListenable<Object?> get selected;

  /// Shows [builder] instead of what is open; [id] marks its row.
  void open(WidgetBuilder builder, {Object? id});
}

/// [builder] as what the tab opens — on the right of a wide screen, over
/// the tab on a phone; [fallback] pushes it where there is no split.
void openDetail(
  BuildContext context,
  WidgetBuilder builder, {
  Object? id,
  required Route<void> Function(WidgetBuilder builder) fallback,
}) {
  final pane = AdaptiveSplit.maybeOf(context);
  if (pane != null) {
    pane.open(builder, id: id);
  } else {
    Navigator.of(context).push(fallback(builder));
  }
}

class _Open {
  const _Open(this.builder, this.id);
  final WidgetBuilder builder;
  final Object? id;
}

/// The list ([list]) with, on a wide screen, the right column beside it —
/// [placeholder] until something opens there. [memoryKey]: the same tab
/// shown again (after another tab) opens what was open. [shortcuts] work
/// anywhere in the tab (a chat, the list).
class AdaptiveSplit extends StatefulWidget {
  const AdaptiveSplit({
    super.key,
    required this.list,
    required this.placeholder,
    required this.phoneRoute,
    required this.paneRoute,
    this.memoryKey,
    this.shortcuts = const {},
  });

  final WidgetBuilder list;
  final String placeholder;

  /// On a phone, how the open thing comes in (the iOS slide).
  final Route<void> Function(WidgetBuilder builder) phoneRoute;

  /// On the right, how it replaces what was there (a quick fade). Make it
  /// `barrierDismissible` (nothing to tap — the page covers it): then Esc
  /// closes what is open on the right.
  final Route<void> Function(WidgetBuilder builder) paneRoute;
  final Object? memoryKey;
  final Map<ShortcutActivator, void Function(BuildContext context, PaneController pane)> shortcuts;

  /// What the right column shows when a tab comes back, by [memoryKey].
  static final _memory = <Object, _Open>{};

  /// Forget every tab's open thing (tests; sign-out).
  static void forgetAll() => _memory.clear();

  static final _mounted = <_AdaptiveSplitState>[];

  /// The split of [memoryKey] that is on screen with two columns, if any —
  /// a notification's chat opens in it.
  static PaneController? visible(Object memoryKey) {
    for (final s in _mounted.reversed) {
      if (s.widget.memoryKey == memoryKey && s._wide == true && (ModalRoute.of(s.context)?.isCurrent ?? true)) {
        return s;
      }
    }
    return null;
  }

  static PaneController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PaneScope>()?.pane;

  /// The id of the row open on the right — null on a phone (nothing is
  /// beside the list there).
  static Object? selectedOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_PaneScope>();
    return scope == null || !scope.wide ? null : scope.notifier?.value;
  }

  @override
  State<AdaptiveSplit> createState() => _AdaptiveSplitState();
}

class _AdaptiveSplitState extends State<AdaptiveSplit> implements PaneController {
  final _pane = GlobalKey<NavigatorState>();
  final _listKey = GlobalKey();
  final _selected = ValueNotifier<Object?>(null);
  late final _observer = _PaneObserver(_paneEmptied);

  /// What is open: on the right, or full screen as [_phoneRoute].
  _Open? _shown;
  Route<void>? _phoneRoute;
  bool? _wide;

  @override
  bool get wide => _wide ?? false;

  @override
  ValueListenable<Object?> get selected => _selected;

  @override
  void initState() {
    super.initState();
    AdaptiveSplit._mounted.add(this);
  }

  @override
  void dispose() {
    AdaptiveSplit._mounted.remove(this);
    _selected.dispose();
    super.dispose();
  }

  @override
  void open(WidgetBuilder builder, {Object? id}) {
    _shown = _Open(builder, id);
    _selected.value = id;
    if (wide) {
      final key = widget.memoryKey;
      if (key != null) AdaptiveSplit._memory[key] = _shown!;
      _pane.currentState?.pushAndRemoveUntil(widget.paneRoute(builder), (r) => r.isFirst);
    } else {
      _pushPhone(_shown!);
    }
  }

  void _pushPhone(_Open what) {
    final route = widget.phoneRoute(what.builder);
    _phoneRoute = route;
    Navigator.of(context).push(route).whenComplete(() {
      if (_phoneRoute != route || !mounted) return;
      _phoneRoute = null;
      _forget();
    });
  }

  /// Back on the right went to the placeholder.
  void _paneEmptied() {
    if (mounted && wide) _forget();
  }

  /// Closed: nothing open, nothing to bring back with the tab.
  void _forget() {
    _shown = null;
    _selected.value = null;
    final key = widget.memoryKey;
    if (key != null) AdaptiveSplit._memory.remove(key);
  }

  /// The window changed: carry what is open across.
  void _moved(bool nowWide) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _wide != nowWide) return;
      final what = _shown;
      if (what == null) return;
      if (nowWide) {
        // Full screen → the right column, unless something is on top of it
        // (then it stays where it is).
        final route = _phoneRoute;
        if (route == null || !route.isActive || !route.isCurrent) return;
        _phoneRoute = null;
        Navigator.of(context).removeRoute(route);
        open(what.builder, id: what.id);
      } else {
        // The right column → full screen (what was opened inside it goes).
        _pushPhone(what);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nowWide = isWideSize(MediaQuery.sizeOf(context));
    if (_wide == null) {
      final key = widget.memoryKey;
      final remembered = key == null ? null : AdaptiveSplit._memory[key];
      if (nowWide && remembered != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && wide && _shown == null) open(remembered.builder, id: remembered.id);
        });
      }
    } else if (_wide != nowWide) {
      _moved(nowWide);
    }
    _wide = nowWide;
    final list = KeyedSubtree(
      key: _listKey,
      child: Builder(builder: widget.list),
    );
    Widget body = nowWide ? _twoColumns(context, list) : list;
    if (widget.shortcuts.isNotEmpty) {
      final inside = body;
      body = Builder(
        builder: (inner) => CallbackShortcuts(
          bindings: {for (final e in widget.shortcuts.entries) e.key: () => e.value(inner, this)},
          child: Focus(autofocus: true, child: inside),
        ),
      );
    }
    return _PaneScope(pane: this, wide: nowWide, notifier: _selected, child: body);
  }

  Widget _twoColumns(BuildContext context, Widget list) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    // Each side lays out as if it were the screen (bubble widths, sheets).
    Widget side(double width, Widget child) => MediaQuery(
      data: mq.copyWith(size: Size(width, mq.size.height)),
      child: child,
    );
    return LayoutBuilder(
      builder: (context, c) {
        final listWidth = listColumnWidth(c.maxWidth);
        final right = c.maxWidth - listWidth - 0.5;
        return Row(
          children: [
            SizedBox(width: listWidth, child: side(listWidth, list)),
            SizedBox(width: 0.5, child: ColoredBox(color: tokens.divider)),
            SizedBox(
              width: right,
              child: side(
                right,
                ClipRect(
                  child: Navigator(
                    key: _pane,
                    observers: [_observer],
                    onGenerateRoute: (_) => PageRouteBuilder<void>(
                      pageBuilder: (ctx, _, _) => ColoredBox(
                        key: const ValueKey('split-placeholder'),
                        color: DsTheme.of(ctx).bg,
                        child: Center(
                          child: Text(
                            widget.placeholder,
                            textAlign: TextAlign.center,
                            style: DsText.callout.copyWith(color: DsTheme.of(ctx).text3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PaneObserver extends NavigatorObserver {
  _PaneObserver(this.onEmpty);
  final VoidCallback onEmpty;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isFirst ?? false) onEmpty();
  }
}

class _PaneScope extends InheritedNotifier<ValueNotifier<Object?>> {
  const _PaneScope({required this.pane, required this.wide, required super.notifier, required super.child});
  final PaneController pane;
  final bool wide;

  @override
  bool updateShouldNotify(_PaneScope old) => old.wide != wide || super.updateShouldNotify(old);
}

/// A sheet's place: at the bottom on a phone; on a wide screen a popup of
/// [kPopupMaxWidth] in the middle (rounded all round — [radius]), above
/// the keyboard. [builder] reads the MediaQuery below it — the popup has
/// no home-bar padding or keyboard inset of its own. Esc closes it.
class DsSheetPlacement extends StatelessWidget {
  const DsSheetPlacement({super.key, required this.builder, this.radius = 20, this.dismissible = true});
  final WidgetBuilder builder;
  final double radius;

  /// Esc closes it (taps outside are the route's business).
  final bool dismissible;

  /// Below a sheet shown as the wide screen's popup (no grabber there).
  static bool popupOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_PopupMark>() != null;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    Widget placed;
    if (!isWideSize(mq.size)) {
      // Rises by its own height with the route (not by the screen's — a
      // small sheet would spend the first frames below the edge).
      final anim = ModalRoute.of(context)?.animation;
      final sheet = Builder(builder: builder);
      placed = Align(
        alignment: Alignment.bottomCenter,
        child: anim == null
            ? sheet
            : SlideTransition(
                position: anim.drive(
                  Tween(begin: const Offset(0, 1), end: Offset.zero).chain(CurveTween(curve: DsMotion.emphasized)),
                ),
                child: sheet,
              ),
      );
    } else {
      final free = mq.size.height - mq.viewInsets.bottom;
      placed = Padding(
        padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
        child: Center(
          child: ConstrainedBox(
            key: const ValueKey('sheet-popup'),
            constraints: BoxConstraints(maxWidth: kPopupMaxWidth, maxHeight: free * 0.86),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: MediaQuery(
                data: mq
                    .removePadding(removeBottom: true)
                    .removeViewInsets(removeBottom: true)
                    .copyWith(size: Size(kPopupMaxWidth, free * 0.86)),
                child: _PopupMark(child: Builder(builder: builder)),
              ),
            ),
          ),
        ),
      );
    }
    if (!dismissible) return placed;
    return Actions(
      actions: {DismissIntent: CallbackAction<DismissIntent>(onInvoke: (_) => Navigator.of(context).maybePop())},
      child: Focus(autofocus: true, child: placed),
    );
  }
}

class _PopupMark extends InheritedWidget {
  const _PopupMark({required super.child});

  @override
  bool updateShouldNotify(_PopupMark old) => false;
}

/// Forms on a wide screen: a column of [kFormMaxWidth] in the middle (the
/// screen lays out as if it were that wide); as is on a phone.
class DsReadableWidth extends StatelessWidget {
  const DsReadableWidth({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    if (!isWideSize(mq.size)) return child;
    return ColoredBox(
      color: DsTheme.of(context).bg,
      child: Center(
        child: SizedBox(
          width: kFormMaxWidth,
          child: MediaQuery(
            data: mq.copyWith(size: Size(kFormMaxWidth, mq.size.height)),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Keys in the composer on a hardware keyboard: Enter (and ⌘/Ctrl+Enter)
/// sends, Shift+Enter is a new line; ↑ in an empty field edits my last
/// message. Letters still being composed (an input method's marked text)
/// take Enter themselves. The on-screen keyboard's Enter stays a new line.
class SendShortcuts extends StatelessWidget {
  const SendShortcuts({
    super.key,
    required this.controller,
    required this.onSend,
    this.onEditLast,
    required this.child,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback? onEditLast;
  final Widget child;

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final composing = controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (keys.isShiftPressed || keys.isAltPressed) return KeyEventResult.ignored;
      if (e is KeyDownEvent) onSend();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && onEditLast != null && controller.text.isEmpty && !keys.isShiftPressed) {
      if (e is KeyDownEvent) onEditLast!();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _key, child: child);
  }
}
