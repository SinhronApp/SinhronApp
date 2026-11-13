// ADR-108 — the first screen's mark breathes (and stands still under Reduce
// Motion); "Setting up" takes 1.5 s, not 5.3 s.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/onboarding/setting_up_screen.dart';
import 'package:sinhron/features/onboarding/welcome_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

Widget _host(Widget child, {bool reduce = false, Size size = const Size(390, 844), bool dark = false}) => MediaQuery(
  data: MediaQueryData(size: size, disableAnimations: reduce),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: DsTheme(tokens: dark ? DsTokens.dark : DsTokens.light, isDark: dark, child: child),
  ),
);

double _markScale(WidgetTester t) =>
    t.widget<ScaleTransition>(find.byKey(const ValueKey('welcome-mark'))).scale.value;

void main() {
  testWidgets('Welcome: the mark breathes — gently', (t) async {
    await t.pumpWidget(_host(const WelcomeScreen()));
    await t.pump(const Duration(milliseconds: 1600));
    final mid = _markScale(t);
    expect(mid, greaterThan(1.0));
    expect(mid, lessThanOrEqualTo(1.05));
    await t.pump(const Duration(milliseconds: 1000));
    expect(_markScale(t), isNot(mid));
  });

  testWidgets('Welcome: under Reduce Motion the mark stands still and everything is shown at once', (t) async {
    await t.pumpWidget(_host(const WelcomeScreen(), reduce: true));
    expect(_markScale(t), 1.0);
    await t.pumpAndSettle(); // nothing is animating
    expect(_markScale(t), 1.0);
    expect(t.widget<FadeTransition>(find.byType(FadeTransition).first).opacity.value, 1.0);
  });

  testWidgets('Welcome: dark theme and an iPad lay out without overflow; buttons keep a phone width', (t) async {
    t.view.physicalSize = const Size(1024, 1366);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var started = 0;
    await t.pumpWidget(
      _host(WelcomeScreen(onGetStarted: () => started++, onTerms: () {}), size: const Size(1024, 1366), dark: true),
    );
    await t.pump(const Duration(seconds: 1));
    expect(t.takeException(), isNull);
    final terms = t.getSize(find.byKey(const ValueKey('welcome-terms')));
    expect(terms.width, lessThanOrEqualTo(440));
    await t.tap(find.text(lookupAppL10n(Locale(currentLanguage)).getStarted));
    expect(started, 1);
    await t.pump(const Duration(milliseconds: 200));
  });

  testWidgets('Welcome: VoiceOver hears the name as a header and the terms as a link', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(_host(WelcomeScreen(onTerms: () {})));
    await t.pump(const Duration(seconds: 1));
    expect(t.getSemantics(find.text('Sinhron')).flagsCollection.isHeader, isTrue);
    expect(t.getSemantics(find.byKey(const ValueKey('welcome-terms'))).flagsCollection.isLink, isTrue);
    expect(find.bySemanticsLabel(RegExp('.')).evaluate(), isNotEmpty);
    final l = lookupAppL10n(Locale(currentLanguage));
    for (final label in [l.getStarted, l.linkDevice, l.restoreFromKey]) {
      expect(t.getSemantics(find.text(label)).flagsCollection.isButton, isTrue, reason: label);
    }
    handle.dispose();
  });

  testWidgets('Setting up: done in 1.5 s, not sooner than its four steps', (t) async {
    var done = 0;
    await t.pumpWidget(_host(SettingUpScreen(onFinished: () => done++)));
    await t.pump(const Duration(milliseconds: 1400));
    expect(done, 0);
    await t.pump(const Duration(milliseconds: 150));
    expect(done, 1);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Setting up: under Reduce Motion the arc stands still, the steps still finish', (t) async {
    var done = 0;
    await t.pumpWidget(_host(SettingUpScreen(onFinished: () => done++), reduce: true));
    await t.pump(const Duration(milliseconds: 1550));
    expect(done, 1);
    expect(t.hasRunningAnimations, isFalse);
  });
}
