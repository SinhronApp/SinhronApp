// Pick a chat to forward a message to — UI backlog §3 item 24.

import 'package:flutter/widgets.dart';

import '../../app/theme/tokens.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_avatar.dart';
import '../chat_list/chat_data.dart';
import '../../l10n/l10n.dart';
import '../../app/adaptive.dart';

/// [title] — "Forward to…" unless given ("Send contact to…").
Future<ChatPreview?> showForwardSheet(BuildContext context, List<ChatPreview> chats, {String? title}) {
  return Navigator.of(context, rootNavigator: true).push<ChatPreview>(
    dsSheetRoute<ChatPreview>(context, (_) => _ForwardSheet(chats: chats, title: title)),
  );
}

class _ForwardSheet extends StatelessWidget {
  const _ForwardSheet({required this.chats, this.title});
  final List<ChatPreview> chats;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return DsSheetPlacement(
      radius: tokens.radiusCard,
      builder: (context) {
        final size = MediaQuery.sizeOf(context);
        final pad = MediaQuery.paddingOf(context);
        final popup = DsSheetPlacement.popupOf(context);
        return Container(
          height: size.height * (popup ? 0.8 : 0.62),
          margin: popup ? EdgeInsets.zero : EdgeInsets.fromLTRB(DsSpace.x2, 0, DsSpace.x2, pad.bottom + DsSpace.x2),
          decoration: dsSheetCard(tokens),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const Padding(padding: EdgeInsets.only(top: DsSpace.x2), child: DsSheetGrabber()),
              Padding(
                padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2h5),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title ?? context.l10n.forwardTo, style: DsText.headline.copyWith(color: tokens.text)),
                    ),
                    GestureDetector(
                      key: const ValueKey('forward-cancel'),
                      onTap: () => Navigator.of(context).pop(),
                      child: Text(context.l10n.cancel, style: DsText.bodyLarge.copyWith(color: tokens.accent)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: chats.isEmpty
                    ? Center(
                        child: Text(context.l10n.noOtherChats, style: DsText.body.copyWith(color: tokens.text3)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: DsSpace.x2),
                        itemCount: chats.length,
                        itemBuilder: (_, i) => GestureDetector(
                          key: ValueKey('forward-${chats[i].id}'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => Navigator.of(context).pop(chats[i]),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x2),
                            child: Row(
                              children: [
                                DsAvatar(
                                  name: chats[i].name,
                                  size: 40,
                                  group: chats[i].group,
                                  image: chats[i].avatar,
                                  saved: chats[i].saved,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    chats[i].name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: DsText.bodyLarge.copyWith(color: tokens.text),
                                  ),
                                ),
                              ],
                            ),
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
