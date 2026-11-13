// ADR-043 — invite links: what a verified link leads to, how links reach the
// app (also the one that started it, once), and the real invite screen.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/invite_link.dart';
import 'package:sinhron/features/invite_link/invite_landing_screen.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

import '../test_harness.dart';

const _grisha = (serverHost: 'chat.example.org', identityHex: 'ab12', name: 'Гриша');

class _FakeLinks implements InviteLinkPlatform {
  _FakeLinks(this.initial);
  String? initial;
  final ctl = StreamController<String>.broadcast();

  @override
  Stream<String> get links => ctl.stream;

  @override
  Future<String?> takeInitial() async {
    final v = initial;
    initial = null;
    return v;
  }
}

void main() {
  group('what an invite leads to', () {
    test('no account → a new one on the invite\'s server', () {
      expect(
        inviteActionFor(_grisha, hasAccount: false, myIdentityHex: null, myServerHost: ''),
        InviteAction.newAccount,
      );
    });
    test('same server → add the inviter', () {
      expect(
        inviteActionFor(_grisha, hasAccount: true, myIdentityHex: 'cd34', myServerHost: 'Chat.Example.org'),
        InviteAction.addContact,
      );
    });
    test('my own link, or another server', () {
      expect(
        inviteActionFor(_grisha, hasAccount: true, myIdentityHex: 'AB12', myServerHost: 'chat.example.org'),
        InviteAction.self,
      );
      expect(
        inviteActionFor(_grisha, hasAccount: true, myIdentityHex: 'cd34', myServerHost: 'other.example.net'),
        InviteAction.otherServer,
      );
    });
  });

  group('short links', () {
    test('both forms are recognised; long and other links are not', () {
      expect(isShortInviteLink('https://chat.example.org/i/Ab3dEf7hJk#AAAAAAAAAAAAAAAAAAAAAA'), isTrue);
      expect(isShortInviteLink('sinhron://i/chat.example.org/Ab3dEf7hJk#AAAAAAAAAAAAAAAAAAAAAA'), isTrue);
      expect(isShortInviteLink(' HTTPS://Chat.Example.org/i/Ab3dEf7hJk#k '), isTrue);
      expect(isShortInviteLink('https://chat.example.org/join#a.b'), isFalse);
      expect(isShortInviteLink('sinhron://join#a.b'), isFalse);
      expect(isShortInviteLink('https://chat.example.org/info#x'), isFalse);
      expect(isShortInviteLink('https://i/x'), isFalse);
    });

    test('an expired short link stops before the check, with its own message', () async {
      final resolved = <String>[];
      final c = ProviderContainer(
        overrides: [
          inviteResolverProvider.overrideWithValue((link) async {
            resolved.add(link);
            throw const InviteLinkError('expired');
          }),
        ],
      );
      addTearDown(c.dispose);
      const link = 'https://chat.example.org/i/Ab3dEf7hJk#AAAAAAAAAAAAAAAAAAAAAA';
      await expectLater(
        c.read(inviteOpenerProvider)(link),
        throwsA(isA<InviteLinkError>().having((e) => e.code, 'code', 'expired')),
      );
      expect(resolved, [link]);
      expect(lookupAppL10n(const Locale('ru')).inviteExpired, 'Ссылка устарела — попросите новую');
      expect(lookupAppL10n(const Locale('en')).inviteExpired, 'This link has expired — ask for a new one');
    });
  });

  test('a pending invite is kept through onboarding and taken once', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(pendingInviteProvider.notifier).set(_grisha);
    expect(c.read(pendingInviteProvider.notifier).take(), _grisha);
    expect(c.read(pendingInviteProvider.notifier).take(), isNull);
  });

  testWidgets('the link that started the app and later ones reach the handler, each once', (t) async {
    final fake = _FakeLinks('https://chat.example.org/join#a.b');
    final got = <String>[];
    await t.pumpWidget(
      ProviderScope(
        overrides: [inviteLinkPlatformProvider.overrideWithValue(fake)],
        child: InviteLinkListener(onLink: got.add, child: const SizedBox()),
      ),
    );
    await t.pump();
    await t.pump();
    expect(got, ['https://chat.example.org/join#a.b']);
    // The same tap arriving again as a live event is not a second invite.
    fake.ctl.add('https://chat.example.org/join#a.b');
    fake.ctl.add('sinhron://join#c.d');
    await t.pump();
    expect(got, ['https://chat.example.org/join#a.b', 'sinhron://join#c.d']);
  });

  testWidgets('the real invite screen: no sample data, the error, the custom button', (t) async {
    await t.pumpWidget(
      wrapForGolden(
        isDark: false,
        child: const InviteLandingScreen(
          server: 'chat.example.org',
          inviterName: 'Гриша',
          inviterUsername: '',
          token: 'Ключ ab12 cd34',
          expiresIn: '',
          reachability: 'Сервер на связи',
          showSteps: false,
          acceptLabel: 'Добавить Гриша в контакты',
          error: 'Ссылка повреждена',
        ),
      ),
    );
    expect(find.text('chat.example.org'), findsOneWidget);
    expect(find.text('Сервер на связи'), findsOneWidget);
    expect(find.text('Ключ ab12 cd34'), findsOneWidget);
    expect(find.text('Добавить Гриша в контакты'), findsOneWidget);
    expect(find.byKey(const ValueKey('invite-error')), findsOneWidget);
    expect(find.textContaining('28'), findsNothing, reason: 'no sample "Reachable · 28 ms"');
    expect(find.textContaining('22'), findsNothing, reason: 'no sample expiry');
  });
}
