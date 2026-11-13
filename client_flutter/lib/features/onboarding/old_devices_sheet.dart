// ADR-075 — right after the 24 words on a new phone: "Your other devices".
// A device restored by the words keeps no account key (ADR-027), so cutting
// the lost phone off needs the words — now, while they are typed. Each
// device: name, when it was last online, "Disconnect" (server revocation
// signed by the account key; the device leaves every chat — this one's and,
// with the signed proof, the contacts' phones take it out too). "Done" goes
// on; nothing is disconnected without a tap.

import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_button.dart';
import '../../app/adaptive.dart';

/// One of the person's other devices, as the sheet shows it.
class OldDevice {
  const OldDevice({required this.pkHex, required this.primary, required this.lastSeenUnix});
  final String pkHex;
  final bool primary;
  final int lastSeenUnix;
}

String _date(int unix) {
  final d = DateTime.fromMillisecondsSinceEpoch(unix * 1000);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year}';
}

/// Shows the sheet; [disconnect] cuts one device off (true when it worked).
Future<void> showOldDevicesSheet(
  BuildContext context, {
  required List<OldDevice> devices,
  required Future<bool> Function(String pkHex) disconnect,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    dsSheetRoute<void>(context, (_) => OldDevicesSheet(devices: devices, disconnect: disconnect), dismissible: false),
  );
}

class OldDevicesSheet extends StatefulWidget {
  const OldDevicesSheet({super.key, required this.devices, required this.disconnect});
  final List<OldDevice> devices;
  final Future<bool> Function(String pkHex) disconnect;

  @override
  State<OldDevicesSheet> createState() => _OldDevicesSheetState();
}

class _OldDevicesSheetState extends State<OldDevicesSheet> {
  final _gone = <String>{};
  final _failed = <String>{};
  String? _busy;

  Future<void> _cut(String pk) async {
    setState(() {
      _busy = pk;
      _failed.remove(pk);
    });
    final ok = await widget.disconnect(pk);
    if (!mounted) return;
    setState(() {
      _busy = null;
      (ok ? _gone : _failed).add(pk);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return DsSheetPlacement(
      dismissible: false,
      builder: (context) {
        final mq = MediaQuery.of(context);
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: Container(
            width: double.infinity,
            color: tokens.surface,
            padding: EdgeInsets.fromLTRB(DsSpace.x5, DsSpace.x2, DsSpace.x5, mq.padding.bottom + DsSpace.x4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const DsSheetGrabber(),
                const SizedBox(height: DsSpace.x5),
                Text(
                  l.oldDevicesTitle,
                  textAlign: TextAlign.center,
                  style: DsText.title3.copyWith(fontWeight: FontWeight.w700, color: tokens.text),
                ),
                const SizedBox(height: DsSpace.x1h5),
                Text(
                  l.oldDevicesBody,
                  textAlign: TextAlign.center,
                  style: DsText.footnote.copyWith(color: tokens.text3),
                ),
                const SizedBox(height: DsSpace.x4),
                for (final d in widget.devices)
                  Padding(
                    key: ValueKey('old-device-${d.pkHex}'),
                    padding: const EdgeInsets.symmetric(vertical: DsSpace.x1h5),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.devicesUnnamed,
                                style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                              ),
                              Text(
                                [
                                  if (d.primary) l.devicesFirstDevice,
                                  l.devicesSeenOn(_date(d.lastSeenUnix)),
                                ].join(' · '),
                                style: DsText.footnote.copyWith(
                                  color: _failed.contains(d.pkHex) ? tokens.danger : tokens.text3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_gone.contains(d.pkHex))
                          Text(
                            l.oldDevicesDisconnected,
                            key: ValueKey('old-device-gone-${d.pkHex}'),
                            style: DsText.callout.copyWith(color: tokens.success, fontWeight: FontWeight.w600),
                          )
                        else
                          DsButton(
                            key: ValueKey('old-device-cut-${d.pkHex}'),
                            label: l.oldDevicesDisconnect,
                            variant: DsButtonVariant.danger,
                            size: DsButtonSize.small,
                            fullWidth: false,
                            loading: _busy == d.pkHex,
                            onPressed: _busy != null ? null : () => _cut(d.pkHex),
                          ),
                      ],
                    ),
                  ),
                if (_failed.isNotEmpty) ...[
                  const SizedBox(height: DsSpace.x1),
                  Text(
                    l.devicesRevokeFailed,
                    textAlign: TextAlign.center,
                    style: DsText.footnote.copyWith(color: tokens.danger),
                  ),
                ],
                const SizedBox(height: DsSpace.x4),
                DsButton(
                  key: const ValueKey('old-devices-done'),
                  label: l.done,
                  variant: DsButtonVariant.secondary,
                  onPressed: _busy != null ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
