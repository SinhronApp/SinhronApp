// Audit 2026-11b — what only the owner may do asks Face ID / the phone's
// passcode first (`confirmOwner`), whether App Lock is on or not.

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/account_delete/delete_account_screen.dart';
import 'package:sinhron/features/app_lock/app_lock.dart' show nothingToAskWith;
import 'package:sinhron/features/settings/app_lock_screen.dart';
import 'package:sinhron/features/sign_out/sign_out_screen.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;
import 'app_lock_test.dart' show FakeAuth, host;

void main() {
  Future<void> pump(WidgetTester t, Widget w, FakeAuth auth, [MemoryStore? store]) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      host(
        Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => w)),
        store ?? MemoryStore(),
        auth,
      ),
    );
    await t.pumpAndSettle();
  }

  // LOCK-6
  testWidgets('Delete account: nothing is deleted until Face ID / passcode passes', (t) async {
    final auth = FakeAuth()..ok = false;
    var deleted = 0;
    await pump(t, DeleteAccountScreen(server: 's', onDelete: (_) async => deleted++), auth);
    await t.enterText(find.byKey(const ValueKey('delete-account-confirm')), 'DELETE');
    await t.pump();
    await t.tap(find.byKey(const ValueKey('delete-account-go')));
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(deleted, 0);

    auth.ok = true;
    await t.tap(find.byKey(const ValueKey('delete-account-go')));
    await t.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('Sign out: nothing is wiped until Face ID / passcode passes', (t) async {
    final auth = FakeAuth()..ok = false;
    var wiped = 0;
    await pump(t, SignOutScreen(name: 'G', username: 'ab12', onConfirm: () => wiped++), auth);
    await t.tap(find.text('Sign out').last);
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(wiped, 0);

    auth.ok = true;
    await t.tap(find.text('Sign out').last);
    await t.pumpAndSettle();
    expect(wiped, 1);
  });

  // LOCK-8
  testWidgets('App Lock: off and a longer timeout need Face ID / passcode', (t) async {
    final store = MemoryStore()..map['app_lock'] = '1';
    final auth = FakeAuth()..ok = false;
    await pump(t, const AppLockScreen(), auth, store);
    await t.tap(find.byKey(const ValueKey('app-lock-toggle')));
    await t.pumpAndSettle();
    expect(auth.asked, 1);
    expect(store.map['app_lock'], '1', reason: 'failed check — stays on');

    await t.tap(find.text('Lock again'));
    await t.pumpAndSettle();
    await t.tap(find.text('After 1 hour').last);
    await t.pumpAndSettle();
    expect(auth.asked, 2);
    expect(store.map['app_lock_after'], isNull, reason: 'failed check — timeout unchanged');

    auth.ok = true;
    await t.tap(find.byKey(const ValueKey('app-lock-toggle')));
    await t.pumpAndSettle();
    expect(store.map['app_lock'], isNot('1'));
  });

  // Android with a fingerprint sensor but no PIN and no fingerprints: the
  // system has nothing to ask with — the owner checks let the person through
  // (as on an iPhone with no passcode); a refusal or a cancel is still "no".
  test('nothing to ask with is told apart from a refusal', () {
    for (final code in ['NotEnrolled', 'PasscodeNotSet']) {
      expect(nothingToAskWith(PlatformException(code: code)), isTrue, reason: code);
    }
    // 'NotAvailable' is iOS's word for any other failure (failed, cancelled by the app).
    for (final code in ['NotAvailable', 'LockedOut', 'PermanentlyLockedOut', 'auth_in_progress', 'channel-error']) {
      expect(nothingToAskWith(PlatformException(code: code)), isFalse, reason: code);
    }
    expect(nothingToAskWith(StateError('x')), isFalse);
  });
}
