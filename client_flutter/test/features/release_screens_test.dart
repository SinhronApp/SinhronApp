// Demo audit 2026-10-15 — screens a release build reaches show this
// phone's data, never the design gallery's people or server.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/people.dart' show ContactRecord, shortKey;
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/calls_list/call_history.dart';
import 'package:sinhron/features/calls_list/calls_list_screen.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/contacts_list/contacts_list_screen.dart';
import 'package:sinhron/features/media_viewer/media_viewer_screen.dart';
import 'package:sinhron/features/settings/recovery_phrase_status_screen.dart';
import 'package:sinhron/features/settings/server_screen.dart';
import 'package:sinhron/features/settings/settings_screen.dart';
import 'package:sinhron/features/settings/storage_screen.dart';
import 'package:sinhron/features/settings/storage_usage.dart';
import 'package:sinhron/features/sign_out/sign_out_screen.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

import '../core/settings_providers_test.dart' show MemoryStore;

final anya = 'a1' * 32;
final bob = 'b0' * 32;

/// Anything from the design gallery that must not reach a release build.
const demo = [
  'Vera',
  '@vera',
  'cabin.sinhron.app',
  'Cabin Studio',
  'Maria Chen',
  'Henry Park',
  'Engineering',
  'Apr 12',
];

void expectNoDemo() {
  for (final d in demo) {
    expect(find.textContaining(d), findsNothing, reason: 'demo "$d" on screen');
  }
}

ChatPreview dm(String id, String name, String? peer, {bool request = false}) =>
    ChatPreview(id: id, name: name, preview: '', time: '', peerId: peer, request: request);

void main() {
  Widget host(Widget child) => ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      chatsProvider.overrideWith((ref) async => const <ChatPreview>[]),
    ],
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 1400)),
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      ),
    ),
  );

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(w));
    await t.pumpAndSettle();
  }

  group('Calls tab', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    core.StoredCallSummary call(String id, String chat, String status, {bool out = false, int? secs}) =>
        core.StoredCallSummary(
          id: id,
          peerChatId: chat,
          kind: 'audio',
          status: status,
          isOutgoing: out,
          startedAtUnix: now,
          durationSecs: secs,
        );

    test('history is named after its chats; deleted chats are left out', () {
      final chats = [
        dm('c1', 'Group a1a1a1a1', anya),
        const ChatPreview(id: 'g', name: 'Дача', preview: '', time: '', group: true),
      ];
      final rows = callEntries(
        [call('1', 'c1', 'missed'), call('2', 'g', 'completed', out: true, secs: 61), call('3', 'gone', 'missed')],
        chats,
        {anya: 'Аня'},
      );
      expect(rows.map((r) => r.name), ['Аня', 'Дача']);
      expect(rows[1].isGroup, isTrue);
      expect(rows[1].durationSecs, 61);
    });

    testWidgets('real history: my name, my calls, a tap opens the chat', (t) async {
      final opened = <String>[];
      await pump(
        t,
        CallsListScreen(
          myName: 'Гриша',
          unreadChats: 0,
          onCallTap: opened.add,
          calls: [
            CallEntry(chatId: 'c1', name: 'Аня', outgoing: false, video: false, status: 'missed', startedAtUnix: now),
            CallEntry(
              chatId: 'g',
              name: 'Дача',
              isGroup: true,
              outgoing: true,
              video: true,
              status: 'completed',
              durationSecs: 61,
              startedAtUnix: now,
            ),
          ],
        ),
      );
      expectNoDemo();
      expect(find.text('Missed · audio'), findsOneWidget);
      expect(find.text('2 min · video'), findsOneWidget);
      await t.tap(find.text('Дача'));
      expect(opened, ['g']);
    });

    // Overnight item 5 — a tap calls back, ⓘ opens the chat; every outcome named.
    testWidgets('a tap calls back, ⓘ opens the chat; busy / cancelled / missed named', (t) async {
      final opened = <String>[];
      final called = <String>[];
      CallEntry e(String id, String name, String status, {bool out = false, bool video = false}) =>
          CallEntry(chatId: id, name: name, outgoing: out, video: video, status: status, startedAtUnix: now);
      await pump(
        t,
        CallsListScreen(
          myName: 'Гриша',
          unreadChats: 0,
          onCallTap: opened.add,
          onCallBack: (id, video) => called.add('$id $video'),
          calls: [
            e('c1', 'Аня', 'missed'),
            e('c2', 'Боб', 'busy', out: true, video: true),
            e('c3', 'Вика', 'cancelled', out: true),
          ],
        ),
      );
      expect(find.text('Missed · audio'), findsOneWidget);
      expect(find.text('Busy · video'), findsOneWidget);
      expect(find.text('Cancelled · audio'), findsOneWidget);
      await t.tap(find.text('Боб'));
      expect(called, ['c2 true']);
      await t.tap(find.byKey(const ValueKey('call-info-c1')));
      expect(opened, ['c1']);
    });

    testWidgets('no calls yet: says how to make one', (t) async {
      await pump(t, const CallsListScreen(calls: [], myName: 'Гриша'));
      expectNoDemo();
      expect(find.textContaining('No calls yet'), findsOneWidget);
    });
  });

  group('Contacts tab', () {
    // ADR-052 — contacts are their own list; chats only add the chat id.
    test('contacts = my stored contacts, by their own name, with our chat if any', () {
      final carl = 'c4' * 32;
      final c = contactEntries(
        [
          ContactRecord(peerId: anya),
          ContactRecord(peerId: bob.toUpperCase(), favourite: true),
          ContactRecord(peerId: carl, name: 'Карл'), // their chat was deleted
          ContactRecord(peerId: 'd0' * 32), // nothing known but the key
        ],
        [
          dm('c1', 'Group a1a1a1a1', anya),
          dm('c2', 'Боб', bob),
          dm('c3', 'Stranger', 'c0' * 32, request: true), // not a contact
          dm('c4', 'No key', null),
          const ChatPreview(id: 'g', name: 'Дача', preview: '', time: '', group: true),
        ],
        {anya: 'Аня'},
      );
      expect(c.map((x) => (x.name, x.chatId, x.favourite)), [
        (shortKey('d0' * 32), null, false),
        ('Аня', 'c1', false),
        ('Боб', 'c2', true),
        ('Карл', null, false),
      ]);
      expect(c[2].peerId, bob, reason: 'keys are lower case');
    });

    testWidgets('my card and my contacts; a tap opens the profile', (t) async {
      final opened = <String>[];
      var myCard = 0;
      await pump(
        t,
        ContactsListScreen(
          me: const MyContactCard(name: 'Гриша', keyLabel: 'ab12 cd34', server: 'chat.777400777.xyz'),
          contacts: [ContactEntry(chatId: 'c1', peerId: anya, name: 'Аня')],
          onOpen: (c) => opened.add(c.chatId!),
          onMyCard: () => myCard++,
        ),
      );
      expectNoDemo();
      expect(find.text('ab12 cd34 · chat.777400777.xyz'), findsOneWidget);
      expect(find.text(shortKey(anya)), findsOneWidget);
      await t.tap(find.text('Аня'));
      await t.tap(find.text('Гриша').last);
      expect(opened, ['c1']);
      expect(myCard, 1);
    });

    // ADR-052 — favourites are real; the phone only where there is a chat;
    // "Invite friends" under my card.
    testWidgets('favourites, invite, and a phone only for people with a chat', (t) async {
      final called = <String>[];
      var invited = 0;
      await pump(
        t,
        ContactsListScreen(
          me: const MyContactCard(name: 'Гриша', keyLabel: 'ab12 cd34', server: 'chat.777400777.xyz'),
          contacts: [
            ContactEntry(chatId: 'c1', peerId: anya, name: 'Аня', favourite: true),
            ContactEntry(peerId: bob, name: 'Боб'),
          ],
          onOpen: (_) {},
          onCall: (c) => called.add(c.name),
          onInvite: () => invited++,
        ),
      );
      expect(find.text('FAVOURITES'), findsOneWidget);
      expect(find.byKey(ValueKey('favourite-$anya')), findsOneWidget);
      expect(find.byKey(ValueKey('favourite-$bob')), findsNothing);
      expect(find.byKey(const ValueKey('call-Аня')), findsNWidgets(2), reason: 'in Favourites and in the list');
      expect(find.byKey(const ValueKey('call-Боб')), findsNothing, reason: 'no chat to call in');
      await t.tap(find.byKey(const ValueKey('call-Аня')).last);
      await t.tap(find.byKey(const ValueKey('contacts-invite')));
      expect(called, ['Аня']);
      expect(invited, 1);
    });
  });

  testWidgets('Server: the host this phone joined, nothing invented', (t) async {
    await pump(t, const ServerScreen(host: 'chat.777400777.xyz', connected: false, protocol: 'WSS · TLS'));
    expectNoDemo();
    expect(find.text('chat.777400777.xyz'), findsOneWidget);
    expect(find.text('Offline'), findsWidgets);
    expect(find.text('Switch server'), findsNothing);
  });

  testWidgets('Recovery phrase: no made-up dates or backup', (t) async {
    await pump(t, const RecoveryPhraseStatusScreen());
    expectNoDemo();
    expect(find.text('Apr 28'), findsNothing);
    expect(find.text('Very high'), findsOneWidget);
  });

  testWidgets('Sign out: who is leaving; no device line when there are none', (t) async {
    await pump(t, const SignOutScreen(name: 'Гриша', username: 'ab12 cd34', otherDeviceCount: 0));
    expectNoDemo();
    expect(find.text('Гриша'), findsOneWidget);
    expect(find.textContaining('has its own keys'), findsNothing);
    expect(find.textContaining('have their own keys'), findsNothing);
  });

  // Tech-debt 2.32 — Storage has real numbers now (it was hidden as sample data).
  testWidgets('Settings: the Storage row opens Storage', (t) async {
    var opened = 0;
    await pump(t, SettingsScreen(onStorageTap: () => opened++));
    await t.scrollUntilVisible(find.text('Storage').last, 200);
    await t.tap(find.text('Storage').last);
    expect(opened, 1);
  });

  // Status 213 — Share / Save really run (they only flashed "Saved").
  testWidgets('Photo viewer, real photo: only buttons that do something', (t) async {
    final calls = <String>[];
    await pump(
      t,
      MediaViewerScreen(
        senderName: 'Аня',
        date: '',
        image: const SizedBox(),
        share: () async {
          calls.add('share');
          return true;
        },
        save: () async {
          calls.add('save');
          return false;
        },
      ),
    );
    expectNoDemo();
    expect(find.text('Share'), findsOneWidget);
    await t.tap(find.text('Share'));
    await t.tap(find.text('Save'));
    await t.pump();
    expect(calls, ['share', 'save']);
    expect(find.text('Could not save'), findsOneWidget, reason: 'a failure says so, not "Saved"');
    await t.pump(const Duration(seconds: 2));
    expect(find.text('Forward'), findsNothing);
    expect(find.text('Delete'), findsNothing);
  });

  // Tech-debt 2.32 — real numbers, chats by name, clearing the copies.
  test('storage usage: chats by their names; per-type sizes as stored', () {
    final u = storageUsageFrom(
      const core.StorageUsageSummary(
        photos: 100,
        videos: 2000,
        voice: 30,
        documents: 4,
        misc: 5,
        unreferenced: 6,
        database: 700,
        byChat: [
          core.ChatStorageUsage(chatId: 'c1', bytes: 2000),
          core.ChatStorageUsage(chatId: 'g', bytes: 130),
          core.ChatStorageUsage(chatId: 'gone', bytes: 9),
        ],
      ),
      [dm('c1', 'Group a1a1a1a1', anya), const ChatPreview(id: 'g', name: 'Дача', preview: '', time: '', group: true)],
      {anya: 'Аня'},
    );
    expect(u.other, 11, reason: 'previews + copies not linked yet');
    expect(u.media, 2145);
    expect(u.database, 700);
    expect(u.chats.map((c) => (c.name, c.bytes, c.isGroup)), [('Аня', 2000, false), ('Дача', 130, true)]);
  });

  testWidgets('Storage: this phone\'s numbers; deleting copies asks first, then says what it freed', (t) async {
    var cleared = 0;
    await pump(
      t,
      Navigator(
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => StorageScreen(
            usage: const StorageUsage(
              photos: 3 * 1024 * 1024,
              database: 512 * 1024,
              chats: [StorageChat(name: 'Аня', bytes: 3 * 1024 * 1024)],
            ),
            onClearCopies: () async {
              cleared++;
              return 3 * 1024 * 1024;
            },
          ),
        ),
      ),
    );
    expectNoDemo();
    expect(find.text('used by Sinhron on this phone'), findsOneWidget);
    expect(find.text('3.0 MB'), findsNWidgets(2), reason: 'Photos row + Аня');
    expect(find.text('Messages'), findsWidgets);
    expect(find.text('Auto-delete old media'), findsNothing, reason: 'design-only settings');
    await t.tap(find.byKey(const ValueKey('storage-clear-copies')));
    await t.pumpAndSettle();
    expect(cleared, 0, reason: 'asks first');
    await t.tap(find.text('Delete media copies').last);
    await t.pumpAndSettle();
    expect(cleared, 1);
    expect(find.text('Freed 3.0 MB'), findsOneWidget);
  });

  // Tech-debt 2.32 — keep unused media copies forever / a month / a week.
  testWidgets('Storage: how long unused copies are kept', (t) async {
    final picked = <int>[];
    await pump(
      t,
      Navigator(
        onGenerateRoute: (_) => PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => StorageScreen(
            usage: const StorageUsage(photos: 1024),
            onClearCopies: () async => 0,
            keepDays: 0,
            onKeepDays: picked.add,
          ),
        ),
      ),
    );
    expect(find.text('Keep media copies'), findsOneWidget);
    expect(find.text('Forever'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('storage-keep-days')));
    await t.pumpAndSettle();
    await t.tap(find.text('A month').last);
    await t.pumpAndSettle();
    expect(picked, [30]);
  });
}
