// iOS-style picker sheet: a title + optional subtitle + the options, the
// current one ticked in the accent colour; returns the picked value (or
// null if cancelled). The same sheet as every other ([dsSheetRoute]).
//
// API:
//   final picked = await showDsPickerSheet(
//     context: ctx,
//     title: 'Last seen',
//     options: ['Everyone', 'My contacts', 'Nobody'],
//     current: lastSeen,
//   );
//   if (picked != null) setState(() => lastSeen = picked);

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

import '../app/adaptive.dart';
import '../app/theme/tokens.dart';
import '../l10n/l10n.dart';
import 'ds_action_sheet.dart';

/// Show the picker sheet. Returns the picked option or null on dismiss.
Future<String?> showDsPickerSheet({
  required BuildContext context,
  required String title,
  required List<String> options,
  required String current,
  String? subtitle,
}) {
  return Navigator.of(context, rootNavigator: true).push<String>(
    dsSheetRoute<String>(
      context,
      (_) => _DsPickerSheet(title: title, subtitle: subtitle, options: options, current: current),
      dragToDismiss: true,
    ),
  );
}

class _DsPickerSheet extends StatelessWidget {
  const _DsPickerSheet({required this.title, this.subtitle, required this.options, required this.current});

  final String title;
  final String? subtitle;
  final List<String> options;
  final String current;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    Widget divider() => Container(height: 0.5, margin: const EdgeInsets.only(left: DsSpace.x4), color: tokens.divider);
    return DsSheetPlacement(
      radius: tokens.radiusCard,
      builder: (ctx) {
        final mq = MediaQuery.of(ctx);
        final popup = DsSheetPlacement.popupOf(ctx);
        return Container(
          width: double.infinity,
          margin: popup ? EdgeInsets.zero : EdgeInsets.fromLTRB(DsSpace.x2, 0, DsSpace.x2, mq.padding.bottom + DsSpace.x2),
          constraints: BoxConstraints(maxHeight: mq.size.height * 0.8),
          decoration: dsSheetCard(tokens),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(padding: EdgeInsets.only(top: DsSpace.x2), child: DsSheetGrabber()),
              DsSheetTitle(title, subtitle: subtitle),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        if (i > 0) divider(),
                        DsMenuRow(
                          label: options[i],
                          selected: options[i] == current,
                          icon: options[i] == current ? CupertinoIcons.checkmark_alt : null,
                          onTap: () => Navigator.of(ctx).pop(options[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Container(height: DsSpace.x2, color: tokens.bgSoft),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(ctx).pop(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: DsSpace.x3h5),
                  child: Text(
                    ctx.l10n.cancel,
                    textAlign: TextAlign.center,
                    style: DsText.headline.copyWith(color: tokens.accent),
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
