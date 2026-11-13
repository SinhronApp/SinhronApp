import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import '../l10n/l10n.dart';
import 'ds_avatar.dart';
import 'ds_icon.dart';
import 'ds_icon_button.dart';
import 'ds_pressable.dart';
import 'ds_spinner.dart';

/// My photo at the top-left of Chats / Calls / Contacts. A tap opens My
/// profile (owner, 2026-10-18: it looked like a button and did nothing).
class DsMyAvatar extends StatelessWidget {
  const DsMyAvatar({super.key, required this.name, this.image, this.size = 34, this.onTap});

  final String name;
  final Uint8List? image;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final avatar = DsAvatar(name: name, size: size, image: image);
    if (onTap == null) return avatar;
    return Semantics(
      button: true,
      label: context.l10n.myProfileTitle,
      excludeSemantics: true,
      onTap: onTap,
      child: DsPressable(key: const ValueKey('header-my-avatar'), scale: 0.92, onTap: onTap, child: avatar),
    );
  }
}

class DsHeader extends StatelessWidget {
  final String userName;

  /// My photo, if I set one (else initials).
  final Uint8List? userImage;
  final String title;
  final VoidCallback? onSearch;
  final VoidCallback? onCompose;

  /// Tap on my photo → My profile.
  final VoidCallback? onProfile;

  /// 0 = large title (top of the list), 1 = compact (scrolled) —
  /// backlog §5 item 41.
  final double collapse;

  /// No connection to the server right now: a spinner before the title (the
  /// caller passes "Connecting…" as [title]) — like Telegram (owner,
  /// 2026-10-16).
  final bool connecting;

  const DsHeader({
    super.key,
    required this.userName,
    this.userImage,
    required this.title,
    this.onSearch,
    this.onCompose,
    this.onProfile,
    this.collapse = 0,
    this.connecting = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final t = collapse.clamp(0.0, 1.0);
    final style = TextStyle.lerp(DsText.title1, DsText.headline, t)!.copyWith(color: tokens.text);
    return Padding(
      padding: EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1h5, DsSpace.x4, DsSpace.x3 - DsSpace.x1h5 * t),
      child: Row(
        children: [
          DsMyAvatar(name: userName, size: 34 - 6 * t, image: userImage, onTap: onProfile),
          const SizedBox(width: 12),
          if (connecting) ...[
            DsSpinner(key: const ValueKey('header-connecting'), color: tokens.accent, size: 18 - 2 * t),
            const SizedBox(width: DsSpace.x2),
          ],
          Expanded(
            // Shrinks to fit rather than cutting «Подключение…».
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(title, key: const ValueKey('header-title'), style: style, maxLines: 1),
            ),
          ),
          DsIconButton(shape: DsIconShape.search, onTap: onSearch),
          DsIconButton(shape: DsIconShape.edit, onTap: onCompose),
        ],
      ),
    );
  }
}
