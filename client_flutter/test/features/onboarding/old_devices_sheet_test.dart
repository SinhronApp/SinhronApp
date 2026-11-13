// ADR-075 — after the 24 words: "Your other devices" — disconnect one (it
// shows as disconnected), a failure says so and leaves it to try again,
// "Done" goes on. Nothing is disconnected without a tap.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/onboarding/old_devices_sheet.dart';
import 'package:sinhron/l10n/l10n.dart';

void main() {
  testWidgets('disconnect the lost phone; a failure can be retried; Done goes on', (t) async {
    t.view.physicalSize = const Size(390, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final asked = <String>[];
    var failNext = true;
    var closed = false;
    final lost = 'aa' * 32, tablet = 'bb' * 32;
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 900)),
          child: Localizations(
            locale: const Locale('en'),
            delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  pageBuilder: (ctx, _, _) => Center(
                    child: GestureDetector(
                      key: const ValueKey('open'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        await showOldDevicesSheet(
                          ctx,
                          devices: [
                            OldDevice(pkHex: lost, primary: true, lastSeenUnix: 1760000000),
                            OldDevice(pkHex: tablet, primary: false, lastSeenUnix: 1760900000),
                          ],
                          disconnect: (pk) async {
                            asked.add(pk);
                            if (failNext) {
                              failNext = false;
                              return false;
                            }
                            return true;
                          },
                        );
                        closed = true;
                      },
                      child: const SizedBox(width: 100, height: 100),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('open')));
    await t.pumpAndSettle();
    expect(find.text('Your other devices'), findsOneWidget);
    expect(find.textContaining('first device'), findsOneWidget, reason: 'the first phone is marked');
    expect(asked, isEmpty, reason: 'nothing without a tap');

    await t.tap(find.byKey(ValueKey('old-device-cut-$lost')));
    await t.pumpAndSettle();
    expect(asked, [lost]);
    expect(find.byKey(ValueKey('old-device-gone-$lost')), findsNothing, reason: 'it failed');
    expect(find.textContaining("Couldn't remove"), findsOneWidget);

    await t.tap(find.byKey(ValueKey('old-device-cut-$lost')));
    await t.pumpAndSettle();
    expect(find.byKey(ValueKey('old-device-gone-$lost')), findsOneWidget);
    expect(find.byKey(ValueKey('old-device-cut-$tablet')), findsOneWidget, reason: 'the tablet stays unless tapped');

    await t.tap(find.byKey(const ValueKey('old-devices-done')));
    await t.pumpAndSettle();
    expect(closed, isTrue);
    expect(asked, [lost, lost]);
  });
}
