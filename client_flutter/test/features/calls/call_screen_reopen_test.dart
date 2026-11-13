// 2026-10-16 UI audit: the call screen, reopened from the call bar, showed
// 00:00 and "mic on" though the call ran a minute with the mic off.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/call_screen.dart';

void main() {
  testWidgets('a reopened call screen shows the call\'s own time and mute', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: CallScreen(
              contactName: 'Мама',
              initialState: CallState.active,
              connectedAt: DateTime.now().subtract(const Duration(seconds: 65)),
              muted: true,
              onToggleMute: (_) {},
            ),
          ),
        ),
      ),
    );
    await t.pump(const Duration(seconds: 1));
    expect(find.textContaining('01:0'), findsOneWidget);
    expect(find.text('Unmute'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
}
