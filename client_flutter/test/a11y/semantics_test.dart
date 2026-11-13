// VoiceOver labels — UI backlog §7 item 55. Checks the semantics tree the
// screen reader sees (a real VoiceOver pass on iPhone is tech-debt 2.29).

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/widgets/ds_chat_row.dart';
import 'package:sinhron/widgets/ds_icon.dart';
import 'package:sinhron/widgets/ds_icon_button.dart';
import 'package:sinhron/widgets/ds_tab_bar.dart';

Widget wrap(Widget child) => DsTheme(
  tokens: DsTokens.light,
  isDark: false,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(375, 812)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topCenter, child: child),
    ),
  ),
);

void main() {
  testWidgets('chat row reads name, unread, pinned, preview and time', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      wrap(
        DsChatRow(
          chat: const ChatPreview(id: 'a', name: 'Maria', preview: 'See you', time: '12:42', unread: 2, pinned: true),
          onTap: () {},
        ),
      ),
    );
    expect(
      t.getSemantics(find.byType(DsChatRow)),
      matchesSemantics(label: 'Maria, 2 unread, pinned, See you, 12:42', isButton: true, hasTapAction: true),
    );
    h.dispose();
  });

  testWidgets('tab bar items announce selection and unread count', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(
      wrap(
        DsTabBar(
          active: DsTabId.chats,
          onSelect: (_) {},
          items: const [
            DsTabItem(id: DsTabId.chats, label: 'Chats', icon: DsIconShape.tabChats, badge: 3),
            DsTabItem(id: DsTabId.settings, label: 'Settings', icon: DsIconShape.tabSettings),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('Chats, 3 unread'), findsOneWidget);
    expect(
      t.getSemantics(find.bySemanticsLabel('Chats, 3 unread')),
      isSemantics(isSelected: true, isButton: true, hasTapAction: true),
    );
    expect(t.getSemantics(find.bySemanticsLabel('Settings')), isSemantics(isSelected: false));
    h.dispose();
  });

  testWidgets('icon button keeps its tap action under a label', (t) async {
    final h = t.ensureSemantics();
    var taps = 0;
    await t.pumpWidget(wrap(DsIconButton(shape: DsIconShape.search, onTap: () => taps++)));
    final node = find.bySemanticsLabel('Search');
    expect(t.getSemantics(node), isSemantics(isButton: true, hasTapAction: true));
    t.semantics.tap(find.semantics.byLabel('Search'));
    expect(taps, 1);
    h.dispose();
  });
}
