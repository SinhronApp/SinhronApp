import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sinhron/app/theme/tokens.dart';

/// Load the bundled Golos Text + Geist Mono fonts so golden snapshots render
/// with real glyphs instead of the default Ahem placeholder.
/// Called from setUpAll() in golden tests.
Future<void> loadAppFonts() async {
  for (final entry in <String, List<String>>{
    'GolosText': [
      'assets/fonts/GolosText-Regular.ttf',
      'assets/fonts/GolosText-Medium.ttf',
      'assets/fonts/GolosText-SemiBold.ttf',
      'assets/fonts/GolosText-Bold.ttf',
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
  // The system icon font (CupertinoIcons) — without it every system icon
  // is an empty box in the screen shots.
  final packages = (jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map)['packages'] as List;
  final root = packages.firstWhere((p) => (p as Map)['name'] == 'cupertino_icons')['rootUri'] as String;
  final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
    ..addFont(
      File.fromUri(Uri.parse('$root/assets/CupertinoIcons.ttf')).readAsBytes().then(ByteData.sublistView),
    );
  await icons.load();
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
