// ADR-057 — "Will calls reach me?" on Android, in plain words (a person
// must not need to understand push): Settings → Sounds & vibration
// says yes (and how: Google push, ntfy, "always connected") or no — and
// lists what to tap to fix it. Also the battery: on first run the system
// "don't optimise battery for Sinhron?" question, once; on a Samsung first a
// note with a button to "Never sleeping apps" (`Battery.kt`).

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/settings_providers.dart';
import 'push.dart';
import 'push_server.dart';

/// The native side (`Battery.kt`, channel `dev.sinhron/battery`; faked in
/// tests).
class BatteryPlatform {
  const BatteryPlatform();
  static const _channel = MethodChannel('dev.sinhron/battery');

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// (battery optimisation off for Sinhron, a Samsung).
  Future<({bool exempt, bool samsung})> status() async {
    final m = (await _call<Map<Object?, Object?>>('status')) ?? const {};
    return (exempt: m['exempt'] == true, samsung: m['samsung'] == true);
  }

  /// The system question (and on a Samsung the note first). True when it
  /// could be asked (a screen is there) or nothing needs asking.
  Future<bool> askExempt({bool samsungHint = false}) async =>
      await _call<bool>('askExempt', {'samsungHint': samsungHint}) ?? false;

  /// Samsung's "Never sleeping apps" (or the nearest battery screen).
  Future<void> openSamsung() => _call<bool>('openSamsung');

  /// The app's own settings page.
  Future<void> openApp() => _call<bool>('openApp');
}

final batteryPlatformProvider = Provider<BatteryPlatform>((ref) => const BatteryPlatform());

/// Asked the battery question once already.
final batteryAskedProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('android_battery_asked', false));

/// ADR-057 — first run (Android, once there is an account): the battery
/// question, once. Not from a screen-less start (no window to ask in).
Future<void> askBatteryOnce(Ref ref) async {
  if (!ref.read(isAndroidProvider) || await ref.read(batteryAskedProvider.future)) return;
  final battery = ref.read(batteryPlatformProvider);
  final s = await battery.status();
  if (s.exempt && !s.samsung) {
    await ref.read(batteryAskedProvider.notifier).save(true);
    return;
  }
  if (await battery.askExempt(samsungHint: true)) await ref.read(batteryAskedProvider.notifier).save(true);
}

/// How messages and calls wake this phone.
enum ReachVia { google, ntfy, alwaysConnected, none }

/// What to tap to make calls reach the phone.
enum ReachFix { allowNotifications, turnOnCalls, turnOnAlwaysConnected, allowBackground }

class CallReach {
  const CallReach({required this.via, required this.fixes, required this.samsung});
  final ReachVia via;
  final List<ReachFix> fixes;

  /// Show the Samsung "Never sleeping apps" button (always, on a Samsung:
  /// its sleeping lists can't be read by apps).
  final bool samsung;

  bool get ok => fixes.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is CallReach && other.via == via && other.samsung == samsung && _sameFixes(other.fixes);

  bool _sameFixes(List<ReachFix> o) => o.length == fixes.length && o.every(fixes.contains);

  @override
  int get hashCode => Object.hash(via, samsung, Object.hashAll(fixes));

  @override
  String toString() => 'CallReach($via, $fixes, samsung: $samsung)';
}

/// The verdict from what the phone says. Google push needs no battery
/// exemption (Android lets its high-priority pushes through); ntfy and
/// "always connected" do.
CallReach callReachFor({
  required String status,
  required bool callsOn,
  required String? route,
  required bool ntfyOk,
  required bool keepConnected,
  required bool exempt,
  required bool samsung,
}) {
  final via = switch (route) {
    final r? when r.startsWith('fcm:') => ReachVia.google,
    final r? when r.startsWith('https://') && ntfyOk => ReachVia.ntfy,
    _ when keepConnected => ReachVia.alwaysConnected,
    _ => ReachVia.none,
  };
  return CallReach(
    via: via,
    samsung: samsung,
    fixes: [
      if (status == 'denied' || status == 'notDetermined') ReachFix.allowNotifications,
      if (!callsOn) ReachFix.turnOnCalls,
      if (via == ReachVia.none) ReachFix.turnOnAlwaysConnected,
      if (!exempt && (via == ReachVia.ntfy || via == ReachVia.alwaysConnected)) ReachFix.allowBackground,
    ],
  );
}

/// This phone's verdict (Android only; re-read when the screen opens or
/// the app comes back).
final callReachProvider = FutureProvider.autoDispose<CallReach?>((ref) async {
  if (!ref.read(isAndroidProvider)) return null;
  final platform = ref.read(pushPlatformProvider);
  final status = await platform.status();
  final route = (await platform.lastVoipToken())?.$1;
  final hint = await ref.watch(ntfyHintProvider.future);
  final battery = await ref.read(batteryPlatformProvider).status();
  return callReachFor(
    status: status,
    callsOn: await ref.watch(incomingCallsProvider.future),
    route: route,
    ntfyOk: hint == null,
    keepConnected: await ref.watch(keepConnectedProvider.future),
    exempt: battery.exempt,
    samsung: battery.samsung,
  );
});
