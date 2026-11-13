// Launch (audit jank-08): while the identity is being read, AppRoot shows
// only the background — not the welcome screen, which used to flash before
// the chat list on every launch.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/navigation.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/onboarding/server_invite_screen.dart';
import 'package:sinhron/features/onboarding/welcome_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../core/settings_providers_test.dart' show MemoryStore;

void main() {
  setUp(() => DsHaptics.enabled = false);

  testWidgets('loading → dark background only; no identity → welcome, and Get started works', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final identity = Completer<core.StoredIdentitySummary?>();
    final c = ProviderContainer(
      overrides: [
        bootDiagnosticsProvider.overrideWithValue(
          const BootDiagnostics(coreVersion: 't', dbPath: 'db', mlsDbPath: '', mlsDbBytes: -1, storageLocked: false),
        ),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        identityProvider.overrideWith((ref) => identity.future),
        hapticsProvider.overrideWithValue(Haptics(() => false)),
      ],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: DsTheme(
          tokens: DsTokens.dark,
          isDark: true,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const AppRoot())),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    expect(find.byType(WelcomeScreen), findsNothing, reason: 'no welcome flash while loading');
    final bg = t.widget<ColoredBox>(find.descendant(of: find.byType(AppRoot), matching: find.byType(ColoredBox)));
    expect(bg.color, DsTokens.dark.bg);

    // The welcome mark animates for ever: pump, don't settle.
    identity.complete(null);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(WelcomeScreen), findsOneWidget);

    await t.tap(find.text('Get started'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(ServerInviteScreen), findsOneWidget, reason: 'the welcome screen is wired');
  });

  testWidgets('the account could not be read → background only, never the welcome screen', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final identity = Completer<core.StoredIdentitySummary?>();
    final c = ProviderContainer(
      overrides: [
        bootDiagnosticsProvider.overrideWithValue(
          const BootDiagnostics(coreVersion: 't', dbPath: 'db', mlsDbPath: '', mlsDbBytes: -1, storageLocked: false),
        ),
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        identityProvider.overrideWith((ref) => identity.future),
        hapticsProvider.overrideWithValue(Haptics(() => false)),
      ],
    );
    addTearDown(c.dispose);
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: DsTheme(
          tokens: DsTokens.dark,
          isDark: true,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => const AppRoot())),
            ),
          ),
        ),
      ),
    );
    identity.completeError(StateError('db'));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(WelcomeScreen), findsNothing, reason: '"Get started" would make a second account');
    final bg = t.widget<ColoredBox>(find.descendant(of: find.byType(AppRoot), matching: find.byType(ColoredBox)));
    expect(bg.color, DsTokens.dark.bg);
  });
}
