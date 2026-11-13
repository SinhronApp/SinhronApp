import '../../core/services/net_service.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show lerpDouble;

import 'package:flutter/rendering.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../core/haptics.dart';
import '../../app/adaptive.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/chat_actions.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/core_providers.dart';
import '../../core/app_notice.dart';
import '../../core/providers/message_actions.dart';
import '../../core/mentions.dart';
import '../../core/providers/people.dart';
import '../../core/providers/presence.dart';
import '../../core/providers/saved_messages.dart';
import '../chat_info/chat_info_screen.dart' show myIdentityProvider;
import '../verify/verify_contact.dart' show verifiedPeersProvider;
import '../../core/providers/settings_providers.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_chat_row.dart';
import '../../widgets/ds_empty_state.dart';
import '../../widgets/ds_count_badge.dart';
import '../../widgets/ds_header.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_pull_to_refresh.dart';
import '../../widgets/ds_shimmer.dart';
import '../../widgets/ds_swipe_actions.dart';
import '../../widgets/ds_page_route.dart';
import '../../widgets/ds_tab_bar.dart';
import '../server_notices/server_notices.dart';
import 'access_reminder.dart';
import 'chat_data.dart';
import 'chat_peek.dart';
import 'chat_folders_screen.dart';
import 'folder_editor_screen.dart';
import 'folders.dart';
import 'reorder_screen.dart';
import '../../l10n/l10n.dart';
import '../app_update/update_banner.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../settings/transfer_cards.dart' show IncomingTransferStrip;

List<DsTabItem> _tabs(BuildContext context, int unreadChats) => [
  DsTabItem(id: DsTabId.chats, label: context.l10n.tabChats, icon: DsIconShape.tabChats, badge: unreadChats),
  DsTabItem(id: DsTabId.calls, label: context.l10n.tabCalls, icon: DsIconShape.tabCalls),
  DsTabItem(id: DsTabId.contacts, label: context.l10n.tabContacts, icon: DsIconShape.tabContacts),
  DsTabItem(id: DsTabId.settings, label: context.l10n.tabSettings, icon: DsIconShape.tabSettings),
];

class ChatListScreen extends ConsumerStatefulWidget {
  /// Called when user taps a chat row. Default = no-op.
  final void Function(ChatPreview chat)? onChatTap;
  final ValueChanged<DsTabId>? onTabChange;
  final VoidCallback? onSearch;
  final VoidCallback? onCompose;

  /// My photo at the top-left → My profile (owner, 2026-10-18).
  final VoidCallback? onProfile;

  /// Open the folder editor (null folder = create a new one).
  final void Function(ChatFolder? folder)? onEditFolder;

  /// Open the archived chats list.
  final VoidCallback? onOpenArchive;

  /// ADR-059 — the "Keep access" card's "Save" (Settings → Secret words).
  final VoidCallback? onSaveAccess;

  const ChatListScreen({
    super.key,
    this.onChatTap,
    this.onTabChange,
    this.onSearch,
    this.onCompose,
    this.onProfile,
    this.onEditFolder,
    this.onOpenArchive,
    this.onSaveAccess,
  });

  @override
  ConsumerState<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends ConsumerState<ChatListScreen> {
  PageController _pages = PageController();

  /// 0 → 1 as the list scrolls: drives the large-title collapse.
  final ValueNotifier<double> _collapse = ValueNotifier(0);

  /// Tab bar content height (without the safe-area inset).
  static const _tabBarHeight = 58.0;

  /// The open folder — by id, so it stays open when folders are moved,
  /// hidden or added; [_folder] is its index among the tabs.
  String? _activeId;
  int _folder = 0;

  /// Tab ids the PageView was built for.
  String _signature = '';

  /// A tab tap animates across pages — no tick for each page passed.
  bool _jumping = false;

  /// The tabs change when folders load, are added, hidden or moved. A
  /// PageView whose pages change off-screen keeps a stale scroll extent
  /// and index, so rebuild it fresh — on a new controller that starts at
  /// the open folder.
  void _syncPages(List<ChatFolder> folders, int active) {
    final sig = folders.map((f) => f.id).join(',');
    if (sig == _signature) return;
    if (_signature.isNotEmpty) {
      final old = _pages;
      _pages = PageController(initialPage: active);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    _signature = sig;
  }

  @override
  void dispose() {
    _connectingTimer?.cancel();
    _collapse.dispose();
    _pages.dispose();
    super.dispose();
  }

  void _selectFolder(int i, List<ChatFolder> folders) {
    setState(() {
      _folder = i;
      _activeId = folders[i].id;
    });
    if (!_pages.hasClients) return;
    _jumping = true;
    _pages
        .animateToPage(i, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic)
        .whenComplete(() => _jumping = false);
  }

  /// Save the tab order after [visibleIds] were rearranged (drag in the
  /// strip, Move left / right); hidden folders keep their places.
  Future<void> _reorderTabs(List<String> visibleIds) {
    final all = [for (final f in ref.read(orderedFoldersProvider)) f.id];
    return ref
        .read(folderLayoutProvider.notifier)
        .setOrder(mergeVisibleOrder(all, ref.read(hiddenFoldersProvider), visibleIds));
  }

  Future<void> _editFolder(ChatFolder? f) async {
    if (widget.onEditFolder != null) return widget.onEditFolder!(f);
    await Navigator.of(context).push(
      DsPageRoute<void>(builder: (ctx) => FolderEditorScreen(folder: f, onDone: () => Navigator.of(ctx).pop())),
    );
  }

  Future<void> _folderMenu(ChatFolder f, List<ChatFolder> folders, List<ChatPreview> chats) async {
    final actions = ref.read(chatActionsProvider);
    final i = folders.indexWhere((x) => x.id == f.id);
    final picked = await showDsActionSheet<String>(
      context,
      title: folderTitle(context, f),
      actions: [
        if (!f.builtIn) DsSheetAction(context.l10n.editFolder, 'edit'),
        if (i > 0) DsSheetAction(context.l10n.moveLeft, 'left'),
        if (i >= 0 && i < folders.length - 1) DsSheetAction(context.l10n.moveRight, 'right'),
        DsSheetAction(context.l10n.markAllRead, 'read'),
        DsSheetAction(context.l10n.hideFolder, 'hide'),
        DsSheetAction(context.l10n.editFolders, 'folders'),
        if (!f.builtIn) DsSheetAction(context.l10n.deleteFolder, 'delete', destructive: true),
      ],
    );
    switch (picked) {
      case 'edit':
        await _editFolder(f);
      case 'left' || 'right':
        // The VoiceOver path for the drag in the strip.
        final ids = [for (final x in folders) x.id];
        ids.insert(i + (picked == 'left' ? -1 : 1), ids.removeAt(i));
        await _reorderTabs(ids);
      case 'read':
        await actions.markAllRead(
          chatsInFolder(f, chats).where((c) => c.hasUnread).map((c) => c.id).whereType<String>(),
        );
      case 'hide':
        await ref.read(folderLayoutProvider.notifier).setHidden(f.id, true);
      case 'folders':
        if (!mounted) return;
        await Navigator.of(context).push(DsPageRoute<void>(builder: (_) => const ChatFoldersScreen()));
      case 'delete':
        // Asks first, as the folder editor does (2026-10-16 UI audit).
        if (!mounted) return;
        final ok = await showDsActionSheet<bool>(
          context,
          title: context.l10n.deleteFolderConfirm(f.name),
          actions: [DsSheetAction(context.l10n.deleteFolder, true, destructive: true)],
        );
        if (ok != true || !mounted) return;
        await ref.read(customFoldersProvider.notifier).delete(f.id);
    }
  }

  /// "Connecting…" in the title while there's no connection (owner,
  /// 2026-10-16, like Telegram) — after a second, so a quick reconnect
  /// doesn't flicker. Not for "idle" (not started: onboarding, tests).
  bool _showConnecting = false;
  Timer? _connectingTimer;

  void _onNetStatus(NetStatus s) {
    final lost = s == NetStatus.connecting || s == NetStatus.disconnected;
    if (!lost) {
      _connectingTimer?.cancel();
      _connectingTimer = null;
      if (_showConnecting) setState(() => _showConnecting = false);
      return;
    }
    if (_showConnecting || _connectingTimer != null) return;
    _connectingTimer = Timer(const Duration(seconds: 1), () {
      _connectingTimer = null;
      if (mounted) setState(() => _showConnecting = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(netStatusProvider, (_, s) => _onNetStatus(s));
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final chatsAsync = ref.watch(chatsProvider);
    // Real data only — never demo rows (UI backlog §1 item 8).
    final chats = chatsAsync.value ?? const <ChatPreview>[];
    final userName = ref.watch(profileNameProvider).value ?? '';
    final unreadChats = ref.watch(unreadChatsCountProvider);
    final folders = ref.watch(tabFoldersProvider);
    var active = folders.indexWhere((f) => f.id == _activeId);
    // The open folder was hidden or deleted: its neighbour opens.
    if (active < 0) active = _folder.clamp(0, folders.length - 1);
    _folder = active;
    _activeId = folders[active].id;
    _syncPages(folders, active);
    // Only "All" left → no strip, as in Telegram.
    final showTabs = folders.length > 1 || folders.single.id != kFolderAll.id;
    // The archive row tops All — or the first tab when All is hidden.
    final homeId = folders.any((f) => f.id == kFolderAll.id) ? kFolderAll.id : folders.first.id;
    final archivedCount = chats.where((c) => c.archived).length;

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Stack(
          children: [
            Column(
              children: [
                // Large title that tightens as the list scrolls (§5 item 41).
                ValueListenableBuilder<double>(
                  valueListenable: _collapse,
                  builder: (_, c, _) => DsHeader(
                    userName: userName,
                    userImage: ref.watch(myAvatarProvider),
                    title: _showConnecting ? context.l10n.netConnecting : context.l10n.chatsTitle,
                    connecting: _showConnecting,
                    collapse: c,
                    onSearch: widget.onSearch,
                    onCompose: widget.onCompose,
                    onProfile: widget.onProfile,
                  ),
                ),
                if (showTabs)
                  _FolderTabs(
                    folders: folders,
                    active: active,
                    counts: [for (final f in folders) unreadInFolder(f, chats)],
                    pages: _pages,
                    onSelect: (i) => _selectFolder(i, folders),
                    onMenu: (i) => _folderMenu(folders[i], folders, chats),
                    onReorder: _reorderTabs,
                    onAdd: widget.onEditFolder == null ? null : () => widget.onEditFolder!(null),
                  ),
                AccessReminderCard(onSave: widget.onSaveAccess),
                // ADR-077 — the server's service notices: polled here; the
                // row itself lives in Settings (status 223).
                const ServerNoticesRow(hidden: true),
                // ADR-058 — "Update 0.6.0 is available" (Android, our APK).
                const UpdateBanner(),
                // ADR-064 — a new device while its chats are arriving.
                const IncomingTransferStrip(),
                Expanded(
                  child: Stack(
                    children: [
                      NotificationListener<ScrollUpdateNotification>(
                        onNotification: (n) {
                          if (n.metrics.axis == Axis.vertical) {
                            // A long All list rests with the archive row tucked
                            // above it — that resting offset is "top", not scrolled.
                            final tucked = _folder < folders.length &&
                                folders[_folder].id == homeId &&
                                archivedCount > 0 &&
                                n.metrics.maxScrollExtent >= _kArchiveRowHeight;
                            final rest = tucked ? _kArchiveRowHeight : 0.0;
                            _collapse.value = ((n.metrics.pixels - rest) / 60).clamp(0.0, 1.0);
                          }
                          return false;
                        },
                        child: KeyedSubtree(
                          key: ValueKey('folder-pages-$_signature'),
                          child: PageView.builder(
                            key: const ValueKey('folder-pages'),
                            controller: _pages,
                            itemCount: folders.length,
                            onPageChanged: (i) {
                              if (_jumping) return;
                              unawaited(ref.read(hapticsProvider).play(Haptic.selection));
                              setState(() {
                                _folder = i;
                                _activeId = folders[i].id;
                              });
                            },
                            itemBuilder: (context, i) {
                              final f = folders[i];
                              final all = f.id == kFolderAll.id;
                              return _FolderPage(
                                key: ValueKey('folder-${f.id}'),
                                folder: f,
                                // ADR-055 — Saved messages: first in All, nowhere else.
                                chats: chatsInFolder(f, [for (final c in chats) if (!c.saved) c]),
                                saved: all && chatsAsync.hasValue ? savedChatEntry(chats) : null,
                                loading: !chatsAsync.hasValue && !chatsAsync.hasError,
                                error: chatsAsync.hasError && chats.isEmpty,
                                noChatsAtAll: chatsAsync.hasValue && chats.isEmpty,
                                archivedCount: f.id == homeId ? archivedCount : 0,
                                onOpenArchive: widget.onOpenArchive,
                                onChatTap: widget.onChatTap,
                                bottomInset: _tabBarHeight + (pad.bottom > 0 ? pad.bottom : 16),
                              );
                            },
                          ),
                        ),
                      ),
                      // The list scrolls under the translucent tab bar.
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: DsTabBar(
                          items: _tabs(context, unreadChats),
                          active: DsTabId.chats,
                          safeBottomPadding: EdgeInsets.only(bottom: pad.bottom > 0 ? pad.bottom : DsSpace.x4),
                          onSelect: (t) {
                            if (t != DsTabId.chats && widget.onTabChange != null) {
                              widget.onTabChange!(t);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Folder tabs (2026-10-18, like Telegram): a pill slides under the open
/// tab and follows the finger while the list is swiped between folders;
/// unread chats per folder as a count. Tap to switch; hold a tab and drag
/// it sideways to move it (saved on release); hold and let go for the
/// folder menu. "+" creates a folder.
class _FolderTabs extends StatefulWidget {
  const _FolderTabs({
    required this.folders,
    required this.active,
    required this.counts,
    required this.pages,
    required this.onSelect,
    required this.onMenu,
    required this.onReorder,
    this.onAdd,
  });

  final List<ChatFolder> folders;
  final int active;
  final List<int> counts;

  /// The folder PageView's controller — the pill follows its page.
  final PageController pages;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onMenu;

  /// Every tab id in the new order, after a drag.
  final ValueChanged<List<String>> onReorder;
  final VoidCallback? onAdd;

  @override
  State<_FolderTabs> createState() => _FolderTabsState();
}

class _FolderTabsState extends State<_FolderTabs> {
  static const _height = 32.0;
  static const _gap = 4.0;
  static const _side = DsSpace.x4;

  final _scroll = ScrollController();

  /// Measured tab widths by folder id (labels and counts vary).
  final Map<String, double> _widths = {};

  /// While dragging: tab slots → folder indices; kept after the drop until
  /// the saved order comes back.
  List<int>? _order;
  int? _drag;
  double _dragDx = 0;
  double _dragBase = 0;
  bool _dragMoved = false;

  int get _n => widget.folders.length;
  List<int> get _slots => _order ?? List.generate(_n, (i) => i);

  double _w(int k) => _widths[widget.folders[k].id] ?? 72;

  /// Left edge of each folder's tab (by folder index) for [order].
  List<double> _xs(List<int> order) {
    final xs = List<double>.filled(_n, 0);
    var x = 0.0;
    for (final k in order) {
      xs[k] = x;
      x += _w(k) + _gap;
    }
    return xs;
  }

  @override
  void didUpdateWidget(_FolderTabs old) {
    super.didUpdateWidget(old);
    final ids = widget.folders.map((f) => f.id).join(',');
    if (ids != old.folders.map((f) => f.id).join(',')) {
      _order = null;
      _drag = null;
      _dragDx = 0;
    }
    if (widget.active != old.active) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(widget.active));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scroll the strip just enough to show the open tab whole, with a bit
  /// of its neighbour peeking (no jump when it's already in view).
  void _reveal(int k) {
    if (!mounted || !_scroll.hasClients || k >= _n) return;
    final p = _scroll.position;
    const peek = DsSpace.x10;
    final left = _side + _xs(_slots)[k];
    final right = left + _w(k);
    var target = p.pixels;
    if (left - peek < p.pixels) target = left - peek;
    if (right + peek > p.pixels + p.viewportDimension) target = right + peek - p.viewportDimension;
    target = target.clamp(0.0, p.maxScrollExtent);
    if ((target - p.pixels).abs() < 1) return;
    _scroll.animateTo(target, duration: DsMotion.of(context, DsMotion.base), curve: DsMotion.enter);
  }

  void _setWidth(String id, double w) {
    if (!mounted || _widths[id] == w) return;
    setState(() => _widths[id] = w);
  }

  void _startDrag(int k) {
    DsHaptics.play(Haptic.menu);
    setState(() {
      _order = [..._slots];
      _drag = k;
      _dragDx = 0;
      _dragBase = 0;
      _dragMoved = false;
    });
  }

  void _updateDrag(double dx) {
    final k = _drag;
    if (k == null) return;
    if (dx.abs() > 6) _dragMoved = true;
    final order = _order!;
    // Swap with a neighbour once the dragged tab's centre passes its
    // centre; the base shifts so the tab stays under the finger.
    while (true) {
      final s = order.indexOf(k);
      final xs = _xs(order);
      final centre = xs[k] + dx - _dragBase + _w(k) / 2;
      if (s < order.length - 1 && centre > xs[order[s + 1]] + _w(order[s + 1]) / 2) {
        _dragBase += _w(order[s + 1]) + _gap;
        order.insert(s + 1, order.removeAt(s));
      } else if (s > 0 && centre < xs[order[s - 1]] + _w(order[s - 1]) / 2) {
        _dragBase -= _w(order[s - 1]) + _gap;
        order.insert(s - 1, order.removeAt(s));
      } else {
        break;
      }
      DsHaptics.play(Haptic.selection);
    }
    setState(() => _dragDx = dx - _dragBase);
  }

  void _endDrag() {
    final k = _drag;
    if (k == null) return;
    final order = _order!;
    var changed = false;
    for (var i = 0; i < order.length; i++) {
      if (order[i] != i) changed = true;
    }
    setState(() {
      _drag = null;
      _dragDx = 0;
      if (!changed) _order = null;
    });
    if (changed) {
      widget.onReorder([for (final i in order) widget.folders[i].id]);
    } else if (!_dragMoved) {
      widget.onMenu(k);
    }
  }

  double _page() {
    final c = widget.pages;
    if (c.hasClients && c.positions.length == 1 && c.position.hasContentDimensions) {
      return (c.page ?? widget.active.toDouble()).clamp(0.0, (_n - 1).toDouble());
    }
    return widget.active.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(_side, DsSpace.x1, _side, DsSpace.x2h5),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: widget.pages,
            builder: (context, _) {
              final page = _page();
              final xs = _xs(_slots);
              double left(int k) => xs[k] + (k == _drag ? _dragDx : 0);
              final lo = page.floor().clamp(0, _n - 1);
              final hi = page.ceil().clamp(0, _n - 1);
              final t = page - lo;
              final total = xs.isEmpty ? 0.0 : [for (var k = 0; k < _n; k++) xs[k] + _w(k)].reduce(math.max);
              final drag = _drag;
              return SizedBox(
                width: total,
                height: _height,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // The sliding pill under the open tab.
                    Positioned(
                      key: const ValueKey('folder-indicator'),
                      left: lerpDouble(left(lo), left(hi), t),
                      width: lerpDouble(_w(lo), _w(hi), t),
                      top: 0,
                      bottom: 0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tokens.text,
                          borderRadius: BorderRadius.circular(tokens.radiusPill),
                        ),
                      ),
                    ),
                    for (var k = 0; k < _n; k++)
                      if (k != drag) _positioned(k, left(k), (1 - (page - k).abs()).clamp(0.0, 1.0), tokens),
                    if (drag != null && drag < _n)
                      _positioned(drag, left(drag), (1 - (page - drag).abs()).clamp(0.0, 1.0), tokens),
                  ],
                ),
              );
            },
          ),
          if (widget.onAdd != null) ...[
            const SizedBox(width: 6),
            Semantics(
              button: true,
              label: context.l10n.newFolder,
              child: DsPressable(
                key: const ValueKey('folder-add'),
                haptic: Haptic.selection,
                onTap: widget.onAdd,
                child: Container(
                  width: _height,
                  height: _height,
                  decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
                  child: CustomPaint(painter: DsGlyphPainter(DsGlyph.plus, color: tokens.text2, strokeWidth: 2)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One tab at [left]; [c] is how open it is (1 = the open tab, between
  /// 0 and 1 mid-swipe) — the label colour follows the sliding pill.
  Widget _positioned(int k, double left, double c, DsTokens tokens) {
    final f = widget.folders[k];
    final count = widget.counts[k];
    final lifted = k == _drag;
    final fg = Color.lerp(tokens.text2, tokens.bg, c)!;
    return AnimatedPositioned(
      key: ValueKey('folder-slot-${f.id}'),
      // Neighbours glide out of the way; the dragged tab sticks to the finger.
      duration: lifted || _order == null ? Duration.zero : const Duration(milliseconds: 180),
      curve: DsMotion.enter,
      left: left,
      top: 0,
      bottom: 0,
      child: Semantics(
        button: true,
        selected: k == widget.active,
        child: GestureDetector(
          key: ValueKey('folder-tab-${f.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () {
            DsHaptics.play(Haptic.selection);
            widget.onSelect(k);
          },
          onLongPressStart: (_) => _startDrag(k),
          onLongPressMoveUpdate: (d) => _updateDrag(d.offsetFromOrigin.dx),
          onLongPressEnd: (_) => _endDrag(),
          child: _WidthReporter(
            onWidth: (w) => _setWidth(f.id, w),
            child: AnimatedScale(
              duration: const Duration(milliseconds: 150),
              scale: lifted ? 1.08 : 1,
              child: Container(
                height: _height,
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
                alignment: Alignment.center,
                decoration: lifted
                    ? BoxDecoration(
                        color: Color.lerp(tokens.surface, tokens.text, c),
                        borderRadius: BorderRadius.circular(tokens.radiusPill),
                        boxShadow: DsShadow.float,
                      )
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(folderLabel(context, f), style: DsType.filterPill.copyWith(color: fg)),
                    if (count > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.nudge1),
                        decoration: BoxDecoration(
                          color: Color.lerp(tokens.accentSoft, DsPalette.white20, c),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: DsAnimatedCount(
                          count: count,
                          style: DsType.filterCount.copyWith(color: Color.lerp(tokens.accent, tokens.bg, c)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Reports its child's laid-out width (after the frame) — the tab strip
/// positions tabs and the pill from real widths.
class _WidthReporter extends SingleChildRenderObjectWidget {
  const _WidthReporter({required this.onWidth, super.child});
  final ValueChanged<double> onWidth;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderWidthReporter(onWidth);

  @override
  void updateRenderObject(BuildContext context, _RenderWidthReporter renderObject) => renderObject.onWidth = onWidth;
}

class _RenderWidthReporter extends RenderProxyBox {
  _RenderWidthReporter(this.onWidth);
  ValueChanged<double> onWidth;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final w = size.width;
    if (w == _last) return;
    _last = w;
    WidgetsBinding.instance.addPostFrameCallback((_) => onWidth(w));
  }
}

/// One folder's chat list (a page of the folder PageView).
class _FolderPage extends ConsumerStatefulWidget {
  const _FolderPage({
    super.key,
    required this.folder,
    required this.chats,
    required this.loading,
    required this.error,
    required this.noChatsAtAll,
    required this.archivedCount,
    this.saved,
    this.bottomInset = 0,
    this.onOpenArchive,
    this.onChatTap,
  });

  final ChatFolder folder;
  final List<ChatPreview> chats;

  /// ADR-055 — the Saved messages row on top (All only), real or stand-in.
  final ChatPreview? saved;
  final bool loading;
  final bool error;
  final bool noChatsAtAll;
  final int archivedCount;

  /// Room under the last row for the translucent tab bar.
  final double bottomInset;
  final VoidCallback? onOpenArchive;
  final void Function(ChatPreview chat)? onChatTap;

  @override
  ConsumerState<_FolderPage> createState() => _FolderPageState();
}

class _FolderPageState extends ConsumerState<_FolderPage> {
  final _scroll = ScrollController();

  /// Tech-debt 2.21 — like Telegram, the archive row waits above the top
  /// of a long list: the list opens scrolled just past it and a pull
  /// down reveals it. Short lists (nothing to scroll) keep it in view.
  bool _archiveTucked = false;

  /// The rows have had their entrance — rows built later (scrolled into
  /// view, a new chat) are simply there.
  bool _appeared = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _tuckArchive() {
    if (_archiveTucked) return;
    _archiveTucked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels == 0 && p.maxScrollExtent >= _kArchiveRowHeight) _scroll.jumpTo(_kArchiveRowHeight);
    });
  }

  @override
  Widget build(BuildContext context) {
    final folder = widget.folder;
    final chats = widget.chats;
    final loading = widget.loading;
    final error = widget.error;
    final noChatsAtAll = widget.noChatsAtAll;
    final archivedCount = widget.archivedCount;
    final bottomInset = widget.bottomInset;
    final onOpenArchive = widget.onOpenArchive;
    final onChatTap = widget.onChatTap;
    final saved = widget.saved;
    Future<void> refresh() async {
      ref.invalidate(chatsProvider);
      await ref.read(chatsProvider.future);
    }

    final Widget body;
    if (loading) {
      body = const _ChatListSkeleton();
    } else if (error) {
      body = _ChatListMessage(title: context.l10n.chatsLoadError, body: context.l10n.pullToRetry);
    } else if (noChatsAtAll && archivedCount == 0 && saved == null) {
      body = _ChatListMessage(title: context.l10n.noChatsYet, body: context.l10n.noChatsHint);
    } else if (chats.isEmpty && archivedCount == 0 && saved == null) {
      body = _ChatListMessage(
        title: context.l10n.noChatsHere,
        body: context.l10n.folderEmptyHint(folderTitle(context, folder)),
      );
    } else {
      final pinnedIds = [
        for (final c in chats)
          if (c.pinned && c.id != null) c.id!,
      ];
      final archive = archivedCount > 0 ? 1 : 0;
      if (archive == 1) _tuckArchive();
      final extra = archive + (saved == null ? 0 : 1);
      // Only Saved so far: the "no chats yet" hint under it.
      final hint = saved != null && chats.isEmpty ? 1 : 0;
      final typing = ref.watch(typingChatsProvider);
      final names = ref.watch(peerNamesProvider).value ?? const <String, String>{};
      final avatars = ref.watch(peerAvatarsProvider).value ?? const <String, Uint8List>{};
      final presence = ref.watch(peerPresenceProvider);
      final verified =
          ref
              .watch(
                verifiedPeersProvider([
                  for (final c in chats)
                    if (!c.group && c.id != null && c.peerId != null) '${c.id}:${c.peerId}',
                ].join(',')),
              )
              .value ??
          const <String>{};
      final me = ref.read(myIdentityProvider)();
      // Rows keep their state when the order changes (pin, a new message,
      // archive) so they can glide to the new place (DsReorderSlide).
      final slots = <String, int>{
        if (archive == 1) 'archive': 0,
        if (saved != null) 'chat-saved': archive,
        for (var i = 0; i < chats.length; i++) 'chat-${chats[i].id ?? '#${i + extra}'}': i + extra,
      };
      final appeared = _appeared;
      if (!appeared) WidgetsBinding.instance.addPostFrameCallback((_) => _appeared = true);
      Widget slot(String id, int i, Widget row) => DsReorderSlide(
        key: ValueKey('slot:$id'),
        child: DsAppear(index: i, animate: !appeared, child: row),
      );
      body = ListView.builder(
        key: const ValueKey('chat-list'),
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
        padding: EdgeInsets.only(bottom: bottomInset),
        itemCount: chats.length + extra + hint,
        findChildIndexCallback: (key) => key is ValueKey<String> ? slots[key.value.replaceFirst('slot:', '')] : null,
        itemBuilder: (ctx, i) {
          if (archive == 1 && i == 0) {
            return slot('archive', i, _ArchiveRow(count: archivedCount, onTap: onOpenArchive));
          }
          if (saved != null && i == archive) {
            return slot(
              'chat-saved',
              i,
              ChatRowWithActions(
                key: const ValueKey('chat-saved'),
                chat: saved,
                isLast: chats.isEmpty,
                pinnedIds: pinnedIds,
                onTap: () => onChatTap?.call(saved),
              ),
            );
          }
          if (hint == 1 && i == extra) {
            return Padding(
              key: const ValueKey('chat-list-message'),
              padding: const EdgeInsets.only(top: DsSpace.x12, bottom: DsSpace.x8),
              child: DsEmptyState(
                illustration: DsIllustration.chats,
                title: context.l10n.noChatsYet,
                body: context.l10n.noChatsHint,
              ),
            );
          }
          final stored = chats[i - extra];
          final photo = stored.peerId == null ? null : avatars[stored.peerId];
          final row = stored
              .withPreview(mentionsToDisplay(stored.preview, (k) => k == me ? context.l10n.you : displayNameOf(k, names)))
              .copyWith(
                avatar: photo,
                verified: stored.peerId != null && verified.contains(stored.peerId!.toLowerCase()),
                // ADR-031 — the green dot, for contacts who share it.
                online: !stored.group && !stored.request && stored.peerId != null && isOnlineNow(presence[stored.peerId]),
              );
          final c = typing.containsKey(row.id) ? row.asTyping(context.l10n.typing) : row;
          return slot(
            'chat-${stored.id ?? '#$i'}',
            i,
            ChatRowWithActions(
              key: ValueKey('chat-${c.id}'),
              chat: c,
              isLast: i == chats.length - 1 + extra,
              pinnedIds: pinnedIds,
              onTap: () => onChatTap?.call(c),
            ),
          );
        },
      );
    }
    // Skeleton → chats (or the empty / error message) crossfades.
    final kind = loading
        ? 'loading'
        : error
        ? 'error'
        : body is ListView
        ? 'list'
        : 'message';
    return DsPullToRefresh(
      onRefresh: refresh,
      child: DsFadeSwitcher(
        duration: DsMotion.base,
        expand: true,
        child: KeyedSubtree(key: ValueKey('folder-body-$kind'), child: body),
      ),
    );
  }
}

/// Height of [_ArchiveRow]: 12 + 52 + 12 padding/avatar + 0.5 divider.
const double _kArchiveRowHeight = 76.5;

/// "Archived chats" entry at the top of the All folder.
class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({required this.count, this.onTap});
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      key: const ValueKey('archive-row'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, DsSpace.x3),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: tokens.bgSoft, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: SizedBox(
                width: 24,
                height: 24,
                child: CustomPaint(painter: DsArchiveGlyph(color: tokens.text2)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                context.l10n.archivedChats,
                style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
              ),
            ),
            Text('$count', style: DsText.body.copyWith(color: tokens.text3)),
          ],
        ),
      ),
    );
  }
}

/// A chat row with working swipe actions (mute / archive / delete) and a
/// long-press peek (preview + full action list). Shared by the folder
/// pages and the archive.
class ChatRowWithActions extends ConsumerWidget {
  const ChatRowWithActions({super.key, required this.chat, required this.isLast, required this.pinnedIds, this.onTap});

  final ChatPreview chat;
  final bool isLast;
  final List<String> pinnedIds;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = chat.id;
    final actions = ref.read(chatActionsProvider);
    const white = DsPalette.white;
    return DsSwipeActions(
      // ADR-055 — Saved messages can't be muted, archived or deleted here.
      actions: id == null || chat.saved
          ? const []
          : [
              DsSwipeAction(
                label: chat.muted ? context.l10n.unmute : context.l10n.mute,
                background: DsPalette.artA8A8AB,
                foreground: white,
                icon: CustomPaint(painter: DsBellOffGlyph(color: white)),
                onTap: () => actions.setMuted(id, !chat.muted),
              ),
              DsSwipeAction(
                label: chat.archived ? context.l10n.unarchive : context.l10n.archive,
                background: DsPalette.orange,
                foreground: white,
                icon: CustomPaint(painter: DsArchiveGlyph(color: white)),
                onTap: () => actions.setArchived(id, !chat.archived),
              ),
              DsSwipeAction(
                label: context.l10n.delete,
                background: DsPalette.danger,
                foreground: white,
                icon: CustomPaint(painter: DsTrashGlyph(color: white)),
                onTap: () => confirmDeleteChat(context, ref, chat),
              ),
            ],
      child: GestureDetector(
        onLongPress: id == null || chat.saved ? null : () => _peek(context, ref),
        child: DsChatRow(
          chat: chat,
          isLast: isLast,
          onTap: onTap,
          selected: id != null && AdaptiveSplit.selectedOf(context) == id,
        ),
      ),
    );
  }

  Future<void> _peek(BuildContext context, WidgetRef ref) async {
    final id = chat.id!;
    final a = ref.read(chatActionsProvider);
    final pinIndex = pinnedIds.indexOf(id);
    final picked = await showDsActionSheet<String>(
      context,
      header: ChatPeekPreview(chat: chat),
      actions: [
        DsSheetAction(context.l10n.open, 'open', icon: CupertinoIcons.chat_bubble),
        DsSheetAction(
          chat.pinned ? context.l10n.unpin : context.l10n.pin,
          'pin',
          icon: chat.pinned ? CupertinoIcons.pin_slash : CupertinoIcons.pin,
        ),
        if (chat.pinned && pinIndex > 0) DsSheetAction(context.l10n.moveUp, 'up', icon: CupertinoIcons.arrow_up),
        if (chat.pinned && pinIndex >= 0 && pinIndex < pinnedIds.length - 1)
          DsSheetAction(context.l10n.moveDown, 'down', icon: CupertinoIcons.arrow_down),
        if (chat.pinned && pinnedIds.length > 1)
          DsSheetAction(context.l10n.reorderPinned, 'reorder', icon: CupertinoIcons.arrow_up_arrow_down),
        DsSheetAction(
          chat.hasUnread ? context.l10n.markRead : context.l10n.markUnread,
          'read',
          icon: chat.hasUnread ? CupertinoIcons.envelope_open : CupertinoIcons.envelope_badge,
        ),
        DsSheetAction(
          chat.muted ? context.l10n.unmute : context.l10n.mute,
          'mute',
          icon: chat.muted ? CupertinoIcons.bell : CupertinoIcons.bell_slash,
        ),
        DsSheetAction(
          chat.archived ? context.l10n.unarchive : context.l10n.archive,
          'archive',
          icon: chat.archived ? CupertinoIcons.tray_arrow_up : CupertinoIcons.archivebox,
        ),
        DsSheetAction(context.l10n.deleteChat, 'delete', destructive: true, icon: CupertinoIcons.trash),
      ],
    );
    if (!context.mounted) return;
    switch (picked) {
      case 'open':
        onTap?.call();
      case 'pin':
        await a.setPinned(id, !chat.pinned);
      case 'up':
        await a.movePinned(pinnedIds, id, -1);
      case 'down':
        await a.movePinned(pinnedIds, id, 1);
      case 'reorder':
        final names = {for (final c in ref.read(chatsProvider).value ?? const <ChatPreview>[]) c.id: c.name};
        await Navigator.of(context).push(
          DsPageRoute<void>(
            builder: (_) => ReorderScreen(
              title: context.l10n.reorderPinnedTitle,
              items: [for (final p in pinnedIds) ReorderItem(p, names[p] ?? '')],
              onReorder: a.reorderPinned,
            ),
          ),
        );
      case 'read':
        await (chat.hasUnread ? a.markRead(id) : a.markUnread(id));
      case 'mute':
        await a.setMuted(id, !chat.muted);
      case 'archive':
        await a.setArchived(id, !chat.archived);
      case 'delete':
        await confirmDeleteChat(context, ref, chat);
    }
  }
}

/// Deletion always asks first (far-swipe lands here too). A group I'm
/// still in is left, as in its info: deleted only here it came back with
/// the next message, and the others kept sending to me.
Future<void> confirmDeleteChat(BuildContext context, WidgetRef ref, ChatPreview chat) async {
  final id = chat.id;
  if (id == null) return;
  final l = context.l10n;
  final leave = chat.group && (await ref.read(groupRoleProvider(id).future)).active;
  if (!context.mounted) return;
  final ok = await showDsActionSheet<bool>(
    context,
    title: leave ? l.groupLeaveConfirm(chat.name) : l.deleteChatConfirm(chat.name),
    actions: [DsSheetAction(leave ? l.groupLeave : l.deleteChat, true, destructive: true)],
  );
  if (ok != true) return;
  if (!leave) return ref.read(chatActionsProvider).delete(id);
  try {
    await ref.read(messageActionsProvider).leaveGroup(id);
  } catch (_) {
    appNotice.value = l.groupActionFailed;
  }
}

/// Placeholder rows while the (local, fast) chat list loads.
class _ChatListSkeleton extends StatelessWidget {
  const _ChatListSkeleton();

  @override
  Widget build(BuildContext context) {
    return DsShimmer(
      // Fills whatever height is there; extra rows are clipped.
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          key: const ValueKey('chat-list-skeleton'),
          children: [
            for (var i = 0; i < 8; i++)
              const Padding(
                padding: EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, DsSpace.x3),
                child: Row(
                  children: [
                    DsSkelCircle(size: 52),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DsSkel(width: 140, height: 12),
                          SizedBox(height: 10),
                          DsSkel(width: 220, height: 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Swipe-action glyph painters
// ═════════════════════════════════════════════════════════════════════

/// Empty / error state for the chat list. Scrollable so pull-to-refresh
/// still works on it.
class _ChatListMessage extends StatelessWidget {
  final String title;
  final String body;

  const _ChatListMessage({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    // Scrollable so pull-to-refresh still works on an empty list.
    return ListView(
      key: const ValueKey('chat-list-message'),
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      padding: const EdgeInsets.only(top: DsSpace.x24, bottom: DsSpace.x8),
      children: [DsEmptyState(illustration: DsIllustration.chats, title: title, body: body)],
    );
  }
}
