// Folder tabs above the chat list (owner, 2026-10-18): any folder hides,
// the built-ins too; hold a tab and drag it to move it; hold and let go
// for the menu; a pill slides under the open tab with the swipe; haptics.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_list/chat_list_screen.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;
import 'chat_list_folders_test.dart' show host, phone, visible;

Finder tab(String id) => find.byKey(ValueKey('folder-tab-$id'));

Map<String, Object?> layout(MemoryStore s) => jsonDecode(s.map['chat_folder_layout']!) as Map<String, Object?>;

void main() {
  testWidgets('hold a tab and let go: the menu; Hide folder hides a built-in for good', (t) async {
    phone(t);
    final store = MemoryStore();
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    expect(tab('groups'), findsOneWidget);

    await t.longPress(tab('groups'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('sheet-action-Edit folders')), findsOneWidget);
    expect(find.byKey(const ValueKey('sheet-action-Delete folder')), findsNothing, reason: 'built-ins only hide');
    await t.tap(find.byKey(const ValueKey('sheet-action-Hide folder')));
    await t.pumpAndSettle();

    expect(tab('groups'), findsNothing);
    expect(layout(store)['hidden'], ['groups']);

    // A restart keeps it hidden.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    expect(tab('groups'), findsNothing);
    expect(tab('personal'), findsOneWidget);
  });

  testWidgets('"All" can be hidden too: the archive row moves to the first tab', (t) async {
    phone(t);
    final store = MemoryStore()..map['chat_folder_layout'] = '{"hidden":["all"]}';
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    expect(tab('all'), findsNothing);
    expect(visible('alice'), isTrue, reason: 'Personal is open now');
    expect(visible('team'), isFalse);
    expect(find.byKey(const ValueKey('archive-row')).hitTestable(), findsOneWidget);
  });

  testWidgets('only All left → no tab strip at all', (t) async {
    phone(t);
    final store = MemoryStore()..map['chat_folder_layout'] = '{"hidden":["personal","groups","unread"]}';
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    expect(tab('all'), findsNothing);
    expect(visible('alice'), isTrue);
    expect(visible('team'), isTrue);
  });

  testWidgets('hold a tab and drag it: the order is saved, the open folder stays open', (t) async {
    phone(t);
    final store = MemoryStore();
    final haptics = <Object?>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    await t.tap(tab('groups'));
    await t.pumpAndSettle();
    expect(visible('alice'), isFalse);

    // Personal, held, dragged right past Groups.
    final g = await t.startGesture(t.getCenter(tab('personal')));
    await t.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 20; i++) {
      await g.moveBy(const Offset(9, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();

    expect(layout(store)['order'], ['all', 'groups', 'personal', 'unread']);
    expect(t.getTopLeft(tab('groups')).dx, lessThan(t.getTopLeft(tab('personal')).dx));
    expect(find.byKey(const ValueKey('sheet-action-Edit folders')), findsNothing, reason: 'a drag is not a menu');
    expect(visible('team'), isTrue, reason: 'Groups is still the open folder');
    expect(visible('alice'), isFalse);
    expect(haptics, containsAll(['HapticFeedbackType.heavyImpact', 'HapticFeedbackType.selectionClick']));
  });

  testWidgets('Move left / right in the menu — the VoiceOver path for the drag', (t) async {
    phone(t);
    final store = MemoryStore()..map['chat_folder_layout'] = '{"hidden":["personal"]}';
    await t.pumpWidget(host(const ChatListScreen(), [], settings: store));
    await t.pumpAndSettle();
    await t.longPress(tab('groups'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Move left')));
    await t.pumpAndSettle();
    expect(layout(store)['order'], ['groups', 'personal', 'all', 'unread'], reason: 'hidden Personal keeps its slot');
    expect(t.getTopLeft(tab('groups')).dx, lessThan(t.getTopLeft(tab('all')).dx));
  });

  testWidgets('the pill slides under the open tab and follows a swipe halfway', (t) async {
    phone(t);
    await t.pumpWidget(host(const ChatListScreen(), []));
    await t.pumpAndSettle();
    final pill = find.byKey(const ValueKey('folder-indicator'));
    expect(t.getRect(pill).left, t.getRect(tab('all')).left);
    expect(t.getRect(pill).width, closeTo(t.getRect(tab('all')).width, 0.5));

    await t.tap(tab('personal'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final midway = t.getRect(pill).left;
    expect(midway, greaterThan(t.getRect(tab('all')).left), reason: 'it slides, not jumps');
    await t.pumpAndSettle();
    expect(t.getRect(pill).left, closeTo(t.getRect(tab('personal')).left, 0.5));

    // Drag the list halfway towards Groups: the pill sits between.
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('folder-pages'))));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(-19, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    final between = t.getRect(pill).left;
    expect(between, greaterThan(t.getRect(tab('personal')).left));
    expect(between, lessThan(t.getRect(tab('groups')).left));
    await g.up();
    await t.pumpAndSettle();
  });
}
