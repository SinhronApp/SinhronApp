// Opening a received document — ADR-017 stage 3.
//
// iOS can only open/share a FILE, so this is the one place a decrypted
// document touches disk: a fresh directory under the app's temp dir,
// written right before the share sheet and deleted as soon as the sheet
// closes (whatever the user picked). Nothing else is ever written — but
// Android's share_plus serves its own copy (`<temp>/share_plus/<name>`) and
// kept it until the next share: [sweepShareCopies] (storage-devices:7).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;

import 'package:flutter/widgets.dart' show WidgetsBinding;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Keep only characters that are safe in a file name; peers control
/// [name], so no path separators or traversal survive.
String safeFileName(String name) {
  final base = name.split(RegExp(r'[/\\]')).last.trim();
  final cleaned = base.replaceAll(RegExp(r'[^\w\-. ()\[\]а-яА-ЯёЁ]'), '_');
  final noDots = cleaned.replaceAll(RegExp(r'^\.+'), '');
  if (noDots.isEmpty) return 'file';
  return noDots.length > 120 ? noDots.substring(noDots.length - 120) : noDots;
}

const Map<String, String> _mimeByExt = {
  'pdf': 'application/pdf',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'odt': 'application/vnd.oasis.opendocument.text',
  'rtf': 'application/rtf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'json': 'application/json',
  'zip': 'application/zip',
  'epub': 'application/epub+zip',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'heic': 'image/heic',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
};

/// Where the share sheet points from. On iPad it is a popover and must be
/// anchored — without an anchor it silently never opened, so a file I sent
/// couldn't be opened there (owner, 2026-10-18). [from] when the caller
/// knows the tapped box; else the middle of the screen. iPhone ignores it.
Rect shareOrigin([Rect? from]) {
  if (from != null && !from.isEmpty) return from;
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) return const Rect.fromLTWH(0, 0, 1, 1);
  final v = views.first;
  final size = v.physicalSize / v.devicePixelRatio;
  return Rect.fromCenter(center: size.center(Offset.zero), width: 1, height: 1);
}

/// MIME type from the extension; generic binary when unknown.
String mimeTypeForFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _mimeByExt[name.substring(dot + 1).toLowerCase()] ?? 'application/octet-stream';
}

/// False when the person closed the sheet without picking anything.
Future<bool> shareDecryptedFile(
  Uint8List bytes, {
  required String fileName,
  required String mimeType,
  Rect? origin,
}) async {
  final tmp = await getTemporaryDirectory();
  final dir = await Directory(
    '${tmp.path}/share-${DateTime.now().microsecondsSinceEpoch}',
  ).create();
  final file = File('${dir.path}/${safeFileName(fileName)}');
  try {
    await file.writeAsBytes(bytes, flush: true);
    final r = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: mimeType.isEmpty ? null : mimeType)],
        sharePositionOrigin: shareOrigin(origin),
      ),
    );
    return r.status != ShareResultStatus.dismissed;
  } finally {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    // The app the person picked may still be reading the copy: a few minutes.
    unawaited(Future.delayed(const Duration(minutes: 5), () => sweepShareCopies(olderThan: const Duration(minutes: 4))));
  }
}

/// storage-devices:7 — share_plus's plaintext copies older than [olderThan]
/// go (all of them at app start and on sign-out). Never throws.
Future<void> sweepShareCopies({Duration olderThan = Duration.zero, Directory? temp}) async {
  try {
    final dir = Directory('${(temp ?? await getTemporaryDirectory()).path}/share_plus');
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().subtract(olderThan);
    await for (final e in dir.list()) {
      try {
        if (!(await e.stat()).modified.isAfter(cutoff)) await e.delete(recursive: true);
      } catch (_) {}
    }
  } catch (_) {}
}
