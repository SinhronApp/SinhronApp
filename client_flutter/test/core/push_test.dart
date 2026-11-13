// Overnight item 8 — push: ask iOS, send the token once, remove it when off.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/app/theme/tokens.dart';
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/features/settings/notifications_screen.dart';
import 'package:sinhron/core/notification_reply.dart';
import 'package:sinhron/core/push.dart';
import 'package:sinhron/core/services/net_service.dart';

import 'settings_providers_test.dart' show MemoryStore;

class FakePushPlatform implements PushPlatform {
  final tokensCtl = StreamController<(String, bool)>.broadcast();
  int registered = 0;
  String state = 'notDetermined';

  @override
  Future<bool> register() async {
    registered++;
    return true;
  }

  @override
  Future<String> status() async => state;

  @override
  Stream<(String, bool)> get tokens => tokensCtl.stream;

  final voipCtl = StreamController<(String, bool)>.broadcast();
  (String, bool)? lastVoip;

  @override
  Stream<(String, bool)> get voipTokens => voipCtl.stream;

  @override
  Future<(String, bool)?> lastVoipToken() async => lastVoip;

  final calls = <String>[];
  final openedCtl = StreamController<String>.broadcast();
  final removedCtl = StreamController<void>.broadcast();

  @override
  Future<void> keepAlive(bool on) async => calls.add('keepAlive $on');

  /// ADR-066 — the `reply` flag of each [showMessage], in order.
  final replyFlags = <bool>[];

  /// ADR-071 (amended) — the `quiet` flag of each [showMessage], in order.
  final quietFlags = <bool>[];

  @override
  Future<void> clearChat(String chatId) async => calls.add('clear $chatId');

  @override
  Future<void> showMessage({
    required String chatId,
    required String title,
    required String body,
    bool reply = false,
    bool quiet = false,
  }) async {
    calls.add('show $chatId $title $body');
    replyFlags.add(reply);
    quietFlags.add(quiet);
  }

  @override
  Stream<String> get opened => openedCtl.stream;

  String? openedAtStart;

  @override
  Future<String?> takeOpened() async {
    final v = openedAtStart;
    openedAtStart = null;
    return v;
  }

  final repliesCtl = StreamController<NotificationReply>.broadcast();
  final pendingReplies = <NotificationReply>[];
  final replyOutcomes = <String>[];

  @override
  Stream<NotificationReply> get replies => repliesCtl.stream;

  @override
  Future<List<NotificationReply>> takeReplies() async {
    final list = [...pendingReplies];
    pendingReplies.clear();
    return list;
  }

  @override
  Future<void> replyDone(String id, ReplyOutcome outcome) async => replyOutcomes.add('$id ${outcome.name}');

  @override
  Stream<void> get tokenRemoved => removedCtl.stream;

  final keys = <String, (String, String)>{};

  @override
  (String, String)? webPushKeys(String token) => keys[token];

  String? context;
  List<String>? previewKeys;
  String? hintKey;
  bool cleared = false;

  @override
  Future<void> setNotificationContext(String json) async => context = json;

  @override
  Future<void> setPreviewKeys(List<String> keys) async => previewKeys = keys;

  @override
  Future<String?> callHintKey() async => hintKey;

  @override
  Future<void> clearNotificationData() async => cleared = true;

  bool ntfy = false;

  @override
  Future<bool> ntfyInstalled() async => ntfy;

  @override
  Future<void> openNtfy() async => calls.add('openNtfy');

  @override
  Future<bool> reconnect() async {
    calls.add('reconnect');
    return true;
  }

  final pushKeys = <String, String>{};

  @override
  String? pushKey(String token) => pushKeys[token];

  String? fcmToken;
  final fcmIds = <Map<String, String>?>[];

  @override
  Future<String?> fcmConfigure(Map<String, String>? ids) async {
    fcmIds.add(ids);
    return ids == null ? null : fcmToken;
  }

  final wakesCtl = StreamController<void>.broadcast();
  bool wokeAtStart = false;

  @override
  Stream<void> get wakes => wakesCtl.stream;

  @override
  Future<bool> takeWake() async => wokeAtStart;

  @override
  Future<void> wakeDone({bool handled = false}) async => calls.add(handled ? 'wakeDone handled' : 'wakeDone');
}

class _Net extends NetService {
  _Net(super.ref);
  String? base = 'https://srv';
  @override
  String? get httpBaseUrl => base;
}

void main() {
  late FakePushPlatform platform;
  late List<String> sent;
  late ProviderContainer c;
  late MemoryStore settings;
  var previewKeyCalls = 0;

  setUp(() {
    previewKeyCalls = 0;
    platform = FakePushPlatform();
    sent = [];
    settings = MemoryStore();
    c = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        netServiceProvider.overrideWith((ref) => _Net(ref)),
        pushPlatformProvider.overrideWithValue(platform),
        pushTokenSenderProvider.overrideWithValue(
          (base, kind, token, sandbox, lang, keys, hint) async => sent.add(
            '$base $kind ${token.isEmpty ? '-' : token} $sandbox${keys == null ? '' : ' ${keys.$1}/${keys.$2}'}'
            '${hint == null ? '' : ' hint=$hint'}',
          ),
        ),
        pushPreviewKeysProvider.overrideWithValue(() async {
          previewKeyCalls++;
          return ['aa' * 32, 'bb' * 32];
        }),
        notificationExtensionProvider.overrideWithValue(true),
      ],
    );
    addTearDown(c.dispose);
  });

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('on by default: asks once the account is connected, and the token reaches the server once', () async {
    final push = c.read(pushServiceProvider);
    await push.start();
    expect(platform.registered, 0, reason: 'not on the first screen, before sign-up');
    await push.onConnected();
    await push.onConnected();
    expect(platform.registered, 1);
    platform.tokensCtl.add(('ab' * 32, true));
    await tick();
    await tick();
    expect(sent, ['https://srv alert ${'ab' * 32} true']);
    await push.sync();
    expect(sent.length, 1, reason: 'same server, token and setting: not again');
  });

  test('switching off removes the token from the server; on sends it again', () async {
    final push = c.read(pushServiceProvider);
    await push.start();
    platform.tokensCtl.add(('cd' * 32, false));
    await tick();
    await tick();
    await push.setEnabled(false);
    expect(sent.last, 'https://srv alert - false');
    await push.setEnabled(true);
    expect(sent.last, 'https://srv alert ${'cd' * 32} false');
  });

  test('storage-devices:16 — after sign-out the old account no longer rings or notifies this phone', () async {
    platform.lastVoip = ('ef' * 32, true);
    final push = c.read(pushServiceProvider);
    await push.start();
    platform.tokensCtl.add(('ab' * 32, true));
    await tick();
    await tick();
    sent.clear();
    await push.stopOnServer();
    expect(sent, unorderedEquals(['https://srv alert - true', 'https://srv voip - true']));
  });

  test('sign-out offline: stopping the pushes gives up instead of holding the wipe', () async {
    final hung = ProviderContainer(
      overrides: [
        settingsStoreProvider.overrideWithValue(settings),
        netServiceProvider.overrideWith((ref) => _Net(ref)),
        pushPlatformProvider.overrideWithValue(platform),
        pushTokenSenderProvider.overrideWithValue((base, kind, token, sandbox, lang, keys, hint) => Completer<void>().future),
      ],
    );
    addTearDown(hung.dispose);
    platform.lastVoip = ('ef' * 32, true);
    final push = hung.read(pushServiceProvider);
    await push.start();
    final watch = Stopwatch()..start();
    await push.stopOnServer();
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('off in settings: never asks iOS', () async {
    settings.map['push_enabled'] = '0';
    await c.read(pushServiceProvider).start();
    await c.read(pushServiceProvider).onConnected();
    expect(platform.registered, 0);
  });

  // Overnight item 9 — the PushKit token rings the phone for calls.
  test('the VoIP token (also one iOS gave before Dart listened) goes as kind voip', () async {
    platform.lastVoip = ('ef' * 32, true);
    await c.read(pushServiceProvider).start();
    await tick();
    expect(sent, contains('https://srv voip ${'ef' * 32} true'));
  });

  // ADR-056 — the PushKit token goes with this phone's call hint key, so
  // a call push can name the chat for CallKit; switched off, neither goes.
  test('the VoIP token carries the call hint key', () async {
    platform.hintKey = '07' * 32;
    platform.lastVoip = ('ef' * 32, false);
    await c.read(pushServiceProvider).start();
    await tick();
    expect(sent, ['https://srv voip ${'ef' * 32} false hint=${'07' * 32}']);
  });

  test('connected: the extension gets the delivery keys once while they stay the same', () async {
    final push = c.read(pushServiceProvider);
    await push.onConnected();
    expect(platform.previewKeys, ['aa' * 32, 'bb' * 32]);
    platform.previewKeys = null;
    await push.onConnected();
    expect(previewKeyCalls, 2);
    expect(platform.previewKeys, isNull, reason: 'unchanged keys are not written again');
  });

  test('incoming calls off: the VoIP token is taken off the server', () async {
    settings.map['incoming_calls'] = '0';
    final push = c.read(pushServiceProvider);
    await push.start();
    platform.voipCtl.add(('ab' * 32, false));
    await tick();
    await tick();
    expect(sent.where((s) => s.contains('voip')), ['https://srv voip - false']);
  });

  // ADR-040 — Android without ntfy: say what to install; iOS refused: where to allow.
  for (final (state, text) in [
    ('noDistributor', 'Install ntfy'),
    ('denied', 'Notifications are off in iOS Settings'),
    ('authorized', 'your server can’t read messages'),
  ]) {
    testWidgets('Sounds & Vibration footer when push is $state', (t) async {
      platform.state = state;
      t.view.physicalSize = const Size(390, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: DsTheme(
            tokens: DsTokens.light,
            isDark: false,
            child: const MediaQuery(
              data: MediaQueryData(size: Size(390, 1400)),
              child: Directionality(textDirection: TextDirection.ltr, child: NotificationsScreen()),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.textContaining(text), findsOneWidget);
    });
  }

  // ADR-040 fallback (Android without ntfy).
  test('"always connected" is saved and tells the phone to keep the app running', () async {
    await c.read(pushServiceProvider).setKeepConnected(true);
    expect(platform.calls, ['keepAlive true']);
    expect(settings.map['android_keep_connected'], '1');
    await c.read(pushServiceProvider).setKeepConnected(false);
    expect(platform.calls.last, 'keepAlive false');
  });

  test('the distributor dropped the endpoint: it comes off the server', () async {
    final push = c.read(pushServiceProvider);
    await push.start();
    platform.tokensCtl.add(('ab' * 32, false));
    await tick();
    await tick();
    platform.removedCtl.add(null);
    await tick();
    await tick();
    expect(sent.where((s) => s.contains('alert')).last, 'https://srv alert - false');
  });

  test('a UnifiedPush endpoint goes with the phone\'s Web Push keys; its removal without', () async {
    const up = 'https://push.example.org/upAbC';
    platform.keys[up] = ('BPub', 'Auth');
    final push = c.read(pushServiceProvider);
    await push.start();
    platform.tokensCtl.add((up, false));
    platform.voipCtl.add((up, false));
    await tick();
    await tick();
    expect(sent, containsAll(['https://srv alert $up false BPub/Auth', 'https://srv voip $up false BPub/Auth']));
    await push.setEnabled(false);
    expect(sent.last, 'https://srv alert - false');
  });
}
