// Appearance — UI backlog §5 items 42-43: a real theme switch (System /
// Light / Dark / OLED black), accent colour and chat wallpaper. All are
// local settings in the encrypted DB; nothing leaves the device.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/providers/settings_providers.dart';
import 'tokens.dart';

enum ThemeChoice { system, light, dark, oled }

/// Accent options (name → light-theme colour; dark derives a brighter
/// tone so contrast on dark surfaces holds). All pass WCAG AA (4.5:1)
/// under white text — test/design/contrast_test.dart.
const kAccents = <String, Color>{
  'blue': Color(0xFF2864DE),
  'violet': Color(0xFF7C3AED),
  'green': Color(0xFF128558),
  'orange': Color(0xFFBA5A08),
  'pink': Color(0xFFD92776),
  'graphite': Color(0xFF4B5563),
};

enum Wallpaper { none, dawn, mist, dusk, dots, waves, photo }

final themeChoiceProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('theme', 'system'));
final accentProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('accent', 'blue'));
final wallpaperProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('wallpaper', 'none'));

ThemeChoice parseTheme(String? s) =>
    ThemeChoice.values.firstWhere((t) => t.name == s, orElse: () => ThemeChoice.system);
Wallpaper parseWallpaper(String? s) => Wallpaper.values.firstWhere((w) => w.name == s, orElse: () => Wallpaper.none);

/// One chat's own wallpaper (owner, 2026-11-03: "change the wallpaper for a
/// specific chat") — same names as [wallpaperProvider], '' = as in all chats.
/// Local to this device, not synced.
final chatWallpaperProvider = AsyncNotifierProvider.family<StringSetting, String, String>(
  (chatId) => StringSetting('wallpaper:$chatId', ''),
);

/// What a chat shows: its own wallpaper when set, else the one for all chats.
Wallpaper resolveWallpaper(String? chatOwn, String? global) =>
    parseWallpaper((chatOwn ?? '').isEmpty ? global : chatOwn);

/// Pure black for OLED screens: darker surfaces, same text / accents.
const DsTokens oledTokens = DsTokens(
  bg: Color(0xFF000000),
  bgSoft: Color(0xFF0B0B0D),
  surface: Color(0xFF121316),
  elevated: Color(0xFF18191D),
  divider: Color(0x14FFFFFF),
  dividerStrong: Color(0x22FFFFFF),
  text: Color(0xFFECEEF1),
  text2: Color(0xFFA6AFBD),
  text3: Color(0xFF7A8496),
  text4: Color(0xFF4A5365),
  accent: Color(0xFF4F8AFF),
  accentSoft: Color(0x294F8AFF),
  accentText: Color(0xFFFFFFFF),
  danger: Color(0xFFFF5A5A),
  dangerSoft: Color(0x29FF5A5A),
  success: Color(0xFF2BC58A),
  avatarShadeStops: [Color(0x1AFFFFFF), Color(0x00FFFFFF), Color(0x2E000000)],
  avatarShadeOffsets: [0.0, 0.4, 1.0],
  shadowRow: [],
  shadowSoft: [],
  shadowFab: [BoxShadow(color: Color(0x594F8AFF), offset: Offset(0, 6), blurRadius: 16)],
  radiusCard: 18,
  radiusPill: 999,
  radiusBubble: 14,
);

Color _mix(Color a, Color b, double t) => Color.lerp(a, b, t)!;

/// [base] with the user's accent. Dark themes get a lighter tone of it.
DsTokens withAccent(DsTokens base, String accentName, {required bool dark}) {
  final c = kAccents[accentName];
  if (c == null || accentName == 'blue') return base;
  final accent = dark ? _mix(c, const Color(0xFFFFFFFF), 0.18) : c;
  return DsTokens(
    bg: base.bg,
    bgSoft: base.bgSoft,
    surface: base.surface,
    elevated: base.elevated,
    divider: base.divider,
    dividerStrong: base.dividerStrong,
    text: base.text,
    text2: base.text2,
    text3: base.text3,
    text4: base.text4,
    accent: accent,
    accentSoft: dark ? accent.withValues(alpha: 0.16) : _mix(accent, const Color(0xFFFFFFFF), 0.88),
    accentText: base.accentText,
    danger: base.danger,
    dangerSoft: base.dangerSoft,
    success: base.success,
    avatarShadeStops: base.avatarShadeStops,
    avatarShadeOffsets: base.avatarShadeOffsets,
    shadowRow: base.shadowRow,
    shadowSoft: base.shadowSoft,
    shadowFab: [BoxShadow(color: accent.withValues(alpha: 0.3), offset: const Offset(0, 6), blurRadius: 16)],
    radiusCard: base.radiusCard,
    radiusPill: base.radiusPill,
    radiusBubble: base.radiusBubble,
  );
}

/// Tokens + darkness for a theme choice and the platform brightness.
(DsTokens, bool) resolveTheme(ThemeChoice choice, Brightness platform, String accent) {
  final (base, dark) = switch (choice) {
    ThemeChoice.light => (DsTokens.light, false),
    ThemeChoice.dark => (DsTokens.dark, true),
    ThemeChoice.oled => (oledTokens, true),
    ThemeChoice.system => platform == Brightness.dark ? (DsTokens.dark, true) : (DsTokens.light, false),
  };
  return (withAccent(base, accent, dark: dark), dark);
}

// ─── Wallpaper ────────────────────────────────────────────────────

/// Where a user's own wallpaper photo lives (app-private, local only).
Future<File> wallpaperPhotoFile() async {
  final dir = await getApplicationSupportDirectory();
  return File('${dir.path}/wallpaper.jpg');
}

/// The user's own wallpaper photo, re-read whenever it changes
/// ([WallpaperPhoto.replace]). It is handed to Flutter as bytes: the file
/// keeps one path, and a path-keyed image stayed cached — a new photo
/// showed only after leaving the chat and coming back.
final wallpaperPhotoProvider = AsyncNotifierProvider<WallpaperPhoto, Uint8List?>(WallpaperPhoto.new);

class WallpaperPhoto extends AsyncNotifier<Uint8List?> {
  @override
  Future<Uint8List?> build() async {
    try {
      final f = await wallpaperPhotoFile();
      return await f.exists() ? await f.readAsBytes() : null;
    } catch (_) {
      return null;
    }
  }

  /// Save [bytes] as the photo; every visible wallpaper shows it at once.
  Future<void> replace(Uint8List bytes) async {
    final f = await wallpaperPhotoFile();
    await f.writeAsBytes(bytes, flush: true);
    state = AsyncData(bytes);
  }
}

/// The chat background. Subtle by design: patterns are a few percent
/// opacity of the text colour so bubbles keep their contrast.
class ChatWallpaper extends ConsumerWidget {
  const ChatWallpaper({super.key, required this.child, this.preview, this.chatId});
  final Widget child;

  /// This chat's own wallpaper wins over the global one ([chatWallpaperProvider]).
  final String? chatId;

  /// Preview a choice (settings) instead of the saved one.
  final Wallpaper? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = chatId;
    final own = id == null ? null : ref.watch(chatWallpaperProvider(id)).value;
    final w = preview ?? resolveWallpaper(own, ref.watch(wallpaperProvider).value);
    final tokens = DsTheme.of(context);
    final dark = DsTheme.isDarkOf(context);
    Widget? bg;
    switch (w) {
      case Wallpaper.none:
        return child;
      case Wallpaper.dawn || Wallpaper.mist || Wallpaper.dusk:
        final colors = switch (w) {
          Wallpaper.dawn =>
            dark ? const [Color(0xFF1B1530), Color(0xFF2A1B2E)] : const [Color(0xFFFFF1E6), Color(0xFFF7E4F2)],
          Wallpaper.mist =>
            dark ? const [Color(0xFF0E1B24), Color(0xFF12222A)] : const [Color(0xFFE8F3F7), Color(0xFFEFF5EA)],
          _ => dark ? const [Color(0xFF151A2E), Color(0xFF0E1320)] : const [Color(0xFFE9ECFB), Color(0xFFF6EEF9)],
        };
        bg = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
          ),
        );
      case Wallpaper.dots || Wallpaper.waves:
        bg = CustomPaint(
          painter: _PatternPainter(waves: w == Wallpaper.waves, color: tokens.text.withValues(alpha: 0.05)),
        );
      case Wallpaper.photo:
        bg = const _PhotoWallpaper();
    }
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: ColoredBox(color: tokens.bg, child: bg),
        ),
        child,
      ],
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({required this.waves, required this.color});
  final bool waves;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    if (!waves) {
      for (var y = 12.0; y < size.height; y += 24) {
        for (var x = (y ~/ 24).isEven ? 12.0 : 24.0; x < size.width; x += 24) {
          canvas.drawCircle(Offset(x, y), 1.6, p);
        }
      }
      return;
    }
    p
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    for (var y = 0.0; y < size.height + 30; y += 30) {
      final path = Path()..moveTo(0, y);
      for (var x = 0.0; x <= size.width; x += 6) {
        path.lineTo(x, y + math.sin(x / 22) * 6);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) => old.waves != waves || old.color != color;
}

class _PhotoWallpaper extends ConsumerWidget {
  const _PhotoWallpaper();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(wallpaperPhotoProvider).value;
    if (bytes == null) return const SizedBox.expand();
    final w = MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context);
    // Dimmed so bubbles stay readable on any photo.
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(bytes, fit: BoxFit.cover, cacheWidth: w.round(), gaplessPlayback: true),
        ColoredBox(color: DsTheme.of(context).bg.withValues(alpha: 0.35)),
      ],
    );
  }
}
