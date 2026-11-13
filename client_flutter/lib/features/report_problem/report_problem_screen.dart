// Settings → "Report a problem" (owner, 2026-10-22). A line or two about
// what happened, what the report holds (and doesn't), a look at it, and
// Send: the system share sheet — Sinhron itself (the chat with whoever
// helps) or Telegram / mail when there's no connection — or Copy.

import 'package:flutter/services.dart' show TextInputAction, TextInputType;
import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_text_field.dart';

class ReportProblemScreen extends StatefulWidget {
  const ReportProblemScreen({super.key, required this.build, this.onSend, this.onCopy, this.onBack});

  /// The report for the note typed (journal and facts read now).
  final Future<String> Function(String note) build;

  /// Share the report (file); false when the sheet was closed.
  final Future<bool> Function(String report)? onSend;
  final Future<void> Function(String report)? onCopy;
  final VoidCallback? onBack;

  @override
  State<ReportProblemScreen> createState() => _ReportProblemScreenState();
}

class _ReportProblemScreenState extends State<ReportProblemScreen> {
  final _note = TextEditingController();
  String? _preview;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _togglePreview() async {
    if (_preview != null) {
      setState(() => _preview = null);
      return;
    }
    try {
      final r = await widget.build(_note.text);
      if (!mounted) return;
      setState(() {
        _preview = r;
        _error = null;
      });
    } catch (e) {
      // Said on the screen — before, a failure here did nothing at all.
      if (mounted) setState(() => _error = context.l10n.reportProblemFailed);
    }
  }

  Future<void> _run(Future<void> Function(String report) f) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f(await widget.build(_note.text));
    } catch (e) {
      if (mounted) setState(() => _error = context.l10n.reportProblemFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    final preview = _preview;
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: l.reportProblemTitle, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x3, DsSpace.x4, pad.bottom + DsSpace.x6),
                children: [
                  DsTextField(
                    key: const ValueKey('report-note'),
                    controller: _note,
                    hintText: l.reportProblemNoteHint,
                    maxLines: 4,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                  ),
                  const SizedBox(height: DsSpace.x3),
                  Container(
                    padding: const EdgeInsets.all(DsSpace.x4),
                    decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(tokens.radiusCard)),
                    child: Text(l.reportProblemWhat, style: DsText.footnote.copyWith(color: tokens.text2)),
                  ),
                  const SizedBox(height: DsSpace.x2),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: DsPressable(
                      key: const ValueKey('report-preview'),
                      onTap: _togglePreview,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: DsSpace.x2),
                        child: Text(
                          preview == null ? l.reportProblemPreview : l.reportProblemHidePreview,
                          style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                        ),
                      ),
                    ),
                  ),
                  DsReveal(
                    open: preview != null,
                    child: Container(
                      key: const ValueKey('report-preview-text'),
                      constraints: const BoxConstraints(maxHeight: 320),
                      padding: const EdgeInsets.all(DsSpace.x3),
                      decoration: BoxDecoration(color: tokens.surface, borderRadius: BorderRadius.circular(12)),
                      child: SingleChildScrollView(
                        child: Text(preview ?? '', style: DsTextArt.t12p5w500Monov2.copyWith(color: tokens.text2)),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: DsSpace.x2),
                    Text(
                      _error!,
                      key: const ValueKey('report-error'),
                      style: DsText.footnote.copyWith(color: tokens.danger),
                    ),
                  ],
                  const SizedBox(height: DsSpace.x4),
                  AnimatedOpacity(
                    opacity: _busy ? 0.6 : 1,
                    duration: DsMotion.fast,
                    child: DsButton(
                      key: const ValueKey('report-send'),
                      label: l.reportProblemSend,
                      loading: _busy,
                      onPressed: widget.onSend == null || _busy ? null : () => _run((r) => widget.onSend!(r)),
                    ),
                  ),
                  const SizedBox(height: DsSpace.x2),
                  DsButton(
                    key: const ValueKey('report-copy'),
                    label: l.reportProblemCopy,
                    variant: DsButtonVariant.secondary,
                    onPressed: widget.onCopy == null || _busy ? null : () => _run(widget.onCopy!),
                  ),
                  const SizedBox(height: DsSpace.x3),
                  Text(
                    l.reportProblemSendHint,
                    textAlign: TextAlign.center,
                    style: DsText.footnote.copyWith(color: tokens.text3),
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
