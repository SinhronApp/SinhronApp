// In-app banners — UI backlog §8 item 57.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/haptics.dart';
import 'package:sinhron/core/providers/chat_actions.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/features/banners/in_app_banner.dart';

import '../core/push_test.dart' show FakePushPlatform;
import '../core/settings_providers_test.dart' show MemoryStore;

const maria = InAppBanner(chatId: 'c1', title: 'Maria', body: 'See you at 9');

/// Lets a test call [maybeShowBanner] with a real provider Ref.
final _raise = Provider<void Function(String chatId, {bool muted, bool archived})>(
  (ref) =>
      (chatId, {muted = false, archived = false}) => maybeShowBanner(
        ref,
        chatId: chatId,
        title: 'Maria',
        body: 'hi',
        kind: 'text',
        muted: muted,
        archived: archived,
      ),
);

void main() {
  setUp(() => DsHaptics.enabled = false);

  group('shouldShowBanner', () {
    bool show({bool enabled = true, bool fg = true, String? open, bool muted = false, bool archived = false}) =>
        shouldShowBanner(
          enabled: enabled,
          foreground: fg,
          openChatId: open,
          chatId: 'c1',
          muted: muted,
          archived: archived,
        );

    test('another chat, app in front → banner', () => expect(show(open: 'c2'), isTrue));
    test('the chat on screen → no banner', () => expect(show(open: 'c1'), isFalse));
    test('muted / archived / turned off / background → no banner', () {
      expect(show(muted: true), isFalse);
      expect(show(archived: true), isFalse);
      expect(show(enabled: false), isFalse);
      expect(show(fg: false), isFalse);
    });
  });

  test('maybeShowBanner respects the open chat and muted chats', () async {
    final c = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(MemoryStore())]);
    addTearDown(c.dispose);
    await c.read(inAppBannersEnabledProvider.future);
    c.read(openChatProvider.notifier).set('c1');
    c.read(_raise)('c1');
    expect(c.read(inAppBannerProvider), isNull);
    c.read(_raise)('c2', muted: true);
    expect(c.read(inAppBannerProvider), isNull);
    c.read(_raise)('c2');
    expect(c.read(inAppBannerProvider)?.chatId, 'c2');
  });

  test('no screen at all (Android "always connected" after a restart): a system notification, no banner', () async {
    final platform = FakePushPlatform();
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        stayConnectedInBackgroundProvider.overrideWithValue(() => true),
        pushPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(c.dispose);
    await c.read(inAppBannersEnabledProvider.future);
    expect(WidgetsBinding.instance.lifecycleState, isNull);
    c.read(_raise)('c2');
    expect(c.read(inAppBannerProvider), isNull);
    expect(platform.calls, ['show c2 Maria hi']);
    c.read(_raise)('c3', muted: true);
    expect(platform.calls, hasLength(1), reason: 'muted stays quiet');
  });

  test('the screen swiped away, the app still running (bug 2026-10-19): a system notification', () async {
    final platform = FakePushPlatform();
    final c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(MemoryStore()),
        stayConnectedInBackgroundProvider.overrideWithValue(() => true),
        pushPlatformProvider.overrideWithValue(platform),
      ],
    );
    addTearDown(c.dispose);
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    addTearDown(() => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
    await c.read(inAppBannersEnabledProvider.future);
    c.read(_raise)('c2');
    expect(c.read(inAppBannerProvider), isNull);
    expect(platform.calls, ['show c2 Maria hi']);
  });

  group('InAppBannerHost', () {
    late ProviderContainer c;
    late List<String> opened;

    Future<void> pump(WidgetTester t, {MemoryStore? store}) async {
      opened = [];
      c = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store ?? MemoryStore())]);
      addTearDown(c.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: MediaQuery(
              data: const MediaQueryData(size: Size(375, 812), padding: EdgeInsets.only(top: 47)),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: InAppBannerHost(onOpen: (b) => opened.add(b.chatId), child: const SizedBox.expand()),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('slides in with name and text; tap opens the chat', (t) async {
      await pump(t);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pumpAndSettle();
      expect(find.text('Maria'), findsOneWidget);
      expect(find.text('See you at 9'), findsOneWidget);
      expect(t.getTopLeft(find.byKey(const ValueKey('in-app-banner'))).dy, greaterThanOrEqualTo(47));

      await t.tap(find.text('See you at 9'));
      await t.pumpAndSettle();
      expect(opened, ['c1']);
      expect(find.byKey(const ValueKey('in-app-banner')), findsNothing);
    });

    testWidgets('swipe up hides it without opening', (t) async {
      await pump(t);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pumpAndSettle();
      await t.drag(find.text('Maria'), const Offset(0, -60));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('in-app-banner')), findsNothing);
      expect(opened, isEmpty);
    });

    testWidgets('a short pull down springs back and stays', (t) async {
      await pump(t);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pumpAndSettle();
      await t.drag(find.text('Maria'), const Offset(0, 40));
      await t.pumpAndSettle();
      expect(find.text('Maria'), findsOneWidget);
    });

    testWidgets('leaves on its own after a few seconds', (t) async {
      await pump(t);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Maria'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('in-app-banner')), findsNothing);
    });

    testWidgets('opening that chat elsewhere hides its banner', (t) async {
      await pump(t);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pumpAndSettle();
      c.read(openChatProvider.notifier).set('c1');
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('in-app-banner')), findsNothing);
    });

    testWidgets('the old "text off" → name only: "New message"; name and text → "Photo"', (t) async {
      final store = MemoryStore()..map['banner_preview'] = '0';
      await pump(t, store: store);
      expect(await c.read(notificationPreviewProvider.future), NotificationPreview.nameOnly);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pumpAndSettle();
      expect(find.text('New message'), findsOneWidget);
      expect(find.text('Maria'), findsOneWidget, reason: 'the name stays');
      expect(find.text('See you at 9'), findsNothing);

      await c.read(notificationPreviewProvider.notifier).save(NotificationPreview.nameAndText);
      c
          .read(inAppBannerProvider.notifier)
          .show(const InAppBanner(chatId: 'c3', title: 'Team', body: '', kind: 'photo'));
      await t.pumpAndSettle();
      expect(find.text('Photo'), findsOneWidget);
    });

    // Owner, 2026-10-16: choose "sender only, or sender and the message".
    testWidgets('nothing → no name, no text: "Sinhron" · "New message"', (t) async {
      final store = MemoryStore()..map['notification_preview'] = 'nothing';
      await pump(t, store: store);
      await c.read(notificationPreviewProvider.future);
      c.read(inAppBannerProvider.notifier).show(maria);
      await t.pumpAndSettle();
      expect(find.text('Sinhron'), findsOneWidget);
      expect(find.text('Maria'), findsNothing);
      expect(find.text('New message'), findsOneWidget);
    });
  });
}
