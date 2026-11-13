// Overnight item 8 — push notifications.
//
// With the setting on (default) the app asks iOS once, registers with APNs
// and tells the server its token (signed, with sandbox / production and
// the phone's language for the words). The server then wakes this phone
// for real messages that arrive while the app is closed: "New message" and
// the badge — never the text or the chat (the server can't read them).
// Switching it off removes the token from the server.
//
// ADR-056 (iPhone): the sender seals a preview of the message to this
// person's delivery key; the Notification Service Extension opens it and
// shows "<name>: <text>" as Settings → Notifications show says. For that the
// app keeps the extension's copy of the delivery keys, the chat and people
// names and who is blocked in the shared Keychain (`NotificationContext`
// in notification_context.dart), and registers a call hint key with the
// PushKit token so CallKit names the caller before the app connects.
//
// ADR-057 (Android): Google push (FCM) when the server has a Firebase
// project (its ids come on `GET /v1/push/info`) and the phone Google
// services — the token goes up with this phone's own key, the server seals
// every push to it, Google sees only that something came. A push wakes the
// app's connection for a few seconds (`push_wake.dart`), so the app fetches
// and draws "name: text" itself. Without Google push or ntfy, "always
// connected" comes on by itself (until the person sets it).
//
// Native side: `ios/Runner/AppDelegate.swift` (`PushBridge`, channel
// `dev.sinhron/push`); Android `Push.kt`, `Fcm.kt`, `PushWake.kt`.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/chat_list/chat_data.dart' show ChatPreview;
import '../l10n/l10n.dart';
import '../src/rust/api/simple.dart' as core;
import 'background_connection.dart' show backgroundConnectionProvider;
import 'call_reach.dart' show askBatteryOnce;
import 'notification_context.dart';
import 'notification_reply.dart' show NotificationReply, ReplyOutcome;
import 'push_server.dart' show fcmIdsFetcherProvider, isAndroidProvider;
import 'providers/settings_providers.dart';
import 'services/net_service.dart';
import 'session.dart';

/// The native bridge (faked in tests).
abstract class PushPlatform {
  /// Ask iOS (once) and register with APNs. True when allowed.
  Future<bool> register();

  /// "authorized" / "denied" / "notDetermined" / "provisional".
  Future<String> status();

  /// Tokens from APNs: (hex, sandbox).
  Stream<(String, bool)> get tokens;

  /// PushKit (calls) tokens — overnight item 9.
  Stream<(String, bool)> get voipTokens;

  /// The PushKit token iOS already gave (it may come before Dart listens).
  Future<(String, bool)?> lastVoipToken();

  /// ADR-040 fallback (Android, no ntfy): keep the app running and connected.
  Future<void> keepAlive(bool on);

  /// In that mode: the notification of a message the app received itself.
  /// ADR-066 — [reply]: with a "Reply" field on it (iPhone: a local
  /// notification — a missed call, a message while the app is connected in
  /// the background).
  /// [quiet]: ADR-071 (amended) — a message request: no sound, no pop-up.
  Future<void> showMessage({
    required String chatId,
    required String title,
    required String body,
    bool reply = false,
    bool quiet = false,
  });

  /// Status 223 — the chat was read (here or on my other device): its
  /// notifications leave the notification centre.
  Future<void> clearChat(String chatId);

  /// A notification was tapped: the chat it was about ('' = none known).
  Stream<String> get opened;

  /// Opened from a notification before Dart listened? Its chat ('' = none),
  /// or null.
  Future<String?> takeOpened();

  /// ADR-066 — a reply typed into a message notification
  /// (`notification_reply.dart`).
  Stream<NotificationReply> get replies;

  /// ADR-066 — replies that came before Dart listened (the native side keeps
  /// them, encrypted, until taken).
  Future<List<NotificationReply>> takeReplies();

  /// ADR-066 — how that reply went: the native side updates the notification.
  Future<void> replyDone(String id, ReplyOutcome outcome);

  /// Android: the distributor dropped the endpoint — take it off the server.
  Stream<void> get tokenRemoved;

  /// Android: the phone's Web Push keys (p256dh, auth — base64url) that came
  /// with this UnifiedPush endpoint; the server encrypts pushes to them
  /// (RFC 8291). Null for APNs tokens.
  (String, String)? webPushKeys(String token);

  /// ADR-056 (iOS) — what the notification extension shows (JSON from
  /// `notificationContextProvider`), into the shared Keychain.
  Future<void> setNotificationContext(String json);

  /// ADR-056 (iOS) — this person's private delivery keys (hex) the
  /// extension opens message previews with.
  Future<void> setPreviewKeys(List<String> keys);

  /// ADR-056 (iOS) — this phone's call hint key (hex, made once); null
  /// where there is none (Android).
  Future<String?> callHintKey();

  /// The account was erased here: forget all of the above.
  Future<void> clearNotificationData();

  /// ADR-040 (Android) — is the ntfy app on this phone?
  Future<bool> ntfyInstalled();

  /// ADR-040 (Android) — open the ntfy app.
  Future<void> openNtfy();

  /// ADR-040 (Android) — register with ntfy again, after the person set this
  /// server there (ntfy keeps an old registration on the server it was made
  /// on). True when there is a distributor.
  Future<bool> reconnect();

  /// ADR-057 (Android) — this phone's own key (hex) that came with an FCM
  /// token; the server seals pushes to it. Null for other tokens.
  String? pushKey(String token);

  /// ADR-057 (Android) — the server's Firebase ids (null: it has none) →
  /// Google push on / off here. The token (`fcm:…`) or null.
  Future<String?> fcmConfigure(Map<String, String>? ids);

  /// ADR-057 — a push woke this app (Android asks while it runs).
  Stream<void> get wakes;

  /// ADR-057 — was this (screen-less) start for a push? Asked once.
  Future<bool> takeWake();

  /// ADR-057 — the woken connection fetched what there was. [handled]: a
  /// message reached the app (it drew its notification or chose not to — a
  /// muted chat), so the phone draws no plain "New message" on top.
  Future<void> wakeDone({bool handled = false});
}

class ChannelPushPlatform implements PushPlatform {
  ChannelPushPlatform() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'token' || 'voipToken':
          final a = (call.arguments as Map).cast<String, Object?>();
          final token = a['token'] as String?;
          if (token != null && token.isNotEmpty) {
            _remember(token, a);
            (call.method == 'token' ? _tokens : _voip).add((token, a['sandbox'] == true));
          }
        case 'opened':
          final a = (call.arguments as Map?)?.cast<String, Object?>();
          final chatId = (a?['chatId'] as String?) ?? '';
          // ADR-066 — nobody listens yet (a cold start: the root widget comes
          // later): kept for [takeOpened] instead of lost.
          if (_opened.hasListener) {
            _opened.add(chatId);
          } else {
            _unclaimedOpen = chatId;
          }
        case 'reply':
          // ADR-066 — true: Dart took it (the native side forgets its copy).
          final r = NotificationReply.fromMap(call.arguments);
          if (r == null || !_replies.hasListener) return false;
          _replies.add(r);
          return true;
        case 'tokenRemoved':
          _removed.add(null);
        case 'wake':
          _wakes.add(null);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('dev.sinhron/push');
  final _tokens = StreamController<(String, bool)>.broadcast();
  final _voip = StreamController<(String, bool)>.broadcast();
  final _opened = StreamController<String>.broadcast();
  String? _unclaimedOpen;
  final _replies = StreamController<NotificationReply>.broadcast();
  final _removed = StreamController<void>.broadcast();
  final _wakes = StreamController<void>.broadcast();
  final _keys = <String, (String, String)>{};
  final _pushKeys = <String, String>{};

  void _remember(String token, Map<String, Object?> a) {
    final p256dh = a['p256dh'] as String?;
    final auth = a['auth'] as String?;
    if (p256dh != null && auth != null) _keys[token] = (p256dh, auth);
    final key = a['key'] as String?;
    if (key != null) _pushKeys[token] = key;
  }

  @override
  (String, String)? webPushKeys(String token) => _keys[token];

  @override
  String? pushKey(String token) => _pushKeys[token];

  @override
  Stream<void> get wakes => _wakes.stream;

  @override
  Future<String?> fcmConfigure(Map<String, String>? ids) => _call<String>('fcmConfigure', {'ids': ids});

  @override
  Future<bool> takeWake() async => await _call<bool>('takeWake') ?? false;

  @override
  Future<void> wakeDone({bool handled = false}) => _call<void>('wakeDone', {'handled': handled});

  @override
  Stream<String> get opened => _opened.stream;

  @override
  Stream<void> get tokenRemoved => _removed.stream;

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null; // iOS has no such method — fine
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> keepAlive(bool on) => _call<void>('keepAlive', {'on': on});

  @override
  Future<void> setNotificationContext(String json) => _call<void>('setNotificationContext', {'json': json});

  @override
  Future<void> setPreviewKeys(List<String> keys) => _call<void>('setPreviewKeys', {'keys': keys});

  @override
  Future<String?> callHintKey() => _call<String>('callHintKey');

  @override
  Future<void> clearNotificationData() => _call<void>('clearNotificationData');

  @override
  Future<bool> ntfyInstalled() async => await _call<bool>('ntfyInstalled') ?? false;

  @override
  Future<void> openNtfy() => _call<bool>('openNtfy');

  @override
  Future<bool> reconnect() async => await _call<bool>('reconnect') ?? false;

  @override
  Future<void> showMessage({
    required String chatId,
    required String title,
    required String body,
    bool reply = false,
    bool quiet = false,
  }) => _call<void>('showMessage', {'chatId': chatId, 'title': title, 'body': body, 'reply': reply, 'quiet': quiet});

  @override
  Future<void> clearChat(String chatId) => _call<void>('clearChat', {'chatId': chatId});

  @override
  Stream<NotificationReply> get replies => _replies.stream;

  @override
  Future<List<NotificationReply>> takeReplies() async {
    final v = await _call<List<Object?>>('takeReplies');
    return [for (final m in v ?? const <Object?>[]) ?NotificationReply.fromMap(m)];
  }

  @override
  Future<void> replyDone(String id, ReplyOutcome outcome) =>
      _call<void>('replyDone', {'id': id, 'outcome': outcome.name});

  @override
  Future<String?> takeOpened() async {
    final local = _unclaimedOpen;
    _unclaimedOpen = null;
    if (local != null) {
      await _call<Object>('takeOpened'); // the native copy of the same tap
      return local;
    }
    final v = await _call<Object>('takeOpened');
    return switch (v) {
      final String s => s,
      true => '',
      _ => null,
    };
  }

  @override
  Stream<(String, bool)> get tokens => _tokens.stream;

  @override
  Stream<(String, bool)> get voipTokens => _voip.stream;

  @override
  Future<(String, bool)?> lastVoipToken() async {
    try {
      final a = (await _channel.invokeMethod<Map<Object?, Object?>>('voipToken'))?.cast<String, Object?>();
      final token = a?['token'] as String?;
      if (token == null || token.isEmpty) return null;
      _remember(token, a!);
      return (token, a['sandbox'] == true);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> register() async {
    try {
      return await _channel.invokeMethod<bool>('register') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String> status() async {
    try {
      return await _channel.invokeMethod<String>('status') ?? 'notDetermined';
    } on MissingPluginException {
      return 'unsupported';
    } on PlatformException {
      return 'unsupported';
    }
  }
}

final pushPlatformProvider = Provider<PushPlatform>((ref) => ChannelPushPlatform());

/// Sends a token to the server (faked in tests): base, kind, token, sandbox,
/// lang, Web Push keys (p256dh, auth — UnifiedPush only), call hint key
/// (hex — PushKit tokens only, ADR-056).
final pushTokenSenderProvider =
    Provider<Future<void> Function(String, String, String, bool, String, (String, String)?, String?)>(
      (ref) =>
          (base, kind, token, sandbox, lang, keys, hintKey) => core.pushRegisterToken(
            serverBaseUrl: base,
            kind: kind,
            tokenHex: token,
            sandbox: sandbox,
            lang: lang,
            p256Dh: keys?.$1,
            auth: keys?.$2,
            callHintKeyHex: hintKey,
          ),
    );

/// ADR-056 — does this phone have the notification extension (iPhone)?
final notificationExtensionProvider = Provider<bool>((ref) => Platform.isIOS);

/// ADR-056 — the private delivery keys for the notification extension
/// (faked in tests).
final pushPreviewKeysProvider = Provider<Future<List<String>> Function()>((ref) => core.pushPreviewKeys);

/// Messages wake this phone while the app is closed.
final pushEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('push_enabled', true));

/// ADR-040 fallback (Android without ntfy): stay connected in background.
/// ADR-057 — until the person sets it, it follows the phone: on while
/// there is no other push (no Google push, no ntfy), off once there is.
/// Bug 2026-10-19 (calls must reach the phone AND the battery
/// mustn't drain) — a choice of "on" made while the phone had no other
/// push goes back to following the phone once Google push works.
class KeepConnectedSetting extends BoolSetting {
  KeepConnectedSetting() : super('android_keep_connected', false);

  /// What the phone chose by itself (no other push → '1').
  static const autoKey = 'android_keep_connected_auto';

  /// Did the phone have another push when the person chose? '1' yes, '0'
  /// no; none: chosen before 2026-10-19 — counts as no.
  static const routeKey = 'android_keep_connected_route';

  @override
  Future<bool> build() async {
    try {
      final store = ref.read(settingsStoreProvider);
      final own = await store.get(key);
      final v = own == null || own.isEmpty ? await store.get(autoKey) : own;
      return v == null ? fallback : v == '1';
    } catch (_) {
      return fallback;
    }
  }

  /// Did the person set the switch themselves? ('' = handed back.)
  Future<bool> chosen() async {
    try {
      return (await ref.read(settingsStoreProvider).get(key) ?? '').isNotEmpty;
    } catch (_) {
      return true; // can't tell — leave it alone
    }
  }

  /// The person's choice, and whether the phone had another push then.
  Future<void> choose(bool on, {required bool hadPush}) async {
    await ref.read(settingsStoreProvider).set(routeKey, hadPush ? '1' : '0');
    await save(on);
  }

  /// "On", chosen while nothing else could wake the phone.
  Future<bool> onForLackOfPush() async {
    try {
      final store = ref.read(settingsStoreProvider);
      return await store.get(key) == '1' && await store.get(routeKey) != '1';
    } catch (_) {
      return false;
    }
  }

  /// Back to following the phone.
  Future<void> handBack() => ref.read(settingsStoreProvider).set(key, '');

  Future<void> saveAuto(bool on) async {
    await ref.read(settingsStoreProvider).set(autoKey, on ? '1' : '0');
    state = AsyncData(on);
  }
}

final keepConnectedProvider = AsyncNotifierProvider<KeepConnectedSetting, bool>(KeepConnectedSetting.new);


/// Does the app keep its connection when it leaves the screen? Only Android
/// with "always connected" on (faked in tests).
final stayConnectedInBackgroundProvider = Provider<bool Function()>(
  (ref) =>
      () => Platform.isAndroid && (ref.read(keepConnectedProvider).value ?? false),
);

/// ADR-040 fallback — after a restart or an update Android starts the app
/// for "always connected" with no screen (`SinhronApplication`): no frame,
/// no widget, so nothing would connect (found on the emulator 2026-10-16).
/// Connect from `main` instead; incoming messages then become system
/// notifications (`maybeShowBanner`). With a screen the route's own
/// `resume()` finds the session already up.
Future<void> connectWithoutScreen(ProviderContainer c) async {
  if (!Platform.isAndroid || !await c.read(keepConnectedProvider.future)) return;
  try {
    await c.read(sessionProvider).resume();
  } catch (_) {
    // Offline — the route retries when the screen opens.
  }
  // No screen: the long background heartbeat (battery 2026-10-18).
  await c.read(backgroundConnectionProvider).startedWithoutScreen(WidgetsBinding.instance.lifecycleState);
}

/// iOS allowed notifications? (re-read when the screen opens)
final pushPermissionProvider = FutureProvider.autoDispose<String>((ref) => ref.read(pushPlatformProvider).status());

class PushService {
  PushService(this._ref);
  final Ref _ref;
  StreamSubscription<(String, bool)>? _sub;
  StreamSubscription<(String, bool)>? _voipSub;
  StreamSubscription<void>? _removedSub;
  (String, bool)? _token;
  (String, bool)? _voip;
  String? _sentFor;
  String? _voipSentFor;

  /// Listen for tokens; ask / register when the setting is on.
  Future<void> start() async {
    final platform = _ref.read(pushPlatformProvider);
    _sub ??= platform.tokens.listen((t) {
      _token = t;
      unawaited(sync());
    });
    _voipSub ??= platform.voipTokens.listen((t) {
      _voip = t;
      unawaited(syncVoip());
      // ADR-057 — a route came (Google push, ntfy): maybe no need to stay
      // connected any more.
      unawaited(applyAutoKeepConnected());
    });
    _removedSub ??= platform.tokenRemoved.listen((_) {
      // ADR-057 — no route left: "always connected" may be needed again.
      unawaited(applyAutoKeepConnected());
      // The distributor dropped us: tell the server (empty token = remove).
      final t = _token;
      _token = t == null ? null : ('', t.$2);
      _voip = t == null ? null : ('', t.$2);
      _sentFor = null;
      _voipSentFor = null;
      unawaited(sync());
      unawaited(syncVoip());
    });
    _voip ??= await platform.lastVoipToken();
    unawaited(syncVoip());
    if (!_ref.read(isAndroidProvider)) return;
    // Audit 15/PA-11 — Android has one route for messages and calls
    // (Push.kt `sendRoute`), but the message one came only as an event: a
    // process that got no event (`/v1/push/info` silent) re-sent only the
    // call token, and a message row the server had dropped stayed gone.
    _token ??= _voip;
    // A route already (Google push or ntfy): "always connected" isn't needed.
    if (_voip != null) await applyAutoKeepConnected();
    if (await _ref.read(keepConnectedProvider.future)) await platform.keepAlive(true);
  }

  /// ADR-057 — "always connected" on by itself while this phone has no
  /// other push, off once it has (Google push came, ntfy was set up);
  /// never against the person's own choice — except an "on" chosen for
  /// lack of push, which follows the phone again once Google push works
  /// (bug 2026-10-19: the always-on socket ran the battery down for nothing).
  Future<void> applyAutoKeepConnected() async {
    if (!_ref.read(isAndroidProvider)) return;
    final setting = _ref.read(keepConnectedProvider.notifier);
    if (await setting.chosen()) {
      // Only for Google push: an ntfy that isn't set to this server yet
      // (status 150) can look like a route and wake nothing.
      final google = _voip?.$1.startsWith('fcm:') ?? false;
      if (!google || !await setting.onForLackOfPush()) return;
      await setting.handBack();
    }
    final want = !_hasPush;
    if (want == await _ref.read(keepConnectedProvider.future)) return;
    await setting.saveAuto(want);
    await _ref.read(pushPlatformProvider).keepAlive(want);
  }

  /// Google push or ntfy reaches this phone.
  bool get _hasPush => _voip != null && _voip!.$1.isNotEmpty;

  /// ADR-057 — Google push: hand the native side this server's Firebase
  /// ids (or that it has none); its token comes back as the route.
  Future<void> syncFcm() async {
    if (!_ref.read(isAndroidProvider)) return;
    final info = await _ref.read(fcmIdsFetcherProvider)();
    if (info == null) return; // offline / unknown — keep what there is
    final platform = _ref.read(pushPlatformProvider);
    final token = await platform.fcmConfigure(info.ids);
    // The route now, with its key (the native side also sends it as an event).
    if (token != null) _voip = await platform.lastVoipToken() ?? _voip;
  }

  /// ADR-040 fallback — the switch in Settings → Sounds & vibrations
  /// (Android only).
  Future<void> setKeepConnected(bool on) async {
    await _ref.read(keepConnectedProvider.notifier).choose(on, hadPush: _hasPush);
    await _ref.read(pushPlatformProvider).keepAlive(on);
  }

  bool _asked = false;

  /// The server connection is up — so there is an account (found on the
  /// Android emulator 2026-10-16: the system "allow notifications?" came on
  /// the very first screen, before sign-up). Ask iOS / Android once now,
  /// then keep the server's copy of the tokens current.
  Future<void> onConnected() async {
    // Status 223 (Android: ни одного push за час): the server may have
    // dropped the token (Google said "gone") while this process kept
    // thinking it was sent — so every connection sends both again.
    _sentFor = null;
    _voipSentFor = null;
    if (!_asked && await _ref.read(pushEnabledProvider.future)) {
      _asked = true;
      await _ref.read(pushPlatformProvider).register();
    }
    // ADR-057 — then, once, the battery question (Android).
    if (await _ref.read(pushEnabledProvider.future)) await askBatteryOnce(_ref);
    await syncFcm();
    await sync();
    await syncVoip();
    await syncPreviewKeys();
    // After Google push had its chance: no route at all → stay connected.
    await applyAutoKeepConnected();
  }

  String? _keysSent;

  /// ADR-056 — hand the extension this week's (and the nearby weeks')
  /// delivery keys; again only when they change (once a week).
  Future<void> syncPreviewKeys() async {
    if (!_ref.read(notificationExtensionProvider)) return;
    try {
      final keys = await _ref.read(pushPreviewKeysProvider)();
      final key = keys.join(',');
      if (key == _keysSent) return;
      await _ref.read(pushPlatformProvider).setPreviewKeys(keys);
      _keysSent = key;
    } catch (_) {
      // Not signed in yet — the next connection tries again.
    }
  }

  /// Send the current token (or its removal) to the server once per
  /// server + token + setting.
  Future<void> sync() async {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    final token = _token;
    if (base == null || token == null) return;
    final on = await _ref.read(pushEnabledProvider.future);
    final key = '$base|${token.$1}|$on|$currentLanguage';
    if (key == _sentFor) return;
    final lang = currentLanguage == 'ru' ? 'ru' : 'en';
    try {
      final platform = _ref.read(pushPlatformProvider);
      final keys = on ? platform.webPushKeys(token.$1) : null;
      // ADR-057 — an FCM token goes with the phone's key (the server seals to it).
      final pushKey = on ? platform.pushKey(token.$1) : null;
      await _ref.read(pushTokenSenderProvider)(base, 'alert', on ? token.$1 : '', token.$2, lang, keys, pushKey);
      _sentFor = key;
      // ignore: avoid_print
      print('[sinhron][push] message token sent: ${_route(token.$1)}${on ? '' : ' (off)'}');
    } catch (e) {
      // Offline — the next start or connection tries again.
      // ignore: avoid_print
      print('[sinhron][push] message token not sent: $e');
    }
  }

  /// Overnight item 9 — the PushKit token rings this phone for calls while
  /// the app is closed; with incoming calls off it is taken off the server.
  Future<void> syncVoip() async {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    final token = _voip;
    if (base == null || token == null) return;
    final on = await _ref.read(incomingCallsProvider.future);
    final platform = _ref.read(pushPlatformProvider);
    // ADR-056 — an APNs PushKit token goes with this phone's call hint key;
    // ADR-057 — an FCM token with the phone's push key.
    final hintKey = on && !token.$1.startsWith('https://')
        ? platform.pushKey(token.$1) ?? await platform.callHintKey()
        : null;
    final key = '$base|${token.$1}|$on|$hintKey';
    if (key == _voipSentFor) return;
    try {
      final keys = on ? platform.webPushKeys(token.$1) : null;
      final lang = currentLanguage == 'ru' ? 'ru' : 'en';
      await _ref.read(pushTokenSenderProvider)(base, 'voip', on ? token.$1 : '', token.$2, lang, keys, hintKey);
      _voipSentFor = key;
      // ignore: avoid_print
      print('[sinhron][push] call token sent: ${_route(token.$1)}${on ? '' : ' (off)'}');
    } catch (e) {
      // Offline — the next connection tries again.
      // ignore: avoid_print
      print('[sinhron][push] call token not sent: $e');
    }
  }

  /// Sign-out and the other wipes (audit storage-devices:16): the server
  /// stops waking this phone for the account that leaves it — no rings, no
  /// "New message" for it. Before the device key goes (the request is
  /// signed with it); a few seconds at most, so signing out offline still
  /// works. The device itself stays on the account's list: revoking the
  /// first device would lock its key (made from the 24 words) out for good.
  Future<void> stopOnServer() async {
    final tokens = [if (_token case final t?) ('alert', t), if (_voip case final t?) ('voip', t)];
    final base = tokens.isEmpty ? null : _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) return;
    final send = _ref.read(pushTokenSenderProvider);
    final lang = currentLanguage == 'ru' ? 'ru' : 'en';
    try {
      await Future.wait([
        for (final (kind, t) in tokens) send(base, kind, '', t.$2, lang, null, null),
      ]).timeout(const Duration(seconds: 3));
    } catch (_) {
      // Offline / the account is gone already — nothing more to do here.
    }
    _sentFor = null;
    _voipSentFor = null;
  }

  /// Which route, never the token itself (the journal goes to the owner).
  static String _route(String token) => token.isEmpty
      ? 'removed'
      : token.startsWith('fcm:')
      ? 'Google'
      : token.startsWith('https://')
      ? 'ntfy'
      : 'Apple';

  /// The switch in Settings → Sounds & Vibration.
  Future<void> setEnabled(bool on) async {
    await _ref.read(pushEnabledProvider.notifier).save(on);
    if (on) await _ref.read(pushPlatformProvider).register();
    await sync();
    _ref.invalidate(pushPermissionProvider);
  }

  void dispose() {
    _sub?.cancel();
    _voipSub?.cancel();
    _removedSub?.cancel();
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final s = PushService(ref);
  ref.onDispose(s.dispose);
  return s;
});

/// ADR-066 — the chat a tapped notification is about, once the chat list
/// has it: on a cold start from the tap the list is still loading (it used
/// to be empty then, and the tap only opened the chat list); a brand-new
/// chat comes with the first sync. Null after [within].
Future<ChatPreview?> waitForChat(
  String chatId, {
  required Future<List<ChatPreview>> Function() chats,
  Duration within = const Duration(seconds: 12),
  Duration every = const Duration(milliseconds: 300),
}) async {
  final until = DateTime.now().add(within);
  while (true) {
    try {
      final found = (await chats()).where((c) => c.id == chatId).firstOrNull;
      if (found != null) return found;
    } catch (_) {
      // The chats DB isn't open yet — try again.
    }
    if (!DateTime.now().isBefore(until)) return null;
    await Future<void>.delayed(every);
  }
}

/// Starts push once the app is up and re-sends the token when the server
/// connection comes back (the server may be new, or was offline). Renders
/// nothing.
class PushSync extends ConsumerStatefulWidget {
  const PushSync({super.key, required this.child, this.onOpenChat});
  final Widget child;

  /// A notification about this chat was tapped (Android: the app knows
  /// which chat — ADR-040; iOS: the extension found it in the preview,
  /// ADR-056).
  final void Function(String chatId)? onOpenChat;

  @override
  ConsumerState<PushSync> createState() => _PushSyncState();
}

class _PushSyncState extends ConsumerState<PushSync> {
  StreamSubscription<String>? _opened;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(pushServiceProvider).start());
    // ADR-056 — the extension's copy of names, blocks and the setting.
    ref.listenManual<String?>(notificationContextProvider, (_, json) {
      if (json != null) unawaited(ref.read(pushPlatformProvider).setNotificationContext(json));
    }, fireImmediately: true);
    final platform = ref.read(pushPlatformProvider);
    _opened = platform.opened.listen(_open);
    // Started by a tap on a notification (cold start).
    unawaited(platform.takeOpened().then((id) => id == null ? null : _open(id)));
  }

  String? _lastOpen;
  DateTime? _lastOpenAt;

  void _open(String chatId) {
    if (chatId.isEmpty) return;
    // ADR-066 — one tap can come twice (the event and `takeOpened` on a
    // start); the second within a moment is the same tap.
    final now = DateTime.now();
    if (chatId == _lastOpen && _lastOpenAt != null && now.difference(_lastOpenAt!) < const Duration(seconds: 3)) return;
    _lastOpen = chatId;
    _lastOpenAt = now;
    widget.onOpenChat?.call(chatId);
  }

  @override
  void dispose() {
    _opened?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Incoming calls switched on / off: the server rings this phone or not.
    ref.listen(incomingCallsProvider, (_, _) => unawaited(ref.read(pushServiceProvider).syncVoip()));
    ref.listen(netStatusProvider, (_, s) {
      if (s == NetStatus.connected) unawaited(ref.read(pushServiceProvider).onConnected());
    });
    return widget.child;
  }
}
