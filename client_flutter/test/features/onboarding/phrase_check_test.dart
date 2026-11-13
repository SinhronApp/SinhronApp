import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/onboarding/phrase_check.dart';

final words = List.generate(24, (i) => 'word$i');

void main() {
  test('two distinct positions (ADR-059), right word among four distinct options', () {
    for (var seed = 0; seed < 50; seed++) {
      final quiz = buildPhraseQuiz(words, Random(seed));
      expect(quiz.length, 2);
      expect(quiz.map((q) => q.position).toSet().length, 2);
      for (final q in quiz) {
        expect(q.answer, words[q.position - 1]);
        expect(q.options.toSet().length, 4);
        expect(q.options, contains(q.answer));
      }
    }
  });

  testWidgets('a miss is explained; two right answers finish', (t) async {
    final quiz = buildPhraseQuiz(words, Random(1));
    bool? result;
    await t.pumpWidget(DsTheme(
      tokens: DsTokens.light,
      isDark: false,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(390, 844)),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder(
              pageBuilder: (ctx, _, _) => Center(
                child: GestureDetector(
                  onTap: () async => result = await Navigator.of(ctx).push<bool>(
                    PageRouteBuilder(pageBuilder: (_, _, _) => PhraseCheckScreen(quiz: quiz)),
                  ),
                  child: const Text('start'),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('start'));
    await t.pumpAndSettle();

    final wrong = quiz[0].options.firstWhere((o) => o != quiz[0].answer);
    await t.tap(find.byKey(ValueKey('phrase-option-$wrong')));
    await t.pumpAndSettle();
    expect(find.textContaining('have another look at word #${quiz[0].position}'), findsOneWidget);

    for (final q in quiz) {
      await t.tap(find.byKey(ValueKey('phrase-option-${q.answer}')));
      await t.pumpAndSettle();
    }
    expect(result, isTrue);
  });
}
