// RAM-only cache of DECRYPTED media bytes — spec §8.6, ADR-017.
//
// Decrypted photos/voice/files live here and nowhere else: never on
// disk (no cached_network_image, no temp files), so the at-rest model
// stays "ciphertext on server and on the device (ADR-033, Rust
// `sinhron_storage::blobs`), keys in SQLCipher, plaintext in RAM".
// LRU by total bytes; concurrent loads of the same key share one
// download.

import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class MediaCache {
  MediaCache({this.maxBytes = 64 * 1024 * 1024});

  final int maxBytes;
  // LinkedHashMap keeps insertion order: first entry = least recent.
  final LinkedHashMap<String, Uint8List> _entries =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List>> _inflight = {};
  int _bytes = 0;

  int get bytes => _bytes;
  int get length => _entries.length;

  Uint8List? get(String key) {
    final v = _entries.remove(key);
    if (v != null) _entries[key] = v; // mark most-recent
    return v;
  }

  void put(String key, Uint8List value) {
    final old = _entries.remove(key);
    if (old != null) _bytes -= old.length;
    // Larger than the whole budget: serve it, don't cache it.
    if (value.length > maxBytes) return;
    _entries[key] = value;
    _bytes += value.length;
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final oldest = _entries.keys.first;
      _bytes -= _entries.remove(oldest)!.length;
    }
  }

  /// Cached bytes for [key], or run [load] once (shared by concurrent
  /// callers) and cache the result. Failures are not cached.
  Future<Uint8List> getOrLoad(String key, Future<Uint8List> Function() load) {
    final hit = get(key);
    if (hit != null) return Future.value(hit);
    return _inflight.putIfAbsent(key, () async {
      try {
        final v = await load();
        put(key, v);
        return v;
      } finally {
        _inflight.remove(key);
      }
    });
  }

  /// Drop everything — e.g. on sign-out.
  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}

final mediaCacheProvider = Provider<MediaCache>((ref) => MediaCache());
