// Secondary screens on a small phone — tech-debt 2.28. Russian strings
// run longer than English; every translated screen is laid out in both
// languages on a 375-pt iPhone and any overflow fails the test. (It
// found 11 screens that overflowed — 6 of them in English too.)

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary, SemanticsNode;
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/account_access.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/blocked_contacts/blocked_contacts_screen.dart';
import 'package:sinhron/features/calls_list/calls_list_screen.dart';
import 'package:sinhron/features/contacts_list/contacts_list_screen.dart';
import 'package:sinhron/features/invite_link/invite_landing_screen.dart';
import 'package:sinhron/features/new_group/new_group_screen.dart';
import 'package:sinhron/features/profile_edit/profile_edit_screen.dart';
import 'package:sinhron/core/pairing.dart';
import 'package:sinhron/features/onboarding/pair_qr_screen.dart';
import 'package:sinhron/features/onboarding/restore_screen.dart';
import 'package:sinhron/features/settings/add_device_screen.dart';
import 'package:sinhron/features/settings/phrase_prompt.dart';
import 'package:sinhron/features/settings/proxy_screen.dart';
import 'package:sinhron/features/settings/linked_devices_screen.dart';
import 'package:sinhron/features/settings/recovery_phrase_status_screen.dart';
import 'package:sinhron/features/settings/server_screen.dart';
import 'package:sinhron/features/settings/storage_screen.dart';
import 'package:sinhron/features/show_qr/show_qr_screen.dart';
import 'package:sinhron/features/sign_out/sign_out_screen.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/onboarding/welcome_screen.dart';
import 'package:sinhron/features/onboarding/profile_screen.dart';
import 'package:sinhron/features/onboarding/server_invite_screen.dart';
import 'package:sinhron/features/onboarding/recovery_phrase_screen.dart';
import 'package:sinhron/features/onboarding/save_access_screen.dart';
import 'package:sinhron/features/compose/compose_screen.dart';
import 'package:sinhron/features/settings/notifications_screen.dart';
import 'package:sinhron/features/settings/privacy_security_screen.dart';
import 'package:sinhron/features/settings/appearance_screen.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

import '../core/account_access_test.dart' show FakeVault, words24;
import '../core/chat_actions_test.dart' show FakeChatStore;
import '../core/settings_providers_test.dart' show MemoryStore;
import '../test_harness.dart' show loadAppFonts;
import 'package:sinhron/widgets/avoid_keyboard.dart';

final _shot = GlobalKey();

void main() {
  // The app's own fonts: the layout (and any overflow) is what a phone shows.
  setUpAll(loadAppFonts);
  setUp(() => DsHaptics.enabled = false);

  final cases = <(String, Widget Function())>[
    // The way in, the first screens, a call — all real-mode (2026-10-16 UI audit).
    ('WelcomeScreen', () => WelcomeScreen(onGetStarted: () {}, onLinkDevice: () {}, onRestore: () {}, onTerms: () {})),
    ('ProfileScreen', () => ProfileScreen(onBack: () {}, onContinue: () {}, initialName: 'Константин')),
    ('ServerInviteScreen', () => ServerInviteScreen(onBack: () {}, onContinue: () {}, initialServer: 'chat.777400777.xyz')),
    ('RecoveryPhraseScreen', () => RecoveryPhraseScreen(onBack: () {}, onSaved: (_) {}, words: 'abandon ability able about above absent absorb abstract absurd abuse access accident account accuse achieve acid acoustic acquire across act action actor actress actual'.split(' '))),
    ('ComposeScreen', () => ComposeScreen(onCancel: () {}, onNewGroup: () {}, onInviteQr: () {}, onScanQr: () {})),
    ('NotificationsScreen', () => NotificationsScreen(onBack: () {})),
    ('PrivacySecurityScreen', () => PrivacySecurityScreen(onBack: () {}, onBlockedList: () {}, onAppLock: () {})),
    ('AppearanceScreen', () => AppearanceScreen(onBack: () {})),
    ('CallScreen incoming', () => CallScreen(contactName: 'Константин Константинопольский', initialState: CallState.incoming, onAccept: () {}, onClose: () {})),
    ('CallScreen active', () => CallScreen(contactName: 'Мама', initialState: CallState.active, onToggleSpeaker: (_) {}, speakerOn: false, onPickAudioRoute: () {}, audioRouteLabel: 'AirPods Pro', audioRouteExternal: true, onClose: () {})),
    ('CallScreen ended', () => const CallScreen(contactName: 'Мама', initialState: CallState.ended, endedLabel: 'Нет ответа')),
    ('BlockedContactsScreen', () => const BlockedContactsScreen()),
    ('LinkedDevicesScreen', () => const LinkedDevicesScreen()),
    ('RestoreScreen', () => const RestoreScreen()),
    ('PairQrScreen', () => const PairQrScreen()),
    ('AddDeviceScreen', () => const AddDeviceScreen()),
    ('PhrasePromptScreen', () => const PhrasePromptScreen()),
    ('ProxyScreen', () => const ProxyScreen()),
    ('StorageScreen', () => const StorageScreen(usage: StorageUsage())),
    ('ShowQrScreen', () => const ShowQrScreen()),
    ('SignOutScreen', () => const SignOutScreen()),
    ('ProfileEditScreen', () => const ProfileEditScreen()),
    ('InviteLandingScreen', () => const InviteLandingScreen()),
    // Real modes (what release builds show) — the longest plausible data.
    (
      'CallsListScreen real',
      () => CallsListScreen(
        myName: 'Константин Константинопольский',
        calls: [
          CallEntry(
            chatId: 'c1',
            name: 'Константин Константинопольский',
            outgoing: false,
            video: true,
            status: 'missed',
            startedAtUnix: DateTime(2026, 10, 1).millisecondsSinceEpoch ~/ 1000,
          ),
          CallEntry(
            chatId: 'c2',
            name: 'Дача',
            isGroup: true,
            outgoing: true,
            video: false,
            status: 'completed',
            durationSecs: 3600,
            startedAtUnix: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          ),
        ],
      ),
    ),
    ('CallsListScreen empty', () => const CallsListScreen(calls: [], myName: 'Гриша')),
    (
      'ContactsListScreen real',
      () => ContactsListScreen(
        me: MyContactCard(
          name: 'Константин Константинопольский',
          keyLabel: 'ab12 cd34 ef56',
          server: 'chat.777400777.xyz',
        ),
        contacts: [
          ContactEntry(chatId: 'c1', peerId: 'a1' * 32, name: 'Константин Константинопольский'),
          ContactEntry(chatId: 'c2', peerId: 'b0' * 32, name: 'Аня'),
        ],
      ),
    ),
    ('ContactsListScreen empty', () => const ContactsListScreen(contacts: [])),
    (
      'NewGroupScreen real empty',
      () => NewGroupScreen(
        contacts: const [],
        me: const NewGroupContact(id: 'me', name: 'Гриша', subtitle: 'ab12 cd34'),
        onCreate: (_, _) async {},
      ),
    ),
    (
      'ServerScreen real',
      () => const ServerScreen(host: 'chat.777400777.xyz:8443', connected: true, protocol: 'WSS · TLS'),
    ),
    ('RecoveryPhraseStatusScreen', () => const RecoveryPhraseStatusScreen()),
    // ADR-059 — sign-up step 3 and the real Secret words screen.
    ('SaveAccessScreen', () => SaveAccessScreen(words: words24.split(' '))),
    (
      'RecoveryPhraseStatusScreen waiting',
      () => const RecoveryPhraseStatusScreen(
        access: AccessState(wordsOnPhone: true),
        passwordsAvailable: true,
      ),
    ),
    (
      'RecoveryPhraseStatusScreen saved',
      () => RecoveryPhraseStatusScreen(
        access: AccessState(savedWay: AccessWay.passwords, savedAt: DateTime(2026, 10, 18)),
        otherDevices: 1,
      ),
    ),
    (
      'SignOutScreen real',
      () =>
          const SignOutScreen(name: 'Константин Константинопольский', username: 'ab12 cd34 ef56', otherDeviceCount: 0),
    ),
  ];

  // 2026-10-16 UI audit — the keyboard up: the root lifts the screen above
  // it (AvoidKeyboard); nothing may overflow in the space left.
  // No keyboard on a call screen.
  const noKeyboard = {'CallScreen incoming', 'CallScreen active', 'CallScreen ended'};
  for (final (name, build) in cases.where((c) => !noKeyboard.contains(c.$1))) {
    testWidgets('$name fits above the keyboard', (t) async {
      t.view.physicalSize = const Size(375, 812);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      currentLanguage = 'ru';
      addTearDown(() => currentLanguage = 'en');
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(MemoryStore()),
            passwordVaultProvider.overrideWithValue(FakeVault()),
            chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
            chatStoreProvider.overrideWithValue(FakeChatStore()),
            hapticsProvider.overrideWithValue(Haptics(() => false)),
          ],
          child: Localizations(
            locale: const Locale('ru'),
            delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
            child: DsTheme(
              tokens: DsTokens.light,
              isDark: false,
              child: MediaQuery(
                data: const MediaQueryData(
                  size: Size(375, 812),
                  padding: EdgeInsets.only(top: 47),
                  viewPadding: EdgeInsets.only(top: 47, bottom: 34),
                  viewInsets: EdgeInsets.only(bottom: 336),
                ),
                child: AvoidKeyboard(
                  child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => build())),
                ),
              ),
            ),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(t.takeException(), isNull);
    });
  }

  for (final lang in ['ru', 'en']) {
    for (final (name, build) in cases) {
      testWidgets('$name lays out in $lang at 375 pt', semanticsEnabled: true, (t) async {
        t.view.physicalSize = const Size(375, 812);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        currentLanguage = lang;
        addTearDown(() => currentLanguage = 'en');
        await t.pumpWidget(
          ProviderScope(
            overrides: [
              settingsStoreProvider.overrideWithValue(MemoryStore()),
              passwordVaultProvider.overrideWithValue(FakeVault()),
              chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
              chatStoreProvider.overrideWithValue(FakeChatStore()),
              hapticsProvider.overrideWithValue(Haptics(() => false)),
              pairingOpsProvider.overrideWithValue(
                PairingOps(
                  offer: (_) async => 'sinhron-pair:2:${'00' * 16}:${'ab' * 32}:${'cd' * 32}',
                  wait: (_, _) => Completer<String?>().future,
                  cancel: () {},
                  isCode: (_) async => false,
                  send: (_, _) async {},
                  sendWithPhrase: (_, _, _) async {},
                  scanQr: () async => null,
                ),
              ),
            ],
            child: Localizations(
              locale: Locale(lang),
              delegates: const [
                AppL10n.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              child: DsTheme(
                tokens: DsTokens.light,
                isDark: false,
                child: MediaQuery(
                  data: const MediaQueryData(size: Size(375, 812), padding: EdgeInsets.only(top: 47, bottom: 34)),
                  child: RepaintBoundary(
                    key: _shot,
                    child: Navigator(onGenerateRoute: (_) => PageRouteBuilder(pageBuilder: (_, _, _) => build())),
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 500));
        expect(t.takeException(), isNull);
        // For a UI review: SINHRON_SCREENS_DIR=<dir> flutter test … saves
        // every screen as a PNG there (macOS fonts; nothing is compared).
        final dir = Platform.environment['SINHRON_SCREENS_DIR'];
        if (dir != null) {
          final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_shot));
          await t.runAsync(() async {
            final image = await boundary.toImage();
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            File('$dir/${name.replaceAll(' ', '_')}_$lang.png').writeAsBytesSync(png!.buffer.asUint8List());
          });
        }
        // Tech-debt 2.29 — VoiceOver: everything you can tap says what it
        // is (an unnamed button reads as "button").
        if (lang == 'en') {
          final unnamed = <String>[];
          void walk(SemanticsNode n) {
            final d = n.getSemanticsData();
            final tappable = d.hasAction(SemanticsAction.tap) || d.hasAction(SemanticsAction.longPress);
            // A node merged into its parent is read as part of it.
            if (tappable && !n.isMergedIntoParent && d.label.trim().isEmpty && d.value.trim().isEmpty && d.hint.trim().isEmpty) {
              unnamed.add('${n.rect} ${d.flagsCollection}');
            }
            n.visitChildren((c) {
              walk(c);
              return true;
            });
          }

          walk(t.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
          expect(unnamed, isEmpty, reason: '$name: unnamed tap targets');
        }
      });
    }
  }
}
