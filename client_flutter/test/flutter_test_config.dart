import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Golden PNGs are recorded on macOS: font rasterisation and the local time zone
/// differ elsewhere, so on Linux (CI, cloud sessions) every golden fails by a few
/// percent of anti-aliased pixels. Off macOS the pixel comparison is skipped —
/// every other assertion in those tests still runs. `SINHRON_GOLDENS=strict`
/// compares anyway; `--update-goldens` is untouched.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final strict = Platform.environment['SINHRON_GOLDENS'] == 'strict';
  if (!Platform.isMacOS && !strict && !autoUpdateGoldenFiles) {
    goldenFileComparator = _NonMacGoldenComparator(goldenFileComparator);
  }
  await testMain();
}

class _NonMacGoldenComparator extends GoldenFileComparator {
  _NonMacGoldenComparator(this._inner);
  final GoldenFileComparator _inner;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  @override
  Future<void> update(Uri golden, Uint8List imageBytes) => _inner.update(golden, imageBytes);

  @override
  Uri getTestUri(Uri key, int? version) => _inner.getTestUri(key, version);
}
