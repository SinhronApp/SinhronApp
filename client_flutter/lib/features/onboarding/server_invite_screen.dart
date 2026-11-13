// The first onboarding step for every path (new account, sign in with the
// 24 words, link by QR): which server (ADR-032). Nothing is compiled in —
// the person types the address the server's owner gave them, or scans the
// QR the installer printed. Before going on, `/_healthz` must answer as a
// Sinhron server; if it doesn't answer at all the person may still go on
// (their network may need a proxy, the server may be restarting).
//
// Per spec §6.1 this binds the account to exactly one server.

import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/qr_scan.dart';
import '../../core/server_address.dart';
import '../../core/session.dart' show serverUrlProvider;
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../../l10n/l10n.dart';

class ServerInviteScreen extends ConsumerStatefulWidget {
  final VoidCallback? onBack;

  /// Called once the server is saved (`server_url`).
  final VoidCallback? onContinue;

  /// Prefilled address (dev builds, a deep link).
  final String? initialServer;

  /// "1 / 3" in the new-account flow; none when signing in.
  final String? step;

  const ServerInviteScreen({super.key, this.onBack, this.onContinue, this.initialServer, this.step = '1 / 3'});

  @override
  ConsumerState<ServerInviteScreen> createState() => _ServerInviteScreenState();
}

enum _Problem { none, invalid, notSinhron, unreachable, notSaved }

class _ServerInviteScreenState extends ConsumerState<ServerInviteScreen> {
  late final TextEditingController _ctrl;
  bool _checking = false;
  _Problem _problem = _Problem.none;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialServer ?? _prefill(kDevServerUrl));
    _ctrl.addListener(_onChanged);
  }

  /// `wss://host/v1/sync` → `host` for the field.
  static String _prefill(String ws) {
    if (ws.isEmpty) return '';
    final base = httpBaseOf(ws);
    return base.startsWith('https://') ? base.substring(8) : base;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (_problem != _Problem.none) setState(() => _problem = _Problem.none);
    setState(() {});
  }

  Future<void> _scan() async {
    final text = await ref.read(qrScannerProvider)();
    if (!mounted || text == null) return;
    final url = normalizeServerInput(text);
    // A scanned code never picks a server without TLS (ADR-032: http:// and
    // ws:// only when typed).
    if (url == null || !url.startsWith('wss://')) {
      setState(() => _problem = _Problem.invalid);
      return;
    }
    _ctrl.text = _prefill(url);
    await _continue();
  }

  Future<void> _continue({bool anyway = false}) async {
    final url = normalizeServerInput(_ctrl.text);
    if (url == null) {
      setState(() => _problem = _Problem.invalid);
      return;
    }
    if (!anyway) {
      setState(() => _checking = true);
      final check = await checkServer(url, get: ref.read(serverHttpGetProvider));
      if (!mounted) return;
      setState(() => _checking = false);
      if (check != ServerCheck.ok) {
        setState(() => _problem = check == ServerCheck.notSinhron ? _Problem.notSinhron : _Problem.unreachable);
        return;
      }
    }
    // Saving goes to the local database. If it isn't open (a broken boot),
    // say so — Continue used to do nothing at all.
    try {
      await ref.read(serverUrlProvider.notifier).save(url);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] server url not saved: $e');
      if (mounted) setState(() => _problem = _Problem.notSaved);
      return;
    }
    if (!mounted) return;
    widget.onContinue?.call();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final l = context.l10n;
    final problem = switch (_problem) {
      _Problem.none => null,
      _Problem.invalid => l.serverInvalid,
      _Problem.notSinhron => l.serverNotSinhron,
      _Problem.unreachable => l.serverUnreachable,
      _Problem.notSaved => l.serverNotSaved,
    };

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            DsAppBar(step: widget.step, onBack: widget.onBack),
            // Scrolls when the keyboard leaves too little room; the buttons
            // stay above the keyboard (2026-10-16 UI audit).
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
                  Text(l.pickServer, style: DsText.display.copyWith(fontWeight: FontWeight.w600, color: tokens.text)),
                  const SizedBox(height: DsSpace.x2),
                  Text(
                    l.pickServerBody,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text2),
                  ),
                ],
              ),
            ),
            const SizedBox(height: DsSpace.x7),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DsTextField(
                    key: const ValueKey('server-field'),
                    label: l.server,
                    controller: _ctrl,
                    mono: true,
                    autofocus: _ctrl.text.isEmpty,
                    hintText: 'sinhron.example.com',
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _continue(),
                  ),
                  const SizedBox(height: DsSpace.x3),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1),
                    child: Text(
                      problem ?? l.serverHowToGet,
                      key: const ValueKey('server-note'),
                      style: DsText.footnote.copyWith(color: problem == null ? tokens.text3 : tokens.danger),
                    ),
                  ),
                  if (_problem == _Problem.unreachable) ...[
                    const SizedBox(height: DsSpace.x2),
                    DsButton(
                      key: const ValueKey('server-anyway'),
                      label: l.serverContinueAnyway,
                      variant: DsButtonVariant.ghost,
                      size: DsButtonSize.small,
                      fullWidth: false,
                      onPressed: () => _continue(anyway: true),
                    ),
                  ],
                ],
              ),
            ),
                    const SizedBox(height: DsSpace.x4),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x3),
              child: DsButton(
                key: const ValueKey('server-scan'),
                label: l.serverScanQr,
                variant: DsButtonVariant.secondary,
                onPressed: _checking ? null : _scan,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(DsSpace.x6, 0, DsSpace.x6, DsSpace.x4h5),
              child: DsButton(
                key: const ValueKey('server-continue'),
                label: l.continueBtn,
                variant: DsButtonVariant.primary,
                loading: _checking,
                onPressed: _ctrl.text.trim().isEmpty || _checking ? null : () => _continue(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
