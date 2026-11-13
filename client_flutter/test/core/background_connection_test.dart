// Bug 2026-10-16 — a backgrounded iPhone kept its socket, so the server sent
// no push. The connection closes in background and reopens on return; not
// during a call. Battery 2026-10-18: Android "always connected" switches the
// heartbeat to the long background gap instead — not on screen, not in a call.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/background_connection.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';

class _Call extends ActiveCallNotifier {
  @override
  ActiveCallState build() => const ActiveCallState.idle();
  void put(ActiveCallState s) => state = s;
}

void main() {
  late List<String> log;
  late ProviderContainer c;
  var stay = false;
  Future<void> Function() sayLeft = () async {};

  setUp(() {
    log = [];
    stay = false;
    sayLeft = () async {};
    c = ProviderContainer(
      overrides: [
        activeCallProvider.overrideWith(_Call.new),
        sayLeftProvider.overrideWithValue(() => sayLeft()),
        stayConnectedInBackgroundProvider.overrideWithValue(() => stay),
        connectionSwitchProvider.overrideWithValue(
          ConnectionSwitch(
            close: () async => log.add('close'),
            open: () async => log.add('open'),
            background: (on) async => log.add(on ? 'bg' : 'fg'),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
  });

  BackgroundConnection bg() => c.read(backgroundConnectionProvider);
  void call(bool active) => (c.read(activeCallProvider.notifier) as _Call).put(
    active
        ? const ActiveCallState(phase: CallPhase.connected, callId: 'c', groupIdHex: 'g')
        : const ActiveCallState.idle(),
  );

  test('leaving the app closes the connection once; coming back reopens it', () async {
    await bg().onLifecycle(AppLifecycleState.inactive);
    expect(log, isEmpty, reason: 'Control Centre — still here');
    await bg().onLifecycle(AppLifecycleState.hidden);
    await bg().onLifecycle(AppLifecycleState.paused);
    expect(log, ['close']);
    await bg().onLifecycle(AppLifecycleState.resumed);
    await bg().onLifecycle(AppLifecycleState.resumed);
    expect(log, ['close', 'open']);
  });

  // Presence 2026-10-19 — the close raced "left" and won: contacts saw
  // "online" for minutes after the iPhone left.
  test('"left" goes out before the connection closes — but the close never hangs on it', () async {
    sayLeft = () async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      log.add('left');
    };
    await bg().onLifecycle(AppLifecycleState.hidden);
    expect(log, ['left', 'close']);

    log.clear();
    await bg().onLifecycle(AppLifecycleState.resumed);
    sayLeft = () => Completer<void>().future; // never finishes (no network)
    final t = Stopwatch()..start();
    await bg().onLifecycle(AppLifecycleState.paused);
    expect(log, ['open', 'close']);
    expect(t.elapsed, lessThan(sayLeftFor + const Duration(seconds: 1)));
  });

  test('during a call the connection stays (its signalling needs it)', () async {
    (c.read(activeCallProvider.notifier) as _Call).put(
      const ActiveCallState(phase: CallPhase.connected, callId: 'c', groupIdHex: 'g'),
    );
    await bg().onLifecycle(AppLifecycleState.paused);
    await bg().onLifecycle(AppLifecycleState.resumed);
    expect(log, isEmpty);
  });

  // ADR-040 fallback: Android "always connected" keeps the connection.
  test('"always connected" (Android without ntfy): stays connected, on the long heartbeat', () async {
    stay = true;
    await bg().onLifecycle(AppLifecycleState.hidden);
    await bg().onLifecycle(AppLifecycleState.paused);
    expect(log, ['bg'], reason: 'no close; told once');
    expect(bg().background, isTrue);
    await bg().onLifecycle(AppLifecycleState.inactive);
    await bg().onLifecycle(AppLifecycleState.resumed);
    expect(log, ['bg', 'fg'], reason: 'back on screen: the short heartbeat, nothing to reopen');
    expect(bg().background, isFalse);
  });

  test('a call off screen keeps the short heartbeat; its end goes back to the long one', () async {
    stay = true;
    bg(); // listening for calls from here
    await bg().onLifecycle(AppLifecycleState.paused);
    expect(log, ['bg']);
    call(true); // answered from the lock screen, screen still off
    await Future<void>.delayed(Duration.zero);
    expect(log, ['bg', 'fg']);
    call(false);
    await Future<void>.delayed(Duration.zero);
    expect(log, ['bg', 'fg', 'bg']);
  });

  test('a call started in the background never switches to the long heartbeat', () async {
    stay = true;
    call(true);
    await bg().onLifecycle(AppLifecycleState.paused);
    expect(log, isEmpty);
  });

  test('iPhone / "always connected" off: never the long heartbeat (the server would count a frozen app online)', () async {
    call(true);
    await bg().onLifecycle(AppLifecycleState.paused);
    call(false);
    await Future<void>.delayed(Duration.zero);
    expect(log, isEmpty);
    expect(bg().background, isFalse);
  });

  test('started with no screen: the long heartbeat until the screen opens', () async {
    stay = true;
    await bg().startedWithoutScreen(null);
    expect(log, ['bg']);
    await bg().onLifecycle(AppLifecycleState.resumed);
    expect(log, ['bg', 'fg']);
  });

  test('the screen came up before the connection: no background heartbeat', () async {
    stay = true;
    await bg().onLifecycle(AppLifecycleState.resumed);
    await bg().startedWithoutScreen(AppLifecycleState.resumed);
    expect(log, isEmpty);
  });
}
