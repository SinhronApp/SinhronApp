// ADR-037 — deleting my account (App Store 5.1.1(v)): tell my groups I left
// (so they take me out of MLS), remove the account on the server, then
// remove the chat backups from the cloud, wipe this phone. Nothing is
// wiped if the server step fails.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/simple.dart' as core;
import 'backup/backup_service.dart';
import 'providers/chat_providers.dart';
import 'providers/message_actions.dart';
import 'services/net_service.dart';
import 'session.dart';

/// The server call (faked in tests): base URL, the 24 words on a device
/// without the account key.
final accountDeleteCallProvider = Provider<Future<void> Function(String base, String? phrase)>(
  (ref) =>
      (base, phrase) => core.accountDelete(serverBaseUrl: base, phrase: phrase),
);

/// Wipes this phone after the account is gone (faked in tests).
final accountWipeProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => ref.read(sessionProvider).eraseAndStartOver(),
);

final accountDeletionProvider = Provider<AccountDeletion>((ref) => AccountDeletion(ref));

class AccountDeletion {
  AccountDeletion(this._ref);
  final Ref _ref;

  Future<void> run({String? phrase}) async {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('offline');
    // Best-effort, before the account (and its connection) is gone: each
    // group hears "left" and one of them commits my removal.
    final chats = await _ref.read(chatsProvider.future).catchError((Object _) => const <Never>[]);
    for (final c in chats) {
      final id = c.id;
      if (!c.group || id == null) continue;
      try {
        await _ref.read(messageActionsProvider).announceLeave(id);
      } catch (_) {
        // Offline or the group is broken — the server step decides.
      }
    }
    await _ref.read(accountDeleteCallProvider)(base, phrase);
    // storage-devices:11 — the chat backups in the cloud go too (best effort).
    try {
      await _ref.read(chatBackupProvider.notifier).deleteAll();
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron] account deletion: backup not removed: $e');
    }
    await _ref.read(accountWipeProvider)();
  }
}
