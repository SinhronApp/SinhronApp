// Step 2 / 3: the user picks a display name and (optionally) an avatar.
// The avatar uses the gradient-seeded initials of the typed name by default;
// the small accent badge in the bottom-right hints at the photo picker.
//
// Source: design/app/entry.jsx SnProfile.

import 'package:flutter/widgets.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_text_field.dart';
import '../../l10n/l10n.dart';

class ProfileScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onContinue;

  /// The name typed, saved before [onContinue].
  final Future<void> Function(String name)? onName;
  final VoidCallback? onPickAvatar;
  final String? initialName;

  const ProfileScreen({super.key, this.onBack, this.onContinue, this.onName, this.onPickAvatar, this.initialName});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName ?? '');
    _nameCtrl.addListener(_onChanged);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  bool get _canContinue => _nameCtrl.text.trim().isNotEmpty;

  /// Stable non-null callback so the button looks "enabled" whenever the
  /// form is valid, even if [widget.onContinue] hasn't been wired up.
  /// A double tap pushed two key screens with different 24 words
  /// (2026-10-16 UI audit).
  bool _busy = false;

  Future<void> _handleContinue() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onName?.call(_nameCtrl.text.trim());
    } catch (_) {
      // Settings not open yet — the name can still be set in Profile later.
    }
    if (mounted) widget.onContinue?.call();
    // Back on this screen later (Back from the next step): usable again.
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _busy = false);
    });
  }

  String get _displayName {
    final t = _nameCtrl.text.trim();
    return t.isEmpty ? 'Sinhron user' : t;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            DsAppBar(step: '2 / 3', onBack: widget.onBack),
            // Scrolls when the keyboard leaves too little room; Continue
            // stays above the keyboard (2026-10-16 UI audit).
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2, DsSpace.x6, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.yourProfile,
                    style: DsText.display.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.l10n.profileBody,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            // Avatar + edit badge
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onPickAvatar,
              child: SizedBox(
                width: 96 + 8,
                height: 96 + 8,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(DsSpace.x1),
                        child: DsAvatar(name: _displayName, size: 96),
                      ),
                    ),
                    Positioned(right: 0, bottom: 0, child: _EditBadge()),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
              child: DsTextField(
                label: context.l10n.nameLabel,
                controller: _nameCtrl,
                hintText: context.l10n.nameHint,
                autofocus: true,
              ),
            ),
                    const SizedBox(height: DsSpace.x4),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x4h5),
              child: DsButton(
                label: context.l10n.continueBtn,
                variant: DsButtonVariant.primary,
                onPressed: _canContinue ? _handleContinue : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: tokens.accent,
        boxShadow: [
          // accent glow drop shadow
          DsShadow.glowOf(tokens.accent, alpha: tokens.accent.a * 0.30, y: 2, blur: 6),
          // bg-colored ring so the badge "pops out" of the avatar
          DsShadow.ring(tokens.bg, spread: 3),
        ],
      ),
      child: const Center(
        child: DsIcon(shape: DsIconShape.edit, size: 14, color: DsPalette.white, strokeWidth: 2),
      ),
    );
  }
}
