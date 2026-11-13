// Voice and document bubble content for encrypted media — ADR-017
// stages 3-4. Same loading model as encrypted_photo.dart: metadata from
// the stored envelope JSON, bytes via MediaLoader (RAM cache).

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/services/media_loader.dart';
import '../../src/rust/api/simple.dart' as core;
import '../documents/document_share.dart';
import '../voice/voice_player.dart';
import '../voice/waveform.dart';
import '../../l10n/l10n.dart';

/// "512 B", "14 KB", "2.4 MB".
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).round()} KB';
  final mb = n / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}

/// "PDF", "DOCX", … — from the file name, else from the MIME subtype.
String fileBadge(String fileName, String mimeType) {
  final dot = fileName.lastIndexOf('.');
  if (dot > 0 && dot < fileName.length - 1) {
    final ext = fileName.substring(dot + 1);
    if (ext.length <= 5) return ext.toUpperCase();
  }
  final slash = mimeType.indexOf('/');
  if (slash >= 0) {
    final sub = mimeType.substring(slash + 1).split(RegExp(r'[.+;-]')).first;
    if (sub.isNotEmpty && sub.length <= 5) return sub.toUpperCase();
  }
  return 'FILE';
}

/// The icon and colour of a file's tile in shared media, by its type.
(IconData, Color) fileLook(String fileName, String mimeType) {
  final t = '${fileBadge(fileName, mimeType)} $mimeType'.toLowerCase();
  bool any(List<String> words) => words.any(t.contains);
  if (any(['pdf'])) return (CupertinoIcons.doc_text_fill, DsPalette.red);
  if (any(['xls', 'csv', 'numbers', 'sheet'])) return (CupertinoIcons.table_fill, DsPalette.green);
  if (any(['zip', 'rar', '7z', 'tar', 'gz'])) return (CupertinoIcons.archivebox_fill, DsPalette.orange);
  if (any(['audio', 'mp3', 'm4a', 'wav', 'ogg'])) return (CupertinoIcons.music_note, DsPalette.pink);
  if (any(['video', 'mp4', 'mov'])) return (CupertinoIcons.film_fill, DsPalette.indigo);
  if (any(['image', 'jpg', 'jpeg', 'png', 'heic'])) return (CupertinoIcons.photo_fill, DsPalette.indigo);
  if (any(['doc', 'txt', 'rtf', 'pages', 'text'])) return (CupertinoIcons.doc_text_fill, DsPalette.blue);
  return (CupertinoIcons.doc_fill, DsPalette.blue);
}

mixin _MediaInfoLoader<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  core.MediaInfo? info;
  bool infoFailed = false;

  String get mediaJsonForInfo;

  @override
  void initState() {
    super.initState();
    ref
        .read(mediaLoaderProvider)
        .info(mediaJsonForInfo)
        .then(
          (i) {
            if (mounted) setState(() => info = i);
          },
          onError: (Object _) {
            if (mounted) setState(() => infoFailed = true);
          },
        );
  }
}

// ── Voice ─────────────────────────────────────────────────────────────

class EncryptedVoice extends ConsumerStatefulWidget {
  const EncryptedVoice({
    super.key,
    required this.mediaJson,
    required this.color,
    this.glyph,
    this.following = const [],
    this.title,
  });

  final String mediaJson;
  final Color color;

  /// Shared media's "who · when" line: set, it sits above a slimmer
  /// waveform, the play button beside both (Telegram).
  final Widget? title;

  /// Set: a solid [color] play button with the ▶ in this colour (Telegram);
  /// null: the old tinted circle.
  final Color? glyph;

  /// Voice messages right after this one — they autoplay in order.
  final List<String> following;

  @override
  ConsumerState<EncryptedVoice> createState() => _EncryptedVoiceState();
}

class _EncryptedVoiceState extends ConsumerState<EncryptedVoice> with _MediaInfoLoader<EncryptedVoice> {
  bool _failed = false;

  @override
  String get mediaJsonForInfo => widget.mediaJson;

  /// 0..1 while a finger is on the waveform (and until the seek lands).
  double? _scrub;

  /// Status 223: a fetch that fails once (not connected yet, the network
  /// switched mid-download) is tried again after a second before the bubble
  /// says "unavailable".
  Future<Uint8List> _fetch(MediaLoader loader) async {
    try {
      return await loader.fetch(widget.mediaJson, thumbnail: false);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][voice] fetch failed, retrying: $e');
      await Future<void>.delayed(const Duration(seconds: 1));
      return loader.fetch(widget.mediaJson, thumbnail: false);
    }
  }

  /// The voice messages after this one, for the autoplay queue.
  List<VoiceTrack> _following(MediaLoader loader) => [
    for (final j in widget.following) (j, () => loader.fetch(j, thumbnail: false)),
  ];

  Future<void> _toggle() async {
    setState(() => _failed = false);
    try {
      final loader = ref.read(mediaLoaderProvider);
      await ref
          .read(voicePlayerProvider.notifier)
          .toggle(widget.mediaJson, () => _fetch(loader), next: _following(loader));
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][voice] play failed: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// A tap on the waveform, or the end of a drag: play from there.
  Future<void> _seek(double f) async {
    setState(() {
      _failed = false;
      _scrub = f;
    });
    try {
      final loader = ref.read(mediaLoaderProvider);
      await ref
          .read(voicePlayerProvider.notifier)
          .seek(
            widget.mediaJson,
            f,
            () => _fetch(loader),
            next: _following(loader),
          );
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][voice] play failed: $e');
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _scrub = null);
    }
  }

  static String _a11yAt(double f, int totalMs) =>
      '${formatVoiceDuration((totalMs * f.clamp(0.0, 1.0)).round())} / ${formatVoiceDuration(totalMs)}';

  static double _at(Offset local) => (local.dx / _waveWidth).clamp(0.0, 1.0);
  static const double _waveWidth = 150;

  @override
  Widget build(BuildContext context) {
    final playback = ref.watch(voicePlayerProvider);
    final mine = playback.key == widget.mediaJson;
    final playing = mine && playback.playing;
    final loading = mine && playback.loading;
    final totalMs = mine && playback.duration > Duration.zero ? playback.duration.inMilliseconds : (info?.durationMs ?? 0);
    final scrub = _scrub;
    final progress = scrub ?? (mine ? playback.progress : 0.0);
    final posMs = scrub != null
        ? (totalMs * scrub).round()
        : mine && playback.position > Duration.zero
        ? playback.position.inMilliseconds
        : totalMs;
    final label = _failed || infoFailed ? context.l10n.unavailable : formatVoiceDuration(posMs);
    final canSeek = !infoFailed && totalMs > 0;
    final title = widget.title;
    final button = GestureDetector(
      key: const ValueKey('voice-play'),
      behavior: HitTestBehavior.opaque,
      onTap: infoFailed ? null : _toggle,
      child: SizedBox(
        width: 38,
        height: 38,
        child: CustomPaint(
          painter: _PlayButtonPainter(color: widget.color, glyph: widget.glyph, playing: playing, loading: loading),
        ),
      ),
    );
    final wave = [
      // Tap a point or drag along the bars to rewind (Telegram). The
      // drag wins over swipe-to-reply because it sits deeper.
      Semantics(
        slider: true,
        label: context.l10n.a11yVoiceSeek,
        value: _a11yAt(progress, totalMs),
        increasedValue: _a11yAt(progress + 0.1, totalMs),
        decreasedValue: _a11yAt(progress - 0.1, totalMs),
        onIncrease: canSeek ? () => _seek((progress + 0.1).clamp(0.0, 1.0)) : null,
        onDecrease: canSeek ? () => _seek((progress - 0.1).clamp(0.0, 1.0)) : null,
        child: GestureDetector(
          key: const ValueKey('voice-waveform'),
          behavior: HitTestBehavior.opaque,
          onTapUp: canSeek ? (d) => _seek(_at(d.localPosition)) : null,
          onHorizontalDragStart: canSeek ? (d) => setState(() => _scrub = _at(d.localPosition)) : null,
          onHorizontalDragUpdate: canSeek ? (d) => setState(() => _scrub = _at(d.localPosition)) : null,
          onHorizontalDragEnd: canSeek
              ? (_) {
                  final f = _scrub;
                  if (f != null) _seek(f);
                }
              : null,
          onHorizontalDragCancel: canSeek ? () => setState(() => _scrub = null) : null,
          child: SizedBox(
            width: _waveWidth,
            height: title == null ? 38 : 24,
            child: Center(
              child: SizedBox(
                width: _waveWidth,
                height: title == null ? 28 : 16,
                child: CustomPaint(
                  painter: WaveformPainter(
                    levels: info?.waveform ?? Uint8List(0),
                    progress: progress,
                    color: widget.color,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text(label, style: DsText.footnote.copyWith(color: widget.color.withValues(alpha: 0.75))),
      // Speed chip while this message is the active one.
      if (mine) ...[
        const SizedBox(width: 6),
        GestureDetector(
          key: const ValueKey('voice-speed'),
          behavior: HitTestBehavior.opaque,
          onTap: () => ref.read(voicePlayerProvider.notifier).cycleSpeed(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5, vertical: DsSpace.x0h5),
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${playback.speed == playback.speed.roundToDouble() ? playback.speed.toInt() : playback.speed}×',
              style: DsText.caption.copyWith(fontWeight: FontWeight.w700, color: widget.color),
            ),
          ),
        ),
      ],
    ];
    if (title == null) {
      return Row(mainAxisSize: MainAxisSize.min, children: [button, const SizedBox(width: 8), ...wave]);
    }
    return Row(
      children: [
        button,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [title, const SizedBox(height: 2), Row(children: wave)],
          ),
        ),
      ],
    );
  }
}

/// Bars for a voice waveform; the played part is drawn at full opacity.
class WaveformPainter extends CustomPainter {
  WaveformPainter({required this.levels, required this.progress, required this.color});

  final Uint8List levels;
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const bars = 32;
    final gap = 2.0;
    final w = (size.width - gap * (bars - 1)) / bars;
    void drawBars(Color c) {
      final paint = Paint()..color = c;
      for (var i = 0; i < bars; i++) {
        final level = levels.isEmpty ? 0 : levels[(i * levels.length / bars).floor().clamp(0, levels.length - 1)];
        final h = math.max(3.0, size.height * level / 255);
        final x = i * (w + gap);
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), Radius.circular(w / 2)),
          paint,
        );
      }
    }

    final p = progress.clamp(0.0, 1.0);
    if (p >= 1) return drawBars(color);
    drawBars(color.withValues(alpha: 0.4));
    if (p <= 0) return;
    // The played part at full opacity, cut exactly at the position — it
    // glides through a bar instead of jumping a bar at a time.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * p, size.height));
    drawBars(color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(WaveformPainter old) => old.progress != progress || old.levels != levels || old.color != color;
}

class _PlayButtonPainter extends CustomPainter {
  _PlayButtonPainter({required this.color, this.glyph, required this.playing, required this.loading});
  final Color color;
  final Color? glyph;
  final bool playing;
  final bool loading;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final solid = glyph;
    canvas.drawCircle(c, r, Paint()..color = solid == null ? color.withValues(alpha: 0.18) : color);
    final p = Paint()..color = solid ?? color;
    if (loading) {
      canvas.drawCircle(c, r * 0.18, p);
    } else if (playing) {
      final w = r * 0.22;
      canvas.drawRect(Rect.fromCenter(center: c.translate(-w, 0), width: w, height: r * 0.8), p);
      canvas.drawRect(Rect.fromCenter(center: c.translate(w, 0), width: w, height: r * 0.8), p);
    } else {
      final path = Path()
        ..moveTo(c.dx - r * 0.25, c.dy - r * 0.4)
        ..lineTo(c.dx + r * 0.45, c.dy)
        ..lineTo(c.dx - r * 0.25, c.dy + r * 0.4)
        ..close();
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_PlayButtonPainter old) =>
      old.playing != playing || old.loading != loading || old.color != color || old.glyph != glyph;
}

// ── Document ──────────────────────────────────────────────────────────

class EncryptedDocument extends ConsumerStatefulWidget {
  const EncryptedDocument({
    super.key,
    required this.mediaJson,
    required this.color,
    this.share = shareDecryptedFile,
    this.date,
  });

  final String mediaJson;
  final Color color;

  /// Shared media's file row: "2.4 MB · 3 November", a coloured tile with
  /// the file type's icon, the whole width.
  final String? date;

  /// Injectable for tests (the real one opens the iOS share sheet).
  final Future<void> Function(Uint8List bytes, {required String fileName, required String mimeType, Rect? origin})
  share;

  @override
  ConsumerState<EncryptedDocument> createState() => _EncryptedDocumentState();
}

class _EncryptedDocumentState extends ConsumerState<EncryptedDocument> with _MediaInfoLoader<EncryptedDocument> {
  bool _opening = false;
  bool _failed = false;

  @override
  String get mediaJsonForInfo => widget.mediaJson;

  Future<void> _open() async {
    final i = info;
    if (i == null || _opening) return;
    setState(() {
      _opening = true;
      _failed = false;
    });
    // The share sheet points at this file on iPad.
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
    try {
      final bytes = await ref.read(mediaLoaderProvider).fetch(widget.mediaJson, thumbnail: false);
      await widget.share(bytes, fileName: i.fileName.isEmpty ? 'file' : i.fileName, mimeType: i.mimeType, origin: origin);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = info;
    final name = i == null
        ? (infoFailed ? context.l10n.documentUnavailable : '…')
        : (i.fileName.isEmpty ? context.l10n.file : i.fileName);
    final sub = i == null
        ? ''
        : _failed
        ? context.l10n.couldNotOpen
        : _opening
        ? context.l10n.decrypting
        : '${formatBytes(i.sizeBytes.toInt())} · ${widget.date ?? fileBadge(i.fileName, i.mimeType)}';
    final (icon, tint) = i == null ? (CupertinoIcons.doc_fill, DsPalette.blue) : fileLook(i.fileName, i.mimeType);
    return GestureDetector(
      key: const ValueKey('document-open'),
      behavior: HitTestBehavior.opaque,
      onTap: _open,
      child: SizedBox(
        width: widget.date == null ? 230 : null,
        child: Row(
          children: [
            if (widget.date != null)
              Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: tint, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, key: const ValueKey('document-type-icon'), size: 22, color: DsPalette.white),
              )
            else
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  i == null ? '' : fileBadge(i.fileName, i.mimeType),
                  style: DsText.micro.copyWith(fontWeight: FontWeight.w700, color: widget.color),
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: widget.color),
                  ),
                  if (sub.isNotEmpty)
                    Text(sub, style: DsText.footnote.copyWith(color: widget.color.withValues(alpha: 0.7))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
