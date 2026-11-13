// Golden tests for WU 1 atoms: DsButton, DsTextField, DsAppBar.
//
// Per spec §15.3, each Ds* widget gets a golden snapshot. These tests
// exercise the primary visual states:
//   - DsButton: 4 variants × default state + 4 states for primary
//   - DsTextField: 4 states (empty, filled, focused, mono)
//   - DsAppBar: back+title, back+step, title-only
//
// All goldens live in `test/goldens/`. Regenerate with:
//   fvm flutter test --update-goldens

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinhron/widgets/ds_app_bar.dart';
import 'package:sinhron/widgets/ds_button.dart';
import 'package:sinhron/widgets/ds_text_field.dart';

import '../test_harness.dart';

void main() {
  setUpAll(() async {
    await loadAppFonts();
  });

  // ─────────────────────────────────────────────────────────────────────
  // DsButton — 4 variants × default state (light)
  // ─────────────────────────────────────────────────────────────────────
  group('DsButton · variants', () {
    for (final entry in <(String, DsButtonVariant, String)>[
      ('primary', DsButtonVariant.primary, 'Send'),
      ('secondary', DsButtonVariant.secondary, 'Cancel'),
      ('ghost', DsButtonVariant.ghost, 'Skip'),
      ('danger', DsButtonVariant.danger, 'Delete'),
    ]) {
      final (name, variant, label) = entry;
      testWidgets('$name default light', (tester) async {
        await tester.pumpWidget(
          wrapForGolden(
            isDark: false,
            size: const Size(280, 80),
            child: SizedBox(
              width: 240,
              child: DsButton(label: label, variant: variant),
            ),
          ),
        );
        await expectLater(
          find.byType(DsButton),
          matchesGoldenFile('goldens/atoms/ds_button_${name}_light.png'),
        );
      });
    }
  });

  // ─────────────────────────────────────────────────────────────────────
  // DsButton — primary × 4 states (light)
  // ─────────────────────────────────────────────────────────────────────
  group('DsButton · primary states', () {
    testWidgets('default', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(280, 80),
          child: SizedBox(
            width: 240,
            child: DsButton(
              label: 'Send',
              variant: DsButtonVariant.primary,
              onPressed: () {},
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsButton),
        matchesGoldenFile('goldens/atoms/ds_button_primary_state_default.png'),
      );
    });

    testWidgets('pressed', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(280, 80),
          child: SizedBox(
            width: 240,
            child: DsButton(
              label: 'Send',
              variant: DsButtonVariant.primary,
              onPressed: () {},
              debugForcePressed: true,
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsButton),
        matchesGoldenFile('goldens/atoms/ds_button_primary_state_pressed.png'),
      );
    });

    testWidgets('disabled', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(280, 80),
          child: const SizedBox(
            width: 240,
            child: DsButton(
              label: 'Send',
              variant: DsButtonVariant.primary,
              // onPressed: null → disabled
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsButton),
        matchesGoldenFile('goldens/atoms/ds_button_primary_state_disabled.png'),
      );
    });

    testWidgets('loading', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(280, 80),
          child: SizedBox(
            width: 240,
            child: DsButton(
              label: 'Sending…',
              variant: DsButtonVariant.primary,
              onPressed: () {},
              loading: true,
            ),
          ),
        ),
      );
      // Pump 1 frame; ring animation kicks in but we capture initial position.
      await tester.pump();
      await expectLater(
        find.byType(DsButton),
        matchesGoldenFile('goldens/atoms/ds_button_primary_state_loading.png'),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // DsButton — dark theme
  // ─────────────────────────────────────────────────────────────────────
  group('DsButton · special', () {
    testWidgets('primary default dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(280, 80),
          child: SizedBox(
            width: 240,
            child: DsButton(
              label: 'Send',
              variant: DsButtonVariant.primary,
              onPressed: () {},
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsButton),
        matchesGoldenFile('goldens/atoms/ds_button_primary_dark.png'),
      );
    });

  });

  // ─────────────────────────────────────────────────────────────────────
  // DsTextField — 4 states
  // ─────────────────────────────────────────────────────────────────────
  group('DsTextField', () {
    testWidgets('empty unfocused light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(320, 100),
          child: const SizedBox(
            width: 280,
            child: DsTextField(label: 'Server', hintText: 'your-server.com'),
          ),
        ),
      );
      await expectLater(
        find.byType(DsTextField),
        matchesGoldenFile('goldens/atoms/ds_text_field_empty_light.png'),
      );
    });

    testWidgets('focused empty light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(320, 100),
          child: const SizedBox(
            width: 280,
            child: DsTextField(
              label: 'Server',
              hintText: 'your-server.com',
              debugForceFocused: true,
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsTextField),
        matchesGoldenFile('goldens/atoms/ds_text_field_focused_light.png'),
      );
    });

    testWidgets('filled mono light', (tester) async {
      final ctrl = TextEditingController(text: 'b8f2 · 41cd · 9a07 · 2e5b');
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(320, 100),
          child: SizedBox(
            width: 280,
            child: DsTextField(
              label: 'Invite token',
              controller: ctrl,
              mono: true,
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsTextField),
        matchesGoldenFile('goldens/atoms/ds_text_field_mono_filled_light.png'),
      );
    });

    testWidgets('empty unfocused dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(320, 100),
          child: const SizedBox(
            width: 280,
            child: DsTextField(
              label: 'Name',
              hintText: 'How you appear to contacts',
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(DsTextField),
        matchesGoldenFile('goldens/atoms/ds_text_field_empty_dark.png'),
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────────
  // DsAppBar — 3 configurations
  // ─────────────────────────────────────────────────────────────────────
  group('DsAppBar', () {
    testWidgets('back + title light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 56),
          child: SizedBox(
            width: 390,
            child: DsAppBar(title: 'Linked devices', onBack: () {}),
          ),
        ),
      );
      await expectLater(
        find.byType(DsAppBar),
        matchesGoldenFile('goldens/atoms/ds_app_bar_back_title_light.png'),
      );
    });

    testWidgets('back + step light', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: false,
          size: const Size(390, 56),
          child: SizedBox(
            width: 390,
            child: DsAppBar(step: '2 / 3', onBack: () {}),
          ),
        ),
      );
      await expectLater(
        find.byType(DsAppBar),
        matchesGoldenFile('goldens/atoms/ds_app_bar_back_step_light.png'),
      );
    });

    testWidgets('title only dark', (tester) async {
      await tester.pumpWidget(
        wrapForGolden(
          isDark: true,
          size: const Size(390, 56),
          child: const SizedBox(width: 390, child: DsAppBar(title: 'Settings')),
        ),
      );
      await expectLater(
        find.byType(DsAppBar),
        matchesGoldenFile('goldens/atoms/ds_app_bar_title_only_dark.png'),
      );
    });
  });
}
