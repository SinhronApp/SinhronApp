import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/new_group/new_group_screen.dart';

void main() {
  // The group name field made a new FocusNode on every build, so Done
  // unfocused a fresh node and the keyboard never closed.
  testWidgets('Done on the group name closes the keyboard', (t) async {
    t.view.physicalSize = const Size(390, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      const DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: Size(390, 1200)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: NewGroupScreen(
              contacts: [NewGroupContact(id: 'A', name: 'Аня', subtitle: 'ab12 cd34')],
              me: NewGroupContact(id: 'me', name: 'Гриша', subtitle: 'ef56 7890'),
              initialStep: NewGroupStep.nameAndCreate,
              initialSelected: ['A'],
            ),
          ),
        ),
      ),
    );
    final field = find.byType(EditableText);
    await t.tap(field);
    await t.enterText(field, 'Family');
    await t.pump();
    expect(t.testTextInput.isVisible, isTrue);

    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(t.testTextInput.isVisible, isFalse);
  });
}
