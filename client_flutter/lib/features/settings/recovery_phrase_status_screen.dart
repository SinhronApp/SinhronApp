// Secret words — Settings → Account → "Secret words".
//
// Per spec §6.8 / §6.8.1, the 24 words are the only thing that brings
// your account back on a new phone. ADR-059: sign-up no longer forces
// writing them down, so this screen is where they get saved later:
//   - not saved yet (they wait on this phone only): an amber hero, "Save to
//     Passwords" and "Write the words down" (with the recovery sheet);
//   - saved: a green hero — how and when;
//   - accounts from before ADR-059 / phones signed in with the words: no
//     hero (the words were written down then).
// Then "Check the words" (all 24, compared with this account's
// fingerprint), the second device (honest: a second device keeps the
// chats, but adding a new phone needs the words — ADR-027) and the tip.

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';

import 'dart:io' show Platform;

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../../widgets/ds_app_bar.dart';
import '_shared.dart';
import '../../l10n/l10n.dart';

class RecoveryPhraseStatusScreen extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onReVerify;

  /// ADR-059 — how the words are kept. Null: still loading.
  final AccessState? access;

  /// The phone has a password manager this app can save to.
  final bool passwordsAvailable;
  final VoidCallback? onSavePasswords;
  final VoidCallback? onWriteDown;

  /// ADR-085 — iPhone, words still a Safari password: move them.
  final VoidCallback? onMoveToKeychain;

  /// The account's other devices (not this one).
  final int otherDevices;
  final VoidCallback? onLinkDevice;

  /// Locale-formatted date for [AccessState.savedAt].
  final String Function(DateTime at)? formatDate;

  const RecoveryPhraseStatusScreen({
    super.key,
    this.onBack,
    this.onReVerify,
    this.access,
    this.passwordsAvailable = false,
    this.onSavePasswords,
    this.onWriteDown,
    this.onMoveToKeychain,
    this.otherDevices = 0,
    this.onLinkDevice,
    this.formatDate,
  });

  @override
  State<RecoveryPhraseStatusScreen> createState() => _RecoveryPhraseStatusScreenState();
}

class _RecoveryPhraseStatusScreenState extends State<RecoveryPhraseStatusScreen> {
  Widget _tip(DsTokens tokens) => Padding(
    padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x1, DsSpace.x7, 0),
    child: Text(
      context.l10n.phraseStatusTip,
      style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
    ),
  );

  /// The real screen (ADR-059).
  List<Widget> _real(BuildContext context) {
    final l = context.l10n;
    final tokens = DsTheme.of(context);
    final a = widget.access;
    final waiting = a?.needsSaving ?? false;
    final at = a?.savedAt;
    final when = at == null ? '' : (widget.formatDate?.call(at) ?? '${at.day}.${at.month}.${at.year}');
    final savedBody = switch (a?.savedWay) {
      AccessWay.passwords => Platform.isAndroid ? l.accessSavedPasswordsAndroid(when) : l.accessSavedPasswordsIos(when),
      AccessWay.keychain => l.accessSavedKeychainIos(when),
      AccessWay.paper => l.accessSavedPaper(when),
      AccessWay.sheet => l.accessSavedSheet(when),
      AccessWay.checked => l.accessSavedChecked(when),
      null => null,
    };
    return [
      if (waiting)
        _AccessHero(
          key: const ValueKey('access-hero-waiting'),
          waiting: true,
          title: l.accessNotSavedTitle,
          body: l.accessNotSavedBody,
        )
      else if (savedBody != null)
        _AccessHero(key: const ValueKey('access-hero-saved'), waiting: false, title: l.accessSavedTitle, body: savedBody),
      // storage-devices:2 — a page on the password domain could ask for them.
      if (a?.savedWay == AccessWay.passwords && defaultTargetPlatform == TargetPlatform.iOS && widget.passwordsAvailable)
        SettingsSection(
          footer: l.moveToKeychainFooter,
          children: [
            SettingsRow(
              key: const ValueKey('access-move-keychain'),
              icon: SettingsRowIcon.key,
              tint: SettingsRowTint.recovery,
              label: l.moveToKeychain,
              onTap: widget.onMoveToKeychain,
              isLast: true,
            ),
          ],
        ),
      if (waiting)
        SettingsSection(
          title: l.accessSaveSection,
          footer: l.accessSaveFooter,
          children: [
            if (widget.passwordsAvailable)
              SettingsRow(
                key: const ValueKey('access-save-passwords'),
                icon: SettingsRowIcon.key,
                tint: SettingsRowTint.recovery,
                label: Platform.isAndroid ? l.saveToPasswordsAndroid : l.saveToPasswordsIos,
                onTap: widget.onSavePasswords,
              ),
            SettingsRow(
              key: const ValueKey('access-write-down'),
              icon: SettingsRowIcon.document,
              tint: SettingsRowTint.chats,
              label: l.writeWordsAction,
              subtitle: l.writeWordsRowHint,
              onTap: widget.onWriteDown,
              isLast: true,
            ),
          ],
        ),
      SettingsSection(
        title: l.phraseStatusActions,
        footer: waiting ? null : l.phraseStatusActionsFooter,
        children: [
          SettingsRow(
            key: const ValueKey('access-check'),
            icon: SettingsRowIcon.shield,
            tint: SettingsRowTint.privacy,
            label: l.phraseStatusReverify,
            value: l.phraseStatusAllWords,
            onTap: widget.onReVerify,
          ),
          SettingsRow(
            icon: SettingsRowIcon.key,
            tint: SettingsRowTint.devices,
            label: l.phraseStatusStrength,
            value: l.phraseStrengthValue,
            isLast: true,
          ),
        ],
      ),
      SettingsSection(
        title: l.secondDeviceSection,
        footer: widget.otherDevices > 0 ? l.secondDeviceYes : l.secondDeviceNo,
        children: [
          SettingsRow(
            key: const ValueKey('access-second-device'),
            icon: SettingsRowIcon.devices,
            tint: SettingsRowTint.devices,
            label: widget.otherDevices > 0 ? l.secondDeviceCount(widget.otherDevices) : l.secondDeviceLink,
            onTap: widget.onLinkDevice,
            isLast: true,
          ),
        ],
      ),
      _tip(tokens),
    ];
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
            DsAppBar(title: context.l10n.phraseStatusTitle, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x1h5, bottom: DsSpace.x6),
                children: _real(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Hero: green check "saved" / amber key "not saved yet"
// ═════════════════════════════════════════════════════════════════════

class _AccessHero extends StatelessWidget {
  const _AccessHero({super.key, required this.waiting, required this.title, required this.body});

  /// Not saved yet: amber key instead of the green check.
  final bool waiting;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final tint = waiting ? DsPalette.orange : DsPalette.green;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1h5, DsSpace.x3h5, DsSpace.x5h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x5, DsSpace.x4h5, DsSpace.x5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [tokens.surface, Color.lerp(tokens.surface, tint, 0.05)!],
          ),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tokens.dividerStrong, width: 0.5),
          boxShadow: DsShadow.card,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: waiting ? DsPalette.orange14 : DsPalette.green10,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: SizedBox(
                  width: 30,
                  height: 30,
                  child: CustomPaint(
                    painter: waiting
                        ? SettingsRowIconPainter(shape: SettingsRowIcon.key, color: tint)
                        : _BigCheckPainter(color: tint),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: DsText.title2.copyWith(fontWeight: FontWeight.w600, height: 1.1, color: tokens.text),
                  ),
                  const SizedBox(height: 4),
                  Text(body, style: DsText.subhead.copyWith(color: tokens.text2)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BigCheckPainter extends CustomPainter {
  final Color color;
  _BigCheckPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final p = Path()
      ..moveTo(5, 12)
      ..lineTo(10.5, 17)
      ..lineTo(19, 7);
    canvas.drawPath(p, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BigCheckPainter old) => old.color != color;
}
