// Privacy → Proxy (Tor): the setting accepts host:port only.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/settings/proxy_screen.dart';

void main() {
  test('host:port or empty', () {
    expect(isValidProxy(''), isTrue, reason: 'off');
    expect(isValidProxy('127.0.0.1:9050'), isTrue);
    expect(isValidProxy('tor.local:9150'), isTrue);
    expect(isValidProxy('127.0.0.1'), isFalse);
    expect(isValidProxy('http://x:1'), isFalse);
    expect(isValidProxy('a b:1'), isFalse);
  });
}
