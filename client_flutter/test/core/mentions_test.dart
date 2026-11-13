// Tech-debt 2.21 — @-mentions: wire tokens ↔ what people see.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/mentions.dart';

final anna = 'a1' * 32;
final annaLee = 'a2' * 32;
final me = 'ee' * 32;

String nameOf(String k) => {anna: 'Аня', annaLee: 'Аня Ли', me: 'вы'}[k] ?? '?';

void main() {
  test('composer names become tokens: longest first, whole words only', () {
    final picked = {'Аня': anna, 'Аня Ли': annaLee};
    expect(encodeMentions('@Аня Ли и @Аня, привет', picked), '${mentionOf(annaLee)} и ${mentionOf(anna)}, привет');
    expect(encodeMentions('@Аняша', picked), '@Аняша', reason: 'not a whole name');
    expect(encodeMentions('почта a@Аня', {'Аня': anna}), 'почта a${mentionOf(anna)}');
    expect(encodeMentions('@Аня', const {}), '@Аня');
  });

  test('tokens show as names; mentionsKey finds me', () {
    final text = 'смотри ${mentionOf(me)} и ${mentionOf(anna)}';
    expect(mentionsToDisplay(text, nameOf), 'смотри @вы и @Аня');
    expect(mentionsKey(text, me), isTrue);
    expect(mentionsKey(text, 'ff' * 32), isFalse);
    expect(mentionsKey(text, null), isFalse);
    expect(mentionsToDisplay('@[nothex]', nameOf), '@[nothex]', reason: 'only real keys are tokens');
  });

  test('editing round-trips', () {
    final stored = 'ок ${mentionOf(annaLee)}!';
    final (shown, picked) = decodeForEditing(stored, nameOf);
    expect(shown, 'ок @Аня Ли!');
    expect(encodeMentions(shown, picked), stored);
  });
}
