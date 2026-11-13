// Linked devices sub-screen. Reached from Settings → Linked devices row.
//
// Sinhron's value prop here vs Signal: a Sinhron account IS the MLS group of
// devices (spec §6.6, §6.8.1). Every linked device shares the encrypted
// state ratchet; removing one is a real MLS Remove that updates the group
// epoch and immediately rotates keys. We hint at this in the section
// footers but don't dump MLS jargon on the user.
//
// ADR-025: real data — `GET /v1/devices` via [linkedDevicesProvider];
// Revoke = server revocation + MLS Remove in every chat
// (`NetService.revokeDevice`).
//
// Composition:
//   1. App-bar with back chevron + "Linked devices".
//   2. Hero card — count + explainer + "Link a new device" (scan its QR,
//      AddDeviceScreen) or the phrase on it.
//   3. CURRENT DEVICE section — single row marked "This device", non-tappable.
//   4. OTHER DEVICES section — each device with its link date + Revoke.
//   5. Section footer explaining MLS state sharing in plain language.
//   6. Trailing destructive: "Remove all other devices".

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/device_providers.dart';
import '../../core/providers/device_transfer.dart';
import '../../core/services/net_service.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../app_lock/app_lock.dart';
import '_shared.dart';
import 'phrase_prompt.dart';
import 'transfer_cards.dart';
import '../../l10n/l10n.dart';

// ═════════════════════════════════════════════════════════════════════
// Data — ADR-025: the person's devices as the server lists them
// ═════════════════════════════════════════════════════════════════════

enum _DeviceKind { iphone, ipad, macbook }

class _Device {
  final String pkHex;
  final String name;
  final String detail;
  // The server doesn't know device models (yet) — a phone glyph for all.
  final _DeviceKind kind = _DeviceKind.iphone;
  final bool isOnline;
  final bool isCurrent;

  const _Device({
    required this.pkHex,
    required this.name,
    required this.detail,
    this.isOnline = false,
    this.isCurrent = false,
  });
}

String _date(int unix) {
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}

/// [given] — the name that device gave itself ("iPad Air"), if it has.
_Device _fromCore(BuildContext context, core.LinkedDevice d, String? given) {
  final l = context.l10n;
  final linked = l.devicesLinkedOn(_date(d.registeredAtUnix.toInt()));
  final seen = d.isThisDevice ? '' : ' · ${l.devicesSeenOn(_date(d.lastSeenUnix.toInt()))}';
  return _Device(
    pkHex: d.devicePkHex,
    name: d.isThisDevice
        ? (given == null ? l.thisDevice : '${l.thisDevice} · $given')
        : given ?? l.devicesUnnamed,
    detail: (d.isPrimary ? '${l.devicesFirstDevice} · $linked' : linked) + seen,
    isOnline: d.isThisDevice,
    isCurrent: d.isThisDevice,
  );
}

// ═════════════════════════════════════════════════════════════════════
// Screen
// ═════════════════════════════════════════════════════════════════════

class LinkedDevicesScreen extends ConsumerStatefulWidget {
  final VoidCallback? onBack;

  /// "Link a new device" — scan the new device's QR (tech-debt 4.2).
  final VoidCallback? onAddDevice;

  const LinkedDevicesScreen({super.key, this.onBack, this.onAddDevice});

  @override
  ConsumerState<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends ConsumerState<LinkedDevicesScreen> {
  bool _busy = false;
  String? _error;

  /// ADR-064 — tapping another device: send it everything (again).
  Future<void> _deviceMenu(_Device d) async {
    final l = context.l10n;
    final go = await showDsActionSheet<bool>(
      context,
      title: d.name,
      actions: [DsSheetAction(l.devicesSendAll, true)],
    );
    if (go != true || !mounted) return;
    setState(() => _error = null);
    try {
      await ref.read(deviceTransfersProvider.notifier).sendTo(d.pkHex);
    } catch (_) {
      if (mounted) setState(() => _error = l.devicesSendAllFailed);
    }
  }

  Future<void> _revoke(List<_Device> devices) async {
    final l = context.l10n;
    final ok = await showDsActionSheet<bool>(
      context,
      title: l.devicesRevokeTitle,
      actions: [DsSheetAction(l.devicesRevokeAction, true, destructive: true)],
    );
    if (ok != true || !mounted) return;
    // Audit DEV-7 — only the owner: Face ID / the phone's passcode first.
    if (!await confirmOwner(ref, l.devicesRevokeAction) || !mounted) return;
    // ADR-027 — a device without the account key asks for the 24 words.
    String? phrase;
    if (!(ref.read(accountKeyHereProvider).value ?? true)) {
      phrase = await promptPhrase(context);
      if (phrase == null || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      for (final d in devices) {
        await ref.read(netServiceProvider).revokeDevice(d.pkHex, phrase: phrase);
      }
    } catch (_) {
      if (mounted) setState(() => _error = l.devicesRevokeFailed);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ref.invalidate(linkedDevicesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final l = context.l10n;
    final async = ref.watch(linkedDevicesProvider);
    // ADR-027 — a device without the account key manages devices with the
    // 24 words (asked for each time).
    final hasKey = ref.watch(accountKeyHereProvider).value ?? true;
    final all =
        async.value?.map((d) => _fromCore(context, d, ref.watch(deviceNameProvider(d.devicePkHex)).value)).toList() ??
        const <_Device>[];
    final current = all.where((d) => d.isCurrent).firstOrNull;
    final others = all.where((d) => !d.isCurrent).toList();
    Widget note(String text, {Color? color}) => Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x1, DsSpace.x7, DsSpace.x3),
      child: Text(text, style: DsText.footnote.copyWith(color: color ?? tokens.text3)),
    );
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            DsAppBar(title: l.linkedDevices, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x1h5, bottom: DsSpace.x6),
                children: [
                  _HeroCard(total: all.isEmpty ? 1 : all.length, onAddDevice: widget.onAddDevice),
                  // ADR-064 — transfers to / from my devices, while they run.
                  const TransferCards(),
                  if (!hasKey) note(l.devicesNotPrimary),
                  if (async.hasError) note(l.devicesLoadFailed, color: tokens.danger),
                  if (_error != null) note(_error!, color: tokens.danger),
                  if (current != null)
                    SettingsSection(
                      title: l.devicesCurrent,
                      children: [_CurrentDeviceRow(device: current)],
                    ),
                  if (others.isNotEmpty)
                    SettingsSection(
                      title: l.devicesOther,
                      footer: l.devicesOtherFooter,
                      children: [
                        for (var i = 0; i < others.length; i++)
                          _OtherDeviceRow(
                            device: others[i],
                            isLast: i == others.length - 1,
                            onRevoke: _busy ? null : () => _revoke([others[i]]),
                            onTap: _busy ? null : () => _deviceMenu(others[i]),
                          ),
                      ],
                    )
                  else if (async.hasValue)
                    note(l.devicesOnlyOne),
                  if (others.isNotEmpty) note(l.devicesSyncNote),
                  if (others.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, 0),
                      child: DsButton(
                        label: l.devicesRemoveAll(others.length),
                        variant: DsButtonVariant.danger,
                        loading: _busy,
                        onPressed: _busy ? null : () => _revoke(others),
                      ),
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
// Hero card: device count + Link a new device CTA
// ═════════════════════════════════════════════════════════════════════

class _HeroCard extends StatelessWidget {
  final int total;
  final VoidCallback? onAddDevice;
  const _HeroCard({required this.total, this.onAddDevice});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1h5, DsSpace.x3h5, DsSpace.x5h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tokens.dividerStrong, width: 0.5),
          boxShadow: DsShadow.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(total.toString(), style: DsTextArt.t44w600.copyWith(color: tokens.text)),
                const SizedBox(width: 6),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: DsSpace.x1h5),
                    child: Text(
                      context.l10n.devicesLinkedCount(total),
                      maxLines: 2,
                      style: DsText.bodyLarge.copyWith(height: 1.1, color: tokens.text3),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(context.l10n.devicesHeroBody, style: DsText.subhead.copyWith(color: tokens.text2)),
            const SizedBox(height: 16),
            if (onAddDevice != null)
              DsButton(
                key: const ValueKey('devices-add'),
                label: context.l10n.devicesLinkNew,
                size: DsButtonSize.medium,
                onPressed: onAddDevice,
              ),
            const SizedBox(height: 12),
            // The other way in: the phrase on the new device.
            Text(context.l10n.devicesHowToLink, style: DsText.footnote.copyWith(color: tokens.text3)),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Current device row — large device icon + "This device" badge
// ═════════════════════════════════════════════════════════════════════

class _CurrentDeviceRow extends StatelessWidget {
  final _Device device;
  const _CurrentDeviceRow({required this.device});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x3, DsSpace.x3h5, DsSpace.x3),
      child: Row(
        children: [
          _DeviceTile(kind: device.kind, isOnline: device.isOnline),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.fromLTRB(DsSpace.nudge7, DsSpace.x0h5, DsSpace.nudge7, DsSpace.x0h5),
                      decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(999)),
                      child: Text(
                        context.l10n.thisDevice,
                        style: DsText.micro.copyWith(fontWeight: FontWeight.w700, height: 1.0, color: tokens.accent),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(device.detail, style: DsText.subhead.copyWith(color: tokens.text3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Other-device row — device icon + name + status + Revoke link
// ═════════════════════════════════════════════════════════════════════

class _OtherDeviceRow extends StatelessWidget {
  final _Device device;
  final bool isLast;
  final VoidCallback? onRevoke;
  final VoidCallback? onTap;
  const _OtherDeviceRow({required this.device, required this.isLast, required this.onRevoke, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        GestureDetector(
          key: ValueKey('device-row-${device.pkHex}'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.nudge11, DsSpace.x3h5, DsSpace.nudge11),
            child: Row(
              children: [
                _DeviceTile(kind: device.kind, isOnline: device.isOnline),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        device.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                      ),
                      const SizedBox(height: 2),
                      Text(device.detail, style: DsText.footnote.copyWith(color: tokens.text3)),
                    ],
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onRevoke,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x1h5),
                    child: Text(
                      context.l10n.devicesRevoke,
                      style: DsText.callout.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: DsPalette.red600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!isLast)
          Positioned(
            left: 70, // align with text after the 56-wide tile + gap
            right: 0,
            bottom: 0,
            height: 0.5,
            child: ColoredBox(color: tokens.divider),
          ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Device tile — 44pt squircle with painted device glyph + status dot
// ═════════════════════════════════════════════════════════════════════

class _DeviceTile extends StatelessWidget {
  final _DeviceKind kind;
  final bool isOnline;
  const _DeviceTile({required this.kind, required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return SizedBox(
      width: 44,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(12)),
            child: Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CustomPaint(
                  painter: _DeviceGlyphPainter(kind: kind, color: tokens.text2),
                ),
              ),
            ),
          ),
          // Online dot (bottom-right corner, with bg ring for legibility)
          if (isOnline)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: DsPalette.green, // green
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.surface, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceGlyphPainter extends CustomPainter {
  final _DeviceKind kind;
  final Color color;
  _DeviceGlyphPainter({required this.kind, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.scale(s);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (kind) {
      case _DeviceKind.iphone:
        // Phone body (portrait), home-indicator bar at bottom
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(7, 2.5, 10, 19), const Radius.circular(2.4)),
          stroke,
        );
        // Speaker pill (top)
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(10.5, 4.5, 3, 1.4), const Radius.circular(0.7)),
          fill,
        );
        // Home indicator (bottom)
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(10, 19, 4, 0.9), const Radius.circular(0.5)),
          fill,
        );
      case _DeviceKind.ipad:
        // Tablet body — wider than phone, taller than wide
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(4, 3, 16, 18), const Radius.circular(2.2)),
          stroke,
        );
        // Camera dot at top-center
        canvas.drawCircle(const Offset(12, 5), 0.5, fill);
        // Home indicator (bottom)
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(10, 19, 4, 0.9), const Radius.circular(0.5)),
          fill,
        );
      case _DeviceKind.macbook:
        // Screen (top)
        canvas.drawRRect(
          RRect.fromRectAndRadius(const Rect.fromLTWH(4, 4, 16, 11), const Radius.circular(1.4)),
          stroke,
        );
        // Base — wider, trapezoidal-ish
        final base = Path()
          ..moveTo(2, 17)
          ..lineTo(22, 17)
          ..lineTo(20.5, 19)
          ..lineTo(3.5, 19)
          ..close();
        canvas.drawPath(base, stroke);
        // Notch in the base (touch bar / trackpad hint)
        canvas.drawLine(const Offset(10.5, 17), const Offset(13.5, 17), stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DeviceGlyphPainter old) => old.kind != kind || old.color != color;
}

// ═════════════════════════════════════════════════════════════════════
// QR icon for the "Link a new device" button leading
// ═════════════════════════════════════════════════════════════════════
