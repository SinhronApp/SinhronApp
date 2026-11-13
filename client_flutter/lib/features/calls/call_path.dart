// ADR-042 — the call's network path, and when to fall back to the reserve.
//
// A call normally lets WebRTC pick the best path: UDP straight to the SFU,
// then TCP, then our TURN. On a network that lets the first packets through
// and then stalls (owner's friend in Russia, 2026-10-16: the call "connected",
// then dropped every ~10 s, 28 rejoins, no sound) WebRTC keeps choosing the
// path that looked fine. The reserve forces media through our TURN over TLS
// on 443 (`turns:` URLs from `/v1/call/turn`, Caddy layer4 → coturn,
// ADR-016): from outside it's one TLS connection to an HTTPS port; sound and
// video stay end-to-end encrypted inside (SFrame).
//
// When the reserve is used:
//   - Settings → "Calls through the reserve path" is on (always);
//   - the direct path failed to connect — retry once through the reserve;
//   - the link keeps dropping (LiveKit "reconnecting" twice within 30 s, or
//     one that lasts 8 s) — rejoin through the reserve;
//   - the reserve was needed in the last 24 h — start with it (the network
//     that broke a call is likely the same one next time).
// A VPN alone doesn't (owner, 2026-10-20 — see [initialCallPath]).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/settings_providers.dart';

/// Settings → Network: every call through the reserve (for networks known
/// to break calls, and to test the reserve).
final callsReserveAlwaysProvider = AsyncNotifierProvider<BoolSetting, bool>(
  () => BoolSetting('calls_reserve_always', false),
);

/// When a call last needed the reserve (ISO time, '' = never).
final callsReserveNeededAtProvider = AsyncNotifierProvider<StringSetting, String>(
  () => StringSetting('calls_reserve_needed_at', ''),
);

/// Which way the call's media goes.
enum CallPath {
  /// WebRTC picks (UDP / TCP / TURN).
  direct,

  /// Only our TURN over TLS (443).
  reserve,
}

/// The TURN URLs that make up the reserve: `turns:` (TLS) only.
List<String> reserveTurnUrls(List<String> urls) => urls.where((u) => u.startsWith('turns:')).toList();

/// How long a call that needed the reserve keeps the next calls on it.
const kReserveRemembered = Duration(hours: 24);

/// The path a new call starts with. A VPN no longer forces the reserve
/// (status 183 did): the direct path offers the reserve's TLS relay too and
/// ICE takes whichever answers first, so a VPN that passes UDP connects in
/// ~4 s instead of ~8 s on the relay (owner, 2026-10-20: "с VPN соединяет
/// намного дольше"); a VPN that breaks the direct media is caught by
/// [PathChurn] / the failed-join retry and moves to the reserve. (In 183
/// the direct attempt timed out under a VPN because the relay itself was
/// cut by Caddy's 3 s TLS wait — fixed on the server the same day.)
CallPath initialCallPath({required bool alwaysReserve, DateTime? reserveNeededAt, required DateTime now}) {
  if (alwaysReserve) return CallPath.reserve;
  if (reserveNeededAt != null && now.difference(reserveNeededAt) < kReserveRemembered) return CallPath.reserve;
  return CallPath.direct;
}

/// Watches LiveKit's "reconnecting" reports on the direct path and says
/// when to give up on it.
class PathChurn {
  PathChurn({this.window = const Duration(seconds: 30), this.longStall = const Duration(seconds: 8)});

  /// Two drops within this → the path is bad.
  final Duration window;

  /// One drop that lasts this long → the path is bad (the caller arms a
  /// timer for it and asks [stalled]).
  final Duration longStall;

  final _drops = <DateTime>[];
  DateTime? _stallSince;

  /// LiveKit reports "reconnecting". True when it's time for the reserve.
  bool dropped(DateTime now) {
    _drops.removeWhere((t) => now.difference(t) > window);
    _drops.add(now);
    _stallSince ??= now;
    return _drops.length >= 2;
  }

  /// LiveKit recovered.
  void recovered() => _stallSince = null;

  /// Still reconnecting since the first report, for [longStall] or more.
  bool stalled(DateTime now) => _stallSince != null && now.difference(_stallSince!) >= longStall;
}
