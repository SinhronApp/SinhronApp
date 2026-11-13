// Shared media gallery — opens from ContactInfo / GroupInfo "Shared media"
// row. Per spec §6.9, every media envelope is stored locally after
// decryption, indexed by (chat, mime, sender, time). This screen is the
// browse-view across that index for a specific conversation.
//
// Four tabs as in Telegram (owner, 2026-11-03): Media (photos and
// videos, a 3-column grid), Files, Voice (voice and round video
// messages), Links — each under month headings (real_shared_media.dart).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/chat_providers.dart' show messagesProvider;

import '../../app/theme/tokens.dart';
import '../../widgets/ds_icon.dart';
import 'real_shared_media.dart';
import '../../l10n/l10n.dart';

class SharedMediaScreen extends StatefulWidget {
  final String contactName;
  final VoidCallback? onBack;

  /// ADR-017 — this chat's encrypted media from the local DB.
  final String chatId;

  /// Gallery "Show in chat" — the wire id of the message to open the chat at.
  final ValueChanged<String>? onShowInChat;

  const SharedMediaScreen({
    super.key,
    this.contactName = '',
    this.onBack,
    required this.chatId,
    this.onShowInChat,
  });

  @override
  State<SharedMediaScreen> createState() => _SharedMediaScreenState();
}

class _SharedMediaScreenState extends State<SharedMediaScreen> {
  SharedSection _tab = SharedSection.media;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    return ColoredBox(
      color: tokens.bg,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            _Header(title: context.l10n.sharedMediaTitle, subtitle: widget.contactName, onBack: widget.onBack),
            Consumer(
              builder: (context, ref, _) {
                final rows = ref.watch(messagesProvider(widget.chatId)).value ?? const [];
                final n = sharedCounts(rows);
                return _TabBar(
                  tab: _tab,
                  onSelect: (t) => setState(() => _tab = t),
                  counts: n,
                );
              },
            ),
            Expanded(
              child: RealSharedMedia(
                chatId: widget.chatId,
                section: _tab,
                contactName: widget.contactName,
                onShowInChat: widget.onShowInChat,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Header — 2-line center (title + contact-name subtitle) + back chevron.
// Same 44+ minHeight as DsAppBar but two stacked lines, since DsAppBar
// is title-only.
// ═════════════════════════════════════════════════════════════════════

class _Header extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onBack;
  const _Header({required this.title, required this.subtitle, this.onBack});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2h5, vertical: DsSpace.x1h5),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: DsSpace.x14),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.headline.copyWith(height: 1.0, color: tokens.text),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DsText.footnote.copyWith(height: 1.0, color: tokens.text3),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              if (onBack != null)
                Semantics(button: true, label: context.l10n.a11yBack, excludeSemantics: true, onTap: onBack, child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onBack,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CustomPaint(painter: DsGlyphPainter(DsGlyph.back, color: tokens.text)),
                      ),
                    ),
                  ),
                )),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Segmented tab bar
// ═════════════════════════════════════════════════════════════════════

class _TabBar extends StatelessWidget {
  final SharedSection tab;
  final ValueChanged<SharedSection> onSelect;

  final Map<SharedSection, int> counts;
  const _TabBar({required this.tab, required this.onSelect, required this.counts});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.divider, width: 0.5)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x2, vertical: DsSpace.x2),
        child: Row(
          children: [
            for (final t in SharedSection.values)
              _Chip(
                key: ValueKey('shared-tab-${t.name}'),
                label: _labelFor(context, t),
                count: counts[t] ?? 0,
                selected: t == tab,
                onTap: () => onSelect(t),
              ),
          ],
        ),
      ),
    );
  }

  String _labelFor(BuildContext context, SharedSection t) => switch (t) {
    SharedSection.media => context.l10n.sharedMediaMedia,
    SharedSection.files => context.l10n.sharedMediaFiles,
    SharedSection.voice => context.l10n.sharedMediaVoice,
    SharedSection.links => context.l10n.links,
  };
}

class _Chip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({super.key, required this.label, required this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: DsSpace.x1h5),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.nudge7, DsSpace.x3, DsSpace.nudge7),
          decoration: BoxDecoration(
            color: selected ? tokens.text : tokens.bgSoft,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: DsText.subhead.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.0,
                  color: selected ? tokens.bg : tokens.text,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                count.toString(),
                style: DsTextArt.t11p5w500Monov3.copyWith(
                  color: selected ? tokens.bg.withValues(alpha: 0.65) : tokens.text3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
