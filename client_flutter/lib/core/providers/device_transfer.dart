// ADR-064 — "a new device is the same device": the full transfer to a
// newly linked device, and the ongoing sync that keeps my devices equal.
//
// Rust does the work (`api/transfer.rs`): the old device packs the whole
// database into encrypted parts, uploads them like media and tells the
// new device over my own-devices group (Saved messages, ADR-055); the new
// one downloads and merges, step by step, resuming after a restart or a
// dropped network. Afterwards contacts, blocked people, chat mute / pin /
// archive, sticker packs, folders and the synced settings go to my other
// devices as they change. This file drives those steps from the app,
// keeps the progress for the screens, and refreshes what changed.

import 'dart:async';
import 'dart:convert' show jsonDecode;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../push.dart' show pushPlatformProvider;
import '../../app/theme/appearance.dart';
import '../../features/banners/in_app_banner.dart';
import '../../features/calls/call_path.dart';
import '../../features/chat_list/folders.dart';
import '../../features/chat_view/emoji_panel.dart';
import '../../features/stickers/sticker_store.dart';
import '../../features/verify/verify_contact.dart';
import '../../l10n/l10n.dart';
import '../../src/rust/api/transfer.dart' as core;
import '../app_badge.dart';
import '../haptics.dart';
import '../services/net_service.dart';
import '../ui_sounds.dart';
import 'chat_providers.dart';
import 'message_actions.dart';
import 'people.dart';
import 'presence.dart';
import 'saved_messages.dart';
import 'settings_providers.dart';

/// The FFI behind transfers and device sync (a seam for tests).
class DeviceTransferBackend {
  /// Every transfer this device knows of; [] when Rust isn't up yet.
  List<core.TransferStatus> status() {
    try {
      return core.deviceTransferStatus();
    } catch (_) {
      return const [];
    }
  }

  Future<core.TransferStatus?> step(String base) => core.deviceTransferStep(serverBaseUrl: base);
  Future<void> start(String deviceHex) => core.deviceTransferStart(devicePkHex: deviceHex);
  Future<void> dismiss(String base, bool outgoing, String deviceHex) =>
      core.deviceTransferDismiss(serverBaseUrl: base, outgoing: outgoing, deviceHex: deviceHex);
  Future<int> flush(String base) => core.deviceSyncFlush(serverBaseUrl: base);
  Future<int> fetchPacks(String base) => core.deviceSyncFetchPacks(serverBaseUrl: base);
}

final deviceTransferBackendProvider = Provider<DeviceTransferBackend>((ref) => DeviceTransferBackend());

/// The server's HTTP origin while connected (null offline). Overridable in tests.
final transferBaseUrlProvider = Provider<String? Function()>(
  (ref) =>
      () => ref.read(netServiceProvider).httpBaseUrl,
);

/// How far a transfer got, 0…1 (for the bars), or null while it can't say.
double? transferFraction(core.TransferStatus s) {
  if (s.stage == 'done') return 1;
  if (s.total <= 0) return null;
  return (s.done / s.total).clamp(0.0, 1.0);
}

/// True while this device is still receiving a transfer.
bool isIncomingInProgress(core.TransferStatus s) => !s.outgoing && s.stage != 'done' && s.stage != 'failed';

/// The transfers (both ways) and the loop that runs them.
class DeviceTransfers extends Notifier<List<core.TransferStatus>> {
  bool _running = false;
  Timer? _retry;

  /// Network trouble mid-transfer: when to try again.
  static const retryAfter = Duration(seconds: 30);

  DeviceTransferBackend get _backend => ref.read(deviceTransferBackendProvider);

  @override
  List<core.TransferStatus> build() {
    ref.onDispose(() => _retry?.cancel());
    return _backend.status();
  }

  /// Did the last attempt stop on the network? (The card says "will go on".)
  bool waiting = false;

  /// Run transfer steps until nothing is left (or the network fails —
  /// then again in [retryAfter]). Safe to call any time; one run at once.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _retry?.cancel();
    var importedSomething = false;
    try {
      while (true) {
        final base = ref.read(transferBaseUrlProvider)();
        if (base == null) break;
        final s = await _backend.step(base);
        waiting = false;
        state = _backend.status();
        if (s == null) break;
        if (!s.outgoing) {
          importedSomething = true;
          // Chats appear as the parts land, not only at the end.
          ref.read(chatsRefresherProvider).schedule();
          if (s.stage == 'parts' && s.done == 1) _refreshAfterImport();
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][transfer] step failed, retrying later: $e');
      waiting = true;
      state = _backend.status();
      _retry = Timer(retryAfter, () => unawaited(run()));
    } finally {
      _running = false;
    }
    if (importedSomething) _refreshAfterImport();
  }

  /// "Send everything to this device" (Devices → a device).
  Future<void> sendTo(String deviceHex) async {
    // The own-devices group must exist and hold that device.
    await ref.read(savedMessagesProvider).ensure();
    await ref.read(netServiceProvider).syncDevices();
    await _backend.start(deviceHex);
    state = _backend.status();
    unawaited(run());
  }

  /// Hide a finished card, or stop an unfinished outgoing transfer.
  Future<void> dismiss(core.TransferStatus s) async {
    final base = ref.read(transferBaseUrlProvider)() ?? '';
    await _backend.dismiss(base, s.outgoing, s.deviceHex);
    state = _backend.status();
  }

  /// A transfer message from my other device (Rust kept the job).
  void onTransferMessage(String? json) {
    state = _backend.status();
    Map<String, dynamic> m;
    try {
      m = jsonDecode(json ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (m['for_me'] == true) unawaited(run());
  }

  void _refreshAfterImport() => refreshAfterImport(ref);
}

/// Everything a transfer — or a restored backup (ADR-073) — may have touched.
void refreshAfterImport(Ref ref) {
  ref.read(chatsRefresherProvider).schedule();
  ref.invalidate(chatsProvider);
  ref.invalidate(savedChatIdProvider);
  ref.invalidate(contactsProvider);
  ref.invalidate(peerNamesProvider);
  ref.invalidate(peerAvatarsProvider);
  ref.invalidate(peerBiosProvider);
  ref.invalidate(blockedPeersProvider);
  ref.invalidate(userStickerPacksProvider);
  invalidateSyncedSettings(ref, null);
  // Copied once: how the app looks and sounds.
  ref.invalidate(themeChoiceProvider);
  ref.invalidate(accentProvider);
  ref.invalidate(wallpaperProvider);
  ref.invalidate(languageProvider);
  ref.invalidate(hapticsEnabledProvider);
  ref.invalidate(uiSoundsEnabledProvider);
  ref.invalidate(inAppBannersEnabledProvider);
  ref.invalidate(iconBadgeEnabledProvider);
  ref.invalidate(notificationPreviewProvider);
  ref.invalidate(callsReserveAlwaysProvider);
}

final deviceTransfersProvider = NotifierProvider<DeviceTransfers, List<core.TransferStatus>>(DeviceTransfers.new);

/// Refresh the providers of synced settings — all of them ([keys] null) or
/// the ones another device changed.
void invalidateSyncedSettings(Ref ref, Iterable<String>? keys) {
  final all = keys == null;
  final set = keys?.toSet() ?? const <String>{};
  bool has(String k) => all || set.contains(k);
  if (has('profile_name')) ref.invalidate(profileNameProvider);
  if (has('profile_avatar')) ref.invalidate(profileAvatarProvider);
  if (has('profile_about')) ref.invalidate(profileAboutProvider);
  if (has('read_receipts')) ref.invalidate(readReceiptsProvider);
  if (has('typing_indicators')) ref.invalidate(typingIndicatorsProvider);
  if (has('show_online')) ref.invalidate(showOnlineProvider);
  if (has('link_previews')) ref.invalidate(linkPreviewsEnabledProvider);
  if (has('incoming_calls')) ref.invalidate(incomingCallsProvider);
  if (has('blocked_chats')) ref.invalidate(blockedChatsProvider);
  if (has('chat_folders')) ref.invalidate(customFoldersProvider);
  if (has('chat_folder_layout')) ref.invalidate(folderLayoutProvider);
  if (has('sticker_recent')) ref.invalidate(recentStickersProvider);
  if (has('emoji_recent')) ref.invalidate(recentEmojiProvider);
  if (has('emoji_tones')) ref.invalidate(emojiTonesProvider);
  if (all || set.any((k) => k.startsWith('verified:'))) {
    ref.invalidate(verifiedPeersProvider);
    ref.invalidate(verifyStateProvider);
  }
}

/// ADR-064 — the ongoing half: send what changed here, apply what my other
/// device changed. NetService calls [flushSoon] on connect and on a timer.
class DeviceSync {
  DeviceSync(this._ref);
  final Ref _ref;
  bool _flushing = false;

  DeviceTransferBackend get _backend => _ref.read(deviceTransferBackendProvider);

  /// Send pending changes to my other devices (nothing when there are none).
  Future<void> flush() async {
    final base = _ref.read(transferBaseUrlProvider)();
    if (base == null || _flushing) return;
    _flushing = true;
    try {
      final n = await _backend.flush(base);
      if (n > 0) {
        // ignore: avoid_print
        print('[sinhron][devsync] sent $n change(s) to my other devices');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][devsync] flush failed: $e');
    } finally {
      _flushing = false;
    }
  }

  /// My other device changed something (Rust already applied it): show it.
  Future<void> onIncoming(String? json) async {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(json ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final settings = (m['settings'] as List<dynamic>? ?? const []).cast<String>();
    if (settings.isNotEmpty) invalidateSyncedSettings(_ref, settings);
    if (m['chats'] == true) {
      _ref.invalidate(chatsProvider);
      _ref.read(chatsRefresherProvider).schedule();
    }
    // Status 223 — read on my other device: its notifications go here too.
    for (final id in (m['read'] as List<dynamic>? ?? const []).whereType<String>()) {
      try {
        unawaited(_ref.read(pushPlatformProvider).clearChat(id).catchError((Object _) {}));
      } catch (_) {
        // no push platform here (tests)
      }
    }
    if (m['contacts'] == true) _ref.invalidate(contactsProvider);
    if (m['blocked'] == true) _ref.invalidate(blockedPeersProvider);
    if (m['packs'] == true) {
      final base = _ref.read(transferBaseUrlProvider)();
      if (base != null) {
        try {
          await _backend.fetchPacks(base);
        } catch (_) {
          // Next change or restart tries again.
        }
      }
      _ref.invalidate(userStickerPacksProvider);
    }
  }
}

final deviceSyncProvider = Provider<DeviceSync>((ref) => DeviceSync(ref));

/// The line under a transfer card / the chat-list strip.
String transferLine(AppL10n l, core.TransferStatus s, {bool waiting = false}) {
  if (waiting && s.stage != 'done' && s.stage != 'failed') return l.transferWaiting;
  switch (s.stage) {
    case 'build':
      return l.transferStageBuild;
    case 'upload':
      return l.transferStageUpload(s.done, s.total);
    case 'offer':
      return l.transferStageOffer;
    case 'media':
      return l.transferStageMedia(s.done, s.total);
    case 'manifest':
      return l.transferStageManifest;
    case 'parts':
      return l.transferStageParts(s.done, s.total);
    case 'packs':
      return l.transferStagePacks;
    case 'failed':
      return l.transferFailed;
    default:
      if (!s.outgoing && !s.mediaReady) return l.transferDoneMediaLater(s.messages);
      if (s.mediaMissing > 0) return l.transferDoneMissing(s.messages, s.mediaMissing);
      return l.transferDone(s.messages);
  }
}
