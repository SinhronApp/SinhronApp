// ADR-061 — screen sharing in a call: the sharpness policy, the state
// machine (behind fake platform / room seams) and the UI pieces.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/features/calls/active_call_provider.dart';
import 'package:sinhron/features/calls/call_quality.dart';
import 'package:sinhron/features/calls/call_screen.dart';
import 'package:sinhron/features/calls/call_screen_share.dart';
import 'package:sinhron/l10n/gen/app_l10n.dart';

class _FakeCall extends ActiveCallNotifier {
  @override
  ActiveCallState build() => const ActiveCallState(phase: CallPhase.connected, callId: 'c1', groupIdHex: 'ab');
  void put(ActiveCallState s) => state = s;
}

class _FakePlatform implements ScreenSharePlatform {
  _FakePlatform({this.startsLater = false, this.allow = true});

  @override
  final bool startsLater;
  bool allow;
  int prepares = 0, releases = 0;
  ThermalLevel heat = 0;
  final stops = StreamController<void>.broadcast();

  @override
  Future<bool> prepare() async {
    prepares++;
    return allow;
  }

  @override
  Future<void> release() async => releases++;

  @override
  Stream<void> get stopRequests => stops.stream;

  @override
  Future<ThermalLevel> thermal() async => heat;
}

class _FakeRoom implements ScreenShareRoom {
  _FakeRoom({this.publishes = true});

  /// setEnabled(true) publishes at once (Android); false = the iPhone, the
  /// track comes later via [publishNow].
  final bool publishes;
  bool fail = false;
  @override
  bool sharing = false;
  final enabled = <bool>[];
  final layers = <({double scaleDownBy, int maxBitrate, int maxFramerate})>[];
  void Function()? _onChange;

  @override
  ({int width, int height})? captureSize = (width: 1080, height: 2400);

  @override
  CallDeviceClass deviceClass = CallDeviceClass.standard;

  @override
  Future<void> setEnabled(bool on) async {
    enabled.add(on);
    if (fail && on) return;
    if (!on || publishes) {
      sharing = on;
      _onChange?.call();
    }
  }

  void publishNow(bool on) {
    sharing = on;
    _onChange?.call();
  }

  @override
  Future<void> applyLayer(({double scaleDownBy, int maxBitrate, int maxFramerate}) layer) async => layers.add(layer);

  @override
  void Function() listen(void Function() onChange) {
    _onChange = onChange;
    return () => _onChange = null;
  }
}

({ProviderContainer c, _FakeCall call, ValueNotifier<ScreenShareRoom?> rooms}) _setUp(
  _FakePlatform platform,
  _FakeRoom? room,
) {
  final call = _FakeCall();
  final rooms = ValueNotifier<ScreenShareRoom?>(room);
  final c = ProviderContainer(
    overrides: [
      activeCallProvider.overrideWith(() => call),
      screenSharePlatformProvider.overrideWithValue(platform),
      screenShareRoomProvider.overrideWithValue(rooms),
    ],
  );
  c.listen(screenShareProvider, (_, _) {});
  return (c: c, call: call, rooms: rooms);
}

void main() {
  group('screenShareLayerFor', () {
    test('a good link: 1.5 Mbps, 15 fps, scaled to the class cap', () {
      final l = screenShareLayerFor(
        device: CallDeviceClass.standard,
        link: CallLinkQuality.good,
        width: 1080,
        height: 2400,
      );
      expect(l.maxBitrate, 1500 * 1000);
      expect(l.maxFramerate, 15);
      expect(l.scaleDownBy, closeTo(2400 / 1600, 1e-9));
    });

    test('excellent on a strong phone: 2.5 Mbps, long side 1920', () {
      final l = screenShareLayerFor(
        device: CallDeviceClass.high,
        link: CallLinkQuality.excellent,
        width: 1170,
        height: 2532,
      );
      expect(l.maxBitrate, 2500 * 1000);
      expect(l.scaleDownBy, closeTo(2532 / 1920, 1e-9));
    });

    test('a poor link gives up frames and bits, not sharpness', () {
      final good = screenShareLayerFor(device: CallDeviceClass.high, link: CallLinkQuality.good, width: 1080, height: 1920);
      final poor = screenShareLayerFor(device: CallDeviceClass.high, link: CallLinkQuality.poor, width: 1080, height: 1920);
      expect(poor.maxBitrate, 600 * 1000);
      expect(poor.maxFramerate, 8);
      expect(poor.scaleDownBy, good.scaleDownBy);
    });

    test('weak phone: 1 Mbps and 10 fps at most', () {
      final l = screenShareLayerFor(device: CallDeviceClass.low, link: CallLinkQuality.excellent, width: 720, height: 1600);
      expect(l.maxBitrate, 1000 * 1000);
      expect(l.maxFramerate, 10);
      expect(l.scaleDownBy, closeTo(1600 / 1280, 1e-9));
    });

    test('heat: serious caps 1.5 Mbps / 10 fps, critical 5 fps and 1280', () {
      final serious = screenShareLayerFor(
        device: CallDeviceClass.high,
        link: CallLinkQuality.excellent,
        thermal: 2,
        width: 1080,
        height: 1920,
      );
      expect(serious.maxBitrate, 1500 * 1000);
      expect(serious.maxFramerate, 10);
      final critical = screenShareLayerFor(
        device: CallDeviceClass.high,
        link: CallLinkQuality.excellent,
        thermal: 3,
        width: 1080,
        height: 1920,
      );
      expect(critical.maxFramerate, 5);
      expect(critical.scaleDownBy, closeTo(1920 / 1280, 1e-9));
    });

    test('unknown or small capture: not scaled', () {
      expect(screenShareLayerFor(device: CallDeviceClass.standard, link: CallLinkQuality.good).scaleDownBy, 1.0);
      expect(
        screenShareLayerFor(device: CallDeviceClass.standard, link: CallLinkQuality.good, width: 720, height: 1280).scaleDownBy,
        1.0,
      );
    });

    test('never AV1 / backup codec: the screen rides the camera publish options', () {
      expect(kScreenShareCaptureOptions.useiOSBroadcastExtension, isTrue);
      expect(kScreenShareEncoding.maxFramerate, 15);
      final opts = callVideoPublishOptions(callVideoPreset(CallDeviceClass.standard), 'h264')
          .copyWith(screenShareEncoding: kScreenShareEncoding);
      expect(opts.backupVideoCodec.enabled, isFalse);
      expect(opts.videoCodec, 'h264');
      expect(opts.screenShareEncoding, kScreenShareEncoding);
    });
  });

  group('ScreenShareNotifier', () {
    test('Android: consent + service, then the track; Stop unpublishes and stops the service', () async {
      final platform = _FakePlatform();
      final room = _FakeRoom();
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      expect(platform.prepares, 1);
      expect(room.enabled, [true]);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.on);
      await Future<void>.delayed(Duration.zero);
      expect(room.layers.last.maxBitrate, 1500 * 1000, reason: 'link not measured yet → good');
      await s.c.read(screenShareProvider.notifier).stop();
      expect(room.enabled, [true, false]);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
      expect(platform.releases, 1);
    });

    test('refused consent: quietly off, nothing published', () async {
      final platform = _FakePlatform(allow: false);
      final room = _FakeRoom();
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      expect(room.enabled, isEmpty);
      final st = s.c.read(screenShareProvider);
      expect(st.phase, ScreenSharePhase.off);
      expect(st.failed, isFalse);
    });

    test('Android: no track after enabling → failed, service stopped', () async {
      final platform = _FakePlatform();
      final room = _FakeRoom()..fail = true;
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      final st = s.c.read(screenShareProvider);
      expect(st.phase, ScreenSharePhase.off);
      expect(st.failed, isTrue);
      expect(platform.releases, 1);
    });

    test('iPhone: asking until "Start Broadcast", off when stopped from the status bar', () async {
      final platform = _FakePlatform(startsLater: true);
      final room = _FakeRoom(publishes: false);
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.asking);
      room.publishNow(true);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.on);
      room.publishNow(false);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
    });

    testWidgets('iPhone: a broadcast sheet nobody answered is forgotten', (t) async {
      final platform = _FakePlatform(startsLater: true);
      final s = _setUp(platform, _FakeRoom(publishes: false));
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.asking);
      await t.pump(kScreenShareAskTimeout + const Duration(seconds: 1));
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
    });

    test('hang-up stops my screen at once', () async {
      final platform = _FakePlatform();
      final room = _FakeRoom();
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      s.call.put(const ActiveCallState(phase: CallPhase.ended, callId: 'c1', groupIdHex: 'ab', endReason: 'hangup'));
      await Future<void>.delayed(Duration.zero);
      expect(room.enabled.last, isFalse);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
      expect(platform.releases, 1);
    });

    test('the room going away (call torn down) ends sharing and the service', () async {
      final platform = _FakePlatform();
      final s = _setUp(platform, _FakeRoom());
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      s.rooms.value = null;
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
      expect(platform.releases, 1);
    });

    test('the link changes → the top layer follows', () async {
      final platform = _FakePlatform();
      final room = _FakeRoom();
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      await Future<void>.delayed(Duration.zero);
      s.call.put(
        const ActiveCallState(phase: CallPhase.connected, callId: 'c1', groupIdHex: 'ab', linkQuality: CallLinkQuality.poor),
      );
      await Future<void>.delayed(Duration.zero);
      expect(room.layers.last.maxBitrate, 600 * 1000);
      expect(room.layers.last.maxFramerate, 8);
    });

    test('"Stop" on the Android notification stops it', () async {
      final platform = _FakePlatform();
      final room = _FakeRoom();
      final s = _setUp(platform, room);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      platform.stops.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
      expect(room.enabled.last, isFalse);
    });

    test('no call / no room: the button does nothing', () async {
      final platform = _FakePlatform();
      final s = _setUp(platform, null);
      addTearDown(s.c.dispose);
      await s.c.read(screenShareProvider.notifier).start();
      expect(platform.prepares, 0);
      expect(s.c.read(screenShareProvider).phase, ScreenSharePhase.off);
    });
  });

  group('UI', () {
    Widget host(Widget child, {List overrides = const []}) => ProviderScope(
      overrides: [...overrides],
      child: DsTheme(
        tokens: DsTokens.light,
        isDark: false,
        child: Localizations(
          locale: const Locale('ru'),
          delegates: AppL10n.localizationsDelegates,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(390, 844)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Overlay(key: ObjectKey(child), initialEntries: [OverlayEntry(builder: (_) => child)]),
            ),
          ),
        ),
      ),
    );

    // The call screen with its share button wired as LiveCallScreen does,
    // and the layer over it (its timer dot keeps moving: pump, not settle).
    Widget withCall(Widget layer) => Stack(
      children: [
        Positioned.fill(
          child: Consumer(
            builder: (context, ref, _) => CallScreen(
              contactName: 'Вера',
              initialState: CallState.active,
              onShareScreen: screenShareTap(ref, roomUp: true),
              sharingScreen: ref.watch(screenShareProvider).sharing,
            ),
          ),
        ),
        Positioned.fill(child: layer),
      ],
    );

    // Owner, 2026-10-19: the button floated on the right edge over the
    // name — now it's one of the call's buttons, in Russian.
    testWidgets('the button says "Показать экран", then "Остановить" while sharing', (t) async {
      var taps = 0;
      Widget screen(bool sharing) => host(
        CallScreen(contactName: 'Вера', initialState: CallState.active, onShareScreen: () => taps++, sharingScreen: sharing),
      );
      await t.pumpWidget(screen(false));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Показать экран'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('call-share-screen')));
      expect(taps, 1);
      await t.pumpWidget(screen(true));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Остановить'), findsOneWidget);
      // Video view: in the bar too.
      await t.pumpWidget(
        host(CallScreen(contactName: 'Вера', initialState: CallState.active, initialMedia: CallMedia.video, onShareScreen: () => taps++)),
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const ValueKey('call-share-screen')));
      expect(taps, 2);
    });

    testWidgets('banner: "Вы показываете экран · Остановить"', (t) async {
      var stops = 0;
      await t.pumpWidget(host(Center(child: ScreenShareBanner(onStop: () => stops++))));
      await t.pumpAndSettle();
      expect(find.text('Вы показываете экран'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('call-screen-stop')));
      expect(stops, 1);
    });

    testWidgets('viewer: name, rotate, back to the call, hang up', (t) async {
      var closed = 0, hung = 0;
      await t.pumpWidget(
        host(
          ScreenShareViewer(
            name: 'Вера',
            video: const SizedBox(key: ValueKey('fake-video'), width: 200, height: 400),
            onClose: () => closed++,
            onHangUp: () => hung++,
            lockOrientation: false,
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Вера показывает экран'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget, reason: 'pinch to zoom');
      expect(t.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 0);
      await t.tap(find.byKey(const ValueKey('call-screen-rotate')));
      await t.pump();
      expect(t.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns, 1);
      await t.tap(find.byKey(const ValueKey('call-screen-back')));
      await t.tap(find.byKey(const ValueKey('call-screen-hangup')));
      expect(closed, 1);
      expect(hung, 1);
    });

    testWidgets('in a live call: the button starts sharing, the banner shows, Stop ends it', (t) async {
      final platform = _FakePlatform();
      final room = _FakeRoom();
      final call = _FakeCall();
      await t.pumpWidget(
        host(
          withCall(CallScreenShareLayer.custom(changes: ValueNotifier(0), findRemote: () => null)),
          overrides: [
            activeCallProvider.overrideWith(() => call),
            screenSharePlatformProvider.overrideWithValue(platform),
            screenShareRoomProvider.overrideWithValue(ValueNotifier<ScreenShareRoom?>(room)),
          ],
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-banner')), findsNothing);
      await t.tap(find.byKey(const ValueKey('call-share-screen')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-banner')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('call-screen-stop')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-banner')), findsNothing);
      expect(room.enabled, [true, false]);
    });

    testWidgets('someone shares: their screen opens big; "К звонку" → a pill to reopen', (t) async {
      final sharer = ValueNotifier<String?>(null);
      await t.pumpWidget(
        host(
          withCall(
            CallScreenShareLayer.custom(
              changes: sharer,
              findRemote: () => sharer.value == null
                  ? null
                  : (identity: sharer.value!, video: const SizedBox(key: ValueKey('their-screen'))),
            ),
          ),
          overrides: [
            activeCallProvider.overrideWith(_FakeCall.new),
            screenSharePlatformProvider.overrideWithValue(_FakePlatform()),
            screenShareRoomProvider.overrideWithValue(ValueNotifier<ScreenShareRoom?>(_FakeRoom())),
          ],
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-viewer')), findsNothing);
      expect(find.byKey(const ValueKey('call-share-screen')), findsOneWidget);
      sharer.value = 'ab12';
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-viewer')), findsOneWidget);
      expect(find.byKey(const ValueKey('their-screen')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('call-screen-back')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-viewer')), findsNothing);
      expect(find.byKey(const ValueKey('call-screen-watch')), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('call-screen-watch')));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-viewer')), findsOneWidget);
      sharer.value = null;
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('call-screen-viewer')), findsNothing);
      expect(find.byKey(const ValueKey('call-screen-watch')), findsNothing);
    });

    testWidgets('a failed start says so for a moment', (t) async {
      final platform = _FakePlatform();
      final room = _FakeRoom()..fail = true;
      await t.pumpWidget(
        host(
          withCall(CallScreenShareLayer.custom(changes: ValueNotifier(0), findRemote: () => null)),
          overrides: [
            activeCallProvider.overrideWith(_FakeCall.new),
            screenSharePlatformProvider.overrideWithValue(platform),
            screenShareRoomProvider.overrideWithValue(ValueNotifier<ScreenShareRoom?>(room)),
          ],
        ),
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const ValueKey('call-share-screen')));
      await t.pump();
      await t.pump();
      expect(find.text('Не удалось показать экран'), findsOneWidget);
      await t.pump(const Duration(seconds: 4));
      expect(find.text('Не удалось показать экран'), findsNothing);
    });
  });
}
