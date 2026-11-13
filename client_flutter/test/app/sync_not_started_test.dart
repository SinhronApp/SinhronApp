// Tech-debt 2.37 (2026-10-16): a "sync not initialised" error while starting
// a chat sent the person to onboarding — where "Create account" would have
// made a new account over the one on the phone (ADR-021). Now it restarts
// the connection with the device key, or shows "Unlock" when there's none.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/navigation.dart';

void main() {
  test('the error is recognised in both spellings', () {
    expect(isSyncNotStarted('Exception: sync not initialised'), isTrue);
    expect(isSyncNotStarted('SyncClient not initialized'), isTrue);
    expect(isSyncNotStarted('net not connected'), isFalse);
  });

  test('starting a chat never routes to onboarding', () {
    final src = File('lib/app/navigation.dart').readAsStringSync();
    final start = src.indexOf('Future<void> _startChatByIdentityOnce(');
    final end = src.indexOf('\n}\n', start);
    expect(start, greaterThan(0));
    final body = src.substring(start, end);
    expect(body, isNot(contains('OnboardingSplashScreen')));
    expect(body, isNot(contains('_wireWelcomeBuilder')));
    expect(body, contains('resume(force: true)'));
  });
}
