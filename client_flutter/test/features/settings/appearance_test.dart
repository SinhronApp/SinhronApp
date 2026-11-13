import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/appearance.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/settings/appearance_screen.dart';

import '../../core/settings_providers_test.dart' show MemoryStore;

void main() {
  test('theme resolution: system follows the platform, OLED is pure black', () {
    expect(resolveTheme(ThemeChoice.system, Brightness.dark, 'blue').$2, isTrue);
    expect(resolveTheme(ThemeChoice.system, Brightness.light, 'blue').$1.bg, DsTokens.light.bg);
    expect(resolveTheme(ThemeChoice.light, Brightness.dark, 'blue').$2, isFalse);
    final (oled, dark) = resolveTheme(ThemeChoice.oled, Brightness.light, 'blue');
    expect(dark, isTrue);
    expect(oled.bg, const Color(0xFF000000));
    expect(parseTheme('nonsense'), ThemeChoice.system);
  });

  test('accent recolours accent tokens only; dark gets a lighter tone', () {
    final (light, _) = resolveTheme(ThemeChoice.light, Brightness.light, 'violet');
    expect(light.accent, kAccents['violet']);
    expect(light.bg, DsTokens.light.bg);
    final (dark, _) = resolveTheme(ThemeChoice.dark, Brightness.light, 'violet');
    expect(dark.accent, isNot(kAccents['violet']));
    expect(dark.accent.computeLuminance(), greaterThan(kAccents['violet']!.computeLuminance()));
  });

  test("a chat's own wallpaper wins over the one for all chats", () {
    expect(resolveWallpaper(null, 'dusk'), Wallpaper.dusk);
    expect(resolveWallpaper('', 'dusk'), Wallpaper.dusk, reason: '"Same as all chats" stores empty');
    expect(resolveWallpaper('dots', 'dusk'), Wallpaper.dots);
    expect(resolveWallpaper('dots', null), Wallpaper.dots);
    expect(resolveWallpaper(null, null), Wallpaper.none);
  });

  testWidgets('the chat screen background uses its own wallpaper', (t) async {
    final store = MemoryStore()
      ..map['wallpaper'] = 'dusk'
      ..map['wallpaper:c1'] = 'dots';
    Widget bg(String chatId) => ProviderScope(
      key: ValueKey(chatId),
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: ChatWallpaper(chatId: chatId, child: const SizedBox.expand()),
        ),
      ),
    );
    await t.pumpWidget(bg('c1'));
    await t.pumpAndSettle();
    expect(find.byType(CustomPaint), findsWidgets, reason: 'dots are painted');
    expect(find.byType(DecoratedBox), findsNothing);
    await t.pumpWidget(bg('c2'));
    await t.pumpAndSettle();
    expect(find.byType(DecoratedBox), findsOneWidget, reason: 'c2 has none of its own: the dusk gradient');
  });

  testWidgets('choosing theme, accent and wallpaper persists them', (t) async {
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final store = MemoryStore();
    await t.pumpWidget(ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      child: const DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: Size(390, 1400)),
          child: Directionality(textDirection: TextDirection.ltr, child: AppearanceScreen()),
        ),
      ),
    ));
    await t.pumpAndSettle();
    // The preview is a short conversation, not two lines (owner, 2026-11-03).
    expect(find.text('Hi! How are you? 👋'), findsOneWidget);
    expect(find.text('Great! We just got back from the mountains 🏔'), findsNWidgets(2), reason: 'and its quote');
    expect(find.text('Of course! 🙌'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('theme-oled')));
    await t.tap(find.byKey(const ValueKey('accent-green')));
    await t.tap(find.byKey(const ValueKey('wallpaper-dots')));
    await t.pumpAndSettle();
    expect(store.map['theme'], 'oled');
    expect(store.map['accent'], 'green');
    expect(store.map['wallpaper'], 'dots');
    expect(find.byType(ChatWallpaper), findsWidgets);
  });

  testWidgets('a new wallpaper photo shows at once, without leaving the chat', (t) async {
    // 1×1 PNGs, one red, one blue.
    final red = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==');
    final blue = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPj/HwADBwIAMCbHYQAAAABJRU5ErkJggg==');
    final container = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        wallpaperPhotoProvider.overrideWith(() => _MemoryPhoto(red)),
      ],
    );
    addTearDown(container.dispose);
    await t.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: MediaQuery(
          data: MediaQueryData(size: Size(390, 600)),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ChatWallpaper(preview: Wallpaper.photo, child: SizedBox.expand()),
          ),
        ),
      ),
    ));
    await t.pump();
    Uint8List shown() => ((t.widget<Image>(find.byType(Image)).image as ResizeImage).imageProvider as MemoryImage).bytes;
    expect(shown(), red);

    await container.read(wallpaperPhotoProvider.notifier).replace(blue);
    await t.pump();
    expect(shown(), blue, reason: 'the same screen shows the new photo');
  });
}

class _MemoryPhoto extends WallpaperPhoto {
  _MemoryPhoto(this._first);
  final Uint8List _first;

  @override
  Future<Uint8List?> build() async => _first;

  @override
  Future<void> replace(Uint8List bytes) async => state = AsyncData(bytes);
}
