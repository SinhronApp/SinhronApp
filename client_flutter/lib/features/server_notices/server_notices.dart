// The "Server" chat — ADR-077. Only the server's administrators see it:
// a row at the top of Chats (last notice, unread count) and a read-only
// chat of the server's service notices — load alerts and reports. Long
// press on a notice copies it (keys and IPs in it).

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../core/admin_notices.dart';
import '../../core/app_notice.dart';
import '../../core/services/net_service.dart';
import '../../l10n/l10n.dart';
import '../../widgets/ds_app_bar.dart';
import '../../widgets/ds_count_badge.dart';
import '../../widgets/ds_page_route.dart';
import '../../widgets/ds_pressable.dart';
import '../settings/_shared.dart';

/// "14:05" today, "23.10 14:05" before.
String adminNoticeTime(DateTime at, DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(at.hour)}:${two(at.minute)}';
  final today = at.year == now.year && at.month == now.month && at.day == now.day;
  return today ? hm : '${two(at.day)}.${two(at.month)} $hm';
}

Color _kindColor(AdminNoticeKind kind, DsTokens tokens) => switch (kind) {
  AdminNoticeKind.alert => tokens.danger,
  AdminNoticeKind.report => DsPalette.orange,
  AdminNoticeKind.ok => tokens.success,
};

class _ServerAvatar extends StatelessWidget {
  const _ServerAvatar({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tokens.accentSoft, shape: BoxShape.circle),
      child: Center(
        child: SizedBox(
          width: size * 0.48,
          height: size * 0.48,
          child: CustomPaint(painter: SettingsRowIconPainter(shape: SettingsRowIcon.server, color: tokens.accent)),
        ),
      ),
    );
  }
}

/// The row at the top of Chats; nothing for anyone but an administrator.
/// While it is mounted it asks the server on every connect (app start, back
/// from the background) and once a minute while connected.
class ServerNoticesRow extends ConsumerStatefulWidget {
  const ServerNoticesRow({super.key, this.onOpen, this.hidden = false});

  final VoidCallback? onOpen;

  /// Status 223 (owner: "move the server's chat to Settings, at the bottom —
  /// it gets in the way every day"): the chat list keeps only the polling;
  /// the row itself is [ServerNoticesSettingsRow] in Settings.
  final bool hidden;

  @override
  ConsumerState<ServerNoticesRow> createState() => _ServerNoticesRowState();
}

class _ServerNoticesRowState extends ConsumerState<ServerNoticesRow> {
  Timer? _timer;
  ProviderSubscription<NetStatus>? _net;

  @override
  void initState() {
    super.initState();
    if (!ref.read(adminNoticesPollProvider)) return;
    _net = ref.listenManual(netStatusProvider, (_, s) {
      final notices = ref.read(adminNoticesProvider.notifier);
      if (s == NetStatus.connected && notices.asking) {
        unawaited(notices.refresh());
        _timer ??= Timer.periodic(kAdminNoticesEvery, (_) {
          if (notices.asking) {
            unawaited(notices.refresh());
          } else {
            _timer?.cancel();
          }
        });
      } else {
        _timer?.cancel();
        _timer = null;
      }
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _net?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onOpen = widget.onOpen;
    final s = ref.watch(adminNoticesProvider);
    if (!s.isAdmin || widget.hidden) return const SizedBox.shrink();
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final last = s.last;
    final unread = s.unread;
    return DsPressable(
      key: const ValueKey('server-notices-row'),
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(DsSpace.x4, DsSpace.x2, DsSpace.x4, DsSpace.x2),
        child: Row(
          children: [
            const _ServerAvatar(size: 52),
            const SizedBox(width: DsSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.serverChatTitle,
                          style: DsType.rowName.copyWith(color: tokens.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (last != null)
                        Text(
                          adminNoticeTime(last.at, DateTime.now()),
                          style: DsType.rowTime.copyWith(color: unread > 0 ? tokens.accent : tokens.text3),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          last?.headline ?? l.serverChatEmpty,
                          style: DsType.rowPreview.copyWith(color: tokens.text2),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (unread > 0) ...[
                        const SizedBox(width: DsSpace.x2),
                        Container(
                          key: const ValueKey('server-notices-unread'),
                          constraints: const BoxConstraints(minWidth: 20),
                          height: 20,
                          padding: const EdgeInsets.symmetric(horizontal: DsSpace.x1h5),
                          decoration: BoxDecoration(color: tokens.accent, borderRadius: BorderRadius.circular(10)),
                          alignment: Alignment.center,
                          child: DsAnimatedCount(count: unread, style: DsType.badge.copyWith(color: tokens.accentText)),
                        ),
                      ],
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

/// The read-only "Server" chat.
class ServerNoticesScreen extends ConsumerStatefulWidget {
  const ServerNoticesScreen({super.key, this.onBack});

  final VoidCallback? onBack;

  @override
  ConsumerState<ServerNoticesScreen> createState() => _ServerNoticesScreenState();
}

class _ServerNoticesScreenState extends ConsumerState<ServerNoticesScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await ref.read(adminNoticesProvider.notifier).refresh();
      if (mounted) await ref.read(adminNoticesProvider.notifier).markRead();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    final mq = MediaQuery.of(context);
    final s = ref.watch(adminNoticesProvider);
    // New ones while the chat is open are read too.
    ref.listen(adminNoticesProvider, (prev, next) {
      if (next.unread > 0) ref.read(adminNoticesProvider.notifier).markRead();
    });
    final now = DateTime.now();
    final items = s.notices.reversed.toList();
    return ColoredBox(
      color: tokens.bgSoft,
      child: Padding(
        padding: EdgeInsets.only(top: mq.padding.top),
        child: Column(
          children: [
            DsAppBar(title: l.serverChatTitle, onBack: widget.onBack),
            Text(l.serverChatSubtitle, style: DsText.footnote.copyWith(color: tokens.text3)),
            const SizedBox(height: DsSpace.x2),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(DsSpace.x6),
                        child: Text(
                          l.serverChatEmpty,
                          textAlign: TextAlign.center,
                          style: DsText.subhead.copyWith(color: tokens.text2),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('server-notices-list'),
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x2, DsSpace.x6, DsSpace.x2),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _NoticeBubble(notice: items[i], now: now),
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(DsSpace.x6, DsSpace.x2, DsSpace.x6, DsSpace.x3 + mq.padding.bottom),
              child: Text(
                l.serverChatFooter,
                textAlign: TextAlign.center,
                style: DsText.caption.copyWith(color: tokens.text3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeBubble extends StatelessWidget {
  const _NoticeBubble({required this.notice, required this.now});

  final AdminNotice notice;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    final l = context.l10n;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DsSpace.x0h5),
        child: DsPressable(
          key: ValueKey('server-notice-${notice.id}'),
          onLongPress: () async {
            await Clipboard.setData(ClipboardData(text: notice.text));
            showDone(l.copied);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ColoredBox(
                color: tokens.surface,
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 3, color: _kindColor(notice.kind, tokens)),
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(DsSpace.x3, DsSpace.x2, DsSpace.x3, DsSpace.x2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(notice.text, style: DsText.body.copyWith(color: tokens.text)),
                              const SizedBox(height: 4),
                              Text(
                                adminNoticeTime(notice.at, now),
                                style: DsText.caption.copyWith(color: tokens.text3),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Status 223 — the server's service notices in Settings (for its
/// administrators only): one row, the unread count as its value.
class ServerNoticesSettingsRow extends ConsumerWidget {
  const ServerNoticesSettingsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(adminNoticesProvider);
    if (!s.isAdmin) return const SizedBox.shrink();
    final l = context.l10n;
    return SettingsSection(
      children: [
        SettingsRow(
          key: const ValueKey('settings-server-notices'),
          glyph: CupertinoIcons.desktopcomputer,
          tint: SettingsRowTint.server,
          label: l.serverChatTitle,
          subtitle: s.last?.headline ?? l.serverChatEmpty,
          value: s.unread > 0 ? '${s.unread}' : null,
          onTap: () => Navigator.of(context).push(
            DsPageRoute<void>(builder: (ctx) => ServerNoticesScreen(onBack: () => Navigator.of(ctx).pop())),
          ),
          isLast: true,
        ),
      ],
    );
  }
}
