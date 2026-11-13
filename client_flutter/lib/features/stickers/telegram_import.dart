// A whole Telegram sticker pack by its link — ADR-062 (owner, 2026-10-18:
// "download a sticker pack in full by a link from Telegram").
//
// https://t.me/addstickers/<name> (pasted in the sticker panel's +, tapped
// in a chat, or opened with Sinhron) → our server fetches the pack with
// the operator's bot token (Telegram never sees this phone) → a preview:
// title, count, the first stickers → "Add N stickers" → every file comes
// down in batches with progress → an ordinary own pack, encrypted here like
// any other (ADR-049). Animated .tgs and video .webm stay animated; a video
// sticker's still is Telegram's small picture of it (iPhone can't play WebM).
//
// The person adds a pack they chose; nothing here lists or crawls
// Telegram's catalogue.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/stickers.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_spinner.dart';
import 'sticker_codec.dart';
import 'sticker_import.dart';
import 'sticker_store.dart';
import 'sticker_view.dart';

final _link = RegExp(
  r'(?:(?:https?://)?(?:www\.)?(?:t\.me|telegram\.me|telegram\.dog)/(?:addstickers|addemoji)/|tg://(?:addstickers|addemoji)\?set=)([A-Za-z0-9_]{1,64})(?![A-Za-z0-9_])',
  caseSensitive: false,
);

/// The pack name in a Telegram sticker link (t.me/addstickers/…,
/// t.me/addemoji/…, tg://addstickers?set=…) anywhere in [text], or null.
String? telegramPackName(String text) => _link.firstMatch(text)?.group(1);

/// The id an imported Telegram pack keeps here: `tg.` + its name in lower
/// case, so adding the same pack again replaces it.
String telegramPackId(String name) {
  final id = 'tg.${name.toLowerCase()}';
  return id.length > 64 ? id.substring(0, 64) : id;
}

/// Where a Telegram pack came from, shown in its sheet.
String telegramPackSource(String name) => 't.me/addstickers/$name';

/// Plain words for a failed Telegram request ("tg:<code>" from the core).
String telegramPackError(AppL10n l, Object e) {
  final s = e.toString();
  if (s.contains('tg:not_found')) return l.tgPackNotFound;
  if (s.contains('tg:not_configured')) return l.tgPackNotConfigured;
  if (s.contains('tg:server_old')) return l.tgPackServerOld;
  if (s.contains('tg:unreachable')) return l.tgPackUnreachable;
  if (s.contains('tg:rate_limited')) return l.tgPackRateLimited;
  return l.tgPackFailed;
}

/// Files fetched at once (one round of the progress).
const kTelegramBatch = 8;

/// Stickers shown before adding.
const kTelegramPreviewCount = 10;

class TelegramImportCancelled implements Exception {
  const TelegramImportCancelled();
}

/// Stickers [indices] of [info] (all when null) with previews, fetched in
/// batches; [have] are ones already fetched (the preview), kept as they
/// are. [preview] makes the still PNG (swapped in tests).
Future<ImportResult> stickersFromTelegram(
  StickerStore store,
  core.TelegramPackInfo info, {
  List<int>? indices,
  Map<int, core.StickerData> have = const {},
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
  Future<Uint8List> Function(Uint8List data, String format, String emoji)? preview,
}) async {
  final make = preview ?? (d, f, e) => stickerStillPng(d, f, emoji: e, px: 128);
  final want = indices ?? [for (var i = 0; i < info.stickers.length && i < kMaxPackStickers; i++) i];
  final got = <int, core.StickerData>{for (final i in want) if (have[i] != null) i: have[i]!};
  var skipped = 0;
  final todo = [for (final i in want) if (!got.containsKey(i)) i];
  onProgress?.call(got.length, want.length);
  for (var at = 0; at < todo.length; at += kTelegramBatch) {
    if (cancelled?.call() ?? false) throw const TelegramImportCancelled();
    final batch = todo.sublist(at, (at + kTelegramBatch).clamp(0, todo.length));
    final files = await store.telegramFiles(
      info.name,
      batch,
      thumbFor: [for (final i in batch) if (info.stickers[i].format == 'webm' && info.stickers[i].thumb) i],
    );
    for (final f in files) {
      final data = f.data;
      final format = stickerFormatOfBytes(data);
      if (data.isEmpty || format == null || data.length > kMaxStickerBytes) {
        skipped++;
        continue;
      }
      final emoji = info.stickers[f.index].emoji;
      var still = Uint8List(0);
      try {
        still = format == 'webm'
            ? (f.thumb.isNotEmpty ? await make(f.thumb, 'webp', emoji) : await make(data, format, emoji))
            : await make(data, format, emoji);
        if (still.length > kMaxPreviewBytes) still = Uint8List(0);
      } catch (_) {
        // An animation the renderer can't open isn't usable; a still
        // picture without a preview still is.
        if (format == 'tgs') {
          skipped++;
          continue;
        }
      }
      got[f.index] = core.StickerData(id: 's${f.index + 1}', emoji: emoji, format: format, data: data, preview: still);
    }
    onProgress?.call(got.length + skipped, want.length);
  }
  return ImportResult([for (final i in want) if (got[i] != null) got[i]!], skipped);
}

/// The pack ready to save: title (the name when Telegram's is unusable),
/// source as its author.
core.StickerPack telegramPack(core.TelegramPackInfo info, List<core.StickerData> stickers) => core.StickerPack(
  info: core.StickerPackInfo(
    id: telegramPackId(info.name),
    title: info.title.trim().isEmpty ? info.name : info.title.trim(),
    author: telegramPackSource(info.name),
    license: '',
    count: stickers.length,
    animated: stickers.any((s) => stickerFormatAnimated(s.format)),
    cover: stickers.first.preview,
  ),
  stickers: stickers,
);

/// Reads a provider: a widget's `ref.read`, or a ProviderContainer's.
typedef ProviderRead = T Function<T>(ProviderListenable<T> provider);

bool _busy = false;

/// Show the Telegram pack [name] and add it on "Add". Plain-words notices
/// on failure.
Future<void> openTelegramPack(BuildContext context, WidgetRef ref, String name) =>
    openTelegramPackWith(context, ref.read, name);

/// [openTelegramPack] from outside a widget (a link that opened the app).
Future<void> openTelegramPackWith(BuildContext context, ProviderRead read, String name) async {
  if (_busy) return;
  _busy = true;
  try {
    await _open(context, read, name);
  } finally {
    _busy = false;
  }
}

Future<void> _open(BuildContext context, ProviderRead read, String name) async {
  final l = context.l10n;
  final store = read(stickerStoreProvider);
  final progress = _Progress(ValueNotifier(l.tgPackLoading))..show(context);
  core.TelegramPackInfo info;
  ImportResult first;
  try {
    info = await store.telegramInfo(name);
    if (info.stickers.isEmpty) throw StateError('tg:not_found');
    first = await stickersFromTelegram(
      store,
      info,
      indices: [for (var i = 0; i < info.stickers.length && i < kTelegramPreviewCount; i++) i],
      cancelled: () => progress.closed,
    );
    if (first.stickers.isEmpty) throw StateError('tg:failed');
  } on TelegramImportCancelled {
    return;
  } catch (e) {
    if (!progress.closed) appNotice.value = telegramPackError(l, e);
    return;
  } finally {
    progress.close();
  }
  if (!context.mounted) return;

  final id = telegramPackId(info.name);
  final have = (read(userStickerPacksProvider).value ?? const []).any((p) => p.id == id);
  final total = info.stickers.length.clamp(0, kMaxPackStickers);
  final look = packViewOf(telegramPack(info, first.stickers));
  final add = await showDsActionSheet<bool>(
    context,
    header: _TelegramPackHeader(title: look.title(''), count: total, stickers: look.stickers, already: have),
    actions: [DsSheetAction(have ? l.tgPackAddToSinhron : l.stickerPackAdd(total), true)],
  );
  if (add != true || !context.mounted) return;

  final down = _Progress(ValueNotifier(l.tgPackDownloading(0, total)))..show(context);
  try {
    final r = await stickersFromTelegram(
      store,
      info,
      have: {for (final s in first.stickers) int.parse(s.id.substring(1)) - 1: s},
      onProgress: (done, all) => down.text.value = l.tgPackDownloading(done, all),
      cancelled: () => down.closed,
    );
    if (r.stickers.isEmpty) throw StateError('tg:failed');
    final view = await read(userStickerPacksProvider.notifier).add(telegramPack(info, r.stickers));
    showDone(r.skipped > 0 ? l.tgPackAddedPartly(view.title(''), r.skipped) : l.stickersImported(view.title('')));
  } on TelegramImportCancelled {
    return;
  } catch (e) {
    if (!down.closed) appNotice.value = telegramPackError(l, e);
  } finally {
    down.close();
  }
}

/// A sheet with a spinner and a line of text; Cancel (or a swipe) closes
/// it and [closed] tells the work to stop.
class _Progress {
  _Progress(this.text);
  final ValueNotifier<String> text;
  final _done = ValueNotifier(false);
  bool closed = false;

  void show(BuildContext context) {
    unawaited(
      showDsActionSheet<void>(
        context,
        header: _ProgressHeader(text: text, done: _done),
        actions: const [],
      ).whenComplete(() => closed = true),
    );
  }

  /// The work is over: the sheet goes (now, or as soon as it is built).
  void close() {
    if (closed) return;
    closed = true;
    _done.value = true;
  }
}

class _ProgressHeader extends StatefulWidget {
  const _ProgressHeader({required this.text, required this.done});
  final ValueListenable<String> text;
  final ValueListenable<bool> done;

  @override
  State<_ProgressHeader> createState() => _ProgressHeaderState();
}

class _ProgressHeaderState extends State<_ProgressHeader> {
  @override
  void initState() {
    super.initState();
    widget.done.addListener(_maybeGo);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeGo());
  }

  @override
  void dispose() {
    widget.done.removeListener(_maybeGo);
    super.dispose();
  }

  void _maybeGo() {
    if (!mounted || !widget.done.value) return;
    final route = ModalRoute.of(context);
    if (route != null && route.isActive) Navigator.of(context).removeRoute(route);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      key: const ValueKey('telegram-pack-progress'),
      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x4, DsSpace.x4, DsSpace.x3),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DsSpinner(color: tokens.accent, size: 24),
          const SizedBox(height: DsSpace.x3),
          ValueListenableBuilder<String>(
            valueListenable: widget.text,
            builder: (_, t, _) => Text(t, textAlign: TextAlign.center, style: DsText.body.copyWith(color: tokens.text)),
          ),
        ],
      ),
    );
  }
}

class _TelegramPackHeader extends StatelessWidget {
  const _TelegramPackHeader({required this.title, required this.count, required this.stickers, required this.already});
  final String title;
  final int count;
  final List<Sticker> stickers;
  final bool already;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return Column(
      key: const ValueKey('telegram-pack-sheet'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3h5, DsSpace.x4, DsSpace.x1),
          child: Text(
            title,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DsText.headline.copyWith(color: tokens.text),
          ),
        ),
        Text(
          '${l.stickerPackCount(count)} · ${l.tgPackFrom}',
          textAlign: TextAlign.center,
          style: DsText.footnote.copyWith(color: tokens.text3),
        ),
        if (already)
          Padding(
            padding: const EdgeInsets.only(top: DsSpace.x1),
            child: Text(l.stickerPackAlready, style: DsText.footnote.copyWith(color: tokens.accent)),
          ),
        LayoutBuilder(
          builder: (context, box) {
            final cell = (box.maxWidth - 2 * DsSpace.x2) / 5;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.all(DsSpace.x2),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, mainAxisExtent: cell),
              itemCount: stickers.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.all(DsSpace.x1),
                child: StickerView.of(stickers[i], size: cell - DsSpace.x2, animate: true),
              ),
            );
          },
        ),
      ],
    );
  }
}
