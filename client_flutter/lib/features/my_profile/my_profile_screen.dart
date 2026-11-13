// My profile — opened by my photo at the top-left of Chats / Calls /
// Contacts and by the profile card in Settings (owner, 2026-10-18).
//
// What other people see of me and how they reach me: photo, name, About,
// my QR code and address in an accent card, Share / Copy tiles (Signal
// style, owner 2026-10-20; my photo opens full screen). It is
// deliberately NOT a copy of the Settings list — editing lives behind
// "Edit" (ProfileEditScreen), everything else stays in Settings.

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:qr/qr.dart';

import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_button.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_qr_card.dart';
import '../verify/verify_contact.dart' show QrMatrixPainter;

class MyProfileScreen extends StatelessWidget {
  const MyProfileScreen({
    super.key,
    required this.name,
    this.about = '',
    this.photo,
    this.address,
    this.qrPayload,
    this.onBack,
    this.onEdit,
    this.onShare,
    this.onCopyAddress,
    this.onPhoto,
  });

  final String name;
  final String about;
  final Uint8List? photo;

  /// Short form of my address ("9a3e 4d12 8b71 …"); null until the phone
  /// has an identity on the server.
  final String? address;

  /// The QR's text (`contactQrPayload`); null = not ready yet.
  final String? qrPayload;
  final VoidCallback? onBack;
  final VoidCallback? onEdit;
  final VoidCallback? onShare;
  final VoidCallback? onCopyAddress;

  /// A tap on my photo — full screen (owner, 2026-10-20). Without a photo
  /// the tap goes to [onEdit] to set one.
  final VoidCallback? onPhoto;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final ready = qrPayload != null;
    final avatarTap = photo != null ? onPhoto : onEdit;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            DsAppBar(
              title: l.myProfileTitle,
              onBack: onBack,
              trailing: onEdit == null
                  ? null
                  : DsPressable(
                      key: const ValueKey('my-profile-edit'),
                      onTap: onEdit,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x2h5),
                        child: Text(
                          l.edit,
                          style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: DsAppearScope(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, DsSpace.x6),
                  children: dsStaggered([
                    Center(
                      child: Semantics(
                        button: avatarTap != null,
                        label: photo != null ? l.a11yOpenPhoto : null,
                        child: DsPressable(
                          key: const ValueKey('my-profile-avatar'),
                          onTap: avatarTap,
                          scale: 0.96,
                          child: DsAvatar(name: name, size: 120, image: photo),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: DsSpace.x4),
                      child: Text(
                        name,
                        key: const ValueKey('my-profile-name'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: DsText.title1.copyWith(fontWeight: FontWeight.w700, color: tokens.text),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: DsSpace.x1h5),
                      child: Text(
                        about.isEmpty ? l.myProfileNoBio : about,
                        textAlign: TextAlign.center,
                        style: DsText.subhead.copyWith(color: about.isEmpty ? tokens.text3 : tokens.text2),
                      ),
                    ),
                    const SizedBox(height: DsSpace.x6),
                    if (ready)
                      Center(
                        child: DsQrCard(
                          key: const ValueKey('my-profile-qr'),
                          code: _Qr(payload: qrPayload!),
                          title: address,
                          subtitle: l.myProfileAddress,
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(DsSpace.x6),
                        decoration: BoxDecoration(
                          color: tokens.surface,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Text(
                          l.myProfileNotReady,
                          key: const ValueKey('my-profile-address'),
                          textAlign: TextAlign.center,
                          style: DsText.subhead.copyWith(color: tokens.text2),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: DsSpace.x4),
                      child: DsActionRow(
                        children: [
                          DsActionButton(
                            key: const ValueKey('my-profile-share'),
                            label: l.share,
                            icon: _glyph(DsActionGlyph.share, tokens),
                            onTap: ready ? onShare : null,
                          ),
                          DsActionButton(
                            key: const ValueKey('my-profile-copy'),
                            label: l.showQrCopyKey,
                            icon: _glyph(DsActionGlyph.copy, tokens),
                            onTap: ready ? onCopyAddress : null,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x4, DsSpace.x4, 0),
                      child: Text(
                        l.myProfileQrHint,
                        textAlign: TextAlign.center,
                        style: DsText.footnote.copyWith(color: tokens.text3),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _glyph(DsActionGlyph g, DsTokens tokens) =>
      CustomPaint(painter: DsActionGlyphPainter(g, color: tokens.accent, strokeWidth: kActionIconStroke));
}

/// The real, scannable code.
class _Qr extends StatelessWidget {
  const _Qr({required this.payload});
  final String payload;

  @override
  Widget build(BuildContext context) {
    final code = QrImage(QrCode.fromData(data: payload, errorCorrectLevel: QrErrorCorrectLevel.M));
    return CustomPaint(painter: QrMatrixPainter(code));
  }
}
