// ADR-073 — the chat backup's Dart half: what goes to the cloud and in
// which order, what gets cleaned, whose files are never touched, and the
// restore. The Rust half is faked ([_Core]); a folder stands in for
// iCloud / Google Drive.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/backup/backup_service.dart';
import 'package:sinhron/core/backup/cloud_store.dart';
import 'package:sinhron/core/providers/chat_providers.dart' show ChatsRefresher, chatsRefresherProvider;
import 'package:sinhron/core/providers/settings_providers.dart';
import 'package:sinhron/core/session.dart';

class _Store implements SettingsStore {
  final map = <String, String>{};
  @override
  Future<String?> get(String key) async => map[key];
  @override
  Future<void> set(String key, String value) async => map[key] = value;
}

class _Keys implements DeviceKeyStore {
  _Keys(this.value);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String deviceKey) async => value = deviceKey;
  @override
  Future<void> delete() async => value = null;
}

/// Records the order of uploads and deletes.
class _Cloud extends DirCloudStore {
  _Cloud(super.dir);
  final puts = <String>[];
  final deletes = <String>[];

  /// Names iCloud hasn't taken from this phone yet.
  final notUploaded = <String>{};

  @override
  Future<bool> uploaded(String name) async => !notUploaded.contains(name);

  @override
  Future<void> put(String name, File file) async {
    puts.add(name);
    await super.put(name, file);
  }

  @override
  Future<void> delete(String name) async {
    deletes.add(name);
    await super.delete(name);
  }

  void seed(String name, String text) {
    dir.createSync(recursive: true);
    File('${dir.path}/$name').writeAsStringSync(text);
  }
}

String _h(String c) => c * 64;

const _words = 'the right words';
const _accountOf = {'key-A': 'acc1', 'key-B': 'acc1', 'key-C': 'acc2'};
const _tagOf = {'key-A': 'aaaaaaaaaaaaaaaa', 'key-B': 'bbbbbbbbbbbbbbbb', 'key-C': 'cccccccccccccccc', 'old': '1111111111111111'};

String _root(String account, DateTime created) => jsonEncode({'account': account, 'created': created.toIso8601String()});

/// Rust's side, in memory: backup N writes part pN and q, then the root,
/// then the photo m; the restore wants q and p1 in turn, then the photo.
class _Core implements BackupCore {
  int generation = 0;
  int _call = 0;
  final adopted = <String>[];
  bool cleared = false;
  int resets = 0;
  int added = 7;

  String get _part => _h('${generation % 10}');

  @override
  Future<String> tag(String secret) async => _tagOf[secret]!;

  @override
  Future<bool> can(String secret) async => secret != 'old';

  @override
  Future<String> unlock(String phrase, String secret) async {
    if (phrase != _words) throw Exception('other_words');
    return 'key-A';
  }

  @override
  Future<BackupStepResult> step(String secret, String staging, List<String> cloudHas, int budget) async {
    _call++;
    if (_call == 1) {
      for (final n in [_part, _h('e')]) {
        if (!cloudHas.contains(n)) File('$staging/$n').writeAsStringSync('part');
      }
      File('$staging/$kBackupRoot').writeAsStringSync(_root(_accountOf[secret]!, DateTime.now()));
      return BackupStepResult(
        stage: 'upload',
        done: false,
        files: [_part, _h('e')].where((n) => !cloudHas.contains(n)).toList(),
        rootReady: true,
      );
    }
    _call = 0;
    final media = cloudHas.contains(_h('f')) ? <String>[] : [_h('f')];
    for (final n in media) {
      File('$staging/$n').writeAsStringSync('photo');
    }
    return BackupStepResult(stage: 'done', done: true, files: media, rootReady: false, mediaTotal: 1, mediaChecked: 1);
  }

  @override
  Future<List<String>> keep() async => [_part, _h('e'), _h('f'), kBackupRoot];

  @override
  Future<void> reset() async => resets++;

  @override
  Future<BackupContents> info(String secret, List<int> root) async {
    final j = jsonDecode(utf8.decode(root)) as Map;
    if (j['account'] != _accountOf[secret]) throw Exception('this backup was made with other secret words');
    return BackupContents(created: DateTime.parse(j['created'] as String), messages: 10, chats: 2, media: 1);
  }

  @override
  Future<BackupContents> start(String secret, List<int> root) => info(secret, root);

  @override
  Future<RestoreStepResult> restoreStep(String staging) async {
    for (final n in [_h('e'), _h('1')]) {
      if (!File('$staging/$n').existsSync()) return RestoreStepResult(stage: 'parts', need: [n], done: false);
    }
    return RestoreStepResult(stage: 'done', need: const [], done: true, changed: true, messagesAdded: added);
  }

  @override
  Future<List<String>> media() async => [_h('f'), _h('9')];

  @override
  Future<int> adopt(String staging, List<String> names) async {
    adopted.addAll(names.where((n) => File('$staging/$n').existsSync()));
    return adopted.length;
  }

  @override
  Future<void> clear() async => cleared = true;
}

/// ADR-090 — the server's note of the newest backup per cloud.
class _Mark implements BackupMark {
  final marks = <String, int>{};
  bool down = false;
  @override
  Future<int> mark(String cloud, int createdTs) async {
    if (down) throw Exception('offline');
    if (createdTs > (marks[cloud] ?? 0)) marks[cloud] = createdTs;
    return marks[cloud] ?? 0;
  }
}

void main() {
  late Directory tmp;
  late _Mark mark;
  late _Cloud cloud;
  late _Core core;
  late _Keys keys;
  late _Store settings;
  var refreshes = 0;

  ProviderContainer make() {
    final c = ProviderContainer(
      overrides: [
        cloudStoreProvider.overrideWithValue(cloud),
        backupCoreProvider.overrideWithValue(core),
        backupMarkProvider.overrideWithValue(mark),
        deviceKeyStoreProvider.overrideWithValue(keys),
        settingsStoreProvider.overrideWithValue(settings),
        backupTempDirProvider.overrideWithValue(() async => Directory('${tmp.path}/tmp')..createSync(recursive: true)),
        chatsRefresherProvider.overrideWithValue(ChatsRefresher(invalidate: () => refreshes++, read: () async {})),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Set<String> inCloud() => cloud.dir.existsSync() ? cloud.dir.listSync().map((f) => f.uri.pathSegments.last).toSet() : {};

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sinhron-backup-');
    cloud = _Cloud(Directory('${tmp.path}/cloud'));
    core = _Core()..generation = 1;
    mark = _Mark();
    keys = _Keys('key-A');
    settings = _Store();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a backup goes up under this device\'s tag, root after its parts; the day is noted', () async {
    final c = make();
    final b = c.read(chatBackupProvider.notifier);
    expect(await b.due(DateTime.now()), isTrue, reason: 'never backed up');
    expect(await b.run(), isTrue);
    const a = 'aaaaaaaaaaaaaaaa';
    expect(inCloud(), {'$a-${_h('1')}', '$a-${_h('e')}', '$a-$kBackupRoot', '$a-${_h('f')}'});
    expect(cloud.puts.indexOf('$a-$kBackupRoot'), greaterThan(cloud.puts.indexOf('$a-${_h('e')}')));
    expect(c.read(chatBackupProvider).stage, 'done');
    expect(await b.due(DateTime.now()), isFalse, reason: 'once a day');
    expect(await b.due(DateTime.now().add(kBackupEvery)), isTrue);
    expect(Directory('${tmp.path}/tmp/backup-out').existsSync(), isFalse, reason: 'staging cleaned');
  });

  test('the next backup cleans what this device left — never another device\'s or account\'s files', () async {
    final c = make();
    final b = c.read(chatBackupProvider.notifier);
    await b.run();
    const a = 'aaaaaaaaaaaaaaaa';
    // Another device of this account (fresh) and someone else's account.
    cloud.seed('bbbbbbbbbbbbbbbb-$kBackupRoot', _root('acc1', DateTime.now()));
    cloud.seed('bbbbbbbbbbbbbbbb-${_h('2')}', 'part');
    cloud.seed('cccccccccccccccc-$kBackupRoot', _root('acc2', DateTime.now().subtract(const Duration(days: 90))));
    cloud.seed('cccccccccccccccc-${_h('3')}', 'part');
    cloud.seed('notes.txt', 'not ours');
    cloud.puts.clear();
    core.generation = 4;
    expect(await b.run(), isTrue);
    expect(cloud.puts, isNot(contains('$a-${_h('f')}')), reason: 'the photo is up already');
    expect(cloud.puts, isNot(contains('$a-${_h('e')}')), reason: 'nor an unchanged part');
    expect(inCloud(), {
      '$a-${_h('4')}', '$a-${_h('e')}', '$a-$kBackupRoot', '$a-${_h('f')}', // ours, without p1
      'bbbbbbbbbbbbbbbb-$kBackupRoot', 'bbbbbbbbbbbbbbbb-${_h('2')}',
      'cccccccccccccccc-$kBackupRoot', 'cccccccccccccccc-${_h('3')}', // another account: never touched
      'notes.txt',
    });
  });

  test('another device of this account silent for over a month: its files go, root first', () async {
    cloud.seed('bbbbbbbbbbbbbbbb-$kBackupRoot', _root('acc1', DateTime.now().subtract(const Duration(days: 31))));
    cloud.seed('bbbbbbbbbbbbbbbb-${_h('2')}', 'part');
    final c = make();
    expect(await c.read(chatBackupProvider.notifier).run(), isTrue);
    expect(inCloud().where((n) => n.startsWith('bbbb')), isEmpty);
    expect(cloud.deletes.first, 'bbbbbbbbbbbbbbbb-$kBackupRoot');
  });

  test('storage-devices:11 — deleting the account takes every backup of it from the cloud, no one else\'s', () async {
    final c = make();
    expect(await c.read(chatBackupProvider.notifier).run(), isTrue);
    cloud.seed('bbbbbbbbbbbbbbbb-$kBackupRoot', _root('acc1', DateTime.now())); // my other device
    cloud.seed('bbbbbbbbbbbbbbbb-${_h('2')}', 'part');
    cloud.seed('cccccccccccccccc-$kBackupRoot', _root('acc2', DateTime.now())); // someone else
    cloud.seed('cccccccccccccccc-${_h('3')}', 'part');
    await c.read(chatBackupProvider.notifier).deleteAll();
    expect(inCloud(), {'cccccccccccccccc-$kBackupRoot', 'cccccccccccccccc-${_h('3')}'});
  });

  test('restore: the newest backup these words open, its own files, then the media', () async {
    final old = DateTime.now().subtract(const Duration(days: 3));
    cloud.seed('bbbbbbbbbbbbbbbb-$kBackupRoot', _root('acc1', old));
    cloud.seed('cccccccccccccccc-$kBackupRoot', _root('acc2', DateTime.now()));
    const a = 'aaaaaaaaaaaaaaaa';
    cloud.seed('$a-$kBackupRoot', _root('acc1', DateTime.now().subtract(const Duration(hours: 2))));
    for (final n in ['e', '1', 'f']) {
      cloud.seed('$a-${_h(n)}', 'x');
    }
    keys.value = 'key-B';
    final c = make();
    final b = c.read(chatBackupProvider.notifier);
    final found = await b.find();
    expect(found!.tag, a, reason: 'newest of this account; the other account\'s newer one does not open');
    expect(await b.restore(found), isTrue);
    expect(core.adopted, [_h('f')], reason: 'the photo the backup has; a missing one is skipped');
    expect(core.cleared, isTrue);
    expect(refreshes, greaterThan(0), reason: 'the chat list re-reads');
    expect(c.read(chatBackupProvider).stage, 'restored');
  });

  test('restore takes another device\'s backup over this device\'s own newer one; its own only when alone', () async {
    const a = 'aaaaaaaaaaaaaaaa', b = 'bbbbbbbbbbbbbbbb';
    cloud.seed('$a-$kBackupRoot', _root('acc1', DateTime.now())); // mine, made daily
    cloud.seed('$b-$kBackupRoot', _root('acc1', DateTime.now().subtract(const Duration(hours: 1))));
    final c = make();
    final backup = c.read(chatBackupProvider.notifier);
    expect((await backup.find())!.tag, b, reason: 'my own backup holds nothing this device lacks');
    File('${cloud.dir.path}/$b-$kBackupRoot').deleteSync();
    expect((await backup.find())!.tag, a, reason: 'a reinstalled main device: its own is all there is');
  });

  // storage-devices:14 — whoever controls the cloud put an older backup
  // back: the restore used to take it as the newest, saying nothing.
  test('a cloud rolled back to an older backup: the restore says a newer one is gone', () async {
    const a = 'aaaaaaaaaaaaaaaa', b = 'bbbbbbbbbbbbbbbb';
    final c = make();
    final backup = c.read(chatBackupProvider.notifier);
    expect(await backup.run(), isTrue);
    expect(mark.marks['folder'], isNotNull, reason: 'the server is told when the backup was made');
    // The newest root is gone; an older one (another device's) is back.
    File('${cloud.dir.path}/$a-$kBackupRoot').deleteSync();
    final old = DateTime.now().subtract(const Duration(days: 9));
    cloud.seed('$b-$kBackupRoot', _root('acc1', old));
    final found = await backup.find();
    expect(found!.tag, b);
    expect(found.missingNewer, isNotNull, reason: 'a newer backup was made, and the cloud lost it');
    expect(found.missingNewer!.isAfter(old), isTrue);
    // The newest one there again: nothing to say. The server not answering: as before.
    expect(await backup.run(), isTrue);
    expect((await backup.find())!.missingNewer, isNull);
    mark.down = true;
    File('${cloud.dir.path}/$a-$kBackupRoot').deleteSync();
    expect((await backup.find())!.missingNewer, isNull);
  });

  test('restore says how many messages it added', () async {
    const b = 'bbbbbbbbbbbbbbbb';
    cloud.seed('$b-$kBackupRoot', _root('acc1', DateTime.now()));
    for (final n in ['e', '1', 'f']) {
      cloud.seed('$b-${_h(n)}', 'x');
    }
    final c = make();
    final backup = c.read(chatBackupProvider.notifier);
    expect(await backup.restore((await backup.find())!), isTrue);
    expect(backup.lastRestoreAdded, 7);
    core.added = 0;
    expect(await backup.restore((await backup.find())!), isTrue);
    expect(backup.lastRestoreAdded, 0, reason: 'nothing new — the screen says so instead of "restored"');
  });

  test('"Back up now" starts a fresh snapshot; the daily run goes on with one under way', () async {
    final c = make();
    final backup = c.read(chatBackupProvider.notifier);
    expect(await backup.run(), isTrue);
    expect(core.resets, 1);
    expect(await backup.run(scheduled: true), isTrue);
    expect(core.resets, 1);
  });

  test('a backup iCloud hasn\'t taken yet is shown as still uploading', () async {
    cloud.notUploaded.add('aaaaaaaaaaaaaaaa-$kBackupRoot');
    ChatBackup.uploadWait = Duration.zero;
    addTearDown(() => ChatBackup.uploadWait = const Duration(seconds: 20));
    final c = make();
    expect(await c.read(chatBackupProvider.notifier).run(), isTrue);
    expect(c.read(chatBackupProvider).uploadPending, isTrue);
    cloud.notUploaded.clear();
    expect(await c.read(chatBackupProvider.notifier).run(), isTrue);
    expect(c.read(chatBackupProvider).uploadPending, isFalse);
  });

  test('a backup file gone from the cloud stops the restore with a reason', () async {
    const a = 'aaaaaaaaaaaaaaaa';
    cloud.seed('$a-$kBackupRoot', _root('acc1', DateTime.now()));
    cloud.seed('$a-${_h('e')}', 'x');
    final c = make();
    final b = c.read(chatBackupProvider.notifier);
    expect(await b.restore((await b.find())!), isFalse);
    expect(c.read(chatBackupProvider).error, contains('missing'));
  });

  test('no cloud, or an older linked device: nothing runs, and the screen is told why', () async {
    cloud.connected = false;
    final c = make();
    final b = c.read(chatBackupProvider.notifier);
    expect(await b.run(), isFalse);
    expect(c.read(chatBackupProvider).error, 'not_connected');
    expect(await b.run(scheduled: true), isFalse);

    cloud.connected = true;
    keys.value = 'old';
    expect(await b.run(), isFalse);
    expect(c.read(chatBackupProvider).error, 'no_key');
    expect(await c.read(backupCanProvider.future), isFalse);
    expect(await b.find(), isNull);
    expect(inCloud(), isEmpty);

    expect(await b.unlock('wrong words'), 'other_words');
    expect(keys.value, 'old');
    expect(await b.unlock(_words), isNull);
    expect(keys.value, 'key-A', reason: 'the device key with the backup key in it');
    expect(await c.read(backupCanProvider.future), isTrue);
    expect(await b.run(), isTrue);
  });

  test('backup names: tag and name, nothing else', () {
    expect(splitBackupName('aaaaaaaaaaaaaaaa-$kBackupRoot'), (tag: 'aaaaaaaaaaaaaaaa', name: kBackupRoot));
    expect(splitBackupName(_h('1')), isNull);
    expect(splitBackupName('notes.txt'), isNull);
  });
}
