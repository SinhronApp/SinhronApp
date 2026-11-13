import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/appearance.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/widgets/ds_empty_state.dart';

void main() {
  for (final (name, tokens, dark) in [
    ('light', DsTokens.light, false),
    ('dark', DsTokens.dark, true),
    ('oled', oledTokens, true),
  ]) {
    testWidgets('every illustration renders in $name', (t) async {
      for (final ill in DsIllustration.values) {
        await t.pumpWidget(DsTheme(
          tokens: tokens,
          isDark: dark,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: DsEmptyState(illustration: ill, title: 'Title ${ill.name}', body: 'Body'),
          ),
        ));
        await t.pumpAndSettle();
        expect(find.byKey(ValueKey('illustration-${ill.name}')), findsOneWidget);
        expect(find.text('Title ${ill.name}'), findsOneWidget);
        expect(t.takeException(), isNull);
      }
    });
  }
}
