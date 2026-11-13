// Haptics map — UI backlog §4 item 34. Every tactile cue in the app goes
// through here, so the vocabulary stays consistent and can be switched
// off in Settings.

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/settings_providers.dart';

enum Haptic {
  /// Picking from a set (tab, reaction, folder).
  selection,

  /// A swipe crossed its action threshold (reply, swipe actions).
  threshold,

  /// Long-press menus opening.
  menu,

  /// Something worked (message sent, saved).
  success,

  /// Something failed / was refused.
  error,

  /// Voice recording started / locked.
  record,
}

/// For design-system widgets that don't use Riverpod (tab bar, pills,
/// swipe rows…). [enabled] mirrors the Settings switch — the app root
/// keeps it in sync with [hapticsEnabledProvider].
abstract final class DsHaptics {
  static bool enabled = true;

  static Future<void> play(Haptic h) => enabled ? _play(h) : Future.value();
}

Future<void> _play(Haptic h) async {
  try {
    switch (h) {
      case Haptic.selection:
        await HapticFeedback.selectionClick();
      case Haptic.threshold || Haptic.record:
        await HapticFeedback.mediumImpact();
      case Haptic.menu:
        await HapticFeedback.heavyImpact();
      case Haptic.success:
        await HapticFeedback.lightImpact();
      case Haptic.error:
        await HapticFeedback.vibrate();
    }
  } catch (_) {
    // No haptics engine (desktop / tests) — silent.
  }
}

/// Plays a [Haptic]. Overridable in tests (records instead of playing).
class Haptics {
  Haptics(this._enabled);
  final bool Function() _enabled;

  Future<void> play(Haptic h) => _enabled() ? _play(h) : Future.value();
}

/// Settings → "Vibration" (on by default).
final hapticsEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('haptics', true));

final hapticsProvider = Provider<Haptics>(
  (ref) => Haptics(() => ref.read(hapticsEnabledProvider).value ?? true),
);
