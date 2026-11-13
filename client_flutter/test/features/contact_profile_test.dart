// ADR-052 — a person's profile from the Contacts tab.

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
import 'package:sinhron/features/contact_info/contact_profile_screen.dart';

import '../core/message_actions_test.dart' show FakeMessageStore, FakeSender;
import '../core/people_test.dart' show FakePeopleStore;
import '../core/settings_providers_test.dart' show MemoryStore;

final anya = 'a1' * 32;
final carl = 'c4' * 32;
final dmId = 'cd' * 20;
final groupId = 'ab' * 20;

void main() {
  late FakePeopleStore people;
  final messages = <String>[];
  final calls = <String>[];

  Widget host(String peer) => ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(MemoryStore()),
      peopleStoreProvider.overrideWithValue(people),
      messageStoreProvider.overrideWithValue(FakeMessageStore()),
      messageSenderProvider.overrideWithValue(FakeSender()),
      chatMembersLoaderProvider.overrideWithValue((id) async => id == groupId ? ['aa' * 32, anya] : const []),
      chatsProvider.overrideWith(
        (ref) async => [
          ChatPreview(id: groupId, name: 'Семья', group: true, preview: '', time: ''),
          ChatPreview(id: dmId, name: 'Аня', preview: '', time: '', peerId: anya),
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
              pageBuilder: (_, _, _) => ContactProfileScreen(
                peerId: peer,
                onMessage: (chatId, name) => messages.add('${chatId ?? 'new'} $name'),
                onCall: (chatId, name, video) => calls.add('$chatId ${video ? 'video' : 'audio'}'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  setUp(() {
    people = FakePeopleStore();
    messages.clear();
    calls.clear();
  });

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(w);
    await t.pumpAndSettle();
  }

  testWidgets('with our chat: bio, message / call / video into it, groups in common, a star', (t) async {
    people.names_[anya] = 'Аня';
    people.bios_[anya] = 'Пишите днём';
    people.contacts_[anya] = ContactRecord(peerId: anya);
    await pump(t, host(anya));
    expect(find.text('Пишите днём'), findsOneWidget);
    expect(find.text('Семья'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('profile-message')));
    await t.tap(find.byKey(const ValueKey('profile-call')));
    await t.tap(find.byKey(const ValueKey('profile-video')));
    expect(messages, ['$dmId Аня']);
    expect(calls, ['$dmId audio', '$dmId video']);
    await t.tap(find.byKey(const ValueKey('profile-favourite')));
    await t.pumpAndSettle();
    expect(people.contacts_[anya]!.favourite, isTrue);
    expect(find.text('Remove from favourites'), findsOneWidget);
  });

  testWidgets('Edit name: only for me, shown at once; Restore brings their own back', (t) async {
    people.names_[anya] = 'Аня';
    people.contacts_[anya] = ContactRecord(peerId: anya);
    await pump(t, host(anya));
    await t.tap(find.byKey(const ValueKey('profile-edit-name')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('name-sheet')), findsOneWidget);
    expect(find.text('Only you see this'), findsOneWidget);
    expect(find.byKey(const ValueKey('name-restore')), findsNothing, reason: 'nothing to restore yet');
    await t.enterText(find.byKey(const ValueKey('name-field')), 'Анечка');
    await t.tap(find.byKey(const ValueKey('name-done')));
    await t.pumpAndSettle();
    expect(find.text('Анечка'), findsOneWidget);
    expect(find.text('Аня'), findsNothing);
    await t.tap(find.byKey(const ValueKey('profile-edit-name')));
    await t.pumpAndSettle();
    await t.tap(find.text('Restore “Аня”'));
    await t.pumpAndSettle();
    expect(find.text('Аня'), findsOneWidget);
    expect(find.text('Анечка'), findsNothing);
  });

  testWidgets('their chat was deleted: still a contact; Message starts a new chat; no calls', (t) async {
    people.contacts_[carl] = ContactRecord(peerId: carl, name: 'Карл');
    await pump(t, host(carl));
    expect(find.text('Карл'), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-call')), findsNothing);
    expect(find.byKey(const ValueKey('profile-media')), findsNothing);
    await t.tap(find.byKey(const ValueKey('profile-message')));
    expect(messages, ['new Карл']);
  });

  testWidgets('blocked: no message or call buttons; Unblock instead of Block', (t) async {
    people.contacts_[anya] = ContactRecord(peerId: anya);
    people.blocked_.add(anya);
    await pump(t, host(anya));
    expect(find.byKey(const ValueKey('profile-message')), findsNothing);
    expect(find.byKey(const ValueKey('profile-call')), findsNothing);
    expect(find.text('Unblock'), findsOneWidget);
  });
}
