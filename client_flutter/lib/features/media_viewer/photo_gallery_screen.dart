// Chat gallery — every photo and video of the chat, like Telegram /
// iOS Photos (UI backlog §3 item 27; owner, 2026-10-18: "smoother, more
// functional, more polished").
//
//   • Hero flight from the bubble: the thumbnail grows from its cropped,
//     rounded box into the fitted full-screen picture, and back on close
//     (gallery_pages.dart) — no "Decrypting…" flash, the thumbnail is
//     already in RAM.
//   • swipe sideways through every photo and video, "3 of 27", sender and
//     date on top, a strip of thumbnails at the bottom (tap to jump)
//   • pinch zoom with rubber bands, pan with inertia while zoomed, double
//     tap zooms into the tapped point (ZoomableView)
//   • drag down (not zoomed) → the picture follows the finger, the black
//     fades; far / fast enough closes (flying back into its bubble), else
//     springs back
//   • video: real player — play / pause, scrubber with time, sound, short
//     clips loop, keeps playing while the chrome hides (gallery_video.dart);
//     the app rotates, so does the viewer
//   • share (anchored on iPad), save to Photos, forward, show in chat,
//     delete; one tap hides / shows the chrome
//   • a round video message (ADR-048) is a circle in the page, the strip
//     and the flight, and has no share / save: its file may hold more than
//     the circle the sender saw (an old uncropped clip) — owner, 2026-10-19
//
// Decrypted bytes stay in RAM (MediaLoader → MediaCache); the neighbours
// are decrypted ahead so swiping never waits. Plaintext touches disk only
// for the moment the user explicitly shares or saves (document_share.dart).

import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_cache.dart';
import '../../core/services/media_loader.dart';
import '../../l10n/l10n.dart';
import '../chat_view/encrypted_photo.dart';
import '../documents/document_share.dart';
import '../video_note/video_note_circle.dart';
import 'gallery_item.dart';
import 'gallery_pages.dart';
import 'gallery_video.dart';
import 'viewer_glyphs.dart';

export 'gallery_item.dart';

/// What the gallery can do besides share / save. Null → no button.
class GalleryActions {
  const GalleryActions({this.forward, this.showInChat, this.delete, this.share, this.save});

  /// Pick a chat and send it there. True = sent ("Forwarded"), null =
  /// picked nothing.
  final Future<bool?> Function(GalleryItem item)? forward;

  /// Called after the gallery has closed.
  final void Function(GalleryItem item)? showInChat;

  /// Ask and delete. True = gone (the gallery drops it).
  final Future<bool> Function(GalleryItem item)? delete;

  /// Defaults: [shareGalleryItem] / [saveGalleryItem]. Injectable for tests.
  final Future<bool> Function(GalleryItem item, Rect origin)? share;
  final Future<bool> Function(GalleryItem item)? save;
}

/// Opens [items] at [index] with a fading, non-opaque route so the Hero
/// and the drag-to-dismiss show the chat behind. [allItems]: the full
/// list when it is still loading (e.g. older history) — merged in once the
/// opening flight has landed, keeping the picture on screen.
Future<void> openPhotoGallery(
  BuildContext context,
  List<GalleryItem> items,
  int index, {
  GalleryActions actions = const GalleryActions(),
  Future<List<GalleryItem>>? allItems,
}) async {
  // The thumbnail decoded before the first frame of the flight, so it
  // never starts from an empty box.
  final cache = ProviderScope.containerOf(context, listen: false).read(mediaCacheProvider);
  final thumb = peekMedia(cache, items[index].mediaJson, thumbnail: true);
  if (thumb != null) {
    try {
      await precacheImage(MemoryImage(thumb), context).timeout(const Duration(milliseconds: 150));
    } catch (_) {}
    if (!context.mounted) return;
  }
  await Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: DsMotion.of(context, DsMotion.slow),
      reverseTransitionDuration: DsMotion.of(context, DsMotion.base),
      pageBuilder: (_, _, _) =>
          PhotoGalleryScreen(items: items, initialIndex: index, actions: actions, allItems: allItems),
      transitionsBuilder: (_, anim, _, child) => FadeTransition(opacity: anim, child: child),
    ),
  );
}

/// Share through the system sheet; [origin] anchors the iPad popover.
Future<bool> shareGalleryItem(MediaLoader loader, GalleryItem item, Rect origin) async {
  if (item.round) return false; // never the raw file of a round video
  try {
    final bytes = await loader.fetch(item.mediaJson, thumbnail: false);
    if (item.isVideo) {
      final info = await loader.info(item.mediaJson);
      final mime = info.mimeType.isEmpty ? 'video/mp4' : info.mimeType;
      await shareDecryptedFile(bytes, fileName: _videoName(mime), mimeType: mime, origin: origin);
    } else {
      await shareDecryptedFile(bytes, fileName: 'photo.jpg', mimeType: 'image/jpeg', origin: origin);
    }
    return true;
  } catch (_) {
    return false;
  }
}

String _videoName(String mime) => mime.contains('quicktime') ? 'video.mov' : 'video.mp4';

/// "Save to Photos" — the user explicitly exports it into the system
/// library (outside Sinhron's protection from then on). A video goes
/// through a short-lived temp file (the Photos API takes a path), deleted
/// right after.
Future<bool> saveGalleryItem(MediaLoader loader, GalleryItem item) async {
  if (item.round) return false; // never the raw file of a round video
  if (!item.isVideo) return savePhotoToLibrary(loader, item.mediaJson);
  Directory? dir;
  try {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) return false;
    final bytes = await loader.fetch(item.mediaJson, thumbnail: false);
    final info = await loader.info(item.mediaJson);
    final tmp = await getTemporaryDirectory();
    dir = await Directory('${tmp.path}/save-${DateTime.now().microsecondsSinceEpoch}').create();
    final file = File('${dir.path}/${_videoName(info.mimeType)}');
    await file.writeAsBytes(bytes, flush: true);
    await Gal.putVideo(file.path);
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}

class PhotoGalleryScreen extends ConsumerStatefulWidget {
  const PhotoGalleryScreen({
    super.key,
    required this.items,
    this.initialIndex = 0,
    this.actions = const GalleryActions(),
    this.allItems,
  });

  final List<GalleryItem> items;
  final int initialIndex;
  final GalleryActions actions;
  final Future<List<GalleryItem>>? allItems;

  @override
  ConsumerState<PhotoGalleryScreen> createState() => _PhotoGalleryScreenState();
}

class _PhotoGalleryScreenState extends ConsumerState<PhotoGalleryScreen> with SingleTickerProviderStateMixin {
  late List<GalleryItem> _items = List.of(widget.items);
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final _strip = ScrollController();
  bool _zoomed = false;
  final _chrome = ValueNotifier<bool>(true);

  /// The current page's player (its controls sit in the bottom chrome).
  /// Not disposed here: a closing video page clears it after the frame.
  final GalleryVideoSlot _video = ValueNotifier(null);
  String? _notice;
  Timer? _noticeTimer;
  Timer? _hideTimer;
  bool _closing = false;
  final _focus = FocusNode();

  /// Vertical drag-to-dismiss offset.
  late final AnimationController _drag = AnimationController.unbounded(vsync: this);

  static const _dismissDistance = 120.0;
  static const _dismissVelocity = 900.0;
  static const _stripCell = 40.0;

  GalleryItem get _item => _items[_index];

  @override
  void initState() {
    super.initState();
    _prefetchAround(_index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centerStrip(animate: false);
    });
    final all = widget.allItems;
    if (all != null) {
      all.then((list) async {
        // Not while the opening flight is in the air or a finger is down.
        final route = _routeAnimation;
        if (route != null && !route.isCompleted) {
          final landed = Completer<void>();
          void check(AnimationStatus s) {
            if (s.isCompleted && !landed.isCompleted) landed.complete();
          }

          route.addStatusListener(check);
          try {
            await landed.future.timeout(const Duration(seconds: 2));
          } on TimeoutException catch (_) {
            // Never landed (reduced motion, interrupted): merge anyway.
          }
          route.removeStatusListener(check);
        }
        if (mounted) _merge(list);
      }, onError: (Object _) {});
    }
  }

  Animation<double>? _routeAnimation;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeAnimation = ModalRoute.of(context)?.animation;
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    _hideTimer?.cancel();
    _pages.dispose();
    _strip.dispose();
    _drag.dispose();
    _chrome.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Swap in the full list, the same picture staying on screen.
  void _merge(List<GalleryItem> list) {
    if (list.isEmpty || !_pages.hasClients) return;
    final pos = _pages.position;
    if (pos.isScrollingNotifier.value) {
      void retry() {
        if (pos.isScrollingNotifier.value) return;
        pos.isScrollingNotifier.removeListener(retry);
        if (mounted) _merge(list);
      }

      pos.isScrollingNotifier.addListener(retry);
      return;
    }
    final at = list.indexWhere((g) => g.heroTag == _item.heroTag);
    if (at < 0 || list.length == _items.length) return;
    setState(() {
      _items = List.of(list);
      _index = at;
      pos.correctPixels(at * pos.viewportDimension);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centerStrip(animate: false);
    });
  }

  // ── paging ──────────────────────────────────────────────────────────

  void _onPageChanged(int i) {
    if (i == _index) return;
    setState(() {
      _index = i;
      _zoomed = false;
    });
    _video.value = null;
    _centerStrip();
    _prefetchAround(i);
    HapticFeedback.selectionClick();
  }

  void _goTo(int i) {
    if (i < 0 || i >= _items.length || i == _index) return;
    _showChrome();
    if ((i - _index).abs() == 1 && !DsMotion.reduced(context)) {
      _pages.animateToPage(i, duration: DsMotion.base, curve: DsMotion.emphasized);
    } else {
      _pages.jumpToPage(i);
    }
  }

  void _centerStrip({bool animate = true}) {
    if (!_strip.hasClients) return;
    final p = _strip.position;
    final target = (_index * _stripCell + _stripCell / 2 - p.viewportDimension / 2).clamp(0.0, p.maxScrollExtent);
    if (animate && !DsMotion.reduced(context)) {
      _strip.animateTo(target, duration: DsMotion.base, curve: DsMotion.enter);
    } else {
      _strip.jumpTo(target);
    }
  }

  /// Decrypt the neighbours ahead: photos in full, videos' posters (and
  /// small videos whole), so a swipe shows them at once.
  void _prefetchAround(int i) {
    final loader = ref.read(mediaLoaderProvider);
    // The one on screen first: its decryption runs during the opening
    // flight (a Hero builds its page only once it lands).
    if (i == _index) quietly(loader.fetch(_items[i].mediaJson, thumbnail: false));
    for (final j in [i + 1, i - 1, i + 2]) {
      if (j < 0 || j >= _items.length) continue;
      final it = _items[j];
      if (!it.isVideo) {
        quietly(loader.fetch(it.mediaJson, thumbnail: false));
        continue;
      }
      quietly(
        loader.info(it.mediaJson).then((info) async {
          if (info.hasThumbnail) await loader.fetch(it.mediaJson, thumbnail: true);
          if ((j - i).abs() == 1 && info.sizeBytes < BigInt.from(16 * 1024 * 1024)) {
            await loader.fetch(it.mediaJson, thumbnail: false);
          }
        }),
      );
    }
  }

  // ── chrome ──────────────────────────────────────────────────────────

  void _toggleChrome() {
    _hideTimer?.cancel();
    _chrome.value = !_chrome.value;
    setState(() {});
  }

  void _showChrome() {
    _hideTimer?.cancel();
    if (!_chrome.value) {
      _chrome.value = true;
      setState(() {});
    }
  }

  /// A playing video takes the screen after a moment (Telegram).
  void _hideSoon() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      final v = _video.value;
      if (!mounted || v == null || !v.value.isPlaying || !_chrome.value) return;
      _chrome.value = false;
      setState(() {});
    });
  }

  void _flash(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  // ── dismiss ─────────────────────────────────────────────────────────

  void _onDragUpdate(DragUpdateDetails d) {
    if (_zoomed || _closing) return;
    _drag.value += d.delta.dy;
  }

  void _onDragEnd(DragEndDetails d) {
    if (_zoomed || _closing) return;
    final v = d.velocity.pixelsPerSecond.dy;
    if (_drag.value.abs() > _dismissDistance || v.abs() > _dismissVelocity) {
      _close();
      return;
    }
    if (DsMotion.reduced(context)) {
      _drag.value = 0;
    } else {
      _drag.animateWith(SpringSimulation(DsMotion.spring, _drag.value, 0, v));
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _video.value?.pause();
    Navigator.of(context).maybePop();
  }

  // ── actions ─────────────────────────────────────────────────────────

  Future<void> _share(BuildContext buttonContext) async {
    final l = context.l10n;
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = shareOrigin(box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size);
    final item = _item;
    if (item.round) return;
    final custom = widget.actions.share;
    final ok = custom != null ? await custom(item, origin) : await shareGalleryItem(ref.read(mediaLoaderProvider), item, origin);
    if (!ok && mounted) _flash(l.couldNotShare);
  }

  Future<void> _save() async {
    final l = context.l10n;
    final item = _item;
    if (item.round) return;
    final custom = widget.actions.save;
    final ok = custom != null ? await custom(item) : await saveGalleryItem(ref.read(mediaLoaderProvider), item);
    if (mounted) _flash(ok ? l.savedToPhotos : l.couldNotSave);
  }

  Future<void> _forward() async {
    final l = context.l10n;
    final f = widget.actions.forward;
    if (f == null) return;
    _video.value?.pause();
    final ok = await f(_item);
    if (ok != null && mounted) _flash(ok ? l.forwarded : l.couldNotForward);
  }

  void _showInChat() {
    final f = widget.actions.showInChat;
    if (f == null) return;
    final item = _item;
    _close();
    f(item);
  }

  Future<void> _delete() async {
    final f = widget.actions.delete;
    if (f == null) return;
    final item = _item;
    _video.value?.pause();
    if (!await f(item) || !mounted) return;
    final at = _items.indexWhere((g) => g.heroTag == item.heroTag);
    if (at < 0) return;
    if (_items.length == 1) {
      _close();
      return;
    }
    _video.value = null;
    setState(() {
      _items.removeAt(at);
      if (_index >= _items.length) {
        _index = _items.length - 1;
        if (_pages.hasClients) _pages.position.correctPixels(_index * _pages.position.viewportDimension);
      }
      _zoomed = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _centerStrip();
    });
    _prefetchAround(_index);
  }

  // ── build ───────────────────────────────────────────────────────────

  Widget _page(BuildContext context, int i) {
    final item = _items[i];
    Widget hero(Widget child) => Hero(
      tag: item.heroTag,
      createRectTween: galleryRectTween,
      flightShuttleBuilder: galleryHeroShuttle,
      child: GalleryHeroChild(item: item, child: child),
    );
    return KeyedSubtree(
      key: ValueKey(item.heroTag),
      child: item.isVideo
          ? GalleryVideoPage(
              item: item,
              active: i == _index,
              slot: _video,
              chromeVisible: _chrome,
              onPlaying: _hideSoon,
              hero: hero,
            )
          : _PhotoPage(
              item: item,
              hero: hero,
              onZoomChanged: (z) {
                if (i == _index && z != _zoomed) setState(() => _zoomed = z);
              },
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final item = _item;
    final chrome = _chrome.value;
    final a = widget.actions;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _goTo(_index - 1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _goTo(_index + 1),
          const SingleActivator(LogicalKeyboardKey.escape): _close,
          const SingleActivator(LogicalKeyboardKey.space): () {
            final v = _video.value;
            if (v != null) v.value.isPlaying ? v.pause() : v.play();
          },
        },
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: AnimatedBuilder(
            animation: _drag,
            builder: (context, _) {
              final fade = (1 - _drag.value.abs() / 400).clamp(0.0, 1.0);
              final chromeOpacity = chrome ? fade : 0.0;
              return Stack(
                children: [
                  Positioned.fill(child: ColoredBox(color: DsPalette.black.withValues(alpha: fade))),
                  Positioned.fill(
                    child: GestureDetector(
                      onVerticalDragUpdate: _zoomed ? null : _onDragUpdate,
                      onVerticalDragEnd: _zoomed ? null : _onDragEnd,
                      onTap: _toggleChrome,
                      child: Transform.translate(
                        offset: Offset(0, _drag.value),
                        child: Transform.scale(
                          scale: 1 - (_drag.value.abs() / 2000).clamp(0.0, 0.15),
                          child: PageView.builder(
                            key: const ValueKey('gallery-pages'),
                            controller: _pages,
                            physics: _zoomed ? const NeverScrollableScrollPhysics() : const BouncingScrollPhysics(),
                            itemCount: _items.length,
                            onPageChanged: _onPageChanged,
                            findChildIndexCallback: (key) {
                              final tag = (key as ValueKey<Object>).value;
                              final at = _items.indexWhere((g) => g.heroTag == tag);
                              return at < 0 ? null : at;
                            },
                            itemBuilder: _page,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Top: close, "3 of 27", sender · date.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !chrome,
                      child: AnimatedOpacity(
                        opacity: chromeOpacity,
                        duration: DsMotion.of(context, DsMotion.fast),
                        child: Container(
                          padding: EdgeInsets.fromLTRB(
                            DsSpace.x2 + pad.left,
                            pad.top + DsSpace.x1h5,
                            DsSpace.x4 + pad.right,
                            DsSpace.x2h5,
                          ),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [DsPalette.art000000aB3, DsPalette.transparent],
                            ),
                          ),
                          child: Row(
                            children: [
                              Semantics(
                                button: true,
                                label: context.l10n.viewerClose,
                                child: GestureDetector(
                                  key: const ValueKey('gallery-close'),
                                  behavior: HitTestBehavior.opaque,
                                  onTap: _close,
                                  child: const Padding(
                                    padding: EdgeInsets.all(DsSpace.x2h5),
                                    child: Icon(CupertinoIcons.xmark, size: 20, color: DsPalette.white),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  children: [
                                    Text(
                                      _items.length > 1
                                          ? context.l10n.nOfM(_index + 1, _items.length)
                                          : (item.sender.isEmpty ? item.date : item.sender),
                                      key: const ValueKey('gallery-counter'),
                                      style: DsTextArt.t15w600,
                                    ),
                                    if (_items.length > 1 && item.subtitle.isNotEmpty)
                                      Text(
                                        item.subtitle,
                                        key: const ValueKey('gallery-subtitle'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: DsTextArt.t12v2,
                                      )
                                    else if (_items.length == 1 && item.sender.isNotEmpty && item.date.isNotEmpty)
                                      Text(item.date, style: DsTextArt.t12v2),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 38),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Bottom: caption, video controls, strip, actions.
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      ignoring: !chrome,
                      child: AnimatedOpacity(
                        opacity: chromeOpacity,
                        duration: DsMotion.of(context, DsMotion.fast),
                        child: Container(
                          padding: EdgeInsets.fromLTRB(pad.left, DsSpace.x6, pad.right, pad.bottom + DsSpace.x1),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomCenter,
                              end: Alignment.topCenter,
                              colors: [DsPalette.art000000aCC, DsPalette.transparent],
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (item.caption.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(DsSpace.x4, 0, DsSpace.x4, DsSpace.x2),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      item.caption,
                                      key: const ValueKey('gallery-caption'),
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: DsTextArt.t14,
                                    ),
                                  ),
                                ),
                              ValueListenableBuilder(
                                valueListenable: _video,
                                builder: (context, v, _) => v == null || !item.isVideo
                                    ? const SizedBox.shrink()
                                    : Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2),
                                        child: GalleryVideoControls(controller: v, onInteract: _hideSoon),
                                      ),
                              ),
                              if (_items.length > 1)
                                SizedBox(
                                  key: const ValueKey('gallery-strip'),
                                  height: 52,
                                  child: ListView.builder(
                                    controller: _strip,
                                    scrollDirection: Axis.horizontal,
                                    itemExtent: _stripCell,
                                    padding: EdgeInsets.zero,
                                    itemCount: _items.length,
                                    itemBuilder: (context, i) => _StripCell(
                                      item: _items[i],
                                      current: i == _index,
                                      onTap: () => _goTo(i),
                                    ),
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                                  children: [
                                    if (!item.round)
                                      Builder(
                                        builder: (bc) => _Action(
                                          id: 'share',
                                          glyph: ViewerGlyph.share,
                                          label: context.l10n.share,
                                          onTap: () => _share(bc),
                                        ),
                                      ),
                                    if (!item.round)
                                      _Action(
                                        id: 'save',
                                        glyph: ViewerGlyph.save,
                                        label: context.l10n.saveToPhotos,
                                        onTap: _save,
                                      ),
                                    if (a.forward != null)
                                      _Action(
                                        id: 'forward',
                                        glyph: ViewerGlyph.forward,
                                        label: context.l10n.forward,
                                        onTap: _forward,
                                      ),
                                    if (a.showInChat != null && item.wireId != null)
                                      _Action(
                                        id: 'show-in-chat',
                                        glyph: ViewerGlyph.showInChat,
                                        label: context.l10n.showInChat,
                                        onTap: _showInChat,
                                      ),
                                    if (a.delete != null)
                                      _Action(
                                        id: 'delete',
                                        glyph: ViewerGlyph.trash,
                                        label: context.l10n.delete,
                                        danger: true,
                                        onTap: _delete,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_notice != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: pad.top + 72,
                      child: IgnorePointer(
                        child: Center(
                          child: Container(
                            key: const ValueKey('gallery-notice'),
                            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
                            decoration: BoxDecoration(
                              color: DsPalette.art222222aCC,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(_notice!, style: DsTextArt.t13v4),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A photo page: zoom around the Hero, bounds from the picture's shape.
class _PhotoPage extends StatefulWidget {
  const _PhotoPage({required this.item, required this.hero, required this.onZoomChanged});
  final GalleryItem item;
  final Widget Function(Widget child) hero;
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> {
  double? _aspect;

  @override
  Widget build(BuildContext context) {
    return ZoomableView(
      contentAspect: _aspect,
      onZoomChanged: widget.onZoomChanged,
      child: widget.hero(
        GalleryImage(
          mediaJson: widget.item.mediaJson,
          onAspect: (a) {
            if (a != _aspect) setState(() => _aspect = a);
          },
        ),
      ),
    );
  }
}

class _StripCell extends StatelessWidget {
  const _StripCell({required this.item, required this.current, required this.onTap});
  final GalleryItem item;
  final bool current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: ValueKey('gallery-strip-${item.heroTag}'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: AnimatedContainer(
          duration: DsMotion.of(context, DsMotion.fast),
          curve: DsMotion.enter,
          width: current ? 38 : 32,
          height: current ? 44 : 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: current ? DsPalette.white : DsPalette.transparent, width: 1.5),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: AnimatedOpacity(
              opacity: current ? 1 : 0.6,
              duration: DsMotion.of(context, DsMotion.fast),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    child: item.round
                        ? VideoNoteCircle(child: EncryptedThumbnail(mediaJson: item.mediaJson))
                        : EncryptedThumbnail(mediaJson: item.mediaJson),
                  ),
                  if (item.isVideo)
                    const Align(
                      alignment: Alignment.bottomLeft,
                      child: Padding(
                        padding: EdgeInsets.all(DsSpace.x0h5),
                        child: ViewerGlyphIcon(ViewerGlyph.play, color: DsPalette.white, size: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.id, required this.glyph, required this.label, required this.onTap, this.danger = false});
  final String id;
  final ViewerGlyph glyph;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: GestureDetector(
      key: ValueKey('gallery-$id'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 52,
        height: 48,
        child: Center(
          child: ViewerGlyphIcon(glyph, color: danger ? DsPalette.artFF6B6B : DsPalette.white, size: 24),
        ),
      ),
    ),
  );
}
