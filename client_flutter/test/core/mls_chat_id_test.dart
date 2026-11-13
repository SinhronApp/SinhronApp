import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_providers.dart';

void main() {
  // A real group id from the test server (2026-10-15): 16 bytes = 32 hex.
  // The old bound (≥40) called it "not encrypted" and blocked sending.
  test('a real OpenMLS group id is an encrypted chat', () {
    expect(looksLikeMlsGroupId('6215b7d06526f464fff3a3edb19b958b'), isTrue);
    expect(looksLikeMlsGroupId('ab' * 20), isTrue);
  });

  test('legacy local chats are not', () {
    expect(looksLikeMlsGroupId('chat-1a2b3c4d'), isFalse); // compose demo row
    expect(looksLikeMlsGroupId('0123456789abcdef'), isFalse); // FNV seed id
    expect(looksLikeMlsGroupId('6215B7D06526F464FFF3A3EDB19B958B'), isFalse); // not lower hex
    expect(looksLikeMlsGroupId(''), isFalse);
  });
}
