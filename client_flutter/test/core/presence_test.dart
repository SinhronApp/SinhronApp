// ADR-031 — "online" / "last seen": off by default, only to contacts,
// timed by the server, forgotten when the owner hides it.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/presence.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/l10n/l10n.dart';

import 'settings_providers_test.dart' show MemoryStore;

final group = 'ab' * 20;
final dm = 'dd' * 20; // personal chat with Anna
final dm2 = 'ee' * 20; // personal chat, other person not known yet
final stranger = 'cd' * 20; // a message request
final blockedDm = 'bb' * 20; // personal chat with someone I blocked
final anna = 'a1' * 32;
final bob = 'b2' * 32;

List<List<Object?>> pairs(List<(String, Map<String, Object?>)> sent) => [
  for (final s in sent) [s.$1, s.$2],
];

void main() {
  late MemoryStore settings;
  late ProviderContainer c;
  late List<(String, Map<String, Object?>)> sent;

  setUp(() async {
    settings = MemoryStore()..map['blocked_chats'] = '$blockedDm=$bob';
    sent = [];
    c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        presenceProvider.overrideWith((ref) => Presence(ref, send: (chat, a) async => sent.add((chat, a)))),
        chatsProvider.overrideWith(
          (ref) async => [
            ChatPreview(id: group, name: 'Family', group: true, preview: '', time: ''),
            ChatPreview(id: dm, name: 'Anna', preview: '', time: '', peerId: anna),
            ChatPreview(id: dm2, name: 'New', preview: '', time: ''),
            ChatPreview(id: stranger, name: 'Stranger', preview: '', time: '', request: true),
            ChatPreview(id: blockedDm, name: 'Bob', preview: '', time: '', peerId: bob),
            const ChatPreview(id: 'demo-chat', name: 'Demo', preview: '', time: ''),
          ],
        ),
      ],
    );
    addTearDown(c.dispose);
    await c.read(chatsProvider.future);
    await c.read(blockedChatsProvider.future);
  });

  test('off by default: opening the app tells nobody', () async {
    expect(await c.read(showOnlineProvider.future), isFalse);
    await c.read(presenceProvider).online();
    await c.read(presenceProvider).offline();
    expect(sent, isEmpty);
  });

  test('on: only contacts hear it — no groups, requests, blocked or demo chats', () async {
    await c.read(showOnlineProvider.notifier).save(true);
    final p = c.read(presenceProvider);
    await p.online();
    expect(pairs(sent), [
      [dm, {'t': 'presence', 'online': true}],
      [dm2, {'t': 'presence', 'online': true}],
    ]);
    sent.clear();
    await p.offline();
    expect(sent.map((s) => s.$2).toSet(), {
      {'t': 'presence', 'online': false},
    });
    sent.clear();
    await p.offline();
    expect(sent, isEmpty, reason: '"left" is said once');
    p.dispose();
  });

  // Battery 2026-10-18 — Android "always connected" keeps the connection
  // all day and reconnects in the background: that is not the person using
  // the phone, so it says nothing (and repeats nothing).
  test('a connection in the background (always connected) never says "online"', () async {
    await c.read(showOnlineProvider.notifier).save(true);
    final p = c.read(presenceProvider);
    await p.reconnected(); // started with no screen
    expect(sent, isEmpty);
    await p.online();
    await p.offline();
    sent.clear();
    await p.reconnected(); // a reconnect off screen
    await p.reconnected();
    expect(sent, isEmpty);
  });

  test('turning it off makes contacts forget; turning it on while open says "online"', () async {
    final p = c.read(presenceProvider);
    await p.online(); // open, but switched off: silent
    expect(sent, isEmpty);
    await c.read(showOnlineProvider.notifier).save(true);
    await p.settingChanged(true);
    expect(sent.map((s) => s.$1), [dm, dm2]);
    sent.clear();
    await c.read(showOnlineProvider.notifier).save(false);
    await p.settingChanged(false);
    expect(pairs(sent), [
      [dm, {'t': 'presence', 'hidden': true}],
      [dm2, {'t': 'presence', 'hidden': true}],
    ]);
    p.dispose();
  });

  test('incoming: only the contact in their own personal chat, timed by the server', () async {
    final p = c.read(presenceProvider);
    final now = DateTime.now();
    final at = now.millisecondsSinceEpoch ~/ 1000 - 10; // ahead of this clock would count as now
    p.onIncoming(group, anna, jsonEncode({'online': true}), atUnix: at);
    p.onIncoming(stranger, anna, jsonEncode({'online': true}), atUnix: at);
    p.onIncoming(dm, bob, jsonEncode({'online': true}), atUnix: at); // not Anna's chat's person
    p.onIncoming(blockedDm, bob, jsonEncode({'online': true}), atUnix: at);
    expect(c.read(peerPresenceProvider), isEmpty);

    p.onIncoming(dm, anna, jsonEncode({'online': true}), atUnix: at);
    expect(isOnlineNow(c.read(peerPresenceProvider)[anna]), isTrue);

    // An older message (Resume after a long time offline) changes nothing.
    p.onIncoming(dm, anna, jsonEncode({'online': false}), atUnix: at - 3600);
    expect(isOnlineNow(c.read(peerPresenceProvider)[anna]), isTrue);

    p.onIncoming(dm, anna, jsonEncode({'online': false}), atUnix: at + 1);
    final seen = c.read(peerPresenceProvider)[anna]!;
    expect(isOnlineNow(seen), isFalse);
    expect(lastSeenAt(seen).millisecondsSinceEpoch ~/ 1000, at + 1);

    p.onIncoming(dm, anna, jsonEncode({'hidden': true}), atUnix: at + 2);
    expect(c.read(peerPresenceProvider), isEmpty, reason: 'she hid it — forget');
  });

  // Bug 2026-10-19: "online" held 6 minutes; now under a minute.
  test('"online" runs out on its own within a minute when no "left" came', () {
    final now = DateTime(2026, 10, 14, 12);
    final s = PresenceSeen(at: now, online: true);
    expect(PeerPresence.onlineFor, lessThanOrEqualTo(const Duration(seconds: 60)));
    expect(PeerPresence.onlineFor, greaterThan(Presence.heartbeat * 2), reason: 'one late heartbeat must not blink');
    expect(isOnlineNow(s, now: now.add(Presence.heartbeat * 2)), isTrue);
    expect(isOnlineNow(s, now: now.add(const Duration(seconds: 60))), isFalse);
    expect(lastSeenAt(s, now: now.add(const Duration(hours: 1))), now, reason: 'their last heartbeat');
    final ru = lookupAppL10n(const Locale('ru'));
    expect(presenceLabel(ru, s, now: now.add(const Duration(seconds: 30))), 'в сети');
    expect(presenceLabel(ru, s, now: now.add(const Duration(seconds: 58))), 'был(а) только что');
    expect(presenceLabel(ru, s, now: now.add(const Duration(minutes: 3, seconds: 5))), 'был(а) 3 минуты назад');
  });

  test('the map re-emits when a label changes: "online" running out, "N minutes ago" ticking', () {
    final now = DateTime(2026, 10, 14, 12);
    final on = PresenceSeen(at: now.subtract(const Duration(seconds: 10)), online: true);
    final left = PresenceSeen(at: now.subtract(const Duration(minutes: 2, seconds: 30)), online: false);
    final old = PresenceSeen(at: now.subtract(const Duration(hours: 2)), online: false);
    expect(nextPresenceChange([on], now), on.at.add(PeerPresence.onlineFor));
    expect(nextPresenceChange([left], now), left.at.add(const Duration(minutes: 3)), reason: '2 → 3 minutes ago');
    expect(nextPresenceChange([old], now), isNull, reason: '"today at 10:00" stays');
    expect(nextPresenceChange([old, left, on], now), left.at.add(const Duration(minutes: 3)), reason: 'the soonest');
    // A quiet "online" that ran out ticks on like a "left".
    final quiet = PresenceSeen(at: now.subtract(const Duration(seconds: 70)), online: true);
    expect(nextPresenceChange([quiet], now), quiet.at.add(const Duration(minutes: 2)));
  });

  // The bug itself: the chat header selected the PresenceSeen object, the
  // map came back with the same object, the header never redrew.
  test('a screen selecting presenceShown redraws when "online" runs out', () async {
    final en = lookupAppL10n(const Locale('en'));
    final shown = <PresenceShown>[];
    c.listen(peerPresenceProvider.select((m) => presenceShown(en, m[anna])), (_, v) => shown.add(v));
    final at = DateTime.now().subtract(PeerPresence.onlineFor - const Duration(milliseconds: 600));
    c.read(peerPresenceProvider.notifier).apply(anna, online: true, hidden: false, at: at);
    expect(shown.single.online, isTrue);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(shown.last.online, isFalse);
    expect(shown.last.label, 'last seen just now');
  });

  test("a receiver's clock running behind the server doesn't stretch \"online\"", () {
    final now = DateTime(2026, 10, 14, 12);
    c.read(peerPresenceProvider.notifier)
        .apply(anna, online: true, hidden: false, at: now.add(const Duration(minutes: 10)), now: now);
    final s = c.read(peerPresenceProvider)[anna]!;
    expect(s.at, now);
    expect(isOnlineNow(s, now: now.add(const Duration(minutes: 1))), isFalse);
  });

  test('"left" is said once even when asked twice at once (hidden, then paused / the close)', () async {
    await c.read(showOnlineProvider.notifier).save(true);
    final slow = <(String, Map<String, Object?>)>[];
    final p = c.read(
      Provider(
        (ref) => Presence(
          ref,
          send: (chat, a) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            slow.add((chat, a));
          },
        ),
      ),
    );
    await p.online();
    slow.clear();
    await Future.wait([p.offline(), p.offline()]);
    await p.offline();
    expect(pairs(slow), [
      [dm, {'t': 'presence', 'online': false}],
      [dm2, {'t': 'presence', 'online': false}],
    ]);
    p.dispose();
  });

  test('last seen survives a restart (kept in settings)', () async {
    final at = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    c.read(presenceProvider).onIncoming(dm, anna, jsonEncode({'online': false}), atUnix: at);
    await Future<void>.delayed(const Duration(seconds: 3)); // debounced save
    expect(jsonDecode(settings.map['presence_seen']!)[anna], {'at': at, 'on': false});

    final c2 = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(settings)]);
    addTearDown(c2.dispose);
    c2.read(peerPresenceProvider);
    await Future<void>.delayed(Duration.zero);
    expect(c2.read(peerPresenceProvider)[anna]?.online, isFalse);
  });

  test('labels: online, just now, minutes, today, yesterday, a date (ru and en)', () {
    final ru = lookupAppL10n(const Locale('ru'));
    final en = lookupAppL10n(const Locale('en'));
    final now = DateTime(2026, 10, 14, 15, 30);
    PresenceSeen left(Duration ago) => PresenceSeen(at: now.subtract(ago), online: false);
    expect(presenceLabel(ru, null, now: now), '');
    expect(presenceLabel(ru, PresenceSeen(at: now, online: true), now: now), 'в сети');
    expect(presenceLabel(ru, left(const Duration(seconds: 20)), now: now), 'был(а) только что');
    expect(presenceLabel(ru, left(const Duration(minutes: 5)), now: now), 'был(а) 5 минут назад');
    expect(presenceLabel(ru, left(const Duration(minutes: 21)), now: now), 'был(а) 21 минуту назад');
    expect(presenceLabel(ru, left(const Duration(hours: 3)), now: now), 'был(а) сегодня в 12:30');
    expect(presenceLabel(ru, left(const Duration(hours: 20)), now: now), 'был(а) вчера в 19:30');
    expect(presenceLabel(ru, left(const Duration(days: 5)), now: now), 'был(а) 09.10.2026');
    expect(presenceLabel(en, left(const Duration(minutes: 1)), now: now), 'last seen 1 minute ago');
    expect(presenceLabel(en, left(const Duration(hours: 20)), now: now), 'last seen yesterday at 19:30');
  });

  // Last in the file: it leaves the test binding "on screen".
  testWidgets('a start with no screen says nothing; the screen coming says "online", leaving says "left"', (
    tester,
  ) async {
    await c.read(showOnlineProvider.notifier).save(true);
    expect(WidgetsBinding.instance.lifecycleState, isNull, reason: 'like Android "always connected" / a push wake');
    await tester.pumpWidget(
      UncontrolledProviderScope(container: c, child: const PresenceKeeper(child: SizedBox())),
    );
    await tester.pump();
    expect(sent, isEmpty);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(sent.map((s) => s.$2).toSet(), {
      {'t': 'presence', 'online': true},
    });
    sent.clear();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(sent.map((s) => s.$2).toSet(), {
      {'t': 'presence', 'online': false},
    });
    await tester.pumpWidget(const SizedBox());
    c.read(presenceProvider).dispose();
  });
}
