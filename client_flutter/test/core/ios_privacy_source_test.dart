// docs/security-review-2026-11.md — iOS / Android parts that can't run here:
// the source says what they do (the Swift checks in ios/SharedTests run on
// the Mac).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('storage-devices:9 — calls never go into Phone → Recents (iCloud backup, past App Lock)', () {
    final src = File('ios/Runner/CallKitBridge.swift').readAsStringSync();
    expect(src, contains('config.includesCallsInRecents = false'));
    expect(src, isNot(contains('includesCallsInRecents = true')));
  });

  test('storage-devices:2 — the 24 words are an iCloud Keychain item, never a website password', () {
    final src = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(src, contains('kSecAttrService as String: PasswordsBridge.service'));
    expect(src, contains('kSecAttrSynchronizable as String: true'));
    // The only web-credential call left deletes the old entry (nil password).
    final web = RegExp(r'SecAddSharedWebCredential\(([^)]*)\)').allMatches(src).map((m) => m[1]!).toList();
    expect(web, hasLength(1));
    expect(web.single, endsWith(', nil'));
  });

  test('storage-devices:8 — copied words stay on this iPhone and expire', () {
    final src = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(src, contains('options: [.localOnly: true, .expirationDate:'));
  });

  test('storage-devices:8 / :19 — Android: FLAG_SECURE on the words, no Recents picture, a sensitive clip', () {
    final src = File('android/app/src/main/kotlin/com/sinhron/sinhron/MainActivity.kt').readAsStringSync();
    expect(src, contains('val secure = wordsShown || (hideRecents && inBackground && Build.VERSION.SDK_INT < 33)'));
    expect(src, contains('setRecentsScreenshotEnabled(!hideRecents)'));
    expect(src, contains('putBoolean("android.content.extra.IS_SENSITIVE", true)'));
  });

  test('sealed-push:2 — the lock screen names a personal chat only for its own peer', () {
    final src = File('ios/Shared/PushShared.swift').readAsStringSync();
    expect(src, contains('var p: String?'));
    expect(src, contains('let trusted = known.g == true ? senderName != nil : known.p?.lowercased() == senderHex'));
    expect(src, contains('if !trusted {'));
  });
}
