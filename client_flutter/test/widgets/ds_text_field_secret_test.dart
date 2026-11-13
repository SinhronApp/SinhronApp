// Audit storage-devices:18 — the 24 words typed with autocorrect, suggestions
// and keyboard learning on: the keyboard kept them.

import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/widgets/ds_text_field.dart';

Future<CupertinoTextField> field(WidgetTester t, TextInputType type) async {
  await t.pumpWidget(
    DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: Directionality(textDirection: TextDirection.ltr, child: DsTextField(keyboardType: type)),
    ),
  );
  return t.widget<CupertinoTextField>(find.byType(CupertinoTextField));
}

void main() {
  testWidgets('the 24-word fields: the keyboard does not learn, suggest or correct them', (t) async {
    final f = await field(t, TextInputType.visiblePassword);
    expect(f.autocorrect, isFalse);
    expect(f.enableSuggestions, isFalse);
    expect(f.enableIMEPersonalizedLearning, isFalse);
    expect(f.smartDashesType, SmartDashesType.disabled);
    expect(f.smartQuotesType, SmartQuotesType.disabled);
  });

  testWidgets('ordinary fields keep the keyboard help', (t) async {
    final f = await field(t, TextInputType.text);
    expect(f.autocorrect, isTrue);
    expect(f.enableSuggestions, isTrue);
    expect(f.enableIMEPersonalizedLearning, isTrue);
  });
}
