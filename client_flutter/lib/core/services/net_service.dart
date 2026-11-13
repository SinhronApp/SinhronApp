// Network event-loop service — drives the Rust sinhron_net WS client
// from Dart and routes incoming events into storage + Riverpod
// invalidations. Lives in `lib/core/services/` to keep it out of the
// provider directory (which is for Riverpod surfaces only).
//
// Lifecycle:
//   • [startFromPhrase] called at end of onboarding (RecoveryPhraseScreen)
//     OR by a Settings "reconnect" button if the seed has been re-derived.
//   • Spawns a single Dart Future that loops `netNextEvent` until the
//     client is shut down. The loop body routes by event.kind:
//        - "connected"    → log
//        - "disconnected" → log (sinhron_net's run_loop auto-reconnects)
//        - "push"         → persist + invalidate
//        - "ack"          → log
//
// ADR-021: the phrase isn't persisted (spec §6.8), but the device key
// derived from it is (iOS Keychain) — `lib/core/session.dart` restarts
// this service with it on every launch and from Settings → "Reconnect".

import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/banners/in_app_banner.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/simple.dart' as core;
import '../background_connection.dart' show backgroundConnectionProvider;
import '../mentions.dart';
import '../message_time.dart';
import '../providers/people.dart';
import '../providers/presence.dart';
import '../providers/chat_actions.dart';
import '../providers/chat_providers.dart';
import '../providers/device_providers.dart' show announceDeviceName;
import '../providers/device_transfer.dart';
import '../providers/personal_chats.dart' show formerPersonalRedirect, personalChatsProvider;
import '../providers/saved_messages.dart' show formerSavedRedirect, savedChatIdProvider, savedMessagesProvider;
import '../../features/chat_info/chat_info_screen.dart' show chatMembersProvider;
import '../../features/chat_list/chat_data.dart' show ChatPreview;
import '../providers/core_providers.dart';
import '../providers/message_actions.dart';
import '../providers/settings_providers.dart';
import '../session.dart' show deviceSeedStoreProvider;
import '../ui_sounds.dart';

/// Public state surface — Riverpod widget can `ref.watch` this to show
/// "Online" / "Reconnecting…" hints in chrome.
enum NetStatus { idle, connecting, connected, disconnected }

class NetService {
  NetService(this._ref);

  final Ref _ref;
  Future<void>? _loop;
  bool _shutdown = false;

  NetStatus _status = NetStatus.idle;
  String? _lastError;

  NetStatus get status => _status;

  /// When the last delivery came down the connection (bug 2026-10-19 —
  /// a push that woke the app asks whether the message is here already).
  DateTime? lastPushAt;

  void _setStatus(NetStatus s) {
    _status = s;
    // Settings → Server shows it live (tech-debt 2.4). The provider may
    // already be gone during app/test teardown.
    try {
      _ref.read(netStatusProvider.notifier).set(s);
    } catch (_) {}
  }

  String? get lastError => _lastError;

  /// HTTP origin of the connected operator server (derived from the WS
  /// url on [startFromPhrase]). Media upload/download goes here.
  String? _httpBaseUrl;
  String? get httpBaseUrl => _httpBaseUrl;

  /// Our identity key (hex) — the same on all our devices (ADR-025).
  String? _myIdentityHex;
  String? get myIdentityHex => _myIdentityHex;

  /// ADR-025 — device sync: on every connect and every few minutes (a
  /// device linked meanwhile joins our chats without a restart).
  static const deviceSyncEvery = Duration(minutes: 5);
  Timer? _deviceSyncTimer;
  bool _deviceSyncing = false;

  /// ADR-064 — what changed here reaches my other devices this often
  /// (when nothing changed, a flush is one local query).
  static const ownSyncEvery = Duration(seconds: 20);
  Timer? _ownSyncTimer;

  /// ADR-025 — our devices as the server lists them.
  Future<List<core.LinkedDevice>> listDevices() async {
    final base = _httpBaseUrl;
    if (base == null) throw StateError('not connected to a server');
    return core.devicesList(serverBaseUrl: base);
  }

  /// ADR-027 — does this device hold the account key? A QR-paired one
  /// doesn't: it can't add or revoke devices.
  Future<bool> hasAccountKey() async {
    try {
      return await core.syncHasAccountKey();
    } catch (_) {
      return true;
    }
  }

  /// ADR-025 — revoke one of our devices and remove it from every chat.
  /// Waits for a running device sync (both make pending Commits).
  ///
  /// ADR-027 — on a device without the account key, [phrase] (the 24
  /// words, used for this call only) authorizes it.
  Future<void> revokeDevice(String devicePkHex, {String? phrase}) async {
    final base = _httpBaseUrl;
    if (base == null) throw StateError('not connected to a server');
    while (_deviceSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _deviceSyncing = true;
    try {
      final groups = (await core.storageChatsList()).map((c) => c.id).where(looksLikeMlsGroupId).toList();
      if (phrase != null) {
        await core.devicesRevokeWithPhrase(
          serverBaseUrl: base,
          devicePkHex: devicePkHex,
          phrase: phrase,
          groupIdsHex: groups,
        );
      } else {
        await core.devicesRevoke(serverBaseUrl: base, devicePkHex: devicePkHex, groupIdsHex: groups);
      }
      // ADR-084 — new delivery and backup keys it can't compute (it keeps
      // the old ones); my other devices get them in my own-devices group.
      await core.syncRotateAccountRoots(serverBaseUrl: base);
      // Tech-debt 2.2 — and a fresh anonymous-delivery key for our chats.
      await core.syncRotateAccessKey(serverBaseUrl: base);
      await core.syncShareAccessKey(groupIdsHex: groups);
    } finally {
      _deviceSyncing = false;
    }
  }

  /// Tech-debt 2.2 — new anonymous-delivery key: the old one stops working
  /// at once, our chats get the new one.
  Future<void> rotateAccessKey() async {
    final base = _httpBaseUrl;
    if (base == null) throw StateError('not connected to a server');
    while (_deviceSyncing) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _deviceSyncing = true;
    try {
      await core.syncRotateAccessKey(serverBaseUrl: base);
      final groups = (await core.storageChatsList()).map((c) => c.id).where(looksLikeMlsGroupId).toList();
      await core.syncShareAccessKey(groupIdsHex: groups);
    } finally {
      _deviceSyncing = false;
    }
  }

  /// ADR-071 — after a block or unblock: the server's set of our
  /// per-contact access keys follows this device's block list (a blocked
  /// person's key is revoked at once, an unblocked one's comes back) and
  /// keys go out to whoever lacks theirs. Offline: device sync on the next
  /// connect does the same (the decisions are re-sent every time).
  Future<void> refreshAccessKeys() async {
    if (_httpBaseUrl == null || _status != NetStatus.connected) return;
    try {
      final groups = (await core.storageChatsList()).map((c) => c.id).where(looksLikeMlsGroupId).toList();
      await core.syncShareAccessKey(groupIdsHex: groups);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][access] refresh failed: $e');
    }
  }

  /// Add our other devices to our chats and drop revoked ones. Never
  /// awaited from the event loop: it waits for server Acks, which only
  /// that loop delivers. Safe to call any time; one run at a time.
  Future<void> syncDevices({List<String>? groupIdsHex}) async {
    final base = _httpBaseUrl;
    if (base == null || _deviceSyncing || _status != NetStatus.connected) return;
    _deviceSyncing = true;
    try {
      final groups =
          groupIdsHex ??
          (await core.storageChatsList()).map((c) => c.id).where(looksLikeMlsGroupId).toList(growable: false);
      if (groups.isEmpty) return;
      final r = await core.syncDevices(serverBaseUrl: base, groupIdsHex: groups);
      // ignore: avoid_print
      print(
        '[sinhron][devices] sync · added=${r.added} removed=${r.removed} '
        'failed=${r.failed.length} transfers=${r.transfers} peers=${r.peersAdded} '
        'joined=${r.joined} peersRemoved=${r.peersRemoved}',
      );
      // ADR-075 — chats entered by their card: their state (members, the
      // "you're not a member" line) is new.
      if (r.joined > 0) _ref.invalidate(chatsProvider);
      // ADR-064 — a device just joined my own-devices group: it gets
      // everything. No such group yet (a device appeared): make it — its
      // own device sync then adds the new device and queues the transfer.
      if (r.transfers > 0) {
        unawaited(_ref.read(deviceTransfersProvider.notifier).run());
      } else if (r.added > 0 && groupIdsHex == null && _ref.read(savedChatIdProvider).value == null) {
        newDeviceWithoutOwnGroup = true;
      }
      // Tech-debt 2.2 — our sealed-sender access key to every chat (once
      // per group epoch), so members can reach us without authenticating.
      // ADR-071 — one per person, their hashes (and my blocks) on the
      // server first.
      await core.syncShareAccessKey(groupIdsHex: groups);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][devices] sync failed: $e');
    } finally {
      _deviceSyncing = false;
    }
    if (newDeviceWithoutOwnGroup) {
      newDeviceWithoutOwnGroup = false;
      unawaited(_ref.read(savedMessagesProvider).ensure().then((_) {}, onError: (Object _) {}));
    }
    // ADR-074 — Saved messages restored from a phone that is gone.
    // One Saved chat even when two devices each made theirs (2026-10-26).
    if (groupIdsHex == null) {
      final saved = _ref.read(savedMessagesProvider);
      unawaited(saved.repair().then((_) => saved.tidy()).then((_) {}, onError: (Object _) {}));
      // Owner, 2026-11-03 — one personal chat per person.
      unawaited(_ref.read(personalChatsProvider).tidy().then((_) {}, onError: (Object _) {}));
    }
  }

  /// Set by [syncDevices]: a device was added but there is no own-devices
  /// group to send it everything through yet.
  bool newDeviceWithoutOwnGroup = false;

  /// CD3 — broadcast stream of call-signaling events. The
  /// [ActiveCallNotifier] subscribes to drive state transitions. We
  /// keep this as a separate Stream (not a generic NetEvent stream)
  /// so consumers don't accidentally listen to push/ack events too.
  /// Broadcast — multiple listeners allowed (currently just
  /// activeCallProvider, but space-suit future ones like a
  /// missed-calls indicator).
  final StreamController<core.NetEvent> _callEventController = StreamController<core.NetEvent>.broadcast();

  /// Public read-only Stream view. Emits only events where
  /// `kind ∈ {"call_invite","call_accept","call_end","call_ring"}`.
  Stream<core.NetEvent> get callEvents => _callEventController.stream;

  /// Start the WS client from the user's secret — a BIP-39 phrase (end
  /// of onboarding) or the device key from the Keychain (ADR-021,
  /// every later launch); the Rust side accepts both.
  /// Idempotent: a second call replaces the underlying connection.
  ///
  /// `httpBaseUrl` is the HTTP origin (no path) of the operator server,
  /// e.g. `http://localhost:8080`. We derive it from `url` automatically:
  /// `ws://host:port/v1/sync` → `http://host:port`.
  Future<void> startFromPhrase({required String phrase, required String url}) async {
    _setStatus(NetStatus.connecting);
    _lastError = null;

    // MLS-state DB path comes from BootDiagnostics — computed once at
    // `main.dart` boot so the layout doesn't drift across this service
    // and other callers (e.g. Sign Out wiping both files). Empty when
    // the docs-dir resolution failed at boot; that triggers in-memory
    // MLS mode (logged loudly — this session won't survive restart).
    final mlsDbPath = _ref.read(bootDiagnosticsProvider).mlsDbPath;
    if (mlsDbPath.isEmpty) {
      // ignore: avoid_print
      print(
        '[sinhron][sync] WARN: no MLS db path — falling back to in-memory '
        '(group state will NOT survive restart)',
      );
    }

    // 0. The SOCKS5 proxy (Tor) for everything below, if one is set.
    try {
      final proxy = await _ref.read(socksProxyProvider.future);
      core.netSetSocksProxy(proxy: proxy);
    } catch (_) {}

    // 1. Initialise SyncClient. Passing a non-empty path persists MLS
    //    state via openmls_sqlite_storage; "" means in-memory only.
    try {
      // ADR-025 — a linked device also has its own key seed.
      final deviceSeed = await _ref.read(deviceSeedStoreProvider).read();
      _myIdentityHex = await core.syncInitFromPhrase(
        phrase: phrase,
        dbPath: mlsDbPath,
        deviceSeedHex: deviceSeed ?? '',
      );
    } catch (e) {
      _lastError = e.toString();
      _setStatus(NetStatus.disconnected);
      // ignore: avoid_print
      print('[sinhron][sync] init failed: $e');
      return;
    }

    // 2. Open the WS connection first (bug 2026-10-16, owner: after Wi-Fi →
    //    LTE the app stayed "net not connected" until a restart). The HTTP
    //    calls below used to come first and, on a socket of the network
    //    that was gone, could hang — with no connection object at all
    //    meanwhile. The Rust client retries by itself (backoff), so on the
    //    very first launch it just logs in once the bootstrap registered us.
    final httpBaseUrl = _wsToHttp(url);
    _httpBaseUrl = httpBaseUrl;
    try {
      await core.netConnectFromPhrase(url: url, phrase: phrase);
    } catch (e) {
      _lastError = e.toString();
      _setStatus(NetStatus.disconnected);
      // ignore: avoid_print
      print('[sinhron][net] connect failed: $e');
      return;
    }
    _shutdown = false;
    _generation++;
    _loop ??= _runEventLoop();
    // Status 223 — sealing (and notification previews) on at once, not
    // only after the bootstrap: the first messages after launch went plain.
    unawaited(_enableSealed(httpBaseUrl));

    // 3. Bootstrap with the server: register identity + publish first KP.
    //    Best-effort, and not waited on for long: unreachable now is fine,
    //    the next launch / reconnect does it again.
    try {
      final result = await core.syncBootstrapWithServer(serverBaseUrl: httpBaseUrl).timeout(_httpWait);
      // ignore: avoid_print
      print('[sinhron][sync] bootstrap ok · $result');
      unawaited(_keyPackageStock(httpBaseUrl));
      // ADR-023 — publish this week's delivery keys (again, now that we're
      // registered — a first launch couldn't before).
      await _enableSealed(httpBaseUrl);
    } catch (e) {
      _lastError = e.toString();
      // ignore: avoid_print
      print('[sinhron][sync] bootstrap failed: $e');
    }
  }

  /// ADR-023 — publish this week's delivery keys; messages to people who
  /// published theirs go sealed (the server doesn't see the chat) and carry
  /// the notification preview (ADR-056).
  Future<void> _enableSealed(String httpBaseUrl) async {
    try {
      await core.syncEnableSealed(serverBaseUrl: httpBaseUrl).timeout(_httpWait);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][sync] sealed keys not published now: $e — the next connection tries again');
    }
  }

  /// ADR-074 — every chat this device is added to uses one of its
  /// KeyPackages, and a launch publishes one. A phone signed in again is
  /// about to be added back to all its chats by its contacts: once per
  /// device, a stock of [keyPackageStock] (unused ones expire in 30 days).
  static const keyPackageStock = 20;

  Future<void> _keyPackageStock(String base) async {
    const flag = 'kp_stock_v1';
    try {
      if ((await core.storageSettingGet(key: flag)) == '1') return;
      final n = await core.syncPublishKeypackages(serverBaseUrl: base, count: keyPackageStock);
      if (n > 0) await core.storageSettingSet(key: flag, value: '1');
      // ignore: avoid_print
      print('[sinhron][sync] key package stock: $n');
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][sync] key package stock not published: $e');
    }
  }

  /// How long a launch waits for one of its HTTP calls (the Rust side has
  /// its own timeouts too; this only stops the wait).
  static const _httpWait = Duration(seconds: 15);

  /// Back from the background (`BackgroundConnection`): the sync client is
  /// still up — only the WS was closed — so open just that (milliseconds)
  /// instead of re-initialising MLS and bootstrapping again (seconds with
  /// no connection object at all: a quick "Start chat" after copying a key
  /// in another app failed with "no connection" — owner, 2026-10-16).
  Future<void> reopen({required String phrase, required String url}) async {
    if (_myIdentityHex == null) return startFromPhrase(phrase: phrase, url: url);
    _setStatus(NetStatus.connecting);
    try {
      await core.netConnectFromPhrase(url: url, phrase: phrase);
    } catch (e) {
      _lastError = e.toString();
      _setStatus(NetStatus.disconnected);
      // ignore: avoid_print
      print('[sinhron][net] reopen failed: $e');
      return;
    }
    _shutdown = false;
    _generation++;
    _loop ??= _runEventLoop();
  }

  /// Wait (up to [timeout]) for the server connection. True when it's up.
  Future<bool> waitConnected(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (_status != NetStatus.connected) {
      if (DateTime.now().isAfter(end)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  /// Bumped on every new connection: an event loop whose client was closed
  /// while a newer one already started (the app went to background and
  /// came straight back) keeps reading from the new client instead of
  /// leaving it unread.
  int _generation = 0;

  /// `ws://host:port/v1/sync` → `http://host:port`. Used to derive the
  /// HTTP base URL from the WS URL the caller provides.
  String _wsToHttp(String wsUrl) {
    var u = wsUrl;
    if (u.startsWith('wss://')) {
      u = 'https://${u.substring(6)}';
    } else if (u.startsWith('ws://')) {
      u = 'http://${u.substring(5)}';
    }
    // Strip /v1/sync (or any path).
    final slash = u.indexOf('/', u.indexOf('://') + 3);
    return slash >= 0 ? u.substring(0, slash) : u;
  }

  /// Stop the event loop + close the underlying client.
  Future<void> shutdown() async {
    _shutdown = true;
    _deviceSyncTimer?.cancel();
    _deviceSyncTimer = null;
    _ownSyncTimer?.cancel();
    _ownSyncTimer = null;
    await core.netShutdown();
    if (!_callEventController.isClosed) {
      await _callEventController.close();
    }
  }

  Future<void> _runEventLoop() async {
    // ignore: avoid_print
    print('[sinhron][net] event loop started');
    var generation = _generation;
    while (!_shutdown) {
      final event = await core.netNextEvent();
      if (event == null && generation != _generation) {
        generation = _generation;
        continue;
      }
      if (event == null) {
        // ignore: avoid_print
        print('[sinhron][net] client dropped — event loop exiting');
        _setStatus(NetStatus.idle);
        _loop = null;
        return;
      }
      await _handleEvent(event);
    }
    _setStatus(NetStatus.idle);
    _loop = null;
  }

  Future<void> _handleEvent(core.NetEvent event) async {
    switch (event.kind) {
      case 'connected':
        _setStatus(NetStatus.connected);
        _lastError = null;
        // Status 223 — this week's delivery keys out (a no-op when they are).
        final base = _httpBaseUrl;
        if (base != null) unawaited(_enableSealed(base));
        unawaited(syncDevices());
        // Not on the background heartbeat: each check wakes the mobile
        // radio, and a reconnect (or the screen) checks anyway.
        _deviceSyncTimer ??= Timer.periodic(deviceSyncEvery, (_) {
          if (!_ref.read(backgroundConnectionProvider).background) unawaited(syncDevices());
        });
        // ADR-064 — an unfinished transfer goes on; changes go out.
        unawaited(_ref.read(deviceTransfersProvider.notifier).run());
        // My other devices learn this one's name ("iPad Air"), then changes go out.
        unawaited(
          announceDeviceName(
            this,
            _ref.read(settingsStoreProvider),
          ).then((_) => _ref.read(deviceSyncProvider).flush(), onError: (Object _) {}),
        );
        _ownSyncTimer ??= Timer.periodic(ownSyncEvery, (_) {
          if (_status == NetStatus.connected && !_ref.read(backgroundConnectionProvider).background) {
            unawaited(_ref.read(deviceSyncProvider).flush());
          }
        });
        unawaited(_ref.read(presenceProvider).reconnected().catchError((Object _) {}));
        // ignore: avoid_print
        print('[sinhron][net] connected');
        break;
      case 'disconnected':
        _setStatus(NetStatus.disconnected);
        _lastError = event.disconnectedReason;
        // ignore: avoid_print
        print('[sinhron][net] disconnected: ${event.disconnectedReason}');
        // Another of my devices removed this one: say so instead of
        // "Connecting…" forever, and stop knocking.
        if (isDeviceRemovedReason(event.disconnectedReason)) {
          _ref.read(deviceRemovedProvider.notifier).set(true);
          unawaited(core.netShutdown().catchError((Object _) {}));
        }
        break;
      case 'push':
        final p = event.push;
        if (p == null) return;
        await _onPush(p);
        break;
      case 'ack':
        final a = event.ack;
        if (a == null) return;
        // ignore: avoid_print
        print(
          '[sinhron][net] ack frame=${a.ackedFrameId} code=${a.errorCode}'
          ' msg=${a.errorMessage}',
        );
        // Submit frames use the message's wire id → ✓ "sent" / failed.
        try {
          await _ref.read(messageActionsProvider).onAck(a.ackedFrameId, ok: a.errorCode == 0, busy: a.errorCode == 429);
        } catch (_) {}
        break;
      case 'welcome':
        final w = event.welcome;
        if (w == null) return;
        await _onWelcome(w);
        break;
      // CD3 — call signaling events fan out to the activeCall provider
      // via [callEvents]. We don't process them here in NetService —
      // that would put too much call-specific logic in the generic
      // network layer.
      case 'call_invite':
      case 'call_accept':
      case 'call_end':
      case 'call_ring':
        // ignore: avoid_print
        print('[sinhron][net][call] ${event.kind}');
        if (!_callEventController.isClosed) {
          _callEventController.add(event);
        }
        break;
      default:
        // ignore: avoid_print
        print('[sinhron][net] unhandled event.kind=${event.kind}');
    }
  }

  /// Incoming MLS Welcome — accept the invite via sync_join_via_welcome
  /// and surface the new chat to the UI. The local chat row is created
  /// with `display_name = "<group>"` as a placeholder; the user can
  /// rename in a later WU. group_id_hex from the Welcome matches what
  /// the inviter computed, so subsequent Pushes for this group route
  /// to the same chat row.
  Future<void> _onWelcome(core.NetWelcome w) async {
    // ignore: avoid_print
    print('[sinhron][net] welcome group=${w.groupIdHex}');
    try {
      final joinedGroupId = await core.syncJoinViaWelcome(welcomeB64: w.welcomeB64);
      // Tech-debt 2.2 — give the new chat our access key. Not awaited from
      // the event loop (a send waits on nothing here, but keep it off).
      unawaited(core.syncShareAccessKey(groupIdsHex: [joinedGroupId]).catchError((_) => 0));
      // ADR-074 — that Welcome used one of this device's KeyPackages: put
      // one back, so the next chat can add it too.
      final base = _httpBaseUrl;
      if (base != null) unawaited(core.syncPublishKeypackage(serverBaseUrl: base).then((_) {}, onError: (Object _) {}));
      // ignore: avoid_print
      print('[sinhron][net] joined via welcome · group=$joinedGroupId');

      // Invited back into a group I was removed from (owner, 2026-10-18):
      // the chat is already here with its name and history — it only
      // needs to stop saying "you're not a member".
      List<ChatPreview> known;
      try {
        known = await _ref.read(chatsProvider.future);
      } catch (_) {
        known = const [];
      }
      // ADR-064 — read the DB too: a device transfer may have just made the
      // row (with its history), and the cached list may not show it yet —
      // re-creating it would wipe its messages.
      var stored = false;
      try {
        stored = (await core.storageChatsList()).any((c) => c.id == joinedGroupId);
      } catch (_) {}
      if (stored || known.any((c) => c.id == joinedGroupId)) {
        _ref.invalidate(groupRoleProvider(joinedGroupId));
        _ref.invalidate(chatMembersProvider(joinedGroupId));
        _ref.invalidate(chatsProvider);
        return;
      }

      await _createChatRow(joinedGroupId);
      _ref.invalidate(chatsProvider);
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][net] sync_join_via_welcome failed: $e');
    }
  }

  /// A local chat row for [groupHex]; its id is the group hex, so the
  /// group's Pushes route here. Someone else started it: a message request
  /// until I accept or write (tech-debt 2.27) — unless it's only me, I was
  /// added back, or [known] (the writer is one of my contacts).
  Future<void> _createChatRow(String groupHex, {bool known = false}) async {
    final l = lookupAppL10n(Locale(currentLanguage));
    final now = DateTime.now();
    // Two people (me + one) → a personal chat: its info screen offers
    // the safety number and blocking, and blocking screens its calls.
    var isGroup = true;
    // ADR-055 — a group of nobody but me came from my own device (my
    // Saved messages, most likely): not a stranger's request.
    var onlyMe = false;
    // ADR-074 — a contact added this phone back into a chat I was in
    // (lost phone, signed in again): mine, not a new request.
    var returning = false;
    // A personal chat knows its person from the start, so "Message" finds
    // it before their profile comes (owner, 2026-11-03: two chats).
    String? peer;
    try {
      final members = await core.syncGroupMembers(groupIdHex: groupHex);
      isGroup = members.length > 2;
      onlyMe = members.length == 1 && members.first == _myIdentityHex;
      final me = (_myIdentityHex ?? '').toLowerCase();
      final others = {for (final m in members) m.toLowerCase()}..remove(me);
      if (members.length == 2 && me.isNotEmpty && others.length == 1) peer = others.single;
      returning = await core.syncGroupAddedBack(groupIdHex: groupHex);
    } catch (_) {}
    try {
      await core.storageChatUpsert(
        id: groupHex,
        // Until their profile names it: a plain "New chat" — it was
        // "Group 3f2a9b1c" even for a personal chat.
        displayName: isGroup ? l.newGroupPlaceholder : l.newChatPlaceholder,
        isGroup: isGroup,
        muted: false,
        pinned: false,
        unreadCount: 0,
        lastMsgPreview: l.netAddedToChat,
        lastMsgTsUnix: now.millisecondsSinceEpoch ~/ 1000,
        lastMsgKind: 'text',
        lastMsgSenderLabel: null,
        lastMsgMine: false,
        createdAtUnix: now.millisecondsSinceEpoch ~/ 1000,
      );
      // A message of mine from another of my devices accepts it too.
      final request = !onlyMe && !returning && !known;
      if (request) await core.storageChatSetRequest(id: groupHex, request: true);
      if (peer != null) {
        await core.storageChatSetPeer(chatId: groupHex, peerId: peer);
        // An accepted chat's person is a contact (as `People.onProfile`
        // did when the row learned them from their profile).
        if (!request) unawaited(_ref.read(peopleProvider).addContact(peer));
      }
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][net] chat row upsert failed: $e');
    }
  }

  /// Route an incoming Push to the right local chat. Reverses the
  /// chatId → group_id_hex mapping by scanning chats. Persists the
  /// remote message + invalidates the relevant providers.
  Future<void> _onPush(core.NetPush p) async {
    lastPushAt = DateTime.now();
    // Never log the body — it's decrypted plaintext (spec §18 #15).
    // ignore: avoid_print
    print(
      '[sinhron][net] push group=${p.groupIdHex} '
      'msg=${p.messageId} seq=${p.sequence} kind=${p.kind}',
    );

    // Rust decoded the ADR-017 envelope; `kind` says what arrived.
    //   text                    → p.text
    //   photo | voice | document → p.mediaJson (+ caption in p.text)
    //   sticker                 → p.mediaJson (ADR-049)
    //   undecrypted             → didn't decrypt, dropped
    //   control                 → an MLS Commit / own echo — nothing to show
    //   history                 → recent messages for our new device (ADR-025)
    //   transfer / device_sync  → from my other device (ADR-064), handled in Rust
    //   unsupported             → newer app version on the other side
    //   invalid                 → malformed envelope, dropped
    String body;
    String kind = 'text';
    String? mediaJson;
    var isAction = false;
    var isHistory = false;
    switch (p.kind) {
      case 'text':
        body = p.text;
        mediaJson = p.mediaJson; // link preview, if any
      case 'photo' || 'voice' || 'document' || 'video' || 'sticker':
        body = p.text;
        kind = p.kind;
        mediaJson = p.mediaJson;
      // ADR-019 — reactions, edits, deletes, receipts, typing.
      // ADR-034 — a group's name.
      case 'reaction' ||
          'edit' ||
          'delete' ||
          'receipt' ||
          'typing' ||
          'timer' ||
          'profile' ||
          'pin' ||
          'screenshot' ||
          'presence' ||
          'group_name' ||
          'leave' ||
          'removed':
        body = '';
        isAction = true;
      // Tech-debt 2.2 — a member's access key; Rust already kept it.
      // A Commit or our own echo isn't a message (it used to be stored as
      // "<binary …>").
      case 'access':
        return;
      // An MLS Commit: a line when it let people in or took them out, or
      // removed me (ADR-035, mls-identity:3).
      case 'control':
        unawaited(_ref.read(messageActionsProvider).onGroupCommit(p.groupIdHex, p.actionJson).catchError((Object _) {}));
        return;
      // ADR-064 — from my other device in my own-devices group (Rust
      // checked that and already applied / kept it).
      case 'device_sync':
        unawaited(_ref.read(deviceSyncProvider).onIncoming(p.actionJson));
        return;
      case 'transfer':
        _ref.read(deviceTransfersProvider.notifier).onTransferMessage(p.actionJson);
        return;
      // ADR-025 — only from ourselves (another of our devices).
      case 'history':
        if (p.senderId == null || p.senderId != _myIdentityHex) return;
        body = '';
        isHistory = true;
      case 'unsupported':
        body = lookupAppL10n(Locale(currentLanguage)).netUnsupportedMessage;
      // Owner, 2026-10-20: a frame that didn't decrypt (a second copy of
      // one already opened, a broken group) showed as a "<binary 574B>"
      // bubble — and a notification. It is dropped (readable bytes too:
      // the plaintext seed chats they were for are gone).
      case 'undecrypted':
        // ignore: avoid_print
        print('[sinhron][net] dropping undecrypted message ${p.messageId} (${p.ciphertext.length} B)');
        return;
      default:
        // ignore: avoid_print
        print('[sinhron][net] dropping ${p.kind} message ${p.messageId}');
        return;
    }

    // Look up the local chat: chatId == group_id_hex (produced by
    // `sync_create_group`).
    var chats = await core.storageChatsList();
    // A former Saved group (folded into the current one) → Saved; a folded
    // personal chat → the one it went into.
    var chatId =
        chats.where((c) => c.id == p.groupIdHex).firstOrNull?.id ??
        await formerSavedRedirect(p.groupIdHex) ??
        await formerPersonalRedirect(p.groupIdHex, chats.map((c) => c.id));
    if (chatId == null) {
      // It decrypted, so I'm in the group — the chat was deleted on this
      // phone (status 211: the message used to be dropped, and it can't be
      // opened twice). It comes back with the message, as in WhatsApp.
      // Changes to a chat that isn't here have nothing to change.
      if (isAction || isHistory) return;
      final contacts = await _ref.read(contactsProvider.future).catchError((Object _) => const <ContactRecord>[]);
      await _createChatRow(p.groupIdHex, known: contacts.any((c) => c.peerId == p.senderId));
      // Back next to a newer chat with the same person (owner, 2026-11-03:
      // two chats): one chat — the message goes where they were folded.
      try {
        await _ref.read(personalChatsProvider).tidy(fresh: p.groupIdHex);
      } catch (_) {}
      chats = await core.storageChatsList();
      chatId = chats.any((c) => c.id == p.groupIdHex)
          ? p.groupIdHex
          : await formerPersonalRedirect(p.groupIdHex, chats.map((c) => c.id)) ?? p.groupIdHex;
      _ref.invalidate(chatsProvider);
    }

    if (isHistory) {
      // History comes only from another device of mine: I already had this
      // chat there, so on this (new) device it isn't a stranger's request
      // (review fix — device linking made every chat a request).
      try {
        await core.storageChatSetRequest(id: chatId, request: false);
      } catch (_) {}
      await _applyHistory(chatId, p.actionJson ?? '[]');
      // ADR-055 — Rust may have just learned this is my Saved messages.
      _ref.invalidate(savedChatIdProvider);
      return;
    }

    // ADR-025 — written by us on another of our devices.
    final mine = p.senderId != null && p.senderId == _myIdentityHex;
    // Tech-debt 2.27 — nothing from a person blocked on this device.
    if (!mine && await _ref.read(peopleProvider).isBlocked(p.senderId)) {
      // ignore: avoid_print
      print('[sinhron][net] dropping ${p.kind} from a blocked sender');
      return;
    }
    final actions = _ref.read(messageActionsProvider);
    if (isAction) {
      // Our other device reading or typing says nothing to this one.
      // Nor does my own profile (owner, 2026-11-01): taken for the other
      // person's, it made me the "peer" of every personal chat — my photo
      // on all of them. My name and photo reach my devices as settings.
      if (mine && (p.kind == 'receipt' || p.kind == 'typing' || p.kind == 'presence' || p.kind == 'profile')) return;
      // ADR-031 — "online" / "last seen", timed by the server.
      if (p.kind == 'presence') {
        _ref
            .read(presenceProvider)
            .onIncoming(chatId, p.senderId, p.actionJson ?? '{}', atUnix: p.deliveredAtUnix.toInt());
        return;
      }
      await actions.onIncomingAction(chatId, p.kind, p.actionJson ?? '{}', p.senderId);
      return;
    }

    // Persist (ours if our other device wrote it). Dedup via storage's
    // PRIMARY KEY: re-receiving the same message_id is silently absorbed.
    final localId = 'remote-${p.messageId}';
    try {
      await _ref
          .read(messageStoreProvider)
          .insert(
            core.NewMessageRow(
              id: localId,
              chatId: chatId,
              // When it was written, not when it reached the server.
              tsUnix: incomingMessageTs(p.messageId, p.deliveredAtUnix),
              body: body,
              kind: kind,
              isMine: mine,
              mediaJson: mediaJson,
              wireId: p.messageId,
              replyJson: p.replyJson,
              senderId: p.senderId,
              // Disappearing: the clock starts when it reaches this phone.
              expireAt: p.expireSecs > 0 ? DateTime.now().millisecondsSinceEpoch ~/ 1000 + p.expireSecs : null,
              // ADR-070 — its formatting (null: an older app's message).
              entitiesJson: p.entitiesJson,
            ),
          );
    } catch (e) {
      // Duplicate (already received) → ignore silently. Anything else
      // gets logged.
      if (!e.toString().contains('UNIQUE')) {
        // ignore: avoid_print
        print('[sinhron][net] storageMessageAppend failed: $e');
      }
      return;
    }
    if (mine) {
      // No unread badge, receipt, sound or banner for our own words.
      try {
        await core.storageChatMarkRead(id: chatId);
      } catch (_) {}
      markChatChangedFromRef(_ref, chatId);
      _ref.read(chatsRefresherProvider).schedule();
      return;
    }
    // The chat on screen gets no unread badge (UI backlog §2).
    final mentionsMe = mentionsKey(body, _myIdentityHex);
    if (_ref.read(openChatProvider) == chatId) {
      try {
        await core.storageChatMarkRead(id: chatId);
      } catch (_) {}
    } else if (mentionsMe) {
      // Tech-debt 2.21 — "@" in the list until read.
      try {
        await core.storageChatSetMentioned(id: chatId);
      } catch (_) {}
    }
    markChatChangedFromRef(_ref, chatId);
    _ref.read(chatsRefresherProvider).schedule();
    // ✓✓ delivered for the sender (and read, if this chat is open).
    unawaited(actions.afterIncomingMessage(chatId));
    // Quiet "received" blip when you're looking at that chat; a banner
    // when it's another one (UI backlog §8 item 57).
    if (_ref.read(openChatProvider) == chatId) {
      unawaited(_ref.read(uiSoundsProvider).play(UiSound.received));
    } else {
      final chat = chats.firstWhere((c) => c.id == chatId);
      final names = _ref.read(peerNamesProvider).value ?? const <String, String>{};
      maybeShowBanner(
        _ref,
        chatId: chatId,
        // A personal chat: by my own name for its person, if I gave one.
        title: (chat.isGroup ? null : _ref.read(contactAliasesProvider).value?[chat.peerId?.toLowerCase()]) ??
            chat.displayName,
        body: mentionsToDisplay(body, (k) => k == _myIdentityHex ? '' : displayNameOf(k, names)),
        kind: kind,
        group: chat.isGroup,
        // ADR-066 — who wrote, in a group's system notification.
        sender: chat.isGroup && (p.senderId ?? '').isNotEmpty ? displayNameOf(p.senderId!, names) : null,
        // A mention of me gets through a muted chat (as in Telegram).
        muted: chat.muted && !mentionsMe,
        archived: chat.archived,
      );
    }
  }

  /// ADR-025 — a chat's recent messages from our other device, for this
  /// newly added one (MLS can't decrypt older messages). Applied only
  /// while the chat has no messages here yet, so a device that has its
  /// own copy is never touched.
  Future<void> _applyHistory(String chatId, String itemsJson) async {
    final existing = await core.storageMessagesList(chatId: chatId, limit: 50);
    if (existing.any((m) => m.kind != 'system')) return;
    final List<dynamic> items;
    try {
      items = jsonDecode(itemsJson) as List<dynamic>;
    } catch (_) {
      return;
    }
    final store = _ref.read(messageStoreProvider);
    for (final raw in items) {
      final m = raw as Map<String, dynamic>;
      final wireId = m['wire_id'] as String;
      final sender = m['sender'] as String;
      final media = m['media_json'] as String;
      try {
        await store.insert(
          core.NewMessageRow(
            id: 'remote-$wireId',
            chatId: chatId,
            tsUnix: (m['ts'] as num).toInt(),
            body: m['text'] as String,
            kind: m['kind'] as String,
            isMine: sender == _myIdentityHex,
            mediaJson: media.isEmpty ? null : media,
            wireId: wireId,
            senderId: sender,
            entitiesJson: m['entities'] is List ? jsonEncode(m['entities']) : null,
          ),
        );
      } catch (_) {
        // Already there (same wire id) — fine.
      }
    }
    // ignore: avoid_print
    print('[sinhron][devices] history: ${items.length} messages for $chatId');
    markChatChangedFromRef(_ref, chatId);
    _ref.read(chatsRefresherProvider).schedule();
  }
}

/// Live connection state (tech-debt 2.4) — the Server row in Settings
/// shows it and offers "Reconnect".
class NetStatusNotifier extends Notifier<NetStatus> {
  @override
  NetStatus build() => NetStatus.idle;

  void set(NetStatus s) => state = s;
}

final netStatusProvider = NotifierProvider<NetStatusNotifier, NetStatus>(NetStatusNotifier.new);

/// The server turned this device away because another of my devices
/// removed it (ws 403 "device disconnected"; owner, 2026-11-01).
bool isDeviceRemovedReason(String? reason) =>
    reason != null && reason.contains('code 403') && reason.contains('device disconnected');

/// True once the server said this device was removed — AppRoot then shows
/// [DeviceRemovedScreen] instead of the chats.
class DeviceRemovedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool v) => state = v;
}

final deviceRemovedProvider = NotifierProvider<DeviceRemovedNotifier, bool>(DeviceRemovedNotifier.new);

/// Provider — single instance per app, lives for the ProviderScope.
final netServiceProvider = Provider<NetService>((ref) => NetService(ref));
