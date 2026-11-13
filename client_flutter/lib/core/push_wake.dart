// ADR-057 — a push woke the app (Android, Google push): connect, fetch what
// came, let the app draw its own notifications ("name: text" — it has the
// messages decrypted; `maybeShowBanner`) or take the call's invite, then
// close the connection again and tell the native side (`PushWake.kt`, whose
// FCM thread keeps the process awake meanwhile).
//
// The engine may have started for this very push with no screen: main()
// calls [listenForPushWakes] — the native side remembered the wake and
// answers `takeWake`; later wakes come as `wake` events.
//
// Bug 2026-10-19 (a Samsung A40): since status 167 the
// server sends the Google push to an Android phone even while its
// connection is open. Then the message usually came down the socket first
// and the app drew "name: text" — and the push's plain "New message" came
// on top. Now the app tells the native side whether a message reached it
// ([PushPlatform.wakeDone] `handled`); and a socket that was open yet
// brought nothing may be dead without the phone knowing — it is replaced
// (Resume brings again whatever it swallowed).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/calls/active_call_provider.dart';
import 'background_connection.dart';
import 'push.dart';
import 'services/net_service.dart';

class PushWake {
  PushWake(
    this._ref, {
    this.connectWithin = const Duration(seconds: 6),
    this.linger = const Duration(seconds: 3),
    this.recent = const Duration(seconds: 30),
  });
  final Ref _ref;

  /// How long to wait for the connection.
  final Duration connectWithin;

  /// How long to stay once connected (the server replays what waited).
  final Duration linger;

  /// With the connection already open, a message that came this long
  /// before the push counts as the one it is about (the server sends both
  /// at once; the socket usually wins).
  final Duration recent;

  int _gen = 0;

  Future<void> run() async {
    final gen = ++_gen;
    final bg = _ref.read(backgroundConnectionProvider);
    final net = _ref.read(netServiceProvider);
    final started = DateTime.now();
    // Open off screen ("always connected", a call): the server sent this
    // down the socket as well.
    final live = !bg.closed && net.status == NetStatus.connected;
    final since = live ? started.subtract(recent) : started;
    var handled = false;
    try {
      await bg.openForPush();
      await _connected();
      await Future<void>.delayed(linger);
      // Not while a call rings or runs: its invite isn't a message, and
      // the call needs this socket (a zombie one is replaced on its own —
      // the server replays a ringing invite on the new one).
      if (live && !_came(net, since) && !_ref.read(activeCallProvider).isActive) {
        await _ref.read(connectionSwitchProvider).refresh();
        await _connected();
        await Future<void>.delayed(linger);
      }
      handled = _came(net, since);
    } catch (_) {}
    // A newer push owns the connection now; it closes and answers.
    if (gen != _gen) return;
    // Closed BEFORE answering: once the native side lets go, Android may
    // freeze the process with the socket still open.
    await bg.closeAfterPush();
    await _ref.read(pushPlatformProvider).wakeDone(handled: handled);
  }

  Future<void> _connected() async {
    final until = DateTime.now().add(connectWithin);
    while (_ref.read(netStatusProvider) != NetStatus.connected && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static bool _came(NetService net, DateTime since) {
    final at = net.lastPushAt;
    return at != null && !at.isBefore(since);
  }
}

final pushWakeProvider = Provider<PushWake>((ref) => PushWake(ref));

/// From main() (Android): this engine handles pushes that wake the app.
/// [canConnect] false (the chats DB is locked, the core didn't load):
/// answer at once — the native side shows the plain "New message".
Future<void> listenForPushWakes(ProviderContainer c, {required bool canConnect}) async {
  final platform = c.read(pushPlatformProvider);
  Future<void> wake() => canConnect ? c.read(pushWakeProvider).run() : platform.wakeDone();
  platform.wakes.listen((_) => unawaited(wake()));
  if (await platform.takeWake()) await wake();
}
