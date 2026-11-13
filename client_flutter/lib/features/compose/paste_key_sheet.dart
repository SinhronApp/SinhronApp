// New chat → "Paste address" (owner, 2026-10-20: the inline field "вылезает
// и спускает всё"): a sheet that slides up over the list and rides above
// the keyboard. Paste from the clipboard in one tap; a counter says how
// much of the 64-character address is there; a whole contact link
// (`sinhron-contact:…`) works too. Returns the key, or null if dismissed.

import 'package:flutter/services.dart' show Clipboard;
import 'package:flutter/widgets.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/contact_qr.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../../widgets/ds_text_field.dart';
import '../../app/adaptive.dart';

/// The key in [text] — a bare address (spaces allowed) or a contact link —
/// or null.
String? pastedKey(String text) => parseContactQr(text.replaceAll(RegExp(r'\s'), ''))?.identityHex;

Future<String?> showPasteKeySheet(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    dsSheetRoute<String>(context, (_) => const _PasteKeySheet()),
  );
}

class _PasteKeySheet extends StatefulWidget {
  const _PasteKeySheet();

  @override
  State<_PasteKeySheet> createState() => _PasteKeySheetState();
}

class _PasteKeySheetState extends State<_PasteKeySheet> {
  final _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _ctrl.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _start(String key) => Navigator.of(context).pop(key);

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final key = pastedKey(_ctrl.text);
    final typed = _ctrl.text.replaceAll(RegExp(r'\s'), '').length;
    final counter = key != null ? l.pasteKeyReady : l.pasteKeyCount(typed);
    return DsSheetPlacement(
      builder: (context) {
        final mq = MediaQuery.of(context);
        return AnimatedPadding(
          duration: DsMotion.base,
          curve: DsMotion.enter,
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: GestureDetector(
            onTap: () {}, // absorbs taps: keeps the sheet open
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: Container(
                width: double.infinity,
                color: tokens.surface,
                padding: EdgeInsets.fromLTRB(
                  DsSpace.x5,
                  DsSpace.x2,
                  DsSpace.x5,
                  (mq.viewInsets.bottom > 0 ? 0 : mq.padding.bottom) + DsSpace.x4,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const DsSheetGrabber(),
                    const SizedBox(height: DsSpace.x5),
                    Container(
                      width: 56,
                      height: 56,
                      decoration: const BoxDecoration(color: DsPalette.artE0B43Ba1A, shape: BoxShape.circle),
                      child: Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CustomPaint(painter: DsKeyGlyphGlyph(color: DsPalette.artE0B43B)),
                        ),
                      ),
                    ),
                    const SizedBox(height: DsSpace.x3),
                    Text(
                      l.startEncrypted,
                      textAlign: TextAlign.center,
                      style: DsText.title3.copyWith(fontWeight: FontWeight.w700, color: tokens.text),
                    ),
                    const SizedBox(height: DsSpace.x1h5),
                    Text(
                      l.pasteKeyHint,
                      textAlign: TextAlign.center,
                      style: DsText.footnote.copyWith(color: tokens.text3),
                    ),
                    const SizedBox(height: DsSpace.x5),
                    DsTextField(
                      key: const ValueKey('paste-key-field'),
                      controller: _ctrl,
                      hintText: l.keyHint,
                      mono: true,
                      autofocus: true,
                      suffix: _ctrl.text.isNotEmpty
                          ? null
                          : DsPressable(
                              key: const ValueKey('paste-key-paste'),
                              onTap: _paste,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x1),
                                child: Text(
                                  l.pasteFromClipboard,
                                  style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
                                ),
                              ),
                            ),
                    ),
                    const SizedBox(height: DsSpace.x2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: AnimatedDefaultTextStyle(
                        duration: DsMotion.fast,
                        style: DsText.caption.copyWith(
                          fontWeight: FontWeight.w500,
                          color: key != null ? tokens.success : tokens.text3,
                        ),
                        child: Text(counter, key: const ValueKey('paste-key-counter')),
                      ),
                    ),
                    const SizedBox(height: DsSpace.x4),
                    DsButton(
                      key: const ValueKey('paste-key-start'),
                      label: l.startChat,
                      onPressed: key == null ? null : () => _start(key),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
