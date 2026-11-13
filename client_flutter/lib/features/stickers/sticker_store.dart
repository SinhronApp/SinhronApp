// Sticker packs for the UI — ADR-049.
//
//   • Built-in packs: app assets (assets/stickers/packs.json), the same in
//     every Sinhron app, so a sticker from one travels by pack id.
//   • Added packs: from files or from another person (share code / "Add
//     pack" on a received sticker). Kept encrypted by the Rust core; here
//     they're decrypted into RAM while the app runs.
//   • Recent: the last [kRecentStickersMax] sent, kept on this phone.
//
// [StickerStore] is the one seam to the core, so widget tests swap in a
// fake (the FFI library isn't loaded under `flutter test`).

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show BuildContext, Localizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/settings_providers.dart';
import '../../core/services/media_cache.dart';
import '../../core/services/net_service.dart';
import '../../src/rust/api/simple.dart' as simple;
import '../../src/rust/api/stickers.dart' as core;
import 'sticker_codec.dart';

/// One sticker, built-in ([asset]) or from an added pack ([data]).
class Sticker {
  const Sticker({
    required this.packId,
    required this.id,
    required this.emoji,
    required this.format,
    this.asset,
    this.data,
    this.preview,
  });

  final String packId;
  final String id;
  final String emoji;

  /// png / webp / tgs / webm.
  final String format;
  final String? asset;
  final Uint8List? data;

  /// Small still PNG (added packs; may be empty).
  final Uint8List? preview;

  /// "pack/sticker" — unique across packs (recents, caches).
  String get key => '$packId/$id';
  bool get animated => stickerFormatAnimated(format);

  Future<Uint8List> bytes() async {
    if (data != null) return data!;
    final b = await rootBundle.load(asset!);
    return b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
  }
}

class StickerPackView {
  const StickerPackView({
    required this.id,
    required this.titles,
    required this.stickers,
    this.author = '',
    this.license = '',
    this.licenseUrl = '',
    this.builtin = false,
  });

  final String id;

  /// Title by language code ('ru', 'en'); added packs have one, under ''.
  final Map<String, String> titles;
  final List<Sticker> stickers;
  final String author;
  final String license;
  final String licenseUrl;
  final bool builtin;

  String title(String lang) => titles[lang] ?? titles['en'] ?? titles.values.first;
  Sticker get cover => stickers.first;
  bool get animated => stickers.any((s) => s.animated);
}

/// The app's language code for pack titles ('en' without Localizations).
String stickerLang(BuildContext context) => Localizations.maybeLocaleOf(context)?.languageCode ?? 'en';

/// The built-in packs every Sinhron app ships (ids start with `sinhron.`).
Future<List<StickerPackView>> loadBuiltinPacks() async {
  final j = jsonDecode(await rootBundle.loadString('assets/stickers/packs.json')) as Map<String, Object?>;
  return [
    for (final p in (j['packs'] as List).cast<Map<String, Object?>>())
      StickerPackView(
        id: p['id'] as String,
        titles: (p['title'] as Map).cast<String, String>(),
        author: p['author'] as String? ?? '',
        license: p['license'] as String? ?? '',
        licenseUrl: p['license_url'] as String? ?? '',
        builtin: true,
        stickers: [
          for (final s in (p['stickers'] as List).cast<Map<String, Object?>>())
            Sticker(
              packId: p['id'] as String,
              id: (s['file'] as String).split('.').first,
              emoji: s['emoji'] as String? ?? '',
              format: (s['file'] as String).split('.').last,
              asset: 'assets/stickers/${p['dir']}/${s['file']}',
            ),
        ],
      ),
  ];
}

final builtinStickerPacksProvider = FutureProvider<List<StickerPackView>>((ref) => loadBuiltinPacks());

StickerPackView packViewOf(core.StickerPack p) => StickerPackView(
  id: p.info.id,
  titles: {'': p.info.title},
  author: p.info.author,
  license: p.info.license,
  stickers: [
    for (final s in p.stickers)
      Sticker(packId: p.info.id, id: s.id, emoji: s.emoji, format: s.format, data: s.data, preview: s.preview),
  ],
);

/// The core's sticker functions.
abstract class StickerStore {
  Future<List<core.StickerPackInfo>> list();
  Future<core.StickerPack> load(String id);
  Future<core.StickerPackInfo> save({
    required String id,
    required String title,
    String author = '',
    String license = '',
    required List<core.StickerData> stickers,
  });
  Future<void> delete(String id);
  Future<void> move(String id, int to);

  /// A share code for an added pack (uploads it encrypted once).
  Future<String> share(String id);
  Future<core.StickerPack> fetchCode(String code);
  Future<core.StickerPack> fetchFromMessage(String mediaJson);
  Future<core.StickerMeta> meta(String mediaJson);

  /// A sticker message's file (the animation, or the picture).
  Future<Uint8List> fetchSticker(String mediaJson);

  /// Its still picture — the small thumbnail, else the full still (owner,
  /// 2026-10-20: a video sticker on iPhone showed its emoji, ⭐, because
  /// the still it carries was never drawn). Null when there is none.
  Future<Uint8List?> fetchStill(String mediaJson);

  /// ADR-062 — a Telegram pack by name, through our server (errors
  /// "tg:<code>").
  Future<core.TelegramPackInfo> telegramInfo(String name);

  /// Files of stickers [indices] of that pack, with Telegram's still for
  /// those in [thumbFor].
  Future<List<core.TelegramFile>> telegramFiles(String name, List<int> indices, {List<int> thumbFor = const []});

  /// Encrypt + upload + send one sticker; the media JSON to store.
  Future<String> send({
    required String serverBaseUrl,
    required String groupIdHex,
    required String messageId,
    required String format,
    required Uint8List data,
    required Uint8List stillPng,
    required Uint8List thumbnailPng,
    required String emoji,
    required String packId,
    required String packTitle,
    required int packCount,
    String? replyJson,
    required int expireSecs,
  });
}

class CoreStickerStore implements StickerStore {
  CoreStickerStore(this._ref);
  final Ref _ref;

  String get _base {
    final b = _ref.read(netServiceProvider).httpBaseUrl;
    if (b == null) throw StateError('not connected to a server');
    return b;
  }

  @override
  Future<List<core.StickerPackInfo>> list() => core.stickerPacksList();
  @override
  Future<core.StickerPack> load(String id) => core.stickerPackLoad(id: id);
  @override
  Future<core.StickerPackInfo> save({
    required String id,
    required String title,
    String author = '',
    String license = '',
    required List<core.StickerData> stickers,
  }) => core.stickerPackSave(id: id, title: title, author: author, license: license, stickers: stickers);
  @override
  Future<void> delete(String id) => core.stickerPackDelete(id: id);
  @override
  Future<void> move(String id, int to) => core.stickerPackMove(id: id, to: to);
  @override
  Future<String> share(String id) => core.stickerPackShare(serverBaseUrl: _base, id: id);
  @override
  Future<core.StickerPack> fetchCode(String code) => core.stickerPackFetch(serverBaseUrl: _base, code: code);
  @override
  Future<core.StickerPack> fetchFromMessage(String mediaJson) =>
      core.stickerPackFetchFromMessage(serverBaseUrl: _base, mediaJson: mediaJson);
  @override
  Future<core.StickerMeta> meta(String mediaJson) => core.stickerMeta(mediaJson: mediaJson);
  @override
  Future<String> send({
    required String serverBaseUrl,
    required String groupIdHex,
    required String messageId,
    required String format,
    required Uint8List data,
    required Uint8List stillPng,
    required Uint8List thumbnailPng,
    required String emoji,
    required String packId,
    required String packTitle,
    required int packCount,
    String? replyJson,
    required int expireSecs,
  }) => core.netSendSticker(
    serverBaseUrl: serverBaseUrl,
    groupIdHex: groupIdHex,
    messageId: messageId,
    format: format,
    data: data,
    stillPng: stillPng,
    thumbnailPng: thumbnailPng,
    emoji: emoji,
    width: 512,
    height: 512,
    packId: packId,
    packTitle: packTitle,
    packCount: packCount,
    replyJson: replyJson,
    expireSecs: expireSecs,
  );
  @override
  Future<core.TelegramPackInfo> telegramInfo(String name) => core.telegramPackInfo(serverBaseUrl: _base, name: name);
  @override
  Future<List<core.TelegramFile>> telegramFiles(String name, List<int> indices, {List<int> thumbFor = const []}) =>
      core.telegramStickerFiles(serverBaseUrl: _base, name: name, indices: indices, thumbFor: thumbFor);
  @override
  Future<Uint8List> fetchSticker(String mediaJson) => _ref
      .read(mediaCacheProvider)
      .getOrLoad('st:$mediaJson', () => core.stickerFetch(serverBaseUrl: _base, mediaJson: mediaJson));
  @override
  Future<Uint8List?> fetchStill(String mediaJson) async {
    Future<Uint8List> get(bool thumb) => _ref
        .read(mediaCacheProvider)
        .getOrLoad(
          'stp:$thumb:$mediaJson',
          () => simple.mediaFetch(serverBaseUrl: _base, mediaJson: mediaJson, thumbnail: thumb),
        );
    Uint8List? still;
    try {
      still = await get(true);
    } catch (_) {
      try {
        still = await get(false);
      } catch (_) {
        return null;
      }
    }
    // Drawn as it is (sticker_view.dart): never one too big to decode.
    return await stickerPictureOk(still) ? still : null;
  }
}

final stickerStoreProvider = Provider<StickerStore>((ref) => CoreStickerStore(ref));

/// The packs this person added, opened into RAM.
class UserStickerPacks extends AsyncNotifier<List<StickerPackView>> {
  @override
  Future<List<StickerPackView>> build() async {
    final store = ref.read(stickerStoreProvider);
    try {
      final infos = await store.list();
      final out = <StickerPackView>[];
      for (final i in infos) {
        try {
          out.add(packViewOf(await store.load(i.id)));
        } catch (_) {
          // A pack that doesn't open (file gone) is skipped, not fatal.
        }
      }
      return out;
    } catch (_) {
      return const []; // DB not open yet
    }
  }

  /// Add (or replace) a pack.
  Future<StickerPackView> add(core.StickerPack p) async {
    await ref.read(stickerStoreProvider).save(
      id: p.info.id,
      title: p.info.title,
      author: p.info.author,
      license: p.info.license,
      stickers: p.stickers,
    );
    final view = packViewOf(p);
    final now = [...(state.value ?? const <StickerPackView>[])];
    final at = now.indexWhere((v) => v.id == view.id);
    if (at >= 0) {
      now[at] = view;
    } else {
      now.add(view);
    }
    state = AsyncData(now);
    return view;
  }

  /// A new pack made on this phone (from files).
  Future<StickerPackView> addNew({required String title, required List<core.StickerData> stickers}) => add(
    core.StickerPack(
      info: core.StickerPackInfo(
        id: newUserPackId(),
        title: title.trim(),
        author: '',
        license: '',
        count: stickers.length,
        animated: stickers.any((s) => stickerFormatAnimated(s.format)),
        cover: stickers.first.preview,
      ),
      stickers: stickers,
    ),
  );

  Future<void> remove(String id) async {
    await ref.read(stickerStoreProvider).delete(id);
    state = AsyncData([...?state.value].where((v) => v.id != id).toList());
  }
}

final userStickerPacksProvider = AsyncNotifierProvider<UserStickerPacks, List<StickerPackView>>(UserStickerPacks.new);

/// Built-in packs first, then the added ones.
final stickerPacksProvider = Provider<List<StickerPackView>>((ref) {
  final builtin = ref.watch(builtinStickerPacksProvider).value ?? const [];
  final mine = ref.watch(userStickerPacksProvider).value ?? const [];
  return [...builtin, ...mine];
});

/// Recently sent stickers, newest first ("pack/sticker" keys).
final recentStickersProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('sticker_recent', ''));

const kRecentStickersMax = 20;

String withRecentSticker(String setting, String key) {
  final list = [key, ...setting.split(' ').where((e) => e.isNotEmpty && e != key)];
  return list.take(kRecentStickersMax).join(' ');
}

/// A fresh id for a pack made on this phone: `u` + 16 hex.
String newUserPackId() {
  final r = Random.secure();
  return 'u${List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

/// Bundled Noto animation for a lone emoji ("😂" → its Lottie), if there
/// is one — big emoji messages move like Telegram's.
Sticker? animatedEmojiFor(List<StickerPackView> builtin, String emoji) {
  String bare(String s) => s.replaceAll('\u{FE0F}', '');
  final e = bare(emoji.trim());
  for (final p in builtin) {
    if (!p.id.startsWith('sinhron.noto')) continue;
    for (final s in p.stickers) {
      if (bare(s.emoji) == e) return s;
    }
  }
  return null;
}
