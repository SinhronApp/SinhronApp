// Storage sub-screen. Reached from Settings → Storage row.
//
// Composition (top → bottom):
//   1. App-bar with back chevron + "Storage" title.
//   2. Hero card — total + animated stacked bar chart broken down by type,
//      colored legend below.
//   3. BY TYPE section — Photos / Videos / Voice / Documents / Other
//      (/ Database). Size + share of the total.
//   4. TOP CHATS section — heaviest conversations.
//   5. MANAGE section — how long unused copies are kept.
//   6. Bottom — destructive clear button.
//
// Tech-debt 2.32: this phone's local media copies (ADR-033) by type and
// by chat, and the message database; the button deletes the media copies
// (messages keep their keys — a file opens from the server again while
// the server still has it).

import 'package:flutter/widgets.dart';

import '../../core/app_notice.dart';
import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../widgets/ds_action_sheet.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_button.dart';
import '../../widgets/ds_picker_sheet.dart';
import '_shared.dart';
import '../../l10n/l10n.dart';

/// One chat's share of the media copies.
class StorageChat {
  const StorageChat({required this.name, required this.bytes, this.isGroup = false});
  final String name;
  final int bytes;
  final bool isGroup;
}

/// What this phone stores for Sinhron (tech-debt 2.32).
class StorageUsage {
  const StorageUsage({
    this.photos = 0,
    this.videos = 0,
    this.voice = 0,
    this.documents = 0,
    this.other = 0,
    this.database = 0,
    this.chats = const [],
  });
  final int photos;
  final int videos;
  final int voice;
  final int documents;

  /// Link-preview images, copies not linked to a message yet.
  final int other;

  /// The message database.
  final int database;

  /// Heaviest first.
  final List<StorageChat> chats;

  int get media => photos + videos + voice + documents + other;
}

/// "512 B", "14 KB", "2.4 MB", "1.2 GB" — number and unit apart for the
/// hero number.
(String, String) storageSizeParts(int n) {
  const k = 1024;
  if (n < k) return ('$n', 'B');
  if (n < k * k) return ('${(n / k).round()}', 'KB');
  if (n < k * k * k) {
    final mb = n / (k * k);
    return (mb < 10 ? mb.toStringAsFixed(1) : '${mb.round()}', 'MB');
  }
  final gb = n / (k * k * k);
  return (gb < 10 ? gb.toStringAsFixed(1) : '${gb.round()}', 'GB');
}

String storageSize(int n) {
  final (v, u) = storageSizeParts(n);
  return '$v $u';
}

// ═════════════════════════════════════════════════════════════════════
// Data
// ═════════════════════════════════════════════════════════════════════

class _Category {
  final String label;
  final int bytes;
  final Color color;
  final SettingsRowIcon icon;
  const _Category({required this.label, required this.bytes, required this.color, required this.icon});
}

List<_Category> _categories(BuildContext context, StorageUsage u) {
  final l = context.l10n;
  return [
    _Category(label: l.photos, bytes: u.photos, color: DsPalette.blue, icon: SettingsRowIcon.photos),
    _Category(label: l.storageVideos, bytes: u.videos, color: DsPalette.violet, icon: SettingsRowIcon.videos),
    _Category(label: l.storageVoice, bytes: u.voice, color: DsPalette.pink, icon: SettingsRowIcon.voice),
    _Category(label: l.sharedMediaDocuments, bytes: u.documents, color: DsPalette.green, icon: SettingsRowIcon.document),
    _Category(label: l.storageOther, bytes: u.other, color: DsPalette.coral, icon: SettingsRowIcon.cache),
    _Category(label: l.storageDatabase, bytes: u.database, color: DsPalette.amber, icon: SettingsRowIcon.storage),
  ];
}

// ═════════════════════════════════════════════════════════════════════
// Screen
// ═════════════════════════════════════════════════════════════════════

class StorageScreen extends StatefulWidget {
  final VoidCallback? onBack;

  /// This phone's numbers.
  final StorageUsage usage;

  /// Delete the local media copies; returns the bytes freed.
  final Future<int> Function()? onClearCopies;

  /// How long unused copies are kept (days, 0 = forever) and changing it
  /// (tech-debt 2.32).
  final int? keepDays;
  final ValueChanged<int>? onKeepDays;

  const StorageScreen({super.key, this.onBack, required this.usage, this.onClearCopies, this.keepDays, this.onKeepDays});

  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  bool _clearing = false;
  int? _freed;

  static String _keepLabel(AppL10n l, int days) => switch (days) {
    7 => l.storageKeepWeek,
    30 => l.storageKeepMonth,
    _ => l.storageKeepForever,
  };

  Future<void> _pickKeepDays(AppL10n l) async {
    const choices = [0, 30, 7];
    final labels = [for (final d in choices) _keepLabel(l, d)];
    final picked = await showDsPickerSheet(
      context: context,
      title: l.storageKeepCopies,
      subtitle: l.storageKeepFooter,
      options: labels,
      current: _keepLabel(l, widget.keepDays ?? 0),
    );
    final i = picked == null ? -1 : labels.indexOf(picked);
    if (i >= 0) widget.onKeepDays?.call(choices[i]);
  }

  Future<void> _clearCopies() async {
    final clear = widget.onClearCopies;
    if (clear == null || _clearing) return;
    final l = context.l10n;
    final ok = await showDsActionSheet<bool>(
      context,
      title: l.storageClearCopiesConfirm,
      actions: [DsSheetAction(l.storageClearCopies, true, destructive: true)],
    );
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final freed = await clear();
      if (mounted) setState(() => _freed = freed);
    } catch (_) {
      appNotice.value = l.groupActionFailed;
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final mq = MediaQuery.of(context);
    final l = context.l10n;
    final u = widget.usage;
    final categories = _categories(context, u);
    final total = categories.fold<int>(0, (s, c) => s + c.bytes);
    final chats = u.chats.take(10).toList();
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top, bottom: mq.padding.bottom),
        child: Column(
          children: [
            DsAppBar(title: l.storage, onBack: widget.onBack),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(top: DsSpace.x1h5, bottom: DsSpace.x6),
                children: [
                  _HeroCard(
                    categories: categories,
                    total: total,
                    subtitle: l.storageUsedHere,
                  ),
                  SettingsSection(
                    title: l.storageByType,
                    children: [
                      for (var i = 0; i < categories.length; i++)
                        _CategoryRow(c: categories[i], total: total, isLast: i == categories.length - 1),
                    ],
                  ),
                  if (chats.isNotEmpty)
                    SettingsSection(
                      title: l.storageTopChats,
                      footer: l.storageTopChatsRealFooter,
                      children: [
                        for (var i = 0; i < chats.length; i++)
                          _TopChatRow(c: chats[i], isLast: i == chats.length - 1),
                      ],
                    ),
                  if (widget.onKeepDays != null)
                    SettingsSection(
                      title: l.storageManage,
                      footer: l.storageKeepFooter,
                      children: [
                        SettingsRow(
                          key: const ValueKey('storage-keep-days'),
                          icon: SettingsRowIcon.clock,
                          tint: SettingsRowTint.recovery,
                          label: l.storageKeepCopies,
                          value: _keepLabel(l, widget.keepDays ?? 0),
                          isLast: true,
                          onTap: () => _pickKeepDays(l),
                        ),
                      ],
                    ),
                  // Destructive action — separate from the sections so it
                  // doesn't look like just another row.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1, DsSpace.x3h5, 0),
                    child: DsButton(
                      key: const ValueKey('storage-clear-copies'),
                      label: _freed != null ? l.storageCopiesCleared(storageSize(_freed!)) : l.storageClearCopies,
                      variant: _freed != null ? DsButtonVariant.secondary : DsButtonVariant.danger,
                      loading: _clearing,
                      onPressed: u.media == 0 || _freed != null ? null : _clearCopies,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(DsSpace.x7, DsSpace.x2h5, DsSpace.x7, 0),
                    child: Text(
                      l.storageClearCopiesFooter,
                      style: DsText.footnote.copyWith(fontWeight: FontWeight.w400, color: tokens.text3),
                    ),
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

// ═════════════════════════════════════════════════════════════════════
// Hero card — big number + stacked bar + legend
// ═════════════════════════════════════════════════════════════════════

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.categories, required this.total, required this.subtitle});
  final List<_Category> categories;
  final int total;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final (value, unit) = storageSizeParts(total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x1h5, DsSpace.x3h5, DsSpace.x5h5),
      child: Container(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5, DsSpace.x4h5),
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tokens.dividerStrong, width: 0.5),
          boxShadow: DsShadow.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(value, style: DsTextArt.t44w600.copyWith(color: tokens.text)),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: DsSpace.x1h5),
                  child: Text(
                    unit == 'MB' ? context.l10n.storageMbUnit : unit,
                    style: DsText.title3.copyWith(fontWeight: FontWeight.w500, height: 1.0, color: tokens.text3),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: DsText.subhead.copyWith(color: tokens.text3)),
            const SizedBox(height: 18),
            _StackedBar(categories: categories, total: total),
            const SizedBox(height: 14),
            _Legend(categories: categories),
          ],
        ),
      ),
    );
  }
}

class _StackedBar extends StatefulWidget {
  const _StackedBar({required this.categories, required this.total});
  final List<_Category> categories;
  final int total;

  @override
  State<_StackedBar> createState() => _StackedBarState();
}

class _StackedBarState extends State<_StackedBar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    // Flex weights in thousandths of the total (Expanded needs ints).
    int share(int bytes) => widget.total == 0 ? 0 : (bytes * 1000 / widget.total).round();
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 16,
            color: tokens.bgSoft,
            // CrossAxisAlignment.stretch is critical — Row's default
            // CrossAxisAlignment.center collapses Expanded children to 0px
            // when they have no intrinsic height.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final c in widget.categories)
                  if (share(c.bytes) > 0)
                    Expanded(
                      flex: share(c.bytes),
                      child: ColoredBox(color: c.color),
                    ),
                // Trailing spacer that shrinks as t → 1, "drawing" the bar
                // left-to-right rather than fading colors in.
                if (t < 1.0 && widget.total > 0)
                  Expanded(flex: (1000 * (1.0 - t)).round().clamp(1, 1000), child: const SizedBox.shrink()),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Legend extends StatelessWidget {
  final List<_Category> categories;
  const _Legend({required this.categories});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final c in categories)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: c.color, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Text(c.label, style: DsText.footnote.copyWith(color: tokens.text2)),
            ],
          ),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Category row — tinted icon (using the category's own color) + size
// ═════════════════════════════════════════════════════════════════════

class _CategoryRow extends StatelessWidget {
  final _Category c;
  final int total;
  final bool isLast;
  const _CategoryRow({required this.c, required this.total, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final percent = total == 0 ? 0 : ((c.bytes / total) * 100).round();

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.nudge11, DsSpace.x3h5, DsSpace.nudge11),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: c.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CustomPaint(
                      painter: SettingsRowIconPainter(shape: c.icon, color: c.color),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  c.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
                ),
              ),
              Text('$percent%', style: DsTextArt.t11p5w500Monov2.copyWith(color: tokens.text4)),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 64),
                child: Text(
                  storageSize(c.bytes),
                  textAlign: TextAlign.right,
                  style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text3),
                ),
              ),
            ],
          ),
        ),
        if (!isLast) Positioned(left: 56, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════
// Top-chats row — gradient initials avatar + name + size
// ═════════════════════════════════════════════════════════════════════

class _TopChatRow extends StatelessWidget {
  final StorageChat c;
  final bool isLast;
  const _TopChatRow({required this.c, required this.isLast});

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(DsSpace.x3h5, DsSpace.x2h5, DsSpace.x3h5, DsSpace.x2h5),
          child: Row(
            children: [
              _MiniAvatar(name: c.name, isGroup: c.isGroup),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  c.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: DsText.body.copyWith(fontWeight: FontWeight.w500, color: tokens.text),
                ),
              ),
              Text(storageSize(c.bytes), style: DsText.callout.copyWith(fontWeight: FontWeight.w500, color: tokens.text3)),
            ],
          ),
        ),
        if (!isLast) Positioned(left: 56, right: 0, bottom: 0, height: 0.5, child: ColoredBox(color: tokens.divider)),
      ],
    );
  }
}

class _MiniAvatar extends StatelessWidget {
  final String name;
  final bool isGroup;
  const _MiniAvatar({required this.name, required this.isGroup});

  @override
  Widget build(BuildContext context) {
    // Deterministic gradient pair from the name hash so the same chat keeps
    // the same color across reloads (and matches DsAvatar's behavior).
    final hash = name.codeUnits.fold<int>(0, (acc, c) => acc + c);
    final palettes = <List<Color>>[
      [DsPalette.blue, DsPalette.indigo],
      [DsPalette.violet, DsPalette.fuchsia],
      [DsPalette.pink, DsPalette.amber],
      [DsPalette.green, DsPalette.cyan],
      [DsPalette.coral, DsPalette.amber],
    ];
    final colors = palettes[hash % palettes.length];

    final initials = _initials(name);

    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        shape: BoxShape.circle,
      ),
      child: Center(child: Text(initials, style: DsTextArt.t11w600v3)),
    );
  }

  String _initials(String s) {
    // For groups like "Family · 8" — take the first letter before the dot.
    final cleaned = s.split('·').first.trim();
    final parts = cleaned.split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0].substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }
}
