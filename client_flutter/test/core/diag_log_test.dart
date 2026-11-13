// "Report a problem" (owner, 2026-10-22): the journal keeps the last hour
// and never a whole key.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/diag_log.dart';

void main() {
  tearDown(DiagLog.instance.reset);

  test('long hex (keys, chat ids) is cut to its start; the rest stays', () {
    final key = 'ab' * 32;
    expect(scrubDiagLine('[sinhron][net] group $key joined'), '[sinhron][net] group ababab… joined');
    expect(scrubDiagLine('[livekit] voice bitrate → 24 kbps'), '[livekit] voice bitrate → 24 kbps');
    expect(scrubDiagLine('wire 0190a1b2-c3d4'), 'wire 0190a1b2-c3d4', reason: 'short ids stay');
  });

  test('recent: the last hour only, oldest first', () {
    final log = DiagLog.instance;
    var now = DateTime(2026, 10, 22, 10);
    log.clock = () => now;
    log.add('[sinhron] old');
    now = now.add(const Duration(minutes: 50));
    log.add('[sinhron] middle');
    now = now.add(const Duration(minutes: 20));
    log.add('[sinhron] new');
    expect([for (final l in log.recent()) l.text], ['[sinhron] middle', '[sinhron] new']);
  });

  test('the file format reads back; junk lines are skipped', () {
    final lines = parseDiagFile('2026-10-22T07:00:00.000Z [android] fcm: push call\nnot a line\n\n2026-10-22T07:00:05Z [ios] pushkit\n');
    expect([for (final l in lines) l.text], ['[android] fcm: push call', '[ios] pushkit']);
    expect(lines.first.at.toUtc(), DateTime.utc(2026, 10, 22, 7));
  });

  test('storage-devices:15 — signing out leaves no journal of the old account behind', () async {
    final tmp = Directory.systemTemp.createTempSync('sinhron-diag-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/${DiagLog.fileName}').writeAsStringSync('2026-10-22T07:00:00.000Z [sinhron] call ab12cd\n');
    File('${tmp.path}/${DiagLog.nativeFileName}').writeAsStringSync('2026-10-22T07:00:01.000Z [ios] pushkit\n');
    final log = DiagLog.instance..dir = tmp;
    log.add('[sinhron] connected');
    await log.clear();
    expect(tmp.listSync(), isEmpty);
    expect(log.recent(const Duration(days: 9999)), isEmpty);
    expect(await log.nativeRecent(const Duration(days: 9999)), isEmpty);
  });
}
