// This device was disconnected from its account (owner, 2026-11-01).
//
// Another of my devices removed this one ("Devices" → Disconnect), so the
// server turns it away ("device disconnected"). It used to keep showing
// the old chats and "Connecting…" forever; now it says what happened and
// offers the only way on: erase this device's copy and start over.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/sinhron_mark.dart';

class DeviceRemovedScreen extends ConsumerStatefulWidget {
  const DeviceRemovedScreen({super.key});

  @override
  ConsumerState<DeviceRemovedScreen> createState() => _DeviceRemovedScreenState();
}

class _DeviceRemovedScreenState extends ConsumerState<DeviceRemovedScreen> {
  bool _busy = false;

  Future<void> _signOut() async {
    setState(() => _busy = true);
    try {
      await ref.read(sessionProvider).eraseAndStartOver(); // clears the flag too
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      appNotice.value = context.l10n.signOutFailed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    return ColoredBox(
      key: const ValueKey('device-removed-screen'),
      color: tokens.bg,
      child: ListView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(DsSpace.gutter, pad.top + DsSpace.x8, DsSpace.gutter, pad.bottom + DsSpace.x6),
        children: [
          const Center(child: SinhronMark(size: 64)),
          const SizedBox(height: DsSpace.x5),
          Text(
            l.deviceRemovedTitle,
            textAlign: TextAlign.center,
            style: DsText.title2.copyWith(color: tokens.text),
          ),
          const SizedBox(height: DsSpace.x2),
          Text(
            l.deviceRemovedBody,
            textAlign: TextAlign.center,
            style: DsText.callout.copyWith(color: tokens.text2),
          ),
          const SizedBox(height: DsSpace.x6),
          DsButton(
            key: const ValueKey('device-removed-sign-out'),
            label: l.deviceRemovedAction,
            loading: _busy,
            onPressed: _busy ? null : _signOut,
          ),
        ],
      ),
    );
  }
}
