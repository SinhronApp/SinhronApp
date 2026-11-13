import 'dart:async' show unawaited;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute, CupertinoTheme, CupertinoThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/backup/backup_service.dart';
import '../core/services/screenshot_watch.dart';
import '../core/haptics.dart';
import '../widgets/app_notice_host.dart';
import '../core/providers/message_actions.dart';
import '../core/providers/presence.dart';
import '../features/app_lock/app_lock.dart';
import '../core/app_badge.dart';
import '../core/background_connection.dart';
import '../core/incoming_share.dart';
import '../core/invite_link.dart';
import '../core/push.dart';
import '../features/banners/in_app_banner.dart';
import '../features/calls/active_call_provider.dart';
import '../features/calls/live_call_bar.dart';
import '../features/calls/live_call_screen.dart';
import '../l10n/l10n.dart';
import 'navigation.dart';
import 'theme/appearance.dart';
import 'theme/palette.dart';
import 'theme/tokens.dart';
import '../widgets/avoid_keyboard.dart';

class SinhronApp extends StatelessWidget {
  const SinhronApp({super.key});

  /// CD5 — global navigator key. Used by [_IncomingCallSentinel] to
  /// push the LiveCallScreen route from outside any Build context
  /// (the listener fires off the build cycle).
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final forcedTheme = Uri.base.queryParameters['theme'];

    return Consumer(
      builder: (context, ref, _) => WidgetsApp(
        title: 'Sinhron',
        // Backlog §7 item 53 — Russian + English; Settings → Language.
        locale: chosenLocale(ref.watch(languageProvider).value),
        localeListResolutionCallback: (device, _) {
          final l = chosenLocale(ref.read(languageProvider).value) ?? resolveLocale(device);
          currentLanguage = l.languageCode;
          return l;
        },
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          AppL10n.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        color: DsPalette.white,
        debugShowCheckedModeBanner: false,
        navigatorKey: navigatorKey,
        pageRouteBuilder: <T>(settings, builder) => CupertinoPageRoute<T>(settings: settings, builder: builder),
        // home: triggers WidgetsApp to create a Navigator above this widget,
        // which is what Navigator.of(context).push(...) relies on.
        home: const AppRoot(),
        builder: (context, child) => Consumer(
          builder: (context, ref, _) {
            // Settings → Appearance (backlog §5 item 42); `?theme=` still
            // forces one for previews / goldens.
            final choice = switch (forcedTheme) {
              'dark' => ThemeChoice.dark,
              'light' => ThemeChoice.light,
              'oled' => ThemeChoice.oled,
              _ => parseTheme(ref.watch(themeChoiceProvider).value),
            };
            final (tokens, isDark) = resolveTheme(
              choice,
              MediaQuery.platformBrightnessOf(context),
              ref.watch(accentProvider).value ?? 'blue',
            );

            return DsTheme(
              tokens: tokens,
              isDark: isDark,
              // CupertinoTheme is required for CupertinoTextField selection
              // handles + toolbar to render visibly. Without it, our root is a
              // bare WidgetsApp → no Cupertino primary color, no toolbar theme
              // → handles + paste menu are invisible (gestures still work, just
              // not painted). Discovered 2026-05-23 on physical iPhone — user
              // could long-press-delete a word but never saw the selection or
              // paste menu. CupertinoColors.activeBlue matches Apple's default.
              child: CupertinoTheme(
                data: CupertinoThemeData(
                  brightness: isDark ? Brightness.dark : Brightness.light,
                  primaryColor: tokens.accent,
                  // Use default Cupertino selection-handle color (activeBlue
                  // family) by NOT overriding selectionTheme — Flutter resolves
                  // it from primaryColor for us.
                ),
                child: DefaultTextStyle(
                  style: DsText.callout.copyWith(color: tokens.text),
                  // CD5 — wrap the entire app subtree with the incoming-call
                  // sentinel. It does NOT add visual surface — just listens
                  // to activeCallProvider transitions and pushes LiveCallScreen
                  // when an incoming call arrives from the server.
                  //
                  // Plus _GlobalDiagnosticBanner overlay — surfaces async error
                  // messages that wouldn't otherwise render (Start chat failure
                  // with theme/overlay/context issues). Mounted at root so it
                  // appears above any push'd routes.
                  child: _IncomingCallSentinel(
                    // Backlog §6 items 47-48: App Lock + app-switcher cover.
                    child: AppLockGate(
                      child: ExpiryJanitor(
                        // ADR-073 — the daily chat backup (BackupKeeper).
                        child: BackupKeeper(
                        // Backlog §8 items 57-58: banners for other chats,
                        // unread count on the app icon.
                        child: PresenceKeeper(child: BackgroundConnectionKeeper(child: InviteLinkListener(
                          // ADR-043 — https://<server>/join#… opened the app.
                          onLink: (link) => handleInviteLink(link),
                          // ADR-060 — another app's share menu → "Send to…".
                          child: IncomingShareListener(
                          onShare: (share) => handleIncomingShare(share),
                          child: PushSync(
                          // ADR-066 — on every start path, also a cold one.
                          onOpenChat: (chatId) => unawaited(openChatFromNotification(chatId)),
                          child: AppBadgeSync(
                          child: InAppBannerHost(
                            onOpen: (b) {
                              final nav = navigatorKey.currentState;
                              if (nav == null) return;
                              pushChatFromAnywhere(nav, chatId: b.chatId, name: b.title);
                            },
                            child: Stack(
                              children: [
                                // CD8 — the call bar over every screen while a
                                // call goes on with its screen closed.
                                AvoidKeyboard(child: CallBarHost(navigatorKey: navigatorKey, child: child!)),
                                const Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: SafeArea(child: AppNoticeHost()),
                                ),
                              ],
                            ),
                          ),
                        ))))))),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// CD5 — global listener that opens [LiveCallScreen] by itself: for an
/// incoming call the app rings itself, and for a call answered in the
/// system UI ([callScreenToOpen]). An incoming call the system already
/// shows (CallKit on iPhone, the call notification on Android with the app
/// in the background) gets no second, in-app ringing screen (owner,
/// 2026-10-18) — the call bar offers it instead. Mounted once at the
/// WidgetsApp root via the `builder:` slot so the listener survives any
/// in-app navigation.
///
/// Why not put this into [activeCallProvider] itself? Because the
/// provider has no concept of "navigation" — that lives in the
/// widget tree. Splitting them keeps the provider testable and
/// the navigation pure-UI.
class _IncomingCallSentinel extends ConsumerWidget {
  final Widget child;
  const _IncomingCallSentinel({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Design-system widgets read the Vibration switch statically.
    DsHaptics.enabled = ref.watch(hapticsEnabledProvider).value ?? true;
    ref.read(screenshotWatchProvider); // ADR-030 — screenshot alerts
    ref.listen<ActiveCallState>(activeCallProvider, (prev, next) {
      if (!callScreenToOpen(prev, next, screenOpen: LiveCallScreen.open.value > 0)) return;
      final nav = SinhronApp.navigatorKey.currentState;
      if (nav == null) return;
      nav.push(callScreenRoute((_) => LiveCallScreen(contactName: callContactName(ref, next))));
    });
    return child;
  }
}
