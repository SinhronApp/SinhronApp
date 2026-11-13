// Settings → Appearance — UI backlog §5 items 42-43. Theme (System /
// Light / Dark / OLED black), accent colour, chat wallpaper with a live
// preview. Everything applies instantly and is stored locally.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme/appearance.dart';
import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/haptics.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_pressable.dart';
import '../chat_view/chat_view_screen.dart' show inBubbleColor;
import '_shared.dart';
import '../../l10n/l10n.dart';

String themeLabel(AppL10n l, ThemeChoice t) => switch (t) {
  ThemeChoice.system => l.themeSystem,
  ThemeChoice.light => l.themeLight,
  ThemeChoice.dark => l.themeDark,
  ThemeChoice.oled => l.themeOled,
};

String wallpaperLabel(AppL10n l, Wallpaper w) => switch (w) {
  Wallpaper.none => l.wallNone,
  Wallpaper.dawn => l.wallDawn,
  Wallpaper.mist => l.wallMist,
  Wallpaper.dusk => l.wallDusk,
  Wallpaper.dots => l.wallDots,
  Wallpaper.waves => l.wallWaves,
  Wallpaper.photo => l.wallPhoto,
};

class AppearanceScreen extends ConsumerWidget {
  const AppearanceScreen({super.key, this.onBack});
  final VoidCallback? onBack;

  Future<void> _pickPhoto(WidgetRef ref) async {
    final XFile? x;
    final Uint8List bytes;
    try {
      x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 2048, requestFullMetadata: false);
      if (x == null) return;
      bytes = await x.readAsBytes();
    } catch (_) {
      appNotice.value = lookupAppL10n(Locale(currentLanguage)).photoCouldNotUse;
      return;
    }
    try {
      await File(x.path).delete();
    } catch (_) {}
    await ref.read(wallpaperPhotoProvider.notifier).replace(bytes);
    await ref.read(wallpaperProvider.notifier).save(Wallpaper.photo.name);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final theme = parseTheme(ref.watch(themeChoiceProvider).value);
    final accent = ref.watch(accentProvider).value ?? 'blue';
    final wallpaper = parseWallpaper(ref.watch(wallpaperProvider).value);

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: context.l10n.appearance, onBack: onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(0, DsSpace.x2, 0, pad.bottom + DsSpace.x6),
                children: [
                  // Live preview of a chat with the current choices.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.gutter),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(tokens.radiusCard),
                      child: ChatWallpaper(child: _PreviewBubbles(tokens: tokens)),
                    ),
                  ),
                  SettingsSection(
                    title: context.l10n.theme,
                    children: [
                      for (final t in ThemeChoice.values)
                        SettingsRow(
                          key: ValueKey('theme-${t.name}'),
                          label: themeLabel(context.l10n, t),
                          selected: t == theme,
                          onTap: () {
                            DsHaptics.play(Haptic.selection);
                            ref.read(themeChoiceProvider.notifier).save(t.name);
                          },
                          isLast: t == ThemeChoice.oled,
                        ),
                    ],
                  ),
                  SettingsSection(
                    title: context.l10n.accentColour,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x3),
                        child: Wrap(
                          spacing: DsSpace.x3,
                          runSpacing: DsSpace.x3,
                          children: [
                            for (final e in kAccents.entries)
                              Semantics(
                                button: true,
                                selected: e.key == accent,
                                label: accentName(context.l10n, e.key),
                                excludeSemantics: true,
                                onTap: () => ref.read(accentProvider.notifier).save(e.key),
                                child: DsPressable(
                                key: ValueKey('accent-${e.key}'),
                                haptic: Haptic.selection,
                                scale: 0.9,
                                onTap: () => ref.read(accentProvider.notifier).save(e.key),
                                child: AnimatedContainer(
                                  duration: DsMotion.of(context, DsMotion.base),
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: e.value,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: e.key == accent ? tokens.text : DsPalette.transparent,
                                      width: 2.5,
                                    ),
                                  ),
                                ),
                              ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: context.l10n.chatWallpaper,
                    footer: context.l10n.wallpaperFooter,
                    children: [
                      WallpaperGrid(
                        selected: wallpaper,
                        onPick: (w) =>
                            w == Wallpaper.photo ? _pickPhoto(ref) : ref.read(wallpaperProvider.notifier).save(w.name),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The wallpaper tiles — Settings → Appearance and a chat's own wallpaper
/// (chat info). [selected] null highlights none; [withPhoto] off hides
/// "Your photo" (there is one photo for all chats).
class WallpaperGrid extends StatelessWidget {
  const WallpaperGrid({super.key, required this.selected, required this.onPick, this.withPhoto = true});
  final Wallpaper? selected;
  final ValueChanged<Wallpaper> onPick;
  final bool withPhoto;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(DsSpace.x3),
        children: [
          for (final w in Wallpaper.values)
            if (withPhoto || w != Wallpaper.photo)
              Padding(
                padding: const EdgeInsets.only(right: DsSpace.x2),
                child: DsPressable(
                  key: ValueKey('wallpaper-${w.name}'),
                  haptic: Haptic.selection,
                  onTap: () => onPick(w),
                  child: Column(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: w == selected ? tokens.accent : tokens.dividerStrong,
                            width: w == selected ? 2 : 1,
                          ),
                        ),
                        child: w == Wallpaper.photo
                            ? Center(child: Text('+', style: DsText.title3.copyWith(color: tokens.text3)))
                            : ChatWallpaper(preview: w, child: const SizedBox.expand()),
                      ),
                      const SizedBox(height: DsSpace.x1),
                      Text(wallpaperLabel(context.l10n, w), style: DsText.caption.copyWith(color: tokens.text2)),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// A short chat on the chosen wallpaper (owner, 2026-11-03: "two messages
/// and one emoji and that's it") — both sides, times, read ticks, a reply.
/// Same colours as the real bubbles in the chat.
class _PreviewBubbles extends StatelessWidget {
  const _PreviewBubbles({required this.tokens});
  final DsTokens tokens;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    Widget bubble(String text, String time, {bool out = false, String? quote}) {
      final fg = out ? DsPalette.white : tokens.text;
      final meta = out ? DsPalette.white78 : tokens.text3;
      return Align(
        alignment: out ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 270),
          margin: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x1, DsSpace.x3, DsSpace.x1),
          padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x1h5, DsSpace.x2h5, DsSpace.x1h5),
          decoration: out
              ? BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [tokens.accent, Color.lerp(tokens.accent, DsPalette.indigo, 0.22)!],
                  ),
                  borderRadius: BorderRadius.circular(18),
                )
              : BoxDecoration(color: inBubbleColor(context), borderRadius: BorderRadius.circular(18)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (quote != null)
                Container(
                  margin: const EdgeInsets.only(bottom: DsSpace.x1),
                  padding: const EdgeInsets.fromLTRB(DsSpace.x2, DsSpace.x1, DsSpace.x2, DsSpace.x1),
                  decoration: BoxDecoration(
                    color: tokens.accent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(left: BorderSide(color: tokens.accent, width: 3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.you, style: DsText.caption.copyWith(color: tokens.accent, fontWeight: FontWeight.w600)),
                      Text(
                        quote,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsText.caption.copyWith(color: tokens.text2),
                      ),
                    ],
                  ),
                ),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.end,
                spacing: DsSpace.x1h5,
                children: [
                  Text(text, style: DsText.body.copyWith(color: fg)),
                  Padding(
                    padding: const EdgeInsets.only(top: DsSpace.x1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(time, style: DsText.caption.copyWith(height: 1.0, color: meta)),
                        // Read ticks, light blue as in the chat.
                        if (out) ...[
                          const SizedBox(width: 3),
                          const DsIcon(shape: DsIconShape.doubleCheck, size: 14, color: DsPalette.artA8E6FF),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    // Sized by its bubbles: no overflow with large text.
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DsSpace.x3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            bubble(l.previewIn, '18:02'),
            bubble(l.previewOut, '18:03', out: true),
            bubble(l.previewReply, '18:05', quote: l.previewOut),
            bubble(l.previewSure, '18:06', out: true),
          ],
        ),
      ),
    );
  }
}

/// The accent's name for VoiceOver ("Blue, selected").
String accentName(AppL10n l, String key) => switch (key) {
  'violet' => l.accentViolet,
  'green' => l.accentGreen,
  'orange' => l.accentOrange,
  'pink' => l.accentPink,
  'graphite' => l.accentGraphite,
  _ => l.accentBlue,
};
