import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/contact_qr.dart';
import 'package:sinhron/features/chat_list/chat_data.dart' show mediaPreviewFallback;

void main() {
  final key = 'ab' * 32;

  test('payload round-trips with the server', () {
    final payload = contactQrPayload(key.toUpperCase(), 'chat.example.com');
    expect(payload, 'sinhron-contact:$key@chat.example.com');
    final c = parseContactQr(payload)!;
    expect(c.identityHex, key);
    expect(c.serverHost, 'chat.example.com');
  });

  test('a bare key (from Copy key) is accepted', () {
    final c = parseContactQr('  $key\n')!;
    expect(c.identityHex, key);
    expect(c.serverHost, isNull);
  });

  test('anything else is not a contact', () {
    for (final bad in [
      '',
      'https://example.com',
      'sinhron-server:https://chat.example.com', // a server QR, not a person
      'sinhron-contact:${'ab' * 31}@x.com', // short key
      'sinhron-contact:${'zz' * 32}@x.com', // not hex
      'ab' * 33,
    ]) {
      expect(parseContactQr(bad), isNull, reason: bad);
    }
  });

  test('fingerprint groups the start of the key', () {
    expect(keyFingerprint('0123456789abcdef${'0' * 48}'), '0123 4567 89ab cdef');
    expect(keyFingerprint(''), '');
  });

  test('the name rides along, URL-encoded; older codes have none', () {
    final p = contactQrPayload(key, 'chat.example.com', name: ' Вера К. & Co ');
    expect(p, startsWith('sinhron-contact:$key@chat.example.com?n='));
    final c = parseContactQr(p)!;
    expect((c.identityHex, c.serverHost, c.name), (key, 'chat.example.com', 'Вера К. & Co'));
    expect(parseContactQr('sinhron-contact:$key@chat.example.com')!.name, isNull);
    expect(contactQrPayload(key, 'h', name: '  '), 'sinhron-contact:$key@h');
    final long = parseContactQr('sinhron-contact:$key@h?n=${Uri.encodeQueryComponent('${'я' * 100}\nline')}')!;
    expect(parseContactQr('sinhron-contact:$key@h?n=100%')!.name, '100%', reason: 'not encoded: taken as is');
    expect(long.name!.length, 64, reason: 'a name, not a page of text');
  });

  test('a shared contact card is the whole message, nothing else', () {
    final card = contactQrPayload(key, 'chat.example.com', name: 'Аня Петрова');
    expect(contactCardOf(' $card\n')!.name, 'Аня Петрова');
    expect(contactCardOf(key), isNull, reason: 'a bare key stays text');
    expect(contactCardOf('look $card'), isNull);
    expect(contactCardOf('$card thanks'), isNull);
    // The chat list says what it is.
    expect(mediaPreviewFallback(card, 'text'), 'Contact: Аня Петрова');
    expect(mediaPreviewFallback(contactQrPayload(key, 'h'), 'text'), 'Contact');
    expect(mediaPreviewFallback('hi', 'text'), 'hi');
  });
}
