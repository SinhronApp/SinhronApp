// App icon badge + unread rule — UI backlog §8 item 58.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/app_badge.dart';
import 'package:sinhron/core/providers/chat_providers.dart';
import 'package:sinhron/core/providers/core_providers.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';

import 'settings_providers_test.dart' show MemoryStore;

class FakeBadge implements AppBadge {
  FakeBadge({this.grant = true});
  final bool grant;
  final sets = <int>[];
  var asked = 0;

  @override
  Future<bool> requestPermission() async {
    asked++;
    return grant;
  }

  @override
  Future<void> set(int count) async => sets.add(count);
}

const chats = [
  ChatPreview(id: 'a', name: 'A', preview: '', time: '', unread: 3),
  ChatPreview(id: 'b', name: 'B', preview: '', time: '', unread: 1, muted: true),
  ChatPreview(id: 'c', name: 'C', preview: '', time: '', unread: 2, archived: true),
  ChatPreview(id: 'd', name: 'D', preview: '', time: '', markedUnread: true),
  ChatPreview(id: 'e', name: 'E', preview: '', time: ''),
];

void main() {
  test('unread chats: muted and archived skipped, "mark as unread" counts', () {
    expect(unreadChatsCount(chats), 2);
  });

  Future<(FakeBadge, MemoryStore)> pump(WidgetTester t, {bool grant = true, bool on = false}) async {
    final badge = FakeBadge(grant: grant);
    final store = MemoryStore();
    if (on) store.map['icon_badge'] = '1';
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          appBadgeProvider.overrideWithValue(badge),
          chatsProvider.overrideWith((ref) async => chats),
        ],
        child: Consumer(
          builder: (context, ref, _) => AppBadgeSync(
            child: GestureDetector(
              key: const ValueKey('toggle'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setIconBadge(ref, !(ref.read(iconBadgeEnabledProvider).value ?? false)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    return (badge, store);
  }

  testWidgets('off by default → icon cleared, iOS not asked', (t) async {
    final (badge, _) = await pump(t);
    expect(badge.sets, [0]);
    expect(badge.asked, 0);
  });

  testWidgets('turned on → asks iOS, shows the unread count; off → clears', (t) async {
    final (badge, store) = await pump(t);
    await t.tap(find.byKey(const ValueKey('toggle')));
    await t.pumpAndSettle();
    expect(badge.asked, 1);
    expect(store.map['icon_badge'], '1');
    expect(badge.sets.last, 2);

    await t.tap(find.byKey(const ValueKey('toggle')));
    await t.pumpAndSettle();
    expect(badge.sets.last, 0);
  });

  testWidgets('permission refused → stays off', (t) async {
    final (badge, store) = await pump(t, grant: false);
    await t.tap(find.byKey(const ValueKey('toggle')));
    await t.pumpAndSettle();
    expect(store.map['icon_badge'], '0');
    expect(badge.sets, [0]);
  });

  testWidgets('already on at launch → count set without asking again', (t) async {
    final (badge, _) = await pump(t, on: true);
    expect(badge.sets, [2]);
    expect(badge.asked, 0);
  });
}
