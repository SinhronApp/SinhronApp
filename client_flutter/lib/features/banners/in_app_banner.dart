// In-app banners — UI backlog §8 item 57.
//
// A message arrives for a chat you're NOT looking at → a card slides
// down from the top: avatar, chat name, the message (or just "New
// message" if previews are off). Tap opens the chat, swipe up hides
// it, otherwise it leaves on its own after a few seconds. Muted and
// archived chats stay quiet; nothing shows while the app is in the
// background or locked (the lock cover sits above it).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../chat_list/chat_data.dart' show contactCardLabel;
import '../../core/providers/chat_actions.dart';
import '../../core/notification_reply.dart' show canReplyFromNotification;
import '../../core/providers/chat_providers.dart' show chatsProvider, isMessageRequest;
import '../../core/providers/people.dart' show isBlockedChat, peerAvatarOf;
import '../../core/providers/settings_providers.dart';
import '../../core/background_connection.dart' show backgroundConnectionProvider;
import '../../core/push.dart' show pushPlatformProvider, stayConnectedInBackgroundProvider;
import '../../l10n/l10n.dart';
import '../../widgets/ds_avatar.dart';
import '../app_lock/app_lock.dart' show appLockEnabledProvider;

/// One banner: who wrote and what (raw body + kind; rendered with the
/// reader's language and the preview setting at show time).
class InAppBanner {
  const InAppBanner({
    required this.chatId,
    required this.title,
    required this.body,
    this.kind = 'text',
    this.group = false,
  });

  final String chatId;
  final String title;
  final String body;
  final String kind;
  final bool group;
}

/// Settings → Sounds & Vibration → "In-app banners".
final inAppBannersEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('in_app_banners', true));

/// What a notification shows (Settings → Sounds & vibrations; owner,
/// 2026-10-16: "sender only, or sender and the message"). For the in-app
/// banners, the Android "always connected" notifications and the name iOS
/// keeps in its call history (CallKit). An iPhone push while Sinhron is
/// closed always says just "New message" — the server can't read who or what.
enum NotificationPreview { nameAndText, nameOnly, nothing }

class NotificationPreviewSetting extends AsyncNotifier<NotificationPreview> {
  static const key = 'notification_preview';

  @override
  Future<NotificationPreview> build() async {
    try {
      final store = ref.read(settingsStoreProvider);
      final v = await store.get(key);
      if (v != null) {
        return NotificationPreview.values.firstWhere((e) => e.name == v, orElse: () => NotificationPreview.nameAndText);
      }
      // Before: an on/off "Show message text" — off kept the name.
      return await store.get('banner_preview') == '0' ? NotificationPreview.nameOnly : NotificationPreview.nameAndText;
    } catch (_) {
      return NotificationPreview.nameAndText;
    }
  }

  Future<void> save(NotificationPreview p) async {
    await ref.read(settingsStoreProvider).set(key, p.name);
    state = AsyncData(p);
  }
}

final notificationPreviewProvider = AsyncNotifierProvider<NotificationPreviewSetting, NotificationPreview>(
  NotificationPreviewSetting.new,
);

/// The title of a notification: the chat's name, or just "Sinhron".
String notificationTitle(NotificationPreview p, String name) => p == NotificationPreview.nothing ? 'Sinhron' : name;

/// The banner on screen (null = none). A newer message replaces the
/// current one rather than queueing — like iOS.
class InAppBanners extends Notifier<InAppBanner?> {
  @override
  InAppBanner? build() => null;

  void show(InAppBanner b) => state = b;

  void dismiss() => state = null;
}

final inAppBannerProvider = NotifierProvider<InAppBanners, InAppBanner?>(InAppBanners.new);

/// Whether a new incoming message should raise a banner.
bool shouldShowBanner({
  required bool enabled,
  required bool foreground,
  required String? openChatId,
  required String chatId,
  required bool muted,
  required bool archived,
}) => enabled && foreground && openChatId != chatId && !muted && !archived;

/// Called by NetService for each newly stored incoming message.
void maybeShowBanner(
  Ref ref, {
  required String chatId,
  required String title,
  required String body,
  required String kind,
  bool group = false,
  String? sender,
  bool muted = false,
  bool archived = false,
}) {
  final life = WidgetsBinding.instance.lifecycleState;
  // ADR-057 — or open only because a push woke the app.
  final stay = ref.read(stayConnectedInBackgroundProvider)() || ref.read(backgroundConnectionProvider).openForAPush;
  // No lifecycle yet is "on screen" (tests, the first frame) — except for an
  // engine Android started with no screen at all ("always connected", a push).
  final foreground = life == AppLifecycleState.resumed || (life == null && !stay);
  // ADR-040 fallback (Android, "always connected") and ADR-057 (woken by a
  // push): in background the app draws the system notification itself — it
  // has the message decrypted.
  if (!foreground && !muted && !archived && stay) {
    final preview = ref.read(notificationPreviewProvider).value ?? NotificationPreview.nameAndText;
    final l = lookupAppL10n(Locale(currentLanguage));
    // ADR-071 (amended) — a stranger's chat I haven't accepted: one quiet
    // "New message request", no name, no text (blocked people never get
    // this far — NetService drops them).
    if (isMessageRequest(ref, chatId)) {
      unawaited(
        ref
            .read(pushPlatformProvider)
            .showMessage(chatId: chatId, title: 'Sinhron', body: l.notificationNewRequest, quiet: true),
      );
      return;
    }
    final text = withSender(
      bannerText(l, InAppBanner(chatId: chatId, title: title, body: body, kind: kind, group: group), preview: preview),
      group ? sender : null,
      preview,
    );
    unawaited(
      ref
          .read(pushPlatformProvider)
          .showMessage(
            chatId: chatId,
            title: notificationTitle(preview, title),
            body: text,
            reply: notificationCanReply(ref, chatId, preview),
          ),
    );
    return;
  }
  if (!shouldShowBanner(
    enabled: ref.read(inAppBannersEnabledProvider).value ?? true,
    foreground: foreground,
    openChatId: ref.read(openChatProvider),
    chatId: chatId,
    muted: muted,
    archived: archived,
  )) {
    return;
  }
  ref
      .read(inAppBannerProvider.notifier)
      .show(InAppBanner(chatId: chatId, title: title, body: body, kind: kind, group: group));
}

/// ADR-066 — a call I missed while Sinhron was off screen: a notification
/// whose tap opens that chat (there was none — only the line in the chat).
/// Muted, archived and blocked chats stay quiet; "show nothing" keeps the
/// name out. The app has to be running: a call the phone rang for while
/// Sinhron was closed shows up in the chat when it next connects.
void maybeNotifyMissedCall(Ref ref, String chatId, {required bool video}) {
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
  final chat = (ref.read(chatsProvider).value ?? const []).where((c) => c.id == chatId).firstOrNull;
  if (chat == null || chat.muted || chat.archived || isBlockedChat(ref, chatId)) return;
  final preview = ref.read(notificationPreviewProvider).value ?? NotificationPreview.nameAndText;
  final l = lookupAppL10n(Locale(currentLanguage));
  unawaited(
    ref
        .read(pushPlatformProvider)
        .showMessage(
          chatId: chatId,
          title: notificationTitle(preview, chat.name),
          body: video ? l.chatMissedVideoCall : l.chatMissedCall,
        ),
  );
}

/// ADR-066 — does the notification of a message in [chatId] get "Reply"?
bool notificationCanReply(Ref ref, String chatId, NotificationPreview preview) => canReplyFromNotification(
  preview: preview,
  appLock: ref.read(appLockEnabledProvider).value ?? true,
  request: isMessageRequest(ref, chatId),
  blocked: isBlockedChat(ref, chatId),
);

/// ADR-066 — a group's notification says who wrote: "Anna: text" (like the
/// iPhone's extension, ADR-056); not with "show nothing".
String withSender(String text, String? sender, NotificationPreview preview) {
  final who = sender?.trim() ?? '';
  return who.isEmpty || preview == NotificationPreview.nothing ? text : '$who: $text';
}

/// What the banner says under the name.
String bannerText(AppL10n l, InAppBanner b, {required NotificationPreview preview}) {
  if (preview != NotificationPreview.nameAndText) return l.bannerNewMessage;
  // A shared contact reads as one, not as its key and server (status 223).
  if (contactCardLabel(l, b.body) case final label?) return label;
  if (b.body.isNotEmpty) return b.body;
  return switch (b.kind) {
    'photo' => l.kindPhoto,
    'sticker' => l.kindSticker,
    'voice' => l.kindVoice,
    'video' => l.video,
    'document' => l.document,
    _ => l.bannerNewMessage,
  };
}

/// Overlays [child] with the current banner. Mounted once at the app
/// root, above every route.
class InAppBannerHost extends ConsumerStatefulWidget {
  const InAppBannerHost({
    super.key,
    required this.child,
    required this.onOpen,
    this.visibleFor = const Duration(seconds: 4),
  });

  final Widget child;
  final void Function(InAppBanner banner) onOpen;
  final Duration visibleFor;

  @override
  ConsumerState<InAppBannerHost> createState() => _InAppBannerHostState();
}

class _InAppBannerHostState extends ConsumerState<InAppBannerHost> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);
  InAppBanner? _shown;
  Timer? _auto;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    _c.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && mounted) setState(() => _shown = null);
    });
    ref.listenManual(inAppBannerProvider, (_, next) => next == null ? _hide() : _show(next));
    // Opening that chat some other way makes its banner pointless.
    ref.listenManual(openChatProvider, (_, id) {
      if (id != null && _shown?.chatId == id) ref.read(inAppBannerProvider.notifier).dismiss();
    });
  }

  @override
  void dispose() {
    _auto?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _show(InAppBanner b) {
    final fresh = _shown == null;
    setState(() {
      _shown = b;
      _drag = 0;
    });
    _c.duration = DsMotion.of(context, DsMotion.slow);
    _c.reverseDuration = DsMotion.of(context, DsMotion.base);
    if (fresh) DsHaptics.play(Haptic.selection);
    _c.animateTo(1, curve: DsMotion.springy);
    _restartTimer();
  }

  void _hide() {
    _auto?.cancel();
    if (_shown != null) _c.animateBack(0, curve: DsMotion.exit);
  }

  void _restartTimer() {
    _auto?.cancel();
    _auto = Timer(widget.visibleFor, () => ref.read(inAppBannerProvider.notifier).dismiss());
  }

  void _open() {
    final b = _shown;
    if (b == null) return;
    ref.read(inAppBannerProvider.notifier).dismiss();
    widget.onOpen(b);
  }

  @override
  Widget build(BuildContext context) {
    final b = _shown;
    return Stack(
      children: [
        widget.child,
        if (b != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, child) {
                final top = MediaQuery.paddingOf(context).top;
                // Slides from above the status bar; follows the finger up,
                // resists a little when pulled down.
                final y = (_c.value - 1) * (top + 120) + _drag;
                return Transform.translate(
                  offset: Offset(0, y),
                  child: Opacity(opacity: _c.value.clamp(0.0, 1.0), child: child),
                );
              },
              child: Padding(
                padding: EdgeInsets.fromLTRB(DsSpace.x2, MediaQuery.paddingOf(context).top + DsSpace.x1, DsSpace.x2, 0),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _open,
                  onVerticalDragStart: (_) => _auto?.cancel(),
                  onVerticalDragUpdate: (d) => setState(() {
                    _drag = d.delta.dy < 0 || _drag < 0
                        ? math.min(0, _drag + d.delta.dy)
                        : math.min(12, _drag + d.delta.dy * 0.2);
                  }),
                  onVerticalDragEnd: (d) {
                    if (_drag < -28 || d.primaryVelocity! < -300) {
                      ref.read(inAppBannerProvider.notifier).dismiss();
                    } else {
                      setState(() => _drag = 0);
                      _restartTimer();
                    }
                  },
                  child: _BannerCard(banner: b, onOpen: _open),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BannerCard extends ConsumerWidget {
  const _BannerCard({required this.banner, required this.onOpen});
  final InAppBanner banner;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DsTheme.of(context);
    final preview = ref.watch(notificationPreviewProvider).value ?? NotificationPreview.nameAndText;
    final text = bannerText(context.l10n, banner, preview: preview);
    final title = notificationTitle(preview, banner.title);
    // Their photo only when the banner may say who it is.
    final photo = banner.group || title != banner.title
        ? null
        : peerAvatarOf(
            ref,
            ref.watch(chatsProvider.select((a) => a.value?.where((c) => c.id == banner.chatId).firstOrNull?.peerId)),
          );
    return Semantics(
      key: const ValueKey('in-app-banner'),
      container: true,
      liveRegion: true,
      button: true,
      label: '$title: $text',
      hint: context.l10n.bannerHint,
      excludeSemantics: true,
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.all(DsSpace.x3),
        decoration: BoxDecoration(
          color: tokens.elevated,
          borderRadius: BorderRadius.circular(tokens.radiusCard),
          border: Border.all(color: tokens.divider, width: 0.5),
          boxShadow: DsShadow.menu,
        ),
        child: Row(
          children: [
            DsAvatar(name: title, size: 38, group: banner.group, image: photo),
            const SizedBox(width: DsSpace.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.callout.copyWith(color: tokens.text, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    text,
                    key: const ValueKey('in-app-banner-text'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: DsText.subhead.copyWith(color: tokens.text2, fontWeight: FontWeight.w400),
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
