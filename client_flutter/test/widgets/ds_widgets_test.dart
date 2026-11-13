// Golden tests for the remaining Ds-widgets that didn't have golden
// coverage yet. Closes §15.3 spec requirement: every Ds-widget has a
// golden snapshot.
//
// Already covered elsewhere:
//   - DsAvatar, DsChatRow       → test/widget_test.dart
//   - DsButton, DsTextField,
//     DsAppBar                  → test/widgets/atoms_test.dart
//
// Covered here:
//   - DsHeader                  → chat-list header (avatar + title + 2 icons)
//   - DsFilterPill + DsFilters  → all/unread/groups pills
//   - DsTabBar                  → 4-tab bottom nav with badge
//   - DsIcon                    → all 14 shapes (grid)
//   - DsIconButton              → plain + with badge
//   - DsMnemonicGrid            → 24-word grid revealed state
//   - DsShimmer + DsSkel + DsSkelCircle → shimmer composition single frame
//
// Goldens live in test/widgets/goldens/widgets/. Regenerate with:
//   fvm flutter test --update-goldens test/widgets/ds_widgets_test.dart

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/widgets/ds_filter_pill.dart';
import 'package:sinhron/widgets/ds_header.dart';
import 'package:sinhron/widgets/ds_icon.dart';
import 'package:sinhron/widgets/ds_icon_button.dart';
import 'package:sinhron/widgets/ds_mnemonic_grid.dart';
import 'package:sinhron/widgets/ds_shimmer.dart';
import 'package:sinhron/widgets/ds_tab_bar.dart';

import '../test_harness.dart';

void main() {
  setUpAll(() async {
    await loadAppFonts();
  });

  // ───────────────────────────────────────────────────────────────────
  // DsHeader
  // ───────────────────────────────────────────────────────────────────
  group('DsHeader', () {
    testWidgets('chats title light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 80),
          child: const SizedBox(
            width: 390,
            child: DsHeader(userName: 'Vera Kuznetsova', title: 'Chats'),
          ),
        ),
      );
      await expectLater(
        find.byType(DsHeader),
        matchesGoldenFile('goldens/widgets/ds_header_chats_light.png'),
      );
    });

    testWidgets('chats title dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(390, 80),
          child: const SizedBox(
            width: 390,
            child: DsHeader(userName: 'Vera Kuznetsova', title: 'Chats'),
          ),
        ),
      );
      await expectLater(
        find.byType(DsHeader),
        matchesGoldenFile('goldens/widgets/ds_header_chats_dark.png'),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // DsFilterPill — 4 cases: inactive/active × no-count/with-count
  // ───────────────────────────────────────────────────────────────────
  group('DsFilterPill', () {
    testWidgets('inactive no count', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(140, 50),
          child: const DsFilterPill(label: 'All'),
        ),
      );
      await expectLater(
        find.byType(DsFilterPill),
        matchesGoldenFile('goldens/widgets/ds_filter_pill_inactive.png'),
      );
    });

    testWidgets('active no count', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(140, 50),
          child: const DsFilterPill(label: 'All', active: true),
        ),
      );
      await expectLater(
        find.byType(DsFilterPill),
        matchesGoldenFile('goldens/widgets/ds_filter_pill_active.png'),
      );
    });

    testWidgets('inactive with count', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(160, 50),
          child: const DsFilterPill(label: 'Unread', count: 7),
        ),
      );
      await expectLater(
        find.byType(DsFilterPill),
        matchesGoldenFile('goldens/widgets/ds_filter_pill_inactive_count.png'),
      );
    });

    testWidgets('active with count', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(160, 50),
          child: const DsFilterPill(label: 'Groups', active: true, count: 4),
        ),
      );
      await expectLater(
        find.byType(DsFilterPill),
        matchesGoldenFile('goldens/widgets/ds_filter_pill_active_count.png'),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // DsFilters — composed strip
  // ───────────────────────────────────────────────────────────────────
  testWidgets('DsFilters composed', (tester) async {
    await tester.pumpWidget(
      wrapForGolden(
        isDark: false,
        size: const Size(390, 60),
        child: const SizedBox(
          width: 390,
          child: DsFilters(
            filters: ['All', 'Unread', 'Groups', 'Archived'],
            active: 'All',
            counts: {'Unread': 7, 'Groups': 4},
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(DsFilters),
      matchesGoldenFile('goldens/widgets/ds_filters_light.png'),
    );
  });

  // ───────────────────────────────────────────────────────────────────
  // DsTabBar — 4 tabs + chats-badge
  // ───────────────────────────────────────────────────────────────────
  group('DsTabBar', () {
    const items = <DsTabItem>[
      DsTabItem(
        id: DsTabId.chats,
        label: 'Chats',
        icon: DsIconShape.tabChats,
        badge: 3,
      ),
      DsTabItem(id: DsTabId.calls, label: 'Calls', icon: DsIconShape.tabCalls),
      DsTabItem(
        id: DsTabId.contacts,
        label: 'Contacts',
        icon: DsIconShape.tabContacts,
      ),
      DsTabItem(
        id: DsTabId.settings,
        label: 'Settings',
        icon: DsIconShape.tabSettings,
      ),
    ];

    testWidgets('chats active with badge light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 100),
          child: const SizedBox(
            width: 390,
            child: DsTabBar(
              active: DsTabId.chats,
              items: items,
              safeBottomPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(); // the open tab's icon springs in
      await expectLater(
        find.byType(DsTabBar),
        matchesGoldenFile('goldens/widgets/ds_tab_bar_chats_active.png'),
      );
    });

    testWidgets('settings active dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(390, 100),
          child: const SizedBox(
            width: 390,
            child: DsTabBar(
              active: DsTabId.settings,
              items: items,
              safeBottomPadding: EdgeInsets.zero,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle(); // the open tab's icon springs in
      await expectLater(
        find.byType(DsTabBar),
        matchesGoldenFile('goldens/widgets/ds_tab_bar_settings_dark.png'),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // DsIcon — all 14 shapes in one grid
  // ───────────────────────────────────────────────────────────────────
  testWidgets('DsIcon all shapes light', (tester) async {
    await tester.pumpWidget(
      wrapForGolden(
        isDark: false,
        size: const Size(320, 200),
        child: Builder(
          builder: (ctx) {
            final color = DsTheme.of(ctx).text;
            return SizedBox(
              width: 320,
              height: 200,
              child: Wrap(
                spacing: 14,
                runSpacing: 14,
                alignment: WrapAlignment.center,
                children: [
                  for (final shape in DsIconShape.values)
                    DsIcon(shape: shape, size: 24, color: color),
                ],
              ),
            );
          },
        ),
      ),
    );
    await expectLater(
      find.byType(Wrap),
      matchesGoldenFile('goldens/widgets/ds_icon_all_shapes.png'),
    );
  });

  // ───────────────────────────────────────────────────────────────────
  // DsIconButton
  // ───────────────────────────────────────────────────────────────────
  group('DsIconButton', () {
    testWidgets('plain', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(70, 70),
          child: const DsIconButton(shape: DsIconShape.search),
        ),
      );
      await expectLater(
        find.byType(DsIconButton),
        matchesGoldenFile('goldens/widgets/ds_icon_button_plain.png'),
      );
    });

    testWidgets('with badge', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(70, 70),
          child: const DsIconButton(shape: DsIconShape.tabChats, badge: 12),
        ),
      );
      await expectLater(
        find.byType(DsIconButton),
        matchesGoldenFile('goldens/widgets/ds_icon_button_badge.png'),
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────
  // DsMnemonicGrid — revealed state (blur+BackdropFilter is unreliable
  // in goldens; reveal-state captures the actual word layout we care
  // about)
  // ───────────────────────────────────────────────────────────────────
  testWidgets('DsMnemonicGrid revealed light', (tester) async {
    const words = [
      'archer',
      'maple',
      'crisp',
      'orbit',
      'lentil',
      'voyage',
      'fabric',
      'quartz',
      'mellow',
      'thorn',
      'cradle',
      'rhythm',
      'silver',
      'breeze',
      'paddle',
      'ember',
      'glacier',
      'plume',
      'echo',
      'forest',
      'beacon',
      'tide',
      'kindle',
      'aurora',
    ];
    await tester.pumpWidget(
      wrapForGolden(
        isDark: false,
        size: const Size(360, 720),
        child: const Padding(
          padding: EdgeInsets.all(20),
          child: SizedBox(
            width: 320,
            child: DsMnemonicGrid(words: words, revealed: true),
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(DsMnemonicGrid),
      matchesGoldenFile('goldens/widgets/ds_mnemonic_grid_revealed.png'),
    );
  });

  // ───────────────────────────────────────────────────────────────────
  // DsShimmer + DsSkel + DsSkelCircle — single-frame snapshot
  // (the animation sweep is captured at frame 0; that's deterministic.)
  // ───────────────────────────────────────────────────────────────────
  testWidgets('DsShimmer composed line light', (tester) async {
    await tester.pumpWidget(
      wrapForGolden(
        isDark: false,
        size: const Size(360, 100),
        child: const SizedBox(
          width: 320,
          height: 70,
          child: DsShimmer(
            child: Row(
              children: [
                DsSkelCircle(size: 46),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      DsSkel(width: 160, height: 12),
                      SizedBox(height: 8),
                      DsSkel(width: 220, height: 10),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // The shimmer keeps ticking; pump a fixed delta so the test settles on
    // a deterministic frame.
    await tester.pump(const Duration(milliseconds: 0));
    await expectLater(
      find.byType(DsShimmer),
      matchesGoldenFile('goldens/widgets/ds_shimmer_composed.png'),
    );
  });
}
