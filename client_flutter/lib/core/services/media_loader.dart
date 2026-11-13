// Media access for widgets — ADR-017. One seam between UI and the Rust
// core so widget tests can swap in fakes (the FFI library isn't loaded
// under `flutter test`).
//
// Decrypted bytes go through [MediaCache] (RAM only, spec §8.6).

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/simple.dart' as core;
import 'media_cache.dart';
import 'net_service.dart';

abstract class MediaLoader {
  /// Display metadata (no keys) from the stored media JSON.
  Future<core.MediaInfo> info(String mediaJson);

  /// Tiny PNG rendered from a BlurHash — instant placeholder.
  Future<Uint8List> blurhash(String hash, int width, int height);

  /// Decrypted file (or its thumbnail) — downloaded, verified, cached.
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail});
}

class CoreMediaLoader implements MediaLoader {
  CoreMediaLoader(this._ref);
  final Ref _ref;

  MediaCache get _cache => _ref.read(mediaCacheProvider);

  @override
  Future<core.MediaInfo> info(String mediaJson) =>
      core.mediaInfo(mediaJson: mediaJson);

  @override
  Future<Uint8List> blurhash(String hash, int width, int height) =>
      _cache.getOrLoad(
        'bh:$hash:$width:$height',
        () => core.mediaBlurhashPng(blurhash: hash, width: width, height: height),
      );

  @override
  Future<Uint8List> fetch(String mediaJson, {required bool thumbnail}) {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) {
      return Future.error(StateError('not connected to a server'));
    }
    return _cache.getOrLoad(
      mediaCacheKey(mediaJson, thumbnail: thumbnail),
      () => core.mediaFetch(
        serverBaseUrl: base,
        mediaJson: mediaJson,
        thumbnail: thumbnail,
      ),
    );
  }
}

/// [MediaCache] key of a decrypted file (or its thumbnail).
String mediaCacheKey(String mediaJson, {required bool thumbnail}) => '${thumbnail ? 't' : 'f'}:$mediaJson';

/// Bytes already decrypted into RAM, right now, without a frame of
/// waiting — the gallery's first frame (under the Hero flight) paints
/// them instead of a "Decrypting…" flash. Null when not loaded yet.
Uint8List? peekMedia(MediaCache cache, String mediaJson, {required bool thumbnail}) =>
    cache.get(mediaCacheKey(mediaJson, thumbnail: thumbnail));

final mediaLoaderProvider =
    Provider<MediaLoader>((ref) => CoreMediaLoader(ref));

/// Link preview cards (ADR-018): metadata + the sender-made image. The
/// receiver never contacts the linked site — the image is an encrypted
/// blob like any photo.
abstract class LinkPreviewLoader {
  Future<core.LinkPreviewInfo> info(String json);
  Future<Uint8List> image(String json);
}

class CoreLinkPreviewLoader implements LinkPreviewLoader {
  CoreLinkPreviewLoader(this._ref);
  final Ref _ref;

  @override
  Future<core.LinkPreviewInfo> info(String json) => core.linkPreviewInfo(json: json);

  @override
  Future<Uint8List> image(String json) {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) return Future.error(StateError('not connected to a server'));
    return _ref
        .read(mediaCacheProvider)
        .getOrLoad('lp:$json', () => core.linkPreviewImage(serverBaseUrl: base, json: json));
  }
}

final linkPreviewLoaderProvider = Provider<LinkPreviewLoader>((ref) => CoreLinkPreviewLoader(ref));
