// Settings → Privacy → Proxy (Tor). The phone's server traffic (WS,
// HTTP, link previews) goes through a SOCKS5 proxy — e.g. Orbot on
// 127.0.0.1:9050 — so the server doesn't see the phone's IP. Calls
// (WebRTC) don't. Saving reconnects.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/session.dart';
import '../calls/call_path.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '_shared.dart';

/// `host:port` or empty.
bool isValidProxy(String s) => s.isEmpty || RegExp(r'^[A-Za-z0-9.\-]+:\d{1,5}$').hasMatch(s);

class ProxyScreen extends ConsumerStatefulWidget {
  const ProxyScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  ConsumerState<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends ConsumerState<ProxyScreen> {
  final _field = TextEditingController();
  String? _error;
  bool _loaded = false;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final v = _field.text.trim().replaceFirst(RegExp(r'^socks5h?://'), '');
    if (!isValidProxy(v)) {
      setState(() => _error = context.l10n.proxyInvalid);
      return;
    }
    await ref.read(socksProxyProvider.notifier).save(v);
    try {
      core.netSetSocksProxy(proxy: v);
    } catch (_) {}
    // New connections use it.
    try {
      await ref.read(sessionProvider).resume(force: true);
    } catch (_) {}
    if (mounted) widget.onBack?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final current = ref.watch(socksProxyProvider).value;
    if (!_loaded && current != null) {
      _field.text = current;
      _loaded = true;
    }
    return ColoredBox(
      key: const ValueKey('proxy-screen'),
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: l.proxyTitle, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                // Sections bring their own side margins: the field and the
                // button line up with the cards below (the cards sat
                // further in — 2026-10-16 UI audit).
                padding: EdgeInsets.fromLTRB(0, DsSpace.x4, 0, pad.bottom + DsSpace.x6),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                  Text(l.proxyBody, style: DsText.callout.copyWith(color: tokens.text2)),
                  const SizedBox(height: DsSpace.x5),
                  DsTextField(
                    key: const ValueKey('proxy-field'),
                    controller: _field,
                    hintText: '127.0.0.1:9050',
                    keyboardType: TextInputType.url,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: DsSpace.x2),
                    Text(_error!, style: DsText.subhead.copyWith(color: tokens.danger)),
                  ],
                  const SizedBox(height: DsSpace.x5),
                  DsButton(key: const ValueKey('proxy-save'), label: l.proxySave, onPressed: _save),
                      ],
                    ),
                  ),
                  const SizedBox(height: DsSpace.x6),
                  // ADR-042 — calls only through the reserve path (443).
                  SettingsSection(
                    title: l.callsReserveSection,
                    footer: l.callsReserveFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('setting-calls-reserve'),
                        label: l.callsReserve,
                        toggle: ref.watch(callsReserveAlwaysProvider).value ?? false,
                        onToggle: (v) => ref.read(callsReserveAlwaysProvider.notifier).save(v),
                        isLast: true,
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
