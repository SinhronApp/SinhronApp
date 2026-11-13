// CD2 — call permissions service (camera + microphone + Bluetooth).
//
// Wraps `permission_handler` with a Sinhron-flavored API:
//   • [CallPermission] enum — the three states UI cares about.
//   • [CallPermissionsService] — request + check methods.
//   • Riverpod-friendly: see [callPermissionsProvider] in
//     core_providers.dart.
//
// Why a wrapper crate rather than direct permission_handler calls?
//   1. UI never sees the raw `PermissionStatus` enum (which has 5
//      values, of which 2 we never reach on iOS) — we narrow it.
//   2. Tests stub a single small surface, not the entire plugin.
//   3. Future swap: if we ever move to a custom platform channel for
//      Bluetooth, only this file changes.
//
// iOS-side requirements live in `ios/Runner/Info.plist`:
//   NSCameraUsageDescription, NSMicrophoneUsageDescription,
//   NSBluetoothAlwaysUsageDescription. Without those strings iOS
//   kills the app on first request.

import 'package:permission_handler/permission_handler.dart';

/// Possible outcomes of a permission request. UI flow:
///   • `granted` — proceed with call setup.
///   • `denied` — show "Permission needed" rationale screen + retry button.
///   • `permanentlyDenied` — show "Open Settings" button (further requests
///     will be auto-denied without prompting; only the system Settings
///     can re-enable).
enum CallPermission {
  granted,
  denied,
  permanentlyDenied,
}

/// Maps `permission_handler`'s broader status enum onto our narrower
/// 3-state model. The `restricted` (parental controls) and `provisional`
/// (iOS push only) states aren't applicable to camera/mic — they map
/// to `permanentlyDenied` so UI shows the Settings escape hatch.
CallPermission _fromStatus(PermissionStatus s) {
  if (s.isGranted || s.isLimited) return CallPermission.granted;
  if (s.isPermanentlyDenied || s.isRestricted) {
    return CallPermission.permanentlyDenied;
  }
  return CallPermission.denied;
}

/// Service-style facade. Stateless — safe to instantiate per call site
/// or pull from a Riverpod provider. Default-constructible.
class CallPermissionsService {
  const CallPermissionsService();

  /// Ask the OS to prompt the user for microphone access if not already
  /// decided. Returns immediately on subsequent calls after the first
  /// decision (no double-prompt). UI should call this when the user
  /// taps "Call" — NOT at app boot (would surprise them).
  Future<CallPermission> requestMic() async {
    final s = await Permission.microphone.request();
    return _fromStatus(s);
  }

  /// Same but for the camera. UI calls this when the user picks
  /// "Video call" specifically. Audio-only calls SHOULD NOT trigger
  /// the camera prompt.
  Future<CallPermission> requestCamera() async {
    final s = await Permission.camera.request();
    return _fromStatus(s);
  }

  /// Request both mic + camera in sequence. Returns whichever is the
  /// "worst" status (granted-then-denied → denied; both granted →
  /// granted; either permanent → permanentlyDenied). Useful for
  /// video-call entry where both are needed.
  Future<CallPermission> requestMicAndCamera() async {
    final mic = await requestMic();
    final cam = await requestCamera();
    return _worstOf(mic, cam);
  }

  /// Check current status WITHOUT prompting. Useful for UI gating:
  /// show "Call" button enabled iff mic is granted.
  Future<CallPermission> checkMic() async {
    final s = await Permission.microphone.status;
    return _fromStatus(s);
  }

  Future<CallPermission> checkCamera() async {
    final s = await Permission.camera.status;
    return _fromStatus(s);
  }

  /// Open the system Settings app at this app's permissions screen.
  /// Returns `true` if the navigation succeeded. Used after
  /// `permanentlyDenied` — the only path back to enabled is manual
  /// user action in Settings.
  Future<bool> openSettings() {
    return openAppSettings();
  }

  static CallPermission _worstOf(CallPermission a, CallPermission b) {
    // Ordering: granted (best) → denied → permanentlyDenied (worst).
    int rank(CallPermission p) {
      switch (p) {
        case CallPermission.granted:
          return 0;
        case CallPermission.denied:
          return 1;
        case CallPermission.permanentlyDenied:
          return 2;
      }
    }
    return rank(a) >= rank(b) ? a : b;
  }
}
