import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/call_video.dart';

void main() {
  Widget host(Widget child) => DsTheme(
    tokens: DsTokens.light,
    isDark: false,
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: SizedBox(width: 180, height: 240, child: child)),
    ),
  );

  // Owner, 2026-10-15: group call tiles showed the first letters of a key.
  testWidgets('a tile shows the name, a ring while speaking, a crossed mic when muted', (t) async {
    await t.pumpWidget(host(const CallTile(name: 'Вера', compact: true, speaking: true, micOff: true)));
    expect(find.text('Вера'), findsOneWidget);
    expect(find.byKey(const ValueKey('tile-mic-off')), findsOneWidget);
    final box = t.widget<Container>(find.byType(Container).first).decoration! as BoxDecoration;
    expect(box.border, isNotNull, reason: 'speaking ring');

    await t.pumpWidget(host(const CallTile(name: 'Вера', compact: true)));
    expect(find.byKey(const ValueKey('tile-mic-off')), findsNothing);
    final quiet = t.widget<Container>(find.byType(Container).first).decoration! as BoxDecoration;
    expect(quiet.border, isNull);
  });
}
