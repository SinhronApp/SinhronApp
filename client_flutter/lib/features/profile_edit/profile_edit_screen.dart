// Edit profile screen. Reached by "Edit" on My profile. Follows
// design/app/settings-detail.jsx SnProfileEdit for the header + hero + form
// fields, then my account (server copy / joined), a privacy link and the
// account actions. The QR, my address and sharing live on My profile only
// (owner, 2026-10-18: no duplicates).
//
// Per spec §6.7 / §6.6, identity (@username + key tree) is immutable on
// the server side — the form's "Username" row is therefore read-only with
// a small explainer. The display name, photo and (ADR-052) the About line
// go to my chats in a `profile` action, end-to-end encrypted, so the people
// I write to see who I am (tech-debt 2.22); people I blocked don't get them.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme/tokens.dart';
import '../../core/providers/core_providers.dart';
import '../../core/providers/people.dart' show kMaxBioChars;
import '../../core/providers/message_actions.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/services/net_service.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../settings/_shared.dart';
import '../../l10n/l10n.dart';
import '../chat_list/chat_data.dart' show formatFullDate;
import '../../core/app_notice.dart';

/// "April 12, 2026" / "12 апреля 2026 г." from unix seconds.
String _formatJoined(int unix) => formatFullDate(unix);

class ProfileEditScreen extends ConsumerStatefulWidget {
  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  final VoidCallback? onPrivacy;
  final VoidCallback? onSignOut;
  final VoidCallback? onDeleteAccount;

  const ProfileEditScreen({
    super.key,
    this.onCancel,
    this.onSave,
    this.onPrivacy,
    this.onSignOut,
    this.onDeleteAccount,
  });

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  // Real, persisted (local-only) profile metadata — loaded in initState.
  final _nameCtrl = TextEditingController();
  final _aboutCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    ref.read(profileNameProvider.future).then((v) {
      if (mounted && _nameCtrl.text.isEmpty) _nameCtrl.text = v;
    });
    ref.read(profileAboutProvider.future).then((v) {
      if (mounted && _aboutCtrl.text.isEmpty) _aboutCtrl.text = v;
    });
  }

  /// The operator server this account lives on.
  String get _server {
    final base = ref.read(netServiceProvider).httpBaseUrl;
    final host = base == null ? '' : (Uri.tryParse(base)?.host ?? '');
    return host.isEmpty ? context.l10n.notConnected : host;
  }

  /// A second tap on Done while saving closed two screens (2026-10-16 UI
  /// audit).
  bool _saving = false;

  Future<void> _handleSave() async {
    if (_saving) return;
    _saving = true;
    try {
      await ref.read(profileNameProvider.notifier).save(_nameCtrl.text.trim());
      await ref.read(profileAboutProvider.notifier).save(_aboutCtrl.text.trim());
    } catch (_) {
      _saving = false;
      if (mounted) appNotice.value = context.l10n.profileSaveFailed;
      return;
    }
    // Tech-debt 2.22 — my chats learn the new name (in the background).
    unawaited(ref.read(peopleProvider).shareEverywhere().catchError((Object _) => 0));
    widget.onSave?.call();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _aboutCtrl.dispose();
    super.dispose();
  }

  Future<void> _copyHandle() async {
    await Clipboard.setData(ClipboardData(text: _server));
    if (!mounted) return;
    showDone(context.l10n.profileEditServerCopied);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            _CancelHeader(onCancel: widget.onCancel, onSave: _handleSave),
            Expanded(
              child: Stack(
                children: [
                  ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: DsSpace.x6),
                    children: [
                      _HeroAvatar(),
                      // Form fields — Name / Username (read-only) / About
                      Padding(
                        padding: const EdgeInsets.fromLTRB(DsSpace.x5, 0, DsSpace.x5, DsSpace.x5h5),
                        child: Column(
                          children: [
                            DsTextField(
                              label: context.l10n.nameLabel,
                              controller: _nameCtrl,
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 14),
                            DsTextField(label: context.l10n.server, mono: true, enabled: false, hintText: _server),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(DsSpace.x0h5, DsSpace.x1h5, DsSpace.x0h5, 0),
                              child: Text(
                                context.l10n.profileEditNoPhoneNote,
                                style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
                              ),
                            ),
                            const SizedBox(height: 14),
                            DsTextField(
                              key: const ValueKey('profile-about'),
                              label: context.l10n.contactAbout,
                              controller: _aboutCtrl,
                              inputFormatters: [LengthLimitingTextInputFormatter(kMaxBioChars)],
                            ),
                            // ADR-052 — it used to stay on this phone.
                            Padding(
                              padding: const EdgeInsets.fromLTRB(DsSpace.x0h5, DsSpace.x1h5, DsSpace.x0h5, 0),
                              child: Text(
                                context.l10n.profileAboutHint,
                                style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // My account: the server I live on (copy) and since when.
                      // The QR, the address and sharing live on My profile —
                      // not repeated here (owner, 2026-10-18).
                      SettingsSection(
                        title: context.l10n.legalYourIdentity,
                        children: [
                          _HandleRow(handle: _server, onCopy: _copyHandle),
                          SettingsRow(
                            icon: SettingsRowIcon.clock,
                            tint: SettingsRowTint.recovery,
                            label: context.l10n.profileEditJoined,
                            value:
                                ref
                                    .watch(identityProvider)
                                    .whenOrNull(
                                      data: (id) => id == null ? null : _formatJoined(id.createdAtUnix.toInt()),
                                    ) ??
                                '—',
                            isLast: true,
                          ),
                        ],
                      ),
                      // Privacy link
                      SettingsSection(
                        title: context.l10n.privacySection,
                        children: [
                          SettingsRow(
                            icon: SettingsRowIcon.shield,
                            tint: SettingsRowTint.privacy,
                            label: context.l10n.profileEditWhoSees,
                            value: context.l10n.privacyTitle,
                            onTap: widget.onPrivacy,
                            isLast: true,
                          ),
                        ],
                      ),
                      // Account actions
                      Padding(
                        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, 0),
                        child: DsButton(
                          label: context.l10n.profileEditSignOut,
                          variant: DsButtonVariant.secondary,
                          onPressed: widget.onSignOut,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, 0, DsSpace.x3h5, 0),
                        child: DsButton(
                          label: context.l10n.deleteAccountTitle,
                          variant: DsButtonVariant.danger,
                          onPressed: widget.onDeleteAccount,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x2h5, DsSpace.x7, 0),
                        child: Text(
                          context.l10n.profileEditAccountFooter,
                          style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
                        ),
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

// ═════════════════════════════════════════════════════════════════════
// Cancel-style header: Cancel · Edit profile · Save
// ═════════════════════════════════════════════════════════════════════

class _CancelHeader extends StatelessWidget {
  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  const _CancelHeader({this.onCancel, this.onSave});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 4,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onCancel?.call(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3),
                child: Center(
                  child: Text(
                    context.l10n.cancel,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w500, height: 1.0, color: tokens.text2),
                  ),
                ),
              ),
            ),
          ),
          Center(
            child: Text(
              context.l10n.profileEditTitle,
              style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.text),
            ),
          ),
          Positioned(
            right: 4,
            top: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onSave?.call(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3),
                child: Center(
                  child: Text(
                    context.l10n.save,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.accent),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero — 96pt avatar with accent edit-pencil badge + "Change photo" link
// ═════════════════════════════════════════════════════════════════════

/// Picks an image for my photo (gallery); faked in tests. Returns its
/// bytes, or null when cancelled. The picker's temp file is deleted.
final avatarSourceProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, requestFullMetadata: false);
    if (x == null) return null;
    final bytes = await x.readAsBytes();
    try {
      await File(x.path).delete();
    } catch (_) {}
    return bytes;
  },
);

/// Re-encodes my photo in Rust (EXIF/GPS gone, ≤32 KB); faked in tests.
final avatarPrepareProvider = Provider<Future<Uint8List> Function(Uint8List)>(
  (ref) => (image) => core.mediaAvatarPrepare(image: image),
);

class _HeroAvatar extends ConsumerWidget {
  Future<void> _change(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
    final has = (ref.read(profileAvatarProvider).value ?? '').isNotEmpty;
    final choice = await showDsActionSheet<String>(
      context,
      actions: [
        DsSheetAction(l.profileEditChoosePhoto, 'pick'),
        if (has) DsSheetAction(l.profileEditRemovePhoto, 'remove', destructive: true),
      ],
    );
    String? next;
    switch (choice) {
      case 'pick':
        try {
          final image = await ref.read(avatarSourceProvider)();
          if (image == null) return;
          next = base64Encode(await ref.read(avatarPrepareProvider)(image));
        } catch (_) {
          // No access to Photos, or not an image we can read: say so
          // (it used to do nothing at all).
          appNotice.value = l.photoCouldNotUse;
          return;
        }
      case 'remove':
        next = '';
      default:
        return;
    }
    await ref.read(profileAvatarProvider.notifier).save(next);
    // Everyone in my chats gets the new photo with my name.
    unawaited(ref.read(peopleProvider).shareEverywhere());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final name = ref.watch(profileNameProvider).value ?? '';
    final b64 = ref.watch(profileAvatarProvider).value ?? '';
    Uint8List? photo;
    try {
      photo = b64.isEmpty ? null : base64Decode(b64);
    } catch (_) {}
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x5, DsSpace.x6, DsSpace.x5, DsSpace.x4h5),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Semantics(
                button: true,
                label: context.l10n.profileEditChangePhoto,
                excludeSemantics: true,
                onTap: () => _change(context, ref),
                child: GestureDetector(
                  key: const ValueKey('profile-photo'),
                  onTap: () => _change(context, ref),
                  child: DsAvatar(name: name, size: 96, image: photo),
                ),
              ),
              Positioned(
                bottom: -2,
                right: -2,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: tokens.accent,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.bgSoft, width: 3),
                    boxShadow: [DsShadow.glowOf(tokens.accent, alpha: 0.30, y: 2, blur: 6)],
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CustomPaint(painter: _PencilPainter(color: tokens.accentText)),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            key: const ValueKey('profile-change-photo'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _change(context, ref),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x1),
              child: Text(
                context.l10n.profileEditChangePhoto,
                style: DsText.subhead.copyWith(height: 1.0, color: tokens.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Handle row — mono full handle + copy button
// ═════════════════════════════════════════════════════════════════════

class _HandleRow extends StatelessWidget {
  final String handle;
  final VoidCallback onCopy;
  const _HandleRow({required this.handle, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.nudge11, DsSpace.x3h5, DsSpace.nudge11),
          child: Row(
            children: [
              SizedBox(width: 30, height: 30, child: Icon(CupertinoIcons.at, size: 22, color: tokens.text2)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.l10n.profileEditHandle,
                      style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsTextArt.t12w500Monov3.copyWith(color: tokens.text3),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onCopy,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x1h5),
                  decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    context.l10n.copy,
                    style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned(left: 56, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Painters
// ═════════════════════════════════════════════════════════════════════

class _PencilPainter extends CustomPainter {
  final Color color;
  _PencilPainter({required this.color});
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(3, 19)
      ..lineTo(21, 19);
    canvas.drawPath(p, stroke);
    final pencil = Path()
      ..moveTo(6, 16)
      ..lineTo(15, 7)
      ..lineTo(18, 10)
      ..lineTo(9, 19)
      ..lineTo(6, 19)
      ..close();
    canvas.drawPath(pencil, stroke);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PencilPainter old) => old.color != color;
}
