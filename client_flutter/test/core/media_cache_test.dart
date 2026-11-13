import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/services/media_cache.dart';

Uint8List _b(int n) => Uint8List(n);

void main() {
  test('evicts least-recently-used entries past the byte budget', () {
    final c = MediaCache(maxBytes: 100);
    c.put('a', _b(40));
    c.put('b', _b(40));
    expect(c.get('a'), isNotNull); // a is now most recent
    c.put('c', _b(40)); // 120 > 100 → evict b (oldest)
    expect(c.get('b'), isNull);
    expect(c.get('a'), isNotNull);
    expect(c.get('c'), isNotNull);
    expect(c.bytes, 80);
  });

  test('replacing a key does not double-count bytes', () {
    final c = MediaCache(maxBytes: 100);
    c.put('a', _b(30));
    c.put('a', _b(50));
    expect(c.bytes, 50);
    expect(c.length, 1);
  });

  test('oversized value is served but not cached', () async {
    final c = MediaCache(maxBytes: 10);
    final v = await c.getOrLoad('big', () async => _b(20));
    expect(v.length, 20);
    expect(c.get('big'), isNull);
    expect(c.bytes, 0);
  });

  test('concurrent loads share one call; failures are not cached', () async {
    final c = MediaCache();
    var calls = 0;
    Future<Uint8List> load() async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return _b(3);
    }

    final r = await Future.wait([c.getOrLoad('k', load), c.getOrLoad('k', load)]);
    expect(calls, 1);
    expect(identical(r[0], r[1]), isTrue);

    var fails = 0;
    Future<Uint8List> boom() async {
      fails++;
      throw StateError('net down');
    }

    await expectLater(c.getOrLoad('x', boom), throwsStateError);
    await expectLater(c.getOrLoad('x', boom), throwsStateError);
    expect(fails, 2, reason: 'a failed load must be retried, not cached');
  });

  test('clear empties the cache', () {
    final c = MediaCache();
    c.put('a', _b(5));
    c.clear();
    expect(c.length, 0);
    expect(c.bytes, 0);
  });
}
