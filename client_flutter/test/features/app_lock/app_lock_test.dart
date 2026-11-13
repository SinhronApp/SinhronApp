import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/settings/app_lock_screen.dart';
import 'package:sinhron/features/settings/privacy_security_screen.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

class FakeAuth implements AppAuthenticator {
  bool ok = true;
  bool supported = true;
  int asked = 0;
  @override
  Future<bool> available() async => supported;
  @override
  Future<bool> authenticate(String reason) async {
    asked++;
    return ok;
  }
}

Widget host(Widget child, MemoryStore store, FakeAuth auth) => ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store), appAuthenticatorProvider.overrideWithValue(auth)],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 1000)),
          child: Directionality(textDirection: TextDirection.ltr, child: child),
        ),
      ),
    );

void main() {
  testWidgets('App Lock on: locked at launch until Face ID / passcode succeeds', (t) async {
    final store = MemoryStore()..map['app_lock'] = '1';
    final auth = FakeAuth()..ok = false;
    await t.pumpWidget(host(const AppLockGate(child: Text('secret chat')), store, auth));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget);
    expect(auth.asked, 1);
    auth.ok = true;
    await t.tap(find.byKey(const ValueKey('lock-cover')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsNothing);
  });

  // Owner audit, 2026-11-02 — the phone's passcode / Face ID removed after
  // App Lock was turned on: nothing could open it, only deleting the app.
  testWidgets('no passcode / Face ID any more: the lock turns itself off and says so', (t) async {
    final store = MemoryStore()..map['app_lock'] = '1';
    final auth = FakeAuth()
      ..ok = false
      ..supported = false;
    appNotice.value = '';
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed); // on screen
    await t.pumpWidget(host(const AppLockGate(child: Text('secret chat')), store, auth));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsNothing);
    expect(find.text('secret chat'), findsOneWidget);
    expect(store.map['app_lock'], isNot('1'));
    expect(appNotice.value, contains('App Lock is off'));
    appNotice.value = '';
  });

  // Audit LOCK-4 — Android starts the app with no screen (a push, "always
  // connected", a reply from a notification): nothing can be asked there and
  // the phone looks as if it had no passcode. The lock must stay on.
  testWidgets('started with no screen: the lock does not turn itself off', (t) async {
    final store = MemoryStore()..map['app_lock'] = '1';
    final auth = FakeAuth()
      ..ok = false
      ..supported = false;
    appNotice.value = '';
    expect(t.binding.lifecycleState, isNot(AppLifecycleState.resumed));
    await t.pumpWidget(host(const AppLockGate(child: Text('secret chat')), store, auth));
    await t.pumpAndSettle();
    expect(store.map['app_lock'], '1');
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget);
    expect(appNotice.value, '');

    // The app is opened; the phone has its passcode after all.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    auth
      ..ok = true
      ..supported = true;
    await t.tap(find.byKey(const ValueKey('lock-cover')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsNothing);
    expect(store.map['app_lock'], '1');
  });

  // storage-devices:19 — Android takes the Recents picture before the blur
  // cover is drawn: with App Lock on, the app asks for no picture at all.
  testWidgets('Android, App Lock on: no Recents picture of the last chat', (t) async {
    final calls = <String>[];
    const ch = MethodChannel('dev.sinhron/privacy');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      calls.add('${c.method} ${(c.arguments as Map)['on']}');
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));
    final store = MemoryStore()..map['app_lock'] = '1';
    await t.pumpWidget(host(const AppLockGate(child: Text('secret chat')), store, FakeAuth()));
    await t.pumpAndSettle();
    expect(calls, ['hideRecents true']);

    final c = ProviderScope.containerOf(t.element(find.byType(AppLockGate)));
    await c.read(appLockEnabledProvider.notifier).save(false);
    await t.pumpAndSettle();
    expect(calls, ['hideRecents true', 'hideRecents false'], reason: 'App Lock off: pictures again');
  });

  testWidgets('switcher cover while inactive; re-lock after the timeout', (t) async {
    final store = MemoryStore()
      ..map['app_lock'] = '1'
      ..map['app_lock_after'] = '60';
    final auth = FakeAuth();
    var now = DateTime(2026, 10, 13, 12);
    await t.pumpWidget(host(AppLockGate(now: () => now, child: const Text('secret chat')), store, auth));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsNothing, reason: 'unlocked at launch');

    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await t.pump();
    expect(find.byKey(const ValueKey('switcher-cover')), findsOneWidget);

    // Back within the minute: no lock.
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(seconds: 20));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('switcher-cover')), findsNothing);
    expect(auth.asked, 1);

    // Away longer than the timeout: locks and asks again.
    auth.ok = false;
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(minutes: 5));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget);
    expect(auth.asked, 2);
  });

  // Audit storage-devices:6 — the phone's clock set back in Settings opened the app.
  testWidgets('the phone clock set back does not skip the lock', (t) async {
    final store = MemoryStore()
      ..map['app_lock'] = '1'
      ..map['app_lock_after'] = '60';
    final auth = FakeAuth();
    var now = DateTime(2026, 10, 13, 12);
    var up = const Duration(hours: 1);
    await t.pumpWidget(host(AppLockGate(now: () => now, uptime: () => up, child: const Text('secret chat')), store, auth));
    await t.pumpAndSettle();
    Future<void> awayAndBack(Duration clock, Duration real) async {
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(clock);
      up += real;
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpAndSettle();
    }

    auth.ok = false;
    // 5 min away, clock moved back by 4.5 min: it reads 30 s.
    await awayAndBack(const Duration(seconds: 30), const Duration(minutes: 5));
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget);
    auth.ok = true;
    await t.tap(find.byKey(const ValueKey('lock-cover')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('lock-cover')), findsNothing);

    auth.ok = false;
    // Clock moved back a day.
    await awayAndBack(const Duration(days: -1), const Duration(seconds: 10));
    expect(find.byKey(const ValueKey('lock-cover')), findsOneWidget);
  });

  testWidgets('turning App Lock on needs a successful check first', (t) async {
    final store = MemoryStore();
    final auth = FakeAuth()..ok = false;
    await t.pumpWidget(host(const AppLockScreen(), store, auth));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('app-lock-toggle')));
    await t.pumpAndSettle();
    expect(store.map['app_lock'], isNull, reason: 'failed check — stays off');
    auth.ok = true;
    await t.tap(find.byKey(const ValueKey('app-lock-toggle')));
    await t.pumpAndSettle();
    expect(store.map['app_lock'], '1');

    auth.supported = false;
    await t.tap(find.byKey(const ValueKey('app-lock-toggle'))); // off: no check needed
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('app-lock-toggle')));
    await t.pumpAndSettle();
    expect(find.textContaining('Set a passcode'), findsOneWidget);
  });

  testWidgets('privacy screen switches are saved settings', (t) async {
    t.view.physicalSize = const Size(390, 2000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = MemoryStore();
    await t.pumpWidget(host(const PrivacySecurityScreen(), store, FakeAuth()));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('privacy-read-receipts')));
    await t.tap(find.byKey(const ValueKey('privacy-typing')));
    await t.tap(find.byKey(const ValueKey('privacy-link-previews')));
    await t.tap(find.byKey(const ValueKey('privacy-switcher')));
    await t.pumpAndSettle();
    expect(store.map, containsPair('read_receipts', '0'));
    expect(store.map, containsPair('typing_indicators', '0'));
    expect(store.map, containsPair('link_previews', '1'));
    expect(store.map, containsPair('hide_in_switcher', '0'));
    // ADR-031 — "online" is off until turned on, then saved.
    expect(store.map.containsKey('show_online'), isFalse);
    await t.tap(find.byKey(const ValueKey('privacy-show-online')));
    await t.pumpAndSettle();
    expect(store.map, containsPair('show_online', '1'));
  });

  // Audit 2026-11b native:1 — the "no Recents picture" flag lives in the
  // Android screen (MainActivity), the engine outlives it: told on every resume.
  testWidgets('a new Android screen on the same engine is told to hide Recents again', (t) async {
    const ch = MethodChannel('dev.sinhron/privacy');
    final store = MemoryStore()..map['app_lock'] = '1';
    // No handler yet: the engine started with no screen.
    await t.pumpWidget(host(const AppLockGate(child: Text('secret chat')), store, FakeAuth()));
    await t.pumpAndSettle();
    final calls = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
      calls.add('${c.method} ${(c.arguments as Map)['on']}');
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));
    t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await t.pumpAndSettle();
    expect(calls, ['hideRecents true']);
  });
}
