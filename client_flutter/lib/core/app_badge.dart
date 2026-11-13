// App icon badge — UI backlog §8 item 58.
//
// The number on the Sinhron icon = chats waiting for you (same rule as
// the Chats tab: muted and archived don't count). Off until you turn it
// on in Settings → Sounds & Vibration, because iOS asks for permission
// first. Set from the running app; with push (tech-debt, needs an Apple
// Developer account) the server-side count will take over while the
// app is closed.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/core_providers.dart';
import 'providers/settings_providers.dart';

/// Native side: `ios/Runner/AppDelegate.swift` (channel `dev.sinhron/badge`).
abstract class AppBadge {
  /// Asks iOS for badge permission. True when granted.
  Future<bool> requestPermission();

  Future<void> set(int count);
}

class ChannelAppBadge implements AppBadge {
  static const _channel = MethodChannel('dev.sinhron/badge');

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> set(int count) async {
    try {
      await _channel.invokeMethod<void>('set', count);
    } on MissingPluginException {
      // Desktop / tests — no icon badge.
    } on PlatformException {
      // Permission withdrawn in iOS Settings — nothing to do.
    }
  }
}

final appBadgeProvider = Provider<AppBadge>((ref) => ChannelAppBadge());

final iconBadgeEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('icon_badge', false));

/// Turn the icon badge on (asks iOS first) or off. Returns the new value.
Future<bool> setIconBadge(WidgetRef ref, bool on) async {
  final granted = on && await ref.read(appBadgeProvider).requestPermission();
  await ref.read(iconBadgeEnabledProvider.notifier).save(granted);
  return granted;
}

/// Keeps the icon number in step with the unread count. Mounted once at
/// the app root; renders nothing.
class AppBadgeSync extends ConsumerStatefulWidget {
  const AppBadgeSync({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<AppBadgeSync> createState() => _AppBadgeSyncState();
}

class _AppBadgeSyncState extends ConsumerState<AppBadgeSync> {
  int? _last;

  @override
  Widget build(BuildContext context) {
    final on = ref.watch(iconBadgeEnabledProvider).value;
    final count = ref.watch(unreadChatsCountProvider);
    // Unknown yet (setting loading) → leave the icon alone.
    if (on != null) {
      final want = on ? count : 0;
      if (want != _last) {
        _last = want;
        ref.read(appBadgeProvider).set(want);
      }
    }
    return widget.child;
  }
}
