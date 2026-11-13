// Settings → Chats → Chat folders (owner, 2026-10-18: "этих папок внутри
// настроек почему нет?"). Like Telegram's folder settings: every folder —
// the built-in ones too — in one list with a drag handle and a show/hide
// switch; tap a custom folder to edit it, swipe it to delete; "Create a
// folder"; ready-made folders one tap away. Order and hidden set go to
// [folderLayoutProvider], folders to [customFoldersProvider] — both in
// the encrypted settings table, nothing leaves the device.

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../core/providers/chat_providers.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_icon.dart';
import '../../widgets/ds_page_route.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../../widgets/ds_swipe_actions.dart';
import '../settings/_shared.dart';
import 'chat_data.dart';
import 'folder_editor_screen.dart';
import 'folders.dart';
import 'reorder_screen.dart' show ReorderHandle;

class ChatFoldersScreen extends ConsumerStatefulWidget {
  const ChatFoldersScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  ConsumerState<ChatFoldersScreen> createState() => _ChatFoldersScreenState();
}

class _ChatFoldersScreenState extends ConsumerState<ChatFoldersScreen> {
  /// The order just dropped, until the saved layout catches up — so the
  /// row doesn't jump back for a frame.
  List<String>? _pending;

  void _haptic(Haptic h) => unawaited(ref.read(hapticsProvider).play(h));

  Future<void> _edit(ChatFolder? folder) => Navigator.of(context).push(
        DsPageRoute<void>(
          builder: (ctx) => FolderEditorScreen(folder: folder, onDone: () => Navigator.of(ctx).pop()),
        ),
      );

  void _move(List<ChatFolder> folders, int from, int to) {
    if (to > from) to -= 1; // ReorderableList reports the slot before removal
    if (to == from) return;
    final ids = [for (final f in folders) f.id];
    ids.insert(to, ids.removeAt(from));
    setState(() => _pending = ids);
    _haptic(Haptic.selection);
    unawaited(
      ref.read(folderLayoutProvider.notifier).setOrder(ids).whenComplete(() {
        if (mounted) setState(() => _pending = null);
      }),
    );
  }

  Future<void> _add(ChatFolder template) async {
    _haptic(Haptic.success);
    await ref.read(customFoldersProvider.notifier).upsert(template);
    // A suggestion deleted while hidden comes back shown.
    await ref.read(folderLayoutProvider.notifier).setHidden(template.id, false);
  }

  Future<void> _delete(ChatFolder f) async {
    final ok = await showDsActionSheet<bool>(
      context,
      title: context.l10n.deleteFolderConfirm(f.name),
      actions: [DsSheetAction(context.l10n.deleteFolder, true, destructive: true)],
    );
    if (ok != true) return;
    await ref.read(customFoldersProvider.notifier).delete(f.id);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final saved = ref.watch(orderedFoldersProvider);
    final folders = _pending == null ? saved : applyFolderOrder(saved, _pending!);
    final hidden = ref.watch(hiddenFoldersProvider);
    final chats = ref.watch(chatsProvider).value ?? const <ChatPreview>[];
    final present = {for (final f in folders) f.id};
    final suggestions = [
      for (final s in suggestedFolders(context.l10n))
        if (!present.contains(s.id)) s,
    ];

    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top),
        child: Column(
          children: [
            DsAppBar(title: context.l10n.chatFolders, onBack: widget.onBack ?? () => Navigator.of(context).maybePop()),
            Expanded(
              child: ListView(
                key: const ValueKey('chat-folders-list'),
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.only(bottom: pad.bottom + DsSpace.x6),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x3, DsSpace.x7, DsSpace.x4),
                    child: Text(
                      context.l10n.chatFoldersHint,
                      style: DsText.footnote.copyWith(color: tokens.text3),
                    ),
                  ),
                  SettingsSection(
                    title: context.l10n.myFolders,
                    children: [
                      _CreateRow(onTap: () => _edit(null)),
                      ReorderableList(
                        key: const ValueKey('folders-reorder-list'),
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: folders.length,
                        onReorder: (from, to) => _move(folders, from, to),
                        onReorderStart: (_) => _haptic(Haptic.menu),
                        proxyDecorator: (child, _, _) => DecoratedBox(
                          decoration: BoxDecoration(color: tokens.surface, boxShadow: DsShadow.float),
                          child: child,
                        ),
                        itemBuilder: (context, i) {
                          final f = folders[i];
                          return ReorderableDelayedDragStartListener(
                            key: ValueKey('folder-row-${f.id}'),
                            index: i,
                            child: _FolderRow(
                              folder: f,
                              index: i,
                              shown: !hidden.contains(f.id),
                              chatCount: chatsInFolder(f, chats).length,
                              isLast: i == folders.length - 1,
                              onShown: (v) {
                                _haptic(Haptic.selection);
                                ref.read(folderLayoutProvider.notifier).setHidden(f.id, !v);
                              },
                              onTap: f.builtIn ? null : () => _edit(f),
                              onDelete: f.builtIn ? null : () => _delete(f),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                  if (suggestions.isNotEmpty)
                    SettingsSection(
                      title: context.l10n.suggestedFolders,
                      children: [
                        for (var i = 0; i < suggestions.length; i++)
                          _SuggestionRow(
                            key: ValueKey('folder-suggestion-${suggestions[i].id}'),
                            folder: suggestions[i],
                            hint: suggestedFolderHint(context.l10n, suggestions[i].id),
                            isLast: i == suggestions.length - 1,
                            onAdd: () => _add(suggestions[i]),
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

/// "+ Create a folder" — the first row of My folders, in accent.
class _CreateRow extends StatelessWidget {
  const _CreateRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return DsPressable(
      key: const ValueKey('folder-create'),
      scale: 0.985,
      onTap: onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(8)),
              child: CustomPaint(
                size: const Size.square(20),
                painter: DsGlyphPainter(DsGlyph.plus, color: tokens.accent, strokeWidth: 2.2),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              context.l10n.createFolder,
              style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// Emoji in a soft tile — a folder's face in the lists.
class FolderEmojiTile extends StatelessWidget {
  const FolderEmojiTile({super.key, required this.emoji, this.size = 30, this.icon = CupertinoIcons.folder});
  final String emoji;
  final double size;

  /// Shown when there is no emoji (a built-in folder, or none picked yet).
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: tokens.bgSoft, borderRadius: BorderRadius.circular(size * 0.27)),
      child: emoji.isEmpty
          ? Icon(icon, size: size * 0.55, color: tokens.accent)
          : Text(emoji, style: DsText.body.copyWith(fontSize: size * 0.53, height: 1)),
    );
  }
}

class _FolderRow extends StatelessWidget {
  const _FolderRow({
    required this.folder,
    required this.index,
    required this.shown,
    required this.chatCount,
    required this.isLast,
    required this.onShown,
    this.onTap,
    this.onDelete,
  });

  final ChatFolder folder;
  final int index;
  final bool shown;
  final int chatCount;
  final bool isLast;
  final ValueChanged<bool> onShown;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final title = folderTitle(context, folder);
    final count = context.l10n.folderChatCount(chatCount);
    Widget row = Container(
      height: 60,
      padding: const EdgeInsets.only(left: DsSpace.x3h5),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: isLast ? null : Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          AnimatedOpacity(
            duration: DsMotion.base,
            opacity: shown ? 1 : 0.45,
            child: FolderEmojiTile(emoji: folderFace(folder).emoji, icon: folderFace(folder).icon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.body.copyWith(
                    fontWeight: FontWeight.w500,
                    color: shown ? tokens.text : tokens.text3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  folder.builtIn ? '${context.l10n.folderBuiltIn} · $count' : count,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.footnote.copyWith(color: tokens.text3),
                ),
              ],
            ),
          ),
          SettingsToggle(
            key: ValueKey('folder-shown-${folder.id}'),
            on: shown,
            onChanged: onShown,
            semanticLabel: context.l10n.showFolderTab(title),
          ),
          ReorderableDragStartListener(
            index: index,
            child: SizedBox(
              key: ValueKey('folder-handle-${folder.id}'),
              width: 52,
              height: 60,
              child: ReorderHandle(color: tokens.text3),
            ),
          ),
        ],
      ),
    );
    if (onTap != null) row = DsPressable(scale: 0.985, onTap: onTap, child: row);
    if (onDelete == null) return row;
    const white = DsPalette.white;
    return DsSwipeActions(
      actions: [
        DsSwipeAction(
          label: context.l10n.delete,
          background: DsPalette.danger,
          foreground: white,
          icon: CustomPaint(painter: DsTrashGlyph(color: white)),
          onTap: onDelete,
        ),
      ],
      child: row,
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({super.key, required this.folder, required this.hint, required this.isLast, required this.onAdd});

  final ChatFolder folder;
  final String hint;
  final bool isLast;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          FolderEmojiTile(emoji: folder.emoji),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.footnote.copyWith(color: tokens.text3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          DsPressable(
            key: ValueKey('folder-add-${folder.id}'),
            haptic: Haptic.selection,
            onTap: onAdd,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.nudge7),
              decoration: BoxDecoration(color: tokens.accentSoft, borderRadius: BorderRadius.circular(tokens.radiusPill)),
              child: Text(
                context.l10n.addFolder,
                style: DsText.subhead.copyWith(fontWeight: FontWeight.w600, color: tokens.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
