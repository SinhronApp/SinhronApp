// The "Server" chat — ADR-077.
//
// A server's operator lists the account keys of its administrators
// (SINHRON_ADMIN_IDENTITIES); the server writes them service notices: high
// load (CPU, memory, connections) and new reports. The app asks for them (POST /v1/admin/notices, signed by
// this device) on every connect and once a minute while connected. Anyone who isn't
// an administrator gets "no" once, and the app stops asking until the
// next start — the "Server" row never shows for them.
//
// Notices live on the server (30 days) and only in memory here; what was
// read is remembered in the settings table (`admin_notices_read`).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/simple.dart' as core;
import 'providers/settings_providers.dart';
import 'services/net_service.dart';

/// Settings key: id of the newest notice seen in the "Server" chat.
const kAdminNoticesReadKey = 'admin_notices_read';

/// How often the app asks while it runs.
const kAdminNoticesEvery = Duration(minutes: 1);

/// Most notices kept on screen.
const kAdminNoticesMax = 500;

enum AdminNoticeKind { alert, ok, report }

class AdminNotice {
  const AdminNotice({required this.id, required this.kind, required this.text, required this.at});

  final int id;
  final AdminNoticeKind kind;
  final String text;
  final DateTime at;

  /// First line, for the chat-list row.
  String get headline => text.split('\n').first;
}

AdminNoticeKind adminNoticeKind(String raw) =>
    AdminNoticeKind.values.where((k) => k.name == raw).firstOrNull ?? AdminNoticeKind.ok;

class AdminNoticesState {
  const AdminNoticesState({this.isAdmin = false, this.notices = const [], this.readUpTo = 0});

  /// The server said this person is its administrator.
  final bool isAdmin;

  /// Oldest first.
  final List<AdminNotice> notices;
  final int readUpTo;

  int get unread => notices.where((n) => n.id > readUpTo).length;
  AdminNotice? get last => notices.isEmpty ? null : notices.last;

  AdminNoticesState copyWith({bool? isAdmin, List<AdminNotice>? notices, int? readUpTo}) => AdminNoticesState(
    isAdmin: isAdmin ?? this.isAdmin,
    notices: notices ?? this.notices,
    readUpTo: readUpTo ?? this.readUpTo,
  );
}

/// Notices after an id; null → not an administrator (faked in tests).
typedef AdminNoticesFetch = Future<List<AdminNotice>?> Function(int afterId);

final adminNoticesFetchProvider = Provider<AdminNoticesFetch>((ref) {
  return (afterId) async {
    final base = ref.read(netServiceProvider).httpBaseUrl;
    if (base == null) throw StateError('offline');
    final got = await core.adminNotices(serverBaseUrl: base, afterId: afterId);
    return got
        ?.map(
          (n) => AdminNotice(
            id: n.id,
            kind: adminNoticeKind(n.kind),
            text: n.text,
            at: DateTime.fromMillisecondsSinceEpoch(n.ts * 1000),
          ),
        )
        .toList();
  };
});

/// [ServerNoticesRow] asks on every connect and once a minute while
/// connected (off in tests: they call [AdminNotices.refresh]).
final adminNoticesPollProvider = Provider<bool>((ref) => true);

class AdminNotices extends Notifier<AdminNoticesState> {
  /// False after the server said "not an administrator".
  bool _asking = true;
  bool _busy = false;

  /// Still worth asking (not told "not an administrator" this run).
  bool get asking => _asking;

  @override
  AdminNoticesState build() => const AdminNoticesState();

  /// Ask the server for what's new. Network errors are quiet — next minute.
  Future<void> refresh() async {
    if (!_asking || _busy) return;
    _busy = true;
    try {
      final first = !state.isAdmin;
      final got = await ref.read(adminNoticesFetchProvider)(state.last?.id ?? 0);
      if (got == null) {
        _asking = false;
        state = const AdminNoticesState();
        return;
      }
      var readUpTo = state.readUpTo;
      if (first) {
        readUpTo = int.tryParse(await ref.read(settingsStoreProvider).get(kAdminNoticesReadKey) ?? '') ?? 0;
      }
      final all = [...state.notices, ...got];
      final kept = all.length > kAdminNoticesMax ? all.sublist(all.length - kAdminNoticesMax) : all;
      state = state.copyWith(isAdmin: true, notices: kept, readUpTo: readUpTo);
    } catch (_) {
      // Offline or the server is busy: try again next minute.
    } finally {
      _busy = false;
    }
  }

  /// The "Server" chat was opened: everything in it is read.
  Future<void> markRead() async {
    final last = state.last;
    if (last == null || last.id <= state.readUpTo) return;
    state = state.copyWith(readUpTo: last.id);
    await ref.read(settingsStoreProvider).set(kAdminNoticesReadKey, '${last.id}');
  }
}

final adminNoticesProvider = NotifierProvider<AdminNotices, AdminNoticesState>(AdminNotices.new);
