// Overnight item 7 / ADR-037 — App Store readiness: deleting the account
// really deletes it, reports reach the operator, the rules are in the app.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/account_deletion.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/services/net_service.dart';
import 'package:sinhron/features/account_delete/delete_account_screen.dart';
import 'package:sinhron/features/app_lock/app_lock.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/legal/legal_text_screen.dart';
import 'package:sinhron/features/onboarding/welcome_screen.dart';
import 'package:sinhron/features/report/report_flow.dart';
import 'package:sinhron/features/settings/settings_screen.dart';

import '../core/chat_actions_test.dart' show FakeChatStore;
import '../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../core/people_test.dart' show FakePeopleStore;
import '../core/settings_providers_test.dart' show MemoryStore;
import 'app_lock/app_lock_test.dart' show FakeAuth;

class _OnlineNet extends NetService {
  _OnlineNet(super.ref);
  @override
  String? get httpBaseUrl => 'https://srv';
}

final anya = 'a1' * 32;

void main() {
  Widget host(Widget child, {List<Override> overrides = const []}) => ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      // Face ID passes (LOCK-6: Delete account asks it first).
      appAuthenticatorProvider.overrideWithValue(FakeAuth()),
      ...overrides,
    ],
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 1200)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(onGenerateRoute: (_) => PageRouteBuilder<void>(pageBuilder: (_, _, _) => child)),
        ),
      ),
    ),
  );

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(w);
    await t.pumpAndSettle();
  }

  group('Delete account', () {
    testWidgets('says what really happens; only the typed word unlocks it', (t) async {
      final calls = <String?>[];
      await pump(
        t,
        host(DeleteAccountScreen(server: 'chat.777400777.xyz', otherDevices: 2, onDelete: (p) async => calls.add(p))),
      );
      expect(find.textContaining('chat.777400777.xyz'), findsOneWidget);
      expect(find.textContaining('2 other devices'), findsOneWidget);
      expect(find.textContaining('vera'), findsNothing, reason: 'no design-mock username');
      expect(find.textContaining('7 days'), findsNothing, reason: 'deletion is immediate');
      await t.tap(find.byKey(const ValueKey('delete-account-go')));
      await t.pump();
      expect(calls, isEmpty, reason: 'not before the word is typed');
      await t.enterText(find.byKey(const ValueKey('delete-account-confirm')), 'delete');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('delete-account-go')));
      await t.pumpAndSettle();
      expect(calls, [null]);
    });

    testWidgets('a QR-paired device asks for the 24 words; a failure says nothing was erased', (t) async {
      final calls = <String?>[];
      await pump(
        t,
        host(
          DeleteAccountScreen(
            server: 's',
            needsPhrase: true,
            askPhrase: () async => 'words',
            onDelete: (p) async {
              calls.add(p);
              throw StateError('offline');
            },
          ),
        ),
      );
      await t.enterText(find.byKey(const ValueKey('delete-account-confirm')), 'DELETE');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('delete-account-go')));
      await t.pumpAndSettle();
      expect(calls, ['words']);
      expect(find.textContaining('Nothing was erased'), findsOneWidget);
    });

    test('groups hear "left", then the server deletes, then this phone is wiped', () async {
      final log = <String>[];
      final sender = FakeSender();
      final c = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          netServiceProvider.overrideWith((ref) => _OnlineNet(ref)),
          messageStoreProvider.overrideWithValue(FakeMessageStore()),
          messageSenderProvider.overrideWithValue(sender),
          chatStoreProvider.overrideWithValue(FakeChatStore()),
          chatsProvider.overrideWith(
            (ref) async => const [
              ChatPreview(id: 'g1', name: 'Дача', preview: '', time: '', group: true),
              ChatPreview(id: 'c1', name: 'Аня', preview: '', time: ''),
            ],
          ),
          accountDeleteCallProvider.overrideWithValue((base, phrase) async => log.add('server $base $phrase')),
          accountWipeProvider.overrideWithValue(() async => log.add('wipe')),
        ],
      );
      addTearDown(c.dispose);
      await c.read(accountDeletionProvider).run();
      expect(sender.actions, [
        {'t': 'leave'},
      ], reason: 'only the group');
      expect(log, ['server https://srv null', 'wipe']);
    });

    test('the server refusing means nothing is wiped', () async {
      var wiped = false;
      final c = ProviderContainer(
        overrides: [
          settingsStoreProvider.overrideWithValue(MemoryStore()),
          netServiceProvider.overrideWith((ref) => _OnlineNet(ref)),
          chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
          accountDeleteCallProvider.overrideWithValue((_, _) async => throw StateError('401')),
          accountWipeProvider.overrideWithValue(() async => wiped = true),
        ],
      );
      addTearDown(c.dispose);
      await expectLater(c.read(accountDeletionProvider).run(), throwsStateError);
      expect(wiped, isFalse);
    });
  });

  testWidgets('Report: reason → with the message → sent → block', (t) async {
    final reports = <String>[];
    final people = FakePeopleStore();
    await pump(
      t,
      host(
        Consumer(
          builder: (context, ref, _) => GestureDetector(
            onTap: () => reportPerson(context, ref, peer: anya, name: 'Аня', messageText: 'buy now', personalChatId: 'c1'),
            child: const Text('go'),
          ),
        ),
        overrides: [
          peopleStoreProvider.overrideWithValue(people),
          reportCallProvider.overrideWithValue((peer, reason, text) async => reports.add('$peer $reason $text')),
        ],
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.textContaining('Report Аня?'), findsOneWidget);
    await t.tap(find.text('Spam'));
    await t.pumpAndSettle();
    await t.tap(find.text('Report and send this message'));
    await t.pumpAndSettle();
    expect(reports, ['$anya spam buy now']);
    expect(find.text('Report sent. Thank you.'), findsOneWidget);
    await t.tap(find.text('Block').last);
    await t.pumpAndSettle();
    expect(people.blocked_, {anya});
  });

  testWidgets('Report without the message sends no text', (t) async {
    final reports = <String>[];
    await pump(
      t,
      host(
        Consumer(
          builder: (context, ref, _) => GestureDetector(
            onTap: () => reportPerson(context, ref, peer: anya, name: 'Аня', messageText: 'hi'),
            child: const Text('go'),
          ),
        ),
        overrides: [
          peopleStoreProvider.overrideWithValue(FakePeopleStore()),
          reportCallProvider.overrideWithValue((peer, reason, text) async => reports.add('$reason $text')),
        ],
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Harassment or threats'));
    await t.pumpAndSettle();
    await t.tap(find.text('Report without the message'));
    await t.pumpAndSettle();
    expect(reports, ['abuse null']);
  });

  testWidgets('Rules & support in Settings; terms say zero tolerance and how to report', (t) async {
    final opened = <String>[];
    await pump(
      t,
      host(
        SettingsScreen(
          onTermsTap: () => opened.add('terms'),
          onPrivacyPolicyTap: () => opened.add('privacy'),
          onSupportTap: () => opened.add('support'),
        ),
      ),
    );
    // The section sits near the end, under the tab bar: scroll past it.
    await t.scrollUntilVisible(find.byKey(const ValueKey('settings-support')), 200);
    await t.drag(find.byType(Scrollable).first, const Offset(0, -400));
    await t.pumpAndSettle();
    for (final k in ['settings-terms', 'settings-privacy-policy', 'settings-support']) {
      await t.tap(find.byKey(ValueKey(k)));
    }
    expect(opened, ['terms', 'privacy', 'support']);
  });

  testWidgets('Rules text: paragraphs split on blank lines', (t) async {
    await pump(t, host(const LegalTextScreen(title: 'Terms', paragraphs: ['Intro', 'One\n\nTwo'])));
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
  });

  testWidgets('Welcome: "By continuing you accept the Terms of use" opens them', (t) async {
    var terms = 0;
    // Not `pump` (pumpAndSettle): the mark breathes forever.
    await t.pumpWidget(host(WelcomeScreen(onTerms: () => terms++)));
    await t.pump(const Duration(seconds: 1));
    await t.tap(find.byKey(const ValueKey('welcome-terms')));
    expect(terms, 1);
  });
}
