// Settings → Chat folders (owner, 2026-10-18): every folder with a
// show/hide switch and a drag handle, create / edit / delete, ready-made
// folders one tap away; the row in Settings.

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_list/chat_folders_screen.dart';
import 'package:sinhron/features/settings/settings_screen.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;
import 'chat_list_folders_test.dart' show host, phone;

Map<String, Object?> layout(MemoryStore s) => jsonDecode(s.map['chat_folder_layout']!) as Map<String, Object?>;

List<Map<String, Object?>> custom(MemoryStore s) =>
    (jsonDecode(s.map['chat_folders'] ?? '[]') as List).cast<Map<String, Object?>>();

/// ReorderableList wants WidgetsLocalizations.
Widget screen() => Localizations(
      locale: Locale('en'),
      delegates: const [AppL10n.delegate, GlobalWidgetsLocalizations.delegate],
      child: const ChatFoldersScreen(),
    );

Finder row(String id) => find.byKey(ValueKey('folder-row-$id'));

void main() {
  testWidgets('every folder is listed — built-ins too — and each one hides and shows', (t) async {
    phone(t);
    final store = MemoryStore()..map['chat_folders'] = '[{"id":"w","name":"Work","emoji":"💼","groups":true}]';
    await t.pumpWidget(host(screen(), [], settings: store));
    await t.pumpAndSettle();

    for (final id in ['all', 'personal', 'groups', 'unread', 'w']) {
      expect(row(id), findsOneWidget);
    }
    expect(find.text('Standard · 3 chats'), findsOneWidget, reason: 'All: alice, bob, team');
    expect(find.text('1 chat'), findsOneWidget, reason: 'Work: team');

    await t.tap(find.byKey(const ValueKey('folder-shown-all')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('folder-shown-w')));
    await t.pumpAndSettle();
    expect(layout(store)['hidden'], ['all', 'w']);
    expect(row('all'), findsOneWidget, reason: 'hidden folders stay in the list, switched off');

    await t.tap(find.byKey(const ValueKey('folder-shown-all')));
    await t.pumpAndSettle();
    expect(layout(store)['hidden'], ['w']);
  });

  testWidgets('drag a folder by its handle — All can move too', (t) async {
    phone(t);
    final store = MemoryStore();
    await t.pumpWidget(host(screen(), [], settings: store));
    await t.pumpAndSettle();

    // All's handle, dragged below Personal (rows are 60 px).
    final g = await t.startGesture(t.getCenter(find.byKey(const ValueKey('folder-handle-all'))));
    await t.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, 10));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await t.pumpAndSettle();
    expect(layout(store)['order'], ['personal', 'all', 'groups', 'unread']);
    expect(t.getTopLeft(row('personal')).dy, lessThan(t.getTopLeft(row('all')).dy));

    // Long-press anywhere on a row works too: Unread to the top.
    final g2 = await t.startGesture(t.getCenter(find.text('Unread')));
    await t.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 20; i++) {
      await g2.moveBy(const Offset(0, -10));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g2.up();
    await t.pumpAndSettle();
    expect(layout(store)['order'], ['unread', 'personal', 'all', 'groups']);
  });

  testWidgets('a suggested folder is one tap away and leaves the suggestions', (t) async {
    phone(t);
    final store = MemoryStore();
    await t.pumpWidget(host(screen(), [], settings: store));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('folder-suggestion-s_muted')), findsOneWidget);

    await t.tap(find.byKey(const ValueKey('folder-add-s_muted')));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('folder-suggestion-s_muted')), findsNothing);
    expect(row('s_muted'), findsOneWidget);
    final saved = custom(store).single;
    expect(saved['name'], 'Muted');
    expect(saved['muted'], 'only');
  });

  testWidgets('create a folder; tap it to edit its rules; swipe to delete', (t) async {
    phone(t);
    final store = MemoryStore();
    await t.pumpWidget(host(screen(), [], settings: store));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const ValueKey('folder-create')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const ValueKey('folder-name')), 'Friends');
    await t.tap(find.byKey(const ValueKey('folder-emoji-💼')));
    await t.tap(find.text('All personal chats'));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('folder-save')));
    await t.pumpAndSettle();
    final id = custom(store).single['id'] as String;
    expect(find.text('💼'), findsOneWidget);
    expect(find.text('2 chats'), findsOneWidget, reason: 'alice and bob');

    // Edit: muted chats → only them.
    await t.tap(find.text('Friends'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('folder-muted-rule')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Only these')));
    await t.pumpAndSettle();
    expect(find.text('Only these'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('folder-save')));
    await t.pumpAndSettle();
    expect(custom(store).single['muted'], 'only');
    expect(find.text('No chats'), findsOneWidget);

    // Swipe left → Delete → confirm.
    await t.drag(row(id), const Offset(-120, 0));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('sheet-action-Delete folder')));
    await t.pumpAndSettle();
    expect(custom(store), isEmpty);
    expect(row(id), findsNothing);
  });

  testWidgets('Settings → Chats has a "Chat folders" row with the tab count', (t) async {
    phone(t);
    var opened = 0;
    final store = MemoryStore()..map['chat_folder_layout'] = '{"hidden":["unread"]}';
    await t.pumpWidget(host(SettingsScreen(onChatFoldersTap: () => opened++), [], settings: store));
    await t.pumpAndSettle();
    final entry = find.byKey(const ValueKey('settings-chat-folders'));
    await t.scrollUntilVisible(entry, 200, scrollable: find.byType(Scrollable).first);
    await t.pumpAndSettle();
    expect(find.descendant(of: entry, matching: find.text('Chat folders')), findsOneWidget);
    expect(find.descendant(of: entry, matching: find.text('3')), findsOneWidget);
    await t.tap(entry);
    expect(opened, 1);
  });
}
