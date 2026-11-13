// The compact search field (bgSoft pill): magnifier, text, × to clear.
// Was the new-group screen's own; Contacts and Calls search with it too
// (tech-debt 2.34).

import 'package:flutter/services.dart' show TextInputAction;
import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import 'ds_shared_glyphs.dart';
import 'ds_text_field.dart';

// Stateful so the field keeps one FocusNode: a node made in build was
// replaced on every keystroke, so Done unfocused a fresh node and the
// keyboard never went away.
class DsSearchPill extends StatefulWidget {
  final TextEditingController controller;

  /// Shown while the field is empty ("Search contacts").
  final String? hint;

  /// Focus the field (and raise the keyboard) as soon as it shows — a
  /// search the user just asked for.
  final bool autofocus;

  const DsSearchPill({super.key, required this.controller, this.hint, this.autofocus = false});

  @override
  State<DsSearchPill> createState() => _DsSearchPillState();
}

class _DsSearchPillState extends State<DsSearchPill> {
  final FocusNode _focus = FocusNode();

  TextEditingController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(DsSearchPill old) {
    super.didUpdateWidget(old);
    if (old.controller != controller) {
      old.controller.removeListener(_changed);
      controller.addListener(_changed);
    }
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final style = DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text);
    final hint = widget.hint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, DsSpace.x1h5),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5),
        decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CustomPaint(painter: DsSearchGlyphGlyph(color: tokens.text3)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  if (hint != null && controller.text.isEmpty)
                    IgnorePointer(child: Text(hint, style: style.copyWith(color: tokens.text3))),
                  Semantics(
                    label: hint,
                    child: DsPlainField(
                    controller: controller,
                    focusNode: _focus,
                    autofocus: widget.autofocus,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _focus.unfocus(),
                    style: style,
                    cursorColor: tokens.accent,
                    backgroundCursorColor: tokens.text4,
                  ),
                  ),
                ],
              ),
            ),
            if (controller.text.isNotEmpty)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => controller.clear(),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CustomPaint(painter: DsXmarkGlyph(color: tokens.text3)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
