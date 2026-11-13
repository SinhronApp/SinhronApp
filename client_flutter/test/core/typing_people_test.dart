// Owner, 2026-10-18 — "several people type in a group — then what?":
// the header names them.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/providers/message_actions.dart';
import 'package:sinhron/l10n/l10n.dart';

void main() {
  test('who types, per chat; a message clears them; quiet ones expire', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final n = c.read(typingPeopleProvider.notifier);
    final t = DateTime(2026, 10, 18, 18);
    n.set('g', 'anya', true, now: t);
    n.set('g', 'boris', true, now: t.add(const Duration(seconds: 4)));
    n.set('g', null, true, now: t); // unknown sender — ignored
    expect(c.read(typingPeopleProvider)['g']!.keys, ['anya', 'boris']);
    n.expire(now: t.add(const Duration(seconds: 7)));
    expect(c.read(typingPeopleProvider)['g']!.keys, ['boris'], reason: 'Аня went quiet');
    n.set('g', 'boris', false);
    expect(c.read(typingPeopleProvider).containsKey('g'), isFalse);
    n.set('g', 'anya', true, now: t);
    n.clear('g');
    expect(c.read(typingPeopleProvider), isEmpty);
  });

  test('the header line: personal chat, one, two, many', () {
    final ru = lookupAppL10n(const Locale('ru'));
    expect(typingLine(ru, ['Аня'], group: false), 'печатает…');
    expect(typingLine(ru, ['Аня'], group: true), 'Аня печатает…');
    expect(typingLine(ru, ['Аня', 'Борис'], group: true), 'Аня и Борис печатают…');
    expect(typingLine(ru, ['a', 'b', 'c'], group: true), '3 человека печатают…');
    expect(typingLine(ru, ['a', 'b', 'c', 'd', 'e'], group: true), '5 человек печатают…');
    final en = lookupAppL10n(const Locale('en'));
    expect(typingLine(en, ['Anya', 'Boris'], group: true), 'Anya and Boris are typing…');
  });
}
