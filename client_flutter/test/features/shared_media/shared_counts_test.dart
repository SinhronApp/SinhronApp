// Owner, 2026-10-18 — "Media & files" showed the mock's 124 / 86 / 18 in
// every chat; the counts are this chat's now.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/shared_media/real_shared_media.dart';
import 'package:sinhron/src/rust/api/simple.dart' as core;

core.StoredMessageSummary row(int i, String kind, {String? media = '{}', bool deleted = false}) => core.StoredMessageSummary(
  id: 'm$i',
  chatId: 'c',
  tsUnix: 1000 + i,
  body: '',
  kind: kind,
  isMine: false,
  status: 1,
  deleted: deleted,
  mediaJson: media,
);

void main() {
  test('counts are the chat\'s own; round videos count as voice, not media', () {
    final n = sharedCounts([
      row(1, 'photo'),
      row(2, 'photo'),
      row(3, 'document'),
      row(4, 'voice'),
      row(5, 'text'), // a link preview
      row(6, 'text', media: null), // plain text
      row(7, 'photo', media: null), // not downloaded / no media
      row(8, 'video'), // a plain video is media
      row(9, 'video', media: '{"kind":"video","round":true}'), // a round video message (ADR-048) is voice
      row(10, 'photo', deleted: true),
    ]);
    expect(n, {
      SharedSection.media: 3,
      SharedSection.files: 1,
      SharedSection.voice: 2,
      SharedSection.links: 1,
    });
  });

  test('sections are newest first and cut into months', () {
    final rows = [
      row(1, 'voice'),
      row(2, 'video', media: '{"kind":"video","round":true}'),
      row(3, 'voice'),
    ];
    expect(sharedRowsOf(rows, SharedSection.voice).map((r) => r.id), ['m3', 'm2', 'm1']);
    expect(sharedRowsOf(rows, SharedSection.media), isEmpty);
    // Nov 2026 and Oct 2026 (local time — mid-month, so any time zone).
    final nov = DateTime(2026, 11, 15).millisecondsSinceEpoch ~/ 1000;
    final oct = DateTime(2026, 10, 15).millisecondsSinceEpoch ~/ 1000;
    core.StoredMessageSummary at(String id, int ts) => core.StoredMessageSummary(
      id: id,
      chatId: 'c',
      tsUnix: ts,
      body: '',
      kind: 'photo',
      isMine: false,
      status: 1,
      deleted: false,
      mediaJson: '{}',
    );
    final months = byMonth([at('a', nov + 60), at('b', nov), at('c', oct)]);
    expect([for (final m in months) '${m.$1}: ${m.$2.map((r) => r.id).join(' ')}'], [
      'November 2026: a b',
      'October 2026: c',
    ]);
  });
}
