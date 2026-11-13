// "Did you write it down?" — UI backlog §6 item 50. After "I've written
// them down", the user picks two of their 24 words (by position) out of
// four choices each (ADR-059: was three — enough to catch a skipped or
// misordered copy, short enough not to annoy). Gentle: a miss says which
// word to look at again, no penalty, and they can go back any time.

import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_pressable.dart';
import '../../l10n/l10n.dart';

class PhraseQuestion {
  const PhraseQuestion(this.position, this.answer, this.options);

  /// 1-based word number.
  final int position;
  final String answer;
  final List<String> options;
}

/// How many words the check asks for.
const kPhraseCheckWords = 2;

/// [kPhraseCheckWords] questions at distinct random positions; each offers
/// the right word plus three other words from the same phrase, shuffled.
List<PhraseQuestion> buildPhraseQuiz(List<String> words, [Random? rng]) {
  final r = rng ?? Random.secure();
  final positions = (List.generate(words.length, (i) => i)..shuffle(r)).take(kPhraseCheckWords).toList()..sort();
  return [
    for (final p in positions)
      () {
        final others = <String>{};
        while (others.length < 3) {
          final w = words[r.nextInt(words.length)];
          if (w != words[p]) others.add(w);
        }
        final opts = [words[p], ...others]..shuffle(r);
        return PhraseQuestion(p + 1, words[p], opts);
      }(),
  ];
}

/// Full-screen check. Pops `true` when all are right.
Future<bool> showPhraseCheck(BuildContext context, List<String> words) async {
  final ok = await Navigator.of(context).push<bool>(
    PageRouteBuilder<bool>(
      transitionDuration: DsMotion.of(context, DsMotion.base),
      pageBuilder: (_, _, _) => PhraseCheckScreen(quiz: buildPhraseQuiz(words)),
      transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    ),
  );
  return ok ?? false;
}

class PhraseCheckScreen extends StatefulWidget {
  const PhraseCheckScreen({super.key, required this.quiz});
  final List<PhraseQuestion> quiz;

  @override
  State<PhraseCheckScreen> createState() => _PhraseCheckScreenState();
}

class _PhraseCheckScreenState extends State<PhraseCheckScreen> {
  int _step = 0;
  String? _wrong;

  void _pick(String w) {
    final q = widget.quiz[_step];
    if (w != q.answer) {
      DsHaptics.play(Haptic.error);
      setState(() => _wrong = w);
      return;
    }
    DsHaptics.play(Haptic.selection);
    if (_step == widget.quiz.length - 1) {
      DsHaptics.play(Haptic.success);
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _step++;
      _wrong = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final q = widget.quiz[_step];
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.fromLTRB(DsSpace.x6, pad.top + DsSpace.x6, DsSpace.x6, pad.bottom + DsSpace.x4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.quickCheck, style: DsText.title1.copyWith(color: tokens.text)),
            const SizedBox(height: DsSpace.x2),
            Text(
              context.l10n.quickCheckBody(_step + 1, widget.quiz.length),
              style: DsText.callout.copyWith(color: tokens.text2),
            ),
            const SizedBox(height: DsSpace.x8),
            AnimatedSwitcher(
              duration: DsMotion.of(context, DsMotion.base),
              child: Column(
                key: ValueKey(_step),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.whichWord(q.position), style: DsText.title3.copyWith(color: tokens.text)),
                  const SizedBox(height: DsSpace.x4),
                  Wrap(
                    spacing: DsSpace.x3,
                    runSpacing: DsSpace.x3,
                    children: [
                      for (final o in q.options)
                        DsPressable(
                          key: ValueKey('phrase-option-$o'),
                          onTap: () => _pick(o),
                          child: AnimatedContainer(
                            duration: DsMotion.of(context, DsMotion.fast),
                            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x5, vertical: DsSpace.x3),
                            decoration: BoxDecoration(
                              color: o == _wrong ? tokens.dangerSoft : tokens.bgSoft,
                              borderRadius: BorderRadius.circular(tokens.radiusPill),
                            ),
                            child: Text(
                              o,
                              style: DsText.bodyLarge.copyWith(
                                fontFamily: DsType.familyMono,
                                color: o == _wrong ? tokens.danger : tokens.text,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: DsSpace.x4),
                  AnimatedOpacity(
                    opacity: _wrong == null ? 0 : 1,
                    duration: DsMotion.of(context, DsMotion.fast),
                    child: Text(
                      context.l10n.wrongWord(q.position),
                      key: const ValueKey('phrase-wrong'),
                      style: DsText.subhead.copyWith(color: tokens.danger),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            DsButton(
              key: const ValueKey('phrase-back'),
              label: context.l10n.showWordsAgain,
              variant: DsButtonVariant.ghost,
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
  }
}
