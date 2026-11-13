// Bug 2026-10-16 (owner: "push doesn't come; with the app closed messages may
// not arrive"). iOS freezes a backgrounded app but leaves its socket open;
// the server kept counting us online for up to its idle timeout, sent new
// messages into the frozen connection and no push. Now the connection
// closes when the app leaves the screen — the server sees us offline at once
// and pushes (ADR-038) — and opens again when the app comes back (the server
// replays everything after our cursor). Not during a call: its signalling
// needs the connection (CallKit keeps the app running). Not on Android with
// "always connected" on (ADR-040 fallback without ntfy): there staying
// connected is the point.
//
// Battery 2026-10-18 (owner: does "always connected" drain the battery?) —
// every heartbeat wakes the phone's mobile radio. While that Android
// connection is off screen and no call runs, it is told it's in the
// background: a heartbeat every 120 s instead of 20 s (sinhron_net
// `Keepalive`; the server agrees per session). On screen or in a call:
// 20 s again, with a heartbeat at once. A network change (Wi-Fi ↔ mobile,
// channel `dev.sinhron/network`, `NetworkWatch.kt`) reconnects at once.
//
// ADR-057 — a push woke the app off screen (`push_wake.dart`): the
// connection opens for a few seconds ([openForPush]) and closes again
// ([closeAfterPush]) — unless the screen came, a call rings or runs, or
// "always connected" is on.
//
// ADR-066 — a reply typed into a notification (both platforms,
// `notification_reply.dart`) holds the connection open the same way
// ([openForReply] / [closeAfterReply]); several may overlap.
//
// Presence 2026-10-19 — closing used to race the "left" message (ADR-031):
// the socket went first, contacts saw "online" for minutes. The close now
// waits for "left" ([sayLeftProvider], at most [sayLeftFor]).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/calls/active_call_provider.dart';
import 'providers/presence.dart' show presenceProvider;
import 'push.dart' show stayConnectedInBackgroundProvider;
import '../src/rust/api/simple.dart' as core;
import 'session.dart';

Future<void> _noBackground(bool _) async {}

Future<void> _noRefresh() async {}

/// Closing / reopening the connection, and its heartbeat mode (faked in
/// tests).
class ConnectionSwitch {
  const ConnectionSwitch({
    required this.close,
    required this.open,
    this.background = _noBackground,
    this.refresh = _noRefresh,
  });
  final Future<void> Function() close;
  final Future<void> Function() open;
  final Future<void> Function(bool on) background;

  /// A new socket for the open connection (it resumes from what the app
  /// consumed — what a dead socket swallowed comes again).
  final Future<void> Function() refresh;
}

final connectionSwitchProvider = Provider<ConnectionSwitch>(
  (ref) => ConnectionSwitch(
    close: core.netShutdown,
    open: () => ref.read(sessionProvider).reconnect(),
    background: (on) => core.netSetBackground(background: on),
    refresh: core.netNetworkChanged,
  ),
);

/// ADR-031 — tell contacts "left" before the connection closes (faked in
/// tests). Nothing when presence is off or "online" was never said.
final sayLeftProvider = Provider<Future<void> Function()>((ref) => () => ref.read(presenceProvider).offline());

/// How long the close waits for "left" — iOS freezes the app within seconds.
const sayLeftFor = Duration(seconds: 3);

class BackgroundConnection {
  BackgroundConnection(this._ref) {
    // A call that starts or ends off screen changes the heartbeat too.
    _ref.listen<bool>(activeCallProvider.select((s) => s.isActive), (_, _) => unawaited(_applyMode()));
  }
  final Ref _ref;
  bool _closed = false;
  bool _away = false;
  bool _background = false;
  bool _forPush = false;
  int _replies = 0;

  bool get closed => _closed;

  /// ADR-057 — open off screen only because a push woke the app (ADR-066:
  /// or a reply from a notification goes out): messages that come now get
  /// system notifications drawn by the app — the server sees this phone
  /// connected and sends no push for them.
  bool get openForAPush => _forPush || _replies > 0;

  /// ADR-057 — a push woke the app with no screen (or one in the
  /// background): open the connection. Nothing when the app is on screen.
  Future<void> openForPush() async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    _away = true;
    _forPush = true;
    await _applyMode();
    if (_closed) {
      _closed = false;
      try {
        await _ref.read(connectionSwitchProvider).open();
      } catch (_) {}
      return;
    }
    // A screen-less start: the first connection of this engine (a no-op
    // when it is already up).
    try {
      await _ref.read(pushResumeProvider)();
    } catch (_) {}
  }

  /// ADR-057 — the woken connection has fetched: close it again so the
  /// server goes back to pushing (a frozen open socket would swallow them).
  Future<void> closeAfterPush() async {
    _forPush = false;
    if (_replies > 0) return; // ADR-066 — a reply still needs it
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    if (_closed || _ref.read(activeCallProvider).isActive || _ref.read(stayConnectedInBackgroundProvider)()) return;
    _closed = true;
    try {
      await _ref.read(connectionSwitchProvider).close();
    } catch (_) {}
  }

  /// ADR-066 — a reply from a notification is about to go out: open the
  /// connection off screen (nothing when the app is on screen).
  Future<void> openForReply() async {
    _replies++;
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    _away = true;
    await _applyMode();
    if (_closed) {
      _closed = false;
      try {
        await _ref.read(connectionSwitchProvider).open();
      } catch (_) {}
      return;
    }
    try {
      await _ref.read(pushResumeProvider)();
    } catch (_) {}
  }

  /// ADR-066 — that reply went (or gave up): the last one closes the
  /// connection again, as after a push — unless a push still uses it.
  Future<void> closeAfterReply() async {
    if (_replies > 0) _replies--;
    if (_replies > 0 || _forPush) return;
    await closeAfterPush();
  }

  /// The connection is on the long background heartbeat (Android "always
  /// connected", off screen, no call).
  bool get background => _background;

  Future<void> _applyMode() async {
    final on = _away && !_ref.read(activeCallProvider).isActive && _ref.read(stayConnectedInBackgroundProvider)();
    if (on == _background) return;
    _background = on;
    try {
      await _ref.read(connectionSwitchProvider).background(on);
    } catch (_) {}
  }

  Future<void> onLifecycle(AppLifecycleState state) async {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _away = true;
        await _applyMode();
        if (_closed || _ref.read(activeCallProvider).isActive || _ref.read(stayConnectedInBackgroundProvider)()) {
          return;
        }
        _closed = true;
        try {
          await _ref.read(sayLeftProvider)().timeout(sayLeftFor);
        } catch (_) {}
        try {
          await _ref.read(connectionSwitchProvider).close();
        } catch (_) {}
      case AppLifecycleState.resumed:
        _away = false;
        _forPush = false;
        await _applyMode();
        if (!_closed) return;
        _closed = false;
        try {
          await _ref.read(connectionSwitchProvider).open();
        } catch (_) {}
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break; // Control Centre, a call banner — still here
    }
  }

  /// Android started the app for "always connected" with no screen
  /// (`connectWithoutScreen`): no lifecycle event comes until one opens.
  Future<void> startedWithoutScreen(AppLifecycleState? now) async {
    if (now == AppLifecycleState.resumed) return; // the screen came first
    _away = true;
    await _applyMode();
  }
}

final backgroundConnectionProvider = Provider<BackgroundConnection>((ref) => BackgroundConnection(ref));

/// The first connection of a screen-less engine (faked in tests).
final pushResumeProvider = Provider<Future<void> Function()>((ref) => () => ref.read(sessionProvider).resume());

/// Android: the phone's default network changed — the connection's socket
/// belongs to the old one; reconnect now (`NetworkWatch.kt`). Set up once
/// from `main`, so it also works with no screen.
void watchNetworkChanges() {
  if (!Platform.isAndroid) return;
  const MethodChannel('dev.sinhron/network').setMethodCallHandler((call) async {
    if (call.method == 'changed') await core.netNetworkChanged();
    return null;
  });
}

/// Mounted once at the app root; renders nothing.
class BackgroundConnectionKeeper extends ConsumerStatefulWidget {
  const BackgroundConnectionKeeper({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<BackgroundConnectionKeeper> createState() => _BackgroundConnectionKeeperState();
}

class _BackgroundConnectionKeeperState extends ConsumerState<BackgroundConnectionKeeper> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Mounted after the app came on screen (the event went by): say so —
    // a screen-less start left the connection on the background heartbeat.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      unawaited(ref.read(backgroundConnectionProvider).onLifecycle(AppLifecycleState.resumed));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(ref.read(backgroundConnectionProvider).onLifecycle(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
