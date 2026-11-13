// Integration test: verify the Rust↔Dart bridge works end-to-end.
// Loads the Rust binary, calls greet() and coreVersion() synchronously,
// asserts both return non-empty strings.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sinhron/src/rust/api/simple.dart';
import 'package:sinhron/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  test('greet() round-trips a string through Rust', () {
    expect(greet(name: 'Tom'), 'Hello, Tom!');
  });

  test('coreVersion() returns a non-empty descriptor', () {
    final v = coreVersion();
    expect(v, contains('sinhron_core'));
    expect(v, contains('frb 2.11.1'));
  });
}
