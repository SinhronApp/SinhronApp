import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinhron/app/theme/tokens.dart';

/// Load the bundled Geist + Geist Mono fonts so golden snapshots render
/// with real glyphs instead of the default Ahem placeholder.
/// Called from setUpAll() in golden tests.
Future<void> loadAppFonts() async {
  for (final entry in <String, List<String>>{
    'Geist': [
      'assets/fonts/Geist-Regular.ttf',
      'assets/fonts/Geist-Medium.ttf',
      'assets/fonts/Geist-SemiBold.ttf',
      'assets/fonts/Geist-Bold.ttf',
    ],
    'GeistMono': [
      'assets/fonts/GeistMono-Regular.ttf',
      'assets/fonts/GeistMono-Medium.ttf',
    ],
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
  }
}

/// Wrap a widget in [DsTheme] + [DefaultTextStyle] for tests. Sizes the
/// surface to an iPhone-14-ish viewport unless [size] is overridden.
Widget wrapForGolden({
  required Widget child,
  required bool isDark,
  Size size = const Size(390, 844),
}) {
  final tokens = isDark ? DsTokens.dark : DsTokens.light;
  return MediaQuery(
    data: MediaQueryData(size: size, devicePixelRatio: 1.0),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: DsTheme(
        tokens: tokens,
        isDark: isDark,
        child: DefaultTextStyle(
          style: TextStyle(
            fontFamily: DsType.family,
            color: tokens.text,
            fontSize: 14,
          ),
          child: ColoredBox(
            color: tokens.bg,
            child: Center(child: child),
          ),
        ),
      ),
    ),
  );
}
