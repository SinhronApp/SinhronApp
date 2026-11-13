import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/ram_media_server.dart';

void main() {
  test('Range header parsing', () {
    expect(RamMediaServer.parseRange(null, 100), isNull);
    expect(RamMediaServer.parseRange('bytes=0-9', 100), (0, 9));
    expect(RamMediaServer.parseRange('bytes=90-', 100), (90, 99));
    expect(RamMediaServer.parseRange('bytes=-10', 100), (90, 99));
    expect(RamMediaServer.parseRange('bytes=50-500', 100), (50, 99), reason: 'clamped');
    expect(RamMediaServer.parseRange('bytes=200-300', 100), (-1, -1), reason: 'unsatisfiable');
    expect(RamMediaServer.parseRange('items=0-1', 100), isNull);
  });

  test('serves the bytes on loopback with ranges; other paths 404; closes', () async {
    final data = Uint8List.fromList(List.generate(1000, (i) => i % 256));
    final server = await RamMediaServer.start(data, mimeType: 'video/mp4');
    final uri = server.uri;
    expect(uri.host, '127.0.0.1');
    expect(uri.path.length, greaterThan(30), reason: 'unguessable path');

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    Future<(int, List<int>, HttpHeaders)> get(Uri u, {String? range}) async {
      final req = await client.getUrl(u);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      return (res.statusCode, body, res.headers);
    }

    final full = await get(uri);
    expect(full.$1, 200);
    expect(full.$2, data);
    expect(full.$3.value(HttpHeaders.acceptRangesHeader), 'bytes');

    final part = await get(uri, range: 'bytes=10-19');
    expect(part.$1, 206);
    expect(part.$2, data.sublist(10, 20));
    expect(part.$3.value(HttpHeaders.contentRangeHeader), 'bytes 10-19/1000');

    expect((await get(uri, range: 'bytes=5000-')).$1, 416);
    expect((await get(uri.replace(path: '/guess'))).$1, 404);

    await server.close();
    await expectLater(get(uri), throwsA(isA<IOException>()));
  });
}
