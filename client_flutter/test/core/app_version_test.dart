// The version under Settings → About is the one in pubspec.yaml (owner,
// 2026-10-16: every update must show a new version, so it's clear which one
// is installed — the pubspec is what TestFlight / the APK carry).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/settings/settings_screen.dart';

void main() {
  test('Settings shows the pubspec version', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    final name = line.substring('version:'.length).trim().split('+').first;
    expect(kAppVersion, name, reason: 'raise kAppVersion together with pubspec `version`');
  });

  test('the build number is shown next to the version when the release script passes it', () {
    expect(appVersionLabel('0.2.0', ''), '0.2.0');
    expect(appVersionLabel('0.2.0', '202610160530'), '0.2.0 (202610160530)');
  });
}
