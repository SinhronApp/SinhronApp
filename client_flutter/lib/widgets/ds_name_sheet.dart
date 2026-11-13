// A small card in the middle of the screen over a blurred backdrop — the
// link sheet (composer) and "Edit name" (a contact's name for me only).

import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter/widgets.dart';

import '../app/adaptive.dart' show kPopupMaxWidth;
import '../app/theme/tokens.dart';
import '../core/providers/settings_providers.dart' show kMaxContactNameChars;
import '../l10n/l10n.dart';
import 'ds_action_sheet.dart';
import 'ds_button.dart';
import 'ds_text_field.dart';

/// Push [sheet] centred over a blur; tapping outside closes it (null).
Future<T?> showCentredSheet<T>(BuildContext context, Widget sheet) =>
    Navigator.of(context, rootNavigator: true).push<T>(dsSheetRoute<T>(context, (_) => sheet, centred: true));

/// The card itself: [children] in a column, lifted over the keyboard.
class DsCentredCard extends StatelessWidget {
  const DsCentredCard({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: DsSpace.x6),
          padding: const EdgeInsets.all(DsSpace.x5),
          constraints: const BoxConstraints(maxWidth: kPopupMaxWidth),
          decoration: dsSheetCard(tokens),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    );
  }
}

/// "Edit name" for a person, prefilled with [current]: resolves to the new
/// name, '' to go back to theirs ([restore] = their own name, shown only
/// while I have one of mine set), or null on cancel.
Future<String?> showNameSheet(BuildContext context, {required String current, String? restore}) =>
    showCentredSheet<String>(context, _NameSheet(current: current, restore: restore));

class _NameSheet extends StatefulWidget {
  const _NameSheet({required this.current, this.restore});
  final String current;
  final String? restore;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _c = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final restore = widget.restore;
    return DsCentredCard(
      key: const ValueKey('name-sheet'),
      children: [
        Text(l.contactEditName, style: DsText.headline.copyWith(color: tokens.text)),
        const SizedBox(height: DsSpace.x3),
        DsTextField(
          key: const ValueKey('name-field'),
          controller: _c,
          autofocus: true,
          inputFormatters: [LengthLimitingTextInputFormatter(kMaxContactNameChars)],
          onSubmitted: (_) => Navigator.of(context).pop(_c.text),
        ),
        const SizedBox(height: DsSpace.x2),
        Text(l.contactNameOnlyYou, style: DsText.footnote.copyWith(color: tokens.text3)),
        const SizedBox(height: DsSpace.x4),
        DsButton(
          key: const ValueKey('name-done'),
          label: l.done,
          onPressed: () => Navigator.of(context).pop(_c.text),
        ),
        if (restore != null) ...[
          const SizedBox(height: DsSpace.x2),
          DsButton(
            key: const ValueKey('name-restore'),
            label: l.contactNameRestore(restore),
            variant: DsButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(''),
          ),
        ],
        const SizedBox(height: DsSpace.x2),
        DsButton(label: l.cancel, variant: DsButtonVariant.ghost, onPressed: () => Navigator.of(context).pop()),
      ],
    );
  }
}
