// Overnight item 4 (2026-10-16) — a release build has no dead buttons and
// no design-gallery people. Source-level guard: it reads lib/ as text.
//
//   • An empty handler (`onTap: () {}` and friends) is allowed only when it
//     deliberately swallows taps (marked "absorbs taps").
//   • The wiring in navigation.dart names no sample person.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final emptyHandler = RegExp(r'\bon[A-Z]\w*\s*:\s*\(\)\s*\{\s*\}');

const demoNames = ['Maria Chen', 'Vera Kuznetsova', 'Henry Park', 'Cabin Studio', 'cabin.sinhron.app', 'Today · 14:22'];

void main() {
  final files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.endsWith('.dart') && !p.contains('/src/rust/') && !p.contains('/gen/'))
          .toList()
        ..sort();

  test('no empty handlers', () {
    final offenders = <String>[];
    for (final path in files) {
      for (final (i, line) in File(path).readAsLinesSync().indexed) {
        if (emptyHandler.hasMatch(line) && !line.contains('absorbs taps')) {
          offenders.add('$path:${i + 1}: ${line.trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'connect it to a real action, hide it, or pass null');
  });

  test('the wiring names no sample person', () {
    final offenders = <String>[];
    for (final (i, line) in File('lib/app/navigation.dart').readAsLinesSync().indexed) {
      if (line.trimLeft().startsWith('//')) continue;
      for (final d in demoNames) {
        if (line.contains(d)) offenders.add('navigation.dart:${i + 1}: ${line.trim()}');
      }
    }
    expect(offenders, isEmpty);
  });
}
