// Serves decrypted media from RAM to the platform player — backlog §3
// item 31 (video), same idea as just_audio's proxy for voice (ADR-017).
//
// AVPlayer can't play from memory, and writing the plaintext video to a
// file would leave it on disk. Instead: an HTTP server bound to the
// loopback interface only, one unguessable path per video, Range
// requests (AVPlayer needs them), closed as soon as the viewer closes.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class RamMediaServer {
  RamMediaServer._(this._server, this._bytes, this._mime, this._path);

  final HttpServer _server;
  final Uint8List _bytes;
  final String _mime;
  final String _path;

  /// Start serving [bytes]; [uri] is valid until [close].
  static Future<RamMediaServer> start(Uint8List bytes, {required String mimeType}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final rng = Random.secure();
    final token = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final s = RamMediaServer._(server, bytes, mimeType, '/$token');
    server.listen(s._handle);
    return s;
  }

  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port, path: _path);

  Future<void> close() => _server.close(force: true);

  /// `bytes=start-end` → inclusive range, clamped; null = whole file.
  static (int, int)? parseRange(String? header, int length) {
    if (header == null || !header.startsWith('bytes=')) return null;
    final spec = header.substring(6).split(',').first.trim();
    final dash = spec.indexOf('-');
    if (dash < 0) return null;
    final a = spec.substring(0, dash), b = spec.substring(dash + 1);
    int start, end;
    if (a.isEmpty) {
      // Suffix: last N bytes.
      final n = int.tryParse(b);
      if (n == null) return null;
      start = max(0, length - n);
      end = length - 1;
    } else {
      final s = int.tryParse(a);
      if (s == null) return null;
      start = s;
      end = b.isEmpty ? length - 1 : (int.tryParse(b) ?? length - 1);
    }
    end = min(end, length - 1);
    if (start > end || start >= length) return (-1, -1);
    return (start, end);
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // Only our own path, only from this device.
    if (req.uri.path != _path || req.connectionInfo?.remoteAddress.isLoopback != true) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.headers
      ..set(HttpHeaders.contentTypeHeader, _mime)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    final range = parseRange(req.headers.value(HttpHeaders.rangeHeader), _bytes.length);
    if (range == null) {
      res.contentLength = _bytes.length;
      if (req.method != 'HEAD') res.add(_bytes);
    } else if (range.$1 < 0) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${_bytes.length}');
    } else {
      final (s, e) = range;
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $s-$e/${_bytes.length}');
      res.contentLength = e - s + 1;
      if (req.method != 'HEAD') res.add(Uint8List.sublistView(_bytes, s, e + 1));
    }
    await res.close();
  }
}
