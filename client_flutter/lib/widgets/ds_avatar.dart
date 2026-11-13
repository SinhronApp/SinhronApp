import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import 'ds_icon.dart';

/// Pale fill + coloured initials for [seed]. The first tint (blue) is kept
/// for Saved messages (ADR-055); people share the rest.
(Color, Color) _tint(String seed, bool dark, {bool saved = false}) {
  final list = dark ? kAvatarTintsDark : kAvatarTints;
  return list[saved ? 0 : 1 + _hashIdx(seed, list.length - 1)];
}

int _hashIdx(String s, int n) {
  var h = 0;
  for (var i = 0; i < s.length; i++) {
    h = (h * 31 + s.codeUnitAt(i)) & 0xFFFFFFFF;
  }
  // 31 leaves 1 when divided by 2, 3, 5, 6 or 10, so for a short name
  // `h % n` alone was just the sum of its letters: "Мама" and "Папа" fell
  // on one colour. Stir the bits first (the last step of MurmurHash3).
  h ^= h >> 16;
  h = (h * 0x85EBCA6B) & 0xFFFFFFFF;
  h ^= h >> 13;
  h = (h * 0xC2B2AE35) & 0xFFFFFFFF;
  h ^= h >> 16;
  return h % n;
}

/// The initials colour of the avatar for [seed] — the same person gets
/// the same hue everywhere (group sender names, tech-debt 2.22).
Color dsAvatarAccent(String seed, {required bool dark}) => _tint(seed, dark).$2;

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

  /// On the call screen, dark in every theme: the dark-theme pair and a
  /// hairline ring, so the disc neither glares nor sinks into the navy.
  final bool onDark;

  const DsAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.group = false,
    this.online = false,
    this.image,
    this.saved = false,
    this.onDark = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final (fill, fg) = _tint(name, onDark || DsTheme.isDarkOf(context), saved: saved);
    final initials = _initials(name);

    final circle = DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: onDark ? Border.all(color: DsPalette.white16) : null,
      ),
      child: Center(
        child: saved
            ? DsIcon(shape: DsIconShape.bookmark, size: size * 0.46, color: fg, strokeWidth: 1.2)
            : group
            ? DsIcon(shape: DsIconShape.groupSilhouette, size: size * 0.5, color: fg)
            : Text(initials, style: DsType.avatarInitials(size, fg)),
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
