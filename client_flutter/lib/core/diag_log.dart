// The app's own journal for "Report a problem" (owner, 2026-10-22: bugs
// were chased by screenshots and "I don't remember how I answered").
//
// Every `print` the app makes ([sinhron] / [livekit] / [callkit] lines:
// connection, pushes, calls) lands here as well as in the console, with
// the time. The last hour goes into a report; the tail is kept in a file
// (`diag.log` in Application Support), so a call that failed before the
// app was closed is still there after it opens again. Native code (the
// Android push / call receiver) appends to `diag-native.log` next to it.
//
// Nothing secret is written: the app never prints message text, names or
// keys, and [scrubDiagLine] cuts any long hex (keys, chat ids) down to its
// first 6 characters as a safety net.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// One line of the journal.
typedef DiagLine = ({DateTime at, String text});

/// Long hex runs (keys, group ids, wire ids without dashes) → their start.
final _hex = RegExp(r'\b[0-9a-fA-F]{16,}\b');

String scrubDiagLine(String line) => _hex.allMatches(line).isEmpty
    ? line
    : line.replaceAllMapped(_hex, (m) => '${m[0]!.substring(0, 6)}…');

class DiagLog {
  DiagLog._();
  static final DiagLog instance = DiagLog._();

  /// Lines kept in memory (an hour of a busy call is well under this).
  static const maxLines = 4000;

  /// The file is cut back to its newer half past this size.
  static const maxFileBytes = 512 * 1024;

  static const fileName = 'diag.log';
  static const nativeFileName = 'diag-native.log';

  final _lines = <DiagLine>[];
  final _pending = StringBuffer();
  Timer? _flush;
  File? _file;

  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  /// Where the journal files live (Application Support); null until [open].
  Directory? dir;

  /// Picks up the tail written before this start and keeps writing to it.
  Future<void> open() async {
    try {
      final d = await getApplicationSupportDirectory();
      await d.create(recursive: true);
      dir = d;
      final f = File('${d.path}/$fileName');
      _file = f;
      if (await f.exists()) {
        // The previous runs' lines go before this run's (none of which
        // reached the file yet — it wasn't open).
        _lines.insertAll(0, parseDiagFile(await f.readAsString()));
        _trim();
        if (await f.length() > maxFileBytes) await _rewrite();
      }
    } catch (_) {
      // No file — the journal still works in memory.
    }
  }

  /// Records one line (already printed to the console by the caller).
  void add(String line) {
    final at = clock();
    final text = scrubDiagLine(line);
    _lines.add((at: at, text: text));
    _trim();
    if (_file == null) return;
    _pending.writeln('${at.toUtc().toIso8601String()} $text');
    _flush ??= Timer(const Duration(seconds: 2), _write);
  }

  void _trim() {
    if (_lines.length > maxLines) _lines.removeRange(0, _lines.length - maxLines);
  }

  Future<void> _write() async {
    _flush = null;
    final f = _file;
    if (f == null || _pending.isEmpty) return;
    final chunk = _pending.toString();
    _pending.clear();
    try {
      await f.writeAsString(chunk, mode: FileMode.append, flush: true);
      if (await f.length() > maxFileBytes) await _rewrite();
    } catch (_) {}
  }

  /// Keep the newer half of the memory copy on disk.
  Future<void> _rewrite() async {
    final f = _file;
    if (f == null) return;
    final keep = _lines.skip(_lines.length ~/ 2);
    await f.writeAsString(
      '${[for (final l in keep) '${l.at.toUtc().toIso8601String()} ${l.text}'].join('\n')}\n',
      flush: true,
    );
  }

  /// Lines from the last [window], oldest first.
  List<DiagLine> recent([Duration window = const Duration(hours: 1)]) {
    final since = clock().subtract(window);
    return [
      for (final l in _lines)
        if (!l.at.isBefore(since)) l,
    ];
  }

  /// The native journal's lines from the last [window] (Android push / call
  /// receivers write it; empty elsewhere).
  Future<List<DiagLine>> nativeRecent([Duration window = const Duration(hours: 1)]) async {
    final d = dir;
    if (d == null) return const [];
    try {
      final f = File('${d.path}/$nativeFileName');
      if (!await f.exists()) return const [];
      final since = clock().subtract(window);
      return [
        for (final l in parseDiagFile(await f.readAsString()))
          if (!l.at.isBefore(since)) (at: l.at, text: scrubDiagLine(l.text)),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Status 223 — when the native journal last had a line containing
  /// [needle] (e.g. "fcm: push"), at any time; null when never (or no file).
  Future<DateTime?> nativeLast(String needle) async {
    final d = dir;
    if (d == null) return null;
    try {
      final f = File('${d.path}/$nativeFileName');
      if (!await f.exists()) return null;
      DateTime? last;
      for (final l in parseDiagFile(await f.readAsString())) {
        if (l.text.contains(needle)) last = l.at;
      }
      return last;
    } catch (_) {
      return null;
    }
  }

  /// Sign-out, account deletion, "Erase and start over" (audit
  /// storage-devices:15): the journal of the account that leaves this phone
  /// goes with it — memory, `diag.log` and `diag-native.log`.
  Future<void> clear() async {
    _lines.clear();
    _pending.clear();
    _flush?.cancel();
    _flush = null;
    final d = dir;
    if (d == null) return;
    for (final name in [fileName, nativeFileName]) {
      try {
        final f = File('${d.path}/$name');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  @visibleForTesting
  void reset() {
    _lines.clear();
    _pending.clear();
    _flush?.cancel();
    _flush = null;
    _file = null;
    dir = null;
    clock = DateTime.now;
  }
}

/// "2026-10-22T10:15:03.120Z text" lines → entries (others skipped).
List<DiagLine> parseDiagFile(String s) {
  final out = <DiagLine>[];
  for (final raw in s.split('\n')) {
    final sp = raw.indexOf(' ');
    if (sp <= 0) continue;
    final at = DateTime.tryParse(raw.substring(0, sp));
    if (at == null) continue;
    out.add((at: at.toLocal(), text: raw.substring(sp + 1)));
  }
  return out;
}
