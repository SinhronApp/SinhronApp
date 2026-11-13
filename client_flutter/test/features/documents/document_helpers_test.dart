import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/features/chat_list/chat_data.dart';
import 'package:sinhron/features/chat_view/encrypted_media_bubbles.dart';
import 'package:sinhron/features/documents/document_share.dart';

void main() {
  test('peer-supplied file names cannot escape the temp dir', () {
    expect(safeFileName('../../etc/passwd'), 'passwd');
    expect(safeFileName(r'..\..\win.ini'), 'win.ini');
    expect(safeFileName('.hidden'), 'hidden');
    expect(safeFileName(''), 'file');
    expect(safeFileName('отчёт 2026 (финал).pdf'), 'отчёт 2026 (финал).pdf');
    expect(safeFileName('a:b*c?.txt'), 'a_b_c_.txt');
    expect(safeFileName('${'x' * 200}.pdf').length, 120);
    expect(safeFileName('${'x' * 200}.pdf'), endsWith('.pdf'));
  });

  test('mime type from extension', () {
    expect(mimeTypeForFileName('Report.PDF'), 'application/pdf');
    expect(mimeTypeForFileName('notes.txt'), 'text/plain');
    expect(mimeTypeForFileName('archive'), 'application/octet-stream');
    expect(mimeTypeForFileName('x.weird'), 'application/octet-stream');
  });

  test('size and badge labels', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(14 * 1024), '14 KB');
    expect(formatBytes((2.4 * 1024 * 1024).round()), '2.4 MB');
    expect(formatBytes(55 * 1024 * 1024), '55 MB');
    expect(fileBadge('contract.docx', ''), 'DOCX');
    expect(fileBadge('noext', 'application/pdf'), 'PDF');
    expect(fileBadge('noext', ''), 'FILE');
  });

  test('chat list shows what arrived when a media message has no caption', () {
    expect(mediaPreviewFallback('', 'photo'), 'Photo');
    expect(mediaPreviewFallback('', 'voice'), 'Voice message');
    expect(mediaPreviewFallback('', 'document'), 'Document');
    expect(mediaPreviewFallback('look!', 'photo'), 'look!');
    expect(mediaPreviewFallback('', 'text'), '');
  });

  test('storage-devices:7 — the recovery sheet\'s plaintext copy in share_plus/ does not stay for months', () async {
    final temp = Directory.systemTemp.createTempSync('share-sweep');
    addTearDown(() => temp.deleteSync(recursive: true));
    final old = File('${temp.path}/share_plus/sinhron-recovery-sheet.png')..createSync(recursive: true);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    final fresh = File('${temp.path}/share_plus/new.png')..createSync();
    await sweepShareCopies(olderThan: const Duration(minutes: 4), temp: temp);
    expect(old.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue, reason: 'the picked app may still be reading it');
    await sweepShareCopies(temp: temp); // app start, sign-out
    expect(fresh.existsSync(), isFalse);
  });
}
