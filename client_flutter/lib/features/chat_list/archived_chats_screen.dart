// Archived chats — UI backlog §2 item 12. Reached from the "Archived
// chats" row at the top of the All folder. Same swipe / long-press
// actions as the main list (swipe "Unarchive" brings a chat back).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/providers/chat_providers.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_empty_state.dart';
import '../../widgets/ds_motion.dart';
import 'chat_data.dart';
import 'chat_list_screen.dart';
import '../../l10n/l10n.dart';

class ArchivedChatsScreen extends ConsumerWidget {
  const ArchivedChatsScreen({super.key, this.onBack, this.onChatTap});

  final VoidCallback? onBack;
  final void Function(ChatPreview chat)? onChatTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final archived = (ref.watch(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.archived).toList();
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: context.l10n.archivedChats, onBack: onBack),
            Expanded(
              child: archived.isEmpty
                                    ? DsEmptyState(
                      illustration: DsIllustration.archive,
                      title: context.l10n.noArchivedChats,
                      body: context.l10n.archiveHint,
                    )
                  : DsAppearScope(
                      child: ListView.builder(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.only(bottom: pad.bottom),
                        itemCount: archived.length,
                        // Rows glide up when one above is unarchived.
                        findChildIndexCallback: (key) {
                          final i = archived.indexWhere((c) => key == ValueKey('slot:${c.id}'));
                          return i < 0 ? null : i;
                        },
                        itemBuilder: (_, i) => DsReorderSlide(
                          key: ValueKey('slot:${archived[i].id}'),
                          child: DsAppear(
                            index: i,
                            child: ChatRowWithActions(
                              key: ValueKey('chat-${archived[i].id}'),
                              chat: archived[i],
                              isLast: i == archived.length - 1,
                              pinnedIds: const [],
                              onTap: () => onChatTap?.call(archived[i]),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
