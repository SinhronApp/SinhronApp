import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/widgets/ds_icon.dart';
import 'package:sinhron/widgets/ds_tab_bar.dart';

void main() {
  Widget bar(int? badge) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: DsTabBar(
            active: DsTabId.chats,
            items: [DsTabItem(id: DsTabId.chats, label: 'Chats', icon: DsIconShape.tabChats, badge: badge)],
          ),
        ),
      ),
    ),
  );

  // Owner, 2026-10-15: a "0" bubble sat on the Chats tab.
  testWidgets('no unread → no badge; some → the number', (t) async {
    await t.pumpWidget(bar(0));
    expect(find.text('0'), findsNothing);
    await t.pumpWidget(bar(3));
    expect(find.text('3'), findsOneWidget);
  });
}
