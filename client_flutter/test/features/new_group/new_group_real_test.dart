// ADR-034 — New group on real people: picks from personal chats with a
// known key, creates with their keys, never shows the demo list.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/people.dart' show shortKey;
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/new_group/new_group_screen.dart';

final me = 'aa' * 32;
final anya = 'a1' * 32;
final bob = 'b0' * 32;
final carol = 'c0' * 32;

ChatPreview dm(String id, String name, String? peer, {bool request = false}) =>
    ChatPreview(id: id, name: name, preview: '', time: '', peerId: peer, request: request);

void main() {
  test('candidates: accepted personal chats with a key, own names, no blocked / members / me', () {
    final chats = [
      dm('1', 'Group a1a1a1a1', anya),
      dm('2', 'Боб', bob),
      dm('3', 'Кэрол', carol, request: true), // not accepted yet
      dm('4', 'Nobody', null), // key not known
      const ChatPreview(id: 'g', name: 'Семья', preview: '', time: '', group: true),
      dm('5', 'Боб again', bob), // same person twice
      dm('6', 'Me on another chat', me),
    ];
    final c = groupCandidates(chats, {anya: 'Аня'}, exclude: {me});
    expect(c.map((x) => x.name), ['Аня', 'Боб']);
    expect(c.map((x) => x.id), [anya, bob]);
    expect(c.first.subtitle, shortKey(anya));
    expect(groupCandidates(chats, {}, exclude: {me, anya}).map((x) => x.id), [bob]);
    expect(groupCandidates(chats, {}, exclude: {me}, blocked: {bob}).map((x) => x.id), [anya]);
  });

  Widget host(Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(390, 1200)),
      child: Directionality(textDirection: TextDirection.ltr, child: child),
    ),
  );

  Future<void> pump(WidgetTester t, Widget w) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(w));
    await t.pumpAndSettle();
  }

  final contacts = [
    NewGroupContact(id: anya, name: 'Аня', subtitle: shortKey(anya)),
    NewGroupContact(id: bob, name: 'Боб', subtitle: shortKey(bob)),
  ];
  final self = NewGroupContact(id: me, name: 'Гриша', subtitle: shortKey(me));

  testWidgets('create: pick two, name it, Create passes their keys', (t) async {
    final created = <(String, List<String>)>[];
    await pump(
      t,
      NewGroupScreen(contacts: contacts, me: self, onCreate: (name, ids) async => created.add((name, ids))),
    );
    expect(find.text('Maria Chen'), findsNothing, reason: 'no demo people');
    await t.tap(find.text('Боб'));
    await t.tap(find.text('Аня'));
    await t.pump();
    await t.tap(find.text('Next · 2 selected'));
    await t.pumpAndSettle();
    // Step 2: me and both members, real names; Create waits for a name.
    expect(find.text('Гриша'), findsNothing, reason: 'my row says You');
    expect(find.text(shortKey(me)), findsOneWidget);
    expect(find.text('Vera Kuznetsova'), findsNothing);
    expect(find.text('@vera'), findsNothing);
    await t.tap(find.text('Create group'));
    expect(created, isEmpty);
    await t.enterText(find.byType(EditableText), '  Дача  ');
    await t.pump();
    await t.tap(find.text('Create group'));
    await t.pumpAndSettle();
    expect(created.single.$1, 'Дача');
    expect(created.single.$2, [bob, anya], reason: 'in the order picked');
  });

  testWidgets('create failure keeps the screen for a retry', (t) async {
    var tries = 0;
    await pump(
      t,
      NewGroupScreen(
        contacts: contacts,
        me: self,
        initialStep: NewGroupStep.nameAndCreate,
        initialSelected: [anya],
        onCreate: (_, _) async {
          tries++;
          throw StateError('no keypackage available');
        },
      ),
    );
    await t.enterText(find.byType(EditableText), 'Дача');
    await t.pump();
    await t.tap(find.text('Create group'));
    await t.pumpAndSettle();
    await t.tap(find.text('Create group'));
    await t.pumpAndSettle();
    expect(tries, 2);
  });

  testWidgets('no contacts: says how to get some', (t) async {
    await pump(t, NewGroupScreen(contacts: const [], me: self, onCreate: (_, _) async {}));
    expect(find.textContaining('Start a personal chat'), findsOneWidget);
    expect(find.text('Alex Park'), findsNothing);
  });

  testWidgets('add members: one step, Add passes the picked keys', (t) async {
    final added = <List<String>>[];
    await pump(t, NewGroupScreen(contacts: contacts, me: self, onAdd: (ids) async => added.add(ids)));
    expect(find.text('Add member'), findsOneWidget);
    expect(find.text('1 / 2'), findsNothing);
    await t.tap(find.text('Аня'));
    await t.pump();
    await t.tap(find.text('Add · 1 selected'));
    await t.pumpAndSettle();
    expect(added, [
      [anya],
    ]);
    expect(find.text('Create group'), findsNothing, reason: 'no name step');
  });
}
