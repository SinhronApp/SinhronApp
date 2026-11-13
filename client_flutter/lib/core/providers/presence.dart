// "Online" / "last seen" — ADR-031.
//
// • Off by default. When the owner turns it on, only contacts see it:
//   people with a personal chat that isn't an unanswered request and isn't
//   blocked. Groups never carry it.
// • Travels end-to-end encrypted as a `presence` action inside each personal
//   chat (like "typing…"), so the server is not told who may see whom.
// • While the app is on screen it says "online" on start and every
//   [Presence.heartbeat]; going to the background says "left". A receiver
//   treats "online" as true for [PeerPresence.onlineFor] after the server
//   time of that message, so a killed app turns into "last seen" by itself.
// • Turning it off sends `hidden`: contacts forget when they last saw me.
//
// Bug 2026-10-19 (owner: "says the other person is online though they left
// long ago"):
// • The chat header, chat info and profile watched `select((m) => m[peer])`:
//   when "online" ran out the map was re-emitted with the same object, so
//   they never rebuilt — "online" stayed while the chat was open. Screens now
//   select [presenceShown] (a value) and the map re-emits whenever a label
//   changes ([nextPresenceChange]): online running out, "N minutes ago".
// • "Online" lasted 6 min after a 5-min heartbeat; now 55 s after a 25-s one.
// • iPhone closes the connection the moment the app leaves the screen
//   (background_connection.dart): "left" lost the race and never went. The
//   close now waits for it ([Presence.offline], sent to all contacts at once).
// • A start with no screen (Android "always connected", a push or a call
//   waking the app) said "online" and repeated it: only `resumed` counts now.
// • A receiver's clock running behind the server's no longer stretches it.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/chat_list/chat_data.dart' show ChatPreview;
import '../../l10n/l10n.dart';
import 'chat_providers.dart';
import 'message_actions.dart' show messageSenderProvider, newWireId;
import 'people.dart' show isBlockedChat;
import 'settings_providers.dart';

/// Show my "online" / "last seen" to my contacts. Off by default.
final showOnlineProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('show_online', false));

/// What I know about one contact.
class PresenceSeen {
  const PresenceSeen({required this.at, required this.online});

  /// Server time of their last presence message.
  final DateTime at;

  /// That message said "online".
  final bool online;

  Map<String, Object?> toJson() => {'at': at.millisecondsSinceEpoch ~/ 1000, 'on': online};

  static PresenceSeen? fromJson(Object? v) {
    if (v is! Map) return null;
    final at = (v['at'] as num?)?.toInt();
    if (at == null || at <= 0) return null;
    return PresenceSeen(at: DateTime.fromMillisecondsSinceEpoch(at * 1000), online: v['on'] == true);
  }
}

/// identity key (hex) → when that contact was last seen. Kept in settings so
/// "last seen" survives a restart.
class PeerPresence extends Notifier<Map<String, PresenceSeen>> {
  /// "Online" holds this long after the message: two heartbeats and slack,
  /// so one late heartbeat doesn't blink, and someone who left without a
  /// "left" turns into "last seen" within a minute.
  static const onlineFor = Duration(seconds: 55);
  static const _key = 'presence_seen';

  Timer? _save;
  Timer? _tick;

  @override
  Map<String, PresenceSeen> build() {
    ref.onDispose(() {
      _save?.cancel();
      _tick?.cancel();
    });
    unawaited(_load());
    return const {};
  }

  Future<void> _load() async {
    try {
      final raw = await ref.read(settingsStoreProvider).get(_key);
      if (raw == null || raw.isEmpty || !ref.mounted) return;
      final m = jsonDecode(raw) as Map<String, Object?>;
      final loaded = <String, PresenceSeen>{
        for (final e in m.entries) e.key: ?PresenceSeen.fromJson(e.value),
      };
      // Anything that arrived while loading wins.
      state = {...loaded, ...state};
      _scheduleTick();
    } catch (_) {
      // Storage not open (onboarding, tests) — start empty.
    }
  }

  /// A contact's presence message, stamped with the server's time. A time
  /// ahead of this phone's clock (it runs behind) counts as now — otherwise
  /// "online" would last that much longer.
  void apply(String peerId, {required bool online, required bool hidden, required DateTime at, DateTime? now}) {
    if (peerId.isEmpty) return;
    final t = now ?? DateTime.now();
    if (at.isAfter(t)) at = t;
    final next = {...state};
    if (hidden) {
      if (next.remove(peerId) == null) return;
    } else {
      final old = next[peerId];
      if (old != null && old.at.isAfter(at)) return; // older message (Resume)
      next[peerId] = PresenceSeen(at: at, online: online);
    }
    state = next;
    _scheduleTick();
    _save?.cancel();
    _save = Timer(const Duration(seconds: 2), _persist);
  }

  Future<void> _persist() async {
    try {
      await ref
          .read(settingsStoreProvider)
          .set(_key, jsonEncode({for (final e in state.entries) e.key: e.value.toJson()}));
    } catch (_) {}
  }

  /// Re-emit the map when the next label changes, so watchers redraw.
  void _scheduleTick() {
    _tick?.cancel();
    final t = DateTime.now();
    final next = nextPresenceChange(state.values, t);
    if (next == null) return;
    _tick = Timer(next.difference(t) + const Duration(milliseconds: 500), () {
      if (!ref.mounted) return;
      state = {...state};
      _scheduleTick();
    });
  }
}

/// When some label next changes: an "online" running out, or "last seen N
/// minutes ago" becoming N+1 (within the hour). Null — nothing will change.
DateTime? nextPresenceChange(Iterable<PresenceSeen> all, DateTime now) {
  DateTime? soonest;
  void take(DateTime d) {
    if (d.isAfter(now) && (soonest == null || d.isBefore(soonest!))) soonest = d;
  }

  for (final s in all) {
    if (isOnlineNow(s, now: now)) {
      take(s.at.add(PeerPresence.onlineFor));
      continue;
    }
    final seen = lastSeenAt(s, now: now);
    final ago = now.difference(seen);
    if (ago < const Duration(hours: 1)) take(seen.add(Duration(minutes: ago.inMinutes + 1)));
  }
  return soonest;
}

final peerPresenceProvider = NotifierProvider<PeerPresence, Map<String, PresenceSeen>>(PeerPresence.new);

/// Is [s] "online" right now?
bool isOnlineNow(PresenceSeen? s, {DateTime? now}) =>
    s != null && s.online && (now ?? DateTime.now()).difference(s.at) < PeerPresence.onlineFor;

/// When they were last seen: now while "online"; otherwise their last
/// message — "left", or the last heartbeat of an app that went quiet.
DateTime lastSeenAt(PresenceSeen s, {DateTime? now}) {
  final t = now ?? DateTime.now();
  return isOnlineNow(s, now: t) ? t : s.at;
}

/// "online" / "last seen 5 minutes ago" / … — or '' when nothing is known.
String presenceLabel(AppL10n l10n, PresenceSeen? s, {DateTime? now}) {
  if (s == null) return '';
  final t = now ?? DateTime.now();
  if (isOnlineNow(s, now: t)) return l10n.online;
  final seen = lastSeenAt(s, now: t).toLocal();
  final ago = t.difference(seen);
  if (ago < const Duration(minutes: 1)) return l10n.lastSeenJustNow;
  if (ago < const Duration(hours: 1)) return l10n.lastSeenMinutes(ago.inMinutes);
  final local = t.toLocal();
  final hm = '${seen.hour.toString().padLeft(2, '0')}:${seen.minute.toString().padLeft(2, '0')}';
  final today = DateTime(local.year, local.month, local.day);
  final day = DateTime(seen.year, seen.month, seen.day);
  if (day == today) return l10n.lastSeenToday(hm);
  if (day == today.subtract(const Duration(days: 1))) return l10n.lastSeenYesterday(hm);
  final date = '${seen.day.toString().padLeft(2, '0')}.${seen.month.toString().padLeft(2, '0')}.${seen.year}';
  return l10n.lastSeenDate(date);
}

/// What a screen shows for one contact. A value (records compare by
/// fields), so `ref.watch(peerPresenceProvider.select(...))` redraws when
/// "online" runs out — the same [PresenceSeen] would look unchanged.
typedef PresenceShown = ({bool known, bool online, String label});

PresenceShown presenceShown(AppL10n l10n, PresenceSeen? s, {DateTime? now}) {
  final t = now ?? DateTime.now();
  return (known: s != null, online: isOnlineNow(s, now: t), label: presenceLabel(l10n, s, now: t));
}

extension IfEmpty on String {
  /// This string, or [other] when it is empty.
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Is this chat a contact's personal chat — the only place presence goes?
bool isContactChat(Ref ref, ChatPreview c) =>
    !c.group && !c.saved && !c.request && c.id != null && looksLikeMlsGroupId(c.id!) && !isBlockedChat(ref, c.id!);

/// Sends my presence and takes in my contacts'.
class Presence {
  Presence(this._ref, {Future<void> Function(String chatId, Map<String, Object?> action)? send})
    : _send = send ?? ((chatId, action) => _ref.read(messageSenderProvider).sendAction(chatId, newWireId(), action));
  final Ref _ref;
  final Future<void> Function(String chatId, Map<String, Object?> action) _send;

  /// How often "online" is repeated while the app is open.
  static const heartbeat = Duration(seconds: 25);

  bool _foreground = false;
  bool _saidOnline = false;
  Timer? _beat;
  Future<void>? _leaving;

  Future<bool> _enabled() async {
    try {
      return await _ref.read(showOnlineProvider.future);
    } catch (_) {
      return _ref.read(showOnlineProvider).value ?? false;
    }
  }

  Future<List<String>> _contactChats() async {
    List<ChatPreview> chats;
    try {
      chats = await _ref.read(chatsProvider.future);
    } catch (_) {
      chats = _ref.read(chatsProvider).value ?? const [];
    }
    return [
      for (final c in chats)
        if (isContactChat(_ref, c)) c.id!,
    ];
  }

  /// To every contact at once: "left" has seconds before iOS freezes the
  /// app.
  Future<void> _toContacts(Map<String, Object?> action) async {
    await Future.wait([
      for (final id in await _contactChats())
        _send(id, action).catchError((Object _) {
          // Offline: the next heartbeat or resume says it again.
        }),
    ]);
  }

  /// The app came to the foreground (or reconnected while in it).
  Future<void> online() async {
    _foreground = true;
    _beat ??= Timer.periodic(heartbeat, (_) => unawaited(_say(true)));
    await _say(true);
  }

  /// The app went to the background. Said once: a second call (`hidden`
  /// then `paused`, or the connection about to close) waits for the same
  /// "left".
  Future<void> offline() {
    _foreground = false;
    _beat?.cancel();
    _beat = null;
    if (_leaving != null) return _leaving!;
    if (!_saidOnline) return Future.value();
    _saidOnline = false; // before the send: coming back meanwhile says "online" again
    return _leaving = _say(false).whenComplete(() => _leaving = null);
  }

  /// The server connection came back.
  Future<void> reconnected() async {
    if (_foreground) await _say(true);
  }

  Future<void> _say(bool on) async {
    if (on && !_foreground) return; // a heartbeat that fired as the app left
    if (!await _enabled() || (on && !_foreground)) return;
    await _toContacts({'t': 'presence', 'online': on});
    if (on) _saidOnline = true;
  }

  /// The switch changed: on → say "online" now (if open); off → contacts
  /// forget when they last saw me.
  Future<void> settingChanged(bool on) async {
    if (on) {
      if (_foreground) await _say(true);
      return;
    }
    _saidOnline = false;
    await _toContacts({'t': 'presence', 'hidden': true});
  }

  /// A presence action from [senderId] in [chatId]; [atUnix] is the server
  /// time of the message. Only a contact's own personal chat counts.
  void onIncoming(String chatId, String? senderId, String actionJson, {required int atUnix}) {
    final peer = senderId ?? '';
    if (peer.isEmpty) return;
    final chat = (_ref.read(chatsProvider).value ?? const <ChatPreview>[]).where((c) => c.id == chatId).firstOrNull;
    if (chat == null || !isContactChat(_ref, chat)) return;
    if (chat.peerId != null && chat.peerId != peer) return; // not the other person
    Map<String, Object?> a;
    try {
      a = jsonDecode(actionJson) as Map<String, Object?>;
    } catch (_) {
      return;
    }
    _ref
        .read(peerPresenceProvider.notifier)
        .apply(
          peer,
          online: a['online'] == true,
          hidden: a['hidden'] == true,
          at: DateTime.fromMillisecondsSinceEpoch(atUnix * 1000),
        );
  }

  void dispose() => _beat?.cancel();
}

final presenceProvider = Provider<Presence>((ref) {
  final p = Presence(ref);
  ref.onDispose(p.dispose);
  return p;
});

/// Says "online" while the app is open and "left" when it goes away.
class PresenceKeeper extends ConsumerStatefulWidget {
  const PresenceKeeper({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<PresenceKeeper> createState() => _PresenceKeeperState();
}

class _PresenceKeeperState extends ConsumerState<PresenceKeeper> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Only on screen: a start without one (Android "always connected", a
    // push or a call waking the app) has no state yet — `resumed` comes
    // when the screen does.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      Future.microtask(() => ref.read(presenceProvider).online().catchError((Object _) {}));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final p = ref.read(presenceProvider);
    switch (state) {
      case AppLifecycleState.resumed:
        p.online().catchError((Object _) {});
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        p.offline().catchError((Object _) {});
      case AppLifecycleState.inactive:
        break; // Control Centre, a call banner — still here
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
