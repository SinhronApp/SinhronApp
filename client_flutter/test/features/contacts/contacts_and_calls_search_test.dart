// Tech-debt 2.34 — the Contacts and Calls tabs on real data: search,
// "Verified", the letter rail, "new call".

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls_list/calls_list_screen.dart';
import 'package:sinhron/features/contacts_list/contacts_list_screen.dart';

final _anya = ContactEntry(chatId: 'c1', peerId: 'a1' * 32, name: 'Аня');
final _boris = ContactEntry(chatId: 'c2', peerId: 'b2' * 32, name: 'Борис');
final _vera = ContactEntry(chatId: 'c3', peerId: 'c3' * 32, name: 'Вера');
final _zed = ContactEntry(chatId: 'c4', peerId: 'd4' * 32, name: 'Zed');

Widget _wrap(Widget child) => DsTheme(
  tokens: DsTokens.light,
  isDark: false,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(390, 844)),
    child: Directionality(textDirection: TextDirection.ltr, child: child),
  ),
);

void main() {
  test('a contact is found by name in any case, or by its key', () {
    final all = [_anya, _boris, _vera, _zed];
    expect(contactsMatching(all, 'бор'), [_boris]);
    expect(contactsMatching(all, 'ВЕР'), [_vera]);
    expect(contactsMatching(all, 'b2b2'), [_boris], reason: 'the key, as shortKey shows it');
    expect(contactsMatching(all, 'b2 b2'), [_boris]);
    expect(contactsMatching(all, 'b'), isEmpty, reason: 'one hex letter is not a key search');
    expect(contactsMatching(all, '  '), all);
    expect(contactLetter('аня'), 'А');
    expect(contactLetter('7 гномов'), '#');
    expect(contactLetter(''), '#');
  });

  testWidgets('Contacts: search narrows the list, Verified has its own section, the rail jumps', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final opened = <String>[];
    await t.pumpWidget(
      _wrap(
        ContactsListScreen(
          contacts: [_anya, _boris, _vera, _zed],
          verifiedPeers: {_vera.peerId},
          onOpen: (c) => opened.add(c.name),
        ),
      ),
    );
    expect(find.byKey(ValueKey('verified-${_vera.peerId}')), findsOneWidget);
    expect(find.byKey(ValueKey('contact-${_vera.peerId}')), findsOneWidget, reason: 'also in A–Я');
    expect(find.byKey(const ValueKey('contacts-letter-rail')), findsNothing, reason: 'a short list has no rail');

    await t.enterText(find.byType(EditableText), 'бор');
    await t.pump();
    expect(find.byKey(ValueKey('contact-${_boris.peerId}')), findsOneWidget);
    expect(find.byKey(ValueKey('contact-${_anya.peerId}')), findsNothing);
    expect(find.byKey(ValueKey('verified-${_vera.peerId}')), findsNothing);
    expect(find.byKey(const ValueKey('contacts-letter-rail')), findsNothing);
    await t.tap(find.byKey(ValueKey('contact-${_boris.peerId}')));
    expect(opened, ['Борис']);

    await t.enterText(find.byType(EditableText), 'нет такого');
    await t.pump();
    expect(find.textContaining('нет такого'), findsWidgets, reason: 'says nothing was found');
  });

  testWidgets('a long list gets the letter rail, sections in A–Я order whatever the input order', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final names = ['Яна', 'Борис', 'Аня', 'Вера', 'Глеб', 'Дина', 'Егор', 'Жанна', 'Зоя', 'Илья', 'Ким', 'Лев', 'Маша', 'Нина', 'Олег'];
    await t.pumpWidget(
      _wrap(
        ContactsListScreen(
          contacts: [
            for (var i = 0; i < names.length; i++)
              ContactEntry(chatId: 'c$i', peerId: i.toRadixString(16).padLeft(2, '0') * 32, name: names[i]),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('contacts-letter-rail')), findsOneWidget);
    final a = t.getTopLeft(find.text('Аня')).dy;
    final b = t.getTopLeft(find.text('Борис')).dy;
    expect(a, lessThan(b), reason: 'А before Б');
  });

  testWidgets('Calls: the search icon opens a field that filters by name; new call', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    var newCalls = 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await t.pumpWidget(
      _wrap(
        CallsListScreen(
          myName: 'Гриша',
          onNewCall: () => newCalls++,
          calls: [
            CallEntry(chatId: 'c1', name: 'Аня', outgoing: true, video: false, status: 'completed', startedAtUnix: now),
            CallEntry(chatId: 'c2', name: 'Борис', outgoing: false, video: true, status: 'missed', startedAtUnix: now),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('calls-search')), findsNothing);
    await t.tap(find.byKey(const ValueKey('calls-search-toggle')));
    await t.pumpAndSettle(); // the field slides open
    await t.enterText(find.byType(EditableText), 'бор');
    await t.pump();
    expect(find.text('Борис'), findsOneWidget);
    expect(find.text('Аня'), findsNothing);
    // Closing the search brings everyone back.
    await t.tap(find.byKey(const ValueKey('calls-search-toggle')));
    await t.pumpAndSettle();
    expect(find.text('Аня'), findsOneWidget);
    expect(find.byKey(const ValueKey('calls-search')), findsNothing, reason: 'folded away');
    await t.tap(find.byKey(const ValueKey('calls-new-call')));
    expect(newCalls, 1);
  });

  testWidgets('Calls: rows that arrive after the history loads still play their entrance', (t) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final calls = [
      CallEntry(chatId: 'c1', name: 'Аня', outgoing: true, video: false, status: 'completed', startedAtUnix: now),
    ];
    await t.pumpWidget(_wrap(const CallsListScreen(myName: 'Гриша', calls: [], loading: true)));
    await t.pump();
    expect(find.text('Аня'), findsNothing);
    expect(find.textContaining('No calls yet'), findsNothing, reason: 'no "empty" flash while loading');

    await t.pumpWidget(_wrap(CallsListScreen(myName: 'Гриша', calls: calls)));
    await t.pump();
    final fade = t.widget<FadeTransition>(
      find.ancestor(of: find.text('Аня'), matching: find.byType(FadeTransition)).first,
    );
    expect(fade.opacity.value, lessThan(1), reason: 'fading in, not just there');
    await t.pumpAndSettle();
    expect(fade.opacity.value, 1);
  });
}
