// ADR-073 — the Rust side of the chat backup (`rust/src/api/backup.rs`)
// behind [BackupCore], in plain Dart numbers.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/backup.dart' as rust;
import '../services/net_service.dart' show netServiceProvider;
import 'backup_service.dart';

/// ADR-090 — [BackupMark] over `chat_backup_mark`, to this phone's server.
class FfiBackupMark implements BackupMark {
  FfiBackupMark(this._ref);
  final Ref _ref;

  @override
  Future<int> mark(String cloud, int createdTs) async {
    final base = _ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('not connected to a server');
    return rust.chatBackupMark(serverBaseUrl: base, cloud: cloud, createdTs: createdTs);
  }
}

class FfiBackupCore implements BackupCore {
  const FfiBackupCore();

  BackupContents _contents(rust.BackupInfo i) => BackupContents(
    created: DateTime.fromMillisecondsSinceEpoch(i.createdTs.toInt() * 1000),
    messages: i.messages.toInt(),
    chats: i.chats.toInt(),
    media: i.media.toInt(),
  );

  @override
  Future<String> tag(String secret) => rust.chatBackupTag(secret: secret);

  @override
  Future<bool> can(String secret) => rust.chatBackupCan(secret: secret);

  @override
  Future<String> unlock(String phrase, String secret) => rust.chatBackupUnlock(phrase: phrase, secret: secret);

  @override
  Future<BackupStepResult> step(String secret, String staging, List<String> cloudHas, int budget) async {
    final p = await rust.chatBackupStep(
      secret: secret,
      stagingDir: staging,
      cloudHas: cloudHas,
      budgetBytes: BigInt.from(budget),
    );
    return BackupStepResult(
      stage: p.stage,
      done: p.done,
      files: p.files,
      rootReady: p.rootReady,
      messages: p.messages.toInt(),
      mediaTotal: p.mediaTotal.toInt(),
      mediaChecked: p.mediaChecked.toInt(),
      mediaMissing: p.mediaMissing.toInt(),
    );
  }

  @override
  Future<List<String>> keep() => rust.chatBackupKeep();

  @override
  Future<void> reset() => rust.chatBackupReset();

  @override
  Future<BackupContents> info(String secret, List<int> root) async =>
      _contents(await rust.chatRestoreInfo(secret: secret, root: root));

  @override
  Future<BackupContents> start(String secret, List<int> root) async =>
      _contents(await rust.chatRestoreStart(secret: secret, root: root));

  @override
  Future<RestoreStepResult> restoreStep(String staging) async {
    final p = await rust.chatRestoreStep(stagingDir: staging);
    return RestoreStepResult(
      stage: p.stage,
      need: p.need,
      done: p.done,
      error: p.error,
      partsDone: p.partsDone,
      partsTotal: p.partsTotal,
      changed: p.changed,
      messagesAdded: p.messagesAdded.toInt(),
    );
  }

  @override
  Future<List<String>> media() => rust.chatRestoreMedia();

  @override
  Future<int> adopt(String staging, List<String> names) => rust.chatRestoreAdopt(stagingDir: staging, names: names);

  @override
  Future<void> clear() => rust.chatRestoreClear();
}
