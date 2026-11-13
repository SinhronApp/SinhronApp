// "Report a problem" (owner, 2026-10-22): one text file — the person's
// words, the phone's facts, the journal for the last hour.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/report_problem/problem_report.dart';
import 'package:sinhron/features/report_problem/report_problem_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

class _Net extends NetService {
  _Net(super.ref);
  @override
  String? get httpBaseUrl => 'https://chat.example';
}

class _Push implements PushPlatform {
  @override
  Future<String> status() async => 'authorized';
  @override
  Future<(String, bool)?> lastVoipToken() async => ('abcd', false);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class _Store implements SettingsStore {
  @override
  Future<String?> get(String key) async => null;
  @override
  Future<void> set(String key, String value) async {}
}

void main() {
  test("the phone's facts come with nobody listening (it awaited, then its Ref was gone — 0.9.0)", () async {
    final c = ProviderContainer(
      overrides: [
        netServiceProvider.overrideWith(_Net.new),
        pushPlatformProvider.overrideWithValue(_Push()),
        settingsStoreProvider.overrideWithValue(_Store()),
      ],
    );
    addTearDown(c.dispose);
    final facts = await c.refresh(problemReportFactsProvider.future).timeout(const Duration(seconds: 5));
    final keys = facts.map((f) => f.$1).toList();
    expect(keys, containsAll(['Версия', 'Сервер', 'Уведомления', 'Push для звонков', 'Входящие звонки']));
    expect(facts.firstWhere((f) => f.$1 == 'Сервер').$2, 'https://chat.example');
    expect(facts.firstWhere((f) => f.$1 == 'Push для звонков').$2, 'APNs / PushKit', reason: 'kind only, never the token');
    // Again — a second report right after.
    expect(await c.refresh(problemReportFactsProvider.future).timeout(const Duration(seconds: 5)), isNotEmpty);
  });

  test('the report: note, facts, both journals', () {
    final r = buildProblemReport(
      note: '  звонок без звука ',
      facts: const [('Версия', '0.8.0 (202610221200)'), ('VPN', 'нет')],
      app: [(at: DateTime(2026, 10, 22, 12, 1, 2), text: '[livekit] connected to room=ababab…')],
      native: [(at: DateTime(2026, 10, 22, 12, 0, 59), text: '[android] fcm: push call (priority 1/1, visible=false)')],
      now: DateTime(2026, 10, 22, 12, 5),
    );
    expect(r, contains('Что случилось:\nзвонок без звука\n'));
    expect(r, contains('Версия: 0.8.0 (202610221200)'));
    expect(r, contains('12:01:02  [livekit] connected to room=ababab…'));
    expect(r, contains('12:00:59  [android] fcm: push call'));
  });

  test('push routes go in by kind, never the token', () {
    expect(pushRouteKind('fcm:secret-token'), 'Google (FCM)');
    expect(pushRouteKind('https://ntfy.example/up123'), 'ntfy');
    expect(pushRouteKind('a1b2c3'), 'APNs / PushKit');
    expect(pushRouteKind(null), 'нет');
  });

  testWidgets('the screen: note → preview → send / copy hand the report on', (t) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final sent = <String>[], copied = <String>[];
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 1000)),
          child: Localizations(
            locale: const Locale('en'),
            delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => ReportProblemScreen(
                      build: (note) async => 'REPORT:$note',
                      onSend: (r) async {
                        sent.add(r);
                        return true;
                      },
                      onCopy: (r) async => copied.add(r),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('No message text, names or keys'), findsOneWidget);
    await t.enterText(find.byType(EditableText), 'no sound');
    await t.tap(find.byKey(const ValueKey('report-preview')));
    await t.pumpAndSettle();
    expect(find.text('REPORT:no sound'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('report-send')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('report-copy')));
    await t.pumpAndSettle();
    expect(sent, ['REPORT:no sound']);
    expect(copied, ['REPORT:no sound']);
  });

  testWidgets('a report that fails to come says so (it used to do nothing)', (t) async {
    t.view.physicalSize = const Size(390, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final sent = <String>[];
    await t.pumpWidget(
      DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: const MediaQueryData(size: Size(390, 1000)),
          child: Localizations(
            locale: const Locale('en'),
            delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => ReportProblemScreen(
                      build: (note) async => throw StateError('broken'),
                      onSend: (r) async {
                        sent.add(r);
                        return true;
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.byKey(const ValueKey('report-preview')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('report-error')), findsOneWidget);
    expect(find.textContaining('broken'), findsNothing, reason: 'no raw error text');
    expect(find.textContaining('Couldn’t put the report together'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('report-send')));
    await t.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.byKey(const ValueKey('report-error')), findsOneWidget);
  });
}
