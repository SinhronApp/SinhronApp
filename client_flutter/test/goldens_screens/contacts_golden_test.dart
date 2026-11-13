// ADR-052 — the Contacts tab and a person's profile as golden images (real
// mode: favourites, invite, a contact without a chat; bio, key, groups in
// common), light / dark, English / Russian. Re-record with
// `flutter test --update-goldens test/goldens_screens/contacts_golden_test.dart`
// on the Mac and look at them.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/features/contact_info/contact_info_screen.dart';
import 'package:sinhron/features/contacts_list/contacts_list_screen.dart';
import 'package:sinhron/l10n/l10n.dart';

import '../test_harness.dart';
import 'key_screens_golden_test.dart' show host;

final _anya = 'a1' * 32;
final _bob = 'b0' * 32;
final _carl = 'c4' * 32;
final _dina = 'd0' * 32;

ContactsListScreen _contacts(String lang) {
  final ru = lang == 'ru';
  return ContactsListScreen(
    me: MyContactCard(name: ru ? 'Вера' : 'Vera', keyLabel: 'ab12 cd34', server: 'chat.example.org'),
    contacts: [
      ContactEntry(chatId: 'c1', peerId: _anya, name: ru ? 'Аня' : 'Anya', favourite: true),
      ContactEntry(chatId: 'c2', peerId: _bob, name: ru ? 'Борис' : 'Boris'),
      ContactEntry(peerId: _carl, name: ru ? 'Карл' : 'Carl'), // the chat was deleted
      ContactEntry(chatId: 'c4', peerId: _dina, name: ru ? 'Дина' : 'Dina'),
    ],
    verifiedPeers: {_bob},
    unreadChats: 2,
    onOpen: (_) {},
    onCall: (_) {},
    onInvite: () {},
    onMyCard: () {},
    onAdd: () {},
  );
}

ContactProfileView _profile(String lang) {
  final ru = lang == 'ru';
  return ContactProfileView(
    name: ru ? 'Аня Смирнова' : 'Anya Smirnova',
    keyLabel: 'a1a1 a1a1',
    status: ru ? 'в сети' : 'online',
    online: true,
    bio: ru ? 'Дизайнер. Пишите днём — вечером отвечаю медленно' : 'Designer. Text in the day — slow to reply at night',
    verified: true,
    favourite: true,
    commonGroups: [
      ContactCommonGroup(chatId: 'g1', name: ru ? 'Семья' : 'Family', members: 5),
      ContactCommonGroup(chatId: 'g2', name: ru ? 'Дача' : 'Cottage', members: 3),
    ],
    onBack: () {},
    onMessage: () {},
    onCall: () {},
    onVideo: () {},
    onSafetyNumber: () {},
    onSharedMedia: () {},
    onOpenGroup: (_) {},
    onToggleContact: () {},
    onToggleFavourite: () {},
    onToggleBlock: () {},
  );
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => DsHaptics.enabled = false);

  Future<void> shoot(WidgetTester t, String name, Widget screen, {required bool dark, required String lang}) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    currentLanguage = lang;
    addTearDown(() => currentLanguage = 'en');
    await t.pumpWidget(host(screen, dark: dark, lang: lang));
    await t.pumpAndSettle();
    await expectLater(find.byType(Navigator).first, matchesGoldenFile('goldens/$name.png'));
  }

  for (final (lang, dark) in [('ru', false), ('en', true)]) {
    final suffix = '${lang}_${dark ? 'dark' : 'light'}';
    testWidgets('contacts $suffix', (t) => shoot(t, 'contacts_$suffix', _contacts(lang), dark: dark, lang: lang));
    testWidgets(
      'contact profile $suffix',
      (t) => shoot(t, 'contact_profile_$suffix', _profile(lang), dark: dark, lang: lang),
    );
  }

  // Without a chat (deleted): only "Message"; no safety number to open, no media.
  testWidgets('contact profile without a chat', (t) async {
    await t.pumpWidget(
      host(
        ContactProfileView(name: 'Карл', keyLabel: 'c4c4 c4c4', onMessage: () {}, onToggleContact: () {}),
        dark: false,
        lang: 'ru',
      ),
    );
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-message')), findsOneWidget);
    expect(find.byKey(const ValueKey('profile-call')), findsNothing);
    expect(find.byKey(const ValueKey('profile-media')), findsNothing);
    expect(find.byKey(const ValueKey('profile-bio')), findsNothing);
    expect(find.text('Удалить из контактов'), findsOneWidget);
  });
}
