// "Rename group" — ADR-035. The new name goes to every member (an
// encrypted `group_name` action); only the group's admin may do it.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_page_route.dart';
import '../../widgets/ds_text_field.dart';

/// The new name (trimmed, non-empty), or null if the user backed out.
Future<String?> promptGroupName(BuildContext context, String current) => Navigator.of(
  context,
).push<String>(DsPageRoute<String>(builder: (_) => GroupRenameScreen(current: current)));

class GroupRenameScreen extends StatefulWidget {
  const GroupRenameScreen({super.key, required this.current});
  final String current;

  @override
  State<GroupRenameScreen> createState() => _GroupRenameScreenState();
}

class _GroupRenameScreenState extends State<GroupRenameScreen> {
  late final _name = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final clean = _name.text.trim();
    Navigator.of(context).pop(clean.isEmpty || clean == widget.current ? null : clean);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final l = context.l10n;
    return ColoredBox(
      key: const ValueKey('group-rename'),
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: l.groupRename, onBack: () => Navigator.of(context).pop()),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(DsSpace.gutter, DsSpace.x4, DsSpace.gutter, pad.bottom + DsSpace.x6),
                children: [
                  DsTextField(
                    key: const ValueKey('group-rename-field'),
                    controller: _name,
                    autofocus: true,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                  ),
                  const SizedBox(height: DsSpace.x5),
                  DsButton(key: const ValueKey('group-rename-save'), label: l.save, onPressed: _save),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
