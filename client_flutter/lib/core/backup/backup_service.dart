// ADR-073 — the chat backup, driven from here: once a day (when the app
// goes to the background or comes back after a day), or on "Back up now";
// and the restore after the 24 words on a new phone.
//
// Rust (`api/backup.rs`) packs the database into encrypted files in a
// staging folder and seals the root with the key from the 24 words; this
// side moves the files to the cloud ([CloudStore]) — root last, so a root
// in the cloud always points at files that are there — and cleans out
// what older backups left. A run cut short (the app closed) goes on next
// time from where it stopped; media go up once (named by content).
//
// Every device keeps its files as `<tag>-<name>` (`chatBackupTag`): an
// iPhone and an iPad on one Apple ID, or two people's accounts on a shared
// one, each keep their own backup and never clean out another's. A
// restore takes the newest one these words open.
//
// ADR-090 (storage-devices:14) — whoever controls the cloud could put an
// older backup back unseen. After each backup the server is told when it
// was made ([BackupMark]); before a restore the phone asks, and a cloud
// whose newest backup is older than that is said so ([BackupContents.missingNewer]).

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../providers/device_transfer.dart' show refreshAfterImport;
import '../providers/settings_providers.dart';
import '../session.dart' show deviceKeyStoreProvider;
import 'backup_core_ffi.dart';
import 'cloud_store.dart';

const kBackupRoot = 'root.sinhron';

/// Bytes written to the staging folder before they go up (keeps the
/// phone's free space needed small).
const kBackupBudgetBytes = 32 * 1024 * 1024;

/// A scheduled backup runs at most this often.
const kBackupEvery = Duration(hours: 24);

/// Another device of this account that hasn't backed up for this long is
/// gone (or wiped): its files are removed after a backup of this one.
const kBackupStale = Duration(days: 30);

final _sha = RegExp(r'^[0-9a-f]{64}$');
final _tagged = RegExp(r'^([0-9a-f]{16})-(.+)$');

/// `<tag>-<name>` → (tag, name); null for anything else in the folder.
({String tag, String name})? splitBackupName(String cloudName) {
  final m = _tagged.firstMatch(cloudName);
  return m == null ? null : (tag: m.group(1)!, name: m.group(2)!);
}

/// The Rust side (`api/backup.rs`), in plain Dart types (a fake in tests).
abstract class BackupCore {
  /// This device's name prefix in the cloud folder.
  Future<String> tag(String secret);

  /// False on a linked device whose key predates the backup ([unlock]).
  Future<bool> can(String secret);

  /// With the 24 words: the device key to keep instead ("other_words").
  Future<String> unlock(String phrase, String secret);
  Future<BackupStepResult> step(String secret, String staging, List<String> cloudHas, int budget);
  Future<List<String>> keep();
  Future<void> reset();
  Future<BackupContents> info(String secret, List<int> root);
  Future<BackupContents> start(String secret, List<int> root);
  Future<RestoreStepResult> restoreStep(String staging);
  Future<List<String>> media();
  Future<int> adopt(String staging, List<String> names);
  Future<void> clear();
}

class BackupStepResult {
  const BackupStepResult({
    required this.stage,
    required this.done,
    required this.files,
    required this.rootReady,
    this.messages = 0,
    this.mediaTotal = 0,
    this.mediaChecked = 0,
    this.mediaMissing = 0,
  });
  final String stage;
  final bool done;
  final List<String> files;
  final bool rootReady;
  final int messages;
  final int mediaTotal;
  final int mediaChecked;
  final int mediaMissing;
}

class BackupContents {
  const BackupContents({
    required this.created,
    required this.messages,
    required this.chats,
    required this.media,
    this.tag = '',
    this.missingNewer,
  });
  final DateTime created;
  final int messages;
  final int chats;
  final int media;

  /// Which device's backup ([BackupCore.tag]).
  final String tag;

  /// ADR-090 — a newer backup was made (then), and the cloud no longer has
  /// it: rolled back, or lost. Null: nothing newer is known.
  final DateTime? missingNewer;

  BackupContents withTag(String t, {DateTime? missingNewer}) => BackupContents(
    created: created,
    messages: messages,
    chats: chats,
    media: media,
    tag: t,
    missingNewer: missingNewer,
  );
}

/// ADR-090 (storage-devices:14) — the server's note of the newest backup
/// this account's devices made in each cloud (`chat_backup_mark`): [mark]
/// with a backup's time (Unix seconds) after it is up, with 0 to only ask.
/// Returns the newest known (0: none).
abstract class BackupMark {
  Future<int> mark(String cloud, int createdTs);
}

final backupMarkProvider = Provider<BackupMark?>((ref) => FfiBackupMark(ref));

/// The server's name for [store]'s cloud ("icloud", "googledrive").
String backupCloudKey(CloudStore store) => store.kind.toLowerCase().replaceAll(RegExp('[^a-z]'), '');

class RestoreStepResult {
  const RestoreStepResult({
    required this.stage,
    required this.need,
    required this.done,
    this.error,
    this.partsDone = 0,
    this.partsTotal = 0,
    this.changed = false,
    this.messagesAdded = 0,
  });
  final String stage;
  final List<String> need;
  final bool done;
  final String? error;
  final int partsDone;
  final int partsTotal;
  final bool changed;

  /// Messages this device didn't have, so far (the whole restore).
  final int messagesAdded;
}

/// The generated bindings (a fake in tests).
final backupCoreProvider = Provider<BackupCore?>((ref) => const FfiBackupCore());

/// Where the staging folders go (the app's temporary folder; a test folder).
final backupTempDirProvider = Provider<Future<Directory> Function()>((ref) => getTemporaryDirectory);

/// Settings → Backup: a copy every day (on by default where the cloud is
/// ready; on Android it starts after "Sign in with Google").
final backupEnabledProvider = AsyncNotifierProvider<BoolSetting, bool>(() => BoolSetting('backup_enabled', true));

/// When the last backup finished (ISO, '' = never).
final backupLastProvider = AsyncNotifierProvider<StringSetting, String>(() => StringSetting('backup_last_at', ''));

/// Can this device back up (false: an older linked device — the 24 words
/// turn it on, [ChatBackup.unlock])?
final backupCanProvider = FutureProvider.autoDispose<bool>((ref) async {
  final core = ref.watch(backupCoreProvider);
  final secret = await ref.watch(deviceKeyStoreProvider).read();
  return core != null && secret != null && await core.can(secret);
});

/// What a run shows on the screen.
@immutable
class BackupState {
  const BackupState({
    this.running = false,
    this.restoring = false,
    this.stage = '',
    this.done = 0,
    this.total = 0,
    this.error,
    this.uploadPending = false,
  });
  final bool running;
  final bool restoring;

  /// The backup is written, but iCloud hasn't taken it from this phone yet
  /// (it waits for Wi-Fi) — my other devices can't see it yet.
  final bool uploadPending;

  /// "build" | "upload" | "media" | "done" (backup); "parts" | "media" … (restore).
  final String stage;
  final int done;
  final int total;
  final String? error;

  BackupState copyWith({bool? running, bool? restoring, String? stage, int? done, int? total, String? error, bool clearError = false}) =>
      BackupState(
        running: running ?? this.running,
        restoring: restoring ?? this.restoring,
        stage: stage ?? this.stage,
        done: done ?? this.done,
        total: total ?? this.total,
        error: clearError ? null : (error ?? this.error),
        uploadPending: uploadPending,
      );
}

class ChatBackup extends Notifier<BackupState> {
  @override
  BackupState build() => const BackupState();

  /// How long a finished backup waits for iCloud to take it before the
  /// screen says "still uploading".
  @visibleForTesting
  static Duration uploadWait = const Duration(seconds: 20);

  Future<Directory> _staging(String name) async {
    final d = Directory('${(await ref.read(backupTempDirProvider)()).path}/$name');
    if (await d.exists()) await d.delete(recursive: true);
    return d.create(recursive: true);
  }

  /// Is a scheduled backup due (on, a cloud, older than [kBackupEvery])?
  Future<bool> due(DateTime now) async {
    if (!(await ref.read(backupEnabledProvider.future))) return false;
    final last = DateTime.tryParse(await ref.read(backupLastProvider.future));
    return last == null || now.difference(last) >= kBackupEvery;
  }

  /// Back up now. [scheduled]: the daily run (waits for Wi-Fi on Android).
  /// Returns true when a full backup is in the cloud.
  Future<bool> run({bool scheduled = false}) async {
    if (state.running || state.restoring) return false;
    final store = ref.read(cloudStoreProvider);
    final core = ref.read(backupCoreProvider);
    if (store == null || core == null) return false;
    final secret = await ref.read(deviceKeyStoreProvider).read();
    // A device paired by QR has no account key: its main device backs up.
    if (secret == null) return false;
    if (!await store.available()) {
      if (!scheduled) state = state.copyWith(error: 'not_connected');
      return false;
    }
    if (scheduled && await store.shouldWaitForWifi()) return false;
    if (!await core.can(secret)) {
      if (!scheduled) state = state.copyWith(error: 'no_key');
      return false;
    }
    state = const BackupState(running: true, stage: 'build');
    // ignore: avoid_print
    print('[sinhron][backup] start (${store.kind}${scheduled ? ', scheduled' : ''})');
    try {
      // "Back up now" is a fresh snapshot — not the rest of one cut off
      // earlier, whose messages are old (2026-10-26). Files already in the
      // cloud are still not uploaded again.
      if (!scheduled) await core.reset();
      final tag = await core.tag(secret);
      final staging = await _staging('backup-out');
      final cloud = {
        for (final n in await store.list())
          if (splitBackupName(n) case (tag: final t, :final name) when t == tag) name,
      };
      DateTime? made;
      while (true) {
        final p = await core.step(secret, staging.path, cloud.toList(), kBackupBudgetBytes);
        for (final name in [...p.files, if (p.rootReady) kBackupRoot]) {
          // Root last: a root in the cloud always points at files there.
          final f = File('${staging.path}/$name');
          await store.put('$tag-$name', f);
          if (name == kBackupRoot) made = (await core.info(secret, await f.readAsBytes())).created;
          await f.delete();
          cloud.add(name);
        }
        state = state.copyWith(stage: p.stage, done: p.mediaChecked, total: p.mediaTotal);
        if (p.done) break;
      }
      // What this device's older backups left behind.
      final keep = (await core.keep()).toSet();
      if (keep.isNotEmpty) {
        for (final n in await store.list()) {
          final s = splitBackupName(n);
          if (s != null && s.tag == tag && _sha.hasMatch(s.name) && !keep.contains(s.name)) await store.delete(n);
        }
      }
      await _dropStale(store, core, secret, tag, staging);
      await staging.delete(recursive: true);
      await ref.read(backupLastProvider.notifier).save(DateTime.now().toUtc().toIso8601String());
      if (made != null) await _mark(store, made.millisecondsSinceEpoch ~/ 1000);
      // iCloud usually takes it within seconds on Wi-Fi; only a backup still
      // waiting after that is shown as uploading.
      var pending = !await store.uploaded('$tag-$kBackupRoot');
      for (var waited = Duration.zero; pending && waited < uploadWait; waited += const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(seconds: 2));
        pending = !await store.uploaded('$tag-$kBackupRoot');
      }
      // ignore: avoid_print
      print('[sinhron][backup] done${pending ? ' (still uploading)' : ''}');
      state = BackupState(stage: 'done', uploadPending: pending);
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][backup] stopped: $e');
      state = BackupState(error: '$e');
      return false;
    }
  }

  /// Every backup in the folder these words open (newest first; a root of
  /// another account is skipped).
  Future<List<BackupContents>> _roots(CloudStore store, BackupCore core, String secret, Directory dir) async {
    final found = <BackupContents>[];
    for (final n in await store.list()) {
      final s = splitBackupName(n);
      if (s == null || s.name != kBackupRoot) continue;
      final f = File('${dir.path}/${s.tag}-$kBackupRoot');
      try {
        if (await store.get(n, f)) found.add((await core.info(secret, await f.readAsBytes())).withTag(s.tag));
      } catch (e) {
        // ignore: avoid_print
        print('[sinhron][backup] root ${s.tag} not opened: $e');
      }
    }
    found.sort((a, b) => b.created.compareTo(a.created));
    return found;
  }

  /// ADR-090 — tell the server / ask it ([at] 0) when the newest backup in
  /// [store] was made; 0 when it doesn't say (offline: no check, as before).
  Future<int> _mark(CloudStore store, int at) async {
    try {
      return await ref.read(backupMarkProvider)?.mark(backupCloudKey(store), at) ?? 0;
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][backup] newest-backup mark: $e');
      return 0;
    }
  }

  /// Another device of this account that stopped backing up long ago:
  /// its files go (root first, so what is left is never taken for a
  /// backup). Only after this device's own backup is in the cloud.
  Future<void> _dropStale(CloudStore store, BackupCore core, String secret, String tag, Directory dir) async {
    final now = DateTime.now();
    final stale = {
      for (final b in await _roots(store, core, secret, dir))
        if (b.tag != tag && now.difference(b.created) > kBackupStale) b.tag,
    };
    await _drop(store, stale);
  }

  /// These devices' backups go (each root first).
  Future<void> _drop(CloudStore store, Set<String> tags) async {
    for (final t in tags) {
      // ignore: avoid_print
      print('[sinhron][backup] removing the backup of device $t');
      await store.delete('$t-$kBackupRoot');
      for (final n in await store.list()) {
        if (splitBackupName(n)?.tag == t) await store.delete(n);
      }
    }
  }

  /// The account is deleted (ADR-037, audit storage-devices:11): every
  /// backup these words open — this device's and my other devices' — goes
  /// from iCloud / Google Drive, so the history doesn't outlive it there.
  /// Nothing when the cloud can't be reached (the screen says so).
  Future<void> deleteAll() async {
    final store = ref.read(cloudStoreProvider);
    final core = ref.read(backupCoreProvider);
    if (store == null || core == null || !await store.available()) return;
    final secret = await ref.read(deviceKeyStoreProvider).read();
    if (secret == null || !await core.can(secret)) return;
    final tags = {
      await core.tag(secret),
      for (final b in await _roots(store, core, secret, await _staging('backup-root'))) b.tag,
    };
    await _drop(store, tags);
  }

  /// The backup to restore: the newest one of my **other** devices — this
  /// device's own (made daily) holds nothing it lacks (2026-10-26: a newly
  /// linked device restored its own backup and got no new messages); its
  /// own only when there is no other (a reinstalled main device).
  Future<BackupContents?> find() async {
    final store = ref.read(cloudStoreProvider);
    final core = ref.read(backupCoreProvider);
    final secret = await ref.read(deviceKeyStoreProvider).read();
    if (store == null || core == null || secret == null || !await store.available()) return null;
    if (!await core.can(secret)) return null;
    final all = await _roots(store, core, secret, await _staging('backup-root'));
    final mine = await core.tag(secret);
    final pick = all.where((b) => b.tag != mine).firstOrNull ?? all.firstOrNull;
    if (pick == null) return null;
    // ADR-090 — the newest backup any of my devices made here is gone.
    final newest = await _mark(store, 0);
    if (newest <= all.first.created.millisecondsSinceEpoch ~/ 1000) return pick;
    return pick.withTag(pick.tag, missingNewer: DateTime.fromMillisecondsSinceEpoch(newest * 1000));
  }

  /// Messages the last restore added here (0: the backup held nothing new).
  int get lastRestoreAdded => _lastRestoreAdded;
  int _lastRestoreAdded = 0;

  /// Turn the backup on for an older linked device: the 24 words add the
  /// backup key to its device key (the same device and database). Null
  /// when done, else what went wrong ("other_words", …).
  Future<String?> unlock(String phrase) async {
    final core = ref.read(backupCoreProvider);
    final keys = ref.read(deviceKeyStoreProvider);
    final secret = await keys.read();
    if (core == null || secret == null) return 'no_key';
    try {
      final next = await core.unlock(phrase, secret);
      if (next != secret) await keys.write(next);
      ref.invalidate(backupCanProvider);
      return null;
    } catch (e) {
      return '$e'.contains('other_words') ? 'other_words' : '$e';
    }
  }

  /// Bring [from] in ([find]): messages, contacts, settings, packs, then
  /// media.
  Future<bool> restore(BackupContents from) async {
    if (state.running || state.restoring) return false;
    final store = ref.read(cloudStoreProvider);
    final core = ref.read(backupCoreProvider);
    final secret = await ref.read(deviceKeyStoreProvider).read();
    if (store == null || core == null || secret == null) return false;
    final pre = '${from.tag}-';
    state = const BackupState(restoring: true, stage: 'manifest');
    _lastRestoreAdded = 0;
    // ignore: avoid_print
    print('[sinhron][backup] restore start (device ${from.tag})');
    try {
      final staging = await _staging('backup-in');
      final root = File('${staging.path}/$kBackupRoot');
      if (!await store.get('$pre$kBackupRoot', root)) throw StateError('no backup in ${store.kind}');
      await core.start(secret, await root.readAsBytes());
      while (true) {
        final p = await core.restoreStep(staging.path);
        _lastRestoreAdded = p.messagesAdded;
        if (p.changed) refreshAfterImport(ref);
        state = state.copyWith(stage: p.stage, done: p.partsDone, total: p.partsTotal);
        if (p.stage == 'failed') throw StateError(p.error ?? 'restore failed');
        if (p.done) break;
        if (p.need.isEmpty) throw StateError('restore stalled at ${p.stage}');
        for (final name in p.need) {
          if (!await store.get('$pre$name', File('${staging.path}/$name'))) throw StateError('a backup file is missing');
        }
      }
      // Media: fetched into local copies, a few at a time.
      final media = await core.media();
      state = state.copyWith(stage: 'media', done: 0, total: media.length);
      for (var i = 0; i < media.length; i += 20) {
        final batch = media.sublist(i, (i + 20).clamp(0, media.length));
        final got = <String>[];
        for (final name in batch) {
          if (await store.get('$pre$name', File('${staging.path}/$name'))) got.add(name);
        }
        await core.adopt(staging.path, got);
        state = state.copyWith(done: i + batch.length);
      }
      await core.clear();
      await staging.delete(recursive: true);
      refreshAfterImport(ref);
      // The chats' MLS membership comes with the next device sync (ADR-075:
      // by their cards; ADR-074: added by members), and only after it does
      // Saved messages repair itself (NetService.syncDevices).
      // ignore: avoid_print
      print('[sinhron][backup] restore done ($_lastRestoreAdded new messages, ${media.length} media)');
      state = const BackupState(stage: 'restored');
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('[sinhron][backup] restore stopped: $e');
      state = BackupState(error: '$e');
      return false;
    }
  }
}

final chatBackupProvider = NotifierProvider<ChatBackup, BackupState>(ChatBackup.new);

/// Runs the daily backup: a minute after start and whenever the app goes to
/// the background or comes back, if one is due.
class BackupKeeper extends ConsumerStatefulWidget {
  const BackupKeeper({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<BackupKeeper> createState() => _BackupKeeperState();
}

class _BackupKeeperState extends ConsumerState<BackupKeeper> with WidgetsBindingObserver {
  Timer? _first;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _first = Timer(const Duration(minutes: 1), _maybe);
  }

  Future<void> _maybe() async {
    try {
      final b = ref.read(chatBackupProvider.notifier);
      if (await b.due(DateTime.now())) await b.run(scheduled: true);
    } catch (_) {
      // Storage not open (onboarding) — next time.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.resumed) unawaited(_maybe());
  }

  @override
  void dispose() {
    _first?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
