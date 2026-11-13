// app-surface:3 (docs/security-review-2026-11.md) — a short invite link
// names the server it is fetched from, so opening it told that server my IP
// before I touched anything. Now: nothing goes out before a tap, unless it is
// my own server.

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/app.dart';
import 'package:sinhron/app/navigation.dart';
import 'package:sinhron/core/invite_link.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;
import 'package:sinhron/app/theme/tokens.dart';

import '../core/settings_providers_test.dart' show MemoryStore;

const _evil = 'sinhron://i/evil.example/AAAAAAAAAA#AAAAAAAAAAAAAAAAAAAAAA';
const _me = core.StoredIdentitySummary(fingerprint: 'fp', ed25519PubHex: 'ed', x25519PubHex: 'x', createdAtUnix: 0);

void main() {
  final en = lookupAppL10n(const Locale('en'));
  late List<String> fetched;

  Future<void> app(WidgetTester t, {required bool account}) async {
    fetched = [];
    globalDiagnosticBanner.value = '';
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith((ref) async => account ? _me : null),
          settingsStoreProvider.overrideWithValue(MemoryStore()..map['server_url'] = 'wss://chat.example.org/v1/sync'),
          inviteResolverProvider.overrideWithValue((link) async {
            fetched.add(link);
            throw const InviteLinkError('expired');
          }),
        ],
        child: WidgetsApp(
          color: const Color(0xFFFFFFFF),
          navigatorKey: SinhronApp.navigatorKey,
          localizationsDelegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
          supportedLocales: AppL10n.supportedLocales,
          locale: const Locale('en'),
          pageRouteBuilder: <T>(s, b) => PageRouteBuilder<T>(settings: s, pageBuilder: (c, _, _) => b(c)),
          builder: (c, child) => DsTheme(tokens: DsTokens.light, isDark: false, child: child!),
          home: const SizedBox(),
        ),
      ),
    );
  }

  test('the host is read the way Rust reads it', () {
    expect(shortInviteHost(_evil), 'evil.example');
    expect(shortInviteHost('HTTPS://Chat.Example.org:443/i/Ab3dEf7hJk?x=1#k'), 'chat.example.org');
  });

  testWidgets('no account: a stranger\'s server is not contacted until I tap Open', (t) async {
    await app(t, account: false);
    final done = handleInviteLink(_evil);
    await t.pumpAndSettle();
    expect(fetched, isEmpty, reason: 'nothing fetched before the tap');
    expect(find.textContaining('evil.example'), findsOneWidget, reason: 'the sheet names the server');
    await t.tap(find.text(en.openLink));
    await t.pumpAndSettle();
    await done;
    expect(fetched, [_evil]);
  });

  testWidgets('an account on my server: another server\'s short link is never fetched', (t) async {
    await app(t, account: true);
    await handleInviteLink(_evil);
    await t.pumpAndSettle();
    expect(fetched, isEmpty);
    expect(globalDiagnosticBanner.value, en.scanContactOtherServer('evil.example'));
    // My own server's link goes on as before.
    const mine = 'https://chat.example.org/i/Ab3dEf7hJk#AAAAAAAAAAAAAAAAAAAAAA';
    await handleInviteLink(mine);
    expect(fetched, [mine]);
  });
}
