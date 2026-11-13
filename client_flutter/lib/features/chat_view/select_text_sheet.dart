// "Select text" in the message menu (owner, 2026-11-03): the message's
// words in a large sheet where any part of them can be selected — the
// system's handles, magnifier and Copy — with its formatting kept
// (ADR-070), and "Copy all". SelectableRegion is in the widgets library
// and the handles / toolbar come from Cupertino: no Material.

import 'package:flutter/cupertino.dart'
    show CupertinoAdaptiveTextSelectionToolbar, CupertinoTextMagnifier, cupertinoTextSelectionHandleControls;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart';

import '../../app/adaptive.dart';
import '../../app/theme/tokens.dart';
import '../../core/app_notice.dart';
import '../../core/haptics.dart';
import '../../core/rich_text.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import 'message_text.dart';

/// Shows [text] (mentions already as names) to select from.
Future<void> showSelectTextSheet(BuildContext context, FormattedText text) =>
    Navigator.of(context, rootNavigator: true).push<void>(dsSheetRoute<void>(context, (_) => SelectTextSheet(text: text)));

class SelectTextSheet extends StatelessWidget {
  const SelectTextSheet({super.key, required this.text});
  final FormattedText text;

  Future<void> _copyAll(BuildContext context) async {
    final l = context.l10n;
    final nav = Navigator.of(context);
    // Plain words for other apps; the formatting comes back when pasted
    // into a Sinhron composer.
    RichClipboard.remember(text);
    await Clipboard.setData(ClipboardData(text: text.text));
    DsHaptics.play(Haptic.success);
    showDone(l.copied);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    Widget action(String label, VoidCallback onTap, {Key? key, bool bold = false}) => GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x3),
        child: Text(
          label,
          style: DsText.bodyLarge.copyWith(color: tokens.accent, fontWeight: bold ? FontWeight.w600 : FontWeight.w400),
        ),
      ),
    );
    return DsSheetPlacement(
      radius: tokens.radiusCard,
      builder: (context) {
        final mq = MediaQuery.of(context);
        final popup = DsSheetPlacement.popupOf(context);
        return Container(
          key: const ValueKey('select-text-sheet'),
          height: popup ? mq.size.height : mq.size.height - mq.padding.vertical - DsSpace.x8,
          margin: popup ? EdgeInsets.zero : EdgeInsets.fromLTRB(DsSpace.x2, 0, DsSpace.x2, mq.padding.bottom + DsSpace.x2),
          decoration: dsSheetCard(tokens),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(padding: EdgeInsets.only(top: DsSpace.x2), child: DsSheetGrabber()),
              Row(
                children: [
                  action(l.selectTextClose, () => Navigator.of(context).pop(), key: const ValueKey('select-text-close')),
                  Expanded(
                    child: Text(
                      l.selectText,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.headline.copyWith(color: tokens.text),
                    ),
                  ),
                  action(l.copyAll, () => _copyAll(context), key: const ValueKey('select-text-copy-all'), bold: true),
                ],
              ),
              Container(height: 0.5, color: tokens.divider),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(DsSpace.x5, DsSpace.x4, DsSpace.x5, DsSpace.x8),
                  child: SelectableRegion(
                    selectionControls: cupertinoTextSelectionHandleControls,
                    magnifierConfiguration: TextMagnifierConfiguration(
                      magnifierBuilder: (_, controller, info) =>
                          CupertinoTextMagnifier(controller: controller, magnifierInfo: info),
                    ),
                    contextMenuBuilder: (context, state) => CupertinoAdaptiveTextSelectionToolbar.buttonItems(
                      anchors: state.contextMenuAnchors,
                      buttonItems: state.contextMenuButtonItems,
                    ),
                    child: MessageText(
                      text: text.text,
                      entities: text.entities,
                      style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w400, height: 1.45, color: tokens.text),
                      linkColor: tokens.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
