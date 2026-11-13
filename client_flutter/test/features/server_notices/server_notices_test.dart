// ADR-077 — the "Server" chat: only administrators see it, new notices
// come in, opening it marks them read, a "not an administrator" answer
// stops the asking.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/admin_notices.dart';
import 'package:sinhron/core/app_notice.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/server_notices/server_notices.dart';
import 'package:sinhron/l10n/l10n.dart';
import 'package:sinhron/widgets/ds_page_route.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

Widget host(List<Override> overrides, Widget child, {bool poll = false}) => ProviderScope(
  overrides: [
    hapticsProvider.overrideWithValue(Haptics(() => false)),
    adminNoticesPollProvider.overrideWithValue(poll),
    ...overrides,
  ],
  child: Localizations(
    locale: const Locale('ru'),
    delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 900)),
        child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => child)),
      ),
    ),
  ),
);

AdminNotice n(int id, String kind, String text) =>
    AdminNotice(id: id, kind: adminNoticeKind(kind), text: text, at: DateTime(2026, 10, 24, 9, id));

void main() {
  setUp(() {
    DsHaptics.enabled = false;
    appNotice.value = '';
  });

  test('time: today — hours, before — with the date', () {
    final now = DateTime(2026, 10, 24, 18);
    expect(adminNoticeTime(DateTime(2026, 10, 24, 9, 5), now), '09:05');
    expect(adminNoticeTime(DateTime(2026, 10, 23, 23, 59), now), '23.10 23:59');
    expect(adminNoticeKind('nonsense'), AdminNoticeKind.ok);
  });

  testWidgets('administrator: row with unread, the chat marks them read', (t) async {
    t.view.physicalSize = const Size(390, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = MemoryStore()..map[kAdminNoticesReadKey] = '1';
    final asked = <int>[];
    var batches = [
      [n(1, 'ok', '✅ Память: снова в норме.'), n(2, 'alert', '⚠️ Мало памяти: занято 95 %.\nвторая строка')],
      [n(3, 'report', '🚩 Новая жалоба № 4: спам')],
    ];
    late ProviderContainer c;
    await t.pumpWidget(
      host(
        [
          settingsStoreProvider.overrideWithValue(store),
          adminNoticesFetchProvider.overrideWithValue((after) async {
            asked.add(after);
            return batches.isEmpty ? <AdminNotice>[] : batches.removeAt(0);
          }),
        ],
        Consumer(
          builder: (context, ref, _) {
            c = ProviderScope.containerOf(context);
            return ServerNoticesRow(
              onOpen: () => Navigator.of(context).push(
                DsPageRoute<void>(builder: (ctx) => ServerNoticesScreen(onBack: () => Navigator.of(ctx).pop())),
              ),
            );
          },
        ),
      ),
    );
    expect(find.byKey(const ValueKey('server-notices-row')), findsNothing, reason: 'not known yet');

    await c.read(adminNoticesProvider.notifier).refresh();
    await t.pumpAndSettle();
    expect(find.text('Сервер'), findsOneWidget);
    expect(find.text('⚠️ Мало памяти: занято 95 %.'), findsOneWidget, reason: 'first line of the last notice');
    expect(c.read(adminNoticesProvider).unread, 1, reason: 'notice 1 was read before');

    await t.tap(find.byKey(const ValueKey('server-notices-row')));
    await t.pumpAndSettle();
    expect(asked, [0, 2], reason: 'opening asks for what is new');
    expect(find.text('🚩 Новая жалоба № 4: спам'), findsOneWidget);
    expect(find.text('⚠️ Мало памяти: занято 95 %.\nвторая строка'), findsOneWidget);
    expect(c.read(adminNoticesProvider).unread, 0);
    expect(store.map[kAdminNoticesReadKey], '3');
  });

  testWidgets('not an administrator: no row, and no more asking', (t) async {
    var asks = 0;
    late ProviderContainer c;
    await t.pumpWidget(
      host(
        [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          adminNoticesFetchProvider.overrideWithValue((after) async {
            asks++;
            return null;
          }),
        ],
        Consumer(
          builder: (context, ref, _) {
            c = ProviderScope.containerOf(context);
            return const ServerNoticesRow();
          },
        ),
      ),
    );
    await c.read(adminNoticesProvider.notifier).refresh();
    await c.read(adminNoticesProvider.notifier).refresh();
    await t.pumpAndSettle();
    expect(asks, 1);
    expect(find.byKey(const ValueKey('server-notices-row')), findsNothing);
  });

  testWidgets('offline: quiet, the next ask works', (t) async {
    var fail = true;
    late ProviderContainer c;
    await t.pumpWidget(
      host(
        [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          adminNoticesFetchProvider.overrideWithValue((after) async {
            if (fail) throw StateError('offline');
            return [n(1, 'report', '🚩 Новая жалоба № 1: спам')];
          }),
        ],
        Consumer(
          builder: (context, ref, _) {
            c = ProviderScope.containerOf(context);
            return const ServerNoticesRow();
          },
        ),
      ),
    );
    await c.read(adminNoticesProvider.notifier).refresh();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('server-notices-row')), findsNothing);
    fail = false;
    await c.read(adminNoticesProvider.notifier).refresh();
    await t.pumpAndSettle();
    expect(find.text('🚩 Новая жалоба № 1: спам'), findsOneWidget);
  });

  testWidgets('the row asks on connect and every minute while connected, not offline', (t) async {
    final asked = <int>[];
    late ProviderContainer c;
    await t.pumpWidget(
      host(
        [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          adminNoticesFetchProvider.overrideWithValue((after) async {
            asked.add(after);
            return <AdminNotice>[];
          }),
        ],
        Consumer(
          builder: (context, ref, _) {
            c = ProviderScope.containerOf(context);
            return const ServerNoticesRow();
          },
        ),
        poll: true,
      ),
    );
    await t.pump();
    expect(asked, isEmpty, reason: 'not connected yet');
    c.read(netStatusProvider.notifier).set(NetStatus.connected);
    await t.pump();
    expect(asked, [0]);
    await t.pump(kAdminNoticesEvery);
    expect(asked, [0, 0]);
    c.read(netStatusProvider.notifier).set(NetStatus.disconnected);
    await t.pump(kAdminNoticesEvery * 3);
    expect(asked.length, 2, reason: 'no asking while offline');
    c.read(netStatusProvider.notifier).set(NetStatus.connected);
    await t.pump();
    expect(asked.length, 3);
    // The row goes away with its timer (no pending timer at the end).
    await t.pumpWidget(const SizedBox());
  });
}
