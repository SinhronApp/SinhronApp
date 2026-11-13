import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/live_call_screen.dart';

class _FakeCall extends ActiveCallNotifier {
  @override
  ActiveCallState build() => const ActiveCallState.idle();
  void put(ActiveCallState s) => state = s;
}

void main() {
  // Owner, 2026-10-15: "the call button does nothing". The screen opens
  // while the call is still idle (the mic is asked first) and used to
  // close itself on its first frame.
  testWidgets('opens on an idle call, closes only when a call that was going ends', (t) async {
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
              child: Navigator(
                key: nav,
                onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
          ),
        ),
      ),
    );
    nav.currentState!.push(PageRouteBuilder(pageBuilder: (_, _, _) => const LiveCallScreen(contactName: 'Вера')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.byType(LiveCallScreen), findsOneWidget, reason: 'idle at open is not "ended"');

    fake.put(const ActiveCallState(phase: CallPhase.outgoingRinging, callId: 'c1', groupIdHex: 'ab'));
    await t.pump();
    fake.put(const ActiveCallState.idle());
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(LiveCallScreen), findsNothing);
  });
}
