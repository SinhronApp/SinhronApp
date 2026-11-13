// Tech-debt 2.22 / 2.27 — the real chat info screen.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/core/providers/people.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_info/chat_info_screen.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';

import '../core/message_actions_test.dart' show FakeGroupOps, FakeMessageStore, FakeSender;
import '../core/people_test.dart' show FakePeopleStore;
import '../core/settings_providers_test.dart' show MemoryStore;

final me = 'aa' * 32;
final anya = 'a1' * 32;
final bob = 'b0' * 32;
final groupId = 'ab' * 20;
final dmId = 'cd' * 20;

void main() {
  late FakePeopleStore people;
  late MemoryStore settings;
  late FakeGroupOps ops;
  late FakeSender sender;
  final verifyCalls = <String?>[];

  final profileCalls = <String>[];

  Widget host(String chatId, List<String> members, {VoidCallback? onAddMembers, String? dmPeer}) => ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(settings),
      peopleStoreProvider.overrideWithValue(people),
      messageStoreProvider.overrideWithValue(FakeMessageStore()),
      messageSenderProvider.overrideWithValue(sender),
      groupOpsProvider.overrideWithValue(ops),
      chatMembersLoaderProvider.overrideWithValue((_) async => members),
      myIdentityProvider.overrideWithValue(() => me),
      chatsProvider.overrideWith(
        (ref) async => [
          ChatPreview(id: groupId, name: 'Семья', group: true, preview: '', time: ''),
          ChatPreview(id: dmId, name: 'Аня', preview: '', time: '', peerId: dmPeer),
        ],
      ),
    ],
    child: DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 1400)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (_, _, _) => ChatInfoScreen(
                chatId: chatId,
                onVerify: (_, peer) => verifyCalls.add(peer),
                onAddMembers: onAddMembers,
                onOpenProfile: (peer, name) => profileCalls.add('$peer $name'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  setUp(() {
    people = FakePeopleStore();
    settings = MemoryStore();
    ops = FakeGroupOps()..adminId = me;
    sender = FakeSender();
    verifyCalls.clear();
    profileCalls.clear();
  });

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(w);
    await t.pumpAndSettle();
  }

  testWidgets('group: members by their own names, me marked, unnamed shown honestly', (t) async {
    people.names_[anya] = 'Аня';
    await pump(t, host(groupId, [me, anya, bob]));
    expect(find.text('Семья'), findsNWidgets(2), reason: 'header + the admin\'s Rename row');
    expect(find.text('3 members'), findsOneWidget);
    expect(find.text('You (you)'), findsOneWidget);
    expect(find.text('Аня'), findsOneWidget);
    expect(find.text('No name shared yet'), findsOneWidget);
    expect(find.text(shortKey(bob)), findsNothing, reason: 'no code beside a name');
    // No safety-number / block rows for the group itself.
    expect(find.byKey(const ValueKey('info-block')), findsNothing);
  });

  // ADR-034 — a group offers "Add member"; a personal chat doesn't.
  testWidgets('group: Add member row opens the picker', (t) async {
    var opened = 0;
    await pump(t, host(groupId, [me, anya, bob], onAddMembers: () => opened++));
    await t.tap(find.byKey(const ValueKey('info-add-member')));
    expect(opened, 1);
  });

  testWidgets('personal chat: no Add member', (t) async {
    await pump(t, host(dmId, [me, anya], onAddMembers: () {}));
    expect(find.byKey(const ValueKey('info-add-member')), findsNothing);
  });

  // ADR-052 — their bio, groups we share, and contacts apart from the chat.
  testWidgets('personal chat: their bio, groups in common, add to / remove from contacts', (t) async {
    people.bios_[anya] = 'Дизайнер. Пишите днём';
    await pump(t, host(dmId, [me, anya]));
    expect(find.byKey(const ValueKey('info-bio')), findsOneWidget);
    expect(find.text('Дизайнер. Пишите днём'), findsOneWidget);
    expect(find.byKey(ValueKey('info-group-$groupId')), findsOneWidget, reason: 'the members loader puts Аня in Семья too');
    expect(find.text('Add to contacts'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('info-contact')));
    await t.pumpAndSettle();
    expect(people.contacts_.keys, [anya]);
    expect(find.text('Remove from contacts'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('info-contact')));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove from contacts').last); // the confirmation
    await t.pumpAndSettle();
    expect(people.contacts_, isEmpty);
  });

  // Owner, 2026-10-19 — what they wrote about themselves, wherever I look.
  testWidgets('personal chat: their bio even while the members are still loading', (t) async {
    people.bios_[anya] = 'Дизайнер';
    await pump(t, host(dmId, const [], dmPeer: anya));
    expect(find.text('Дизайнер'), findsOneWidget);
  });

  testWidgets('group: a member\'s profile (with their bio) opens from their row', (t) async {
    people.names_[anya] = 'Аня';
    await pump(t, host(groupId, [me, anya, bob]));
    await t.tap(find.byKey(ValueKey('member-$anya')));
    await t.pumpAndSettle();
    await t.tap(find.text('Profile'));
    await t.pumpAndSettle();
    expect(profileCalls, ['$anya Аня']);
  });

  testWidgets('group: a member can be verified or blocked from their row', (t) async {
    people.names_[anya] = 'Аня';
    await pump(t, host(groupId, [me, anya, bob]));
    await t.tap(find.byKey(ValueKey('member-$anya')));
    await t.pumpAndSettle();
    await t.tap(find.text('Check it’s really them'));
    await t.pumpAndSettle();
    expect(verifyCalls, [anya]);

    await t.tap(find.byKey(ValueKey('member-$anya')));
    await t.pumpAndSettle();
    await t.tap(find.text('Block').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Block').last); // confirm
    await t.pumpAndSettle();
    expect(people.blocked_, {anya});
    expect(settings.map['blocked_chats'] ?? '', isEmpty, reason: 'a group is not a personal chat');
    expect(find.text('Blocked'), findsOneWidget);
  });

  testWidgets('personal chat: safety number and block, which also screens its calls', (t) async {
    await pump(t, host(dmId, [me, anya]));
    expect(find.text('Personal chat · encrypted'), findsOneWidget);
    expect(find.byKey(const ValueKey('info-report')), findsOneWidget, reason: 'ADR-037 — report to the operator');
    await t.tap(find.byKey(const ValueKey('info-verify')));
    await t.pumpAndSettle();
    expect(verifyCalls, [null]);

    await t.tap(find.byKey(const ValueKey('info-block')));
    await t.pumpAndSettle();
    await t.tap(find.text('Block').last);
    await t.pumpAndSettle();
    expect(people.blocked_, {anya});
    expect(settings.map['blocked_chats'], '$dmId=$anya');

    await t.tap(find.byKey(const ValueKey('info-block'))); // now "Unblock"
    await t.pumpAndSettle();
    expect(people.blocked_, isEmpty);
    expect(settings.map['blocked_chats'], '');
  });

  // ADR-035 — the admin (creator) manages; everyone else can only leave.
  testWidgets('group admin: badge, rename, remove a member, leave', (t) async {
    people.names_[anya] = 'Аня';
    await pump(t, host(groupId, [me, anya, bob], onAddMembers: () {}));
    expect(find.text('admin'), findsOneWidget, reason: 'me, the creator');
    expect(find.byKey(const ValueKey('info-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('info-add-member')), findsOneWidget);
    expect(find.byKey(const ValueKey('info-leave')), findsOneWidget);
    expect(find.byKey(const ValueKey('info-delete')), findsNothing, reason: 'leave, not just delete');

    await t.tap(find.byKey(ValueKey('member-$anya')));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove from group'));
    await t.pumpAndSettle();
    expect(find.text('Remove Аня from the group? They won’t be able to read new messages.'), findsOneWidget);
    await t.tap(find.text('Remove from group').last);
    await t.pumpAndSettle();
    expect(ops.calls, ['remove $anya']);
    expect(sender.actions.single['t'], 'removed');

    await t.tap(find.byKey(const ValueKey('info-rename')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('group-rename-field')), 'Дом');
    await t.tap(find.byKey(const ValueKey('group-rename-save')));
    await t.pumpAndSettle();
    expect(sender.actions.last, {'t': 'group_name', 'name': 'Дом'});
  });

  testWidgets('group member (not admin): no rename / remove / add, can leave', (t) async {
    ops.adminId = anya;
    people.names_[anya] = 'Аня';
    await pump(t, host(groupId, [me, anya, bob], onAddMembers: () {}));
    expect(find.text('admin'), findsOneWidget, reason: 'Аня, the creator');
    expect(find.byKey(const ValueKey('info-rename')), findsNothing);
    expect(find.byKey(const ValueKey('info-add-member')), findsNothing);
    await t.tap(find.byKey(ValueKey('member-$bob')));
    await t.pumpAndSettle();
    expect(find.text('Remove from group'), findsNothing);
    await t.tapAt(const Offset(10, 10)); // dismiss the sheet
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('info-leave')));
    await t.pumpAndSettle();
    await t.tap(find.text('Leave group').last);
    await t.pumpAndSettle();
    expect(sender.actions.single, {'t': 'leave'});
    expect(ops.calls, ['leave-server']);
  });

  testWidgets('removed from a group: says so, no members, delete instead of leave', (t) async {
    ops.active = false;
    await pump(t, host(groupId, [me, anya]));
    expect(find.text('You’re no longer a member of this group.'), findsOneWidget);
    expect(find.byKey(ValueKey('member-$anya')), findsNothing);
    expect(find.byKey(const ValueKey('info-leave')), findsNothing);
    expect(find.byKey(const ValueKey('info-delete')), findsOneWidget);
  });

  // Owner, 2026-11-03 — a chat's own wallpaper.
  testWidgets('Wallpaper row: pick one for this chat, "Same as all chats" clears it', (t) async {
    await pump(t, host(dmId, [me, anya]));
    await t.tap(find.byKey(const ValueKey('info-wallpaper')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('wallpaper-dots')), findsOneWidget, reason: 'the Appearance tiles');
    expect(find.byKey(const ValueKey('wallpaper-photo')), findsNothing, reason: 'one photo for all chats');
    expect(find.text('Same as all chats'), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-action-checked')), findsOneWidget, reason: 'no own wallpaper yet: checked');
    expect(find.textContaining('✓'), findsNothing, reason: 'an icon, not a character');

    await t.tap(find.byKey(const ValueKey('wallpaper-dots')));
    await t.pumpAndSettle();
    expect(settings.map['wallpaper:$dmId'], 'dots');
    expect(settings.map['wallpaper'], isNull, reason: 'all other chats untouched');
    expect(find.text('Dots'), findsOneWidget, reason: 'the row names it');

    await t.tap(find.byKey(const ValueKey('info-wallpaper')));
    await t.pumpAndSettle();
    await t.tap(find.text('Same as all chats'));
    await t.pumpAndSettle();
    expect(settings.map['wallpaper:$dmId'], '');
    expect(find.text('Dots'), findsNothing);
  });
}
