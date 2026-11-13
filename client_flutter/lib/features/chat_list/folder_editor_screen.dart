// Folder editor — UI backlog §2 item 11. Create or edit a custom folder:
// name, emoji, chat types (personal / groups), which chats (only unread;
// muted and archived chats: show / hide / only them — 2026-10-18) and
// per-chat include / exclude. Saved to the encrypted settings table via
// [customFoldersProvider]; nothing leaves the device.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/providers/chat_providers.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_text_field.dart';
import '../settings/_shared.dart';
import 'chat_data.dart';
import 'chat_folders_screen.dart' show FolderEmojiTile;
import 'folders.dart';
import '../../l10n/l10n.dart';

const kFolderEmoji = [
  '', '💬', '⭐️', '💼', '🏠', '👨‍👩‍👧', '❤️', '🎓', '🎮', '✈️', '🛒', '🔒', //
  '📚', '💡', '🎵', '⚽️', '🍕', '💰', '🛠️', '🐶', '🌿', '🎉', '📌', '🔕', '🔔', '🗂️',
];

class FolderEditorScreen extends ConsumerStatefulWidget {
  const FolderEditorScreen({super.key, this.folder, this.onDone});

  /// null = create a new folder.
  final ChatFolder? folder;

  /// Called after save / delete / cancel.
  final VoidCallback? onDone;

  @override
  ConsumerState<FolderEditorScreen> createState() => _FolderEditorScreenState();
}

class _FolderEditorScreenState extends ConsumerState<FolderEditorScreen> {
  late ChatFolder _draft = widget.folder ?? ChatFolder(id: newFolderId(), name: '');
  late final TextEditingController _name = TextEditingController(text: _draft.name);

  bool get _isNew => widget.folder == null;
  bool get _canSave => _name.text.trim().isNotEmpty;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_canSave) return;
    await ref.read(customFoldersProvider.notifier).upsert(_draft.copyWith(name: _name.text.trim()));
    widget.onDone?.call();
  }

  Future<void> _delete() async {
    final ok = await showDsActionSheet<bool>(
      context,
      title: context.l10n.deleteFolderConfirm(_draft.name),
      actions: [DsSheetAction(context.l10n.deleteFolder, true, destructive: true)],
    );
    if (ok != true) return;
    await ref.read(customFoldersProvider.notifier).delete(_draft.id);
    widget.onDone?.call();
  }

  String _ruleLabel(FolderRule r) => switch (r) {
        FolderRule.show => context.l10n.ruleShow,
        FolderRule.hide => context.l10n.ruleHide,
        FolderRule.only => context.l10n.ruleOnly,
      };

  Future<FolderRule?> _pickRule(String title) => showDsActionSheet<FolderRule>(
        context,
        title: title,
        actions: [for (final r in FolderRule.values) DsSheetAction(_ruleLabel(r), r)],
      );

  /// Chat row tap cycles: rule-based → always include → always exclude.
  void _cycle(String id) {
    final inc = {..._draft.includeChatIds};
    final exc = {..._draft.excludeChatIds};
    if (inc.remove(id)) {
      exc.add(id);
    } else if (!exc.remove(id)) {
      inc.add(id);
    }
    setState(() => _draft = _draft.copyWith(includeChatIds: inc, excludeChatIds: exc));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final chats = (ref.watch(chatsProvider).value ?? const <ChatPreview>[])
        .where((c) => c.id != null && (!c.archived || _draft.archived != FolderRule.hide))
        .toList();
    final matching = chatsInFolder(_draft, chats).length;

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(
              title: _isNew ? context.l10n.newFolder : context.l10n.editFolder,
              onBack: widget.onDone,
              trailing: GestureDetector(
                key: const ValueKey('folder-save'),
                behavior: HitTestBehavior.opaque,
                onTap: _canSave ? _save : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x2h5),
                  child: Text(
                    context.l10n.save,
                    style: DsText.bodyLarge.copyWith(
                      fontWeight: FontWeight.w600,
                      color: _canSave ? tokens.accent : tokens.text4,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(0, DsSpace.x2, 0, pad.bottom + DsSpace.x6),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4),
                    child: Row(
                      children: [
                        FolderEmojiTile(emoji: _draft.emoji, size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DsTextField(
                            key: const ValueKey('folder-name'),
                            controller: _name,
                            hintText: context.l10n.folderName,
                            autofocus: _isNew,
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 44,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3),
                      children: [
                        for (final e in kFolderEmoji)
                          GestureDetector(
                            key: ValueKey('folder-emoji-$e'),
                            onTap: () => setState(() => _draft = _draft.copyWith(emoji: e)),
                            child: Container(
                              width: 44,
                              margin: const EdgeInsets.symmetric(horizontal: DsSpace.nudge3),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: _draft.emoji == e ? tokens.surface : DsPalette.transparent,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: _draft.emoji == e ? tokens.accent : DsPalette.transparent,
                                  width: 1.5,
                                ),
                              ),
                              child: Text(e.isEmpty ? '—' : e, style: DsText.title3.copyWith(color: tokens.text3)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: DsSpace.x4),
                  SettingsSection(
                    title: context.l10n.folderChatTypes,
                    children: [
                      SettingsRow(
                        label: context.l10n.allPersonal,
                        toggle: _draft.includePersonal,
                        onToggle: (v) => setState(() => _draft = _draft.copyWith(includePersonal: v)),
                      ),
                      SettingsRow(
                        label: context.l10n.allGroups,
                        toggle: _draft.includeGroups,
                        onToggle: (v) => setState(() => _draft = _draft.copyWith(includeGroups: v)),
                        isLast: true,
                      ),
                    ],
                  ),
                  SettingsSection(
                    title: context.l10n.folderWhichChats,
                    footer: context.l10n.folderRulesFooter,
                    children: [
                      SettingsRow(
                        key: const ValueKey('folder-only-unread'),
                        label: context.l10n.onlyUnread,
                        toggle: _draft.excludeRead,
                        onToggle: (v) => setState(() => _draft = _draft.copyWith(excludeRead: v)),
                      ),
                      SettingsRow(
                        key: const ValueKey('folder-muted-rule'),
                        label: context.l10n.mutedChats,
                        value: _ruleLabel(_draft.muted),
                        onTap: () async {
                          final r = await _pickRule(context.l10n.mutedChats);
                          if (r != null && mounted) setState(() => _draft = _draft.copyWith(muted: r));
                        },
                      ),
                      SettingsRow(
                        key: const ValueKey('folder-archived-rule'),
                        label: context.l10n.archivedChats,
                        value: _ruleLabel(_draft.archived),
                        onTap: () async {
                          final r = await _pickRule(context.l10n.archivedChats);
                          if (r != null && mounted) setState(() => _draft = _draft.copyWith(archived: r));
                        },
                        isLast: true,
                      ),
                    ],
                  ),
                  if (chats.isNotEmpty)
                    SettingsSection(
                      title: context.l10n.chatsInFolderCount(matching),
                      footer: context.l10n.folderChatHint,
                      children: [
                        for (var i = 0; i < chats.length; i++)
                          SettingsRow(
                            key: ValueKey('folder-chat-${chats[i].id}'),
                            label: chats[i].name,
                            value: _draft.includeChatIds.contains(chats[i].id)
                                ? context.l10n.included
                                : _draft.excludeChatIds.contains(chats[i].id)
                                ? context.l10n.hidden
                                : (_draft.matches(chats[i]) ? context.l10n.byRule : ''),
                            onTap: () => _cycle(chats[i].id!),
                            isLast: i == chats.length - 1,
                          ),
                      ],
                    ),
                  if (!_isNew)
                    SettingsSection(
                      children: [
                        GestureDetector(
                          key: const ValueKey('folder-delete'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _delete,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: DsSpace.x3h5),
                            child: Center(
                              child: Text(
                                context.l10n.deleteFolder,
                                style: DsText.bodyLarge.copyWith(color: tokens.danger),
                              ),
                            ),
                          ),
                        ),
                      ],
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
