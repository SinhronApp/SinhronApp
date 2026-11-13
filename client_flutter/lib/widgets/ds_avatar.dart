import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import 'ds_icon.dart';

const List<List<Color>> _avatarPalettes = [
  [DsPalette.peach, DsPalette.salmon], // amber
  [DsPalette.sky, DsPalette.blue500], // blue
  [DsPalette.lilac, DsPalette.violet], // violet
  [DsPalette.mint, DsPalette.emerald], // teal
  [DsPalette.rose200, DsPalette.pink], // pink
  [DsPalette.artFFE08A, DsPalette.amber], // gold
  [DsPalette.artA7C5EB, DsPalette.blue600], // navy
  [DsPalette.artD4B8FF, DsPalette.purple600], // purple
  [DsPalette.artFFCFA5, DsPalette.coral], // peach
  [DsPalette.artB5E2A1, DsPalette.lime600], // olive
];

/// ADR-055 — Saved messages: the "blue" avatar, the same for everyone.
const List<Color> _savedPalette = [DsPalette.sky, DsPalette.blue500];

int _hashIdx(String s, int n) {
  var h = 0;
  for (var i = 0; i < s.length; i++) {
    h = (h * 31 + s.codeUnitAt(i)) & 0xFFFFFFFF;
  }
  return h % n;
}

/// The darker colour of the avatar gradient for [seed] — the same person
/// gets the same hue everywhere (group sender names, tech-debt 2.22).
Color dsAvatarAccent(String seed) => _avatarPalettes[_hashIdx(seed, _avatarPalettes.length)][1];

String _initials(String name) {
  final stripped = name.replaceAll(RegExp(r'^[^A-Za-zА-Яа-яЁё]+'), '');
  final parts = stripped.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) {
    return name.substring(0, name.length >= 2 ? 2 : name.length).toUpperCase();
  }
  if (parts.length == 1) {
    return parts[0].substring(0, parts[0].length >= 2 ? 2 : parts[0].length).toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

class DsAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool group;
  final bool online;

  /// A photo (JPEG bytes) instead of initials — tech-debt 2.21.
  final Uint8List? image;

  /// ADR-055 — my Saved messages: a bookmark on blue, never initials.
  final bool saved;

  const DsAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.group = false,
    this.online = false,
    this.image,
    this.saved = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final palette = saved ? _savedPalette : _avatarPalettes[_hashIdx(name, _avatarPalettes.length)];
    final initials = _initials(name);

    final circle = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette,
          // CSS 150deg ≈ topLeft→bottomRight, slight skew; close enough visually
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Center(
              child: saved
                  ? DsIcon(shape: DsIconShape.bookmark, size: size * 0.46, color: DsPalette.white, strokeWidth: 1.2)
                  : group
                  ? DsIcon(shape: DsIconShape.groupSilhouette, size: size * 0.5, color: DsPalette.white)
                  : Text(initials, style: DsType.avatarInitials(size)),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, gradient: tokens.avatarShade),
            ),
          ),
        ],
      ),
    );

    final photo = image;
    final inner = ClipOval(
      child: photo == null || photo.isEmpty
          ? circle
          : Image.memory(
              photo,
              key: const ValueKey('avatar-photo'),
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: (size * 3).round(),
              errorBuilder: (_, _, _) => circle,
            ),
    );

    if (!online) {
      return SizedBox(width: size, height: size, child: inner);
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: inner),
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: size * 0.28,
              height: size * 0.28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.success,
                border: Border.all(color: tokens.bg, width: 2.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
