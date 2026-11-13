// The app's toast: one compact pill under the status bar for
// [appNotice] (errors / notes) and [showDone] (confirmations). Dark glass
// with a coloured badge, slides in, hides itself; a tap hides it sooner.
// Replaces the full-width blue banner that stayed until tapped.

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import '../core/app_notice.dart';
import '../core/haptics.dart';
import 'ds_icon.dart';

enum NoticeTone { done, info, error }

/// Errors are worded "… failed" / "Couldn't …" / "Не удалось …" across the
/// app; everything else set on [appNotice] is a note.
@visibleForTesting
NoticeTone toneOf(String msg) {
  final m = msg.toLowerCase();
  const markers = ['error', 'failed', 'couldn', 'can’t', "can't", 'не удалось', 'ошибка', 'нет соединения'];
  return markers.any(m.contains) ? NoticeTone.error : NoticeTone.info;
}

/// How long each kind stays: confirmations are glanced at, errors read.
Duration noticeDuration(NoticeTone t) => switch (t) {
  NoticeTone.done => const Duration(milliseconds: 1800),
  NoticeTone.info => const Duration(seconds: 4),
  NoticeTone.error => const Duration(seconds: 6),
};

class AppNoticeHost extends StatefulWidget {
  const AppNoticeHost({super.key});

  @override
  State<AppNoticeHost> createState() => _AppNoticeHostState();
}

class _AppNoticeHostState extends State<AppNoticeHost> {
  String _text = '';
  NoticeTone _tone = NoticeTone.info;
  bool _visible = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    appNotice.addListener(_onNotice);
    appDone.addListener(_onDone);
    if (appNotice.value.isNotEmpty) _onNotice();
  }

  @override
  void dispose() {
    _hide?.cancel();
    appNotice.removeListener(_onNotice);
    appDone.removeListener(_onDone);
    super.dispose();
  }

  void _onNotice() {
    final msg = appNotice.value;
    if (msg.isEmpty) {
      if (_tone != NoticeTone.done) _dismiss();
      return;
    }
    _show(msg, toneOf(msg));
  }

  void _onDone() {
    final text = appDone.value.text;
    if (text.isEmpty) return;
    DsHaptics.play(Haptic.success);
    _show(text, NoticeTone.done);
  }

  void _show(String text, NoticeTone tone) {
    _hide?.cancel();
    setState(() {
      _text = text;
      _tone = tone;
      _visible = true;
    });
    _hide = Timer(noticeDuration(tone), _dismiss);
  }

  void _dismiss() {
    _hide?.cancel();
    if (!mounted) return;
    if (_visible) setState(() => _visible = false);
    // Screens compare appNotice to clear their own note — keep it in step.
    if (_tone != NoticeTone.done && appNotice.value == _text) appNotice.value = '';
  }

  @override
  Widget build(BuildContext context) {
    if (_text.isEmpty) return const SizedBox.shrink();
    final tokens = DsTheme.of(context);
    final badge = switch (_tone) {
      NoticeTone.done => DsPalette.green,
      NoticeTone.error => tokens.danger,
      NoticeTone.info => tokens.accent,
    };
    return IgnorePointer(
      ignoring: !_visible,
      child: AnimatedSlide(
        offset: _visible ? Offset.zero : const Offset(0, -0.6),
        duration: DsMotion.base,
        curve: _visible ? DsMotion.emphasized : DsMotion.exit,
        child: AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: DsMotion.base,
          curve: _visible ? DsMotion.enter : DsMotion.exit,
          onEnd: () {
            if (!_visible && mounted) setState(() => _text = '');
          },
          child: Padding(
            padding: const EdgeInsets.only(top: DsSpace.x2),
            child: Center(
              child: Semantics(
                liveRegion: true,
                button: true,
                label: _text,
                child: GestureDetector(
                  key: const ValueKey('app-notice'),
                  onTap: _dismiss,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        borderRadius: BorderRadius.all(Radius.circular(999)),
                        boxShadow: DsShadow.menu,
                      ),
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(Radius.circular(999)),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: DsPalette.toastGlass,
                              borderRadius: const BorderRadius.all(Radius.circular(999)),
                              border: Border.all(color: DsPalette.white10, width: 0.5),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x2, DsSpace.x4, DsSpace.x2),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _Badge(tone: _tone, color: badge),
                                  const SizedBox(width: DsSpace.x2h5),
                                  Flexible(
                                    child: Text(
                                      _text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: DsText.toast,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 22 pt round badge: ✓ for done, × for errors, a dot for notes.
class _Badge extends StatelessWidget {
  const _Badge({required this.tone, required this.color});
  final NoticeTone tone;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: switch (tone) {
        NoticeTone.done => CustomPaint(
          size: const Size.square(14),
          painter: DsGlyphPainter(DsGlyph.check, color: DsPalette.white, strokeWidth: 2.6),
        ),
        NoticeTone.error => CustomPaint(
          size: const Size.square(12),
          painter: DsGlyphPainter(DsGlyph.close, color: DsPalette.white, strokeWidth: 2.6),
        ),
        NoticeTone.info => Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(color: DsPalette.white, shape: BoxShape.circle),
        ),
      },
    );
  }
}
