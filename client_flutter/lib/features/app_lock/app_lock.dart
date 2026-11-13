// App lock and app-switcher privacy — UI backlog §6 items 47-48.
//
//   • App Lock (off by default): Face ID / Touch ID, falling back to the
//     device passcode. Locks on launch and after being in the
//     background longer than the chosen timeout.
//   • Hide in app switcher (on by default): while the app is inactive
//     (switcher, Control Centre, incoming call) a blurred cover hides
//     the chat contents from the system snapshot. Android takes that
//     snapshot before the cover is drawn (audit storage-devices:19), so
//     with App Lock on it also gets no Recents picture at all
//     (`hideFromRecents`, screen_privacy.dart).
//
// The lock is a cover over the whole app, not a separate route — so a
// deep screen comes back exactly as it was after unlocking.

import 'dart:ui' show ImageFilter;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/theme/motion.dart';
import '../../app/theme/tokens.dart';
import '../../core/account_access.dart';
import '../../core/app_notice.dart';
import '../../core/haptics.dart';
import '../../core/providers/settings_providers.dart';
import '../../core/screen_privacy.dart';
import '../../widgets/sinhron_mark.dart';
import '../../l10n/l10n.dart';

/// Biometric / passcode check. Faked in tests.
abstract class AppAuthenticator {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

/// The system says it has nothing to ask with (no screen lock, nothing
/// enrolled) — not a refusal by the person. Not 'NotAvailable': on iOS the
/// plugin gives that for any other failure (a failed or cancelled check).
bool nothingToAskWith(Object error) =>
    error is PlatformException && const {'NotEnrolled', 'PasscodeNotSet'}.contains(error.code);

class LocalAppAuthenticator implements AppAuthenticator {
  final _auth = LocalAuthentication();
  bool _nothingToAskWith = false;

  @override
  Future<bool> available() async {
    if (_nothingToAskWith) return false;
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    _nothingToAskWith = false;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(stickyAuth: true, biometricOnly: false, useErrorDialogs: false),
      );
    } catch (e) {
      _nothingToAskWith = nothingToAskWith(e);
      return false;
    }
  }
}

final appAuthenticatorProvider = Provider<AppAuthenticator>((ref) => LocalAppAuthenticator());

/// Face ID / Touch ID / the passcode before what only the owner may do —
/// linking a device, showing the 24 words — whether App Lock is on or not
/// (audit storage-devices:3, :5: anyone holding the open phone could). A
/// phone with no passcode at all can't ask: it goes ahead.
Future<bool> confirmOwner(WidgetRef ref, String reason) async {
  final auth = ref.read(appAuthenticatorProvider);
  return await auth.authenticate(reason) || !await auth.available();
}

/// The words saved in Passwords / iCloud Keychain, only after the same
/// check (audit SEED-1): every "Paste from…" button goes through here —
/// the keychain itself hands them over without asking.
Future<String?> pickSavedWords(WidgetRef ref, String reason) async {
  if (!await confirmOwner(ref, reason)) return null;
  return ref.read(passwordVaultProvider).pick();
}

final appLockEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('app_lock', false));

/// Seconds in the background before locking again (0 = immediately).
final appLockAfterProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('app_lock_after', '60'));

final hideInSwitcherProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('hide_in_switcher', true));

/// Choices for "Lock again" (seconds as stored → label).
const kLockAfterKeys = ['0', '60', '300', '3600'];

String lockAfterLabel(AppL10n l, String key) => switch (key) {
      '0' => l.lockImmediately,
      '300' => l.lockAfterMinutes(5),
      '3600' => l.lockAfterHour,
      _ => l.lockAfterMinutes(1),
    };

/// Time since start — the phone's clock in Settings doesn't move it.
final _sinceStart = Stopwatch()..start();

/// Wraps the whole app: lock cover + switcher cover.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child, this.now, this.uptime});
  final Widget child;

  /// Clocks (tests): the phone's clock, and time since start that the
  /// clock in Settings can't move.
  final DateTime Function()? now;
  final Duration Function()? uptime;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> with WidgetsBindingObserver {
  bool _locked = false;
  bool _obscured = false;
  bool _checkedLaunch = false;
  bool _authenticating = false;
  bool _recentsHidden = false;
  DateTime? _backgroundedAt;
  Duration _backgroundedUptime = Duration.zero;

  DateTime get _now => (widget.now ?? DateTime.now)();
  Duration get _uptime => (widget.uptime ?? () => _sinceStart.elapsed)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool get _lockOn => ref.read(appLockEnabledProvider).value ?? false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        if (ref.read(hideInSwitcherProvider).value ?? true) setState(() => _obscured = true);
      case AppLifecycleState.paused:
        if (_backgroundedAt == null) {
          _backgroundedAt = _now;
          _backgroundedUptime = _uptime;
        }
        if (ref.read(hideInSwitcherProvider).value ?? true) setState(() => _obscured = true);
      case AppLifecycleState.resumed:
        // Android: the screen (MainActivity) may be new on the same engine,
        // or the engine started before any screen — tell it again.
        if (_recentsHidden) hideFromRecents(true);
        final away = _backgroundedAt;
        _backgroundedAt = null;
        final after = int.tryParse(ref.read(appLockAfterProvider).value ?? '60') ?? 60;
        // Audit storage-devices:6 — the phone's clock set back opened the
        // app. Either clock past the timeout locks, and so does a clock
        // that went back (uptime alone may stop while the phone sleeps).
        final wall = away == null ? Duration.zero : _now.difference(away);
        final up = _uptime - _backgroundedUptime;
        final lock = _lockOn && away != null && (wall.isNegative || wall.inSeconds >= after || up.inSeconds >= after);
        setState(() {
          _obscured = false;
          if (lock) _locked = true;
        });
        if (lock) _unlock();
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _unlock() async {
    if (_authenticating) return;
    _authenticating = true;
    final auth = ref.read(appAuthenticatorProvider);
    final l = context.l10n;
    final ok = await auth.authenticate(l.unlockReason);
    // The phone's passcode / Face ID removed after the lock was turned on:
    // nothing could open it any more, and the only way out was deleting
    // the app with its chats. The lock turns itself off and says so.
    // Only with the app on screen (audit LOCK-4): started with no screen
    // (Android: a push, "always connected", a reply from a notification)
    // nothing can be asked and it looked the same — the lock went off.
    final stuck =
        !ok && WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed && !await auth.available();
    _authenticating = false;
    if (!mounted) return;
    if (ok || stuck) {
      if (stuck) {
        await ref.read(appLockEnabledProvider.notifier).save(false);
        appNotice.value = l.appLockOffNoPasscode;
      } else {
        DsHaptics.play(Haptic.success);
      }
      if (mounted) setState(() => _locked = false);
    } else {
      DsHaptics.play(Haptic.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Cold start: locked if App Lock is on (once the setting has loaded).
    final enabled = ref.watch(appLockEnabledProvider);
    final hide = enabled.value == true && (ref.watch(hideInSwitcherProvider).value ?? true);
    if (hide != _recentsHidden) {
      _recentsHidden = hide;
      hideFromRecents(hide);
    }
    if (!_checkedLaunch && enabled.hasValue) {
      _checkedLaunch = true;
      if (enabled.value == true) {
        _locked = true;
        WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
      }
    }
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        // Hidden from assistive tech while locked — and from the keyboard
        // (audit LOCK-1: Enter sent from the chat left open under the cover).
        ExcludeFocus(
          excluding: _locked,
          child: ExcludeSemantics(excluding: _locked, child: widget.child),
        ),
        if (_obscured && !_locked) const Positioned.fill(child: _SwitcherCover()),
        if (_locked) Positioned.fill(child: _LockCover(onUnlock: _unlock)),
      ],
    );
  }
}

class _SwitcherCover extends StatelessWidget {
  const _SwitcherCover();

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return BackdropFilter(
      key: const ValueKey('switcher-cover'),
      filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: ColoredBox(
        color: tokens.bg.withValues(alpha: 0.7),
        child: const Center(child: SinhronMark(size: 56)),
      ),
    );
  }
}

class _LockCover extends StatelessWidget {
  const _LockCover({required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);
    return GestureDetector(
      key: const ValueKey('lock-cover'),
      behavior: HitTestBehavior.opaque,
      onTap: onUnlock,
      child: ColoredBox(
        color: tokens.bg,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.9, end: 1),
          duration: DsMotion.of(context, DsMotion.slow),
          curve: DsMotion.enter,
          builder: (_, s, child) => Transform.scale(scale: s, child: child),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SinhronMark(size: 64),
              const SizedBox(height: DsSpace.x5),
              Text(context.l10n.appLocked, style: DsText.title3.copyWith(color: tokens.text)),
              const SizedBox(height: DsSpace.x2),
              Text(context.l10n.tapToUnlock, style: DsText.callout.copyWith(color: tokens.text3)),
            ],
          ),
        ),
      ),
    );
  }
}
