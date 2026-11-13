import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/widgets/app_notice_host.dart';

void main() {
  Widget host() => const DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: MediaQueryData(size: Size(390, 800)),
      child: Directionality(textDirection: TextDirection.ltr, child: AppNoticeHost()),
    ),
  );

  tearDown(() => appNotice.value = '');

  test('errors are told apart from notes', () {
    expect(toneOf('Profile save failed'), NoticeTone.error);
    expect(toneOf('Не удалось начать чат'), NoticeTone.error);
    expect(toneOf('Starting chat…'), NoticeTone.info);
  });

  testWidgets('a confirmation shows as a pill and hides itself; the same text twice shows twice', (t) async {
    await t.pumpWidget(host());
    expect(find.text('Key copied'), findsNothing);

    showDone('Key copied');
    await t.pump();
    expect(find.text('Key copied'), findsOneWidget);

    await t.pump(noticeDuration(NoticeTone.done));
    await t.pumpAndSettle();
    expect(find.text('Key copied'), findsNothing, reason: 'gone without a tap');

    showDone('Key copied');
    await t.pump();
    expect(find.text('Key copied'), findsOneWidget);
    await t.pump(noticeDuration(NoticeTone.done));
    await t.pumpAndSettle();
  });

  testWidgets('a background error stays readable, then clears itself and appNotice', (t) async {
    await t.pumpWidget(host());
    appNotice.value = 'Profile save failed';
    await t.pump();
    expect(find.text('Profile save failed'), findsOneWidget);

    await t.pump(noticeDuration(NoticeTone.info));
    expect(find.text('Profile save failed'), findsOneWidget, reason: 'errors stay longer than notes');

    await t.pump(noticeDuration(NoticeTone.error));
    await t.pumpAndSettle();
    expect(find.text('Profile save failed'), findsNothing);
    expect(appNotice.value, isEmpty);
  });

  testWidgets('a tap hides it at once', (t) async {
    await t.pumpWidget(host());
    appNotice.value = 'Starting chat…';
    await t.pump();
    await t.tap(find.byKey(const ValueKey('app-notice')));
    await t.pumpAndSettle();
    expect(find.text('Starting chat…'), findsNothing);
    expect(appNotice.value, isEmpty);
  });
}
