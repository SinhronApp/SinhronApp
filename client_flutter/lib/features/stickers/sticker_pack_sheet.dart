// A sticker pack in a sheet — ADR-049: its stickers, who made it and under
// which licence, and what can be done with it: add it (someone else's),
// share or remove it (one's own). Built-in packs are just shown.

import 'dart:async';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/stickers.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../documents/document_share.dart' show shareOrigin;
import 'sticker_store.dart';
import 'sticker_view.dart';
import 'telegram_import.dart';

enum _PackAction { add, share, copy, delete }

/// Show [pack]. [foreign] is a pack from someone else (a share code or a
/// received sticker) — "Add" saves it here.
Future<void> showStickerPackSheet(
  BuildContext context,
  WidgetRef ref,
  StickerPackView pack, {
  core.StickerPack? foreign,
}) async {
  final l = context.l10n;
  final mine = ref.read(userStickerPacksProvider).value ?? const [];
  final have = pack.builtin || mine.any((p) => p.id == pack.id);
  final own = !pack.builtin && foreign == null;
  final picked = await showDsActionSheet<_PackAction>(
    context,
    header: _PackHeader(pack: pack, note: have && foreign != null ? l.stickerPackAlready : null),
    actions: [
      if (foreign != null && !have) DsSheetAction(l.stickerPackAdd(pack.stickers.length), _PackAction.add),
      if (own) ...[
        DsSheetAction(l.stickerPackShare, _PackAction.share),
        DsSheetAction(l.stickerPackCopyCode, _PackAction.copy),
        DsSheetAction(l.stickerPackDelete, _PackAction.delete, destructive: true),
      ],
    ],
  );
  if (picked == null) return;
  try {
    switch (picked) {
      case _PackAction.add:
        await ref.read(userStickerPacksProvider.notifier).add(foreign!);
        showDone(l.stickerPackAdded);
      case _PackAction.share:
        final code = await ref.read(stickerStoreProvider).share(pack.id);
        await SharePlus.instance.share(ShareParams(text: l.stickerPackShareText(code), sharePositionOrigin: shareOrigin()));
      case _PackAction.copy:
        final code = await ref.read(stickerStoreProvider).share(pack.id);
        await Clipboard.setData(ClipboardData(text: code));
        showDone(l.stickerPackCodeCopied);
      case _PackAction.delete:
        await ref.read(userStickerPacksProvider.notifier).remove(pack.id);
    }
  } catch (_) {
    appNotice.value = l.stickerPackUnavailable;
  }
}

class _PackHeader extends StatelessWidget {
  const _PackHeader({required this.pack, this.note});
  final StickerPackView pack;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final lang = stickerLang(context);
    final credit = [
      if (pack.builtin) l.stickerPackBuiltin,
      if (pack.author.isNotEmpty) pack.author,
      if (pack.license.isNotEmpty) pack.license,
    ].join(' · ');
    return Column(
      key: const ValueKey('sticker-pack-sheet'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3h5, DsSpace.x4, DsSpace.x1),
          child: Text(
            pack.title(lang),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: DsText.headline.copyWith(color: tokens.text),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x5),
          child: Text(
            [l.stickerPackCount(pack.stickers.length), if (credit.isNotEmpty) credit].join(' · '),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: DsText.footnote.copyWith(color: tokens.text3),
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: DsSpace.x1),
            child: Text(note!, style: DsText.footnote.copyWith(color: tokens.accent)),
          ),
        Flexible(
          child: LayoutBuilder(
            builder: (context, box) {
              final cell = (box.maxWidth - 2 * DsSpace.x2) / 5;
              return GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(DsSpace.x2),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 5, mainAxisExtent: cell),
                itemCount: pack.stickers.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.all(DsSpace.x1),
                  child: StickerView.of(pack.stickers[i], size: cell - DsSpace.x2, animate: true),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Open the pack a received sticker came from: a built-in one from this
/// app, else the one it carries (downloaded, decrypted, not yet added).
Future<void> openPackOfSticker(BuildContext context, WidgetRef ref, String mediaJson) async {
  final l = context.l10n;
  final store = ref.read(stickerStoreProvider);
  try {
    final meta = await store.meta(mediaJson);
    if (!context.mounted) return;
    final List<StickerPackView> builtin = await ref.read(builtinStickerPacksProvider.future);
    final mine = ref.read(userStickerPacksProvider).value ?? const [];
    final local = [...builtin, ...mine].where((p) => p.id == meta.packId).firstOrNull;
    if (local != null) {
      if (context.mounted) await showStickerPackSheet(context, ref, local);
      return;
    }
    if (!meta.packAttached) {
      appNotice.value = l.stickerPackNotShared;
      return;
    }
    final p = await store.fetchFromMessage(mediaJson);
    if (context.mounted) await showStickerPackSheet(context, ref, packViewOf(p), foreign: p);
  } catch (_) {
    appNotice.value = l.stickerPackUnavailable;
  }
}

/// Add a pack from a share code — or a Telegram link (ADR-062) — on the
/// clipboard.
Future<void> addPackFromClipboard(BuildContext context, WidgetRef ref) async {
  final l = context.l10n;
  final text = (await Clipboard.getData('text/plain'))?.text ?? '';
  final telegram = telegramPackName(text);
  if (telegram != null && !text.contains('sinhron-stickers:')) {
    if (context.mounted) await openTelegramPack(context, ref, telegram);
    return;
  }
  if (!text.contains('sinhron-stickers:')) {
    appNotice.value = l.stickersNoCode;
    return;
  }
  try {
    final p = await ref.read(stickerStoreProvider).fetchCode(text);
    if (context.mounted) unawaited(showStickerPackSheet(context, ref, packViewOf(p), foreign: p));
  } catch (_) {
    appNotice.value = l.stickerPackUnavailable;
  }
}
