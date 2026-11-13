// Outgoing media that hasn't landed in the message list yet — ADR-017.
//
// Photo prep + encryption + upload takes seconds, so the chat shows a
// pending bubble ("Sending photo…") right away. On success the item
// disappears (the real message row replaces it); on failure it stays
// as "Not sent — tap to retry" with the original job kept for retry.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/simple.dart' as core;
import 'chat_providers.dart';
import 'message_actions.dart' show messageSenderProvider;

/// A media send job. Calls [reportWireId] with the wire message id of
/// this attempt as soon as it has one, so the UI can poll its upload %.
typedef PendingJob = Future<void> Function(void Function(String wireId) reportWireId);

/// Upload fraction for a wire message id: 0..1, 0 while preparing,
/// negative when unknown. Overridden in tests (no FFI under flutter test).
final uploadProgressProvider = Provider<double Function(String wireId)>(
  (ref) => (id) => core.mediaUploadProgress(messageId: id),
);

enum PendingMediaState { sending, failed }

class PendingMedia {
  const PendingMedia({
    required this.id,
    required this.chatId,
    required this.kind,
    required this.label,
    required this.state,
    required this.job,
    this.error,
    this.wireId,
  });

  final String id;
  final String chatId;

  /// "photo" | "document" | "voice"
  final String kind;

  /// Short UI text, e.g. "Photo" or the document's file name.
  final String label;
  final PendingMediaState state;
  final PendingJob job;
  final String? error;

  /// Wire message id of the current attempt (for upload progress).
  final String? wireId;

  PendingMedia copyWith({PendingMediaState? state, String? error, String? wireId}) => PendingMedia(
        id: id,
        chatId: chatId,
        kind: kind,
        label: label,
        state: state ?? this.state,
        job: job,
        error: error,
        wireId: wireId ?? this.wireId,
      );
}

class PendingMediaNotifier extends Notifier<List<PendingMedia>> {
  int _seq = 0;

  /// Items the person cancelled; their job may still be finishing.
  final _cancelled = <String>{};

  @override
  List<PendingMedia> build() => const [];

  List<PendingMedia> forChat(String chatId) =>
      state.where((p) => p.chatId == chatId).toList(growable: false);

  /// Track [job] (encrypt + upload + send + store) for [chatId]. Never
  /// throws: failures become a retryable `failed` item.
  Future<void> run({
    required String chatId,
    required String kind,
    required String label,
    required PendingJob job,
  }) async {
    final id = 'pending-${_seq++}';
    state = [
      ...state,
      PendingMedia(
        id: id,
        chatId: chatId,
        kind: kind,
        label: label,
        state: PendingMediaState.sending,
        job: job,
      ),
    ];
    await _execute(id);
  }

  Future<void> retry(String id) async {
    final item = _find(id);
    if (item == null || item.state != PendingMediaState.failed) return;
    _replace(item.copyWith(state: PendingMediaState.sending));
    await _execute(id);
  }

  void dismiss(String id) {
    state = state.where((p) => p.id != id).toList(growable: false);
  }

  /// "Cancel sending" while it prepares / uploads (owner, 2026-10-18): the
  /// bubble goes at once, and the send stops before it reaches the network
  /// (Rust checks the cancel before the upload and before encrypt +
  /// submit). Already past that point — it was sent, and stays.
  void cancel(String id) {
    final item = _find(id);
    if (item == null) return;
    _cancelled.add(id);
    final wire = item.wireId;
    if (wire != null) ref.read(messageSenderProvider).cancelSend(wire);
    dismiss(id);
  }

  Future<void> _execute(String id) async {
    final item = _find(id);
    if (item == null) return;
    try {
      await item.job((wireId) {
        if (_cancelled.contains(id)) {
          ref.read(messageSenderProvider).cancelSend(wireId);
          return;
        }
        final current = _find(id);
        if (current != null) _replace(current.copyWith(wireId: wireId));
      });
      _cancelled.remove(id); // too late to cancel: it went out
      dismiss(id);
      // The real message row now exists — refresh chat + list preview.
      markChatChangedFromRef(ref, item.chatId);
      ref.invalidate(chatsProvider);
    } catch (e) {
      if (_cancelled.remove(id)) return; // cancelled: nothing to show
      final current = _find(id);
      if (current != null) {
        _replace(current.copyWith(state: PendingMediaState.failed, error: e.toString()));
      }
    }
  }

  PendingMedia? _find(String id) {
    for (final p in state) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _replace(PendingMedia item) {
    state = [for (final p in state) p.id == item.id ? item : p];
  }
}

final pendingMediaProvider =
    NotifierProvider<PendingMediaNotifier, List<PendingMedia>>(
  PendingMediaNotifier.new,
);
