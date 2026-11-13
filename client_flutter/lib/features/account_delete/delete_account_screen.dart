// Delete account — the real flow (ADR-037; App Store 5.1.1(v)).
//
// What it says is what happens: the account goes from the server at once
// (key, devices, queued messages), groups are told I left, this phone is
// wiped. Messages already sent stay with the people who got them.
//
// Confirm by typing a word (DELETE / УДАЛИТЬ). A device paired by QR holds
// no account key (ADR-027) — it asks for the 24 words, used for this call
// only.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_text_field.dart';
import '../app_lock/app_lock.dart';

class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({
    super.key,
    required this.server,
    required this.onDelete,
    this.needsPhrase = false,
    this.askPhrase,
    this.otherDevices = 0,
    this.onBack,
  });

  /// The server the account lives on (shown in the warning).
  final String server;

  /// Delete on the server, tell the groups, wipe this phone. Throws on
  /// failure (nothing is wiped then). [phrase] — the 24 words when
  /// [needsPhrase].
  final Future<void> Function(String? phrase) onDelete;

  /// This device has no account key (paired by QR).
  final bool needsPhrase;

  /// Ask for the 24 words; null = the person backed out.
  final Future<String?> Function()? askPhrase;

  /// My other devices — they stop working too.
  final int otherDevices;

  final VoidCallback? onBack;

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _confirm.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  bool get _typed => _confirm.text.trim().toUpperCase() == context.l10n.deleteAccountWord.toUpperCase();

  Future<void> _delete() async {
    if (_busy || !_typed) return;
    // Audit LOCK-6 — only the owner: Face ID / the phone's passcode first.
    if (!await confirmOwner(ref, context.l10n.deleteAccountTitle) || !mounted) return;
    String? phrase;
    if (widget.needsPhrase) {
      phrase = await widget.askPhrase?.call();
      if (phrase == null || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final failed = context.l10n.deleteAccountFailed;
    try {
      await widget.onDelete(phrase);
    } catch (_) {
      if (mounted) setState(() => _error = failed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final points = [
      l.deleteAccountServer(widget.server),
      l.deleteAccountGroups,
      l.deleteAccountThisPhone,
      if (widget.otherDevices > 0) l.deleteAccountOtherDevices(widget.otherDevices),
      l.deleteAccountSentStays,
      l.deleteAccountPhrase,
    ];
    return ColoredBox(
      key: const ValueKey('delete-account'),
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: l.deleteAccountTitle, onBack: _busy ? null : widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  Text(l.deleteAccountCannotUndo, style: DsText.title3.copyWith(color: tokens.text)),
                  const SizedBox(height: DsSpace.x3),
                  for (final p in points)
                    Padding(
                      padding: const EdgeInsets.only(bottom: DsSpace.x2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('•  ', style: DsText.callout.copyWith(color: tokens.text2)),
                          Expanded(child: Text(p, style: DsText.callout.copyWith(color: tokens.text2))),
                        ],
                      ),
                    ),
                  const SizedBox(height: DsSpace.x4),
                  Text(l.deleteAccountTypeWord(l.deleteAccountWord), style: DsText.subhead.copyWith(color: tokens.text)),
                  const SizedBox(height: DsSpace.x2),
                  DsTextField(
                    key: const ValueKey('delete-account-confirm'),
                    controller: _confirm,
                    hintText: l.deleteAccountWord,
                    enabled: !_busy,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _delete(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: DsSpace.x2),
                    Text(_error!, style: DsText.subhead.copyWith(color: tokens.danger)),
                  ],
                  const SizedBox(height: DsSpace.x5),
                  DsButton(
                    key: const ValueKey('delete-account-go'),
                    label: l.deleteAccountTitle,
                    variant: DsButtonVariant.danger,
                    loading: _busy,
                    onPressed: _typed && !_busy ? _delete : null,
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
