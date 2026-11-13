// Local search overlay. Reached from the ChatList header search icon.
//
// UI backlog §2 item 17 — real search: chat names from the chat list and
// decrypted message text from the local SQLCipher DB
// (`storage_messages_search`). Per spec §6.7 nothing here touches the
// network; the server never sees what you typed.
//
// Composition:
//   1. Search pill + Cancel.
//   2. No query — Recent: chats opened from here before, each with × and
//      "Clear" for all (owner, 2026-10-20); none yet — a short hint and
//      the "only on this device" note.
//   3. Query — Chats / Messages sections with the match highlighted.
// The three crossfade into each other; the screen itself fades in over
// the chat list instead of sliding in from the side.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../core/providers/chat_providers.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/providers/people.dart' show peerAvatarsProvider, withPhotos;
import '../../src/rust/api/simple.dart' as core;
import '../../widgets/ds_avatar.dart';
import '../../widgets/ds_empty_state.dart';
import '../../widgets/ds_motion.dart';
import '../../widgets/ds_pressable.dart';
import '../../widgets/ds_search_pill.dart';
import '../../widgets/ds_shared_glyphs.dart';
import '../chat_list/chat_data.dart';
import '../../l10n/l10n.dart';

/// Message-text search seam (the Rust FFI in the app, a fake in tests).
typedef MessageSearcher = Future<List<core.MessageSearchHit>> Function(String query);

final messageSearcherProvider = Provider<MessageSearcher>(
  (ref) =>
      (q) => core.storageMessagesSearch(query: q, limit: 50),
);

/// Chats opened from search, newest first — one chat id per line, in the
/// local encrypted settings table. Only ids: never what was typed.
final recentSearchProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('search_recent', ''));

const kRecentSearchMax = 12;

List<String> parseRecentSearch(String setting) => [
  for (final id in setting.split('\n'))
    if (id.isNotEmpty) id,
];

/// [setting] with [chatId] moved (or added) to the front, capped at [kRecentSearchMax].
String withRecentSearch(String setting, String chatId) =>
    [chatId, ...parseRecentSearch(setting).where((id) => id != chatId)].take(kRecentSearchMax).join('\n');

String withoutRecentSearch(String setting, String chatId) =>
    parseRecentSearch(setting).where((id) => id != chatId).join('\n');

/// Up to ~90 chars of [body] around the first match of [query], so the
/// highlight is visible even deep inside a long message.
String snippetAround(String body, String query) {
  final flat = body.replaceAll('\n', ' ');
  final i = flat.toLowerCase().indexOf(query.trim().toLowerCase());
  if (i <= 30) return flat;
  return '…${flat.substring(i - 24)}';
}

// ═════════════════════════════════════════════════════════════════════
// Screen
// ═════════════════════════════════════════════════════════════════════

class SearchOverlayScreen extends ConsumerStatefulWidget {
  final VoidCallback? onCancel;

  /// Open a chat (from a chat hit, or a message hit without [onOpenMessage]).
  final void Function(ChatPreview chat)? onOpenChat;

  /// Open a chat scrolled to a found message (wire id).
  final void Function(ChatPreview chat, String wireId)? onOpenMessage;

  /// For dev previews — start with the field pre-filled (skips having to
  /// drive the keyboard from a screenshot harness).
  final String initialQuery;

  const SearchOverlayScreen({super.key, this.onCancel, this.onOpenChat, this.onOpenMessage, this.initialQuery = ''});

  @override
  ConsumerState<SearchOverlayScreen> createState() => _SearchOverlayScreenState();
}

class _SearchOverlayScreenState extends ConsumerState<SearchOverlayScreen> {
  late String _query = widget.initialQuery;
  List<core.MessageSearchHit> _messages = const [];
  bool _searching = false;
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (_query.trim().isNotEmpty) _runSearch(_query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() => _query = v);
    _debounce?.cancel();
    if (v.trim().isEmpty) {
      _generation++;
      setState(() {
        _messages = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 180), () => _runSearch(v));
  }

  Future<void> _runSearch(String q) async {
    final gen = ++_generation;
    List<core.MessageSearchHit> hits;
    try {
      hits = await ref.read(messageSearcherProvider)(q.trim());
    } catch (_) {
      hits = const [];
    }
    // A newer keystroke already started another search — drop this one.
    if (!mounted || gen != _generation) return;
    setState(() {
      _messages = hits;
      _searching = false;
    });
  }

  void _remember(ChatPreview chat) {
    final id = chat.id;
    if (id == null) return;
    final n = ref.read(recentSearchProvider.notifier);
    n.save(withRecentSearch(ref.read(recentSearchProvider).value ?? '', id)).ignore();
  }

  void _forget(String? chatId) {
    final n = ref.read(recentSearchProvider.notifier);
    DsHaptics.play(Haptic.selection);
    n.save(chatId == null ? '' : withoutRecentSearch(ref.read(recentSearchProvider).value ?? '', chatId)).ignore();
  }

  void _openChat(ChatPreview chat) {
    _remember(chat);
    widget.onOpenChat?.call(chat);
  }

  void _openHit(core.MessageSearchHit hit, List<ChatPreview> chats) {
    final chat = chats.where((c) => c.id == hit.chatId).firstOrNull;
    if (chat == null) return;
    _remember(chat);
    final wire = hit.wireId;
    final open = widget.onOpenMessage;
    if (wire != null && open != null) {
      open(chat, wire);
    } else {
      widget.onOpenChat?.call(chat);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final pad = MediaQuery.paddingOf(context);
    final chats = withPhotos(
      ref.watch(chatsProvider).value ?? const <ChatPreview>[],
      ref.watch(peerAvatarsProvider).value ?? const {},
    );
    final q = _query.trim().toLowerCase();
    final chatHits = q.isEmpty ? const <ChatPreview>[] : chats.where((c) => c.name.toLowerCase().contains(q)).toList();

    final byId = {
      for (final c in chats)
        if (c.id != null) c.id!: c,
    };
    // Chats since deleted simply drop out.
    final recent = [
      for (final id in parseRecentSearch(ref.watch(recentSearchProvider).value ?? ''))
        if (byId[id] != null) byId[id]!,
    ];

    final Widget body;
    if (q.isEmpty) {
      body = recent.isEmpty
          ? const _EmptyHint(key: ValueKey('search-empty'))
          : _Recent(
              key: const ValueKey('search-recent'),
              chats: recent,
              onOpen: _openChat,
              onRemove: (c) => _forget(c.id),
              onClear: () => _forget(null),
            );
    } else if (chatHits.isEmpty && _messages.isEmpty) {
      body = _searching
          ? const SizedBox.shrink(key: ValueKey('search-wait'))
          : _NoResults(key: const ValueKey('search-none'), query: _query);
    } else {
      body = _Results(
        key: const ValueKey('search-results'),
        query: _query,
        chats: chatHits,
        photos: {
          for (final c in chats)
            if (c.id != null && c.avatar != null) c.id!: c.avatar!,
        },
        messages: _messages,
        onChat: _openChat,
        onMessage: (m) => _openHit(m, chats),
      );
    }

    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: pad.top, bottom: pad.bottom),
        child: Column(
          children: [
            _SearchAppBar(initialQuery: widget.initialQuery, onChanged: _onChanged, onCancel: widget.onCancel),
            Expanded(
              child: DsFadeSwitcher(alignment: Alignment.topCenter, expand: true, child: body),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// App bar: search field + Cancel
// ═════════════════════════════════════════════════════════════════════

class _SearchAppBar extends StatefulWidget {
  final String initialQuery;
  final ValueChanged<String> onChanged;
  final VoidCallback? onCancel;
  const _SearchAppBar({required this.initialQuery, required this.onChanged, this.onCancel});

  @override
  State<_SearchAppBar> createState() => _SearchAppBarState();
}

class _SearchAppBarState extends State<_SearchAppBar> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initialQuery);
  late String _last = _ctrl.text;

  @override
  void initState() {
    super.initState();
    // Selection moves fire too — pass on text changes only.
    _ctrl.addListener(() {
      if (_ctrl.text == _last) return;
      _last = _ctrl.text;
      widget.onChanged(_last);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, DsSpace.x1h5, DsSpace.x1h5, DsSpace.x1),
      child: Row(
        children: [
          Expanded(
            child: DsSearchPill(
              key: const ValueKey('search-field'),
              controller: _ctrl,
              hint: context.l10n.searchHint,
              autofocus: widget.initialQuery.isEmpty,
            ),
          ),
          DsPressable(
            key: const ValueKey('search-cancel'),
            onTap: () => widget.onCancel?.call(),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, DsSpace.x3, DsSpace.x2h5, DsSpace.x3),
              child: Text(
                context.l10n.cancel,
                style: DsText.body.copyWith(fontWeight: FontWeight.w500, height: 1.0, color: tokens.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// No query yet: the chats opened from search before — × on each, "Clear"
/// for all, like recent searches on iOS.
class _Recent extends StatelessWidget {
  const _Recent({super.key, required this.chats, required this.onOpen, required this.onRemove, required this.onClear});

  final List<ChatPreview> chats;
  final ValueChanged<ChatPreview> onOpen;
  final ValueChanged<ChatPreview> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return DsAppearScope(
      child: ListView(
        physics: const BouncingScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(0, DsSpace.x2, 0, DsSpace.x6),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x1, DsSpace.x1h5, DsSpace.x1),
            child: Row(
              children: [
                Expanded(
                  child: Text(l.searchRecent, style: DsText.headline.copyWith(color: tokens.text)),
                ),
                DsPressable(
                  key: const ValueKey('search-recent-clear'),
                  onTap: onClear,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x2),
                    child: Text(
                      l.searchRecentClear,
                      style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.accent),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...dsStaggered([
            for (var i = 0; i < chats.length; i++)
              _RecentRow(
                key: ValueKey('search-recent-${chats[i].id}'),
                chat: chats[i],
                isLast: i == chats.length - 1,
                onTap: () => onOpen(chats[i]),
                onRemove: () => onRemove(chats[i]),
              ),
          ]),
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  const _RecentRow({super.key, required this.chat, required this.isLast, required this.onTap, required this.onRemove});

  final ChatPreview chat;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        DsPressable(
          onTap: onTap,
          scale: 0.985,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2, DsSpace.x1, DsSpace.x2),
            child: Row(
              children: [
                DsAvatar(name: chat.name, size: 44, group: chat.group, image: chat.avatar, saved: chat.saved),
                const SizedBox(width: DsSpace.x3),
                Expanded(
                  child: Text(
                    chat.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                  ),
                ),
                Semantics(
                  button: true,
                  label: context.l10n.searchRecentRemove(chat.name),
                  excludeSemantics: true,
                  child: DsPressable(
                    key: ValueKey('search-recent-remove-${chat.id}'),
                    onTap: onRemove,
                    scale: 0.85,
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CustomPaint(painter: DsXmarkGlyph(color: tokens.text3)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!isLast) Positioned(left: 72, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x8, DsSpace.x10, DsSpace.x8, 0),
      child: Column(
        children: [
          Text(
            context.l10n.searchEmptyTitle,
            textAlign: TextAlign.center,
            style: DsText.bodyLarge.copyWith(fontWeight: FontWeight.w600, color: tokens.text2),
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.searchPrivacy,
            textAlign: TextAlign.center,
            style: DsText.footnote.copyWith(color: tokens.text3),
          ),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  final String query;
  final List<ChatPreview> chats;
  final List<core.MessageSearchHit> messages;
  final ValueChanged<ChatPreview> onChat;
  final ValueChanged<core.MessageSearchHit> onMessage;

  /// Chat id → photo, for message hits.
  final Map<String, Uint8List> photos;
  const _Results({
    super.key,
    required this.query,
    required this.chats,
    this.photos = const {},
    required this.messages,
    required this.onChat,
    required this.onMessage,
  });

  @override
  Widget build(BuildContext context) {
    final header = chats.isEmpty ? 0 : chats.length + 2;
    final total = header + (messages.isEmpty ? 0 : messages.length + 1);
    // Lazy: message hits can be many.
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(0, DsSpace.x1h5, 0, DsSpace.x6),
      itemCount: total,
      itemBuilder: (context, i) {
        if (i < header) {
          if (i == 0) return _ResultSectionHeader(label: context.l10n.chatsTitle);
          if (i == header - 1) return const SizedBox(height: 18);
          final c = chats[i - 1];
          return _ChatHitRow(chat: c, query: query, isLast: i == chats.length, onTap: () => onChat(c));
        }
        final j = i - header;
        if (j == 0) return _ResultSectionHeader(label: context.l10n.messagesSection);
        final m = messages[j - 1];
        return _MessageHitRow(
          key: ValueKey('hit-${m.messageId}'),
          hit: m,
          query: query,
          isLast: j == messages.length,
          photo: photos[m.chatId],
          onTap: () => onMessage(m),
        );
      },
    );
  }
}

class _ResultSectionHeader extends StatelessWidget {
  final String label;
  const _ResultSectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x2h5, DsSpace.x7, DsSpace.x2),
      child: Text(
        label.toUpperCase(),
        style: DsText.caption.copyWith(fontWeight: FontWeight.w600, color: tokens.text3),
      ),
    );
  }
}

class _ChatHitRow extends StatelessWidget {
  final ChatPreview chat;
  final String query;
  final bool isLast;
  final VoidCallback? onTap;
  const _ChatHitRow({required this.chat, required this.query, required this.isLast, this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2h5),
            child: Row(
              children: [
                DsAvatar(name: chat.name, size: 40, group: chat.group, image: chat.avatar, saved: chat.saved),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _HighlightedText(
                        text: chat.name,
                        query: query,
                        baseStyle: DsText.body.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                        accentColor: tokens.accent,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        chat.group ? context.l10n.groupWithTime(chat.time) : chat.time,
                        style: DsText.footnote.copyWith(color: tokens.text3),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!isLast) Positioned(left: 68, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

class _MessageHitRow extends StatelessWidget {
  final core.MessageSearchHit hit;
  final String query;
  final bool isLast;
  final VoidCallback? onTap;
  final Uint8List? photo;
  const _MessageHitRow({
    super.key,
    required this.hit,
    required this.query,
    required this.isLast,
    this.onTap,
    this.photo,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2h5, DsSpace.x4, DsSpace.x2h5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DsAvatar(name: hit.chatName, size: 40, image: photo),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              hit.chatName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: DsText.callout.copyWith(fontWeight: FontWeight.w600, color: tokens.text),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '· ${formatChatTime(hit.tsUnix.toInt())}',
                            style: DsText.footnote.copyWith(color: tokens.text3),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      _HighlightedText(
                        text: snippetAround(hit.body, query),
                        query: query,
                        maxLines: 2,
                        baseStyle: DsText.subhead.copyWith(color: tokens.text2),
                        accentColor: tokens.accent,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (!isLast) Positioned(left: 68, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// No-results empty state
// ═════════════════════════════════════════════════════════════════════

class _NoResults extends StatelessWidget {
  final String query;
  const _NoResults({super.key, required this.query});

  @override
  Widget build(BuildContext context) => DsEmptyState(
    illustration: DsIllustration.search,
    title: context.l10n.noResults(query),
    body: context.l10n.noResultsHint,
  );
}

// ═════════════════════════════════════════════════════════════════════
// Match-highlighted text — splits on substring, renders matched
// substring in accent color.
// ═════════════════════════════════════════════════════════════════════

class _HighlightedText extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle baseStyle;
  final Color accentColor;
  final int maxLines;
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.baseStyle,
    required this.accentColor,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    if (q.isEmpty) {
      return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: baseStyle);
    }
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final qLower = q.toLowerCase();
    var start = 0;
    while (start < text.length) {
      final idx = lower.indexOf(qLower, start);
      if (idx == -1) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: baseStyle.copyWith(color: accentColor, fontWeight: FontWeight.w700),
        ),
      );
      start = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: baseStyle, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Painters
// ═════════════════════════════════════════════════════════════════════
