// Media viewer — a profile photo full screen (openAvatarFullScreen).
// Pinch-to-zoom + pan (InteractiveViewer), floating chrome (top bar with
// the name, bottom bar with Share / Save). Tap the photo to hide/show
// chrome — the iOS Photos.app pattern. (Chat photos open in
// PhotoGalleryScreen.)

import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_icon.dart';
import '../../l10n/l10n.dart';
import 'viewer_glyphs.dart';

class MediaViewerScreen extends StatefulWidget {
  final String senderName;
  final String date; // already-formatted, e.g. "Apr 28 · 14:22"
  final VoidCallback? onClose;

  /// The picture (in memory).
  final Widget image;

  /// Status 213 — the real actions (they only flashed "Saved" / "Shared"
  /// before). True = done; null hides the button.
  final Future<bool> Function()? share;
  final Future<bool> Function()? save;

  const MediaViewerScreen({
    super.key,
    required this.senderName,
    required this.date,
    this.onClose,
    required this.image,
    this.share,
    this.save,
  });

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> with SingleTickerProviderStateMixin {
  bool _chromeVisible = true;
  late final AnimationController _chromeCtrl;
  late final TransformationController _viewer;
  String? _savedNotice; // brief "Saved" / "Couldn't save" notice
  bool _noticeOk = true;

  @override
  void initState() {
    super.initState();
    _chromeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: 1.0);
    _viewer = TransformationController();
  }

  @override
  void dispose() {
    _chromeCtrl.dispose();
    _viewer.dispose();
    super.dispose();
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    if (_chromeVisible) {
      _chromeCtrl.forward();
    } else {
      _chromeCtrl.reverse();
    }
  }

  void _flashNotice(String label, {bool ok = true}) {
    setState(() {
      _savedNotice = label;
      _noticeOk = ok;
    });
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _savedNotice = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return ColoredBox(
      color: DsPalette.black,
      child: Stack(
        children: [
          // Image area — pinch-to-zoom, pan, double-tap-to-reset
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleChrome,
              onDoubleTap: () => _viewer.value = Matrix4.identity(),
              child: InteractiveViewer(
                transformationController: _viewer,
                minScale: 1.0,
                maxScale: 4.0,
                child: Center(child: widget.image),
              ),
            ),
          ),
          // Top chrome bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _chromeCtrl,
              child: _TopBar(
                senderName: widget.senderName,
                date: widget.date,
                topInset: mq.padding.top,
                onClose: widget.onClose,
              ),
            ),
          ),
          // Bottom chrome bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _chromeCtrl,
              child: _BottomBar(
                bottomInset: mq.padding.bottom,
                onShare: widget.share == null
                    ? null
                    : () async {
                        final l = context.l10n;
                        if (!await widget.share!() && mounted) _flashNotice(l.couldNotShare, ok: false);
                      },
                onSave: widget.save == null
                    ? null
                    : () async {
                        final l = context.l10n;
                        final ok = await widget.save!();
                        if (mounted) _flashNotice(ok ? l.savedToPhotos : l.couldNotSave, ok: ok);
                      },
              ),
            ),
          ),
          // Toast notice (above bottom bar)
          if (_savedNotice != null)
            Positioned(
              bottom: mq.padding.bottom + 110,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2, DsSpace.x3h5, DsSpace.x2),
                  decoration: BoxDecoration(
                    color: _noticeOk ? DsPalette.green80 : DsPalette.black40,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_noticeOk) ...[
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CustomPaint(painter: DsGlyphPainter(DsGlyph.check, color: DsPalette.white)),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Text(_savedNotice!, style: DsTextArt.t13w600v6),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Top chrome bar
// ═════════════════════════════════════════════════════════════════════

class _TopBar extends StatelessWidget {
  final String senderName;
  final String date;
  final double topInset;
  final VoidCallback? onClose;

  const _TopBar({required this.senderName, required this.date, required this.topInset, this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [DsPalette.art000000aB3, DsPalette.transparent],
        ),
      ),
      padding: EdgeInsets.only(top: topInset, left: DsSpace.x1, right: DsSpace.x1, bottom: DsSpace.x3),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onClose?.call(),
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CustomPaint(painter: DsGlyphPainter(DsGlyph.close, color: DsPalette.white)),
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(senderName, style: DsTextArt.t15p5w600),
                Text(date, style: DsTextArt.t12p5w500),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Bottom chrome bar
// ═════════════════════════════════════════════════════════════════════

class _BottomBar extends StatelessWidget {
  final double bottomInset;
  final VoidCallback? onShare;
  final VoidCallback? onSave;

  const _BottomBar({required this.bottomInset, this.onShare, this.onSave});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [DsPalette.art000000aCC, DsPalette.transparent],
        ),
      ),
      padding: EdgeInsets.only(
        left: DsSpace.x6,
        right: DsSpace.x6,
        top: DsSpace.x5h5,
        bottom: bottomInset + DsSpace.x3h5,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (onShare != null) _ActionButton(label: context.l10n.share, glyph: ViewerGlyph.share, onTap: onShare),
          if (onSave != null) _ActionButton(label: context.l10n.saveToPhotos, glyph: ViewerGlyph.save, onTap: onSave),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final ViewerGlyph glyph;
  final VoidCallback? onTap;
  const _ActionButton({required this.label, required this.glyph, this.onTap});

  @override
  Widget build(BuildContext context) {
    const color = DsPalette.white;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onTap?.call(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ViewerGlyphIcon(glyph, color: color),
          const SizedBox(height: 6),
          Text(label, style: DsText.caption.copyWith(height: 1.0, color: color)),
        ],
      ),
    );
  }
}
