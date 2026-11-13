// Owner, 2026-10-18: "to get from a call to the chat I had to hang up" —
// the call screen minimises, a call bar on every screen brings it back;
// and "an incoming call with the app open: the system banner and the app's
// screen both" — the app opens its own ringing screen only when the system
// isn't showing the call.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/live_call_bar.dart';
import 'package:sinhron/features/calls/live_call_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

class _FakeCall extends ActiveCallNotifier {
  @override
  ActiveCallState build() => const ActiveCallState.idle();
  void put(ActiveCallState s) => state = s;

  final camera = <bool>[];
  @override
  Future<bool> setCameraEnabled(bool on) async {
    camera.add(on);
    return true;
  }
}

void main() {
  final ru = lookupAppL10n(const Locale('ru'));
  final t0 = DateTime(2026, 10, 18, 12);

  group('the bar says what the call is doing', () {
    test('talking: "Идёт звонок · 02:14 · вернуться", from when the sound came', () {
      final call = ActiveCallState(
        phase: CallPhase.connected,
        callId: 'c',
        connectedAt: t0,
        audioAt: t0.add(const Duration(seconds: 1)),
      );
      expect(callBarLabel(ru, call, now: t0.add(const Duration(minutes: 2, seconds: 15))), 'Идёт звонок · 02:14 · вернуться');
    });

    test('answered, no sound yet: "Соединяем…"', () {
      final call = ActiveCallState(phase: CallPhase.connected, callId: 'c', connectedAt: t0);
      expect(call.connecting, isTrue);
      expect(callBarLabel(ru, call, now: t0), 'Соединяем… · вернуться');
    });

    test('ringing, calling, ended', () {
      expect(callBarLabel(ru, const ActiveCallState(phase: CallPhase.incomingRinging)), 'Входящий звонок · ответить');
      expect(callBarLabel(ru, const ActiveCallState(phase: CallPhase.outgoingRinging)), 'Вызов… · вернуться');
      expect(callBarLabel(ru, const ActiveCallState(phase: CallPhase.ended)), 'Звонок завершён');
      final video = ActiveCallState(phase: CallPhase.connected, kind: CallKind.video, connectedAt: t0, audioAt: t0);
      expect(callBarLabel(ru, video, now: t0.add(const Duration(seconds: 5))), 'Идёт видеозвонок · 00:05 · вернуться');
    });
  });

  group('one ringing UI', () {
    const ringingSystem = ActiveCallState(phase: CallPhase.incomingRinging, callId: 'c1');
    const ringingHere = ActiveCallState(phase: CallPhase.incomingRinging, callId: 'c1', ringsInApp: true);
    const talking = ActiveCallState(phase: CallPhase.connected, callId: 'c1');

    test('the system shows it (CallKit / the call notification): no in-app screen', () {
      expect(callScreenToOpen(const ActiveCallState.idle(), ringingSystem, screenOpen: false), isFalse);
    });

    test('the app rings it itself: its screen opens once', () {
      expect(callScreenToOpen(ringingSystem, ringingHere, screenOpen: false), isTrue, reason: 'Android: app came to front');
      expect(callScreenToOpen(const ActiveCallState.idle(), ringingHere, screenOpen: false), isTrue);
      expect(callScreenToOpen(ringingHere, ringingHere, screenOpen: false), isFalse, reason: 'not again');
    });

    test('answered in the system UI → the call screen opens', () {
      expect(callScreenToOpen(ringingSystem, talking, screenOpen: false), isTrue);
      expect(callScreenToOpen(ringingSystem, talking, screenOpen: true), isFalse, reason: 'answered on our screen');
    });

    test('never over an open call screen; not for my own calls', () {
      expect(callScreenToOpen(const ActiveCallState.idle(), ringingHere, screenOpen: true), isFalse);
      const out = ActiveCallState(phase: CallPhase.outgoingRinging, callId: 'c2');
      expect(callScreenToOpen(out, const ActiveCallState(phase: CallPhase.connected, callId: 'c2'), screenOpen: false), isFalse);
    });
  });

  testWidgets('minimise → the bar on top of the app; tap → back to the call', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fake = _FakeCall();
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ProviderScope(
        overrides: [activeCallProvider.overrideWith(() => fake)],
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844), padding: EdgeInsets.only(top: 47)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: CallBarHost(
                navigatorKey: nav,
                child: Navigator(
                  key: nav,
                  onGenerateRoute: (_) => PageRouteBuilder(
                    pageBuilder: (context, _, _) => Align(
                      alignment: Alignment.topLeft,
                      child: SizedBox(key: const ValueKey('chat'), height: MediaQuery.paddingOf(context).top + 10),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('call-bar')), findsNothing, reason: 'no call');

    // A call going on, its screen open: no bar.
    fake.put(
      ActiveCallState(
        phase: CallPhase.connected,
        callId: 'c1',
        groupIdHex: 'ab',
        kind: CallKind.video,
        cameraOn: true,
        connectedAt: DateTime.now(),
      ),
    );
    nav.currentState!.push(callScreenRoute((_) => const LiveCallScreen(contactName: 'Вера')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(LiveCallScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('call-bar')), findsNothing);
    expect(find.text('Connecting…'), findsNothing, reason: 'the dots are our own');
    expect(find.byKey(const ValueKey('call-connecting')), findsOneWidget, reason: 'answered, no sound yet');

    // ⌄ — back to the app, the call goes on.
    await t.tap(find.byKey(const ValueKey('call-minimize')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    await t.pump(); // the screen is gone → the bar comes
    await t.pump(const Duration(milliseconds: 300)); // …growing in
    expect(find.byType(LiveCallScreen), findsNothing);
    expect(find.byKey(const ValueKey('call-bar')), findsOneWidget);
    expect(find.text('Connecting… · tap to return'), findsOneWidget);
    // Owner, 2026-10-18: "the camera must not close when the call is
    // minimised" — the camera belongs to the call, not to its screen.
    expect(fake.camera, isEmpty);
    expect(fake.state.cameraOn, isTrue);
    expect(t.getSize(find.byKey(const ValueKey('chat'))).height, 10, reason: 'the bar took the status bar room');

    fake.put(fake.state.copyWith(audioAt: DateTime.now().subtract(const Duration(seconds: 3))));
    await t.pump();
    expect(find.text('Video call in progress · 00:03 · tap to return'), findsOneWidget);

    // Tap → the call screen again, the bar goes.
    await t.tap(find.byKey(const ValueKey('call-bar')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(LiveCallScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('call-bar')), findsNothing);

    // The call ends: the screen closes, no bar left over.
    fake.put(const ActiveCallState.idle());
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(LiveCallScreen), findsNothing);
    expect(find.byKey(const ValueKey('call-bar')), findsNothing);
  });

  testWidgets('an incoming call on CallKit while elsewhere in the app: the bar offers to answer', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final fake = _FakeCall();
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      ProviderScope(
        overrides: [activeCallProvider.overrideWith(() => fake)],
        child: DsTheme(
          tokens: DsTokens.light,
          isDark: false,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: CallBarHost(
                navigatorKey: nav,
                child: Navigator(key: nav, onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const SizedBox())),
              ),
            ),
          ),
        ),
      ),
    );
    fake.put(const ActiveCallState(phase: CallPhase.incomingRinging, callId: 'c1', groupIdHex: 'ab'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Incoming call · tap to answer'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('call-bar')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('call-accept')), findsOneWidget, reason: 'the app screen answers too');
    expect(find.byKey(const ValueKey('call-minimize')), findsNothing, reason: 'answer or decline first');
  });
}
