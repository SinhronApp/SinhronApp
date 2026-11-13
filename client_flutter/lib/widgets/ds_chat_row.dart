import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';

import '../app/theme/motion.dart';
import '../app/theme/palette.dart';
import '../app/theme/tokens.dart';
import '../features/chat_list/chat_data.dart';
import '../l10n/l10n.dart';
import 'ds_avatar.dart';
import 'ds_count_badge.dart';
import 'ds_icon.dart';
import 'ds_motion.dart';
import 'ds_pressable.dart';
import 'ds_verified_badge.dart';

class DsChatRow extends StatelessWidget {
  final ChatPreview chat;
  final bool isLast;
  final VoidCallback? onTap;

  /// Open beside the list (iPad, ADR-076) — the row is tinted.
  final bool selected;

  const DsChatRow({super.key, required this.chat, this.isLast = false, this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    // ADR-055 — in the app's current language, whatever the row stored.
    final chat = this.chat.saved ? this.chat.copyWith(name: context.l10n.savedMessages) : this.chat;

    final timeColor = chat.unread > 0 ? tokens.accent : tokens.text3;
    final previewColor = chat.typing ? tokens.accent : tokens.text2;

    final nameRow = Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  chat.name,
                  style: DsType.rowName.copyWith(color: tokens.text),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
              if (chat.verified) ...[const SizedBox(width: 5), const DsVerifiedBadge(size: 14)],
              if (chat.muted) ...[
                const SizedBox(width: 5),
                DsIcon(shape: DsIconShape.muteBell, size: 13, color: tokens.text3),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        Text(chat.time, style: DsType.rowTime.copyWith(color: timeColor)),
      ],
    );

    final previewRow = Row(
      children: [
        Expanded(
          // A new last message or "typing…" crossfades in.
          child: DsFadeSwitcher(
            alignment: AlignmentDirectional.centerStart,
            rise: 4,
            child: KeyedSubtree(
              key: ValueKey('${chat.typing}|${chat.draft}|${chat.sender}|${chat.kind}|${chat.preview}'),
              child: _PreviewLine(
                chat: chat,
                previewColor: previewColor,
                senderColor: tokens.text,
                kindIconColor: chat.kind == ChatPreviewKind.call ? tokens.success : tokens.accent,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // The unread pill, ticks and pin swap with a little pop; a changed
        // count rolls inside the pill (DsAnimatedCount).
        DsFadeSwitcher(
          alignment: AlignmentDirectional.centerEnd,
          scaleFrom: 0.7,
          duration: DsMotion.base,
          child: KeyedSubtree(
            key: ValueKey(_TrailingIndicators.signature(chat)),
            child: _TrailingIndicators(chat: chat),
          ),
        ),
      ],
    );

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x2h5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          DsAvatar(
            name: chat.name,
            size: 52,
            group: chat.group,
            online: chat.online,
            image: chat.avatar,
            saved: chat.saved,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [nameRow, const SizedBox(height: 3), previewRow],
            ),
          ),
        ],
      ),
    );

    // No line between rows (the calm look): air separates them.
    const divider = SizedBox.shrink();

    // VoiceOver: one stop per chat with what matters (§7 item 55).
    final l = context.l10n;
    final a11y = [
      chat.name,
      if (chat.hasUnread && chat.unread > 0) l.a11yUnread(chat.unread),
      if (chat.pinned) l.a11yPinned,
      if (chat.muted) l.a11yMuted,
      if (chat.draft != null && chat.draft!.isNotEmpty) l.a11yDraft(chat.draft!) else chat.preview,
      chat.time,
    ].where((x) => x.isNotEmpty).join(', ');
    // iOS list feel: the row tints while pressed (backlog §4 item 36).
    return Semantics(
      button: true,
      label: a11y,
      excludeSemantics: true,
      // Excluding children drops their tap action — re-expose it so a
      // VoiceOver double-tap still opens the chat.
      onTap: onTap,
      child: DsPressable(
        scale: 1,
        pressedColor: tokens.bgSoft,
        onTap: onTap,
        child: ColoredBox(
          color: selected ? tokens.accentSoft : DsPalette.transparent,
          child: Column(mainAxisSize: MainAxisSize.min, children: [content, divider]),
        ),
      ),
    );
  }
}

class _PreviewLine extends StatelessWidget {
  final ChatPreview chat;
  final Color previewColor;
  final Color senderColor;
  final Color kindIconColor;

  const _PreviewLine({
    required this.chat,
    required this.previewColor,
    required this.senderColor,
    required this.kindIconColor,
  });

  @override
  Widget build(BuildContext context) {
    final spans = <InlineSpan>[];

    // An unsent draft replaces the preview (Telegram-style).
    final draft = chat.draft;
    if (draft != null && draft.isNotEmpty) {
      return Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: context.l10n.chatDraftPrefix,
              style: DsType.rowPreview.copyWith(color: DsTheme.of(context).danger),
            ),
            TextSpan(text: draft.replaceAll('\n', ' ')),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: DsType.rowPreview.copyWith(color: previewColor),
      );
    }

    // Tech-debt 2.27 — someone new started this chat and it isn't accepted.
    if (chat.request) {
      spans.add(
        TextSpan(
          text: '${context.l10n.requestTitle} · ',
          style: DsType.rowSender.copyWith(color: DsTheme.of(context).accent),
        ),
      );
    }

    if (chat.sender != null) {
      spans.add(
        TextSpan(
          text: '${chat.sender}: ',
          style: DsType.rowSender.copyWith(color: senderColor),
        ),
      );
    }

    final iconShape = switch (chat.kind) {
      ChatPreviewKind.voice => DsIconShape.voice,
      ChatPreviewKind.photo => DsIconShape.photo,
      ChatPreviewKind.call => DsIconShape.call,
      ChatPreviewKind.text => null,
    };
    if (iconShape != null) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: DsSpace.x1),
            child: DsIcon(shape: iconShape, size: 14, color: kindIconColor),
          ),
        ),
      );
    }

    spans.add(
      TextSpan(
        text: chat.preview,
        style: DsType.rowPreview.copyWith(
          color: previewColor,
          fontStyle: chat.typing ? FontStyle.italic : FontStyle.normal,
        ),
      ),
    );

    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DsType.rowPreview.copyWith(color: previewColor),
    );
  }
}

class _TrailingIndicators extends StatelessWidget {
  final ChatPreview chat;

  const _TrailingIndicators({required this.chat});

  /// What is shown, without the count — a new count isn't a new badge.
  static String signature(ChatPreview c) =>
      '${c.pinned && c.unread == 0}|${c.sent && c.unread == 0}|${c.read}|${c.delivered}|${c.failed}|'
      '${c.unread > 0}|${c.muted}|${c.markedUnread}|${c.mention}';

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final children = <Widget>[];

    if (chat.pinned && chat.unread == 0) {
      children.add(Icon(CupertinoIcons.pin, size: 14, color: tokens.text3));
    }

    if (chat.failed && chat.unread == 0) {
      // Status 211 — my newest message didn't go: seen without opening it.
      children.add(
        Container(
          key: const ValueKey('chat-row-failed'),
          width: 18,
          height: 18,
          decoration: const BoxDecoration(color: DsPalette.alert, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: const Text('!', style: DsTextArt.t13w700),
        ),
      );
    } else if (chat.sent && chat.unread == 0) {
      children.add(
        DsIcon(
          shape: chat.read || chat.delivered ? DsIconShape.doubleCheck : DsIconShape.check,
          size: 16,
          color: chat.read ? tokens.accent : tokens.text3,
        ),
      );
    }

    if (chat.unread > 0) {
      children.add(_UnreadPill(count: chat.unread, muted: chat.muted));
    } else if (chat.markedUnread) {
      // Marked unread by hand: a dot, no number.
      children.add(
        Container(
          key: const ValueKey('marked-unread-dot'),
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: chat.muted ? tokens.chipActive : tokens.accent, shape: BoxShape.circle),
        ),
      );
    }

    if (chat.mention) {
      children.add(
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: tokens.accent, borderRadius: BorderRadius.circular(11)),
          alignment: Alignment.center,
          child: Text('@', style: DsTextArt.t13w700.copyWith(color: tokens.accentText)),
        ),
      );
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(width: 6), children[i]],
      ],
    );
  }
}

class _UnreadPill extends StatelessWidget {
  final int count;
  final bool muted;

  const _UnreadPill({required this.count, required this.muted});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final bg = muted ? tokens.chipActive : tokens.accent;
    final fg = muted ? tokens.text2 : tokens.accentText;
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.nudge7),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(11)),
      alignment: Alignment.center,
      child: DsAnimatedCount(count: count, style: DsType.badge.copyWith(color: fg), max: 1 << 30),
    );
  }
}
